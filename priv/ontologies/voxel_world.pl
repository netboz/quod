%% Composable terrain domain. The owning ontology supplies ACLs, physics
%% configuration, resource policy and initial coverage. No actors are founded
%% here, and exploration changes no durable facts.
isa(voxel_world, quod:space:physical_space).
isa(bounded_voxel_world, voxel_world).
isa(unbounded_voxel_world, voxel_world).

voxel_world_definition(_,_,_) :- fail.
voxel_world_owner(_,_) :- fail.
voxel_chunk_override(_,_,_,_) :- fail.
voxel_allowances(_,_) :- fail.
voxel_initial_chunks(_,_,_) :- fail.
can_create_voxel_world(_,_) :- fail.
can_edit_voxel_world(_,_,_) :- fail.
can_manage_voxel_world(_,_,_) :- fail.

voxel_world_state(W,Revision,Spec) :-
    findall(definition(R,S),voxel_world_definition(W,R,S),Rows),
    (Rows = [] -> Revision = 0, Spec = none
    ; Rows = [definition(Revision,Spec)] -> true
    ; fail_with_reason(ambiguous_voxel_world(W))).

voxel_expected_world(W,Expected,Spec) :-
    voxel_world_state(W,Revision,Actual),
    (Revision = Expected -> true ; fail_with_reason(voxel_world_conflict(W,Revision))),
    (Spec = Actual -> true ; fail_with_reason(voxel_world_exists(W))).

%% The physical binding is derived from the ordinary body definition. Its
%% revision belongs to physics; no independently writable terrain binding.
voxel_terrain_binding(W,Body,Revision) :-
    physics_body_definition(W,Body,Revision,fixed,vector(0,0,0),
                            owned(voxel_field_v1(W,_,_),1)).

voxel_create(W,Expected,Spec) :-
    term_variables([W,Expected,Spec],[]),
    transaction((current_principal(P), can_create_voxel_world(W,P),
        voxel_expected_world(W,Expected,none),
        voxel_initial_selection(W,Spec,Chunks),
        \+ voxel_terrain_binding(W,_,_), \+ voxel_chunk_override(W,_,_,_),
        (Expected = 0 -> true ; retract(voxel_world_definition(W,Expected,none))),
        Revision is Expected+1, assertz(voxel_world_definition(W,Revision,Spec)),
        findall(Owner,voxel_world_owner(W,Owner),Owners),
        (Owners = [] -> assertz(voxel_world_owner(W,P)); Owners = [_]),
        (instance_of(voxel_world,W) -> true ; assertz((instance_of(voxel_world,W) :- true))),
        voxel_validate_chunks(W,Chunks),
        physics_body_capacity(W,1), physics_allocate_body(W,Body),
        term_digest(Spec,Digest), Shape = voxel_field_v1(W,Revision,Digest),
        physics_required_allowances(W,limits(_,_,_,Coordinate,_),_,_,_),
        physics_checked_body(Body,fixed,vector(0,0,0),Shape,1,Coordinate),
        physics_advance_structure(W,Structure),
        assertz(physics_body_definition(W,Body,Structure,fixed,vector(0,0,0),owned(Shape,1))))).

voxel_initial_selection(W,Spec,Chunks) :-
    voxel_sampling_field(Spec,Field), voxel_limits(W,Sampling,_,_,_,_),
    '$quod_voxel'(sample(Field,vector(0,0,0),dimensions(1,1,1)),Sampling,_),
    findall(Cs,voxel_initial_chunks(W,Spec,Cs),[Chunks]), Chunks = [_|_],
    voxel_unique_chunks(Chunks), voxel_chunk_allowance(W,Chunks).

%% Rebuilding or removing terrain requires an empty physical space. Occupants
%% leave through existing placement/withdrawal actions; this action cannot
%% discard their assignments, controls or recovery state.
voxel_lifecycle_basis(W,Revision,Versions) :-
    current_principal(P), can_manage_voxel_world(W,P,_),
    voxel_world_state(W,Revision,Spec), Spec \= none,
    voxel_patch_versions(W,Versions).
voxel_patch_versions(W,Versions) :-
    findall(C,voxel_chunk_override(W,C,_,_),Rows), sort(Rows,Chunks),
    voxel_chunk_versions(W,Chunks,Versions).

voxel_regenerate(W,Expected,Versions,Spec) :-
    Spec \= none, voxel_redefine(W,Expected,Versions,Spec,regenerate).
voxel_remove(W,Expected,Versions) :- voxel_redefine(W,Expected,Versions,none,remove).

voxel_redefine(W,Expected,Versions,Spec,Operation) :-
    term_variables([W,Expected,Versions,Spec],[]),
    transaction((current_principal(P),can_manage_voxel_world(W,P,Operation),
        voxel_world_state(W,Revision,Before), Before \= none,
        (Expected = Revision -> true ; fail_with_reason(voxel_world_conflict(W,Revision))),
        voxel_patch_versions(W,Current),
        (Current = Versions -> true ; fail_with_reason(voxel_patch_conflict(W))),
        (Operation = regenerate, Current \= [] -> fail_with_reason(voxel_world_edited(W)); true),
        findall(body(B,R,K,Pose,D),physics_body_definition(W,B,R,K,Pose,D),Bodies),
        (Bodies = [body(Body,BodyRevision,fixed,vector(0,0,0),Definition)],
         Definition = owned(voxel_field_v1(W,_,_),1) -> true
        ; fail_with_reason(voxel_world_occupied(W))),
        (Spec = none -> true ; voxel_initial_selection(W,Spec,Chunks)),
        Next is Revision+1,
        retract(voxel_world_definition(W,Revision,Before)),
        assertz(voxel_world_definition(W,Next,Spec)),
        findall(override(C,R,Patch),voxel_chunk_override(W,C,R,Patch),Overrides),
        voxel_remove_overrides(W,Overrides),
        (Spec = none -> physics_remove_body(W,Body,BodyRevision,fixed,vector(0,0,0),Definition)
        ; voxel_validate_chunks(W,Chunks),term_digest(Spec,Digest),Shape = voxel_field_v1(W,Next,Digest),
          physics_replace_body(W,Body,BodyRevision,fixed,vector(0,0,0),Definition,
                               vector(0,0,0),owned(Shape,1),geometry(Shape,1))))).

voxel_remove_overrides(_,[]).
voxel_remove_overrides(W,[override(C,R,Patch)|Rows]) :-
    retract(voxel_chunk_override(W,C,R,Patch)),voxel_remove_overrides(W,Rows).

%% A descriptor is an authored generated shape, not an explicit triangle
%% surface. Selection resolves it against the same verified ontology snapshot.
physics_valid_shape(fixed,voxel_field_v1(W,R,Digest),_) :-
    voxel_world_definition(W,R,Spec), Spec \= none, term_digest(Spec,Digest).

voxel_sampling_field(terrain_v1(unbounded,smooth,Field),Field) :-
    Field = field_v1(_,_,_,_).
voxel_sampling_field(terrain_v1(bounded(Min,Max),smooth,field_v1(Seed,S,Ops,M)),
                     field_v1(Seed,S,Clipped,M)) :-
    voxel_chunk_coordinate(Min), voxel_chunk_coordinate(Max),
    Min = chunk_v1(X0,Y0,Z0), Max = chunk_v1(X1,Y1,Z1),
    X0 < X1, Y0 < Y1, Z0 < Z1,
    integer(S), S > 0,
    A is X0*8*S, B is Y0*8*S, C is Z0*8*S,
    D is X1*8*S, E is Y1*8*S, F is Z1*8*S,
    append(Ops,[clip_box(vector(A,B,C),vector(D,E,F))],Clipped).

voxel_limits(W,Sampling,Surface,Chunks,Bytes,GeometryBytes) :-
    findall(L,voxel_allowances(W,L),[voxel_limits(Sampling,Surface,Chunks,Bytes,GeometryBytes)]),
    integer(Chunks), Chunks >= 0, integer(Bytes), Bytes >= 0,
    integer(GeometryBytes), GeometryBytes >= 0.

voxel_chunk_coordinate(chunk_v1(X,Y,Z)) :- integer(X), integer(Y), integer(Z).
voxel_unique_chunks(Chunks) :-
    term_variables(Chunks,[]), sort(Chunks,Sorted), length(Chunks,N), length(Sorted,N),
    voxel_chunk_coordinates(Chunks).
voxel_chunk_coordinates([]).
voxel_chunk_coordinates([C|Cs]) :- voxel_chunk_coordinate(C), voxel_chunk_coordinates(Cs).

%% Absence is a real read dependency. An empty current patch keeps its
%% revision, so painting back to the generator cannot resurrect a stale edit.
voxel_patch_state(W,C,Revision,Patch) :-
    findall(patch(R,P),voxel_chunk_override(W,C,R,P),Rows),
    (Rows = [] -> Revision = 0, Patch = patch_v1(<<"">>)
    ; Rows = [patch(Revision,Patch)] -> true
    ; fail_with_reason(ambiguous_voxel_patch(W,C))).

voxel_edit_basis(W,Brush,Revision,Expected) :-
    current_principal(P), can_edit_voxel_world(W,P,Brush),
    voxel_world_state(W,Revision,Spec), voxel_sampling_field(Spec,field_v1(_,Spacing,_,_)),
    voxel_limits(W,_,_,Maximum,_,_),
    '$quod_voxel'(brush_chunks(Brush,Spacing),chunk_limits(Maximum),Chunks),
    voxel_chunk_versions(W,Chunks,Expected).
voxel_chunk_versions(_,[],[]).
voxel_chunk_versions(W,[C|Cs],[chunk(C,R)|Rows]) :-
    voxel_patch_state(W,C,R,_), voxel_chunk_versions(W,Cs,Rows).

voxel_edit(W,ExpectedWorld,ExpectedChunks,Brush) :-
    term_variables([W,ExpectedWorld,ExpectedChunks,Brush],[]),
    transaction((voxel_edit_basis(W,Brush,Revision,Current),
        (Revision = ExpectedWorld -> true ; fail_with_reason(voxel_world_conflict(W,Revision))),
        (Current = ExpectedChunks -> true ; fail_with_reason(voxel_patch_conflict(W))),
        voxel_world_definition(W,Revision,Spec), voxel_sampling_field(Spec,Field),
        voxel_limits(W,Sampling,_,_,Bytes,_),
        voxel_edit_chunks(W,Current,Field,Brush,edit_limits(Sampling,Bytes),Changed,Consumers),
        sort(Consumers,Unique), voxel_chunk_allowance(W,Unique), voxel_validate_chunks(W,Unique),
        (member(density,Changed) -> voxel_refresh_terrain(W) ; true))).

voxel_edit_chunks(_,[],_,_,_,[],[]).
voxel_edit_chunks(W,[chunk(C,R)|Cs],Field,Brush,Limits,Changed,Consumers) :-
    voxel_patch_state(W,C,R,Before),
    '$quod_voxel'(edit(Field,C,Before,Brush),Limits,edit_v1(After,Density,Material,Affected)),
    (After == Before -> Here = []
    ; (R = 0 -> true ; retract(voxel_chunk_override(W,C,R,Before))),
      Next is R+1, assertz(voxel_chunk_override(W,C,Next,After)),
      findall(Kind,((Density = true, Kind = density);(Material = true, Kind = material)),Here)),
    voxel_edit_chunks(W,Cs,Field,Brush,Limits,Rest,Remaining),
    append(Here,Rest,Changed), append(Affected,Remaining,Consumers).

voxel_refresh_terrain(W) :-
    findall(body(B,R,D),
        (physics_body_definition(W,B,R,fixed,vector(0,0,0),D),D = owned(voxel_field_v1(W,_,_),1)),
        [body(Body,Revision,Definition)]),
    Definition = owned(Shape,Density),
    physics_replace_body(W,Body,Revision,fixed,vector(0,0,0),Definition,vector(0,0,0),Definition,
                         geometry(Shape,Density)).

voxel_chunk_inputs(W,C,Field,Overrides) :-
    voxel_world_state(W,_,Spec), voxel_sampling_field(Spec,Field),
    C = chunk_v1(X,Y,Z),
    %% Overrides are sparse. One read of the current relation also captures
    %% absence; do not prove 27 empty patch states for every procedural chunk.
    findall(Owner,(voxel_chunk_override(W,Owner,_,_),Owner = chunk_v1(A,B,E),
                  abs(A-X) =< 1,abs(B-Y) =< 1,abs(E-Z) =< 1),Present),
    sort(Present,Owners),voxel_override_inputs(W,Owners,Overrides).
voxel_override_inputs(_,[],[]).
voxel_override_inputs(W,[C|Cs],[override(C,Patch)|Rows]) :-
    voxel_patch_state(W,C,_,Patch),voxel_override_inputs(W,Cs,Rows).

%% Called only when authoring changes or filling a consumer's missing
%% materialization. Ordinary descriptor proofs never generate triangle lists.
voxel_validate_chunks(W,Chunks) :-
    voxel_limits(W,_,_,_,_,Maximum), voxel_validate_chunks(W,Chunks,0,Maximum).
voxel_validate_chunks(_,[],_,_).
voxel_validate_chunks(W,[C|Cs],Used,Maximum) :-
    voxel_chunk_inputs(W,C,Field,Overrides), Field = field_v1(_,Spacing,_,_),
    voxel_limits(W,Sampling,Surface,_,PatchBytes,_),
    '$quod_voxel'(chunk(Field,C,Overrides),chunk_limits(Sampling,PatchBytes),Samples),
    '$quod_voxel'(chunk_surface(Samples,Spacing),Surface,surface(_,Triangles)),
    length(Triangles,Count), Bytes is Used+16+38*Count,
    (Bytes =< Maximum -> true ; fail_with_reason(voxel_allowance(geometry_bytes,Bytes,Maximum))),
    voxel_validate_chunks(W,Cs,Bytes,Maximum).

voxel_chunk_allowance(W,Chunks) :-
    voxel_limits(W,_,_,Maximum,_,_), length(Chunks,Count),
    (Count =< Maximum -> true ; fail_with_reason(voxel_allowance(affected_chunks,Count,Maximum))).

%% The resource selector carries descriptors and current inputs. Numerical
%% buffers are retained by its existing consumer, never regenerated by a view
%% proof or stored in ontology history.
voxel_materialization_plan(W,Revision,Digest,Demand,materialization(Field,Chunks,Limits)) :-
    voxel_world_definition(W,Revision,Spec), term_digest(Spec,Digest),
    voxel_sampling_field(Spec,Field),
    findall(Cs,voxel_initial_chunks(W,Spec,Cs),[Initial]), voxel_unique_chunks(Initial),
    voxel_limits(W,Sampling,Surface,Maximum,PatchBytes,GeometryBytes),
    (Demand = initial -> Pinned = Initial, Ranges = []
    ; Demand = regions(Ranges), Pinned = []),
    '$quod_voxel'(resident_chunks(Pinned,Ranges),chunk_limits(Maximum),Chunks),
    Limits = prepare_limits(Sampling,Surface,PatchBytes,GeometryBytes).
