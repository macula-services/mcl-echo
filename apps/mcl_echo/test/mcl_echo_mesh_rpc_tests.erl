%% @doc Real (not mocked) tests of `handle_request/2' itself -- the
%% actual per-call logic a real inbound CALL frame would reach, exercised
%% directly rather than through a live mesh connection this suite has no
%% need to stand up.
-module(mcl_echo_mesh_rpc_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, Pid} = mcl_echo_limiter:start_link(),
    Pid.

%% Synchronous: see mcl_echo_limiter_tests's own teardown/1 for why.
teardown(Pid) ->
    Ref = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _Reason} -> ok end.

handle_request_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Pid) ->
        [
            fun echoes_a_bare_text_payload_unchanged/0,
            fun echoes_a_map_payload_unchanged/0,
            fun strips_the_platform_injected_caller_key_from_a_map_payload/0,
            fun refuses_a_payload_over_the_size_cap/0,
            fun a_map_payload_is_rate_limited_per_caller/0,
            fun distinct_callers_are_not_limited_by_each_others_traffic/0
        ]
    end}.

echoes_a_bare_text_payload_unchanged() ->
    %% Exactly the shape every SDK quickstart sends: `Value::Text("hello")'
    %% roundtrips through macula_cbor_nif as a bare Erlang binary (see
    %% macula_cbor_nif_tests's own binary_roundtrip_test/0 -- the
    %% `{text, Bin}' tagging some other hecate-* services see is applied
    %% by THEIR OWN wire_in/1-style processing of nested map values, not
    %% by the platform for a bare top-level payload).
    Payload = <<"hello">>,
    ?assertEqual({reply, <<"hello">>, undefined},
                 mcl_echo_mesh_rpc:handle_request(Payload, undefined)).

echoes_a_map_payload_unchanged() ->
    Payload = #{<<"greeting">> => <<"hi">>},
    ?assertEqual({reply, #{<<"greeting">> => <<"hi">>}, undefined},
                 mcl_echo_mesh_rpc:handle_request(Payload, undefined)).

strips_the_platform_injected_caller_key_from_a_map_payload() ->
    %% `caller' is injected by macula_station_link's own dispatch code,
    %% never something the actual caller put in their own message --
    %% echoing it back would show them a field they never sent.
    Payload = #{<<"greeting">> => <<"hi">>, caller => <<"some-node-id">>},
    {reply, Reply, undefined} = mcl_echo_mesh_rpc:handle_request(Payload, undefined),
    ?assertEqual(#{<<"greeting">> => <<"hi">>}, Reply),
    ?assertNot(maps:is_key(caller, Reply)).

refuses_a_payload_over_the_size_cap() ->
    Oversized = binary:copy(<<"x">>, 5000),
    ?assertEqual({error, payload_too_large, undefined},
                 mcl_echo_mesh_rpc:handle_request(Oversized, undefined)).

a_map_payload_is_rate_limited_per_caller() ->
    Caller = unique_caller(),
    Payload = fun() -> #{<<"v">> => 1, caller => Caller} end,
    Results = [mcl_echo_mesh_rpc:handle_request(Payload(), undefined)
               || _ <- lists:seq(1, 20)],
    ?assert(lists:all(fun({reply, _, undefined}) -> true; (_) -> false end, Results)),
    ?assertEqual({error, rate_limited, undefined},
                 mcl_echo_mesh_rpc:handle_request(Payload(), undefined)).

distinct_callers_are_not_limited_by_each_others_traffic() ->
    CallerA = unique_caller(),
    CallerB = unique_caller(),
    PayloadFor = fun(C) -> #{<<"v">> => 1, caller => C} end,
    [mcl_echo_mesh_rpc:handle_request(PayloadFor(CallerA), undefined)
     || _ <- lists:seq(1, 20)],
    ?assertEqual({error, rate_limited, undefined},
                 mcl_echo_mesh_rpc:handle_request(PayloadFor(CallerA), undefined)),
    ?assertMatch({reply, _, undefined},
                 mcl_echo_mesh_rpc:handle_request(PayloadFor(CallerB), undefined)).

unique_caller() ->
    N = erlang:unique_integer([positive, monotonic]),
    <<"caller-", (integer_to_binary(N))/binary>>.
