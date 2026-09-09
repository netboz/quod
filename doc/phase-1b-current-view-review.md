# Phase 1B — current-view work and freshness review

**Status: direction and all three detailed cut contracts approved;
Cut 1 independently reviewed and committed (`e4ad3e1`, 0.7.153);
Cut 2 independently reviewed SAFE TO COMMIT, with all gates reproduced green.
Cut 3 remains gated.**
Source baseline: `d48cd89` on `claude/next`, deployed 0.7.152. Phase 1A's
source and hardware reviews are closed; its absolute latency gate is not.
This document proposes an alternative to weakening identity freshness:
remove repeated execution work inside the existing verifier while retaining
its authentication contract. Claude explicitly approved that direction and
early exit for final confirmation only. The completed pull transitions and
shared consensus-facing codec/store contract are now in
[the approved contract](phase-1b-codec-and-pull-contract.md). Each cut still
requires authorization, fresh sequential gates and review before commit.
Broader response reuse and the historical-committee shortcut
remain unapproved and rejected, respectively.

## 1. Accepted evidence and the actual call path

[Phase-1A hardware results](phase-1a-hardware-results.md) owns the approved
numbers, topology, incidents and archive. Each row below includes all 100
requests; all 400 writes committed. Times are milliseconds.

| Path | Concurrency | Mean | p50 | p99 |
|---|---:|---:|---:|---:|
| Local | 1 | 55.79 | 55 | 80 |
| Local | 4 | 78.59 | 78 | 89 |
| One-hop | 1 | 544.16 | 544 | 665 |
| One-hop | 4 | 1558.56 | 1609 | 1797 |

There are zero index-scan spans in all 200 one-hop traces. Per-request means
explain 99.756% / 99.901% of server time. This identifies the containing
owners, not every function inside them. Flat behavior through 10,000 entries
has not been measured.

All 200 `quod.foreign.current` spans run on **target node 2**, verifying
**quod:trace152-source** while authenticating a newly opened remote scope:

    source proof → target scope authentication
                 → existing foreign.current(source identity)
                 → verify the agent certificate against that committee
                 → target's ordinary ACL and proof

The decisive source chain is `quod_prolog:verify_scope_authentication` →
`verify_scope_agent_identity` → `local_or_foreign_agent_view/5`. The separate
`quod_ask:verified_plain_read_routes/3` filter is bypassed for these execute
requests. Optimizing that plain-read filter would not fix this benchmark.
Source-side identity-signature collection is about 4 ms in inspected serial
traces; the expensive operation is target-side committee verification.

| Diagnostic quantity | c1 | c4 |
|---|---:|---:|
| foreign.current mean per request | 281.837 | 1045.506 |
| Observed shared verification workers | 99 | 24 |
| Verification-worker mean per worker | 284.32 | 1101.35 |
| Page verification mean per worker | 46.56 | 236.18 |
| Foreign ledger append mean per worker | 18.21 | 63.49 |
| Tip confirmation mean per worker | 83.75 | 275.09 |
| Worker time outside the union of named direct children | 133.31 | 520.78 |

These are nested diagnostics, **not additive to request latency**. In
particular, one shared worker can serve several callers: 24 workers do not
mean 24 requests. The suffixes have 1–3 entries at c1 and 1–5 at c4. Existing
resident sessions already resume the verified prefix; there is no replay to
remove here. Nor does initial worker admission explain the staircase: the
caller-side owner-request entry to worker-start interval averages about
0.161 / 0.938 ms. This is a scheduling proxy including message/owner handling,
not a separate queue gauge; later owner-mailbox decoding is a different wait.
The residual row includes acquisition, decoding and intervening work; it is
not a measurement of network latency or of any one function.

Raw evidence: `/tmp/quod-a1a4-152/onehop-{c1,c4}-n100/traces/`, their TSVs
and manifests, and the original archive named in the hardware report. The
follow-up offline audit is `/tmp/quod-a1a4-152-phase1b-analysis/`. It is not a
new workload or replacement baseline.

## 2. Source-confirmed repeated work

This table records the `d48cd89` / 0.7.152 diagnosis, not present-tense claims
about the working tree. Committed Cut 1 removes its first row's owner-side
decoder; the Cut-2 implementation addresses the three entry-consumer rows.
The last row belongs to still-gated Cut 3. New page spans
separate wait, decode and local completion; no new hardware saving is claimed.

| Owner/seam | Baseline work | Disposition |
|---|---|---|
| foreign_log `accept_live_page_result/7` | decodes all entry blobs synchronously in the node-wide gen_server | move interpretation to existing requesting verification/probe workers; retain correlation and lifecycle in the owner |
| catchup `page_stats/1` | calls `ledger:encode_entry/1` to count bytes | count carried canonical entry bytes, after the existing ingress bounds check |
| baseline ledger `block_from_entry_view/1`, transaction `encode_ledger_transaction/1` | decode/re-encode record views and verify transaction signatures during encoding | Cut 2 removes consumer reconstruction via canonical artifacts; transaction encoder and forward-verifier validation remain unchanged |
| ledger_store `append/2` | calls the checked entry encoder again after history verification | persist the same verified canonical artifact; preserve contiguous-index checks, framing and sync |
| foreign_log `probe_pages` → advance → `current_committee_confirmed` | one-entry probes, then suffix fetch, then tip probes; both probe rounds wait for all replies | first remove unnecessary all-reply waiting where the unchanged acceptance predicate is already satisfied; broader response reuse needs the proof in §5 |

For N=4, the ordinary changed-head shape is 4 + 1 + 4 page requests per
worker. One-entry probing deliberately limits fan-out byte retention; replacing
it with four full pages is not automatically an improvement. Encoding accounts
for about 8.87 / 53.84 ms per foreign append worker before its storage sync.
Baseline traces do not isolate owner-side decode, every probe, or the time
waiting for replies after a sufficient quorum: add that granularity at these
existing seams before claiming their millisecond savings.

These are source-confirmed execution patterns, not proof that each explains
the measured c4 increase. Do not promise a 120 ms result by subtracting nested
spans or deleting a security check.

## 3. Security contract: retain, do not substitute

Unchanged authority: exact genesis-anchored history, slot-era verification,
current committee derived by the existing certified projection, existing
quorum threshold, and the existing proof/request/expiry-bound agent
certificate. Directory contacts and height wakes remain reachability and
progress signals, never committee evidence. Target ACL remains the only
policy deciding whether this goal may run. No agent-ledger OCC read or extra
consensus step is reintroduced into the caller's transaction.

Two different adversarial obligations must not be conflated:

1. **Known replacement:** the receiver has verified a replacement committee.
   A fresh request signed by the old committee must fail, even with a future
   expiry. `fully_replaced_committee_cannot_authorize_fresh_request_test`
   pins this. Its own comment correctly says it supplies the two views; it
   is not a live discovery test. Its old-view positive control accepts the
   otherwise genuine old signatures.
2. **Concealed replacement:** the receiver knows only an earlier prefix and
   a fully retired signing quorum retains usable keys and conceals everything
   newer. An old-era certificate does not reveal the replacement. Neither
   does the name `current/4` constitute an independent freshness oracle:
   `current_view_confirmed` derives the committee from verified history and
   asks those members to corroborate height. A stronger guarantee needs an
   explicit fault/trust premise; it cannot be obtained by renaming a cache
   or adding a nonce/expiry to the same old signatures.

The second observation is a conditional indistinguishability argument, not
a claim that the deployed protocol newly violates its stated model. The
[finality plan §4.3](finality-round-recovery-plan.md) explicitly assumes
per-era fault bounds and excludes long-range forgery after historical-quorum
key compromise. Review must distinguish honest retired peers, faults within
that model, and an adversary controlling a whole old quorum. This proposal
adds no guarantee for the last case and weakens none of the current checks.

“Forward-secure signatures” alone are not a completed redesign. Their usual
property protects past periods after exposure of an evolved current secret;
it does not stop use of an explicitly retained old secret. A design depending
on erasure or authenticated period selection must specify and justify both.
See the original [Bellare–Miner paper](https://doi.org/10.1007/3-540-48405-1_28).
As a comparison, not a proposed dependency, the
[CometBFT light-client specification](https://github.com/cometbft/cometbft/blob/main/spec/light-client/README.md)
makes trusted initialization and freshness assumptions explicit. Do not import
a trusted checkpoint, root-owned era registry or clock authority into Quod
without a separate architecture decision.

**Direction decision:** Claude approved removing the execution duplication in
§4 while preserving the existing current-view rule exactly. This is not
approval of a replacement cryptographic contract. The producer/consumer
contracts have since been approved separately; implementation authority and
review-before-commit remain required.

## 4. Cut 1: coordination separate from interpretation (review closed)

### 4.1 Keep lifecycle at the existing owner

`quod_foreign_log` continues to own shared work, callers, exact link/producer
bindings, grants, request IDs, original absolute deadlines and cancellation.
The existing worker which requested a page performs its wrapped decode and
verification. No new process family, worker pool, broker or cache.

Moving the decode is not permission to acknowledge malformed pages early.
The request row must remain correlated until its worker reports page-decode
success/failure; reserve the received successor grant until the same page-level
terminal transition that currently releases it. This means the relocated
decode/canonicality boundary, **not** the end of forward history verification
or the whole current-view request. Complete this local page handoff before
requesting another page: retaining credit until the whole verifier finishes
would block its own next page or same-link confirmation. It adds no wire ACK;
verified-history publication still has its separate verification/durability
gate. A decode result after deadline, worker death, cancellation or link
replacement cannot publish a page or release a
replacement link's credit. Malformed content retains the existing typed
failure and exact-link cancellation. **Worker death during decode closes the
exact old link through `cancel_pull_owned`; it never installs the reserved
successor credit.** The tagged puller monitor remains live through decoding.
The [complete transition table](phase-1b-codec-and-pull-contract.md#13-complete-transition-table)
pins raw-reply consumption, exact-PID decode acknowledgment, expiry and late
verdicts, retirement and unsent-row reconstruction. Claude approved it with
the explicit binding re-check, nullable reply type and error-response test
now included. Simply returning raw blobs and completing the row is insufficient.

### 4.2 Carry bytes through the one verification path

Extend the existing prepared-page value from `prepare_verified_page` to carry
the canonical entry artifacts used to derive its verified entries, projection
and phase delta. This is request-owned data, not a new resident result cache.
The decoder/constructor checks bytes and their view at the boundary; the
existing forward verifier still checks ancestry, certificates, signatures,
membership eras and semantic admission. Metadata used by append must derive
from those same artifacts, never from an independently supplied record.

Size accounting and durable framing must consume those exact bytes without
re-running authentication just to measure or serialize them. Public/untrusted
record constructors retain their validation; an opaque Erlang type or a
caller-supplied `verified = true` is not a security boundary. Specify the
actual producer/consumer contract before removing any check. No `skip_verify`
flag, permissive raw append, alternate decoder or parallel store API is an
acceptable substitute. This **is consensus-facing by construction**: Simplex
uses the same `append/2` as foreign history. The
[shared artifact contract](phase-1b-codec-and-pull-contract.md#2-shared-canonical-artifact-contract)
specifies the sole codec-owned constructors, decoder, byte/view accessors,
artifact-only append and all producer/consumer migrations. Proposal/signing
APIs stay unchanged; no foreign-only exception or wire/ledger/certificate
format change is proposed. The persistence audit identified the native
prepared-genesis entry inside the effect journal: the contract explicitly
preserves its existing stored bytes and effect hash, with checked import on
activation and no fresh-genesis fallback for malformed prepared data.

### 4.3 Preserve proof and storage lifetimes

The [roadmap §3.5](performance-roadmap.md) backtracking contract is unchanged:
ledger sessions are bounded byte views, MVCC bases are pinned proof snapshots,
and overlays/choicepoints remain in the existing proof engine. A later head
must not reopen an existing scope on redo, `next`, cut or rollback. Certificates
still authenticate a new scope before any target proof executes; later claim
validation cannot retroactively authorize an earlier read.

Borrowed source PID/identity/session binding, source-death cleanup, durable
append then phase/checkpoint publication, wrapped foreign symbols, historical
exact-reference verification and consume-once wake permission stay intact.
No change to Q4 feed semantics, operation resubmission, result authentication,
finality, L2, recovery commitments or compaction. No full-open fallback.

## 5. Final-confirmation direction approved; broader reuse unapproved

For `current_committee_confirmed` specifically, an event-driven quorum
collector can stop after the unchanged confirmation predicate has enough
distinct current-committee successes, or after success is impossible.
**Do not apply this stopping condition to initial `probe_pages`:** its
`advance_snapshot` consumer chooses the maximum returned height, so early
completion there is not automatically equivalent. Generalize the existing
collector's completion condition rather than changing all of its callers.
It must cancel/drain remaining existing probe workers and their
page requests without cancelling unrelated shared callers. A slow fourth peer
must not delay three already-valid confirmed responses at N=4; an old-committee response
must never count after the verified suffix changes the committee. Keep one
collector abstraction, not a second implementation for the optimized case.
Claude confirmed the final-confirmation predicate is monotone for that fixed
post-advance committee. The [collector contract](phase-1b-codec-and-pull-contract.md#3-final-confirmation-collector-contract)
pins distinct-peer counting, impossibility and monitor-driven cancellation.

Broader probe/suffix/confirmation reuse is a **candidate, not an approved
one-wave contract**. The current reply carries blobs and a captured height,
bound to a peer/link/request/range; it does not attest an exact common head
hash or era. In particular, the initial probe at H+1 is not automatically
equivalent to a confirmation issued after verifying a longer suffix.

Before reusing such a response, prove exactly which bytes/range and captured
height satisfy the existing post-verification predicate, at which observation
cut. Cover mixed heights, truncated pages, a membership change inside the
suffix, a dishonest height claim and replies from the superseded committee.
Otherwise retain the necessary later query through the same owner. Do not
advertise generic one-wave verification; discovery and committee changes can
require further messages. Any required new head binding is a separately
reviewed wire contract, not something the current grammar already provides.

## 6. Implementation and measurement gates, after Yan's go

1. **Owner-decode cut:** relocate interpretation with the exact lifecycle in
   §4.1 and nested tracing at decode, owner handling and page delivery. Prove
   another identity's ready request progresses while one worker's decoder is
   deliberately held. No production sleeps or extra workers.
2. **Canonical-artifact cut:** implement the reviewed shared contract and delete
   redundant size/storage re-encoding at the replaced call sites. Trace tests
   count decodes, signature checks and encodes with positive controls. They
   must fail before the change and demonstrate removal, not just faster code.
3. **Probe cut:** §5's final-confirmation contract is reviewed; implement its
   distinct-peer and cleanup tests, then return the code for review.
   Initial collect-all is untouched. Broader response reuse is not part of
   any of these cuts and requires its own accepted equivalence argument.

Each cut independently passes sequential EUnit, ask CT, QUIC CT, xref,
dialyzer and diff-check. Consensus/DTX/signing-journal changes require review
before commit. No implementation starts on the strength of this proposal.

Mandatory negative/lifecycle coverage across the affected cuts:

- malformed canonical bytes, invalid transaction signature, view/byte mismatch,
  wrong anchor, wrong historical era and fabricated committee transition;
- worker/link/source death, queued and in-flight expiry, late result, duplicate
  result, exact-link cancellation and unrelated shared-caller survival;
- immediate worker DOWN after raw delivery but before decode acknowledgment:
  exact-link close, reserved credit discarded, unsent sibling preserved;
- zero foreign atoms, bounded page/count accounting and immutable snapshot
  behavior across concurrent append/backtracking;
- N=4 quorum with one silent peer; insufficient quorum; mixed eras and heights;
  existing retired-committee/fresh-request negative unchanged;
- duplicate peer candidates/results cannot count twice; three fast confirmations
  finish while the fourth remains held, and impossibility returns promptly;
  canceled in-flight pulls are reaped while the enclosing current request is
  still pending, so whole-request cleanup cannot conceal a broken pull monitor;
- exact persisted/transmitted bytes unchanged and no new live full-open site;
  AST inventory and replay-positive-control tests remain green.

Then measure the same N=4 fixture shape, local/one-hop c1/c4 n≥100, all failures
included and no resubmission. Keep 0.7.152 as its own baseline; account for
fixture height, resident/background state and trace overhead. Add sufficient
worker/probe detail to explain ≥95% of per-worker elapsed means before blaming
the residual on network or mailbox work. Do not double-count shared workers
as per-request costs. The absolute targets remain targets, not predictions;
10,000-entry and c4 hardware closure are still owed.

## 7. Documentation and deletion closure

On approved implementation, update the foreign-log ownership/comment contract,
catch-up decode/size contract, ledger artifact/store contract, and the anatomy
with measured results. Remove superseded decode/encode call sites, collector
branches and metrics only when their replacements are verified. Preserve the
one public failure vocabulary and the A1–A4 lifecycle regressions. Do not edit
Yan's write-lanes document or four SVGs.

This review changes only the hardware-review status, roadmap pointers and this
proposal. It introduces no production behavior and claims no new workload
result or security theorem.
