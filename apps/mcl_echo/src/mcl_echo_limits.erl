%% @doc The echo's inbound limits: the shipped defaults, validation, and
%% the one place the effective values live (persistent_term) so both the
%% size cap in `mcl_echo_mesh_rpc' and the rate limiter in
%% `mcl_echo_limiter' read the same numbers.
%%
%% THE LIMITS ARE OPERATOR CONFIG, NOT CODE (mcl-echo#11). This module
%% ships the defaults; a deploy overrides any subset through this
%% application's `limits' env in `config/sys.config.src' (startup), and
%% an operator changes them on a running node through
%% `mcl_echo_limiter:set_limits/1' (runtime; that path also clears the
%% rate counters when the window length changes). Every path validates
%% here: `set/1' and `validate/1' return `{error, Reason}', while
%% `load/0' at boot RAISES -- a service that silently ignored a typo in
%% its limits would look protected and not be.
%%
%% WHY persistent_term: `mcl_echo_limiter:allow/1' runs in the caller's
%% process on every inbound call and must not serialize through a
%% gen_server. A persistent_term read is shared and copy-free, and the
%% writes are rare: boot, or an operator's explicit `set/1'. The boot
%% load merges the env OVER the effective values rather than over the
%% defaults, so a runtime change survives a limiter crash and restart.
-module(mcl_echo_limits).

%% `get/0' is this module's own API name, next to the auto-imported
%% `erlang:get/0'; the clash is resolved here once instead of at every
%% call site.
-compile({no_auto_import, [get/0]}).

-export([defaults/0, get/0, load/0, set/1, reset/0, validate/1]).

-export_type([limits/0, overrides/0]).

-define(APP, mcl_echo).
-define(PT_KEY, {?MODULE, limits}).
-define(KEYS, [max_payload_external_size, window_ms, per_caller_max, global_max]).

-type limits() :: #{max_payload_external_size := pos_integer(),
                    window_ms := pos_integer(),
                    per_caller_max := pos_integer(),
                    global_max := pos_integer()}.
-type overrides() :: #{atom() => pos_integer()}.

%% @doc The shipped limits, equal to what the code hardcoded before
%% mcl-echo#11: a 4096-byte payload cap (term size, not binary bytes), a
%% 10-second window, 20 calls per caller and 300 globally.
-spec defaults() -> limits().
defaults() ->
    #{max_payload_external_size => 4096,
      window_ms                 => 10000,
      per_caller_max            => 20,
      global_max                => 300}.

%% @doc The effective limits. Returns `defaults/0' when nothing was
%% loaded or set yet, so a module-level unit test never crashes on a
%% missing boot.
-spec get() -> limits().
get() ->
    persistent_term:get(?PT_KEY, defaults()).

%% @doc Boot path: `{mcl_echo, [{limits, Overrides}]}' from sys.config,
%% merged over the effective limits and validated. Raises
%% `{mcl_echo_bad_limits, Reason}' on an unknown key, a non-positive
%% value or `per_caller_max > global_max'.
-spec load() -> limits().
load() ->
    Overrides = application:get_env(?APP, limits, #{}),
    case resolve(get(), Overrides) of
        {ok, Limits} ->
            persistent_term:put(?PT_KEY, Limits),
            Limits;
        {error, Reason} ->
            error({mcl_echo_bad_limits, Reason})
    end.

%% @doc Runtime path: apply a partial (or full) override set over the
%% effective limits. On `{error, Reason}' nothing changes.
-spec set(overrides()) -> {ok, limits()} | {error, term()}.
set(Overrides) ->
    case resolve(get(), Overrides) of
        {ok, Limits} ->
            persistent_term:put(?PT_KEY, Limits),
            {ok, Limits};
        {error, _Reason} = Error ->
            Error
    end.

%% @doc Back to `defaults/0' -- not to the env: the next `load/0'
%% re-applies the env, and an operator resetting by hand wants the
%% shipped values.
-spec reset() -> {ok, limits()}.
reset() ->
    Limits = defaults(),
    persistent_term:put(?PT_KEY, Limits),
    {ok, Limits}.

%% @doc Validate an override set against the effective limits without
%% applying it.
-spec validate(term()) -> ok | {error, term()}.
validate(Overrides) ->
    case resolve(get(), Overrides) of
        {ok, _Limits} -> ok;
        {error, _Reason} = Error -> Error
    end.

resolve(Current, Overrides) when is_map(Overrides) ->
    case validate_entries(maps:to_list(Overrides)) of
        ok -> validate_relation(maps:merge(Current, Overrides));
        {error, _Reason} = Error -> Error
    end;
resolve(_Current, NotMap) ->
    {error, {not_a_map, NotMap}}.

%% The per-caller budget cannot exceed the shared one: a caller over the
%% global max could never be admitted anyway, so the pair is a
%% contradiction worth refusing at the point it is configured.
validate_relation(Merged) ->
    PerCaller = maps:get(per_caller_max, Merged),
    Global = maps:get(global_max, Merged),
    case PerCaller =< Global of
        true -> {ok, Merged};
        false -> {error, {per_caller_above_global, PerCaller, Global}}
    end.

validate_entries([]) ->
    ok;
validate_entries([{Key, Value} | Rest]) ->
    case lists:member(Key, ?KEYS) of
        false -> {error, {unknown_key, Key}};
        true -> validate_value(Key, Value, Rest)
    end.

validate_value(_Key, Value, Rest) when is_integer(Value), Value > 0 ->
    validate_entries(Rest);
validate_value(Key, Value, _Rest) ->
    {error, {not_a_positive_integer, Key, Value}}.
