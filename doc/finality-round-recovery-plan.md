# Finality recovery without sacrificing write throughput — review draft

Status: **approved pipelined baseline; membership-round recommendation under review;
not approved for implementation**. Source reviewed at `b7c497e` / 0.7.143 on
2026-09-07. Claude withdrew the per-slot rounds recommendation and accepted
protocol-faithful pipelined Simplex with separate views and ledger heights.
Both grandchild and first-observed-finality handover candidates are refuted.
The reviewer confirms both the temporal-taint and committed-intent classification
counterexamples. Contract v2 selects grammar from the **parent value**, allows
activation A to finalize ordinary intent I, and deletes explicit SKIP. These
simplifications are recorded below; the claimed architectural closure is not.
§4.3.9 exposes the remaining **same-view competing-parent** obligation: A above
I and an ordinary bypass above P can each carry valid parent evidence. A value
unique given I is not yet unique for that view. Permanent per-view support and
per-round-only support give different unresolved liveness/safety obligations.
The no-lock journal proposal is conditional on closing that boundary. No custom
unlock, second mode selector or throughput-reducing global barrier is authorized.
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
| Sequential membership with in-view rounds | Retain the no-child boundary for activation A only; I remains ordinary intent. Mixed final votes can witness recovery, not select a parent/mode. The former A-or-SKIP lock design is superseded, not a second implementation option. |
| Complaint-taint mode selection | Withdrawn by Claude after §4.3.7: later knowledge cannot change earlier portable complaint shares. No evidence-field patch or revocation. |
| Committed-intent entry trigger | Withdrawn after the same-parent classification schedule: ordinary pipelining does not require the parent applied; later finality cannot re-type existing child votes. |
| Parent-value activation, no SKIP (contract v2) | Fixes that same-parent race and deletes SKIP lifecycle/codec work. Retains intent I plus activation A, using the existing epoch projection seam. Competing parent I versus bypass parent P still needs one same-view safety/liveness rule (§4.3.9); no implementation approval. |

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
attempt metadata, never a mutable part of the retained value. Fixed-era views
retain the reviewed per-view discipline. The shared format must distinguish
these meanings without a legacy decoder or implicit round alias.

The finalized ancestry appends at contiguous ledger heights. Failed views
produce neither fact changes nor synthetic terminal entries. A genuinely
committed empty carrier is a block and receives an append position, unlike a
view skipped by complaint evidence. DTX exact references bind **ledger heights,
not views**, retaining their exact-entry/hash/finality binding. A bare numeric
height is not a proof. No caller-supplied height/view alias may select an entry.

Fixed-era once-only append uses unique notarization per view. Activation-round
recovery must establish a unique **decided value** for the whole view, including
competing ordinary-parent proposals. Per-(view, round) latches alone do not
establish per-view notarization uniqueness; calling A single-valued given I does
not supply it (§4.3.9). The ancestry walk deduplicates finalized views
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
not activate a committee; its only admissible child is activation A, which may
carry I's finality. This parent-local rule still needs §4.3.9's competing-parent
proof. Do not freeze I until direct commit: that would strand its 2/2 split.
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
executor. The **activation** exclusion survives: A cannot be finalized by a
descendant. Its round recovery stays within O. I changes desired membership
facts, not active authority; A may finalize I through this same ancestry walk.

Direct healthy finality needs no carrier to prove the write. That is not a
promise of zero carrier traffic: the entering-view edge can race final votes
even on a healthy network. Preserve useful payload overlap, and count actual
carriers as cost, not useful writes. The old grandchild-handover carrier is
withdrawn; A-as-I's-carrier is a different, conditional proposal (§4.3.4).
No carrier above unresolved A is permitted. Historical
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
| Ordinary fixed-era content without pending intent | useful payload overlap; carrier if needed | same certified committee |
| DTX control barrier | empty carrier after deterministic validation; application ordering fenced | same certified committee |
| Membership intent I | only deterministic A may extend this parent; A may carry I's finality | O; no active-era change at I |
| Membership activation A | no child of any kind; recover the **same view** in rounds | O until A's direct decision; N only for certified descendants of committed A |

These are **parent-local** rules, not proof that all proposals in a view share
the same parent or mode. That remaining boundary is §4.3.9. An empty carrier
has no escape privilege above unresolved A. A receiver learning A's commit
later cannot retroactively validate an old-era child. The first descendant's
append position follows A; its view may have gaps, so do not call it view A+1.

Contract v2 deletes explicit SKIP and proposes one activation value for the
given intent/entry, with round-free value bytes and round-bound votes. A quorum
of distinct old members' final votes of any kind may witness round recovery,
so an agreed activation's 2-commit/2-complaint split can progress. Complaints
are not themselves a decision. This is not a proof that activation complaints
and ordinary bypass complaints can safely mix; their shared entry/escape
semantics remain unspecified. No-lock recovery is therefore conditional, not
an approved signing schema.

A must be constructible from the **notarized, available I and its validated
ancestry**, without needing I's commit certificate. Requiring committed I,
as one sentence in the feedback does, would contradict A's carrier role and
recreate the intent's latched-split deadlock. A must also remain constructible
if O is later unable to contact prospective members of N; no new-member vote
is authority for activating N, nor may liveness assume their cooperation.

The cost is two ledger values I+A per successful change, one extra entry
relative to a one-stage change, plus sequential recovery at A when contested.
It is **not necessarily two separate direct commit certificates**: committing
A can finalize both entries. Measure the actual critical path, votes, journal
writes and carrier traffic; do not promise a universal additional commit
delay or zero overhead. Ordinary non-membership overlap remains required.

O must retain quorum liveness until activation. Losing that quorum means
unavailability; no timeout, minority, read certificate or N-only vote can
activate N. Restart must preserve the old-era retained value/evidence and
all signing obligations before exposing another vote.

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

#### 4.3.6 Earlier multi-value round rules — superseded design, retained lessons

The former A-or-SKIP recommendation used Tendermint v3 Algorithm 1 as the
reference for exact prior-round support guards and commit locks. Contract v2
deletes the alternative SKIP value, so that lock/validValue design is **not an
active implementation branch**. Its earlier bounded witness stays labelled
historical; it does not establish the new proposal's lock-free composition.

Three lessons still bind:

1. A round number alone does not establish safety. Per-round non-equivocation
   cannot be cited as per-view uniqueness. If competing values are possible,
   their support, decision and escape rules need an explicit proof; never graft
   an ad-hoc unlock onto unchanged descendant-finality semantics.
2. A complaint is not absence of notarization. In the former design z could
   hide supportQC(M,0), honest voters complain, and a later SKIP decide before
   that QC appeared. This refuted “skip only if never notarized,” not by itself
   decision agreement. The same knowledge error matters now: supportQC(I) and
   complaintQC(I) can coexist. No certificate is revoked by later revelation.
3. Mixed final-vote evidence is formable, but is recovery evidence, not a
   decision or a proof of common parent/mode. The temporal-taint boundary below
   and the committed-intent entry trigger were both withdrawn on that basis.

Progress still requires eventual synchrony, an available old quorum, an honest
round leader eventually, and sufficient time for evidence/body dissemination
and validation. The existing readiness-gated head watchdog is the proposed
failure-detection owner; safety cannot depend on timing. A fixed Delta does
not automatically inherit an increasing-timeout liveness proof. No success-path
polling, retry ladder or second pacemaker is authorized.

Map evidence distribution at the existing owners: Simplex's
`emit_slot_evidence`, transport outboxes and certified-body requests carry
unfinalized proposals/shares/QCs; `quod_feed` carries **finalized** history,
not an uncommitted activation proposal. Show that authentic evidence learned
by one honest validator reaches the others after synchrony despite leader
loss. Naming those owners is not the proof.

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

#### 4.3.8 SKIP deleted; retained activation-byte and era obligations

Contract v2 removes explicit SKIP, its codec variant, consumption/gap lifecycle,
fresh-intent retry and alternative-value journal machinery from the proposed
cut. The former byte draft is deleted, not parked as a compatibility shape.
Historical SKIP counterexamples in §4.3.6 describe the withdrawn design only.
Ordinary Simplex complaint evidence remains; it was never that explicit value.

Use the existing canonical value codec and signing owner. A's exact value
must be determined by the certified intent, selected entry view/parent and
old-era context. `A(I)` is shorthand, **not** permission to re-use the same
view-bound bytes in several views: §4.1 still requires one view per value.
With that entry fixed, proposers and rounds must produce identical bytes,
without local timestamps, round numbers or leader choices in the value.
The actual byte vectors await the still-open entry rule, not a new encoder.

Votes for A use O's era-start hash: genesis for the founding era, otherwise
the canonical activation hash derived from the certified prefix. A's hash
starts N's domain for **descendants after A commits**, never A's own votes.
Equivalent quorum signer subsets cannot change that identity. Wrong
domain/era/view/parent/value binding is rejected by the same verifier.

#### 4.3.9 Parent-value activation — contract v2 and the remaining boundary

Review `a8418e38-1516-472c-bd37-30de1ac269fe` withdraws the committed-intent
trigger and proposes the following contract. It is folded here as a
**candidate**, not accepted as architecturally closed.

**What the revision fixes.** Previously an ordinary child C could already
have votes above notarized I; revealing I's commit then reclassified that same
ancestry as activation-only. Ordinary readiness does not require that parent
applied: `proposal_slot`, `valid_proposal` and `may_vote` deliberately permit
approved-uncommitted parent overlap. The reviewer confirms this counterexample.
With grammar determined by retained **parent values**, an ordinary C above I
is invalid before and after I's finality; A is the only child for that parent.
This closes the same-parent classification race without freezing I.

I remains ordinary content, committing desired facts but changing no active
committee. A is a directly finalized old-era barrier and may implicitly
finalize I. Given the same I/entry, no alternative SKIP is needed: complaints
change the recovery round; leaders re-propose the same A; cancellation of a
committed change is a later, separately authorized countermanding intent.
This removes consumption/retry machinery, not ordinary transaction dedup.

**The missing premise: agreement on the parent/mode for the view.** The feedback
itself permits both A(parent I) and ordinary bypass B(parent P), where I extends
P and a complaint certificate gaps I's view. Both proposals may be correctly
leader-signed. Reconstructing the grammar for each parent does not select
between them. Two assertions in the review do not close this:

- I's **support QC and complaint QC can coexist** under ordinary Simplex.
  Sign support, delay its assembled QC, then complain; no direct commit vote
  is needed. SupportQC(I) supplies A's parent; complaintQC(I) permits bypass
  parent P. Both entry premises certify. ComplaintQC(I) excludes I's *direct
  same-view commit QC*, not I's **ancestor finality via A**. Indeed the new
  contract explicitly lets I's complainers commit A.
- “Per-view support uniqueness” is not established by the proposed
  **per-(view, round)** latches. A is unique given I, but ordinary B and A are
  different values for the same view. The fixed-era uniqueness proof cannot
  silently replace a per-round premise with a per-view one.

The following bounded schedules isolate the two possible latch readings.
O={a,b,c,z}, q=3, z Byzantine. They do **not** claim a production fork.

| Latch reading | Schedule | Obligation exposed |
|---|---|---|
| One supported value per view across all rounds | At view V, z sends valid A/I to a,b and valid B/P to c, using the coexisting parent certificates, then goes silent. a,b retain A; c retains B. | A has at most two honest supporters and B one. Activation-only round complaints have two signers; ordinary-only skip complaints one. No stated support or typed-escape quorum forms. Even a later mixed round witness cannot erase permanent per-view choices. |
| Only per-(view, round) support | B can obtain support by a,b,z in round 0; A can obtain support by a,b,c in round 1, under these latches alone. | Two notarizations of V do not violate same-round non-equivocation. This refutes the asserted uniqueness lemma, **not by itself finality agreement**: a full legal cross-mode round-entry/decision schedule still requires the missing guards. |

The first row is a liveness counterexample **to the literal permanent-latch,
mode-separated escape rules**, not a claim that every possible rule deadlocks.
The second is a ballot-level counterexample **to latches-alone uniqueness**,
not an assumption that unspecified cross-mode recovery is already legal.
Both need a single architectural answer, not a test that supplies common
entry as an input and calls that agreement.

**Required closure:** specify the exact same-view rules for support,
commit/complaint, round entry, ordinary view escape and late certificates
when the parents select different grammars. Prove safety and post-synchrony
progress without z, including a QC held privately before reveal. If a guard
excludes one schedule, state its locally verifiable evidence and show how the
losing honest voters resume. No vote erasure, absence-of-QC oracle, mutable
certificate, new selector owner or global ordinary-write serialization.
Do not repair the gap by restoring arbitrary locks around the rejected
rounds-plus-unchanged-child-finality hybrid (§3). A different complete boundary
may be proposed, but must close both safety and liveness before code.

**One committee projection, no second authority.** Reuse `active_validators`:
its reserved epoch-snapshot seam is real, but currently returns committed
membership facts unchanged. `committee_delta` still folds desired facts at
I in the ordinary live/replay reducer; voting/leading/disseminating authority
is those facts at the last certified activation A. A activates that snapshot;
it does not secretly mutate Prolog facts. The epoch reference/snapshot lives
at the existing consensus/projection owner, not in a new pending registry.
Local voting, `adopt_history`, `history_committee`, current-view verification,
catch-up, route eligibility and committee-based authorization must derive the
same active era from that prefix, not switch early by reading desired facts.
Ordinary target ACLs are unchanged; “committee-based” is not a new ACL layer.
A is old-era-signed; only its descendants use N (§4.3.8).

**Caller and ordering contract.** The original ordinary result is delivered
at I's commit: it acknowledges desired membership facts, **not necessarily
that N is already active**. A may have finalized I in the same ancestry walk,
but two success states must not be conflated. Existing projection/status
owners expose activation; no second receipt, synthetic abort or automatic
resubmission. A losing uncommitted I has no successful intent result; retained
signed work follows ordinary custody. `duplicate_transaction` still prevents
a committed I from being re-applied as if it were a fresh authorized change.

“No ordinary descendant above I until A” serializes separate intent blocks
on one branch; it does **not** decide how several intents in one candidate
payload are selected. Current membership transactions are singleton in
`membership_payload_shape`/`is_membership_change`. Do not silently remove that payload
rule when separating the no-child barrier: either retain its existing
deterministic selection semantics or specify/prove a replacement. This is a
remaining payload clarification, not a new capacity cap. Two queued intents,
losing branches and later countermanding facts need explicit live/replay tests.

**Witness scope.** The extension reproduces the coexisting I certificates and
both latch-reading obligations above. It checks the same-parent refusal and,
with parent/activation supplied as inputs, lock-free 2/2 round recovery, model
restore and A-as-carrier. It does not implement parent selection, cryptography,
actual canonical A bytes, production journal recovery or era projection.
Deterministic codec vectors, multiple-intent processing and removed-validator
tests remain required after the entry contract is settled; none is claimed
passed from this small witness.

SKIP removal and owner reuse simplify the proposal. They do not establish
same-view mode agreement. No source/format/fleet change is authorized; §6's
throughput and H1 gates are unchanged. The next review must close this precise
boundary rather than approve a fixed-parent test as the full protocol.

### 4.4 The live window must permit the required progress

**Reviewed rule:** the depth bound governs payload-bearing advancement only.
Fixed-era empty finality-carriers are exempt and may chain. They cannot cross
the activation barrier in §4.3; above I, only A is eligible. This is a payload/protocol
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
Fixed-era pipeline voting adds no Tendermint lock. Contract v2 proposes only
round-scoped activation latches and exact supported-body/evidence custody at
this **same journal owner**. The former SKIP/lock/validValue schema is withdrawn,
not retained as an optional path. The single-value argument on which lock-free
recovery relies is still conditional on §4.3.9's same-view parent/mode proof.
Do not replace that proof with either an extra lock or a “no locks” slogan.

The signing journal remains the sole persist-before-exposure owner. Persist
the exact supported bytes and support latch atomically; persist the final
commit-or-complaint latch before exposure. Remove adjacent-view exclusions,
not fixed-era same-view or membership same-round non-equivocation. **QSJ4
replaces QSJ3**, without compatibility; the exact membership-round schema is
part of the pending sign-off, not an approved era-agnostic implementation.
A decision is terminal; late evidence cannot erase a signing obligation or
reopen an outcome. Restart retains every outstanding view's required exact
body/evidence and signing floor. The eventual schema must express the proved
cross-mode rule, not invent one by choosing its map keys. Reuse exact
byte/parent/era-bound validation in existing candidate state,
not a new cache. Temporary evidence unavailability is not ordinary Prolog
failure. Proposer loss cannot strand required bytes.

A membership round change must also re-project its leader and invalidate old
placement at the existing ingress/custody owners, without changing the request
bytes or author sequence. No global-view advance is inferred from a round
change alone. The parent/mode proof in §4.3.9 must close before implementing it.

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
| `quod_simplex` | one engine, useful fixed-era pipeline, certificate pool, validation workers, ordered finalization | intent ordinary / activation no-child classification at `payload_is_consensus_barrier`; proved parent/mode recovery; activate the existing `active_validators` epoch-projection seam; delete terminal complaint-to-ledger-skip, adjacent-slot exclusions, camp/grace machinery |
| `quod_signing_journal` | atomic supported-body/vote custody, DTX/content custody | fixed-era per-view latches and reviewed activation-round custody in QSJ4; no explicit SKIP or unproved lock schema; remove adjacent-view exclusions, not equivocation guards |
| `quod_ingress_state` and relay custody | existing queues, signed submissions and authenticated delivery | one consensus-derived leader; duplicated leadership calculation and stale placement assumptions |
| `quod_ledger` and records | canonical bytes, store and codec ownership | view/append-position distinction; complaint-certified synthetic terminal entries |
| `quod_catchup` | one chain/era/certificate verifier; old-era signature boundary | fixed-era ancestry grammar replaces depth-one-only proof assumptions; direct activation finality and I-as-ancestor use that verifier and the same active-era projection |
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
- A valid fixed-era carrier delivered after its parent's finality still
  verifies; proposal validity cannot depend on certificate arrival order.
- Gapped views, competing branches and equivalent witnesses: one final chain,
  contiguous append, exact references and no duplicate ancestor apply.
- DTX barrier completes without later user traffic and without premature
  facts/effects/custody release, including contested fixed-era carriers.

Membership tests must exercise distributed entry, not only inject a common
parent/mode into a unit fixture:

- **Same-parent grammar:** a correctly signed ordinary child above notarized I
  is refused before support, both before and after I's finality. Parent-retained
  restart derives the same answer. No applied-parent assumption or vote retyping.
- **Competing parents (§4.3.9):** genuine supportQC(I) and complaintQC(I);
  A/I versus ordinary B/P in the same view. Check both evidence reveal orders,
  per-view and per-round guards, and late higher-round evidence after bypass
  children have already received votes. Pin whichever exact rule resolves
  this case, then show one final chain **and** progress without z.
- **Mixed knowledge / silent leader:** a,b see A/I, c sees B/P, z withholds
  cooperation. No test may assume a common mode or use z's signature to escape
  the two-versus-one honest partition. A lone evidence holder and two distinct
  intent parents must be covered too.
- **Intent 2/2 then activation 2/2:** A is constructed before I's direct commit,
  retries only its consensus round, and commits under O; that single direct
  finality finalizes I+A once. I's complainers can commit A in its different
  view. No ordinary client resubmission and no extra carrier above A.
- **Activation barrier:** reject both empty and non-empty old-era children
  above unresolved A at shared signing and history validation. After O commits
  A, the first descendant uses N and A's era hash, even with gapped views.
  Disjoint committees and a removed validator's post-A vote are explicit cases.
- **Arrival overlap / hidden evidence:** the earlier §4.3.2/§4.3.3 old/new branch
  schedules must not yield both final chains. Apply their boundary to A, not
  desired intent I. A fresh verifier accepts the same history regardless of
  which valid certificate bundle arrives first; later evidence revokes nothing.
  Support-plus-complaint coexistence must not be incorrectly rejected as itself
  Byzantine behavior.
- **Old quorum unavailable:** no N-only activation, minority fallback or timer
  workaround. State liveness assumptions; old authority must become available.
- **Round safety/custody:** leader loss and restart preserve exact supported
  bytes, votes and terminal decisions under the finally reviewed cross-parent
  rule. Wrong domain/era/view/round/value evidence and duplicate signers fail;
  a new round number alone supplies no unstated authority. Mixed final votes
  witness recovery only, not a decision. No explicit SKIP producer or decoder.
- **Activation bytes:** different proposers and rounds construct identical A
  for the same certified I/entry. View and parent binding cannot be omitted
  to fake determinism; no timestamp/leader/round-dependent value.
- **One projection:** live apply, fresh catch-up, historical committee,
  current-view verification and route eligibility all retain O through I
  and derive N from committed A. No raw desired-fact early activation.
- **Intent ordering and results:** two queued membership transactions, the
  same-block selection rule, later countermanding intent and losing I branch.
  Original result at I acknowledges committed facts, not premature activation.
  Duplicate I never re-applies; no consumption-after-SKIP or re-signing path.
- Keep the historical U/T and classification witnesses as refutations of the
  withdrawn rules, not active taint fields or an alternative lock implementation.

Shared crash/delivery requirements:

- Crash around every durable vote/body/send; proposer loss, stale validation
  and live-link replacement; no double signing or lost work.
- Leader/view/round changes and same-peer revisits re-place retained bytes
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
| `quod_simplex:adopt_history` membership boundary comment | keep direct-finality/no-old-child invariant for activation; document the proved I→A entry and committee projection, **not** refuted park-on-proposal/taint or an applied-parent assumption that breaks ordinary overlap |
| `active_validators`, `committee_delta`, history committee views, membership action docs | desired facts at I versus active-era snapshot at A; caller result at I does not promise N active; settle batch intent selection; no SKIP lifecycle, second authority or raw fact mutation by an "empty" block |
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
the handover, temporal-taint and committed-intent classification counterexamples.
Parent-value contract v2 fixes the same-parent classification and deletes SKIP.
Its fixed-parent single-value recovery is conditional: §4.3.9 still owes the
same-view competing-parent safety/liveness boundary. No implementation.
The former witness is retained at `/tmp/quod-handover-proof.uQlvgn/`; the new
bounded checker and output are at `/tmp/quod-membership-round-proof.Pj4253/`.
Its historical multi-value cases remain labelled as such. The new extension
checks the stated parent classifier and ballot/evidence premises, explicitly
separating fixed-parent positive controls from cross-parent counterexamples.
It is not a full protocol, availability, transport or mode-selection model.
The k-bound attribution in §4.4 distinguishes the published stable-leader
protocol from Quod's adaptation. Neither a scratch model nor the name of a
published protocol substitutes for proving its actual Quod composition.
No proposed throughput gain has yet been measured, and the unchanged §6/H1
gate still applies.
