# Analyzer visibility headset test — prepared

The corrected private client and signed fixture are ready as artifacts. No client, fixture, sign-in clock or participant interval is running. The next opportunity uses fresh label `visibility-visual-human02`.

Yan gives the launch instruction **before** putting on the headset, then puts it on immediately while these commands start. Do not wait for a second reply, confirmation, or typed `begin` from Yan. Start the fixture with `tty:true` and wait for `M1B_READY`:

```sh
python3 -B /home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-attention-vr-preparation-20261102/manual_run.py visibility-visual-fixture-wrapper02 -- python3 -B /home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-visibility-client-package-20261102/serve.py visibility-visual-human02-server --stage /data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source --profile test --qualified --presentation-source --clean-manifest /data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source-manifest.json --affected-wire /home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json
```

Then start the client with `tty:true`:

```sh
python3 -B /home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-vr-visual-readiness-20261102/live.py --label visibility-visual-human02 --manifest /home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-visibility-client-package-20261102/inputs/client-visibility-vr-visual-companion01-manifest.json --server-label visibility-visual-human02-server --launch-and-begin
```

The client sends its own single begin after mapped PREPARED. Monitor `VISUAL_READY`: Focused, CanRender, advancing stereo frames, tracked head and signed world/receiver. Process start or PREPARED is insufficient. Yan does not need to read or answer chat while wearing the headset. If the original 30-second no-frame limit fires, retain the failure and close normally. No build, audit, runtime setting change or retry is part of launch.

The task is agreed before launch: select either of the two parts of the **same Analyzer**. Check whether `Analyzer settings` and `Measurement` appear in front of the selected part and whether the field and action are readable. Do not Submit. If that works, move the same form to Personal workspace and back Near this object. Yan can remove the headset afterward to report or request stop; there is no in-headset chat step.

The existing owner enforces preparation 180 s, no-visual-frame 30 s, participant 1800 s, normal close 60 s, outer 2100 s and the earlier authentic sign-in expiry. On a stop, send `finish\n` once to this exact current client, await its close/EOF, then `stop\n` once to its fixture. The previous human01 targets remain closed.

The parent [qualification](../godot-visibility-client-package-20261102/result.json) and [source bindings](../godot-visibility-client-package-20261102/artifacts-ready.json) are retained. The last live attempt yielded zero VR frames in SteamVR Synchronized; this card makes no headset-ready claim.
