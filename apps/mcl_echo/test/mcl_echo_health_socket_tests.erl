%% @doc /health is a Unix socket inside the container, not a port (mcl_om 0.39,
%% #17): no service listens on a port just to be health-checked. The release
%% config sets it, the image checks it over the socket, and nothing configures,
%% exposes or passes a health port.
-module(mcl_echo_health_socket_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SOCKET, "/run/mcl/health.sock").

the_release_config_sets_the_health_socket_test() ->
    Text = read("config/sys.config.src"),
    ?assertMatch({match, _}, re:run(Text, <<"\\{health_socket, +\"/run/mcl/health\\.sock\"\\}">>)).

the_image_checks_health_over_the_socket_test() ->
    ?assertNotEqual(nomatch, binary:match(read("Containerfile"), <<"--unix-socket ", ?SOCKET>>)).

nothing_configures_exposes_or_passes_a_health_port_test() ->
    ?assertEqual([], [F || F <- ["config/sys.config.src", "Containerfile", "deploy/docker-compose.yml",
                                 "scripts/health.sh"],
                           binary:match(read(F), [<<"health_port">>, <<"MCL_HEALTH_PORT">>, <<"EXPOSE">>]) =/= nomatch]).

read(File) ->
    {ok, Bin} = file:read_file(File),
    Bin.
