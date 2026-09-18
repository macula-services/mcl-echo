# mcl-echo

**Always-on echo, the mesh's hello-world target every SDK quickstart calls**

## Status: the first mcl service, pending its live check on the PQ fleet

The service boots, joins the mesh, answers `/health` on 8461, and advertises
the echo capability through the standard `mcl_om_capabilities` path
(`mcl_echo_service:capabilities/0`). The 11.x wire refuses a procedure
without an org namespace, so the wire name is `Org/echo`: the org — and with
it the realm — is **deploy config, not code**. Every realm runs its own echo
under its own name; the io.macula fleet deploys org `io.macula` under the
io.macula realm (the realm's own namespace), and the SDK quickstarts on the
PQ fleet call `io.macula/echo`. The bare `io.macula.echo` literal every 10.x
quickstart hardcodes keeps working on the classical fleet (hecate-echo,
untouched).

The service asserts the pair is consistent before advertising: the realm tag
must be `macula_realm:id/1` of the org (sha256 of its name). A realm mismatch
between advertiser and caller is silent on the wire (`unknown_next_peer`,
indistinguishable from nobody listening) and an org drift would silently
rename the wire procedure to a name no caller uses — so a config pair that
drifted crashes this service loudly at boot instead of recreating that bug
quietly.

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
| `MCL_ORG` | required | The wire namespace: the echo advertises as `MCL_ORG/echo`. Must be the realm's name. |
| `MCL_REALM` | required | 64-hex realm tag, the `sha256` of the org's name — the service crashes at boot if the two drift apart. |
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
