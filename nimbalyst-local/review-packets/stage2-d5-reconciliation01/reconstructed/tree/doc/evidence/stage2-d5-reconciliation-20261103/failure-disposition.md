# Reconciliation audit failures

- audit01: actual Python exit 1, tool chunk e21009. The initial full tracked-patch comparison included the intentional plan edit. Corrected comparison excludes only that plan; 848 inherited source hashes/modes remain checked. Its saved stderr is transcribed from the complete tool output, not a separately captured pipe.
- audit02: actual Python exit 1; full stdout/stderr and EOF are retained. The owner list used the proposed M0 space_physics.pl name. Corrected to the existing quod_physics.pl owner; no file is silently skipped.
- audit03: actual Python exit 0 and both EOF. This checks source preservation and historical receipt consistency, not product runtime behavior. No application or test campaign was launched by any audit.
