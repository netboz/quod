# L2 slice 7 — canonical claim and inclusion vectors, clean format break

This implements the approved slices 6–8 contract's slice-7 invariants 1–6,
with the relayed C2, receipt-evidence and intermediate-admission rulings.
Multi-ontology writes are a primary workload. This slice prepares their common
representation; it does not enable independent N-target execution or claim a
performance improvement. Yan's write-lanes plan and figures are unchanged.

## Representation and authority

One metadata-only source claim carries the canonical exact anchored writer
bundle set and predicted application references. The source's own writes, if
any, belong to its ordinary target bundle, never to the claim's facts, reads
or effects. N=1 uses the same representation, constructors and selectors.
Targets authenticate and select their own anchored plan before materializing
its vocabulary. Request, manifest, attestation and predicted identities must
agree; certificate signature subsets and acceleration evidence do not choose
semantic transaction IDs.

A receipt is the canonical complete vector `{Target, {included, ApplicationRef}}`.
It persists no committed/rejected verdict. Inclusion is not an execution
verdict. Exact evidence and projection/replay require the same complete set;
duplicates, omissions, extras and replacement rows are refused. A terminal
source receipt does not substitute for the target's verified result.
Slice 8 adds the certified-verdict arm within this format and restricts new
receipts to it by validation policy; included-kind historical rows remain valid
bytes of that single format. Its verdict-evidence design needs its own ruling;
f+1 current-view lookup is not exact historical verdict evidence.

The proof planner still returns typed lane-unavailable for L2. Independently,
`validate_content_transactions` refuses N>1 source claims with
`independent_lane_unavailable`, and the operation worker refuses N-vectors
before choosing a target. These are the required intermediate availability
boundaries, not permanent N=1 implementations or permission to fall back to L3.
Slice 8 must cryptographically justify surviving independent intent from the
original signed goal before enabling dispatch. A peer-supplied Boolean is not
that authority.

## One clean break, no compatibility arm

| Carrier | New format | Old bytes |
| --- | --- | --- |
| Transaction envelope / semantic ID | V14 / ID domain version 7 | V13 not decoded |
| Local and foreign-cache ledger segments | V6, `0x915106AF` | V5 named superseded format, including short tails |
| Signing journal | QSJ4, record 4 | QSJ3 refused by name |
| Effect journal | QEJ2, snapshot 7, row 6 | QEJ1 refused by name before stored submission decoding |
| Foreign cache identity/checkpoint metadata | version 3 | old derived metadata cannot admit pre-break ledger bytes |
| Outcome index | format 7 | derived vectors rebuilt in the new era |
| DTX phase scratch certificate carrier | tagged version 1 | untagged rows refused, no old-session import |

Endpoint vocabulary changes with the envelope in this same scope. Identity
files and node-actor pointers are not transaction-byte stores and do not change.
The effect journal is the additional canonical-envelope carrier found by the
audit; the cache/checkpoint/phase index also carry derived or certificate data.
No legacy writer, decoder, ledger rewrite or migration is supplied.

Deployment is a separate decision requiring Yan's explicit full-fleet wipe
authorization. No such authorization exists. Old ledgers must fail closed;
empty stores must found cleanly. Frozen evidence and STOP markers survive and
must never be treated as data to wipe. Post-wipe measurements require a fresh
label; the historical +8.7% question remains unresolved, not fixed by a reset.

## Controls and explicit deferral

Permanent tests cover N=1/2/4 canonical sets and predictions; local target
metadata/application separation; anchored bundle/request/attestation refusal;
target policy apply/reject with real hand-built quorum certificates; valid
certificate-subset identity invariance; full reference-only receipts and
monotone outcome-index reopen; validator and real-worker availability refusals.
Hand-built N-target claims are **not consensus-admitted**. Certificates in
shape-only codec fixtures are labeled as such, not counted as finality checks.
Existing read-certificate/OCC and effect-custody tests retain their assertions.

**L2-S8-DEFERRED-7.4-ADMITTED-PARTIAL-OUTCOME:** the end-to-end admitted N>1
partial-outcome witness is carried to slice 8 by explicit ruling. There it must
show one target's certified rejection with committed siblings after the signed
intent authority seam exists. No fake admission or test-only bypass is allowed.
Slice-7 target-validator/reference/monotone-vector controls are not deferred.

Control 7.5 uses hash-pinned real V5/QSJ3 ledgers and a real QEJ1 journal:
old code accepts them, new code refuses their formats by name without modifying
them; fresh new stores and a real founded N=1 vector operation work. Named
structural fail-before controls, exact source hashes and full child exits are
retained in the implementation handoff, not inferred from passing exit codes.

A's absolute deadlines and route-neutral evidence, failure-residency, B's
owner span discipline, C/R apply ordering and all ordinary target validation
remain. No new owner, timer, queue, lock or execution fast-path is introduced.
R-RESTART-RACE-01 and both EUnit ledger items remain open. Full clean sequential
gates and Claude's exact-tree review are required before any slice-7 commit.
