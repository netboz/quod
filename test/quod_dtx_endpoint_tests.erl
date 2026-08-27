-module(quod_dtx_endpoint_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").
-include("quod_transport_limits.hrl").

channel_and_limits_are_fixed_test() ->
    Ns = <<"quod:endpoint">>,
    ?assertEqual(
       term_to_binary({quod_dtx, Ns}, [deterministic]),
       quod_dtx_endpoint:channel(Ns)),
    ?assertEqual(
       #{max_envelope_bytes => ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES,
         worker_timeout_ms => 30000},
       quod_dtx_endpoint:limits()),
    ?assert(?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES <
            ?QUOD_TRANSPORT_MAX_FRAME_BYTES).

all_request_shapes_roundtrip_deterministically_test() ->
    Ns = <<"quod:endpoint">>,
    Requests =
        [{submit, id(1), record_blob()},
         {phase, id(2), digest(2), 'begin'},
         {phase, id(3), digest(2), prepare},
         {phase, id(4), digest(2), decision},
         {phase, id(5), digest(2), finalize},
         {phase, id(6), digest(2), complete},
         {outcome, id(7), group_ref(), digest(7), 11},
         {outcome_barrier, id(11), group_ref(), digest(7), 11},
         {applied, id(8), digest(2), certified_ref(), 9, commit},
         {applied, id(9), digest(2), certified_ref(), 0, abort},
         {outcome, id(10), transaction_ref(), digest(7), 11},
         {outcome, id(12), operation_ref(), digest(7), 11}],
    lists:foreach(
      fun(Request) ->
          {ok, Frame} = quod_dtx_endpoint:encode_request(Ns, Request),
          ?assertEqual({ok, Request},
                       quod_dtx_endpoint:decode_request(Ns, Frame)),
          ?assertEqual({ok, Ns, Request},
                       quod_dtx_endpoint:decode_request(Frame)),
          ?assertEqual({ok, Frame},
                       quod_dtx_endpoint:encode_request(Ns, Request))
      end, Requests).

all_response_shapes_roundtrip_and_correlate_test() ->
    Ns = <<"quod:endpoint">>,
    Ref = certified_ref(),
    GroupRef = group_ref(),
    PrepareBlob = quod_ct:dtx_prepare_blob(),
    PrepareDigest = record_blob_digest(PrepareBlob),
    TxRef = transaction_ref(),
    Statuses =
        [#{status => pending, ref => TxRef},
         #{status => committed, height => 11, ref => TxRef},
         #{status => rejected, reason => conflict, height => 11,
           ref => TxRef},
         #{status => pending, phase => pending_begin, ref => GroupRef},
         #{status => pending, phase => begun, ref => GroupRef},
         #{status => pending, phase => finalizing_commit, ref => GroupRef},
         #{status => pending, phase => finalizing_abort, ref => GroupRef},
         #{status => pending, phase => publication, ref => GroupRef},
         #{status => committed, height => 12, ref => GroupRef,
           bindings => [{<<"X">>, linked}],
           participant_slots => participant_slots()},
         #{status => aborted, height => 13, ref => GroupRef,
           reasons => [{cannot_link, bob}],
           participant_slots => participant_slots()},
         #{status => rejected, reason => coordinator_retired,
           ref => GroupRef},
         #{status => claimed, operation_state => unresolved, height => 14,
           ref => operation_ref(), request_digest => digest(13),
           outcome_ref => TxRef},
         #{status => claimed, operation_state => terminal, height => 14,
           ref => operation_ref(), request_digest => digest(13),
           outcome_ref => target_transaction_ref()}],
    Pairs =
        [{{submit, id(1), record_blob()},
          {accepted, id(1), record_blob_digest(), accepted_ref()}},
         {{submit, id(10), PrepareBlob},
          {refused, id(10), target(), PrepareDigest, 4,
           reasons_blob()}},
         {{phase, id(2), digest(2), finalize},
          {phase, id(2), 0, not_found}},
         {{phase, id(3), digest(2), finalize},
          {phase, id(3), 7, pending}},
         {{phase, id(4), digest(2), finalize},
          {phase, id(4), 8, {committed, Ref}}},
         {{applied, id(5), digest(2), Ref, 9, commit},
          {applied, id(5), target(), digest(7), digest(2), Ref, 9, commit}}]
        ++ [{{outcome, id(16 + N), maps:get(ref, Status), digest(7), 11},
             {outcome, id(16 + N), outcome_target(), digest(7), 12, Status}}
            || {N, Status} <- lists:enumerate(Statuses)],
    OutcomePairs =
        Pairs ++
        [{{outcome, id(50), GroupRef, digest(7), 11},
          {outcome, id(50), outcome_target(), digest(7), 12, not_found}},
         {{outcome_barrier, id(51), GroupRef, digest(7), 11},
          {outcome_barrier, id(51), outcome_target(), digest(7), 12,
           pending_begin}},
         {{outcome_barrier, id(52), GroupRef, digest(7), 11},
          {outcome_barrier, id(52), outcome_target(), digest(7), 12,
           coordinator_retired}},
         {{outcome_barrier, id(53), GroupRef, digest(7), 11},
          {outcome_barrier, id(53), outcome_target(), digest(7), 12,
           not_found}}],
    lists:foreach(
      fun({Request, Response}) ->
          {ok, Frame} = quod_dtx_endpoint:encode_response(Ns, Response),
          ?assertEqual({ok, Response},
                       quod_dtx_endpoint:decode_response(Ns, Frame)),
          ?assertEqual({ok, Ns, Response},
                       quod_dtx_endpoint:decode_response(Frame)),
          ?assert(quod_dtx_endpoint:correlates(Request, Response)),
          ?assertEqual(quod_dtx_endpoint:request_id(Request),
                       quod_dtx_endpoint:response_id(Response))
      end, OutcomePairs),
    lists:foreach(
      fun(Reason) ->
          Request = {outcome, id(60), GroupRef, digest(7), 11},
          Response = {error, id(60), Reason},
          {ok, Frame} = quod_dtx_endpoint:encode_response(Ns, Response),
          ?assertEqual({ok, Response},
                       quod_dtx_endpoint:decode_response(Ns, Frame)),
          ?assert(quod_dtx_endpoint:correlates(Request, Response))
      end, [busy, not_ready, not_found, invalid_request]).

certified_remote_application_response_correlates_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    {ok, ClaimEvidence} = quod_transaction:encode_evidence(
                            maps:get(certified_claim_ref, Fixture),
                            maps:get(claim, Fixture)),
    {ok, TargetEvidence} = quod_transaction:encode_evidence(
                             maps:get(certified_target_ref, Fixture),
                             maps:get(application, Fixture)),
    Request = {apply_claim, id(63), ClaimEvidence},
    Response = {application, id(63), committed, TargetEvidence},
    TargetNs = element(1, maps:get(participant_target, Fixture)),
    ?assertMatch({ok, _}, quod_dtx_endpoint:encode_request(TargetNs, Request)),
    ?assertMatch({ok, _},
                 quod_dtx_endpoint:encode_response(TargetNs, Response)),
    ?assert(quod_dtx_endpoint:correlates(Request, Response)).

direction_namespace_and_exact_correlation_are_enforced_test() ->
    Ns = <<"quod:endpoint">>,
    OtherNs = <<"quod:other">>,
    Ref = certified_ref(),
    Request = {applied, id(1), digest(2), Ref, 9, commit},
    Response =
        {applied, id(1), target(), digest(7), digest(2), Ref, 9, commit},
    {ok, RequestFrame} = quod_dtx_endpoint:encode_request(Ns, Request),
    {ok, ResponseFrame} = quod_dtx_endpoint:encode_response(Ns, Response),
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
    Status = #{status => pending, phase => begun, ref => GroupRef},
    ?assert(quod_dtx_endpoint:correlates(
              Request, setelement(6, Response, Status))),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request,
                 setelement(6, Response,
                            Status#{ref => transaction_ref()}))),
    Barrier = {outcome_barrier, id(41), GroupRef, CommitteeId, 11},
    BarrierReply = {outcome_barrier, id(41), outcome_target(), CommitteeId,
                    11, not_found},
    ?assert(quod_dtx_endpoint:correlates(Barrier, BarrierReply)),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Barrier, setelement(5, BarrierReply, 10))).

submit_digest_correlation_is_exact_test() ->
    Request = {submit, id(1), record_blob()},
    ?assert(quod_dtx_endpoint:correlates(
              Request,
              {accepted, id(1), record_blob_digest(), accepted_ref()})),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request,
                 {accepted, id(1), digest(250), accepted_ref()})),
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request,
                 {accepted, id(1), record_blob_digest(), certified_ref()})),
    %% A deterministic refusal exists only for Prepare.  Other submit kinds
    %% can be accepted or transiently unavailable, but cannot be converted to
    %% a logical target-policy refusal.
    ?assertNot(quod_dtx_endpoint:correlates(
                 Request,
                 {refused, id(1), target(), record_blob_digest(), 0,
                  reasons_blob()})),
    PrepareBlob = quod_ct:dtx_prepare_blob(),
    PrepareDigest = record_blob_digest(PrepareBlob),
    PrepareRequest = {submit, id(2), PrepareBlob},
    ?assert(quod_dtx_endpoint:correlates(
              PrepareRequest,
              {refused, id(2), target(), PrepareDigest, 0,
               reasons_blob()})),
    ?assertNot(quod_dtx_endpoint:correlates(
                 PrepareRequest,
                 {refused, id(2), target(), digest(250), 0,
                  reasons_blob()})).

malformed_and_noncanonical_frames_fail_closed_test() ->
    Ns = <<"quod:endpoint">>,
    Good = {phase, id(1), digest(2), 'begin'},
    GoodInner = term_to_binary(Good, [deterministic]),
    WrongVersion = outer(Ns, 1, GoodInner),
    WrongDomain = term_to_binary(
                    {quod_dtx_endpoint_old, 1, Ns, GoodInner},
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

    CompressedRecord = term_to_binary(
                         {quod_dtx_begin, 2,
                          binary:copy(<<0>>, 8 * 1024), none, none, []},
                         [compressed]),
    ?assertMatch(<<131, 80, _/binary>>, CompressedRecord),
    ?assertEqual(
       {error, {protocol_error, bad_record}},
       quod_dtx_endpoint:encode_request(
         Ns, {submit, id(1), CompressedRecord})),
    TrailingRecord = <<(record_blob())/binary, 0>>,
    ?assertEqual(
       {error, {protocol_error, bad_record}},
       quod_dtx_endpoint:encode_request(
         Ns, {submit, id(1), TrailingRecord})),
    ?assertEqual(
       {error, {too_large, record}},
       quod_dtx_endpoint:encode_request(
         Ns,
         {submit, id(1),
          <<0:(?QUOD_MAX_DTX_BODY_BYTES + 1)/unit:8>>})).

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
    Frame = outer(Ns, 3, Inner),
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
         {submit, id(1),
          term_to_binary(
            {quod_dtx_begin, 2, {opaque_manifest, digest(4)},
             none, none, []},
            [deterministic])},
         {phase, id(1), <<2:248>>, 'begin'},
         {phase, id(1), digest(2), unknown_phase},
         {outcome, id(1), setelement(3, GroupRef, <<1:248>>),
          digest(7), 1},
         {outcome, id(1), {transaction, <<>>, digest(1), digest(2)},
          digest(7), 1},
         {outcome, id(1), GroupRef, <<1:248>>, 1},
         {outcome, id(1), GroupRef, digest(7), 0},
         {outcome_barrier, id(1), transaction_ref(), digest(7), 1},
         {applied, id(1), digest(2), invalid_ref, 0, commit},
         {applied, id(1), digest(2), Ref, -1, commit},
         {applied, id(1), digest(2), Ref, 0, unknown_verdict}],
    [?assertMatch({error, _}, quod_dtx_endpoint:encode_request(Ns, Bad))
     || Bad <- BadRequests],
    BadResponses =
        [{accepted, id(1), <<1:248>>, accepted_ref()},
         {accepted, id(1), record_blob_digest(), invalid_ref},
         {accepted, id(1), record_blob_digest(), certified_ref()},
         {refused, id(1), target(), digest(1), 0,
          term_to_binary([], [deterministic])},
         {refused, id(1), target(), digest(1), 0,
          refusal_blob([{prepare_refused, reason_identity(target())}])},
         {refused, id(1), target(), digest(1), 0,
          refusal_blob(
            [{prepare_refused,
              reason_identity({<<"quod:other">>, digest(6)})},
             conflict_retry])},
         {refused, id(1), target(), digest(1), -1, reasons_blob()},
         {refused, id(1), {<<>>, digest(1)}, digest(1), 0,
          reasons_blob()},
         {phase, id(1), -1, not_found},
         {phase, id(1), 16#10000000000000000, pending},
         {phase, id(1), 0, unknown},
         {phase, id(1), 0, {committed, invalid_ref}},
         {applied, id(1), {<<>>, digest(1)}, digest(2), digest(3), Ref,
          0, commit},
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
    [?assertMatch({error, _}, quod_dtx_endpoint:encode_response(Ns, Bad))
     || Bad <- BadResponses].

outer(Ns, Version, Inner) ->
    term_to_binary(
      {quod_dtx_endpoint, Version, Ns, Inner}, [deterministic]).

record_blob() ->
    {ok, Record} =
        quod_dtx:new_finalize(
          digest(4), certified_ref(), abort, none, 0),
    {ok, Blob} = quod_dtx:encode_record(Record),
    Blob.

record_blob_digest() -> record_blob_digest(record_blob()).

record_blob_digest(Blob) ->
    {ok, Record} = quod_dtx:decode_record(Blob),
    quod_dtx:record_digest(Record).

certified_ref() ->
    {ok, Ref} = quod_dtx:certified_ref(
                  <<"quod:target">>, digest(1), 7,
                  digest(2), digest(3), <<"qc">>),
    Ref.

accepted_ref() ->
    {ok, Ref} = quod_dtx:certified_ref(
                  <<"quod:target">>, digest(1), 7,
                  digest(2), record_blob_digest(), <<"qc">>),
    Ref.

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
    refusal_blob(
      [{prepare_refused, reason_identity(target())},
       {goal, {cannot_link, alice, bob}}]).

refusal_blob(Reasons) ->
    {ok, Blob} = quod_wire_term:encode_failure_reasons(Reasons),
    Blob.

reason_identity({Ns, Anchor}) -> {ontology, Ns, Anchor}.

id(N) -> <<N:128>>.
digest(N) -> <<N:256>>.

agent_ref(Ns, Anchor, N) ->
    {ok, #{blob := Blob}} = quod_agent_ref:from_text(
                              Ns, Anchor,
                              <<"human_user(", (integer_to_binary(N))/binary,
                                ").">>,
                              2),
    Blob.
