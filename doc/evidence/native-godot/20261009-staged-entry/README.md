# Staged entry and rendering contrast

The client now prepares its identity before any network configuration or request.
A first launch offers **Create my key** and backup import. A saved identity skips
that welcome step and opens **Connect to Quod**, with remembered node and port.
Connect is explicit on every launch. Authentication without a network account
opens a separate account-creation step. Successful lobby loading closes the
panel; Menu/Tab exposes account, refresh, backup and disconnect controls.

Destination changes retire authentication, nonce, scene and resources while
retaining the local identity owner. Failed key import preserves the saved file
and displays recovery, with an offline Retry saved key action. Pending enrollment
still resolves its original signed operation without duplicate submission.

Ambient energy is 0.22 (previously 0.65), directional energy 0.9 (previously 1.1),
directional shadows are enabled, and filmic tone mapping uses exposure 0.7.
Server-authored materials and scene data are unchanged.

## Validation

The final [sequential gate run](staged-entry-final-02/) passes formatting, seven
Rust tests, browser/native contracts, nine browser test files, strict Clippy,
extension build, viewer/resource checks, isolated TLS integration, three-process
onboarding/recovery, Linux export and exported startup. Logs and true child
exits are retained for each gate. No deployed-node writes were performed.

The onboarding fixture verifies zero network requests before explicit Connect,
key creation despite invalid node/certificate settings, remembered key and
endpoint over separate launches, no identity/settings rewrite on unchanged
restore, exactly two enrollment writes and one outcome lookup, and a closed
menu after lobby load. TLS integration also verifies that destination change
invalidates signed reads while preserving the key, and a wrong-passphrase
import preserves the identity bytes and permits offline recovery.

[Final desktop captures](staged-entry-visual-04/run/result.json) pass with no
engine diagnostics. The entry panel also remains inside an 860×440 viewport;
its primary Connect action is visible and secondary controls can scroll.

[Welcome screen](staged-entry-visual-04/frames/welcome.png)

[Connection screen](staged-entry-visual-04/frames/connection.png)

[Short connection screen](staged-entry-visual-04/frames/connection-short.png)

[Key recovery screen](staged-entry-visual-04/frames/key-error.png)

[Original lighting](staged-entry-visual-04/frames/lighting-before.png)

[Updated lighting](staged-entry-visual-04/frames/lighting-after.png)

The visual comparison uses identical offline geometry/materials and camera,
with the earlier lighting applied only inside the test. Disposable generated
private keys are excluded from this evidence. Physical headset acceptance and
the previously recorded OpenXR shutdown diagnostics remain separate.

## Retained attempts and scope

`staged-entry-import-01` records the editor's local-socket sandbox denial; later
host-authorized export/import gates pass. `staged-entry-onboarding-01` records
a test synchronization failure: the test reacted to the preliminary disconnect
status instead of completed identity loading. The replacement waits on the
identity-loaded signal; run 02 and both complete sequences pass. No failure
was overwritten. Visual runs 01–04 retain the layout/exposure refinement and
final recovery-screen check. Final sequence 02 includes the recovery change
added after the earlier passing sequence.

The conceptual-thinking MCP was used to check the key/network ordering and
ownership boundary; knowledge-graph memory supplied the existing protocol,
recovery and server-scope constraints and records this revised flow.

[Source/export hashes](source-manifest.json) freeze the delivered tree. Production
source delta is **+259 / −107 lines (net +152)**, excluding tests/tooling/docs.
Growth supplies the staged, responsive presentation and explicit authentication
retirement. Identity persistence, transport, enrollment, resources and rendering
keep their existing owners. The old combined entry flow was replaced. No Quod
server source, configuration, ontology or deployed state was changed by this work.
