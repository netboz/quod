%% Code views and a pure compiler for ordinary, inspectable editing goals.
%% The owning ontology's normal can_invoke/4 policy authorizes the returned goal.
acl_sovereign(quod:prolog).
can_invoke(Goal, _, _, _) :- prolog_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- prolog_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

prolog_query(prolog_predicates(_, _)).
prolog_query(prolog_source(_, _, _)).
prolog_query(prolog_source(_, _)).
prolog_query(prolog_inspect(_, _, _)).
prolog_query(prolog_edit_goal(_, _, _, _, _)).
prolog_query(prolog_clauses(_, _)).
prolog_query(Goal) :- public_source_query(Goal).

%% Explicit interfaces describe callable operations; their declaration grants
%% no target source-read, invocation, content-edit or policy-edit permission.
ontology_interface(prolog_predicates/2, <<"current predicate catalogue">>).
ontology_interface(prolog_source/2, <<"complete current source cursor">>).
ontology_interface(prolog_source/3, <<"explicit predicate source">>).
ontology_interface(prolog_inspect/3, <<"authorized target inspection">>).
ontology_interface(prolog_edit_goal/5, <<"compile an exact-baseline content or policy edit">>).

%% The compiler transforms source and goal terms as data. Qualified names in
%% those terms never authorize implicit argument following by these helpers.
no_follow(prolog_clauses/2).
no_follow(prolog_edit_goal/5).
no_follow(prolog_edit_body/6).
no_follow(prolog_ordered_clauses/2).
no_follow(prolog_keyed_entries/2).
no_follow(prolog_numbered_entries/3).
no_follow(prolog_grouped_entries/2).
no_follow(prolog_groups/2).
no_follow(prolog_group_tail/4).
no_follow(prolog_predicate_edits/3).
no_follow(prolog_predicate_edit/5).
no_follow(prolog_edit_destination/3).
no_follow(prolog_code/3).
no_follow(prolog_clause/2).
no_follow(prolog_unique_clauses/2).
no_follow(prolog_changed_suffix/4).
no_follow(prolog_edit_tail/5).
no_follow(prolog_retract_goals/3).
no_follow(prolog_assert_goals/3).
no_follow(prolog_goal_tree/4).

prolog_clauses(Source, Clauses) :-
    '$quod_program_source'(Clauses, Source).

%% One target inspection path. Catalogued system access is explicit and does
%% not fall back to an API subset if a retained target lacks the read wrapper.
%% Other targets retain their ordinary admission policy (including ownership).
prolog_inspect(ontology_ref(Namespace, Anchor), Query, Result) :-
    quod:root::(current_ontology_identity(<<"quod:root">>, _),
                system_source_access(ontology_ref(Namespace, Anchor), _)),
    !,
    Namespace::(current_ontology_identity(Namespace, Anchor),
                system_prolog_introspection(Query, Result)).
prolog_inspect(ontology_ref(Namespace, Anchor), Query, Result) :-
    Namespace::(current_ontology_identity(Namespace, Anchor),
                prolog_introspection(Query, Result)).

prolog_predicates(Target, Indicators) :-
    prolog_inspect(Target, predicates, Indicators).

%% The default lens returns the entire frozen current state in bounded cursor
%% answers. Explicit predicate selection belongs to the lens ontology as well.
prolog_source(Target, Chunk) :-
    quod:root::system_ontology(<<"quod:lens">>, Anchor),
    <<"quod:lens">>::(current_ontology_identity(<<"quod:lens">>, Anchor),
        view(<<"ontology_source">>, [Target], Chunk)).
prolog_source(Target, Indicator, Source) :-
    quod:root::system_ontology(<<"quod:lens">>, Anchor),
    <<"quod:lens">>::(current_ontology_identity(<<"quod:lens">>, Anchor),
        view(<<"predicate_source">>, [Target, Indicator], Source)).

%% Source is data while this goal is compiled. The caller submits the explicit
%% returned assertz/retract goals through normal signed admission; new callable
%% symbols therefore use the same atom accounting as handwritten goals.
%% Source checks return no scratch bindings: the durable result must not
%% duplicate the inspected program. The ordinary transaction composes inside
%% actions and other transactions with their existing savepoint semantics.
prolog_edit_goal(Target, Selection, ExpectedSource, DraftSource, Edit) :-
    Target = ontology_ref(Namespace, Anchor),
    term_variables([Namespace, Anchor, Selection], []),
    '$quod_program_source'(ExpectedProgram, ExpectedSource),
    '$quod_program_source'(DraftProgram, DraftSource),
    prolog_code(ExpectedProgram, ExpectedClauses, ExpectedEntries),
    prolog_code(DraftProgram, DraftClauses, DraftEntries),
    prolog_unique_clauses(DraftEntries, Selection),
    prolog_edit_body(Selection, ExpectedClauses, DraftClauses,
                     ExpectedEntries, DraftEntries, Body),
    TargetEdit = Namespace::(current_ontology_identity(Namespace, Anchor),
                             transaction(Body)),
    prolog_edit_destination(Target, TargetEdit, Edit).

%% Complete text has the same canonical predicate ordering as the source lens.
%% Each changed predicate keeps its ordered common prefix. Unchanged predicates
%% (including runtime-owned and shared definitions) generate no mutations.
%% The guard reads one coherent snapshot. Ordinary predicate version tokens
%% protect every inspected and newly edited definition through Accept.
prolog_edit_body(all, _, _, ExpectedEntries, DraftEntries,
                 (Guard, Changes)) :-
    !,
    prolog_ordered_clauses(ExpectedEntries, ExpectedClauses),
    '$quod_program_source'(ExpectedClauses, CanonicalExpected),
    term_digest(CanonicalExpected, ExpectedDigest),
    binary_codes(CanonicalExpected, Bytes), length(Bytes, Length),
    (Length > 0 -> ChunkBytes = Length ; ChunkBytes = 1),
    Guard = (findall(Kind-Digest,
                    ('$quod_source_chunk'(all, ChunkBytes, source_chunk(Kind, Current)),
                     term_digest(Current, Digest)), [done-ExpectedDigest])
             -> true ; fail_with_reason(edit_conflict(all))),
    prolog_grouped_entries(ExpectedEntries, ExpectedGroups),
    prolog_grouped_entries(DraftEntries, DraftGroups),
    prolog_predicate_edits(ExpectedGroups, DraftGroups, Goals),
    (Goals = [] -> Changes = true
    ; length(Goals, Count), prolog_goal_tree(Count, Goals, [], Changes)).
prolog_edit_body(Indicator, ExpectedClauses, DraftClauses, ExpectedEntries, DraftEntries,
                 (Guard, Tail)) :-
    '$quod_program_source'(ExpectedClauses, CanonicalExpected),
    '$quod_program_source'(DraftClauses, CanonicalDraft),
    Guard = ('$quod_predicate_source'(Indicator, CanonicalExpected)
             -> true ; fail_with_reason(edit_conflict(Indicator))),
    prolog_changed_suffix(ExpectedEntries, DraftEntries, Remove, Add),
    prolog_edit_tail(Remove, Add, Indicator, CanonicalDraft, Tail).

%% Across-predicate order is presentation; within-predicate clause order is
%% semantic. Normalize both opened baselines and subsequent saved drafts alike.
prolog_ordered_clauses(Entries, Clauses) :-
    prolog_keyed_entries(Entries, Sorted),
    findall(Clause, member(_-code(_, _, Clause), Sorted), Clauses).

prolog_keyed_entries(Entries, Sorted) :-
    prolog_numbered_entries(Entries, 0, Keyed),
    sort(Keyed, Sorted).
prolog_numbered_entries([], _, []).
prolog_numbered_entries([code(Source, Clause) | Entries], Index,
                       [Indicator-code(Index, Source, Clause) | Keyed]) :-
    '$quod_source_indicator'(Clause, Indicator),
    Next is Index + 1,
    prolog_numbered_entries(Entries, Next, Keyed).

prolog_grouped_entries(Entries, Groups) :-
    prolog_keyed_entries(Entries, Sorted),
    prolog_groups(Sorted, Groups).
prolog_groups([], []).
prolog_groups([Indicator-code(_, Source, Clause) | Rest], [predicate(Indicator, [code(Source, Clause) | Entries]) | Groups]) :-
    prolog_group_tail(Rest, Indicator, Entries, Tail),
    prolog_groups(Tail, Groups).
prolog_group_tail([Indicator-code(_, Source, Clause) | Rest], Indicator, [code(Source, Clause) | Entries], Tail) :-
    !, prolog_group_tail(Rest, Indicator, Entries, Tail).
prolog_group_tail(Tail, _, [], Tail).

prolog_predicate_edits([], [], []).
prolog_predicate_edits([predicate(I, Before) | Expected], [predicate(I, After) | Draft], Goals) :-
    !,
    prolog_predicate_edits(Expected, Draft, Tail),
    prolog_predicate_edit(I, Before, After, Tail, Goals).
prolog_predicate_edits([predicate(I, Before) | Expected], Draft, Goals) :-
    (Draft = [] ; Draft = [predicate(J, _) | _], I @< J),
    !,
    prolog_predicate_edits(Expected, Draft, Tail),
    prolog_predicate_edit(I, Before, [], Tail, Goals).
prolog_predicate_edits(Expected, [predicate(I, After) | Draft], Goals) :-
    prolog_predicate_edits(Expected, Draft, Tail),
    prolog_predicate_edit(I, [], After, Tail, Goals).

prolog_predicate_edit(Indicator, Before, After, Tail, Goals) :-
    prolog_changed_suffix(Before, After, Remove, Add),
    (Remove = [], Add = [] -> Goals = Tail
    ; findall(Clause, member(code(_, Clause), After), Clauses),
      '$quod_program_source'(Clauses, CanonicalDraft),
      prolog_edit_tail(Remove, Add, Indicator, CanonicalDraft, Goal),
      Goals = [Goal | Tail]).

%% Root already authorizes its administrator's exact direct transaction. Keep
%% that existing path rather than adding a second root self-edit wrapper.
prolog_edit_destination(
        ontology_ref(<<"quod:root">>, _), TargetEdit, TargetEdit) :- !.
prolog_edit_destination(
        ontology_ref(Namespace, Anchor),
        Namespace::(current_ontology_identity(Namespace, Anchor),
                    transaction(Body)),
        Namespace::(current_ontology_identity(Namespace, Anchor),
                    system_prolog_edit,
                    transaction(Body))) :-
    %% Unit-local and other unanchored compiler uses have no scope in which to
    %% ask root. They retain the ordinary direct target edit; signed requests
    %% have a principal and may select this administrator wrapper.
    current_principal(_),
    quod:root::(current_ontology_identity(<<"quod:root">>, _),
                system_source_access(
                    ontology_ref(Namespace, Anchor), editable)),
    !.
prolog_edit_destination(_, TargetEdit, TargetEdit).

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
