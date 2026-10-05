# Physics integration evidence — 2026-10-05

Implementation and validation are complete; changes are uncommitted. This is
verification evidence, not a review or deployment approval. The semantic authority
is [world.md](../../world.md); the current boundary audit is
[physics-native.md](../../physics-native.md).

## Final verification

Clean sequential campaign **06** passed every gate, with true child exits:

- Cargo native tests and Clippy with warnings denied.
- EUnit: **3,650 tests, zero failures**, 481.537 seconds.
- Common Test: **145 tests passed**.
- xref, Dialyzer and production release assembly.

The source remained unchanged throughout that campaign. Its
[source manifest](source-manifest.json) hashes 818 non-document files, relative
to base commit `6e5f85331f94cc024bb487f6bc47cbc2c76634cb`.
[Gate exits](gates-final.status), [delivery exits](delivery-final.status) and
[image/build identities](delivery-context.json) record the exact scope.

The focused physics suite has 25 tests. It exercises the real runtime and hosted
actor path for optional startup, falling motion, unchanged retention without
history folds or file writes/syncs, changed-body installation, sleeping,
allowance failures, retirement, same-host generations, assignment replacement,
replay/collapse, stale frames, coalescing and activation custody. Cancellation
races cover both commit orders, including an already-prepared old proof; policy,
exact-request and groundness refusals; disabled-space cancellation; and refusal
to restore cancelled bytes. Additional cases cover interrupted initial selectors,
late activation after owner failure, and explicit lifecycle recovery when an
uncertain custody write never arrives. Deterministic simulator protocol tests
cover late resolve replies and unchanged reconciliation after uncertain stores.

A final [read-only trace of the real owner fixture](owner-poses.log) records body
2 at 2.9983 m after falling from its 3 m baseline, revision 2 at 4.9983 m after
installation at 5 m, and the sleeping body at 0.49993 m on the ground. Its
assertions and observer source are retained in the validation archive.

The final Docker release built with Rust **1.90.0** and passed:

- Packaged native loading, finite falling-body steps/queries and retirement.
- Full embedded Quod application boot with the physics library removed;
  availability is false and the load error remains inspectable.
- The packaged-library benchmark below.

The updated CI image also built locally; its Rust/Cargo 1.90.0 and rebar3 toolchain
were checked. Neither image was pushed or deployed. The runner image must be
published/rebuilt from `deploy/ci/Dockerfile` before using the new Cargo gates.
Native library installation uses an atomic rename: a separate check verifies
that an open old inode retains complete bytes while the replacement gets a new
inode. Native hot-code upgrade is unsupported; restart the release to load it.

## Retained logs

[Validation archive](validation-logs.tar.gz) contains 143 original logs, scripts,
source manifests, exit files and stop markers, including failed and superseded
runs. [Common Test reports](common-test-reports.tar.gz) retains the full report
and case-output trees for campaigns 04 and 06 (444 files), excluding scratch
ontology datastores in `log_private`. Original scratch data was not deleted.
Earlier filenames containing “final” remain unchanged; campaign 06 and
`delivery-context.json` identify the delivered source and images.

[Fable's read-only reports](fable-reviews.txt) are consultative, not approvals.
The parent verified their causal paths and implemented the fixes. Fable explicitly
did not claim to have re-read the last uncertainty/groundness/diagnostic fixes;
those and subsequent build/type fixes were checked by the parent and tests.

Retained failures and their disposition:

- The initial 0.26.1 implementation/measurements were superseded by 0.36.0.
  Campaign 01 was explicitly stopped during EUnit at the latest-version request.
  The initial 0.36 API migration compiler errors and subsequent pass are retained.
- Earlier owner tests exposed result/selection ordering and fixture barriers.
  Collapse tests now retract their blocking gate in committed truth before
  overflow, so recovery does not accidentally reuse a blocked selector.
- Focused final-01 failed on stale cross-fixture status messages and an incorrect
  non-finite-input assumption. Receivers now verify anchor/current owner; the
  native boundary case actually overflows a world AABB and checks quarantine.
- Focused final-07/08 failed in the test signer while formatting named variables.
  It now uses production's canonical variable instantiation; the intended
  signed-ingress cancellation refusal assertions pass.
- Campaign 02 was stopped during EUnit after discovering that a late activation
  could clear unexpected-owner quarantine. The fix and real late-commit regression
  preserve the failed slot across custody/generation-only changes.
- Campaign 03: 3,650 EUnit tests, one failure. The unchanged-I/O test consumed
  unrelated trace messages from EUnit's reused mailbox. A dedicated trace receiver
  fixes attribution while preserving the zero watched-call assertion.
- Campaign 04 passed EUnit, Common Test and xref, then failed Dialyzer: a constant
  false NIF availability stub and two implicitly discarded timer results.
  Availability now reads the module-load result; discarding timer results is
  explicit. The direct Dialyzer fix check and complete campaign 06 pass.
- Campaign 05 was stopped during EUnit for atomic native-library installation,
  preventing a recompile from truncating a library mapped by a running BEAM.
- The first shared regression run hit sandbox UDP `eperm`; the separately labeled
  network-enabled run passed all 79 tests, subsequently covered by the full gates.
- The first packaged smoke omitted its boot-file path. The later final-06 smoke
  explicitly reloaded a NIF already loaded by embedded boot and received
  “Upgrade not supported.” Final-07 uses `ensure_loaded` and passes. These were
  smoke-command defects; their logs and loader diagnosis remain retained.
- Early cost runs include an overlap with tests and a missing `/usr/bin/time`.
  They are retained and do not certify the final measurements.

## Packaged native measurements

[Packaged cost log](rapier-0.36.0-packaged-costs.log) is the primary measurement.
It runs [quod_physics_bench.erl](../../../test/quod_physics_bench.erl) against the
final image's library, with **two normal and two dirty CPU schedulers**. The
benchmark beam is mounted read-only; no test/build campaign overlaps it.
The exact Docker command is `quod-physics-docker-bench-06.sh` in the archive.

Host: Intel i7-9700K, 8 physical cores, Linux x86_64 7.2.8. Image: Rust/Cargo
1.90.0, Erlang/OTP 28 with ERTS 16.4.0.2, release native build with
`solver-bounds-checks`. CPU frequency is not locked. These are observations,
not service-level guarantees or universal allocation/destructor bounds.

Each serial case makes 500 fixed calls and queries after each. The 2/64/256-body
cases have **34/34/39 active integrations**; the later idle calls are reported
separately. P99 is therefore the maximum for these small active samples.
Queries copy all poses and active solver-contact candidates. The production
owner stops calling the engine when asleep; idle-call timings only characterize
the adapter. Every case has zero joints and chunks.

Observed active step plus sample p50/p95/max, in microseconds:

- 2 bodies: **13 / 38 / 100**; query p95 **6**.
- 64 bodies: **379 / 534 / 1574**; query p95 **88**.
- 256 bodies: **1958 / 2426 / 8075**; query p95 **258**.

Twenty steps of 64 overlapping cuboids reached 2,016 contact pairs and **6.992 ms**
maximum step/sample cost. That stress case grants more output contacts than the
fixture's 256; the fixture would fail visibly instead of publishing excess output.
Pair work/memory can grow quadratically before that output check.

Four simultaneous 64-body worlds measured step p95 **353–449 µs**. The normal
scheduler ping probe measured p95 **2 µs**, p99 **5 µs**, maximum **124 µs** over
32,885 samples. Serial/concurrent and run-to-run differences include warm-up,
frequency and runtime effects; they are not controlled speedup comparisons.

Explicit destruction took **42/149/557 µs**. Killing the sole owner of a populated
256-body resource through receipt of DOWN took **228 µs** in one observation;
that notification latency is not an independent measurement of final native
resource destruction. RSS was 60,220 KiB after the first world, 68,876 KiB after
the serial 256-body case, and 72,452 KiB during the concurrent case. RSS includes
BEAM heaps, code, allocator caches and copied terms; it is not precise per-world
native allocation accounting. Policy must budget aggregate worlds and pair work.

The [host Rust 1.99 measurement](rapier-0.36.0-final-costs.log),
[earlier bounds-checks measurement](rapier-0.36.0-bounds-costs.log) and
[earlier 0.36 measurement](rapier-0.36.0-costs.log) remain available separately.
The latter predates enabling solver bounds checks.

## Dependency audit and scope

Rapier is pinned to **0.36.0**, verified as the latest stable crate on 2026-10-05
using Cargo's registry and the
[upstream changelog](https://github.com/dimforge/rapier/blob/master/CHANGELOG.md).
Rustler is pinned to 0.36.2; Cargo.lock fixes transitive versions.

[Captured RustSec matches](rustsec-20261005.json) use database commit
`ef6173cbc5c50ec8166f9a5b28f07834144373ee`. Every locked package name was checked
against advisory files and affected/patched ranges reviewed. All 12 matches
are patched at the locked versions. This is a dated package/range review, not a
`cargo audit` invocation or proof that unknown vulnerabilities do not exist.
The 0.36 graph removes the earlier unmaintained `paste` dependency.

BBSvx was inspected at `002b92100ac4abd1c14bbddc251c07217fc84138`. Its ordinary
locked NIF calls, unbounded bulk/event output and continuously stepped/broadcast
sleeping worlds were not reused. The audit retains the recorded
[NIF/port decision](../../outdated/client-world-direction.md#81-engine-direction)
for this policy-admitted cuboid profile. Native abort, OOM and undefined behavior
remain uncontainable in-process; isolation or unacceptable target-load cost
requires the supervised-port fallback before enabling that profile.

Production paths add 1,008 and remove 10 lines, including 26 Rust unit-test lines
and the native manifest. Excluding those unit tests gives **982 added, 10 removed,
net +972 production lines**. Lockfile, docs, Erlang tests and top-level/CI build
configuration are excluded from that count. The full non-document/non-lockfile
net delta is +1,893 lines. Growth supplies the new adapter, one simulator owner,
Prolog activation/cancellation and existing-runtime integration; no second domain
executor, broker or durable outbox was introduced.
