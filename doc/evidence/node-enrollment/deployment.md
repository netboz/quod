# Node enrollment deployment evidence

## Version 0.7.250 and retained policy

Yan authorized commit and deployment, and separately confirmed the exact
retained policy proposal after automatic approval review initially rejected
that policy mutation as insufficiently authorized by deployment alone.

- Implementation: `dd7370a2a20f5a29dcc48c31c1352a4236944f2c`.
- Separate release label: `017d5ce309dd89a5eaf0f9d913f12d8cb5aa8697`.
- Immutable image: `192.168.1.11:5000/quod:0.7.250@sha256:52668b41e155f5516c7250263c51233f44b95e97a3568f50b36484844501077e`.
- Nomad deployment: `0b2e9c57-2744-7442-fb77-9a4249166d07`.
  The exact API receipt is retained with the operator logs; all eight home
  and two cloud allocations became healthy.
- All ten physical keys, eighteen catalogue anchors and the founder's exact
  ordinary identity survived the binary rollout. Only four image references
  in the existing job changed; placement, volumes and templates were retained.

The founder signed its ordinary self-hosting and exact class delegation:
operation `658C0C388C5783F2291971FE9F61124FD9DEBBC3BE9B4D5363C6FE2555DF1D9D`,
committed. The existing human administrator then signed the reviewed atomic
class/root source update: group
`642574d51241dde06585deeb384264f6916ec1f2b541d470994ee2dfa0d8be05`,
operation `k1GUihH3iw7La2mOWWenwT4KgzDVkdeQetSNyrrctn4`, committed at
class height 3 and root height 50. The approved goal SHA-256 is
`7daacaf3db4956cd922f0c75189e021a5107fee57fe9bfc649568255f3f9dd1d`.
The first browser attempt failed before signing because its retained origin
port had changed. The second retained the original browser key store and
verified the same network through the new endpoint. No private key was exported.

No ledgers were refounded, no committee was expanded and no uncertain request
was replayed. Eight previously identityless nodes enrolled automatically.
The remaining cloud node retained a definite refusal, with no allocation.

Operator evidence is in `/tmp/quod-node-enrollment-deploy-20261007`.
Signed request custody and browser authentication files remain private there;
they are not committed. Image/local module comparison found equivalent code;
two raw MD5 differences were compiler tuple-allocation hints and consequent
anonymous-function hashes, verified by normalized disassembly.

## Routing defects exposed by live acceptance

Two defects prevented completing acceptance despite a healthy scheduler rollout:

1. Root retained no incoming directory consumers. Its outgoing control link
   set was empty, so later generations and withdrawals reached nobody after
   their initial snapshots. Read-only pre-fix evidence shows zero root routes
   on the remaining cloud node and only one on each other node.
2. The sole local custodian could not confirm an observer advertiser's current
   identity through a self network pull. The same certified-current query
   returned retry after 10001 ms on the custodian and succeeded in 14 ms on a
   third-party node. The transport-level self-pull failure remains outside
   this correction; evidence acquisition now uses the existing local archive
   when the physical self key is an answerer, preserving verification and quorum.

The correction retains monitored incoming subscriptions in directory control,
with authority-gated fan-out and revocation cleanup. Where a peer has both
incoming and outgoing streams, incoming subscription delivery takes precedence:
that is the stream the receiver pinned to the relay. The shared evidence reader
uses the existing immutable snapshot and catchup evidence verifier for self.
There is no additional process, queue, readiness timer or enrollment workflow.

Fable independently checked both causes and the corrected relay direction.
Its initial suggestion to prefer the outgoing stream was rejected: direct-link
ingress cannot accept third-party relays. Its subsequent review confirms the
incoming-stream rule. Negative non-control delivery coverage and a cold local
evidence cost check address its test observations. Natural renewal ticks are
used in integration coverage.

## Follow-up verification

Logs and frozen scopes are in `/tmp/quod-node-enrollment-routing-20261007`.
Every invocation retains full logs and its true exit; no failed log is replaced.

- `focused-01`: 212 tests, two failures. New subscriber fixture lacked its
  root control policy; one peer-network test was blocked by sandbox `eperm`.
- `focused-02`: 212 tests, one failure. The fixture still seeded the wrong
  predicate; the production query requires `directory_control_peer/1`.
- `directory-03`: 25 tests, zero failures after correcting that fixture.
- `directory-04`: 25 tests, one failure in the new duplicate-delivery assertion;
  it counted a legitimate upstream resync frame as a duplicate generation.
  `directory-05` distinguishes the protocol frames: 25 tests, zero failures,
  including deduplication and known non-control subscription/fan-out rejection.
- `remote-01`: enrollment and both received-generation assertions passed;
  the new cost assertion incorrectly required two probes despite reusable
  current evidence. The case failed at that assertion.
- `remote-02`: real signed enrollment, received renewals in both directions
  and unchanged-read checks passed. The final cost fixture additionally starts
  with an unadvertised newly created identity to require a real local probe.
- `remote-03`: the cold cost assertions passed (two local probes, zero archive
  rebuilds/writes), then diagnostic logging failed because the isolated peer
  does not load the Common Test logging module. Logging moved to the controller.
- `remote-04`: final cold local evidence checks, signed automatic enrollment
  and natural received renewals in both directions passed, exit 0.
- `gates-01`: clean steps and EUnit (3766 tests, zero failures) exited 0;
  driver intentionally exited 75 after EUnit to include the review's
  duplicate-delivery correction in a newly frozen full campaign.

The second six-file scope is frozen in `routing-tree-02.json`. The production
delta is +86/-16 lines (net +70); tests add the cold-read cost measurement,
real received-renewal checks and subscriber lifecycle/security coverage.
Growth is confined to the existing directory owner and evidence transport.

Campaign `gates-02` passed both clean steps, EUnit (3766/0), all thirteen
Common Test suites (146/0), xref and Dialyzer. The driver intentionally stopped
with exit 75 after Dialyzer, before the release gate. The parent's lifecycle
check found that directory-only restart did not reset incoming streams, unlike
the feed owner. Fable's claim that it already did was incorrect. Subscriptions
would therefore be lost while clients retained their old streams. This requires
the existing transport reset hook and a real restart regression before release.

`remote-05-before-restart-fix` reproduced that failure: after restarting only
the custodian's directory control process, the applicant retained a live control
link but received no newer root generation. `remote-06-restart-fixed` passed
after adding the existing `quod_conn:reset_inbound_channel/1` hook after channel
subscription. The test verifies a different applicant link, exactly one restored
subscriber and control link, and another naturally renewed generation. Fable
explicitly retracted its earlier lifecycle claim and reviewed this mechanism.
The third six-file scope is `routing-tree-03.json`; it adds three production
lines to tree-02, with no new process, timer or transport mechanism.

Campaign `gates-03` passed both clean steps, EUnit (3766/0), and the ask,
QUIC, Quod Simplex, Simplex and join suites (105/0). It deliberately stopped
with driver exit 75 after join. Independent inspection found that sparse
evidence verification rejected the local adapter's opaque continuation whenever
a proof needed more than one page. The proof receiver now consumes `more | done`,
matching the existing finality transfer receiver; the adapter retains its own
continuation and the network decoder still requires its exact wire token.

The existing 8,001-carrier proof fixture now also traverses the local sparse
adapter and receiver through a read-only archive snapshot and a captured era
index. It requires a nonterminal local page and checks the exact certified
result plus unchanged index state. Wire tests reject the local token.

- `paged-01-before-fix` failed because the fixture supplied an index writer
  instead of its captured read-only view.
- `paged-02-before-fix` reached the local nonterminal page and failed with retry.
- `paged-03-fixed` still failed; `paged-04-diagnostic` exposed the remaining
  fixture error: full material projection instead of compact committee authority.
- `paged-05-fixed` used the verified genesis authority: 49 tests, zero failures,
  exit 0. The complete local proof and malformed-wire rejection both passed.

The fourth seven-file scope is `routing-tree-04.json`. Campaign `gates-04`
passed both clean steps and EUnit (3766/0), then failed the ask suite (41/1)
and exited 1. The directory restart assertion required exactly one subscriber
on the custodian globally; the observed count was two. The test has three
physical peers, and the source peer is also entitled to a control subscription.
The failure did not capture peer keys, so it does not establish whether those
two streams belonged to different peers. This remains preserved, not relabeled
a successful run.

Two explicitly labeled diagnostic ask-suite runs (`ask-07` and `ask-08`)
each passed 42/0 and captured a single applicant subscriber. The revised
assertion requires exactly one subscriber for the applicant and uniqueness
across all subscriber peer keys. It therefore continues to reject duplicate
streams for any peer while admitting a legitimate second subscriber. The
new-link and naturally renewed-generation assertions remain unchanged.
No production code changed for this fixture correction. `ask-09` passed all
42 cases with the per-peer assertions. The final scope is `routing-tree-05.json`;
the clean sequential `gates-05` campaign passed all 20 gates, driver exit 0.
EUnit passed 3766/0 and all thirteen Common Test suites passed 146/0; xref,
Dialyzer, the production release and diff-check also exited 0. Full log paths,
true child exits and log digests are in `routing-gates-05.json`. Every frozen
file hash was rechecked after the run. The production delta is +97/-22 lines
(net +75), confined to the existing owners and shared evidence verifier.
## Version 0.7.251 completed

The follow-up code was committed as `16878f5013d6b0709c655567ac536bfb0aaca6a7`
and the separate release label as `297d44ee359b3efe5eec5d2b08da89568676ac6c`.
The labeled production release, Docker build and registry push exited 0.
The immutable image is
`192.168.1.11:5000/quod:0.7.251@sha256:0b725ef324705c3fc5c1d2fb7541bb32453f91acdf4b23db1c05adc3ec93882f`.

Nomad's plan changed only four image references; all placements were feasible.
Plan exit 1 was the expected changed-plan result. Submission used the observed
JobModifyIndex 824831. Deployment `69b8d270-c733-60ca-518a-7348325bf36b`
completed successfully: eight home and two cloud allocations healthy, job
version 245. Existing placement, volumes, templates and policies were retained.

Fresh before/after observations through the running fleet establish:

- All ten physical keys survived. All nine previously bound exact identities
  and their pointer file hashes stayed identical through ten endpoint changes.
- The remaining cloud node enrolled automatically. Every runtime reports
  enrollment complete, an active verified key, self-hosting and exactly one
  matching committed identity allocation.
- Every node sees ten exact root routes and all nineteen system routes
  (eighteen catalogue entries plus root) from the ten physical nodes. Eligible
  ordinary identity advertisements passed on every node as well.
- A second capture more than thirty seconds later shows advanced generation
  numbers, live leases and only the current endpoints. The old claims did not
  survive the rollout. All ten signed public queries passed through real ingress.
- The root anchor and all eighteen catalogue anchors are unchanged. Root still
  has one validator and nine observers. No ledger was refounded and no uncertain
  operation was automatically replayed. Existing private routing and target ACL
  checks passed in the complete release integration suite.

The first live signed-read script supplied a named variable to the normalized
term formatter and was rejected before submission. Its corrected second run
completed the first node, then failed while serializing a response containing
Latin-1 display bytes. The third run returns compact Unicode-safe outcomes:
ten successes, exit 0. These were read-only validation calls, not creation
replays. The first detailed route capture passed five nodes before remote
stdout truncated the sixth result; the compact second capture preserved the
same checks and passed all ten nodes, exit 0. Both failed harness runs are
retained with their true driver exits.

[deployment-251.json](deployment-251.json) records the immutable artifact,
commits, scheduler result, acceptance summary and log digests. Full logs and
before/after receipts are retained in
`/tmp/quod-node-enrollment-deploy-251-20261007`. The strict unknown-operation
custody and initial-custodian restrictions documented in the contract still
apply; the unrelated self-network transport cause was not changed.
