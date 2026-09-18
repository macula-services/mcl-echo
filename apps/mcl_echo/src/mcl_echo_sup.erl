%% @doc Supervises this service's own processes.
%%
%% One child: the rate-limiter table owner, which must be up before any
%% call can be answered. `io.macula.echo' itself is advertised by
%% `mcl_om_capabilities' (see `mcl_echo_service:capabilities/0'),
%% which supervises and periodically re-advertises its own handler --
%% this supervisor has nothing left to do for that.
-module(mcl_echo_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => mcl_echo_limiter,
          start => {mcl_echo_limiter, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
