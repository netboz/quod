# Retained-work gate 03

Native debug/release (57 each), clippy, 234 client cases, UI build/lint and all 4,109 EUnit tests passed. The isolated authority-trace test passed within the full suite.

Common Test exposed three signing refusals in the host-failover variants. The fixture constructed literal signing grants with `format/1`, while the current agent signer uses `format_clause/1`. The latter emits a terminating period and verifies its round trip; exact Prolog request matching correctly refused the stale literal. The fix changes only the fixture’s formatter, preserving the three allowed work values, current host/epoch/key checks and all recovery assertions. No production code or authorization check changes. The original scope and logs remain frozen.

Final campaign 04 reruns all Common Test cases, then xref, Dialyzer and release assembly. Production, native, browser and EUnit case implementations are byte-identical to campaign 03. The sole source change is one formatter call in the CT-only `quod_agent_failover_SUITE.erl`, which has no EUnit cases or references from other test modules. Earlier passing gates are retained as evidence for their exact scopes rather than silently rerun or relabeled.

Final CT receipt: 145 passed, three failed; true child exit 1. No skipped cases or additional failures.
