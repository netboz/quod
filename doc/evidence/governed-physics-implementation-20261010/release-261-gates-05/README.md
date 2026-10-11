# Release 0.7.261: final sequential checks

All eleven checks passed on the separately frozen final inputs. The runner and
each child exited zero, and the input hashes remained unchanged. This campaign
ran from 18:14:44 to 18:40:39 UTC on 2026-10-11.

- Native tests: 22 in debug and 22 in release; Clippy with warnings denied.
- Client tests: 126; UI production build and lint.
- EUnit: 3,880; Common Test: 146.
- xref, Dialyzer and production release packaging.

[Results](PASSED.json) retain each command, start time, duration and child exit.
[Runner exit](process-exit.json) records the observed outer exit.
[Full command logs](full-logs.tar.gz) and the separate
[Common Test case logs](common-test-logs.tar.gz) preserve the complete output.
[Frozen inputs](frozen-inputs.tar.gz) contain all 683 tested source inputs;
[source hashes](source-manifest.json) and [asset hashes](explorer-manifest.json)
bind the source tree and 176 generated browser assets. All browser assets match
the previous committed release, so no generated asset change is needed.

Campaigns 01–04 and their failures or explicit interruption remain retained.
The [diagnosis](../release-261-test-diagnostics/README.md) identifies the leaked
test namespaces and preserves the cancellation failure as unexplained. The
assertion and five-second deadline were kept; final full-suite execution passed.

The [native correction](../floor-slide-disposition.md) and
[final test review](../release-261-test-implementation-review-02/disposition.md)
explain the final code and review findings. This is build and test evidence;
deployment and signed desktop acceptance remain separate obligations.
