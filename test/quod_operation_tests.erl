-module(quod_operation_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Pure transition fixtures: signed plans/claims and AM3 votes are real; the
%% certified reference QC bytes stand for an ALREADY verified owner input.
%% These are not consensus-admission or history-verification witnesses.
one_two_four_targets_use_one_model_test() ->
    lists:foreach(fun(N) ->
        F = fixture(N), M = maps:get(model, F), Targets = maps:get(targets, F),
        ?assertEqual([{application, T} || T <- Targets], quod_operation:work(M)),
        ?assertEqual(pending, quod_operation:results(M)),
        ?assertEqual(pending, quod_operation:completion(M)),
        Final = lists:foldl(fun(T, Acc) -> observe(F, T, applied, Acc) end,
                           M, lists:reverse(Targets)),
        ?assertEqual([], quod_operation:work(Final)),
        {ok, Rows} = quod_operation:results(Final),
        ?assertEqual(Targets, [T || {T, _} <- Rows]),
        ?assertEqual(all_applied, quod_operation_vector:aggregate(Rows)),
        {ok, Complete} = quod_operation:completion(Final),
        ?assert(quod_transaction:valid_id(maps:get(origin, F), Complete)),
        #transaction{role = {remote_complete, _, _, Receipt}} = Complete,
        ?assert(quod_operation_vector:certified(Receipt)),
        ?assertEqual({ok, Final}, quod_operation:restore_receipt(Complete, Final))
    end, [1, 2, 4]).

partial_success_keeps_other_targets_independent_test() ->
    F = fixture(2), [A, B] = maps:get(targets, F), M0 = maps:get(model, F),
    M1 = observe(F, A, applied, M0),
    ?assertEqual([{application, B}], quod_operation:work(M1)),
    ?assertEqual(pending, quod_operation:results(M1)),
    M2 = observe(F, B, {rejected, conflict_retry}, M1),
    {ok, Rows} = quod_operation:results(M2),
    ?assertEqual(mixed, quod_operation_vector:aggregate(Rows)),
    ?assertMatch([{A, {committed, _}}, {B, {{rejected, conflict_retry}, _}}], Rows),
    ?assertEqual(M2, observe(F, A, applied, M2)),
    {Ref, E, Certificate} = vote(F, A, {rejected, not_authorized}),
    ?assertEqual({error, conflicting_target_evidence},
                 quod_operation:accept(A, Ref, E, Certificate, M2)).

inclusion_is_not_a_verdict_or_a_redelivery_command_test() ->
    F = fixture(2), [A, B] = maps:get(targets, F), M0 = maps:get(model, F),
    {Ref, E, _} = vote(F, A, applied),
    {ok, M1} = quod_operation:accept(A, Ref, E, none, M0),
    ?assertEqual([{certify, A, Ref, E}, {application, B}], quod_operation:work(M1)),
    ?assertEqual(pending, quod_operation:results(M1)),
    ?assertEqual(quod_operation:claim_bytes(M0), quod_operation:claim_bytes(M1)),
    M2 = observe(F, A, applied, M1),
    ?assertEqual({ok, M2}, quod_operation:accept(A, Ref, E, none, M2)).

inclusion_only_receipt_is_refused_without_restoring_legacy_work_test() ->
    F = fixture(2), M0 = maps:get(model, F),
    Final = lists:foldl(fun(T, M) -> observe(F, T, applied, M) end,
                       M0, maps:get(targets, F)),
    {ok, Complete} = quod_operation:completion(Final),
    #transaction{role = {remote_complete, Op, Digest, _}} = Complete,
    Included = [{quod_operation_vector:target(R), {included, R}}
                || R <- quod_operation:references(M0)],
    Old = Complete#transaction{role = {remote_complete, Op, Digest, Included}},
    ?assertEqual(error, quod_operation_vector:receipt_references(Included)),
    ?assertEqual({error, invalid_completion}, quod_operation:restore_receipt(Old, M0)),
    ?assertEqual([{application, T} || T <- maps:get(targets, F)], quod_operation:work(M0)).

target_binding_cannot_be_substituted_test() ->
    F = fixture(2), [A, B] = maps:get(targets, F), M = maps:get(model, F),
    {Ref, E, Cert} = vote(F, A, applied),
    ?assertEqual({error, invalid_target_evidence}, quod_operation:accept(B, Ref, E, Cert, M)),
    #{transaction := Tx} = E,
    ?assertEqual({error, invalid_target_evidence}, quod_operation:accept(
                   A, Ref, E#{transaction := Tx#transaction{tx_id = <<99:256>>}}, Cert, M)).

receipt_pair_order_is_canonical_and_result_reads_do_not_rebind_test() ->
    F = fixture(2), M = maps:get(model, F), [A, B] = maps:get(targets, F),
    CompleteModel = observe(F, B, {rejected, conflict_retry}, observe(F, A, applied, M)),
    {ok, Complete} = quod_operation:completion(CompleteModel),
    #transaction{evidence = {applications, Pairs}} = Complete,
    ?assertEqual({error, invalid_completion}, quod_operation:restore_receipt(
                   Complete#transaction{evidence = {applications, lists:reverse(Pairs)}}, M)),
    {ok, Restored} = quod_operation:restore_receipt(Complete, M),
    {{RA, RB, All}, {call_count, Counts}} = tprof:profile(fun() ->
        {quod_operation:result(A, Restored), quod_operation:result(B, Restored),
         quod_operation:results(Restored)}
    end, #{type => call_count, report => return,
           pattern => [{quod_applied_certificate, operation_certificate_binding, 1}]}),
    ?assertMatch({ok, {committed, _}}, RA),
    ?assertMatch({ok, {{rejected, conflict_retry}, _}}, RB),
    ?assertMatch({ok, [{A, _}, {B, _}]}, All),
    ?assertEqual(0, lists:sum([N || {_, _, _, Ps} <- Counts, {_, N, _} <- Ps])).

publication_floor_and_exact_outcome_are_required_test() ->
    F = fixture(1), [A] = maps:get(targets, F), {Ref, E, _} = vote(F, A, applied),
    StableRef = quod_transaction:stable_ref(Ref),
    #{slot := Slot} = E,
    Outcome = #{status => committed, height => Slot, ref => StableRef},
    ?assertEqual(pending, quod_operation:applied_result(Ref, E, not_ready)),
    ?assertEqual(pending, quod_operation:applied_result(
                   Ref, E, #{applied_floor => Slot - 1, outcome => Outcome})),
    ?assertEqual({ok, applied}, quod_operation:applied_result(
                   Ref, E, #{applied_floor => Slot, outcome => Outcome})),
    ?assertEqual(invalid, quod_operation:applied_result(
                   Ref, E, #{applied_floor => Slot, outcome => Outcome#{height := Slot+1}})),
    ?assertEqual({ok, {rejected, conflict_retry}}, quod_operation:applied_result(
                   Ref, E, #{applied_floor => Slot, outcome =>
                     Outcome#{status := rejected, reason => conflict_retry}})).

fixture(N) ->
    Origin = {<<"quod:s8-model-source">>, <<71:256>>},
    Targets = [{<<"quod:s8-model-target-", (integer_to_binary(I))/binary>>, <<I:256>>}
               || I <- lists:seq(1, N)],
    F = quod_ct:signed_plan_fixture(#{target => Origin, participant_target => hd(Targets)}, Targets),
    Signer = #{pubkey := Key} = maps:get(node_identity, F),
    Admission = maps:get(admission, F),
    Claim0 = quod_transaction:remote_claim(Origin, maps:get(manifest, F),
                                           maps:get(bundles, F), maps:get(auth, F), []),
    {Ns, Anchor} = Origin,
    {ok, Claim} = quod_transaction:sign({Ns, Anchor, Admission},
        Claim0#transaction{author = Key, author_seq = 1, submitted_at = 1}, Signer),
    {ok, ClaimRef} = quod_dtx:certified_ref(Ns, Anchor, 2, <<72:256>>,
                                          Claim#transaction.tx_id, quod_ct:fixture_finality(1, <<72:256>>)),
    {ok, #{operation_ref := Op}} = quod_transaction:request_claim(Claim),
    {ok, M} = quod_operation:new(Ns, Op, ClaimRef, Claim),
    F#{model => M, claim => Claim, claim_ref => ClaimRef, targets => Targets}.

vote(F, Target = {Ns, Anchor}, Result) ->
    Claim = maps:get(claim, F), ClaimRef = maps:get(claim_ref, F),
    App = quod_transaction:attach_evidence(
      quod_transaction:remote_application(quod_transaction:stable_ref(ClaimRef), Claim, Target),
      ClaimRef, Claim),
    {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, 3, <<73:256>>, App#transaction.tx_id, quod_ct:fixture_finality(2, <<73:256>>)),
    Signer = maps:get(node_identity, F), Network = maps:get(network, F),
    E = #{identity => Target, phase => transaction, slot => 3, block_hash => <<73:256>>,
          record_digest => App#transaction.tx_id, transaction => App,
          committee_id => <<74:256>>, committee => [maps:get(pubkey, Signer)]},
    {ok, Statement} = quod_applied_certificate:operation_statement(Network, E, Result),
    {ok, Vote} = quod_applied_certificate:sign_operation_vote(Statement, Signer),
    {ok, Cert} = quod_applied_certificate:operation_certificate(Statement, [Vote]),
    ?assert(quod_applied_certificate:verify_operation_certificate(Cert, Network, E)),
    {Ref, E, Cert}.

observe(F, Target, Result, M) ->
    {Ref, E, Cert} = vote(F, Target, Result),
    {ok, Updated} = quod_operation:accept(Target, Ref, E, Cert, M), Updated.
