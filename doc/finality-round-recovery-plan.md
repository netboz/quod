# Finality recovery without sacrificing write throughput — review draft

Status: **approved pipelined baseline; membership-round recommendation under review;
not approved for implementation**. Source reviewed at `b7c497e` / 0.7.143 on
2026-09-07. Claude withdrew the per-slot rounds recommendation and accepted
protocol-faithful pipelined Simplex with separate views and ledger heights.
Both grandchild and first-observed-finality handover candidates are refuted.
The reviewer now also confirms §4.3.7's temporal counterexample and withdraws
complaint taint. The replacement candidate is **declared activation views**:
ordinary committed intent, then sequential activation with in-view rounds.
§4.3.9 records that direction and the still-missing certified entry boundary
when the intent itself is pipelined, plus the intent/activation/SKIP lifecycle.
Decided-value exclusivity remains accepted. The SKIP bytes in §4.3.8 are a
review candidate, not permission to implement the still-unproved composition.
Do not implement a shorthand
"Tendermint-style" lock without its exact voting and evidence rules.
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
in §4.3 still block implementation. The new recommendation explicitly confines
rounds to closed membership barriers; it does not authorize rounds underneath
an open Simplex child pipeline or sequential consensus for ordinary writes.

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
| Sequential membership with in-view rounds | New, narrower review recommendation: no child may extend unresolved membership; DTX and ordinary payloads keep the fixed-era pipeline. Mixed final votes can witness a round change, unlike the rejected complaints-only sketch. The support/lock/skip rules and certified barrier-mode boundary still require proof; this is real new consensus state, not a free exception. |
| Complaint-taint mode selection | Withdrawn by Claude after §4.3.7: later knowledge cannot change earlier portable complaint shares. No evidence-field patch or revocation. |
| Declared activation views (intent/activation split) | Latest candidate: choose activation mode from agreed history before voting, not proposal-arrival knowledge. Adds an intent commit to membership operations. Entry across an unfinalized intent and exact lifecycle semantics remain open in §4.3.9; no implementation approval. |

Stable leaders and other throughput variants are not folded into this repair.
Evaluate them separately only if measurements justify their added scope and
fairness tradeoff. No second engine, verifier or configurable compatibility mode.
The proposed membership-specific voting discipline is nevertheless additional
protocol complexity; sharing an owner does not itself prove the composition.

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

**Membership recommendation's explicit extension:** recovery votes also bind
their in-view round. Re-proposing the exact membership value in another round
does not change its view, bytes, parent or value hash. Round is vote/proposal
attempt metadata, never a mutable part of the locked value. Fixed-era views
retain the reviewed per-view discipline. The shared format must distinguish
these meanings without a legacy decoder or implicit round alias.

The finalized ancestry appends at contiguous ledger heights. Failed views
produce neither fact changes nor synthetic terminal entries. A genuinely
committed empty carrier is a block and receives an append position, unlike a
view skipped by complaint evidence. DTX exact references bind **ledger heights,
not views**, retaining their exact-entry/hash/finality binding. A bare numeric
height is not a proof. No caller-supplied height/view alias may select an entry.

Fixed-era once-only append uses unique notarization per view. With recovery
rounds, the membership proof must instead establish a unique **decided value**
for that view: standard round locks do not promise that only one value can ever
be notarized across all rounds. The ancestry walk deduplicates finalized views
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
production when it extends a notarized, unfinalized parent without crossing
unresolved membership. The shared payload gate retains ordinary semantic
checks; an unresolved membership **activation** parent admits **no child**,
empty or non-empty. The proposed intent is ordinary fixed-era content and does
not activate a committee; its transition into a declared activation view still
needs §4.3.9's entry proof. Do not silently give it the same no-child restriction.
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
executor. The **membership** exclusion survives: membership cannot be finalized
by a descendant. Its round recovery stays within the old committee in §4.3.

Direct healthy finality needs no carrier to prove the write. That is not a
promise of zero carrier traffic: the entering-view edge can race final votes
even on a healthy network. Preserve useful payload overlap, and count actual
carriers as cost, not useful writes. Both mandatory membership carriers and
carriers above unresolved membership are withdrawn; §4.3.4 records the rule. Historical
verification cannot depend on the receiver's current lack of a certificate.

### 4.3 Committee changes are the hardest boundary

Committees come from committed `peer_admitted` facts. A speculative child
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

The latest recommendation preserves the sequential boundary for an activation
block A, preceded by an ordinary intent I. O directly finalizes A before **any
child** of A can be proposed. Contested A recovers in its view using rounds;
DTX and intent blocks remain fixed-era. This shifts the entry problem to I→A;
it does not prove that boundary automatically. §4.3.9 records the candidate
and remaining obligations. The historical schedules below call the actual
committee-changing block M; they are not descriptions of the new intent I.
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

**Focused re-check of sequential membership:** step 2 is refused. O cannot
support C over unresolved M, irrespective of whether C is empty; once M is
certifiably committed, the shared verifier selects N for its child. There is
no O-signed child certificate to race with G. This closes this exact witness;
it does not prove the proposed in-view recovery or its mode-selection rule.

Source grounding: today's `implicit_finality` rejects committee barriers
(`quod_simplex.erl`, around 597–605), and `adopt_history`'s boundary comment
(around 9387) explicitly relies on **no next-slot proposal before committee
finality**. That exclusion and boundary comment survive this recommendation;
they are not stale code to delete. Allowing old-era carriers removed their
protection. The paper's
§2.3.3/§2.4 separates certificate-based commitment from notarization-driven
view advance; §3.1's quorum intersection assumes one committee. None of these
is a proof that the proposed overlapping eras are safe.

#### 4.3.4 Candidate boundary: ordinary intent, sequential activation

One payload/ancestry validation seam owns the distinction:

| Parent/work | Progress while its direct finality is unresolved | Authority |
|---|---|---|
| Ordinary fixed-era content | existing useful payload overlap; carrier if needed | same certified committee |
| DTX control barrier | empty carrier after deterministic validation; application ordering remains fenced | same certified committee |
| Membership intent I | ordinary fixed-era pipeline/carriers; commits intent facts, not a new voting set | O; I→activation entry still requires §4.3.9 |
| Declared membership activation A | no child of any kind; recover the **same view** in rounds | O until A's direct decision; N only for certified descendants of committed A |

An empty carrier has no activation escape privilege. Both live support and
history validation reject one above unresolved A. A receiver learning A's
commit later cannot retroactively turn an old-era child into valid evidence.
The first appended descendant of A is at its next ledger height; its protocol
view may have gaps, so "slot+1" must not silently re-conflate views and heights.

The review recommends an intent-pinned activation value A and a possible explicit
`skip-of-view` value, with round-free value bytes, round-bound votes, and
round-change evidence containing a quorum of distinct old members' final votes
of **any** kind for one round. A 2-commit/2-complaint split can supply that
quorum. Commit votes retain a value/round lock; complaints do not erase it.
Higher-round re-proposal/relocking must obey the exact support guards below.
This is proposed additional consensus state, not existing code or a second
runtime owner. SKIP need not exclude old notarizations; it must exclude a
different decision. The boundary against ordinary view escape is still open
(§4.3.9); specifying SKIP bytes alone does not close it. The taint candidate
in §4.3.7 is withdrawn, not an optional implementation of that boundary.

Healthy A can finalize directly in round 0, but the new intent I adds **one
ordinary commit per membership operation** relative to the former one-stage
proposal. There is no justified zero-cost claim: entry/drain rules may add
membership-path costs beyond this minimum. Ordinary unrelated traffic must
retain its useful overlap. "Round 0 is byte-identical" is not an approved
format claim; rounds, journal and certificate consumers change in the cut.

O must retain quorum liveness until the membership decision. Losing that quorum
is explicit unavailability: no timeout, minority, read certificate or N-only
vote may activate N. Restart must preserve the old-era round decisions, locks,
retained value and supporting evidence before any signature is exposed.

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

#### 4.3.6 Round rules: accepted corrections and proof boundary

The comparison is the actual Tendermint v3 Algorithm 1, not its name. Its
support/prevote choice consults the retained lock and a verified *earlier-round*
support certificate; quorum final votes of different kinds advance recovery,
but do not choose or finalize a value. A nil final vote is not a committed skip.
The lock and most recent supported value serve different roles.

The latest review closes the following distinctions, not the whole composition:

1. **Guard support, not only final votes.** Without prior supporting evidence,
   a locked voter supports only its locked value (or refuses). For a different
   value, the proposal must carry a valid support certificate from round `vr`
   with `locked_round < vr < current_round`. Algorithm 1 writes `<=` for
   the lower bound: for a **different** value, a conflicting QC at the lock's
   own round is already impossible by same-round quorum intersection. These
   are equivalent on genuine certificates, not two unlock paths. A numerically higher
   round is no permission to help form the very conflicting QC used to unlock.
   Membership, unique signers, view/value/round binding and actual QC validity
   are checked by the existing verifier. Retain the latest supported value/QC
   for re-proposal even if the validator had already complained in that round.
2. **Complaint is not SKIP.** Three complaints or a mixed final-vote quorum
   prove neither "M never notarized" nor a decision on an explicit SKIP value.
   Claude explicitly withdraws `skip-wins-only-if-never-notarized` and accepts
   **decided-value exclusivity**. Counterexample: Byzantine z receives
   support(M,0) from a,b and adds its own signature, retaining the QC privately.
   No honest validator sees the QC or locks M. All three honest validators
   complain; in round 1 they can support and commit a separately proposed SKIP
   under ordinary unlocked voting. Revealing QC(M,0) afterwards violates the
   "never notarized" promise, though it does **not** by itself create conflicting
   finality. Accept this schedule; no global absence test is required.
   Before decision, authentic old support evidence may justify a later proposal
   under the prior-round guards; it does not automatically replace a newer
   retained value or lock. After decision it cannot reopen the view or revoke
   its outcome. An explicit SKIP needs its own proposal and support/commit
   quorums. It appends nothing and does not change the committee; retained
   unapplied work remains in ordinary custody, with no fabricated abort,
   new client request, author sequence or uncertain-write resubmission. The
   latest proposal now introduces an already-committed intent transaction;
   its consumption/retry semantics need the separate closure in §4.3.9.
3. **One certified view-escape rule remains missing.** Claude proposed signed
   membership evidence in complaints, park-on-evidence, and ordinary skip only
   from an entirely untainted complaint quorum. §4.3.7 refutes the proposed
   intersection proof even when all evidence is signed and cannot be stripped.
   Later knowledge cannot change an earlier share; Claude now confirms this
   and withdraws that proof. Declared views replace the candidate in §4.3.9,
   conditional on the entry boundary there. Do not adopt the taint candidate
   or silently replace it with an irreversible exit rule. Initial-leader
   content/membership and M1/M2 equivocation must be included in the eventual
   composition proof, not dismissed by per-round uniqueness alone.
4. **Progress and retention.** Define the round leader, same-round final-vote
   exclusion, handling of old valid decisions, supported-body/QC custody,
   restart floors and evidence-driven wake/replacement of placement. Mixed
   final-vote evidence is formable, but formability alone is not a liveness
   proof. The existing readiness-gated head watchdog is the proposed failure-
   detection owner; safety is independent of timing. Liveness needs eventual
   synchrony, an available old quorum and sufficient time for proposal/evidence
   dissemination and validation. A fixed configured Delta is not automatically
   Tendermint's increasing-timeout proof; the sufficient-delay assumption and
   round-leader progress must be explicit. No success-path polling, delay
   ladder or second pacemaker process is authorized.

   Map dissemination precisely: Simplex's `emit_slot_evidence`, existing
   transport outboxes and certified-body request/response own unfinalized
   proposals/shares/QCs. `quod_feed` disseminates **finalized** history; it
   does not presently gossip an uncommitted membership proposal or validValue
   QC. Extending retained evidence at the same owners must show that evidence
   learned by one honest validator reaches the others after synchrony, including
   after its leader disappears. Naming the feed/outbox is not that proof.

The bounded witness checks the no-child refusal, 2/2 round-1 recovery under
these lock guards, rejection of a Byzantine higher-round conflicting proposal,
and the hidden-notarization/SKIP schedule. The extension below checks immutable
complaints and delayed evidence. It still takes valid proposals and round
leadership as inputs, not a proof of distributed mode selection or liveness.
The implementation remains blocked
pending this focused sign-off. No ordinary-throughput regression is authorized.

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

#### 4.3.8 Explicit SKIP value — byte-level review candidate

Resolve the independent representation question without implying that §4.3.7
is solved. Propose this closed, fixed-length variant in the **same value codec**:

```erlang
SkipBytes = <<"quod/simplex/skip", 0, 1:8,
              Domain:32/binary, EraStartHash:32/binary,
              View:64/unsigned-big, ParentHash:32/binary>>.
SkipHash = crypto:hash(sha256, SkipBytes).
```

`Domain` is existing `consensus_domain(Ns, GenesisHash)`. `EraStartHash` is the
canonical block hash that activated O (genesis for the founding era), derived
from the same certified ancestry, never a certificate-signer subset hash or
the proposed activation A. A's hash becomes **N's** era-start hash only after
A commits; it must not replace O's era binding in votes for A or SKIP.
`ParentHash` is the shared, validated pre-view
parent selected by the eventual entry rule; another parent cannot create a
second lock/decision domain in the same era/view. That entry rule must reject
it, not let a signer vote in both domains. `View` retains the
existing unsigned-64 representation, now a view rather than an append height.
No round, timestamp, candidate-M hash, map, optional field or trailing bytes.
M1/M2 equivocation therefore cannot mint distinct skips for the same instance.

The ordinary proposal/share codec's cut-version domain and vote-kind separation
bind `(Domain, EraStartHash, View, Round, SkipHash)` just as they bind another
membership-round value hash. No separate signer/verifier or SKIP-as-complaint
alias. Membership SKIP is valid only inside a **certifiably entered** instance;
§4.3.9 still owes that entry rule. A complete old-quorum SKIP decision excludes
any other decided value for the instance; a complaint quorum does not decide it.
Retain/carry its certified view-gap evidence through the existing journal and
history verifier, without a ledger block, content mutation, effect or authority
change. This does not make the journal's retained decision evidence volatile.
Reject wrong domain/era/parent/view, alternate encodings and complaint-as-commit.
This grammar is for focused review only; no producer or parser is implemented.

#### 4.3.9 Declared activation views — candidate and remaining boundaries

Review `93966c67-ad65-4147-874e-e842bbaa1aba` confirms the U/T counterexample
and withdraws the taint proof. Its replacement is structurally different:
commit intent I in ordinary fixed-era consensus, then recover activation A
in rounds at a view **declared before voting by agreed history**. At an entered
activation view, only the intent-pinned A or explicit SKIP is eligible;
complaints are round-change votes, not ordinary view-skip evidence. A commits
under O; its children use N. Intent on a losing, unfinalized branch does not
authorize a committee change. This direction is recorded, not yet proved.

**Conditional result:** given one agreed entry prefix and intent, the old
taint problem disappears: every voter uses the same grammar, surprise payloads
are invalid, and the pinned A recovers the 2/2 split in round 1. The witness
checks those properties under an explicitly given entry prefix. That assumption
is the unresolved part, not a distributed protocol established by the test.

**Entry before votes, including the intent's pipeline.** The review's statement
that existing readiness requires every candidate's parent to be applied is
false for ordinary content. `proposal_slot` (around line 8530) deliberately
permits H+2 over approved H+1 before H+1 commits; `valid_proposal` binds the
approved parent (around 12122); `may_vote` (around 13959) checks participation/
catch-up capability, not equality of approved and finalized heights. The
approved new protocol preserves this useful overlap.

Consider finalized P, followed by notarized intent I in view v. Delay I's
commit certificate while an ordinary child C in view v+1 is supported, which
the proposed ordinary-intent rule permits. Then reveal I's finality. The same
ancestry now contains a **committed** unconsumed intent and the proposed rule
classifies v+1 as activation-only. C's already-signed ordinary votes cannot
change meaning. Different arrival times likewise permit different live
classifications. Calling "committed" a global fact rather than local knowledge
does not help a voter lacking that certificate.

This is a counterexample to the claimed entry/readiness premise, not a complete
ledger-fork simulation or a proof that intent/activation is impossible. An
explicit prefix/entry certificate in the proposal could be part of a solution,
but its selection must prohibit competing ordinary/activation entry evidence
for the **same** view, including previously supported children. Merely freezing
all children of unfinalized I is insufficient: I is an ordinary view, so its
2-commit/2-complaint split then has neither a terminal QC nor a carrier and
recreates the original stall. Changing the trigger to notarized intent changes
the premise and must cover losing branches and the earlier cross-era schedules.
No implicit extra drain barrier or serialization of every ordinary block.

**One committee-fact projection, not two authorities.** The split also needs
an exact materialization contract. Today `committee_delta` derives membership
from ordinary `peer_admitted` diffs for both live and replay (around 15275).
An actually empty A cannot change those facts by the existing reducer. There
is, however, an existing intended/active distinction worth reusing:
`active_validators` (around 15392) documents the epoch-projection seam but is
currently the identity over committed committee facts. Review whether I
commits the desired facts and A activates that certified snapshot through this
same projection, rather than inventing a second pending-membership registry.
That is a candidate simplification, **not existing epoch support**: catch-up,
historical committee selection, live votes, routing and authorization consumers
must all agree on which set is active. Otherwise specify how A applies the
already-authorized change through the one committed reducer. Do not describe
an empty block changing Prolog facts as already implemented or harmless.

**Intent consumption, outcomes and SKIP remain unspecified.** The review says
SKIP consumes I and returns the membership transaction to custody for a fresh
intent. But I has already committed: `duplicate_transaction` in the shared
projection returns its prior result without reapplying it. Re-queueing its
same signed bytes cannot create a fresh intent. A new signed intent is a new
transaction and needs an explicit authorization/result contract; it is not
ordinary placement of an uncertain submission.

Specify what the original caller observes when I commits versus A activates;
where consumed intent is durably evidenced after SKIP when no new ledger
block follows; how a fresh verifier/restart derives that same state; and how
multiple pending intents or a stale desired committee are ordered/validated.
Existing QSJ4/gap-evidence ownership may be reused, but local knowledge alone
cannot consume a committed fact. No synthetic success/abort, silent re-signing,
automatic client resubmission, or new lifecycle/result owner.

**Potential simplification for review:** if the committed intent pins an always-
valid A, is SKIP still needed at all? Removing it could remove consumption,
fresh-intent retry and alternative-value locking obligations. If cancellation
or activation invalidity makes it necessary, name that case and its semantics.
This is not an adopted rule or a solution to the entry race. Similarly, the
activation value must be byte-pinned by the intent/entry, without round-dependent
timestamps or leader choices silently producing different A values.

The added commit is a disclosed **minimum membership cost**, not a measured
latency bound or proven full-overlap claim. §6 is unchanged. No source code,
new certificate implementation, timer, cache, owner or authority is authorized.

### 4.4 The live window must permit the required progress

**Reviewed rule:** the depth bound governs payload-bearing advancement only.
Fixed-era empty finality-carriers are exempt and may chain. They cannot cross
the membership barrier in §4.3. This is a payload/protocol
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
Fixed-era pipeline voting adds no Tendermint lock. The membership recommendation
does add round-scoped latches, `lockedValue/lockedRound`, and
`validValue/validRound` with the latest supported value's exact body and QC
at this **same journal owner**, conditional on §4.3's proof. Do not hide this
change behind the old blanket "no locks" sentence or duplicate custody.

The signing journal remains the sole persist-before-exposure owner. Persist
the exact supported bytes and support latch atomically; persist the final
commit-or-complaint latch before exposure. Remove adjacent-view exclusions,
not fixed-era same-view or membership same-round non-equivocation. **QSJ4
replaces QSJ3**, without compatibility; the exact membership-round schema is
part of the pending sign-off, not an approved era-agnostic implementation.
The lock and validValue may name different rounds/values: retain both obligations,
not one "latest" row overwriting a still-required lock. Late evidence cannot
overwrite a newer validRound; a decision is terminal. Restart retains every
outstanding view's required body/evidence and signing
floor. Reuse exact byte/parent/era-bound validation in existing candidate state,
not a new cache. Temporary evidence unavailability is not ordinary Prolog
failure. Proposer loss cannot strand required bytes.

A membership round change must also re-project its leader and invalidate old
placement at the existing ingress/custody owners, without changing the request
bytes or author sequence. No global-view advance is inferred from a round
change alone. The mode/escape proof in §4.3.6 must close before implementing it.

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
| `quod_simplex` | one engine, useful fixed-era pipeline, certificate pool, validation workers, ordered finalization; activation explicit-finality/no-child barrier | coherent view/ancestry progress; reviewed activation-entry/recovery; assess existing `active_validators` epoch-projection seam rather than add a membership registry; terminal complaint-to-ledger-skip, adjacent-slot voting exclusions, camp/grace machinery |
| `quod_signing_journal` | atomic supported-body/vote custody, DTX/content custody | fixed-era per-view latches and reviewed membership-round lock/custody in QSJ4; remove adjacent-view exclusions, not equivocation guards |
| `quod_ingress_state` and relay custody | existing queues, signed submissions and authenticated delivery | one consensus-derived leader; duplicated leadership calculation and stale placement assumptions |
| `quod_ledger` and records | canonical bytes, store and codec ownership | view/append-position distinction; complaint-certified synthetic terminal entries |
| `quod_catchup` | one chain/era/certificate verifier; direct membership finality and old-era signature boundary | fixed-era ancestry grammar replaces depth-one-only proof assumptions; membership-round finality shares the verifier |
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
   §4.3's membership-round extension, including its effect on those sections.
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
- Gapped views, competing branches and equivalent witnesses: one final chain,
  contiguous append, exact references and no duplicate ancestor apply.
- DTX barrier completes without later user traffic and without premature
  facts/effects/custody release.
- Membership at the same split: disjoint committees, correct signing/activation
  era, removed-member rejection and fresh catch-up agreement.
- **Contested membership:** M's 2/2 split recovers within its view in round 1,
  under the reviewed support/lock rules, without changing an old round's vote.
  A proposed old-era carrier C is rejected, not used for recovery. Conversely
  fixed-era DTX plus contested carrier follows §4.4. Pin both classifications
  through the one shared payload/ancestry gate.
- **Byzantine membership child:** reject both non-empty and empty old-era
  children at shared admission/validation before support, live and on replay.
- The §4.3.2 support-plus-complaint-QC schedule cannot yield both old-branch X
  and new-branch G finality. Check same-view non-equivocation and signer sets
  explicitly; under the replacement rule, G cannot use N before an O commit.
  A test with only 2/2 splits does not cover this safety boundary.
- **Commit-certificate arrival overlap (§4.3.3):** old voters try C while
  QC_O(M) reaches N first. The sequential gate must refuse C before support,
  preventing QC_O(C) and QC_N(G) from finalizing different children.
  A fresh verifier given either evidence bundle first must reach the same
  irreversible boundary; receiving an earlier ancestor QC later cannot revoke
  an already accepted committed carrier.
- **Old quorum unavailable mid-handover:** no N-only activation or minority
  fallback. Pin the explicit liveness limitation; recovery resumes only with
  the required certified old-era authority, not a timer workaround.
- A directly finalized M has its ordinary N-signed next child, with no mandatory
  carrier. A valid **fixed-era** carrier delayed until after parent finality
  still verifies live and on replay; an old-era child of unresolved M does not.
- Byzantine equivocation across membership rounds cannot defeat a retained
  lock: changing a round number is insufficient support evidence; a forged,
  wrong-view, wrong-value or current-round purported prior QC is rejected.
  Count a Byzantine signer's two final votes once, never as two quorum members.
- Mixed final votes authorize recovery only, not a commit/skip decision. Pin
  the reviewed treatment of a privately held old notarization revealed after
  a SKIP decision; do not test a global non-existence predicate as an oracle.
- Round leader loss and restart mid-round preserve the locked/supported value,
  body and votes; normal progress is message-driven. Old valid decisions still
  verify, and N activates only after direct O-certified membership finality.
- Validators disagreeing on receipt of the membership body/QC must not split
  irreversibly between in-view recovery and ordinary next-view advancement.
- **Temporal taint (§4.3.7):** unchanged U={a,b,z} precedes tainted T={a,c,z}
  and membership commit by a,b,c in round 1. The replacement rule must reject
  incompatible certificates regardless of reveal order, without rewriting U.
  Also require progress with two clean shares, one tainted share and a silent
  Byzantine member; permanent per-share exit must not hide a new deadlock.
- A lone parked evidence holder, initial-leader content/M or M1/M2 equivocation,
  and late proposals after already-signed next-view votes must be covered by
  the same proved boundary, not only by a known-mode membership fixture.
- Hidden support QC before decision may supply valid prior-round evidence;
  after decision it changes nothing. SKIP's canonical byte vectors, cross-
  domain/era/view/parent refusal, no append and retained custody are pinned.
- **Declared activation entry:** test the intent while uncommitted, children
  already supported before its finality arrives, losing intent branches, and
  intent plus child each at 2/2. Given-entry activation tests are not enough.
  No existing signed ordinary view may silently turn into a round-based view.
- Prove activation changes the active committee through the same live/replay
  projection; the old era signs A/SKIP, only A's descendants use A's era hash.
- Pin intent selection, activation byte identity, original caller outcome,
  consumed-state recovery after an idle SKIP, and authorized retry semantics
  if SKIP survives review. Re-enqueuing a committed transaction is not a retry
  mechanism; no fabricated receipt or automatic re-signing may make it one.
- Crash around every durable vote/body/send; proposer loss, stale validation
  and live-link replacement; no double signing or lost work.
- Leader/view changes and same-peer revisits re-place retained bytes without
  fresh client requests or author sequences.
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
| `quod_simplex:adopt_history` membership boundary comment | keep direct-finality/no-old-child invariant for activation; document the proved I→A entry and committee projection, **not** refuted park-on-proposal/taint or an applied-parent assumption that breaks ordinary overlap |
| `active_validators`, `committee_delta`, history committee views, membership action docs | settle intended facts versus active-era projection and I/A/SKIP outcomes at existing owners before implementation; no second membership authority or raw fact mutation by an "empty" block |
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
  exact lock/support/decision reference for the proposed closed-membership
  recovery, not approval to replace the fixed-era Simplex pipeline.

Diagnosis and the pipelined view/height baseline are accepted. Review confirmed
both handover counterexamples and the temporal taint counterexample. The latest
recommendation splits intent from declared sequential activation. Given an
agreed entry, no-child and round rules close the old overlap; §4.3.9 still owes
that entry across the intent pipeline and an exact lifecycle/projection
contract. Decided-value exclusivity remains accepted; SKIP bytes are a candidate,
and its necessity is explicitly for review, not assumed. No implementation.
The former witness is retained at `/tmp/quod-handover-proof.uQlvgn/`; the new
bounded checker and output are at `/tmp/quod-membership-round-proof.Pj4253/`.
It assumes a known membership instance and checks the stated ballot/evidence
guards, not a full protocol, availability, transport or mode-selection model.
The k-bound attribution in §4.4 distinguishes the published stable-leader
protocol from Quod's adaptation. Neither a scratch model nor the name of a
published protocol substitutes for proving its actual Quod composition.
No proposed throughput gain has yet been measured, and the unchanged §6/H1
gate still applies.
