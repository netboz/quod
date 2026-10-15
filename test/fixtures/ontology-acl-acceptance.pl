%% Policy for a disposable acceptance target. Grants are local ontology facts;
%% only its owner may change them. Guest writes admit the declared factual and derived content predicates.
can_invoke(_, Principal, _, _) :- acl_test_owner(Principal).
can_invoke((current_ontology_identity(_, _), Goal), Principal, _, _) :-
    acl_test_access(Principal, _), acl_test_read(Goal).
can_invoke((current_ontology_identity(_, _), transaction(Body)), Principal, _, _) :-
    acl_test_access(Principal, edit), acl_test_content_goal(Body).

acl_test_read(prolog_introspection(_, _)).
acl_test_read(Goal) :- public_source_query(Goal).

ontology_source_mode(editable) :- current_principal(P), acl_test_owner(P).
ontology_source_mode(editable) :- current_principal(P), acl_test_access(P, edit).
ontology_source_mode(read_only) :- current_principal(P), acl_test_access(P, read).

acl_test_content_goal(true).
acl_test_content_goal((A, B)) :- acl_test_content_goal(A), acl_test_content_goal(B).
acl_test_content_goal((findall(Kind-Digest,
        ('$quod_source_chunk'(all, Bytes, source_chunk(Kind, Current)),
         term_digest(Current, Digest)), [done-Expected]) -> true ; fail_with_reason(edit_conflict(all)))) :-
    integer(Bytes), Bytes > 0, binary(Expected).
acl_test_content_goal(('$quod_predicate_source'(Indicator, _) -> true ;
                       fail_with_reason(edit_conflict(Indicator)))) :- acl_test_content_indicator(Indicator).
acl_test_content_goal(('$quod_predicate_source'(Indicator, _) -> true ;
                       fail_with_reason(edit_not_representable(Indicator)))) :- acl_test_content_indicator(Indicator).
acl_test_content_goal(assertz((acl_test_value(_) :- true))).
acl_test_content_goal('$quod_retract_exact'((acl_test_value(_) :- true))).
acl_test_content_goal(assertz((acl_test_derived(X) :- acl_test_value(X)))).
acl_test_content_goal('$quod_retract_exact'((acl_test_derived(X) :- acl_test_value(X)))).
acl_test_content_indicator(acl_test_value/1).
acl_test_content_indicator(acl_test_derived/1).

acl_test_value(initial).
ontology_interface(acl_test_value/1, <<"Stored content; invocation has no guest grant">>).
