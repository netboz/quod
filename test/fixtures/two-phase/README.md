# Superseded .200 carriers

The files below are base64 transports of actual .200 writer output, captured
and reopened by frozen commit `7f4500cdd066d7c669976d4d9bec218a3cd9f4fb` in an
isolated local VM. Permanent tests pin every decoded SHA-256. No live fleet
store, private production identity, or compatibility decoder is involved.

| Fixture | Contents |
| --- | --- |
| `ledger-v6.b64` | Signed transaction plus signed Begin in slot 2 with a real commit certificate |
| `transaction-v14.b64` | That writer's signed transaction submission and target binding |
| `outcome-v7.b64` | Closed DETS outcome index after applying the Begin |
| `phase-history-v1.b64` | Old phase codec's canonical history row, not a full DETS file |
| `effect-qej2.b64` | Own signed plan bound to a pending group; no effect executed |
| `cache-v4.b64` | Old foreign-cache identity manifest |
| `checkpoint-v4.b64` | Old writer's checkpoint containing the Begin projection |

These are format/admission controls, not full founding or live-consensus
witnesses. The ledger uses the existing signed local fixture; the effect
fixture uses the existing policy-binding stub and synthetic group reference.
The cache writer uses the same ledger bytes as `ledger-v6.b64`. The checkpoint
test also isolates its guard inside a deliberately mixed current-manifest,
current-ledger store: old bytes must be refused, never relabelled as corruption
and automatically deleted. Normal all-old cache refusal is tested separately
at the actual owner startup boundary.

Capture receipt and true-exit logs: I1 `old-carriers-v4/CAPTURE.json` and
`runs-old-carriers-capture-v4/`. Earlier failed capture attempts remain retained.

## Signing journal

`qsj4-signing.b64` is a text transport of the unchanged, real QSJ4 file emitted
and successfully reopened by the frozen .200 journal and codec at commit
`7f4500cdd066d7c669976d4d9bec218a3cd9f4fb`. It contains one signed pending Begin
made with test-only identities, not live key material or fleet data.

Decoded bytes: 9,467; SHA-256:
`cae5823b77650473ce1beecedec05dfff58bad1a94cb97fbb9c42f896bc8a482`.
Namespace: `quod:signed-fixture`; domain: unsigned integer 41 in 256 bits.

The I1 capture receipt records old-code acceptance before the journal changed.
The permanent current-code test requires named refusal without mutating these
bytes. Base64 is only fixture packaging: the store opens the decoded old file.
