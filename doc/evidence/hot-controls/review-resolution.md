# Hot controls review disposition

Yan requested Claude review and removal of superseded backend code before the
authorized commit and deployment. Claude Fable reviewed the frozen tree at
`/tmp/quod-hot-controls/review-01/tree`; session
`b9c69c1b-d4e1-4471-8824-0f4b8e205475` retains the original full report.
The [compatibility addendum](review-01-fable.md) is captured verbatim.
The reviewer read source only; it did not run builds or tests.

The original verdict was **no blocking findings for task acceptance**, with two
medium liveness findings. Both were independently reproduced and corrected:

- Saved, never-submitted rest custody survived an authored cancellation and
  permanently blocked a new checkpoint. The existing author edit now proves
  exact activity cancellation and a changed body revision; a distinct explicit
  checkpoint can replace that custody without inventing a backend rejection or
  resubmitting the old action. The regression retains an unknown outcome through
  owner death, edits, completes the new checkpoint, and rechecks the old outcome.
- A changed control definition with the same principal/binding hid the retained
  sequence behind `-1` feedback. The signed socket regression reproduced this
  after sequence 7 and a controlled-body revision edit. Feedback now reports 7
  as suspended, and a new registered signed sequence-8 push succeeds.

Other findings were checked against real consumers and current semantics:

- Missing navigation guards previously bypassed invalidation. Removed that
  fallback, made guards mandatory at initialization, and supplied the real
  atomics guard in simulator fixtures. Unguarded startup is refused.
- Removed the superseded native `step/1` wrapper/export. All callers use the
  single `step/2` NIF. Internal defaults, local/remote proof contexts and absent
  transient effects remain current execution cases, not compatibility engines.
- Free-body relocation no longer applies box-only door validation. It preserves
  existing authored shape/orientation and atomically invalidates rest state.
  Ball and compound checkpoint/edit regressions pass.
- Checkpoint lifecycle commits conservatively refresh signed views and suspend
  voluntary inputs while retaining pose. This cost is documented; narrowing the
  verified resource basis would require separate measured work.
- Replaced `door_observation` status naming with neutral `observation` and renamed
  projection pose/shape variables. Disabled worlds refuse checkpoint requests.
  Changed push allowances report refusal separately from expiry.
- Reaction-guard and invalid-reaction-request branches are reachable: runtime
  physics dispatch maps `{failed,R}` to `{error,R}`. Transient dirtiness is read
  by scope session control/reporting. Neither is dead code.

Additional tests cover an individually bounded impulse exceeding accumulated
speed, fresh client recovery after an uncertain reply without replay, and visible
real-owner failure when a recovery checkpoint overlaps another body.

The reviewer suggested further coverage of a paused custody-store race and a
push during an in-flight checkpoint. The existing finish/edit OCC race is
covered; store and finish share the same revision/activity read dependencies.
Hot motion does not mutate those authored dependencies: a checkpoint records
its authenticated historical rest sample, and later unsaved motion is lost on
recovery. Hardware WebXR acceptance belongs to the separate movement task.

All failed campaigns and fixtures remain under `/tmp/quod-hot-controls`.
The first full clean campaign stopped at the vault TLS listener's sandbox
`eperm`; it is not release evidence. The next campaign uses the required local
network permissions and a fresh source freeze after the review corrections.
