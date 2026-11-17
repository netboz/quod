# Unapplied shared-boundary proposals

These patches are review artifacts, **not production changes**, not compiled or executed. Automatic approval review rejected both corresponding production actions before execution. The parent explicitly requested these artifacts and will obtain approval. Do not apply them as an indirect retry.

## Nested invocation owner

`nested-goal-owner.patch` removes the separate 128 KiB nested-goal quota consistently, without splitting the model call or changing deadlines. Its exact source hashes and proposed delta are in `nested-goal-owner.json` (+8/−13, net −5).

The actual failed route is ordinary `space_exposure_projection` → exact pinned `in_ontology(...,model(Parts,Marks))` → `quod_scope_session:valid_invocation_input/4`. `diagnostic-signed04` records a 159,879-byte goal, nonempty caller chain and valid transaction selection, refused as `protocol_error,request_binding`. The full source catalogue has 285 predicates and requires 570 marks after retiring two shortening helpers. The observer measured 858 catalogue enumerations; it does not establish timing attribution for each call. The broader observer in `diagnostic-signed03` changed the terminal symptom to `proof_limit_exceeded` and is not equivalent performance evidence.

The proposal retains exact invocation ID, principal/chain, selected scope, authorization reproving, canonical atom-safe decoding, original deadlines, pinned proof heap/answer admission and whole durable-plan admission. A transcript goal already carried inside an admitted canonical plan does not acquire a second allocation quota. Remote scope payloads still have their existing complete scope-envelope owner; this is **not** a claim that that envelope or its enclosing network quota is an intrinsic encoding limit. The change is broader than a scene schema edit and needs the requested explicit approval.

Affected verification after approval: retained full-catalogue signed diagnostic and `LimitsChecks.cs` (actual native catalogue, long exact name, policy denial/withdrawal, stale selected contents, real committed catalogue update, cycle, reconnect, unchanged counters); focused scope-session/proof-session/scope-wire/DTX authorization and finite material-policy refusal tests. Retain malformed identity/chain/selection and denied-source cases. Do not change byte budgets/deadlines in tests to obtain green.

## Signed result and view owner

`presentation-reply-owner.patch` removes duplicate 512 KiB result/view and endpoint-envelope quotas through the current wire/result/view/endpoint owners. Its exact source hashes/delta are in `presentation-reply-owner.json` (+40/−67, net −27). It adds no alternative encoding, stream or compatibility route. `reply-baseline01` is a real `quod_client_result:normalize/2` baseline: one 600,000-byte binding is refused as `{error,result_too_large}` before transport.

Keep finite callers of `quod_wire_term:encode_bindings/2` unchanged; `unlimited` explicitly defers the result owner's duplicate byte check to already-admitted proof work. Safe decoding remains canonical, rejects compressed ETF/trailing bytes and unknown shapes, and cannot create atoms. Requests keep their existing signed ingress validation. View expiry/revocation/cancellation and GUI receiver capacity remain unchanged. Keep endpoint `too_large/0`: complete outgoing and incoming endpoint envelopes are checked against the existing `QUOD_TRANSPORT_MAX_FRAME_BYTES` admission policy. `quod_link:frame/1` only adds the length prefix, so relying on receiver refusal alone would lose a clean local failure. The redundant endpoint-envelope macro is retired; this does not raise or copy a limit.

Affected verification after approval: the separate unapplied `presentation-reply-tests.patch` updates obsolete quota expectations in `quod_client_result_tests` and `quod_client_goal_endpoint_tests`; preserve malformed result, dependency, identity, correlation, compression and canonicality refusals. Exercise complete >512 KiB result round trips and actual signed native projections/GUI preparation. Proposed tests cover >512 KiB complete results, exact dependency retention, malformed-result refusal, endpoint round trips and explicit encode/decode refusal above the existing network envelope policy. They are review artifacts, not applied or executed. `git apply --check` validates only patch applicability.

## Remaining boundary work, not hidden in either patch

- The proposal retains the old reply constant solely because `quod_terrain_wire` and its tests still consume it; it removes the unused endpoint-envelope constant. The response patch alone is **not complete retirement** of 512 KiB presentation policy. `quod_terrain_wire:admit/3` refuses large manifests/chunks; `batch/2` packs a retained resource selection to that quota. `quod_physics:deliver_terrain` / `deliver_resource_snapshot` and acknowledgement callers must be corrected together after approval. No copied or raised default is proposed. Stage 3 domain/physical policy remains separate.
- `include/quod_transport_limits.hrl` sets a 1 MiB network frame policy, enforced by `quod_link:parse_one`; it is not intrinsic ETF/WebSocket capacity. Existing protocol length fields and canonical grammar are separate. The revised endpoint patch retains explicit whole-envelope encode/decode refusal against that existing network policy. Removing the response subquota does not make cross-node large projections unbounded. There is no demonstrated Prolog owner for changing this general transport ingress allocation in this slice. That broader ownership must be resolved rather than claiming success, weakening admission blindly or substituting pagination.
- Shared term depth 64 is an existing structural safety policy, not an encoding theorem; directory namespace 255 and signed-input/parser quotas are separate shared ingress policies. They were audited but neither changed nor renamed “physical limits.” Current selected long-name tests cross retired presentation maxima while remaining valid for the installed identity protocol.
- Generic browser `mesh_asset`/terrain descriptors accept `unlimited`; explicit finite allowances remain checked against measured costs. Native `SceneMark.Decode` currently supports box/wire_box/sphere/group only. `ControllerMapping.Decode` consumes the separate `tracked_model(...,asset(...))` profile with the existing explicitly finite authored controller allowances. `ModelAsset`, `StaticGlb.Admit`, `Transport.Model` and `RenderModels` are live profile owners, not superseded generic-mesh mirrors; no native mesh/terrain capability is claimed here.

## Review revision 02

The original proposal artifacts remain frozen in `stage2-presentation-limits01`.
The current production proposals are +8/−13 (nested goal) and +40/−67
(result/view/endpoint), net −32 combined. Separate proposed test deltas are
+8/−12 and +33/−54. No production or test patch was applied, compiled or run.
All four patches pass `git apply --check` against their exact recorded source.
The nested-goal tests retain whole-scope encoding refusal and replace only the
retired per-invocation quota expectation. The result tests retain malformed,
canonical, dependency and transport-envelope obligations. Finite pinned proof
admission tests remain applicable and must run after approval.

The remaining terrain-wire 512 KiB admission/packing caller is explicitly outside
these two patches, not silently accepted or called an encoding constraint. A
consolidated approval should cover retiring its obsolete `admit/3`, `batch/2`,
physics delivery-prefix acknowledgements and browser `through` acknowledgements
together, with their terrain-wire, signed physics and terrain-delivery tests.
Preserve exact requested chunk sets, stale token/interest rejection, measured
finite resource admission and retained unchanged resources. This caller closure
and any resulting artifact updates remain required before the overall request
can be marked complete; no alternate stream or replacement quota is proposed.
