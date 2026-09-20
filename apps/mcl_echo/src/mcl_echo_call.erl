%%%-------------------------------------------------------------------
%%% @doc The terminal caller: call mcl-echo/echo in the io.macula realm.
%%%
%%% A plain CLI script (`rebar3 escriptize'), NOT a test: before the
%%% realm's desk admits the node the call resolves no provider; after
%%% Admit + issue it answers pong.
%%%
%%%   ./scripts/mcl_echo_call [station]
%%%
%%% THE STATION IS AN ARGUMENT because several callers at once are the
%%% interesting case. Pinned to one station, six sessions all enter the
%%% mesh through the same box and a fan-out test measures one route six
%%% times. Name the station and each caller takes its own way in.
%%% `mcl_echo_stations:names/0' lists them; the default is helsinki.
%%%
%%% EVERYTHING A SESSION REPORTS IS PRINTED, not assumed. A fan-out is
%%% read back from six terminals, and a session that reports the route
%%% it MEANT to take rather than the one it took makes the whole run
%%% unreadable. So the banner carries the station and its host, the
%%% station node id this dial is pinned to, the procedure, the realm in
%%% both its name and tag form, this caller's own node id, and the
%%% payload term itself. The payload is printed from ?PAYLOAD, the same
%%% macro the call sends, so the printed line is evidence rather than a
%%% second claim that could drift from the first.
%%%
%%% THE CALLER NODE ID IS THE RATE-LIMIT KEY and that is why it is
%%% printed. `macula_station_link:with_caller/2' merges the wire-
%%% authenticated caller into the payload ONLY when the payload is a
%%% map, so ?PAYLOAD is a map deliberately: a bare-text payload reaches
%%% `mcl_echo_mesh_rpc:limiter_key/1' with no attribution and falls back
%%% to one shared 300-per-10s global counter, where six concurrent
%%% sessions contend with each other and with every other caller on the
%%% mesh. As a map each session gets its own 20-per-10s bucket, keyed by
%%% the identity generated below -- fresh every run, so the six buckets
%%% are genuinely six.
%%%
%%% THE UNVERIFIED-DIAL WARNING IS EXPECTED and is not this harness
%%% misconfiguring itself. `verify => webpki' is passed to connect
%%% below, but `macula_peering_conn:start_dial/1' in macula 11.4.0
%%% reads only `alpn' and `timeout_ms' off the dial target and
%%% hardcodes `{verify, none}' into the QUIC dial, so the option
%%% cannot take effect on this path whatever a caller sets or wherever
%%% they put it. What names the station here is the D16 handshake pin:
%%% `expected_node_id' is required, and the station's challenge must
%%% derive to the node id dialled. The option stays so the intent is on
%%% the record and a later fix makes it live. Reported for routing, not
%%% repaired here: macula is not this repo.
%%%
%%% The realm key below is the io.macula realm's PUBLIC half (the
%%% realm_trust pin), not secret.
%%%-------------------------------------------------------------------
-module(mcl_echo_call).
-include("mcl_echo_io_macula.hrl").

-export([main/0]).

-define(DEFAULT_PROCEDURE, <<"mcl-echo/echo">>).

%% A MAP, not bare text -- see the caller-node-id note above. Held in one
%% macro so the banner prints the term that is actually sent.
-define(PAYLOAD, #{<<"ping">> => <<"pong">>}).

main() ->
    run(station_arg(init:get_plain_arguments()), ?DEFAULT_PROCEDURE).

station_arg([])           -> mcl_echo_stations:default();
station_arg([Name | _])   -> Name.

run(Station, Procedure) ->
    dial(mcl_echo_stations:pin(Station), Station, Procedure).

%% An unknown name is a typo at a terminal, not a mesh failure: say so and
%% list the real ones rather than dialling something arbitrary.
dial({error, {unknown_station, Name}}, _Station, _Procedure) ->
    io:format("unknown station ~ts~nknown stations: ~p~n",
              [Name, mcl_echo_stations:names()]),
    halt(2);
dial({ok, #{host := Host, expected_node_id := Pin} = Seed}, Station, Procedure) ->
    io:format("station        ~ts (~ts)~n", [station_label(Station), Host]),
    io:format("station nodeid ~ts~n", [hex(Pin)]),
    io:format("procedure      ~ts~n", [Procedure]),
    {ok, _} = application:ensure_all_started(macula),
    {ok, Profile} = macula_crypto_profile:configured(),
    {ok, Key} = macula_node_keys:generate(
                  identity, Profile,
                  #{puzzle_difficulty => macula_node_keys:puzzle_difficulty()}),
    Realm = macula_realm:id(?MCL_ECHO_REALM_NAME),
    io:format("realm          ~ts (~ts)~n", [?MCL_ECHO_REALM_NAME, hex(Realm)]),
    io:format("caller nodeid  ~ts~n", [hex(macula_node_keys:key_id(Key))]),
    io:format("payload        ~p (~p bytes local external_size, cap 4096)~n",
              [?PAYLOAD, erlang:external_size(?PAYLOAD)]),
    io:format("tls            an UNVERIFIED dial warning follows: expected, the "
              "station is pinned by node id at the handshake (module doc)~n", []),
    {ok, Pool} = macula_client:connect(
                   [Seed],
                   #{node_identity => Key,
                     verify => webpki,
                     %% BOTH STATED, NEITHER DEFAULTED. One seed and
                     %% discovery off means the pool holds exactly one
                     %% entry link, the station named on the command
                     %% line, so `first_success' has nothing to choose
                     %% between and the six callers differ in the
                     %% station and in nothing else. Left to the
                     %% default these are mode-dependent:
                     %% `macula_client:default_link_selection/1' gives
                     %% `first_success' with no discovery and `random',
                     %% reshuffled per call, with it, and
                     %% `station_discovery' defaults to `#{}' whose
                     %% meaning is a default in its own right. Six
                     %% sessions that drift between those are running
                     %% six experiments, not one.
                     station_discovery => #{enabled => false},
                     link_selection => first_success,
                     realm_trust => #{Realm => ?MCL_ECHO_REAL_REALM_KEY}}),
    ok = wait_healthy(Pool, 60),
    print_links("links before", Pool, Pin),
    Reply = call_with_transient_retry(Pool, Realm, Procedure, 5),
    io:format("result         ~p~n", [Reply]),
    print_links("links after", Pool, Pin),
    _ = close_quietly(Pool),
    case Reply of
        {ok, _}          -> halt(0);
        {error, _Reason} -> halt(1)
    end.

%% WHICH STATION ANSWERED, read off the pool rather than taken from the
%% argument a second time. `macula_client:links/1' reports each link's
%% dial host and the peer node id the CONNECT/HELLO handshake actually
%% produced, so the verdict below compares the station on the wire
%% against the id this dial was pinned to -- evidence from the
%% handshake, not our own table agreeing with itself.
%%
%% PRINTED TWICE, before and after, because a call is two hops. The
%% first is the entry station this session picked. The second is
%% whatever serving station the resolved advertisement names, which the
%% SDK reaches with a direct dial of its own; those links land in the
%% same pool (`macula_client:direct_dial/4' marks them and
%% `handle_call(links, ...)' returns every link), so a second row in the
%% AFTER list is that second hop, named. The BEFORE list is the load
%% bearing one: one seed with discovery off means exactly one link, so
%% no other station could have carried the call.
%%
%% The SDK attributes no reply to a link, so this is where the evidence
%% stops: the link set the pool held, with peer identities from the
%% handshake. It does not prove which link carried one particular frame,
%% and with more than one link in the BEFORE list it would not be
%% enough.
print_links(Label, Pool, Pin) ->
    {ok, Links} = macula_client:links(Pool),
    io:format("~-14s ~p link(s)~n", [Label, length(Links)]),
    lists:foreach(fun(L) -> print_link(L, Pin) end, Links).

print_link(#{host := Host, connected := Connected, node_id := NodeId}, Pin) ->
    io:format("               ~ts connected=~p peer=~ts ~s~n",
              [host_label(Host), Connected, peer_label(NodeId),
               pin_verdict(NodeId, Pin)]).

host_label(undefined) -> <<"(host unknown)">>;
host_label(Host)      -> Host.

peer_label(undefined) -> <<"(pre-handshake)">>;
peer_label(NodeId)    -> hex(NodeId).

pin_verdict(Pin, Pin)        -> "= pinned entry station";
pin_verdict(undefined, _Pin) -> "= no peer id yet";
pin_verdict(_Other, _Pin)    -> "= another station".

%% The default arrives as an atom and a command line argument as a
%% string; both print as the same plain name so six reports line up.
station_label(Name) when is_atom(Name)   -> atom_to_binary(Name, utf8);
station_label(Name) when is_binary(Name) -> Name;
station_label(Name) when is_list(Name)   -> unicode:characters_to_binary(Name).

hex(Bin) -> binary:encode_hex(Bin, lowercase).

%% Right after admission the first live call can hit a transient
%% (timeout on a fresh route, temporary_relay_failure) while the
%% advertise path warms up -- retry THOSE, not resolution errors: a
%% not-admitted procedure must keep failing fast and visibly.
call_with_transient_retry(_Pool, _Realm, _Procedure, 0) ->
    erlang:error(call_never_succeeded);
call_with_transient_retry(Pool, Realm, Procedure, Attempts) ->
    case macula:call(Pool, Realm, Procedure, ?PAYLOAD, 15_000) of
        {ok, _} = Success ->
            Success;
        {error, timeout} ->
            retry_transient(Pool, Realm, Procedure, Attempts, timeout);
        {error, {call_error, <<"temporary_relay_failure">>, _}} ->
            retry_transient(Pool, Realm, Procedure, Attempts, temporary_relay_failure);
        {error, _Reason} = Failure ->
            Failure
    end.

retry_transient(Pool, Realm, Procedure, Attempts, Reason) ->
    io:format("transient ~p, retrying...~n", [Reason]),
    timer:sleep(2_000),
    call_with_transient_retry(Pool, Realm, Procedure, Attempts - 1).

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
