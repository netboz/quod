# Deployed native connection

The client now authenticates against `192.168.1.10:31609` using the selected
self-signed certificate and its `localhost` certificate name. Dial address and
verified certificate name are separate settings; a name override requires an
explicit trusted certificate. TLS verification remains enabled.

Live testing also found that the original native fixture incorrectly represented
the challenge ID as 32 bytes. The unchanged server's `challenge_bytes/7` requires
16 bytes. Rust validation and the browser-generated fixture now match that
contract, including a rejection check for the old invalid length.

[Live check 03](live-auth-03/output.log) passes actual Godot TLS, challenge
authentication and public catalogue discovery; signup is advertised. It uses a
separate local test identity and makes zero domain writes. Automatic approval
review rejected live test-account/lobby creation because it would create
persistent remote state without explicit approval. The read-only alternative
was approved. Account creation remains the user's explicit client action.

The sequential `deployed-client-final-01` gates passed core/browser contracts,
Clippy, resource checks, TLS import, three-process onboarding/recovery, export
and exported startup. The onboarding fixture now dials an IP with a localhost-only
certificate. [Negative checks](deployed-client-final-01/onboarding-fixture/tls-rejections.json)
verify both wrong-name and unrelated-certificate handshake rejection; expected
TLS diagnostics are preserved in their separate log.

Failed live check 01 retains the signal-name parse error and its terminated
child exit. Check 02 retains the authentication length mismatch. Neither failure
was overwritten. [Source and export hashes](source-manifest.json) freeze the
tested implementation. Production source delta is net **+17 lines** for the
TLS setting and corrected challenge validation, excluding tests/tooling/docs.

The native desktop client was opened with the endpoint, certificate and TLS name
prefilled. These settings are remembered in the local development profile; the
user can reopen it with `python3 client/native/tools/run.py`. No server code,
configuration or domain data was changed. Full real-account/lobby and physical
Vive acceptance remain separate from this live connection result.
