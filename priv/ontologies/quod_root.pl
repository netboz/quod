%% quod:root — the root ontology.
%%
%% This is the SEED content the founding node reads once at network creation and
%% commits into the ledger as the genesis. After birth it lives in the replicated
%% ledger; joining nodes sync it and never re-read this file. Modeled on onia_root.pl.

%% The ACL authority anchor for this network (exactly one).
acl_sovereign('quod:root').

%% Default-open reads. Load-bearing: with no can_read/3 clause every read
%% fail-closes (unknown-predicate ⇒ deny). Narrow this per-ontology as needed.
can_read(_Goal, _Subject, _Ns).

%% Admission rule proved when a node asks to join this namespace's committee. Proved TWICE: once by
%% the submitting node (via the `admit` predicate), then re-proved by EVERY validator against its own
%% kb before it will support-sign the membership change (`quod_prolog:request_membership_verdict/5`) —
%% so admission is a decision of the committee, not the submitter. Goal shape: `can_join(Ns, [Host, Port],
%% Pubkey)` — arg 2 is `[Host, Port]`, arg 3 the advertised pubkey (== NodeId at this stage).
%% Default-open (any node may join). Load-bearing like can_read: with NO clause, a join fail-closes
%% (the re-proof fails → invalid). It must be **side-effect-free** — a `can_join` that stages a write is
%% rejected network-wide (the proof overlay would ride its ops into the committed membership diff). Narrow
%% to an allowlist / signature check once membership signing (Phase B) lands.
can_join(_Ns, _JoinerId, _Info).

%% The system-ontology registry: system_ontology(Name, PlFile, ExternalPreds, Flags).
%% Root declares itself; further system ontologies are added when the cascade lands.
system_ontology('quod:root', 'quod_root.pl', [], []).
