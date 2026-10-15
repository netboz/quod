# Verdict

The bounded existing-owner extension is architecturally valid, with three corrections and three must-verify preconditions below. It fixes a **pre-existing shared signing-custody gap**: today every custodied store (C) is signed and sent with no durable copy anywhere until the ledger commits it; the signer is the only party that knows the bytes, and the ledger cannot retain an operation it has not received. That is why a durable receipt at the signing custody owner is the only unavoidable durable runtime extension for the lobby guarantee. I withdraw "no lawful remedy without a second journal". No line count claimed.

# Contract

**Owner.** `quod_agent_vault`, new narrow capability "pending custody-establishing request receipt". Ledger remains sole outcome authority; the vault never resolves, submits or interprets outcomes. Module doc sentence "not a signed-request or outcome journal" must be replaced accordingly, and `delete/2` must never touch receipt files.

**Slot key — correction.** `{Network, WorldRef, physics_activation}`. Do **not** put assignment/epoch in the key: a successor under a new assignment on the same node must collide with the old receipt or it will mint a fresh C. Assignment is receipt *content*.

**Receipt content.** `{AgentRef, Epoch, Key}` it was signed under; `{Generation, Prior, Token}`; C bytes+signature (op id and `not_after_ms` are inside); R bytes+signature structured (needed to form the cancel goal and match `physics_request` without reparsing C). Plaintext, `write_atomic` 0600 + dir sync; not a secret, no AEAD.

**API.** `retain(Slot, Receipt, Deadline)` → `{ok, retained} | {ok, {existing, Receipt}} | {error, vault_storage_unavailable}`; `retained(Slot)` → in-memory, no I/O; `retire(Slot, Receipt)`. All three go through the existing `custody_operation`/`sync_pending` path, so ambiguous durability blocks and refuses, and storage failure sends nothing. Receipts are loaded once at `init`, held in state.

**Serialization with stale owners.** Both owners may sign (signing is not a write). First `retain` wins; the loser receives `existing` and must discard its signed copy and resolve the existing C instead. Never adopt the dead owner's token: the existing `Installed =:= Token` guard already routes a foreign committed activation to `awaiting_selection` and the next generation.

**Lifecycle.**
1. Worker signs R, signs C (existing `sign_request`, fresh op id), `retain` — durable **before** C enters ingress.
2. `retained` → submit C (existing). Certified committed → submit R as today; retire receipt (the committed `physics_request` fact is now R's retention; crash before R send → existing `resolve` path → unknown → unavailable). Certified rejected/aborted → retire; a new attempt with a new op id is lawful. Transport error/unknown → keep receipt, phase unresolved, no retry.
3. Restart/new owner: on `custody = none`, consult `retained` before `request_activation`. Existing → `request(resolve, {CBytes, CSig})` via `resolve_operation`. Committed → retire, continue on ledger custody. Terminal negative → retire, mint anew. Unknown → `{unavailable, store_unresolved}`; no mint.
4. Fences that retire an unknown receipt: (a) committed `physics_cancelled_request` for the exact R request — the store's `\+ physics_cancelled_request` read makes this a proof that C cannot apply; (b) committed hosting/key epoch advance *if* the store binds the exact key (see V1). Nothing else; no timeout.
5. Disable / host change / key delete: receipt untouched; re-enable on this node resolves it first. A successor on another node is fenced only by (b).

**Bounds.** One receipt per hosted world per purpose; set derived from worlds this node's agents act in. Stale receipts for never-revisited worlds persist until fenced — state this in the doc, expose in diagnostics.

**Consolidation.** `#s.uncertain` in `quod_physics` and the receipt are the same truth; make the worker read the receipt rather than keep a second copy.

# Blockers / must-verify (code not in excerpts)

- **V1 (precondition, cross-node):** the store proof must derive `current_principal` from the *active* `agent_hosted` key for the exact epoch, so a committed re-host rejects the old C. If it does not, a successor on another node can never know the old C is dead and must stay unavailable forever — fix the binding before relying on fence (b).
- **V2:** `physics_cancel_activation` must assert `physics_cancelled_request` for a request **not yet** in `physics_request` (the unknown-C case), and `\+` must be an OCC read dependency. Also `can_cancel_physics_activation(_,_) :- fail` makes the only remedy unreachable; a world policy rule is required, Prolog-side.
- **V3:** `resolve_operation` must be non-submitting and must distinguish certified terminal from merely unknown; certified negative expiry is used only if ingress really issues it.
- **V4:** audit every `custodied` call site; add retention only where the outer execute establishes durable custody for a signed inner request a successor could re-mint. Others pass `none`; semantics unchanged.

# Tests (real seams)

1. Crash after `retain`, before C send → restart → resolve → unknown → unavailable; ingress sees exactly one op id ever.
2. Crash after C send; C commits post-restart → committed → ledger custody → R resolve unknown → unavailable → explicit cancel works.
3. Certified reject → retire → new op id allowed.
4. Two owners, same world → second gets `existing`, submits nothing, keeps own token.
5. Unknown receipt + committed cancel fence → retired; late C delivery is rejected by ledger.
6. Unknown receipt + committed epoch advance → retired; old C rejected (proves V1).
7. `delete/2` leaves receipts; vault restart reloads them.
8. `retain` storage failure → nothing sent; `sync_pending` refusal path.
9. Repeated `retained` performs no file read/write/sync.

# Corrected sequence

1. Verify V1–V4 (read-only, one evidence note).
2. Vault receipt capability + doc + delete isolation.
3. `quod_agent` custodied path: retain between sign-C and submit-C, explicit retention argument.
4. `quod_physics`: consult receipt at `custody = none`, resolve C, retire on certified, fence recognition; fold `uncertain`.
5. Tests above.
6. Then the lobby founding changes — agreed as stated: enabled intent at founding, enabled required at prepare+init, host/admission/controls/viewpoint in one commit, no bound control before the pilot body, mapping validated once.