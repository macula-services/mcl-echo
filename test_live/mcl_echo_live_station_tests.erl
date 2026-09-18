%% Live end-to-end proof that the SERVICE, booted as a real OTP
%% application, advertises its echo capability and answers a real
%% mesh-to-mesh call on the PQ fleet. The first live check of the first
%% mcl service.
%%
%% The 11.x port changes what the check needs to arrange: the service
%% boots a puzzle-hardened pq_hybrid node key, every dial is pinned
%% (D5), and the wire procedure `Org/echo' needs its D25 authorization
%% chain in the DHT before the advertise -- the realm-signed
%% org_directory and the org-signed procedure_delegation naming the
%% service's node id. The test provisions the chain the way a realm
%% admin's provisioning step would: it generates the identity key the
%% service will load, derives its node id, publishes the chain through
%% a scratch pool, then boots the service.
%%
%% The org/realm pair is the test's own (`acme.test'), proving the
%% config-driven contract: any realm runs its own echo under its own
%% name. The io.macula fleet deploys the same service with org
%% `io.macula' under the io.macula realm; the code is identical.
%%
%% Runs against pq.station-fi-helsinki.macula.io -- nuremberg currently
%% publishes no station_endpoint, so a direct-dial resolution through
%% it misses (a live-fleet finding, not this repo's).
%%
%% Lives in test_live/, NOT test/ -- excluded from the default
%% `rebar3 eunit' and CI's main gate on purpose. Run explicitly:
%%   rebar3 as live_test eunit --dir test_live
-module(mcl_echo_live_station_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SEED_HOST, <<"pq.station-fi-helsinki.macula.io">>).
-define(SEED_PORT, 4433).
-define(SEED_NODE_ID,
        <<16#004d1f470097ccf8826ce291900e882fdb1f20375e53901facaec0f23eb4efd8:256>>).

the_booted_service_answers_a_real_echo_call_test_() ->
    {timeout, 120, fun run/0}.

run() ->
    stopped_already(mcl_echo),
    {ok, _} = application:ensure_all_started(macula),
    %% A FRESH org per run: the org_directory slot is a signer-deduped
    %% multiset, and every run publishes its own realm key -- a stale
    %% directory from an earlier run would shadow this run's (find_record
    %% returns whichever it holds, and the org_key inside would not match
    %% this run's delegation). A unique org gives each run its own slot,
    %% the way a real deploy's one realm admin owns its one slot.
    Org = <<"acme.test.", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>,
    Realm = macula_realm:id(Org),

    %% The realm admin's provisioning step, arranged by the test: an
    %% identity key for the service to load, and the D25 chain naming
    %% its node id, published before the boot.
    KeyPath = tmp_path(),
    {ok, ServiceKey} = macula_node_keys:generate(
                         identity, profile(),
                         #{puzzle_difficulty =>
                               macula_node_keys:puzzle_difficulty()}),
    ok = macula_node_keys:save(KeyPath, ServiceKey),
    {ok, ServiceNodeId} = macula_node_keys:node_id(ServiceKey),
    {ok, RealmKey} = macula_node_keys:generate(realm, profile()),
    {ok, OrgKey} = macula_node_keys:generate(org, profile()),
    ok = publish_chain(Realm, RealmKey, OrgKey, ServiceNodeId, Org),

    %% Boot the real application on the test realm/org. The om's env is
    %% set on the LOADED mcl_om app (set_env on an unloaded app is a
    %% silent no-op, and the health listener would bind its default
    %% port, 8470, which this box's hecate-rag dev container owns).
    application:load(mcl_om),
    application:set_env(mcl_om, health_port, 0),
    application:set_env(mcl_om, identity_key_path, KeyPath),
    application:set_env(mcl_om, station_seeds, [seed()]),
    application:set_env(mcl_om, realm, Realm),
    application:set_env(mcl_om, org, Org),
    %% The pool pins the realm key the D25 resolution verifies against
    %% -- a deploy configures this from the realm's trust list, exactly
    %% like the consumer's own pin.
    application:set_env(mcl_om, realm_trust,
                        #{Realm => macula_node_keys:public_key(RealmKey)}),
    {ok, _} = application:ensure_all_started(mcl_echo),

    %% A genuinely separate consumer identity/pool, pinning the realm
    %% key a verifying caller would.
    {ok, ConsumerKey} = macula_node_keys:generate(
                          identity, profile(),
                          #{puzzle_difficulty =>
                                macula_node_keys:puzzle_difficulty()}),
    {ok, Consumer} = macula_client:connect(
                       [seed()],
                       #{node_identity => ConsumerKey,
                         realm_trust =>
                           #{Realm =>
                                 macula_node_keys:public_key(RealmKey)}}),
    ok = wait_healthy(Consumer, 200),

    Result = call_when_advertised(Consumer, Realm, Org),
    {ok, _Reply} = Result,

    catch macula_client:close(Consumer),
    application:stop(mcl_echo),
    application:unload(mcl_echo),
    file:delete(KeyPath),

    %% The echo answers with the payload unchanged (minus the
    %% platform-injected caller); keys arrive {text, _}-tagged on the
    %% 11.x wire -- mcl_om_wire:field is the contract.
    {ok, Reply} = Result,
    ?assertEqual(<<"pong">>, mcl_om_wire:field(ping, Reply)).

%% The advertise runs at boot, before the service's pool has its first
%% healthy link -- it fails once with {provider_authorization,
%% no_healthy_station} and the 30s republish tick retries until the DHT
%% record lands. Wait for that record (the honest "the capability is
%% genuinely advertised" signal), then call.
call_when_advertised(Consumer, Realm, Org) ->
    Key = macula_record:procedure_key(Realm, <<Org/binary, "/echo">>),
    call_once_advertised(find_advertised(Consumer, Key, 30), Consumer,
                         Realm, Org).

find_advertised(_Consumer, _Key, 0) ->
    erlang:error(advertise_never_landed);
find_advertised(Consumer, Key, N) ->
    advertised_or_wait(macula:find_records(Consumer, Key), Consumer, Key, N).

advertised_or_wait({ok, [_ | _]}, _Consumer, _Key, _N) ->
    ok;
advertised_or_wait(_Other, Consumer, Key, N) ->
    timer:sleep(2_000),
    find_advertised(Consumer, Key, N - 1).

call_once_advertised(ok, Consumer, Realm, Org) ->
    mcl_om_capabilities:call_capability(
      Consumer, Realm, Org, <<"echo">>,
      #{<<"ping">> => <<"pong">>}, 15_000, #{}).

profile() ->
    {ok, P} = macula_crypto_profile:configured(),
    P.

tmp_path() ->
    Name = binary:encode_hex(crypto:strong_rand_bytes(8)),
    filename:join("/tmp", <<"mcl_echo_live_", Name/binary, ".key">>).

seed() ->
    #{host => ?SEED_HOST, port => ?SEED_PORT,
      expected_node_id => ?SEED_NODE_ID}.

%% The D25 chain, published through a scratch pool with its own
%% identity: the realm-signed org_directory and the org-signed
%% procedure_delegation naming the service's node id.
publish_chain(Realm, RealmKey, OrgKey, ServiceNodeId, Org) ->
    {ok, ScratchKey} = macula_node_keys:generate(
                         identity, profile(),
                         #{puzzle_difficulty =>
                               macula_node_keys:puzzle_difficulty()}),
    {ok, Pool} = macula_client:connect([seed()], #{node_identity => ScratchKey}),
    ok = wait_healthy(Pool, 200),
    OrgKeyId = macula_node_keys:key_id(OrgKey),
    OrgDir = macula_record:sign(
               macula_record:org_directory(Realm, Org, OrgKeyId), RealmKey),
    Deleg = macula_record:sign(
              macula_record:procedure_delegation(OrgKeyId, ServiceNodeId),
              OrgKey),
    ok = macula:put_record(Pool, macula_record:encode(OrgDir)),
    ok = macula:put_record(Pool, macula_record:encode(Deleg)),
    catch macula_client:close(Pool),
    ok.

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).

stopped_already(App) ->
    _ = (catch application:stop(App)),
    _ = application:unload(App),
    ok.
