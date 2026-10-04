%%% @doc Supervises this service's own processes.
%%%
%%% NO CHILDREN AS OF THE GUARD ADOPTION (mcl-om#13): the hand-rolled
%%% rate limiter is retired — the pipeline owns the counters now, and
%%% mcl_om supervises them. The echo capability itself is advertised by
%%% `mcl_om_capabilities' (see `mcl_echo_service:capabilities/0'),
%%% which supervises and periodically re-advertises its own handler —
%%% this supervisor has nothing left to do.
-module(mcl_echo_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
