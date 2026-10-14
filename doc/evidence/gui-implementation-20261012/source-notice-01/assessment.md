# Independent assessment

Accepted after tracing the same follower protocol: advances are acknowledged one
at a time, all publications of a height arrive together, and initial/rebuilt
follow state is a publication-free baseline. Filtering through the already-owned
verified height therefore discards only consumed occurrences. Equal-height state
and freshness still take the existing resource reconciliation path.

The regression proves duplicate notice suppression using the actual runtime
receiver/dispatcher and excludes repeated I/O. It does not separately simulate
readiness withdrawal/restoration at unchanged height; that preservation is source
verified, not a new hardware or owner-lifecycle test claim. Later real changes,
runtime restart and cache rebuild pass in the same fixture. gate01 65/0, exit0.
The retained red01 demonstrates the original failure.

Fable's local-envelope caveat is valid and remains part of the separate pending
retained-intent dispatch consultation. No durable delivery or retry guarantee is
introduced; dropped best-effort occurrences remain dropped. No second queue or
inventory, wire change, commit or deployment.
