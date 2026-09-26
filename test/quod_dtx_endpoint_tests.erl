-module(quod_dtx_endpoint_tests).

-include_lib("eunit/include/eunit.hrl").

owner_errors_use_the_wire_refusal_vocabulary_test() ->
    Id = <<77:128>>,
    lists:foreach(fun(Reason) ->
        Response = {error, Id, Reason},
        ?assertEqual(Response, quod_dtx_endpoint:error_response(Id, Reason)),
        {ok, Bytes} = quod_dtx_endpoint:encode_response(<<"target">>, Response, []),
        ?assertEqual({ok, Response, []}, quod_dtx_endpoint:decode_response(<<"target">>, Bytes))
    end, [busy, not_ready, not_found, invalid_request, conflict_retry,
          read_certificate_unavailable, independent_scope_required]),
    ?assertEqual({error, Id, not_ready}, quod_dtx_endpoint:error_response(Id, {untrusted, <<"details">>})).
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").
-include("quod_transport_limits.hrl").

channel_and_wire_bounds_are_fixed_test() ->
    Ns = <<"quod:endpoint">>,
    ?assertEqual(
       term_to_binary({quod_dtx, Ns}, [deterministic]),
       quod_dtx_endpoint:channel(Ns)),
    ?assertEqual(?QUOD_MAX_FOREIGN_PAGE_BYTES,
                 ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES),
    ?assert(?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES <
            ?QUOD_TRANSPORT_MAX_FRAME_BYTES).

trace_carrier_is_transport_only_and_never_changes_correlation_test() ->
    Ns = <<"quod:endpoint">>,
    Request = {phase, id(1), digest(2), vote},
    Response = {phase, id(1), 9, pending},
    Carrier = [{<<"traceparent">>,
                <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>}],
    {ok, Traced} = quod_dtx_endpoint:encode_request(Ns, Request, [], Carrier),
    {ok, Plain} = quod_dtx_endpoint:encode_request(Ns, Request, []),
    ?assertNotEqual(Traced, Plain),
    ?assertEqual({ok, Request, [], Carrier}, quod_dtx_endpoint:decode_request(Ns, Traced)),
    {quod_dtx_endpoint, 13, Ns, Inner, Carrier} = binary_to_term(Traced, [safe]),
    {quod_dtx_endpoint, 13, Ns, Inner, []} = binary_to_term(Plain, [safe]),
    ?assert(quod_dtx_endpoint:correlates(Request, Response)),
    ?assertNot(quod_dtx_endpoint:correlates(Request, setelement(2, Response, id(2)))),
    BadCarrier = [{<<"baggage">>, <<"not-authority">>}],
    ?assertEqual({error, {protocol_error, bad_trace_context}},
                 quod_dtx_endpoint:encode_request(Ns, Request, [], BadCarrier)),
    ?assertEqual({error, {protocol_error, bad_trace_context}},
      quod_dtx_endpoint:decode_request(Ns, term_to_binary(
        {quod_dtx_endpoint, 13, Ns, Inner, BadCarrier}, [deterministic]))),
    ?assertMatch({error, _}, quod_dtx_endpoint:decode_request(Ns, term_to_binary(
        {quod_dtx_endpoint, 9, Ns, Inner}, [deterministic]))).

all_request_shapes_roundtrip_deterministically_test() ->
    Ns = <<"quod:endpoint">>,
    Requests =
        [{submit, id(1), record_blob()},
         {read_attest, id(14), read_plan_blob()},
         {phase, id(2), digest(2), vote},
         {phase, id(3), digest(2), resolve},
         {present, id(4), digest(2), <<"manifest authenticated by owner">>},
         {phase, id(6), digest(2), complete},
         {outcome, id(7), group_ref(), digest(7), 11},
         {applied, id(8), digest(2), certified_ref(), 9, commit},
         {applied, id(9), digest(2), certified_ref(), 0, abort},
         {outcome, id(10), transaction_ref(), digest(7), 11},
         {outcome, id(12), operation_ref(), digest(7), 11},
         {cancel_operation_effect, id(13), {Ns, digest(1)}, <<"signed-submission">>}],
    lists:foreach(
      fun(Request) ->
          {ok, Frame} = quod_dtx_endpoint:encode_request(Ns, Request, []),
          ?assertEqual({ok, Request, [], []},
                       quod_dtx_endpoint:decode_request(Ns, Frame)),
          ?assertEqual({ok, Frame},
                       quod_dtx_endpoint:encode_request(Ns, Request, []))
      end, Requests).

all_response_shapes_roundtrip_and_correlate_test() ->
    Ns = <<"quod:endpoint">>,
    Ref = certified_ref(),
    GroupRef = group_ref(),
    TxRef = transaction_ref(),
    {ok, Receipt} = quod_ct:certified_receipt([target_transaction_ref()]),
    Statuses =
        [#{status => pending, ref => TxRef},
         #{status => committed, height => 11, ref => TxRef},
         #{status => rejected, reason => conflict, height => 11,
           ref => TxRef},
         #{status => pending, phase => pending_vote, ref => GroupRef},
         #{status => pending, phase => voted, ref => GroupRef},
         #{status => pending, phase => resolving_commit, ref => GroupRef},
         #{status => pending, phase => resolving_abort, ref => GroupRef},
         #{status => pending, phase => publication, ref => GroupRef},
         #{status => committed, height => 12, ref => GroupRef,
           bindings => [{<<"X">>, linked}],
           participant_slots => participant_slots()},
         #{status => aborted, height => 13, ref => GroupRef,
           reasons => [{cannot_link, bob}],
           participant_slots => participant_slots()},
         #{status => claimed, operation_state => unresolved, height => 14, receipt_height => none,
           ref => operation_ref(), request_digest => digest(13),
           outcome_ref => {applications, [TxRef]}, included => []},
         #{status => claimed, operation_state => terminal, height => 14, receipt_height => 15,
           ref => operation_ref(), request_digest => digest(13),
           outcome_ref => {applications, [target_transaction_ref()]},
           included => Receipt}],
    Pairs =
        [{{submit, id(1), record_blob()},
          {accepted, id(1), record_blob_digest(), accepted_ref()}},
         {{present, id(10), digest(2), <<"manifest authenticated by owner">>},
          {presented, id(10), digest(2)}},
         {{phase, id(2), digest(2), resolve},
          {phase, id(2), 0, not_found}},
         {{phase, id(3), digest(2), resolve},
          {phase, id(3), 7, pending}},
         {{phase, id(4), digest(2), resolve},
          {phase, id(4), 8, {committed, Ref}}},
         {{applied, id(5), digest(2), Ref, 9, commit},
          {applied, id(5), target(), digest(7), digest(2), Ref, 9, commit,
           digest(8), <<9:512>>}},
         {{read_attest, id(14), read_plan_blob()},
          {read_attest, id(14), target(), read_plan_proof_id(),
           read_plan_digest(), read_anchor_ref(), digest(7), digest(8),
           <<9:512>>}},
         {{cancel_operation_effect, id(6), {Ns, digest(1)}, <<"signed-submission">>},
          {operation_effect_cancelled, id(6), cancelled}}]
        ++ [{{outcome, id(16 + N), maps:get(ref, Status), digest(7), 11},
             {outcome, id(16 + N), outcome_target(), digest(7), 12, Status}}
            || {N, Status} <- lists:enumerate(Statuses)],
    OutcomePairs =
        Pairs ++
        [{{outcome, id(50), GroupRef, digest(7), 11},
          {outcome, id(50), outcome_target(), digest(7), 12, not_found}}],
    lists:foreach(
      fun({Request, Response}) ->
          {ok, Frame} = quod_dtx_endpoint:encode_response(Ns, Response, []),
          ?assertEqual({ok, Response, []},
                       quod_dtx_endpoint:decode_response(Ns, Frame)),
          ?assert(quod_dtx_endpoint:correlates(Request, Response)),
          ?assertEqual(quod_dtx_endpoint:request_id(Request),
                       quod_dtx_endpoint:response_id(Response))
      end, OutcomePairs),
    lists:foreach(
      fun(Reason) ->
          Request = {outcome, id(60), GroupRef, digest(7), 11},
          Response = {error, id(60), Reason},
          {ok, Frame} = quod_dtx_endpoint:encode_response(Ns, Response, []),
          ?assertEqual({ok, Response, []},
                       quod_dtx_endpoint:decode_response(Ns, Frame)),
          ?assert(quod_dtx_endpoint:correlates(Request, Response))
      end, [busy, not_ready, not_found, invalid_request,
            conflict_retry, read_certificate_unavailable]).

certified_remote_application_response_correlates_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    {ok, ClaimEvidence} = quod_transaction:encode_evidence(
                            maps:get(certified_claim_ref, Fixture),
                            maps:get(claim, Fixture)),
    {ok, TargetEvidence} = quod_transaction:encode_evidence(
                             maps:get(certified_target_ref, Fixture),
                             maps:get(application, Fixture)),
    Request = {apply_claim, id(63), maps:get(participant_target, Fixture), ClaimEvidence},
    Response = {application, id(63), committed, TargetEvidence},
    TargetNs = element(1, maps:get(participant_target, Fixture)),
    ?assertMatch({ok, _},
                 quod_dtx_endpoint:encode_request(TargetNs, Request, [])),
    ?assertMatch({ok, _},
                 quod_dtx_endpoint:encode_response(TargetNs, Response, [])),
    ?assert(quod_dtx_endpoint:correlates(Request, Response)).

direction_namespace_and_exact_correlation_are_enforced_test() ->
    Ns = <<"quod:endpoint">>,
    OtherNs = <<"quod:other">>,
    Ref = certified_ref(),
    Request = {applied, id(1), digest(2), Ref, 9, commit},
    Response =
        {applied, id(1), target(), digest(7), digest(2), Ref, 9, commit,
         digest(8), <<9:512>>},
    {ok, RequestFrame} = quod_dtx_endpoint:encode_request(Ns, Request, []),
    {ok, ResponseFrame} = quod_dtx_endpoint:encode_response(Ns, Response, []),
    ?assertEqual(
       {error, {protocol_error, bad_shape}},
       quod_dtx_endpoint:decode_response(Ns, RequestFrame)),
    ?assertEqual(
       {error, {protocol_error, bad_shape}},
       quod_dtx_endpoint:decode_request(Ns, ResponseFrame)),
    ?assertEqual(
       {error, {protocol_error, bad_namespace}},
       quod_dtx_endpoint:decode_request(OtherNs, RequestFrame)),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request, setelement(7, Response, 10))),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request, setelement(8, Response, abort))),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request, setelement(2, Response, id(2)))).

read_attest_correlation_binds_the_exact_plan_test() ->
    Request = {read_attest, id(14), read_plan_blob()},
    Response =
        {read_attest, id(14), target(), read_plan_proof_id(),
         read_plan_digest(), read_anchor_ref(), digest(7), digest(8),
         <<9:512>>},
    ?assert(quod_dtx_endpoint:correlates(Request, Response)),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request, setelement(4, Response, digest(17)))),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request, setelement(5, Response, digest(16)))).

applied_response_carries_signer_and_signature_test() ->
    Ns = <<"quod:endpoint">>,
    Ref = certified_ref(),
    Request = {applied, id(1), digest(2), Ref, 9, commit},
    Response = {applied, id(1), target(), digest(7), digest(2), Ref, 9,
                commit, digest(8), <<9:512>>},
    {ok, Frame} = quod_dtx_endpoint:encode_response(Ns, Response, []),
    ?assertEqual({ok, Response, []},
                 quod_dtx_endpoint:decode_response(Ns, Frame)),
    ?assert(quod_dtx_endpoint:correlates(Request, Response)),
    Inner = term_to_binary({Response, []}, [deterministic]),
    ?assertEqual(
       {error, {protocol_error, wrong_version}},
       quod_dtx_endpoint:decode_response(Ns, outer(Ns, 6, Inner))).

cancel_operation_effect_rejects_the_old_tuple_test() ->
    Ns = <<"quod:endpoint">>,
    RequestId = id(62),
    OldRequest =
        {cancel_operation_effect, RequestId, transaction_ref(),
         target_transaction_ref(), digest(9)},
    NewMalformedRequest =
        {cancel_operation_effect, RequestId, {Ns, digest(1)}, <<"not-a-submission">>},
    ?assertMatch(
       {error, {protocol_error, bad_shape}},
       quod_dtx_endpoint:encode_request(Ns, OldRequest, [])),
    %% This layer owns framing only. The authenticated target engine calls the
    %% one transaction decoder; parsing here too would verify every cancel
    %% submission twice.
    ?assertMatch(
       {ok, _},
       quod_dtx_endpoint:encode_request(Ns, NewMalformedRequest, [])),
    ?assertEqual(error, quod_dtx_endpoint:request_id(OldRequest)),
    ?assertEqual(RequestId,
                 quod_dtx_endpoint:request_id(NewMalformedRequest)),
    ?assert(
       quod_dtx_endpoint:correlates(
         NewMalformedRequest,
         {operation_effect_cancelled, RequestId, cancelled})).

entry_hint_roundtrips_as_untrusted_sidecar_test() ->
    Ns = <<"quod:endpoint">>,
    Request = {phase, id(1), digest(2), vote},
    Ref = certified_ref(),
    Entry = untrusted_entry(),
    Hints = [{Ref, Entry}],
    {ok, Frame} = quod_dtx_endpoint:encode_request(Ns, Request, Hints),
    {quod_dtx_endpoint, 13, Ns, InnerBinary, []} =
        binary_to_term(Frame, [safe]),
    {Request, [{entry_bytes, Ref, EntryBytes}]} =
        binary_to_term(InnerBinary, [safe]),
    ?assert(is_binary(EntryBytes)),
    ?assertEqual({ok, Entry}, quod_ledger:decode_entry(EntryBytes)),
    {ok, Request, [{Ref, Selected}], []} =
        quod_dtx_endpoint:decode_request(Ns, Frame),
    ?assertEqual({ok, EntryBytes}, quod_ledger:hint_bytes(Selected)),
    ?assertEqual({error, bad_entry}, quod_ledger:encode_entry(Selected)),
    %% Canonical shape is not finality authority. This fixture's invalid
    %% signature crosses the framing seam; the history verifier must refuse it.
    #cert{sigs = [{_, Signature}]} = (quod_ledger:entry_view(Entry))#entry.cert,
    ?assertEqual(<<0:512>>, Signature).

application_result_sidecar_roundtrips_entry_and_member_vote_test() ->
    quod_operation_fixture:with(1, fun(F) ->
        Ns = element(1, maps:get(target, F)),
        Ref = maps:get(certified_target_ref, F),
        Entry = maps:get(entry, F),
        Evidence = maps:get(evidence, F),
        Signer = maps:get(node_identity, F),
        Key = maps:get(pubkey, Signer),
        {ok, Statement} = quod_applied_certificate:operation_statement(
                            maps:get(network, F), Evidence, applied),
        {ok, {Key, Signature}} =
            quod_applied_certificate:sign_operation_vote(Statement, Signer),
        Vote = {{operation_vote, Ref, Key}, {Statement, Signature}},
        Hints = [{Ref, Entry}, Vote],
        Response = {application, id(64), committed,
                    element(2, quod_transaction:encode_evidence(
                                 Ref, maps:get(application, F)))},
        {ok, Frame} = quod_dtx_endpoint:encode_response(Ns, Response, Hints),
        {ok, Response, [{Ref, Selected}, Vote]} =
            quod_dtx_endpoint:decode_response(Ns, Frame),
        ?assertEqual(quod_ledger:encode_entry(Entry), quod_ledger:hint_bytes(Selected)),
        ?assertEqual(maps:get(application, F), quod_ledger:selected_record(Selected)),
        BadVote = {{operation_vote, maps:get(certified_claim_ref, F), Key},
                   {Statement, Signature}},
        ?assertEqual([], quod_dtx_endpoint:normalize_sidecar([BadVote])),
        ?assertEqual(
           {error, {protocol_error, bad_hints}},
           quod_dtx_endpoint:encode_response(Ns, Response, [BadVote]))
    end).

malformed_received_hint_is_ignored_without_losing_the_request_test() ->
    Ns = <<"quod:endpoint">>,
    Request = {phase, id(1), digest(2), vote},
    Ref = certified_ref(),
    WrongSlot = #entry{index = 8, data = noop},
    %% The wire never accepts a decoded entry record. A malformed or
    %% old-shaped hint disappears without changing the semantic request.
    Inner = term_to_binary({Request, [{Ref, WrongSlot}]}, [deterministic]),
    Frame = outer(Ns, 13, Inner),
    ?assertEqual({ok, Request, [], []},
                 quod_dtx_endpoint:decode_request(Ns, Frame)),
    MalformedInner =
        term_to_binary(
          {Request, [{entry_bytes, Ref, <<"not-an-entry">>}]},
          [deterministic]),
    ?assertEqual(
       {ok, Request, [], []},
       quod_dtx_endpoint:decode_request(
         Ns, outer(Ns, 13, MalformedInner))),
    ?assertEqual(
       {error, {protocol_error, bad_hints}},
       quod_dtx_endpoint:encode_request(
         Ns, Request, [{Ref, WrongSlot}])),
    Entry = untrusted_entry(),
    %% Even a genuine local artifact is not a wire capability: copying its
    %% private tuple into the fallback must not bypass the canonical decoder.
    ArtifactInner = term_to_binary({Request, [{Ref, Entry}]}, [deterministic]),
    ?assertEqual({ok, Request, [], []},
                 quod_dtx_endpoint:decode_request(
                   Ns, outer(Ns, 13, ArtifactInner))),
    ?assertEqual(
       {error, {protocol_error, bad_hints}},
       quod_dtx_endpoint:encode_request(
         Ns, Request, [{Ref, Entry}, {Ref, Entry}])).

entry_sidecar_keeps_foreign_symbols_wrapped_test() ->
    Ns = <<"quod:endpoint">>,
    Ref = setelement(7, certified_ref(), <<1:256>>),
    Name = <<"cut2_sidecar_foreign_", (integer_to_binary(
                                      erlang:unique_integer([positive])))/binary>>,
    Symbol = {'$quod_symbol', Name},
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
    Transaction = #transaction{tx_id = <<1:256>>, origin = {Ns, <<0:256>>},
                                author = <<1:256>>, read_check = #{},
                                diff = [{assert, {{Symbol, value}, true}}]},
    {ok, TxBytes} = quod_transaction:encode_ledger_transaction(Transaction),
    Era = <<9:256>>,
    BlockBytes = term_to_binary(
                   {quod_block, 3, Era, 6, {Era, 5, <<0:256>>}, 7,
                    {batch, [{transaction, TxBytes}]}, 0}, [deterministic]),
    Finality = {quod_finality, 1, Era, 6, crypto:hash(sha256, BlockBytes),
                [{<<1:256>>, <<0:512>>}]},
    EntryBytes = term_to_binary(
                   {quod_entry, 2, 7, BlockBytes, Finality}, [deterministic]),
    [{Ref, Entry}] = quod_dtx_endpoint:decode_validation_sidecar(
                      [{entry_bytes, Ref, EntryBytes}]),
    ?assertEqual({ok, EntryBytes}, quod_ledger:hint_bytes(Entry)),
    Decoded = quod_ledger:selected_record(Entry),
    ?assertEqual(Transaction#transaction.diff, Decoded#transaction.diff),
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)).

published_group_pending_status_uses_current_wire_vocabulary_test() ->
    Ns = <<"quod:endpoint">>,
    GroupRef = group_ref(),
    lists:foreach(fun(Phase) ->
        {ok, Status} = quod_outcome:public(
                         #{type => group, ref => GroupRef,
                           status => {pending, Phase}}),
        Response = {outcome, id(40), outcome_target(), digest(7), 12, Status},
        {ok, Bytes} = quod_dtx_endpoint:encode_response(Ns, Response, []),
        ?assertEqual({ok, Response, []},
                     quod_dtx_endpoint:decode_response(Ns, Bytes))
    end, [pending_vote, voted, resolving_commit, resolving_abort, publication]),
    lists:foreach(fun(Phase) ->
        Status = #{status => pending, phase => Phase, ref => GroupRef},
        Response = {outcome, id(40), outcome_target(), digest(7), 12, Status},
        ?assertEqual({error, {protocol_error, bad_shape}},
                     quod_dtx_endpoint:encode_response(Ns, Response, []))
    end, [begun, finalizing_commit, finalizing_abort]).

outcome_view_and_floor_correlation_are_exact_test() ->
    GroupRef = group_ref(),
    CommitteeId = digest(7),
    Request = {outcome, id(40), GroupRef, CommitteeId, 11},
    Response = {outcome, id(40), outcome_target(), CommitteeId, 12,
                not_found},
    ?assert(quod_dtx_endpoint:correlates(Request, Response)),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request, setelement(3, Response,
                                     {<<"quod:other">>, digest(1)}))),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request, setelement(4, Response, digest(8)))),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request, setelement(5, Response, 10))),
    Status = #{status => pending, phase => voted, ref => GroupRef},
    ?assert(quod_dtx_endpoint:correlates(
              Request, setelement(6, Response, Status))),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request,
                 setelement(6, Response,
                            Status#{ref => transaction_ref()}))).

old_phase_refusal_and_absence_barrier_vocabulary_is_rejected_test() ->
    Ns = <<"quod:endpoint">>,
    [?assertMatch({error, {protocol_error, bad_shape}},
                  quod_dtx_endpoint:encode_request(Ns, {phase, id(1), digest(2), Phase}, []))
     || Phase <- ['begin', prepare, decision, finalize]],
    GroupRef = group_ref(), CommitteeId = digest(7),
    Barrier = {outcome_barrier, id(41), GroupRef, CommitteeId, 11},
    BarrierReply = {outcome_barrier, id(41), outcome_target(), CommitteeId,
                    11, not_found},
    ?assertMatch({error, _}, quod_dtx_endpoint:encode_request(Ns, Barrier, [])),
    ?assertMatch({error, _}, quod_dtx_endpoint:encode_response(Ns, BarrierReply, [])),
    ?assertNot(quod_dtx_endpoint:correlates(Barrier, BarrierReply)),
    ?assertMatch({error, _}, quod_dtx_endpoint:encode_response(Ns,
                  {refused, id(1), target(), digest(1), 0, reasons_blob()}, [])),
    {ok, Frame} = quod_dtx_endpoint:encode_request(Ns, {phase, id(1), digest(2), vote}, []),
    {quod_dtx_endpoint, 13, Ns, Inner, []} = binary_to_term(Frame, [safe]),
    ?assertEqual({error, {protocol_error, wrong_version}},
                 quod_dtx_endpoint:decode_request(Ns, outer(Ns, 12, Inner))).

submit_digest_correlation_is_exact_test() ->
    Request = {submit, id(1), record_blob()},
    ?assert(quod_dtx_endpoint:correlates(
              Request,
              {accepted, id(1), record_blob_digest(), accepted_ref()})),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request,
                 {accepted, id(1), digest(250), accepted_ref()})),
    %% A correlated transport answer is not evidence. The resolver authenticates
    %% the certified reference against the role/group, including when the owner
    %% selected a negative vote instead of the submitted positive proposal.
    ?assert(quod_dtx_endpoint:correlates(
              Request, {accepted, id(1), record_blob_digest(), certified_ref()})),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request,
                 {refused, id(1), target(), record_blob_digest(), 0,
                  reasons_blob()})).

selected_negative_vote_correlates_without_becoming_an_uncommitted_refusal_test() ->
    F = quod_ct:signed_atomic_fixture(#{}),
    G = maps:get(group, F), T = maps:get(origin, F),
    Bundle = lists:keyfind(T, 1, maps:get(bundles, F)),
    {ok, Positive} = quod_atomic:new_vote(G, T, Bundle, prepared),
    {ok, Negative} = quod_atomic:new_vote(G, T, Bundle, {refused, [vote_deadline]}),
    {ok, Blob} = quod_atomic:encode_record(Positive),
    {Ns, Anchor} = T,
    {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, 7, digest(2),
                                      quod_atomic:record_digest(Negative), quod_ct:fixture_finality(6, digest(2))),
    Request = {submit, id(2), Blob},
    Response = {accepted, id(2), quod_atomic:record_digest(Positive), Ref},
    ?assertNotEqual(quod_atomic:record_digest(Positive), quod_atomic:record_digest(Negative)),
    ?assert(quod_dtx_endpoint:correlates(Request, Response)),
    ?assertNot(quod_dtx_endpoint:correlates(Request, setelement(3, Response, digest(250)))),
    ?assertNot(quod_dtx_endpoint:correlates(Request,
                {refused, id(2), T, quod_atomic:record_digest(Positive), 0, reasons_blob()})).

malformed_and_noncanonical_frames_fail_closed_test() ->
    Ns = <<"quod:endpoint">>,
    Good = {phase, id(1), digest(2), vote},
    GoodInner = term_to_binary({Good, []}, [deterministic]),
    WrongVersion = outer(Ns, 6, GoodInner),
    WrongDomain = term_to_binary(
                    {quod_dtx_endpoint_old, 1, Ns, GoodInner, []},
                    [deterministic]),
    ?assertEqual(
       {error, {protocol_error, wrong_version}},
       quod_dtx_endpoint:decode_request(Ns, WrongVersion)),
    ?assertEqual(
       {error, {protocol_error, bad_domain}},
       quod_dtx_endpoint:decode_request(Ns, WrongDomain)),
    ?assertEqual(
       {error, {protocol_error, bad_etf}},
       quod_dtx_endpoint:decode_request(Ns, <<131, 80, 0, 0, 0, 1, 0>>)),
    ?assertEqual(
       {error, {too_large, dtx_endpoint}},
       quod_dtx_endpoint:decode_request(
         Ns,
         <<0:(?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES + 1)/unit:8>>)),

    CompressedRecord = term_to_binary(binary_to_term(record_blob(), [safe]), [compressed]),
    ?assertMatch(<<131, 80, _/binary>>, CompressedRecord),
    TrailingRecord = <<(record_blob())/binary, 0>>,
    %% Framing keeps bytes opaque. Canonicality belongs to the one atomic
    %% decoder; transport correlation cannot authenticate malformed bytes.
    lists:foreach(fun(BadBlob) ->
        Request = {submit, id(1), BadBlob},
        ?assertMatch({ok, _}, quod_dtx_endpoint:encode_request(Ns, Request, [])),
        ?assertEqual(error, quod_atomic:decode_material(BadBlob)),
        ?assertNot(quod_dtx_endpoint:correlates(Request,
                     {accepted, id(1), record_blob_digest(), accepted_ref()}))
    end, [CompressedRecord, TrailingRecord]),
    ?assertEqual(
       {error, {too_large, record}},
       quod_dtx_endpoint:encode_request(
         Ns,
         {submit, id(1),
          <<0:(?QUOD_MAX_DTX_BODY_BYTES + 1)/unit:8>>}, [])).

unknown_atoms_are_not_created_test() ->
    Ns = <<"quod:endpoint">>,
    AtomName = <<"quod_dtx_endpoint_never_existing_atom_9f37b8">>,
    ?assertException(error, badarg,
                     binary_to_existing_atom(AtomName, utf8)),
    %% Inner `{phase, Id, Digest, UnknownAtom}` encoded manually with an
    %% ATOM_UTF8_EXT. The outer frame is valid and canonical; safe inner decode
    %% must reject before allocating the atom.
    Inner = <<131, 104, 4,
              119, 5, "phase",
              109, 0, 0, 0, 16, (id(1))/binary,
              109, 0, 0, 0, 32, (digest(2))/binary,
              118, (byte_size(AtomName)):16, AtomName/binary>>,
    InnerTerm = binary:part(Inner, 1, byte_size(Inner) - 1),
    Wrapped = <<131, 104, 2, InnerTerm/binary, 106>>,
    Frame = outer(Ns, 13, Wrapped),
    Before = erlang:system_info(atom_count),
    ?assertEqual(
       {error, {protocol_error, bad_etf}},
       quod_dtx_endpoint:decode_request(Ns, Frame)),
    ?assertEqual(Before, erlang:system_info(atom_count)),
    ?assertException(error, badarg,
                     binary_to_existing_atom(AtomName, utf8)).

invalid_fixed_shapes_are_rejected_test() ->
    Ns = <<"quod:endpoint">>,
    Ref = certified_ref(),
    GroupRef = group_ref(),
    BadRequests =
        [{submit, <<1:120>>, record_blob()},
         {submit, id(1), <<>>},
         {present, id(1), <<2:248>>, <<"group">>},
         {phase, id(1), <<2:248>>, vote},
         {phase, id(1), digest(2), unknown_phase},
         {outcome, id(1), setelement(3, GroupRef, <<1:248>>),
          digest(7), 1},
         {outcome, id(1), {transaction, <<>>, digest(1), digest(2)},
          digest(7), 1},
         {outcome, id(1), GroupRef, <<1:248>>, 1},
         {outcome, id(1), GroupRef, digest(7), 0},
         {outcome_barrier, id(1), transaction_ref(), digest(7), 1},
         {read_attest, id(1), <<"not-a-plan">>},
         {applied, id(1), digest(2), invalid_ref, 0, commit},
         {applied, id(1), digest(2), Ref, -1, commit},
         {applied, id(1), digest(2), Ref, 0, unknown_verdict}],
    [?assertMatch({error, _}, quod_dtx_endpoint:encode_request(Ns, Bad, []))
     || Bad <- BadRequests],
    BadResponses =
        [{accepted, id(1), <<1:248>>, accepted_ref()},
         {accepted, id(1), record_blob_digest(), invalid_ref},
         {refused, id(1), target(), digest(1), 0,
          reasons_blob()},
         {presented, id(1), <<1:248>>},
         {phase, id(1), -1, not_found},
         {phase, id(1), 16#10000000000000000, pending},
         {phase, id(1), 0, unknown},
         {phase, id(1), 0, {committed, invalid_ref}},
         {read_attest, id(1), target(), read_plan_proof_id(),
          read_plan_digest(), certified_ref(), digest(3), digest(4),
          <<5:512>>},
         {applied, id(1), {<<>>, digest(1)}, digest(2), digest(3), Ref,
          0, commit, digest(4), <<5:512>>},
         {applied, id(1), target(), digest(2), digest(3), Ref,
          0, commit, <<4:248>>, <<5:512>>},
         {applied, id(1), target(), digest(2), digest(3), Ref,
          0, commit, digest(4), <<5:504>>},
         {error, id(1), timeout},
         {outcome, id(1), outcome_target(), digest(7), 12,
          #{status => pending, phase => unknown, ref => GroupRef}},
         {outcome, id(1), outcome_target(), digest(7), 12,
          #{status => committed, height => 1, ref => GroupRef,
            bindings => [{<<"X">>, ok}], participant_slots => []}},
         {outcome, id(1), outcome_target(), digest(7), 12,
         #{status => claimed, height => 1, ref => operation_ref(),
            request_digest => <<1:248>>, outcome_ref => transaction_ref()}},
         {outcome, id(1), outcome_target(), digest(7), 12,
          #{status => claimed, operation_state => corrupt, height => 1,
            ref => operation_ref(), request_digest => digest(13),
            outcome_ref => transaction_ref()}},
         {outcome, id(1), {<<>>, digest(1)}, digest(7), 12, not_found},
         {outcome, id(1), outcome_target(), <<1:248>>, 12, not_found},
         {outcome, id(1), outcome_target(), digest(7), -1, not_found},
         {outcome_barrier, id(1), outcome_target(), digest(7), 12,
          unknown}],
    [?assertMatch({error, _}, quod_dtx_endpoint:encode_response(Ns, Bad, []))
     || Bad <- BadResponses].

outer(Ns, Version, Inner) ->
    term_to_binary(
      {quod_dtx_endpoint, Version, Ns, Inner, []}, [deterministic]).

record_blob() ->
    %% Shape-only references, not a consensus certificate. Stable bytes keep
    %% the independent framing and correlation assertions reproducible.
    Record = quod_ct:atomic_abort_record(target(), digest(6), certified_ref()),
    {ok, Blob} = quod_atomic:encode_record(Record),
    Blob.

record_blob_digest() -> record_blob_digest(record_blob()).

record_blob_digest(Blob) ->
    {ok, Digest} = quod_atomic:encoded_record_digest(Blob),
    Digest.

untrusted_entry() ->
    F = quod_ct:protocol_fixture(<<"quod:target">>),
    quod_ct:committed_entry(<<"quod:target">>, 7, {batch, [maps:get(transaction, F)]}).

certified_ref() ->
    {ok, Ref} = quod_dtx:certified_ref(
                  <<"quod:target">>, digest(1), 7,
                  digest(2), digest(3), quod_ct:fixture_finality(6, digest(2))),
    Ref.

accepted_ref() ->
    {ok, Ref} = quod_dtx:certified_ref(
                  <<"quod:target">>, digest(1), 7,
                  digest(2), record_blob_digest(), quod_ct:fixture_finality(6, digest(2))),
    Ref.

read_anchor_ref() ->
    {Ns, Anchor} = target(),
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, 7, digest(2), digest(3), quod_ct:fixture_finality(6, digest(2))),
    Ref.

read_plan_blob() ->
    {ok, Blob} = quod_dtx:encode(read_plan()),
    Blob.

read_plan() ->
    {ok, Empty} = quod_wire_term:encode_canonical([]),
    {ok, Reads} = quod_wire_term:encode_canonical(
                    [{{benchmark_echo, 1}, never_present}]),
    Core = #{target => target(), base_height => 1,
             proof_id => read_plan_proof_id(),
             origin => {<<"quod:origin">>, digest(11)},
             principal => anonymous, request_binding => none,
             overlay_generation => 0, diff_ops => 0, read_functors => 1,
             effects_count => 0,
             conflict_descriptor =>
                 #{reads => [{<<"benchmark_echo">>, 1}],
                   writes => [], custody => []},
             diff => Empty, read_check => Reads, effects => Empty,
             live_bridges => Empty, transcript => Empty},
    {quod_plan, Core, none, none}.

read_plan_proof_id() -> digest(15).
read_plan_digest() -> quod_dtx:digest(read_plan()).

group_ref() ->
    {group, <<"quod:origin">>, digest(1), digest(2), digest(3), digest(4)}.

transaction_ref() ->
    {transaction, <<"quod:origin">>, digest(1), digest(4)}.

target_transaction_ref() ->
    {transaction, <<"quod:target">>, digest(5), digest(14)}.

operation_ref() ->
    {operation, <<"quod:origin">>, digest(1),
     agent_ref(<<"quod:agent">>, digest(12), 12), digest(13)}.

target() -> {<<"quod:target">>, digest(5)}.

outcome_target() -> {<<"quod:origin">>, digest(1)}.

participant_slots() ->
    [{{<<"quod:a">>, digest(10)}, 7, 1},
     {{<<"quod:b">>, digest(11)}, 8, 2}].

reasons_blob() ->
    {ok, Blob} = quod_wire_term:encode_failure_reasons([vote_deadline]),
    Blob.

id(N) -> <<N:128>>.
digest(N) -> <<N:256>>.

agent_ref(Ns, Anchor, N) ->
    {ok, #{blob := Blob}} = quod_agent_ref:from_text(
                              Ns, Anchor,
                              <<"human_user(", (integer_to_binary(N))/binary,
                                ").">>,
                              2),
    Blob.
