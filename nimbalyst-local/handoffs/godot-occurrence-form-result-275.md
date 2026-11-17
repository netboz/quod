# Selected occurrence forms and shared solid material — bounded QUO-24 result

The selected instance's existing ontology-authored form now stays associated
with the chosen visual occurrence. The user can deliberately place that same
form near the occurrence or in the personal workspace and return without
recreating its native controls, controller or draft. This works for the current
world and an independently rendered, signed Eidolon preview. Two occurrences of
one exact subject remain distinct presentation targets. The separate shared
solid-material correction now produces different shading on differently oriented
faces and retains authored material factors.

This is the sole writer's bounded software result, following the
[review and Claude reconciliation](godot-spec-conformance-review-275.md) and
[45-item inventory](../../doc/evidence/godot-vr-gui-alignment-20261101/conformance-review-274.md).
It is not full GUI, Stage2, M4/M5, browser, release or human/HMD acceptance.
Coordinator integration remains separate. Existing QUO-24 and user authority
remain authoritative; tracker body publication is still blocked and was not
retried. No replacement item, plan or checklist was created.

## Interaction and owner map

| Responsibility | Existing owner and delivered behavior |
| --- | --- |
| Semantic subject, offer, authorization, action and result | Existing class-selected recipe and `gui_forms` owners are unchanged. A class can define recipes in its own ontology. No class-specific client action, new ontology, wire schema or domain executor was added. |
| Exact visual selection | [ScenePanel](../../client/godot/ScenePanel.cs) carries owner, mark ID, installed incarnation and exact subject together. Pose/corners resolve through that live owner. Press on occurrence A and release on B cannot select B merely because their subjects match. Removal/reuse cannot revive an old selection. |
| Form and placement | [Main](../../client/godot/Main.cs) passes selection to the same [EidolonPanel](../../client/godot/EidolonPanel.cs), which uses its existing OperationsPanel/FormPanel. Near/personal is local presentation, with no domain instruction or change to semantic revision, target, draft or original outcome. Unplaced/removed visuals expose the explicit personal alternative. |
| Acyclic native rendering | [SpatialGui](../../client/godot/SpatialGui.cs) constructs the one form tree once in FormSurface. The preview ScenePanel is outside that tree. Desktop mirror, existing personal/current-world plane and preview-owned near plane sample the same form texture; the preview never samples a texture containing itself. Installed lifetime owners are not detached/reparented. |
| Input and adjacent text entry | Existing native routing/capture owns the root and form viewports; the same [keyboard](../../client/godot/SpatialKeyboard.cs) edits the actual focused native editor. [OpenXRInput](../../client/godot/OpenXRInput.cs) keeps signed, tracking, focus, menu/modal, neutral and release fences. Geometry/lifetime changes cancel capture. Software spatial composition does not start native XR. |
| Refresh and retirement | Main/SignedView explicitly distinguish same-owner Updating from terminal withdrawal. Updating immediately hides/revokes interaction while retaining inert resources; acceptance restores the exact occurrence. The preview reader lives only for its installed authorized visual consumer and retires on denial, subject or consumer replacement. |
| Material | [Core/Scene](../../client/godot/Core/Scene.cs) retains validated metallic/roughness/emission; ScenePanel applies them to shared lit solids with neutral adapter lighting. Wires remain unshaded and labels opaque. This adds no domain sun, terrain, room or physical-body model. |

Desktop uses a bounded task region beside the scene where space permits, and the
existing full-width alternative for enlarged/narrow layouts. Spatial composition
places the form above the selected visual in that visual's own coordinate system;
preview coordinates are never silently treated as current-world coordinates.
Orientation is stable until a deliberate placement change, not head-follow.

## Causal baselines and corrections

[Occurrence baseline02](../../doc/evidence/godot-occurrence-forms-20261101/inputs/occurrence-baseline02.json)
passes eight prerequisites then fails the actual occurrence/pose assertion:
the old picker exported only the subject. The corrected path retains exact
occurrence identity, including a non-space instrument and authored space actions.
Lifetime11 separately reproduced the Updating-order defect that discarded the
selected incarnation before suspending its view; the current explicit refresh
disposition preserves it inertly without weakening terminal withdrawal.

[Preview baseline17](../../doc/evidence/godot-occurrence-forms-20261101/inputs/occurrence-preview-baseline17.json)
proves that selecting the offered operation withdrew its own preview: pose null,
zero preview marks, field installed but invisible. The coordinator reconciled
the form-only viewport extension against the original specification. Current
preview117 qualifies that correction, not merely the earlier narrow retention
check. The [surface disposition](../../doc/evidence/godot-occurrence-forms-20261101/surface-binding-disposition.md)
records the render dependency and all intermediate failures.

The original273 material baseline sampled three faces as exactly `6a90d9ff` and
hit its original pre-completion bound. It remains a whole failed run. The selected
material15 uses the same face assertion and shared material methods: sampled
faces are `6f94ddff`, `405988ff`, `415a8aff`, maximum difference0.24967319. It also
checks resource retention, a real authored update, metallic/roughness/emission,
wire/label distinction, malformed refusal and retirement. This establishes
software material behavior, not comfortable Vive shape perception.

Affected regressions were corrected at their actual owners: native FormSurface
allocation now follows MinimumSizeChanged; spatial presentation listens for form
size even without native tracker attachment; the owned unused FormMirror is
freed; root native mouse motion carries the native previous-position delta.
Workspace25's stale ancestor cast was diagnostic-only; workspace26's original
relative-motion assertion genuinely failed and now passes unchanged in27.

## Actual qualification

[result.json](../../doc/evidence/godot-occurrence-forms-20261101/result.json) has
`passed=true` and `evidence_verified=true`. Qualification wrapper and child exit0.
The selected gates are:

| Case | Actual checks | Actual completion |
| --- | ---: | --- |
| Current-world interaction27 | 91 | client/server/wrapper0; four EOF |
| Embedded-preview interaction27 | 117 | client/server/wrapper0; four EOF |
| Lifetime24 / authored space24 / desktop occurrence input25 | 29 / 40 / 14 | each client/server/wrapper0; four EOF |
| Native workspace27 | 36 stored +9 native probes =45 PASS lines | client/wrapper0; two EOF |
| Native keyboard21 / controller21 | 169 / 86 | each client/wrapper0; two EOF |
| Root keyboard ray21 / form keyboard ray22 / scene23 | 16 / 16 / 12 | each client/wrapper0; two EOF |
| Separate material17 | 15 | client/server/wrapper0; four EOF |

Selected cases have no reader/timeout/cleanup failure and zero host input/native
XR. Current27 world/preview/workspace use the selected product vector. Earlier
selected cases retain explicit intervening-input dispositions in the aggregate:
documentation; the removed obsolete Main body-child exception; native size and
relative-motion corrections qualified by27; and the WorkspaceChecks ancestor
lookup not executed by other phases. Material17's responsible decoder and exact
ScenePanel material methods remain byte-identical. These are deliberate reuse
boundaries, not a claim that every historical full vector equals current source.

Signed tests bind all14 current server resources, exact qualified runtime
objects and four fresh fixture outputs. No core/server release rebuild or broad
unchanged suite ran. Three accepted unchanged world/form and preview/form
renewals plus near/personal transitions retain native resources and record named
history/projection/rebuild/write/sync `work.calls=[]`, local writes0. Real movement,
authorized action/readback, removal, denial and changed-subject replacement still
execute. The original action/result identity survives relocation; no uncertain
submission is replayed. Existing computed lenses retain their necessary cursor
reevaluation on accepted refresh.

Actual26/48/narrow and spatial rasters were inspected, including current27
current-world form, narrow field/selection and preview-near form. Their native
clip and pointer/keyboard checks qualify usable software targets; bounded task
scrolling is recorded where used. They do not prove apparent angle, reach,
headset pixels or human understanding. The [retained failures](../../doc/evidence/godot-occurrence-forms-20261101/retained-failures.md)
include input17's behavior-complete original60-second noEOF failure. Later normal
exits establish no historical shutdown cause/fix. Preview23 has110 passing
prefix checks; an earlier progress report understated that prefix as109.

## Exact source, product and custody

HEAD remains `293cf6115c0a6b18315eccdbb42cbca396f443d3` on
`worktree/pearl-stone`, with an empty index and accepted/user changes preserved.
Against accepted262 source, production is **372 added /124 removed, net248** in
nine existing files. Growth supplies the missing occurrence lifetime, single
form-only rendering/input binding and affected material owner, without a new
framework. Existing test files add9/remove8; README adds23/removes1. The separate
four-line AGENTS addition is Yan's same-ontology recipe rule. All31 agents remain.
Unaccepted273 attention edits remain in separate before-copies, patch and build
trees; they are absent from selected production.

Trace-free `occurrence-product01` has98 live=supplied inputs,196 export files,
193578580 bytes, five source-only build phases and outer0. It is PRIVATE,
`distributable=false`, without diagnostic overrides; no archive was refreshed.

- [Product manifest](../../doc/evidence/godot-occurrence-forms-20261101/inputs/client-occurrence-product01-manifest.json): `d67294b8bfe7f7f2dfdba9b65f48815b66dfc4409dad73d966455c1f0eb7d406`.
- DLL: `7b32926a8e2aebff4c90f8dc918b66e2d70b42f21cb399a199a10be07f720b2d`; PCK: `ccb78f3bd54206033f7b8ce3b4b570c81adc1acfbf3c70e82fa9f40eb13af424`.
- Engine remains `02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268`; pinned dependencies unchanged.
- Qualification cache `/data/quod-m4-vr-ca84d4f8-20261029/cache/occurrence-qualification01-hashes.json`: `2e823f65e5827db725ef64d9d3bcfce588c4a89619b96ecf742c1369c18d3b07`. All inherited stat keys, including pathless rows, are retained. Reuse requires authenticated SHA and exact stats or controlled-copy provenance.

The exact sparse freeze owner is
[freeze.py](../../doc/evidence/godot-occurrence-forms-20261101/freeze.py).
Its external true-exit/completion receipt is
`/data/quod-m4-vr-ca84d4f8-20261029/artifacts/occurrence-form-freeze-runs01/result.json`;
the immutable target is `artifacts/quod-occurrence-form-handoff-ca84d4f8-20261101-01`
under the same Data root. Only an actual successful receipt establishes sealing;
this document's existence does not. Separate copies of all14 changed inherited
files precede real binary patch check/apply and actual tar reconstruction, with
bytes/types/literal links/full modes checked. New263–275 source/evidence is included
against accepted262; prior private profiles/pending work remain preserved in place.
No full inherited tree, old export/archive/API/history recount, old inode links or
chmods are used. Large caches, raw logs and materializations stay private in Data.

One old AGENTS before-source exact-stat key was absent from262's cache. Only that
8636-byte ordinary source was freshly checked against its authenticated accepted
index and separately copied; no inherited custody was invented. Whole current
inbox9 bodies were read once at the seal boundary and saved in
[integration-before-seal.json](../../doc/evidence/godot-occurrence-forms-20261101/inputs/integration-before-seal.json).
The available tool lists messages; it does not consume them.

## Remaining limits and later human task

Compact attention, exact deferred-question subject binding/recovery, broader
component and authored asset families, authored browser appearance and measured
device ergonomics remain open. Backup/import stays desktop-only; the native
keyboard is the existing fixed subset. This local selected-occurrence binding
does not claim arbitrary ontology-authored surface geometry or asset support.
No headset/runtime, physical input, deployment, global configuration, package,
new reviewer, commit or later ticket was started.

For a later separately authorized human check: select one of two visible
representations of an instance; identify whose form appeared; enter an unsent
value, move it to the personal workspace and back, and verify the value remains.
Then deliberately submit one offered action and read its result. Ask whether the
association, controls and solid shape are understandable and comfortable. No
human opportunity is opened by this handoff.
