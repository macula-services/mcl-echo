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
%%% they put it.
%%%
%%% MERGED, NOT RELEASED, NOT RUNNING, and the three are worth keeping
%%% apart. macula's trunk fixes it in `f3575b25', where `start_dial/1'
%%% passes `dial_opts(Target)' and that function reads the target's own
%%% `verify'. That commit is on origin/main, carries no tag, and is not
%%% an ancestor of v11.4.0, which is what hex serves and what this
%%% service runs. So the option is inert HERE until a release carries
%%% the fix, and the running artifact is what this comment describes.
%%%
%%% What names the station meanwhile is the D16 handshake pin:
%%% `expected_node_id' is required and the station's challenge must
%%% derive to the node id dialled. TLS server verification is not the
%%% control on this path; the pin is, and the option should not read as
%%% though it were. The option stays so the intent is on the record.
%%%
%%% The realm key below is the io.macula realm's PUBLIC half (the
%%% realm_trust pin), not secret.
%%%-------------------------------------------------------------------
-module(mcl_echo_call).
-include("mcl_echo_io_macula.hrl").

-export([main/0]).

%% Exported so the seam's SHAPE can be checked without spending a call on
%% the mesh. `macula_direct_dial:dial_io/2' refuses a wrong key set or a
%% wrong arity with `function_clause' raised in the caller, at call time,
%% which a clean compile does not catch: a harness that only crashes once
%% it is pointed at a live station is the failure this whole script
%% exists to avoid.
-export([recording_dial_io/0]).

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
    print_route(),
    print_links("links after", Pool, Pin),
    _ = close_quietly(Pool),
    case Reply of
        {ok, _}          -> halt(0);
        {error, _Reason} -> halt(1)
    end.

%% WHICH STATION ANSWERED, from the SDK's own seam. `macula:call/5'
%% never names the station it resolved to, so a harness that logs its own
%% argument logs nothing: it restates the request and calls it an answer.
%% `macula:call/5' is exactly `macula_direct_dial:call/5', which is
%% `call/6' with no options, and `call/6' takes a `dial_io' (see that
%% module's "Dial I/O" section). The `call_station' function in it is
%% handed the RESOLVED station and the node id pinned as
%% `expected_node_id' for that dial, so what is recorded below is a
%% pinned answer rather than a hopeful label.
%%
%% BOTH LEGS ARE RECORDED, because they can land on different boxes and
%% the failures being chased live in the first one. `find_records' is the
%% advertisement lookup (`macula_direct_dial:advertised_stations/3'),
%% `find_record' the station-endpoint lookup, and `call_station' the call
%% itself.
%%
%% TWO TRAPS, from that module's own contract. The seam is per call, not
%% per pool. And `dial_io/2' REPLACES the defaults with the given map
%% rather than merging it: it requires every key the call needs
%% (`call/6' asks for exactly `find_records', `find_record' and
%% `call_station'), and refuses any key outside `dial_io()' or at the
%% wrong arity with `function_clause' raised in the caller. So: exactly
%% those three keys, at arities 3, 3 and 8, each delegating to the
%% default it shadows.
-define(TRACE, mcl_echo_call_route).

%% THE SEAM OWNS ITS TABLE, so it cannot be built without one. Separating
%% the two cost a crash in the offline shape check: the recording funs are
%% called from inside the SDK, so a missing table surfaces as a `badarg'
%% in `ets:insert/2' several frames down in `macula_direct_dial', which is
%% a wretched thing to hand six sessions. Idempotent because a transient
%% retry builds the io again, and the steps accumulate across attempts on
%% purpose: each pass over the DHT is worth seeing.
%%
%% Public and named: the funs run in whichever process the pool drives
%% them from, not necessarily this one. Owned by the caller's process,
%% which lives for the whole run.
ensure_trace() ->
    trace_table(ets:whereis(?TRACE)).

trace_table(undefined) ->
    ?TRACE = ets:new(?TRACE, [ordered_set, public, named_table]),
    ok;
trace_table(_Tid) ->
    ok.

record_step(Event) ->
    true = ets:insert(?TRACE, {erlang:unique_integer([monotonic, positive]), Event}),
    ok.

recording_dial_io() ->
    ok = ensure_trace(),
    #{find_records =>
          fun(P, K, T) -> found_records(hex(K), macula:find_records(P, K, T)) end,
      find_record =>
          fun(P, K, T) -> found_record(hex(K), macula:find_record(P, K, T)) end,
      call_station =>
          fun(P, Station, Target, R, Proc, Pay, T, O) ->
              record_step({call_station_to, seed_label(Station), hex(Target)}),
              called(hex(Target),
                     macula:call_station(P, Station, Target, R, Proc, Pay, T, O))
          end}.

%% One clause set per leg rather than one shared summary: a call reply is
%% an arbitrary term and may well be a list, which a shared "is it a
%% list" summary would report as a record count.
found_records(Key, {ok, Recs} = Result) ->
    record_step({find_records, Key, {ok, length(Recs), records}}),
    Result;
found_records(Key, {error, Reason} = Result) ->
    record_step({find_records, Key, {error, Reason}}),
    Result.

found_record(Key, {ok, _Rec} = Result) ->
    record_step({find_record, Key, {ok, one_record}}),
    Result;
found_record(Key, {error, Reason} = Result) ->
    record_step({find_record, Key, {error, Reason}}),
    Result.

called(Target, {ok, _Reply} = Result) ->
    record_step({call_station_answered, Target, ok}),
    Result;
called(Target, {error, Reason} = Result) ->
    record_step({call_station_answered, Target, {error, Reason}}),
    Result.

seed_label(#{host := H, port := P}) ->
    iolist_to_binary(io_lib:format("~ts:~p", [H, P]));
seed_label(Seed) when is_binary(Seed) ->
    Seed;
seed_label(Seed) when is_list(Seed) ->
    unicode:characters_to_binary(Seed).

%% The route as it was walked, in order. A step that never appears is as
%% informative as one that does: no `find_record' line means resolution
%% never got as far as the station-endpoint lookup, and no
%% `call_station_to' line means it never reached a provider at all.
print_route() ->
    io:format("route          ~p step(s), in order~n", [ets:info(?TRACE, size)]),
    lists:foreach(fun({_Seq, Event}) -> io:format("               ~p~n", [Event]) end,
                  ets:tab2list(?TRACE)).

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
    case macula_direct_dial:call(Pool, Realm, Procedure, ?PAYLOAD, 15_000,
                                 #{dial_io => recording_dial_io()}) of
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
