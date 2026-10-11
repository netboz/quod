# Release 0.7.258: first clean campaign failure

The frozen input tree passed native tests and Clippy, client tests, UI build and lint,
and all 3,870 EUnit cases. Common Test exited 1: 141 passed, and five cases in
`quod_agent_failover_SUITE` were automatically skipped after fixture initialization
called the removed vault `generate/1` function through an RPC helper.

The correction replaces that one stale fixture call with `prepare(Blob, 0)`.
The existing five recovery cases and their assertions are retained. Production
code is unchanged; the superseded vault interface remains removed. A repository
search covering both direct and RPC calls found no further active callers.

The original STOP marker, exact input manifest, child results, triage and complete
console/Common Test logs are retained here. This is a failed release campaign,
not successful integration evidence. A separately labeled frozen campaign will
run the clean sequential gates after this test correction. No deployment, image
publication or candidate refound occurred from this campaign.
