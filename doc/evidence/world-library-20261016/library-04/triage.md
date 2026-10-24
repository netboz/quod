# Naming dependency assertion

The real form now creates a world with a name from the naming ontology. The
next assertion incorrectly equates unchanged naming content with unchanged
ledger height. The retained ledger inspection in `naming-history-03` shows
only the existing atomic protocol's Vote and Resolve at heights 2 and 3.
`route_plans/4` includes reader scopes in an ordinary multiwriter group.

Replace the height assertion with equality of the naming ontology's complete
source before and after creation, read through the existing signed source
cursor. Preserve the checks that the generated name belongs to the selected
pool and that the saved world name remains stable. Do not alter commit routing.

The stopped-ledger diagnostic succeeds with the release's declared BEAM modules
loaded, as embedded production does. Its earlier strict scan refusal came from
the standalone diagnostic setup, not repaired data; no history was changed.
