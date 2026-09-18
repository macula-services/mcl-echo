%% @doc Real (not mocked) tests against the limiter's own ETS table:
%% boots the actual gen_server, calls the actual `allow/1', and asserts
%% on genuine atomic-counter behavior rather than a model of it.
-module(mcl_echo_limiter_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, Pid} = mcl_echo_limiter:start_link(),
    Pid.

%% Synchronous: the next test FILE's own setup/0 re-registers this same
%% local name and re-creates the same named ETS table, which must not
%% race an async exit signal still in flight from this one.
teardown(Pid) ->
    Ref = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _Reason} -> ok end.

limiter_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Pid) ->
        [
            fun per_caller_allows_up_to_its_own_max/0,
            fun per_caller_denies_once_over_its_own_max/0,
            fun distinct_callers_have_independent_counters/0,
            fun the_global_key_has_its_own_higher_max/0,
            fun exceeding_the_global_max_denies_further_unattributed_calls/0
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

unique_caller() ->
    N = erlang:unique_integer([positive, monotonic]),
    <<"caller-", (integer_to_binary(N))/binary>>.
