# QUO-66: governed proof answers and current desktop package

Checkpoint200, continued by Recovery202 against accepted199/195. Sole actual
session `ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f`; API model is
`openai-codex:gpt-6-astra`. The historical requested Sol label did not change
the running model. Effective backend effort is unexposed. Coordinator:
`ed9cd520-b2a4-4607-a8f5-ff99d08f3e46`.

## Result and exact limits

The old 65,536-byte proof-answer allocation is replaced by the existing
committed Prolog material policy. The real producer and nested-answer consumer
both enforce their own pinned allocation before exposing/unifying a solution.
The desktop now shows the exact resource, quantity and allowance rather than
only `material_limit`. No close-order, engine, focus, calibration or domain
semantics were changed.

Shutdown reliability remains unresolved. One bounded instrumented run reached
all existing close awaits, Quit and tree exit, with client/server0, four EOFs
and zero final resources. The close-begin to `_ExitTree` interval was
0.051128695 seconds, not process-exit latency. Its original wrapper1 from the
duplicate diagnostic `models.settled` assertion is retained; a separately
labelled offline reconciliation0 distinguishes task status from the awaited
milestone. No original60s trace trigger, capture or attach occurred. The earlier
05/09 pauses remain whole failures without a demonstrated cause or fix.

The release checks are complete as explicit composite evidence: native56,
4,276 unchanged EUnit passes plus the two corrected existing generators,
Common Test150, xref, Dialyzer and production release. The original full EUnit
failure and the remaining campaign's generated-lock metadata failure are both
retained. The latter has a separate offline reconciliation0; neither whole
campaign is relabelled green. Exact qualification and immutable reconstruction
are recorded in `doc/evidence/godot-client-policy-20261031/result.json` and the
final boundary receipt.

## Policy and source

`material_policy.pl` authors `proof/answer_bytes` with the same explicit
`unlimited` semantics already used by other material resources; authorized
ordinary overrides may choose a finite nonnegative value, including zero.
There is no Erlang default or environment authority. Invalid, missing or
ambiguous committed selections fail closed. This does not update founded/live
ontologies.

The quantity is canonical atom-safe answer payload bytes. The signed fixture's
80,000-byte binding measures 80,041 answer bytes. Complete carrier/transport,
safe-term, client aggregate and durable-result capacities remain separate.
Wire14 refuses versions1–13; no hidden compatibility lane or split/replayed
transaction is introduced. A staged policy raise cannot enlarge its own proof;
read dependencies retain OCC conflict and original recovery semantics.
Twenty unchanged invocations select once and perform zero named history,
projection rebuild, write or sync work; actual authorized policy changes
propagate through the existing owners.

The production delta is eight files, +70/-34 lines: material policy/admission,
proof session, scope session/wire, receiving ask, obsolete cap header and shared
client Transport error presentation. Existing mutable owners remain the only
owners. The net 36 lines add the independent receiving-policy check and exact
resource-error presentation while removing the old cap and duplicate enforcement.
Modified tests and protocol documentation, plus the two focused new
test sources, are recorded separately in the exact delta. Old observations,
snapshots and failed labels are unchanged.
The seven modified test files total +93/-17; the protocol document is +25/-4.
New proof-answer and resource-message tests contain177 and41 lines respectively.
There are16 changed inherited files, each with its own preserved before-copy.

## Qualification

- Original selected-worker80k baseline1; exact unchanged regression final02=0.
- Clean affected EUnit105=0; signed local/cohosted/remote policy case06=0,
  including producer raise, independently smaller receiver refusal and an
  explicitly intended restoring action. Exact actual/allowance is retained.
- Full release01 native56=0; EUnit4,276 passed/two stale catalogue-count
  assertions failed, child1/no timeout. A separate clean release02 verifies
  the exact five anchored recipes in those two existing generators; both pass0
  with their permission/source checks intact. No product changed for this
  correction. Common Test150/xref/Dialyzer/release each exit0. The campaign
  outer remains1 because the final stage lock omits the five existing source
  checkouts. A separate Erlang-parser reconciliation0 proves all other lock
  entries/checksums and actual dependency sources/links unchanged; all1432
  live authored inputs are exact. No test/app rerun or lock restoration occurs.
- Transport baseline02 restore0/run1; final01 nine checks/0. The response is a
  disposable HttpMessageHandler fixture, not a live network claim. Big integer
  decimal reporting and existing uncertain-write classification are preserved.
- Current separate companion journey: initial72/reopen21, all three children
  and wrapper0/six EOFs/no reader errors. Same U/A/profile/location and committed
  graphical/text fact reopen without new instructions or replay. Actual Control
  signals drive the existing owners; zero host input/focus actions. Final scene,
  sockets, sources, appearances and captures0; XR is off. `work.calls=[]` on
  unchanged observations. This is not ordinary uninstrumented or human proof.
- Current ordinary extracted product: isolation probe0, mapped owned launch,
  its packaged CoreCLR and exact-owned normal close0. No qualification flag,
  SDK/developer paths, host focus or display mutation.

All true failed labels remain in `failure-disposition.md` and their receipts.
Root203–210 independently checked the reported bounded inputs/results;
that is distinct from pending final full-boundary integration.

## Usable private package

Archive:
`/data/quod-m4-vr-ca84d4f8-20261029/artifacts/quod-workbench-linux-x86_64-policy-private01.tar.gz`

SHA256 `b9f17535526937648f43667e150b153bcf5dc8e067423f68863c6627407b7464`,
78,074,348 bytes,207 files. Independent `policy-repro02` has the same SHA.
Archive/extraction paths, types, headers, bytes and modes are checked, including
a path containing spaces. The previous199 archive remains untouched.

Trace-free private product02 has97 supplied=current inputs and196 exports,
193,471,872 bytes. Manifest
`doc/evidence/godot-client-policy-20261031/inputs/client-policy-product02-manifest.json`
SHA `d64d2ecd39822de63b9c8169d9eff32cd778c54dff685925d9cbcba6a6e3874f`;
DLL `8f31f5c03a63bda60c67c19b996f0997e950f79d82c436b66940e5187b8e60a9`;
PCK `74a0e52cb8862134f46792ea2e5fbeed2df0ae2a01b79440ee81fbd627b0e7e0`.
Pinned engine remains
`02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268`.
The companion has98 supplied inputs and is never distributed. Only Transport
changes production client behavior; the product input vector also includes
the two affected test sources. All five build phases are true0 for each payload.

Extract the archive into a chosen directory and run the contained `quod`
launcher. Keep XR disabled for ordinary desktop use:

```sh
./quod-linux-x86_64/quod --xr-mode off -- --node https://your-server.example:14570 --ca /path/to/your-ca.pem --profile /path/to/private-profile
```

Use the actual authorized endpoint/trust files and private profile; these example
values are placeholders, never baked fixture configuration. Sign in through the
ordinary client. No SDK/build commands or manual test-server sequence is needed.
The package supplies the desktop client and managed runtime, not a server,
account/credentials or optional OpenXR runtime. GLIBC2.44+ and appropriate host
graphics/desktop libraries are required; current-host isolation is not proof on
older distributions. The byte-identical16-ELF dependency audit is reused.

For a later normal desktop human check: sign in, create a space in explicit
storage, enter it, inspect the exact ontology's Workbench, prepare a permitted
fact, Preview, explicitly Save, verify the returned graph/text, disconnect,
reopen the same profile/location and exit. No participant wait is started here.

## Custody and remaining acceptance

Final qualification `policy-final-qualification01` exits0 without rerunning
applications/providers. The additive boundary is
`/data/quod-m4-vr-ca84d4f8-20261029/artifacts/quod-client-policy-handoff-ca84d4f8-20261031-02`;
its external actual-child/completion receipt is
`/data/quod-m4-vr-ca84d4f8-20261029/artifacts/client-policy-freeze-runs02/result.json`.
The seal owner makes16 separate inherited copies before real binary patch
check/application and independently extracts all new/changed tar contents,
checking bytes, types, literal links and full modes. It reconstructs the complete
new delta against accepted199/195, not a full inherited tree. Coordinator
independent integration remains a separate acceptance step.
Failed seal01 remains preserved: its reconstruction completed but the final
inventory check raised a Python name-shadowing error. Label02 corrects only
that seal helper and includes the failed receipt/metadata; no product/test rerun.

All raw/new heavy work stays under the authorized private Data root; the large
new release logs have literal worktree links and exact private stream receipts.
Old API bytes, histories and accepted export vectors were not recounted.
The build helper did omit cache inheritance for its archived source inputs:
the exact audit records 74,706,372 avoidable repeated digest bytes for its six
current references. This is retained as custody overhead, not new authored
bytes. Its actual focused06 cache is now SHA-authenticated and reused through
all six exact stat keys, with zero archive-byte reads in the correction check.
No old inode link/chmod, cleanup,
commit/push, global install/configuration, native XR/runtime or hardware action,
display-configuration or focus action,
live policy deployment, retirement or network cutover occurred.

The new wire boundary and committed material-policy changes need coordinated
future deployment through their normal authority. Human desktop/VR usability,
historical shutdown reliability and full M4/M5/release/retirement/cutover remain
open. Tracker body/checklist publication remains blocked without retry; no full
ticket closure or next-ticket dispatch is claimed.
