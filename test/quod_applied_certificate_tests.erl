-module(quod_applied_certificate_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% These are certificate-verifier fixtures with already-verified history
%% supplied as an input. The real admitted mixed-outcome CT witness separately
%% proves ordering, durable publication and historical evidence acquisition.
exact_operation_result_certificate_test() ->
    {Network, Evidence, Signers} = fixture(),
    lists:foreach(fun(Result) ->
        Certificate = certificate(Network, Evidence, Result, lists:sublist(Signers, 2)),
        ?assert(quod_applied_certificate:verify_operation_certificate(
                  Certificate, Network, Evidence)),
        {ok, #{result := Result}} =
            quod_applied_certificate:operation_certificate_binding(Certificate)
    end, [applied, {rejected, conflict_retry}, {rejected, not_authorized}]).

application_occurrence_and_every_domain_field_are_bound_test() ->
    {Network, Evidence, Signers} = fixture(),
    Certificate = certificate(Network, Evidence, applied, lists:sublist(Signers, 2)),
    ?assertNot(quod_applied_certificate:verify_operation_certificate(
                 Certificate, <<99:256>>, Evidence)),
    #{transaction := Transaction} = Evidence,
    Variants = [Evidence#{slot := 8}, Evidence#{block_hash := <<99:256>>},
                Evidence#{identity := {<<"other">>, <<9:256>>}},
                Evidence#{committee_id := <<99:256>>},
                Evidence#{transaction := Transaction#transaction{tx_id = <<99:256>>}},
                Evidence#{transaction := Transaction#transaction{
                  role = {remote_application, {transaction, <<"source">>, <<1:256>>, <<99:256>>},
                          operation_ref(), <<7:256>>}}}],
    lists:foreach(fun(Other) ->
        ?assertNot(quod_applied_certificate:verify_operation_certificate(
                     Certificate, Network, Other))
    end, Variants),
    {quod_operation_applied_certificate, 1, Statement, Signatures} = Certificate,
    lists:foreach(fun(OtherStatement) ->
        ?assertNot(quod_applied_certificate:verify_operation_certificate(
          {quod_operation_applied_certificate, 1, OtherStatement, Signatures},
          Network, Evidence))
    end, [setelement(1, Statement, quod_dtx_applied_vote),
          setelement(6, Statement, setelement(5, operation_ref(), <<99:256>>)),
          setelement(9, Statement, {rejected, conflict_retry})]).

quorum_is_distinct_and_historical_test() ->
    {Network, Evidence, Signers} = fixture(),
    [First, Second | _] = Signers,
    One = certificate(Network, Evidence, applied, [First]),
    ?assertNot(quod_applied_certificate:verify_operation_certificate(One, Network, Evidence)),
    Good = certificate(Network, Evidence, applied, [First, Second]),
    {quod_operation_applied_certificate, 1, Statement, [Vote | _]} = Good,
    ?assertEqual(error, quod_applied_certificate:operation_certificate(Statement, [Vote, Vote])),
    NewKey = signer(),
    LaterOnly = certificate(Network, Evidence, applied, [First, NewKey]),
    ?assertNot(quod_applied_certificate:verify_operation_certificate(
                 LaterOnly, Network, Evidence)),
    %% A current-key substitution cannot change the committee at this slot.
    NewCommittee = [maps:get(pubkey, S) || S <- [First, NewKey]],
    ?assertNot(quod_applied_certificate:verify_operation_certificate(
                 Good, Network, Evidence#{committee := NewCommittee})),
    ?assert(quod_applied_certificate:verify_operation_certificate(Good, Network, Evidence)).

only_canonical_terminal_results_are_signed_test() ->
    {Network, Evidence, _Signers} = fixture(),
    lists:foreach(fun(Result) ->
        ?assertEqual(error, quod_applied_certificate:operation_statement(Network, Evidence, Result))
    end, [committed, pending, timeout, {rejected, not_ready},
          {rejected, <<"arbitrary error text">>}, {rejected, invalid_authorization_transcript}]).

receipt_identity_excludes_interchangeable_signature_subsets_test() ->
    {Network, Evidence, [A, B, C, _]} = fixture(),
    First = certificate(Network, Evidence, applied, [A, B]),
    Second = certificate(Network, Evidence, applied, [B, C]),
    ?assertNotEqual(First, Second),
    {ok, #{target := Target, application_ref := Ref}} =
        quod_applied_certificate:operation_certificate_binding(First),
    Rows1 = [{Target, {certified, Ref, First}}],
    Rows2 = [{Target, {certified, Ref, Second}}],
    ?assertEqual({ok, [Ref]}, quod_operation_vector:receipt_references(Rows1)),
    ?assert(quod_operation_vector:certified(Rows1)),
    ?assert(quod_operation_vector:same_receipt(Rows1, Rows2)),
    {ok, Included} = quod_operation_vector:included([Ref]),
    ?assertNot(quod_operation_vector:certified(Included)),
    ?assertNot(quod_operation_vector:same_receipt(Included, Rows1)),
    Tx1 = quod_transaction:remote_complete({<<"source">>, <<1:256>>}, operation_ref(), <<7:256>>, Rows1),
    Tx2 = quod_transaction:remote_complete({<<"source">>, <<1:256>>}, operation_ref(), <<7:256>>, Rows2),
    ?assertEqual(Tx1#transaction.tx_id, Tx2#transaction.tx_id),
    ?assertEqual(error, quod_operation_vector:receipt([
                        {{<<"other">>, <<3:256>>}, {certified, Ref, First}}])),
    ?assertEqual(error, quod_operation_vector:receipt(Rows1 ++ Rows2)).

certificate(Network, Evidence, Result, Signers) ->
    {ok, Statement} = quod_applied_certificate:operation_statement(Network, Evidence, Result),
    Votes = [begin
                 {ok, Vote} = quod_applied_certificate:sign_operation_vote(Statement, Signer),
                 Vote
             end || Signer <- Signers],
    {ok, Certificate} = quod_applied_certificate:operation_certificate(Statement, lists:sort(Votes)),
    Certificate.

fixture() ->
    Signers = [signer() || _ <- lists:seq(1, 4)],
    Application = #transaction{tx_id = <<4:256>>,
      role = {remote_application, {transaction, <<"source">>, <<1:256>>, <<2:256>>},
              operation_ref(), <<7:256>>}},
    {<<10:256>>, #{identity => {<<"target">>, <<3:256>>}, phase => transaction,
                  slot => 7, block_hash => <<5:256>>, committee_id => <<6:256>>,
                  transaction => Application,
                  committee => lists:sort([maps:get(pubkey, S) || S <- Signers])}, Signers}.

operation_ref() -> {operation, <<"source">>, <<1:256>>, <<"agent">>, <<8:256>>}.

signer() ->
    {Public, Secret} = quod_identity:generate(),
    #{pubkey => Public, key => quod_identity:key_term({Public, Secret})}.
