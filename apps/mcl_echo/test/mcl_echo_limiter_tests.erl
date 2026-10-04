%% @doc Real (not mocked) tests against the limiter's own ETS table:
%% boots the actual gen_server, calls the actual `allow/1', and asserts
%% on genuine atomic-counter behavior rather than a model of it.
-module(mcl_echo_limiter_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    %% The limits are process-external (persistent_term) now (mcl-echo#11),
    %% so every suite starts from the shipped defaults.
    {ok, _} = mcl_echo_limits:reset(),
    {ok, Pid} = mcl_echo_limiter:start_link(),
    Pid.

%% Synchronous: the next test FILE's own setup/0 re-registers this same
%% local name and re-creates the same named ETS table, which must not
%% race an async exit signal still in flight from this one.
teardown(Pid) ->
    Ref = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _Reason} -> ok end,
    {ok, _} = mcl_echo_limits:reset().

limiter_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Pid) ->
        [
            fun per_caller_allows_up_to_its_own_max/0,
            fun per_caller_denies_once_over_its_own_max/0,
            fun distinct_callers_have_independent_counters/0,
            fun the_global_key_has_its_own_higher_max/0,
            fun exceeding_the_global_max_denies_further_unattributed_calls/0,
            fun stats_show_the_window_and_who_is_over_limit/0,
            fun a_runtime_limit_change_takes_effect/0,
            fun changing_the_window_length_clears_the_counters/0,
            fun a_bad_runtime_change_is_refused_and_changes_nothing/0
        ]
    end}.

per_caller_allows_up_to_its_own_max() ->
    Caller = unique_caller(),
    Results = [mcl_echo_limiter:allow(Caller) || _ <- lists:seq(1, 20)],
    ?assertEqual(lists:duplicate(20, allow), Results).

per_caller_denies_once_over_its_own_max() ->
    Caller = unique_caller(),
    [mcl_echo_limiter:allow(Caller) || _ <- lists:seq(1, 20)],
    ?assertEqual(deny, mcl_echo_limiter:allow(Caller)),
    ?assertEqual(deny, mcl_echo_limiter:allow(Caller)).

distinct_callers_have_independent_counters() ->
    CallerA = unique_caller(),
    CallerB = unique_caller(),
    [mcl_echo_limiter:allow(CallerA) || _ <- lists:seq(1, 20)],
    ?assertEqual(deny, mcl_echo_limiter:allow(CallerA)),
    %% CallerB's own budget is untouched by CallerA's burst.
    ?assertEqual(allow, mcl_echo_limiter:allow(CallerB)).

the_global_key_has_its_own_higher_max() ->
    %% Exhaust one caller's (lower) per-caller budget, then confirm the
    %% global key -- unattributed calls, i.e. most real traffic here --
    %% is a genuinely separate counter with room well past that.
    Caller = unique_caller(),
    [mcl_echo_limiter:allow(Caller) || _ <- lists:seq(1, 20)],
    ?assertEqual(deny, mcl_echo_limiter:allow(Caller)),
    GlobalResults = ['$global' || _ <- lists:seq(1, 21)],
    ?assertEqual(lists:duplicate(21, allow),
                 [mcl_echo_limiter:allow(K) || K <- GlobalResults]).

exceeding_the_global_max_denies_further_unattributed_calls() ->
    %% 300 is the global max; this test's own prior global calls in the
    %% same process (from the test above) share the SAME window, so
    %% drive it past 300 total from a fresh vantage point by checking
    %% only that denial eventually happens, not an exact count -- the
    %% window boundary is real wall-clock time and not worth pinning
    %% a unit test to.
    Results = [mcl_echo_limiter:allow('$global') || _ <- lists:seq(1, 400)],
    ?assert(lists:member(deny, Results)).

a_runtime_limit_change_takes_effect() ->
    {ok, _} = mcl_echo_limiter:set_limits(#{per_caller_max => 3}),
    Caller = unique_caller(),
    Results = [mcl_echo_limiter:allow(Caller) || _ <- lists:seq(1, 3)],
    ?assertEqual(lists:duplicate(3, allow), Results),
    ?assertEqual(deny, mcl_echo_limiter:allow(Caller)),
    {ok, _} = mcl_echo_limits:reset().

changing_the_window_length_clears_the_counters() ->
    Caller = unique_caller(),
    [mcl_echo_limiter:allow(Caller) || _ <- lists:seq(1, 20)],
    ?assertEqual(deny, mcl_echo_limiter:allow(Caller)),
    {ok, _} = mcl_echo_limiter:set_limits(#{window_ms => 20000}),
    ?assertEqual(allow, mcl_echo_limiter:allow(Caller)),
    {ok, _} = mcl_echo_limits:reset().

a_bad_runtime_change_is_refused_and_changes_nothing() ->
    Before = mcl_echo_limiter:get_limits(),
    ?assertEqual({error, {unknown_key, nope}},
                 mcl_echo_limiter:set_limits(#{nope => 1})),
    ?assertEqual(Before, mcl_echo_limiter:get_limits()).

stats_show_the_window_and_who_is_over_limit() ->
    Caller = unique_caller(),
    [mcl_echo_limiter:allow(Caller) || _ <- lists:seq(1, 20)],
    _ = mcl_echo_limiter:allow(Caller),
    Stats = mcl_echo_limiter:stats(),
    ?assertEqual(20, maps:get(per_caller_max, maps:get(limits, Stats))),
    ?assert(maps:get(callers_over_limit, Stats) >= 1),
    ?assert(maps:get(global_count, Stats) >= 21),
    ?assert(lists:keymember(Caller, 1, maps:get(top_callers, Stats))).

unique_caller() ->
    N = erlang:unique_integer([positive, monotonic]),
    <<"caller-", (integer_to_binary(N))/binary>>.
