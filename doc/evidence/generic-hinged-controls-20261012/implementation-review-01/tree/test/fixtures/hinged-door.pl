%% Example rules for the shared production hinged capability.
hinged_example(vertical_door, vector(0,1500,0), 0,
               vector(1500,1500,Z), passage_closed) :- Z is -500.
physics_hinged_class(vertical_door, 1,
    hinged(box(50,1000,50), box(1000,1000,100), 1, vector(0,1,0),
           anchors(vector(0,0,0),vector(X,0,0)), limits(Lower,1500), 1500,
           position(0,motor(100,10,1000),stop(20,target_or_contact)))) :-
    X is -1000, Lower is -1500.
physics_hinged_consequence(room,10,Request,closed,
                          assertz(hinged_result(passage_closed,Request))).
