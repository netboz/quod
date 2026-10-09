# Qualify the optional native Godot client and resolve OpenXR shutdown failures

Local tracker: [QUD.28](nimbalyst://QUD.28). Tracker metadata and local body are saved; collaborative body storage failed on creation and retry. This file preserves the complete task description.

+Preserve the existing client/native prototype and doc/evidence/native-godot evidence. Yan prefers WebXR; this is an optional parked client workstream, not a replacement for [QUD.26](nimbalyst://QUD.26) or a reason to change the server.

Latest desktop entry, persistence, TLS/authentication, rendering and capture checks passed in the owning session. Native OpenXR qualification remains failed: XR_ERROR_SESSION_NOT_STOPPING, spatial-discovery signal teardown diagnostic and leaked interaction-profile RIDs are retained in native-xr-03. Simulator stereo/tracking and zero engine exits do not establish physical headset acceptance.

Finish by identifying the actual engine/runtime teardown cause and validating the exported client on intended Vive hardware, including pixels, input, focus/disconnect/re-entry and clean shutdown. Verify current real-lobby reads with the user's ordinary existing identity/account path; do not create a disposable world as acceptance or search for private credentials. Keep public TLS verification, retained operation identity and no uncertain enrollment resubmission.

The native client currently provides observer camera movement and tracked room-scale view only; it has no authoritative controlled-body or controller locomotion integration. Any future support must reuse the existing signed control/projection interface and ontology policy and be explicitly scoped. Keep all server source/protocol/deployment changes out of this client task.

Before commit, curate exact client-only source/evidence, reuse unchanged qualified gates, and state hardware limitations honestly. References: client/native/README.md, doc/native-godot-client-plan.md, doc/evidence/native-godot/README.md and the latest mouse-capture evidence.
