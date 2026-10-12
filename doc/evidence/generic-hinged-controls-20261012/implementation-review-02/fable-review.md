**Verdict: GO on the corrected scope, conditional only on the restarted clean gate campaign finishing green. No code or design blocker remains.**

**H1 fix is minimal and correct.** The member rule now reads `(State = closing(R) -> After = cancelled(R) ; After = State)` at `tree/priv/ontologies/quod_hinged.pl:159`. The first packet had a three-way branch that mapped finished to idle. The red log reproduces exactly the chain I predicted: idle fails both the finished and cancelled arms, falls to certified rejection, and the committed outcome yields `hinged_custody_held(10)`. The close action maps `finished(R,_)` to the `finished(R)` lifecycle, so the shared comparator accepts replacement after a move. Checkpoints are still removed and all three revisions advance, so the pending-finish fence is intact.

**Finish stays historical, not a placement certificate.** Nothing in `src/` reads the finished state; the runtime only sees activities through `physics_activity`, which reports non-closing members as request none with hold. The only durable placement input is the checkpoint, which the move deletes, so a restarted owner restores the authored baseline until the next close writes a revision-3 checkpoint. The regression asserts exactly that. The doc wording at physics-native.md lines 526 to 531 says the same thing.

**Rest store duplicate removed correctly.** The store now binds the world from the sample frame and relies on the single validation inside `physics_rest_measurement`. Net change is one line fewer in each file.

**Low-note dispositions all hold.**
- Angular bounds: Prolog measurement at line 116 and the Erlang restore case at `quod_physics.erl:741-744` both fail closed. The Erlang case has no clamping clause, so an out-of-range or stale checkpoint crashes the projection rather than fabricating an angle. The limitation is now documented at lines 509 to 513. Both fixture targets sit inside their limits with margin.
- Hold edit during closing: documented at lines 518 to 521 as invalid, cancel as the governed stop. The new fence test covers the real production seam by editing the control after a real signed sample, before store and before finish, and confirms the sample dies, state stays closing, and cancel still commits.
- start_native cache: the invariant argument is sound and I accept retaining it over a defensive reset.

**New tests are the right shape.** The group-move regression runs on both authored worlds, confirms old custody bytes differ from the new ones, resolves the old operation as still committed, and finds the new checkpoint. The obstruction and permissions test exercises close denial, blocked result, cancel denial and cancel commit on both objects. Green log shows the three targeted generators at 0 failures with sources unchanged.

**Not verified here.** The full 188-case run and clean sequential gates are not claimed green and I have no evidence for them. That campaign completing is the only remaining condition. Two pre-existing float-match compile warnings in the test module at lines 959 and 1439 appear in the red log; they are outside this scope and not a blocker.
