# Independent disposition of implementation-plan review 02

[Fable's full report](plan-review-02/fable-review.md) is consultative. The
[receipt](plan-review-02/receipt.json) records child exit 0, no changed frozen
inputs, and model usage including `claude-fable-5-1` (plus CLI Haiku usage).
The reviewer performed source review only. Neither it nor the parent ran
production tests or headset validation for this documentation change.

## Accepted and incorporated

- **P1-2:** authoritative current question/work state belongs in the responsible
  agent's ontology. The application retains its component definition and
  continuation. Parent confirmed `select_resource/4` is a local, read-only
  selector without a managed foreign proof context. This supports a remote
  responder without another pending-work index.
- **P1-3, simplified:** all submitted-form examples use one recoverable question
  lifecycle. The event is not an answer-history fact; accepted bindings remain
  only as unfinished work and are consumed with completion. Local presentation
  and editing remain local. A separate weak event-only form mode is unnecessary
  for this milestone and would complicate identity, provenance and feedback.
- **P1-4:** class/schema compilation belongs in signed proofs, with exact
  configured vocabulary anchors. Reaction guards and work selectors use local
  rows, not foreign class traversal. Parent checked the unanchored foreign
  `Ns::isa/2` clause in the current common semantics.
- **P2-1, qualified:** separate display-only initial-value refresh from the
  semantic submission revision. Keep validation context, option membership,
  targets and binding/continuation changes in the semantic revision; do not
  exclude every changing value indiscriminately.
- **P2-2/P2-4/P2-5/P2-7:** expose existing signed operation identity through a
  replayable accessor, name narrow grants, record local-only control routing,
  and migrate the vocabulary/Eidolon/lobby producers with their client parsers.
  An unsupported route is not authoritative absence.
- **P3-1, qualified:** enlarged cancellation separation, focusable status/error
  summary, inline field feedback, descriptions for locked controls and explicit
  inspect/check affordances are incorporated into the local visual study.
  Recovery cannot mean an automatic retry of an uncertain operation. Actual
  application recovery actions must come from domain policy.
- **P3-3:** later human connection does not automatically retry a failed ask.
  Any re-ask must follow an authorized dependency change or explicit action in
  the existing owner. No readiness timer is introduced.

## Rejected or not established

**The proposed admission trace is not accepted.** Its step 4 returns success
after the socket pushes a frame. Step 5 only subsequently creates and journals
the human-signed request. This does not establish client acceptance of the
descriptor, browser custody before a loss, or an atomic shared question/HUD
transition before opening success. In particular, socket death after push does
not imply that the browser has created its journal row, contrary to step 8.
The proposed local offer table also needs a lifecycle/cost justification; it
cannot be assumed to be existing machinery.

An uncertain R1 control call and an independently signed R2 material call do
not automatically give the original caller exact R2 evidence. The report says
both that a timed-out control has no operation reference and that unknown
outcomes keep their exact reference, without defining the handoff. Parent
confirmed that existing outcome resolution needs the exact signed request and
returns pending on absence; absence is not permission to create another
operation. The report therefore has not solved section 5.

The proposed form-level uniqueness checks and `gui_ask/1` selection conflict
with the explicit requirement for concurrent openings of the same form. They
also replace the convenient imperative call example with a different authoring
surface. Correlate by question identity, not by uniqueness of the form.

**P1-1 identifies a real additional owner gap, but not the sole gap.** Parent
confirmed `quod_agent:start_request` has only read/execute timeout cases and
current agent work dispatches execute. Supporting a declared control mode
would require extending those existing owners. That extension alone does not
solve client acceptance, custody, creation/result ordering or remote routing.
No new executor or queue is authorized as a shortcut.

**P2-3's two-mode API is not adopted.** The plan now uses one submitted-form
lifecycle. Local view projection still uses signed reads, but showing a view
is not a substitute for accepted question opening.

**P2-6's brightness-scale defect is incorrect.** The parent checked
[the existing environment vocabulary](../../../priv/ontologies/quod_environment.pl):
`have_attribute(sky_sphere, brightness, permille)` already defines the unit.
The founded value 120 is 12%; the example's edited value 650 is 65%. The plan
now states that conversion explicitly. Different example values are not a
format incompatibility.

**P3-2 repeats an explicitly rejected recommendation.** Pending request count
and total queued bytes are capacity budgets, not encoding constraints. Their
policy ownership must be fixed with enforcement if they participate in
admission; do not merely relabel the constants. Human-question allowances and
responder policy are useful distinctions and are retained.

The review's example claims of automatically correlated Applied feedback do
not establish a retained authenticated completion observation. Terminal
feedback must be grounded in the verified consequence or original operation
outcome, not merely in deletion of a pending row or silence from a reaction.

## Gate and local verification

The plan is **not implementation-ready**. Section 5 still needs the exact
existing-owner trace for actual receiver acceptance, selected responder,
durable creation, custody before dispatch and original caller outcome under
each loss. This is an internal architecture/correctness gate, not a request to
weaken the settled absent-human/agent failure behavior. No production code or
GUI transaction path was added.

[Initial draft validation](draft-validation-01.json),
[expanded example and browser checks](draft-validation-02.json),
[visual contrast calculation](visual-contrast-01.json), and
[small visual corrections](visual-delta-validation-03.json) retain their actual
scope and limitations. The headless browser did not deliver normal focus
events; an explicit event established only handler behavior. That observation
remains a limitation, not a passing keyboard-ergonomics result.

The earlier [DNS failure](plan-review-01-failure.md) and
[automatic approval rejection](plan-review-02/approval-rejection.json) remain
intact. Yan subsequently explicitly
[authorized the frozen source transfer](plan-review-02/source-transfer-authorization.json),
allowing review 02 to run. Neither transfer approval nor Fable's report grants
implementation approval.
