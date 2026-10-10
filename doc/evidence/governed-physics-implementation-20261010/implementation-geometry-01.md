# Shared geometry prerequisite: implementation scope

This is partial implementation of the governed-physics task. The ownership and
foreign-projection delegation choices in [architecture-gate.md](architecture-gate.md)
remain pending. No deployment, live founding, capability installation, hosting,
body edit or ledger mutation was performed by this session.

`priv/ontologies/quod_physics.pl` replaces the box-only `physics_valid_body/5`
with one `physics_valid_body/6` authored-body schema. Body relocation uses it,
preserving an authored rotation. It validates ground identity, kind, pose,
density, coordinate policy, primitive solids, compound part poses and fixed
surface indexing. Native representation, positive hull volume, triangle area,
compound bounds and supported joint mechanics remain adapter checks. Door
actions use the same schema and explicitly retain the adapter's box hinge
requirement. No bridge, mutable owner or capability manifest changed.

Production delta is 46 added, 9 removed lines (net +37); the shared supported
geometry schema accounts for the growth. Documentation adds 6 lines and tests
add 60 lines. No compatibility branch or old validator remains.

Six signed edit cases exercise boxes, balls, capsules, convex solids, rigid
parts and fixed surfaces through the installed production physics owner.
They verify policy denial, committed edits, stable anchored world/body identity,
preserved rotation, advanced body/structure revision, stale rejection and
unchanged repeat work without the traced history/storage operations or another
native installation. The rejection case covers eleven malformed definitions
through signed edits and verifies unchanged committed state and height.
These fixtures do not establish remote-source propagation or real-lobby desktop
acceptance.

## Validation receipts

- `geometry-01.log` / `geometry-01-exit.json`: six supported-shape cases passed;
  rejection fixture setup failed on unsupported `retractall/1`, child exit 1.
  Its failed fixture remains `/tmp/quod_hosted_A7EA0218EB489E23`.
- `geometry-02.log` / `geometry-02-exit.json`: setup replaced with the existing
  single-body `retract/1`; 7 tests, zero failures, child exit 0.
- `owners-geometry-01.log` / `owners-geometry-01-exit.json`: physics, control,
  runtime and space owner modules; 173 tests, zero failures, child exit 0.
  Production/test hashes before and after the run are equal.
- `git diff --check` passed.

The IP-address browser attempt reached an error page and was closed by its
owner. A read-only network-enabled HEAD probe reached TLS but failed hostname
verification (exit 60). Public certificate inspection showed `DNS:localhost`
and `IP:127.0.0.1`; the localhost HEAD probe had no reachable listener (exit 7).
No signed personal-lobby baseline was obtained. This does not prove that the
personal lobby is absent and authorizes no replacement account or lobby.

Full implementation, normal-view integration, exact remote invalidation and
unchanged-work measurements, concurrent admission/edit/withdrawal and real
signed acceptance in the preserved current personal lobby remain required.
The second Fable review freezes and assesses only this implemented prerequisite;
it is not review or acceptance of the remaining feature.
