Yan explicitly requested Claude/Fable review of the plan and then implementation.
This is the implementation review of the shared system-predicate registration
slice after the corrected reuse audit. Be independent and read-only. Read
tree/AGENTS.md and tree/CLAUDE.md, then the relevant architecture and sources.
Only the frozen tree, implementation.patch, and evidence in this packet are in
scope. Report concrete findings with frozen file/line references and severity.

The user's latest correction is emphatic: NO BACKWARD COMPATIBILITY. Do not
invent compatibility gates for arbitrary old predicate definitions, require
old/new code paths, or propose per-ontology capability epochs. The unnecessary
old-manifest test and collision-inventory instructions have been removed.
Historical diagnostic evidence is not active product code or a release gate.
Preserving Yan's ACTUAL current lobby identity/history is a separate requirement;
its baseline has not been obtained and no deployment is proposed here.

Current change: add quod_physics_predicates to existing quod_predicates:load/1,
remove redundant optional loads in hosting/space/failure fixtures, and use
existing per-world Prolog attributes and ACLs. Registration itself allocates
nothing and grants nothing. No separate physics ontology, capability loader,
compatibility branch, process or mutable domain store was introduced.

The new two-world fixtures use different ontology identities, gravity from
attribute/3, signed permitted/denied body reads, initially disabled worlds, and
gravity replacement preserving world identity. Canonical projection recovers
the same genesis/manifest without adding physics provenance. Check these claims
and the actual public bridge authorization/context behavior. Consider registration
reachability, lifecycle ownership, stale fences and any unused added code.

The patch includes an already reviewed geometry slice (Prolog native-shape
validation and native hinge rotation refusal). Focus on new registration, fixture
changes and measurement synchronization, but flag any concrete defect you find.

Measurement: the strict global unchanged-check trace initially caught legitimate
source remote_complete writes after the target collider edit had committed.
The diagnostic matched the exact target transaction. The test now subscribes
before snapshot, waits for the ORIGINAL operation's retained source receipt
using projection notices and an absolute deadline, then measures unchanged
reconcile calls. The zero-I/O assertion remains and now also traces ledger append.
Check synchronization correctness, deadlines, exact identity, cleanup and whether
it could conceal I/O caused by the measured checks. Temporary diagnostic printing
was removed. 228 owner tests passed with unchanged source hashes; after removing
the compatibility-only test, six projection tests passed. Receipts and the local
scope report are included. These are not live remote or signed lobby acceptance.

Full task requirements remain: a live collider in ontology A consumed by authority
P must follow A's committed changes through existing subscriptions and retained
verified projections. No manual re-adoption, mirrored mutable collider store,
polling, new diff broker or second sync protocol. Explicit pinned recipes are a
different case and cannot replace live instances. Ordinary view must track actual
visible-world, acting-agent, physics, authorization and geometry dependencies,
including disabled/denied selections. Those missing pieces are NOT implemented
by this slice. Do not approve the full task or recommend a pinned-copy substitute.

Give (1) findings, (2) whether this local slice is coherent under the stated scope,
(3) any actual unused/compatibility-only code left by these edits, and (4) limits
on validation. Do not request unrelated features or generic legacy support.
