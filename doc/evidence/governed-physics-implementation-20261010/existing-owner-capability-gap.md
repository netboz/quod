# Retained ontology capability activation: architecture gap

Status: historical, unapproved proposal. Its interactive approval question was
cancelled. Yan's subsequent system-predicate correction invalidates the claim
below that a per-ontology capability epoch is necessarily missing: shared
startup registration already exists in `quod_predicates:load/1` and
`quod_committed_projection:new_est/0`. Physics is not currently registered
there, but registration itself allocates no simulation. Evaluate that simpler
composition first, retaining Prolog authorization and resource policy. The
earlier proposal is preserved below to explain its review evidence; it is not
the selected implementation plan.

The current contract places a world's authority instance and physical state in
that world's ontology (`doc/world.md`, authority and restart fencing). There is
no demonstrated independent governance/lifecycle reason to move this personal
lobby's authority into another ontology. Missing a bridge in its founding
manifest is insufficient justification for that boundary. This proposal keeps
the existing owner and requires no compatibility implementation.

## Demonstrated gap

`quod_lobby:lobby_options` normally founds a personal lobby with only
`quod_agent_predicates`. `quod_committed_projection:prepare_genesis_modules`
loads that retained manifest at slot 1; `quod_commit_validation` rejects changes
to `external_predicate_modules/1` in ordinary and prepared commits.
Updating a package or declaring `physical_space` cannot add the missing physics
bridge to that ontology. The current signed personal lobby's actual manifest
and identity still need to be read; the factory and historical evidence do not
identify its retained state.

If that manifest lacks physics, the existing lifecycle owner has no approved
transition for adding the capability while preserving founding provenance.
The concrete missing capability is a root-authorized, versioned effective
native profile, installed through a cold coordinated release. Implementation
of this foundational transition requires the architecture/deployment gate in
the task. The removed mutable-module selection/reconciliation experiment is
not its implementation.

## Proposed bounded contract for local implementation

Keep the founding `external_predicate_modules/1` record immutable as provenance.
Introduce one authoritative desired native-profile epoch at the target, using
an exact `ontology_ref(Namespace, GenesisAnchor)`. An ordinary root-authorized
Prolog action compares its expected epoch and approves an exact released profile
(ordered capabilities/modules, registry/code digest and participating validator
profile). Root holds the authorization receipt; target holds desired capability
state. Class membership, viewing and simulation enablement grant no capability
installation, control or allocation by themselves.

The root receipt and target transition must be one existing sealed atomic
transaction. Extend the current lifecycle/action and commit-validation owners
to authenticate that exact authorization and reject arbitrary target writes to
the effective-profile record. Domain approval belongs to root/target Prolog;
Erlang verifies the bound lifecycle/provenance evidence and implements native
installation. A package filename, asserted class or caller-supplied principal
cannot substitute for that evidence.

Replace genesis-manifest-only composition with this single effective-profile
contract for all upgraded scopes. Genesis still records original provenance;
the applicable release explicitly prepares retained scopes through authorized
append-only transitions. There is no old/new execution branch, absent-record
fallback or automatic ledger migration. The effective profile cannot be hot
swapped in a running proof engine. A coordinated cold release quiesces all
participating validators, proof engines and projection consumers, then recovers
their retained histories with the same approved profile and registry.

Proof/session, prepared-effect and installation fences must bind the effective
epoch/profile in addition to ontology identity and existing custody. Competing
installations, edits, admission and withdrawal use current per-predicate OCC;
stale proofs cannot authorize a new registry. Matching compatible validators
for this deployment creates no permanent compatibility path.

Commit and actual registry installation remain distinct. The existing owner
publishes incarnation-scoped installation notices; consumers await those notices
under original deadlines. Only subsequently enabled, authorized, budgeted Prolog
physics selections may allocate a native world. A nonphysical or disabled space
allocates none. An unavailable controlled body remains unavailable.

Before commit, failed authorization/preparation rolls back the atomic transition.
After commit, rollback is an explicitly authorized newer epoch selecting the
prior released profile, with another coordinated cold gate; it never rewrites
history. Recovery restores the current committed epoch, profile, control/custody
and body references. Uncertain installation operations resolve their original
identity. Withdrawal must revoke dependent authority/control and capability in
the same authorized atomic transition, followed by owner retirement notices;
there is no post-commit data repair or inferred simulation handoff.

## References and acceptance boundary

The concrete live values remain unverified. The baseline must bind the current
signed acting `agent_instance_ref`, visible `world_ref`, authority
`agent_instance_ref`, source `instance_ref` and scoped body ID/revision to their
actual namespace/genesis anchors and current history tips. No old or system
lobby anchor is substituted. Local tests can use explicitly founded identities;
they cannot fill this baseline.

Ratifying this proposal authorizes local implementation/testing of the new
capability-evolution contract. Deployment, release-profile activation and live
ledger changes remain with the existing release authority and a single writer.
The task stays open until its own remote propagation/work measurements and
signed desktop acceptance in the preserved actual lobby pass.
