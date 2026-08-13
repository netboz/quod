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
%% NOTE: this is not the whole effective policy. Founding injects an invisible
%% bodyless host-entry clause `can_invoke(_, _, [], _)` into EVERY genesis, so a
%% proof entered on the host itself (an empty call chain) is always admitted and
%% cannot be locked out by narrowing this clause. Author clauses here govern
%% remote and cross-ontology callers (a non-empty chain); with none, an ontology
%% is host-answerable and otherwise closed. This root ships open to all so it is
%% queryable fleet-wide.
can_invoke(_Goal, _Principal, _CallChain, _Ns).

%% Node-local ontology lifecycle. Prolog proves authorization and hosting state,
%% then records a typed effect in a root transaction with an empty fact diff.
%% The local effect journal performs the external operation only after that
%% transaction is durably ordered and applied.
ontology_hosted(Name) :- ontology_join_state(Name, starting).
ontology_hosted(Name) :- ontology_join_state(Name, joining).
ontology_hosted(Name) :- ontology_join_state(Name, ready).

ontology_joined(Name, GenesisHash) :-
    ontology_hosted(Name),
    ontology_genesis_anchor(Name, GenesisHash).

action(create_ontology(Name, Options),
       [authorized_ontology_lifecycle(create_ontology(Name, Options)),
        ontology_join_state(Name, not_hosted)],
       ontology_hosted(Name)).

action(join_ontology(Name, GenesisHash, Seeds),
       [authorized_ontology_lifecycle(
            join_ontology(Name, GenesisHash, Seeds)),
        ontology_join_state(Name, not_hosted)],
       ontology_joined(Name, GenesisHash)).

%% First-slice host authority: a node may change only its own hosting state and
%% only while its key is a currently admitted validator of quod:root.
can_create_ontology(node(NodeKey), _Name, _Options) :-
    peer_admitted(NodeKey, _, _, NodeKey).

%% Open registration is intentionally narrow. `user_home_genesis/3` is an
%% engine query predicate that accepts only the deterministic namespace and
%% fixed genesis options derived from this exact Ed25519 key. It cannot accept
%% a user-selected name, source file, or arbitrary initial policy.
can_create_ontology(user(PublicKey), Name, Options) :-
    user_home_genesis(PublicKey, Name, Options).

can_join_ontology(node(NodeKey), _Name, _GenesisHash, _Seeds) :-
    peer_admitted(NodeKey, _, _, NodeKey).

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

%% The system-ontology registry: system_ontology(Name, PlFile, ExternalPreds, Flags).
%% Root declares itself; the real system ontologies (quod:user, quod:node, ... — the
%% network's own infrastructure knowledge, to be specified from the onia/bbsvx
%% reference material) are added when they are authored. Demo/user-level ontologies
%% (animals, pets) are NOT system ontologies and do not belong in this registry.
system_ontology(quod:root, 'quod_root.pl', [], []).
