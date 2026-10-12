# Independent implementation review

Scope: frozen release 263 gate 03 and the matching Claude review payload
`35034c49cccb14feb59e340cbef20edf7aeb45693a2d09210e75cfd3efdbf377`.
This review does not itself approve deployment or close desktop acceptance.

The concrete miss is substantiated at the existing GJK owner: the recorded
last-chance point is a simplex projection, not a support point. Treating it as
a separating halfspace can return no hit for a body inside the target distance.
Keeping the current lower-bound impact for shape casts prevents this false
miss. The existing small-TOI refinement derives the actual contact normal and
rejects separation. Composite traversal still visits each triangle/part.
The private boolean selects ray versus shape-cast uncertainty semantics; it
is not a deployment-version or compatibility branch. Exactly one library
algorithm file differs from the published package, verified file by file.

Quod retains initial and final occupancy checks, coordinate validation,
per-collider query charges, slide/rotation bounds and unavailable/exhausted
answers. The correction adds no native query before a sweep, no tolerance and
no configurable resource cap. It cannot authorize movement or durable changes:
Prolog policy, signed admission, controls, body/structure/run fences and the
atomic ontology/verified-projection lifecycle are unchanged.

Landing's physical swept path has no added skin; the downward support search
continues to use the authored skin. This matches the documented complete-body
path requirement and prevents a clear resting body being blocked by its own
support margin. The strict new resting-path regression is retained. Separate
wall crossing and occupied-destination tests require refusal with no pose
mutation. The change does not declare a mechanically successful landing from
commit or installation and creates no durable observation exemption.

The old distance oracle used a 1m contact prediction. A retained diagnostic
shows a negative contact despite positive AABB clearance above a flat surface.
Replacing it with direct intersection does not relax tolerance. All original
query-count limits, displacement, height-drift, occupied-body, full-path and
geometry assertions remain. Direct triangle regression fails with the original
library; the updated algorithm passes. Debug/release and Clippy have passed;
full server gates, external review and signed desktop evidence remain separate.

Runtime-reachability checks confirm Space::cast still uses one linear cast or
one nonlinear cast per candidate collider. The withdrawn contact-manifold
precheck is absent. Shared physics/view owners contain no personal-world name.
The removed external selection experiment and old watch/2 API remain absent.
Text-search receipts support, but do not alone establish, this owner inspection.

Production line delta: native adapter +3/-1 (two comments and the landing
argument), patched upstream algorithm +12/-12, obsolete client comment -1;
net +1 across these implementations. Native tests +208/-7. The complete
vendored upstream source adds 79,506 Rust source lines for reproducible Cargo
selection, not a new domain engine; only its one recorded algorithm changes.
