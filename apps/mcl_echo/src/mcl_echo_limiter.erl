%% @doc A fixed-window request-rate limiter for the echo procedure.
%%
%% `io.macula.echo' is deliberately public and unauthenticated -- that is
%% the whole point of a hello-world target -- so it gets nothing for free
%% from the platform: `macula_station_link''s own dispatch code carries no
%% rate limiting or backpressure at any layer (traced directly, not
%% assumed). "Let it crash" is not a defense against a caller that keeps
%% calling.
%%
%% Keyed by caller NodeId when the platform actually hands one to a
%% handler, which it only does when the payload is a map (see
%% `mcl_echo_mesh_rpc' for why most real traffic here is NOT a map, and
%% therefore falls back to `?GLOBAL_KEY').
%%
%% THE LIMITS ARE OPERATOR CONFIG (mcl-echo#11): `mcl_echo_limits' owns
%% the defaults and the validation, `set_limits/1' changes them on a
%% running node, and `allow/1' reads them from persistent_term per call
%% rather than binding them into the compiled code. A window-length
%% change clears the counters: the window number renames every key, and
%% old keys under a longer window would look like the future and never be
%% swept.
%%
%% Fixed-window, not sliding or token-bucket: `Window = Now div WindowMs'
%% makes a new window a NEW ets key, so `ets:update_counter/4' with a
%% default tuple is the entire atomic increment-and-check -- no
%% lookup-then-insert race under concurrent bursts, which matters here
%% specifically because `macula_response' spawns one fresh, independent
%% process per inbound call, so a burst from one caller runs genuinely
%% concurrently, not serialized through any single gen_server.
-module(mcl_echo_limiter).

-behaviour(gen_server).

-export([start_link/0, allow/1, get_limits/0, set_limits/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, mcl_echo_limiter_table).
-define(GLOBAL_KEY, '$global').
-define(CLEANUP_INTERVAL_MS, 60000).
-define(RETAIN_WINDOWS, 3).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc `Key' is a caller NodeId (binary, the wire-authenticated public
%% key) when the platform provided one, or the atom `'$global'' for a
%% call the platform gave no attribution for. Every un-attributable call
%% shares one counter, deliberately -- it is the only defense available
%% for that traffic, not a per-caller one wearing a global disguise.
-spec allow(binary() | '$global') -> allow | deny.
allow(Key) ->
    Limits = mcl_echo_limits:get(),
    Window = current_window(Limits),
    Max = max_for(Key, Limits),
    Count = ets:update_counter(?TABLE, {Key, Window}, {2, 1}, {{Key, Window}, 0}),
    verdict(Count, Max).

current_window() ->
    current_window(mcl_echo_limits:get()).

current_window(Limits) ->
    erlang:monotonic_time(millisecond) div maps:get(window_ms, Limits).

verdict(Count, Max) when Count =< Max -> allow;
verdict(_Count, _Max) -> deny.

max_for(?GLOBAL_KEY, Limits) -> maps:get(global_max, Limits);
max_for(_CallerNodeId, Limits) -> maps:get(per_caller_max, Limits).

%% @doc The effective limits, for callers that want to report or assert
%% them -- the same map `mcl_echo_limits:get/0' returns.
-spec get_limits() -> mcl_echo_limits:limits().
get_limits() ->
    mcl_echo_limits:get().

%% @doc The runtime operator path (mcl-echo#11): apply a partial
%% override set over the effective limits, then clear the counters when
%% the window length changed. Validation lives in `mcl_echo_limits'; on
%% `{error, Reason}' nothing changed, counters included.
-spec set_limits(mcl_echo_limits:overrides()) ->
          {ok, mcl_echo_limits:limits()} | {error, term()}.
set_limits(Overrides) ->
    Old = mcl_echo_limits:get(),
    case mcl_echo_limits:set(Overrides) of
        {ok, New} ->
            ok = maybe_clear_on_window_change(maps:get(window_ms, Old),
                                              maps:get(window_ms, New)),
            {ok, New};
        {error, _Reason} = Error ->
            Error
    end.

maybe_clear_on_window_change(Same, Same) ->
    ok;
maybe_clear_on_window_change(_Old, _New) ->
    clear_counters().

clear_counters() ->
    case ets:info(?TABLE) of
        undefined -> ok;
        _Table -> ets:delete_all_objects(?TABLE), ok
    end.

init([]) ->
    %% Validate and publish the configured limits BEFORE the table
    %% exists: a typo in sys.config must stop this service, not start it
    %% with defaults that only look protected (mcl-echo#11).
    _ = mcl_echo_limits:load(),
    ?TABLE = ets:new(?TABLE, [set, public, named_table, {write_concurrency, true}]),
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), sweep),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    sweep_old_windows(),
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), sweep),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% Drops windows old enough that nothing still-live could be reading
%% them, so the table stays bounded by (distinct callers seen recently)
%% rather than growing forever.
sweep_old_windows() ->
    Cutoff = current_window() - ?RETAIN_WINDOWS,
    MatchSpec = [{{{'_', '$1'}, '_'}, [{'<', '$1', Cutoff}], [true]}],
    ets:select_delete(?TABLE, MatchSpec).
