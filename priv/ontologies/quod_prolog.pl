%% Code views and a pure compiler for ordinary, inspectable editing goals.
%% The owning ontology's normal can_invoke/4 policy authorizes the returned goal.
acl_sovereign(quod:prolog).
can_invoke(Goal, _, _, _) :- prolog_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- prolog_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

prolog_query(prolog_predicates(_, _)).
prolog_query(prolog_source(_, _, _)).
prolog_query(prolog_edit_goal(_, _, _, _, _)).
prolog_query(prolog_clauses(_, _)).

prolog_clauses(Source, Clauses) :-
    '$quod_program_source'(Clauses, Source).

prolog_predicates(ontology_ref(Namespace, Anchor), Indicators) :-
    Namespace::(current_ontology_identity(Namespace, Anchor),
        findall(Indicator, current_predicate(Indicator), Unsorted),
        sort(Unsorted, Indicators)).

prolog_source(ontology_ref(Namespace, Anchor), Indicator, Source) :-
    Namespace::(current_ontology_identity(Namespace, Anchor),
        '$quod_predicate_source'(Indicator, Source)).

%% Source is data while this goal is compiled. The caller submits the explicit
%% returned assertz/retract goals through normal signed admission; new callable
%% symbols therefore use the same atom accounting as handwritten goals.
%% Source checks return no scratch bindings: the durable result must not
%% duplicate the inspected program. The ordinary transaction composes inside
%% actions and other transactions with their existing savepoint semantics.
prolog_edit_goal(ontology_ref(Namespace, Anchor), Indicator,
                 ExpectedSource, DraftSource,
                 Namespace::(current_ontology_identity(Namespace, Anchor),
                             transaction(Body))) :-
    term_variables([Namespace, Anchor, Indicator], []),
    '$quod_program_source'(ExpectedProgram, ExpectedSource),
    '$quod_program_source'(DraftProgram, DraftSource),
    prolog_code(ExpectedProgram, ExpectedClauses, ExpectedEntries),
    prolog_code(DraftProgram, DraftClauses, DraftEntries),
    prolog_unique_clauses(DraftEntries, Indicator),
    '$quod_program_source'(ExpectedClauses, CanonicalExpected),
    '$quod_program_source'(DraftClauses, CanonicalDraft),
    prolog_changed_suffix(ExpectedEntries, DraftEntries, Remove, Add),
    prolog_edit_tail(Remove, Add, Indicator, CanonicalDraft, Tail),
    Body = (('$quod_predicate_source'(Indicator, CanonicalExpected) -> true ; fail_with_reason(edit_conflict(Indicator))),
            Tail).

%% Compare ground source keys, never unify two clauses to test equality.
%% The bridge numbers variables independently for each printed clause.
prolog_code([], [], []).
prolog_code([Term | Terms], [Clause | Clauses], [code(Source, Clause) | Entries]) :-
    prolog_clause(Term, Clause),
    '$quod_program_source'([Clause], Source),
    prolog_code(Terms, Clauses, Entries).

prolog_clause((Head :- Body), (Head :- Body)) :- !.
prolog_clause(Head, (Head :- true)).

prolog_unique_clauses(Entries, Indicator) :-
    findall(Source, member(code(Source, _), Entries), Sources),
    sort(Sources, Unique), length(Sources, Count),
    (length(Unique, Count) -> true ; fail_with_reason(duplicate_clause(Indicator))).

prolog_changed_suffix([code(Source, _) | Expected], [code(Source, _) | Draft], Remove, Add) :-
    !, prolog_changed_suffix(Expected, Draft, Remove, Add).
prolog_changed_suffix(Expected, Draft, Expected, Draft).

prolog_edit_tail([], [], _, _, true) :- !.
prolog_edit_tail(Remove, Add, Indicator, CanonicalDraft, Goal) :-
    Check = ('$quod_predicate_source'(Indicator, CanonicalDraft) -> true ; fail_with_reason(edit_not_representable(Indicator))),
    prolog_assert_goals(Add, [Check], Assertions),
    prolog_retract_goals(Remove, Assertions, Goals),
    length(Goals, Count), prolog_goal_tree(Count, Goals, [], Goal).

prolog_retract_goals([], Tail, Tail).
prolog_retract_goals([code(_, Clause) | Clauses], Tail,
                     ['$quod_retract_exact'(Clause) | Rest]) :-
    prolog_retract_goals(Clauses, Tail, Rest).

prolog_assert_goals([], Tail, Tail).
prolog_assert_goals([code(_, Clause) | Clauses], Tail, [assertz(Clause) | Rest]) :-
    prolog_assert_goals(Clauses, Tail, Rest).

%% Association changes no execution order. Balanced ordinary conjunctions keep
%% clause count from consuming the shared structural-depth allowance linearly.
prolog_goal_tree(1, [Goal | Rest], Rest, Goal) :- !.
prolog_goal_tree(Count, Goals, Rest, (Left, Right)) :-
    LeftCount is Count // 2, RightCount is Count - LeftCount,
    prolog_goal_tree(LeftCount, Goals, Middle, Left),
    prolog_goal_tree(RightCount, Middle, Rest, Right).
