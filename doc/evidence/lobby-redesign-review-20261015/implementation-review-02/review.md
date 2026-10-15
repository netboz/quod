# Follow-up review — B1/B2 closure and evidence

Scope: supplied excerpts only; no tools. Gates-02 is *starting*, not passed; nothing here assumes otherwise. Advice consultative.

## Verdict

Both blockers are closed by minimal, in-owner changes. The stale-comment cleanup is done. No new correctness blocker in the supplied code. The implementation may proceed to the authorized candidate refound and desktop acceptance **after** the frozen gates-02 campaign passes with full logs and true exits, plus the image-level checks listed under "Acceptance evidence". Nothing below requires further refactoring.

---

## B1 — frozen source paths: CLOSED (implementation), with deployment conditions

What changed: `quod_fresh_systems:path/1` → `/opt/quod/priv/ontologies/<File>`; Dockerfile creates exactly one `/opt/quod/priv` symlink to the single `lib/quod-*/priv` (build fails if zero or many). The quod:lobby genesis now freezes a release-independent path; each image re-points the symlink; `provision_lobby` reads real contents at prepared creation and freezes them in the new lobby genesis. That is the failure mode I raised, removed without a resolver, fallback or parallel path. Inline source correctly rejected (88,061 > 65,536; no cap change).

Residuals (none blocking, no code change required):

- The five file names are now a frozen genesis contract: renaming/moving any of `lobby_instance.pl, space.pl, agent_instance.pl, quod_physics.pl, space_view.pl` in a later release refuses every new signup until the next quod:lobby refound. Worth one invariant comment at `terms(<<"lobby">>, …)` (AGENTS: keep comments about current invariants). Optional, same scope.
- `path/1` is used for *all* founding reads (including the signup template at `terms(<<"signup">>, …)`), so `quod_fresh_systems` founding now works only where `/opt/quod/priv` exists — i.e. the image. Non-image founding (dev shell `bootstrap=true`) regresses. Acceptable since the only sanctioned founding is the pinned image; record it in the handoff.
- Tests still found their own way, so the production path is only exercised in the image. Hence the image checks below are mandatory, not optional.

## B2 — non-monotone retirement fence: CLOSED

`physics_store_retired/8` (:586-592) now has exactly the three documented exits: cancellation, generation advance, revoked key + later host epoch. All monotone; matches `doc/lobby-redesign.md:131-133`.

The test (`quod_physics_tests.erl:2829-2854`) does what was claimed: original store paused with receipt retained → `physics_assign_authority(room,actor,other)` spawns a new owner (`P2 =/= New`) still reporting `activation_custody_unresolved`, receipt intact → swap back, new owner (`P3 =/= Swapped`) still unresolved, receipt intact → explicit `physics_cancel_activation` with the exact signed request commits → released original store is fenced (`:554`), fresh activation reaches generation 1, receipt retired (`:2865`). The orphan path I described cannot occur any more: the receipt (with its inner request) survives the swap, so a late-committed original store is resolved from the retained receipt, not stranded. Revoke branch (`:2855-2859`) exercises the key/epoch exit. ✓

## Same-scope cleanup

`quod_wire_term.erl:684-685` and `quod_client_goal_parser.erl:267-269` now state the depth bound only. ✓ GUI example migrated to `lobby_sky/2` with the same values (`quod_gui_examples_tests.erl:115-116`); test-only. ✓

## Disposition of prior evidence items

| # | Item | Status |
|---|---|---|
| 1 | Clean frozen gates | **Pending** — gates-01 stopped at 3999/4000 (preserved), gates-02 starting |
| 2 | `path/1` (B1) | Closed, image checks owed |
| 3 | `prepare_agent_key_custody` | Closed — proof-context + read-only + exact `{Ns,Anchor}` scope, `local_destination` = own node actor reference checked before and after the vault, `agent_key_preparation` proven on committed state with read-set absorbed (OCC on the grant; matches the revoke-after-proof test `:50-67`) |
| 4 | Observation stores read `physics_run(W,G,Token)` | Closed — `physics_valid_sample/2:684` reads the sample's exact G/Token (G>0, so pre-activation samples are invalid); used by `physics_rest_measurement:819` and `physics_hinged_measurement:112` before the store. The checkpoint-only predicate was not excerpted; stated as sharing the same predicate — low risk, accepted |
| 5 | Codec caller audit | Closed except one line: `decode_payload(failure_reasons, Encoded)` (`quod_scope_wire.erl:404-406`) bypasses the `payload_limit`/`quod_safe_term` branch. Show that `quod_wire_term:decode_failure_reasons/1` applies a byte bound before structural decode (the per-reason `?ERLOG_MAX_FAILURE_REASON_BYTES` at `:690` is on the encode side). Evidence, not a code change, unless it is unbounded |
| 6 | Dropped loop-case coverage | Half closed — signed `physics_edit_definition(console,…)` updates the native body, bumps structure, keeps the owner incarnation, and `reconcile_resource(all)` leaves installs unchanged (`lifecycle:78-97`). The *source-editor* edit of a physical lobby (no reinstall/replay) is still not shown; non-blocking |
| 7 | Rejection leaves no partial transition | Closed — malformed floor and body allowance < admission set both `{failed,_}`, `assert_unconfigured` (no host/key/assignment/control/body, no worlds after reconcile), authored row preserved, both gravities (`quod_physics_tests.erl:37-46,88-94`) |
| 8 | Execute-with-empty-diff cost | Closed — `submit_sealed_plans` routes `read` → `{ok, Bindings, [], ReadSet}`, no consensus slot (`quod_prolog.erl:653-654`) |
| 9 | Per-file delta | Closed — +331 reported; `quod_wire_term.erl` +68/−68 net 0 for a counter removal is odd but honestly reported, not blocking |
| 10 | Desktop acceptance | **Pending** |

R1–R8 dispositions: accepted as stated. R1/R2 are cost/availability limits, never resubmission. R5 correctly downgraded: the owner keeps source/policy editing authority, so first-host loss is recoverable by an ordinary ontology edit, not bricked.

---

## Implementation blockers

**None.**

Optional, trivial, same scope: the invariant comment on the five frozen file names (B1 residual). Not required to proceed.

## Acceptance evidence still owed (separate from implementation)

1. Gates-02: full sequential eunit/CT/dialyzer/xref, client files, UI build/lint — retained logs, true child exits. Any failure is triaged, not rerun.
2. Image check, before refound: on the built candidate image, `ls -L /opt/quod/priv/ontologies/{lobby_instance,space,agent_instance,quod_physics,space_view}.pl` and the signup template resolve; symlink is the only `/opt/quod/priv`.
3. Boot/founding on the image: refound succeeds (lobby + signup founding both read via `path/1`), then one real signup → prepared lobby creation on the candidate network.
4. The scenario B1 was about: after a subsequent image (patch bump), a new signup still creates a lobby. Verifiable by repeating item 2 on image N+1 before deploying it.
5. `decode_failure_reasons/1` byte bound (item 5).
6. Source-editor edit of a physical lobby without reinstall/replay (item 6, non-blocking).
7. Desktop acceptance items from `doc/lobby-redesign.md:160-177`.
8. Handoff notes: mixed-fleet divergence (old binaries reject what new accept — fine only for a clean pinned refound), R8 operator procedure, dev-shell founding regression.

## Conclusion

B1 and B2 are resolved minimally and correctly; no new blockers. Proceed to the authorized candidate refound/desktop acceptance once gates-02 is green with evidence and the image checks (2–3) pass. Item 4 should be verified before the first post-refound image rollout.

Stop-notification: tool-less review, `/bin/sh /home/yan/.codex/notify-stop.sh` not invoked; no delivery claimed.
