-module(quod_signing_journal_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-define(MAGIC, 16#51534A34). %% "QSJ4"
-define(HDR_BYTES, 12).

persists_votes_and_dtx_floor_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          Block = supported_block(6, 1),
          H1 = quod_simplex:block_hash(Block),
          H2 = hash(2),
          {ok, J1} = quod_signing_journal:record_support(J0, Block),
          SizeAfterSupport = filelib:file_size(journal_path(Ns, Dir)),
          {ok, J1} = quod_signing_journal:record_support(J1, Block),
          ?assertEqual(SizeAfterSupport,
                       filelib:file_size(journal_path(Ns, Dir))),
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
          ?assertEqual(#{6 => Block},
                       quod_signing_journal:supported_blocks(J3)),
          ?assertEqual(7, quod_signing_journal:dtx_floor(J3, Lane)),
          ?assertEqual(#{}, quod_signing_journal:pending_begins(J3)),
          J4 = quod_signing_journal:compact(J3),
          ok = quod_signing_journal:close(J4),
          {ok, J5} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(#{6 => Block},
                       quod_signing_journal:supported_blocks(J5)),
          ok = quod_signing_journal:close(J5)
      end).

malformed_supported_block_is_rejected_without_mutation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          ok = quod_signing_journal:close(J0),
          Path = journal_path(Ns, Dir),
          Offset = filelib:file_size(Path),
          Block = supported_block(6, 1),
          Bytes = quod_ledger:block_bytes(Block),
          Payload = term_to_binary(
                      {quod_signing_support, 4, 7, Bytes},
                      [deterministic]),
          ok = file:write_file(
                 Path, quod_signing_journal:test_frame(Payload), [append]),
          {ok, Before} = file:read_file(Path),
          ?assertError(
             {signing_journal_bad_supported_block, Offset},
             quod_signing_journal:recover(Ns, domain(1), Dir)),
          ?assertEqual({ok, Before}, file:read_file(Path))
      end).

conflicting_votes_fail_stop_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          Block1 = supported_block(6, 1),
          Block2 = supported_block(6, 2),
          H1 = quod_simplex:block_hash(Block1),
          H2 = quod_simplex:block_hash(Block2),
          {ok, J1} = quod_signing_journal:record_support(J0, Block1),
          ?assertError(
             {vote_conflict, 6, {support, H1}, {support, H2}},
             quod_signing_journal:record_support(J1, Block2)),
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
          {ok, J2} = quod_signing_journal:record_support(
                       J1, supported_block(1, 1)),
          %% Reconcile removes the only live latch.  Compaction must still
          %% retain the sticky evidence that a signature once existed.
          {ok, J3} = quod_signing_journal:reconcile(
                       J2, summary(1, #{}, #{})),
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

superseded_signing_magic_fails_explicitly_without_mutation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Path = journal_path(Ns, Dir),
          ok = filelib:ensure_dir(Path),
          lists:foreach(
            fun({Version, Magic}) ->
                Bytes = <<Magic:32>>,
                ok = file:write_file(Path, Bytes),
                ?assertError(
                   {unsupported_signing_journal_format, Version, 0},
                   quod_signing_journal:recover(Ns, domain(1), Dir)),
                ?assertEqual({ok, Bytes}, file:read_file(Path))
            end,
            [{1, 16#51534A31}, {2, 16#51534A32}, {3, 16#51534A33}])
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

superseded_signing_magic_in_tail_is_not_trimmed_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          ok = quod_signing_journal:close(J0),
          Path = journal_path(Ns, Dir),
          {ok, Header} = file:read_file(Path),
          Legacy = <<16#51534A31:32>>,
          ok = file:write_file(Path, Legacy, [append]),
          Bytes = <<Header/binary, Legacy/binary>>,
          HeaderSize = byte_size(Header),
          ?assertError(
             {unsupported_signing_journal_format, 1, HeaderSize},
             quod_signing_journal:recover(Ns, domain(1), Dir)),
          ?assertEqual({ok, Bytes}, file:read_file(Path))
      end).

torn_final_frame_is_trimmed_after_domain_validation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          Block = supported_block(6, 1),
          {ok, J1} = quod_signing_journal:record_support(J0, Block),
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
          ?assertEqual(#{6 => #{support => quod_simplex:block_hash(Block),
                                final => none},
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
          {ok, J1} = quod_signing_journal:record_support(
                       J0, supported_block(6, 1)),
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
          {ok, J1} = quod_signing_journal:record_support(
                       J0, supported_block(5, 5)),
          {ok, J2} = quod_signing_journal:record_vote(
                       J1, complaint, 6, none),
          {Signer1, Admission1, Control1} = finalize_control(11, 4),
          Lane1 = {Admission1, maps:get(pubkey, Signer1)},
          {ok, J3, _} = quod_signing_journal:record_dtx(J2, Control1),
          {Signer2, Admission2, Control2} = finalize_control(12, 9),
          Lane2 = {Admission2, maps:get(pubkey, Signer2)},
          {ok, J4, _} = quod_signing_journal:record_dtx(J3, Control2),
          {ok, J5} = quod_signing_journal:reconcile(
                       J4, summary(5, #{Lane2 => 7}, #{})),
          ?assertEqual(#{6 => #{support => none, final => complaint}},
                       quod_signing_journal:rounds(J5)),
          ?assertEqual(#{}, quod_signing_journal:supported_blocks(J5)),
          ?assertEqual(0, quod_signing_journal:dtx_floor(J5, Lane1)),
          ?assertEqual(9, quod_signing_journal:dtx_floor(J5, Lane2)),
          ?assertError(
             invalid_signing_journal_reconciliation,
             quod_signing_journal:reconcile(
               J5, summary(999, #{malformed => 0}, #{}))),
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
                       J2, summary(0, #{Lane1 => 9, Lane2 => 0}, #{})),
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

uncommitted_dtx_floor_survives_unrelated_reconciliation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {Signer, Admission, Control} = finalize_control(23, 1),
          Author = maps:get(pubkey, Signer),
          Lane = {Admission, Author},
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1, _} = quod_signing_journal:record_dtx(J0, Control),

          %% A different committed entry may reconcile the journal before the
          %% retained DTX control certifies.  Membership still owns this lane,
          %% so its durable allocation must remain the next-sequence floor.
          {ok, J2} = quod_signing_journal:reconcile(
                       J1, summary(
                             1, #{}, #{Author => Admission}, #{})),
          ?assertEqual(1, quod_signing_journal:dtx_floor(J2, Lane)),
          ?assertError(
             {dtx_sequence_conflict, Lane, 1, 1},
             quod_signing_journal:record_dtx(J2, Control)),
          Meta = quod_dtx:control_metadata(Control),
          {ok, Control2} = quod_dtx:sign_control(
                             maps:get(target, Meta),
                             quod_dtx:control_body(Control),
                             Admission, 2, 0, Signer),
          {ok, J3, _} = quod_signing_journal:record_dtx(J2, Control2),
          ?assertEqual(2, quod_signing_journal:dtx_floor(J3, Lane)),
          ok = quod_signing_journal:close(J3),

          {ok, J4} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(2, quod_signing_journal:dtx_floor(J4, Lane)),
          ok = quod_signing_journal:close(J4)
      end).

uncommitted_dtx_floor_is_pruned_by_admission_rotation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {Signer, Admission1, Control} = finalize_control(24, 1),
          Author = maps:get(pubkey, Signer),
          Lane1 = {Admission1, Author},
          Admission2 = hash(7024),
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1, _} = quod_signing_journal:record_dtx(J0, Control),
          {ok, J2} = quod_signing_journal:reconcile(
                       J1, summary(
                             1, #{}, #{Author => Admission2}, #{})),
          ?assertEqual(0, quod_signing_journal:dtx_floor(J2, Lane1)),
          ok = quod_signing_journal:close(J2)
      end).

committed_dtx_floor_survives_without_local_record_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {Signer, Admission, _Control} = finalize_control(25, 1),
          Author = maps:get(pubkey, Signer),
          Lane = {Admission, Author},
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1} = quod_signing_journal:reconcile(
                       J0, summary(
                             1, #{Lane => 5},
                             #{Author => Admission}, #{})),
          ?assertEqual(5, quod_signing_journal:dtx_floor(J1, Lane)),
          ok = quod_signing_journal:close(J1)
      end).

committed_dtx_floor_wins_over_lower_local_floor_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {Signer, Admission, Control} = finalize_control(26, 1),
          Author = maps:get(pubkey, Signer),
          Lane = {Admission, Author},
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1, _} = quod_signing_journal:record_dtx(J0, Control),
          {ok, J2} = quod_signing_journal:reconcile(
                       J1, summary(
                             1, #{Lane => 5},
                             #{Author => Admission}, #{})),
          ?assertEqual(5, quod_signing_journal:dtx_floor(J2, Lane)),
          ok = quod_signing_journal:close(J2)
      end).

malformed_current_admissions_rejects_reconciliation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          ?assertError(
             invalid_signing_journal_reconciliation,
             quod_signing_journal:reconcile(
               J0, summary(0, #{}, #{hash(1) => malformed}, #{}))),
          ?assertError(
             invalid_signing_journal_reconciliation,
             quod_signing_journal:reconcile(
               J0, #{committed_slot => 0, live_dtx_lanes => #{},
                     pending_begins => #{}})),
          ok = quod_signing_journal:close(J0)
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

each_pending_begin_is_one_durable_frame_test() ->
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
             #{GroupId =>
                   #{lane => Lane, sequence => Sequence,
                     body => Body, envelope => Envelope}},
             quod_signing_journal:pending_begins(J1)),
          ok = quod_signing_journal:close(J1),

          {ok, J2} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(Sequence, quod_signing_journal:dtx_floor(J2, Lane)),
          ?assertEqual(
             #{GroupId =>
                   #{lane => Lane, sequence => Sequence,
                     body => Body, envelope => Envelope}},
             quod_signing_journal:pending_begins(J2)),
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
          ?assertEqual(pending_map(ExpectedPending),
                       quod_signing_journal:pending_begins(J2)),
          J3 = quod_signing_journal:compact(J2),
          Path = journal_path(Ns, Dir),
          {ok, Compacted} = file:read_file(Path),
          ?assertEqual(3, frame_count(Compacted)),
          ok = quod_signing_journal:close(J3),

          {ok, J4} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(5, quod_signing_journal:dtx_floor(J4, Lane)),
          ?assertEqual(pending_map(ExpectedPending),
                       quod_signing_journal:pending_begins(J4)),
          ok = quod_signing_journal:close(J4)
      end).

pending_begin_reenveloping_is_scoped_to_its_group_test() ->
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
          ?assertMatch(#{Group1 := #{lane := Lane, sequence := 2,
                                    envelope := Envelope2}},
                       quod_signing_journal:pending_begins(J3)),

          %% A higher validated committed floor does not make already exposed
          %% bytes equivocate. The exact envelope stays idempotent; only a new
          %% envelope must allocate above the current floor.
          {ok, J4} = quod_signing_journal:reconcile(
                       J3, summary(0, #{Lane => 5}, #{Group1 => Lane})),
          ?assertEqual(5, quod_signing_journal:dtx_floor(J4, Lane)),
          Size4 = filelib:file_size(Path),
          {ok, J4a, Envelope2} =
              quod_signing_journal:record_dtx(J4, Control2),
          ?assertEqual(Size4, filelib:file_size(Path)),
          Control6 = sign_begin(Ctx, Record, 6),
          {ok, J5, Envelope6} =
              quod_signing_journal:record_dtx(J4a, Control6),

          #{control := OtherControl} = Other = begin_control(Ctx, 2, 7),
          #{group_id := Group2} = pending_fixture(Other),
          {ok, J6, _} = quod_signing_journal:record_dtx(J5, OtherControl),
          ?assertMatch(
             #{Group1 := #{lane := Lane, sequence := 6},
               Group2 := #{lane := Lane, sequence := 7}},
             quod_signing_journal:pending_begins(J6)),

          %% Exact bytes from the older group remain idempotently retrievable
          %% after another group advanced the same lane.
          BeforeRetry = filelib:file_size(Path),
          {ok, J7, Envelope6} =
              quod_signing_journal:record_dtx(J6, Control6),
          ?assertEqual(BeforeRetry, filelib:file_size(Path)),
          ok = quod_signing_journal:close(J7)
      end).

scanner_recovers_distinct_pending_groups_from_one_lane_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Ctx = begin_context(3),
          #{control := Control1} = Fixture1 = begin_control(Ctx, 1, 1),
          Fixture2 = begin_control(Ctx, 2, 2),
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1, _} = quod_signing_journal:record_dtx(J0, Control1),
          ok = quod_signing_journal:close(J1),
          Path = journal_path(Ns, Dir),
          PendingTerm = pending_term(Fixture2),
          Payload = term_to_binary(PendingTerm, [deterministic]),
          Frame = quod_signing_journal:test_frame(Payload),
          ok = file:write_file(Path, Frame, [append]),
          {ok, J2} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(
             maps:merge(pending_map(pending_fixture(Fixture1)),
                        pending_map(pending_fixture(Fixture2))),
             quod_signing_journal:pending_begins(J2)),
          ok = quod_signing_journal:close(J2)
      end).

reconcile_prunes_each_pending_group_independently_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Ctx = begin_context(4),
          #{control := Control1} = Fixture1 = begin_control(Ctx, 1, 1),
          #{lane := Lane} = pending_fixture(Fixture1),
          #{control := Control2} = Fixture2 = begin_control(Ctx, 2, 2),
          Expected2 = pending_fixture(Fixture2),
          #{group_id := Group1} = pending_fixture(Fixture1),
          #{group_id := Group2} = Expected2,
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {ok, J1, _} = quod_signing_journal:record_dtx(J0, Control1),
          {ok, J1a, _} = quod_signing_journal:record_dtx(J1, Control2),
          {ok, J2} = quod_signing_journal:reconcile(
                       J1a, summary(0, #{Lane => 2}, #{Group2 => Lane})),
          ?assertEqual(#{Group2 => pending_row(Expected2)},
                       quod_signing_journal:pending_begins(J2)),
          ?assertEqual(2, quod_signing_journal:dtx_floor(J2, Lane)),
          ?assertNot(maps:is_key(Group1,
                                 quod_signing_journal:pending_begins(J2))),
          ok = quod_signing_journal:close(J2),

          {ok, J3} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(#{Group2 => pending_row(Expected2)},
                       quod_signing_journal:pending_begins(J3)),
          ok = quod_signing_journal:close(J3)
      end).

pending_begin_population_has_no_compiled_count_limit_test() ->
    with_dir(
      fun(Ns, Dir) ->
          Ctx = begin_context(40),
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          {J1, Expected} = lists:foldl(
            fun(Variant, {Journal, Acc}) ->
                    Fixture = begin_control(Ctx, Variant, Variant),
                    #{control := Control} = Fixture,
                    #{group_id := GroupId} = Pending =
                        pending_fixture(Fixture),
                    {ok, Journal1, _} =
                        quod_signing_journal:record_dtx(Journal, Control),
                    {Journal1, Acc#{GroupId => pending_row(Pending)}}
            end, {J0, #{}}, lists:seq(1, 65)),
          ?assertEqual(65,
                       map_size(quod_signing_journal:pending_begins(J1))),
          ?assertEqual(Expected,
                       quod_signing_journal:pending_begins(J1)),
          [{_GroupId, #{lane := Lane}} | _] = maps:to_list(Expected),
          PendingRefs = maps:map(
                          fun(_Id, #{lane := PendingLane}) -> PendingLane end,
                          Expected),
          {ok, J1a} = quod_signing_journal:reconcile(
                        J1, summary(0, #{Lane => 65}, PendingRefs)),
          ?assertEqual(Expected,
                       quod_signing_journal:pending_begins(J1a)),
          J2 = quod_signing_journal:compact(J1a),
          ok = quod_signing_journal:close(J2),

          {ok, J3} = quod_signing_journal:recover(Ns, domain(1), Dir),
          ?assertEqual(Expected,
                       quod_signing_journal:pending_begins(J3)),
          ok = quod_signing_journal:close(J3)
      end).

compaction_orders_pending_groups_canonically_test() ->
    with_dir(
      fun(_Ns, Dir) ->
          Ns1 = <<"journal:canonical:one">>,
          Ns2 = <<"journal:canonical:two">>,
          Domain = domain(44),
          Fixture1 = begin_control(begin_context(41), 1, 1),
          Fixture2 = begin_control(begin_context(42), 2, 1),
          #{control := Control1} = Fixture1,
          #{control := Control2} = Fixture2,

          {ok, A0} = quod_signing_journal:initialize(Ns1, Domain, Dir),
          {ok, A1, _} = quod_signing_journal:record_dtx(A0, Control1),
          {ok, A2, _} = quod_signing_journal:record_dtx(A1, Control2),
          A3 = quod_signing_journal:compact(A2),
          ok = quod_signing_journal:close(A3),

          {ok, B0} = quod_signing_journal:initialize(Ns2, Domain, Dir),
          {ok, B1, _} = quod_signing_journal:record_dtx(B0, Control2),
          {ok, B2, _} = quod_signing_journal:record_dtx(B1, Control1),
          B3 = quod_signing_journal:compact(B2),
          ok = quod_signing_journal:close(B3),

          ?assertEqual(file:read_file(journal_path(Ns1, Dir)),
                       file:read_file(journal_path(Ns2, Dir)))
      end).

superseded_record_version_is_not_accepted_under_qsj2_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {ok, J0} = quod_signing_journal:initialize(Ns, domain(1), Dir),
          ok = quod_signing_journal:close(J0),
          Path = journal_path(Ns, Dir),
          Offset = filelib:file_size(Path),
          Hash = hash(1),
          Payload = term_to_binary(
                      {quod_signing_vote, 1, support, 1, Hash},
                      [deterministic]),
          ok = file:write_file(
                 Path, quod_signing_journal:test_frame(Payload), [append]),
          {ok, Before} = file:read_file(Path),
          ?assertError(
             {signing_journal_bad_record,
              {quod_signing_vote, 1, support, 1, Hash}, Offset},
             quod_signing_journal:recover(Ns, domain(1), Dir)),
          ?assertEqual({ok, Before}, file:read_file(Path))
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
          {ok, J1} = quod_signing_journal:record_transaction(
                       J0, T1, Submission1, ready),
          Path = journal_path(Ns, Dir),
          Size1 = filelib:file_size(Path),
          ?assertMatch(
             #{TxId := #{admission := Admission1, sequence := 1}},
             quod_signing_journal:pending_transactions(J1)),

          %% Exact custody retry is a read: no duplicate durable frame.
          {ok, J2} = quod_signing_journal:record_transaction(
                       J1, T1, Submission1, ready),
          ?assertEqual(Size1, filelib:file_size(Path)),

          %% Effect custody is globally ordered by author sequence. Only the
          %% exact persisted envelope is an idempotent retry; even a
          %% same-admission re-sign is an anti-equivocation conflict.
          {T2, Submission2} = signed_effect(
                                Ns, Anchor, Admission1, 2, Base, Signer),
          ?assertError(
             {transaction_signing_conflict, TxId},
             quod_signing_journal:record_transaction(
               J2, T2, Submission2, ready)),
          {T3, Submission3} = signed_effect(
                                Ns, Anchor, Admission2, 3, Base, Signer),
          {ok, BeforeConflict} = file:read_file(Path),
          ?assertError(
             {transaction_signing_conflict, TxId},
             quod_signing_journal:record_transaction(
               J2, T3, Submission3, ready)),
          ?assertEqual({ok, BeforeConflict}, file:read_file(Path)),
          ok = quod_signing_journal:close(J2),

          {ok, J4} = quod_signing_journal:recover(
                       Ns, domain(1), Dir),
          ?assertMatch(
             #{TxId := #{admission := Admission1, sequence := 1}},
             quod_signing_journal:pending_transactions(J4)),
          {ok, J5} = quod_signing_journal:retire_transaction(J4, TxId),
          ?assertEqual(#{}, quod_signing_journal:pending_transactions(J5)),
          ok = quod_signing_journal:close(J5),
          {ok, J6} = quod_signing_journal:recover(
                       Ns, domain(1), Dir),
          ?assertEqual(#{}, quod_signing_journal:pending_transactions(J6)),
          ok = quod_signing_journal:close(J6)
      end).

dormant_transaction_requires_durable_binding_before_activation_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {Pub, Seed} = quod_identity:generate(),
          Signer = #{pubkey => Pub,
                     key => quod_identity:key_term({Pub, Seed})},
          Anchor = hash(8251),
          Admission = hash(8252),
          Base = effect_transaction(Ns, Anchor, Pub),
          {Transaction, Submission} = signed_effect(
                                        Ns, Anchor, Admission, 1,
                                        Base, Signer),
          TxId = Transaction#transaction.tx_id,
          {ok, J0} = quod_signing_journal:initialize(
                       Ns, domain(1), Dir),
          {ok, J1} = quod_signing_journal:record_transaction(
                       J0, Transaction, Submission, dormant),
          Path = journal_path(Ns, Dir),
          SizeDormant = filelib:file_size(Path),

          %% Neither the activation API nor a repeated ready registration may
          %% bypass the fsynced target-prerequisite binding.
          ?assertError(
             {transaction_signing_not_bound, TxId},
             quod_signing_journal:activate_transaction(J1, TxId)),
          ?assertError(
             {transaction_signing_not_bound, TxId},
             quod_signing_journal:record_transaction(
               J1, Transaction, Submission, ready)),
          ?assertEqual(SizeDormant, filelib:file_size(Path)),
          ?assertMatch(
             #{TxId := #{state := dormant}},
             quod_signing_journal:pending_transactions(J1)),

          {ok, J2} = quod_signing_journal:bind_transaction(J1, TxId),
          ?assertMatch(
             #{TxId := #{state := bound}},
             quod_signing_journal:pending_transactions(J2)),
          {ok, J3} = quod_signing_journal:activate_transaction(J2, TxId),
          ?assertMatch(
             #{TxId := #{state := ready}},
             quod_signing_journal:pending_transactions(J3)),
          ok = quod_signing_journal:close(J3),

          {ok, J4} = quod_signing_journal:recover(
                       Ns, domain(1), Dir),
          ?assertMatch(
             #{TxId := #{state := ready}},
             quod_signing_journal:pending_transactions(J4)),
          ok = quod_signing_journal:close(J4)
      end).

dormant_transaction_activation_record_is_rejected_on_recovery_test() ->
    with_dir(
      fun(Ns, Dir) ->
          {Pub, Seed} = quod_identity:generate(),
          Signer = #{pubkey => Pub,
                     key => quod_identity:key_term({Pub, Seed})},
          Anchor = hash(8261),
          Admission = hash(8262),
          Base = effect_transaction(Ns, Anchor, Pub),
          {Transaction, Submission} = signed_effect(
                                        Ns, Anchor, Admission, 1,
                                        Base, Signer),
          TxId = Transaction#transaction.tx_id,
          {ok, J0} = quod_signing_journal:initialize(
                       Ns, domain(1), Dir),
          {ok, J1} = quod_signing_journal:record_transaction(
                       J0, Transaction, Submission, dormant),
          ok = quod_signing_journal:close(J1),
          Path = journal_path(Ns, Dir),
          Offset = filelib:file_size(Path),
          Payload = term_to_binary(
                      {quod_signing_transaction_activated, 4, TxId},
                      [deterministic]),
          ok = file:write_file(
                 Path, quod_signing_journal:test_frame(Payload), [append]),
          ?assertError(
             {signing_journal_bad_transaction_activation, Offset},
             quod_signing_journal:recover(Ns, domain(1), Dir))
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
                        {quod_signing_final_vote, 4,
                         complaint, 8, none},
                        [deterministic]),
          Unknown = binary:replace(
                      Canonical, <<"complaint">>, <<"qzxqvjklm">>),
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
                {quod_signing_pending_begin, 4, Fixed, Fixed,
                 16#FFFFFFFFFFFFFFFF, Fixed, Body, Envelope},
                [deterministic]),
    ?assertEqual(quod_signing_journal:test_max_frame_payload_bytes(),
                 byte_size(AtLimit)),
    Frame = quod_signing_journal:test_frame(AtLimit),
    ?assertEqual(byte_size(AtLimit) + ?HDR_BYTES, byte_size(Frame)),
    Over = term_to_binary(
             {quod_signing_pending_begin, 4, Fixed, Fixed,
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
    Name = "quod_signing_journal_" ++
           binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    Dir = filename:join("/tmp", Name),
    try Fun(Ns, Dir)
    after
        _ = file:del_dir_r(Dir)
    end.

summary(Slot, Live, PendingBegins) ->
    Admissions = maps:from_list(
                   [{Author, Admission}
                    || {{Admission, Author}, _Floor} <- maps:to_list(Live)]),
    summary(Slot, Live, Admissions, PendingBegins).

summary(Slot, Live, Admissions, PendingBegins) ->
    #{committed_slot => Slot, live_dtx_lanes => Live,
      current_admissions => Admissions,
      pending_begins => PendingBegins}.

finalize_control(N, Sequence) ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Admission = hash(1000 + N),
    Ns = <<"journal:target">>,
    Target = {Ns, hash(2000 + N)},
    GroupId = hash(3000 + N),
    {ok, DecisionRef} = quod_dtx:certified_ref(
                          <<Ns/binary, ":origin">>, hash(1990 + N), 1,
                          hash(4000 + N), hash(5000 + N),
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
                         request_binding => none,
                         participants => Participants}),
    Bundle1 = bundle(Target1, Plan1, Manifest, Signer1),
    Bundle2 = bundle(Target2, Plan2, Manifest, Signer2),
    {ok, Record} = quod_dtx:new_begin(
                     Manifest, none, [Bundle1, Bundle2]),
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
                         principal => anonymous, request_binding => none}),
        {Target, Plan, Signer}
    after
        quod_proof_session:stop(Session)
    end.

bundle(Target, Plan, Manifest, Signer) ->
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    {ok, Attestation} = quod_dtx:attest_plan(1,
                          Target, Plan, Manifest, Signer),
    {Target, quod_dtx:digest(Plan), PlanBlob, Attestation}.

sign_begin(#{origin := Origin, admission := Admission,
             signer := Signer}, Record, Sequence) ->
    {ok, Control} = quod_dtx:sign_control(
                      Origin, Record, Admission, Sequence, 0, Signer),
    Control.

same_lane_finalize(#{origin := {Ns, _Anchor} = Target,
                     admission := Admission, signer := Signer}, Sequence) ->
    {ok, DecisionRef} = quod_dtx:certified_ref(
                          <<Ns/binary, ":origin">>, hash(7099), 1,
                          hash(7100), hash(7101), <<"qc">>),
    {ok, Record} = quod_dtx:new_finalize(
                     hash(7102), DecisionRef, abort, none, 0),
    {ok, Control} = quod_dtx:sign_control(
                      Target, Record, Admission, Sequence, 0, Signer),
    Control.

effect_transaction(Ns, Anchor, Author) ->
    {ok, Goal} = quod_durable_term:encode_goal(
                   {create_ontology, <<"journal:created">>, []}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    {ok, #{blob := AgentRef}} = quod_agent_ref:from_text(
                                  <<"journal:agent">>, hash(8202),
                                  <<"journal_agent.">>, 1),
    Effect = {quod_direct_effect, 2, local_durable,
              ontology_lifecycle, create, hash(8201), Author,
              {agent, AgentRef}, {<<"journal:created">>, hash(8203)},
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

pending_map(#{group_id := GroupId} = Fixture) ->
    #{GroupId => pending_row(Fixture)}.

pending_row(#{lane := Lane, sequence := Sequence,
              body := Body, envelope := Envelope}) ->
    #{lane => Lane, sequence => Sequence,
      body => Body, envelope => Envelope}.

pending_term(Fixture) ->
    #{lane := {Admission, Author}, sequence := Sequence,
      group_id := GroupId, body := Body, envelope := Envelope} =
        pending_fixture(Fixture),
    {quod_signing_pending_begin, 4, Admission, Author, Sequence,
     GroupId, Body, Envelope}.

supported_block(Slot, Variant) ->
    {_Signer, _Admission, Control} = finalize_control(10000 + Variant, 1),
    {ok, ControlBytes} = quod_dtx:encode_control(Control),
    {ok, Block} = quod_ledger:new_block(
                    Slot, Slot - 1, {batch, [{dtx, ControlBytes}]}, 0),
    Block.

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
