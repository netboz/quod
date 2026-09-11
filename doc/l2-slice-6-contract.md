# L2 slice 6 — explicit independent-write intent

Implementation of the reviewed September 11, 2026 C1 clarification. This
records that ruling without editing Yan's write-lanes plan or the frozen
overnight slices-6–8 draft. The objective remains faster common multi-ontology
writes; this slice establishes safe selection, not the parallel commit path
or a measured performance improvement.

## Approved semantics

Changes stage in the existing proof/session temporary store. Ordinary logical
backtracking retains changes. Only the selected whole-goal success seals and
submits them; whole-proof failure before durable handoff commits nothing.
`transaction/1` keeps its existing explicit savepoint semantics. A Prolog cut
is not a durable commit boundary. Unwrapped multi-ontology writes remain atomic.

`independent(Goal)` opts into independent target outcomes only when its intent
survives on the selected successful answer. The intent follows bindings across
backtracking, cuts and exceptions; it is not a sticky process flag. Sequential
successful wrappers merge. Nested independent wrappers, independent inside
transaction, and transaction inside independent are errors, including selected
and reentrant ontologies. Every explicit wrapper requires the original verified
signed request, uniformly for zero, one and multiple writers.

Provenance belongs to staged material, including retained material from failed
branches. It may veto an independent route, never restore discarded successful
intent or refuse the ordinary atomic default because of provenance. All
retained fact operations, events and effects are checked at sealing. Completely
cancelled facts do not contribute; an associated retained event or effect still
does. Read dependencies retain their existing rules. No normalization or rollback
of ordinary staged writes is added.

| Selected successful intent | Retained write provenance | Result |
| --- | --- | --- |
| ordinary | any, including mixed wrapped and ordinary residue | Existing lane by writer count (F1 stays atomic for multiple writers) |
| independent | independent only, or no writes | Independent choice; zero/one writer uses the existing read/single-target path |
| independent | mixed ordinary and independent material | `independent_mixed_writes`, before dispatch |
| independent | ordinary material | `independent_mixed_writes`, before dispatch |

F1: failed wrapped writes followed by ordinary success retain their changes but
not their intent, so multiple writers use L3. This includes a fallback that
stages ordinary writes alongside wrapped residue: adding a wrapper to a failed
branch must not turn an otherwise committing ordinary proof into a refusal.
Rejecting either form of F1 is too strict.
F2: ordinary failed-branch residue plus a successful wrapped write is mixed and
refused. F3: wrapped failed-branch residue plus a successful wrapped write selects
L2. Until slice 8, two or more independent writers return
`independent_lane_unavailable`; there is no silent atomic fallback.

## Implementation boundaries

The successful marker is a private Erlog binding keyed by an existing overlay's
unforgeable reference. Active wrapper mode belongs to each invocation. Rebasing
shared staged state preserves the receiving invocation's mode; a new invocation
does not inherit another invocation's selected answer. Descendant answer intent
joins the caller's binding trail before execution continues. Cursor acceptance
uses only the accepted answer's intent.

Fact-operation provenance is stored with existing temporary functor rows;
events and prepared effects carry their own marks. Sealing reduces only retained
material to a two-bit ordinary/independent mask. The existing origin owner combines
scope masks before routing, attestation, claims, application or effect dispatch.
No new database, owner, timer, queue, rollback mechanism or durable tracking is
introduced. No caller deadline or evidence-resolver budget is extended.

The current scope wire changes from version 11 to 12, strictly and without a
legacy decoder. Existing invocation selections carry active mode; successful
answers carry selected intent; seals carry the provenance mask. Nested-controller
events carry their actual validated invocation selection instead of discarding it.
Actor, lineage, target, authentication, size and deadline checks remain in place.
These fields are transient execution metadata, not a new signed ledger format.
Durable plans, transactions, journals and signatures retain their existing bytes.

The existing owner-only callable-symbol walk recognizes `independent/1` as
containing a goal. It still stops at foreign selection boundaries and leaves
ordinary data opaque. Closed scope and client error vocabularies carry the four
named independent refusals rather than flattening them into an unavailable proof.

## Review and remaining slices

Required review evidence includes local binding/provenance controls; real founded
co-hosted signed proofs; real QUIC nodes and signed ingress; cursor acceptance;
remote/reentrant nesting; cancelled facts with retained events/effects; exact
error propagation; deliberate-bug controls including over-strict F1 refusal;
and the full clean sequential gate suite with full logs and true exits.
Exact-tree review is required before committing this slice.

Slice 7 generalizes claims and makes the reviewed clean durable-format break;
there is no legacy read decoder. Slice 8 supplies parallel target dispatch and
one complete verified outcome vector before asynchronous source receipt. Before
remote intent gains independent-dispatch power, slice 8 must cryptographically
justify it from the original signed goal; a peer-supplied answer boolean is not
sufficient authorization. Neither
is implemented by slice 6. Slice-7 deployment requires separate explicit fleet
wipe authorization and verified identity mounts. No fleet wipe is authorized here.

Keep c4's reproducing state until its separately contracted observation work or
an explicit retirement decision. R-RESTART-RACE-01, the B combined-suite flake,
c4 latency/trace coverage and +8.7% remain open. No standing measurement, health
or performance gate is retired by this correctness slice.
