# Runtime prerequisite provenance

Owner: session `bcf9e26a-2ac6-4f06-a3bc-39c914de2aeb` (Vive stage-1 acceptance), pending work related to [QUO-37](nimbalyst://QUO-37). Current shared issue state remains to-do; its label is not source qualification. The owner narrowed correction08 after rejecting a broader worker/queue expansion. No new worker-pool/resource-allocation framework was imported.

The initial worker tree is committed `f6c29fe925e666dd68ee7fa68c0e03f5d03391a2`. Source files for completed Stage 1 and controllers were already committed. Every imported file was clean in this worktree before integration and matched the exact SHA-256 in the owner's correction08 release-gates-04 input manifest. All 46 paths are frozen in [runtime-prerequisite-scope.json](inputs/runtime-prerequisite-scope.json); [runtime-prerequisite.patch](inputs/runtime-prerequisite.patch) is a reproducible binary patch against this worker base.

Historical qualified source: base `e026d2a42333dbe90d3af4b0c42bcf5ed4940781` plus patch `7e92e5b8f35e1ced960ed7f2126bab7458cc12ab063e6bcdaf08d0e0e022dd74`. The preserved owner record is `/home/yan/src/quod/doc/evidence/stage1-vive-20261025/correction-08/qualification-result.json`; full logs and source manifest are in its `release-gates-04` directory. That record passed all 12 sequential gates (4,235 EUnit, 149 CT, native/client/static/release), and retains failed campaigns 01–03. This is historical verification of the imported prerequisite, not a claim that this newer entire branch passed those release gates.

Imported scope: governed committed proof-heap policy; complete invocation/savepoint/scope/participant vectors without duplicate Erlang population ceilings; preserved encoding/headroom/uniqueness/OCC/cancellation/deadlines; real resource refusals through cohosted/remote paths; exact result decoding; the existing GUI test fixture's missing cross-ontology progress owner; advertised textual IPv4/IPv6 certificate SAN support and its tests. The personal-agent source change is a composition comment. The related policy documentation was imported separately as [runtime-policy-doc.patch](inputs/runtime-policy-doc.patch).

The concrete need is normal storage discovery exceeding the former 64 lifetime invocations, plus atomic source/composition installation and actual target admission. Selecting only constants would remove enforcement ownership without the coherent committed-policy and protocol paths. No changed browser/controller scene, XR runtime, generated browser binary, local tracker, planning or hardware campaign file was imported.

## Read-only main delta classification

| Category | Exact source scope | Disposition / provenance |
| --- | --- | --- |
| browser | `client/patches/README.md`, `client/src/controlled-navigation.js`, `client/src/controller-scene.js`, `client/src/world-scene.js`, `client/src/world-xr.js`, `client/test/controlled-navigation.test.js`, `client/test/controller-scene.test.js`, `client/test/movement.fixture.html`, `client/test/world-xr.test.js`, `client/test/xr-browser-boundary.js` | Preserved in main; not copied. Browser/XR owner is QUO-58 / sessions 7c45b431-c08b-4bfd-a145-3246cf120a05 and dae4037e-4241-4c96-8f50-118adfe9162c. |
| documentation | `doc/gui-examples.md`, `doc/multiwrite-architecture.md` | Preserved in main. Multiwrite policy addition was separately scoped; other documentation/planning did not enter this branch. |
| planning | `nimbalyst-local/plans/quo-58-webxr-startup-correction.md`, `nimbalyst-local/tracker/tasks.md` | Preserved in main. Multiwrite policy addition was separately scoped; other documentation/planning did not enter this branch. |
| runtime-prerequisite | `include/quod_proof_limits.hrl`, `priv/ontologies/material_policy.pl`, `priv/ontologies/personal_agent.pl`, `src/predicates/quod_ask.erl`, `src/predicates/quod_common_primitives.erl`, `src/quod_ask_router.erl`, `src/quod_atomic.erl`, `src/quod_client_goal.erl`, `src/quod_client_result.erl`, `src/quod_client_tls.erl`, `src/quod_dtx.erl`, `src/quod_dtx_coordinator.erl`, `src/quod_dtx_current_view.erl`, `src/quod_dtx_endpoint.erl`, `src/quod_foreign_log.erl`, `src/quod_material_admission.erl`, `src/quod_operation_vector.erl`, `src/quod_outcome.erl`, `src/quod_prolog.erl`, `src/quod_proof_context.erl`, `src/quod_proof_session.erl`, `src/quod_scope_session.erl`, `src/quod_scope_wire.erl`, `src/quod_transaction.erl`, `src/quod_transaction_scope.erl`, `test/quod_ask_SUITE.erl`, `test/quod_ask_router_tests.erl`, `test/quod_ask_tests.erl`, `test/quod_atomic_tests.erl`, `test/quod_client_result_tests.erl`, `test/quod_dtx_deadline_tests.erl`, `test/quod_dtx_tests.erl`, `test/quod_gui_question_tests.erl`, `test/quod_lifecycle_single_path_tests.erl`, `test/quod_material_admission_tests.erl`, `test/quod_operation_vector_tests.erl`, `test/quod_physics_control_tests.erl`, `test/quod_prolog_scope_target_tests.erl`, `test/quod_prolog_tests.erl`, `test/quod_proof_context_tests.erl`, `test/quod_proof_session_savepoint_tests.erl`, `test/quod_proof_session_tests.erl`, `test/quod_proof_trace_tests.erl`, `test/quod_schema_tests.erl`, `test/quod_scope_session_tests.erl`, `test/quod_scope_wire_tests.erl` | Imported only exact qualified paths above. |

## Invalidation rule

A subsequent runtime/common source, dependency or foundation source change invalidates the affected receipt. Compare full manifests, rebuild compatible predicate artifacts, and rerun focused checks plus M1a fresh founding/journey checks before using its evidence. Do not copy mutable main sources or trust a prior ticket status. The immutable M0 handoff snapshot supplies this exact baseline.

Current integrated production physical delta versus worker HEAD: +377 / −598, net −221 lines. Qualification probes are evidence code and reported separately; no seven-foundation replacement or retirement move was implemented in M0.

## Worker verification corrections

The original 46-path import and historical owner receipt remain immutable provenance. Forty-four imported paths still match exactly. The four-line [peer cache correction](inputs/worker-ct-cache.patch) changes only `test/quod_ask_SUITE.erl`: OTP caches its actual fixed installed code paths, preserving exact-build assertions and deadlines. The [endpoint decoder correction](inputs/worker-outcome-codec.patch) changes only the inner ETF decoder in `src/quod_dtx_endpoint.erl` and adds a production-codec regression in `test/quod_dtx_endpoint_tests.erl` (not an imported path). [Before/after hashes](inputs/worker-outcome-codec.json) and [validation manifest05](inputs/validation-source-manifest-05.json) identify this worker-owned delta.

The retained gateway failure was a rejected valid outcome response, not a demonstrated deadline race. Exact bytes reached the requester; an unknown Prolog symbol made the old atom-table-dependent decoder return `bad_etf`. The shared canonical opaque-symbol decoder resolves it without allocating atoms or changing the wire, deadlines, certification, correlation, outcome semantics or original request. Endpoint EUnit shows red-before/green-after; all four actual remote cases pass. See the [causal evidence and gate index](README.md#runtime-and-source-qualification). No lifecycle/state owner was added or changed.

The separately worker-owned [HTTP dependency correction](inputs/worker-http-dependency.json) changes `rebar.config`/`rebar.lock` to Cowboy2.19.0, Cowlib2.21.0 and Ranch2.3.0; README records their OTP27 minimum. A bounded real fixture reproduces Cowboy2.12's passive/unlimited-flow state after a large request. The qualified upstream stack passes 22 focused HTTP/HTTPS tests and eight independent original ACL fixtures. No deadline, assertion or uncertain operation was changed. This scope is additional to the original 46-path import.

The uninstrumented [clean campaign04](r1-gates-04-result.json) passes native56, EUnit4,246, CT149, xref and Dialyzer sequentially on [1,559 frozen source inputs and1,094 dependency entries](inputs/r1-gates-04-source-manifest.json). The [production release](logs/r1-release-01.json) also passes without starting or deploying it. All current source/dependency hashes were checked after assembly; earlier failed campaigns remain retained. These current-baseline results precede the single authorized Fable review and replace the earlier partial qualification limit.

The single authorized Fable review completed on immutable snapshot03. Its
[checked boundary finding](checked-fable-review.md) adds complete-inner-frame
producer admission through the existing canonical decoder, with no receiver
limit/deadline change. [The separate patch](inputs/worker-review-depth.patch)
and [current hashes](inputs/worker-review-depth-source.json) preserve that
additional worker-owned delta. Final campaign06 passes native56/EUnit4,247/CT149/xref/Dialyzer and release02
on the corrected source; campaign04 remains valid pre-review history. The
separate bootstrap fixture synchronization preserves all original assertions
and deadline and passes20 repeats plus the full campaign. Source and copied
compiler-metadata provenance are recorded in the final R1 handoff.
