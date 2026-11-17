# Consultative mechanics review

Claude Fable session `ca58432f-ea5c-4d98-aeeb-c92a8e6a120b`, approved read-only source payload. No writes, commands, builds or tests. Advice independently checked against the full preflight36v exception stack: the fault is the old literal contents-clause selector. The assertion remains contents-only and requires unavailable, with no cube fallback.

Agreed on the premise. I did not assume the first Enter was missing; the absence of `travel_offer_missing` in preflight36 already established that discovery succeeded.

Ranking the reachable `[X] = []` sites after the first Enter, in execution order:

- **`[Create|_]` at :644.** Cannot be `[]`. The class subject is `{class_ref, Ns, Anchor, space}`, identical to the M2 read that returned three offers, and class offers do not read A's location. A denied or erroring read would fail the `m1a_read` tuple match, which reports a tuple, not `[]`.
- **`[Enter]` in `m3a_enter` at :791 and `[Leave]` at :651.** Same discovery path as the first Enter with a different `Before`. After each travel the assignment table holds one row (withdraw asserts `(personal, N+1, none)`, place retracts it and asserts `(personal, N+2, Dest)`), so `space_travel_context` stays a singleton. No difference from S1 found for S2 or S0.
- **`[E1]`, `[E2]`, `[EL]` in `m3a_recursive` at :760 to :762.** Only `[]` if the projection succeeds with a wrong status; a failing projection would badmatch `{scene,_,_}` instead. The contents path through the generic exterior clause, `space_entity_model` and `space_occurrence_model` yields `contents` status correctly on my read.
- **`[ContentsRecipe]` at :778.** Deterministically `[]` in the current tree. The comprehension filters source terms on the head `{class_eidolon, space, _, contents, _}`; the consolidation removed that literal clause and `space_exterior_recipe(contents, space_contents)` now carries the key. This fails every run regardless of what the stack shows for earlier steps, so it needs fixing either way: retract the exact `space_exterior_recipe(contents, space_contents)` fact, or restore one literal contents clause. Retracting the generic `class_eidolon` clause would also remove solid and wireframe and invalidate the "no cube fallback" assertion that follows.

Nothing is printed between the first Enter and the end of `m3a_recursive` (`M3a signed same-agent route` is emitted only after it returns), so the log cannot discriminate among these sites. The `-v` stack will. If it lands on :778, the route S0→S1→S2→S1→S0, leave, re-enter, conflict and the nested projection all passed.

