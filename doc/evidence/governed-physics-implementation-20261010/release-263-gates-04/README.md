# Release 263 gate04 — stopped

Six sequential gates passed: native debug/release tests (34 each), clippy, client tests, UI build and lint. EUnit ran 3,884 tests with two failures. CT, xref, Dialyzer and release packaging did not run. This campaign is not eligible for release; the live deployment remains 262.

The ordinary-observatory assertion read a retiring physics entry before its runtime owner processed DOWN. The space semantics fixture read Prolog replay readiness before the runtime completed its asynchronous reconciliation. The fixes wait for actual owner message processing, then take a synchronous snapshot; no production behavior or assertions are weakened. The retirement test additionally suspends the physics process to force the pending-retirement state.

Failed hosted fixtures remain at `/tmp/quod_hosted_033E2FA55CC65E61` and `/tmp/quod_hosted_8B0AC817B72DE443`. Full EUnit output, frozen input hashes, true process exit and STOP are retained here. Review comment/oracle corrections occurred in the working tree after this freeze and will be included in the next separate campaign.
