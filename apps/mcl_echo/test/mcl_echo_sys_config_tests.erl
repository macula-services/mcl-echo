%% @doc The release config, asserted in a way relx does not.
%%
%% The release bakes config/sys.config.src into sys.config after relx
%% substitutes every ${VAR} placeholder from the environment, and NOTHING
%% in the pipeline parses the result: relx copies the template unvalidated,
%% eunit never reads it, and a release image boots (or fails to) long after
%% the gate is green. 0.2.1 shipped exactly that: the #13 edit left a
%% trailing comma on the last mcl_om entry, the commented-out inbound_guard
%% block below it, and the node crash-looped on `syntax error before: ']''
%% in the baked sys.config. Erlang has no trailing commas.
%%
%% This test fills the placeholders and parses the result, so the whole
%% class of substitution-time breakage fails eunit instead of the fleet.
-module(mcl_echo_sys_config_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REALM, <<"abb81b5a614b63551b400b810648c0c8a78efad845442630c94b46cc95d2fcd1">>).

sys_config_template_parses_after_substitution_test() ->
    {ok, Bin} = file:read_file("config/sys.config.src"),
    Substituted = lists:foldl(fun({Placeholder, Value}, Acc) ->
                                  binary:replace(Acc, Placeholder, Value, [global])
                              end, Bin,
                              [{<<"${MCL_HEALTH_PORT}">>, <<"8461">>},
                               {<<"${MCL_REALM}">>, ?REALM},
                               {<<"${MCL_REALM_KEY}">>, ?REALM}]),
    {ok, Tokens, _} = erl_scan:string(binary_to_list(Substituted)),
    case erl_parse:parse_term(Tokens) of
        {ok, _} ->
            ok;
        {error, {Line, Mod, Msg}} ->
            erlang:error({sys_config_parse_failed, Line, Mod, lists:flatten(Msg)})
    end.
