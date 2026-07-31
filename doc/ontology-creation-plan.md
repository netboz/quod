# `create_ontology` — testing slice

## Goal

Add one Erlang API that creates and starts a local N=1 ontology from ordered
term, inline-source, and file-source inputs, and one root action whose thin
external Erlang adapter calls it.

```erlang
quod_ontology:create(
  {':', user_alice, notes},
  [{terms, [{note, welcome}]},
   {source, <<"can_read(Goal, Subject, Ns) :- policy(Goal, Subject, Ns).">>},
   {source_file, <<"/srv/quod/notes.pl">>}]).
```

The created namespace owns its own slot-1 ledger.  Its genesis contains the
provided terms, the generated `consensus_incarnation/1`, and its self-only
`peer_admitted/4` fact.

No root catalogue, root transaction, directory change, membership automation,
ownership rule, manifest, quota, or restart-persistence feature is part of
this slice.

## Public API

```erlang
quod_ontology:create(Name, Options) ->
    {ok, created | resumed, Namespace, GenesisHash} | {error, Reason}.
```

- `Name` is first canonicalised by `quod_ontology_name:flatten/1`, then checked
  before any manager or filesystem call.  The resulting namespace must be a
  non-empty, valid UTF-8 binary of at most 128 bytes.  The complete `quod:`
  system namespace is reserved: `create/2` rejects every name whose canonical
  binary is exactly `<<"quod">>` or begins with `<<"quod:">>`, not merely the
  currently-declared `quod:root`. This grammar also bounds the two existing
  ETS-name atoms created for a running namespace; the wider atom/economic
  policy remains a separate design.
- `Options` is a proper ordered list of repeatable `{terms, Terms}`,
  `{source, Text}`, and `{source_file, Path}` inputs. Their parsed terms are
  combined in exact option/source order and become the user-controlled part of
  slot 1. The complete input and error contract is documented in
  `doc/ontology-creation-input-plan.md`.
- Before compilation, the API rejects a user clause whose head is
  `consensus_incarnation/1` or `peer_admitted/4`.  Those facts are generated
  exactly once by the genesis builder and cannot be overridden by
  the combined terms.
- The API then pre-compiles the combined terms with
  `quod_prolog:terms_to_diff/1` **before** it calls the namespace manager. A
  compilation error is returned as `{error, Reason}`.  If
  `terms_to_diff/1` throws `{genesis_failed, {assert, Term, InterpreterState}}`,
  `create/2` keeps the offending `Term` but removes the internal Erlog state
  from its public error.  Other compiler exceptions are likewise caught and
  mapped to a finite creation error; no `#est{}`, PID, reference, or stacktrace
  crosses the API.  Thus malformed content cannot enter the manager desired
  map, start a retry loop, or create even an empty namespace directory.
- The API builds the self-only `mode = create` config by passing a small content
  descriptor through the existing `quod_app:build_ns_config/1`, then adding the
  internal `genesis_terms` value. The descriptor copies the resolved
  `data_dir` and optional `ledger_dir` from the live `quod:root` content config
  in the manager's desired map; these paths are per-content settings, not
  node-wide settings. Because that manager config already contains converted
  string paths, the API copies those two resolved keys into the result of
  `build_ns_config/1` rather than feeding them back through its binary HOCON
  input. If no live root config is available, creation fails instead of
  silently using the ephemeral user-cache default. The API therefore reuses
  the running node's identity, storage placement, and normal operational
  limits without copying their defaults. It does not create a temporary `.pl`
  file.
- `quod_simplex:genesis_tx/4` remains the single genesis builder used for both
  boot-config and runtime creation.  Its existing optional content step gains
  `genesis_terms`; it still compiles through `quod_prolog:terms_to_diff/1`.
  Supplying both `genesis_file` and `genesis_terms` is a loud configuration
  error, never a precedence rule.
- Creation starts through a small atomic namespace-manager operation,
  `start_new_content/2`, never directly through `quod_ns_sup`.  While
  serialising the desired map, the manager accepts the call only if the
  namespace is absent, inserts the caller's config, and attempts the start.  If
  that attempt fails, the manager removes and persists only the exact desired
  entry that this call inserted and returns the start error without scheduling
  the 250 ms reconciliation retry. A start result of
  `{error, {already_started, Pid}}` is a collision, not success: the manager
  rolls back its inserted config and returns `already_configured`, because the
  surviving child may have been started under a different config. The same
  classification covers an `already_present` child spec. Before insertion, an
  undesired-but-still-running child left by an earlier failed stop is also a
  collision, never adopted under the new config. If the
  namespace was already desired, it likewise returns `already_configured`
  without touching or stopping it. This
  manager-owned rollback prevents both poisoned desired state and the more
  serious mistake of tearing down an existing live ontology after a colliding
  create call.  Ordinary boot/reconciliation continues to use
  `start_content/2`.
- `start_new_content/2` deliberately skips `maybe_notify_directory`: this slice
  creates a local/private ontology and has no directory-advertisement feature.
  Existing boot and reconciliation paths retain their current notifications.
- After a successful start, the API calls the existing data-directory
  publication helper used by boot so explorer/read-only store lookup sees the
  runtime namespace.  The helper is factored/exported rather than reimplemented;
  a failed start publishes nothing.
- The API checks the local ledger before start.  A fresh slot-0/no-log path
  returns `created`; an existing valid slot-1 path returns `resumed`.  In the
  latter case the supplied options are not applied and the explicit result prevents
  a caller from mistaking resume for a new creation.

For this first test slice, a whole application restart does **not**
automatically reopen dynamically created ontologies.  Calling `create/2` again
with an existing local ledger resumes it as `mode = create`; automatic durable
hosting intent is deliberately deferred rather than introducing a manifest.

## Action and external adapter

Root exposes creation as an ordinary action:

```prolog
action(create_ontology(Name, Options),
       [ontology_join_state(Name, not_hosted),
        create_ontology_effect(Name, Options)],
       true).
```

The public call is `goal(create_ontology(Name, Options))`. The governed
external adapter is `create_ontology_effect/2`, and its compiled handler is
named `create_ontology_effect_predicate/3`: every Erlang
function entered by Erlog will use the `_predicate` suffix from now on.  It is
an `effect` predicate.  The handler itself checks
`ctx_ns(Context) =:= <<"quod:root">>` before doing any work; registration as an
effect is not treated as an authorisation check.  It then dereferences and
validates its arguments, calls `quod_ontology:create/2`, and uses
`erlog_int:prove_body/2` on success. On a wrong execution namespace, invalid
arguments, or an API error it proves `fail_with_reason(Reason)`, which records
the reason and immediately fails through normal Prolog backtracking. This
follows the thin in-repo external-predicate boundary used by
`quod_committee_predicates`, `quod_directory_predicates`, and
`quod_runtime_predicates`; it keeps genesis and lifecycle work out of the Erlog
handler. Invalid names or inputs therefore make the predicate fail as
well as making the Erlang API return `{error, Reason}`.

The predicate exposes a small, stable Prolog reason vocabulary:

```prolog
ontology_creation_failed(invalid_arguments)
ontology_creation_failed(root_only)
ontology_creation_failed(invalid_name)
ontology_creation_failed(reserved_system_namespace)
ontology_creation_failed(invalid_options)
ontology_creation_failed(invalid_initial_terms)
ontology_creation_failed(invalid_source(OptionIndex, Line))
ontology_creation_failed(source_file_error(OptionIndex))
ontology_creation_failed(start_failed)
```

It does not copy arbitrary Erlang error terms into Prolog: child-start errors
may contain PIDs, references, paths, or other non-portable implementation
details. The Erlang API retains its detailed `{error, Reason}` for operators;
the predicate maps that result to the bounded, always-ground public reason
above. The interpreter then adds the exhausted
`goal(create_ontology(Name, Options))` call
as the outer diagnostic frame. A caller may recover normally:

```prolog
create_or_recover(Name, Options) :-
    goal(create_ontology(Name, Options)).
create_or_recover(_Name, _Options) :-
    get_fail_reasons(Reasons),
    member(ontology_creation_failed(Why), Reasons),
    recover_creation(Why).
```

The recovery clause searches the bounded stack instead of assuming an exact
prefix: the automatically-added outer goal may itself exceed the 4 KiB reason
limit and be represented by the truncation marker.  There is no second error
stack or Quod-specific failure mechanism.

A small `quod_prolog:effect/2` entry point uses the existing per-proof worker
path as a third proof kind, alongside `prove` and `prove_ro`; it does not call
`prove_est/2` directly. The worker therefore holds the same snapshot pin,
monitor, timeout, and read-set lifecycle as every other public proof. For this
kind the worker installs a new `effect_context/2`, and `finish_proof` returns
the normal success or public `fail` / `{fail, Reasons}` shape. An effect proof
that stages a non-empty Prolog diff is rejected explicitly: effects may invoke
the external operation, but may not smuggle ontology writes through this
runner.
This is necessary because creating files and a supervised child from an
ordinary `prove/3` would be unsafe: proofs may be retried, rejected, or
replayed by consensus.  This is not an operator-authorisation framework.

Normal `prove/3`, `prove_ro/3`, served asks, and the explorer prove endpoint do
not enter an effect context, so they cannot accidentally trigger the predicate.
`quod eval` can call `quod_prolog:effect/2` while testing.

The predicate requires the complete option list to be ground. Ground facts can
be supplied with `terms/1`; rules containing variables should use `source/1` or
`source_file/1`, where variables are parsed inside the new ontology rather
than being caller variables.

## Explicit non-goals

- No root `ontology/2` fact and no replicated catalogue.
- No durable hosting manifest or automatic recreation after a full app restart.
- No directory advertisement: private reachability remains local/direct-seed.
- No permission, ownership, payment, atom-capacity, deletion, transfer, or
  remote membership design.
- No default ACL or `can_join/3`: the supplied initial terms define the
  ontology's policy.  A test that needs remote reads includes `can_read/3`.

## Tests

1. `quod_ontology:create/2` creates an N=1 namespace whose slot 1 contains the
   supplied ordered inputs, exactly one generated incarnation and founding-member
   fact, and an available genesis anchor. Its operational config comes from
   `build_ns_config/1`, its resolved data/ledger paths equal root's, and the
   explorer data-directory map is published after the successful start.
2. Empty, invalid-UTF-8, over-128-byte, and `quod:` system names are rejected
   before manager/filesystem work. Each starts no child, creates no ledger
   directory, and leaves the desired map unchanged.
3. Malformed options or terms, bad source/file input, and user-supplied
   `consensus_incarnation/1` or `peer_admitted/4` clause heads are rejected
   before the manager. The detailed API error identifies the offending term
   without containing an Erlog interpreter state, and no retry timer or desired
   entry remains.
4. With an ontology already live and desired, a colliding create call returns
   `already_configured`; the live PID and the entire desired map remain
   unchanged. A failed start for a newly admitted name proves that the manager
   rolls back only that new desired entry and schedules no reconciliation
   retry. An undesired live child proves that supervisor collisions are not
   adopted or stopped; the manager applies that same rollback and collision
   classification to `already_started` and `already_present` start results.
5. `goal(create_ontology/2)` reaches the external
   `create_ontology_effect/2` adapter, which calls the same API. A direct call
   to the removed external `create_ontology/2` functor cannot perform the
   lifecycle operation. An adapter call outside `quod:root` fails with
   `ontology_creation_failed(root_only)` before side effects. Invalid input and
   start errors return `{fail, Reasons}` containing the matching stable
   `ontology_creation_failed/1` reason, and a fallback clause finds it with
   `member/2` even when the automatically-added outer goal is too large to
   retain verbatim.
6. Normal proof contexts reject the effect before it runs. The effect runner
   uses a monitored proof worker and returns public failure reasons; a test
   effect that stages a non-empty diff is rejected rather than submitted.
7. Repeating the API against an existing ledger returns `resumed` and does not
   append a second genesis block or silently apply new initial terms.

Run focused EUnit/CT for this path, then the full release gate before commit.
