# scenes-01 stopped

The disposable 300-mark valid-case VM was still using a CPU after its proof.
It was intentionally stopped with SIGUSR1 at 15:27:19 UTC to obtain a diagnostic.
The gate recorded exit 1. Its result graph was retained in the process dictionary.
The current call was `erts_debug:same/2`, under `erts_debug:is_term_seen/2`,
`remember_term/2`, and `size/3`, reached from the optional `erts_debug:size/1`
argument to the final log print. This was observation work after proof timing
and memory capture, not time in the Prolog proof. No scene result had been
printed, and no timing from this run is used.

Keep the original gate log and [stack evidence](scenes-01-diagnostic.txt).
The [instrumentation patch](scenes-01-instrumentation.patch) removes only the
optional graph-size query. A distinct `scenes-02` label runs that corrected
probe; it does not replace this stopped run. The full raw dump remains temporary
under the disposable build tree and is removed with it after recording evidence.
