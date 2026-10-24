# Read-only Fable consultation: partial world-library integration

Read `/home/yan/src/quod/AGENTS.md` first. Yan explicitly requested Fable reviews.
This consultation is not approval to commit, deploy, mutate live ontologies,
change resource limits, or change wire formats. Do not run tests/builds, edit
files/memories, or delegate. Return a complete final report with precise frozen
file/line references, confirmed defects separated from risks, scope limitations,
and recommended corrections. The parent independently checks every finding.

Frozen source: `/home/yan/src/quod/_build/world-library-20261016/review-01/tree`.
There are 1,068 entries in `source-manifest.json`. `changes.json` and
`integration.patch` are the 25-file delta from the pre-integration baseline,
excluding the already-reviewed terrain core changes. Production delta: +599/-115
(net +484); this is a new workspace/controller/domain composition plus shared
refactoring, not a finished simplification claim. The snapshot includes current
contracts and the authorized plan. Read `doc/multiwrite-architecture.md` before
architecture advice. Do not retarget to a later live tree.

## Status and evidence

This is a partial implementation with a concrete composition blocker, not a
finished candidate for release. No real GUI creation/entry acceptance has passed.
`../library-01/receipt.json`, `run.log`, and `triage.md` record the failed real
signed-owner fixture. It fails at founding, before assertions. The independent
`../composition-01` receipt/log and `../measure-composition.escript` show that
eleven shared source files alone produce 130,314 initial ETF bytes but 339,337
canonical genesis diff bytes; transaction encoding returns `too_large` and the
genesis validator returns false. The source alone also requires 516 cold symbols
against 512, before owner/host/vocabulary facts and lobby geometry. No constants
were raised and no founding was split. The naming ontology is separate and is
not part of that payload.

`../names-01` preserves two fixture failures; its triage explains corrections.
`../names-02` passes 428 tests. `../client-01` passes two files; `../client-02`
passes four files under Node 26's file-level report. `../library-client-01` runs
the new controller file directly and reports seven actual passing tests.
`../ui-typecheck-01` passes TypeScript. These are focused live-tree receipts,
not a clean frozen campaign. No full gates have run for this scope.

## Questions to inspect

1. Independently confirm the two composition constraints and trace ordinary
   prepared founding, canonical transaction/block encoding, cold materialization,
   join and restart. Recommend the smallest principled shared correction that
   keeps several worlds in the existing user-owned lobby, one transaction per
   transition and ontology-owned policy. Is there an already-supported composition
   mechanism we have missed? Do not propose staged founding/source fragments to
   evade limits, larger Erlang constants, a world-specific codec, or a second
   domain executor. Distinguish an actual representational bound from resource
   policy. A shared compact encoding or admission-policy change is wider than the
   two client extensions Yan authorized and would need a concrete decision first.
2. Review the new domain composition: ownership, responder restrictions, exact
   GUI occurrence/answer completion, name persistence, duplicate-label identities,
   authority/pilot isolation, shared physical initialization and bounded spawn
   candidate against the native final admission contract. Consider failed/stale
   GUI completion, and expected fresh-account source composition.
3. Review shared client initialization, journal recovery, cancellation, exact
   space selection, GUI control reuse and outgoing-view retirement. In particular
   check close/identity/view changes during signing or after a write has reached
   the network; late results must not navigate or delete needed recovery evidence.
4. Identify any already-introduced correctness or architectural defects worth
   fixing independently of the blocker. Prioritize material issues, not style.

Known unfinished acceptance: fresh/existing human HUD source installation,
successful combined founding, real-world admission for all presets, browser
create/list/enter/return/reentry, preserving patches/checkpoints across restart,
and the frozen sequential gates. Do not describe these as tested or completed.
`../naming-provenance.md` records the deferred book-import discovery; the draft's
small landscape pool is original Quod data in the existing engine, not a claim
to have imported the rest of the book. This is world creation/exploration, not a
digging-game milestone. Terrain tools remain secondary.
