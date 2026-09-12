-module(quod_cut_event_tests).
-include_lib("eunit/include/eunit.hrl").

findall_cut_preserves_staging_and_transaction_savepoints_test_() ->
    Failed = {findall, value, {',', {trigger_event, retained}, {',', '!', fail}}, []},
    Succeeded = {findall, value, {',', {trigger_event, retained}, '!'}, [value]},
    Negated = {'\\+', {',', {trigger_event, retained}, {',', '!', fail}}},
    Cases = [{failed_generator, Failed}, {successful_generator, Succeeded},
             {negated_failed_cut, Negated}],
    [{atom_to_list(Kind) ++ ":" ++ atom_to_list(Name), fun() ->
        {Goal, Expected} = case Kind of
            ordinary -> {Inner, [{event, retained}]};
            transaction -> {{transaction, Inner}, []}
        end,
        ?assertEqual(Expected, staged(Goal))
    end} || Kind <- [ordinary, transaction], {Name, Inner} <- Cases].

explicit_session_savepoint_restores_findall_event_and_keeps_read_dependency_test() ->
    with_session([{source, value}], fun(Session) ->
        ok = quod_proof_session:checkpoint_many(Session, [before_collection]),
        Goal = {findall, value,
                 {',', {source, value}, {',', {trigger_event, retained}, '!'}}, [value]},
        prove(Session, <<2:128>>, Goal),
        ?assertEqual([{event, retained}], quod_proof_session:local_changes(Session)),
        ?assert(maps:is_key({source, 1}, quod_proof_session:read_set(Session))),
        ok = quod_proof_session:restore_many(Session, [before_collection]),
        ?assertEqual([], quod_proof_session:local_changes(Session)),
        ?assert(maps:is_key({source, 1}, quod_proof_session:read_set(Session))),
        ok = quod_proof_session:release_many(Session, [before_collection])
    end).

staged(Goal) ->
    with_session([], fun(Session) ->
        prove(Session, <<1:128>>, Goal), quod_proof_session:local_changes(Session)
    end).

prove(Session, Id, Goal) ->
    ok = quod_proof_session:open(Session, Id, Goal, allowed,
       quod_predicates:proof_context(<<"cut:event-regression">>, 1, undefined),
       quod_transaction_scope:empty_selection()),
    ?assertMatch({solution, _}, quod_proof_session:next(Session, Id)).

with_session(Facts, Fun) ->
    Base = quod_transaction_predicates:load(quod_ct:committed_kb(Facts)),
    Session = quod_proof_session:start(Base, #{read_set => true}),
    try Fun(Session) after quod_proof_session:stop(Session) end.
