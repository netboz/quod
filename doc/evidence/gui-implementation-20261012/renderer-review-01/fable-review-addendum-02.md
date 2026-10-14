# Fable review addendum 2: renderer delta-02

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
Earlier reports unchanged. Basis: `delta-02/` (five files) diffed against
`delta-01/` and `tree/`. No command, build, test or browser run; the parent's
gate and MCP results are not verified or claimed.

## 1. Against addendum 1

- **Presentation kinds in submitted forms: fixed.** `gui_compile/5` now
  refuses any tree containing `editor`, `bindings` or `catalogue_selection`
  (`delta-02/priv/ontologies/gui_instance.pl`, after the vocabulary ask and
  before the control check). The guard uses the `no_follow` tree walk, so a
  refusal is plain failure with no foreign ask, and by reading it backtracks
  through the single deterministic vocabulary ask without any raising
  alternative. The signed test adds each kind to the lobby and the independent
  instrument form and expects `{fail, _}`, then restores the tree. The plan
  text records the rule and the `catalogue_selection` contract.
- **Invalid or missing numeric position: fixed.** The slider or dial is
  hidden while the draft is invalid or missing (`slider.isVisible = valid`),
  so no position is implied; the fixture asserts `!gain.isVisible` in both
  cases.
- **Underscore Babylon members: accepted as stated.** `@babylonjs` is pinned
  exactly in `client/package.json` (not in this packet; the parent's word),
  the real-pointer fixture exercises the overridden hooks, and the panel does
  not run against unselected library versions. I withdraw the load-time
  assertion suggestion; the fixture is the guard.
- **Immediate required feedback: accepted as a deliberate choice.** It does
  not block a blank draft, so the plan's "may start empty" holds.

## 2. Plan section 5 rewrite

The replaced text now states the selected shape consistently with the
component-review addenda: one original signed execute; prepared presentation
through the declared action, proof-local handle and effect journal; question
row, HUD reference and effect in one atomic transaction; handler feasibility
obtained by the private staging continuation from the selected host's runtime
as part of preparation, never as a visible liveness result or an actor effect;
provisional hidden view with expiry on rollback; certified result as success,
pre-dispatch refusal as Prolog failure, post-dispatch uncertainty retained
under the original evidence; `at(NodeKey, Namespace)::Goal` named as an
unimplemented, wire-changing route constraint with one scope per identity and
conflict refusal. The gate paragraph lists the effect catalogue and journal
executor case, the handle dispatch, and the host-runtime feasibility read as
required extensions. Two sentences worth keeping exact when implementing:
"This does not authorize relabeling an arbitrary live query as a staging
operation", and the hosted-agent caller must retain outcome evidence before
dispatch. Nothing in the rewrite contradicts the verified owner facts.

## 3. Remaining notes, all low

- The guard in `gui_compile/5` rejects by kind after compilation; a form that
  is refused for this reason costs one vocabulary ask first. Fine for a
  misauthored form, not a hot path.
- `slider.isVisible = valid` plus `isEnabled`/`isReadOnly` are three flags
  for one state; a comment already explains the visibility rule.
- Not in this packet and still untested: more than one `gui_vocabulary/2`
  row; registration counts on repeated reads.
