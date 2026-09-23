%% @doc The terminal caller's dial seam is one the SDK accepts.
%%
%% `macula_direct_dial:dial_io/2' REPLACES its defaults with the map it is
%% given and refuses, with `function_clause' raised in the caller, any map
%% missing a key the call needs. macula 12 added two such keys to a call
%% (`resolved_candidate', `remember_resolved'), and the caller crashed on
%% its first call against the live fleet while compiling clean. This test
%% hands the map to the SDK's real `call/6', so the SDK's own check decides.
%%
%% The pool is a pid that has already exited: once the seam is accepted the
%% call's first I/O fails against it, which is fine. The only failure this
%% test is about is the seam being refused.
-module(mcl_echo_call_tests).

-include_lib("eunit/include/eunit.hrl").

recording_dial_io_is_accepted_by_the_sdk_call_test() ->
    DeadPool = spawn(fun() -> ok end),
    Ref = monitor(process, DeadPool),
    receive {'DOWN', Ref, process, DeadPool, _} -> ok end,

    Outcome = try macula_direct_dial:call(
                    DeadPool, <<0:256>>, <<"mcl-echo/echo">>, #{}, 1_000,
                    #{dial_io => mcl_echo_call:recording_dial_io()}) of
                  Result -> {returned, Result}
              catch
                  Class:Reason:Stack -> {raised, Class, Reason, top_frame(Stack)}
              end,

    ?assertNotMatch({raised, error, function_clause,
                     {macula_direct_dial, Seam, _}}
                    when Seam =:= given_key; Seam =:= dial_function,
                    Outcome).

top_frame([{M, F, A, _Loc} | _]) -> {M, F, A};
top_frame(_) -> none.
