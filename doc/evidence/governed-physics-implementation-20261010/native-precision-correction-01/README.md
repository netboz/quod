# Single binary64 physics and grazing-contact correction

Status: implementation review GO with documented corrections; final gate05 passes
all eleven checks after correcting gate04's two lifecycle test races. Candidate262
remains deployed. This is not real-client acceptance or permission to close the task.

The binary32 GJK fix solved the three captured floor stalls, but a full face/edge
oracle found another normal error: 0.069428 radians near an isolated supported
triangle. At the actual 2m/s walking speed it returned Occupied. The engine now uses
one upstream binary64 implementation; binary32 packages and downcasts are removed.
The same minimal stagnation/iteration correction remains, with the convergence
hunk removed. No contact precheck, secondary query world or budget increase exists.

The final native suite passes34 tests in both profiles, including23,920 travel
cases and8,736 reciprocal steps. The independent oracle covers1,390 face/edge/vertex
casts: zero misses, maximum within-skin error0.00018388rad and overall0.001850rad.
For within-skin starts, it verifies normal error against the absolute analytic
velocity margin at2/4/8m/s, preserving both approach and separation signs on this
sampled set. Outside-skin vertical casts measure slide quality only. The analytic
oracle is identity-frame/horizontal; rotated geometry has separate movement tests. A provisional all-distance
0.0003rad assertion failed outside the2mm skin; an initial assumption that all edge
diagonals approach was also false. Those failed hypotheses are retained, not hidden
by a production tolerance increase or changes to accepted budget assertions.

Binary64 exit/refinement counters contain no contact-None or unrecorded outcome in
the captured, reciprocal and matrix campaigns. These are bounded observed results,
not proof that every library miss is certified. At +/-990m offsets under a1000m
coordinate allowance, the original slide checks still consume5–6 queries (<10).
No instrumentation is installed in production.

The existing benchmark was extended with16bodies,144vertices,242triangles and2,000
controlled surface moves. Campaign03 passes: query p50/p95/p99/max104/153/567/1594us,
unchanged install31us with zero changes, retirement15us. This is a local release
sample, not a latency or heap bound. Campaign01 retains the direct binary32/binary64
comparison and measured inline layouts. Campaign02 stopped because its new wrapper
forgot the real NIF's {ok,Answer} envelope; that wrapper alone was corrected.
The real improper-list unwind and non-finite quarantine tests pass2/2.

The dependency audit verifies the published f64 archive plus the single patch and
LICENSE. Audit01 incorrectly collapsed duplicate package names; its STOP remains.
Audit02 checks all69 locked versions/64 names against the pinned RustSec database:
13 advisory matches, all satisfying a complete patched range. It is a dated source
review, not a claim of formal dependency safety or a cargo-audit run.

Existing authored Prolog source remains committed state, with its valid narrower
encoding envelope. Deployment changes no founding manifest, body identity, anchors
or history. The personal acceptance world has no rest/hinge checkpoints; post-release
readback must confirm that along with current owner recovery. Rollback uses the
prior image and original job; no above-binary32 values are authored by this release.

See the plan review/disposition, the frozen release gate04 record and the forthcoming
implementation review and signed desktop evidence for the remaining gates. XR and
durable real-door consequences are separate acceptance work.
