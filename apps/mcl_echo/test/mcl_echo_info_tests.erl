%% @doc `mcl-echo/info', the procedure mcl_om 0.28 answers for this service with
%% no code of its own: who it is, its versions and what it advertises.
%%
%% Built from this service's real info/0 and its real capabilities/0 with
%% `info' added the way mcl_om:boot/2 adds it, then sent through macula's own
%% frame codec, the path a reply takes. What arrives must be text, never bytes,
%% and name this service, its procedures and the mcl_om 0.28 / macula 12.2 pair
%% it was built with (12.2 under an older mcl_om lets a failed publish
%% announcement kill the publishing process).
-module(mcl_echo_info_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SERVICE, mcl_echo_service).
-define(ORG, <<"mcl-echo">>).

info_round_trip_test_() ->
    {setup, fun configure/0, fun unconfigure/1,
     fun(_) ->
         Reply = through_the_codec(mcl_om_info:render(facts())),
         #{name := Name, version := Version} = ?SERVICE:info(),
         Own = [<<(?ORG)/binary, "/", N/binary>> || #{name := N} <- ?SERVICE:capabilities()],
         [?_assertEqual({text, Name}, maps:get(name, Reply)),
          ?_assertEqual({text, Version}, maps:get(version, Reply)),
          ?_assertEqual({text, ?ORG}, maps:get(org, Reply)),
          ?_assertEqual([{text, C} || C <- [<<(?ORG)/binary, "/info">> | Own]],
                        maps:get(capabilities, Reply)),
          ?_assertEqual([], [V || V <- lists:flatten(maps:values(Reply)), is_binary(V)]),
          %% Floors, not exact versions: mcl_om 0.31 or later WITH macula 12.7.0 or
          %% later. 0.31 registers each capability on its serving station only,
          %% and 12.7.0's pool renews an advertised chain before its 30-minute
          %% delegation lapses (macula#38, D32); on anything older this echo drops
          %% off the mesh when its delegation expires. 12.7.0 also keeps 12.5.1's
          %% request admission fix (macula#37). A later compatible release must
          %% not fail this.
          ?_assert(at_least(maps:get(mcl_om_version, Reply), [0, 31, 0])),
          ?_assert(at_least(maps:get(macula_version, Reply), [12, 7, 0]))]
     end}.

%% The service must leave `info' to mcl_om: declaring its own refuses boot.
the_service_does_not_declare_info_test_() ->
    {setup, fun configure/0, fun unconfigure/1,
     fun(_) -> ?_assertMatch([_ | _], mcl_om_info:with_info(?SERVICE:capabilities())) end}.

%% What mcl_om_info:answer/1 gathers on a live node, from this service's own
%% sources instead of a running mcl_om.
facts() ->
    #{name := Name, version := Version, description := Description} = ?SERVICE:info(),
    Caps = mcl_om_info:with_info(?SERVICE:capabilities()),
    #{name => Name, version => Version, description => Description,
      service_name => Name, box => <<"test-box">>, org => ?ORG,
      node_id => <<16#ab:256>>,
      macula_version => vsn(macula), mcl_om_version => vsn(mcl_om),
      uptime_s => 1, status => ok,
      capabilities => [<<(?ORG)/binary, "/", N/binary>> || #{name := N} <- Caps]}.

%% Whether a `{text, <<"X.Y.Z">>}' version is at least [Major, Minor, Patch].
at_least({text, Vsn}, Floor) ->
    [binary_to_integer(P) || P <- binary:split(Vsn, <<".">>, [global])] >= Floor.

vsn(App) ->
    _ = application:load(App),
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.

through_the_codec(Payload) ->
    {ok, Key} = macula_node_keys:generate(identity, pq_hybrid, #{puzzle_difficulty => 0}),
    Spec = #{request_id => crypto:strong_rand_bytes(16),
             realm => crypto:hash(sha256, <<"io.macula">>),
             procedure => <<(?ORG)/binary, "/info">>,
             target => macula_node_keys:key_id(Key),
             deadline => erlang:system_time(millisecond) + 60_000,
             payload => Payload},
    {ok, Decoded, <<>>} = macula_frame:decode(macula_frame:encode(macula_frame:call(Spec, Key))),
    {ok, #{payload := Delivered}} = macula_frame:verify_request(Decoded, pq_hybrid),
    %% Keys arrive as sent, CBOR text (`{text, <<"name">>}'); values keep their
    %% `{text, _}' tags, which is what the assertions look at.
    maps:from_list([{key(K), V} || {K, V} <- maps:to_list(Delivered)]).

key({text, K}) -> binary_to_existing_atom(K);
key(K) when is_atom(K) -> K.

%% mcl_echo_service:capabilities/0 asserts the realm and org through a RUNNING
%% mcl_om_identity (it refuses to advertise on an unbooted one), so one is
%% booted here on a well-formed realm and this service's org, the way
%% mcl_echo_service_tests boots it.
-define(TEST_REALM,
        <<16#AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899:256>>).

configure() ->
    Profile = application:get_env(macula, crypto_profile),
    ok = application:set_env(macula, crypto_profile, pq_hybrid),
    Running = stop_running_identity(whereis(mcl_om_identity)),
    Saved = {application:get_env(mcl_om, realm), application:get_env(mcl_om, org)},
    ok = application:set_env(mcl_om, realm, ?TEST_REALM),
    ok = application:set_env(mcl_om, org, ?ORG),
    {ok, Pid} = mcl_om_identity:start_link(),
    unlink(Pid),
    {Pid, Running, Saved, Profile}.

%% Everything back as it was, including macula's crypto profile: a later suite
%% in the same VM may depend on it.
unconfigure({Pid, Running, {Realm, Org}, Profile}) ->
    try gen_server:stop(Pid) catch _:_ -> ok end,
    restore(mcl_om, realm, Realm),
    restore(mcl_om, org, Org),
    restore(macula, crypto_profile, Profile),
    restart_identity(Running).

stop_running_identity(undefined) ->
    undefined;
stop_running_identity(Old) ->
    unlink(Old),
    Ref = monitor(process, Old),
    exit(Old, kill),
    receive {'DOWN', Ref, process, Old, _} -> ok after 2_000 -> ok end,
    running.

restore(App, Key, undefined) -> application:unset_env(App, Key);
restore(App, Key, {ok, Value}) -> application:set_env(App, Key, Value).

restart_identity(undefined) -> ok;
restart_identity(running) -> {ok, _} = mcl_om_identity:start_link(), ok.
