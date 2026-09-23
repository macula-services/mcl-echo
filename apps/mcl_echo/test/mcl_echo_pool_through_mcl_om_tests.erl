%% @doc The connection pool starts, through mcl_om, with the macula this
%% service resolves.
%%
%% THE REST OF THIS SUITE NEVER STARTS A POOL, and that let it pass 24/24
%% against hex mcl_om 0.4.0 on macula 12: a combination that cannot start one,
%% because 0.4.0 composes a `verify' option macula 12 refuses in any value
%% (`{refused, {verify, one_verification_mode}}'). Deployed, that service is
%% dead on arrival and its suite is green. This test boots mcl_om the way the
%% service does, against the mcl_om and macula this repository actually
%% resolves, so a pairing that cannot connect fails here and not on a box.
%%
%% The seed is unreachable on purpose (`127.0.0.1:1'). The pool is a supervised
%% process that dials in the background, so its existence proves macula
%% accepted every option mcl_om composed; reaching a station is the live
%% suite's job.
-module(mcl_echo_pool_through_mcl_om_tests).

-include_lib("eunit/include/eunit.hrl").

-define(UNREACHABLE_SEED, #{host => <<"127.0.0.1">>, port => 1,
                            expected_node_id => <<0:256>>}).
-define(REALM, <<16#EC:256>>).

pool_starts_through_mcl_om_test_() ->
    {setup, fun boot_mcl_om/0, fun stop_mcl_om/1,
     fun(Started) ->
        [?_assertMatch({ok, _}, Started),
         ?_assertMatch({ok, Pid} when is_pid(Pid), mcl_om:macula_client())]
     end}.

boot_mcl_om() ->
    application:load(mcl_om),
    application:set_env(mcl_om, health_port, 0),
    application:set_env(mcl_om, station_seeds, [?UNREACHABLE_SEED]),
    application:set_env(mcl_om, realm, ?REALM),
    application:set_env(mcl_om, realm_key, realm_key_hex()),
    application:ensure_all_started(mcl_om).

stop_mcl_om(_Started) ->
    application:stop(mcl_om),
    [application:unset_env(mcl_om, K) || K <- [health_port, station_seeds, realm, realm_key]],
    ok.

%% A real realm public key in the configured profile, hex as the deploy env
%% carries it: macula refuses a pinned key that is not well formed for the
%% profile, which would fail this test for a reason it is not about.
realm_key_hex() ->
    application:load(macula),
    {ok, Profile} = macula_crypto_profile:configured(),
    {ok, Key} = macula_node_keys:generate(realm, Profile),
    binary:encode_hex(macula_node_keys:public_key(Key), lowercase).
