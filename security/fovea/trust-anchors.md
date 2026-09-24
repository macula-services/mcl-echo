# Trust-Anchor Register — mcl-echo

Anchors whose compromise totals the assessment's `by_design` claims, in the
spec's sense (spec/v0.2/14-instantiation). Four; no more, because anything
with a smaller blast radius is a sensitive secret, not an anchor.

| # | Anchor | Type | Present? | Ceremony | Compromise impact |
|---|--------|------|----------|----------|-------------------|
| 1 | io.macula realm signing key (counterpart of `MCL_REALM_KEY`, hex) | Realm authority | ☐ (held by realm operator, off-repo) | Realm-side | Total: every org-scoped advertisement resolves against this; a forged key mints spoofed realms. Excluded from this assessment's write scope by design — verify at macula-realm's own register. |
| 2 | This node's identity key (`/etc/mcl/secrets/identity.key`) | Node authority | ☑ (mounted volume `mcl-echo_mcl_echo_secrets`) | Volume hand-over at deploy; no ceremony doc yet → noted in cells | Everything `decommission.possession` plus all authenticity cells: impersonition as `mcl-echo/echo` with some legitimacy at the provider desk. |
| 3 | Release pipeline: `ghcr.io` org account + CI runner | Supply-chain authority | ☑ (GitHub org) | Not documented → placeholder register, anchor-level gap | All `create`/(acquire)/`deliver` claims: a reachable attacker publishes a plausible `:latest`. |
| 4 | macula 12 wire profile (`macula_node_keys` puzzle + `pq_hybrid`) | Hard consensus | ☑ (vendor code shipped as dep `macula ~> 12.2`) | macula-io release process | `temporal.*` PQ-resistance claims: swapping the profile silently erases them; macula 12 makes the profile a floor, not a floor+choice. |

**Rules confirmed:** scope-totalling only. `mcl_echo` cookie, health port,
`MCL_SERVICE_NAME` and friends are secrets or knobs, not anchors, and are
referenced in cells where they matter.
