# Native Godot first-slice evidence

The latest [mouse-capture checks](20261009-mouse-capture/README.md) verify
click-to-capture, persistent look and explicit release, replacing hold-to-look.

The [scene/navigation checks](20261009-scene-navigation/README.md) reproduce the
lobby shadow defect with its packaged models and verify desktop camera controls.

The latest [staged entry and contrast checks](20261009-staged-entry/README.md)
verify offline key creation, explicit connection, saved-key recovery, quieter
lobby controls and revised lighting.

The [deployed connection check](20261009-deployed-connection/README.md) verifies
native TLS/authentication against the LAN node and corrects the challenge fixture.

For the subsequent browser-style identity generation, storage and account setup,
see [identity/onboarding evidence](20261008-identity-ux/README.md).

Date: 2026-10-08. The client implementation and Linux export are available;
the overall first-slice acceptance is **incomplete**. No deployed Quod account
was used, physical Vive testing was not performed, and the native XR shutdown
gate fails with engine diagnostics.

## Passing client gates

The final [sequential client run](20261008-first-slice/final-client-01/format/result.json)
passed formatting, four Rust core tests, the shared browser-generated corpus,
eight existing browser contract test files, Clippy with warnings denied, the
release extension build, Godot resource/scene checks, the actual connection UI
against a local TLS fixture, Linux export and startup of the exported binary.
Every gate retains its full log and true exit under
`20261008-first-slice/final-client-01/`.

The [TLS result](20261008-first-slice/final-client-01/tls-fixture/result.json)
exercises worker-thread encrypted identity import, certificate verification,
custom node/port selection, Ed25519 challenge and exact signed lobby reads.
Changing the port retires the old identity/session and scene. Its server is a
test-only Node HTTPS fixture with disposable identity material, not a modified
Quod deployment. It permits only the two required reads.

The [viewer log](20261008-first-slice/final-client-01/viewer/output.log) checks
asymmetric model transforms, subject identity, fresh and reused asset allowance
enforcement, retained children across parent removal and resource cleanup.
Unchanged repeats preserve resource fetch/decode counters and occurrence
instances. No disk asset cache exists.

The [desktop capture](20261008-first-slice/desktop-frame-02/frame.png) verifies
the real Vulkan renderer and the scrollable node/port/identity connection form
in a short desktop window. The [export startup log](20261008-first-slice/final-client-01/export-start/output.log)
qualifies loading the packaged extension and diagnostic scene headlessly; it
does not establish real-server or physical-XR operation.

## XR result and remaining blockers

The final [native XR result](20261008-first-slice/native-xr-03/result.json) is
**failed**, despite both application child exits being zero. It used the
existing private Monado 25.1.0 simulated runtime, NVIDIA RTX 4090, Vulkan Mobile
renderer, stage floor reference, two simulated simple controllers and a
diagnostic cube. The service ran in its own temporary runtime directory and was
stopped by the harness; the previous WebXR campaign was preserved.

Each of two sessions observed 120 post-render intervals, two eye transforms
separated by approximately 63 mm, a changing head pose, and both controllers
tracked. Raw timing samples are retained in the session JSON files; the
[computed summary](20261008-first-slice/frame-summary.json) includes all samples,
including warm-up. These are application frame intervals in a simulator, not
GPU timings or headset comfort measurements. No physical controller button
delivery, focus recovery or physical headset output was qualified.

Both final logs retain these shutdown diagnostics:

- `XR_ERROR_SESSION_NOT_STOPPING` from the runtime during engine teardown.
- A nonexistent spatial-discovery signal disconnection, matching
  [Godot issue 122238](https://github.com/godotengine/godot/issues/122238).
- Two leaked Godot OpenXR interaction-profile RIDs.

The capture API returned black images for the XR multiview target. Those files
are retained as failed visual evidence, not proof of headset pixels. Desktop
pixel output is verified separately. The rig's application-owned tracking
callback teardown and action-name conflict were fixed; the remaining engine
diagnostics are not suppressed or converted into passes. Resolving/qualifying
those diagnostics and testing the physical Vive remain required before claiming
clean XR acceptance.

Live-node acceptance also needs a chosen reachable TLS endpoint and an existing
account's encrypted identity backup, entered by its owner through the client.
No private identity material was searched for or added to fixtures.

## Failures and provenance

All earlier attempts are retained. The first XR harness reported a misleading
pass because it checked exit codes and measurements without scanning diagnostics.
Its unchanged `native-xr-01/result.json` is superseded by this triage and the
strict failed results from runs 02/03. Run 01 also exposed the corrected tracking
lambda and `grip` action-name issues. Run 02 removed those application errors.
The audio-less fixture now explicitly uses the Dummy audio driver.

Other retained failures were compilation/type errors during implementation,
the exact lobby-goal spacing and JSON numeric representation in conformance
tests, an incorrectly constructed negative fixture, an importer socket denial
inside the sandbox, and two Clippy findings. Each was corrected before the
final sequence; no failed log was replaced or assertion weakened. Desktop
capture 01 exposed the form-height issue corrected in capture 02.

The [source manifest](20261008-first-slice/source-manifest.json) records the exact
client files, current browser reference contracts, asset fixtures and export
hashes. The [initial baseline](20261008-first-slice/implementation-01/baseline.json)
and [initial working-tree status](20261008-first-slice/implementation-01/status-before.txt)
preserve unrelated dirty work. Existing tracked files matched that baseline at
final inspection except concurrently modified `rebar.config` and `rebar.lock`;
this work did not write either file. Its writes are confined to the new native
client, shared client fixtures, its plan and this evidence.

Production source delta: **+2,306 / −0 lines** across Rust, GDScript and shaders,
excluding tests, tooling, declarative engine resources/configuration and docs.
This is a new client surface; the growth provides the reusable protocol core,
required cryptography/asset validation, native rendering and transport/XR owners.
It does not add server machinery or remove the existing browser surface.
