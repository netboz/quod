space_entity_pose(Space,Subject,Layout,Pose) :-
    (space_placement(Space,Subject,Assignment), space_instance(Space,physical_space) ->
        findall(binding(B,R),physics_body_definition(Space,B,R,_,_,live(Subject,Assignment,_,_)),
                [binding(Body,Revision)]), Pose = body_pose(Body,Revision)
    ; Layout = transform(_,_,_,_,_,_), Pose = Layout).
