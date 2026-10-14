# Session restoration release 0.7.266

Deployed to [the live candidate](https://192.168.1.10:30519). The source fixes are
`c6894d21598519f47eeb23d534b8178fedbb4b76`; the separate release label is `ea03009e0d2fbafb81fd21d9010794a98003bd4b`.
The immutable image is `192.168.1.11:5000/quod:0.7.266@sha256:330ff596c6b8c3faf1976ef29d3713c69c728ae0519577c165f0dff027b796fc`.

The client hides an expired scene and offers **Restore session**. Source and
console drafts survive same-account authentication renewal; proofs are retired
and existing operation receipts are recovered without resubmitting writes.
Source refresh rereads the ordinary anchored Eidolon, reloads pristine contents
and access, and preserves the original baseline of dirty drafts. Editor actions
have visible button styling. The only server production change sets the default
authentication lifetime to 15 minutes; signed goal deadlines are unchanged.
Existing session-admission limits remain unchanged. Question-draft preservation
and broader session recovery were outside this small prototype.

## Deployment and live verification

One indexed image-only rolling update changed five task image references. The
existing one-node-at-a-time strategy, templates, volumes, root, namespace histories
and node principal identities were retained. Candidate job version is
**78**, modify index **859202**. All eight nodes have 18 ready
system ontologies and outcome format 9. The main job and ingress are unchanged.
No refounding or ledger deletion occurred.

All 365 committed browser files matched the clean build and shipped image. Live
HTML and its entry assets matched those files. Alice and Bob authenticated at the
real origin with their existing saved profiles and received 15-minute sessions.
Their exact target anchor was unchanged. Actual source refresh passed in both
windows. Alice's policy source matched the saved committed source; Bob's committed
baseline remained `acl_test_value(should_be_denied) :- true.`. His captured
`revoked_attempt` draft was restored after that check and survived refresh.
No preview or save was submitted during reopening. The earlier manual negative
ACL sequence remains deferred; its interrupted state is not counted as a pass.

## Validation and failure disposition

The fresh sequential campaign passed all eleven checks with unchanged frozen
inputs: 35 native tests in debug and release, Clippy, 180 client tests, UI build and
lint, **3,976 EUnit tests**, **148 Common Test cases**, xref, Dialyzer and release
assembly. The existing lint warnings remain. Authentication and actual World/
source-editor browser regressions also passed. Expiry masking, inertness, failed
restore, same-account draft retention and background expiry were tested through
the real SessionEntry component; live server expiry values were checked separately.

Yan requested Claude Fable review. It found no material production defect and
recommended retaining the original metrics tests. The first campaign's unchanged
router test exceeded its five-second startup limit while our two forced-software
3D browsers consumed approximately four CPU cores. Suspending only those idle
browser trees restored the unchanged module: all 20 tests passed, with its cold
metrics test at 1.434 seconds. No assertions or timeouts were changed. The failed
campaign and diagnostic exits are retained. The browsers later closed while
suspended; their existing profiles and draft snapshot allowed guarded reopening.
The reopened launcher uses default rendering instead of forcing software 3D.

The first Nomad plan guard expected all eight replacements in one evaluation.
The existing MaxParallel1 strategy correctly planned one replacement. That guard
submitted no mutation. The corrected operator submitted exactly once and observed
the successful rollout. An initial live refresh verifier checked between cache
invalidation and completed source delivery; later read-only inspection showed the
same policy, and a verifier synchronized on actual source delivery passed.
Preparation and selector failures are retained in the private build evidence.

Production grew by 72 lines for the expiry presentation, semantic draft lifetime
and actual refresh/error handling; no domain engine or compatibility path was added.
No human signing key was exported. Raw job payloads, browser profiles, source-draft
snapshots and signed requests stay in the private ignored build directory.

[Summary](SUMMARY.json), [release logs](release-logs.tar.gz),
[verified deployment records](deployment-records.tar.gz), and
[Claude Fable review](fable-review.md) retain the reviewable results.
