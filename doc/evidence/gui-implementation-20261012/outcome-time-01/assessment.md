# Independent assessment

Accepted core report and final addendum. Certified times follow the actual
content/control projection paths, share claims' staged flush and publication,
and cannot leak retained future rows during replay. Immutable row checks refuse
conflicts; equal adjacent times remain valid. One existing cache algorithm now
serves group, operation and timestamp lookups. Net production growth after final
followup is 41 lines, for retained time validation and publication; no process,
queue, separate cache or resource ceiling was introduced.

Gate01 211/0 exit0 (before lookup extraction); gate02 259/0 exit0;
final gate03 260/0 exit0, 16.618s. Source-only Fable reviews did not run tests.
The disk fixture checks repeated unchanged reads/apply/empty-flush for no writes,
no history reads/rebuilds and a real subsequent update. Shared projection tests
check exact entry timestamps. Local/foreign/runtime suites passed together.

Other integer format versions are refused and preserved, including newer ones.
Old deployed binaries retain their old policy and may reset a newer derived
index on rollback: no deployment, downgrade, migration or wipe is authorized.
Same-format wrong-anchor behavior is pre-existing and was not changed here.
No negative expiry token, public expired answer or automatic GUI dispatch yet.
