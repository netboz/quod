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
148 Common Tests, native debug/release, Clippy, all18client test files,
UI build/lint, xref, Dialyzer and production release. Every child exit is0
and all frozen inputs remain unchanged. Full logs are in checks.tar.gz.
Deployed idle-through-renewal desktop validation remains the next gate.

The archive preserves failed reproducer01 (nonexistent catalogue option),
focused01/02 fixture failures, and superseded gates01. SIGTERM interrupted its
EUnit process but Erlang exited0; that row is explicitly invalid. Its following
CT subtree was stopped with SIGKILL, producing true child exit -9 and STOP. No interrupted
campaign authorizes release. Corrected gates02 is a separate frozen campaign.

Returning from a tool releases pointer capture; click the world to use desktop
movement controls. Physical VR keyboard/comfort acceptance is not claimed.
