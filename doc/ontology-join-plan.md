# `join_ontology` — dynamic hosting slice

> **Architecture update:** validation, exact-anchor join, namespace-manager,
> effect-journal, and recovery rules remain authoritative. Earlier revisions'
> dedicated lifecycle runner and hidden authorization proof have been removed.
> The implemented public path is defined by
> `ontology-lifecycle-single-path-plan.md`.

## Goal

Let the node ontology start hosting an existing ontology through the
normal pinned-genesis join and catch-up path.

```prolog
"quod:node"::join_ontology(
   {':', user_alice, notes},
   "5f8c...64 hexadecimal characters...",
   [seed("192.168.1.11", 14567)]).
```

The operation is deliberately small: one Erlang API builds the same `mode =
join` configuration used at boot, and the ordinary action path calls that API
after proving an explicit node-ontology
`action(Transition, Prerequisites, DesiredState)` clause. It does not create a
second join implementation.

Joining is asynchronous. Success from ordinary signed or node-authored
`execute` means either
that the exact pinned target already held, or that the local join was accepted
and its supervised catch-up process was started. It does **not** claim that a
new catch-up has finished. A separate read-only predicate reports the local
progress:

```prolog
ontology_join_state(user_alice:notes, State).
```

`State` is one of `not_hosted`, `starting`, `joining`, `ready`, or `stopping`.
The caller may poll this predicate. No proof worker waits for network catch-up,
and no second lifecycle/status store is introduced.

## Erlang API

Extend `quod_ontology` with:

```erlang
quod_ontology:join(Name, GenesisHash, Seeds) ->
    {ok, joining | resumed, Namespace, RawGenesisHash} |
    {error, Reason}.

quod_ontology:local_state(Name) ->
    {ok, not_hosted | starting | joining | ready | stopping} |
    {error, Reason}.
```

`GenesisHash` is textual hexadecimal input: exactly 64 hexadecimal characters,
decoded once to the immutable 32-byte anchor used by `quod_simplex`. Accepting
Unicode character data here is representation-normalisation, not a second hash
format; the semantic input is always the displayed hexadecimal anchor copied
from the founder/API.

`Seeds` is a proper, non-empty list of at most 32
`{seed, Host, Port}` terms. `Host` is non-empty Unicode character data and
`Port` is an integer in `1..65535`. The API normalises these once to the
existing `{HostString, Port}` `seed_peers` form. Passing host and port as
separate fields avoids ambiguous `host:port` parsing and handles IPv6 without a
new endpoint grammar. Duplicate normalised endpoints are rejected rather than
silently changing the caller's input.

All validation happens before consulting the namespace manager or filesystem.
Names reuse the exact canonicalisation and bounds already enforced by
`create/2`. A `quod:*` ontology is created normally under `quod:node` policy and only
becomes a system ontology when root later records its exact anchor; malformed
names fail before any lifecycle work. The shared name, root-storage and ledger-state helpers remain in
`quod_ontology`; they are factored rather than copied into a join module.

## Reusing the existing join path

After validation, `join/3`:

1. Obtains the root ontology's existing `data_dir` / `ledger_dir` placement,
   exactly as `create/2` does.
2. Calls `quod_app:build_ns_config/1` with `mode => join`, no genesis source,
   and the textual genesis anchor, then installs the already-normalised
   `seed_peers`. This keeps all proof-worker, timeout and consensus defaults on
   the one existing configuration path while avoiding `content_seeds/1`'s
   boot-time policy of silently ignoring malformed recovery hints.
3. Reads the local ledger state before start. No local log gives API status
   `joining`; an existing log gives `resumed`. Supplied input never overwrites
   an existing ledger.
4. Calls `quod_namespace_manager:start_new_content/2`, never
   `quod_ns_sup:start_child/2` directly. The manager first rejects desired/live
   collisions, starts the child while the name is still unadmitted, verifies
   that `quod_simplex:genesis_hash/1` exposes the exact pinned anchor, and only
   then persists desired state and publishes the explorer data-directory entry
   before replying. A failed start or anchor check records no desire and
   publishes nothing; only the just-started child is stopped. This check does
   not wait for slot 1 to download: the lock-free genesis table is available
   on a fresh joiner before catch-up. Network-directory advertisement remains
   deliberately absent for a private runtime ontology.

The existing catch-up/feed/consensus processes do everything after that point.
An unavailable seed leaves the ontology in `joining`; when a valid seed becomes
reachable, the same supervised process progresses to `ready`. The API does not
turn temporary network unavailability into failure and does not implement its
own retries.

`local_state/1` derives its answer from existing state only:

- no manager desire and no live namespace: `not_hosted`;
- manager desire but no live Simplex process: `starting`;
- a live Simplex process with `syncing = true`: `joining`;
- a live Simplex process with `syncing = false`: `ready`;
- a live process after its manager desire was removed: `stopping`.

`quod_simplex:status/1` deliberately returns `#{}` when its one-second statem
call cannot obtain an answer. If the Simplex process is still live, that
unknown/busy status maps conservatively to `joining`, never to `ready` or
`not_hosted`. Polling therefore cannot claim completion merely because a
catching-up consensus mailbox is busy. This slice does not add another status
table or a second lock-free Simplex projection for a short-lived testing API.

The Prolog name is `ontology_join_state/2`, as used by the action prerequisite.
It is explicitly documented as the state on the node that answered, not a
consensus fact or a network-wide ontology state. The short transition states
are observable rather than hidden or persisted.

## The common ontology layer

Add `priv/ontologies/common_predicates.pl` as Quod's code-owned Prolog baseline
for every ontology. Loading has one owner and one path:

1. `quod_committed_projection:new_est/0` creates Erlog's built-ins, list library and DCG
   library, then sets `unknown = fail`, exactly as today.
2. It registers every governed compiled predicate and the `::` ask predicate.
3. Only then it resolves `ontologies/common_predicates.pl` under
   `code:priv_dir(quod)`, parses it, and folds its terms through Erlog's normal
   `assertz` clause compiler into that new MVCC KB.

Loading the common interpreted clauses after all compiled registrations is a
deliberate safety boundary: a common source term that collides with a built-in,
governed effect/query, or `::` fails loudly as an attempt to modify a static
procedure. It cannot silently shadow an Erlang security boundary. The common
source is loaded once per newly constructed KB; it is not consulted by
`quod_simplex`, the namespace manager, or the ontology-creation API directly.

Every relevant path already converges on `quod_committed_projection:new_est/0`: a live namespace starts
from it, a restarted Prolog projection rebuilds from it before ledger replay,
and `terms_to_diff/1` wraps a KB returned by it before compiling supplied
genesis terms. Consequently the common clauses are present before ontology
content in all three cases without a second loader.

The common clauses belong to the base DB before the local write overlay is
created. `terms_to_diff/1` therefore captures only the caller's supplied terms;
loading the baseline itself emits no genesis or ledger operation. An ontology
may still extend or deliberately change these interpreted predicates through
its normal committed writes, just as it extends `action/3`; those explicit
changes do belong in its ledger. Replay constructs the same release-owned base
and then applies the committed diffs once, so neither restart nor catch-up
duplicates the baseline clauses.

A missing, unreadable or invalid common file is a KB-construction failure. It
is never treated as an empty framework. This first slice reads the small file
on each KB construction; it adds no `persistent_term` cache or cache-invalidation
policy for an operation that is not a hot path. All nodes serving one ontology
must run the same Quod release, as they already must for Erlog built-ins and
compiled predicates. A future semantic edit to the common file is therefore a
consensus-code change, not an ontology transaction or a compatibility layer.

## Shared `goal/1` action pattern

`doc/distributed-proof-plan.md` sections 2.3 and 3 are normative. The common
file exposes the same target-driven relation in every ontology:

```prolog
action(Transition, Prerequisites, DesiredState).
goal(DesiredState).
```

`goal/1` checks the desired state read-only first. If it already holds, no
transition runs. Otherwise it validates and tries each declaration reaching
that state in Prolog order. A transition is one callable goal or a non-empty
proper list of callable goals; prerequisites form a proper list. Ordinary
prerequisites are read-only state checks, while explicit `goal(State)` and
`Ns::goal(State)` prerequisites may establish another state recursively.

Each candidate's prerequisites, transition, and exact postcondition run inside
`transaction/1`. That predicate is semidet: it adopts only the first complete
inner solution and exposes no inner redo. A failed candidate restores every
assertion, retraction, and abolish it staged before another declaration is
tried; failure reasons remain available. Term-identity cycle detection prevents
recursive state loops.

The old effect-oriented forward lookup, reverse-effect lookup,
`assert_effect/1`, generic `assert_fact/1` / `remove_fact/1` actions, and direct
fallback are removed rather than retained as compatibility paths. Ontologies
use explicit named transitions; the desired state is proved, never inferred or
automatically asserted by the framework.

Only that framework core is brought across. Domain class, subscription,
network-node and client-effect rules in BBSVX's larger common file do not belong
in Quod's common baseline.

The node-local slice carries its engine-owned principal in the private overlay;
the later authenticated `subject/3` design can use the same policy and action
shape.

## Ordinary node action

`quod:node` contains the ordinary action and policy clauses:

```prolog
ontology_hosted(Name) :- ontology_join_state(Name, starting).
ontology_hosted(Name) :- ontology_join_state(Name, joining).
ontology_hosted(Name) :- ontology_join_state(Name, ready).

ontology_joined(Name, GenesisHash) :-
    ontology_hosted(Name),
    ontology_genesis_anchor(Name, GenesisHash).

action('$quod_stage_ontology'(Handle,
                              create_ontology(Name, Options),
                              ontology_hosted(Name)),
       [current_principal(Agent),
        can_create_ontology(Agent, Name, Options),
        ontology_join_state(Name, not_hosted)],
       ontology_hosted(Name)).

action('$quod_stage_ontology'(Handle,
                              join_ontology(Name, GenesisHash, Seeds),
                              ontology_joined(Name, GenesisHash)),
       [current_principal(Agent),
        can_join_ontology(Agent, Name, GenesisHash, Seeds),
        ontology_join_state(Name, not_hosted)],
       ontology_joined(Name, GenesisHash)).

can_create_ontology(node(NodeKey), _Name, _Options) :-
    peer_admitted(NodeKey, _, _, NodeKey).

can_join_ontology(node(NodeKey), _Name, _GenesisHash, _Seeds) :-
    peer_admitted(NodeKey, _, _, NodeKey).
```

The public fully ground `create_ontology/2` or `join_ontology/3` goal targets
`quod:node` and runs as one ordinary proof. Signed requests carry their verified
principal; node-authored requests derive `node(NodePublicKey)` from the engine.
The normal `can_invoke/4` entry and the action prerequisites make the complete
policy decision. There is no lifecycle-specific policy proof.

The public staging bridge structurally validates the request and registers one
opaque proof-local handle. After the declared prerequisites succeed, the exact
internal continuation prepares input once and stages one closed create/join
effect. Backtracking or proof failure discards it. Commit records that effect in
the `quod:node` transaction; the node-wide journal executes it after apply and
checks the real desired state before retry. An uncertain result carries the
exact transaction reference. The manager remains the authoritative atomic
collision check.

`ontology_join_state/2` and `ontology_genesis_anchor/2` are query-class,
`quod:node`-only local-state predicates. They perform no IO. The old inline-IO
effect functors, lifecycle worker, and compatibility registrations are absent.

The low-level preparation/execution functions remain trusted same-VM
internals. They do not authenticate callers and must not be exposed directly
as network endpoints. Production contains no raw `create/2` or `join/3` route
beside the ordinary action path; those wrappers are TEST fixture conveniences.

The lifecycle-specific join vocabulary includes:

```prolog
ontology_join_failed(invalid_arguments)
ontology_join_failed(wrong_ontology)
ontology_join_failed(invalid_name)
ontology_join_failed(invalid_genesis_hash)
ontology_join_failed(invalid_seeds)
ontology_join_failed(already_hosted)
ontology_join_failed(root_unavailable)
ontology_join_failed(start_failed)
```

Detailed Erlang start errors remain available from the low-level preparer, but
PIDs, paths, references and nested supervisor terms never cross into Prolog.
Prerequisite failures retain the normal bounded failure-reason stack;
post-proof executor failures are returned explicitly in the same bounded
vocabulary. Generic engine states remain errors, and ambiguous post-commit
journal completion is `{error, outcome_unknown}`.

A manager race returning `{already_configured, Namespace}` is mapped to the bounded
`ontology_creation_failed(already_hosted)` reason instead of the generic
`start_failed` on create, and to `ontology_join_failed(already_hosted)` on join.
The Prolog precondition normally catches it; the manager remains
the authoritative race closure for both lifecycle operations.

Invalid arguments to `ontology_join_state/2` similarly fail with a bounded
`ontology_state_failed(invalid_arguments | wrong_ontology | invalid_name)` reason.
`not_hosted` is a successful state answer, not an error.

The desired-state check makes create idempotent for an already hosted namespace
and makes an exact repeated join idempotent only when the live anchor matches.
When the target is false, the `not_hosted` prerequisite prevents a conflicting
create or wrong-anchor join from reaching the typed executor.
`start_new_content/2` remains the authoritative race-safe check inside Erlang;
the Prolog relation expresses policy while the manager closes the check/start
race.

These action clauses are part of `quod_node.pl` and enter the node system
ontology at its genesis. An existing node ledger does not re-read that file.
Testing this new action surface on an older deployed fleet therefore requires a
normal node-ontology policy update or a clean test re-found. No hidden boot-time
injection or compatibility clause makes old content appear updated.

## Lifecycle meaning

A fresh joiner is an observer. Reaching `ready` means it has verified and
applied the anchored chain locally; it does not mean it has become a voting
committee member. Admission remains the ontology's existing, separate
`admit/3` transaction, including its `can_join/3` and `peer_ready/1` checks.

Calling `join/3` again while the namespace is live fails as `already_hosted`
without altering the existing process or desired map. A full application
restart reloads the namespace manager's node-local hosting checkpoint and
resumes the exact anchored ledger automatically. After a deliberate stop,
calling `join/3` with the same anchor resumes it explicitly. The existing join
startup validation rejects a different anchor for an existing ledger; no
migration or compatibility path is added.

At the Prolog boundary, repeating the exact `join_ontology` action succeeds
without calling `join/3` again because `ontology_joined(Name, GenesisHash)` is
already true. Repeating it with a different anchor fails: the desired state is
false and the namespace is not `not_hosted`.

As with runtime creation, the checkpoint contains only local desired hosting.
It neither admits this node to the target committee nor publishes a directory
record; those remain separate authorized operations.

## Tests

1. API validation rejects malformed names, hashes, seed shapes, ports,
   duplicates and oversized seed lists before manager/filesystem work. The
   desired map and data-directory publication map remain byte-for-byte
   unchanged.
2. A real Quod MVCC KB contains the common action core after static predicate
   registration. It proves target-first idempotence, declaration-order
   alternatives sharing one desired state, single and ordered-list
   transitions, prerequisite order, recursive `goal/1`, cycle rejection, and
   rollback of assertions, retractions, and abolishes after transition or
   postcondition failure. `transaction/1` keeps only its first complete inner
   solution. A common term that collides with a compiled functor is rejected.
   Building a fresh KB does not duplicate common clauses, and
   `terms_to_diff/1` never returns them in a genesis diff.
3. The action entry is `quod:node`-only and requires a fully ground action. Wrong
   scope, non-ground arguments, authorization denial, missing declarations,
   and definite API failures produce the exact bounded reason; ambiguous
   completion remains `{error, outcome_unknown}`. Ordinary proofs and the
   removed inline-IO effect functors perform no lifecycle IO.
4. The two node `action/3` clauses use `ontology_hosted/1` and the
   anchor-sensitive `ontology_joined/2` desired states. Declaration and
   authorization checks precede source reads; valid input is prepared exactly
   once. An authorized already-true target stages no effect, an exact
   repeated join succeeds, and a wrong-anchor repeat fails. For an execution
   candidate, authorization precedes `not_hosted` in the ordinary prerequisite
   phase. A failed or backtracked candidate discards the prepared effect. A
   race after commit is rejected by `start_new_content/2`.
5. A real founder commits a fact. A second node invokes ordinary
   `quod_prolog:execute/2` against `quod:node` with
   the founder's anchor and endpoint, observes
   `joining` (or `ready` if loopback catch-up wins the race), eventually
   observes `ready`, and proves the fact from its own applied KB. Its role
   remains observer.
6. Stop the founder before starting the joiner. The action is still accepted,
   `ontology_join_state/2` reports `joining`, and no worker is blocked. Restart
   the founder at the same authenticated endpoint; the existing join process
   reaches `ready` without a second predicate call. This non-vacuously proves
   the asynchronous contract and reuse of existing retries.
7. A collision with a live or desired namespace leaves its PID, config and
   desired map unchanged. A synchronous child-start failure admits no desired
   entry and leaves no reconciliation retry when cleanup succeeds, using the
   manager's `start_new_content/2` guarantees.
8. Stop and rejoin against the same local ledger: the API returns `resumed`,
   no second genesis is written, catch-up continues from the durable prefix,
   and the data-directory map is republished only after validated start.
   Rejoining that ledger with a different anchor fails without admitting
   desire and leaves the existing ledger byte-for-byte unchanged.
9. `ontology_join_state/2` covers `not_hosted`, `joining` and `ready` through
   real lifecycle transitions; focused manager tests cover the short
   `starting` / `stopping` races without adding sleeps to production code. A
   live process whose status call returns `#{}` reports `joining`; calling the
   predicate from a non-node ontology fails with `wrong_ontology`.
10. The removed inline-IO lifecycle functors have no compiled registration or
    handler and cannot perform IO. Creation and joining succeed through the one
    ordinary proof/action path; signed and node-authored execution do not form
    separate implementations.

Use focused EUnit plus the existing real-QUIC join suite while implementing.
Run the full compile, xref, Dialyzer, EUnit and CT release gate only once the
slice is ready for commit.

## Explicit non-goals

- No new catch-up, feed, consensus, retry or lifecycle worker.
- No automatic committee admission or `can_join/3` bypass.
- No directory publication; dynamically joined ontologies remain private.
- No replicated hosting catalogue or automatic committee re-admission.
- No user/agent identity, ontology ownership, payment or quota model beyond
  the node-local self-admitted-validator policy.
- No blocking `wait_until_joined` predicate and no polling loop inside Erlog.
- No backward-compatibility signature or alternate input form.
