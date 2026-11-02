%% @doc The release's pre_start hook, rel/hooks/check_echo_limits (mcl-echo#31).
%%
%% config/sys.config.src substitutes each MCL_ECHO_* limit as a bare integer,
%% so an empty or non-numeric value bakes a sys.config that does not parse and
%% the VM dies on a syntax error naming no variable. The hook runs first and
%% refuses with a sentence that names it. These tests source the hook the way
%% the start script does (`. hook') and read its exit status and output.
%%
%% The start script skips a hook whose file is missing without a word, so the
%% wiring in rebar.config is asserted too, not assumed.
-module(mcl_echo_limit_hook_tests).

-include_lib("eunit/include/eunit.hrl").

-define(HOOK, "rel/hooks/check_echo_limits").
-define(VARS, ["MCL_ECHO_MAX_PAYLOAD_BYTES", "MCL_ECHO_WINDOW_MS",
               "MCL_ECHO_PER_CALLER_MAX", "MCL_ECHO_GLOBAL_MAX"]).

%% The image's own defaults (Containerfile ENV) pass.
image_defaults_pass_test() ->
    ?assertMatch({0, _}, run_hook(image_env())).

empty_value_is_refused_by_name_test_() ->
    [refused_by_name(Var, "") || Var <- ?VARS].

unset_value_is_refused_by_name_test_() ->
    [?_assertMatch({1, _}, run_hook(lists:keydelete(Var, 1, image_env()))) || Var <- ?VARS] ++
    [?_assert(names(Var, run_hook(lists:keydelete(Var, 1, image_env())))) || Var <- ?VARS].

not_a_positive_integer_is_refused_test_() ->
    [refused_by_name("MCL_ECHO_WINDOW_MS", Bad)
     || Bad <- ["abc", "0", "-5", "10s", "1.5", "010", " 20", "20 "]].

any_positive_integer_passes_test() ->
    Env = lists:keystore("MCL_ECHO_GLOBAL_MAX", 1, image_env(), {"MCL_ECHO_GLOBAL_MAX", "1"}),
    ?assertMatch({0, _}, run_hook(Env)).

%% relx installs the hook only if both lines are there: the pre_start entry
%% names hooks/check_echo_limits relative to bin/, and the overlay copies the
%% file to exactly that place.
rebar_config_installs_the_hook_test() ->
    {ok, Terms} = file:consult("rebar.config"),
    Relx = proplists:get_value(relx, Terms),
    Hooks = proplists:get_value(extended_start_script_hooks, Relx),
    ?assert(lists:member({custom, "hooks/check_echo_limits"},
                         proplists:get_value(pre_start, Hooks))),
    ?assert(lists:member({copy, ?HOOK, "bin/hooks/check_echo_limits"},
                         proplists:get_value(overlay, Relx))),
    ?assert(filelib:is_regular(?HOOK)).

%% The image builds the release from what it copies in; rel/ must be there.
containerfile_copies_the_hook_test() ->
    {ok, Bin} = file:read_file("Containerfile"),
    ?assertMatch({match, _}, re:run(Bin, "^COPY rel \\./rel$", [multiline])).

refused_by_name(Var, Value) ->
    Env = lists:keystore(Var, 1, image_env(), {Var, Value}),
    Result = run_hook(Env),
    {Var ++ "=" ++ Value,
     [?_assertMatch({1, _}, Result), ?_assert(names(Var, Result))]}.

names(Var, {_Status, Output}) ->
    string:find(Output, Var ++ " must be a positive integer") =/= nomatch.

%% The image's MCL_ECHO_* defaults, read from the Containerfile.
image_env() ->
    {ok, Bin} = file:read_file("Containerfile"),
    [{binary_to_list(K), binary_to_list(V)}
     || Line <- binary:split(Bin, <<"\n">>, [global]),
        {match, [K, V]} <- [re:run(Line, "^ENV (MCL_ECHO_[A-Z_]+)=([0-9]+)$",
                                   [{capture, all_but_first, binary}])]].

%% Sources the hook in a clean sh with only Env set (plus PATH), as the start
%% script does; an `exit' in the hook ends the shell before the marker.
run_hook(Env) ->
    Sh = os:find_executable("sh"),
    Clean = [{"PATH", os:getenv("PATH")} | Env],
    Port = open_port({spawn_executable, os:find_executable("env")},
                     [{args, ["-i" | [K ++ "=" ++ V || {K, V} <- Clean]] ++
                             [Sh, "-c", ". ./" ?HOOK " && echo hook-passed"]},
                      exit_status, stderr_to_stdout, binary, use_stdio]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, S}} -> {S, binary_to_list(Acc)}
    after 10000 -> error(hook_timeout)
    end.
