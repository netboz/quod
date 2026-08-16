# Root-driven directory control: implementation plan

> **Implemented.** The implementation also closes the all-ports-moved case by
> deriving anonymous recovery contacts from the root content seeds, as
> described below. The source inventory remains as an audit trail.

## 1. Goal

Replace the network directory's static `host:port` bootstrap configuration with
the root ontology's committed membership truth.

The root ontology decides **which node keys may seed and relay directory
control traffic**. The root content block's existing seed endpoints recover a
live key/address observation when the cache is stale; the transport cache
accelerates later dials. Every retained directory-control connection is
pinned to its authenticated Ed25519 key.

This removes the failure mode where a Nomad restart changes every dynamic port
while the directory keeps dialing addresses rendered before the restart.

This is a breaking replacement. There is no legacy bootstrap fallback, dual
resolver, or compatibility parser.

## 2. Boundary

The design deliberately separates durable truth from moving runtime state:

- `peer_admitted/4` in `quod:root` is the committed authority for directory
  control peers.
- `quod_quic:resolve/1` is one current local `NodeKey => Endpoint` observation.
  The root API deliberately returns only the node key; it does not treat the
  committed Host/Port arguments as durable routing truth. Existing consensus
  code does, however, seed the same address cache from those arguments:
  `quod_simplex:adopt_history/2` overwrites the hint at a live membership
  commit, and `learn_member_endpoints/3` fills an absent hint while catching
  up. A boot re-fold reconstructs only the key set. Consequently `resolve/1`
  may initially return a stale committed endpoint after a deployment move.
- the existing root `content.seeds` are anonymous recovery contacts. Control
  dials them with `open_link_identified/2`, which authenticates the TLS and
  header key without learning into the shared cache. A result is accepted only
  when that exact key is present in the latest successful
  `directory_control_peer/1` proof. Control then explicitly learns the
  authenticated contact endpoint and retains it as that key's control link.
  This closes the all-ports-moved case without granting an address any
  authority and without adding directory-specific bootstrap configuration.
- `quod_quic:open_link_pinned/3` proves that the process reached at that
  endpoint owns the selected node key and preserves the directory no-learn
  isolation.
- Signed directory records, exact namespace/host authorization, leases,
  high-water marks and route selection remain unchanged.

There is no bootstrap cycle. The query is a local read of the already-running
root knowledge base. It does not use `directory_host/5`, `::`, or any directory
route.

## 3. Root API

Add one `query`-class external predicate that succeeds only while the proof is
executing in the `quod:root` context:

```prolog
directory_control_peer(?NodeKey).
```

Its solutions are the distinct canonical public keys in the proof snapshot's
committed `peer_admitted/4` facts. Conceptually:

```prolog
directory_control_peer(NodeKey) :-
    peer_admitted(_, _, _, NodeKey).
```

The implementation belongs in `quod_directory_predicates`, is registered in
both `quod_predicates:governed/0` and `quod_predicates:registry/1`, and reuses
`quod_committee_predicates:admitted_pubkeys/1`. It must:

1. succeed only in a `quod:root` execution context;
2. re-filter and enumerate only exact 32-byte keys from canonical committed
   facts (`admitted_pubkeys/1` currently guarantees only `is_binary/1`);
3. use Erlog's existing `member/2` list predicate for normal unification and
   backtracking, rather than implementing another choice-point walker;
4. stage no write and perform no network or process operation.

This context check is an authority boundary, not a secrecy claim. A served
`quod:root::directory_control_peer(Key)` read also executes in the root
context and can enumerate the keys. Committee public keys are already public
protocol identities, so that is harmless. Directory control itself uses the
local proof path and never performs a network ask for discovery.

It is an external predicate instead of a mutable root rule for two reasons:

- it is immediately available on the existing root ledger when the new code
  starts, so no root transaction or ledger re-founding is required;
- compiled predicates are immutable in the Erlog database, while their answers
  still come exclusively from the frozen committed Prolog snapshot. Until
  authenticated root-administration writes exist, a normal mutable root rule
  could be widened by an ordinary content write.

The control process obtains a snapshot with one local read-only proof:

```prolog
findall(NodeKey, directory_control_peer(NodeKey), NodeKeys).
```

`admitted_pubkeys/1` already returns a sorted distinct list. The external
handler's mandatory extra work is the exact 32-byte filter; the control process
still validates the returned shape before converting it to its key-set map,
but does not sort/deduplicate the list again. The whole root committee is the
control-peer authority; an arbitrary Erlang-side truncation would silently
change the root ontology's answer, while `findall/3` has already materialized
the complete set. If a bounded relay subset becomes necessary, root must define
that policy explicitly in a later predicate.

The local key remains in the authority set, so a root member can recognize its
relay role, but is excluded from outbound dial candidates. Do not add
`peer_ready/1` to this predicate: committed membership is stable authority,
while cache resolution plus a pinned connection is the liveness test. A
transient feed observation must not shrink relay authority.

A failed or unready root proof adds no authority and is retried later.

## 4. Control-link state machine

`quod_directory_control` keeps the following discovery state:

```text
control_peers   current last-successful root key set
dial_queue      exact {NodeKey, Endpoint} candidates awaiting a bounded open
pending_links   NodeKey => {Endpoint, OpenRef, DeadlineTimerRef}
control_links   NodeKey => {Endpoint, LinkPid, MonitorRef}
root_contacts   bounded endpoints copied from the root content seeds
pending_contacts Endpoint => {OpenRef, DeadlineTimerRef}
peer_query      optional {Pid, MonitorRef, Token, TimerRef}
peer_height     height of the last successful root proof
```

The root proof must never run in the directory control process itself.
`quod_prolog:prove_ro/2` is called by at most one monitored, timed worker.
Worker messages preserve the distinction between
`{ok, Height, NodeKeys}` (where `NodeKeys = []` is a real successful answer)
and `{error, Reason}` or worker failure. Every result carries the current token
and is ignored if stale; a successful result calls
`demonitor(MonitorRef, [flush])` and cancels the exact timer before its later
`DOWN` can be interpreted as failure. Termination kills and demonitors the
exact worker and cancels its timer. The control mailbox therefore continues to
renew records, ingest messages and answer resync requests while root is
booting, rebuilding, blocked, or proving.

One successful proof reconciles links as follows:

1. replace `control_peers` with the complete validated result, including an
   empty result;
2. cancel and remove pending attempts for keys no longer present; demonitor
   active links with `[flush]`, remove their exact entries, and close them;
3. exclude self from dialing, call `quod_quic:resolve/1` for every other key,
   and queue every currently resolvable key without an exact live or pending
   `{NodeKey, Endpoint}`;
4. pump only a small fixed number of concurrent
   `open_link_pinned(NodeKey, Endpoint, Channel)` attempts. Before pumping an
   entry, re-check both current membership and that `resolve/1` still returns
   its exact endpoint; never start a duplicate pending open for that key and
   endpoint. Each attempt has a control deadline no shorter than the
   transport's bounded connect-plus-link-ACK interval, so stale endpoints
   cannot occupy the entire dial pool indefinitely;
5. match `link_up` and `link_error` against the exact current
   `{NodeKey, Endpoint, OpenRef}` and cancel its exact deadline timer. A
   matching error, timeout or endpoint change removes that pending generation
   and pumps another candidate. Ignore an unmatched late result: the transport
   may reuse the same authenticated channel `LinkPid` for two opens, so blindly
   closing a late PID could kill the current good link. `quod_quic` remains the
   owner of an ignored link;
6. on a matching `link_up`, first handle transport reuse idempotently: if its
   endpoint and `LinkPid` already equal the current entry, clear the pending
   attempt without adding a second monitor or closing anything. Otherwise
   monitor the new process and publish its exact
   `{NodeKey, Endpoint, LinkPid, MonitorRef}` before retiring an older link for
   that key; then `demonitor(OldMonitorRef, [flush])`, close the old link, send
   the current local signed record if one exists, and request snapshot page
   zero;
7. on `DOWN`, remove a link only when both the delivered `MonitorRef` and
   `LinkPid` match the currently stored entry for that node key; then refresh
   root truth and retry the currently resolved endpoint. A superseded link's
   `DOWN` is therefore inert.

If `resolve/1` reports a changed endpoint while the old link is alive, open the
new pinned link first and replace the old one only after success. Readers and
resync therefore see overlap, never a replacement-induced gap.

The complete committee is intentionally not truncated in Erlang. This assumes
the root committee remains operationally bounded: each node materializes
`O(N)` keys and can hold `O(N)` control links, with `O(N^2)` links across a
fully informed committee. That is the same scalability boundary already
present in root consensus, not a bound on the number or size of user
ontologies. If root membership itself must scale beyond it, root must expose a
committed relay-subset predicate; a local arbitrary cap is not acceptable.

The ordinary directory renewal tick refreshes the root peer set and resyncs
every active control link. A transient failed root proof leaves the last
successful set unchanged; this is an availability-only stale-authority window:
a former relay still cannot forge an author's signature or bypass the
receiver's exact namespace/key allowlist. The next successful proof, including
an empty result, replaces the set exactly.

Maintaining links to all currently resolvable root peers is deliberate and
best-effort over each node's current cache. It does not claim to manufacture a
full mesh: nodes may have different cache contents, and a non-member observer
may initially know only one root peer. Settling forever on one arbitrarily
chosen peer can partition directory views into stable pairs; instead, every
resolvable root edge is used and retried as live observations appear. The
connected authenticated root network supplies the relay core, and an observer
needs one reachable root member to join its resync path. If that underlying
root graph or its address observations are unavailable, directory convergence
is unavailable too; the directory does not weaken integrity or invent a
second source of topology truth.

A one-member root committee has no remote control link. That is valid: its
local signed record is installed locally, and there is no peer from which it
needs to resync.

## 5. Dissemination and source authority

The same `control_peers` snapshot replaces bootstrap identity as the relay
authority.

An announcement is accepted for expensive decoding/verification only when its
authenticated source key is either:

- allowlisted somewhere, so it may be the direct author of a system record; or
- a current root directory control peer.

After decoding, source shapes are exact:

- `{direct_link, Key, Endpoint, LinkPid}` is a direct author only when the
  signed author equals `Key` and the signed endpoint equals `Endpoint`;
- if those fields do not match, the same source is a relay only when `Key` is
  in `control_peers`;
- `{pinned_link, Key, LinkPid}` has no independently observed author endpoint
  and is relay-only, requiring `Key` in `control_peers`;
- an ordinary allowlisted non-control host may pass the cheap prefilter, but
  cannot relay another author's record after decoding.

The production classifier preserves the authenticated source key. It returns
an authority-bearing `{relay, Key}` or `{resync, Key, LinkPid}` shape and never
collapses a remote source to a bare `relay` or `resync` atom.
`source_matches/3` consults the current state for those shapes; there is no
unconditional `source_matches(_, relay) -> true` clause. Thus the cheap
allowlist prefilter is only a CPU guard, never the final relay decision.

Every receiver still verifies the original signature and its own exact
namespace/key allowlist. Root control-peer status grants relay capability only;
it never grants authority to fabricate or alter a directory record.

Snapshot pages are ingested only when
`{NodeKey, Endpoint, LinkPid, MonitorRef}` exactly matches a currently tracked
outbound control link. Concretely, a `{pinned_link, NodeKey, LinkPid}` source
must find `control_links[NodeKey]` with that exact `LinkPid`; the endpoint and
monitor belong to that same stored entry. Key membership alone is insufficient.
Pagination continues on that same current link. Public mutually authenticated
nodes may still request a bounded snapshot, but read access does not become
ingest or relay authority.

Dissemination becomes:

- every host sends its current signed record to its active root control links;
- a node forwards an accepted third-party record to each active root control
  link except the signed author and authenticated immediate source, only while
  its own key is in `control_peers`;
- every node periodically resyncs from every active root control link.

High-water checks make loops and duplicate delivery harmless. This avoids
redundant fanout by nodes that are not directory relays and stops coupling
control dissemination to the set of advertised ontology hosts.

## 6. Code and configuration removed

Before deleting the bootstrap helpers, rewire every production seam that
currently reaches them:

- the `inbound/3` announce branch and `control_source_allowed/2` retain the
  authenticated source key through classification;
- `record_source/2` preserves the authenticated key, returning direct only for
  an exact author-key and signed-endpoint match and otherwise
  `{relay, PeerKey}`; `source_matches/2` becomes state-aware
  `source_matches/3` and admits that relay only when `PeerKey` is in
  `control_peers`. Delete the current unconditional `relay -> true` behavior;
- replace `bootstrap_snapshot_source/2` in the `inbound/3` snapshot branch
  with an exact `control_snapshot_source/2` lookup of the current
  `control_links[PeerKey]` entry and its `LinkPid`; a stale or duplicate link
  to an otherwise-current key cannot ingest pages. Accepted page records retain
  `{resync, PeerKey, LinkPid}`, and `source_matches/3` rechecks that exact
  current entry; delete the unconditional bare `resync -> true` clause too;
- replace the generic link `DOWN` handler with exact current
  `{MonitorRef, LinkPid}` correlation. Endpoint replacement and proved-set
  removal both demonitor the retired reference with `[flush]` before closing
  its process, so a retired `DOWN` cannot delete a replacement;
- `set_normalized_hosted/2` starts or retains asynchronous root-peer
  reconciliation instead of calling `contact_next_bootstrap/1`;
- the successful control `link_up` path ends by pumping the bounded dial queue
  instead of calling `contact_next_bootstrap/1`;
- `publish_hosted/2` and `renew_advertisement/1` send the local record over
  active control links, and forward third-party records only when self is a
  current control peer, instead of composing `send_bootstraps/2`,
  `contact_next_bootstrap/1` and system-route `fanout/3`;
- `directory_tick/1` starts a root refresh if none is active, reconciles
  currently known endpoints and resyncs active control links instead of
  calling `maintain_bootstraps/1`;
- `recover_directory_state/1` clears expired peer-record ownership, retains
  and reconciles exact control links, requests fresh snapshots and republishes
  the current self record instead of calling `maintain_bootstraps/1`.

`send_current_and_resync/2` is reusable for an exact newly-installed control
link. The replacement helpers operate only on `control_links`; they never scan
directory routes to decide control dissemination.

Remove from `quod_directory_control`:

- `bootstrap_seeds`
- `bootstrap_queue`
- `pending_seed`
- `bootstrap_bindings`
- `seed_links`
- bootstrap `link_up`/`link_error` clauses
- `contact_next_bootstrap/1`
- `maintain_bootstraps/1`
- `send_bootstrap_resyncs/1`
- `retry_missing_bootstraps/1`
- `send_bootstraps/2`
- `bootstrap_peer/2`
- bootstrap-specific snapshot-source classification
- `test_seed_links/0`

Remove `quod_directory:system_routes/0`. Root-control links now form the
dissemination graph, and this function has no other production caller. This
also removes an `ets:tab2list/1` plus sort/dedup scan from every accepted
announcement.

Remove from configuration and deployment:

- `directory.bootstraps`
- `directory_bootstraps` Nomad variable
- parsing and validation in `quod_app`
- schema examples, tests and documentation describing system-bootstrap TOFU

The removed HOCON field is invalid after the change. It is not silently
ignored.

Replace the `bootstraps` control statistic with explicit
`control_peer_count`, `control_link_count`, `control_pending_count`,
`root_proof_height` and `root_proof_status` values. There is no deprecated
stats alias.

Identity discovery by endpoint is shared by private direct ontology seeds and
root contacts. The transport primitive is named `open_link_identified/2`; it
returns the mutually authenticated node key while suppressing automatic shared
cache learning. Each caller applies its own authority rule before retaining or
promoting the result, so no second link implementation is introduced.

## 7. Other Prolog simplification in this slice

`quod_directory_predicates:directory_host/5` delegates enumeration to the
standard Erlog list predicate:

```prolog
member([GenesisAnchor, NodeKey, Host, Port], Candidates)
```

The external handler still performs the root-context and ground-namespace
checks and reads the bounded ETS candidates directly. `member/2` performs the
unification and backtracking. This removes duplicate list-predicate machinery
and follows the established Erlog external-predicate pattern.

No list append is needed in either predicate; goals are prepended to `Next`.

## 8. What deliberately stays in Erlang

The following are moving state, validation mechanisms, or effects and should
not be copied into the root ledger:

- signed route records and Ed25519 verification;
- live NodeKey-to-endpoint observations;
- local hosted-namespace registry inspection;
- route leases, expiry and epoch/sequence high-water marks;
- exact record shape, rate and capacity enforcement;
- ETS route lookup used by the hot `::` path;
- pinned socket opening, retry and fanout/resync effects.

`directory_host/5` remains an external root query over the live ETS index.
Routing a `::` call through a second root proof would add latency and create an
unnecessary dependency in the hot path.

## 9. Prolog changes explicitly deferred

The exact `Namespace => allowed NodeKeys` system-host policy is duplicated
operator configuration today. It is a good eventual root predicate:

```prolog
directory_host_authorized(Ontology, NodeKey).
```

It must not move in this slice. Quod does not yet have authenticated
root-administration writes, so an ordinary root content write is not a safe
replacement for local operator-controlled configuration. After signed root
administration exists, this policy can live in root and be projected into a
bounded ETS authorization index; the HOCON allowlist can then be deleted.

Private direct seeds remain local route P-state. The calling/parent ontology
may instead own a durable, endpoint-free `subscribes/2` relation to the private
child, as planned in `ontology-subscription-plan.md`; that relation can activate
only where the runtime can already reconstruct a confirmed route. Persisting or
projecting private seed addresses still requires a separate control-plane
design. The current local-only direct-seed behavior remains unchanged here.

## 10. Implementation order

Expected source scope:

- `quod_predicates`: add `{directory_control_peer, 1}` to `governed/0` and add
  its `query` handler to `registry/1`; both registrations are required;
- `quod_directory_predicates`: export/implement
  `directory_control_peer_1/3` and factor both directory enumerations through
  `member/2`;
- `quod_directory_control`: root proof, link reconciliation, source authority,
  exact-ref `DOWN` handling, dissemination and resync, including every
  bootstrap call-site rewire listed in Section 6;
- `quod_directory`: remove `system_routes/0`; private route storage,
  add/confirm and resolver ordering stay untouched;
- `quod_schema`, `quod_app`, `config/quod.conf` and both directory blocks in
  `deploy/quod.nomad`: delete static bootstrap configuration;
- `quod_quic` and `quod_ask`: scoped identity-discovery API and connection tag;
- `quod_directory_predicates_tests`, `quod_directory_control_tests`,
  `quod_directory_SUITE`, `quod_schema_tests` and identity-discovery cases in
  `quod_quic_SUITE`: focused contract changes;
- directory/inter-ontology docs and affected module comments: remove stale
  system-bootstrap language.

1. Register both dispatcher halves, add, and test the root-context-only
   `directory_control_peer/1`.
2. Replace `directory_host/5`'s custom enumeration with Erlog `member/2`.
3. Add the non-blocking root-query and pinned control-link state machine,
   keeping successful-empty and failed query outcomes distinct.
4. Change `inbound/3`, `control_source_allowed/2`, `record_source/2`,
   `source_matches/2`, snapshot-source classification, exact link `DOWN`, and
   fanout authority to use the proved root control-peer set and current exact
   link entry.
5. Delete every static system-bootstrap state/function and
   `quod_directory:system_routes/0`.
6. Remove `directory.bootstraps` from schema, application wiring, both Nomad
   directory templates, `config/quod.conf` and
   examples.
7. Expose the remaining TOFU operation as the generic, scoped
   `open_link_identified/2` primitive; callers decide whether the authenticated
   identity is authorised.
8. Update `doc/network-directory-plan.md`, `doc/inter-ontology.md` and stale
   module comments to describe the implemented root-driven path.
9. Run focused gates, obtain read-only review, then commit.
10. Deploy without wiping the ledger and rerun the cross-ontology benchmark.

No compatibility implementation is permitted between steps 3 and 6; they are
one atomic source change.

## 11. Focused acceptance tests

### Root predicate

- A KB loaded through `quod_predicates:load/1` reports
  `quod_predicates:class({directory_control_peer, 1}) =:= query` and enumerates
  a non-empty set through normal Prolog backtracking. This catches a missing
  `governed/0` entry or `registry/1` handler rather than testing the handler in
  isolation.
- An integration case invokes the real local
  `quod_prolog:prove_ro(<<"quod:root">>, findall(...), <<"quod:root">>)`
  path and obtains that non-empty set; an unregistered predicate must not be
  mistaken for a legitimate successful-empty committee.
- It enumerates the distinct canonical `peer_admitted/4` keys from the frozen
  root snapshot and fails outside a `quod:root` execution context.
- It rejects a binary whose size is not exactly 32 bytes.
- A membership addition/removal changes the next result set.
- Duplicate canonical facts still yield one key because
  `admitted_pubkeys/1` is already distinct.
- Committed Host/Port values do not appear in, or influence, this predicate's
  answer.

### Discovery state machine

- Directory startup remains non-blocking while root is absent, unready,
  rebuilding, or deliberately blocked.
- Starting from a non-empty last-successful set, `{ok, Height, []}` replaces it
  with empty and closes its links, while no-such-root, rebuilding, timeout,
  malformed result, or worker failure retains it. A stale token can do neither.
- Unresolved peers do not block attempts to other resolved peers.
- A queued `{Key, E1}` is skipped if membership is revoked or the cache changes
  to E2 before it is pumped. A timed-out E1 attempt releases its concurrency
  slot, and its later result cannot replace E2.
- A stale cached endpoint fails its pinned dial without dropping other live
  control links.
- A successful pinned link sends the current record and starts page-zero
  resync.
- Link `DOWN` retries that peer independently; removal from the next proved
  set closes only that peer's pending and active links.
- A changed endpoint is inserted successfully before its old live link is
  closed.
- With old `{K, E1, L1, M1}` replaced by `{K, E2, L2, M2}`, delivering
  `{'DOWN', M1, process, L1, Reason}` leaves the exact L2 entry unchanged.
  Only the exact M2/L2 `DOWN` removes it and schedules retry.
- Stale root-query results, worker `DOWN`, link `DOWN`, `link_up` and
  `link_error` events cannot mutate a newer generation.
- Late `link_up`/`link_error` messages from an older `OpenRef` cannot replace
  a current pending or active link. If the transport returns the current
  `LinkPid` for both an old and a current open, the old reply is ignored and
  cannot close that good PID; the current exact reply is idempotent and does
  not add a second monitor.
- A one-member root committee remains healthy without a remote link.
- A deliberately sparse observer that initially resolves only one root member
  still converges through that member; the test does not require
  `control_link_count = control_peer_count - 1`.

### Authority

- A direct author is accepted exactly as before.
- A current root control peer may relay another author's valid immutable
  record.
- Through the real `inbound/3` source shapes, the same third-party signed
  record is accepted from a current control key and rejected from an
  allowlisted non-control key. A helper invocation with a preclassified bare
  `relay` token is not sufficient coverage.
- Direct-link and pinned-link source shapes cannot be confused.
- After `{K, E1, L1, M1}` is replaced by `{K, E2, L2, M2}`, a snapshot on L1
  and one on an unrelated pinned link are rejected; the identical page on
  current L2 is accepted and pagination continues on L2.
- Signature, mixed-namespace, exact-allowlist and high-water tests remain
  unchanged and green.

### Configuration and local direct seeds

- A config containing `directory.bootstraps` is rejected.
- Allowlist and direct-seed parsing remain unchanged.
- Local direct-seed identity discovery still confirms only after a successful namespace exchange,
  does not enter the public directory and does not mutate the shared address
  cache.

### End to end

- Multiple nodes with no directory bootstrap addresses converge directory
  records over their running root control graph.
- The dynamic-port overwrite case is ordered and non-vacuous:
  1. admit a persistent peer key through a live committed membership change at
     `E_old` (or replay that admission through a real catch-up window), rather
     than founding it in genesis;
  2. before any replacement observation, assert
     `quod_quic:resolve(Key) = {ok, E_old}`, proving that the committed endpoint
     entered the cache;
  3. reschedule the same key at `E_new`;
  4. establish a real ordinary mutually authenticated root link whose header
     teaches `E_new`, without calling a test-only `quod_quic:learn/2`, and
     assert that `resolve(Key)` now returns `E_new`;
  5. prove that the root-driven pinned control link and directory records
     converge at `E_new` with no configuration update.
- The cross-ontology preflight proves the target is remote and then completes
  its fixed-work load without `unknown_ontology`.

Focused EUnit plus the directory and transport CT suites are sufficient during
development. Full EUnit/CT, Dialyzer and xref remain the release gate.

## 12. Deployment and measurement

The predicate is code-provided and reads the existing root ledger, so deployment
requires neither a root transaction nor a ledger wipe.

Deploy the image and the bootstrap-free Nomad template together. The directory
wire record and control frames do not change. Root consensus continues
independently during deployment; directory soft state may temporarily resync
but cannot alter consensus.

After convergence:

1. verify control peer/link counts and the last successful root-proof height on
   every node, except the valid zero-link one-member case;
2. verify system routes refill after a node-port change;
3. run the cross-ontology fixed-work benchmark;
4. compare request success, directory convergence time, transaction latency and
   consensus progress with the preceding run.

## 13. Questions for review

Claude should specifically check:

1. whether the root-execution-context compiled predicate over the frozen
   `peer_admitted/4` snapshot preserves Prolog as the sole authority;
2. whether the mixed-provenance address-cache boundary is accurate and stale
   committed hints remain availability-only under pinned dialing;
3. whether successful-empty, failed, timed-out and stale-token proof outcomes
   are distinguished without losing the last valid authority set;
4. whether direct-author versus root-relay classification is complete on every
   inbound source shape and no bare authority token remains;
5. whether exact active-link snapshot acceptance, insert-before-close,
   exact-ref `DOWN`, bounded dial timeout and transport link reuse leave any
   stale-generation hole;
6. whether best-effort links over the connected root graph suffice without
   coupling dissemination to advertised system routes or claiming a full mesh;
7. whether the proposed deletion and call-site rewire lists leave any hidden
   system-bootstrap fallback or stale TOFU terminology;
8. whether the focused tests are non-vacuous, especially live-commit
   stale-address overwrite, relay rejection and old-link snapshot/`DOWN`.
