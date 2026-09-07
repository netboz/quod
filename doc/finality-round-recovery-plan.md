# Finality recovery without sacrificing write throughput — review draft

Status: **approved pipelined baseline; activation-ladder handover blocked on review;
not approved for implementation**. Source reviewed at `b7c497e` / 0.7.143 on
2026-09-07. Claude withdrew the per-slot rounds recommendation and accepted
protocol-faithful pipelined Simplex with separate views and ledger heights.
Both grandchild and first-observed-finality handover candidates are refuted.
The reviewer concedes contract v2's typed-complaint deadlock and per-round
uniqueness gap. Contract v4 removes in-view rounds, locks and typed complaints;
it proposes deterministic old-era activation rungs using ordinary Simplex
carriers. Those fixed-committee simplifications hold conditionally, but the
cross-era claim does not: §4.3.9 reproduces old-rung R versus new-era child G,
both above the **same A**, with genuine old commitQC(A) carried by G.
Both certify under the offered-evidence rules, without any equivocation or
skipped view. This reopens §4.3.3, not a new fixed-era failure. The phrase
“other old-era children are invalid” needs a portable retirement rule compatible
with rung recovery; local knowledge of finality cannot be that rule.
Consensus, DTX and signing-journal code still require review before commit.
This commit is a plan only: no code, format, release bump or fleet change.

## 1. Throughput is a design requirement

Yan's objective is increased **durably completed write throughput**. The
previous recommendation to replace the pipeline with sequential per-height
Tendermint is withdrawn. Merely disclosing a possible throughput regression
does not justify accepting it.

Preserving useful overlap is the default constraint. Removing it requires
a concrete replacement with demonstrated net-throughput improvement while
preserving latency and correctness. No such evidence exists today.

The approved baseline is restoring original Simplex's coherent progress/ancestry
rules within the existing owners, with §4.1's view/height separation. The baseline
choice is closed; its complete Quod adaptation is not yet proved. Review has
closed the view/height and per-view custody choices and accepted the carrier
and payload-window direction. The membership boundary and its interactions
in §4.3 still block implementation. In-view rounds are now withdrawn entirely;
neither the old hybrid nor sequential consensus for ordinary writes is authorized.

Two obligations remain separate: repair permanent consensus stalls without
slowing healthy writes; then attribute and remove the per-write H1 cost.
Resolving a stall is not, by itself, a throughput measurement.

## 2. Established failure and evidence

The relay-readiness fix succeeded: preserved group
`3A8C2845311282594E39B33D4426297BFB70C760C2FF1F945442E2C920E1EE62`
completed without resubmission (source Decision 38, Complete 40).

A subsequent two-writer request stuck at `quod:route-a`: committed height
1787, notarized candidate 1788. All four validators have three support
signatures, two commit signatures and two complaints; quorum is three.
`3044d9b2` and `8fe423df` signed commit; `84fe4be5` and `96c49bc3`
signed complaint. These are votes, not committed ledger outcomes. Group:
`6FDDFDBA6A0D61C5E779593F08F5416F35ABCBE39FA7E2C8D20C1D2A6D231B6D`.

The permanent locks are unchanged:

1. `may_commit/2`, `may_complain/2` and the signing journal forbid opposite
   final votes, including the adjacent-slot implication.
2. Neither terminal certificate reaches quorum; re-delivery changes no vote.
3. Proposal/payload barriers prevent a successor over unfinished DTX;
   `noop` is not currently a proposable block.

Raw evidence: `/tmp/quod-h1-143-pair-smoke/results.tsv` reports client
30,047 ms and `pending`; 30,027 ms was an internal stage, not that wall time.
Preserve the group/journals during review. Do not resubmit, wipe or add load
to the stuck ontology. The split's cause in time is distinct from proving
that the current transitions cannot recover it.

## 3. Approved pipelined baseline and closed rounds debate

The reference is `doc/simplex_extended.pdf`, §§2.3–3.3. Notarization permits
advancement before direct finality. A complaint permits progress, not an
immediate durable empty entry. A committed descendant finalizes ancestors;
a parent's complaint does not itself prohibit committing its child. These
rules belong together; Quod cannot keep incompatible terminal-skip/cross-slot
rules and inherit the paper's liveness proof.

Under the reference, the observed notarized parent permits considering a
successor. Its complainers may commit that successor; a successful descendant
can finalize the parent without changing an old vote. This describes the
reference, NOT yet a completed DTX/membership adaptation.

| Direction | Disposition |
|---|---|
| Another complaint/grace exception | Reject: leaves the incompatible rules and cannot safely change the permanent locks. |
| Sequential per-height Tendermint | Withdrawn as recommendation: sacrifices overlap without a demonstrated compensating gain. |
| Restore protocol-faithful pipelined Simplex | Approved review baseline, including view/height separation. Finish the membership/era proof before implementation. |
| Per-height rounds plus current implicit child finality | Claude formally retracts this recommendation: the live split cannot form its round-change certificate; round-in-value bytes changes the locked identity; and multiple round candidates make unchanged slot-bound implicit finality unsound. Parent-value binding and coherent ancestry rules were the decisive reason to select spec-Simplex instead. Do not reintroduce the hybrid. |
| Sequential membership with in-view rounds | Withdrawn by Claude: mode-typed complaints strand honest voters; per-round latches do not prove per-view uniqueness; a minority commit trigger does not exclude an ordinary complaint quorum. No rounds/locks/typed-complaint branch remains planned. |
| Complaint-taint mode selection | Withdrawn by Claude after §4.3.7: later knowledge cannot change earlier portable complaint shares. No evidence-field patch or revocation. |
| Committed-intent entry trigger | Withdrawn after the same-parent classification schedule: ordinary pipelining does not require the parent applied; later finality cannot re-type existing child votes. |
| Parent-value activation, no SKIP (contract v2) | Superseded by v4 after the reviewer accepted the competing-parent objections; same-parent grammar and SKIP deletion remain useful. |
| Pinned activation ladder, uniform complaints (contract v4) | Fixed-era escape and rung recovery reuse Simplex; singleton membership payload retained. Cross-era entry through any rung's commit QC reopens old/new descendant overlap even with the same activation base (§4.3.9). Not accepted for implementation. |

Stable leaders and other throughput variants are not folded into this repair.
Evaluate them separately only if measurements justify their added scope and
fairness tradeoff. No second engine, verifier or configurable compatibility mode.
V4's special payload and handover grammar is still a protocol change; sharing
the existing votes and owners does not prove its cross-era composition.

### Recorded reasons for the retraction

- Three complaints cannot be collected from the reproduced two-complaint
  split. A chosen protocol must explain this exact schedule.
- In a per-height re-proposal protocol, a mutable round cannot change the
  locked value's bytes/timestamp. Original Simplex uses a different operation:
  a new view extends a parent. Do not mix the meanings of slot and round.
- Current `quod_catchup:verify_implicit` binds a child to the parent's slot.
  Allowing several supported values for that slot in different rounds breaks
  that uniqueness argument. A parent hash alone is not a cross-height lock
  proof. A restored Simplex mapping must preserve one supported value per view.
- One finalized value does not mean identical certificate bytes. Existing
  independent verification of equivalent signer subsets must remain.
- Leadership also lives in `quod_ingress_state` and placement correlations.
  Updating the vote state alone can leave accepted requests stranded.
- FLP does not establish an exhaustive list of engineering alternatives.

## 4. Reviewed decisions and remaining proof obligations

### 4.1 Views versus ledger heights

Today protocol positions, append indexes, ingress placement and DTX references
share slot numbers. Complaints must not manufacture irrevocable ledger entries
merely to keep those numbers equal.

**Closed by review.** Support/commit votes bind `(View, ValueHash)`, retaining
the existing signature-domain and vote-kind separation; a complaint binds its
view without asserting a block value. A block value is proposed in exactly one
view. A new view extends a parent; it never re-labels/re-signs the same block
bytes as a proposal in another view. Re-sending an existing signed proposal is
not a new proposal. Parent identity and view belong to the canonical block
grammar; append height is derived from the finalized ancestry.

**No in-view recovery round:** v4's next rung is a new parent-bound value in a
fresh view, not a re-signing of A in another round. Votes and the journal keep
the one per-view discipline; no round dimension or legacy round alias is added.

The finalized ancestry appends at contiguous ledger heights. Failed views
produce neither fact changes nor synthetic terminal entries. A genuinely
committed empty carrier is a block and receives an append position, unlike a
view skipped by complaint evidence. DTX exact references bind **ledger heights,
not views**, retaining their exact-entry/hash/finality binding. A bare numeric
height is not a proof. No caller-supplied height/view alias may select an entry.

Fixed-era once-only append uses unique notarization per view. Uniform per-view
latches restore that premise for competing parents **within one committee**.
They do not establish quorum intersection between disjoint old/new committees
authorized by different child evidence (§4.3.9). The ancestry walk deduplicates finalized views
against the committed prefix; a second descendant cannot re-apply an ancestor.
The existing codec, store and finalization path own this mapping; no second
ledger/index owner. §4.3 must establish unique era authority before this
within-era uniqueness argument can be used across reconfiguration.

The implementation audit must classify every affected `slot` use as protocol
view, append height or placement. This is not a local rename. Failed-view
evidence and parent material must remain sufficient for that same verifier's
forward ancestry walk, including after restart.

### 4.2 Application ordering versus consensus progress

DTX must still prevent later application work from assuming an uncommitted
Prepare/Decision/Finalize has been applied. That does not justify preventing
consensus from exchanging the evidence needed to finish the pending block.
Effects and facts remain released only through certified, ordered apply.

**Carrier direction for fixed-era barriers:** an empty payload is eligible for
production when it extends a notarized, unfinalized parent. The shared payload
gate retains ordinary semantic checks. V4 proposes deterministic old-era A
above intent I and further empty rungs above A, instead of the former no-child
activation barrier. Each may carry its ancestry's finality. This is recorded
as the candidate, not permission to remove the current membership fence:
retiring those old-era descendants before N starts remains unsolved (§4.3.9).
An empty carrier is
an ordinary block through the same proposal, votes, journal, verifier and append
path—not a DTX-only escape, unsigned marker or new certificate family. Eligibility
is the leader's liveness-side choice; shared proposal/history validation uses
the carried ancestry/evidence, not whether this receiver has already learned
another finality certificate. §4.3 specifies the separate membership barrier.

**Explicit trigger:** entering a fixed-era view whose selected parent is complete
and notarized-but-unfinalized wakes the existing proposal owner. Prefer an admissible
non-empty payload; if none can safely extend that parent, the same owner can
propose an empty carrier. The entering-view message/evidence edge is the trigger,
not a timer, polling loop or a later user request. Parent finality arriving
before an unsent carrier is selected removes that need; it must not cause a
second proposal after a support latch has already retained one. Idle finalized
ontologies do not create carrier traffic.

**Invariant replacing the DTX control exclusion in `implicit_finality`:** every
honest validator's support of a DTX barrier already waits for that exact
block's deterministic validation verdict against the correct parent state.
A descendant can therefore carry its ancestor's finality without bypassing
that validation. Apply still walks the finalized ancestry once in order;
controls, facts, effects and custody are not released from support alone.
No `if DTX then bypass validation` branch, speculative Prolog apply or second
executor. V4 also proposes ancestor finality for activation values; that change
is blocked on its handover proof. I changes desired membership facts, not active
authority. No existing membership exclusion is deleted in production by this plan.

Direct healthy finality needs no carrier to prove the write. That is not a
promise of zero carrier traffic: the entering-view edge can race final votes
even on a healthy network. Preserve useful payload overlap, and count actual
carriers as cost, not useful writes. The old grandchild-handover rule is
withdrawn; v4 instead requires an old commit QC for new-era entry, but has not
proved retirement of old rungs (§4.3.9). Historical
verification cannot depend on the receiver's current lack of a certificate.

### 4.3 Committee changes are the hardest boundary

Today committees come directly from committed `peer_admitted` facts; the
candidate separates desired facts at I from their activation at A through
the existing epoch projection seam, not a new authority. A speculative child
cannot gain authority from an unfinalized membership change. A fresh verifier
must not use the new committee to check an old-committee descendant that
finalized that change.

#### 4.3.1 Review disposition

Let M change committee O to N. Grandchild activation failed §4.3.2. The
replacement, "the first O commit K whose ancestry contains M activates N",
blocked that first schedule but failed §4.3.3. Claude independently confirmed
the second counterexample: first *observed* finality is not a chain-derived
handover boundary, and a globally first certificate is not locally knowable.
Both directions are withdrawn, not alternative implementations to retain.

V4 withdraws sequential activation rounds in favor of an old-era ladder above
ordinary intent I: base A and further rungs, any directly committed rung
authorizing N. A's hash is the proposed era identity regardless of which rung
commits. This fixes neither old-rung retirement nor conflicting children above
that same base; §4.3.9 checks the offered rule explicitly. Historical schedules
below call the committee-changing block M, not v4's desired-fact intent I.
No implementation.

#### 4.3.2 Closed counterexample to the withdrawn grandchild rule

N=4, quorum 3, old committee O = {o1,o2,o3,oz}, new committee
N = {n1,n2,n3,n4}, disjoint. All can be honest; oz need only receive evidence
late (an isolated commit share from oz does not form a quorum). The schedule is before
network synchrony. P is a finalized old-era parent. Notarization and complaint
certificates **can coexist**: the exclusion is commit-versus-complaint in one
view, not support-versus-complaint.

| View/branch | Support signers | Final-vote signers | Result |
|---|---|---|---|
| 10: M extends P, changes O to N | o1,o2,oz | o1,o2,o3 complain | M has a support QC and a complaint QC, no direct finality. |
| 11: C is M's empty old-era child | o1,o2,oz | o1,o2,o3 complain | C also has both QCs, no direct finality. |
| 12: X extends P, skipping 10/11 under their complaint QCs | o1,o2,o3 | o1,o2,o3 commit | O finalizes a chain omitting M and C. |
| 12: G extends C, under the proposed grandchild activation | n1,n2,n3 | n1,n2,n3 commit | N finalizes a chain including M and C. |

One admissible message ordering: delay M's support QC until o1/o2 have complained,
then give them that QC but withhold M's complaint QC so they can extend M with C.
Delay C's support QC until after their complaints too. Give N both support QCs;
give O the complaint QCs before it sees C's completed notarization. An old-era
leader that advanced via complaints has P as its selected parent and proposes X.
The new-era branch proposes G from C. Withholding/delaying honest broadcasts
before synchrony does not require an honest signer to equivocate.

Every shown QC has three distinct authorized signers under its branch-derived
era; no signer supports two values or both commits and complains in one view.
Nevertheless the two view-12 finality certificates conflict. The old/new voting
quorums need not intersect, and the new committee is using its own descendant
to retroactively authorize its introduction. Unique notarization per view in
one fixed committee does not resolve that circular authority.

This is an abstract schedule/quorum check of the candidate, not a reproduced
production failure or full model check. It is not the preserved 2/2 split:
those latched votes cannot later form a complaint QC. Testing only two stacked
2/2 splits can therefore pass while missing this cross-era safety failure.
The withdrawn grandchild rule contained no earlier certified retirement of O;
the replacement is checked separately below.

**Historical re-check against the now-refuted replacement:** with neither M nor C committed
under O, no K exists, so G cannot be N-signed. It must use O, whose same-view
support exclusivity prevents both X and G from getting quorums. The original
self-authorization schedule is blocked. This establishes that old-era finality
is necessary; it does not prove unique authority over subsequent children.

#### 4.3.3 Confirmed counterexample: different first commit certificates

Use disjoint O = {o1,o2,o3,o4}, N = {n1,n2,n3,n4}, quorum 3. All are honest.
Choose the old leader for view 11 among o1/o2/o3; the new committee has its own
leader. P is the finalized old parent. The network delays messages before
synchrony; no signing rule may depend on learning a broadcast instantly.

1. O notarizes membership M at view 10. o1/o2/o3 emit commit shares for M and
   advance on its notarization, as the pipeline permits. Deliver those commit
   shares to o4, which assembles QC_O(M), and deliver that evidence to N through
   ordinary certified-history dissemination. Delay QC_O(M) and the other M
   commit shares to o1/o2/o3. Each knows its own share, not the quorum.
2. To o1/o2/o3, M remains notarized but unfinalized. Under the replacement's
   contested-case rule, O proposes empty child C at view 11, parent M. These
   three support C; deliver its support quorum and then their C commit shares
   among them. They obtain QC_O(C) **before** QC_O(M). C finalizes ancestry
   P→M→C; their first observed handover block is K=C.
3. N already has QC_O(M). Under K=M activation, it proposes another child G at
   view 11, parent M, and n1/n2/n3 support and commit G. It finalizes P→M→G.
   G may carry ordinary work, while C is empty: they are different block values.

No party double-supports a view or signs both commit and complaint. Every
certificate has three members of the committee selected by its disclosed
handover evidence. Both branches include M, so the fixed-era argument that
"no old branch excluding M can finalize" does **not** exclude this fork.
The missing uniqueness is C versus G, not M versus its old parent.

Calling K the globally earliest O commit does not yet solve the problem:
QC_O(M) may exist without being present in C's offered history. A fresh verifier
of P→M→C plus QC_O(C) cannot prove that no earlier certificate was assembled
elsewhere. Giving it QC_O(M) later must not revoke finality it already accepted.
Likewise, an old carrier that is merely proposed can become obsolete, but an
**already finalized** old carrier cannot be discarded as a harmless redundant
branch: carriers are ledger blocks with append positions under §4.1.

Claude confirmed this paper counterexample to the replacement **as stated**.
It is not a deployed failure or exhaustive model check. A finality certificate
for M alone does not retire in-flight O descendants. An unstated freeze after
each commit share would instead risk stranding the carrier quorum in the 2/2
split. Neither patch is retained.

**Historical check of the now-withdrawn sequential candidate:** step 2 is refused. O cannot
support C over unresolved M, irrespective of whether C is empty; once M is
certifiably committed, the shared verifier selects N for its child. There is
no O-signed child certificate to race with G. This closes this exact witness;
it does not prove the proposed in-view recovery or its mode-selection rule.

Source grounding: today's `implicit_finality` rejects committee barriers
(`quod_simplex.erl`, around 597–605), and `adopt_history`'s boundary comment
(around 9387) explicitly relies on **no next-slot proposal before committee
finality**. That is the protection v4 proposes replacing, not dead code already
safe to delete. Allowing old-era carriers without a proved replacement removes
it. The paper's
§2.3.3/§2.4 separates certificate-based commitment from notarization-driven
view advance; §3.1's quorum intersection assumes one committee. None of these
is a proof that the proposed overlapping eras are safe.

#### 4.3.4 V4 candidate: one fixed-era protocol, pinned activation ladder

| Work | Candidate grammar/progress | Authority claim |
|---|---|---|
| Ordinary fixed-era content | useful payload overlap; carrier if needed | current certified committee |
| DTX control barrier | empty carrier after deterministic validation | same committee; application fenced |
| Membership intent I | ordinary desired facts; singleton membership payload retained | O |
| Base A above I; rung R above a ladder tip | deterministic empty, view/parent-bound value; ordinary per-view support/commit/complaint | O, using notarized parent evidence |
| First new-era child G | carries the tip's genuine old commit QC | N selected by intent; base A hash starts the era |

The first four rows explain recovery **within O**. The last row conflicts with
the old-rung row unless a portable rule retires those descendants before N may
sign. V4's clause “any other old-era child above the ladder tip is invalid”
does not specify that rule consistently with permitting a next rung on a
merely notarized tip. This is the blocker, not an implementation detail.

Uniform complaints remove the mode-specific 2-versus-1 escape partition.
Different views allow fresh votes without changing an old latch. A fixed-era
rung commit can finalize a stack of 2/2 parents. These conditional properties
are checked in the bounded witness; they are not a handover proof.

A/rungs must be constructible from notarized, available parent bytes and
validated ancestry, without requiring that parent committed. Consecutive
rungs need no gap evidence; a proposed child that skips any views still needs
the ordinary complaint certificates for those gaps. “No ladder gap evidence”
cannot silently exempt a non-consecutive proposal from the shared verifier.

No explicit SKIP value, in-view round leader, lock or alternative-vote family.
Per-view recovery and evidence distribution stay at the existing owners.
Membership payload selection stays singleton through
`membership_payload_shape`, not a new cap or pending-intent registry.

Cost: at least I+A ledger entries for a successful change; additional rungs
are extra committed entries, votes, verification and journal work. A direct
commit on one rung can finalize the whole prefix, so the number of entries
is not the number of sequential direct commit certificates. Do not promise
that the ladder is cheaper without measurements. Ordinary throughput and
§6's acceptance gates are unchanged.

#### 4.3.5 Closed one-shot complaint-threshold direction

Assume N=3f+1, f>=1, commit quorum q=2f+1, and the existing possibility of
support-plus-complaint, with honest commit/complaint exclusion. A proposed
carrier-eligibility rule requires t complaints about M to exclude a commit
certificate for M. To force an **honest** intersection:

`q + t > N + f`, hence `t >= 2f+1`.

But an all-honest split with f+1 committed and 2f complained has no terminal
quorum and can never supply more than 2f complaints. Recovery needs `t <= 2f`.
No t satisfies both. At N=4 this is precisely `t >= 3` versus `t <= 2`.
The review's general sentence "f+1 committed leaves f+1 complaints" was correct
only at f=1; the corrected general bound above yields the same contradiction.

This closes the **one-shot complaint-count gate under those voting rules**;
do not try another threshold. It is not a theorem excluding every possible
certificate grammar, signing restriction or reconfiguration protocol. Those
change the premise and require their own reviewed safety/liveness design.

#### 4.3.6 In-view rounds withdrawn — reasons and retained obligations

Review `bdd87d48-8b0a-4afd-8338-b3409936309e` concedes the two §4.3.9
objections from contract v2:

- Permanent per-view support plus mode-typed complaints strands a,b on A and
  c on bypass B when z is silent: neither typed escape family reaches q=3.
- Only per-(view, round) support permits different notarizations across rounds.
  That alone is not a full fork, but it invalidates the claimed per-view
  uniqueness premise.
- An f+1-commit round-entry trigger does not exclude a complaint QC. At N=4,
  commit shares {a,z} and complaint shares {b,c,z} coexist if z double-votes.
  Requiring q commit shares instead is already the commit QC and cannot rescue
  a 2/2 split. This closes that threshold sketch, not all conceivable protocols.

Rounds, locks, validValue/validRound, typed complaints and explicit SKIP are
removed from the planned cut. Historical witnesses remain evidence of why
those proposals failed, not dormant implementations or alternate formats.
Tendermint's name or a mixed-vote quorum never supplied a common entry rule.

V4 keeps the baseline's uniform complaint certificate and fresh-view recovery.
Safety still cannot depend on the timing of message delivery. Eventual
synchrony, available eligible quorum and an honest future leader are liveness
assumptions, not guarantees that a current broadcast has reached everyone.
The existing readiness-gated watchdog remains the failure-detection owner;
no success-path polling, retry ladder or second pacemaker.

Unfinalized proposals/shares/QCs travel through Simplex's evidence emission,
transport outboxes and retained-body requests; `quod_feed` carries finalized
history. A QC can be assembled by honest nodes when they receive q signatures;
f+1 honest shares alone are not a q-signature certificate. Withheld Byzantine
shares may waste views; ordinary complaints permit fixed-era recovery.
Neither broadcast nor eventual delivery prevents the pre-synchrony handover
schedule in §4.3.9. Parent/body availability and restart custody remain required.

#### 4.3.7 Counterexample to the complaint-taint boundary

This checks the review of `ad44f66`, attachment
`5459ea3c-9a55-4524-a74d-c3d7687d0103`. Grant its strongest interpretation:
each complaint's evidence field is signed, immutable and correctly verified;
membership M is a valid leader-signed proposal for V. O={a,b,c,z}, q=3,
z Byzantine. All messages shown are for the same old era and view V.

| Step | Evidence/messages | Consequence under the proposed rule |
|---|---|---|
| 1 | Before seeing M, a and b complain in round 0 without evidence. z adds an untainted share and privately assembles U={a,b,z}. | U is an ordinary-skip certificate by the taint test. No honest node has to learn U yet. |
| 2 | c receives M before complaining and attaches it. Assemble T={a,c,z}, reusing a's and z's original shares. | T is tainted and authorizes in-view round change. No share was modified. |
| 3 | Deliver M and T, but not U, to a,b,c. | All park in V. Their round-0 complaints do not forbid round-1 support/commit under the proposed recovery rules. |
| 4 | Round 1's leader proposes M; a,b,c support, learn the support QC, and commit it. | QC_commit(M,1) exists, with three distinct old members and no same-round equivocation. |
| 5 | Reveal the unchanged U. | The same taint test still accepts ordinary skip of V, despite the actual membership commit. |

U and the commit quorum intersect in **a,b**, both honest. They knew M when
committing in round 1, not when signing their round-0 complaints. The inference
"an intersecting honest committer therefore attached evidence to its earlier
complaint" is false. This is not evidence-field stripping, a different era,
duplicate weight, or a violation of the support/lock guards. A fresh verifier
cannot invalidate U based on a certificate it has not received.

This bounded witness proves that the proposed boundary accepts both an ordinary
view-skip certificate and membership finality for V. It does not simulate full
old/new divergent ledger execution. Their asserted mutual exclusion is already
refuted; fork prevention cannot be inferred from that proof. The related claim
that an ignorant next-view quorum is impossible also lacks its premise: a lone
parked honest c leaves a,b,z, which is a quorum. Any safe rollback/exit rule must
account for votes that advanced nodes have **already** signed, not just their
current location.

Re-signing complaints with later evidence cannot retract the retained U. Nor
can U be accepted only until local M finality arrives: that reintroduces the
certificate-arrival dependence refuted in §4.3.3. A simple irreversible exit
on an untainted share is not a free fix either: two honest clean complaints,
one honest tainted complaint and one silent Byzantine member yield neither a
clean skip quorum nor three members still permitted to recover in V. A
different rule allowing some continued votes must prove its own lock/liveness
composition, not silently inherit this one.

**Required architectural answer:** define one monotone signing/evidence rule
that excludes incompatible escape and membership decisions over their entire
lifetimes, while allowing a live old quorum to finish the mixed-knowledge
schedule without Byzantine cooperation. No negative-global-knowledge test,
revocable certificates, arrival-order mode flag, new polling, or lost ordinary
pipeline overlap. The taint candidate is not accepted for implementation.

#### 4.3.8 No round/SKIP format; deterministic ladder values

V4 removes the in-view round dimension in addition to SKIP and its lifecycle.
QSJ4 is still the planned clean journal cut for view/height/signing semantics;
it is **not** a round-based journal. No round alias or alternative decoder.

Use the existing canonical value codec and signing owner. Each A/rung is
determined by its certified parent, intent/base, own view and old-era context.
Different proposers in the same view must produce identical pinned ladder
bytes for that parent. A rung in another view is a **different value**, never
re-use of a view-bound A. No local timestamp, leader choice or round field
changes the intended payload. Actual codec vectors remain implementation
artifacts, not something proved by the scratch model's string identifiers.

A and old rungs bind O's existing era-start hash. V4 proposes base A's canonical
hash for N's era, independent of certificate signer subsets or the rung that
directly commits. New-era entry carries an exact old commit QC for its parent.
These bindings are necessary but not sufficient: both conflicting branches
in §4.3.9 share the **same base A**. An era label is not a certified cutoff of
O's authority to sign further children.

#### 4.3.9 Pinned activation ladder — same-base handover counterexample

Contract v4 (review `bdd87d48-8b0a-4afd-8338-b3409936309e`) replaces the
previous entry/mode contract with ordinary per-view complaints and old-era
empty rungs. It accepts the v2 objections rather than adding another unlock
or typed escape. The fixed-era positive cases are useful and stay recorded.
**The claim that this closes reconfiguration is not accepted.**

**Counterexample: portable entry evidence does not retire old descendants.**
Take disjoint O={o1,o2,o3,o4}, N={n1,n2,n3,n4}, q=3. All are honest. P is
finalized; I in view 10 is already committed under O. A is the pinned base
above I in view 11. This stronger prefix makes intent-bypass exclusion irrelevant.
Choose the old leader for view 12 among o1/o2/o3; N has its own eligible leader.
Delay honest broadcasts before synchrony, without losing messages forever.

| Step | Evidence and permitted action under v4 | Result |
|---|---|---|
| 1 | O notarizes A. o1/o2/o3 emit commit shares for A and advance on its notarization. Deliver all three shares to o4, then genuine commitQC_O(A) to N. Delay that aggregate and the other A shares to o1/o2/o3. | N can certify the old parent; those three old voters know their own commit share and supportQC(A), but not finality. |
| 2 | The old leader proposes deterministic rung R at view 12, parent A. Its stated parent premise is supportQC_O(A); there is no gap. o1/o2/o3 support and commit R. | Genuine commitQC_O(R); old history P→I→A→R. |
| 3 | N proposes different ordinary child G at view 12, parent A, carrying the exact commitQC_O(A) required by v4. n1/n2/n3 support and commit G. | Genuine commitQC_N(G); new history P→I→A→G. |

Every signer respects one support and one final-vote choice per view.
Committing A and later R is allowed by the proposed ordinary pipeline;
no adjacent-view retirement guard was specified. Both committees follow
their **own offered portable evidence**. There is no Byzantine party,
complaint certificate, gap, round change, second activation base or differing
intent. Both children include A and select A as the era-start identity.
Pinning old R's bytes does not make new-era ordinary G the same value.

This checks the literal supportQC-to-old-rung and commitQC-to-new-child
permissions in v4. It is an abstract signing/evidence counterexample, not a
deployed fork or exhaustive protocol model. It is the §4.3.3 C/G race with
**A fixed as the common base**, so choosing A rather than “first observed
committed rung” does not avoid it.

**Why the proposed exclusion proof does not cover this.** A committed view's
complaint QC is impossible under the same committee, so a later branch cannot
gap that view. This is the fixed-era argument against a bypass *omitting* a
committed rung. R and G both **extend** A, skipping nothing. Old/new quorums
need not intersect, so same-view uniqueness within O cannot compare R with G
signed by N. A unique activation fact/base is weaker than a unique descendant
history. Supplying commitQC(A) authorizes N under the candidate but contains
no signed promise that O has ceased supporting old descendants.

**Resolve the conflicting reading explicitly.** If “other old-era children
above the ladder tip are invalid” means R is always invalid, it contradicts
the recovery rung rule. If it means R becomes invalid when the receiver learns
commitQC(A), R can already have committed before that message arrives, as in
the table; finality cannot be revoked. If it means some additional portable
evidence forbids R before N starts, name that evidence and its signing rule.
Proof-carrying new entry alone is not such an exclusion proof.

A personal “stop old work after signing commit(A)” condition is not a free
repair: in A's 2-commit/2-complaint split, only two old validators could then
sign its recovery rung, below q=3. A global “no commit QC exists” check is not
locally knowable. Do not silently restore either condition or claim broadcast
makes the race impossible. Eventual delivery does not undo two certified branches.

**Architecture boundary for the next review.** Establish one certifiable
handover cutoff that both (a) excludes incompatible old descendants before
new authority can certify a child, and (b) remains obtainable after the exact
latched 2/2 split with a live honest quorum. State the evidence, signed
obligations and local/catch-up verification rules at the existing owners.
If this requires a different reconfiguration protocol or a membership-specific
cost, disclose it and prove it; do not call it “only grammar” while leaving
retirement undefined. Preserve ordinary-write overlap, the fixed-era Simplex
baseline and §6. Do not bolt another arrival-order exception onto the ladder.

**Retained application contract.** I writes desired membership facts through
the ordinary reducer and its result acknowledges that commit, not necessarily
active N. `membership_payload_shape` singleton selection remains as-is;
do not remove it when changing the consensus barrier classification.
Cancellation is a later separately authorized intent; duplicates do not
re-apply I and uncertain requests are not automatically resubmitted.

Reuse the existing `active_validators` epoch projection, not a pending
membership registry. Its current implementation is the identity over committed
facts; actual activation remains future work. Live/history/current-view/
catch-up/route-eligibility consumers must share the same proved active-era
boundary. V4's base-hash proposal is recorded, not an already safe epoch rule.

**Witness and limits.** `/tmp/quod-pinned-ladder-proof.iM99TR/check.mjs` checks
uniform escape after mixed-parent votes, fixed-O recovery through two latched
splits, and same-O competing-value exclusion in both orders. It also verifies
every signer/latch/exact-parent-certificate condition in the table and obtains
both conflicting certificates, plus rejects the naïve local-QC and personal-
commit freeze fixes. It does not implement actual codecs, networking, production
journal recovery or a general reconfiguration protocol. Historical v2 tests are
superseded, not evidence that v4 passed them all. No implementation authority.

### 4.4 The live window must permit the required progress

**Reviewed rule:** the depth bound governs payload-bearing advancement only.
Fixed-era empty finality-carriers are exempt and may chain. V4 proposes using
that same allowance for old-era activation rungs, but its cross-era termination
is blocked by §4.3.9. This is a payload/protocol
distinction at one owner, not a second pipeline, new hard cap or cap increase.

Concrete counterexample to preserving Quod's global depth-one window: committed
head v-1; v is notarized with a latched 2-commit/2-complaint split. View v+1
becomes notarized with a fresh 2/2 split too. Both first-stage quorums exist;
neither final-vote camp reaches three. The current global allowance of two
uncommitted slots prevents v+2, so no later descendant can finalize either.
Removing the adjacent-view voting exclusion alone does not fix that deadlock.

With the reviewed rule, the next empty carrier and further necessary carriers
can proceed through the same view/proposal/signing machinery even while the
payload window is full. Once a descendant obtains commit finality, the existing
ancestry walk finalizes its ancestors, makes those entries durable once, and
prunes the collapsed live prefix while retaining journal floors and the
evidence/custody still required for serving and recovery.

**Paper attribution precision:** §5 of StableDispersedSimplex does describe a
k-style bound, but includes epoch-wide complaints and an end-of-epoch escape.
Its guarded advance also governs commit emission; it is not byte-for-byte
Quod's global `live_pipeline_slot` bound. The schedule above refutes the bound
transplanted onto basic per-view voting, not the complete published stable-
leader protocol. The carrier exemption is this plan's adaptation, to be tested
and proved, not a quotation of that paper's k rule. Stable-leader epochs are
not being introduced by this slice.

After synchrony and an eligible honest leader, the reference liveness argument
can collapse a **fixed-era** carrier chain, provided validity and dissemination
remain live. This is not a fixed bound on pre-synchrony memory/history, nor
proof that the currently open cross-era rule is safe/live. No arbitrary new
retention cap; pruning must preserve signing and availability obligations.

### 4.5 One routing projection and one signing owner

Project `(identity, era, view, leader)` from consensus into ordinary ingress
and retained DTX delivery. View changes invalidate obsolete placement and
wake existing owners, including unchanged live links and same-peer revisits.
Re-place identical retained signed submissions and operation/group identities.
A view advance is not proof of exclusion; only finalized history resolves it.
No new author sequence, client request or fabricated abort.

**Closed for the fixed-era baseline:** per-view support and final-vote latches,
plus supported-body custody, generalize the existing atomic-retention pattern.
Fixed-era pipeline voting adds no Tendermint lock. V4 returns membership votes
to exactly that per-view shape; no rounds, typed complaints, SKIP or validValue
schema. Supported-body/evidence custody stays at this **same journal owner**.
Same-era latches do not retire a different committee's authority: §4.3.9's
handover proof remains required, not something a journal key can invent.

The signing journal remains the sole persist-before-exposure owner. Persist
the exact supported bytes and support latch atomically; persist the final
commit-or-complaint latch before exposure. Remove adjacent-view exclusions,
not same-view non-equivocation. **QSJ4 replaces QSJ3**, without compatibility;
the bump covers the view/height and signing-semantics cut, not a recovery-round
dimension. Exact era-bound retirement/custody rules await handover sign-off.
A decision is terminal; late evidence cannot erase a signing obligation or
reopen an outcome. Restart retains every outstanding view's required exact
body/evidence and signing floor. The eventual schema must express the proved
handover rule, not invent one by choosing its map keys. Reuse exact
byte/parent/era-bound validation in existing candidate state,
not a new cache. Temporary evidence unavailability is not ordinary Prolog
failure. Proposer loss cannot strand required bytes.

A carrier advances the view and hence leader/placement through those same
owners, without new request bytes or author sequences. There is no additional
in-view round transition. Handover must also invalidate obsolete authority and
placement through a proved certificate-bound rule, not a local-finality flag.

### 4.6 Event-driven implementation

Proposal, validation completion, certificate, link and readiness messages
drive the existing state machine immediately. Reference failure detection
handles missing progress under stated synchrony assumptions. No polling,
success-path delay, retry ladder or additional watchdog protocol. A paper's
`wait until` maps to Erlang state transitions, not a polling loop.

## 5. Ownership and intended deletion map

These changes are conditional on closing section 4, not patches to apply now.

| Owner | Keep | Refactor/delete in the atomic cut |
|---|---|---|
| `quod_simplex` | one engine, useful pipeline, certificate pool, validation workers, ordered finalization, singleton membership payload | v4 proposes intent/ladder grammar at the existing payload seam; do not delete membership fence before proving old-era retirement; use `active_validators`; delete terminal complaint-to-ledger-skip, adjacent-slot exclusions, camp/grace machinery in the approved atomic cut |
| `quod_signing_journal` | atomic supported-body/vote custody, DTX/content custody | one per-view discipline in QSJ4; no round/typed-complaint/SKIP/lock branch; exact old-era retirement remains to be proved before implementation |
| `quod_ingress_state` and relay custody | existing queues, signed submissions and authenticated delivery | one consensus-derived leader; duplicated leadership calculation and stale placement assumptions |
| `quod_ledger` and records | canonical bytes, store and codec ownership | view/append-position distinction; complaint-certified synthetic terminal entries |
| `quod_catchup` | one chain/era/certificate verifier; exact canonical bytes | fixed-era ancestry grammar replaces depth-one-only assumptions; any new handover must verify the same irrevocable old-era cutoff live and on fresh catch-up |
| `quod_foreign_log`, DTX references | one certified projection and exact-reference owner | same byte-bound grammar, no second evidence path |
| Prolog/apply/effects | existing authorization, deterministic truth and effects | preserve semantic fences; remove only fences proved to stop consensus unnecessarily |

Wholesale deletion of the pipeline/implicit finality is not approved. Fewer
conflicting rules, not fewer useful concurrent operations, is the objective.

## 6. Performance acceptance and independent H1 work

Count **unique durably completed user writes/s**, not acceptance responses,
votes, candidate blocks or progress-only empties. For a fixed workload:

`writes/s = useful writes per finalized block / mean finalized-block interval`.

Serialization increases that interval unless a measured saving offsets it.
Bigger batches can also increase waiting; they do not prove compensation.
Keep existing batching, with no new batch-fill delay or batching subsystem.

Compare identical hardware, N=4 topology, payloads, routes, ledger heights/
shapes, client distribution and offered load. Report repeated runs, unique
durable writes/s, failures/pending, mean/p50/p99 latency, writes/block, block
interval, queue wait, verification and journal-sync cost. Observe actual
child work overlapping parent finality; do not infer it from field names.

Required workloads: ordinary writes c=1/c=4 and saturation; an isolated last
write with no subsequent traffic; L1 certified readers; atomic two-writer and
A→B→C→D; membership and failed/delayed leaders. Keep fault and healthy results
separate, and count necessary progress-only blocks as cost, not useful writes.

Acceptance: fault recovery without ordinary-throughput regression beyond
measured run variation. A serialization alternative needs demonstrated NET
improvement. Preserve existing latency goals: one-hop c4 p99 <=450 ms and the
requested sub-500 ms remote-write objective. Neither is satisfied by a paper's
network-step count, a selected favorable run, or a freshly wiped ledger.

H1 remains separate and necessary:

1. `verify_resident_local_snapshot` opens a snapshot per exact reference.
   Measure repeated opens/checks inside a validation job before deciding what
   the existing owner can safely reuse.
2. `quod_ledger_store:locate/2` uses a sparse index: `skip_frames` performs at
   most 255 header preads, not a full-height scan. Compare reference count,
   position modulo 256, old-era fallback, storage and phase-index work.
3. Explain >=95% of the increase in MEAN latency from per-request sums/means.
   Distinguish `phase_suspend` and `phase_resume`; no marginal-quantile sums.

One lost overlap does not explain the earlier 11–17 s chains. Neither
algorithm restoration nor replacement proves that cost gone. H1 may continue
on unaffected fixtures; preserve the stuck group. Cold start, compaction and
carried small fixes stay separate. L2 remains gated; Yan's lane files untouched.

## 7. Review and implementation sequence

The sequencing agreed by Yan is binding because finality and H2 both touch
catch-up, ledger and phase-index seams, and the finality re-found destroys the
grown fixtures. This does not authorize any finality or H2 code now.

1. **Now, in parallel: H1 measurement and finality paper.** Finish H1's
   discriminator matrix on unaffected fixtures, retain raw outputs and deliver
   the >=95%-of-means attribution table, with `phase_suspend` separate from
   `phase_resume`. Label all these results **pre-cut 0.7.143**. Commit this
   amended plan and return it for architecture review: baseline selection and
   fixed-era §4.1/§4.5 are closed; verify the §4.2/§4.4 mapping and sign off
   §4.3's membership handover, including its effect on those sections.
   Model schedules without a second production owner; no silently invented
   era-handover, skip or mode-selection exception.
2. **Then, the finality arc.** Only after the architecture review is green and
   the H1 campaign has finished and its evidence is archived, make the atomic
   engine/journal/codec/finality/ingress/catch-up cut. Never combine new
   producers with old trust semantics. Delete superseded rules/comments/tests,
   with no compatibility switch. Run fault, restart and throughput gates and
   full sequential code gates; review precedes each consensus-area commit.
   Separately bump and perform the reviewed coordinated clean re-found, never
   a mixed-fleet rolling protocol. **No H1 run remains in flight at the cut or
   re-found.** The old fixtures must not be silently lost halfway through a run.
3. **Only after the finality cut and re-found: H2.** Re-grow fixtures on the
   new ledger and establish the post-cut baseline before implementation or
   conclusions about the height fix. Bring backend selection to review with
   the completed H1 attribution table, and revalidate its owner on the new
   protocol. Build H2 once against the final catch-up/ledger/phase-index seams,
   not once before the cut and again after it.

Keep pre-cut and post-cut datasets separate: do not pool them or subtract a
post-cut result from 0.7.143 to claim an H2 gain. The endorsed finality throughput
gate in §6 is unchanged; an H2 before/after comparison must use the same new
protocol and freshly grown, comparable fixtures. A re-found resetting height
is never evidence that the height-growth defect was fixed.

Current formats: QSJ3 journal, v1 block/entry grammar, `sx2` envelope.
The journal replacement is QSJ4. Select the remaining exact bumps after the
era/representation review; audit all embedded finality consumers. Do not bump
unrelated transaction/scope grammars without a field change. Foreign ingestion
remains wrapped with zero atom allocation.

A re-found DOES NOT recover the preserved old group. Keep it intact until that
re-found is scheduled; archive its evidence as **unresolved-on-the-old-network**
before retirement, never an uncommitted abort/success. Reproduce that fault on
the new protocol and prove completion there without resubmission. Planning
authorizes no fleet mutation. H1 continues only on unaffected fixtures.

## 8. Non-vacuous tests and gates

- Exact N=4 split, delayed/hidden evidence and a silent Byzantine member;
  completion without changing/double-counting an old vote.
- **Stacked double split:** notarized v and v+1 each latch 2 commit / 2
  complaint votes. An empty v+2 carrier and further necessary carriers remain
  admissible with the payload window full; one commit collapses the ancestry
  exactly once. The pre-change global depth-one rule must fail this schedule.
- Ordinary child work starts before parent finality; no test encoding forced
  sequential execution as the desired result.
- Complaint alone appends no terminal empty entry; eventual ancestry cannot
  contradict a previously published outcome.
- A valid fixed-era carrier delivered after its parent's finality still
  verifies; proposal validity cannot depend on certificate arrival order.
- Gapped views, competing branches and equivalent witnesses: one final chain,
  contiguous append, exact references and no duplicate ancestor apply.
- DTX barrier completes without later user traffic and without premature
  facts/effects/custody release, including contested fixed-era carriers.

Membership tests must exercise both fixed-era recovery and handover; shared
parent/base inputs alone do not prove authority exclusion:

- **Same-parent grammar:** a correctly signed ordinary child above notarized I
  is refused before support, both before and after I's finality. Parent-retained
  restart derives the same answer. No applied-parent assumption or vote retyping.
- **Competing parents:** genuine supportQC(I) and complaintQC(I); A/I versus
  ordinary B/P in the same view, both winner orders, one O notarization only.
  Uniform complaints let honest voters rebase in a fresh view without changing
  an old vote. Non-consecutive parents still require every ordinary gap QC.
- **Mixed knowledge / silent leader:** a,b see A/I, c sees B/P, z withholds
  cooperation. No test may assume common parent knowledge or use z's signature to escape
  the two-versus-one honest partition. A lone evidence holder and two distinct
  intent parents must be covered too.
- **Intent 2/2 then base/rung 2/2:** A is constructed from notarized I;
  a later old-era rung in a fresh view finalizes the prefix once under the
  proposed ladder rule. No rounds, old-vote changes or client resubmission.
- **Same-base old/new overlap (§4.3.9):** deliver commitQC_O(A) to N before
  o1/o2/o3 learn it; old R and proof-carrying new G both extend A at view 12.
  The finally approved handover must reject at least one BEFORE its support
  quorum, with portable evidence, and retain 2/2 liveness. No local-finality
  oracle, forced instant broadcast, or absent-QC assumption in the fixture.
- **Arrival overlap / hidden evidence:** the earlier §4.3.2/§4.3.3 old/new branch
  schedules must not yield both final chains. Apply their boundary to A, not
  desired intent I. A fresh verifier accepts the same history regardless of
  which valid certificate bundle arrives first; later evidence revokes nothing.
  Support-plus-complaint coexistence must not be incorrectly rejected as itself
  Byzantine behavior.
- **Old quorum unavailable:** no N-only activation, minority fallback or timer
  workaround. State liveness assumptions; old authority must become available.
- **Signing/custody:** leader loss and restart preserve per-view choices,
  exact bytes and finality obligations. Wrong domain/era/view/value evidence
  and duplicate signers fail. No round/typed-complaint/SKIP producer or decoder.
- **Activation/rung bytes:** different proposers construct identical pinned
  bytes for the same parent/view, but different views have different values.
  No timestamp/leader/round freedom; pin actual production codec vectors.
- **One projection:** live apply, fresh catch-up, historical committee,
  current-view verification and route eligibility all retain O through I
  and derive N from the finally proved handover cutoff, including disjoint
  committees and removed-member rejection. No raw desired-fact early activation.
- **Intent ordering and results:** two queued membership transactions, the
  same-block selection rule, later countermanding intent and losing I branch.
  Original result at I acknowledges committed facts, not premature activation.
  Duplicate I never re-applies; no consumption-after-SKIP or re-signing path.
- Keep the historical U/T and classification witnesses as refutations of the
  withdrawn rules, not active taint fields or an alternative lock implementation.

Shared crash/delivery requirements:

- Crash around every durable vote/body/send; proposer loss, stale validation
  and live-link replacement; no double signing or lost work.
- Leader/view changes and same-peer revisits re-place retained bytes
  without fresh client requests or author sequences.
- Multiple failed views cannot hit an incidental window bound and deadlock;
  retained proof/body pruning preserves signing and availability obligations.
- Live and wrapped-history verification agree, reject wrong era/value/ancestry
  and allocate no foreign vocabulary.

Full implementation gates: compile, EUnit, `quod_ask_SUITE`, applicable
consensus/join suites, xref, dialyzer, diff-check, sequentially. No new consensus
gate exceptions. No implementation gates are claimed for this planning edit.

## 9. Documentation amendments after approval

| Passage | Amendment |
|---|---|
| `quod_simplex` moduledoc, vote guards, proposal/finality/barrier comments | coherent view/ancestry rules, useful overlap and application/consensus boundary |
| `quod_simplex:adopt_history` membership boundary comment | replace the current no-child protection only with a proved cutoff excluding old descendants; a parent commit QC alone is insufficient; retain ordinary overlap |
| `active_validators`, `committee_delta`, history committee views, membership action docs | desired facts versus proved activation boundary; distinguish base hash from old-era retirement height/view; caller result at I does not promise N active; preserve singleton selection; no new authority |
| Signing journal moduledoc | crash-safe view decisions, retained evidence, pruning and break |
| `include/quod_ledger.hrl`, ledger and catch-up docs | precise view/height/era binding; remove old skip/depth-one-only claims |
| Ingress and DTX relay comments | one leader projection and custody wake |
| `doc/content-layer.md` around lines 220–262 | replace terminal-skip/adjacent-vote/camp/grace story with the approved protocol |
| `doc/deferred.md` around lines 292–302 | close residual only after implementation and fault/hardware proof |
| `doc/notes-for-gpt.md` historical slot-6180 notes | preserve evidence and append correction, not retroactive success |
| H1/DTX-latency plans and release instructions | throughput comparison, 95%-means gate, honest old-network outcome accounting |

## 10. References and proof boundary

- [Shoup, Sing a Song of Simplex](https://drops.dagstuhl.de/storage/00lipics/lipics-vol319-disc2024/LIPIcs.DISC.2024.37/LIPIcs.DISC.2024.37.pdf)
  and full version `doc/simplex_extended.pdf`, §§2.3–3.3.
- [Buchman/Kwon/Milosevic, v3 Algorithm 1](https://arxiv.org/pdf/1807.04938v3):
  reference for the superseded multi-value round discussion, not a second
  implementation branch or approval to replace the fixed-era Simplex pipeline.

Diagnosis and the pipelined view/height baseline are accepted. Review confirmed
the handover, temporal-taint, classification and v2 mode/round objections.
V4 removes the latter machinery and reuses the fixed-era carrier mechanism.
Its proposed handover nevertheless permits the same-base old-rung/new-child
counterexample in §4.3.9. No implementation.
Historical witnesses remain at `/tmp/quod-handover-proof.uQlvgn/` and
`/tmp/quod-membership-round-proof.Pj4253/`; they do not describe active round
implementation work. Current v4 checker/output:
`/tmp/quod-pinned-ladder-proof.iM99TR/`. It separates fixed-O positive controls
from the explicit cross-era signing/evidence counterexample. It is not a full
protocol, cryptography, production codec or persistence model.
The k-bound attribution in §4.4 distinguishes the published stable-leader
protocol from Quod's adaptation. Neither a scratch model nor the name of a
published protocol substitutes for proving its actual Quod composition.
No proposed throughput gain has yet been measured, and the unchanged §6/H1
gate still applies.
