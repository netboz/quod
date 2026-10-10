**Verdict for this stage: sound in its core mechanics, not yet mergeable as-is.** Height retention for origin, co-hosted and remote scopes is correct and captured before cleanup. The envelope validation is correct. Two medium issues need a decision before the socket tests land: the signed-read envelope is dropped on oversized or invalid replies, and the socket now blocks on the engine mailbox twice per local dependency on every open.

## Findings

**M1. Oversized or invalid read replies lose the envelope.** `tree/src/quod_client_result.erl:114-123` returns the inner `{error, result_too_large}` bare, and `bounded/1` at line 167-172 returns bare errors when the whole `{read, …}` term exceeds the cap. The stated contract is that every signed read carries `{read, Dependencies, Outcome}`; consumers matching that shape fall through to their catch-all. Dependencies are bounded to 8 small tuples, so wrapping as `{read, Deps, {error, result_too_large}}` always fits. The socket happens to survive via its catch-all at `quod_client_simulation.erl:95`. Not covered by the new test.

**M2. Repeated-operation cost on the engine mailbox.** `local_dependencies_current/1` (`quod_client_simulation.erl:122-127`) issues a `quod_prolog:stats/1` gen_server call per local dependency, and it runs twice per open: at `resume_projection` (line 130) and again at `attach` (line 168). The old code made one `applied/1` call per namespace. Because the runtime subscription is registered before the first check, any advance after it arrives as a `projection_advanced`/`applied_live` message and triggers refresh anyway, so the second check is redundant. Worse, a stats timeout under load yields `#{}` (`quod_prolog.erl:994-996`), which reads as a height mismatch and triggers `refresh`, which triggers a full signed proof plus more stats calls. That is a refresh storm on an already saturated engine.

**L1. Crash on a narrow race.** `quod_client_simulation.erl:113-114` monitors `quod_reg:where({foreign_log,node})` after a successful follow. If the foreign log dies in between, `monitor(process, undefined)` raises badarg and the socket crashes instead of reporting unavailable.

**L2. Wrong reason on expiry.** `quod_client_simulation.erl:81-92`: when `Remaining =< 0` the client is told `invalid_dependencies`. The old code said `expired`.

**L3. Semantics change while waiting for installation.** The dedicated `waiting_expired` timer was removed; expiry now reaches `refresh(S, expired)` (line 219) instead of the terminal `unavailable/expired` that `waiting/4` used to send. Probably intended as unification, but it changes what the browser does on expiry and should be stated.

**L4. Local/foreign classification is decided once.** `follow_dependencies` classifies by `quod_reg:where({quod_prolog, Ns})` at registration. A locally hosted namespace whose engine is restarting is followed through the foreign log and never re-classified. Invalidation still works because certified progress advances, but the local incarnation monitor the plan requires is absent for that case.

**Design risk, not a defect.** Exact equality between the remote target's applied `BaseHeight` and the local foreign log's certified height (`quod_client_simulation.erl:228-231`) can skew by one under load, and local exact equality fails under continuous commits on any dependency namespace. Each miss costs a full signed proof. This is what the plan specified, so I only flag that the no-replay trace should include a loaded dependency.

**Note.** HTTP error bodies now carry `dependencies` (`quod_client_result.erl:399-403`), despite the comment that errors carry no request evidence. Fine if intended.

## Confirmed correct

- Origin height is the admitted `Applied` (`quod_prolog.erl:4389-4391`); co-hosted fresh and reuse opens return the worker height (`quod_prolog.erl:1776-1778`, `1964`); remote opens carry the authenticated `BaseHeight` from the `scope_opened` event and the router stores it on the per-proof reuse row (`quod_ask_router.erl:1115`, `1498-1499`). The only transition to `active` is that event, so reuse never returns an undefined height.
- Dependencies are read after finalize and before `quod_proof_context:stop` (`quod_prolog.erl:4402-4414`); `finalize/1` never removes scopes, so failed branches and abort keep them. Only `mode := read` is wrapped; control, cursor and writes keep their shapes.
- The context re-read in `open_scope` (`quod_proof_context.erl:605`) fixes a real pre-existing overwrite: the old `put_context(Ctx0…)` discarded the router binding and agent identity installed inside the opener. The modified `finalizes_remote_router_once` test now exercises the production order.
- Envelope validation: strictly increasing distinct namespaces, 256-bit anchors, uint64 heights, at most 8 entries, nested read rejected, whole-reply byte cap via canonical encode/decode.
- Socket ordering: subscribe/follow before any snapshot; errors release partial evidence (`quod_client_simulation.erl:89-90`); negative outcomes keep follows (line 156-157); every notice is acked; stale refs and duplicate DOWNs are harmless; unwatch runs inside `release` before the refresh reply; the expiry timer is the original absolute one.
- No polling, no new broker, no projection rebuild introduced.

## Omissions against the included sources

- No test that `await_remote_scope_open` propagates `BaseHeight` or that the co-hosted reuse path returns the worker height; the updated `quod_ask_tests` only discard `_Height`.
- No end-to-end test that `run_pinned_origin` wraps only `read` and that a failed alternative's scope appears in the envelope. The proof-context unit test uses fake scopes.
- No test for M1's bare-error corner.
- Socket tests are absent from the packet, as stated. The bundled `mark_body`/`transform` change (`quod_client_simulation.erl:196-212`) belongs to the earlier mixed-scene correction and rides in this diff.

Outstanding items named in the request (typed selection, remote collider projection, physical lifecycle, signed lobby acceptance) are untouched here and remain open.
