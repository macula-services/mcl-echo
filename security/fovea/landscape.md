# System Landscape — mcl-echo

```
                          io.macula realm (operator desk)
                          ┌──────────────────────────────────┐
                          │      provider authorization       │
                          │      D25 delegation:              │
                          │      node-id → org 'mcl-echo'     │
                          └─────────────▲────────────────────┘
                                        │  realm-scoped
                                        │  advertisement
                                        │
   station (any of the six pins)   providers' desks
        ┌──────────────────┐
        │  station leader  │◄── DHT\Service directory
        │  (mesh L1)       │◄────────────────────────┐
        └────────▲─────────┘                         │
   QUIC-pinned D5/D16 dial (host+node_id)             │ org-scoped call
                 │                                    │
                 ▼                                    │
        ┌─────────────────────────────────────────┐   │
        │            mcl-echo node (OTP)           │   │
        │                                          │   │
        │  ┌───────────────┐    ┌───────────────┐  │   │
        │  │ mcl_om wiring │───▶│ mcl_echo      │  │   │
        │  │ realm, org,   │    │ service       │  │   │
        │  │ realm_key,    │    │ echo handler  │[3]│   │
        │  │ capabilities  │    └───────────────┘  │   │
        │  └───────────────┘                       │   │
        │  ┌───────────────┐    ┌───────────────┐  │   │
        │  │ /health :8461 │    │ identity.key  │  │   │
        │  └───────────────┘    │ (volume) [1]  │  │   │
        │                       └───────────────┘  │   │
        └──────────────────────────────────────────┘
                 ▲
                 │ image :latest (GHCR, see trust anchor #3)
                 │
        ┌────────┴─────────────────────────────────────────┐
        │  build pipeline (CI): digest-pinned base images, │
        │  sha256-pinned rebar3, pinned OTP 28.4.3,        │
        │  lint+tests in  macula-ci-otp image [2]          │
        └──────────────────────────────────────────────────┘

         [1]  the only in-scope secret
         [2]  documented in CHANGELOG: 2026-09 images only
         [3]  guard surface: payload cap 4096 external_size,
              rate limit 20/10s per caller + 300/10s global
```

## Scope markers

In scope (per fovea.yaml): the node, image, volume, wire surface, build
pipeline, D25 lifecycle. Out: realm desk operation, stations themselves,
operators' host OS.

## Risks the landscape must answer

1. **Anchor placement.** Three of four anchors are outside the box: the
   realm's signing key (correct), the identity key volume (correct, but see
   cells), the pipeline (out-of-host, intentionally). The diagram has no
   "trust arrow" pointing inward from an unknown direction — if it did,
   mcl-echo's honest claim to *not* guard against the host is broken.
2. **First-hop.** Every inbound path arrives via the *pinned* **station dial
   only**; host networking means the landscape's "external world" is strictly
   the mesh plus the health port. No other listening edge.
3. **Observable links.** The QUIC dial is the only blob anyone can watch;
   everything under `in_motion` in this assessment is about this one link,
   and the topology of stations, not the service's internal state.
