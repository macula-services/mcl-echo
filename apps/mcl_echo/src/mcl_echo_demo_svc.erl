%%%-------------------------------------------------------------------
%%% @doc The demo service runner: boot mcl-echo under the REAL
%%% io.macula realm and stay up until killed.
%%%
%%% A plain long-running process — NOT a test. No window, no budget,
%%% no timeout: the service claims at boot (mcl_om's claim worker
%%% retries until the realm records it), then serves until the
%%% operator stops it. The realm's desk admits + issues whenever it
%%% wants; this process never leaves on its own.
%%%
%%%   ./scripts/mcl_echo_demo start   # (stop/status/restart/reset)
%%%
%%% MCL_BOX overrides the desk's Node label; MCL_LIVE_IDENTITY
%%% (default /tmp/mcl_echo_live_realm.key) is the service's persistent
%%% PQ identity. The realm key below is the io.macula realm's PUBLIC
%%% half (the realm_trust pin), not secret.
%%%-------------------------------------------------------------------
-module(mcl_echo_demo_svc).
-include("mcl_echo_io_macula.hrl").

-export([main/0]).

main() ->
    {ok, _} = application:ensure_all_started(macula),

    KeyPath = identity_path(),
    {ok, ServiceKey} = load_or_generate_identity(KeyPath),
    {ok, ServiceNodeId} = macula_node_keys:node_id(ServiceKey),
    io:format("mcl_echo_demo: REAL realm ~s, org ~s, node id ~s~n",
              [?MCL_ECHO_REALM_NAME, ?MCL_ECHO_DEFAULT_ORG,
               binary:encode_hex(ServiceNodeId, lowercase)]),

    Realm = macula_realm:id(?MCL_ECHO_REALM_NAME),
    application:load(mcl_om),
    application:set_env(mcl_om, health_port, 0),
    application:set_env(mcl_om, identity_key_path, KeyPath),
    application:set_env(mcl_om, station_seeds, [seed()]),
    application:set_env(mcl_om, realm, Realm),
    application:set_env(mcl_om, org, ?MCL_ECHO_DEFAULT_ORG),
    application:set_env(mcl_om, service_name, <<"mcl-echo">>),
    application:set_env(mcl_om, box, box_label()),
    application:set_env(mcl_om, realm_trust, #{Realm => ?MCL_ECHO_REAL_REALM_KEY}),
    {ok, _} = application:ensure_all_started(mcl_echo),

    io:format("mcl_echo_demo: service up — the realm's desk decides; ", []),
    io:format("scripts/mcl_echo_call is the caller~n", []),

    %% Stay up forever — the stop script kills this process.
    receive after infinity -> ok end.

seed() ->
    #{host => ?MCL_ECHO_SEED_HOST, port => ?MCL_ECHO_SEED_PORT,
      expected_node_id => ?MCL_ECHO_SEED_NODE_ID}.

identity_path() ->
    case os:getenv("MCL_LIVE_IDENTITY") of
        false -> "/tmp/mcl_echo_live_realm.key";
        Path  -> Path
    end.

load_or_generate_identity(Path) ->
    {ok, Profile} = macula_crypto_profile:configured(),
    case macula_node_keys:load(Path, identity, Profile) of
        {ok, Key} ->
            {ok, Key};
        {error, _} ->
            {ok, Key} = macula_node_keys:generate(
                          identity, Profile,
                          #{puzzle_difficulty =>
                                macula_node_keys:puzzle_difficulty()}),
            ok = macula_node_keys:save(Path, Key),
            {ok, Key}
    end.

%% os:getenv returns a LIST, never a binary — convert, or the desk's
%% Node column comes back empty (measured live).
box_label() ->
    case os:getenv("MCL_BOX") of
        false -> <<"beam02.lab">>;
        Value -> unicode:characters_to_binary(Value)
    end.
