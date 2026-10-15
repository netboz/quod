# Lobby safety and jump verification

Delivered as0.7.271; see [deployment and desktop results](deployment-271/README.md).
The records below retain the pre-delivery verification campaigns and failures.

The deployed 0.7.270 fall was reproduced using the retained isolated acceptance
account. Physics and its signed projection remained active, with no browser
error. At Y below -45m the camera was outside the fixed 40m sky radius; the
canvas displayed its navy clear colour. Both fixture restores committed through
the existing signed operation journal. No user account was edited.

The floor asset now includes a closed 20mm glass bowl, 4.4m across, dipping from
-0.1m at its edge to -0.55m at its centre. Core static GLB alpha blending is
reused. The authored fixed collision surface fills that centre and follows the
1m outer coping. It uses193 vertices/360 triangles; the roof uses72/96. Lobby
geometry policy admits384 vertices/512 triangles. This is the existing ontology
resource policy, with no native budget or proof-heap constant changes.

The initial552-triangle floor hit the64MiB proof worker heap while atomically
initializing; it was simplified without splitting the edit or dropping a safety
surface. Earlier invalid centre-height/enumeration attempts remain logged.
The real complete factory and native-owner safety queries now pass, including
spawn clearance, glass support, outer-rim clipping and repeated no-I/O queries.

Jump is one discrete command over the existing signed control ingress. Prolog
requires grounded mode and exact configured launch speed. The existing owner
uses its existing native landing query to check support, then its retained
vertical state/travel solver for ascent, ceiling contact, gravity and landing.
The push path and jump path share the extracted discrete/gravity helper. No new
process, protocol, NIF, world copy or client collision engine is introduced.
Default policy walks at2.5m/s and jumps at3m/s (about0.43m measured rise).
Desktop Space repeat is suppressed. Ground/ceiling/air/disconnect tests pass.

Stopped jump-owner01 was a rebar command selector error. Jump-owner02 used a
stale sleeping notification in its disconnect assertion;03 waits for actual
landing frames on the new registration. No assertion was weakened.

Current implementation has no commit, deployment or refound yet. Prior
candidate-only clean-redeploy permission exists in the conversation; this task
itself grants no wider destructive authority. Main network and browser keys
remain excluded.


Fable review01 approved the design subject to real-owner rim containment evidence.
Six cases now cover axis/face/next-vertex directions, both jumping before
contact and attempting a jump after pressing against the wall. All remain
inside the coping through120 frames of held drive. Approaching cases really
jump; at a touching wall the existing minimum-up native support query can
conservatively refuse with no_support. No new rim exception was needed.
The expanded rim/jump/numeric run passes10 tests. Rim-owner02 failed due to
midface fixture overlap and integer diagonal drive rounding;03 incorrectly
required a jump despite the native wall-support refusal. Full failures remain.

Native jump-query errors now retire the world through existing fail/2, and
the shared numeric envelope validates jump speed. Source-frame mismatch uses
an explicit case. The skin-margin wording is corrected. Final review02 and
release-gates02 run on the corrected frozen tree.

Release-gates01 is deliberately superseded. Its first six gates passed;
EUnit was interrupted with SIGTERM, which Erlang reports as exit0 without a
completed test summary. That row is not accepted as a pass. Its subsequent
CT child was killed with recorded exit-9. Logs and both cancellation markers
remain intact. No failure is silently rerun or represented as passing.

Initial production change was121 added/28 removed lines, net+93, excluding generated
browser assets, binaries, tests and documentation. Growth supplies the glass
mesh, authored collision surface, capability and shared owner integration.

Release-gates02 is also retained as an execution-environment stop: its first
six gates passed, but the runner lacked local socket access required by
integration tests. Its EUnit child was deliberately stopped with exit-9
before accepting any integration result. Final release-gates03 uses the
same corrected source with permitted local test networking. The first launch
while preparation was still running did not execute a gate (exit2); its
receipt is preserved separately.

Review02 did not produce a verdict: sandbox DNS blocked the API (ENOTFOUND,
zero model tokens). Review03 uses the same previously approved source bundle
with network access. These are tooling failures, not passing evidence.


Review03 accepted the code corrections but rejected the first rim evidence as
potentially vacuous. Every final case must now launch, touch the wall while
actually rising, and reach a higher subsequent position. All120 held-drive
frames must remain inside8.56m radius with height above0.7m. Results print
actual normals, first contact height, later peak and maximum radius. Motion
is extracted from the authored lobby clause so the fixture cannot drift.

These stronger tests exposed a real ascent bug: vertical wall contact normals
contained negative components around1e-9, which the first ceiling heuristic
misclassified. The existing descent-progress helper is now shared for blocked
ascent and descent. No epsilon, new solver or collision exception was added.
With correct ascent,4m/s and3.5m/s can climb the actual rounded rim; both
failing runs remain. Default Prolog policy now uses3m/s. All six actual jumps
contact the wall while rising and then reachY1.186 (rise0.434m), while maximum
radius stays below8.306m. The expanded jump/ceiling/air/reconnect/wedge suite
passes11 tests. At exact wall-skin contact the existing native support query
can conservatively refuse a jump; stepping away permits its floor check.

Release-gates03 was superseded and its EUnit child deliberately stopped with
exit-9 after this production finding. Final release-gates04 and focused
Fable review04 use the corrected tree; no commit or live mutation yet.

Fable04 approves the core correction and non-vacuous experiment with no
remaining core blocker. The default jump value trades height for keeping the
existing coping containing; its speed/geometry invariant is now documented.
Production adapters always send the projected authored speed. The exact
founding-proof heap peak was not measured; successful atomic initialization
within the unchanged64MiB cap is the observed evidence.

A focused keyboard regression also found that held travel waited250ms after
a jump. Invalidating the existing lastDrive latch resumes continuous input
promptly while existing discrete-sequence/sending guards preserve ordering
and uncertain-operation handling.26 navigation/simulation tests pass. Final
GUI review05 and all11 sequential gates05 use this completed source and
rebuilt UI. Previous gates04 was superseded with recorded childexit-9.
Final production delta130 additions/36 removals, net+94 lines, excluding
assets, generated bundles, tests and documentation.

Fable05 approves the keyboard handoff fix with no blockers. Jump-drive02 is
the pre-fix reproduction (`2 != 3` held-drive count);03 is post-fix26/0.
Prompt resumption remains bounded by actual discrete feedback, preserving
ordering. A Space press during another in-flight control can be dropped
under the existing one-command rule; no new queue or uncertain resend is
introduced. Held-key repeat submits no further jump.

Final gates05 passed all11 sequential gates, each with true childexit0 and
unchanged frozen inputs: native debug/release, Clippy,18 client test files,
UI build/lint,4009 EUnit tests/0 failures,148 Common Tests, xref, Dialyzer and
production release packaging. Full logs/manifests/runner are retained under
gates-05. No implementation edits occurred during this accepted campaign.
Yan explicitly reaffirmed deployment and ledger-purge authority before going
to sleep; the prepared clean candidate-only workflow excludes the separate
main network and browser key files. Commit/image/deployment follow these gates.
