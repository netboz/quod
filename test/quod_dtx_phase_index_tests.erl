-module(quod_dtx_phase_index_tests).

-include_lib("eunit/include/eunit.hrl").

constant_work_extent_stats_follow_committed_rows_test() ->
    with_index(
      fun(Index, _DataDir) ->
          {ok, #{rows := 0, file_bytes := EmptyBytes}} =
              quod_dtx_phase_index:stats(Index),
          Signer = signer(),
          Target = {<<"quod:phase-stats">>, key(800)},
          Projection = quod_dtx:initial_projection(Target, 0),
          {Control, Ref} = direct_abort(
                             Target, key(801), key(802), 1, Signer),
          {ok, Projection, [_]} = phase_apply(
                                       Index, Control, Ref, Projection),
          {ok, #{rows := 1, file_bytes := StoredBytes}} =
              quod_dtx_phase_index:stats(Index),
          ?assert(StoredBytes >= EmptyBytes)
      end).

exact_history_survives_interleaved_windows_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Signer = signer(),
          Target = {<<"quod:phase-target">>, key(1)},
          Projection = quod_dtx:initial_projection(Target, 0),
          {ControlA, RefA} = direct_abort(Target, key(10), key(11), 1, Signer),
          {ControlB, RefB} = direct_abort(Target, key(20), key(21), 2, Signer),

          {ok, Projection, [_]} =
              phase_apply(
                Index, ControlA, RefA, Projection),
          {ok, Projection, [_]} =
              phase_apply(
                Index, ControlB, RefB, Projection),

          %% A later catch-up window may revisit an ancient GroupId.  The
          %% exact retry is idempotent, while a different record at the same
          %% phase is a deterministic conflict rather than a fresh history.
          {ok, Projection, []} =
              phase_apply(
                Index, ControlA, RefA, Projection),
          {ConflictingA, ConflictingRefA} =
              direct_abort(Target, key(10), key(12), 3, Signer),
          ?assertEqual(
             {error, {invalid_transition, semantic_conflict}},
             phase_apply(
               Index, ConflictingA, ConflictingRefA, Projection))
      end).

failed_transition_never_replaces_exact_history_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Signer = signer(),
          Target = {<<"quod:phase-target">>, key(30)},
          Projection = quod_dtx:initial_projection(Target, 0),
          {Original, OriginalRef} =
              direct_abort(Target, key(31), key(32), 1, Signer),
          {Conflict, ConflictRef} =
              direct_abort(Target, key(31), key(33), 2, Signer),
          {ok, Projection, [_]} =
              phase_apply(
                Index, Original, OriginalRef, Projection),
          ?assertMatch(
             {error, {invalid_transition, _}},
             phase_apply(
               Index, Conflict, ConflictRef, Projection)),
          {ok, Projection, []} =
              phase_apply(
                Index, Original, OriginalRef, Projection)
      end).

preview_isolated_until_one_explicit_commit_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Signer = signer(),
          Target = {<<"quod:phase-target">>, key(34)},
          Projection = quod_dtx:initial_projection(Target, 0),
          GroupId = key(35),
          {Original, OriginalRef} =
              direct_abort(Target, GroupId, key(36), 1, Signer),
          {Conflict, ConflictRef} =
              direct_abort(Target, GroupId, key(37), 2, Signer),

          Delta0 = quod_dtx_phase_index:new_delta(),
          {ok, Delta1, Projection, [_]} =
              phase_preview(
                Index, Delta0, Original, OriginalRef, Projection),

          %% A later record in this same window sees the staged history.
          ?assertEqual(
             {error, {invalid_transition, semantic_conflict}},
             phase_preview(
               Index, Delta1, Conflict, ConflictRef, Projection)),

          %% Discarding the delta models a failed ledger sink: DETS is still
          %% empty, so the alternative first record remains independently
          %% admissible.
          {ok, _Discarded, Projection, [_]} =
              phase_preview(
                Index, quod_dtx_phase_index:new_delta(),
                Conflict, ConflictRef, Projection),

          ok = quod_dtx_phase_index:commit_delta(Index, Delta1),
          {ok, _RetryDelta, Projection, []} =
              phase_preview(
                Index, quod_dtx_phase_index:new_delta(),
                Original, OriginalRef, Projection),
          ?assertEqual(
             {error, {invalid_transition, semantic_conflict}},
             phase_preview(
               Index, quod_dtx_phase_index:new_delta(),
               Conflict, ConflictRef, Projection))
      end).

one_delta_commits_all_interleaved_groups_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Signer = signer(),
          Target = {<<"quod:phase-target">>, key(38)},
          Projection = quod_dtx:initial_projection(Target, 0),
          {ControlA, RefA} = direct_abort(
                               Target, key(39), key(40), 1, Signer),
          {ControlB, RefB} = direct_abort(
                               Target, key(41), key(42), 2, Signer),
          {ok, Delta1, Projection, [_]} =
              phase_preview(
                Index, quod_dtx_phase_index:new_delta(),
                ControlA, RefA, Projection),
          {ok, Delta2, Projection, [_]} =
              phase_preview(
                Index, Delta1, ControlB, RefB, Projection),
          ok = quod_dtx_phase_index:commit_delta(Index, Delta2),
          {ok, Projection, []} = phase_apply(
                                     Index, ControlA, RefA, Projection),
          {ok, Projection, []} = phase_apply(
                                     Index, ControlB, RefB, Projection)
      end).

same_phase_batch_commits_every_exact_history_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Signer = signer(),
          Target = {<<"quod:phase-batch">>, key(46)},
          Projection = quod_dtx:initial_projection(Target, 0),
          {ControlA, RefA} = direct_abort(
                               Target, key(500), key(501), 1, Signer),
          {ControlB, RefB} = direct_abort(
                               Target, key(502), key(503), 2, Signer),
          {ok, Projection, Effects} = quod_dtx_phase_index:apply_batch(
                                          Index,
                                          [{ControlA, RefA},
                                           {ControlB, RefB}],
                                          Projection),
          ?assertEqual(2, length(Effects)),
          {ok, Projection, []} = phase_apply(
                                      Index, ControlA, RefA, Projection),
          {ok, Projection, []} = phase_apply(
                                      Index, ControlB, RefB, Projection)
      end).

window_delta_has_no_arbitrary_group_count_cap_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Signer = signer(),
          Target = {<<"quod:phase-target">>, key(47)},
          Projection = quod_dtx:initial_projection(Target, 0),
          Delta =
              lists:foldl(
                fun(N, Delta0) ->
                    {Control, Ref} = direct_abort(
                                       Target, key(1000 + N), key(2000 + N),
                                       N, Signer),
                    {ok, Delta1, Projection, [_]} =
                        phase_preview(
                          Index, Delta0, Control, Ref, Projection),
                    Delta1
                end,
                quod_dtx_phase_index:new_delta(),
                lists:seq(1, 300)),
          ok = quod_dtx_phase_index:commit_delta(Index, Delta),
          lists:foreach(
            fun(N) ->
                {Control, Ref} = direct_abort(
                                   Target, key(1000 + N), key(2000 + N),
                                   N, Signer),
                {ok, Projection, []} = phase_apply(
                                           Index, Control, Ref, Projection)
            end, [1, 257, 300])
      end).

phase_batch_failure_commits_no_partial_history_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Signer = signer(),
          Target = {<<"quod:phase-batch-atomic">>, key(48)},
          Projection = quod_dtx:initial_projection(Target, 0),
          {ControlA, RefA} =
              direct_abort(Target, key(200), key(201), 1, Signer),
          {OriginalB, OriginalRefB} =
              direct_abort(Target, key(300), key(301), 2, Signer),
          {ConflictB, ConflictRefB} =
              direct_abort(Target, key(300), key(302), 3, Signer),
          {ok, Projection, [_]} = phase_apply(
                                       Index, OriginalB, OriginalRefB,
                                       Projection),

          %% A reduces first, then B conflicts with its exact stored history.
          %% The batch error must leave A absent rather than committing a
          %% successful prefix.
          ?assertEqual(
             {error, {invalid_transition, semantic_conflict}},
             quod_dtx_phase_index:apply_batch(
               Index, [{ControlA, RefA}, {ConflictB, ConflictRefB}],
               Projection)),
          {ok, Projection, [_]} = phase_apply(
                                       Index, ControlA, RefA, Projection),
          {ok, Projection, []} = phase_apply(
                                      Index, OriginalB, OriginalRefB,
                                      Projection)
      end).

singleton_batch_reapply_is_idempotent_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Signer = signer(),
          Target = {<<"quod:phase-singleton">>, key(49)},
          Projection = quod_dtx:initial_projection(Target, 0),
          {Control, Ref} = direct_abort(
                             Target, key(400), key(401), 1, Signer),
          {ok, Projection, [_]} = phase_apply(
                                       Index, Control, Ref, Projection),
          {ok, Projection, [#{effects := []}]} =
              quod_dtx_phase_index:apply_batch(
                Index, [{Control, Ref}], Projection)
      end).

noncanonical_or_trailing_history_fails_closed_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Signer = signer(),
          Target = {<<"quod:phase-target">>, key(40)},
          GroupId = key(41),
          Projection = quod_dtx:initial_projection(Target, 0),
          {Control, Ref} = direct_abort(Target, GroupId, key(42), 1, Signer),
          Canonical = term_to_binary(quod_dtx:initial_group_history(),
                                    [deterministic]),
          ok = quod_dtx_phase_index:test_insert_raw(
                 Index, GroupId, <<Canonical/binary, 0>>),
          ?assertEqual(
             {error, phase_index_corrupt},
             phase_apply(
               Index, Control, Ref, Projection))
      end).

canonical_history_under_the_wrong_group_key_fails_closed_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Signer = signer(),
          Target = {<<"quod:phase-target">>, key(43)},
          GroupId = key(44),
          WrongGroupId = key(45),
          Projection = quod_dtx:initial_projection(Target, 0),
          {Control, Ref} = direct_abort(Target, GroupId, key(46), 1, Signer),
          Entry = #{group_id => WrongGroupId,
                    digest => quod_dtx:record_digest(Control), ref => Ref},
          WrongHistory =
              #{group_id => WrongGroupId,
                records => #{finalize => Entry}},
          ok = quod_dtx_phase_index:test_insert_raw(
                 Index, GroupId,
                 term_to_binary(WrongHistory, [deterministic])),
          ?assertEqual(
             {error, {invalid_transition, bad_binding}},
             phase_apply(
               Index, Control, Ref, Projection))
      end).

session_paths_are_unique_and_close_removes_only_its_file_test() ->
    with_tmp(
      fun(DataDir, Ns) ->
          {ok, First} = quod_dtx_phase_index:open(DataDir, Ns),
          {ok, Second} = quod_dtx_phase_index:open(DataDir, Ns),
          FirstPath = quod_dtx_phase_index:test_path(First),
          SecondPath = quod_dtx_phase_index:test_path(Second),
          ?assertNotEqual(FirstPath, SecondPath),
          ?assert(filelib:is_file(FirstPath)),
          ?assert(filelib:is_file(SecondPath)),
          ok = quod_dtx_phase_index:close(First),
          ?assertNot(filelib:is_file(FirstPath)),
          ?assert(filelib:is_file(SecondPath)),
          ok = quod_dtx_phase_index:close(Second),
          ?assertNot(filelib:is_file(SecondPath))
      end).

suspended_session_reopens_with_exact_history_test() ->
    with_tmp(
      fun(DataDir, Ns) ->
          {ok, Index0} = quod_dtx_phase_index:open(DataDir, Ns),
          Signer = signer(),
          Target = {<<"quod:phase-target">>, key(80)},
          Projection = quod_dtx:initial_projection(Target, 0),
          {Control, Ref} = direct_abort(
                             Target, key(81), key(82), 1, Signer),
          {ok, Projection, [_]} = phase_apply(
                                      Index0, Control, Ref, Projection),
          Path = quod_dtx_phase_index:test_path(Index0),
          {ok, Suspended0} = quod_dtx_phase_index:suspend(Index0),
          ?assert(filelib:is_file(Path)),
          {ok, Index1} = quod_dtx_phase_index:resume(Suspended0),
          {ok, Projection, []} = phase_apply(
                                     Index1, Control, Ref, Projection),
          {ok, Suspended1} = quod_dtx_phase_index:suspend(Index1),
          ok = quod_dtx_phase_index:close(Suspended1),
          ?assertNot(filelib:is_file(Path)),
          ?assertMatch(
             {error, {phase_index_io, enoent}},
             quod_dtx_phase_index:resume(Suspended1))
      end).

killed_owner_does_not_collide_and_startup_cleanup_is_exact_test() ->
    with_tmp(
      fun(DataDir, Ns) ->
          Parent = self(),
          {Owner, Monitor} =
              spawn_monitor(
                fun() ->
                    {ok, Index} = quod_dtx_phase_index:open(DataDir, Ns),
                    Parent ! {opened, quod_dtx_phase_index:test_path(Index)},
                    receive stop -> ok end
                end),
          Abandoned =
              receive
                  {opened, Path} -> Path
              after 5000 ->
                  error(open_timeout)
              end,
          exit(Owner, kill),
          receive
              {'DOWN', Monitor, process, Owner, killed} -> ok
          after 5000 ->
              error(owner_down_timeout)
          end,
          ?assert(filelib:is_file(Abandoned)),

          %% A replacement session mints a new table name even before startup
          %% cleanup removes the killed worker's abandoned file.
          {ok, Replacement} = quod_dtx_phase_index:open(DataDir, Ns),
          ReplacementPath = quod_dtx_phase_index:test_path(Replacement),
          ?assertNotEqual(Abandoned, ReplacementPath),
          ok = quod_dtx_phase_index:close(Replacement),
          ?assert(filelib:is_file(Abandoned)),

          NsDir = quod_ledger_store:ns_dir(DataDir, Ns),
          Adjacent = filename:join(NsDir, "dtx-phases.not-a-session.dets"),
          Uppercase = filename:join(
                        NsDir,
                        "dtx-phases.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.dets"),
          ok = file:write_file(Adjacent, <<"keep">>),
          ok = file:write_file(Uppercase, <<"keep">>),
          ok = quod_dtx_phase_index:cleanup(DataDir, Ns),
          ?assertNot(filelib:is_file(Abandoned)),
          ?assert(filelib:is_file(Adjacent)),
          ?assert(filelib:is_file(Uppercase))
      end).

malformed_control_is_rejected_before_index_access_test() ->
    with_index(
      fun(Index, _DataDir) ->
          Target = {<<"quod:phase-target">>, key(50)},
          Projection = quod_dtx:initial_projection(Target, 0),
          ?assertEqual(
             {error, bad_phase_index_control},
             phase_apply(
               Index, malformed, malformed, Projection))
      end).

phase_preview(Index, Delta, Control, Ref, Projection) ->
    case quod_dtx_phase_index:preview_batch(
           Index, Delta, [{Control, Ref}], Projection) of
        {ok, Delta1, Projection1, [#{effects := Effects}]} ->
            {ok, Delta1, Projection1, Effects};
        Other -> Other
    end.

phase_apply(Index, Control, Ref, Projection) ->
    case quod_dtx_phase_index:apply_batch(
           Index, [{Control, Ref}], Projection) of
        {ok, Projection1, [#{effects := Effects}]} ->
            {ok, Projection1, Effects};
        Other -> Other
    end.

with_index(Fun) ->
    with_tmp(
      fun(DataDir, Ns) ->
          {ok, Index} = quod_dtx_phase_index:open(DataDir, Ns),
          try Fun(Index, DataDir)
          after
              ok = quod_dtx_phase_index:close(Index)
          end
      end).

with_tmp(Fun) ->
    Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
    DataDir = filename:join("/tmp", "quod_dtx_phase_index_" ++ Unique),
    Ns = <<"quod:phase-index-test">>,
    ok = filelib:ensure_path(DataDir),
    try Fun(DataDir, Ns)
    after
        _ = file:del_dir_r(DataDir)
    end.

direct_abort(Target, GroupId, DecisionDigest, Sequence, Signer) ->
    {OriginNs, OriginAnchor} = {<<"quod:phase-origin">>, key(60)},
    {ok, DecisionRef} =
        quod_dtx:certified_ref(
          OriginNs, OriginAnchor, 7, key(61), DecisionDigest,
          <<"decision-qc">>),
    {ok, Record} =
        quod_dtx:new_finalize(GroupId, DecisionRef, abort, none, 0),
    {ok, Control} =
        quod_dtx:sign_control(
          Target, Record, key(62), Sequence, Sequence, Signer),
    {TargetNs, TargetAnchor} = Target,
    {ok, Ref} =
        quod_dtx:certified_ref(
          TargetNs, TargetAnchor, 10 + Sequence, key(70 + Sequence),
          quod_dtx:record_digest(Control), <<"finalize-qc">>),
    {Control, Ref}.

signer() ->
    {Pubkey, Seed} = quod_identity:generate(),
    #{pubkey => Pubkey,
      key => quod_identity:key_term({Pubkey, Seed})}.

key(N) -> <<N:256>>.
