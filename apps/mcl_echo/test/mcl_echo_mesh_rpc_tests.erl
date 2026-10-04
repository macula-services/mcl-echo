%%% @doc Tests of `handle_request/2' itself — the pure echo.
%%%
%%% The guards (payload size, rate) are the mcl-om pipeline's now
%%% (mcl-om#13), wrapped at advertise time and tested in mcl-om's own
%%% suites; this module asserts only what this handler does: echo the
%%% payload, minus the platform-injected `caller'.
-module(mcl_echo_mesh_rpc_tests).

-include_lib("eunit/include/eunit.hrl").

handle_request_test_() ->
    [
        fun echoes_a_bare_text_payload_unchanged/0,
        fun echoes_a_map_payload_unchanged/0,
        fun strips_the_platform_injected_caller_key_from_a_map_payload/0
    ].

echoes_a_bare_text_payload_unchanged() ->
    %% Exactly the shape every SDK quickstart sends: `Value::Text("hello")'
    %% roundtrips through macula_cbor_nif as a bare Erlang binary (see
    %% macula_cbor_nif_tests's own binary_roundtrip_test/0 — the
    %% `{text, Bin}' tagging some other services see is applied
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
    %% never something the actual caller put in their own message —
    %% echoing it back would show them a field they never sent.
    Payload = #{<<"greeting">> => <<"hi">>, caller => <<"some-node-id">>},
    {reply, Reply, undefined} = mcl_echo_mesh_rpc:handle_request(Payload, undefined),
    ?assertEqual(#{<<"greeting">> => <<"hi">>}, Reply),
    ?assertNot(maps:is_key(caller, Reply)).
