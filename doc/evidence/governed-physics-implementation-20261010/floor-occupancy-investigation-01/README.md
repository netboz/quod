# Remaining native floor refusals — isolated investigation

The signed desktop 262-02 recording captured three clear-floor pauses. All
three exact starting positions and quantized velocities fail in an unchanged
copy of the production solver using the already-authored annular surface and
capsule. No visual mesh, changed tolerance, collider edit or ledger mutation is
involved. These local cases diagnose the real recording; they are not substitutes
for signed desktop acceptance.

Every named campaign retains full logs, source hashes and true child exit in
`campaigns.tar.gz`. Unchanged-input receipts are also readable separately.

- `quod27-floor-occupancy-repro-01`: expected regression failure, all three
  positions return Occupied(1,3). The installed world has only the relevant
  surface and body, so query counts differ from the complete real world.
- `quod27-floor-occupancy-trace-01`: diagnostic tracing shows the linear cast
  returning None, followed by a correctly refused penetrating endpoint.
- `quod27-floor-occupancy-query-01`: direct 2 mm target-distance casts miss at
  all three poses, with either stop-at-penetration flag. Zero target distance
  sees a hit; initial contact queries confirm positive separation below 2 mm.
  This diagnoses the cast; it does not authorize removing the policy's skin.
- `quod27-floor-occupancy-gjk-trace-01`: diagnostic-only dependency trace failed
  compilation because Parry's no_std module needs std::eprintln!. It produced
  no solver result and its stop marker remains.
- `quod27-floor-occupancy-gjk-trace-02`: the separately labelled qualified trace
  reproduces all failures and reaches the GJK ray halfspace miss branch. The
  relevant assertion still fails. These trace patches are scratch-only.
- `quod27-floor-contact-probe-01`: the library's existing contact-manifold query
  exposes the close supporting face at each captured position; the unchanged
  movement assertion still fails.
- `quod27-floor-contact-candidate-01`: scratch-only manifold preflight fixes all
  three cases, and 21 of 23 native tests pass. Two existing query-count bounds
  fail (head-on and same-surface obstacles). Those failures are retained and
  not waived. This is an experiment, not an approved production correction.

All campaigns exited 101, for the explicitly distinguished causes above. Native
production files and the deployed 0.7.262 remain unchanged. The plan is under
consultative Claude review; multi-face behavior, query accounting, broad
regressions and real signed acceptance still need verification.

The published Parry 0.31.1 archive has SHA256
7b626edc0b497dba4bdf6e1e0797895294ed9f61dac2bd28cb5d34d37ad2ca7e.
Every unpacked cached file was compared byte-for-byte with that archive; there
were no differences. Diagnostic dependency changes are retained as patches
against that exact version, rather than mutating the Cargo registry or adding
a production dependency fork.
