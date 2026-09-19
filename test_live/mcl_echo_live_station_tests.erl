%% Live end-to-end proof that the SERVICE, booted as a real OTP
%% application, advertises its echo capability and answers a real
%% mesh-to-mesh call on the PQ fleet. The first live check of the first
%% mcl service.
%%
%% TWO MODES:
%%
%%   scratch (default) — the test provisions its own chain: a fresh
%%   `acme.test.<random>' org with the realm-name-org convention, its
%%   own realm key, and the D25 chain published through a scratch pool
%%   before the boot. Self-contained; nothing outside the test matters.
%%
%%   real (MCL_LIVE_REALM set) — the honest deployment shape: org
%%   `mcl-echo' under the REAL io.macula realm (one org per service,
%%   PLAN_PROVIDER_AUTHORIZATION_FLOW.md). The test does NOT provision
%%   anything: the service's own boot claim (mcl_om 0.2) asks the realm
%%   for its delegation over the wire, the realm's operator admits +
%%   issues (tick box or admin RPC), and the test's advertise-wait
%%   proves the REAL chain resolved. The service identity loads from
%%   MCL_LIVE_IDENTITY (default /tmp/mcl_echo_live_realm.key) — the
%%   operator must admit THAT node id; run/0 prints it at boot.
%%
%% The 11.x port changes what the check needs to arrange: the service
%% boots a puzzle-hardened pq_hybrid node key, every dial is pinned
%% (D5), and the wire procedure `Org/echo' needs its D25 authorization
%% chain in the DHT before the advertise — the realm-signed
%% org_directory and the org-signed procedure_delegation naming the
%% service's node id.
%%
%% Runs against pq.station-fi-helsinki.macula.io -- nuremberg currently
%% publishes no station_endpoint, so a direct-dial resolution through
%% it misses (a live-fleet finding, not this repo's).
%%
%% Lives in test_live/, NOT test/ -- excluded from the default
%% `rebar3 eunit' and CI's main gate on purpose. Run explicitly:
%%   rebar3 as live_test eunit --dir test_live
%%   MCL_LIVE_REALM=1 rebar3 as live_test eunit --dir test_live
-module(mcl_echo_live_station_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SEED_HOST, <<"pq.station-fi-helsinki.macula.io">>).
-define(SEED_PORT, 4433).
-define(SEED_NODE_ID,
        <<16#004d1f470097ccf8826ce291900e882fdb1f20375e53901facaec0f23eb4efd8:256>>).

%% The REAL io.macula realm: the wire tag and the realm signing key's
%% PUBLIC half (the realm_trust pin every caller holds — read off the
%% macula.io box's realm-key.pq.bin, public material only).
-define(REAL_REALM_NAME, <<"io.macula">>).
-define(REAL_ORG, <<"mcl-echo">>).
-define(REAL_REALM_KEY,
        <<16#1A6B9042FEC6F6D17AE36139FF5598B268AB03A77187D28E0E2AF9DEC071FC55:256,
          16#4BBCF4C79DBAA4E9761496E2EFEAAB34EABAE67E975735684A6A6DC355235701:256,
          16#730F17DE29C3E5F95BFA082DBAAD6312014FF318BFB351BAFE8DD06DDD2354F1:256,
          16#97E4D383749DCF3AE78F63EA08F3FCB5907D8ED9C7FA2A860D1E1DB305D28E81:256,
          16#4E88A6A4CF8A336D8797C2C43513BDC9F471326FF480650C3D2345448CA5AADC:256,
          16#816400CF33AABB73321895C9BD4375DC89F351E95F75C33B50F83372DDAEA43B:256,
          16#2284B423EA48CC86767C6B990ADE766C07C8467B6D42C5F5EE660C23D309CF8C:256,
          16#9A729D54C1D50149B67D343553E825E4FA987D382A5DD6E44FEC71EA949FA881:256,
          16#4B58BA06F44E5E55BAB22B6B071F15D9A5D91B8FFBCB53078FB4AE115D3011BD:256,
          16#6CE887AF5EF54FE054C32EE5271E6EB80BBD4294742A2B67F1A62BBC82BE0159:256,
          16#A3E52BD21D9E2E3EF5D7E0A52389DEDE71B2F6D33F0FB2E28B03771B15E994DF:256,
          16#AAD0A412C9AA356A1746334DB68B94E12A0BE6EA7D375D68D188BC0E11A7DC83:256,
          16#C9CA30F7A975D5F032E8BEC77325415CE800B53B3D2B18A48189AB0BB283B492:256,
          16#5D6BBA0CCB198597F4B2BAA2AE2F813D4A8A04CFEF54CBB638E8004F97C63DFA:256,
          16#DD134D29CFB17E7B6C9C23653EDF1CD2BAAEA4091BECC804684606D75099901F:256,
          16#D6E4D4ECF8B42F1A7055168FF32A43CD8BC8500687CC79B49D831C7CD7DCE87E:256,
          16#05B6F945F39243588E3AE55506D5E97465AAD8652F26D2A8851CD7B3F0B621E6:256,
          16#E035E186511AC49F434E26D8FEE8450856FE7E0949AA6A8465FCB8620FDE8A5C:256,
          16#9142605478F1C1C1101BC19724C106283F0EA35F746FA1AE423EC3FBB561A5D0:256,
          16#CE16B3196F4ECDC41D2CB7A6AF64E9E91516238CE0A5BE7C6F810F3FE76E298C:256,
          16#0F68ED1D2AAF94921AA357BCB23A177AC5CA2B2C12345AB5B5E4826D81F89846:256,
          16#AB09D6A8D92A96194873764B1B6B7C65F5C3C11B283BCBA092F3A64340D83D01:256,
          16#7139C035FBE8AF3D7DC720961C7A4ADE30F246B24F7697F1AB64218630D1BCD0:256,
          16#FD47AC86801216E4738403297A95E82670DC860F1873741E5BBC01A6E4A7DBD9:256,
          16#F7D4C1320A4A8736C28AB5852AABB89457E60A409E467E253A0E650C767DA3D7:256,
          16#B20844C0CDC4208B41FF429D4124234D2983BEA7720DA3B3E077A77CFA31DF47:256,
          16#338643C142D6744EAACBACE119D22FC92B62B238F8179A625B2807B8898EE9B5:256,
          16#DB48B1446694CE02D4C54B08D70AA733A41A8B86761CF6BF3F53817EE24CEBBD:256,
          16#EB00ECF726585F16D124C4B85F04122690426EB27134D1E3A133F6A2EA40A06D:256,
          16#6BE2B89F64BAFDA2AC4D4FB612B2345C5AA17E9FB93206039D478063B49C6F73:256,
          16#21FFE986B009DDE950C351B3E01F3B44DD0F99B58100A647D6060DB2DB8AD522:256,
          16#7B092C8CD40AFE011D9B3B9D89F9072D352E0B75AC3A285E6B66FD7F8619308F:256,
          16#2ACBC92FD27FE0B2EAC5B6FFCC63DC5CFE749550DA03372ADD40CDDC51A489CB:256,
          16#BA82C621279944B83C401BF5C863504F25242FD03604EE83A5E3BA021109F591:256,
          16#14D8B0D80B803D116B78E6BC5E100885DAA46E563A06CC85503925ADD3C6BA4A:256,
          16#47BB86B55EE5160A412C24816CB78697B01CC71DB5A6DBF04AE2AB2415AE3BDA:256,
          16#35127220414B8C243F3F36876B68E9DBDDCAA16EB3E990CD0AB879CD5F8080C8:256,
          16#E9DC0404F2C700A6830F6892A89DE80A4965B0566DAB78C2E428C3B1BC7E9C45:256,
          16#C024903A0AE70FB6407E89D2637E973C0853552B37163FB5D4119521318DE1E7:256,
          16#8CA745683DA49299D7041EC722E1EE16703E79D47B5F2A7BEB341B01682D4B4E:256,
          16#9C5604194A62AB8140B2A0DC913145E0C429295727D4E3E79D4DA2927258A4B2:256,
          16#ED289FBDA01FB3CF0BFFC50C677D7E8CD1EC69032243F9ED30F642E8BE0A2EAA:256,
          16#2ED377FD9A44F0FA0452DE395797061D415215BA042FC7F6A82402198C72B3E4:256,
          16#A783D7A27A3DD1E4DCD7729414EFEE4E724D6983B80382C959C31C33A082E016:256,
          16#58C01DC3EA76246719F86F96DFF7F8B7AA11AF3BD58AEBB4B35FDAEF38146C93:256,
          16#F043E907C73AD5D822FB6866BC3DE09E8F4A30211C8671E48C7C422EEBEF1F1C:256,
          16#269CC717BDB74772D84AFBC8FC3232808DFFA21F10A1C56BA8FC30DCC30C9B66:256,
          16#01C5E64620F07874FA0AB4B332D257AA702AB2A4275BA0009C17BB80DFAF7224:256,
          16#4274A60CC0695CA9B296CD143B4BEBC5FBA68894812319E48284BA06AB2AF5E0:256,
          16#B04808ADDA488050290DB01D5403118B078A117D0D3C4FFAC07478FE8BDF055C:256,
          16#E1031CA0DD597E8B18D77777AF6D0EA7CE0318972FB04FC898021388275DC3DB:256,
          16#D6B799298455F4B88D7EBB0F820359CC5C26B305716AF08E90EF0DC935FC16F8:256,
          16#7DE24B1A1B7A543FC2A1E42DDED031D149DC04D2197DFDDAFDBC615C0BE78B19:256,
          16#5A85CB701DB036456D826330B6B5C534AD7F2B16D9120E42FB746209DCE5EA03:256,
          16#068CAF320E9EE28CE17D238A5BE5736E91DCA177FACE15863356F52F87A8D44E:256,
          16#96E757EE4BB26552110BFE81A1491BF70DD4228D6A801AC92238B3452E37DC25:256,
          16#F5DED861F50FFFB2BA9A72789152E91601EDE4429D3B1B8E0756C569068FF1E0:256,
          16#A1665642695E2C4EB31CC1AE74D944D1840F393FFB08824A55AE77E15BBBDB22:256,
          16#2DCAF73D2E19FC1073881DBA187118DE9E1B9F16A5FBD636E025B0E0E6C30291:256,
          16#8FD03405A4DC54D3A9C757B597E560CE05B7E0122A6FBCDFA9D2C6F8C8BB1141:256,
          16#C7C19F1DE233306353222A6D83933CA658748800442502F52202429CB745F8AA:256,
          16#F96451DABA3B8B74BF35716F6DBDDC5C87E22AC2820C1FFABE707525EBC04A9B:256,
          16#1ABBE4AFE6C5E9CEFCD5358E23BD13EB31072C6B57133FF7CBA457EF3318AFBD:256,
          16#1A953BCA6EF26B59B89ED386AF3A857ED4EB03F8BC822C01D80C6217952AB219:256,
          16#F7A22E961C3F7EBA7B6D65DA0EA5CFB1E99A40B05F229F728ADCFACEC7B9DFCB:256,
          16#F1662E790A60B8499C07FD6E5A93ED9737BBDF52679DFD78D0B86C206E2CE92D:256,
          16#9F4EB612B65EEE3433AACA6C1EE43970176018306777115AFC287DAA0A2B5823:256,
          16#E1309877C9EA0EF05CB0B5610E575B19652142B81784191DBB62CCE543CD004A:256,
          16#838A9400533C8E6887B2D5D07BA6671F7EC3A7D4DF0251C2F60261B2E8F28F14:256,
          16#B772BA60C0EDC73635779555DE1BE974AB823470DA12216C9C000D4781C706BB:256,
          16#887259B96ECC11AF692EF143EAF1DAC715CEED96DD3191CA479918727273280C:256,
          16#4137C795DBF2DDA9DB0D2D1F62FC64FF067012DE007AC3103EC5C171D762CCE5:256,
          16#046C69BBE7F66F676EEECB98CF18CC2E1D7BC0A0A04021857350E9646D1EE512:256,
          16#8DAC3536AC67682C673C0BA8B8D67284E592017CEAFB421EE091586CF9D3B886:256,
          16#34DF0BB0206FABA5D0D87FEF85DD51053EAD7DAFBDA474A55ECEDBAEFB1B01A8:256,
          16#55983FB7A46175D0591CC9B8CDB9A7558298B7D08EE50001D8F67D2CB741289D:256,
          16#4E5677BCB73F3525E2E92AEF8C49D24CB379D84580A22903905D4F3881DE8385:256,
          16#91947662FB44EFD3C142A7B7D87CF942FED6B5F1361BBA53A68A3524B1A413F6:256,
          16#68592A1070C7079A87FA537AFC29F9D06D3DC70D30E7BF3320B825CEFE6F031A:256,
          16#C8B98A8BB1345E309C0C27A767F471E4D89D560BAAFC00119331AF131378BD1C:256,
          16#4BDFFCFA98B0BBCC50FE4D3A82F59C43022846960218484AA15294F94E0094DD:256,
          16#3082020A0282020100975043DE212AA819E2D1841959664B84D9491AC6E89A61:256,
          16#BC10FD22AEDFE7BA66C2E301C868577FD2F4A977947AA2445B2952B861AE80F4:256,
          16#1E808058BA57B544D268C2EAA16F2D9E9C8DD6C15AC77ABD1880267B08AA44DE:256,
          16#53C75EE50F346954F9DFED4B43B44AE99831ACBC1BF01C2E24318135E8B207DD:256,
          16#C2B71BA9A4FABA442C38289E7655066D12197E72AB402CABA38B1339E9F72ED4:256,
          16#B1859E9BBE49FFF226618541B7DA2E50EDA90323B451EA42F6804B6F589D5DD8:256,
          16#BEF924F78F1517FE812E81672B41C8EFA49D5B3CF0965B40F3F50EC2A68A8F08:256,
          16#25999E6E4983EF278690C259661EFEA454D284ECE4B32C52B0DAB46C6EE309E6:256,
          16#C2CECD0D96E0B725F443250A28E922A17D110CE5B32947AD800EF4AD68D00210:256,
          16#4E7622AB21CE7B6AE93827DD31A50E841E248EE973151254F4E2800F47A76308:256,
          16#27C42E42AFD90C2338BD71D0A15E9DE6E93921746BB384ADCC3887FCD1DEF308:256,
          16#6BCE3B17238EA31DC4F886A88F93BEF2B3C8ED9FE35D51AEE158C1A1AEA8D2A4:256,
          16#876A2101D17CEBAAF182D9BBA36E09B59422911DC7079D57D3DF7F5216345908:256,
          16#C51625414F456AA3CB890836B31DA42B0FB7E85C68EC5DE0071B4BA044C25CA8:256,
          16#FAFC38CF840DCB0747D6C21B3F30EE656320C5701A85B94D2148B44AE37E9185:256,
          16#C621C8C2AFC47C4C8B9458863F4824A6806420D15F90127062BB96A92D392816:256,
          16#D60D01D3A15D043B6B0203010001:112>>).

the_booted_service_answers_a_real_echo_call_test_() ->
    {timeout, demo_timeout(), fun run/0}.

demo_timeout() ->
    case os:getenv("MCL_LIVE_DEMO") of
        false -> 120;
        _     -> 1200
    end.

run() ->
    case os:getenv("MCL_LIVE_REALM") of
        false   -> run_scratch();
        _Other  -> run_real()
    end.

%% The self-contained path: a fresh org with the realm-name-org
%% convention, the chain published by the test itself.
run_scratch() ->
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

    _ = close_quietly(Consumer),
    application:stop(mcl_echo),
    application:unload(mcl_echo),
    file:delete(KeyPath),

    %% The echo answers with the payload unchanged (minus the
    %% platform-injected caller); keys arrive {text, _}-tagged on the
    %% 11.x wire -- mcl_om_wire:field is the contract.
    {ok, Reply} = Result,
    ?assertEqual(<<"pong">>, mcl_om_wire:field(ping, Reply)).

%% The REAL-realm path (MCL_LIVE_REALM set): org `mcl-echo' under the
%% io.macula realm, nothing provisioned here. The service's own boot
%% claim asks the realm for the delegation; the realm's operator
%% admits + issues while this test's advertise-wait retries.
run_real() ->
    stopped_already(mcl_echo),
    {ok, _} = application:ensure_all_started(macula),

    Realm = macula_realm:id(?REAL_REALM_NAME),
    KeyPath = real_identity_path(),
    {ok, ServiceKey} = load_or_generate_identity(KeyPath),
    {ok, ServiceNodeId} = macula_node_keys:node_id(ServiceKey),
    io:format("mcl_echo_live: REAL realm ~s, org ~s, node id ~s~n",
              [?REAL_REALM_NAME, ?REAL_ORG,
               binary:encode_hex(ServiceNodeId, lowercase)]),

    %% Boot the real application under the real pair, pinning the real
    %% realm key. No chain publish: the claim + the operator issue it.
    application:load(mcl_om),
    application:set_env(mcl_om, health_port, 0),
    application:set_env(mcl_om, identity_key_path, KeyPath),
    application:set_env(mcl_om, station_seeds, [seed()]),
    application:set_env(mcl_om, realm, Realm),
    application:set_env(mcl_om, org, ?REAL_ORG),
    %% The claim's own payload carries the node's human context —
    %% the desk shows "mcl-echo on beam02.lab" from these.
    application:set_env(mcl_om, service_name, <<"mcl-echo">>),
    application:set_env(mcl_om, box, <<"beam02.lab">>),
    application:set_env(mcl_om, realm_trust, #{Realm => ?REAL_REALM_KEY}),
    {ok, _} = application:ensure_all_started(mcl_echo),

    %% A separate consumer identity/pool, pinning the same real realm
    %% key a verifying caller would.
    {ok, ConsumerKey} = macula_node_keys:generate(
                          identity, profile(),
                          #{puzzle_difficulty =>
                                macula_node_keys:puzzle_difficulty()}),
    {ok, Consumer} = macula_client:connect(
                       [seed()],
                       #{node_identity => ConsumerKey,
                         realm_trust => #{Realm => ?REAL_REALM_KEY}}),
    ok = wait_healthy(Consumer, 200),

    Result = call_when_advertised(Consumer, Realm, ?REAL_ORG, demo_budget()),
    {ok, _Reply} = Result,

    _ = close_quietly(Consumer),
    application:stop(mcl_echo),
    application:unload(mcl_echo),

    {ok, Reply} = Result,
    ?assertEqual(<<"pong">>, mcl_om_wire:field(ping, Reply)).

%% MCL_LIVE_DEMO=1 keeps the service up and waits a LONG budget so a
%% human can run the whole flow by hand: claim (boot) -> call fails ->
%% admit+issue on the realm desk -> call succeeds. Without it the
%% budget is the ordinary 30 attempts.
demo_budget() ->
    case os:getenv("MCL_LIVE_DEMO") of
        false -> 30;
        _     -> 450
    end.

real_identity_path() ->
    case os:getenv("MCL_LIVE_IDENTITY") of
        false -> "/tmp/mcl_echo_live_realm.key";
        Path  -> Path
    end.

load_or_generate_identity(Path) ->
    case macula_node_keys:load(Path, identity, profile()) of
        {ok, Key} ->
            {ok, Key};
        {error, _} ->
            {ok, Key} = macula_node_keys:generate(
                           identity, profile(),
                           #{puzzle_difficulty =>
                                 macula_node_keys:puzzle_difficulty()}),
            ok = macula_node_keys:save(Path, Key),
            {ok, Key}
    end.

%% The advertise runs at boot, before the service's pool has its first
%% healthy link -- it fails once with {provider_authorization,
%% no_healthy_station} and the 30s republish tick retries until the DHT
%% record lands. Wait for that record (the honest "the capability is
%% genuinely advertised" signal), then call.
call_when_advertised(Consumer, Realm, Org) ->
    call_when_advertised(Consumer, Realm, Org, 30).

call_when_advertised(Consumer, Realm, Org, Budget) ->
    Key = macula_record:procedure_key(Realm, <<Org/binary, "/echo">>),
    call_once_advertised(find_advertised(Consumer, Key, Budget), Consumer,
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
    _ = close_quietly(Pool),
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
    _ = stop_quietly(App),
    _ = application:unload(App),
    ok.

%% A close/stop that never fails the test: the pool may already be
%% gone, and the OTP 29 `catch'-expression deprecation forbids the old
%% bare `catch' form under warnings_as_errors.
close_quietly(Pid) ->
    try macula_client:close(Pid) catch _:_ -> ok end.

stop_quietly(App) ->
    try application:stop(App) catch _:_ -> ok end.
