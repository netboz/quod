# Responsible owners and discriminating evidence

## Two engine cleanup corrections

`godot-4.7.2-openxr-lifetimes.patch` SHA256 `06e06c0670bc1ebf3b25f6946bdbcbf48ab674d89e90a5d399a9dbca06e31fed` changes2 private upstream source files, +6/-2, net+4. No relocation or Quod production change.

1. `modules/openxr/openxr_interface.cpp::_load_action_map` creates interaction-profile RIDs but incorrectly tests/pushes the local resource array rather than the member `interaction_profiles` collection. The existing `_free_action_map` owner frees that member. Installing each created RID in the same owner's existing collection fixes the missing ownership link; no second registry or suppression is added.
2. `modules/openxr/extensions/spatial_entities/openxr_spatial_marker_tracking.cpp::on_session_destroyed` disconnects a signal even when unsupported spatial-marker setup returned before connecting it. The destruction path now shares the existing creation support guard. Actual connected supported lifetimes retain their normal disconnect.

Exact official source/archive, original and changed files, full patch, original15214-entry manifest and generated/build artifacts are retained. `native-sim-baseline01` and `native-sim-patched01` execute the same196-file fresh application payload, with only the executable changed. Both supply18 application assertions and272 nonempty stereo submission entries; only baseline reports the spatial disconnect error/profile RID leak. Patched client/runtime/wrapper0, EOF, clean diagnostics. One native session per case,3 adapter pause/reentry cycles. Simulator controller source-valid frames are0; no wand acceptance.

`native-fault-reentry01` adds a different lifecycle interleaving: output writing deliberately throws DirectoryNotFoundException; the existing shared exception path awaits Main.CloseApplication(1). Its real client1 is preserved, its disconnect notification is observed, and monado-ctl sees that owned PID absent. The same still-running owned runtime then accepts a fresh process/native session of the exact same application, which passes18 and exits0/disconnects/absent. Both cases balance one swapchain create/destroy; native lifecycle entry counts are retained separately. Runtime/wrapper0, all EOF, no reader errors or target diagnostics. No sleeps, retries, deadline changes, new app close route or product exception handling.

The old direct-Quit SESSION_NOT_STOPPING minimal repro remains failed under its old engine boundary. Current Quod requests exit and observes stopping through its existing owner. The new cases have the expected exit/end/destroy entry chain and no SESSION_NOT_STOPPING diagnostic; this does not rewrite the old repro or close all QUO-27 platform obligations.

## Display path is a separate cause

Installed Hyprland0.56.2 source at actual commit `efb50993780079460b0cbed1363e2166a2de1d9f` (Aquamarine0.15.1) checks the disabled output rule before offering a non-desktop connector for DRM lease. User's runtime configuration has three explicit desktop rules and then a catch-all disabled rule. Actual Wayland discovery initially offered no connectors although DRM reported connected non-desktop Vive HDMI-A-1/id828. The live non-desktop monitor path also does not update that active rule through an ordinary rule application.

The first explicitly authorized HDMI-only exception command returned0 but did not produce an offer within its20s observation; it remains failed and was restored. After the human-authorized physical HDMI reconnect, the read-only observer received actual HDMI-A-1/id828 offer notification. Its observer/wrapper0/EOF are offer proof only. Subsequent owned Monado direct-mode runs select828 and reach2160x1200 display surface/swapchain/vblank initialization. No other monitor, config file, global driver/runtime selection or display session was changed; the temporary exception was restored after each owned run.

An already published lease offer can outlive the temporary runtime-rule exception because the compositor's offer collection persists. We claim the exact restoration command, unchanged desktop properties and unchanged76 config files; we do not claim the whole compositor state became byte-for-byte identical or perform a global reload to force it.

The earlier Xlib VK_ERROR_UNKNOWN/:0 authorization failures remain separate. Actual real lens output is established only by `vive-display-observation03` and its human answer. Neither the profile RID fix nor unsupported-spatial guard modifies display creation or tracking.

## Cold tracking and rendering limits

Pinned `OpenXRAPI::pre_render` uses xrLocateViews validity bits to set `render_state.view_pose_valid`; `pre_draw_viewport` checks this before creating/acquiring application swapchains. The read-only source path is compatible with no application swaps while native head/view tracking is invalid. The cold run records90 invalid head frames and0 swaps; the later manual run records valid/high head frames,15,203 nonempty two-view submissions and human-visible Quod in both lenses. We did not capture the cold render-thread flag/returned xrLocateViews result, so this does not establish every historical missing-image cause. No confidence guard,90-frame assertion, calibration, mapping or profile is relaxed.

Manual observer01/02 readiness failures are harness/diagnostic-export failures, not reproductions of the historical desktop stalls. The release template clears unsafe CLI script overrides; observer01's embedded successor still lacked a delivered stdout readiness marker. The final observer uses a normal embedded entry scene and stderr markers; the release source defaults to buffered stdout. That change and subsequent readiness discriminate observation delivery, but do not prove the exact absence cause in the killed prior process. All failed bytes/logs/exits remain.

No desktop close-chain rewrite, SignedView change or new desktop observation was made. Both original desktop stalls remain failed/unattributed; the new native fault result does not locate their cause.
