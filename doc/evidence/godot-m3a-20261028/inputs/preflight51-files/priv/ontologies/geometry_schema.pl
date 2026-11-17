%% Pure authored geometry schema shared by body authoring, terrain, hinge and
%% native installation callers. This framework validates supplied data and
%% supplied coordinate allowances; it selects no policy, body, world or run.
%% Mutable definitions and all admission/delegation consequences stay with
%% their composing ontology. Native feasibility checks remain authoritative.
%% Coordinates, shapes and frame descriptors are local data, never scope requests.
no_follow(physics_valid_body/6).
no_follow(physics_world_position/1).
no_follow(physics_world_pose/1).
no_follow(physics_frame_path/1).
no_follow(physics_local_pose/1).
no_follow(physics_valid_pose/2).
no_follow(physics_valid_shape/3).
no_follow(physics_valid_solid/2).
no_follow(physics_dimension/2).
no_follow(physics_valid_parts/2).
no_follow(physics_valid_vertices/2).
no_follow(physics_valid_triangles/2).
no_follow(physics_vertex_index/2).
no_follow(physics_native_scalar_limit/1).
no_follow(physics_positive_scalar/1).
no_follow(physics_milli_integer/1).
no_follow(physics_coordinate/2).
no_follow(physics_body_vector/2).
no_follow(physics_body_coordinate/2).

physics_valid_body(Id, Kind, Pose, Shape, Density, Coordinate) :-
    term_variables([Id, Kind, Pose, Shape, Density, Coordinate], []),
    integer(Id), Id >= 0, Id < 18446744073709551616,
    member(Kind, [fixed, dynamic, controlled]), physics_positive_scalar(Density),
    integer(Coordinate), Coordinate > 0,
    physics_world_pose(Pose), physics_valid_shape(Kind, Shape, Coordinate).
%% Absolute positions are exact millimetres. The coordinate allowance governs
%% the current native window and local shapes, not distance from world zero.
physics_world_position(vector(X,Y,Z)) :- integer(X), integer(Y), integer(Z).
physics_world_pose(vector(X,Y,Z)) :- physics_world_position(vector(X,Y,Z)).
physics_world_pose(pose(Position,rotation(X,Y,Z))) :-
    physics_world_position(Position),
    physics_milli_integer(X), physics_milli_integer(Y), physics_milli_integer(Z).
physics_world_pose(framed(Path,Local)) :-
    Path = [_|_], physics_frame_path(Path), physics_local_pose(Local).
physics_frame_path([]).
physics_frame_path([frame(entity_ref(Ns,A,E),Assignment,Revision)|Rest]) :-
    binary(Ns), binary(A), term_variables(E,[]), integer(Assignment), Assignment > 0,
    binary_codes(Revision,Bytes), length(Bytes,32), physics_frame_path(Rest).
physics_local_pose(transform(X,Y,Z,RX,RY,RZ)) :- space_transform(transform(X,Y,Z,RX,RY,RZ)).
physics_local_pose(Pose) :- Pose \= framed(_,_), physics_world_pose(Pose).
physics_valid_pose(vector(X,Y,Z), Coordinate) :-
    physics_body_vector(vector(X,Y,Z), Coordinate).
physics_valid_pose(pose(Position, rotation(X,Y,Z)), Coordinate) :-
    physics_body_vector(Position, Coordinate),
    physics_milli_integer(X), physics_milli_integer(Y), physics_milli_integer(Z).
physics_valid_shape(_, Shape, Coordinate) :- physics_valid_solid(Shape, Coordinate).
physics_valid_shape(_, parts(Parts), Coordinate) :-
    Parts = [_ | _], physics_valid_parts(Parts, Coordinate).
physics_valid_shape(fixed, surface(Vertices, Triangles), Coordinate) :-
    Vertices = [_,_,_ | _], physics_valid_vertices(Vertices, Coordinate),
    length(Vertices, Count), Triangles = [_ | _], physics_valid_triangles(Triangles, Count).
physics_valid_solid(box(X,Y,Z), Coordinate) :-
    physics_dimension(X, Coordinate), physics_dimension(Y, Coordinate), physics_dimension(Z, Coordinate).
physics_valid_solid(ball(Radius), Coordinate) :- physics_dimension(Radius, Coordinate).
physics_valid_solid(capsule(HalfSegment, Radius), Coordinate) :-
    physics_dimension(HalfSegment, Coordinate), physics_dimension(Radius, Coordinate).
physics_valid_solid(convex(Vertices), Coordinate) :-
    Vertices = [_,_,_,_ | _], physics_valid_vertices(Vertices, Coordinate).
physics_dimension(X, Coordinate) :- physics_body_coordinate(X, Coordinate), X > 0.
physics_valid_parts([], _).
physics_valid_parts([part(Pose, Solid) | Rest], Coordinate) :-
    physics_valid_pose(Pose, Coordinate), physics_valid_solid(Solid, Coordinate),
    physics_valid_parts(Rest, Coordinate).
physics_valid_vertices([], _).
physics_valid_vertices([Vertex | Rest], Coordinate) :-
    physics_body_vector(Vertex, Coordinate), physics_valid_vertices(Rest, Coordinate).
physics_valid_triangles([], _).
physics_valid_triangles([triangle(A,B,C) | Rest], Count) :-
    physics_vertex_index(A, Count), physics_vertex_index(B, Count), physics_vertex_index(C, Count),
    A \= B, B \= C, A \= C, physics_valid_triangles(Rest, Count).
physics_vertex_index(Index, Count) :-
    integer(Index), Index >= 0, Index < 4294967296, Index < Count.
%% Largest finite binary64 integer accepted before the interface's unit division.
%% This is an encoding envelope; policy supplies each coordinate allowance.
physics_native_scalar_limit(179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368).
physics_positive_scalar(X) :-
    integer(X), X > 0, physics_native_scalar_limit(Max), X =< Max.
physics_milli_integer(X) :-
    integer(X), physics_native_scalar_limit(Max), X >= -Max, X =< Max.
physics_coordinate(X, Limit) :-
    physics_milli_integer(X), X >= -Limit, X =< Limit.
physics_body_vector(vector(X,Y,Z), Limit) :-
    physics_body_coordinate(X, Limit), physics_body_coordinate(Y, Limit), physics_body_coordinate(Z, Limit).
physics_body_coordinate(X, Limit) :-
    physics_milli_integer(X),
    (physics_coordinate(X, Limit) -> true ; fail_with_reason(coordinate_allowance(Limit))).
