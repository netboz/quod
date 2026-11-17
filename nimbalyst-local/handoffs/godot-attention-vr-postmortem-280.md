# Closed opportunity280: offline post-mortem

The original native admission failure and separate fixture stop error remain unchanged. Both children and wrappers exited **1**, with all four EOF and no reader errors. Their absence was checked during closure; this review made no new process, hardware, runtime, display or focus query. No new launch or control write occurred.

## Evidence and uncertainty

- **Native admission:** the saved BLOCKER reports SteamVR/OpenXR 2.18.4, running/Synchronized, `CanRender=false`, primary interface and action set active, `UseXR=true`, Always, stereo2, draw count4. Signed world, operation and question-receiver acceptance remained true, captures0, with 865.025 seconds of sign-in remaining. No READY or participant interval began. Local PREPARED→begin took 0.036440 seconds, with 169.481500 seconds of original preparation remaining.
- **Standby:** unestablished in the inspected invocation receipts. There is no explicit standby observation in the captured client/native logs and no separate retained SteamVR server/monitor interval log identified in this input set. Synchronized, headHigh and the user's earlier availability statement do not prove standby, wearing or absence.
- **Frame pumping versus render admission:** only one predicted-display-time sample, 260162122767215, was retained. The `xr_frames=0` observer requires the whole render predicate, including `CanRender`; it does not count native `xrWaitFrame`/`xrBeginFrame`/`xrEndFrame` calls. These receipts establish neither advancing native frame calls nor a directly recorded `shouldRender=false` value. No positive rendered-frame marker was emitted. The native log's single “No viewport was marked with use_xr” warning is retained alongside the later BLOCKER's `UseXR=true`; it is not proof of a persistent viewport defect. Buffered managed/native stdout ordering is not a common timestamped timeline.
- **Qt monitor:** this process selected `QT_QPA_PLATFORM=xcb` while retaining DISPLAY/WAYLAND_DISPLAY. No matching helper incarnation or Qt platform-plugin error was recorded. Preflight observed an already-existing user-owned vrmonitor. None of that proves a new Qt helper started successfully or that Qt caused the admission failure.
- **Controllers:** both native profiles were `/interaction_profiles/none`, untracked/notneutral, with unsupported router sources and empty bindings. This is direct admission evidence, not a controller-power, pairing or wearing diagnosis. Model completion was settled with all model acquisitions/instances/leases zero, so it is not evidence of loaded controller models. HeadHigh was reported but presence was unsupported/null.
- **Other native errors:** stderr retains initial `xrCreateInstance` errors and the actual 30-second readiness timeout. Later successful initialization/running observations preclude describing the entire invocation as an instance-creation failure. Their causal relationship is unestablished.

The original signed setup was accepted; no human occurrence-form/attention task was performed or credited. This review identifies no production or runtime correction justified by the available interval.

## Fixture teardown correction for future recipes

I sent one blank LF to the fixture. Its saved `commands/0` accepts exactly `"stop\n"`; the blank line instead reached JSON decoding and produced `unexpected_end`. That explains the fixture's nonzero exit independently of the earlier native BLOCKER. It is an operator input error, not an XR or application result. No second write was sent.

The future [teardown contract](../../doc/evidence/godot-attention-vr-preparation-20261102/future-stop-contract-after280.json) records machine-readable, distinct commands:

1. Address only a newly authorized, verified current client supervisor; send `finish\n` once if still live and not already finishing. Await actual closure/EOF under the original bound.
2. Address only that invocation's verified current fixture; send **`stop\n`**, exactly the five bytes **`73 74 6f 70 0a`**, once if still live and not already stopped. Await its actual exit/EOF. A blank line, JSON-quoted string or literal backslash+n is incorrect.

Closed/replaced PTYs are forbidden. An uncertain control write is recorded, never replayed. This addendum is documentation for future recipes and test harnesses, not launch authority or an executed teardown regression. The original prepared receipt, executed drivers, failed result and profile remain intact.

## Disposition

- [x] Bound the original closure, invocation, client/native/helper observations and fixture receipts.
- [x] Separate observed admission conditions from unmeasured standby, native frame progression, Qt startup and wearing.
- [x] Document exact future stop bytes against the saved existing command owners.
- [x] Preserve original failures and finish offline; no retry or new opportunity.

[Original closure](../../doc/evidence/godot-attention-vr-preparation-20261102/closure280.json), SHA `d10d988cb0bbf454aabff0150cb957b2755980a437b399f63de8513bb41262dc`, and [offline analysis receipt](../../doc/evidence/godot-attention-vr-preparation-20261102/postmortem280.json), SHA `3f085f79d4cb2e0640fdf2de4fcabc4bbd459b4eb7465ab11f96f537b93d9d94`, retain the exact input hashes, modes, line references and limits. [Offline command receipt](../../doc/evidence/godot-attention-vr-preparation-20261102/logs/postmortem280-offline01.json) records actual child0 and explicit completion; this is analysis success, not a new application test. [Analysis source](../../doc/evidence/godot-attention-vr-preparation-20261102/postmortem280.py) reads only the named saved files.

The final full worker inbox batch contained this post-mortem instruction and coordinator observation `meta-1793615536737-6hsz9vf`; both bodies were read. Its viewport-warning/initial-instance-error cautions agree with the disposition above. Listing the batch does not consume its rows. No production or feature-inventory change; no package, human/HMD or shutdown-reliability acceptance.
