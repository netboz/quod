# M0 qualification evidence

The seven-foundation and space contract is [godot-foundation-contract.md](../../godot-foundation-contract.md). This evidence qualifies a bounded Linux Godot/.NET probe and the existing production protocol seams. The seven new foundations, ordinary-space signup and complete Godot journey are not installed. No ontology retirement, deployment, deletion or commit occurred.

The implementation is uncommitted on `worktree/pearl-stone`, base/current HEAD
`f6c29fe925e666dd68ee7fa68c0e03f5d03391a2`. [QUO-61](nimbalyst://QUO-61)
owns status. Final **clean campaign06 passes all five sequential gates**:
56 native tests, 4,247 EUnit tests, 149 CT tests, xref and Dialyzer.
[Local production release02](logs/r1-release-02.json) also passes.
The single authorized Fable review completed against immutable snapshot03;
its [checked findings](checked-fable-review.md) are addressed. The later
bootstrap fixture correction passes20 repeats and the full campaign06.
All eleven M0 acceptance items are evidenced; implemented work stays in-review.
Parent M0 credit remains with coordinator verification. Earlier failed/unrun
campaigns remain retained with proven causes and corrections below.

## Acceptance mapping

IDs below follow the four original acceptance items and seven additional refinements in their existing order. “Specified” is M0 contract evidence; later implementation acceptance remains with its milestone.

| Item | Evidence and actual result |
| --- | --- |
| A1 reproducible sources/catalogue, all-source map, sole owners | [Runtime manifest](runtime-manifest.json), [all 50 sources and textual callers](ontology-audit.json), [complete disposition map](retirement-map.md), [live exact catalogue](catalogue.json), [owner contract](../../godot-foundation-contract.md). Common startup loading, composed source inputs and configured/authored reachability are traced in [source-reachability.md](source-reachability.md). No lexical absence is a retirement proof. |
| A2 real protocol fixtures, U/A, operations/results, exact values, deadlines/recovery | [100 concrete signed requests and their index](production-protocol-index.json), [original 83 requests/bindings](production-protocol-fixtures.json), [17 offered Reset requests/bindings](production-controller-reset-fixtures.json). [Production capture](logs/protocol-capture-01.log): five tests passed; [Reset capture](logs/protocol-capture-reset-02.log): one passed. [Cross-owner encoder/signature check](logs/production-wire-03.log) verifies all 100; [exported generic crypto](logs/exported-protocol-final-02.log) independently verifies the first 83. Exact deadline/signing bytes retained; real Stage-1 recovery covers original results after restart/removal. [Public native contract](../../../client/test/fixtures/native-contract/contracts.json) covers non-ASCII, binary and arbitrary integers. |
| A3 maintained crypto/storage, no old bridge | [Final export](logs/godot-export-11.log), [crypto](logs/exported-crypto-final-06.log), [durable storage/SIGKILL results](logs/storage-detail-07/storage-result.json), [TLS](logs/tls-detail-05/result.json), [locked probe sources](probe/Qualification.cs). See qualification and unlock boundaries below. |
| A4 exact cutover/dependency scope, reduction, preservation | [Network boundary](network-boundary.md), [read-only inventory](network-inventory.json), [prerequisite ownership/provenance](prerequisites.md), [source manifest](runtime-manifest.json), [reduction/archive contract](../../godot-foundation-contract.md). Current production delta +377/−598 = **−221 physical lines**; no archive moves. [Line accounting](line-delta.json) records separate test changes (+502/−225) and 21 qualification sources / 1,350 physical lines needed for reproducible probes and gate manifests. Planned active Prolog target 24 production files, seven test fixtures, ≤5,700 nonblank/noncomment production lines. |
| R1 freeze runtime/common/dependencies; pending QUO-37 separated | [46-path coherent prerequisite](inputs/runtime-prerequisite-scope.json), [binary patch](inputs/runtime-prerequisite.patch), [provenance](prerequisites.md), [integrated source manifest](runtime-manifest.json), [compiled artifacts](runtime-build-manifest.json). [Final campaign06](r1-gates-06-result.json) passes native56/EUnit4,247/CT149/xref/Dialyzer; [release02](logs/r1-release-02.json) passes. [Frozen1,559 source inputs](inputs/r1-gates-06-source-manifest.json), [post-release checks](inputs/r1-release-02-source-check.json), [recorded source/cache distinction](inputs/r1-gates-06-copy-hygiene.json), [checked review](checked-fable-review.md) and all earlier failures are retained. |
| R2 seven namespaces/composition/pins/privacy/onboarding/storage | [Authority, identity and signup contract](../../godot-foundation-contract.md), [current space spec](../../spaces.md), [preserved architecture](../../../nimbalyst-local/plans/space-conceptual-architecture-review.md). Exact old anchors are recorded; new random founding anchors are explicit output slots, to be replaced by the M1a receipt. Private signup source is explicitly excluded from public source disclosure. |
| R3 Godot/templates/maintained binding/export/exact values/active keys | [Pinned engine/templates](inputs/godot-artifacts.json), [.NET/package locks](probe/M0.csproj), [Debug lock](probe/packages.Debug.linux-x64.lock.json), [export lock](probe/packages.ExportRelease.linux-x64.lock.json), [toolchain](toolchain.json), [export hash manifest](export-manifest.json), final checks listed under A3. Active plaintext-key protection/unlock is specified separately below. |
| R4 existing governed founding and old resource recipe | [Ordered founding contract](../../godot-foundation-contract.md), [exact node/root inputs](source-reachability.md), [root/jobs/groups/allocations/volumes/ingress](network-boundary.md). M1a executes clean genesis; M5 reuses that recipe and rechecks resource IDs/routing before removal. |
| R5 Erlang/Prolog outdated destinations/exclusions/obligations | [Every-source disposition map](retirement-map.md). Both archive roots are outside compiler/resource roots; application module lists, package lists, bootstrap and source loaders must exclude them. No complete Erlang runtime owner is proved obsolete. Relocation/retained archive counts are separate from active reduction. |
| R6 ordinary S0/A/ownership/storage/original-result recovery | [Onboarding atomic transitions, demonstrated construction gap, grants and recovery](../../godot-foundation-contract.md); [space spec](../../spaces.md) and [architecture](../../../nimbalyst-local/plans/space-conceptual-architecture-review.md) maintained. U/A differ; S0 is ordinary/parentless/U-owned; black empty interior has controllers/GUI. Optional construction-time initial occupants use existing parts/placement in M1a. M2/M3 child creation/entry and selectable real-size wireframe are explicit. |
| R7 recursive contents/frames/physics/disclosure/cycles/dependencies | [Portable recursive fixture](recursive-contract.json), [real Godot Transform3D composition](logs/exported-crypto-final-06.log), [existing physics owner and concrete shared-domain adapter gap](../../godot-foundation-contract.md). M3 must prove live recursive rendering and applicable contacts/control; this fixture is not that integrated proof. Broader D5/D6 remain open. |

## Runtime and source qualification

[prerequisites.md](prerequisites.md) identifies the prerequisite owner, original qualified base/patch, all 46 imported paths and the browser/planning delta left in main. All imports matched correction08/release-gates-04 hashes. The separately scoped [policy documentation patch](inputs/runtime-policy-doc.patch) is retained. Current runtime is never inferred from a tracker label. The imported source is frozen here; any subsequent runtime/common/base/dependency change requires affected checks again.

The initial pre-R1 tree compiled successfully: [command/status](logs/runtime-compile-01.json), [full log](logs/runtime-compile-01.log). Two first EUnit attempts cancelled during cold OpenTelemetry loading before any test body. A deterministic disposable tmpfs source copy retained every source hash and dependency, without creating another Git worktree or branch. Its [focused command/status](logs/runtime-focused-tmpfs-03.json) and [full log](logs/runtime-focused-tmpfs-03.log) passed **462 tests in 19 modules**. These cover material policy, proof/savepoint/context/scope, wire/router/ask, atomic/DTX, signed client/auth/result, space/creation, portable GUI, controllers, personal-agent custody and lifecycle. Repeat-read fixtures verify unchanged reads perform no history replay, rebuild, disk write or sync and actual updates remain durable. [xref](logs/xref-01.json) passed on the same production inputs.

The original [remote-policy-02](logs/remote-policy-02.log) and [path-order experiment](logs/remote-policy-03.log) failed fixture startup at its unchanged 5,000ms peer-call deadline, before any body. [Stack-only diagnostics](logs/boot-diagnostic-02.log) and [file-search counts](boot-file-search.json) identified uncached inherited paths. OTP26+ explicitly supports directory caching for fixed compiled paths. The worker's [four-line test-fixture patch](inputs/worker-ct-cache.patch) caches the peer's actual installed paths, retains all exact-build assertions, and changes no runtime/common/dependency input or deadline. An initial cache attempt using parent paths failed with `bad_directory` ([remote-policy-04](logs/remote-policy-04.log)); the actual installed peer paths succeed. **[Remote-policy-05](logs/remote-policy-05.log) runs and passes the real test body.**

[Remote-path-regressions-06](logs/remote-path-regressions-06.log) passed the two fresh-symbol cases, then failed `remote_signed_gateway_read_execute_cursor` while resolving its already committed operation. The equality of the 5,000ms outer/inner bounds did not establish a timing race. Bounded [diagnostic 10](logs/outcome-diagnostic-10.log) proves the target had the committed slot/result, certification returned promptly, and the exact canonical response frame reached the requester. The endpoint rejected that response as `bad_etf`: the binding contained domain symbol `meat`, absent from the requester's atom table. No operation was resubmitted.

The [scoped worker patch](inputs/worker-outcome-codec.patch) uses the existing `quod_safe_term:decode_wrapped/2` at the endpoint's inner-value boundary. That owner verifies the original canonical ETF bytes and retains unknown symbols as opaque values without creating atoms. Fixed namespace/request/response admission, exact correlation, signed/certified view, wire v13 and caller deadlines remain unchanged. There is no new process, state, retry or local-result fallback. [Endpoint regression before the fix](logs/endpoint-symbol-regression-red-01.json) failed exactly the positive unknown-symbol outcome; [after the fix](logs/endpoint-symbol-regression-green-02.json) all **23 tests pass**, including malformed/noncanonical/unknown-control rejection and exact >uint64/binary values. [All four original remote cases](logs/remote-symbol-outcome-green-07.json) pass unchanged: gateway read/execute/cursor, both fresh-symbol paths and local/remote policy refusal.

[Worker hashes](inputs/worker-outcome-codec.json) and [validation input manifest 05](inputs/validation-source-manifest-05.json) separate this fix from the imported prerequisite. Forty-four imported paths remain byte-identical; `src/quod_dtx_endpoint.erl` has this decoder correction, `test/quod_ask_SUITE.erl` has the four-line cache correction, and `test/quod_dtx_endpoint_tests.erl` adds the regression. No lifecycle/state owner changes, deadline changes or new domain authority were introduced.

The owner's historical correction08 release-gates-04 passed twelve gates (4,235 EUnit/149 CT); it remains provenance, not current-branch qualification. The initial clean campaign02 followed [README](../../../README.md) and [CI](../../../.forgejo/workflows/gates.yml): native locked tests → full EUnit → full CT → xref → Dialyzer. [Campaign source/dependency manifest](inputs/r1-gates-02-source-manifest.json) pins the cached builder by immutable image ID, **Rust1.90.0**, Cargo1.90.0, OTP28/ERTS16.4.0.2 and rebar3.26.0. Only locked dependency sources were copied; application/dependency beam files and native outputs were rebuilt. Of1,079 dependency input entries,1,076 remain byte-identical. Three generated lexer/parser `.erl` files are regenerated from identical grammar inputs with the pinned container parsetools; only `-file` path/version annotations differ. Their actual compiled-source hashes and contents are retained in the [generated dependency record](inputs/generated-dependencies-r1-gates-03.json). The native gate passes **56 tests**. Full EUnit completed **4,246 tests with one failure**: the Node HTTPS ACL fixture lost a connection during a source read (`UND_ERR_SOCKET`, other side closed). [Full failed campaign](r1-gates-02-result.json) records true exit1 and CT/xref/Dialyzer unrun. [Isolated reproduction](logs/acl-focused-01.json) passes in16.21s on unchanged source; that is not a cause or a replacement full-gate pass. An isolated observed run also passes; a deliberate5.1s client event-loop stall produces ordinary idle closes but still passes, so that hypothesis is not a demonstrated cause. No connection policy, deadline, assertion or retry was changed. The separately labeled `r1-gates-03` campaign ran the identical1,559 source inputs with [bounded, payload-free Node observation](inputs/r1-gates-03-observation-manifest.json) and captured recurrence. That was an intermediate observation; the later state trace below establishes the HTTP cause and qualified correction. Matching [toolchain receipts](logs/ci-toolchain-01.json) are retained. The generic OTP cached image lacked Rust (individual commands exited127); it was not used for qualification. Preparation01 failed while dereferencing a dangling dependency test-fixture symlink, before any gate. Preparation02 preserves and records that relative symlink. The [preparation failure record](logs/r1-gates-01-preparation.json) retains its failure and all unrun gates; no test assertions were changed.

## Clean-client feasibility and selected dependencies

The selected candidate is **Godot 4.7.2 .NET** (`ed1daf0bf`) and matching .NET export templates. Their exact official URLs and SHA-256 hashes are in [godot-artifacts.json](inputs/godot-artifacts.json). Selection is supported by the [official Godot maintenance release](https://godotengine.org/article/maintenance-release-godot-4-7-2/). Engine/editor and both desktop templates must stay on that exact release for these results.

Use maintained generic **BouncyCastle.Cryptography 2.7.0** for Ed25519, with .NET’s standard `RandomNumberGenerator`, PBKDF2-HMAC-SHA256 and AES-256-GCM. This is an ordinary managed dependency, not a mandatory general binding architecture or custom cryptographic algorithm. The [maintainer release](https://www.bouncycastle.org/resources/new-release-bouncy-castle-c-2-7-0/) and [standard OS-backed RNG API](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.randomnumbergenerator?view=net-10.0) support that choice. [Probe project](probe/M0.csproj), [SDK pin](probe/global.json), configuration-specific lockfiles and [toolchain output](toolchain.json) freeze SDK 10.0.112/runtime 10.0.12/linux-x64 and transitive package integrity. Debug includes Godot’s editor package; ExportRelease has a separate locked graph. Both restore in locked mode.

The qualification project does not reference/link the old Quod Rust core or GDExtension. The final self-contained exported distribution loads BouncyCastle and its packaged .NET runtime with `DOTNET_ROOT` pointing at a nonexistent installation. [Final export](logs/godot-export-11.json), [exact export files/hashes](export-manifest.json), [final crypto run](logs/exported-crypto-final-06.json) and [production request run](logs/exported-protocol-final-02.json) retain commands and true exits. This proves exported Linux dependency loading; it does not establish broad desktop UI, XR or another OS’s export support.

[The existing native public contract](../../../client/native/tools/contracts.mjs) supplies its valid [public fixture](../../../client/test/fixtures/native-contract/contracts.json). The generic probe imports that browser-created encrypted bundle, matches exact public key, request/challenge signatures and request bytes, refuses a wrong passphrase and modified GCM ciphertext, exports a new compatible bundle, and the actual browser key provider imports/signs it. The unchanged format is PBKDF2-HMAC-SHA256, **600,000** iterations, 16-byte salt, AES-256-GCM, 12-byte IV, 16-byte tag and AAD `quod-client-key-v1`. BigInteger/exact text round-trips preserve values above signed 64-bit and uint64; UTF-8 lengths and binary bytes are exact. Runtime OS entropy use is retained in [redacted getrandom trace](logs/entropy-redacted.strace); a successful distinct sample is not itself a proof of entropy strength.

The final export also reconstructs and verifies 83 real signed production fixture requests with the generic Ed25519 dependency. The browser encoder/Node Ed25519 verifies all 100 captured requests including a second offered Reset fixture. Functional goals use the existing term reader; the 21+ hosting commands with authored infix syntax are evaluated by the server’s actual parser in production tests. The projection term reader is deliberately not treated as a parser for arbitrary authored source.

## Active key, launch and durability contract

Preserve the established launch behavior: create/import and durably save an identity offline before connecting; restore the active identity on later launch using its private local file; connect explicitly. The encrypted portable backup requires its passphrase. It does **not** prove passphrase encryption of the active key. The previous active file is protected by private filesystem permissions, and M1b preserves that model unless a separate justified security/product change is resolved. M0 does not introduce a mandatory startup passphrase or silently convert backup encryption into an active-file guarantee.

The bounded Linux probe uses .NET ordinary filesystem operations plus libc directory `fsync`: private directory 0700/file 0600, one writer lease, write a fresh random exclusive temporary file, flush file, atomically rename, sync parent directory, read back. A client must durably retain identity/account and original signed-operation state before dispatch/Connect and recover the original reference after uncertain completion. The probe stores the existing public fixture key payload and original signed request; restoring it reproduces the exact signature. The string `original-U-A-S0` in the storage probe is a fixture reference label, not a claim that M0 provisioned those identities.

[Final storage results](logs/storage-detail-07/storage-result.json) retain every child exit. External SIGKILL at explicit before-rename/after-rename notifications yields **−9**, followed by old/new reference and key/signature recovery respectively. Normal save/update recover durably; a second writer, insecure permissions, corrupt JSON and an active-file symlink refuse. Two unchanged reads leave inode, mtime and SHA-256 unchanged, with **zero fsync/fdatasync and no active-file write open** in the retained syscall traces; a real update has file+directory sync and changes/reloads correctly. These are process-crash tests, not power-cut/storage-controller qualification. Lock file/process diagnostic logs are distinguished from active identity state.

[Final TLS fixtures](logs/tls-detail-05/result.json) use ordinary HTTPS, explicit trusted CA plus hostname/validity validation, no redirect, and a 5-second HTTP deadline. Trusted matching localhost succeeds; untrusted root, wrong hostname and expired certificate refuse. This is public transport authentication; U and A additionally authenticate by exact Ed25519 signed requests at the existing ingress. Revocation was not tested; the local pinned/self-signed trust fixture has no CRL/OCSP service. Private-network certificate trust configuration is recorded separately in the network inventory.

## Production GUI/space obligations

The [protocol index](production-protocol-index.json) links concrete fixture byte/signature records to operation IDs, exact targets, public keys and deadlines. [Controller tests](../../../test/quod_controller_tests.erl) prove human-signed U→A instruction, A execute custody, offered Save and fenced Reset, stale-revision refusal, unrelated-principal refusal, read-only repeat costs and original outcome lookup. [Personal-agent tests](../../../test/quod_personal_agent_tests.erl) cover delegated instruction authority, revocation, exact expiry and original-outcome association. [Signed creation tests](../../../test/quod_space_creation_tests.erl) cover ordinary, foreign storage and cross-owner atomic placement, ownership separate from storage, integer/rational dimensions, generated entity/result refs, rollback, restart, removed-object original results and no constructor replay. [GUI operation tests](../../../test/quod_gui_operations_tests.erl) cover current offered revisions, non-prebound outputs and typed results. Client-auth/goal/router tests in the 462 run preserve signing/parser/cancellation/deadline admission seams.

M1a adds normal signed signup/setup and negative disclosure tests for private receipts/account/preferences/instructions, unrelated humans/agents and public complete-source/view readers. The current source permits public system-source reads for all catalogue entries except root; therefore the new user foundation must be explicitly excluded, not merely renamed from signup. M1b exercises real Godot keyboard/mouse Save/Reset through U→A. M2 tests S1 creation near A, exterior display without entry, plus the finite real-size wireframe recipe, asymmetric/rational extents, transforms and picking. M3 tests same-A S1/S2 entry and recursive contents exposure/withdrawal, cycles, dependency updates and actual authoritative physical behavior. No old bridge fixture result substitutes for those integrated milestone journeys.

[Final consistency check](logs/final-consistency-05-post-review.log) passed the current runtime/prerequisite/source/dependency hashes, all-source maps and target counts, inherited-document preservation, local link targets and final export contents. [Final diff check](logs/diff-check-final-01.json) exited 0.

## Retained failures and limits

Every runner [status JSON index](evidence-run-index.json) records command, cwd, start, elapsed time, true child exit, timeout and diagnostic count; the matching `.log` retains full output. A zero child exit with Godot `ERROR:` diagnostics was not treated as clean qualification. Failed/unrun evidence is retained rather than overwritten.

Failures include the initial census termination; tracker sandbox `Error: kill ESRCH` and QUO-46 resolution failure; inventory null-service handling and wrong certificate path; managed compile namespace ambiguity; editor user-directory errors; missing solution/export config; sandboxed export socket errors; one lockfile incorrectly used for two build configurations; initial wire-example parser mistakes; buffered lock-holder readiness; malformed expired-certificate generation; the cold-loading EUnit cancellations and CT/diagnostic failures above, including the retained invalid-parent-path cache attempt and the then-unresolved signed-gateway remote-outcome timeout (now causally corrected as recorded above). [Production-wire-01](logs/production-wire-01.log) incorrectly assumed arbitrary authored infix goals were projection terms; [production-wire-02](logs/production-wire-02.log) correctly detected that the first capture omitted offered Reset. A second actual production test now supplies it; the final check asserts both Save and Reset.

[Storage-final-05](logs/storage-final-05.log) used the wrong detail-directory environment variable and refused reuse. [Storage-final-06](logs/storage-final-06.log) then exposed an actual Godot shutdown fault: managed `Environment.Exit` after rename produced SIGSEGV (−11), not the requested exit 87, with native cleanup errors. The probe now blocks at an explicit seam and the external harness SIGKILLs it; [storage-final-07](logs/storage-final-07.log) passes the stronger abrupt-process test without graceful shutdown. This does not claim the engine’s `Environment.Exit` failure was fixed. TLS rejection may cause a fixture-server broken pipe; all final transport acceptance/refusal assertions and child exits pass. No failed assertion was silently suppressed or deadline extended.

Shared logs redact 217 randomly generated disposable test private-key tuples across 7 logs, identified by [redaction manifest](log-redactions.json); all other output, line counts, commands and exits remain. The public deterministic key fixture is intentionally public. Raw private-key-bearing logs are outside this tree in a restricted temporary directory and are excluded from the handoff snapshot. No real account private key/token is evidence. Entropy traces omit returned random bytes.

Desktop evidence is **automated Linux headless editor/export**, not an interactive desktop journey. Automated XR **UNRUN**, physical Vive **UNRUN**, Quest **not qualified**. The old native/XR shutdown-failure evidence remains outside this M0 scope; do not relabel it as a pass. The five current server qualification gates and local production release pass as recorded below. A power-cut campaign, other OS exports, live seven-foundation signup and recursive physics remain unrun here.

The [original partial handoff](../../../nimbalyst-local/handoffs/godot-m0-result.md) remains historical. The [current R1 handoff](../../../nimbalyst-local/handoffs/godot-m0-r1-result.md) records source/snapshot identity, model/effort limits, resolved causes and shared tracker limitations. The single authorized Fable review and its independently checked dispositions are retained in [checked-fable-review.md](checked-fable-review.md). The coordinator decides readiness for M1a; M0 starts no later milestone.


## HTTP transport correction after full-gate failures

Campaigns02 and03 each completed4,246 EUnit tests with one original HTTPS ACL
fixture failure, and correctly left CT/xref/Dialyzer unrun. A diagnostic pass
was not accepted as a fix. Bounded repetition reproduced the fault in case3
([repeat07](logs/acl-close-repeat-07.json)) and case7
([state09](logs/acl-state-repeat-09.json)). The latter records the exact server
state at its unchanged5,000ms no-request-line timeout: `active=false`,
`flow=infinity`, empty buffer, no active stream. The next request's bytes had
already been written. After a large body crosses the initial flow window,
queued final body data can reset flow credit while leaving Cowboy2.12 passive;
the later read-body flow command does not reactivate an unlimited-flow state.
This is an HTTP dependency defect, not permission to retry the uncertain write.

The [worker dependency patch and provenance](inputs/worker-http-dependency.json)
replace the locked HTTP stack with **Cowboy2.19.0/Cowlib2.21.0/Ranch2.3.0**.
The maintainer [documents the active packet default change](https://ninenines.eu/docs/en/cowboy/2.13/manual/cowboy_http/)
and [supports OTP27+ for the selected release](https://ninenines.eu/articles/cowboy-2.19.0/).
The [checked upstream source comparison](inputs/http-upstream-flow-mechanism.json)
identifies stream termination as the repair: Cowboy2.12 only rearms a passive
connection in `stream_next` when a queued successor exists. The selected
Cowboy2.19 rearms it in `stream_terminate` even with no successor, before
returning to the next request. The separate `active_n` default change does not
establish that repair. This corrects the original causal inference preserved
in the review snapshot; no maintainer bug-ID attribution is claimed.
No custom dependency fork, local socket
workaround, new owner, changed deadline, budget increase or retry was added.
The old failures, all commands and raw original private-key-bearing logs are
retained under their documented public/private boundaries.

The candidate was qualified in disposable build02 before integration:
[22 focused HTTP/HTTPS tests](logs/http-dependency-candidate-focused-03.json)
and [eight independent full original fixtures](logs/acl-upstream-repeat-10.json)
all pass, including real source/policy ACL, atomic updates, receipt barriers and
unchanged-read no-I/O assertions. Focused02 selected nonexistent test-module
names and ran no tests; it remains a failed harness receipt. Only the verified
`rebar.config`/`rebar.lock` and the documented OTP minimum entered the branch.
The failed build03 remains the unchanged old-stack forensic copy; build02's
subsequent candidate reuse is explicitly recorded. Campaign04 rebuilt from
clean source using the qualified locked dependency sources, without any Node
or server diagnostic instrumentation. Its complete gates now pass before the
single authorized Fable review. Earlier focused old-stack receipts remain
historical; they do not substitute for current-baseline checks.


## Current review boundary

[Campaign06](r1-gates-06-result.json) retains exact ordered commands, full logs
and five true zero exits on unchanged1,559 source inputs: native56, EUnit4,247,
CT149, xref and Dialyzer. [Release02](logs/r1-release-02.json) exits0; the
[post-release source check](inputs/r1-release-02-source-check.json) verifies all
live/build source hashes and1,094 dependency source/resource entries. One copied
compiler index is classified and retained separately below. [Actual compiled
artifacts](runtime-build-manifest.json) cover394 app/beam/native files across
test/default/prod and24 dependency application descriptors, including the locked
Cowboy2.19.0/Cowlib2.21.0/Ranch2.3.0 stack. No release was started, published or
deployed. Exact toolchain: OTP28.5.0.2/ERTS16.4.0.2, rebar3.26.0,
Rust/Cargo1.90.0 and the immutable local image ID in [server-toolchain.json](server-toolchain.json).

Existing signed-zero warnings in unchanged `src/quod_physics.erl:1192` remain
in full logs. Current physical tests pass; recursive shared-domain delivery is
required in M3. Campaign04/release01 remain pre-review successes. Campaign05's
fixture failure and campaigns02/03 HTTP failures retain their true exits and
later unrun gates. The [run index](evidence-run-index.json),
[checked Fable dispositions](checked-fable-review.md) and
[final R1 handoff](../../../nimbalyst-local/handoffs/godot-m0-r1-result.md)
record the complete current boundary. No second review was launched.

## Final bootstrap fixture correction

[Campaign05](r1-gates-05-result.json) retains native56 pass and EUnit4,247/one
failure, with later gates unrun. The certified bootstrap result was correct;
its original test assumed concurrent callback arrival order. The
[test-only patch and provenance](inputs/worker-bootstrap-fixture-source.json)
keep the original assertions and5,000ms deadline, using an existing real-collector
processing barrier before valid-proof delivery. [Twenty repeats](logs/bootstrap-fixture-repeat-02.json)
pass. Campaign06 freezes that final fixture and codec baseline independently.

The [build-input hygiene record](inputs/r1-gates-06-copy-hygiene.json) separates
1,094 dependency source/resource entries from one copied Rebar compiler index
in the original1,095-entry manifest. Its complete input bytes/hash are retained;
[cleanup01](logs/compiler-index-cleanup-01.json) clears it before default-profile
compilation. The test profile generated its own index. The source/output scan
finds zero copied beam/native/object/archive inputs. Current source copying
excludes hidden root tool-cache directories; campaign06's exact used runner
and this explicit cleanup remain reproducible. No runtime source changed.
