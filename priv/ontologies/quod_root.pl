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

%% Admission rule the leader proves when a node asks to join this namespace's committee.
%% can_join(Ns, JoinerId, Info) — default-open (any node may join). Load-bearing like
%% can_read: with no clause, a join fail-closes. Narrow to an allowlist / signature check
%% once node identities (pubkeys) are wired. JoinerId = [Host, Port]; Info = advertised
%% pubkey (`none` in Phase 1).
can_join(_Ns, _JoinerId, _Info).

%% The system-ontology registry: system_ontology(Name, PlFile, ExternalPreds, Flags).
%% Root declares itself; further system ontologies are added when the cascade lands.
system_ontology('quod:root', 'quod_root.pl', [], []).
