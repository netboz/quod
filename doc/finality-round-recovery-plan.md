# Finality recovery without sacrificing write throughput — review draft

Status: **approved pipelined baseline; membership-round recommendation under review;
not approved for implementation**. Source reviewed at `b7c497e` / 0.7.143 on
2026-09-07. Claude withdrew the per-slot rounds recommendation and accepted
protocol-faithful pipelined Simplex with separate views and ledger heights.
Both grandchild and first-observed-finality handover candidates are refuted.
§4.3 now records sequential membership with in-view recovery rounds as the
reviewer's replacement recommendation. The no-child boundary closes the old
overlap; the round/skip grammar and composition with ordinary view advancement
still need the focused architecture sign-off. Do not implement a shorthand
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
checks; an unresolved membership parent admits **no child**, empty or non-empty.
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

The new recommendation preserves today's sequential membership boundary:
O directly finalizes M before **any child** of M can be proposed. Contested M
recovers inside its view using rounds, not old-era descendants. DTX barriers
remain fixed-era and use the approved carriers. §4.3.4 spells out this division;
§4.3.6 records the round/skip/composition proof still required. No implementation.

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

#### 4.3.4 Recommended boundary: sequential membership, in-view recovery

One payload/ancestry validation seam owns the distinction:

| Parent/work | Progress while its direct finality is unresolved | Authority |
|---|---|---|
| Ordinary fixed-era content | existing useful payload overlap; carrier if needed | same certified committee |
| DTX control barrier | empty carrier after deterministic validation; application ordering remains fenced | same certified committee |
| Membership M | no child of any kind; recover the **same view** in rounds | O until M's direct decision; N only for certified descendants of committed M |

An empty carrier has no membership escape privilege. Both live support and
history validation reject one above unresolved M. A receiver learning M's
commit later cannot retroactively turn an old-era child into valid evidence.
The first appended descendant of M is at its next ledger height; its protocol
view may have gaps, so "slot+1" must not silently re-conflate views and heights.

The review recommends a stable membership value M and a possible explicit
`skip-of-view` value, with round-free value bytes, round-bound votes, and
round-change evidence containing a quorum of distinct old members' final votes
of **any** kind for one round. A 2-commit/2-complaint split can supply that
quorum. Commit votes retain a value/round lock; complaints do not erase it.
Higher-round re-proposal/relocking must obey the exact support guards below.
This is proposed additional consensus state, not existing code or a second
runtime owner. Skip eligibility is not yet settled (§4.3.6).

Healthy M can finalize directly in round 0; no mandatory carrier or extra
network phase is intended. "Round 0 is byte-identical" is not an approved
format claim: round binding, journal records and all certificate consumers
change in the coordinated cut. Preserve the healthy message count and measure
latency/throughput, rather than promise zero cost. Ordinary overlap is unchanged.

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

#### 4.3.6 Focused round-proof obligations, not shorthand inheritance

The comparison is the actual Tendermint v3 Algorithm 1, not its name. Its
support/prevote choice consults the retained lock and a verified *earlier-round*
support certificate; quorum final votes of different kinds advance recovery,
but do not choose or finalize a value. A nil final vote is not a committed skip.
The lock and most recent supported value serve different roles.

The recommendation needs the following precise obligations:

1. **Guard support, not only final votes.** Without prior supporting evidence,
   a locked voter supports only its locked value (or refuses). For a different
   value, the proposal must carry a valid support certificate from round `vr`
   with `locked_round <= vr < current_round`; equal-round conflicting QCs are
   themselves impossible under quorum intersection. A numerically higher
   round is no permission to help form the very conflicting QC used to unlock.
   Membership, unique signers, view/value/round binding and actual QC validity
   are checked by the existing verifier. Retain the latest supported value/QC
   for re-proposal even if the validator had already complained in that round.
2. **Complaint is not SKIP.** Three complaints or a mixed final-vote quorum
   prove neither "M never notarized" nor a decision on an explicit SKIP value.
   The original recommendation's `skip-wins-only-if-never-notarized` claim does
   not follow from commit-lock voting. Counterexample: Byzantine z receives
   support(M,0) from a,b and adds its own signature, retaining the QC privately.
   No honest validator sees the QC or locks M. All three honest validators
   complain; in round 1 they can support and commit a separately proposed SKIP
   under ordinary unlocked voting. Revealing QC(M,0) afterwards violates the
   "never notarized" promise, though it does **not** by itself create conflicting
   finality. Refusing this schedule needs a specified, locally verifiable rule
   and liveness proof, not a predicate checking globally absent evidence.
   Alternatively review must explicitly revise the promise to safe decided-
   value exclusivity. Neither choice is silently adopted by this plan.
   Any SKIP grammar must preserve §4.1: no synthetic ledger entry or membership
   change, and no fabricated abort/new submission for the retained transaction.
3. **One certified view-escape rule.** A validator without the membership body
   can time out/complain while another knows M is notarized. Specify when these
   votes move to another *round of this view*, versus ordinary Simplex's next
   *view*. A mixed-vote quorum alone does not certify which mode/body was chosen.
   Show that no honest set irrevocably leaves for a later fixed-era view while
   another remains bound to membership recovery and neither can obtain quorum.
   Also specify how the selected M is identified if the initial leader
   equivocates between valid membership bodies before either gets a QC;
   the witness's fixed input M is not a selection protocol. Classify from
   validated evidence at the existing owner, never a caller's mode flag or
   local arrival order. This is a composition proof still owed,
   not a claimed counterexample to a fully specified protocol.
4. **Progress and retention.** Define the round leader, same-round final-vote
   exclusion, handling of old valid decisions, supported-body/QC custody,
   restart floors and evidence-driven wake/replacement of placement. Mixed
   final-vote evidence is formable, but formability alone is not a liveness
   proof. The paper's timeout/gossip assumptions cannot be discarded while
   inheriting its proof; map actual failure detection into the existing owner,
   with no success-path polling, delay ladder or second pacemaker process.

The bounded witness checks the no-child refusal, 2/2 round-1 recovery under
these lock guards, rejection of a Byzantine higher-round conflicting proposal,
and the hidden-notarization/SKIP schedule. Its membership mode and selected M
are inputs, not a proof of obligation 3. The implementation remains blocked
pending this focused sign-off. No ordinary-throughput regression is authorized.

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
does add round-scoped latches and value/round lock plus supported-value evidence
at this **same journal owner**, conditional on §4.3's proof. Do not hide this
change behind the old blanket "no locks" sentence or duplicate custody.

The signing journal remains the sole persist-before-exposure owner. Persist
the exact supported bytes and support latch atomically; persist the final
commit-or-complaint latch before exposure. Remove adjacent-view exclusions,
not fixed-era same-view or membership same-round non-equivocation. **QSJ4
replaces QSJ3**, without compatibility; the exact membership-round schema is
part of the pending sign-off, not an approved era-agnostic implementation.
Restart retains every outstanding view's required body/evidence and signing
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
| `quod_simplex` | one engine, useful fixed-era pipeline, certificate pool, validation workers, ordered finalization; membership explicit-finality/no-child barrier | coherent view/ancestry progress; reviewed in-view membership recovery; terminal complaint-to-ledger-skip, adjacent-slot voting exclusions, camp/grace machinery |
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
both handover counterexamples and now recommends sequential membership with
in-view rounds. The no-child rule closes the old authority overlap; exact
round/skip/mode composition remains the focused implementation-blocking proof.
The former witness is retained at `/tmp/quod-handover-proof.uQlvgn/`; the new
bounded checker and output are at `/tmp/quod-membership-round-proof.Pj4253/`.
It assumes a known membership instance and checks the stated ballot/evidence
guards, not a full protocol, availability, transport or mode-selection model.
The k-bound attribution in §4.4 distinguishes the published stable-leader
protocol from Quod's adaptation. Neither a scratch model nor the name of a
published protocol substitutes for proving its actual Quod composition.
No proposed throughput gain has yet been measured, and the unchanged §6/H1
gate still applies.
