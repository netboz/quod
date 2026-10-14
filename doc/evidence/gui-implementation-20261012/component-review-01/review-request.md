# Fable review: implemented GUI foundations and opening integration

Yan explicitly requested Claude Fable review of the plan and implementation.
Read the frozen `tree/AGENTS.md` first. All source inputs are in `tree/`, listed
in `source-manifest.json`. Read only that snapshot for code conclusions. Do not
modify source, start another agent, run commands, claim tests, or send messages
outside this review. Save your report beside this request as `fable-review.md`.

The implementation is deliberately incomplete. Review this actual component
slice, not a claim that the GUI milestone is finished:

- `priv/ontologies/common_predicates.pl` and
  `src/quod_erlog_db_local_prove.erl`: shared final-segment owner resolution for
  `quod:gui:text_box` and `(quod:gui):text_box`, including generated followers.
- `src/predicates/quod_common_primitives.erl`: pure existing-name-grammar
  `ontology_name/2` and variable-sensitive canonical `variant_digest/2`.
- `priv/ontologies/quod_gui.pl`: class vocabulary, defaults, common-control
  property/value contracts. Legacy workspace descriptors remain until their
  whole producer/controller replacement; no replacement renderer is claimed.
- `priv/ontologies/gui_instance.pl`: reusable source composition, anchored
  component projection, variable binding to authored continuations, separate
  defaults/revisions, readonly/disabled constraints. It performs no opening,
  submission, reaction dispatch or continuation execution.
- `test/quod_gui_components_tests.erl`, its fixture, common primitive tests,
  class and ask tests, and reused lobby test fixture.

The parent has run 97 tests successfully before the final additions for empty
required defaults and disabled-value revision coverage. That final expanded
run is in progress. The signed fixture uses the real lobby and independent
nonphysical application, existing ingress/scopes/ACLs, and a trace assertion
that repeated schema reads perform no history reads, projection reconstruction,
file writes or syncs. Headset and browser behavior have not been implemented
or tested by this slice. Identify correctness/authority/performance issues,
especially accidental arbitrary-argument following, wrong namespace grouping,
schema ambiguity, defaults, binding templates, hash collisions, stale revisions,
and incomplete evidence. Prioritize actionable findings with exact file anchors.

Separately, examine section 5 of `doc/gui-implementation-plan.md` and the
independent prior disposition at
`doc/evidence/gui-implementation-20261012/assessment.md`. Do not repeat its
rejected proposal of returning success after a socket push and later creating
the question. The requirement is settled: no connected intended human or
capable authorized responsible agent means Prolog failure. Unknown outcomes
must not be misreported as failure or retried with fresh operation identities.
Question creation and the human HUD reference must be one atomic transition.
Acceptance does not promise continued connectivity during later editing.

Propose one executable opening sequence if the existing owners support it.
Name original request, acceptance point, exact material operation, durable
custody before dispatch, and the original caller's success/fail/unknown result
for each death/loss boundary. Audit the actual live-observation/material-diff
veto in `quod_dtx`, original-request evidence requirements in outcome lookup,
agent request custody, direct-effect journal, and authenticated view owners.
An event-only diff is still material. An arbitrary `observed` term is not
authenticated runtime observation. A partial custody transaction cannot be
hidden by calling it a failed open. The effect journal is not an agent outbox.
Do not create a GUI executor, receipt protocol, private question queue, or
duplicate transaction/recovery guarantees. If a generic existing owner really
needs extending, specify the smallest missing capability and its proof and
recovery invariants concretely rather than claiming it already exists.

Consultative advice only. Explicitly separate verified code facts, proposed
changes, and unresolved questions. No request to weaken settled requirements.
