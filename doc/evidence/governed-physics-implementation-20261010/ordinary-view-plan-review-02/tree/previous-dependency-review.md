I have what I need; writing the review now.

**Verdict for this correction stage: M1, M2, L1, L2, L3 and L4 are fixed as described, and removing the second snapshot keeps a defensible linearization point.** No blocking defect found. One identity gap, a few low items and several missing tests remain. The new async socket and overflow tests were still running when this packet was frozen, so nothing below assumes they pass.

## Previous findings

- **M1 fixed.** `tree/src/quod_client_result.erl:57-66` validates dependencies first, normalizes the inner result through the ordinary path, rejects non-read outcomes, then bounds the whole envelope. `bounded_error/2` at lines 174-180 degrades to `{read, Deps, {error, R}}` and only then to `{read, [], {error, R}}`. Malformed dependencies return the empty list with `proof_unavailable`. The socket now reaches its `{error, _}` branch at `quod_client_simulation.erl:78` instead of the catch-all. Test coverage at `quod_client_result_tests.erl:152-173` covers inner overflow, invalid binding, aggregate overflow, dependencies-alone overflow and a malformed anchor.
- **M2 fixed.** One `send_request` per owner pid after all registrations (`quod_client_simulation.erl:148-152`), no stats call at attach, no timeout other than the signed expiry timer, cancellation in `release/1` at lines 346-347. Because `gen_server` requests use `{alias, demonitor}`, the zero-timeout `receive_response` deactivates the alias, so a late engine reply is dropped rather than delivered as a stray message. The lifecycle test at `quod_physics_tests.erl:923-946` holds the real engine inside a sys debug hook and shows the socket still handles expiry.
- **L1 fixed.** Monitor is taken on a known pid before `follow`, and the owner is re-checked after registration (`quod_client_simulation.erl:128-143`). Absent owner returns `dependency_unavailable`.
- **L2 fixed.** `Remaining =< 0` now reports `expired` (line 93).
- **L3 fixed and stated.** Unattached expiry is terminal (line 258-259); attached expiry refreshes (line 257). Covered at `quod_physics_tests.erl:975-981`.
- **L4 fixed.** A namespace with a known genesis or content supervisor but no engine takes a gproc `follow` name monitor and waits (lines 113-124). Re-registration refreshes.

## New findings

- **N1, Low. Local classification ignores the anchor.** `follow_dependencies/2` picks the local branch on namespace name alone (line 103). If the proof's dependency anchor differs from the local genesis hash, the mismatch is only seen at `snapshot_response` (lines 158-161) and answered with `refresh`. A client that obeys refresh re-proves and hits the same mismatch, so a persistent mismatch becomes a re-proof loop. Realistic only for a re-founded namespace reachable under two anchors, but the identity rule should be `{Ns, Anchor}`: when the local genesis hash differs, follow it as foreign or answer `unavailable`.
- **N2, Low. The socket still blocks on the foreign-log owner.** `quod_foreign_log:follow/2` and `unfollow/1` are synchronous one-second calls (`quod_foreign_log.erl:892`, `983`), up to eight each per open. A busy owner turns into a terminal `dependency_unavailable`, which is the same class of load sensitivity M2 removed for engines. `follow_request/2` and `unfollow_request/1` already exist (`quod_foreign_log.erl:905`, `918`) and fit the request-collection pattern.
- **N3, Low. Redundant clause.** `applied_live` handling at `quod_client_simulation.erl:279-280` duplicates `projection_advanced` (lines 277-278): every material apply also publishes `projection_advanced` (`quod_prolog.erl:1497-1505`). The only namespace lacking an owner pid is the name-follow case, and there the `registered` notice refreshes before the engine can publish. Verify by trace and remove, or state the reason it stays.
- **N4, Low. Unreachable guard.** The `{{reply, _}, _, _}` clause at line 164-165 cannot fire for the current `get_stats` reply shape (`quod_prolog.erl:1277`). Harmless, but one more concept.
- **N5, Note. Unreachable foreign dependency waits silently.** An `{unreachable, …}` notice while pending falls into the wait branch (line 273), so the client learns nothing until expiry. Consistent with the foreign log's "unreachable is not a refusal" rule, but worth stating.
- **N6, Low. Dependency namespaces are unbounded.** `valid_dependencies/3` (`quod_client_result.erl:320-323`) checks no namespace length, although the directory bound is already included. The aggregate-overflow test at `quod_client_result_tests.erl:165-171` depends on a 256 KiB namespace the proof can never produce. A faithful test uses eight real-length namespaces and an answer just under the cap.

## Linearization point

Removing the second snapshot is sound. Subscriptions and follows exist before the single snapshot. The engine answers `get_stats` after every earlier apply, each of which already published to the subscribed socket, and Erlang orders messages between one sender and one receiver, so any advance after the reply arrives after it. The attached view therefore means: every dependency equalled its pinned height at its reply, and no advance has been observed since. An advance between reply and attach is delivered right after attach and refreshes. The second snapshot added nothing. The same holds for foreign dependencies: a first consumer receives `{building, _}` then a certified notice from the woken follow job (`quod_foreign_log.erl:3390-3399`, `3780`), and coalescing keeps the newest height.

## Confirmed correct

- Subscribe-before-snapshot order, including `{physics, Ns}` before the proof (line 49).
- Exact checks at the reply: pid, genesis hash and height (lines 158-160); lower waits, higher refreshes (lines 297-302).
- Stale replies and duplicate notices are harmless: fresh request collection per open, `no_request` falls to `{ok, S}`, released state matches no clause.
- Retained negative outcome keeps follows and timer (line 195-196); errors release everything (line 78); the lifecycle test verifies a later grant wakes the same view (`quod_physics_tests.erl:909-922`).
- Timer reference is synchronized with attached state; stale timer references are ignored.

## Missing obligations and unverifiable items

- No test for the name-follow path (engine missing at open, then re-registered). It rests on gproc delivering `{gproc, registered, Ref, Key}` for a `follow` monitor taken on an unregistered name. I believe that is gproc's behaviour but could not confirm from the packet.
- No test that an engine snapshot above the pinned height refreshes before attach, nor for the lower-height wait, nor for a foreign owner that changes incarnation between follow and the post-check.
- `quod_simplex:genesis_hash/1` for an unknown namespace must return `undefined` for line 114 to classify correctly. Not in the packet.
- Production line delta could not be computed from this packet.

Scope stays partial as stated. Typed normal-view selections, UI integration, remote collider projection, physics admission and signed lobby acceptance are untouched here and remain open.
