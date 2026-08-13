-module(quod_signing_journal_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-define(MAGIC, 16#51534A31). %% "QSJ1"
-define(HDR_BYTES, 12).

persists_votes_and_dtx_floor_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          H1 = hash(1),
          H2 = hash(2),
          {ok, J1} = quod_signing_journal:record_vote(J0, support, 6, H1),
          %% Support and final votes are independent protocol decisions.
          {ok, J1a} = quod_signing_journal:record_vote(J1, commit, 6, H2),
          {ok, J1b} = quod_signing_journal:record_vote(
                        J1a, complaint, 7, none),
          {Signer, Admission, Control} = finalize_control(1, 7),
          Lane = {Admission, maps:get(pubkey, Signer)},
          {ok, J2, Envelope} = quod_signing_journal:record_dtx(J1b, Control),
          ?assertEqual({ok, Control}, quod_dtx:decode_control(Envelope)),
          ?assertEqual(7, quod_signing_journal:dtx_floor(J2, Lane)),
          ok = quod_signing_journal:close(J2),

          {ok, J3} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(#{6 => #{support => H1, final => {commit, H2}},
                         7 => #{support => none, final => complaint}},
                       quod_signing_journal:rounds(J3)),
          ?assertEqual(7, quod_signing_journal:dtx_floor(J3, Lane)),
          ?assertEqual(none, quod_signing_journal:pending_begin(J3)),
          ok = quod_signing_journal:close(J3)
      end).

conflicting_votes_fail_stop_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          H1 = hash(1),
          H2 = hash(2),
          {ok, J1} = quod_signing_journal:record_vote(J0, support, 6, H1),
          ?assertError(
             {vote_conflict, 6, {support, H1}, {support, H2}},
             quod_signing_journal:record_vote(J1, support, 6, H2)),
          {ok, J2} = quod_signing_journal:record_vote(
                       J1, complaint, 6, none),
          ok = quod_signing_journal:close(J2),
          {ok, J3} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertError(
             {vote_conflict, 6, complaint, {commit, H1}},
             quod_signing_journal:record_vote(J3, commit, 6, H1)),
          ok = quod_signing_journal:close(J3)
      end).

unused_header_is_replaceable_but_used_compacted_header_is_not_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          ok = quod_signing_journal:close(J0),
          {ok, J1} = quod_signing_journal:initialize(Ns, domain(2), Dir),
          {ok, J2} = quod_signing_journal:record_vote(
                       J1, support, 1, hash(1)),
          %% Reconcile removes the only live latch.  Compaction must still
          %% retain the sticky evidence that a signature once existed.
          {ok, J3} = quod_signing_journal:reconcile(
                       J2, summary(1, #{}, none)),
          J4 = quod_signing_journal:compact(J3),
          ?assertEqual(#{}, quod_signing_journal:rounds(J4)),
          ok = quod_signing_journal:close(J4),
          Path = journal_path(Ns, Dir),
          {ok, Before} = file:read_file(Path),
          ?assertError(signing_journal_not_empty,
                       quod_signing_journal:initialize(
                         Ns, domain(3), Dir)),
          ?assertEqual({ok, Before}, file:read_file(Path))
      end).

missing_recovery_fails_without_creating_a_file_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Path = journal_path(Ns, Dir),
          ?assertError({signing_journal_missing, Path},
                       quod_signing_journal:recover(Ns, domain(1), Dir)),
          ?assertNot(filelib:is_file(Path))
      end).

legacy_magics_fail_explicitly_without_mutation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Path = journal_path(Ns, Dir),
          ok = filelib:ensure_dir(Path),
          lists:foreach(
            fun({Version, Magic}) ->
                Bytes = <<Magic:32>>,
                ok = file:write_file(Path, Bytes),
                ?assertError(
                   {unsupported_vote_journal_format, Version, 0},
                   quod_signing_journal:recover(Ns, domain(1), Dir)),
                ?assertEqual({ok, Bytes}, file:read_file(Path))
            end,
            [{1, 16#51564A31}, {2, 16#51564A32}, {3, 16#51564A33}])
      end).

legacy_magic_in_tail_is_not_trimmed_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          ok = quod_signing_journal:close(J0),
          Path = journal_path(Ns, Dir),
          {ok, Header} = file:read_file(Path),
          Legacy = <<16#51564A33:32>>,
          ok = file:write_file(Path, Legacy, [append]),
          Bytes = <<Header/binary, Legacy/binary>>,
          HeaderSize = byte_size(Header),
          ?assertError(
             {unsupported_vote_journal_format, 3, HeaderSize},
             quod_signing_journal:recover(Ns, domain(1), Dir)),
          ?assertEqual({ok, Bytes}, file:read_file(Path))
      end).

torn_final_frame_is_trimmed_after_domain_validation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1} = quod_signing_journal:record_vote(
                       J0, support, 6, hash(1)),
          ok = quod_signing_journal:close(J1),
          Path = journal_path(Ns, Dir),
          {ok, Complete} = file:read_file(Path),
          Torn = <<?MAGIC:32, 100:32, 0:32, "short">>,
          ok = file:write_file(Path, Torn, [append]),
          {ok, J2} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual({ok, Complete}, file:read_file(Path)),
          {ok, J3} = quod_signing_journal:record_vote(
                       J2, complaint, 7, none),
          ok = quod_signing_journal:close(J3),
          {ok, J4} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(#{6 => #{support => hash(1), final => none},
                         7 => #{support => none, final => complaint}},
                       quod_signing_journal:rounds(J4)),
          ok = quod_signing_journal:close(J4)
      end).

domain_mismatch_precedes_torn_tail_repair_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          ok = quod_signing_journal:close(J0),
          Path = journal_path(Ns, Dir),
          Torn = <<?MAGIC:32, 100:32, 0:32, "short">>,
          ok = file:write_file(Path, Torn, [append]),
          {ok, Before} = file:read_file(Path),
          Domain1 = domain(1),
          Domain2 = domain(2),
          ?assertError(
             {signing_journal_domain_mismatch, Domain1, Domain2},
             quod_signing_journal:recover(Ns, Domain2, Dir)),
          ?assertEqual({ok, Before}, file:read_file(Path))
      end).

complete_crc_corruption_fails_without_mutation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1} = quod_signing_journal:record_vote(
                       J0, support, 6, hash(1)),
          ok = quod_signing_journal:close(J1),
          Path = journal_path(Ns, Dir),
          {ok, Bytes0} = file:read_file(Path),
          HeaderBytes = first_frame_bytes(Bytes0),
          PayloadOffset = HeaderBytes + ?HDR_BYTES,
          <<Prefix:PayloadOffset/binary, Byte, Rest/binary>> = Bytes0,
          Bytes = <<Prefix/binary, (Byte bxor 1), Rest/binary>>,
          ok = file:write_file(Path, Bytes),
          ?assertError(
             {signing_journal_corruption, bad_crc, HeaderBytes},
             quod_signing_journal:recover(Ns, domain(1), Dir)),
          ?assertEqual({ok, Bytes}, file:read_file(Path))
      end).

reconcile_uses_only_the_validated_summary_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1} = quod_signing_journal:record_vote(
                       J0, support, 5, hash(5)),
          {ok, J2} = quod_signing_journal:record_vote(
                       J1, complaint, 6, none),
          {Signer1, Admission1, Control1} = finalize_control(11, 4),
          Lane1 = {Admission1, maps:get(pubkey, Signer1)},
          {ok, J3, _} = quod_signing_journal:record_dtx(J2, Control1),
          {Signer2, Admission2, Control2} = finalize_control(12, 9),
          Lane2 = {Admission2, maps:get(pubkey, Signer2)},
          {ok, J4, _} = quod_signing_journal:record_dtx(J3, Control2),
          {ok, J5} = quod_signing_journal:reconcile(
                       J4, summary(5, #{Lane2 => 7}, none)),
          ?assertEqual(#{6 => #{support => none, final => complaint}},
                       quod_signing_journal:rounds(J5)),
          ?assertEqual(0, quod_signing_journal:dtx_floor(J5, Lane1)),
          ?assertEqual(9, quod_signing_journal:dtx_floor(J5, Lane2)),
          ?assertError(
             invalid_signing_journal_reconciliation,
             quod_signing_journal:reconcile(
               J5, summary(999, #{malformed => 0}, none))),
          ok = quod_signing_journal:close(J5)
      end).

dtx_floors_are_scoped_by_author_admission_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {Signer, Admission1, Control1} = finalize_control(21, 5),
          Meta = quod_dtx:control_metadata(Control1),
          Target = maps:get(target, Meta),
          Record = quod_dtx:control_body(Control1),
          Admission2 = hash(7021),
          {ok, Control2} = quod_dtx:sign_control(
                             Target, Record, Admission2, 1, 0, Signer),
          Author = maps:get(pubkey, Signer),
          Lane1 = {Admission1, Author},
          Lane2 = {Admission2, Author},
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1, _} = quod_signing_journal:record_dtx(J0, Control1),
          {ok, J2, _} = quod_signing_journal:record_dtx(J1, Control2),
          {ok, J3} = quod_signing_journal:reconcile(
                       J2, summary(0, #{Lane1 => 9, Lane2 => 0}, none)),
          ?assertEqual(9, quod_signing_journal:dtx_floor(J3, Lane1)),
          ?assertEqual(1, quod_signing_journal:dtx_floor(J3, Lane2)),
          {ok, Control3} = quod_dtx:sign_control(
                             Target, Record, Admission1, 10, 0, Signer),
          {ok, J4, _} = quod_signing_journal:record_dtx(J3, Control3),
          ok = quod_signing_journal:close(J4),
          {ok, J5} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(10, quod_signing_journal:dtx_floor(J5, Lane1)),
          ?assertEqual(1, quod_signing_journal:dtx_floor(J5, Lane2)),
          ok = quod_signing_journal:close(J5)
      end).

invalid_dtx_control_cannot_mutate_the_journal_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {_Signer, Admission, Control} = finalize_control(22, 1),
          Author = maps:get(author, quod_dtx:control_metadata(Control)),
          Tampered = setelement(10, Control, <<0:512>>),
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          Path = journal_path(Ns, Dir),
          {ok, Before} = file:read_file(Path),
          ?assertError(
             {invalid_dtx_control, bad_control},
             quod_signing_journal:record_dtx(J0, Tampered)),
          ?assertEqual(0, quod_signing_journal:dtx_floor(
                            J0, {Admission, Author})),
          ?assertEqual({ok, Before}, file:read_file(Path)),
          ok = quod_signing_journal:close(J0)
      end).

pending_begin_is_one_durable_frame_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Ctx = begin_context(1),
          #{control := Control} = Fixture = begin_control(Ctx, 1, 1),
          #{lane := Lane, sequence := Sequence, group_id := GroupId,
            body := Body, envelope := Envelope} = pending_fixture(Fixture),
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          Path = journal_path(Ns, Dir),
          {ok, Header} = file:read_file(Path),
          {ok, J1, Envelope} = quod_signing_journal:record_dtx(J0, Control),
          {ok, Bytes} = file:read_file(Path),
          %% The allocation floor and the exact recoverable Begin are one
          %% synced append, not two independently crashable records.
          ?assertEqual(1, frame_count(Header)),
          ?assertEqual(2, frame_count(Bytes)),
          ?assertEqual(Sequence, quod_signing_journal:dtx_floor(J1, Lane)),
          ?assertEqual(
             #{lane => Lane, sequence => Sequence, group_id => GroupId,
               body => Body, envelope => Envelope},
             quod_signing_journal:pending_begin(J1)),
          ok = quod_signing_journal:close(J1),

          {ok, J2} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(Sequence, quod_signing_journal:dtx_floor(J2, Lane)),
          ?assertEqual(
             #{lane => Lane, sequence => Sequence, group_id => GroupId,
               body => Body, envelope => Envelope},
             quod_signing_journal:pending_begin(J2)),
          ok = quod_signing_journal:close(J2)
      end).

pending_compaction_preserves_a_later_same_lane_floor_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Ctx = begin_context(5),
          #{control := Begin} = Fixture = begin_control(Ctx, 1, 1),
          ExpectedPending = pending_fixture(Fixture),
          #{lane := Lane} = ExpectedPending,
          Later = same_lane_finalize(Ctx, 5),
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1, _} = quod_signing_journal:record_dtx(J0, Begin),
          {ok, J2, _} = quod_signing_journal:record_dtx(J1, Later),
          ?assertEqual(5, quod_signing_journal:dtx_floor(J2, Lane)),
          ?assertEqual(ExpectedPending,
                       quod_signing_journal:pending_begin(J2)),
          J3 = quod_signing_journal:compact(J2),
          Path = journal_path(Ns, Dir),
          {ok, Compacted} = file:read_file(Path),
          ?assertEqual(3, frame_count(Compacted)),
          ok = quod_signing_journal:close(J3),

          {ok, J4} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(5, quod_signing_journal:dtx_floor(J4, Lane)),
          ?assertEqual(ExpectedPending,
                       quod_signing_journal:pending_begin(J4)),
          ok = quod_signing_journal:close(J4)
      end).

pending_begin_allows_only_same_body_reenveloping_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Ctx = begin_context(2),
          #{record := Record, control := Control1} =
              Fixture1 = begin_control(Ctx, 1, 1),
          #{lane := Lane, group_id := Group1, envelope := Envelope1} =
              pending_fixture(Fixture1),
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1, Envelope1} =
              quod_signing_journal:record_dtx(J0, Control1),
          Path = journal_path(Ns, Dir),
          Size1 = filelib:file_size(Path),

          %% An exact retry is idempotent and does not append another frame.
          {ok, J2, Envelope1} =
              quod_signing_journal:record_dtx(J1, Control1),
          ?assertEqual(Size1, filelib:file_size(Path)),

          Control2 = sign_begin(Ctx, Record, 2),
          {ok, J3, Envelope2} =
              quod_signing_journal:record_dtx(J2, Control2),
          ?assertNotEqual(Envelope1, Envelope2),
          ?assertEqual(2, quod_signing_journal:dtx_floor(J3, Lane)),
          ?assertMatch(#{lane := Lane, sequence := 2,
                         group_id := Group1, envelope := Envelope2},
                       quod_signing_journal:pending_begin(J3)),

          %% A higher validated committed floor makes that exact envelope
          %% stale; only the same body at a new higher sequence may replace it.
          {ok, J4} = quod_signing_journal:reconcile(
                       J3, summary(0, #{Lane => 5}, {Group1, Lane})),
          ?assertEqual(5, quod_signing_journal:dtx_floor(J4, Lane)),
          ?assertError(
             {pending_begin_conflict,
              #{pending := {Group1, Lane, 2},
                requested := {Group1, Lane, 2}, floor := 5}},
             quod_signing_journal:record_dtx(J4, Control2)),
          Control6 = sign_begin(Ctx, Record, 6),
          {ok, J5, _Envelope6} =
              quod_signing_journal:record_dtx(J4, Control6),

          #{control := OtherControl} = Other = begin_control(Ctx, 2, 7),
          #{group_id := Group2} = pending_fixture(Other),
          ?assertError(
             {pending_begin_conflict,
              #{pending := {Group1, Lane, 6},
                requested := {Group2, Lane, 7}, floor := 6}},
             quod_signing_journal:record_dtx(J5, OtherControl)),
          ok = quod_signing_journal:close(J5)
      end).

scanner_rejects_a_conflicting_pending_begin_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Ctx = begin_context(3),
          #{control := Control1} = begin_control(Ctx, 1, 1),
          Fixture2 = begin_control(Ctx, 2, 2),
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1, _} = quod_signing_journal:record_dtx(J0, Control1),
          ok = quod_signing_journal:close(J1),
          Path = journal_path(Ns, Dir),
          Offset = filelib:file_size(Path),
          PendingTerm = pending_term(Fixture2),
          Payload = term_to_binary(PendingTerm, [deterministic]),
          Frame = quod_signing_journal:test_frame(Payload),
          ok = file:write_file(Path, Frame, [append]),
          {ok, Before} = file:read_file(Path),
          ?assertError(
             {signing_journal_pending_conflict, Offset},
             quod_signing_journal:recover(Ns, domain(1), Dir)),
          ?assertEqual({ok, Before}, file:read_file(Path))
      end).

reconcile_retires_pending_before_accepting_another_group_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Ctx = begin_context(4),
          #{control := Control1} = Fixture1 = begin_control(Ctx, 1, 1),
          #{lane := Lane} = pending_fixture(Fixture1),
          #{control := Control2} = Fixture2 = begin_control(Ctx, 2, 2),
          Expected2 = pending_fixture(Fixture2),
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1, _} = quod_signing_journal:record_dtx(J0, Control1),
          {ok, J2} = quod_signing_journal:reconcile(
                       J1, summary(0, #{Lane => 1}, none)),
          ?assertEqual(none, quod_signing_journal:pending_begin(J2)),
          ?assertEqual(1, quod_signing_journal:dtx_floor(J2, Lane)),
          {ok, J3, _} = quod_signing_journal:record_dtx(J2, Control2),
          ?assertEqual(Expected2, quod_signing_journal:pending_begin(J3)),
          ok = quod_signing_journal:close(J3),

          {ok, J4} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(Expected2, quod_signing_journal:pending_begin(J4)),
          ok = quod_signing_journal:close(J4)
      end).

effect_custody_is_durable_idempotent_and_admission_scoped_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {Pub, Seed} = quod_identity:generate(),
          Signer = #{pubkey => Pub,
                     key => quod_identity:key_term({Pub, Seed})},
          Anchor = hash(8101),
          Admission1 = hash(8102),
          Admission2 = hash(8103),
          Base = effect_transaction(Ns, Anchor, Pub),
          {T1, Submission1} = signed_effect(
                                Ns, Anchor, Admission1, 1, Base, Signer),
          TxId = T1#transaction.tx_id,
          {ok, J0} = quod_signing_journal:initialize(
                       Ns, domain(1), Dir),
          {ok, J1} = quod_signing_journal:record_effect(
                       J0, T1, Submission1),
          Path = journal_path(Ns, Dir),
          Size1 = filelib:file_size(Path),
          ?assertMatch(
             #{TxId := #{admission := Admission1, sequence := 1}},
             quod_signing_journal:pending_effects(J1)),

          %% Exact custody retry is a read: no duplicate durable frame.
          {ok, J2} = quod_signing_journal:record_effect(
                       J1, T1, Submission1),
          ?assertEqual(Size1, filelib:file_size(Path)),

          %% Effect custody is globally ordered by author sequence. Only the
          %% exact persisted envelope is an idempotent retry; even a
          %% same-admission re-sign is an anti-equivocation conflict.
          {T2, Submission2} = signed_effect(
                                Ns, Anchor, Admission1, 2, Base, Signer),
          ?assertError(
             {effect_signing_conflict, TxId},
             quod_signing_journal:record_effect(J2, T2, Submission2)),
          {T3, Submission3} = signed_effect(
                                Ns, Anchor, Admission2, 3, Base, Signer),
          {ok, BeforeConflict} = file:read_file(Path),
          ?assertError(
             {effect_signing_conflict, TxId},
             quod_signing_journal:record_effect(J2, T3, Submission3)),
          ?assertEqual({ok, BeforeConflict}, file:read_file(Path)),
          ok = quod_signing_journal:close(J2),

          {ok, J4} = quod_signing_journal:recover(
                       Ns, domain(1), Dir),
          ?assertMatch(
             #{TxId := #{admission := Admission1, sequence := 1}},
             quod_signing_journal:pending_effects(J4)),
          {ok, J5} = quod_signing_journal:retire_effect(J4, TxId),
          ?assertEqual(#{}, quod_signing_journal:pending_effects(J5)),
          ok = quod_signing_journal:close(J5),
          {ok, J6} = quod_signing_journal:recover(
                       Ns, domain(1), Dir),
          ?assertEqual(#{}, quod_signing_journal:pending_effects(J6)),
          ok = quod_signing_journal:close(J6)
      end).

compressed_record_is_rejected_without_mutation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          ok = quod_signing_journal:close(J0),
          Path = journal_path(Ns, Dir),
          Offset = filelib:file_size(Path),
          Payload = term_to_binary(lists:duplicate(1000, support),
                                   [compressed]),
          ?assertMatch(<<131, 80, _/binary>>, Payload),
          Frame = quod_signing_journal:test_frame(Payload),
          ok = file:write_file(Path, Frame, [append]),
          {ok, Before} = file:read_file(Path),
          ?assertError(
             {signing_journal_bad_record, compressed, Offset},
             quod_signing_journal:recover(Ns, domain(1), Dir)),
          ?assertEqual({ok, Before}, file:read_file(Path))
      end).

unknown_atom_record_is_rejected_without_atom_creation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          ok = quod_signing_journal:close(J0),
          Path = journal_path(Ns, Dir),
          Offset = filelib:file_size(Path),
          Canonical = term_to_binary(
                        {quod_signing_vote, 1, support, 8, hash(8)},
                        [deterministic]),
          Unknown = binary:replace(Canonical, <<"support">>, <<"qzxqvjk">>),
          ?assertNotEqual(Canonical, Unknown),
          Frame = quod_signing_journal:test_frame(Unknown),
          ok = file:write_file(Path, Frame, [append]),
          Atoms = erlang:system_info(atom_count),
          ?assertError(
             {signing_journal_bad_record, bad_term, Offset},
             quod_signing_journal:recover(Ns, domain(1), Dir)),
          ?assertEqual(Atoms, erlang:system_info(atom_count))
      end).

frame_bound_tracks_shared_dtx_limits_exactly_test() ->
    Fixed = <<0:256>>,
    Body = binary:copy(<<0>>, ?QUOD_MAX_DTX_BODY_BYTES),
    Envelope = binary:copy(<<0>>, ?QUOD_MAX_DTX_CONTROL_BYTES),
    AtLimit = term_to_binary(
                {quod_signing_pending_begin, 1, Fixed, Fixed,
                 16#FFFFFFFFFFFFFFFF, Fixed, Body, Envelope},
                [deterministic]),
    ?assertEqual(quod_signing_journal:test_max_frame_payload_bytes(),
                 byte_size(AtLimit)),
    Frame = quod_signing_journal:test_frame(AtLimit),
    ?assertEqual(byte_size(AtLimit) + ?HDR_BYTES, byte_size(Frame)),
    Over = term_to_binary(
             {quod_signing_pending_begin, 1, Fixed, Fixed,
              16#FFFFFFFFFFFFFFFF, Fixed, Body,
             <<Envelope/binary, 0>>},
             [deterministic]),
    OverSize = byte_size(Over),
    ?assertError(
       {signing_journal_frame_too_big, OverSize},
       quod_signing_journal:test_frame(Over)).

%% ------------------------------------------------------------------
%% helpers
%% ------------------------------------------------------------------

with_dir(Fun) ->
    Ns = <<"journal:test">>,
    Name = lists:concat(
             ["quod_signing_journal_",
              integer_to_list(erlang:unique_integer([positive]))]),
    Dir = filename:join("/tmp", Name),
    try Fun(Ns, Dir)
    after
        _ = file:del_dir_r(Dir)
    end.

summary(Slot, Live, Pending) ->
    #{committed_slot => Slot, live_dtx_lanes => Live, pending => Pending}.

finalize_control(N, Sequence) ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Admission = hash(1000 + N),
    Ns = <<"journal:target">>,
    Anchor = hash(2000 + N),
    Target = {Ns, Anchor},
    GroupId = hash(3000 + N),
    {ok, DecisionRef} = quod_dtx:certified_ref(
                          Ns, Anchor, 1, hash(4000 + N), hash(5000 + N),
                          <<"finality">>),
    {ok, Record} = quod_dtx:new_finalize(
                     GroupId, DecisionRef, abort, none, 0),
    {ok, Control} = quod_dtx:sign_control(
                      Target, Record, Admission, Sequence, 0, Signer),
    {Signer, Admission, Control}.

begin_context(N) ->
    {Pub, Seed} = quod_identity:generate(),
    #{signer => #{pubkey => Pub,
                  key => quod_identity:key_term({Pub, Seed})},
      admission => hash(6000 + N),
      origin => {<<"journal:origin">>, hash(6100 + N)}}.

begin_control(Ctx, Variant, Sequence) ->
    #{origin := {OriginNs, OriginAnchor} = Origin,
      admission := Admission,
      signer := #{pubkey := Author} = CoordinatorSigner} = Ctx,
    ProofId = hash(6200 + Variant),
    {Target1, Plan1, Signer1} =
        signed_plan(Variant, 1, Origin, ProofId),
    {Target2, Plan2, Signer2} =
        signed_plan(Variant, 2, Origin, ProofId),
    Participants = [{Target1, quod_dtx:digest(Plan1)},
                    {Target2, quod_dtx:digest(Plan2)}],
    {ok, Goal} = quod_durable_term:encode_goal(true),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    {ok, Manifest} = quod_dtx:new_manifest(
                       #{proof_id => ProofId,
                         coordinator =>
                             {OriginNs, OriginAnchor, Author, Admission},
                         nonce => hash(6300 + Variant),
                         principal => anonymous,
                         goal => Goal,
                         result => Result,
                         participants => Participants}),
    Bundle1 = bundle(Target1, Plan1, Manifest, Signer1),
    Bundle2 = bundle(Target2, Plan2, Manifest, Signer2),
    {ok, Record} = quod_dtx:new_begin(Manifest, [Bundle1, Bundle2]),
    Control = sign_begin(Ctx, Record, Sequence),
    #{control => Control, record => Record,
      coordinator_signer => CoordinatorSigner}.

signed_plan(Variant, Participant, Origin, ProofId) ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub,
               key => quod_identity:key_term({Pub, Seed})},
    Ns = iolist_to_binary(
           [<<"journal:participant:">>, integer_to_binary(Participant)]),
    Target = {Ns, hash(6400 + Variant * 10 + Participant)},
    Session = quod_proof_session:start(
                quod_ct:committed_kb([]),
                #{read_set => true, proof_context => {origin, test},
                  signer => Signer}),
    InvocationId = <<Variant:64, Participant:64>>,
    Goal = {assertz, {journal_fact, Variant, Participant}},
    Context = quod_predicates:proof_context(
                Ns, 1, undefined, [Target]),
    try
        ok = quod_proof_session:open(
               Session, InvocationId, Goal, allowed, Context,
               quod_transaction_scope:empty_selection()),
        {solution, _} = quod_proof_session:next(Session, InvocationId),
        {ok, Plan} = quod_dtx:seal_session(
                       Session,
                       #{target => Target, base_height => 1,
                         proof_id => ProofId, origin => Origin,
                         principal => anonymous}),
        {Target, Plan, Signer}
    after
        quod_proof_session:stop(Session)
    end.

bundle(Target, Plan, Manifest, Signer) ->
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    {ok, Attestation} = quod_dtx:attest_plan(
                          Target, Plan, Manifest, Signer),
    {Target, quod_dtx:digest(Plan), PlanBlob, Attestation}.

sign_begin(#{origin := Origin, admission := Admission,
             signer := Signer}, Record, Sequence) ->
    {ok, Control} = quod_dtx:sign_control(
                      Origin, Record, Admission, Sequence, 0, Signer),
    Control.

same_lane_finalize(#{origin := {Ns, Anchor} = Target,
                     admission := Admission, signer := Signer}, Sequence) ->
    {ok, DecisionRef} = quod_dtx:certified_ref(
                          Ns, Anchor, 1, hash(7100), hash(7101), <<"qc">>),
    {ok, Record} = quod_dtx:new_finalize(
                     hash(7102), DecisionRef, abort, none, 0),
    {ok, Control} = quod_dtx:sign_control(
                      Target, Record, Admission, Sequence, 0, Signer),
    Control.

effect_transaction(Ns, Anchor, Author) ->
    {ok, Goal} = quod_durable_term:encode_goal(
                   {create_ontology, <<"journal:created">>, []}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Effect = {quod_direct_effect, 1, local_durable,
              ontology_lifecycle, create, hash(8201), Author,
              {user, hash(8202)}, {<<"journal:created">>, hash(8203)},
              hash(8204), hash(8205)},
    quod_transaction:bind_id(
      {Ns, Anchor},
      #transaction{origin = {Ns, Anchor}, proof_id = hash(8206),
                   plan_digest = hash(8207), goal = Goal, result = Result,
                   diff = [], read_check = #{}, effects = [Effect],
                   author = Author, author_seq = 1,
                   submitted_at = 1234, sig = none}).

signed_effect(Ns, Anchor, Admission, Sequence, Base, Signer) ->
    Unsigned = Base#transaction{author_seq = Sequence, sig = none},
    {ok, Signed, Submission} = quod_transaction:sign_submission(
                                 {Ns, Anchor, Admission}, Unsigned, Signer),
    {Signed, Submission}.

pending_fixture(#{control := Control}) ->
    Meta = quod_dtx:control_metadata(Control),
    #{lane => {maps:get(author_admission, Meta), maps:get(author, Meta)},
      sequence => maps:get(sequence, Meta),
      group_id => quod_dtx:group_id(Control),
      body => maps:get(body_blob, Meta),
      envelope => element(2, quod_dtx:encode_control(Control))}.

pending_term(Fixture) ->
    #{lane := {Admission, Author}, sequence := Sequence,
      group_id := GroupId, body := Body, envelope := Envelope} =
        pending_fixture(Fixture),
    {quod_signing_pending_begin, 1, Admission, Author, Sequence,
     GroupId, Body, Envelope}.

frame_count(Bytes) -> frame_count(Bytes, 0).

frame_count(<<>>, Count) -> Count;
frame_count(<<?MAGIC:32, Len:32, _CRC:32, _Payload:Len/binary, Rest/binary>>,
            Count) ->
    frame_count(Rest, Count + 1).

domain(N) -> hash(9000 + N).
hash(N) -> crypto:hash(sha256, <<N:64>>).

journal_path(Ns, Dir) ->
    filename:join(quod_ledger_store:ns_dir(Dir, Ns), "signing.0001").

first_frame_bytes(<<?MAGIC:32, Len:32, _CRC:32, _/binary>>) ->
    ?HDR_BYTES + Len.
