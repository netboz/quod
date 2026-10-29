# Read-only Claude Fable occurrence advice

Session ca58432f-ea5c-4d98-aeeb-c92a8e6a120b. Approved source payload; no writes, builds or tests. Advice is consultative, not qualification evidence.

Reading the live recursive scene path and the renderer schema it must fit.

Checked the live tree (now including `quod_physics_frames.erl`, the `framed/2` pose, `physics_frame_member`, `view_frame` in the selection, and the Babylon `paintBodyPoses` semantics). Advice:

## Descriptor: do not add a third `body_pose` argument

A body's source frame is already determined by its definition: `physics_body_definition(W,B,R,_,framed(Path,_),live(...))`. So `reframe(SourceChain, OccurrenceChain)` inside every mark would copy data the owner can derive and would bloat marks that are bounded by `limit(mark_id)`/reply bytes, not by count. The minimal portable form is one new pose atom and one receipt table:

```prolog
%% mark pose, only under an occurrence group of the viewed scene
relative(Parent, body_frame_pose(B, R))
%% selection, generalising the view_frame already added
view_frame(Viewed, ViewChain, [body_frame(B, R, PathId, Transforms), ...])
```

Semantics: the mark's local pose is `inverse(compose(Transforms)) · WorldPose(B,R)` placed under `Parent`. `Transforms` is the exact parent-first list of authored `transform/6` edges for the body's own `framed` path, read once per distinct `(B,R)` through the existing `physics_view_frames/3` and keyed by `space_occurrence_id(Path)`. `body_pose/2` keeps its absolute meaning on the placement path ([scene.js:80](/home/yan/src/quod_worktrees/pearl-stone/client/src/scene.js:80) re-expresses an absolute world pose under the parent), so M1/M2 fixtures stay valid. No pose is copied: the only moving data is the existing per-body frame stream.

Touch points, one clause each: `placed/1` and `attachment_pose/1` ([gui_scene.pl:227](/home/yan/src/quod_worktrees/pearl-stone/priv/ontologies/gui_scene.pl:227)), `model_transform/2` (:419), `scoped_transform/3` (:541), `mark_body/2` ([quod_client_view.erl:578](/home/yan/src/quod_worktrees/pearl-stone/src/quod_client_view.erl:578)), `physics_view_body/3` ([quod_physics.pl:703](/home/yan/src/quod_worktrees/pearl-stone/priv/ontologies/quod_physics.pl:703)). `body_bindings` already tolerates several marks per body (the "Twin" test at quod_physics_tests.erl:2238), so the frame stream needs no change.

## Binding and dependency rules

- **Same selected world only.** `physics_view_body(body_frame_pose(B,R), depicts(_,_,_), W)` must require `physics_body_definition(W,B,R,_,framed(Path,_),_)` and that `Path` is a current `physics_frame_member` chain of W. A decorative occurrence of a body in another domain, or in a nonphysical view, stays a static authored transform. That is a definition, not a fallback, and it is what keeps one native viewer per socket.
- **Fences are already sufficient.** A source-frame move bumps body revision through `physics_reframe_bodies`, so an old `body_frame_pose(B,R)` fails `body_bindings` and the view refreshes. Edge transform reads enter the signed view's read set through `physics_view_frames` (it rechecks `term_digest(frame(Transform,Recipe))` against the member revision), so a representation edit invalidates the view through the normal path. No new notice kind.
- **Emit it from `space_scene_parts` only when `Use = display`** and `space_subject_binding` at the *entity's real container* resolves to a body in the view's world. Today a display reference yields `source_layout` and the entity's own container-local `Layout` (live [quod_space.pl:520](/home/yan/src/quod_worktrees/pearl-stone/priv/ontologies/quod_space.pl:520)), which is the static copy you described.

## Schema, resource and ACL checks

- `limit(scene, 512)` counts marks; `body_frame` rows live in the selection, so they cost reply bytes under `QUOD_CLIENT_GOAL_MAX_REPLY_BYTES`, not scene budget. One row per distinct `(B,R)` keeps that bounded by the body allowance.
- `entity_scene/3` is not in `space_query/1` (quod_space.pl:11 to 17). Both `space_scene_parts` (:511) and `physics_view_frames` call it cross-owner from the viewer's principal. For a foreign edge or source owner the viewer needs that owner's explicit grant; verify it exists in the fixture rather than relying on same-owner U.
- The receipt grants nothing: `body_frame` transforms are committed facts the viewer could already read; the body pose stream still requires `can_view_physics` on the one world.

## Concrete owner-level issues in the live shared-frame paths

1. **Display reference pose is wrong frame today.** For `Relation = display`, `Pose = Layout` is the entity's transform in its own container, applied in the displaying space. Pre-existing, but with nested exposure it now places S2's contents at S2-local coordinates inside S0. `space_member/2` has no pose; a display reference needs its own authored transform at the displaying space or must be refused.
2. **Whole-view failure on one unbound subject.** `physics_scene_binding/5` fails when a placed subject has neither body nor frame nor inert-frame admission, and `space_exposed_subjects` propagates that to the entire projection. Fail-closed is correct, but it is scene-wide, not "that occurrence only".
3. **Body pose and authored location can disagree.** `physics_install_component` takes `Local` from root `physics_component_admission/5`, not from the entity's committed `attribute(Entity, transform, _)`. `space_travel` then moves the authored pose while the body stays at the root's row. Derive `Local` from the source's committed transform in the same transaction, or document that physical placement ignores the attribute.
4. **Mode coupling.** `physics_definition(Space,_,frame(_,Recipe))` and `physics_view_frames` hardcode `playing`; it works because both modes map to the same `recipe(Ns,A,space_contents)`, but an edition-only recipe would silently break the digest match.
5. **Deterministic floats.** `quod_physics_frames:euler/1` decomposes from matrix entries, so `q` and `−q` agree; `normal/1` per multiply is fine. Keep `term_digest` over the integer transforms, never over these floats, which the live code already does.
