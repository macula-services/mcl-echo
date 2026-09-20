# mcl-echo

**Always-on echo, the mesh's hello-world target every SDK quickstart calls**

## Status: live on the PQ fleet

The service boots, joins the mesh, answers `/health` on 8461, and advertises
the echo capability through the standard `mcl_om_capabilities` path
(`mcl_echo_service:capabilities/0`). The 11.x wire refuses a procedure
without an org namespace, so the wire name is `Org/echo`: the org is
**deploy config, not code**.

One org per service, named after the repo
(`PLAN_PROVIDER_AUTHORIZATION_FLOW.md`, macula-realm). This fleet deploys org
`mcl-echo` under the **io.macula** realm, so the wire procedure is
`mcl-echo/echo`. The org and the realm are independent: every `mcl-*` service
carries its own org and they all sit in the io.macula realm. The realm issues
this node's D25 delegation after admission.

`mcl_om_capabilities` registers the org-qualified procedure and nothing else.
The bare `io.macula.echo` literal every 10.x quickstart hardcodes is **not**
advertised here. It keeps working on the classical fleet (hecate-echo), which
is a separate deployment.

Before advertising, `mcl_echo_service:capabilities/0` asserts that both values
are configured and well formed: the realm tag is a 32-byte binary, and the org
is a valid wire segment (`^[a-z0-9][a-z0-9._-]*$`) and not the `_` placeholder
`mcl_om_identity` returns when nothing set it. It does **not** check that the
realm is a hash of the org. That coupling belonged to the old realm-name-org
convention and is gone; the org is bound to the node at admission, on the realm
side.

Both checks crash the node at boot rather than letting it drift. A realm
mismatch between advertiser and caller is silent on the wire
(`unknown_next_peer`, indistinguishable from nobody listening), and an org
drift silently renames the wire procedure to a name no caller uses. Crashing is
the loud version of the exact bug this service exists to stop.

## Calling it

| | |
|---|---|
| Realm name | `io.macula` |
| Realm tag | `abb81b5a614b63551b400b810648c0c8a78efad845442630c94b46cc95d2fcd1` |
| Procedure | `mcl-echo/echo` |

    macula:call(Pool, Realm, <<"mcl-echo/echo">>, Payload, Timeout)

The realm tag is `macula_realm:id(<<"io.macula">>)`, and every SDK carries the
same helper. `scripts/mcl_echo_call` is the worked example, seed pin and realm
trust pin included.

The handler replies with the payload unchanged, minus the platform-injected
`caller` key. Two guards apply, both implemented in the handler because the
platform provides neither:

- **Payload cap**, 4096 bytes measured by `erlang:external_size/1` so it bounds
  every payload shape and not only binaries. Over it: `payload_too_large`.
- **Fixed-window rate limit** (`mcl_echo_limiter`): a 10 second window, 20 calls
  per caller, 300 globally. Over it: `rate_limited`.

⚠ **A caller is only attributable when the payload is a map.** The
wire-authenticated caller node id is merged in by
`macula_station_link:with_caller/2` for map payloads only, so a bare text
payload (what the 10.x quickstarts send) falls into the one shared global
bucket. Several callers testing at once with text payloads share a single
300-per-10s counter instead of getting 20 each. Send a map.

It asks the realm for no authority beyond its own scope: the echo is
deliberately public (`auth => open`), not gated by a UCAN grant.

## Running it

    rebar3 compile
    rebar3 eunit
    rebar3 lint

    scripts/health.sh                      # against a running node

Building the image needs a Rust toolchain, because macula ships a QUIC NIF and
the alpine build compiles it from source rather than fetching one linked against
a different libc.

    podman build -t mcl-echo -f Containerfile .

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `MCL_ORG` | required | The wire namespace: the echo advertises as `MCL_ORG/echo`. One org per service, named after the repo: `mcl-echo`. Must match `^[a-z0-9][a-z0-9._-]*$`. Independent of the realm. |
| `MCL_REALM` | required | 64-hex realm tag: `sha256` of the **realm** name, `io.macula`. Not a hash of the org. Reaches the node as an application env, never a bare shell variable: `config/sys.config.src` is the only place the two meet. |
| `MACULA_STATION_SEEDS` | required | Station hosts to dial, `host[:port]`, comma-separated. No default: naming a realm costs nothing, dialling a production station from every dev clone does. |
| `MACULA_STATION_NODE_IDS` | required | The matching 64-hex station node ids, comma-separated, index-paired with the seeds. The 11.x dial is pinned (D5): mcl_om refuses to boot a pool with an unpinned seed. |
| `MCL_HEALTH_PORT` | `8461` | Health endpoint. Host networking makes a collision a silent bind failure, so check the host before changing.  |
| `MCL_NODE_NAME` | `mcl_echo` | Erlang node name. |
| `MCL_NODE_HOST` | `127.0.0.1` | Erlang node host. |
| `MCL_COOKIE` | `mcl_echo` | Erlang cookie. |

`deploy/docker-compose.yml` runs it, and carries what the service knows about
itself. If you deploy through something else, let that carry **placement**: which
host, which station, which realm, which secret store. Keeping the two apart is
what stops a config table in a README and the real environment drifting.

## Deployment

CI builds on every push to `main` and pushes
`ghcr.io/macula-services/mcl-echo:latest` plus the semver tag. Pull `:latest`
under watchtower and a merge is a deploy, while a rollback is pinning to a
semver tag.

Two things CI cannot do for you, both of which have bitten:

1. The registry package may be created **private**, and the pull then fails on
   the host with a bare `unauthorized` that names nothing. Check it after the
   first build. On ghcr the `org.opencontainers.image.source` label in the
   Containerfile is what links the package to the repository.
2. The host needs `MCL_ORG`, `MCL_REALM` and the pinned station pair supplied
   from somewhere they are not committed — and the realm's D25 chain must
   publish a procedure delegation naming this service's node id for `MCL_ORG`
   (the realm admin's provisioning step).

## The service contract

Six callbacks in `mcl_echo_service`, all required, all resolved **by name** by
`mcl_om` at startup on a live node. The `-behaviour(mcl_om_service)`
attribute turns a missing one into a compile error rather than an `undef` where
nobody is watching, and the eunit suite guards the attribute itself.

### Adding a store later

This service has no `reckon-db` store, which is the right answer for most. The
reckon-db applications run either way; what a store adds is a data directory, an
open handle, and something written.

The cheapest way to get one is to scaffold again with `store=1`, which generates
the callbacks, the config and the guards together.

⚠ **By hand it is three things and not one, and the missing third crash-loops the
node.** Export `store_id/0` and `data_dir/0`; add the `evoq` adapter block to
`config/sys.config.src`, without which boot raises
`{not_configured, event_store_adapter}` before any service code runs; and mount a
volume in the compose file. A sibling service put two of three fleet nodes into a
boot loop by doing the first and not the second.

## Licence

Apache-2.0.
