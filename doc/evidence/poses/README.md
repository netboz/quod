# Authoritative body pose stream evidence

This implements body-pose streaming for one local signed view. Prolog owns view policy and
body-to-entity bindings; the retained native owner supplies current poses with
one outstanding delivery credit. Dropped motion ticks need no replay. Durable
gaps, authority/run changes and reconnect require a fresh signed projection.
Physical identity includes the world, authority epoch, run/incarnation, body
and structural revision; an occurrence's mark ID is never physical identity.

The requested [Claude/Fable review](fable-review.md) and checked
[disposition](review-disposition.md) are retained. Review is consultative;
implementation and evidence remain uncommitted.

## Acceptance coverage

- The real native owner coalesces many steps behind one outstanding frame,
  delivers the latest on acknowledgement, rejects stale structure and reports
  existing simulation failure. An unchanged repeat is traced for native
  reconstruction, ledger reads and file/DETS writes or syncs.
- The signed endpoint lifecycle fixture uses production WebSocket callbacks,
  session/proof ingress, runtime and door owner. It checks moving/closed door
  poses, appearance refresh without native reinstallation, exact expiry,
  installation wait expiry, stale timers, owner restart and policy revocation.
- Babylon NullEngine verifies that appearance changes retain the live pose,
  and deleting/recreating an occurrence cannot inherit the old body's pose.
- Pure frame and socket tests cover skipped ticks, stale/duplicate frames,
  epoch/run/incarnation fences, exact uint64 identity, complete pose sets,
  refresh/reconnect signing and delayed messages or retired signer failures.

These tests do not claim manual headset or end-to-end TLS browser validation.
The scope remains one local view; remote multi-viewer authorization is absent.
Every durable namespace advance conservatively requests a fresh projection.
This can starve motion in a busy namespace; the last pose remains visibly stale
during refresh, without restoring the durable baseline. Signed request expiry
uses the existing lifetime and requires a new signed read.

## Validation records

Base commit: `781c4a68c7e00d536caf8fb4a2b7ac1e8f08cba0`.

Clean sequential campaign **03** passed on unchanged production and test
sources, including the final signer-cancellation and cleanup changes:

- Client suite: **105 tests passed**; the new simulation file contains
  five individual acceptance cases, also checked with a direct Node run.
- TypeScript and browser build: passed; tracked assets regenerated.
- Full EUnit: **3,768 tests, zero failures**.
- Common Test: **146/146 passed**.
- xref, Dialyzer and production release packaging: passed.

The campaign's `exits.jsonl` records every command and true child exit.
`source-manifest.json` identifies the final changed sources and browser assets;
the campaign's before/after hashes verify that production and test sources
stayed frozen. Documentation and evidence were finalized afterward.
`validation-logs.tar.gz` retains complete logs, runner scripts, source snapshots,
focused checks and earlier stop markers. `common-test-reports.tar.gz` retains
the full reports for these three campaigns. `SHA256SUMS` covers the bundle.

Earlier failures and interruptions remain in the bundle and are not counted
as successful gates:

- An initial mistaken `eunit --help` command ran tests in the sandbox. Ranch
  listen failed with `eperm`, then a closed output pipe caused `epipe`. The
  shell pipeline's zero exit was not a test pass. Full output was not captured;
  the invalid attempt is described in `prior-invalid-run.txt`.
- Campaign 01 was interrupted to apply review fixes. EUnit returned zero after
  SIGTERM without a completion summary, so it is invalid. The following CT
  child was explicitly stopped with SIGKILL (actual exit -9). Stop markers and
  the interruption explanation are retained.
- Campaign 02 passed 3,768 EUnit tests, all 146 Common Tests and xref, then
  stopped at two Dialyzer unmatched-return warnings in socket cleanup. The
  discarded cleanup results are now explicit. During this campaign, the
  final JavaScript signer-cancellation fix was separately tested and rebuilt;
  its early client gate is not represented as testing that later change.

## Scope and delta

Production source delta, excluding generated browser assets, docs and tests:
**+451 / -14 = +437 lines**. The growth supplies the explicit signed transport,
bounded delivery credit, physical identity filtering and client lifecycle.
It adds no broker, simulator, persistent pose history or readiness polling.
Tracked browser assets are regenerated from the client/UI sources.

No commit, deployment, migration or label bump was performed.
