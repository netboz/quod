# External predicate refusal audit

This table classifies every bare `erlog_int:fail` in `src/predicates` in the
2026-10-09 input tree, before the edits below. Locations are input-tree line
numbers (the ontology helper move adds one line). The hot-control table in
`failure-reasons-design.md` supplies the physics rows; the three retained
physics failures are signature/binding mismatch, signed goal/scope mismatch,
and absent reaction metadata. Policy denial remains ordinary failure.

`false` means no solution, `refusal` records a portable reason through the
shared helper, and `error` uses the existing Erlog error channel. Missing
managed context is the documented exception; absent private metadata is a
valid non-match. An installed managed context missing a required identity
is a refusal. Internal continuation failures preserve existing reasons.

| Module: input line | Condition | Class and resulting contract |
|---|---|---|
| ontology:66 | no signer in this engine | false; no signer-bound context |
| ontology:147 | prepared anchor does not unify with requested anchor | false |
| ontology:188 | authenticated agent cannot materialize | error `invalid_authenticated_principal` |
| ontology:191 | handler called with wrong functor | error `domain_error(principal_query,Goal)` |
| ontology:282 | requested ontology not hosted | refusal `ontology_anchor_failed(not_hosted)` |
| ontology:297 | valid anchor differs from committed anchor | false |
| agent:40 | local node actor absent | refusal `node_actor_unavailable` |
| agent:55 | signing from writable proof | error `context_violation(sign_agent_request,query,write_proof)` |
| agent:74 | instance text and agent reference disagree or malformed | error `domain_error(agent_request,Typed)` |
| agent:76 | executing scope identity absent | refusal `scope_identity_unavailable(Ns)` |
| agent:76 | request scope differs from executing scope | error `context_violation(sign_agent_request,query,foreign_scope)` |
| agent:76 | request cannot encode | error `domain_error(agent_request,Typed)` |
| agent:76 | node actor absent | refusal `node_actor_unavailable` |
| agent:78 | request unbound | error `instantiation_error` |
| agent:78 | request wrong shape | error `domain_error(agent_request,Typed)` |
| agent:98 | vault refuses signature release | refusal `agent_signing_unavailable(Reason)`; closed vault reason vocabulary |
| agent:100 | signing policy denies | false |
| agent:100 | signing policy evaluation errors | error `invalid_signing_policy`; never deny |
| agent_work:22 | instance not ground | error `instantiation_error` |
| agent_work:22 | wake unbound | error `instantiation_error` |
| agent_work:22 | wake outside changed/continue | error `domain_error(agent_work_wake,Wake)` |
| committee:80 | namespace absent | false; no managed context |
| committee:81 | committee at encoding ceiling | refusal `committee_full`; MAX_VALIDATORS is an existing shared protocol bound; its value and ownership are unchanged |
| committee:88 | public key unbound | error `instantiation_error` |
| committee:88 | public key not binary | error `type_error(binary,Pub)` |
| committee:103 | would remove last existing member | refusal `last_committee_member` |
| committee:103 | key not a member | false; also at floor |
| committee:106 | public key unbound/wrong type | same argument errors as admit |
| committee:124 | peer not caught up/live | false; observational readiness relation |
| committee:126 | namespace/height absent | false; no managed context |
| committee:129 | public key unbound/wrong type | same argument errors as admit |
| common:78 | invalid chunk size in pre-existing uncommitted source-chunk feature | outside this commit; preserve the feature owner's baseline; required instantiation/type/domain classification belongs with that feature |
| common:135 | source indicator unbound | error `instantiation_error` |
| common:135 | source indicator malformed | error `domain_error(predicate_indicator,Indicator)` |
| common:145 | exact authored clause absent | false |
| common:211 | draw salt unbound | error `instantiation_error` |
| common:211 | salt not portable | error `domain_error(proof_salt,Salt)` |
| common:214 | draw divisor unbound/wrong type/nonpositive | instantiation/type(integer)/domain(proof_draw_divisor) error |
| common:214 | draw has no proof identity | false; no proof session/verdict context |
| common:252 | codes contain variables | error `instantiation_error` |
| common:252 | list contains nonbytes | error `domain_error(byte_list,Codes)` |
| common:255 | both arguments unbound | error `instantiation_error` |
| common:255 | codes not list | error `type_error(list,Codes)` |
| common:258 | first argument not binary/variable | error `type_error(binary,Binary)` |
| physics signed request | selected goal cannot encode as a bounded durable term | error `domain_error(signed_goal,Goal)`; encoded variables remain valid, signature/goal mismatch remains false |
| directory:50 | ontology name unbound | error `instantiation_error` |
| directory:50 | ontology name malformed | error `domain_error(ontology_name,Name)` |
| directory:53 | directory queried outside root | error `context_violation(directory_host,query,non_root)` |
| directory:70 | control peers queried outside root | error `context_violation(directory_control_peer,query,non_root)` |
| ask:58 | handler receives wrong functor | error `domain_error(ontology_query,Goal)` |
| ask:69 | follower already answered this call | false |
| ask:137 | target stream exhausted | false; merges target reasons unchanged |
| transaction:53 | event not ground | error `instantiation_error` |
| transaction:53 | event outside durable event domain | error `domain_error(event,Term)` |
| transaction:113 | independent continuation redo | false; restores mode and resumes alternatives |
| transaction:118 | independent alternatives exhausted | false; restores ordinary intent |
| action:119 | state-check redo | false; read-only scope preserved |
| action:124 | state-check exhausted | false; restores writable scope |
| action:178 | callable/action-shape recognition false | false; pure recognizers select authored action candidates |
| runtime:65 | required scope identity absent | refusal `scope_identity_unavailable` |
| runtime:104 | stored digest differs from signed digest | false; exact request matching relation |
| runtime:113 | signature/operation scope mismatch | false |
| runtime:113 | scope identity absent | refusal `scope_identity_unavailable` |
| runtime:132 | no signed expiry/reaction metadata | false; no metadata context |
| runtime:142 | reaction metadata absent | false; no metadata context |
| runtime:142 | expiry unbound/wrong type/nonpositive | instantiation/type(integer)/domain(request_expiry) error |
| runtime:142 | expiry above owner ceiling | false; requested constraint exceeds policy |
| runtime:151 | observation absent or owner differs | false; authenticated observation relation |
| runtime:167 | recovery metadata absent or exact owner/epoch mismatch | false; eligibility relation |
| runtime:167 | required target or epoch unbound in matching metadata | error `instantiation_error` |
| runtime:167 | custody target/epoch/result malformed in matching metadata | error `domain_error(agent_custody,Arguments)` |
| runtime:177 | physics preparation metadata absent | false; no metadata context |
| runtime:177 | signed preparation holes/template malformed | error `domain_error(signed_preparation,Template)` |
| runtime:275 | prepared variable absent from selected goal | error `domain_error(preparation_goal,Goal)` |
| runtime:280 | signed preparation/selected goal invalid | error `domain_error(preparation_goal,Goal)` |
| runtime:284 | unrelated generic reaction lacks physics custody | false; declaration ineligible |
| runtime:318 | resource scope not ground | error `instantiation_error` |

Operation-outcome infrastructure errors remain errors, including the monotonic
sealing veto when caught, as required by `doc/multiwrite-architecture.md`.
Vault signing does not submit an action; its bounded unavailability refusal
cannot imply an uncertain action resubmission. Transient release exits do.

The input tree's documented plain-failure behavior for draw and byte conversion
is superseded by Yan's ruling. Pure recognition relations and engine-owned
search continuations remain false goals. The later lifecycle table also
classifies already reasoned validation sites against the same contract.

## Hot-control decisions checked against implementation

The handoff's normative section has moved to `doc/proofs.md`. Definite release
refusals become `{fail,[Reason]}`; caught exits become `{unknown,owner_unavailable}`
in the internal effect reply and remain request errors. Navigation invalidation
is checked before any active-world admission, returning `reinstalling` for
inputs. A nonactive world refuses input as `physics_world_unavailable`.

The inspection also found an expected checkpoint sequence conflict and missing
push allowances. They now record `checkpoint_conflict(Body)` and
`push_allowances_missing(Body)` respectively. The input control lookup records
`control_conflict(CurrentEpoch)` for a stale binding epoch and `no_control(World)`
for no selection, retaining plain permission denial within agent configuration.
Malformed bridge-returned limits raise `domain_error(physics_limits,Limits)`;
frame shape includes its anchored authority and positive generation/revision.

The owner-side liveness vocabulary is independent of a valid read answer
`unavailable`. A read timeout has no action consequence; a release timeout may
have one. Neither path resubmits a request.

Additional singleton checks on the hot-control path reject multiple binding,
rest-state, or rest-custody rows with `ambiguous_control(World)`,
`ambiguous_checkpoint(Body)`, or `ambiguous_checkpoint_custody(Body)`. These
are authored configuration refusals, not ordinary no-solution queries. Their
signed-ingress assertions sit beside the other policy-reason rows.

The shared dispatcher's missing-descriptor branch is also an engine contract
error in a managed context: `context_violation(Functor,unregistered,Kind)`.
An unmanaged engine still fails plainly. This closes the fallback next to the
shared helper; it does not grant access to an unregistered bridge.

A sample projection also requires a positive integer body revision; malformed
policy returns raise `domain_error(physics_body_revision,Revision)`. A valid
positive revision with no installed sample still binds `unavailable`, tested
by decoding the actual normalized answer binding.

## Existing lifecycle reasons checked against the new contract

These sites already had reasons, so the bare-fail enumeration did not find
them. Yan's error ruling still applies. The table below precedes their edits;
ordinary permission prerequisites and operational owner refusals retain their
existing reasons.

| Site | Condition | Class and resulting contract |
|---|---|---|
| lifecycle request validation | required request fields not ground | error `instantiation_error` (creation's output anchor remains a variable) |
| lifecycle request validation | malformed typed action/name/options/seeds/anchor | error `domain_error(ontology_action,Action)` |
| lifecycle request owner | action belongs to another ontology | error `context_violation(Functor,staging,wrong_ontology)` |
| lifecycle continuation | opaque handle not registered for exact action | error `domain_error(ontology_request_handle,Handle)` |
| lifecycle continuation | malformed action or wrong handler goal | error `domain_error(ontology_action,Action)` |
| lifecycle preparation | malformed initial terms/source program | error `domain_error(ontology_action,Action)` |
| lifecycle preparation | engine-owned structural descriptor invalid | error `system_error(invalid_lifecycle_descriptor)` |
| lifecycle preparation | already hosted, source-file I/O, capacity or startup unavailable | retain existing bounded lifecycle refusal vocabulary |
| lifecycle staging | prepared anchor differs from supplied valid anchor | ordinary unification failure |
| lifecycle staging | required action/desired-state fields not ground | error `instantiation_error` |
| lifecycle staging | exact request action changed | error `domain_error(ontology_action,Action)` |
| lifecycle staging | prepared-effect construction violates contract | error `system_error(invalid_prepared_effect)` |
| lifecycle staging | executor not installed | retain `ontology_*_failed(rebuilding)` |
| ontology state/anchor query | required name not ground | error `instantiation_error` |
| ontology state/anchor query | malformed name or query goal | error `domain_error(ontology_name,Name)` / query domain |
| ontology anchor match | malformed bound anchor | error `domain_error(genesis_anchor,Value)` |
| ontology anchor match | valid different anchor | ordinary failure |

Singleton helpers check row cardinality with fresh variables, then unify the
selected row with caller arguments. A valid unequal value stays ordinary
failure. Required allowance lookups retain all authored alternatives; only an
empty configuration records a missing reason. Input control is selected once
before motion or push limits, so a failed push cannot duplicate its control
refusal. A read whose caller deadline already expired records `expired`, not
an unavailability claim about an owner it never called.
