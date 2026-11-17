-module(carrier_admission_checks).
-include("retired_presentation_sizes.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").
-include("quod_ledger.hrl").

full_material_payload_roundtrip_test() ->
    Value = {model, binary:copy(<<"x">>, ?LEGACY_SCOPE_WIRE_MAX_ENVELOPE_BYTES + 1)},
    {ok, Blob} = quod_scope_wire:encode_payload(goal, Value),
    ?assertEqual({ok, Value}, quod_scope_wire:decode_payload(goal, Blob)).

journal_frame_has_no_material_subquota_test() ->
    Value = binary:copy(<<"x">>, ?LEGACY_MAX_DTX_BODY_BYTES +
                                ?LEGACY_MAX_DTX_CONTROL_BYTES + 164),
    <<_Magic:32, Size:32, CRC:32, Payload/binary>> =
        quod_signing_journal:test_frame(Value),
    ?assertEqual(Value, Payload),
    ?assertEqual(byte_size(Value), Size),
    ?assertEqual(erlang:crc32(Value), CRC).

large_recovered_goal_preserves_authorization_test() ->
    Target = {<<"quod:policy-target">>, <<1:256>>},
    Origin = {<<"quod:policy-origin">>, <<2:256>>},
    Chain = [Target, Origin],
    Goal = {read, binary:copy(<<"x">>, ?LEGACY_MAX_PLAN_ENVELOPE_BYTES + 1)},
    Allow = quod_ask_tests:policy_kb(
        [{can_invoke, {'Goal'}, {'Principal'}, {'Chain'}, {'Namespace'}}]),
    Deny = quod_ask_tests:policy_kb([]),
    Transcript = quod_ask_tests:authorization_transcript(Goal, allowed, Chain),
    ?assertEqual(ok, quod_ask:validate_authorization_transcript(
        Target, Origin, anonymous, 1, Transcript, Allow)),
    ?assertEqual({error, invalid_authorization_transcript},
        quod_ask:validate_authorization_transcript(
            Target, Origin, anonymous, 1, Transcript, Deny)),
    ?assertEqual({error, invalid_authorization_transcript},
        quod_ask:validate_authorization_transcript(
            Target, {<<"quod:wrong">>, <<3:256>>}, anonymous, 1, Transcript, Allow)).

large_signed_block_survives_journal_reopen_test() ->
    F = quod_ledger_artifact_tests:fixture(quod_ledger),
    {Ns, Anchor} = Binding = maps:get(binding, F),
    Base = maps:get(transaction, F),
    T0 = Base#transaction{diff=[{assert, {{payload,binary:copy(<<7>>,1100*1024)},true}}],
                          sig=none,signed_bytes=none},
    T1 = quod_transaction:bind_id(Binding,T0),
    {ok,T} = quod_transaction:sign({Ns,Anchor,maps:get(admission,F)},T1,maps:get(signer,F)),
    {ok,B} = quod_ledger:new_block({maps:get(era,F),5},
        quod_ledger:block_ref(maps:get(parent,F)),4,{batch,[T]},103),
    quod_signing_journal_tests:with_dir(fun(_,Dir) ->
        Domain = <<91:256>>,
        {ok,J0} = quod_signing_journal:initialize(Ns,Domain,Dir),
        {ok,J1} = quod_signing_journal:record_support(J0,B),
        Expected = quod_signing_journal:supported_blocks(J1),
        J2 = quod_signing_journal:compact(J1),
        ok = quod_signing_journal:close(J2),
        {ok,J3} = quod_signing_journal:recover(Ns,Domain,Dir),
        ?assertEqual(Expected,quod_signing_journal:supported_blocks(J3)),
        ok = quod_signing_journal:close(J3)
    end).
