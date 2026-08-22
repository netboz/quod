%% quod:root — the root ontology.
%%
%% This is the SEED content the founding node reads once at network creation and
%% commits into the ledger as the genesis. After birth it lives in the replicated
%% ledger; joining nodes sync it and never re-read this file. Modeled on onia_root.pl.

%% The ACL authority anchor for this network (exactly one). `quod:root` is the
%% structured name form — `:` reads "belongs-to" (doc/inter-ontology.md §2): the
%% ontology `root`, owned by `quod`.
acl_sovereign(quod:root).

%% Default-open invocation. The rule sees the whole call chain at once — a
%% restrictive policy relates its members itself rather than judging them one at
%% a time. `Principal` is engine-owned (`{node, NodeKey}`, `{user, PublicKey}`
%% or `anonymous`);
%% a refusal is ordinary failure carrying not_allowed(Ns).
%%
%% NOTE: this is not the whole effective policy. Founding injects a generated
%% bodyless host-entry clause `can_invoke(_, _, [], _)` into EVERY genesis, so a
%% proof entered on the host itself (an empty call chain) is always admitted and
%% cannot be locked out by narrowing this clause. Author clauses here govern
%% remote and cross-ontology callers (a non-empty chain); with none, an ontology
%% is host-answerable and otherwise closed. This root ships open to all so it is
%% queryable fleet-wide.
can_invoke(_Goal, _Principal, _CallChain, _Ns).

%% Root is the one ontology every node starts before it can execute durable
%% effects, so it owns the node-wide custody capacity without a bootstrap
%% fallback. With no override the effective capacity is 64. An operator may
%% call the setter or atomically replace the single override fact; there is no
%% compiled maximum, and `unlimited` is explicit.
effect_custody_capacity(Capacity) :-
    effect_custody_capacity_override(Capacity).
effect_custody_capacity(64) :-
    \+ effect_custody_capacity_override(_).

valid_effect_custody_capacity(unlimited).
valid_effect_custody_capacity(Capacity) :-
    integer(Capacity),
    Capacity >= 0.

set_effect_custody_capacity(Capacity) :-
    valid_effect_custody_capacity(Capacity),
    abolish(effect_custody_capacity_override/1),
    assertz(effect_custody_capacity_override(Capacity)).

%% This founding handler projects D into the one node-wide journal before E.
%% The bridge receives the complete solution list and fails loudly unless the
%% effective policy has exactly one valid value.
state_handler(effect_custody_capacity_projection,
              [effect_custody_capacity_override/1], [],
              reconcile_effect_custody_capacity).

reconcile_effect_custody_capacity(Scope) :-
    findall(Capacity, effect_custody_capacity(Capacity), Capacities),
    '$quod_project_effect_custody_capacity'(Capacities, Scope).

%% Root governs the creation of new ontology identities. The node which authors
%% the accepted root transaction remains the direct-effect executor and
%% initially hosts the new ontology; other nodes join that exact identity
%% through quod:node.
ontology_hosted(Name) :- ontology_join_state(Name, starting).
ontology_hosted(Name) :- ontology_join_state(Name, joining).
ontology_hosted(Name) :- ontology_join_state(Name, ready).

action('$quod_stage_ontology'(Handle, create_ontology(Name, Options),
                              ontology_hosted(Name)),
       [current_principal(Agent),
        can_create_ontology(Agent, Name, Options),
        ontology_join_state(Name, not_hosted)],
       ontology_hosted(Name)).

%% The current browser convenience is ordinary Prolog over generic creation.
%% It has no lifecycle action, effect kind, or Erlang dispatcher of its own.
create_user_home :-
    current_principal(user(PublicKey)),
    user_home_genesis(PublicKey, Name, Options),
    create_ontology(Name, Options).

%% First-slice creation policy. An admitted root validator may found a general
%% ontology. Transitional browser registration remains narrow:
%% `user_home_genesis/3` accepts only the deterministic namespace and fixed
%% genesis derived from the authenticated Ed25519 key.
can_create_ontology(node(NodeKey), _Name, _Options) :-
    peer_admitted(NodeKey, _, _, NodeKey).

can_create_ontology(user(PublicKey), Name, Options) :-
    user_home_genesis(PublicKey, Name, Options).

%% Admission rule proved when a node asks to join this namespace's committee. Proved TWICE: once by
%% the submitting node (via the `admit` predicate), then re-proved by EVERY validator against its own
%% kb before it will support-sign the membership change (`quod_prolog:request_membership_verdict/5`) —
%% so admission is a decision of the committee, not the submitter. Goal shape: `can_join(Ns, [Host, Port],
%% Pubkey)` — arg 2 is `[Host, Port]`, arg 3 the advertised pubkey (== NodeId at this stage).
%% Load-bearing like can_invoke: with NO clause, a join fail-closes (the re-proof fails → invalid). It must
%% be **side-effect-free** — a `can_join` that stages a write is rejected network-wide (the proof overlay
%% would ride its ops into the committed membership diff).
%%
%% The gate: `peer_ready` (a read-only external predicate) is true iff the judging node has a fresh feed
%% digest from the candidate at (near) its own height — provably alive and caught up. A dead or lagging
%% candidate is REFUSED instead of freezing a small (quorum = all) committee. Validators may split on it
%% (each observes liveness independently); that fail-closes the slot and the submitter retries. It is
%% liveness UX, not a security boundary (the height claim is unauthenticated) — narrow further with an
%% allowlist / signature check once membership signing (Phase B) lands.
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

%% System ontologies are created through the ordinary lifecycle first.  Once
%% their exact genesis anchor is known, root may register them as:
%%
%% system_ontology(Name, GenesisAnchor).
%%
%% Root itself is the configured bootstrap exception and is never listed here.
%% A catalogue row contains no endpoint, source file, module name, or runtime
%% option. Nodes join the exact recorded history through normal routing; that
%% ontology's immutable genesis carries its own hashed predicate-module
%% manifest.
