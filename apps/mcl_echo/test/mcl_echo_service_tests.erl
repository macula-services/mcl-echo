%% @doc The service contract, asserted locally.
%%
%% mcl_om resolves its six callbacks BY NAME at startup, on a live node, so a
%% service that forgets one dies with `undef' where nobody is watching. The
%% primary defence is the `-behaviour(mcl_om_service)' attribute on the
%% service module, which turns a missing callback into a compile error under
%% warnings_as_errors.
%%
%% What this suite adds is everything the compiler cannot see: that the attribute
%% has not been quietly dropped, that the values inside those callbacks are the
%% shapes mcl_om will destructure, and that the names and version this service
%% reports are the ones it actually has. Nothing local boots mcl_om, so
%% asserting the shape by hand is the closest available thing to a rehearsal.
-module(mcl_echo_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, mcl_echo).
-define(SERVICE, mcl_echo_service).

%% Belt and braces with the behaviour attribute, and it survives the attribute
%% being removed. If mcl_om ever adds a SEVENTH required callback this test
%% keeps passing and the deploy still breaks, which is the honest limit of a
%% local assertion about a remote contract.
exports_every_required_callback_test() ->
    _ = code:ensure_loaded(?SERVICE),
    Required = [{info, 0}, {start, 1}, {stop, 1},
                {health, 0}, {capabilities, 0}, {identity_spec, 0}],
    Missing = [F || {N, A} = F <- Required,
                    not erlang:function_exported(?SERVICE, N, A)],
    ?assertEqual([], Missing).

info_carries_the_three_keys_test() ->
    #{name := Name, version := Vsn, description := Desc} = ?SERVICE:info(),
    ?assert(is_binary(Name)),
    ?assert(is_binary(Vsn)),
    ?assert(is_binary(Desc)),
    ?assertEqual(<<"mcl-echo">>, Name).

%% THE TWO NAMES MUST AGREE. The OTP application is snake_case because it is an
%% Erlang atom; the repository, the container image and the name this service
%% answers to on the mesh are kebab-case. They describe one service, so a
%% scaffold generated with a mismatched pair is caught here on the first eunit
%% run rather than by a puzzled reader months later.
mesh_name_matches_the_application_test() ->
    #{name := Wire} = ?SERVICE:info(),
    Snake = atom_to_binary(?APP, utf8),
    ?assertEqual(binary:replace(Snake, <<"_">>, <<"-">>, [global]), Wire).

%% The version in info/0 is what a peer reads off /health, so it disagreeing with
%% the application it describes is a lie that nothing else would catch.
info_version_matches_the_application_test() ->
    _ = application:load(?APP),
    {ok, Vsn} = application:get_key(?APP, vsn),
    #{version := Reported} = ?SERVICE:info(),
    ?assertEqual(list_to_binary(Vsn), Reported).

health_is_green_test() ->
    ?assertEqual(ok, ?SERVICE:health()).

%% Without `mcl_om_identity' running, `realm/0' returns `{error,
%% not_booted}' -- `capabilities/0' must crash rather than silently fall
%% through to advertising on the wrong realm, so this asserts the crash,
%% not a return value.
capabilities_crash_before_the_identity_boots_test() ->
    ?assertError({mcl_echo_realm_mismatch, {error, not_booted}},
                 ?SERVICE:capabilities()).

%% The positive path, with a REAL mcl_om_identity booted on a
%% well-formed realm/org pair (any 32-byte realm tag + any valid org
%% segment; the org and realm are decoupled since the
%% one-org-per-service cutover): exactly one capability, named as the
%% wire contract's own name -- the org-qualified wire name comes from
%% the org, not from the capability name.
capabilities_with_a_booted_identity_is_the_one_echo_capability_test_() ->
    {setup,
     fun start_identity_on_a_wellformed_realm_and_org/0,
     fun stop_identity_and_restore_env/1,
     fun(_Pid) ->
         ?_assertEqual([#{name => <<"echo">>, version => 1,
                          handler => {mcl_echo_mesh_rpc, []}, auth => open}],
                       ?SERVICE:capabilities())
     end}.

%% The crashes the configured-ness assert exists for: an unset org
%% (the `_` placeholder) or a malformed org must crash at boot, never
%% silently advertise under a namespace no caller uses -- and since
%% the realm-side org binding happens at admission, there is no
%% hash-coupling left to drift.
capabilities_crash_on_an_unset_org_test_() ->
    {setup,
     fun start_identity_on_an_unset_org/0,
     fun stop_identity_and_restore_env/1,
     fun(_Pid) ->
         ?_assertError({mcl_echo_org_unset, _}, ?SERVICE:capabilities())
     end}.

capabilities_crash_on_an_invalid_org_test_() ->
    {setup,
     fun start_identity_on_an_invalid_org/0,
     fun stop_identity_and_restore_env/1,
     fun(_Pid) ->
         ?_assertError({mcl_echo_org_invalid, _}, ?SERVICE:capabilities())
     end}.

-define(TEST_ORG, <<"acme.test">>).
-define(TEST_REALM,
        <<16#AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899:256>>).

start_identity_on_a_wellformed_realm_and_org() ->
    start_identity_with(?TEST_REALM, ?TEST_ORG).

start_identity_on_an_unset_org() ->
    start_identity_with(?TEST_REALM, <<"_">>).

start_identity_on_an_invalid_org() ->
    start_identity_with(?TEST_REALM, <<"Bad Org">>).

start_identity_with(Realm, Org) ->
    Running = ensure_identity_not_running(),
    Saved = {application:get_env(mcl_om, realm),
             application:get_env(mcl_om, org)},
    ok = application:set_env(mcl_om, realm, Realm),
    ok = application:set_env(mcl_om, org, Org),
    {ok, Pid} = mcl_om_identity:start_link(),
    {Pid, Running, Saved}.

stop_identity_and_restore_env({Pid, Running, Saved}) ->
    try gen_server:stop(Pid) catch _:_ -> ok end,
    {SavedRealm, SavedOrg} = Saved,
    restore_env(realm, SavedRealm),
    restore_env(org, SavedOrg),
    restore_identity(Running).

ensure_identity_not_running() ->
    case whereis(mcl_om_identity) of
        undefined -> undefined;
        Old ->
            unlink(Old),
            Ref = monitor(process, Old),
            exit(Old, kill),
            receive
                {'DOWN', Ref, process, Old, _Reason} -> ok
            after 2_000 -> ok
            end,
            running
    end.

restore_env(_Key, undefined) -> ok;
restore_env(Key, {ok, Value}) -> ok = application:set_env(mcl_om, Key, Value).

restore_identity(undefined) -> ok;
restore_identity(running)   -> {ok, _} = mcl_om_identity:start_link(), ok.

identity_spec_has_the_shape_mcl_om_expects_test() ->
    #{scope := Scope, actions := Actions,
      resources := Resources, ttl_days := Ttl} = ?SERVICE:identity_spec(),
    ?assert(is_binary(Scope)),
    ?assert(is_list(Actions)),
    ?assert(is_list(Resources)),
    ?assert(is_integer(Ttl) andalso Ttl > 0).

%% `io.macula.echo' is deliberately public: this service asks the realm
%% for no authority beyond its own scope regardless of what it announces,
%% since `auth => open' on the capability itself is what makes it
%% callable by anyone, not a UCAN grant.
authority_matches_what_is_announced_test() ->
    #{actions := Actions, resources := Resources} = ?SERVICE:identity_spec(),
    ?assertEqual([], Actions),
    ?assertEqual([], Resources).

%% The supervisor starts and stops cleanly on its own, without mcl_om.
%% `io.macula.echo' itself is now advertised by `mcl_om_capabilities'
%% (a separate, already-running process in a real boot), not by a child
%% of this supervisor -- so there is exactly one child to check.
supervisor_starts_and_stops_test() ->
    {ok, Pid} = mcl_echo_sup:start_link(),
    ?assert(is_process_alive(Pid)),
    Children = supervisor:which_children(Pid),
    ?assertEqual(1, length(Children)),
    ?assert(lists:all(fun({_Id, Child, _Type, _Mods}) -> is_pid(Child) end, Children)),
    unlink(Pid),
    exit(Pid, shutdown).

%%==============================================================================
%% The runtime is pinned in two places, and neither is the one you are running
%%==============================================================================

%% ⚠ THIS GUARD EXISTS BECAUSE A SIBLING SERVICE DID NOT HAVE IT, AND IT COST
%% THREE COMMITS AND AN IMAGE THAT SHIPPED ANYWAY.
%%
%% Its `Containerfile' said 27 while development ran on 28. So `rebar3 eunit'
%% passing locally meant "passing on 28" and nothing more, CI failed on a crash
%% that does not occur on 28 at all, and because the image build is a separate
%% workflow the image went to the fleet regardless.
%%
%% The release is pinned in TWO files, and the version actually running is a
%% third thing that agrees with neither by default. **A comment in each file
%% saying they must match is not a mechanism**, and both files carried one.
%%
%% ⚠⚠ IT FAILS RATHER THAN WARNS WHEN YOUR VM DIFFERS, AND THAT IS DELIBERATE.
%% Developing on a release you do not ship makes a green suite mean less than it
%% appears to. If you want to work on another release, move both pins and find
%% out what breaks, which is the whole point of having them.
%%
%% ⚠ TO THE PATCH, AND NOTHING FLOATS. This compared majors only, so when Docker
%% Hub moved the floating `erlang:28-alpine' on 2026-09-22 the next deploy
%% shipped OTP 28.5 and this stayed green. It compares the full release now:
%% the builder's (which must also carry a digest, so a re-pushed tag cannot
%% change what builds), the release lint's toolchain step insists on (its image
%% tag carries a date, not a version), .tool-versions, and this VM.
the_runtime_agrees_between_the_image_the_ci_and_this_vm_test() ->
    Image = pinned("Containerfile",
                   "^FROM docker\\.io/(?:hexpm/)?erlang:([0-9]+\\.[0-9]+\\.[0-9]+)"
                   "-alpine[^@\\s]*@sha256:[0-9a-f]{64} AS builder$"),
    Ci = pinned(".github/workflows/lint.yml",
                "\\{<<\"([0-9]+\\.[0-9]+\\.[0-9]+)\">>, true\\} -> halt\\(0\\);"),
    Tools = pinned(".tool-versions", "^erlang ([0-9]+\\.[0-9]+\\.[0-9]+)$"),
    %% Sorted and deduplicated, so a failure prints every version rather than
    %% the first pair that happened to be compared.
    ?assertEqual([Image], lists:usort([Image, Ci, Tools, running_otp()])).

%% The full release, 28.4.3 and not 28: `otp_release' names only the major.
running_otp() ->
    {ok, Version} = file:read_file(filename:join([code:root_dir(), "releases",
                                                  erlang:system_info(otp_release),
                                                  "OTP_VERSION"])),
    string:trim(Version).

%% rebar3 is a tool in the image build, pinned like the images: one release,
%% verified by sha256. It was fetched from an S3 URL that serves whatever was
%% published last.
image_build_pins_rebar3_by_sha256_test() ->
    {ok, Containerfile} = file:read_file(alongside("Containerfile")),
    ?assertMatch({match, _},
                 re:run(Containerfile, "releases/download/3\\.27\\.0/rebar3")),
    ?assertMatch({match, _},
                 re:run(Containerfile, "\\b[0-9a-f]{64}  /usr/local/bin/rebar3")),
    ?assertNotEqual(nomatch, binary:match(Containerfile, <<"sha256sum -c -">>)),
    ?assertEqual(nomatch, binary:match(Containerfile, <<"s3.amazonaws.com/rebar3">>)).

%% Nothing names a floating image: a lint container of `erlang:28' would pass
%% the check above only while Docker Hub happens to agree.
lint_runs_on_no_floating_image_test() ->
    {ok, Lint} = file:read_file(alongside(".github/workflows/lint.yml")),
    ?assertMatch({match, _},
                 re:run(Lint, "image: ghcr\\.io/macula-io/macula-ci-otp:[0-9]{8}-[0-9]{4}@sha256:[0-9a-f]{64}$",
                        [multiline])).

%% ONE ORG PER SERVICE, NAMED AFTER THE REPOSITORY, fixed in the release. It
%% came from `${MCL_ORG}', so a host that never set the variable ran a node whose
%% org was the literal "${MCL_ORG}": since mcl_om 0.27.1 that refuses to boot,
%% and before it the node ran green and advertised nothing. The org is a
%% property of the service, not of where it runs.
the_release_fixes_the_org_to_the_repository_name_test() ->
    ?assertEqual(<<"mcl-echo">>,
                 pinned("config/sys.config.src", "^\\s+\\{org,\\s*<<\"([^\"]*)\">>\\},")).

%% The image says which commit it was built from: build-push passes the sha,
%% the runtime stage labels the image with it. A digest pinned on a box is
%% then traceable to a commit without the registry's history.
the_image_carries_its_revision_test() ->
    ?assertEqual(<<"REVISION">>,
                 pinned("Containerfile", "^ARG (REVISION)=unknown$")),
    ?assertEqual(<<"${REVISION}">>,
                 pinned("Containerfile", "^LABEL org\\.opencontainers\\.image\\.revision=\"([^\"]+)\"$")),
    ?assertEqual(<<"${{ github.sha }}">>,
                 pinned(".github/workflows/build-push.yml", "^\\s+REVISION=(.+)$")).

pinned(Relative, Pattern) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    {match, [Version]} = re:run(Text, Pattern,
                                [multiline, {capture, all_but_first, binary}]),
    Version.

%% Relative to the beam rather than the working directory, because eunit runs
%% from wherever the developer happens to be standing.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) ->
    climb(filename:dirname(Dir), Name, Left - 1).
