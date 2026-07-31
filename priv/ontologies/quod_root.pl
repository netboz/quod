%% quod:root — the root ontology.
%%
%% This is the SEED content the founding node reads once at network creation and
%% commits into the ledger as the genesis. After birth it lives in the replicated
%% ledger; joining nodes sync it and never re-read this file. Modeled on onia_root.pl.

%% The ACL authority anchor for this network (exactly one). `quod:root` is the
%% structured name form — `:` reads "belongs-to" (doc/inter-ontology.md §2): the
%% ontology `root`, owned by `quod`.
acl_sovereign(quod:root).

%% Default-open reads. Load-bearing: with no can_read/3 clause every read
%% fail-closes (unknown-predicate ⇒ deny). Narrow this per-ontology as needed.
can_read(_Goal, _Subject, _Ns).

%% Node-local ontology lifecycle. The external operation is the final ordered
%% prerequisite; the action effect is true because hosting state is volatile on
%% this node and must not be asserted into root's replicated ledger.
action(create_ontology(Name, Options),
       [ontology_join_state(Name, not_hosted),
        create_ontology_effect(Name, Options)],
       true).

action(join_ontology(Name, GenesisHash, Seeds),
       [ontology_join_state(Name, not_hosted),
        join_ontology_effect(Name, GenesisHash, Seeds)],
       true).

%% Admission rule proved when a node asks to join this namespace's committee. Proved TWICE: once by
%% the submitting node (via the `admit` predicate), then re-proved by EVERY validator against its own
%% kb before it will support-sign the membership change (`quod_prolog:request_membership_verdict/5`) —
%% so admission is a decision of the committee, not the submitter. Goal shape: `can_join(Ns, [Host, Port],
%% Pubkey)` — arg 2 is `[Host, Port]`, arg 3 the advertised pubkey (== NodeId at this stage).
%% Load-bearing like can_read: with NO clause, a join fail-closes (the re-proof fails → invalid). It must
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
