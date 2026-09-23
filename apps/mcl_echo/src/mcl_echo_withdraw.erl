%%%-------------------------------------------------------------------
%%% @doc The terminal withdraw: bury the stale D25 chain in the DHT
%%% after a realm ledger reset.
%%%
%%% The reset wipes the realm's ledger, but the published delegation
%%% lives 6h on the wire and the org key survives on the realm's
%%% identity volume — so the service would still advertise and answer
%%% unless the grant is tombstoned. This calls the realm's own admin
%%% withdraw RPC over the mesh, exactly once.
%%%
%%%   MACULA_ADMIN_TOKEN=<secret> ./scripts/mcl_echo_withdraw [node_hex] [org]
%%%
%%% The realm key below is the io.macula realm's PUBLIC half (the
%%% realm_trust pin), not secret.
%%%-------------------------------------------------------------------
-module(mcl_echo_withdraw).
-include("mcl_echo_io_macula.hrl").

-export([main/0]).

-define(WITHDRAW_PROCEDURE,
        <<"io.macula/_realm/_realm/admin/withdraw_provider_authorization_v1">>).
-define(CALL_TIMEOUT_MS, 20_000).

main() ->
    {NodeHex, Org} = args(),
    Token = token(),
    {ok, _} = application:ensure_all_started(macula),
    {ok, Profile} = macula_crypto_profile:configured(),
    {ok, Key} = macula_node_keys:generate(
                  identity, Profile,
                  #{puzzle_difficulty => macula_node_keys:puzzle_difficulty()}),
    Realm = macula_realm:id(?MCL_ECHO_REALM_NAME),
    {ok, Seed} = mcl_echo_stations:pin(mcl_echo_stations:default()),
    {ok, Pool} = macula_client:connect(
                   [Seed],
                   #{node_identity => Key,
                     %% No `verify': macula 12 refuses it in any value
                     %% (`{refused, {verify, one_verification_mode}}').
                     %% The D16 `expected_node_id' pin in the seed is
                     %% what binds this dial. Matches `mcl_echo_call'
                     %% and mcl_om's own pool opts.
                     realm_trust => #{Realm => ?MCL_ECHO_REAL_REALM_KEY}}),
    ok = wait_healthy(Pool, 60),
    Payload = #{<<"admin_token">> => Token,
                <<"org">> => Org,
                <<"provider_node_id">> => NodeHex},
    Reply = macula:call(Pool, Realm, ?WITHDRAW_PROCEDURE, Payload, ?CALL_TIMEOUT_MS),
    io:format("withdraw: ~p~n", [Reply]),
    _ = close_quietly(Pool),
    case Reply of
        {ok, _}          -> halt(0);
        {error, _Reason} -> halt(1)
    end.

args() ->
    [NodeHex | Rest] =
        case init:get_plain_arguments() of
            [_ | _] = All -> All;
            [] -> erlang:error("usage: mcl_echo_withdraw <node_id_hex> [org]")
        end,
    Org = case Rest of
              [O | _] -> unicode:characters_to_binary(O);
              []      -> ?MCL_ECHO_DEFAULT_ORG
          end,
    {unicode:characters_to_binary(NodeHex), Org}.

token() ->
    case os:getenv("MACULA_ADMIN_TOKEN") of
        false -> erlang:error("MACULA_ADMIN_TOKEN missing");
        T     -> unicode:characters_to_binary(T)
    end.

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).

close_quietly(Pool) ->
    try macula_client:close(Pool) catch _:_ -> ok end.
