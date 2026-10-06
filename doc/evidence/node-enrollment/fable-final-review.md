# Final Fable readiness verdict

Read-only review; no child builds or tests. Earlier architecture/security review and its independently checked corrections are retained in the adjacent reports and summarized in validation.md.

The router delta mirrors the auth one exactly and is correct.

- **Owner identity and timing.** The router registers as `{local, quod_client_goal_router}` before `init/1` runs ([quod_client_goal_router.erl:47](/home/yan/src/quod/src/quod_client_goal_router.erl:47)), so the pid in the notice already resolves through `whereis`. The notice is published after the channel subscription and immediately before `{ok, S}`, so a router that announced itself can already receive forwarded frames; nothing is announced before it is usable. The test init clause deliberately publishes nothing, which keeps fixture routers from waking a production manager.
- **Manager side.** Subscribe in `init` before the startup snapshot, incarnation check against `whereis`, unsubscribe in `terminate`, all identical to the auth handling, and both feed the same coalesced job through the dirty flag. A stale notice from a dead router incarnation is ignored; the live incarnation republishes. No new process, no timer, no change to route authority or custody.
- **App barrier.** The restored cast sits after `maybe_start_directory_tracking`, so it fires only once every supervisor child exists and tracking has started, and the comment states its distinct purpose. With the two owner notices it is at most one additional `enroll/0` run per boot.
- **Combined effect.** A first dispatch refused while the router was absent is now re-driven by the router's own readiness edge, not by unrelated traffic. That closes the residual I raised without broadening scope.

**Final verdict for these deltas:** safe, readiness-complete for auth-only, router-only and whole-tree starts, and consistent with strict no-resend. Nothing further from me is needed before the tree-04 freeze and the full sequential clean campaign. The retained live-fleet migration remains unapproved and unrun.
