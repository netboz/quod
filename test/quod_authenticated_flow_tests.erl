-module(quod_authenticated_flow_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Real signed plans and certified entry fixtures exercise production decode
%% and target validation. The fixture is not a consensus-admission witness.
decode_to_target_validation_authenticates_once_test() ->
    lists:foreach(fun(N) -> quod_operation_fixture:with(N, fun(F) ->
        App = maps:get(application, F), Target = maps:get(target, F),
        {ok, Bytes} = quod_transaction:encode_ledger_transaction(App),
        Plan = maps:get(Target, maps:get(plans, F)),
        [{_, Chain, GoalBlob, _, _, _, _}] = quod_ct:plan_material(transcript, Plan),
        {ok, Goal} = quod_durable_term:decode_goal(GoalBlob),
        {ok, Principal} = quod_agent_ref:materialize_principal(quod_dtx:principal(Plan)),
        Key = maps:get(pubkey, maps:get(node_identity, F)),
        {Ns, Anchor} = Target,
        Est = quod_ct:committed_kb([
          {peer_admitted, Key, "validator", 14567, Key},
          {can_invoke, Goal, Principal, [S || {S, _} <- tl(Chain)], Ns}]),
        {ok, Index} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
        try
            Context = quod_commit_validation:new(Target, 1, Est, Index, none),
            {Result, Counts} = counted(fun() ->
                {ok, Decoded} = quod_transaction:decode_ledger_transaction(Bytes, materialized),
                quod_commit_validation:remote_application(Decoded, Context)
            end),
            ?assertMatch({apply, _, #{diff := [_ | _]}}, Result),
            ?assertEqual(N, count(quod_dtx, verify, 1, Counts)),
            ?assertEqual(N, count(quod_dtx, attested_context, 4, Counts)),
            ?assertEqual(1, count(quod_dtx, material, 1, Counts))
        after ok = quod_outcome:close(Index)
        end
    end) end, [1, 2, 4, 8]).

authenticated_claim_consumers_do_not_verify_or_materialize_test() ->
    quod_operation_fixture:with(4, fun(F) ->
        Claim = maps:get(claim, F),
        {ok, Bytes} = quod_transaction:encode_ledger_transaction(Claim),
        {ok, Decoded} = quod_transaction:decode_ledger_transaction(Bytes, wrapped),
        {ok, Counts} = counted(fun() ->
            ok = quod_transaction:validate_independent_claim(Decoded),
            lists:foreach(fun(Target) ->
                ?assertEqual(shared, quod_transaction:remote_claim_route(Decoded, Target))
            end, maps:get(targets, F))
        end),
        ?assertEqual(0, count(quod_dtx, verify, 1, Counts)),
        ?assertEqual(0, count(quod_dtx, attested_context, 4, Counts)),
        ?assertEqual(0, count(quod_dtx, material, 1, Counts))
    end).

claim_view_cannot_survive_changed_authentication_inputs_test() ->
    quod_operation_fixture:with(2, fun(F) ->
        C = maps:get(claim, F), T = maps:get(target, F),
        {remote_claim, M, [B | Bs], Refs} = C#transaction.role,
        {Target, Digest, Blob, A} = B,
        Forged = {Target, Digest, Blob, setelement(tuple_size(A), A, <<0:512>>)},
        lists:foreach(fun(Bad) ->
            ?assertEqual(error, quod_transaction:remote_claim_route(Bad, T)),
            ?assertEqual({error, invalid_plan_attestation},
                         quod_transaction:validate_independent_claim(Bad)),
            {Ns, Anchor} = C#transaction.origin,
            ?assertEqual({error, bad_term}, quod_transaction:bytes(
                           {Ns, Anchor, maps:get(admission, F)}, Bad))
        end, [C#transaction{role = {remote_claim, M, [Forged | Bs], Refs}},
              C#transaction{role = {remote_claim, setelement(5, M, <<99:256>>), [B | Bs], Refs}},
              C#transaction{origin = {element(1, C#transaction.origin), <<99:256>>}}])
    end).

source_effect_context_authenticates_once_without_materializing_test() ->
    F = quod_ct:signed_effect_operation_submission(#{additional_writer => true}),
    Submission = maps:get(submission, F),
    {{ok, Blob, Claim, Plans}, Counts} = counted(fun() ->
        quod_transaction:operation_submission_context(Submission)
    end),
    {remote_claim, _, Bundles, _} = Claim#transaction.role,
    ?assertEqual(term_to_binary(Submission, [deterministic]), Blob),
    ?assertEqual(1, length(Plans)),
    ?assertEqual(length(Bundles), count(quod_dtx, verify, 1, Counts)),
    ?assertEqual(length(Bundles), count(quod_dtx, attested_context, 4, Counts)),
    ?assertEqual(0, count(quod_dtx, material, 1, Counts)).

receipt_exact_evidence_does_not_reencode_test() ->
    F = quod_ct:remote_operation_fixture(#{receipt_kind => certified}),
    App = maps:get(application, F), Ref = maps:get(certified_target_ref, F),
    Exact = #{identity => maps:get(participant_target, F), phase => transaction,
      slot => 3, block_hash => <<214:256>>, committee_id => <<215:256>>,
      transaction => App, committee => [maps:get(pubkey, maps:get(node_identity, F))]},
    quod_ct:with_network_identity(maps:get(network, F), fun() ->
        {ok, Counts} = counted(fun() -> quod_commit_validation:validate_evidence(
                     maps:get(completion, F), #{Ref => Exact}) end),
        ?assertEqual(0, count(quod_transaction, encode_ledger_transaction, 1, Counts)),
        %% The certificate itself is still authenticated once.
        ?assertEqual(1, count(quod_identity, verify, 3, Counts)),
        Bad = Exact#{transaction := App#transaction{read_check = #{ {bad, 1} => absent }}},
        ?assertEqual({error, operation_receipt_reference_binding},
          quod_commit_validation:validate_evidence(maps:get(completion, F), #{Ref => Bad}))
    end).

am3_collection_authenticates_votes_not_its_assembled_certificate_test() ->
    quod_operation_fixture:with(1, fun(F) ->
        E = (maps:get(evidence, F))#{routes => #{}}, Ref = maps:get(certified_target_ref, F),
        Key = maps:get(pubkey, maps:get(node_identity, F)), Network = maps:get(network, F),
        {ok, Statement} = quod_applied_certificate:operation_statement(Network, E, applied),
        {ok, {Key, Sig}} = quod_applied_certificate:sign_operation_vote(Statement, maps:get(node_identity, F)),
        D = #{node_key => fun() -> Key end, network_identity => fun() -> {ok, Network} end,
              resolve => fun(_) -> undefined end,
              local => fun(_, {operation_applied, Id, R}, _) ->
                  {ok, {operation_applied, Id, R, Statement, Key, Sig}, []}
              end},
        {{ok, Cert}, Counts} = counted(fun() ->
            quod_dtx_current_view:test_certify_operation(maps:get(source_ns, F), Ref, E,
                                                        quod_time:mono_ms() + 1000, D)
        end),
        ?assertEqual(1, count(quod_identity, verify, 3, Counts)),
        ?assert(quod_applied_certificate:verify_operation_certificate(Cert, Network, E)),
        ?assertEqual({error, retry}, quod_dtx_current_view:test_certify_operation(
          maps:get(source_ns, F), Ref, E, quod_time:mono_ms(), D))
    end).

counted(Fun) ->
    [{module, M} = code:ensure_loaded(M) || M <- [quod_dtx, quod_transaction, quod_identity]],
    {Result, {call_count, Rows}} = tprof:profile(Fun, #{type => call_count, report => return,
      pattern => [{quod_dtx, verify, 1}, {quod_dtx, attested_context, 4},
                  {quod_dtx, material, 1}, {quod_transaction, encode_ledger_transaction, 1},
                  {quod_identity, verify, 3}], timeout => 30000}),
    {Result, Rows}.
count(M, F, A, Rows) ->
    lists:sum([N || {Mod, Fn, Arity, Ps} <- Rows, {_, N, _} <- Ps,
                   Mod =:= M, Fn =:= F, Arity =:= A]).
