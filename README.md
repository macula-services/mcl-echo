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
advertised here, and nothing on the fleet answers it any more: callers use the
org-qualified `mcl-echo/echo`.

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
trust pin included:

    ./scripts/mcl_echo_call                # default, helsinki
    ./scripts/mcl_echo_call falkenstein    # pick the way in

The station is the caller's route into the mesh, and **several callers at once
should each take their own**. Pinned to one station, six sessions all enter
through the same box and a fan-out measures a single route six times.
`mcl_echo_stations` holds the six pins, host and node id together, taken from
macula-demo's `topologies/eu/stations.csv`: `helsinki`, `falkenstein`,
`frankfurt`, `nuremberg`, `paris`, `amsterdam`. The script prints the station
it dialled before calling, so a session reports the route it took rather than
the one it meant to take.

### The six-caller fan-out

One session per station, one line each, fired at the same time:

    ./scripts/mcl_echo_call nuremberg
    ./scripts/mcl_echo_call falkenstein
    ./scripts/mcl_echo_call frankfurt
    ./scripts/mcl_echo_call helsinki
    ./scripts/mcl_echo_call paris
    ./scripts/mcl_echo_call amsterdam

`falkenstein`, `helsinki` and `frankfurt` are mcl-echo's own seeds; the other
three are stations it never dials. The split is three seed and three non-seed
deliberately, because a result that holds on both halves says something a
result from the seeds alone does not.

Everything the run depends on is printed rather than assumed, and the banner is
what a session reports back:

    station        falkenstein (station-de-falkenstein.macula.io)
    station nodeid 00df68247d119685f94030afdb203ab7a2a105fb6093a964dbf0509a57e86435
    procedure      mcl-echo/echo
    realm          io.macula (abb81b5a614b63551b400b810648c0c8a78efad845442630c94b46cc95d2fcd1)
    caller nodeid  006a9f092dcc55a5899e2a4f5d93a5dba4bc0706a9b15f40b66ee3a63c24d73a
    payload        #{<<"ping">> => <<"pong">>} (24 bytes local external_size, cap 4096)
    tls            an UNVERIFIED dial warning follows: expected, ...
    result         {ok, ...}

Between `result` and `links after` the run prints a `route` block: every DHT
lookup and every station call the SDK actually made, in order. That comes from
`macula_direct_dial`'s own `dial_io` seam, not from a label this script writes
about its own input. `macula:call/5` never names the station it resolved to, so
a harness that logs its argument logs nothing; `call/6` is handed a `find_records`
(advertisement lookup), a `find_record` (station endpoint lookup) and a
`call_station`.

⚠ **A call carries two identities and they are different things:** it dials the
serving **station**'s endpoint and addresses the request to the **provider**. In
`macula:call_station(Pool, Station, Target, ...)` the Target is the provider, and
the station's pin rides in `Opts`. The route block records all three by name,
`station_url`, `station_pin` and `provider`, because recording only the Target
and calling it "the station" reports an id that names nothing on the fleet.
`station_pin` is what D16 enforces at the handshake, so that is the station. A step that never appears says as
much as one that does: no `find_record` line means resolution never reached the
station endpoint lookup, and no `call_station_to` line means it never reached a
provider at all.

The realm is computed with `macula_realm:id/1` and the payload is printed from
the same macro the call sends, so both lines are evidence and not a second
claim that could drift from the first. The caller node id is minted fresh every
run and **is the rate-limit key**, which is why it is on the banner: six
sessions sending maps get six separate 20-per-10s buckets, and a `rate_limited`
result is only readable if you know which bucket it came from.

The callers ask for **`verify => none`, deliberately**, and the UNVERIFIED-dial
warning that follows is macula reporting that decision rather than a problem.
What binds a dial to the station it names is the D16 handshake pin,
`expected_node_id`, which is required and which the station's challenge must
derive to. TLS server verification is not the control on this path; the pin is.
macula 11.5.0's own `macula_peering_conn:dial_opts/1` says the same: a station's
leaf is self-signed or issued by an unrelated PKI, and the signed handshake binds
the connection, not the certificate chain.

This said `webpki` until recently, and that was safe only by accident. macula
11.4.0's `start_dial/1` read just `alpn` and `timeout_ms` off the dial target and
passed a literal `{verify, none}`, so the option was decorative. 11.5.0 honours
the target's value, which would have made `webpki` a real X.509 chain check
against the built-in public roots on every station dial. A harness that cannot
connect measures nothing, so asking for `none` explicitly is what keeps the six
callers able to dial once mcl-echo moves to 11.5.0. mcl_om's pool default made
the same move for the same reason.

Each session's pool holds a **single seed, its own assigned station**, never a
shared six-seed list, and `station_discovery => #{enabled => false}` with
`link_selection => first_success` are passed explicitly rather than left to a
default. That matters more than it looks. Pool-routed DHT lookups order links
with `maps:values` over a seed-keyed map, so a shared seed list sorts the same
way in every session and all six would send their lookups to the same box,
reproducibly, looking stable rather than wrong. One seed each makes both legs
that session's station, so "from six different stations" is true of the lookup
leg as well as the call leg. It also leaves `first_success` nothing to choose
between, so the six callers differ in the station and in nothing else.

The script refuses rather than guesses on two things, because a run that differs
from its neighbours without saying so costs more than it reports:

- **exit 3**, the tree is not compiled. Without it the `-pa` glob stays literal
  and `erl` fails deep in the boot with nothing naming the cause.
- **exit 4**, `mise` is missing. `.tool-versions` pins the OTP these beams and
  their NIFs were built with, and it is not the first `erl` on `PATH`, so an
  unpinned run would quietly use a different VM from the build and from the
  other five callers.

The 11.x dial is pinned (D5), so a station is only reachable together with the
node id minted for that box. That is why the name alone is not enough and the
table carries both. The fleet is IPv6 only: a host with no IPv6 path reaches
none of them.

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

The OTP is pinned in `.tool-versions` and is not the first `erl` on `PATH` here,
so prefix with `mise exec --` (the caller script does this for you):

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
| `MCL_REALM_KEY` | required | The **trust anchor**: the io.macula realm's public signing key, hex encoded. A different thing from `MCL_REALM`, which is only an identifier. Every org-namespaced advertisement is verified against this key, so without it nothing resolves, the boot claim never reaches the realm, and the service runs green and unreachable. Public material, not a secret. Requires `mcl_om >= 0.3.0`, which refuses to start a pool without it. |
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

CI publishes on two channels, and they are deliberately separate:

| Push | Publishes | Is |
|------|-----------|-----|
| to `main` | `ghcr.io/macula-services/mcl-echo:latest` | the deploy channel |
| a `v*` tag | `ghcr.io/macula-services/mcl-echo:<semver>` only | the rollback archive |

Pull `:latest` under watchtower and a merge is a deploy. A rollback is pinning
to a semver tag, then back to `:latest` once the fix ships.

**A tag push does not move `:latest`.** It used to, which meant cutting a
release also deployed it, seconds later, to every box watching `:latest`
whether anyone intended that or not, and made a release impossible to cut
during a live test without swapping the artifact under it. Cutting a release
and deploying one are separate acts.

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
