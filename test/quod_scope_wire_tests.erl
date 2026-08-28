-module(quod_scope_wire_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_proof_limits.hrl").

all_command_shapes_roundtrip_deterministically_test() ->
    Goal = payload(goal, {lookup, item}),
    Answer = payload(answer, {item, found}),
    Reasons = payload(failure_reasons, [{missing, item}]),
    ErlogError = payload(erlog_error, {permission_error, write}),
    Manifest = payload(manifest, manifest()),
    GroupRef = group_ref(),
    Operations =
        [{scope_open, node},
         {scope_open, signed_auth(<<"request">>, <<7:512>>)},
         scope_close,
         scope_seal,
         {scope_attest, Manifest},
         {bind_group_effects, GroupRef, key(130)},
         {bind_operation_effect, <<"signed operation submission">>},
         {invoke_open, id(1), selection(none, []), chain(2), Goal},
         {invoke_next, id(1), 1},
         {invoke_cancel, id(1)},
         {nested_opened, id(2), id(3)},
         {nested_solution, id(2), id(3), 1, Answer},
         {nested_complete, id(2), id(3), 2, Reasons},
         {nested_erlog_error, id(2), id(3), 3, ErlogError},
         {nested_error, id(2), {ontology_busy, <<"quod:c">>}},
         {tx_activated, id(4), id(7), [{id(5), id(6), id(7), id(8)}]},
         {tx_finished, id(4), none},
         {savepoint_allocated, id(4), id(8)},
         {savepoint_restored, id(4), [id(8), id(9)]},
         {materialize, id(4), id(5), id(7), [id(8), id(9)]},
         {batch_restore, [id(8), id(9)]},
         {batch_release, [id(8), id(9)]},
         {controller_error, id(4), {savepoint_limit_exceeded, 1024}}],
    lists:foreach(
      fun({Index, Operation}) ->
          Command = {scope_command, binding(), Index, id(Index + 20),
                     30000, Operation},
          {ok, Encoded} = quod_scope_wire:encode_command(Command),
          ?assertEqual({ok, Command}, quod_scope_wire:decode_request(Encoded)),
          {ok, EncodedAgain} = quod_scope_wire:encode_command(Command),
          ?assertEqual(Encoded, EncodedAgain)
      end, lists:enumerate(Operations)).

scope_v5_authentication_digest_is_exact_and_bounded_test() ->
    {ok, NodeDigest} = quod_scope_wire:authentication_digest(node),
    Auth = signed_auth(<<"request">>, <<7:512>>),
    {ok, SignedDigest} = quod_scope_wire:authentication_digest(Auth),
    ?assertNotEqual(NodeDigest, SignedDigest),
    ?assertNotEqual(
       SignedDigest,
       element(2, quod_scope_wire:authentication_digest(
                    signed_auth(<<"request!">>, <<7:512>>)))),
    ?assertNotEqual(
       SignedDigest,
       element(2, quod_scope_wire:authentication_digest(
                    signed_auth(<<"request">>, <<8:512>>)))),
    ?assertEqual(
       {error, {protocol_error, bad_authentication}},
       quod_scope_wire:authentication_digest(
         signed_auth(<<"request">>, <<7:504>>))),
    ?assertEqual(
       {error, {protocol_error, bad_authentication}},
       quod_scope_wire:authentication_digest(missing)).

scope_v5_binding_rejects_principal_and_authentication_substitution_test() ->
    Command = command({scope_open, node}),
    {scope_command, Binding, Seq, RequestId, Budget, Operation} = Command,
    ?assertMatch({ok, _}, quod_scope_wire:encode_command(Command)),
    ?assertEqual(
       {error, {protocol_error, bad_principal}},
       quod_scope_wire:encode_command(
         {scope_command, setelement(9, Binding, {agent, <<1:248>>}),
          Seq, RequestId, Budget, Operation})),
    ?assertEqual(
       {error, {protocol_error, bad_authentication}},
       quod_scope_wire:encode_command(
         {scope_command, setelement(10, Binding, <<1:248>>),
          Seq, RequestId, Budget, Operation})),
    OldBinding = list_to_tuple(lists:sublist(tuple_to_list(Binding), 8)),
    ?assertEqual(
       {error, {protocol_error, bad_binding}},
       quod_scope_wire:encode_command(
         {scope_command, OldBinding, Seq, RequestId, Budget, Operation})).

all_events_carry_exact_state_and_roundtrip_test() ->
    Goal = payload(goal, {call, c}),
    Answer = payload(answer, ok),
    Reasons = payload(failure_reasons, [{failed, c}]),
    ErlogError = payload(erlog_error, {type_error, callable}),
    Attestation = payload(attestation, attestation()),
    Operations =
        [{scope_opened, 77},
         scope_closed,
         plan_not_material,
         {plan_sealed, <<"opaque plan">>},
         {plan_attested, Attestation},
         group_effects_bound,
         {invocation_opened, id(1)},
         {solution, id(1), 1, Answer},
         {complete, id(1), 2, Reasons},
         {erlog_error, id(1), 3, ErlogError},
         {invocation_error, id(1), 4, {proof_limit_exceeded, <<"quod:b">>}},
         {scope_error, read_only},
         {nested_open, id(2), <<"quod:c">>, chain(2), Goal},
         {nested_next, id(2), id(3), 1},
         {nested_cancel, id(2), id(3)},
         {tx_activate, id(4), id(5), none, [id(6), id(7)]},
         {tx_finish, id(4), id(5), id(7), id(6), finish},
         {tx_finish, id(4), id(5), id(7), id(6), discard},
         {savepoint_allocate, id(4), id(5), id(7)},
         {savepoint_restore, id(4), id(5), id(7), [id(8), id(9)]},
         {materialized, id(4), [id(8), id(9)]},
         {batch_restored, [id(8), id(9)]},
         {batch_released, [id(8), id(9)]}],
    lists:foreach(
      fun({Index, Operation}) ->
          Dirty = (Index rem 2) =:= 0,
          Event = {scope_event, binding(), Index, id(Index + 40), Index,
                   Index - 1, Dirty, Operation},
          {ok, Encoded} = quod_scope_wire:encode_event(Event),
          ?assertEqual({ok, Event}, quod_scope_wire:decode_response(Encoded))
      end, lists:enumerate(Operations)).

scope_error_target_binding_does_not_constrain_invocation_errors_test() ->
    Target = <<"quod:target">>,
    Descendant = <<"quod:descendant">>,
    PendingGroup = <<77:256>>,
    ?assert(quod_scope_wire:scope_error_matches_target(
              {proof_limit_exceeded, Target}, Target)),
    ?assertNot(quod_scope_wire:scope_error_matches_target(
                 {proof_limit_exceeded, Descendant}, Target)),
    ?assert(quod_scope_wire:scope_error_matches_target(read_only, Target)),
    ?assert(quod_scope_wire:scope_error_matches_target(
              {scope_limit_exceeded, 8}, Target)),
    ?assert(quod_scope_wire:scope_error_matches_target(
              {transaction_pending, PendingGroup}, Target)),
    ?assertNot(quod_scope_wire:scope_error_matches_target(
                 arbitrary_remote_error, Target)),
    ?assertEqual(
       {proof_limit_exceeded, Target},
       quod_scope_wire:normalize_public_error(
         {proof_limit_exceeded, Target}, Target)),
    ?assertEqual(
       {protocol_error, proof_engine},
       quod_scope_wire:normalize_public_error(
         {proof_limit_exceeded, Descendant}, Target)),
    ?assertEqual(
       {transaction_pending, PendingGroup},
       quod_scope_wire:normalize_public_error(
         {transaction_pending, PendingGroup}, Target)),

    PendingEvent = event({scope_error,
                          {transaction_pending, PendingGroup}}),
    {ok, EncodedPending} = quod_scope_wire:encode_event(PendingEvent),
    ?assertEqual({ok, PendingEvent},
                 quod_scope_wire:decode_response(EncodedPending)),
    ?assertEqual(
       {error, {protocol_error, bad_error_code}},
       quod_scope_wire:encode_event(
         event({scope_error, {transaction_pending, <<"short">>}}))),

    InvocationError = event(
                        {invocation_error, id(1), 1,
                         {proof_limit_exceeded, Descendant}}),
    {ok, Encoded} = quod_scope_wire:encode_event(InvocationError),
    ?assertEqual(
       {ok, InvocationError}, quod_scope_wire:decode_response(Encoded)).

seal_operations_round_trip_and_stay_bounded_test() ->
    SealCommand = command(scope_seal),
    {ok, EncodedCommand} = quod_scope_wire:encode_command(SealCommand),
    ?assertEqual({ok, SealCommand},
                 quod_scope_wire:decode_request(EncodedCommand)),
    NotMaterial = event(plan_not_material),
    {ok, EncodedNotMaterial} = quod_scope_wire:encode_event(NotMaterial),
    ?assertEqual({ok, NotMaterial},
                 quod_scope_wire:decode_response(EncodedNotMaterial)),
    Sealed = event({plan_sealed, <<"opaque plan blob">>}),
    {ok, EncodedSealed} = quod_scope_wire:encode_event(Sealed),
    ?assertEqual({ok, Sealed}, quod_scope_wire:decode_response(EncodedSealed)),
    Oversized = event(
                  {plan_sealed,
                   <<0:(?QUOD_MAX_PLAN_ENVELOPE_BYTES + 1)/unit:8>>}),
    ?assertEqual({error, {too_large, plan}},
                 quod_scope_wire:encode_event(Oversized)),
    %% The seal failure vocabulary is part of the closed public catalog.
    lists:foreach(
      fun(Reason) ->
          Event = event({scope_error, Reason}),
          {ok, EncodedError} = quod_scope_wire:encode_event(Event),
          ?assertEqual({ok, Event},
                       quod_scope_wire:decode_response(EncodedError))
      end,
      [{too_large, transcript}, {too_large, plan}, {too_large, result},
       {non_transactional_dependency, {directory_host, 5}},
       {network_identity_unavailable, <<"quod:target">>}]),
    ?assertEqual(
       {error, {protocol_error, bad_error_code}},
       quod_scope_wire:encode_event(
         event({scope_error, {non_transactional_dependency, not_a_functor}}))).

manifest_attestation_payloads_are_canonical_and_bounded_test() ->
    Manifest = manifest(),
    Attestation = attestation(),
    ManifestBlob = payload(manifest, Manifest),
    AttestationBlob = payload(attestation, Attestation),
    ?assertEqual(
       {ok, Manifest},
       quod_scope_wire:decode_payload(manifest, ManifestBlob)),
    ?assertEqual(
       {ok, Attestation},
       quod_scope_wire:decode_payload(attestation, AttestationBlob)),
    ?assertEqual(
       {error, {too_large, manifest}},
       quod_scope_wire:encode_command(
         command(
           {scope_attest,
            <<0:(?QUOD_MAX_DTX_BODY_BYTES + 1)/unit:8>>}))),
    ?assertEqual(
       {error, {too_large, attestation}},
       quod_scope_wire:encode_event(
         event(
           {plan_attested,
            <<0:(?QUOD_MAX_DTX_BODY_BYTES + 1)/unit:8>>}))).

group_effect_binding_is_exact_and_bounded_test() ->
    GroupRef = group_ref(),
    Command = command({bind_group_effects, GroupRef, key(131)}),
    {ok, Encoded} = quod_scope_wire:encode_command(Command),
    ?assertEqual({ok, Command}, quod_scope_wire:decode_request(Encoded)),
    ?assertEqual(
       {error, {protocol_error, bad_shape}},
       quod_scope_wire:encode_command(
         command({bind_group_effects, GroupRef, <<1:248>>}))),
    ?assertEqual(
       {error, {protocol_error, bad_shape}},
       quod_scope_wire:encode_command(
         command({bind_group_effects,
                  setelement(2, GroupRef, <<>>), key(131)}))),
    Ack = event(group_effects_bound),
    {ok, AckEncoded} = quod_scope_wire:encode_event(Ack),
    ?assertEqual({ok, Ack}, quod_scope_wire:decode_response(AckEncoded)).

operation_effect_submission_crosses_scope_at_shared_bound_test() ->
    SubmissionBlob =
        <<0:?QUOD_MAX_OPERATION_SUBMISSION_BYTES/unit:8>>,
    Command = command({bind_operation_effect, SubmissionBlob}),
    {ok, Encoded} = quod_scope_wire:encode_command(Command),
    %% This is the regression: the old independent 128 KiB envelope rejected
    %% an artifact accepted by the transaction codec before it reached the
    %% authenticated target-side decoder.
    ?assert(byte_size(Encoded) > (128 * 1024)),
    ?assert(byte_size(Encoded) =< ?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES),
    ?assertEqual({ok, Command}, quod_scope_wire:decode_request(Encoded)),
    OversizedBlob = <<SubmissionBlob/binary, 0>>,
    Oversized = command({bind_operation_effect, OversizedBlob}),
    ?assertEqual(
       {error, {too_large, operation_submission}},
       quod_scope_wire:encode_command(Oversized)),
    %% A peer cannot bypass the field owner by writing the ETF directly.
    ?assertEqual(
       {error, {too_large, operation_submission}},
       quod_scope_wire:decode_request(raw_frame(Oversized))).

scope_namespace_uses_directory_bound_test() ->
    MaxNamespace =
        binary:copy(<<"n">>, ?DIRECTORY_MAX_NAMESPACE_BYTES),
    AtLimit = command_with_binding(
                {scope_open, node}, binding_with_origin(MaxNamespace)),
    ?assertMatch({ok, _}, quod_scope_wire:encode_command(AtLimit)),
    OversizedNamespace = <<MaxNamespace/binary, "n">>,
    TooLarge = command_with_binding(
                 {scope_open, node},
                 binding_with_origin(OversizedNamespace)),
    ?assertEqual(
       {error, {protocol_error, bad_identity}},
       quod_scope_wire:encode_command(TooLarge)).

submit_operations_round_trip_and_stay_bounded_test() ->
    {ok, GoalBlob} = quod_durable_term:encode_goal({goal, ok}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{'X' => ok}),
    Submit = command(
               {submit_plan, <<"plan blob">>, GoalBlob, ResultBlob, []}),
    {ok, EncodedSubmit} = quod_scope_wire:encode_command(Submit),
    ?assertEqual({ok, Submit}, quod_scope_wire:decode_request(EncodedSubmit)),
    %% Goal/result bytes remain opaque at the outer command boundary. Their
    %% canonical decode happens only after the target has authenticated and
    %% matched the already-open scope.
    OpaqueSubmit = command(
                     {submit_plan, <<"plan blob">>,
                      <<"not canonical goal ETF">>,
                      <<"not canonical result ETF">>, []}),
    {ok, EncodedOpaque} = quod_scope_wire:encode_command(OpaqueSubmit),
    ?assertEqual(
       {ok, OpaqueSubmit}, quod_scope_wire:decode_request(EncodedOpaque)),
    ?assertEqual(
       {error, {too_large, plan}},
       quod_scope_wire:encode_command(
         command({submit_plan,
                  <<0:(?QUOD_MAX_PLAN_ENVELOPE_BYTES + 1)/unit:8>>,
                  GoalBlob, ResultBlob, []}))),
    ?assertEqual(
       {error, {too_large, result}},
       quod_scope_wire:encode_command(
         command({submit_plan, <<"p">>, GoalBlob,
                  <<0:(?QUOD_MAX_DURABLE_RESULT_BYTES + 1)/unit:8>>, []}))),
    ?assertEqual(
       {error, {protocol_error, bad_payload}},
       quod_scope_wire:encode_command(
         command({submit_plan, <<"p">>, GoalBlob, ResultBlob,
                  [{<<"not-trace-context">>, <<"x">>}]}))),
    TxId = <<2:256>>,
    Committed = event({plan_submitted, {committed, 7, TxId}}),
    {ok, EncodedCommitted} = quod_scope_wire:encode_event(Committed),
    ?assertEqual({ok, Committed},
                 quod_scope_wire:decode_response(EncodedCommitted)),
    lists:foreach(
      fun(Reason) ->
          Event = event({plan_submitted, {rejected, Reason}}),
          {ok, Encoded} = quod_scope_wire:encode_event(Event),
          ?assertEqual({ok, Event}, quod_scope_wire:decode_response(Encoded))
      end,
      [conflict_retry, policy_self_seal_forbidden, retry, consensus_unavailable,
       bad_plan]),
    OutcomeRef = {transaction, <<"ns">>, <<1:256>>, TxId},
    Unknown = event({plan_submitted, {outcome_unknown, OutcomeRef}}),
    {ok, EncodedUnknown} = quod_scope_wire:encode_event(Unknown),
    ?assertEqual({ok, Unknown},
                 quod_scope_wire:decode_response(EncodedUnknown)),
    ?assertEqual(
       {error, {protocol_error, bad_error_code}},
       quod_scope_wire:encode_event(
         event({plan_submitted, {rejected, arbitrary_atom}}))),
    ?assertEqual(
       {error, {protocol_error, bad_shape}},
       quod_scope_wire:encode_event(
         event({plan_submitted, {committed, 0, TxId}}))),
    ?assertEqual(
       {error, {protocol_error, bad_shape}},
       quod_scope_wire:encode_event(
         event({plan_submitted, {committed, 7, <<"short">>}}))).

retired_generic_public_errors_are_rejected_test() ->
    Retired = [broken_scope, scope_timeout, bad_request, not_allowed,
               unknown_lineage, unknown_savepoint,
               active_child_transaction, transaction_scope_mismatch,
               broken_transaction_controller],
    lists:foreach(
      fun(Reason) ->
          Command = command({nested_error, id(90), Reason}),
          Event = event({scope_error, Reason}),
          ?assertEqual(
             {error, {protocol_error, bad_error_code}},
             quod_scope_wire:encode_command(Command)),
          ?assertEqual(
             {error, {protocol_error, bad_error_code}},
             quod_scope_wire:decode_request(raw_frame(Command))),
          ?assertEqual(
             {error, {protocol_error, bad_error_code}},
             quod_scope_wire:encode_event(Event)),
          ?assertEqual(
             {error, {protocol_error, bad_error_code}},
             quod_scope_wire:decode_response(raw_frame(Event)))
      end, Retired).

goal_stays_opaque_until_explicit_payload_decode_test() ->
    Unknown = <<"quod_scope_wire_never_intern_",
                (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    ?assertException(error, badarg, binary_to_existing_atom(Unknown, utf8)),
    UnknownAtomEtf = <<131, 119, (byte_size(Unknown)):8, Unknown/binary>>,
    Command = {scope_command, binding(), 1, id(10), 30000,
               {invoke_open, id(11), selection(none, []),
                chain(1), UnknownAtomEtf}},
    {ok, Encoded} = quod_scope_wire:encode_command(Command),
    ?assertEqual({ok, Command}, quod_scope_wire:decode_request(Encoded)),
    ?assertEqual(
       {error, {protocol_error, bad_payload}},
       quod_scope_wire:decode_payload(goal, UnknownAtomEtf)),
    ?assertException(error, badarg, binary_to_existing_atom(Unknown, utf8)).

opaque_goal_symbol_survives_scope_codec_test() ->
    Symbol = <<"quod_scope_relay_only_",
               (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Goal = {{'$quod_symbol', Symbol}, x},
    {ok, Blob} = quod_scope_wire:encode_payload(goal, Goal),
    ?assertEqual({ok, Goal}, quod_scope_wire:decode_payload(goal, Blob)),
    ?assertException(error, badarg, binary_to_existing_atom(Symbol, utf8)).

payload_byte_bounds_are_exact_test() ->
    exact_payload_boundary(goal, ?QUOD_MAX_NESTED_GOAL_BYTES),
    exact_payload_boundary(answer, ?QUOD_MAX_PROOF_ANSWER_BYTES),
    exact_failure_reason_payload_boundary(),
    exact_payload_boundary(erlog_error, ?ERLOG_MAX_FAILURE_REASON_BYTES),
    ?assertEqual(
       {ok, [{because, no_clause}]},
       quod_scope_wire:decode_payload(
         failure_reasons,
         payload(failure_reasons, [{because, no_clause}]))),
    ?assertEqual(
       {ok, {type_error, callable}},
       quod_scope_wire:decode_payload(
         erlog_error, payload(erlog_error, {type_error, callable}))).

exact_failure_reason_payload_boundary() ->
    Reasons = failure_reason_stack_at_wire_limit(),
    {ok, AtLimit} = quod_scope_wire:encode_payload(
                      failure_reasons, Reasons),
    ?assertEqual(?ERLOG_MAX_FAILURE_REASONS_BYTES, byte_size(AtLimit)),
    ?assertEqual(
       {ok, Reasons},
       quod_scope_wire:decode_payload(failure_reasons, AtLimit)),
    Prefix = lists:droplast(Reasons),
    Last = lists:last(Reasons),
    TooLarge = Prefix ++ [<<Last/binary, 0>>],
    ?assertEqual(
       {error, {too_large, failure_reasons}},
       quod_scope_wire:encode_payload(failure_reasons, TooLarge)),
    ?assertEqual(
       {error, {too_large, failure_reasons}},
       quod_scope_wire:decode_payload(
         failure_reasons, <<AtLimit/binary, 0>>)),
    ?assertEqual(
       {ok, []},
       quod_scope_wire:decode_payload(
         failure_reasons, payload(failure_reasons, []))).

scope_envelope_byte_bound_is_exact_and_predecode_test() ->
    AtLimit = <<0:?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES/unit:8>>,
    %% At the exact byte boundary decoding is attempted and rejects the bytes
    %% as ETF. One byte more is rejected before any decode.
    ?assertEqual(
       {error, {protocol_error, bad_etf}},
       quod_scope_wire:decode_request(AtLimit)),
    ?assertEqual(
       {error, {too_large, scope_envelope}},
       quod_scope_wire:decode_request(
         <<AtLimit/binary, 0>>)).

outer_safe_etf_and_version_are_fail_closed_test() ->
    Command = {scope_command,
               binding_with_origin(
                 binary:copy(<<"x">>, ?DIRECTORY_MAX_NAMESPACE_BYTES)),
               1, id(1), 30000, {scope_open, node}},
    {ok, Encoded} = quod_scope_wire:encode_command(Command),
    ?assertEqual(
       {error, {protocol_error, bad_etf}},
       quod_scope_wire:decode_request(<<Encoded/binary, 0>>)),
    Outer = binary_to_term(Encoded),
    Compressed = term_to_binary(Outer, [{compressed, 9}]),
    ?assertMatch(<<131, 80, _/binary>>, Compressed),
    ?assertEqual(
       {error, {protocol_error, bad_etf}},
       quod_scope_wire:decode_request(Compressed)),
    {Domain, _Version, Frame} = Outer,
    %% Every superseded scope wire is an identifiable rejection: an old peer
    %% is refused at the version boundary, never misparsed as the current wire.
    lists:foreach(
      fun(OldVersion) ->
          WrongVersion =
              term_to_binary({Domain, OldVersion, Frame}, [deterministic]),
          ?assertEqual(
             {error, {protocol_error, wrong_version}},
             quod_scope_wire:decode_request(WrongVersion))
      end, lists:seq(1, 7)),
    WrongDomain = term_to_binary({<<"other.scope">>, 5, Frame}, [deterministic]),
    ?assertEqual(
       {error, {protocol_error, bad_domain}},
       quod_scope_wire:decode_request(WrongDomain)),
    ?assertEqual(
       {error, {protocol_error, bad_frame_type}},
       quod_scope_wire:decode_response(Encoded)),
    Event = event(scope_closed),
    {ok, EncodedEvent} = quod_scope_wire:encode_event(Event),
    ?assertEqual(
       {error, {protocol_error, bad_frame_type}},
       quod_scope_wire:decode_request(EncodedEvent)),
    ?assertEqual(
       {error, {protocol_error, bad_shape}},
       quod_scope_wire:decode_request(
         term_to_binary({quod_ask_open, id(1)}, [deterministic]))).

unknown_outer_atom_is_not_created_test() ->
    Unknown = <<"quod_scope_outer_never_intern_",
                (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    ?assertException(error, badarg, binary_to_existing_atom(Unknown, utf8)),
    UnknownAtomEtf = <<131, 119, (byte_size(Unknown)):8, Unknown/binary>>,
    ?assertEqual(
       {error, {protocol_error, bad_etf}},
       quod_scope_wire:decode_request(UnknownAtomEtf)),
    ?assertException(error, badarg, binary_to_existing_atom(Unknown, utf8)).

identity_probe_and_response_are_fixed_safe_frames_test() ->
    Probe = {scope_identity_probe, id(70), key(1), <<"quod:seeded">>},
    {ok, EncodedProbe} = quod_scope_wire:encode_identity_probe(Probe),
    ?assertEqual(
       {ok, Probe}, quod_scope_wire:decode_request(EncodedProbe)),
    ?assertEqual(
       {error, {protocol_error, bad_frame_type}},
       quod_scope_wire:decode_response(EncodedProbe)),

    Response =
        {scope_identity_response, id(70), key(2),
         {<<"quod:seeded">>, key(3)}, validator},
    {ok, EncodedResponse} =
        quod_scope_wire:encode_identity_response(Response),
    ?assertEqual(
       {ok, Response},
       quod_scope_wire:decode_response(EncodedResponse)),
    ?assertEqual(
       {error, {protocol_error, bad_frame_type}},
       quod_scope_wire:decode_request(EncodedResponse)),
    ?assertEqual(
       {error, {protocol_error, bad_role}},
       quod_scope_wire:encode_identity_response(
         setelement(5, Response, member))),

    Legacy = term_to_binary(
               {quod_scope_identity, id(70), key(2), key(3)},
               [deterministic]),
    ?assertEqual(
       {error, {protocol_error, bad_shape}},
       quod_scope_wire:decode_response(Legacy)).

ids_sequences_chain_generation_and_dirty_are_bounded_test() ->
    Max = ?QUOD_SCOPE_WIRE_MAX_UINT64,
    Goal = payload(goal, true),
    MaxCommand = {scope_command, binding(), Max, id(1), Max,
                  {invoke_open, id(2), selection(none, []),
                   chain(?QUOD_MAX_ACTIVE_PROOF_DEPTH), Goal}},
    ?assertMatch({ok, _}, quod_scope_wire:encode_command(MaxCommand)),
    ?assertEqual(
       {error, {protocol_error, bad_sequence}},
       quod_scope_wire:encode_command(setelement(3, MaxCommand, Max + 1))),
    ?assertEqual(
       {error, {protocol_error, bad_budget}},
       quod_scope_wire:encode_command(setelement(5, MaxCommand, Max + 1))),
    ?assertEqual(
       {error, {protocol_error, bad_id}},
       quod_scope_wire:encode_command(setelement(4, MaxCommand, <<0:120>>))),
    TooDeep = setelement(
                6, MaxCommand,
                {invoke_open, id(2), selection(none, []),
                 chain(?QUOD_MAX_ACTIVE_PROOF_DEPTH + 1), Goal}),
    ?assertEqual(
       {error, {protocol_error, bad_chain}},
       quod_scope_wire:encode_command(TooDeep)),
    BadChain = setelement(
                 6, MaxCommand,
                 {invoke_open, id(2), selection(none, []),
                  [{<<"bad">>, <<0:248>>}], Goal}),
    ?assertEqual(
       {error, {protocol_error, bad_chain}},
       quod_scope_wire:encode_command(BadChain)),
    Event = {scope_event, binding(), Max, id(3), Max, Max, false,
             {scope_opened, Max}},
    ?assertMatch({ok, _}, quod_scope_wire:encode_event(Event)),
    ?assertEqual(
       {error, {protocol_error, bad_generation}},
       quod_scope_wire:encode_event(setelement(6, Event, Max + 1))),
    ?assertEqual(
       {error, {protocol_error, bad_dirty}},
       quod_scope_wire:encode_event(setelement(7, Event, not_a_boolean))).

dirty_is_mandatory_and_error_vocabulary_is_closed_test() ->
    Event = {scope_event, binding(), 1, id(3), 1, 0, true,
             {scope_error, {protocol_error, command_sequence}}},
    {ok, Encoded} = quod_scope_wire:encode_event(Event),
    {Domain, Version,
     {scope_event, Binding, EventSeq, RequestId, CommandSeq,
      Generation, _Dirty, Operation}} = binary_to_term(Encoded),
    MissingDirty = term_to_binary(
                     {Domain, Version,
                      {scope_event, Binding, EventSeq, RequestId,
                       CommandSeq, Generation, Operation}},
                     [deterministic]),
    ?assertEqual(
       {error, {protocol_error, bad_shape}},
       quod_scope_wire:decode_response(MissingDirty)),
    BadDirty = term_to_binary(
                 {Domain, Version,
                  {scope_event, Binding, EventSeq, RequestId,
                   CommandSeq, Generation, not_boolean, Operation}},
                 [deterministic]),
    ?assertEqual(
       {error, {protocol_error, bad_dirty}},
       quod_scope_wire:decode_response(BadDirty)),
    ?assertEqual(
       {error, {protocol_error, bad_error_code}},
       quod_scope_wire:encode_event(
         setelement(8, Event, {scope_error, arbitrary_remote_error}))).

lineage_controller_shapes_and_limits_are_exact_test() ->
    Goal = payload(goal, true),
    Invoke = command(
               {invoke_open, id(1), selection(id(2), [id(3), id(4)]),
                chain(1), Goal}),
    ?assertMatch({ok, _}, quod_scope_wire:encode_command(Invoke)),
    ?assertMatch(
       {ok, _},
       quod_scope_wire:encode_command(
         command({invoke_open, id(1), selection(none, []),
                  chain(1), Goal}))),
    ?assertEqual(
       {error, {protocol_error, bad_selection}},
       quod_scope_wire:encode_command(
         command({invoke_open, id(1), selection(<<0:120>>, []),
                  chain(1), Goal}))),

    Limit = ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF,
    BatchIds = ids(1000, Limit),
    ?assertMatch(
       {ok, _},
       quod_scope_wire:encode_command(
         command({invoke_open, id(1), selection(id(2), BatchIds),
                  chain(1), Goal}))),
    ?assertEqual(
       {error, {protocol_error, bad_selection}},
       quod_scope_wire:encode_command(
         command({invoke_open, id(1),
                  selection(id(2), lists:reverse(BatchIds)),
                  chain(1), Goal}))),
    ?assertEqual(
       {error, {protocol_error, bad_selection}},
       quod_scope_wire:encode_command(
         command({invoke_open, id(1), selection(none, [id(3)]),
                  chain(1), Goal}))),
    ?assertEqual(
       {error, {protocol_error, bad_selection}},
       quod_scope_wire:encode_command(
         command({invoke_open, id(1),
                  selection(id(2), ids(1000, Limit + 1)),
                  chain(1), Goal}))),
    ?assertMatch(
       {ok, _},
       quod_scope_wire:encode_command(command({batch_restore, BatchIds}))),
    ?assertEqual(
       {error, {protocol_error, bad_id_list}},
       quod_scope_wire:encode_command(
         command({batch_restore, ids(1000, Limit + 1)}))),
    ?assertEqual(
       {error, {protocol_error, bad_id_list}},
       quod_scope_wire:encode_command(
         command({batch_release, [id(10), id(10)]}))),
    ?assertEqual(
       {error, {protocol_error, bad_id_list}},
       quod_scope_wire:encode_command(
         command({batch_release, [id(10) | improper]}))),
    ?assertEqual(
       {error, {protocol_error, bad_id_list}},
       quod_scope_wire:encode_event(
         event({tx_activate, id(1), id(2), none, []}))),

    Activated = [{id(11), id(12), id(13), id(14)},
                 {id(15), id(16), id(17), id(14)}],
    ?assertMatch(
       {ok, _},
       quod_scope_wire:encode_command(
         command({tx_activated, id(1), id(17), Activated}))),
    ?assertEqual(
       {error, {protocol_error, bad_activation}},
       quod_scope_wire:encode_command(
         command({tx_activated, id(1), id(13), Activated}))),
    DuplicateFrame = [hd(Activated),
                      {id(11), id(18), id(19), id(14)}],
    ?assertEqual(
       {error, {protocol_error, bad_activation}},
       quod_scope_wire:encode_command(
         command({tx_activated, id(1), id(19), DuplicateFrame}))),
    ?assertEqual(
       {error, {protocol_error, bad_transaction_mode}},
       quod_scope_wire:encode_event(
         event({tx_finish, id(1), id(2), id(3), id(4), rollback}))).

superseded_transaction_wire_shapes_are_rejected_test() ->
    Goal = payload(goal, true),
    OldCommands =
        [{{invoke_open, id(1), chain(1), Goal}, bad_shape},
         {{invoke_open, id(1), none, chain(1), Goal}, bad_selection},
         {{savepoint_error, id(1), bad_request}, bad_shape},
         {{savepoint_checkpoint, id(1)}, bad_shape},
         {{savepoint_restore, id(1)}, bad_shape},
         {{savepoint_release, id(1)}, bad_shape},
         {{batch_checkpoint, [id(1)]}, bad_shape}],
    lists:foreach(
      fun({Operation, ErrorKind}) ->
          Command = command(Operation),
          ?assertEqual(
             {error, {protocol_error, ErrorKind}},
             quod_scope_wire:encode_command(Command)),
          ?assertEqual(
             {error, {protocol_error, ErrorKind}},
             quod_scope_wire:decode_request(raw_frame(Command)))
      end, OldCommands),
    OldEvents =
        [{savepoint_allocate, id(1)},
         {savepoint_checkpointed, id(1)},
         {savepoint_restored, id(1)},
         {savepoint_released, id(1)},
         {batch_checkpointed, [id(1)]}],
    lists:foreach(
      fun(Operation) ->
          Event = event(Operation),
          ?assertEqual(
             {error, {protocol_error, bad_shape}},
             quod_scope_wire:encode_event(Event)),
          ?assertEqual(
             {error, {protocol_error, bad_shape}},
             quod_scope_wire:decode_response(raw_frame(Event)))
      end, OldEvents).

exact_payload_boundary(Kind, MaxBytes) ->
    Empty = term_to_binary({1, <<>>}, [deterministic]),
    Term = binary:copy(<<"p">>, MaxBytes - byte_size(Empty)),
    {ok, AtLimit} = quod_scope_wire:encode_payload(Kind, Term),
    ?assertEqual(MaxBytes, byte_size(AtLimit)),
    ?assertEqual({ok, Term}, quod_scope_wire:decode_payload(Kind, AtLimit)),
    ?assertEqual(
       {error, {too_large, Kind}},
       quod_scope_wire:encode_payload(Kind, <<Term/binary, "x">>)),
    ?assertEqual(
       {error, {too_large, Kind}},
       quod_scope_wire:decode_payload(Kind, <<AtLimit/binary, 0>>)).

reason_wire_size(Reason) ->
    {ok, Wire} = quod_wire_term:encode(Reason),
    byte_size(term_to_binary(Wire, [deterministic])).

reason_stack_wire_size(Reasons) ->
    {ok, Wire} = quod_wire_term:encode(Reasons),
    byte_size(term_to_binary(Wire, [deterministic])).

reason_binary_at_wire_size(Size) ->
    EmptySize = reason_wire_size(<<>>),
    true = Size >= EmptySize,
    Binary = binary:copy(<<"r">>, Size - EmptySize),
    Size = reason_wire_size(Binary),
    Binary.

failure_reason_stack_at_wire_limit() ->
    MaxReason = reason_binary_at_wire_size(?ERLOG_MAX_FAILURE_REASON_BYTES),
    Prefix = lists:duplicate(7, MaxReason),
    BaseSize = reason_stack_wire_size(Prefix ++ [<<>>]),
    Growth = ?ERLOG_MAX_FAILURE_REASONS_BYTES - BaseSize,
    true = Growth >= 0,
    Last = binary:copy(<<"s">>, Growth),
    true = reason_wire_size(Last) =< ?ERLOG_MAX_FAILURE_REASON_BYTES,
    Reasons = Prefix ++ [Last],
    ?ERLOG_MAX_FAILURE_REASONS_BYTES = reason_stack_wire_size(Reasons),
    Reasons.

payload(Kind, Term) ->
    {ok, Blob} = quod_scope_wire:encode_payload(Kind, Term),
    Blob.

manifest() ->
    {ok, GoalBlob} = quod_durable_term:encode_goal({scope_wire, true}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    {ok, Manifest} = quod_dtx:new_manifest(
                       #{proof_id => key(120),
                         coordinator =>
                             {<<"quod:a">>, key(5), key(121), key(122)},
                         nonce => key(123),
                         principal => anonymous,
                         goal => GoalBlob,
                         result => ResultBlob,
                         request_binding => none,
                         participants =>
                             [{{<<"quod:b">>, key(6)}, key(124)},
                              {{<<"quod:c">>, key(7)}, key(125)}]}),
    Manifest.

attestation() ->
    {quod_dtx_attestation, 2, {<<"quod:b">>, key(6)},
     key(126), key(127), key(128), <<129:512>>}.

group_ref() ->
    Manifest = manifest(),
    {ok, GroupRef} = quod_dtx:manifest_group_ref(Manifest, key(129)),
    GroupRef.

command(Operation) ->
    {scope_command, binding(), 1, id(90), 30000, Operation}.

command_with_binding(Operation, Binding) ->
    {scope_command, Binding, 1, id(90), 30000, Operation}.

event(Operation) ->
    {scope_event, binding(), 1, id(91), 1, 0, false, Operation}.

raw_frame(Frame) ->
    term_to_binary({<<"quod.scope">>, 8, Frame}, [deterministic]).

signed_auth(RequestBytes, Signature) ->
    {ok, #{blob := AgentRef}} = quod_agent_ref:from_text(
                                  <<"quod:a">>, key(5),
                                  <<"human_user(alice).">>, 2),
    Statement = {agent_identity_v1, key(7),
                 {<<"quod:a">>, key(5)}, key(3), key(8),
                 AgentRef, key(9), key(10), 9999999999999, active},
    {ok, Certificate} = quod_agent_identity:certificate(
                          Statement, [], []),
    {signed_goal, RequestBytes, Signature, Certificate}.

selection(Lineage, BatchIds) ->
    {tx_selection, Lineage, BatchIds}.

binding() -> binding_with_origin(<<"quod:a">>).

binding_with_origin(OriginNs) ->
    {ok, AuthenticationDigest} =
        quod_scope_wire:authentication_digest(node),
    {scope_binding, key(1), key(2), key(3), id(4),
     {OriginNs, key(5)}, {<<"quod:b">>, key(6)}, read_write,
     {node, key(1)}, AuthenticationDigest}.

chain(Count) ->
    [{<<"quod:", (integer_to_binary(Index))/binary>>, key(20 + Index)}
     || Index <- lists:seq(1, Count)].

ids(Start, Count) ->
    [id(Start + Offset) || Offset <- lists:seq(0, Count - 1)].

key(N) -> <<N:256>>.
id(N) -> <<N:128>>.
