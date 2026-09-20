%%%-------------------------------------------------------------------
%%% @doc The terminal caller: call mcl-echo/echo in the io.macula realm.
%%%
%%% A plain CLI script (`rebar3 escriptize`), NOT a test: before the
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
%%% The station dialled is printed before the call, so a session can
%%% report which way in it actually took rather than which it intended.
%%%
%%% The realm key below is the io.macula realm's PUBLIC half (the
%%% realm_trust pin), not secret.
%%%-------------------------------------------------------------------
-module(mcl_echo_call).
-include("mcl_echo_io_macula.hrl").

-export([main/0]).

-define(DEFAULT_PROCEDURE, <<"mcl-echo/echo">>).



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
dial({ok, #{host := Host} = Seed}, Station, Procedure) ->
    io:format("station ~p (~ts), procedure ~ts~n", [Station, Host, Procedure]),
    {ok, _} = application:ensure_all_started(macula),
    {ok, Profile} = macula_crypto_profile:configured(),
    {ok, Key} = macula_node_keys:generate(
                  identity, Profile,
                  #{puzzle_difficulty => macula_node_keys:puzzle_difficulty()}),
    Realm = macula_realm:id(?MCL_ECHO_REALM_NAME),
    {ok, Pool} = macula_client:connect(
                   [Seed],
                   #{node_identity => Key,
                     verify => webpki,
                     realm_trust => #{Realm => ?MCL_ECHO_REAL_REALM_KEY}}),
    ok = wait_healthy(Pool, 60),
    Reply = call_with_transient_retry(Pool, Realm, Procedure, 5),
    io:format("~p~n", [Reply]),
    _ = close_quietly(Pool),
    case Reply of
        {ok, _}          -> halt(0);
        {error, _Reason} -> halt(1)
    end.

%% Right after admission the first live call can hit a transient
%% (timeout on a fresh route, temporary_relay_failure) while the
%% advertise path warms up — retry THOSE, not resolution errors: a
%% not-admitted procedure must keep failing fast and visibly.
call_with_transient_retry(_Pool, _Realm, _Procedure, 0) ->
    erlang:error(call_never_succeeded);
call_with_transient_retry(Pool, Realm, Procedure, Attempts) ->
    case macula:call(Pool, Realm, Procedure,
                     #{<<"ping">> => <<"pong">>}, 15_000) of
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
