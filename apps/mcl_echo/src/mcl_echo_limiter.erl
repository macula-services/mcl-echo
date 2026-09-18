%% @doc A fixed-window request-rate limiter for the echo procedure.
%%
%% `io.macula.echo' is deliberately public and unauthenticated -- that is
%% the whole point of a hello-world target -- so it gets nothing for free
%% from the platform: `macula_station_link''s own dispatch code carries no
%% rate limiting or backpressure at any layer (traced directly, not
%% assumed). "Let it crash" is not a defense against a caller that keeps
%% calling.
%%
%% Keyed by caller NodeId when the platform actually hands one to a
%% handler, which it only does when the payload is a map (see
%% `mcl_echo_mesh_rpc' for why most real traffic here is NOT a map, and
%% therefore falls back to `?GLOBAL_KEY').
%%
%% Fixed-window, not sliding or token-bucket: `Window = Now div WindowMs'
%% makes a new window a NEW ets key, so `ets:update_counter/4' with a
%% default tuple is the entire atomic increment-and-check -- no
%% lookup-then-insert race under concurrent bursts, which matters here
%% specifically because `macula_response' spawns one fresh, independent
%% process per inbound call, so a burst from one caller runs genuinely
%% concurrently, not serialized through any single gen_server.
-module(mcl_echo_limiter).

-behaviour(gen_server).

-export([start_link/0, allow/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, mcl_echo_limiter_table).
-define(WINDOW_MS, 10000).
-define(PER_CALLER_MAX, 20).
-define(GLOBAL_MAX, 300).
-define(GLOBAL_KEY, '$global').
-define(CLEANUP_INTERVAL_MS, 60000).
-define(RETAIN_WINDOWS, 3).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc `Key' is a caller NodeId (binary, the wire-authenticated public
%% key) when the platform provided one, or the atom `'$global'' for a
%% call the platform gave no attribution for. Every un-attributable call
%% shares one counter, deliberately -- it is the only defense available
%% for that traffic, not a per-caller one wearing a global disguise.
-spec allow(binary() | '$global') -> allow | deny.
allow(Key) ->
    Window = current_window(),
    Max = max_for(Key),
    Count = ets:update_counter(?TABLE, {Key, Window}, {2, 1}, {{Key, Window}, 0}),
    verdict(Count, Max).

current_window() ->
    erlang:monotonic_time(millisecond) div ?WINDOW_MS.

verdict(Count, Max) when Count =< Max -> allow;
verdict(_Count, _Max) -> deny.

max_for(?GLOBAL_KEY) -> ?GLOBAL_MAX;
max_for(_CallerNodeId) -> ?PER_CALLER_MAX.

init([]) ->
    ?TABLE = ets:new(?TABLE, [set, public, named_table, {write_concurrency, true}]),
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), sweep),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    sweep_old_windows(),
    erlang:send_after(?CLEANUP_INTERVAL_MS, self(), sweep),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% Drops windows old enough that nothing still-live could be reading
%% them, so the table stays bounded by (distinct callers seen recently)
%% rather than growing forever.
sweep_old_windows() ->
    Cutoff = current_window() - ?RETAIN_WINDOWS,
    MatchSpec = [{{{'_', '$1'}, '_'}, [{'<', '$1', Cutoff}], [true]}],
    ets:select_delete(?TABLE, MatchSpec).
