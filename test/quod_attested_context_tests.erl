-module(quod_attested_context_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Real signed protocol fixtures. They do not claim consensus admission.
attested_context_is_the_exact_signed_projection_test() ->
    F = fixture(2),
    lists:foreach(fun({Target, Digest, _Blob, Attestation}) ->
        Plan = maps:get(Target, maps:get(plans, F)),
        Expected = #{proof_id => maps:get(proof_id, F),
                     origin => maps:get(origin, F),
                     principal => maps:get(principal, F),
                     goal => maps:get(goal_blob, F),
                     result => maps:get(result_blob, F), plan_digest => Digest},
        {{ok, Actual}, Count} = counted(fun() ->
            quod_dtx:attested_context(Target, Plan, maps:get(manifest, F), Attestation)
        end),
        ?assertEqual(Expected, Actual),
        ?assertEqual(1, Count),
        ?assertEqual({ok, Actual}, quod_dtx:event_context(maps:get(manifest, F), Plan))
    end, maps:get(bundles, F)).

one_plan_verification_per_constructor_target_test() ->
    lists:foreach(fun(N) ->
        F = fixture(N),
        {Claim, Count} = counted(fun() -> construct(F) end),
        ?assertMatch(#transaction{role = {remote_claim, _, _, _}}, Claim),
        ?assertEqual(N, Count)
    end, [1,2,4,8]).

one_plan_verification_per_decoded_target_test() ->
    lists:foreach(fun(N) ->
        F = fixture(N), Signed = signed(F, construct(F)),
        {ok, Bytes} = quod_transaction:encode_ledger_transaction(Signed),
        {{ok, Decoded}, Count} = counted(fun() ->
            quod_transaction:decode_ledger_transaction(Bytes, wrapped)
        end),
        ?assertEqual(N, Count),
        ?assertEqual(Signed#transaction.signed_bytes, Decoded#transaction.signed_bytes),
        ?assertEqual({ok, Bytes}, quod_transaction:encode_ledger_transaction(Decoded))
    end, [1,2,4,8]).

corrupt_plan_signature_still_refuses_test() ->
    F = fixture(2), Plan = maps:get(plan, F),
    BadPlan = setelement(4, Plan, flipped(element(4, Plan))),
    ?assertEqual(error, context(F, BadPlan, maps:get(manifest, F), maps:get(attestation, F))),
    %% Plan digest excludes its signature. The still-valid attestation cannot
    %% stand in for the corrupted plan's own signature at this boundary.
    ?assertEqual(quod_dtx:digest(Plan), quod_dtx:digest(BadPlan)).

corrupt_attestation_still_refuses_test() ->
    F = fixture(2), Attestation = maps:get(attestation, F),
    Bad = setelement(tuple_size(Attestation), Attestation,
                     flipped(element(tuple_size(Attestation), Attestation))),
    ?assertEqual(error, context(F, maps:get(plan, F), maps:get(manifest, F), Bad)).

different_manifest_and_target_still_refuse_test() ->
    F = fixture(2), Plan = maps:get(plan, F), M = maps:get(manifest, F),
    A = maps:get(attestation, F),
    ?assertEqual(error, context(F, Plan, setelement(5, M, <<99:256>>), A)),
    {Ns, _} = maps:get(participant_target, F),
    ?assertEqual(error, quod_dtx:attested_context({Ns, <<99:256>>}, Plan, M, A)),
    ?assertEqual(error, context(F, malformed, M, A)).

claim_context_comparison_still_refuses_substitution_test() ->
    F = fixture(2), Claim = construct(F),
    %% A valid authenticated context is not a license to omit the claim's
    %% own field comparison. Rebuild ALL semantic IDs and predictions so no
    %% unrelated stale-ID check can accidentally make this control pass.
    {Ns, Anchor} = maps:get(origin, F),
    Signer = maps:get(node_identity, F),
    Binding = {Ns, Anchor, maps:get(admission, F)},
    C = Claim#transaction{author = maps:get(pubkey, Signer), author_seq = 1, submitted_at = 1},
    {ok, WrongResult} = quod_durable_term:encode_result(#{'Different' => true}),
    lists:foreach(fun(Wrong) ->
        Forged = rebind_predictions(F, Claim, Wrong),
        ?assertMatch({error, _}, quod_transaction:bytes(Binding, Forged))
    end, [C#transaction{result = WrongResult}, C#transaction{proof_id = <<99:256>>}]).

rebind_predictions(F, Original, Wrong) ->
    {Ns, Anchor} = Origin = maps:get(origin, F),
    #transaction{tx_id = ClaimId} = quod_transaction:bind_id(Origin, Wrong),
    NewRef = {transaction, Ns, Anchor, ClaimId},
    OldRef = {transaction, Ns, Anchor, Original#transaction.tx_id},
    {remote_claim, Manifest, Bundles, OldRefs} = Original#transaction.role,
    Refs = [begin
        Target = {TargetNs, TargetAnchor} = quod_operation_vector:target(Ref),
        App = quod_transaction:remote_application(OldRef, Original, Target),
        {remote_application, OldRef, OperationRef, Digest} = App#transaction.role,
        Changed = App#transaction{goal = Wrong#transaction.goal, result = Wrong#transaction.result,
                    role = {remote_application, NewRef, OperationRef, Digest}},
        #transaction{tx_id = ApplicationId} = quod_transaction:bind_id(Target, Changed),
        {transaction, TargetNs, TargetAnchor, ApplicationId}
    end || Ref <- OldRefs],
    Wrong#transaction{tx_id = ClaimId, role = {remote_claim, Manifest, Bundles, Refs}}.

fixture(N) ->
    Origin = {<<"quod:context-source">>, <<71:256>>},
    Targets = [{<<"quod:context-target-", (integer_to_binary(I))/binary>>, <<I:256>>}
               || I <- lists:seq(1,N)],
    quod_ct:signed_plan_fixture(#{target => Origin, participant_target => hd(Targets)}, Targets).
construct(F) ->
    quod_transaction:remote_claim(maps:get(origin, F), maps:get(manifest, F),
                                  maps:get(bundles, F), maps:get(auth, F), []).
context(F, P, M, A) -> quod_dtx:attested_context(maps:get(participant_target, F), P, M, A).
flipped(<<Byte, Rest/binary>>) -> <<(Byte bxor 1), Rest/binary>>.
signed(F, Claim) ->
    Signer = #{pubkey := Key} = maps:get(node_identity, F), {Ns, Anchor} = maps:get(origin, F),
    {ok, Signed} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)},
        Claim#transaction{author = Key, author_seq = 1, submitted_at = 1}, Signer), Signed.
counted(Fun) ->
    {module, quod_dtx} = code:ensure_loaded(quod_dtx),
    {Result, {call_count, Rows}} = tprof:profile(Fun,
        #{type => call_count, report => return,
          pattern => [{quod_dtx, verify, 1}], timeout => 30000}),
    {Result, lists:sum([N || {quod_dtx, verify, 1, Ps} <- Rows, {_Pid, N, _} <- Ps])}.
