# Replacement coverage and review disposition

Implementation is in progress. These are verification obligations, not release clearance.

The source-repair test module `quod_lobby_setup_tests` is retired with
`complete_lobby_setup`. Its valid obligations move to the complete factory and
shared initialization tests: owner and exact-anchor refusal, revoked setup,
atomic first assignment/admission/control, stale competing edits, and unchanged
preparation. Source preservation and conflict behavior remain covered by the
ordinary source editor tests. Old histories are not silently repaired.

`quod_lobby_tests` now tests the shared space view and ordinary Eidolon selection.
Its source/GUI fixture is an authored information space with decorative poses;
it does not claim native physics acceptance. Complete physical defaults and
local live-definition bindings are tested through the lifecycle and physics
owners. The first-host test exercises the same `physics_initialize` in gallery
and workshop ontologies with different gravity.

The Fable custody consultation completed successfully in solution-consult-04.
Its conditions were checked against active-key authorization in `quod_ask`,
assignment revocation in `agent_instance.pl`, resolve-only signed ingress, and
the cancellation action. Cancellation originally required stored inner custody;
the implementation extends that action to fence a valid exact pending request
before the outer store has committed. The physics selector observes that fence
through its current-custody consistency read. No elapsed time retires a request.

Observation custody uses the existing physical frame/generation and activity
revision fences. A restarted native owner cannot produce a measurement until
its fresh activation commits; old-frame observation stores cannot establish
custody for that new generation. Activation is the request that can be
re-created against the same prior state after restart, so its outer request is
retained by the existing key vault.

The complete founding initially failed at the codec's fixed 20,000-node quota
(20,213 nodes, 77,752 native diff bytes). Individual operations were valid. Failed
runs and bounded diagnostic results are retained under the implementation build
evidence. The refactor removes the redundant node counter; protocol byte bounds,
structural depth, symbol checks, atom safety and root prepared-effect admission
remain. Canonical encodings are unchanged. Fable's completed implementation
review accepted this refactor, subject to the boundary audit below and the
candidate's clean, uniformly pinned deployment.

An additional Fable codec consultation was rejected by automatic approval review
before execution because it would share repository source and architecture.
Yan subsequently approved sharing the relevant source, docs, tests and diffs;
final-review-01 completed successfully with unchanged inputs. The rejected
attempt remains preserved and is not counted as a review or gate.

Targeted verification now passes all 20 lobby tests (lobby-suite-02), both
non-lobby initialization fixtures (non-lobby-initialize-check06), complete native
founding/view, and interrupted activation before and after first send. Earlier
fixture failures remain archived: old mark counts, query variable numbering and
public query shape, and a pilot fixture lacking agent classification. These
results do not substitute for the full regression gates or desktop acceptance.

## Final review dispositions

The full Fable report and exact input hashes are in `implementation-review-01`.

- B1: persisted version-specific paths are replaced in the founding helper by
  `/opt/quod/priv/ontologies/...`. Docker exposes the one release directory at
  that stable path. No runtime resolver, fallback or alternate creation path is
  added. Inline source was measured in isolated probes and rejected at 88,061
  answer bytes against the existing 65,536-byte bound; no limit was raised.
- B2: remove authority inequality as a retirement fence. Authority can change
  and return, so that condition is not irreversible. The real-owner test now
  switches authority away and back while the original store is uncertain,
  verifies the exact receipt survives, then cancels it explicitly. The existing
  cancellation and revoked-key exits both pass.
- Remove the codec and parser comments that still mentioned a node quota.
- R1/R2: preserve the conservative lifecycle. A known committed outer store can
  race a stale selection and cause one OCC-refused extra store; it cannot
  overwrite custody or resubmit the uncertain original. A failed receipt write
  remains unresolved until exact cancellation or terminal evidence. These are
  availability/cost limitations, not permission for speculative resubmission.
- R3: `quod_prolog:submit_sealed_plans/6` routes no-write/no-effect proofs to
  `read`, returning bindings without a consensus submission. Explicit finish
  setup can update local account storage; ordinary reconnect only resolves the
  existing journal and does not repeat setup. The button may also appear during
  a transient unavailable physical view.
- R4: the original monotonic agent timer remains the outer deadline, including
  while the vault call is pending. The wall-clock-derived vault budget cannot
  extend that worker's lifetime.
- R5/R6: default policy grants first-host setup; it does not provide a dedicated
  transfer UI or automatically repair a deliberately unusable owner-selected
  key. The ontology owner retains ordinary source/policy editing authority;
  this is not permanent loss of ownership. No fallback grant is introduced.
- R7: the presentation fixture remains explicitly nonphysical. The real
  complete-factory test now edits a local console definition through the signed
  action, verifies the owner and native shape, preserves the owner incarnation,
  and verifies unchanged reconciliation does not reinstall it.
- R8: an operator may inspect the exact network/world/purpose receipt through
  `quod_agent_vault:retained/1`. The ontology owner can submit the existing
  `physics_cancel_activation/3` with that receipt's exact signed inner request.
  Never delete a receipt or resubmit it to clear uncertainty.

## Boundary and behavior evidence

The direct `quod_wire_term:decode/1` production callers are the scope codec
(after bounded `quod_safe_term:decode/2`) and `existing_symbols/1` (a local
round-trip of a term just encoded in the same function). Other external byte
entry points use bounded canonical decoding. Direct encoders consume local
Prolog terms: durable goals/results and scope payloads enforce their enclosing
byte bounds; DTX bindings enter through its bounded safe-term envelope; client
goals enter through the frozen lexer/goal byte limits; diff events and runtime
reaction patterns come from the governed committed program. No new raw
`binary_to_term` or distribution entry is introduced. Root's prepared-effect
policy remains in force for complete ontology creation.

`quod_agent_predicates:prepare_agent_key_custody/3` checks exact scope identity,
read-only context and `local_destination/1`, which compares with the actual
node actor reference. `authorize_custody/8` proves `agent_key_preparation` before
using the existing vault and rechecks destination before returning the key.

Observation custody's shared `physics_valid_sample/2` reads the exact current
`physics_run(W,G,Token)`, authority, epoch and structure. Rest, hinge and
checkpoint measurement predicates use it before storing their signed request.
They cannot move an old sample into a new incarnation's run.

Initialization rejection tests now cover malformed floor geometry and a body
allowance smaller than the complete admission set, in both gallery and workshop.
They assert rollback of assignment, bodies and controls and preservation of the
authored source. Existing stale-assignment and revoked-grant tests remain.

Full release-gates-01 stopped at EUnit: 3,999 passed, one GUI example used the
superseded `lobby_sky/1` query. Its replacement names the exact sky in
`lobby_sky/2` and keeps all expected values; the targeted example passes.
The failed log and STOP remain intact. Release-gates-02 then passed all 4000
EUnit tests, all 148 Common Tests and xref, but stopped at Dialyzer because the
receipt filename helper was passed an incomplete vault record. Refactoring that
helper to take the directory directly leaves custody behavior unchanged. The
focused vault tests and Dialyzer pass. The new frozen gates-03 campaign verifies
the corrected tree: all eleven gates passed with unchanged frozen inputs. Earlier failures
are retained under gates-01 and gates-02.
Per-file production delta is recorded in `production-delta.json`: +331 lines,
including the shared space view and durable custody in existing owners, with no
new process. Generated assets and coverage are excluded from that count.
