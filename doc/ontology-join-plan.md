# `join_ontology` — dynamic hosting slice

## Goal

Let the root ontology on a node start hosting an existing ontology through the
normal pinned-genesis join and catch-up path.

```prolog
goal(
    join_ontology(
        user_alice:notes,
        "5f8c...64 hexadecimal characters...",
        [seed("192.168.1.11", 14567)])).
```

The operation is deliberately small: one Erlang API builds the same `mode =
join` configuration used at boot, and one thin external Erlang effect predicate
calls that API. The shared `goal/1` action pattern from BBSVX and Onia resolves
an explicit root-ontology `action(Action, Prerequisites, Effect)` clause. It does
not create a second join implementation.

Joining is asynchronous. Success of `goal(join_ontology(...))` means that the
local, pinned join was accepted and its supervised catch-up process was
started; it does **not** claim that catch-up has finished. A separate read-only
predicate reports the local progress:

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
`create/2`, including rejection of every reserved `quod` / `quod:*` system
namespace. The shared name, root-storage and ledger-state helpers remain in
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
   `quod_ns_sup:start_child/2` directly. This preserves the manager's atomic
   desired-state insertion, exact rollback on start failure, collision safety,
   supervisor recovery, and deliberate lack of directory advertisement for a
   private runtime ontology.
5. Verifies that `quod_simplex:genesis_hash/1` exposes the exact pinned anchor,
   then calls the existing `quod_app:publish_data_dir/2`. Publication therefore
   happens only after the local join process accepted the anchor. This check
   does not wait for slot 1 to download: the current lock-free genesis table is
   explicitly available on a fresh joiner before catch-up.

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

1. `quod_prolog:build_kb/0` creates Erlog's built-ins, list library and DCG
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

Every relevant path already converges on `build_kb/0`: a live namespace starts
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

The common file carries the BBSVX/Onia action core, with one explicit Quod
safety rule described below. Its basic forward path remains:

```prolog
goal(Goal) :- goal(Goal, []).

goal(Goal, Visited) :- member_eq(Goal, Visited), !, fail.

goal(Goal, Visited) :-
    action(Goal, Prerequisites, Effect),
    satisfy_prereq(Prerequisites, [Goal | Visited]),
    assert_effect(Effect).
```

The file carries the complete common mechanism, not a look-alike special case:

1. cycle detection by term identity (`==`);
2. forward lookup by action name;
3. reverse lookup from a desired effect, trying specific actions first;
4. catch-all `assert_fact/1` / `remove_fact/1` actions last;
5. direct `call/1` fallback;
6. ordered prerequisite evaluation through `call/1`;
7. `true`, `retract(Term)`, and ordinary assertion effect handling.

Quod does not import the two unsafe fall-through cases verbatim. Both reverse
lookup clauses first require:

```prolog
reverse_goal_allowed(Goal) :-
    Goal \= true,
    \+ action(Goal, _, _).
```

This gives two precise semantics:

- `goal(true)` is handled only by the final direct `call/1` fallback. It never
  reverse-selects every lifecycle action whose intentionally empty effect is
  `true`.
- a term declared as an action name is forward-only. If its prerequisites or
  external adapter fail, reverse lookup cannot reinterpret that same term as a
  fact for the `assert_fact/1` catch-all. The original failure reasons survive
  and the effect runner never receives a junk staged write.

Reverse lookup by a genuine desired effect is unchanged: for example an
`instance_of/2` effect can still locate a specific `create_instance/2` action,
and an undeclared ordinary fact can still reach the catch-all. This is a
general action/fact separation rule, not a lifecycle-name exception.

Only that framework core is brought across. Domain class, subscription,
network-node and client-effect rules in BBSVX's larger common file do not belong
in Quod's common baseline.

This replaces the former `doc/agent-fipa-plan.md` design that rejected the
BBSVX/Onia `goal/1` pattern and used a subject/result-shaped `action/3`.
Keep that document's action section and later FIPA request mapping aligned with
this one action definition. Also keep
`doc/ontology-creation-plan.md` and
`doc/ontology-creation-input-plan.md` for the renamed creation adapter and the
new `goal(create_ontology(...))` entry point. Identities remain available to
action prerequisites through the proof subject/context; they do not require
changing the action's three fields.

## Root lifecycle actions

Add these ordinary clauses to the root ontology:

```prolog
action(create_ontology(Name, Options),
       [ontology_join_state(Name, not_hosted),
        create_ontology_effect(Name, Options)],
       true).

action(join_ontology(Name, GenesisHash, Seeds),
       [ontology_join_state(Name, not_hosted),
        join_ontology_effect(Name, GenesisHash, Seeds)],
       true).
```

`satisfy_prereq/2` calls these entries from left to right. The live state check
therefore runs before the Erlang effect. The manager still performs the
authoritative atomic collision check, closing a race between the Prolog
prerequisite and start.

The external operation is the final prerequisite and the declared action
effect is `true`. That is intentional: starting a local supervised namespace is
volatile node state, not a durable ontology fact. Asserting a fake
`joining(...)` fact would immediately become stale and would be replicated to
nodes whose local state differs. `ontology_join_state/2` reads the real local
runtime instead.

The first clause moves the existing creation effect behind the same public
`goal/1` boundary now, rather than leaving two lifecycle conventions. The
Erlang `quod_ontology:create/2` API itself is unchanged.

Creation and joining remain open in this testing slice. When identities land,
root can prepend authorization predicates to either prerequisite list without
changing `goal/1`, the external adapters, or the lifecycle APIs.

Register three governed adapter predicates in the existing
`quod_ontology_predicates` module:

```prolog
create_ontology_effect(Name, Options).                  % effect
join_ontology_effect(Name, GenesisHash, Seeds).          % effect
ontology_join_state(Name, State).                        % query
```

There is no compatibility registration for the old external
`create_ontology/2` functor. The semantic public entry becomes
`goal(create_ontology(...))`; tests and documentation change together.

Their Erlang handlers use the established `_predicate` suffix:
`create_ontology_effect_predicate/3`, `join_ontology_effect_predicate/3`, and
`ontology_join_state_predicate/3`.

All handlers require the executing namespace to be `quod:root`. The join
adapter requires its three inputs to be ground and calls only
`quod_ontology:join/3`; accepted `joining` and `resumed` API results both satisfy
the prerequisite. The creation adapter similarly delegates to
`quod_ontology:create/2`; `created` and `resumed` both satisfy it. The state
handler requires a ground name, calls only `quod_ontology:local_state/1`, and
unifies `State` through Erlog's normal unification path; `State` need not be
ground.

On an invalid call or API error, an effect adapter proves
`fail_with_reason/1`, which records the reason and immediately fails through
normal backtracking. There is no Quod-private error stack and no use of the old
`set_fail_reason` name.

The predicate exposes only this bounded, ground vocabulary:

```prolog
ontology_join_failed(invalid_arguments)
ontology_join_failed(root_only)
ontology_join_failed(invalid_name)
ontology_join_failed(reserved_system_namespace)
ontology_join_failed(invalid_genesis_hash)
ontology_join_failed(invalid_seeds)
ontology_join_failed(already_hosted)
ontology_join_failed(root_unavailable)
ontology_join_failed(start_failed)
```

Detailed Erlang start errors remain available from `quod_ontology:join/3`, but
PIDs, paths, references and nested supervisor terms never cross into Prolog.
The interpreter retains the failed adapter, the failed state prerequisite when
applicable, and the outer `goal(join_ontology(...))` call in its normal bounded
failure stack.

While the creation adapter is being renamed, a manager race returning
`{already_configured, Namespace}` is likewise mapped to the bounded
`ontology_creation_failed(already_hosted)` reason instead of the generic
`start_failed`. The Prolog precondition normally catches it; the manager remains
the authoritative race closure for both lifecycle operations.

Invalid arguments to `ontology_join_state/2` similarly fail with a bounded
`ontology_state_failed(invalid_arguments | root_only | invalid_name)` reason.
`not_hosted` is a successful state answer, not an error.

The action prerequisite is useful beyond join: it prevents both create and
join from reaching their effect adapters when this node already hosts or is
starting the namespace. `start_new_content/2` remains the authoritative
race-safe check inside Erlang; the Prolog prerequisite expresses policy and
gives the caller the failed state goal, while the manager closes the
check/start race.

These action clauses are part of `quod_root.pl`, whose content is committed only at
root genesis. An existing root ledger does not re-read that file. Testing this
new action surface on the deployed fleet therefore requires either a deliberate
root transaction installing the clauses or, preferably during the current test
stage, a clean re-found. No hidden boot-time injection or compatibility clause
is added to make an old root appear updated.

## Lifecycle meaning

A fresh joiner is an observer. Reaching `ready` means it has verified and
applied the anchored chain locally; it does not mean it has become a voting
committee member. Admission remains the ontology's existing, separate
`admit/3` transaction, including its `can_join/3` and `peer_ready/1` checks.

Calling `join/3` again while the namespace is live fails as `already_hosted`
without altering the existing process or desired map. After a deliberate stop
or full application restart, calling it with the same anchor resumes the local
ledger. The existing join startup validation rejects a different anchor for an
existing ledger; no migration or compatibility path is added.

As with runtime creation, a full application restart forgets the dynamic
hosting intention. Reissuing the join action resumes it. Durable manifests,
automatic admission and restart orchestration are separate future work.

## Tests

1. API validation rejects malformed names, hashes, seed shapes, ports,
   duplicates and oversized seed lists before manager/filesystem work. The
   desired map and data-directory publication map remain byte-for-byte
   unchanged.
2. A real Quod MVCC KB contains the common action core after static predicate
   registration. It proves forward lookup, reverse-effect lookup,
   specific-before-catch-all ordering, cycle rejection, direct fallback,
   prerequisite order, and assert/retract/true effects. A common term that
   collides with a compiled functor is rejected. Building a fresh KB does not
   duplicate common clauses, and `terms_to_diff/1` never returns them in a
   genesis diff.
3. The effect adapters are root-only and effect-only. Wrong scope, ordinary
   proof context, non-ground arguments and API errors produce the exact bounded
   failure reason through the normal stack. The creation action still covers
   every existing ordered input and failure case after its adapter rename.
4. The two root `action/3` clauses prove their `not_hosted` prerequisite before
   invoking an effect. An already `starting`, `joining`, `ready`, or `stopping`
   namespace never reaches the adapter; `goal(join_ontology(...))` returns its
   bounded failure stack, stages no junk fact, and is never reported as
   `effect_staged_write`. A race after that proof is still rejected by
   `start_new_content/2`. `goal(true)` succeeds with an empty diff and invokes
   no lifecycle adapter, while reverse lookup for genuine effects and the
   ordinary undeclared-fact catch-all remain functional.
5. A real founder commits a fact. A second node invokes
   `goal(join_ontology(...))` with
   the founder's anchor and endpoint, observes
   `joining` (or `ready` if loopback catch-up wins the race), eventually
   observes `ready`, and proves the fact from its own applied KB. Its role
   remains observer.
6. Stop the founder before starting the joiner. The goal still succeeds,
   `ontology_join_state/2` reports `joining`, and no worker is blocked. Restart
   the founder at the same authenticated endpoint; the existing join process
   reaches `ready` without a second predicate call. This non-vacuously proves
   the asynchronous contract and reuse of existing retries.
7. A collision with a live or desired namespace leaves its PID, config and
   desired map unchanged. A synchronous child-start failure rolls back only the
   new desired entry and leaves no reconciliation retry, using the manager's
   existing `start_new_content/2` guarantees.
8. Stop and rejoin against the same local ledger: the API returns `resumed`,
   no second genesis is written, catch-up continues from the durable prefix,
   and the data-directory map is republished only after successful start.
   Rejoining that ledger with a different anchor fails, rolls back the exact
   attempted desire, and leaves the existing ledger byte-for-byte unchanged.
9. `ontology_join_state/2` covers `not_hosted`, `joining` and `ready` through
   real lifecycle transitions; focused manager tests cover the short
   `starting` / `stopping` races without adding sleeps to production code. A
   live process whose status call returns `#{}` reports `joining`; calling the
   predicate from a non-root ontology fails with `root_only`.
10. The removed direct external `create_ontology/2` functor cannot perform a
    lifecycle effect. Creation succeeds only through
    `goal(create_ontology(...))`, with all existing source-input tests retained
    at that public boundary.

Use focused EUnit plus the existing real-QUIC join suite while implementing.
Run the full compile, xref, Dialyzer, EUnit and CT release gate only once the
slice is ready for commit.

## Explicit non-goals

- No new catch-up, feed, consensus, retry or lifecycle worker.
- No automatic committee admission or `can_join/3` bypass.
- No directory publication; dynamically joined ontologies remain private.
- No durable hosting manifest or automatic restart rejoin.
- No creation/join authorisation, identity ownership, payment or quota model.
- No blocking `wait_until_joined` predicate and no polling loop inside Erlog.
- No backward-compatibility signature or alternate input form.
