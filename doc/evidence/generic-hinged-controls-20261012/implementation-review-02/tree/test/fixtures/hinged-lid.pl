%% Same capability, horizontal axis, opposite travel and a nonzero target.
%% The group's authored rotation makes the target pose level in world space.
hinged_example(container_lid, pose(vector(0,3000,0),rotation(Rx,0,0)), 400,
               vector(0,3100,1200), container_closed) :- Rx is -400.
physics_hinged_class(container_lid, 1,
    hinged(box(1000,200,100),
           parts([part(vector(0,0,0),box(1000,100,1000)),
                  part(vector(0,150,HandleZ),ball(150))]),
           1, vector(1,0,0), anchors(vector(0,0,0),vector(0,0,AnchorZ)),
           limits(Lower,1200), Baseline,
           position(400,motor(1000,100,1000),stop(20,target_or_contact)))) :-
    HandleZ is -700, AnchorZ is -1000, Lower is -1300, Baseline is -1200.
physics_hinged_consequence(room,10,Request,closed,
                          assertz(hinged_result(container_closed,Request))).
