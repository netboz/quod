# Draft preservation assessment

Found during integration: the controller reset local input whenever either the
schema revision or the editable-defaults token changed. That contradicts the
plan's stale-draft preservation and can silently discard human work.

The controller now retains one local draft with its semantic view and revision.
The current signed form remains the submission authority. A stale schema locks
editing and submission while the shared desktop/spatial model displays the old
controls with their old values. Changed editable defaults preserve input; the
explicit Use current defaults action replaces only local data and is disabled
under the existing lock. An initially stale view can return to the accepted
schema safely: its never-editable fields are replaced before editing is allowed.
No second state machine, storage layer, domain state or operation queue is added.

Tests cover changed and removed fields, repeated stale updates, unchanged
renewals, defaults replacement, initial-stale recovery, synchronous write locks,
unknown response/reopen and exact outcome resolution. gate01 directly ran the
controller file: 9 tests, 0 failures, exit0. gate02 ran all17 client test files:
0 failures, exit0. gate03 TypeScript/Vite build: exit0.

MCP browser result02 exercises mounted React controls, the shared spatial model
and real IndexedDB journal: shared draft/defaults preservation/explicit defaults
choice/stale preservation and all loss/reopen/resolution locks true. Exactly one
execute and one matching outcome read; no retained fixture rows or browser
errors. The first evaluation had a transport error, retained separately; a
read-only inspection found no mounted run before a fresh page was used. The
fixture's socket/HTTP and scene sink are doubles; this is not remote opening,
Babylon hit targeting or Vive acceptance. No Claude review requested or claimed.

Self-review found no remaining defect within this change. The former draft-loss
assertion was replaced by the required preservation assertion, not removed;
schema authority and unknown-write locks remain independently tested.
