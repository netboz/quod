# Retained DTX controls: classify before renewing a signature

**2026-09-10 — diagnosis and correction contract independently approved;
scope C implemented and full sequential gates passed. The final tree awaits
implementation review before commit. No hardware or performance closure is claimed.**
Source baseline: `3b58f51`, Quod 0.7.160. This follows question C in the
independently accepted [hardware review](residency-owner-hardware-results.md).
The failure branch predates the residency cut. The experiment below reproduces
its mechanism, not the truncated hardware record's identity.

## 1. Exact cause and evidence boundary

The owner has two different obligations: classify whether a retained phase
still belongs in the committed DTX state, and renew an otherwise live local
control whose signing sequence was overtaken. They execute in the wrong order
during commit. A valid alternative record can complete a group's phase without
matching the locally retained record digest. That leftover is semantically
stale, but signing refresh processes it before readiness retirement does.

Baseline source locations:

| Function | What actually happens |
| --- | --- |
| `quod_simplex:select_dtx_wave/5`, line 9248 | Selects at most one phase transition per group. Its comment explicitly allows different certified-reference proof subsets and promises that the committed transition retires the others. |
| `commit_block/3`, line 9566 | Persists the certified entry; resolves included controls; adopts the new projection; reconciles signing state; only then applies live state. |
| `resolve_committed_dtx_control/5`, line 9762 | Resolves the exact included record digest, not every semantic alternative. This distinction is necessary: an alternative was not itself committed. |
| `reconcile_signing_state_journal/1`, line 10353 | Reconciles durable journal state, then refreshes retained signatures. |
| `refresh_dtx_submission/4`, line 10458 | An own-lane sequence at/below the new committed floor is removed and re-signed without first consulting the new DTX readiness verdict. |
| `sign_and_retain_dtx/7`, line 7200 | Signs and calls the durable journal before installing the renewed row. |
| `retained_placement/1`, line 7188 | Installation sees `stale` and raises `stale_retained_dtx`. |
| `reclassify_retained_row/2`, line 7421 | Already owns normal stale retirement and conflict refusal, but is reached too late in this ordering. |

For non-Begin controls, `quod_signing_journal:record_dtx/2` persists the
anti-equivocation **sequence floor**, not a recoverable copy of that control's
body. The reproduced crash therefore leaves an extra durable floor, not a
new committed Prepare or a stale Prepare body to replay. The exposed floor
must never be rolled back. Begin's separate durable pending-body custody must
continue to use its existing retirement/projection machinery.

Hardware limits remain explicit. The crash state was truncated at 4096 bytes;
the offending hardware phase, GroupId, sequence and slot are unknown. Two
pending replies preceded the crash, so the crash cannot explain all four.
The runtime's later replaying-1302/applied-1304 discrepancy has no traced
missing edge and is a separate open item.

## 2. Reproduced valid schedule

Isolated archive: `/tmp/quod-stale-retained-probe-pJptyT/README.md` and
`stale_retained_probe.erl`. Signed entries, checked projections, ledger files,
journals and individual reports are retained there. No private keys are in
the signed-fixture archive. The Simplex source SHA256 is
`c5d46718eb9a3163dd0f3e5759267f0387748f5705c846b4d42ce58de5a2394a`.
All 1157 original function ASTs are unchanged; one export exposes the existing
relayed-retention seam. Shared source, tests and build output are untouched.

1. Construct real N=4 genesis histories and derive their admissions through
   checked validation. Construct signed Begin records for disjoint G1/G2
   plans (`group_one/1`, `group_two/1`) through ordinary proof fixtures.
2. G1's one Begin entry has two distinct valid 3-of-4 finality proofs. Both
   fully verify; their immutable claims agree. The resulting Prepare records
   P1/P2 have the same group but different record digests. G2's Prepare Q is
   valid and independent.
3. Validator A retains P1 at local sequence 1, then Q at sequence 2. Its real
   selector chooses `[P1_A, Q_A]`.
4. Another validator R receives those exact envelopes and retains P2 in its
   own earlier-sorting, genesis-derived lane. R's real selector chooses
   `[P2_R, Q_A]`. This avoids the invalid shortcut of pretending A's own
   higher-sequence alternative simply outruns its lower one.
5. Certify that selected slot-2 wave over parent 1. Its finality, reference
   chains and checked history fold pass. Append the exact entry after the
   real genesis. Both groups become prepared; A's committed floor is 2.
6. Exact-digest resolution removes Q, not P1. Install the checked projection
   and run the actual signing reconciliation. P1 is stale, but the renewal
   signs sequence 3 and syncs its floor before installation raises.
7. Reopen the journal: floor 3 survives. Read ledger slot 2: its canonical
   committed bytes survive unchanged.

The probe exercises the real commit **transition seams in source order**,
not a complete live `commit_block/3` invocation or network consensus. No
readiness result, projection, signature or journal return is stubbed. Its
schedule is constructive evidence for the mechanism, not attribution of the
specific fleet record.

| Unchanged-source check | Agent run | Main-agent repeat |
| --- | --- | --- |
| Expected diagnostic: crash and durable floor 3 | exit 0 | `root-diagnostic.log`, exit 0 |
| Desired postcondition: no crash, floor remains 2 | exit 1 at `stale_retained_dtx` | `root-desired.log`, exit 1 at the same assertion |
| Only unrelated Q commits: P1 stays ready and renews to 3 | exit 0 | `root-positive.log`, exit 0 |
| Exact P1 and Q commit: both rows drain, floor stays 2 | exit 0 | `root-exact.log`, exit 0 |

The first diagnostic attempt failed in isolated fixture setup because its
module path lacked `priv/ontologies/common_predicates.pl`; it is preserved as
`diagnostic-1.log`. Pointing the isolated code path at existing assets fixed
setup, not production behavior or assertions. These are focused diagnostic
tests, not a fresh full-gate claim.

## 3. Proposed correction at the existing owner

One ordered transition, using the existing readiness classifier:

```text
certified commit -> exact-digest resolution -> adopt committed projection
                 -> existing journal reconciliation
                 -> reclassify retained controls on that projection
                 -> renew signatures only for surviving rows
                 -> existing live apply and pending-Begin notifications
```

Reuse `refresh_retained_readiness` / `reclassify_retained_row`, rather than
adding a second stale/conflict table inside the signing path. The signature
walk must read its row inventory **after** reclassification; an earlier copied
map must not resurrect a retired row. Retain the projection fingerprint so
the subsequent ordinary drive does not repeat an unchanged classification.
Keep `retained_placement(stale)` loud as an invariant; do not catch the crash,
reinterpret it as success, or make the installer silently drop signed work.

Required outcomes:

- Stale rows use existing retirement and its exact waiter result. An
  alternative's commit is not an accepted reference for the retired bytes.
  No synthetic committed response, automatic resubmission or new recovery.
- `{refused, conflict}` uses the existing conflict rejection seam; blocked
  rows remain retained, with their current placement and wake discipline.
- Surviving own-lane rows whose sequence floor advanced still renew. Foreign
  authors retain their original envelopes and existing admission checks.
- Exposed journal floors are monotonic, including across restart. Begin
  retirement removes pending custody through the one existing journal and
  outcome projection; do not move apply-before-notification ordering or emit
  pending-Begin resolution twice.
- Signing, ledger persistence, reference identity, phase validation, consensus
  quorum, selection order and relay rules do not change. There is no format
  break, new lock, owner, timer or grouping exception.

The correction belongs at signing reconciliation's shared retained lifecycle,
not at the benchmark, Prepare-only constructor or certificate decoder. It
must cover all callers of the refresh, including recovery/catch-up, without
inventing a separate restart repair.

### A simple call reorder is not sufficient for pending Begin

The adversarial source pass found an additional ordering obligation in this
proposal, not a second measured fleet diagnosis. Retain a valid pending Begin
G2 while no conflict exists; an older overlapping G1 then commits first.
`dtx_pending_after/2` removes G1 only, and
`reconciled_pending_begins/1` filters by admission, so the first journal
reconciliation can still retain G2. New readiness classifies G2 as
conflict-refused. Calling the current immediate retirement helper here would
send `dtx_group_resolved` **before** `commit_block` reaches `apply_live`.

Therefore refactor the existing retirement seam to return its pending-Begin
transition with its updated state, instead of unconditionally publishing that
transition inside the helper. Commit, skip and catch-up reconciliation combine
these removals with their already-returned `PendingTransition`, deduplicate
exact group bindings, and publish once at their existing post-apply boundary.
Ordinary non-commit retirement completes at its current outer boundary. No
defer flag, extra mailbox queue, process, persistence format or alternate
retirement implementation. Journal removal remains durable; never lower its
floor. Preserve the ordered pending projection updates as well as the final
notification, with a trace of the actual Prolog message order in the regression.

The shared reclassifier must also pass the actual record kind to the existing
refusal adapter: its present hard-coded `prepare` argument cannot label a
refused Begin as Prepare. Reuse the existing phase-specific/public result
grammar, not a new refusal or fake commit. Pin that behavior explicitly in
review; a partial reorder that fixes Prepare but changes Begin publication
order or invents a Prepare response is not the proposed correction.

### Bounded diagnostics, not larger raw state dumps

The eventual implementation must make an invariant failure actionable without
printing the state or key-bearing journal. At the existing retained-owner
boundary include only namespace, group/record digest, phase, committed height,
old/proposed sequence, committed floor and closed readiness classification.
No plan, goal, envelope, signature, private key, raw exception state or metric
label IDs. Normal semantic retirement is not an error; if an impossible stale
installation still occurs it remains a loud error with those bounded details.
Use the existing formatter/sanitizer. Do not globally increase its truncation
limit or add per-entry tracing to unrelated healthy work.

## 4. Implementation and review gates

After contract approval, turn the probe into a permanent production-seam
regression, with its failing old-source control. Add exact waiter assertions:
the included Q gets its committed reference, the stale P1 gets the existing
retirement result, and both are delivered once. Exercise ready, blocked,
conflict-refused and stale rows; preserve the healthy renewal controls.
Use a real journal to pin floor monotonicity and Begin custody/notification
ordering across reopen. Add an integrated commit-path test so the probe's
explicit transition composition cannot conceal a different live ordering.
Name the **catch-up-window reconciliation** caller explicitly in the ordering
matrix: its combined pending-Begin transition must publish once after its
window apply, not only after a live `commit_block` apply.
In particular, drive the overlapping G1/G2 Begin schedule above and prove
G2's durable custody retires, its reply is phase-appropriate, and its one
resolution notification follows the applied G1 entry. The simple
pre-renewal-reclassification mutant must fail this ordering test; it is not
enough for the alternative-Prepare crash to disappear.
Pin bounded diagnostics and secret redaction. Keep existing custody, signing,
concurrent-group, canonical-artifact and full-open guard tests.

One reviewed behavioral commit only after a clean sequential EUnit, ask CT,
QUIC CT, both Simplex suites, xref, Dialyzer, production release and diff-check
run with true exit codes. No assertion may weaken to accommodate the defect.
No full-gate counts for the future tree are claimed here.

Question C is diagnosed and its implementation contract approved.
[Contracts A+B](dtx-evidence-and-observation-contract.md) are also approved,
but follow as separately identified scopes after C. Each implementation
remains review-before-commit gated. Both stopped campaigns,
original response categories and preserved ledgers remain untouched. A later
measured campaign must separately pass health and original-response reliability
before making any performance claim.

## 5. Implementation checkpoint — 2026-09-10

Scope C's source correction is now implemented, not committed. Its full
sequential gates passed; independent implementation review remains required.
Evidence for this tree is collected separately in
`/tmp/quod-retained-C-kNmwxD`; the original diagnosis and stopped campaigns
remain intact.

The existing retirement helpers now return `{State, PendingTransition}`.
Signing reconciliation performs the existing readiness classification before
reading the rows for renewal, then combines the original journal removals,
readiness retirements and signature/admission retirements by exact group
binding. Live commit, skip and catch-up retain their existing post-apply
publication sites. `keep_progress` and invalid-candidate retirement finish
their transitions at their existing ordinary boundaries. Exact committed
records preserve their existing replies; refused Begin uses the Begin result
grammar rather than a Prepare refusal.

The installation diagnostic reuses the existing formatter and sanitizer,
with only namespace, group/record digests, phase, height, old/proposed sequence,
committed floor and `stale` classification. Namespaces longer than 255 bytes
are explicitly marked as truncated. The unchanged invariant still throws;
normal semantic retirement is not logged as an error. Restore installation
uses the same diagnostic without changing its classification or recovery
behavior. The separately noted restore-conflict/dormant-activation edges are
not fixed or attributed to hardware by this change.

The permanent Begin regressions now exercise both live quorum commit and the
catch-up sink, check **both** original and retirement notifications exactly
once after apply, and enter production `keep_progress` for ordinary
retirement. Two reversed wait-die schedules prove blocked Begin survivors
renew, retain their waiter/custody and reopen at the monotonic floor. Current
tests pass all five; the unchanged source fails three, and the simple reorder
fails both post-apply tests while all three healthy controls pass.

The permanent Prepare regressions use real N=4 admissions, distinct valid
quorum subsets, actual competing selectors, checked history and real journals.
They pin exact waiter replies, absence of signing for the stale alternative,
healthy renewal, exact-digest drain and repeated reconciliation after reopen.
Their intentional signature-only invariant control must still fail loudly
and preserve the exposed floor, with a whitelisted diagnostic.

Final frozen-tree gates completed at **2026-09-10 14:25:25 UTC**:

| Gate | Result (true exit 0 throughout) |
| --- | --- |
| Full EUnit | 1,984 tests, 0 failures |
| Ask CT | 26/26 |
| QUIC CT | 26/26 |
| Quod Simplex CT | 12/12 |
| Four-node Simplex CT | 8/8 |
| xref / Dialyzer | Passed |
| Production release | 0.7.160 assembled; not deployed |
| Diff check / source-test hash check | Passed; frozen files unchanged |

There are 12 new permanent tests: five Begin cases and seven Prepare/diagnostic
cases. The namespace diagnostic controls include the exact 255-byte boundary
and oversized printable/nonprintable inputs. These diagnostic-only oversized
identities use a short physical storage label, not a runtime admission claim.
The final Prepare fail-before control preserves its expected exit 1,
`stale_retained_dtx`, one signing attempt and reopened floor 3. The original
1,157 function ASTs were verified unchanged in that isolated baseline VM.

`/tmp/quod-retained-C-kNmwxD/IMPLEMENTATION-HANDOFF.md` records the results and
`CLAUDE-REVIEW-PROMPT.md` requests the outstanding exact-tree review. The final
source/test manifest is `gates-1/tree-sha256.txt`; `gates-1/exit-codes.tsv`
records each gate's true exit status. A preliminary focused test failed because
the sandbox denied a local peer listener (`eperm`); that failure is preserved,
and the permitted rerun passed without changing assertions or time limits.

No new performance result, deployment, version bump or ledger purge is part
of this checkpoint. A and B remain separate unimplemented scopes.
