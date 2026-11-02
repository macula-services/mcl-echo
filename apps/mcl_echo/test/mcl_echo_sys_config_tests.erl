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
    _ = parsed_sys_config().

%% The echo names its KEM key (macula-fleet#7): callers seal to it, and a clear
%% caller is still answered (its capability is `preferred', the default). A
%% release that dropped the line would answer every call in the clear and look
%% healthy, so the baked config is asserted, not assumed.
kem_advertise_enabled_test() ->
    Macula = proplists:get_value(macula, parsed_sys_config()),
    ?assertEqual(enabled, proplists:get_value(kem_advertise, Macula)).

%% mcl-echo#11: the echo's numbers come from config, per environment. Filled
%% from the image's own defaults (Containerfile ENV), the entry equals what the
%% capability declares, so a box that overrides nothing runs exactly the code's
%% numbers; and the guard's boot check accepts it.
image_default_limits_equal_the_capabilitys_test() ->
    MclOm = proplists:get_value(mcl_om, parsed_sys_config()),
    #{procedures := #{<<"mcl-echo/echo">> := Configured}} =
        proplists:get_value(inbound_guard, MclOm),
    [#{limits := Declared}] = mcl_echo_service_limits(),
    ?assertEqual(Declared, Configured),
    _ = application:load(mcl_om),
    ok = application:set_env(mcl_om, inbound_guard, proplists:get_value(inbound_guard, MclOm)),
    try ?assertEqual(ok, mcl_om_guard_limits:validate_config())
    after application:unset_env(mcl_om, inbound_guard)
    end.

%% capabilities/0 asserts the live realm and org first; the limits are a
%% literal in it, read here without a booted identity.
mcl_echo_service_limits() ->
    {ok, Forms} = epp:parse_file("apps/mcl_echo/src/mcl_echo_service.erl", []),
    [Clause] = [C || {function, _, capabilities, 0, [C]} <- Forms],
    {clause, _, [], [], Body} = Clause,
    {value, Caps, _} = erl_eval:exprs([lists:last(Body)], []),
    Caps.

%% The image's ENV defaults, KEY=VALUE per line.
image_env() ->
    {ok, Bin} = file:read_file("Containerfile"),
    [{iolist_to_binary(["${", K, "}"]), V}
     || Line <- binary:split(Bin, <<"\n">>, [global]),
        {match, [K, V]} <- [re:run(Line, "^ENV (MCL_ECHO_[A-Z_]+)=([0-9]+)$",
                                   [{capture, all_but_first, binary}])]].

parsed_sys_config() ->
    {ok, Bin} = file:read_file("config/sys.config.src"),
    Substituted = lists:foldl(fun({Placeholder, Value}, Acc) ->
                                  binary:replace(Acc, Placeholder, Value, [global])
                              end, Bin,
                              [{<<"${MCL_HEALTH_PORT}">>, <<"8461">>},
                               {<<"${MCL_REALM}">>, ?REALM},
                               {<<"${MCL_REALM_KEY}">>, ?REALM} | image_env()]),
    {ok, Tokens, _} = erl_scan:string(binary_to_list(Substituted)),
    case erl_parse:parse_term(Tokens) of
        {ok, Config} ->
            Config;
        {error, {Line, Mod, Msg}} ->
            erlang:error({sys_config_parse_failed, Line, Mod, lists:flatten(Msg)})
    end.
