# Analyzer visibility test — revised offline preparation

No app, fixture or SteamVR process is launched by this card. Yan gives any future launch instruction from the desktop and puts on the headset immediately; the local owner sends begin once. There is no in-headset typing step.

Start the fixture with `tty:true`, await `M1B_READY`:

```sh
python3 -B /home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-attention-vr-preparation-20261102/manual_run.py visibility-visual-fixture-wrapper03 -- python3 -B /home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-visibility-client-package-20261102/serve.py visibility-visual-human03-server --stage /data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source --profile test --qualified --presentation-source --clean-manifest /data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source-manifest.json --affected-wire /home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json
```

Start the client with `tty:true`:

```sh
python3 -B /home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-vr-visual-readiness-20261102/live.py --label visibility-visual-human03 --manifest /home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-visibility-test-20261103/inputs/client-visibility-visual-companion04-manifest.json --server-label visibility-visual-human03-server --launch-and-begin
```

This separate diagnostic companion has the same 98 production inputs and 196 outputs. Its 30-second visual admission timeout is removed; the original 180-second preparation bound, authentic earlier sign-in expiry, 1800-second participant bound and normal exact-owned close remain. The local software guard still requires actual Focused stereo rendering and signed world/receiver before declaring VISUAL_READY; controller availability remains separate. If no admission occurs by the original preparation bound, close normally and retain the failure.

First human task, only after actual admission: select one of two occurrences of the same Analyzer and check whether the titled Measurement form is visible in front and readable. No Submit. On stop, exact current client `finish\n` once, then fixture `stop\n` once after client closure. No automatic relaunch or SteamVR setting change.

The prior [attempt result](attempt-visual02-result.json) retained 236 advancing stereo frames but only SteamVR Visible and no controller profiles. SteamVR's later crash is reported by Yan; its cause is not established. This revised card is offline preparation, not a headset-ready claim.
