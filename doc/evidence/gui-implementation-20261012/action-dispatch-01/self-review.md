# Independent assessment

The common declared-action helper now receives the private transition instead
of hardcoding ontology lifecycle dispatch. The existing lifecycle bridge still
validates the public action and allocates the exact opaque proof-local handle;
it constructs its own private continuation with one fresh desired-state variable.
The action declaration binds that variable exactly as before. No new native
operation, registry or authority mechanism is introduced. The old arity2 helper
is removed and its only production caller is migrated.

Both native and future GUI bridges can use the same action candidate, prerequisite
state checks and savepoint rollback. An additional test traverses a failed first
candidate before a successful second candidate and verifies no leaked assertion;
an exact failed transition also leaves no assertion. Existing native lifecycle
tests cover forged handles, policy refusals, foreign prerequisites, original
signed custody, effect rollback and journal restart.

Gate01: 90 tests, 0 failures, true child exit0, 71.369 seconds. It includes action
predicates/savepoints, the complete lifecycle single-path suite and GUI component/
question regression. Production +7/-7, net 0. This is self-review,
not Claude review. The native GUI presentation operation is not implemented by
this small shared-mechanism simplification.
