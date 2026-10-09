# Complete ontology source inspection

Implementation scope is every ontology whose target policy authorizes inspection.
The shared source primitive, source tool, lens and editor contain no lobby-specific
inspection path. The lobby test module supplies the established signed ingress,
real ontology owners, administrator and ordinary-user fixtures.

## Acceptance evidence

- Complete source is compared with actual predicate and policy source for all
  17 public system targets in the integration catalogue, including `quod:node`
  and `quod:modelling`. Stored shared `isa/2` semantics and dollar-named helpers
  remain visible. Root/signup administrator restrictions and personal ownership
  remain separate from public-system source permission.
- An administrator changes the lens's chunk policy through the signed compiler
  and transaction seam. A signed source cursor suspends after its first chunk;
  another signed transaction asserts/retracts a node fact. The original cursor
  returns byte-identical pre-edit state; refresh returns exactly the replacement.
- The explicit predicate lens reads the replacement while invoking that predicate
  as the ordinary reader is refused. Existing edit tests retain target admission,
  exact baselines, stale-edit refusal, preview/Accept and saved-outcome recovery.
- Restart with the same retained ledger and genesis anchor reproduces the exact
  complete state. Unauthorized personal targets and wrong anchors are refused.
- Two unchanged complete reads through signed cursors produce zero traced calls
  to projection creation/source loading, history reads, ledger snapshot/index
  reads, file writes, pwrite, sync or datasync. The trace has its own relay and
  delivery barrier; earlier tests' mailbox messages cannot contaminate it.
- Browser coverage uses real React, signing and IndexedDB with explicit HTTP
  fixtures; server authorization and recovery use real owners in Erlang tests.
  It checks complete-state default, genesis display, explicit predicate selection,
  read-only controls, refresh, clause editing and interrupted-save recovery.
  Client tests also cover split UTF-8 chunks and rejection of truncated/lost reads.

The generic self-ask correction uses Erlog's ordinary `call/1` handling for an
uncompiled selected goal. Conjunction and local-cut regressions accompany it;
it adds no process, permission owner or execution lane.

## Validation result

The final clean sequential campaign (03) passed every gate with actual child
exit 0: 110 client tests, UI build/lint, 3,769 EUnit tests, 146 Common Tests,
xref, Dialyzer and release assembly. Final UI campaign 02 and browser acceptance
04 also passed. No source freeze changed during either campaign.

[Verification receipt](verification.json) records the gate results and the final
working-tree comparisons. [Full validation logs](validation-logs.tar.gz) include
the runners, frozen manifests, individual gate exit receipts, complete Common
Test reports and retained failed attempts. The release was assembled only in the
isolated validation tree; it was not deployed.

## Evidence and scope

[Source hashes](source-manifest.json) identify changed source/tests/docs and the
browser assets. [Production line counts](line-delta.json) record 173 additions,
261 removals, net **−88**; tests, docs and generated assets are excluded.

The clean campaign runs client tests, UI build/lint, EUnit, Common Test, xref,
Dialyzer and release assembly sequentially. Every completed gate has its actual
subprocess exit, duration and full log. Dependency source caches rebuild Erlang
BEAMs; unchanged Cargo artifacts and the validated Dialyzer PLT are reusable
build caches. The source and lockfile hashes are checked between gates.

Retained earlier failures are test-development/harness evidence, not passed
campaigns: the first compilation had a trailing-comma fixture error; the next
run exposed the real self-ask conjunction crash. Subsequent focused failures
identified obsolete whitelist/lens expectations, a wrong node-policy test name,
a single-chunk fixture requiring an explicitly smaller Prolog chunk policy,
unrelated mailbox traces, and a wrong-anchor assertion placed after owner
shutdown. The final focused run passed 104 tests. The added read-only browser
assertion initially expected the pre-save fixture value; it now checks the
source committed earlier in that same scenario. The final browser run also
checks that spatial read-only source uses the existing scrollable text field,
with the lens selector enabled.

Clean preparation 01 stopped on a dependency's dangling fixture symlink.
Campaign 02 passed 110 client tests, UI build/lint, 3,769 EUnit tests, 146 Common
Tests and xref, then stopped because source overrides caused rebar to rewrite
its copied lockfile. Its stop record and logs are retained. Campaign 03 uses
the normal pinned dependency layout; a lock preflight verifies no rewrite.

The last UI-only refinement uses the existing scrollable text field for spatial
read-only inspection and removes an unnecessary generic read-only field option.
Backend sources, ontology policy and Erlang tests are unchanged from campaign 03.
The final UI scope is frozen separately: UI preparation 01 omitted the shared
term-limit header needed by a client test and failed; UI campaign 02 includes
that fixture and passes client tests, build and lint. Its detailed TAP output
records all 110 passing client tests. The final browser acceptance run is 04.
The final verification receipt compares the working tree with both frozen scopes
and the generated assets with the final UI build.

At initial implementation validation, no production deployment, stored-policy
migration, ledger wipe, re-founding, label bump or git commit had been performed. The exact-baseline atomic migration,
original-operation outcome resolution and post-restart verification procedure
is in [the source ACL contract](../../system-ontology-acls.md).

## Authorized clean deployment

The user subsequently directed a ledger purge and clean redeployment.
[Deployment 0.7.254](deployment-254/README.md) records the eight candidate volume
deletions, clean founding, successful eight-node rollout, all-public-ontology
signed reads and byte-identical source after restart. No retained-ledger
migration was submitted. Source and release-label changes remain uncommitted.
