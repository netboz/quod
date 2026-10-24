# Fable review: terrain visibility and appearance

Read AGENTS.md. Yan explicitly requests Claude review of the fixes for a live
0.7.273 world showing no textures/sky and flashing blue during ordinary walking.
Review read-only: no commands, tests, builds, edits, memory updates or delegation.
Return a COMPLETE concise report with verdict, confirmed defects versus risks,
exact frozen file/line references, and inspection/evidence limits.

The exact tree is `_build/terrain-presentation-20261017/review-01/tree`.
`source-manifest.json` hashes all 1,212 source inputs; `scope.json` lists changed
files, and `changes.patch` compares this task with its pre-fix baseline. The
prior world-library implementation is outside this review unless needed to
assess a changed seam. No release/deployment/commit approval is requested.

Independent reproduction used the deployed application, an existing agent-owned
test account, ordinary signed navigation and a 20-second held movement key.
`_build/terrain-presentation-20261017/baseline-01/observation.json` records two
fully hidden terrain frames on a new interest window and held travel stopping
after 4.315 m. The renderer tied root visibility to `terrainReady`; the world
adapter also replaced a still-authorized physical binding with null during
loading, which cleared held input. Physics/stream protocol are unchanged.

Corrections:
- Display verified chunks incrementally. Current manifest validation, digest,
  resource limits, obsolete-row eviction, replacement-projection hiding and
  body/revision fences remain. Movement still waits for current completion.
- Keep the active physical camera binding and held input during streaming;
  suppress commands locally while loading. The existing command gate also
  still refuses them. XR clearance/mapping checks remain.
- New-world palettes select existing Babylon assets from the material catalogue
  through the shared lobby vocabulary and freeze them in world state. No hash
  duplication or client-side domain defaults. Each new world creates its own
  sky instance in the same creation transaction using the existing sky Eidolon.
- Shared sky geometry follows the camera through parent transforms and excludes
  terrain fog. The camera keeps its ordinary far plane. Fog uses authored sky
  tint/brightness when available.

Please examine visibility versus authorization, asynchronous readiness, stale
manifest handling, held input and XR clearance; sky parenting, clipping/depth
and lifecycle; catalogue reads/ACLs, atomic creation and independent sky state.
Prefer refactoring shared concepts over exceptions. No compatibility path or
new process should be introduced. User accounts/worlds must be preserved.

Evidence: 27 focused client cases and UI build passed. The first focused Erlang
run passed 11 and failed one newly added assertion due to fixture variable
ordering (`../focused-01-triage.md`); the frozen test corrects that ordering and
the new run is pending. The first browser run with a substituted local bundle
disconnected before receiving any world projection; this is under diagnosis,
NOT passing browser evidence. Full release gates and deployment have not run.
Existing-world appearance installation must use the real owner's signed path;
that deployment mechanism remains to be completed and is not asserted reviewed.
