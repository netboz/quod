# Prepared direct visual-test launch card

OFFLINE ONLY. Root must verify this artifact and separately authorize one future launch. No app/fixture/XR session is running. Do not ask Yan to wear the headset during preparation: invite him only after actual VISUAL_READY. There is no AI preflight/build/audit at test time; the existing owners still perform exact mapped-incarnation, expiry and source checks as part of launch.

From `/home/yan/src/quod_worktrees/pearl-stone`, run the following with **tty:true**, then wait only for this fixture's actual M1B_READY:

```sh
python3 -B doc/evidence/godot-attention-vr-preparation-20261102/manual_run.py attention-visual-fixture-wrapper01 -- python3 -B doc/evidence/godot-attention-vr-preparation-20261102/serve.py attention-visual-human01-server --stage /data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source --profile test --qualified --presentation-source --clean-manifest /data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source-manifest.json --affected-wire doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json
```

Immediately run the client with **tty:true**. Its existing local owner sends one delegated begin after the exact mapped PREPARED state; no second coordinator round trip:

```sh
python3 -B doc/evidence/godot-vr-visual-readiness-20261102/live.py --label attention-visual-human01 --manifest doc/evidence/godot-vr-visual-readiness-20261102/inputs/client-attention-vr-visual-companion01-manifest.json --server-label attention-visual-human01-server --launch-and-begin
```

The fresh labels are reserved for one future opportunity only. If they already exist, stop rather than reusing a profile or replaying work. No old PTY/PID is a target.

**VISUAL_READY** is emitted on the first actual Focused/CanRender/advancing stereo callback with tracked head and currently accepted signed world/receiver, while authentication is unexpired. It immediately starts the visual participant interval. Invite Yan: “The visual scene is ready; you can put on the headset now. Look for Current space and the two Analyzer objects.” This is not a claim about headset pixels or interactive readiness. Report each controller's actual tracking/bindings. For any pointing or selection, use only a controller currently supported, tracked and admitted by the existing production input owner. The separate strict two-controller result is optional qualification, not a visual-test gate. When the corresponding input is admitted, the proposed user task is: choose an Analyzer, view its form near the object or in the personal workspace, then open an attention request and choose Later. Do not automate these actions or claim success without feedback.

The legacy VR263_READY remains a separate strict two-supported-controller result. It does not restart any deadline, and the visual path does not wait30 seconds for it. Missing controllers stay governed by production input fences. Temporary signed Updating remains locked and observable without closing a visually admitted session. The finite30-second failure bound is for failure to obtain a qualifying visual frame; preparation180, participant1800, close60, outer2100 and authentic earlier expiry remain absolute.

On explicit stop, expiry or failure: send client `finish\n` once through its current exact-owned supervisor, await actual closure/EOF or retain the failure, then send fixture **`stop\n` exactly once** (hex73746f700a). Never send an empty line, silently retry an uncertain write, signal a runtime helper or extend a deadline.

281 timing: coordinator-reported delay **4m8s** preceded app preparation. Saved app preparation was **6.816s**, local begin followed PREPARED by **0.004666s**, and the former native controller gate ended at30s. These are distinct intervals; the coordinator delay is not app startup latency. Failed281 remains unchanged, including native admission failure and incomplete client EOF.

Exact input hashes, current14-source server bindings and commands are in [run-card.json](run-card.json). Companion manifest SHA `3d6256aa8923d28cc9c0b78fc13ee764f0cebcfb05037300e00be398db2918c2`; accepted product SHA `dce5fe3f690dec8e3b7fd54b2e8da622efaa5e61ff65c4330b09cb21833f05bf`. Per-process Qt=xcb and installed SteamVR selection preserve Godot Wayland/Vulkan/mobile and all global/user settings.
