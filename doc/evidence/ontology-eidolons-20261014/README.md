# Ontology Eidolon implementation evidence

Ontology instances now use owner-derived exact `ontology_ref/2` identity and
ordinary `entity_eidolons/2`. The ontology-only dispatch and duplicate recipe-side
source classifier are removed. ACL entry rules, explicit interfaces and live
routes use existing authorized inspection, lenses, encodings and retained
cursors. Editable presentation is advisory; actual content and policy edits
retain current admission, exact source baselines, transactions and outcome
handling. Space, location, ownership and physics remain independent.

## Reviews

- [Plan disposition](plan-disposition.md): Fable plan review 02 succeeded,
  with 25 unchanged frozen inputs. Plan review 01 failed with ENOTFOUND before
  API access; its receipt and logs remain intact.
- [Implementation disposition](implementation-disposition.md): initial Fable
  review found no blocking defect. Its reported refinements and the independently
  identified client scope/key issue were corrected.
- [Final Fable review](implementation-review-02/fable-review.md) confirms all
  corrections with no remaining concrete defect; true child exit 0 and 17
  unchanged inputs. Reviews requested Fable with no fallback, read-only tools,
  hooks/MCP disabled. Receipts also report auxiliary Haiku usage.

## Verification

- [Initial frozen full gates](/home/yan/src/quod/_build/ontology-eidolons-20261014/gates-01/results.json):
  180 client tests, UI build/lint, 3973 EUnit tests, 148 Common Test cases,
  xref and Dialyzer passed. Sources stayed unchanged across every gate.
- [Final correction gates](/home/yan/src/quod/_build/ontology-eidolons-20261014/corrections-02/results.json):
  180 client tests, UI build/lint, 86 focused Erlang tests, xref and Dialyzer
  passed on their separately frozen source scope. Coverage includes real signed
  system/root/owned/read-only/denied reads, mode conflicts and invalid declarations,
  unauthorized policy edits, stale ownership, wrong/unbound target anchors,
  original source cursor/restart/no-I/O obligations, private routes, all transport
  host forms, route conflict/host updates and refusal to seal a live-route write.
- [Browser result](browser-01/result.json): readonly lens, exact target,
  complete UTF-8, refresh, held-read target switching and denial clearing all
  passed; zero execute requests and no browser errors. The browser and Vite
  server closed, and the launcher recorded true exit 0.
- All 1079 final frozen input files match the shared working sources at final
  synthesis. Generated UI builds remain in the isolated check trees; existing
  user-owned shared bundle changes were preserved.

The unchanged-tree baseline passed 83 tests. Verification 01 retained two failures
in newly authored expected route text (`:- true` versus canonical data facts);
expectations were corrected without changing the formatter. Verification 02
passed both affected tests; later signed and final frozen checks also passed.
An unsupported help flag unexpectedly started a broader suite and stopped on a
sandbox-refused local TLS listener; its [receipt](help-command-01/receipt.json)
records 46 passing tests and six cancelled cases. The subsequent frozen full
gates used authorized local socket access and passed. No failure was erased or
silently resumed.

## Scope and handoff

[Production delta](production-delta.json): 279 lines added, 88 removed, net +191.
Growth supplies three previously missing capabilities: filtered inspection in
the existing chunker, executing-owner live route projection, and a non-code lens
consumer. Existing source-cursor code is shared; there is no second domain
engine, directory, executor, queue, ontology registry or permission oracle.
Most baselines are frozen start snapshots; the primitive chunk block baseline
was reconstructed from its recorded initial read while retaining untouched user
changes, as identified in the delta receipt.

The source is uncommitted and ready for review. No labels, deployed policies,
running bundles, histories or genesis identities were changed. Activating the
new common primitive arity and authored definitions requires the existing
authorized compatible-artifact/retained-history procedure. Source editing does
not authorize deployment, refounding or history deletion. Text highlighting and
the 3D editing workbench remain their separately tracked consumers.
## Deployment

The authorized combined commit and candidate `0.7.265` deployment are recorded in
[deployment-265/README.md](deployment-265/README.md). That separately labelled
campaign preserves the original implementation verification and its
no-deployment boundary.
