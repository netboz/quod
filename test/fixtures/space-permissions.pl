%% Authored grants for signed space/physics fixtures. The production operation
%% guard owns committed evaluation, inheritance, overrides and policy reads.
class_permission(Class, Name, check(space_test_permission)) :-
    member(Class, [thing, agent]),
    member(Name, [space_enter, space_leave, space_admit, space_remove]).
space_test_permission(Actor, Subject, Operation) :-
    Operation =.. [Name, _, Other, Mode],
    space_test_grant(Subject, Actor, Name, Other, Mode).
