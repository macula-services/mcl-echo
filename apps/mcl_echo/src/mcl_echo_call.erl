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
%%% THE UNVERIFIED-DIAL WARNING IS EXPECTED, and `verify => none' below
%%% is a decision rather than an oversight. What binds this dial to the
%%% station it names is the D16 handshake pin: `expected_node_id' is
%%% required and the station's challenge must derive to the node id
%%% dialled. TLS server verification is not the control on this path;
%%% the pin is. macula 11.5.0's own `macula_peering_conn:dial_opts/1'
%%% says the same -- a station's leaf is self-signed or issued by an
%%% unrelated PKI, and the signed handshake binds the connection, not
%%% the certificate chain.
%%%
%%% THIS USED TO SAY `webpki' AND THAT WAS ONLY SAFE BY ACCIDENT.
%%% macula 11.4.0's `start_dial/1' discarded the caller's value and
%%% passed a literal `{verify, none}', so the option was decorative and
%%% this harness connected regardless. 11.5.0 honours the target's
%%% value, which would have turned `webpki' into a real X.509 chain
%%% check against the built-in public roots on every station dial, and
%%% a harness that cannot connect measures nothing. Asking for `none'
%%% explicitly is what keeps the six callers able to dial at all once
%%% mcl-echo moves to 11.5.0.
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

%% Exported for the same reason: the freshness classifier decides whether a
%% call went through the tolerance window or read an ordinarily live record,
%% and that judgement should be checkable without spending a call on the mesh.
-export([endpoint_freshness/1]).

-define(DEFAULT_PROCEDURE, <<"mcl-echo/echo">>).

%% A MAP, not bare text -- see the caller-node-id note above. Held in one
%% macro so the banner prints the term that is actually sent.
-define(PAYLOAD, #{<<"ping">> => <<"pong">>}).

main() ->
    Args = init:get_plain_arguments(),
    run(station_arg(Args), calls_arg(Args), ?DEFAULT_PROCEDURE).

station_arg([])           -> mcl_echo_stations:default();
station_arg([Name | _])   -> Name.

%% `./scripts/mcl_echo_call <station> [N]'. N defaults to 1, which keeps a
%% single-call run byte-identical in shape to every earlier one.
calls_arg([_Station, N | _]) -> positive_int(N);
calls_arg(_Args)             -> 1.

positive_int(S) ->
    checked_count(catch list_to_integer(S), S).

checked_count(N, _S) when is_integer(N), N > 0 -> N;
checked_count(_NotACount, S) ->
    io:format("second argument must be a positive call count, got ~ts~n", [S]),
    halt(2).

%% The instrument line comes FIRST, before the station is even resolved, so it
%% prints on every path including an unknown-station typo. A run that cannot
%% say which artifact produced it is not worth comparing against another.
run(Station, Calls, Procedure) ->
    io:format("instrument     HEAD ~s, mcl_echo_call.beam md5 ~ts~n",
              [head_label(), beam_md5()]),
    dial(mcl_echo_stations:pin(Station), Station, Calls, Procedure).

%% An unknown name is a typo at a terminal, not a mesh failure: say so and
%% list the real ones rather than dialling something arbitrary.
dial({error, {unknown_station, Name}}, _Station, _Calls, _Procedure) ->
    io:format("unknown station ~ts~nknown stations: ~p~n",
              [Name, mcl_echo_stations:names()]),
    halt(2);
dial({ok, #{host := Host, expected_node_id := Pin} = Seed}, Station, Calls, Procedure) ->
    {VmMs, _} = erlang:statistics(wall_clock),
    T0 = mono(),
    io:format("station        ~ts (~ts)~n", [station_label(Station), Host]),
    io:format("station nodeid ~ts~n", [hex(Pin)]),
    io:format("procedure      ~ts~n", [Procedure]),
    {ok, _} = application:ensure_all_started(macula),
    TApp = mono(),
    {ok, Profile} = macula_crypto_profile:configured(),
    {ok, Key} = macula_node_keys:generate(
                  identity, Profile,
                  #{puzzle_difficulty => macula_node_keys:puzzle_difficulty()}),
    TKey = mono(),
    Realm = macula_realm:id(?MCL_ECHO_REALM_NAME),
    io:format("realm          ~ts (~ts)~n", [?MCL_ECHO_REALM_NAME, hex(Realm)]),
    io:format("caller nodeid  ~ts~n", [hex(macula_node_keys:key_id(Key))]),
    io:format("payload        ~p (~p bytes local external_size, cap 4096)~n",
              [?PAYLOAD, erlang:external_size(?PAYLOAD)]),
    io:format("tls            verify=none, asked for deliberately: an UNVERIFIED "
              "dial warning follows and the node id pin is the control~n", []),
    {ok, Pool} = macula_client:connect(
                   [Seed],
                   #{node_identity => Key,
                     %% Deliberate, not a default -- see the module doc.
                     verify => none,
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
    TConn = mono(),
    ok = wait_healthy(Pool, 60),
    TReady = mono(),
    print_prelude_timing(VmMs, T0, TApp, TKey, TConn, TReady),
    print_links("links before", Pool, Pin),
    Calls1 = [one_call(N, Pool, Realm, Procedure) || N <- lists:seq(1, Calls)],
    print_call_summary(Calls1),
    print_links("links after", Pool, Pin),
    _ = close_quietly(Pool),
    halt(exit_code(Calls1)).

%% WHICH STATION ANSWERED, from the SDK's own seam. `macula:call/5'
%% never names the station it resolved to, so a harness that logs its own
%% argument logs nothing: it restates the request and calls it an answer.
%% `macula:call/5' is exactly `macula_direct_dial:call/5', which is
%% `call/6' with no options, and `call/6' takes a `dial_io' (see that
%% module's "Dial I/O" section).
%%
%% ⚠ TWO IDENTITIES, AND THEY ARE DIFFERENT THINGS. A call dials the
%% serving STATION's endpoint and addresses the request to the PROVIDER.
%% `macula:call_station(Pool, Station, Target, Realm, Procedure, Payload,
%% TimeoutMs, Opts)': arg 2 is the dial URL, arg 3 is the Target, which
%% is the PROVIDER's node id, and the station's pin rides in `Opts' --
%% `call_station/8' does `maps:with([verify, expected_node_id,
%% pin_tls_cert], Opts)' on its next line. So all three are recorded
%% below, separately and by name, because an earlier version recorded
%% only the Target and this module's own doc called it the station. It
%% is not: `000e02b5...' is mcl-echo's provider id and names no station
%% on the fleet. Three sessions caught that independently against
%% stations.csv on the night of the six-caller run.
%%
%% `station_pin' comes from `Opts' and is the value D16 enforces at the
%% handshake, so it is the station identity, checkable against the
%% `find_record' endpoint key above it. `unpinned' there would mean a
%% dial with no pin at all, which 11.x refuses, so it should never
%% appear and is worth seeing loudly if it does.
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

%% The row carries a timestamp, the printed route TERM does not. Timings live
%% in their own block (see `print_call_timing/1'): the route terms are a
%% semantic record of what the SDK did, and folding durations into them would
%% make each one noisier to scan at the exact moment someone is looking for
%% `{ok,0,records}'. It would also change those term shapes a third time, and
%% the banner's generation-identifying property came from their having changed
%% twice -- though the instrument line now states the generation outright, so
%% that property is no longer load-bearing.
record_step(Event) ->
    true = ets:insert(?TRACE, {erlang:unique_integer([monotonic, positive]),
                               Event, mono()}),
    ok.

recording_dial_io() ->
    ok = ensure_trace(),
    #{find_records =>
          fun(P, K, T) -> found_records(hex(K), macula:find_records(P, K, T)) end,
      find_record =>
          fun(P, K, T) -> found_record(hex(K), macula:find_record(P, K, T)) end,
      call_station =>
          fun(P, Station, Target, R, Proc, Pay, T, O) ->
              record_step({call_station_to,
                           #{station_url => seed_label(Station),
                             station_pin => station_pin(O),
                             provider    => hex(Target)}}),
              called(hex(Target),
                     macula:call_station(P, Station, Target, R, Proc, Pay, T, O))
          end}.

%% The station identity, from `Opts' where it actually rides. `unpinned'
%% rather than a missing key: 11.x refuses an unpinned dial, so its
%% absence here would be a finding rather than a formatting detail.
station_pin(Opts) ->
    pin_label(maps:get(expected_node_id, Opts, undefined)).

pin_label(undefined) -> unpinned;
pin_label(NodeId)    -> hex(NodeId).

%% One clause set per leg rather than one shared summary: a call reply is
%% an arbitrary term and may well be a list, which a shared "is it a
%% list" summary would report as a record count.
found_records(Key, {ok, Recs} = Result) ->
    record_step({find_records, Key, {ok, length(Recs), records}}),
    Result;
found_records(Key, {error, Reason} = Result) ->
    record_step({find_records, Key, {error, Reason}}),
    Result.

found_record(Key, {ok, Rec} = Result) ->
    record_step({find_record, Key, endpoint_freshness(Rec)}),
    Result;
found_record(Key, {error, Reason} = Result) ->
    record_step({find_record, Key, {error, Reason}}),
    Result.

called(Provider, {ok, _Reply} = Result) ->
    record_step({call_station_answered, #{provider => Provider}, ok}),
    Result;
called(Provider, {error, Reason} = Result) ->
    record_step({call_station_answered, #{provider => Provider}, {error, Reason}}),
    Result.

%% WAS THE RECORD ORDINARILY LIVE, OR SERVED THROUGH THE TOLERANCE WINDOW?
%% `macula_record:clock/2' refuses a record only at
%% `expires_at + ?CLOCK_TOLERANCE_MS', five minutes, so a record can be PAST
%% ITS OWN EXPIRY and still be served. A caller cannot tell the two apart from
%% `{ok, _}' alone, and that is exactly the distinction the station
%% serving-window fix is about: six green calls do not show the fix was
%% exercised if every one of them read an ordinarily live record.
%%
%% The record is already in hand here, so the route block can classify itself
%% and no timing or box-side read is needed afterwards. Same time base as
%% `clock/2': `erlang:system_time(millisecond)'.
endpoint_freshness(#{expires_at := Expires}) ->
    freshness(Expires - erlang:system_time(millisecond));
endpoint_freshness(_NoExpiresAt) ->
    {ok, one_record, no_expires_at}.

%% The tolerance is `macula_record:?CLOCK_TOLERANCE_MS', 5 minutes. Past THAT,
%% `clock/2' refuses the record, so a caller should never see one -- and if it
%% does, calling it `in_tolerance_window' would be a false label on an anomaly
%% (clock skew between caller and station, or a tolerance that is not what this
%% comment says). Named separately so it reads as the finding it would be.
-define(TOLERANCE_MS, 5 * 60 * 1000).

freshness(MarginMs) when MarginMs >= 0 ->
    {ok, one_record, live, {ttl_left_s, MarginMs div 1000}};
freshness(MarginMs) when MarginMs > -?TOLERANCE_MS ->
    {ok, one_record, in_tolerance_window, {past_expiry_s, (-MarginMs) div 1000}};
freshness(MarginMs) ->
    {ok, one_record, past_tolerance_should_not_be_served,
     {past_expiry_s, (-MarginMs) div 1000}}.

%% The instrument that is actually running. `code:which/1' names the file the
%% VM loaded, so this is the artifact rather than a guess at it; anything other
%% than a path (`preloaded', `cover_compiled') is reported as such rather than
%% silently omitted.
head_label() ->
    head_or_unknown(os:getenv("MCL_ECHO_HEAD")).

head_or_unknown(false) -> "unknown (not run via scripts/mcl_echo_call)";
head_or_unknown(Head)  -> Head.

beam_md5() ->
    md5_of(code:which(?MODULE)).

md5_of(Path) when is_list(Path) ->
    md5_of_file(file:read_file(Path));
md5_of(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

md5_of_file({ok, Bin})    -> binary:encode_hex(crypto:hash(md5, Bin), lowercase);
md5_of_file({error, Why}) -> iolist_to_binary(io_lib:format("unreadable (~p)", [Why])).

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
%% ONE CALL, TIMED AND TRACED ON ITS OWN. The trace is cleared first so each
%% call's route block is that call's, not a running total: whether
%% `find_records' and `find_record' appear on calls 2..N is the question this
%% exists to answer, and it cannot be read off an accumulating list.
%%
%% Steps DO accumulate across a transient retry within one call, on purpose --
%% each pass over the DHT is worth seeing.
one_call(N, Pool, Realm, Procedure) ->
    reset_trace(),
    T0 = mono(),
    Reply = call_with_transient_retry(Pool, Realm, Procedure, 5),
    Elapsed = mono() - T0,
    io:format("~ncall ~p         ~p ms~n", [N, Elapsed]),
    io:format("  result       ~p~n", [Reply]),
    print_route(),
    print_call_timing(T0),
    {N, Elapsed, Reply}.

reset_trace() ->
    ok = ensure_trace(),
    true = ets:delete_all_objects(?TRACE),
    ok.

%% ⛔ CALL 1 IS NEVER AVERAGED INTO THE REST. It pays resolution, and a dial if
%% the route is new; calls 2..N may pay neither. A mean over all N hides exactly
%% the thing being measured, and a single mean latency for an echo is the shape
%% of number that gets quoted later without its spread.
%%
%% ⚠ AND WHAT THIS DOES NOT SHOW: N calls from one caller to one provider over
%% one entry station is ONE route and one pair of endpoints. It is not a fleet
%% latency figure and must not be reported as one.
print_call_summary(Calls) when length(Calls) < 2 ->
    ok;
print_call_summary([{1, First, _} | Rest] = Calls) ->
    Warm = [Ms || {_N, Ms, _R} <- Rest],
    io:format("~nsummary        call 1 and the rest, deliberately NOT averaged together~n"),
    io:format("               call 1       ~6w ms   pays resolution, and a dial if the route is new~n",
              [First]),
    io:format("               call 2       ~6w ms~n", [hd(Warm)]),
    io:format("               calls 2..~p   min ~w / median ~w / max ~w ms   (n=~p)~n",
              [length(Calls), lists:min(Warm), median(Warm), lists:max(Warm), length(Warm)]),
    io:format("               one route, one pair of endpoints: NOT a fleet figure~n"),
    ok.

%% Upper of the two middles on an even count. Stated rather than left for
%% someone to discover it disagrees with their own arithmetic.
median(L) ->
    Sorted = lists:sort(L),
    lists:nth((length(Sorted) div 2) + 1, Sorted).

%% Any failed call fails the run, so a partial failure across N cannot exit 0.
exit_code(Calls) ->
    failed_to_code(lists:any(fun({_N, _Ms, {error, _}}) -> true;
                                (_Ok) -> false
                             end, Calls)).

failed_to_code(true)  -> 1;
failed_to_code(false) -> 0.

mono() -> erlang:monotonic_time(millisecond).

print_route() ->
    io:format("  route        ~p step(s), in order~n", [ets:info(?TRACE, size)]),
    lists:foreach(fun({_Seq, Event, _T}) -> io:format("               ~p~n", [Event]) end,
                  ets:tab2list(?TRACE)).

%% Durations, in their own block, one line per step plus what the step was.
%% `since_call_start_ms' is cumulative and `step_ms' is the gap from the
%% previous step, because a single cumulative column hides which step was slow
%% and a single gap column hides where in the call it happened.
print_call_timing(CallStart) ->
    io:format("  timing       step_ms / since_call_start_ms~n"),
    lists:foldl(fun(Row, Prev) -> print_timing_row(Row, Prev, CallStart) end,
                CallStart, ets:tab2list(?TRACE)),
    ok.

print_timing_row({_Seq, Event, T}, Prev, CallStart) ->
    io:format("               ~6w / ~6w  ~s~n",
              [T - Prev, T - CallStart, step_name(Event)]),
    T.

%% The step's own label, not its payload: the payload is already in the route
%% block above and repeating it here would double the width for nothing.
step_name(Event) when is_tuple(Event) -> atom_to_list(element(1, Event));
step_name(Event)                      -> io_lib:format("~p", [Event]).

%% WHAT THE PRELUDE IS, and why it is broken out rather than folded into call 1.
%% None of it is per-call work: it happens once, before any call, and on a
%% long-lived client it would never be paid again. Folding it into call 1 would
%% make the first call look expensive for reasons that have nothing to do with
%% calling.
%%
%% `vm_to_first_line' is from `erlang:statistics(wall_clock)', so it covers VM
%% boot and code loading -- everything before this module's first line, which
%% cannot be measured from inside it any other way.
print_prelude_timing(VmMs, T0, TApp, TKey, TConn, TReady) ->
    io:format("prelude        ms, one-off, NOT per call~n"),
    lists:foreach(fun({Label, Ms}) -> io:format("               ~6w  ~s~n", [Ms, Label]) end,
                  [{"vm boot + code load (to this module's first line)", VmMs},
                   {"application:ensure_all_started(macula)", TApp - T0},
                   {"identity key generation (puzzle)", TKey - TApp},
                   {"macula_client:connect", TConn - TKey},
                   {"wait for a healthy link (handshake)", TReady - TConn},
                   {"TOTAL prelude after this module started", TReady - T0}]).

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
