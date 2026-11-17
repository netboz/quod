# Consolidated owner and verification map

All changes below are unapplied proposals. This is a review artifact under the existing Stage2 plan, not a new tracker or master plan.

| Shared owner | Proposed correction | Obligations and affected verification |
|---|---|---|
| Quorum; committee predicates; Simplex; journal; foreign history; DTX current view/coordinator | Remove committee64 and derived route/map ceilings. Preserve distinct32-byte members, endpoint types, canonical sorted signatures, actual N-based consensus and exact f+1. Remove bounded-hint eviction state/metric. |65-member signed quorum and wrong-domain/duplicate/extra honest rows; authored can_join denial/readiness; current/history membership equivalence; persisted admissions and routes; hostile discovery hints never gain a vote. Existing committee/crypto suites retain these obligations. |
| Ingress state and atomic admission, Simplex collectors | Remove512 pending, per-author64 and derived byte refusal. Keep queue ordering/byte accounting, duplicate group/token refusal, pinned custody, membership serialization and event-driven wake keys. Encoding failure is invalid material, never a fabricated large size; custody retains uncertain work. Remove obsolete overflow metric/state. | Counter baseline is pure-owner only. Real distinct signed65+ admissions, cancellation/expiry, no duplicate enrollment, retained journal recovery, FIFO, membership barrier, malformed local rejection vs custody parking, unchanged fingerprints and real update wake. Existing ingress/atomic projection suites must replace quota-only assertions. |
| Catchup → link credit lifecycle → foreign verified cache/projection | Remove256/900KiB policies; retain cursor/lookahead and complete frame-capacity accounting, no history aggregation into one frame. Preserve exact namespace/height/continuation and original deadline. Local borrowed view uses same owner without a network envelope. | Full catalogue of entries/complete groups and multi-page witness with actual cursor continuation; exact capacity arithmetic; wrong/stale grant/token/owner; cancellation while reader retained; tampered proof/signature/parent binding; current-source withdrawal.54 arithmetic cases passed against unchanged codecs. Revised cursor code is not executed yet. |
| Foreign cache byte owner | Reserve actual group bytes and exact encoded manifest/checkpoint metadata; remove estimated page padding. Decode canonical wrapped metadata without the page subquota. Retire estimated follow_pages; preserve actual entries/bytes. | Fault injection at reservation/append/sync/checkpoint, no replay after uncertain write, exact cache accounting/reopen, unchanged cache no writes/rebuild, actual update installed. Existing persistence/foreign residency tests retain this coverage. |
| Ledger store framing | Remove arbitrary64MiB reader cap. Preserve uint32 writer representability, CRC, magic, complete group boundaries, torn-tail rules. Pre-read is bounded by actual file extent rather than a fabricated safety number. Read chunk/index cadence remains an implementation granularity, not admission. | Large valid archive frame; tiny corrupt file advertising huge length produces short/corrupt result without allocating missing bytes; historical format refusal; writer width overflow; exact snapshot/reopen. No archive migration is performed. |
| Wire materialization/client authentication | Retire512 per-material vocabulary,16384 built-in cumulative quota and100000 reserve. Count newly allocated names against actual VM capacity; preserve explicit finite overrides/rates and opaque ordinary arguments. |513 valid callables; no argument atom creation; existing atom reuse; finite configured refusal and rate denial; malformed/unrepresentable atom names distinct from capacity. Do not exhaust the VM atom table to test it. Precheck is not atomic against other allocators. |
| Direct effect and transaction/DTX codecs | Remove2KiB payload quota, keep singleton descriptor/plan operation semantics and executor/actor/target binding. No new founding lifecycle. | Effect04 baseline isolates quota with canonical actor/short namespaces. Test legitimate large actor, signed plan/transaction context, invalid/duplicate effects, wrong executor and original recovery. |
| Pinned Erlog + Quod diagnostic wire/scope/ontology | Remove duplicated reason/count/boundary quotas through current callback and portable canonical codecs. Preserve explicit finite callback, truncation marker when that callback refuses, variable/runtime-term rejection. Dead count/boundary record fields and Quod resets are retired together; the new dependency requires a coordinated rebuild. |257+ real reasons, large single reason/full stack, finite callback refusal, malformed/nonportable reason, source-bound failure propagation/cancellation. Exact dependency patch must become a reviewed pinned revision; no cache fork. |
| Namespace lifecycle/directory/client/scope/storage | Conditional admission patch distinguishes actual signed/channel widths. Concrete shared hash-key, old-layout refusal, two-root preflight and existing ETS-name correction are prepared; deployment/cutover remains separately authorized. | See NAMESPACE-DECISION.md. No quota-only claim of delivered namespace support. |

The historical reference inventory remains literal in `inputs/legacy-test-retirement.json`.
The final patches contain concrete replacements, not merely this map. Quota-only
expectations now require complete values; malformed/compressed/trailing input,
crypto/canonical identity, FIFO/custody, denial and explicit finite-policy checks
remain. See RESULTS for exact cursor and same-event fixed-point replacements.
TEST-only small framing allowances exercise the actual retained cursor and
endpoint owner, not a second producer. Production and test overlay compile
receipts and exact source hashes are distinct from runtime acceptance.

Authentication challenge/session defaults and the opening-link outbox are also
in the consolidated patch. Finite explicit auth options/rates, expiry, single-use
challenge consumption and deduplicated exact frames remain with their existing
owners. Namespace tests cover no-write old-layout refusal across separate roots,
stopped lookup, current foreign manifests, large exact names and the signed
uint16 mirrors. Optional heap accounting and remaining configured worker-pool
policy are not silently included.

`proposals/remaining_admission_checks.erl` is also included as the concrete
`quod_remaining_admission_tests` repository test patch. No proposed test was run.
The next authorized execution must preserve full exits/EOF and original failure
labels and target affected owners; no completed D5/form/entry suites need another
green run. Original aggregate30s renewal acceptance remains open.
