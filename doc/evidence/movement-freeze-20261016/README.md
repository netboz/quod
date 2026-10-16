# Movement after ontology inspection

The reported freeze was reproduced on the deployed 0.7.271 desktop using the
existing isolated acceptance account. Opening and promptly closing the source
view permits movement after clicking the world. Leaving source open until the
quiet physical WebSocket closes reproduces the failure: pointer capture returns,
but no control request or body movement follows.

Cowboy 2.12's default 60-second inbound-idle timeout pre-empts the existing 300-second
signed read, whose browser renewal is scheduled halfway through its lease. A
sleeping physical world produces no new poses and therefore no frame ACKs.
The source view makes that quiet interval easy to encounter; it does not remove
the avatar, collider or movement binding.

The shared view reply now sets the transport idle window from the remaining
signed expiry only when delivering an admitted projection. Existing absolute
expiry, dependency/ACL invalidation, renewal, recovery and uncertain-operation
rules remain authoritative. No heartbeat, reconnect loop or additional owner
was introduced. Unauthenticated opening retains Cowboy's default timeout.
Production delta: 10 added / 1 removed lines, net +9. Source/domain schema unchanged;
this release preserves the candidate's existing ledger volumes.

Claude Fable review01 approved production and found two test-fixture defects:
the simulation-open wrapper discarded the expiry override and a timestamp
reused an existing status-map variable. The wrapper now forwards its fixture,
and the initial timestamp is named Opened. Review02 confirms both corrections
and approves subject to final checks. Its advisory to wait for explicit commit
is covered by Yan's standing authorization for this continuing workflow.

Final focused03 passes 236 tests with zero failures, including real-owner renewal,
retained foreign dependencies without physics I/O, expiry, stale timers,
revocation and recovery. All eleven final frozen sequential release gates02 pass: 4009 EUnit tests,
148 Common Tests, native debug/release, Clippy, all 18 client test files,
UI build/lint, xref, Dialyzer and production release. Every child exit is 0
and all frozen inputs remain unchanged. Full logs are in checks.tar.gz.
Deployed desktop01 passes on the same existing account and exact anchored lobby.
It read ontology source through ordinary renewal after 150.259s,
including 147.030s of actual physical-stream silence, then
verified authoritative body movement after closing source, a repeated source
open/close, and console close. Zero execute writes, no page errors and no physical-view disconnects.
The optional question HUD remains unavailable, as before; its separate denied
connection is outside this movement fix.
Physical VR acceptance is not implied.

The archive preserves failed reproducer01 (nonexistent catalogue option),
focused01/02 fixture failures, and superseded gates01. SIGTERM interrupted its
EUnit process but Erlang exited0; that row is explicitly invalid. Its following
CT subtree was stopped with SIGKILL, producing true child exit -9 and STOP. No interrupted
campaign authorizes release. Corrected gates02 is a separate frozen campaign.

Returning from a tool releases pointer capture; click the world to use desktop
movement controls. Physical VR keyboard/comfort acceptance is not claimed.

## Delivered release

Implementation commit `1d20ee9d39cb451710e2b6c8aff52786c972225d`; separate label
`034a49a04973bbb045023cd2d9d561bcea4f8ffc`. Release 0.7.272 is deployed at
https://192.168.1.10:30519/ with image digest
`sha256:44efbe7be43c73d2e80d923cd492771d6793dcc9556281c07e1d249b6f76a4c5`.
All image inputs match committed blobs; browser assets and isolated boot pass.

Candidate job 91/index 866029; deployment
`88bec3cb-4e5f-08c2-65f5-167966e13b3d` completed with 8 healthy nodes and 0 restarts.
All 18 system ontologies are ready on every node. Existing root
`8E3314264F847487FEFDB04A34F7E2B74BCBB1CA41357A73AFDD3F6D0C8BD9D8` and all 31 recorded ontology identities/committed tips are unchanged.
All 8 v9 volume IDs/names/placements are retained; no ledger refound or purge.
Main job 246/index 826727 and ingress 1/index 846370 remain unchanged, as does
its public TLS certificate. Existing accounts/lobbies remain usable.

The first deployment dry-run guard expected 8 immediate replacements, whereas
Nomad's retained MaxParallel 1 policy correctly planned 1 replacement and 7 held.
It stopped before any intent/submission. PLAN-STOP and original plan are
preserved. Separately labelled deployment02 asserts that 1/7 start and 8 healthy
completion, with a single CAS submission. No uncertain request was repeated.

Full operational records, exact request/receipt, indexed deployment events,
image build/boot logs, owner probes, history tips and stopped dry run are in
`deployment-records.tar.gz`. Browser profile, private keys, cookies, node data
and image build caches are excluded. Desktop observations are in desktop01.
