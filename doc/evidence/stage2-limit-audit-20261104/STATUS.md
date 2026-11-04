# Stage 2 restriction inventory cross-check

The audit checkpoint below is retained as observed. The later 2026-11-04
[delivery supplement](#long-namespace-source-view-delivery-2026-11-04)
records the correction and signed acceptance of its bounded gap.

Requested scope: check item 1, comparing the original restrictions with current
code and existing test evidence. No production correction or Stage 2 closure.
Audited Quod `d572e73fa6dfc3116ccb36016309852cc45f0d83`, Erlog
`79b3874617a4eb9f76d5089a3fc908667e605e8a` in pearl-stone.

**Finding: one confirmed omission in the original namespace/view scope.**
The source-access WebSocket validator still rejects target namespaces longer
than 255 bytes. The other enumerated removals are present, with recorded affected
verification. The open checklist item is therefore not merely stale wording.

## Method and source binding

The audit joins these historical inventories, rather than searching for every
number in the repository and treating it as a quota:

- [Presentation owner inventory](../stage2-presentation-limits-20261103/inputs/owner-inventory.json).
- [Boundary correction inventory](../stage2-presentation-boundaries-20261103/remaining-correction-inventory.md), including its 182 recorded caller references.
- [Consolidated owner map](../stage2-remaining-admission-20261103/OWNER-VERIFICATION.md) and [applied results](../stage2-remaining-admission-20261103/APPLIED-RESULTS.md).

[Audit script](audit.py) and [machine-readable result](audit.json) bind 250 current
source files and compare successive campaign afterimages. The 36 header symbols
retired between the saved headers and current source have no production macro
references; test-only historical thresholds are not imported by production.
This absence alone is not proof: the remaining owners and numeric guards were
also inspected, which found the literal 255 guard below.

Of the consolidated campaign's 108 entries, 100 current files are byte-identical;
one deleted empty header is also correctly absent. The seven remaining changed
entries are explained by later renewal, predicate-removal and documentation
receipts. Across the combined campaign maps, all seven latest differing paths
match those later recorded afterimages, including the comment-only ask change.
This establishes source continuity, not a claim that every earlier test ran on
the later complete tree. Original failed runs and their corrected fixtures stay
under their original labels. No completed runtime suite was rerun.

## Inventory disposition

| Original restriction | Current source and disposition | Existing evidence |
| --- | --- | --- |
| Scene/traversal counts, lens/workbench counts | Removed in `common_predicates.pl`, `gui_scene.pl`, `gui_tools.pl`; recursion/cycles and frames remain. | Presentation owner02/03, browser02/03 and later configured large-catalogue acceptance. |
| Label/identifier shortening; coordinate/scale ceilings | Removed; type, positivity, shape and finite renderer conversion remain. | Same presentation source hashes and browser/native checks. |
| Global asset ceilings; text input default4096 | Removed; explicit authored resources and optional `max_bytes` remain. | Presentation resource-owner01 and browser/native checks. |
| Nested128KiB, result/view/terrain512KiB, link1MiB and derived request ceilings | Removed through goal/HTTP/view/link/terrain owners and browser/native mirrors; real field widths remain. | Boundary owner, signed ingress, HTTP, browser/native and terrain02 receipts. |
| Parser2048 tokens, symbol/number1024 and term depth64 | Removed from server parser, shared term codecs, browser reader and native Term. | Boundary tests plus applied-integration02; finalization admission02 accepts depth96 and large fields. |
| Derived block/plan/control/scope/journal subquotas | Removed; material policy still decides authored finite admission. | Carrier-current01/fixture02/recovery01 and applied owner/integration checks. |
| Committee64 and derived route/map caps | Removed; exact membership, signature sizes, uniqueness and quorum remain. | applied-owners02/03, committee tests and 65-member signed quorum. |
| Pending512, per-author64, derived ingress bytes and opening-link outbox | Removed; ordering, duplicates, custody and deadlines remain. | applied-owners01/02 and actual 513 signed relay admissions, not a claim of 513 completed consensus commits. |
| Foreign page256/900KiB; estimated cache padding | Removed; retained cursors use actual complete-frame space and preserve continuation. | applied-history and integration02: 258-entry snapshot,259 update,unchanged zero opens. |
| Ledger reader64MiB | Removed; actual file extent, uint32 frame length, CRC and torn-tail handling remain. | Applied ledger/history tests and current matching store source. |
| Callable512, cumulative16384 and reserved100000 atoms | Removed; actual VM name/capacity checks and explicit finite options remain. | applied-codecs/owners and 513 callable acceptance with opaque arguments. |
| Direct-effect2048-byte payload | Removed; the protocol's single-effect semantics remain. | remaining-admission large-actor test and applied owner checks. |
| Erlog reason256/count,4096 individual,32768 total and boundary count | Removed; explicit callback refusal and portable values remain. | Seven Erlog modules, remaining-admission diagnostics test, later renewal correction and published pin. |
| Proof/scope workers64 and authentication population defaults | Defaults unlimited; supplied finite options still enforced. | 65 live workers/release and finite-option tests in applied owner/codecs checks. |
| Namespace128/255 and filesystem naming | Core request/directory/storage and client mirrors corrected; **source-access view guard remains**. | Existing long-name encoding/storage tests pass but do not cover the missing view boundary. |

The existing receipt metadata (including nonzero exits and EOF fields) is retained
in `audit.json` by exact source receipt path/hash. The authoritative failure
interpretations remain in the campaign results, not replaced by aggregate totals.

## Confirmed remaining source-access guard

[quod_client_view.erl:231](../../../src/quod_client_view.erl) accepts
`source_access` only when its target namespace is at most255 bytes. Actual path:
WebSocket open → `decode_command` → `open_request` → `view_request` →
`gui_view_goal(source_access,...)`. A longer target returns `error`, causing
`invalid_view_request` before the ordinary signed ingress worker runs.

The signed request has real16/32-bit fields, and the target reference is ordinary
Prolog data; there is no255-byte field at this check. Directory/storage and native
request tests explicitly accept1024-byte names. Existing `quod_source_view_tests`
uses `quod:gui`, so its authorization/revocation/unchanged-work coverage does not
exercise this case.

[Probe](source_view_probe.erl), [driver](run_probe.py), [stdout](source-view01-stdout.log)
and [receipt](source-view01.json) observe the existing private validator through
the **exported production WebSocket callback**, without `export_all`, edits or
replacement owners. Exact production beams match the retained production10
receipt, and the relevant current source hashes match those compiled inputs.

Observed validator outcomes:255 bytes accepted;256 and1024 bytes rejected. The
probe exits0 because it asserts this observed defect, not because acceptance is
fixed. It signs and checks the request bytes, but intentionally uses expired
requests so no authorization worker or store opens. Return tracing distinguishes
the namespace-shape verdict from the later expiry refusal. This is a precise
pre-admission reproduction, **not end-to-end signed view acceptance**. Both child
streams reached EOF; no timer deadline or user data was changed.

Correction and affected signed view tests remain to be done. This check makes no
production edits and introduces no new limit.

## Adjacent observations, separate from the original removal claim

- `quod_effect_journal:bounded_reason/1` substitutes `oversized_reason` beyond4096
  encoded bytes; loaded-row validation also requires result<=4096. These are
  effect execution/preparation diagnostics, distinct from the Erlog proof-reason
  stack whose quotas were removed. Source-inspected; no runtime failure reproduced.
- `quod_simplex:retained_diagnostic_namespace/1` truncates names to255 bytes in one
  invariant-error log. It does not reject or shorten the stored namespace.
- `quod_c4_attempt` retains bounded optional tracing-window inputs. Those govern
  diagnostic instrumentation, not normal ontology admission.

These are not silently declared encoding constraints or fixed by this audit.
Real unsigned field widths, VM atom constraints, explicit policy values, existing
protocol deadlines, sparse-index cadence and the agreed singleton effect shape
were distinguished from population/text quotas. Optional memory accounting,
user-store migration, hardware/shutdown, Stage3 and deployment remain separate.

## Audit bookkeeping

The supplied tracker ID still resolves to no item; no duplicate was created.
Initial exploratory searches included nonexistent guessed filenames (Wire.cs,
SignedGoal.cs, common.pl/quod_common.pl, quod_client_view test glob and a receipt
at the wrong directory), producing literal `No such file or directory` search
errors. Inventory discovery corrected the paths; none was a runtime test or a
missing application module. The diagnostic probe passed on its first invocation.
Production delta is **+0/-0**. Only this evidence and the plan/handoff finding are
added; prior user-owned changes, stores and evidence remain intact.

## Long-namespace source-view delivery — 2026-11-04

The actual path remained WebSocket open → `decode_command` → `open_request` →
`view_request` → `gui_view_goal(source_access,...)` → existing signed source-access
owner. The guard in `src/quod_client_view.erl` rejected a 1024-byte target name
before signed authorization. Removing only `byte_size(Ns) =< 255` permits that
name while retaining the nonempty binary, 32-byte anchor and canonical target
checks. The ordinary source-access subscription and policy owners are unchanged;
no new limit, bypass, store representation or client-specific path was added.

The new `long_namespace_source_view_keeps_authorization_test_` in
`test/quod_source_view_tests.erl` uses a temporary store, signed GUI session,
actual socket and valid genesis anchor. It opens a 1024-byte target as read-only,
checks an unchanged repeat through the owner's zero-I/O assertion, rejects a
wrong anchor, then replaces the root source-access permission with denial and
checks the resulting unavailable view and absent installed state. The existing
short-name authorization/withdrawal test also runs. This covers the affected
permission and stale-view behavior without changing their owners.

The corrected real-owner baseline
[`source-long-baseline03`](inputs/source-long-baseline03.json) compiles the
committed pre-correction owner into an isolated source copy. It exits **1**, both
streams EOF: the short test passes, then the long test fails with literal
`{unexpected_source_view,#{<<"reason">> => <<"invalid_view_request">>,
<<"type">> => <<"unavailable">>}}`. The matching current-source
[`source-long-fixed03`](inputs/source-long-fixed03.json) exits **0**, both EOF,
**2 tests passed**. Full [baseline](logs/source-long-baseline03-stdout.log) and
[fixed](logs/source-long-fixed03-stdout.log) stdout and corresponding stderr
remain retained. [`source-long-production01`](inputs/source-long-production01.json)
compiles all production Erlang without `TEST`/`export_all` against pinned Erlog;
exit **0**, both EOF, full [stdout](logs/source-long-production01-stdout.log) and
[stderr](logs/source-long-production01-stderr.log) retained. The
[`source-view-fixed01`](source-view-fixed01.json) production-callback shape probe
separately verifies 255, 256 and 1024 bytes accepted after correction; exit **0**,
both EOF. This probe is a shape check, not the signed acceptance above.

Earlier `source-long-baseline01`, `source-long-fixed01` and `source-long-trace01`–`04`
in `../stage2-predicate-removal-20261103` remain literal exit-1 fixture failures:
their long-target anchor was `undefined` because the fixture read genesis before
starting that ontology. They are not used as the failing baseline or acceptance.
The `source-long-baseline02` driver failed before Erlang because its new evidence
directories did not yet exist; its literal failure is retained in
[`source-long-baseline02-driver-failure.txt`](inputs/source-long-baseline02-driver-failure.txt).
No failure was overwritten or silently promoted.

Exact source SHA-256 in the accepted signed receipt and the production receipt:

| Input | SHA-256 |
| --- | --- |
| `src/quod_client_view.erl` | `87e8d74ee3e48290844a6796223bcf5fd9f20206501242ee1c39fc88d80043fd` |
| `test/quod_source_view_tests.erl` | `87d0df96d6966ef2f2a576de5594b8820e6b1dbd8a689fb5f1e3b91c5f44f8e9` |
| Pinned Erlog HEAD | `79b3874617a4eb9f76d5089a3fc908667e605e8a` |

Baseline owner SHA-256 is
`bb1b84c10337d33b24f6193dd34a2206125cf3dd0eae2b020dfda6b42e0bfcbe`;
the test SHA is identical across baseline and fix. Receipt SHA-256 values:
baseline `9aab9b7c25ddfa77deca4d2c35f691fb922badc1bea05d85968d10dac7f5e50a`,
fixed `0f9984f7faca96aa1a7f982172675d45581fcab0f7a2bd4544a0720cace2a485`,
production `e46235ac6718efcd22db0ad10dadcb9175da46cf7ddb8fdc55b711dc25460200`.
The compiled-input and beam hashes, full commands, exits and EOF fields are in
those receipts. Actual production delta: **+1/−1 line, net 0**, one guard changed;
the test adds 52 lines. The original inventory's other removals were not rerun.

The Stage 2 policy-literal checklist item is now complete for its recorded scope.
Its parent remains open for separate current whole-tree/runtime acceptance;
adjacent effect-journal diagnostic4096 and Simplex log truncation255 are still
inventory observations, with no claimed correction. Stage 3, ontology founding,
broader renewal, user stores, hardware and deployment were not touched.
