# `create_ontology` — local preparation and durable action

## Goal

The trusted Erlang API prepares and starts a local N=1 ontology from ordered
term, inline-source, and file-source inputs. The public root action uses that
same preparer but first records a typed create effect in one ordinary root
transaction; local hosting starts only after that transaction is applied.

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

There is still no root catalogue fact, ownership table, manifest, or quota.
The public action does create a root ledger transaction with an empty root
diff and a closed effect descriptor. The low-level `quod_ontology:create/2`
function remains a trusted same-VM primitive and does not itself authorize or
write the root ledger.

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
- The deterministic encoding of that prepared content diff is limited by the
  shared `MAX_GENESIS_INITIAL_DIFF_BYTES` value (192 KiB). Oversize input fails
  as `initial_content_too_large` before manager or filesystem mutation; slot 1
  remains subject to the complete 256 KiB block limit.
- The API builds the self-only `mode = create` config by passing a small content
  descriptor through the existing `quod_app:build_ns_config/1`, then adding the
  internal, already-compiled `genesis_diff` value. The descriptor copies the resolved
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
  boot-config and runtime creation. Runtime creation passes `genesis_diff`, so
  namespace start never rereads or recompiles caller input. The builder compiles
  only its generated incarnation/member facts and prepends them to the prepared
  diff in one linear pass. `genesis_file` and `genesis_diff` are mutually
  exclusive; both together are a loud configuration error.
- Creation starts through a small atomic namespace-manager operation,
  `start_new_content/2`, never directly through `quod_ns_sup`. The manager
  accepts the call only if the namespace is neither desired nor live. It starts
  the child while no desired entry exists, validates the resulting 32-byte
  genesis anchor, and only then persists the config and publishes the
  explorer's data-directory entry before replying with that anchor. A start
  result of
  `{error, {already_started, Pid}}` is a collision, not success: the manager
  returns `already_configured`, because the surviving child may have been
  started under a different config. The same classification covers an
  `already_present` child spec. An
  undesired-but-still-running child left by an earlier failed stop is also a
  collision, never adopted under the new config. If the
  namespace was already desired, it likewise returns `already_configured`
  without touching or stopping it. A failed start or anchor validation stops
  only the just-started child, admits no desired entry, publishes nothing, and
  schedules reconciliation only if that cleanup itself fails. A manager crash
  before persistence leaves an undesired child that reconciliation removes; a
  crash after persistence is completed by the same validated reconciliation
  path. Ordinary boot continues to use `start_content/2`.
- `start_new_content/2` deliberately skips `maybe_notify_directory`: this slice
  creates a local/private ontology and has no directory-advertisement feature.
  Existing boot and reconciliation paths retain their current notifications.
- The namespace manager is the sole writer of the explorer's data-directory
  projection. Normal starts and reconciliation also validate each live
  content anchor before publication; reconciliation batches all map additions
  into one environment update. Stopped ontology entries remain available for
  read-only ledger inspection.
- The API checks the local ledger before start.  A fresh slot-0/no-log path
  returns `created`; an existing valid slot-1 path returns `resumed`.  In the
  latter case the supplied options are not applied and the explicit result prevents
  a caller from mistaking resume for a new creation.

The namespace manager durably checkpoints the configurations it admitted
through `start_new_content/2`. A whole application restart reloads that
node-local desired set and reopens each existing ledger at its exact genesis
anchor. Static content configuration overrides a same-name checkpoint at boot.
The checkpoint is not a replicated ontology catalogue and grants no network
authority; it records only what this node deliberately hosts. An explicit
`stop_content/1` removes the corresponding checkpoint before stopping it.

## Authorized action runner

Root declares creation as an ordinary policy action:

```prolog
ontology_hosted(Name) :- ontology_join_state(Name, starting).
ontology_hosted(Name) :- ontology_join_state(Name, joining).
ontology_hosted(Name) :- ontology_join_state(Name, ready).

action(create_ontology(Name, Options),
       [authorized_ontology_lifecycle(create_ontology(Name, Options)),
        ontology_join_state(Name, not_hosted)],
       ontology_hosted(Name)).
```

The public node-local entry is:

```erlang
quod_prolog:run_action(
  <<"quod:root">>,
  {create_ontology, Name, Options}).
```

It accepts only a fully ground `create_ontology/2` or `join_ontology/3` action
targeting `quod:root`. The engine derives `node(NodePublicKey)` from its own
identity and stores it only in the private proof overlay; callers and Prolog
cannot provide or forge that principal. Root policy authorizes creation only
when that key is currently self-admitted in the committed root snapshot.

The bounded action worker first validates the exact transition declaration and
authorizes the engine-owned principal before reading caller-selected source
paths. It compiles the source once into an opaque prepared descriptor, then a
read-only Prolog preparer checks the selected desired state or the declaration's
ordered prerequisites. The first attempted assert, retract, or abolish fails
even if later backtracking would have left an empty diff. The runner
re-authorizes before either idempotent success or execution; execution invokes
only the typed prepared helper once and verifies `ontology_hosted(Name)`
afterward. A missing valid declaration fails as `action_not_declared`; a staged
write fails as `lifecycle_staged_write` and executes nothing.

The low-level `quod_ontology:create/2` API remains available to trusted code in
the same VM. It does not authenticate remote callers and must not be exposed as
a network authorization boundary.

The lifecycle-specific creation vocabulary includes:

```prolog
ontology_creation_failed(invalid_arguments)
ontology_creation_failed(root_only)
ontology_creation_failed(not_authorized)
ontology_creation_failed(action_not_declared)
ontology_creation_failed(invalid_name)
ontology_creation_failed(reserved_system_namespace)
ontology_creation_failed(invalid_options)
ontology_creation_failed(invalid_initial_terms)
ontology_creation_failed(initial_content_too_large)
ontology_creation_failed(invalid_source(OptionIndex, Line))
ontology_creation_failed(source_file_error(OptionIndex))
ontology_creation_failed(already_hosted)
ontology_creation_failed(start_failed)
```

It does not copy arbitrary Erlang error terms into failure reasons: child-start errors
may contain PIDs, references, paths, or other non-portable implementation
details. The Erlang API retains its detailed `{error, Reason}` for operators;
the typed executor maps that result to the bounded, always-ground public reason
above. Generic runner states such as `busy`, `rebuilding`, or
`action_declaration_failed` remain explicit engine errors, and an ambiguous
manager/action-worker completion is `{error, outcome_unknown}` rather than a
definite failure reason. The existing Erlog failure-reason stack remains available while proving
prerequisites; post-proof executor errors are returned explicitly in the same
bounded term shape. There is no second error stack.

Normal `prove/2`, `prove_ro/2`, selected scopes, the explorer prove endpoint, and
ordinary `goal(create_ontology(...))` proofs cannot execute lifecycle IO. The
complete action must be ground before the worker starts. Ground facts can be
supplied with `terms/1`; rules containing variables should use `source/1` or
`source_file/1`, where variables are parsed inside the new ontology rather
than being caller variables.

## Explicit non-goals

- No root `ontology/2` fact and no replicated catalogue.
- No replicated hosting catalogue or automatic hosting on another node.
- No directory advertisement: private reachability remains local/direct-seed.
- No user/agent identity or ownership, payment, atom-capacity, deletion,
  transfer, or remote membership design beyond the node-local
  self-admitted-validator policy.
- No default remote ACL or `can_join/3`: apart from the injected local
  host-entry rule, the supplied initial terms define the ontology's policy. A
  test that needs remote or cross-ontology calls includes the corresponding
  `can_invoke/4` rule.

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
   unchanged. A failed admission proves that the manager never records the new
   desired entry and schedules no reconciliation retry when cleanup succeeds.
   An undesired live child proves that supervisor collisions are not adopted or
   stopped; `already_started` and `already_present` receive the same collision
   classification.
5. `quod_prolog:run_action/2` accepts the ground root action and calls the same
   API only after the committed root policy authorizes the engine-owned node
   principal. Wrong scope, invalid input, missing action declaration,
   non-membership, collision, and start errors return the matching bounded
   `ontology_creation_failed/1` reason.
6. Ordinary proof contexts and the removed low-level effect functor perform no
   lifecycle IO. The monitored action worker rejects both staged writes and a
   policy that attempts any mutation; the executor's second authorization
   still rejects a declaration from which the visible policy prerequisite was
   removed. Any action-worker loss conservatively reports `outcome_unknown`,
   because the engine does not maintain a second phase-tracking framework.
7. Repeating the API against an existing ledger returns `resumed` and does not
   append a second genesis block or silently apply new initial terms.
8. Reconciliation republishes an already-running desired namespace only after
   re-validating its genesis anchor.

Run focused EUnit/CT for this path, then the full release gate before commit.
