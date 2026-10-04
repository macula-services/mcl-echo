%% @doc Tests for the limits module itself (mcl-echo#11): the shipped
%% defaults, validation, and the boot path (application env). The limiter
%% and handler suites exercise how the values are used; this one pins
%% what may be configured at all.
-module(mcl_echo_limits_tests).

-include_lib("eunit/include/eunit.hrl").

defaults_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Ok) ->
        [
            fun get_falls_back_to_the_shipped_defaults/0,
            fun reset_restores_the_shipped_defaults/0,
            fun set_applies_a_validated_partial_change/0,
            fun set_refuses_an_unknown_key/0,
            fun set_refuses_a_non_positive_value/0,
            fun set_refuses_per_caller_above_global/0,
            fun validate_checks_without_applying/0
        ]
    end}.

%% The env group runs apart from the others: these tests deliberately set
%% and unset the application env, and must not leak it into a suite that
%% assumes the shipped defaults.
env_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Ok) ->
        [
            fun env_overrides_are_merged_over_the_defaults_at_boot/0,
            fun an_invalid_env_set_stops_the_boot/0
        ]
    end}.

setup() ->
    application:unset_env(mcl_echo, limits),
    {ok, _} = mcl_echo_limits:reset(),
    ok.

teardown(_Ok) ->
    application:unset_env(mcl_echo, limits),
    {ok, _} = mcl_echo_limits:reset(),
    ok.

get_falls_back_to_the_shipped_defaults() ->
    ?assertEqual(#{max_payload_external_size => 4096,
                   window_ms                 => 10000,
                   per_caller_max            => 20,
                   global_max                => 300},
                 mcl_echo_limits:get()).

env_overrides_are_merged_over_the_defaults_at_boot() ->
    ok = application:set_env(mcl_echo, limits, #{per_caller_max => 7}),
    Loaded = mcl_echo_limits:load(),
    ?assertEqual(7, maps:get(per_caller_max, Loaded)),
    ?assertEqual(4096, maps:get(max_payload_external_size, Loaded)),
    ?assertEqual(Loaded, mcl_echo_limits:get()).

an_invalid_env_set_stops_the_boot() ->
    ok = application:set_env(mcl_echo, limits, #{plop => 1}),
    ?assertError({mcl_echo_bad_limits, {unknown_key, plop}},
                 mcl_echo_limits:load()).

set_applies_a_validated_partial_change() ->
    {ok, New} = mcl_echo_limits:set(#{window_ms => 5000}),
    ?assertEqual(5000, maps:get(window_ms, New)),
    ?assertEqual(20, maps:get(per_caller_max, New)),
    ?assertEqual(New, mcl_echo_limits:get()).

set_refuses_an_unknown_key() ->
    Before = mcl_echo_limits:get(),
    ?assertEqual({error, {unknown_key, nope}},
                 mcl_echo_limits:set(#{nope => 1})),
    ?assertEqual(Before, mcl_echo_limits:get()).

set_refuses_a_non_positive_value() ->
    ?assertEqual({error, {not_a_positive_integer, per_caller_max, 0}},
                 mcl_echo_limits:set(#{per_caller_max => 0})),
    ?assertEqual({error, {not_a_positive_integer, window_ms, -1}},
                 mcl_echo_limits:set(#{window_ms => -1})).

set_refuses_per_caller_above_global() ->
    ?assertEqual({error, {per_caller_above_global, 50, 30}},
                 mcl_echo_limits:set(#{per_caller_max => 50, global_max => 30})).

validate_checks_without_applying() ->
    Before = mcl_echo_limits:get(),
    ?assertEqual(ok, mcl_echo_limits:validate(#{window_ms => 1000})),
    ?assertEqual({error, {unknown_key, bogus}},
                 mcl_echo_limits:validate(#{bogus => 1})),
    ?assertEqual(Before, mcl_echo_limits:get()).

reset_restores_the_shipped_defaults() ->
    {ok, _} = mcl_echo_limits:set(#{per_caller_max => 2}),
    {ok, Defaults} = mcl_echo_limits:reset(),
    ?assertEqual(mcl_echo_limits:defaults(), Defaults),
    ?assertEqual(Defaults, mcl_echo_limits:get()).
