%% Fixture instance ACLs preserve selective admission while shared classes
%% keep their defaults at their own owners.
instance_permission(Entity, Name, check(space_test_permission)) :-
    instance_of(_, Entity),
    member(Name, [space_enter, space_leave, space_admit, space_remove]).
class_permission(manuscript, space_enter, check(space_test_permission)).
space_test_permission(Actor, Subject, Operation) :-
    Operation =.. [Name, _, Other, Mode],
    space_test_grant(Subject, Actor, Name, Other, Mode).
