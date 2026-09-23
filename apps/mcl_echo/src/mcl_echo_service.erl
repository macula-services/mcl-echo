%% @doc The mcl_om service contract: what this service is and may do.
%%
%% SIX CALLBACKS, ALL REQUIRED. mcl_om resolves them BY NAME at startup, on a
%% live node, so a service that forgets one dies with `undef' where nobody is
%% watching. The `-behaviour' attribute below is what turns that into a compile
%% error instead, and the generated test suite guards the attribute itself.
-module(mcl_echo_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{name => <<"mcl-echo">>,
      version => <<"0.1.0">>,
      description => <<"Always-on echo, the mesh's hello-world target every SDK quickstart calls">>}.

start(_Opts) -> mcl_echo_sup:start_link().

stop(_State) -> ok.

%% Green once the supervision tree is up. Replace this with a real probe of
%% whatever this service needs in order to do its job. A dark mesh is usually NOT
%% a health failure: decide that deliberately rather than by default.
health() -> ok.

%% The echo capability, advertised through the standard
%% `mcl_om_capabilities' path. The 11.x wire refuses a procedure without
%% an org namespace (`no_org_namespace'), so the wire name is `Org/echo':
%% the org (and the realm the org lives in) are DEPLOY CONFIG, not code.
%% Per the provider-authorization flow's decisions (macula-realm,
%% PLAN_PROVIDER_AUTHORIZATION_FLOW.md): one org per service, named
%% after the repo -- this fleet deploys org `mcl-echo' under the
%% io.macula realm, and the realm issues the D25 delegation for this
%% node after admission. The bare `io.macula.echo' literal every 10.x
%% quickstart hardcodes is not advertised, and nothing on the fleet
%% answers it any more; callers use the org-qualified name.
%%
%% `mcl_om_capabilities' resolves ONE realm and ONE org for the whole
%% batch, from this node's own live identity. A realm mismatch between
%% advertiser and caller is silent on the wire (`unknown_next_peer',
%% indistinguishable from "nobody is listening"), which is the exact
%% failure this service exists to stop happening -- and an org drift
%% would silently rename the wire procedure to a name no caller uses,
%% the same failure one layer up. So the two are asserted CONFIGURED
%% and well-formed, crash-loud, rather than trusted to a config pair
%% nothing would notice going wrong: the realm must be a 32-byte tag
%% and the org a valid wire segment (never the `_` placeholder). The
%% OLD sha256(org) == realm coupling died with the realm-name-org
%% convention: under one-org-per-service the realm is io.macula for
%% every mcl-* org, and the pairing is enforced at ADMISSION on the
%% realm side (org bound at admission), not by hashing the name.
%% A deploy that drifts one of the two crashes at boot instead of
%% advertising where nobody can find it. `capabilities/0' runs as an
%% argument to `mcl_om_capabilities:register/1' inside `mcl_om:boot/2',
%% by which point `mcl_om_identity' is already up (OTP application-start
%% ordering starts it ahead of the service module's own boot), so
%% there is no race to guard against here, only config values to check.
capabilities() ->
    ok = assert_realm_org_configured(),
    [#{name => <<"echo">>,
       version => 1,
       handler => {mcl_echo_mesh_rpc, []},
       auth => open}].

assert_realm_org_configured() ->
    checked_realm(mcl_om_identity:realm(), mcl_om_identity:org()).

checked_realm({error, not_booted}, _Org) ->
    error({mcl_echo_realm_mismatch, {error, not_booted}});
checked_realm({ok, Realm}, Org) ->
    checked_tag(Realm, Org);
checked_realm(Realm, Org) ->
    error({mcl_echo_realm_mismatch, Realm, Org}).

checked_tag(<<_:256>>, Org) ->
    checked_org(Org);
checked_tag(Realm, Org) ->
    error({mcl_echo_realm_org_mismatch, Realm, Org}).

checked_org(<<"_">>) ->
    error({mcl_echo_org_unset, unconfigured_org});
checked_org(Org) ->
    case re:run(Org, <<"^[a-z0-9][a-z0-9._-]*$">>, [{capture, none}]) of
        match    -> ok;
        nomatch  -> error({mcl_echo_org_invalid, Org})
    end.

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more.
%% Ask for exactly the topics you publish and subscribe to. Popped, an attacker
%% gains precisely this and no more, which is the whole point of listing it.
%%
%% The scope is claimed now because it is the namespace every later resource
%% hangs under, and a scope costs nothing while a rename costs every deployed
%% peer.
identity_spec() ->
    #{scope => <<"mcl-echo">>,
      actions => [],
      resources => [],
      ttl_days => 30}.
