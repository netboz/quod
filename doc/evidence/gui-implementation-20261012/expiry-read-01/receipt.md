# Verification receipt

All exits below are actual rebar child exits, collected by the parent. No active
jobs remain from this scope. Source manifest.json matches tree/ and live source
at the integration boundary; before-manifest.json also verified.

| Gate | Result | Exit | Scope |
| --- | --- | --- | --- |
| 01 | 81/0 | 0 | Existing affected unit suites after initial implementation |
| 02 | 83/0 | 0 | Adds expiry index/replay and claimed-nonterminal cases |
| 03 | 67/0 | 0 | Outcome and certification/vote boundaries |
| 04 | 86 tests, 1 failure | 1 | Hosted rollback fixture omitted transaction predicates |
| 05 | 86/0 | 0 | Corrected fixture; dependency assertion unchanged |
| 06 | 30/0 | 0 | Certification/projection including remote application |
| 07 | 275 tests, 4 failures | 1 | New era test incorrectly expected raw-block pool refusal |
| 08 | 275/0, 5.052s | 0 | Actual quorum-supported protocol boundary, full Simplex suite |
| 09 | 462/0, 192.197s | 0 | Read-set, outcome, commit validation, committed projection, DTX, atomic projection/format, foreign projection, runtime and full physics suites |

Failed test sources are gate04-test-source.erl and gate07-test-source.erl;
all logs are retained. The failed gate04 hosted directory is
/tmp/quod_hosted_1AD0E761445BFD3A. No unrelated files or prior failed evidence
were removed. git diff --check passes. No commit, deployment or headset claim.
