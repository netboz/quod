-module(quod_outcome_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

deterministic_transaction_identity_is_target_anchored_test() ->
    Ns = <<"quod:target">>,
    Anchor = <<1:256>>,
    Digest = <<2:256>>,
    T = transaction(Ns, Anchor, Digest),
    ?assert(quod_transaction:valid_id({Ns, Anchor}, T)),
    ?assertNot(quod_transaction:valid_id(
                 {<<"quod:other">>, Anchor}, T)),
    ?assertNot(quod_transaction:valid_id({Ns, <<3:256>>}, T)).

all_public_outcome_references_share_one_identity_parser_test() ->
    Ns = <<"quod:target">>,
    Anchor = <<1:256>>,
    Identity = {Ns, Anchor},
    ?assertEqual(
       {ok, Identity},
       quod_outcome:ref_identity({transaction, Ns, Anchor, <<2:256>>})),
    ?assertEqual(
       {ok, Identity},
       quod_outcome:ref_identity(
         {group, Ns, Anchor, <<3:256>>, <<4:256>>, <<5:256>>})),
    ?assertEqual(
       {ok, Identity},
       quod_outcome:ref_identity(
         {operation, Ns, Anchor, <<6:256>>, <<7:256>>})),
    ?assertEqual(error, quod_outcome:ref_identity({transaction, Ns, Anchor})),
    ?assertEqual(error, quod_outcome:ref_identity(not_a_reference)).

pending_terminal_and_semantic_duplicate_test() ->
    Ns = <<"quod:outcome-memory">>,
    Anchor = <<4:256>>,
    Digest = <<5:256>>,
    {ok, Index0} = quod_outcome:open(
                     Ns, Anchor, #{outcome_backend => memory}),
    T = transaction(Ns, Anchor, Digest),
    {new, Index1} = quod_outcome:admit(Index0, T),
    Ref = {transaction, Ns, Anchor, T#transaction.tx_id},
    {{ok, Pending}, Index2} = quod_outcome:lookup_ref(Index1, Ref),
    ?assertEqual(pending, maps:get(status, Pending)),
    {pending, Pending, Index2a} = quod_outcome:classify(Index2, T),
    {new, Stored, Index3} = quod_outcome:terminal(
                              Index2a, 27, committed,
                              {pending, Pending}),
    ?assertEqual({committed, 27}, maps:get(status, Stored)),
    {terminal, Stored, Index4} = quod_outcome:classify(Index3, T),
    {duplicate, Stored, Index5} = quod_outcome:terminal(
                                    Index4, 27, committed,
                                    {terminal, Stored}),
    ?assertEqual(
       {ok, #{status => committed, height => 27, ref => Ref}},
       quod_outcome:public(Stored)),
    {{ok, Stored}, _Index6} = quod_outcome:lookup_ref(Index5, Ref),
    ok = quod_outcome:close(Index5).

changed_content_requires_its_own_transaction_id_test() ->
    Ns = <<"quod:outcome-conflict">>,
    Anchor = <<6:256>>,
    Digest = <<7:256>>,
    {ok, Index0} = quod_outcome:open(
                     Ns, Anchor, #{outcome_backend => memory}),
    T = transaction(Ns, Anchor, Digest),
    {new, Candidate, Index0a} = quod_outcome:classify(Index0, T),
    {new, _Stored, Index1} = quod_outcome:terminal(
                               Index0a, 3, committed, {new, Candidate}),
    Changed0 = T#transaction{diff = [{assert, {{different, true}, true}}]},
    ?assertEqual({error, outcome_index_bad_transaction},
                 quod_outcome:classify(Index1, Changed0)),
    Changed = quod_transaction:bind_id({Ns, Anchor}, Changed0),
    ?assertNotEqual(T#transaction.tx_id, Changed#transaction.tx_id),
    ?assertMatch({new, _, _}, quod_outcome:classify(Index1, Changed)),
    ok = quod_outcome:close(Index1).

one_operation_projection_arbitrates_transaction_and_begin_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    {Ns, Anchor} = Target = maps:get(target, Fixture),
    Transaction = maps:get(transaction, Fixture),
    Begin = maps:get('begin', Fixture),
    {ok, TransactionClaim} = quod_transaction:request_claim(Transaction),
    {ok, BeginClaim} = quod_dtx:request_claim(Begin),
    ?assertEqual(TransactionClaim, BeginClaim),
    TransactionRef =
        {transaction, Ns, Anchor, Transaction#transaction.tx_id},
    {ok, GroupRef} = quod_dtx:begin_group_ref(Begin),
    {ok, Index0} = quod_outcome:open(
                     Ns, Anchor, #{outcome_backend => memory}),
    {new, Index1} = quod_outcome:claim_operation(
                      Index0, 2, TransactionClaim, TransactionRef),
    {{claimed, Existing}, Index2} = quod_outcome:check_operation(
                                      Index1, BeginClaim, GroupRef),
    ?assertEqual(TransactionRef, maps:get(outcome_ref, Existing)),
    ?assertEqual(
       {error, outcome_index_conflict},
       quod_outcome:claim_operation(
         Index2, 3, BeginClaim, GroupRef)),
    OperationRef = maps:get(operation_ref, TransactionClaim),
    {{ok, Existing}, Index3} = quod_outcome:lookup_ref(Index2, OperationRef),
    ?assertEqual(
       {ok, #{status => claimed, ref => OperationRef,
              request_digest => maps:get(digest, TransactionClaim),
              outcome_ref => TransactionRef, height => 2}},
       quod_outcome:public(Existing)),
    ?assertEqual(Target, maps:get(target, TransactionClaim)),
    ok = quod_outcome:close(Index3).

same_operation_id_conflicts_across_transaction_and_begin_after_reopen_test() ->
    First = quod_ct:signed_dtx_begin_fixture(#{}),
    {Ns, Anchor} = Target = maps:get(target, First),
    Second = quod_ct:signed_dtx_begin_fixture(
               #{target => Target,
                 key_pair => maps:get(key_pair, First),
                 operation_id => maps:get(operation_id, First),
                 goal_text => <<"assertz(saved(other)).">>}),
    {ok, FirstClaim} = quod_transaction:request_claim(
                         maps:get(transaction, First)),
    {ok, SecondClaim} = quod_dtx:request_claim(maps:get('begin', Second)),
    ?assertEqual(maps:get(key, FirstClaim), maps:get(key, SecondClaim)),
    ?assertNotEqual(maps:get(digest, FirstClaim), maps:get(digest, SecondClaim)),
    FirstRef = {transaction, Ns, Anchor,
                (maps:get(transaction, First))#transaction.tx_id},
    {ok, SecondRef} = quod_dtx:begin_group_ref(maps:get('begin', Second)),
    Dir = outcome_dir("operation-reopen"),
    Config = #{data_dir => Dir, outcome_backend => disk},
    try
        {ok, Index0} = quod_outcome:open(Ns, Anchor, Config),
        {new, Index1} = quod_outcome:claim_operation(
                          Index0, 2, FirstClaim, FirstRef),
        {ok, Index2} = quod_outcome:flush(Index1),
        ok = quod_outcome:close(Index2),
        {ok, Reopened0} = quod_outcome:open(Ns, Anchor, Config),
        {{claimed, Stored}, Reopened1} = quod_outcome:check_operation(
                                          Reopened0, SecondClaim, SecondRef),
        ?assertEqual(maps:get(digest, FirstClaim),
                     maps:get(request_digest, Stored)),
        ?assertEqual(
           {error, outcome_index_conflict},
           quod_outcome:claim_operation(
             Reopened1, 3, SecondClaim, SecondRef)),
        ok = quod_outcome:close(Reopened1)
    after
        _ = file:del_dir_r(Dir)
    end.

nondeterministic_transaction_id_is_rejected_test() ->
    Ns = <<"quod:outcome-id">>,
    Anchor = <<24:256>>,
    Digest = <<25:256>>,
    {ok, Index} = quod_outcome:open(
                    Ns, Anchor, #{outcome_backend => memory}),
    T = (transaction(Ns, Anchor, Digest))#transaction{tx_id = <<26:256>>},
    ?assertEqual({error, outcome_index_bad_transaction},
                 quod_outcome:admit(Index, T)),
    ok = quod_outcome:close(Index).

pending_begin_reenvelope_advances_only_the_same_lane_and_group_test() ->
    Ns = <<"quod:pending-reenvelope">>,
    Anchor = <<27:256>>,
    Lane = {<<28:256>>, <<29:256>>},
    GroupId = <<30:256>>,
    {ok, Index0} = quod_outcome:open(
                     Ns, Anchor, #{outcome_backend => memory}),
    Pending2 = #{lane => Lane, sequence => 2, group_id => GroupId},
    {ok, Index1} = quod_outcome:project_pending_begin(Index0, Pending2),
    {ok, Index1} = quod_outcome:project_pending_begin(Index1, Pending2),
    Pending4 = Pending2#{sequence := 4},
    {ok, Index2} = quod_outcome:project_pending_begin(Index1, Pending4),
    ?assertEqual(
       Pending4,
       maps:get(pending_begin, quod_outcome:dtx_state(Index2))),
    ?assertEqual(
       {error, outcome_index_conflict},
       quod_outcome:project_pending_begin(
         Index2, Pending2#{sequence := 3})),
    ?assertEqual(
       {error, outcome_index_conflict},
       quod_outcome:project_pending_begin(
         Index2, Pending4#{group_id := <<31:256>>})),
    ?assertEqual(
       {error, outcome_index_conflict},
       quod_outcome:project_pending_begin(
         Index2, Pending4#{lane := {<<32:256>>, <<33:256>>}})),
    ok = quod_outcome:close(Index2).

anchored_lookup_rejects_another_founding_test() ->
    Ns = <<"quod:outcome-anchor">>,
    Anchor = <<8:256>>,
    Digest = <<9:256>>,
    {ok, Index0} = quod_outcome:open(
                     Ns, Anchor, #{outcome_backend => memory}),
    T = transaction(Ns, Anchor, Digest),
    {new, Candidate, Index0a} = quod_outcome:classify(Index0, T),
    {new, _Stored, Index1} = quod_outcome:terminal(
                               Index0a, 1, committed, {new, Candidate}),
    WrongRef = {transaction, Ns, <<10:256>>, T#transaction.tx_id},
    ?assertEqual({wrong_anchor, Index1},
                 quod_outcome:lookup_ref(Index1, WrongRef)),
    ?assertEqual({not_found, Index1},
                 quod_outcome:lookup_ref(
                   Index1, {transaction, Ns, Anchor, <<"short">>})),
    ok = quod_outcome:close(Index1).

terminal_older_than_retired_scan_budget_survives_reopen_test() ->
    Ns = <<"quod:outcome-disk">>,
    Anchor = <<11:256>>,
    Digest = <<12:256>>,
    Dir = filename:join(
            "/tmp", "quod-outcome-" ++
                integer_to_list(erlang:unique_integer([positive]))),
    Config = #{data_dir => Dir, outcome_backend => disk},
    try
        T = transaction(Ns, Anchor, Digest),
        Ref = {transaction, Ns, Anchor, T#transaction.tx_id},
        {ok, Index0} = quod_outcome:open(Ns, Anchor, Config),
        {new, Index1} = quod_outcome:admit(Index0, T),
        {pending, Pending, Index1a} = quod_outcome:classify(Index1, T),
        {new, Stored, Index2} = quod_outcome:terminal(
                                  Index1a, 6001, committed,
                                  {pending, Pending}),
        ok = quod_outcome:close(Index2),
        {ok, Reopened0} = quod_outcome:open(Ns, Anchor, Config),
        {{ok, Stored}, Reopened1} = quod_outcome:lookup_ref(Reopened0, Ref),
        ok = quod_outcome:close(Reopened1)
    after
        _ = file:del_dir_r(Dir)
    end.

staged_terminal_is_visible_to_owner_before_flush_test() ->
    Ns = <<"quod:outcome-staged">>,
    Anchor = <<17:256>>,
    Dir = filename:join(
            "/tmp", "quod-outcome-" ++
                integer_to_list(erlang:unique_integer([positive]))),
    Config = #{data_dir => Dir, outcome_backend => disk},
    try
        T = transaction(Ns, Anchor, <<18:256>>),
        Ref = {transaction, Ns, Anchor, T#transaction.tx_id},
        {ok, Index0} = quod_outcome:open(Ns, Anchor, Config),
        {new, Index1} = quod_outcome:admit(Index0, T),
        {pending, Pending, Index1a} = quod_outcome:classify(Index1, T),
        {new, Stored, Index2} = quod_outcome:terminal(
                                  Index1a, 2, committed,
                                  {pending, Pending}),
        {{ok, Stored}, Index3} = quod_outcome:lookup_ref(Index2, Ref),
        DataDir = quod_ledger_store:data_dir(Config),
        ?assertMatch(
           {ok, #{status := pending}},
           quod_outcome:lookup_live(Ns, DataDir, T#transaction.tx_id)),
        {ok, Index4} = quod_outcome:flush(Index3),
        ?assertMatch(
           {ok, #{status := committed, height := 2}},
           quod_outcome:lookup_live(Ns, DataDir, T#transaction.tx_id)),
        ok = quod_outcome:close(Index4),
        %% Stopping the ontology closes its owner handle, but the explorer's
        %% read-only path remains available from the same derived index.
        ?assertMatch(
           {ok, #{status := committed, height := 2}},
           quod_outcome:lookup_live(Ns, DataDir, T#transaction.tx_id))
    after
        _ = file:del_dir_r(Dir)
    end.

table_failure_invalidates_only_the_rebuildable_index_test() ->
    Ns = <<"quod:outcome-reset">>,
    Anchor = <<27:256>>,
    Dir = filename:join(
            "/tmp", "quod-outcome-" ++
                integer_to_list(erlang:unique_integer([positive]))),
    Config = #{data_dir => Dir, outcome_backend => disk},
    try
        T = transaction(Ns, Anchor, <<28:256>>),
        Ref = {transaction, Ns, Anchor, T#transaction.tx_id},
        {ok, Index0} = quod_outcome:open(Ns, Anchor, Config),
        {new, Index1} = quod_outcome:admit(Index0, T),
        {pending, Pending, Index1a} = quod_outcome:classify(Index1, T),
        {new, _Stored, Index2} = quod_outcome:terminal(
                                   Index1a, 4, committed,
                                   {pending, Pending}),
        {ok, Index3} = quod_outcome:flush(Index2),
        ok = quod_outcome:close(Index3),
        {ok, Reopened} = quod_outcome:open(Ns, Anchor, Config),
        Path = filename:join(
                 quod_ledger_store:ns_dir(
                   quod_ledger_store:data_dir(Config), Ns),
                 "outcomes.dets"),
        ok = dets:close(Path),
        ?assertMatch(
           {{error, {outcome_index_io, _}}, _},
           quod_outcome:lookup_ref(Reopened, Ref)),
        ?assertNot(filelib:is_file(Path)),
        {ok, Fresh} = quod_outcome:open(Ns, Anchor, Config),
        ?assertMatch({not_found, _}, quod_outcome:lookup_ref(Fresh, Ref)),
        ok = quod_outcome:close(Fresh)
    after
        _ = file:del_dir_r(Dir)
    end.

public_rejects_corrupt_rows_test() ->
    Ref = {transaction, <<"quod:bad">>, <<19:256>>, <<20:256>>},
    ?assertEqual(
       {error, outcome_index_corrupt},
       quod_outcome:public(#{ref => Ref, status => {committed, 0}})),
    ?assertEqual(
       {error, outcome_index_corrupt},
       quod_outcome:public(#{ref => Ref, status => {rejected, <<"bad">>, 1}})),
    ?assertEqual({error, outcome_index_corrupt}, quod_outcome:public(#{})).

pending_begin_and_abort_reasons_survive_the_ordered_disk_projection_test() ->
    with_group_identity(
      fun(Pub, Signer) ->
          Ns = <<"quod:group-origin">>,
          Anchor = <<31:256>>,
          Reasons = [{prepare_refused,
                      {ontology, <<"quod:group-b">>, <<32:256>>}},
                     {goal, {cannot_link, bob, tom}}],
          F = group_fixture(Ns, Anchor, Pub, Signer, {abort, Reasons}),
          Dir = outcome_dir("group-abort"),
          Config = #{data_dir => Dir, outcome_backend => disk},
          try
              {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
              Pending = #{lane => {maps:get(admission, F), Pub},
                          sequence => 1,
                          group_id => maps:get(group_id, F),
                          body => <<"kept-only-in-journal">>,
                          envelope => <<"kept-only-in-journal">>},
              {ok, I1} = quod_outcome:project_pending_begin(I0, Pending),
              Ref = maps:get(group_ref, F),
              {{ok, PendingOutcome}, I2} = quod_outcome:lookup_ref(I1, Ref),
              ?assertEqual(
                 {ok, #{status => pending, phase => pending_begin,
                        ref => Ref}},
                 quod_outcome:public(PendingOutcome)),

              {I3, H1, P1} = apply_group_control(
                               I2, 1, maps:get(begin_control, F),
                               maps:get(begin_ref, F),
                               quod_dtx:initial_group_history(),
                               quod_dtx:initial_projection({Ns, Anchor}, 0)),
              ?assertEqual(none, maps:get(
                                   pending_begin,
                                   quod_outcome:dtx_state(I3))),
              {ok, I4a} = quod_outcome:advance_applied(I3, 1),
              {ok, I4} = quod_outcome:flush(I4a),

              {I5, H2, P2} = apply_group_control(
                               I4, 2, maps:get(decision_control, F),
                               maps:get(decision_ref, F), H1, P1),
              {ok, I6a} = quod_outcome:advance_applied(I5, 2),
              {ok, I6} = quod_outcome:flush(I6a),
              {{ok, Decided}, I7} = quod_outcome:lookup_ref(I6, Ref),
              ?assertEqual(
                 {ok, #{status => pending, phase => finalizing_abort,
                        ref => Ref}},
                 quod_outcome:public(Decided)),

              {I8, _H3, _P3} = apply_group_control(
                                  I7, 3, maps:get(complete_control, F),
                                  maps:get(complete_ref, F), H2, P2),
              %% Complete is staged, but its result is not public until the
              %% same ordered floor and row are durably flushed together.
              {{ok, Unpublished}, I9} = quod_outcome:lookup_ref(I8, Ref),
              ?assertEqual(
                 {ok, #{status => pending, phase => publication,
                        ref => Ref}},
                 quod_outcome:public(Unpublished)),
              {ok, I10a} = quod_outcome:advance_applied(I9, 3),
              ?assertEqual(2, quod_outcome:applied_floor(I10a)),
              {ok, I10} = quod_outcome:flush(I10a),
              ?assertEqual(3, quod_outcome:applied_floor(I10)),
              {{ok, Aborted}, I11} = quod_outcome:lookup_ref(I10, Ref),
              {ok, Public} = quod_outcome:public(Aborted),
              ?assertEqual(aborted, maps:get(status, Public)),
              ?assertEqual(Reasons, maps:get(reasons, Public)),
              ?assertEqual(maps:get(participant_slots, F),
                           maps:get(participant_slots, Public)),
              ok = quod_outcome:close(I11),

              {ok, Reopened0} = quod_outcome:open(Ns, Anchor, Config),
              %% DTX is replay-derived and starts from the empty prefix on
              %% every engine restart; no terminal history may suppress its
              %% live-equivalent reducer effects.
              ?assertEqual(0, quod_outcome:applied_floor(Reopened0)),
              {EmptyHistory, Reopened1} = quod_outcome:group_history(
                                            Reopened0,
                                            maps:get(group_id, F)),
              ?assertEqual(quod_dtx:initial_group_history(), EmptyHistory),
              {Reopened2, RH1, RP1} = apply_group_control(
                                        Reopened1, 1,
                                        maps:get(begin_control, F),
                                        maps:get(begin_ref, F),
                                        EmptyHistory,
                                        quod_dtx:initial_projection(
                                          {Ns, Anchor}, 0)),
              {ok, Reopened3a} = quod_outcome:advance_applied(Reopened2, 1),
              {ok, Reopened3} = quod_outcome:flush(Reopened3a),
              {Reopened4, RH2, RP2} = apply_group_control(
                                        Reopened3, 2,
                                        maps:get(decision_control, F),
                                        maps:get(decision_ref, F), RH1, RP1),
              {ok, Reopened5a} = quod_outcome:advance_applied(Reopened4, 2),
              {ok, Reopened5} = quod_outcome:flush(Reopened5a),
              {Reopened6, _RH3, _RP3} = apply_group_control(
                                          Reopened5, 3,
                                          maps:get(complete_control, F),
                                          maps:get(complete_ref, F), RH2, RP2),
              {ok, Reopened7a} = quod_outcome:advance_applied(Reopened6, 3),
              {ok, Reopened7} = quod_outcome:flush(Reopened7a),
              {{ok, ReopenedOutcome}, Reopened8} =
                  quod_outcome:lookup_ref(Reopened7, Ref),
              {ok, ReopenedPublic} = quod_outcome:public(ReopenedOutcome),
              ?assertEqual(Reasons, maps:get(reasons, ReopenedPublic)),
              {StoredHistory, Reopened9} = quod_outcome:group_history(
                                             Reopened8,
                                             maps:get(group_id, F)),
              DecisionEntry = maps:get(
                                decision, maps:get(records, StoredHistory)),
              ?assertEqual(maps:get(decision_record, F),
                           maps:get(record, DecisionEntry)),
              {{ok, StoredGroup}, Reopened10} =
                  quod_outcome:lookup_group(
                    Reopened9, maps:get(group_id, F)),
              %% The canonical Decision record is the only durable copy of
              %% the reason blob, and Begin is the only durable copy of the
              %% result; Complete adds publication metadata only.
              Terminal = maps:get(terminal, StoredGroup),
              ?assertNot(maps:is_key(
                           reasons, Terminal)),
              ?assertNot(maps:is_key(result, Terminal)),
              ok = quod_outcome:close(Reopened10)
          after
              _ = file:del_dir_r(Dir)
          end
      end).

commit_result_and_participant_slots_are_published_from_complete_test() ->
    with_group_identity(
      fun(Pub, Signer) ->
          Ns = <<"quod:group-commit">>,
          Anchor = <<41:256>>,
          F = group_fixture(Ns, Anchor, Pub, Signer, commit),
          {ok, I0} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
          LocalPending = #{lane => {<<70:256>>, Pub}, sequence => 9,
                           group_id => <<71:256>>},
          {ok, I0a} = quod_outcome:project_pending_begin(I0, LocalPending),
          {I1, H1, P1} = apply_group_control(
                           I0a, 1, maps:get(begin_control, F),
                           maps:get(begin_ref, F),
                           quod_dtx:initial_group_history(),
                           quod_dtx:initial_projection({Ns, Anchor}, 0)),
          ?assertEqual(LocalPending,
                       maps:get(pending_begin,
                                quod_outcome:dtx_state(I1))),
          {ok, I2a} = quod_outcome:advance_applied(I1, 1),
          {ok, I2} = quod_outcome:flush(I2a),
          {I3, H2, P2} = apply_group_control(
                           I2, 2, maps:get(decision_control, F),
                           maps:get(decision_ref, F), H1, P1),
          {ok, I4a} = quod_outcome:advance_applied(I3, 2),
          {ok, I4} = quod_outcome:flush(I4a),
          {I5, _H3, _P3} = apply_group_control(
                              I4, 3, maps:get(complete_control, F),
                              maps:get(complete_ref, F), H2, P2),
          {ok, I6a} = quod_outcome:advance_applied(I5, 3),
          {ok, I6} = quod_outcome:flush(I6a),
          {{ok, Outcome}, I7} = quod_outcome:lookup_ref(
                                  I6, maps:get(group_ref, F)),
          {ok, Public} = quod_outcome:public(Outcome),
          ?assertEqual(committed, maps:get(status, Public)),
          ?assertEqual([{<<"X">>, linked}], maps:get(bindings, Public)),
          ?assertEqual(maps:get(participant_slots, F),
                       maps:get(participant_slots, Public)),
          ok = quod_outcome:close(I7)
      end).

prepared_plan_is_hidden_then_replaced_by_exact_applied_state_test() ->
    with_group_identity(
      fun(Pub, Signer) ->
          Ns = <<"quod:participant">>,
          Anchor = <<51:256>>,
          F = group_fixture(Ns, Anchor, Pub, Signer, commit),
          Target = {Ns, Anchor},
          GroupId = maps:get(group_id, F),
          BeginRef = maps:get(begin_ref, F),
          PlanBlob = maps:get(plan_a_blob, F),
          {ok, Prepare} = quod_dtx:new_prepare(
                            maps:get(begin_record, F), BeginRef, Target),
          PrepareControl = signed_control(
                             Target, Prepare, maps:get(admission, F), 1,
                             Signer),
          PrepareRef = group_ref(Target, 1, Prepare),
          DecisionRef = maps:get(decision_ref, F),
          {ok, Finalize} = quod_dtx:new_finalize(
                             GroupId, DecisionRef, commit, PrepareRef, 2),
          FinalizeControl = signed_control(
                              Target, Finalize, maps:get(admission, F), 2,
                              Signer),
          FinalizeRef = group_ref(Target, 2, Finalize),
          {ok, I0} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
          P0 = quod_dtx:initial_projection(Target, 0),
          {I1, H1, P1} = apply_group_control(
                           I0, 1, PrepareControl, PrepareRef,
                           quod_dtx:initial_group_history(), P0),
          PreparedProjection = maps:get(
                                 projection, quod_outcome:dtx_state(I1)),
          ?assertMatch(
             #{active := #{participant := #{plan := PlanBlob}}},
             PreparedProjection),
          {ok, I2a} = quod_outcome:advance_applied(I1, 1),
          {ok, I2} = quod_outcome:flush(I2a),
          {I3, _H2, _P2, DeferredAck} =
              apply_group_control_with_deferred_ack(
                I2, 2, FinalizeControl, FinalizeRef, H1, P1),
          {ok, I4a} = quod_outcome:advance_applied(I3, 2),
          {ok, I4} = quod_outcome:flush(I4a),
          %% The caller may send this token only after this flush and its
          %% common MVCC publication have both succeeded.
          ?assertEqual({finalize_applied, GroupId, 2, 2}, DeferredAck),
          {{ok, AppliedRow}, I5} = quod_outcome:lookup_group(I4, GroupId),
          ?assertMatch(#{verdict := commit, slot := 2, generation := 2},
                       maps:get(applied, AppliedRow)),
          StoredProjection = maps:get(
                               projection, quod_outcome:dtx_state(I5)),
          ?assertEqual(open, maps:get(proof_fence, StoredProjection)),
          ok = quod_outcome:close(I5)
      end).

restart_preserves_transactions_and_reemits_prepared_finalize_effect_test() ->
    with_group_identity(
      fun(Pub, Signer) ->
          Ns = <<"quod:restart-participant">>,
          Anchor = <<141:256>>,
          Target = {Ns, Anchor},
          F = group_fixture(Ns, Anchor, Pub, Signer, commit),
          GroupId = maps:get(group_id, F),
          BeginRef = maps:get(begin_ref, F),
          PlanBlob = maps:get(plan_a_blob, F),
          Manifest = maps:get(manifest, F),
          PlanDigest = maps:get(plan_a_digest, F),
          {ok, Prepare} = quod_dtx:new_prepare(
                            maps:get(begin_record, F), BeginRef, Target),
          PrepareControl = signed_control(
                             Target, Prepare, maps:get(admission, F), 1,
                             Signer),
          PrepareRef = group_ref(Target, 2, Prepare),
          {ok, Finalize} = quod_dtx:new_finalize(
                             GroupId, maps:get(decision_ref, F), commit,
                             PrepareRef, 2),
          FinalizeControl = signed_control(
                              Target, Finalize, maps:get(admission, F), 2,
                              Signer),
          FinalizeRef = group_ref(Target, 3, Finalize),
          Tx = transaction(Ns, Anchor, <<144:256>>),
          TxRef = {transaction, Ns, Anchor, Tx#transaction.tx_id},
          Dir = outcome_dir("dtx-restart"),
          Config = #{data_dir => Dir, outcome_backend => disk},
          try
              {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
              {new, TxCandidate, I1} = quod_outcome:classify(I0, Tx),
              {new, StoredTx, I2} = quod_outcome:terminal(
                                      I1, 1, committed,
                                      {new, TxCandidate}),
              {ok, I3a} = quod_outcome:advance_applied(I2, 1),
              {ok, I3} = quod_outcome:flush(I3a),

              H0 = quod_dtx:initial_group_history(),
              P0 = quod_dtx:initial_projection(Target, 0),
              {ok, H1, P1, [{prepared, GroupId, PrepareRef, Manifest,
                              PlanDigest, PlanBlob, 1}] = PrepareEffects} =
                  quod_dtx:reduce(PrepareControl, PrepareRef, H0, P0),
              {ok, I4, none} = quod_outcome:apply_dtx(
                                  I3, 2, PrepareControl, H1, P1,
                                  PrepareEffects),
              {ok, I5a} = quod_outcome:advance_applied(I4, 2),
              {ok, I5} = quod_outcome:flush(I5a),
              {ok, H2, P2,
               [{apply_prepared, GroupId, Manifest, PlanDigest, PlanBlob,
                                 FinalizeRef, 2}] =
                   FinalizeEffects} =
                  quod_dtx:reduce(
                    FinalizeControl, FinalizeRef, H1, P1),
              {ok, I6, DeferredAck} =
                  quod_outcome:apply_dtx(
                    I5, 3, FinalizeControl, H2, P2, FinalizeEffects),
              {ok, I7a} = quod_outcome:advance_applied(I6, 3),
              {ok, I7} = quod_outcome:flush(I7a),
              ?assertEqual(
                 {finalize_applied, GroupId, 3, 2}, DeferredAck),
              ok = quod_outcome:close(I7),

              {ok, R0} = quod_outcome:open(Ns, Anchor, Config),
              %% The ordinary row is preserved and still carries the exact
              %% terminal slot used by its own replay path.
              {{ok, StoredTx}, R1} = quod_outcome:lookup_ref(R0, TxRef),
              ?assertEqual(0, quod_outcome:applied_floor(R1)),
              {ResetHistory, R2} = quod_outcome:group_history(R1, GroupId),
              ?assertEqual(quod_dtx:initial_group_history(), ResetHistory),
              ?assertMatch({not_found, _},
                           quod_outcome:lookup_group(R2, GroupId)),
              ?assertEqual(
                 quod_dtx:initial_projection(Target, 0),
                 maps:get(projection, quod_outcome:dtx_state(R2))),

              %% Slot 1's ordinary replay advances the shared ordered floor;
              %% the same DTX reducer can then replay from its empty prefix.
              {ok, R3a} = quod_outcome:advance_applied(R2, 1),
              {ok, R3} = quod_outcome:flush(R3a),
              {ok, RH1, RP1,
               [{prepared, GroupId, PrepareRef, Manifest, PlanDigest,
                             PlanBlob, 1}] =
                   ReplayPrepareEffects} =
                  quod_dtx:reduce(
                    PrepareControl, PrepareRef, ResetHistory,
                    quod_dtx:initial_projection(Target, 0)),
              {ok, R4, none} = quod_outcome:apply_dtx(
                                  R3, 2, PrepareControl, RH1, RP1,
                                  ReplayPrepareEffects),
              {ok, R5a} = quod_outcome:advance_applied(R4, 2),
              {ok, R5} = quod_outcome:flush(R5a),
              {ok, RH2, RP2,
               [{apply_prepared, GroupId, Manifest, PlanDigest, PlanBlob,
                                 FinalizeRef, 2}] =
                   ReplayFinalizeEffects} =
                  quod_dtx:reduce(
                    FinalizeControl, FinalizeRef, RH1, RP1),
              {ok, R6, ReplayDeferredAck} =
                  quod_outcome:apply_dtx(
                    R5, 3, FinalizeControl, RH2, RP2,
                    ReplayFinalizeEffects),
              {ok, R7a} = quod_outcome:advance_applied(R6, 3),
              {ok, R7} = quod_outcome:flush(R7a),
              ?assertEqual(
                 {finalize_applied, GroupId, 3, 2}, ReplayDeferredAck),
              {{ok, RebuiltGroup}, R8} =
                  quod_outcome:lookup_group(R7, GroupId),
              ?assertMatch(#{verdict := commit, slot := 3, generation := 2},
                           maps:get(applied, RebuiltGroup)),
              ok = quod_outcome:close(R8)
          after
              _ = file:del_dir_r(Dir)
          end
      end).

direct_abort_tombstone_is_an_exact_disk_phase_without_an_active_role_test() ->
    with_group_identity(
      fun(_Pub, Signer) ->
          Ns = <<"quod:direct-abort">>,
          Anchor = <<54:256>>,
          Target = {Ns, Anchor},
          GroupId = <<55:256>>,
          Admission = <<56:256>>,
          DecisionRef = synthetic_ref(
                          {<<"quod:foreign-origin">>, <<57:256>>},
                          8, <<58:256>>),
          {ok, Finalize} = quod_dtx:new_finalize(
                             GroupId, DecisionRef, abort, none, 0),
          Control = signed_control(Target, Finalize, Admission, 1, Signer),
          Ref = group_ref(Target, 1, Finalize),
          Dir = outcome_dir("direct-abort"),
          Config = #{data_dir => Dir, outcome_backend => disk},
          try
              {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
              {I1, History, Projection} = apply_group_control(
                                            I0, 1, Control, Ref,
                                            quod_dtx:initial_group_history(),
                                            quod_dtx:initial_projection(
                                              Target, 0)),
              ?assertEqual(none, maps:get(active, Projection)),
              ?assertEqual([finalize],
                           maps:keys(maps:get(records, History))),
              {ok, I2a} = quod_outcome:advance_applied(I1, 1),
              {ok, I2} = quod_outcome:flush(I2a),
              ok = quod_outcome:close(I2),
              {ok, Reopened0} = quod_outcome:open(Ns, Anchor, Config),
              {EmptyHistory, Reopened1} = quod_outcome:group_history(
                                            Reopened0, GroupId),
              ?assertEqual(quod_dtx:initial_group_history(), EmptyHistory),
              {Replayed0, StoredHistory, _StoredProjection} =
                  apply_group_control(
                    Reopened1, 1, Control, Ref, EmptyHistory,
                    quod_dtx:initial_projection(Target, 0)),
              ?assertEqual(History, StoredHistory),
              {ok, Replayed1a} = quod_outcome:advance_applied(Replayed0, 1),
              {ok, Replayed1} = quod_outcome:flush(Replayed1a),
              {{ok, Row}, Reopened2} = quod_outcome:lookup_group(
                                        Replayed1, GroupId),
              ?assertMatch(#{verdict := abort, slot := 1, generation := 0},
                           maps:get(applied, Row)),
              ok = quod_outcome:close(Reopened2)
          after
              _ = file:del_dir_r(Dir)
          end
      end).

origin_and_participant_roles_share_the_one_projection_slot_test() ->
    with_group_identity(
      fun(Pub, Signer) ->
          Ns = <<"quod:dual-role">>,
          Anchor = <<59:256>>,
          Target = {Ns, Anchor},
          F = group_fixture(Ns, Anchor, Pub, Signer, commit),
          {ok, Prepare} = quod_dtx:new_prepare(
                            maps:get(begin_record, F), maps:get(begin_ref, F),
                            Target),
          PrepareControl = signed_control(
                             Target, Prepare, maps:get(admission, F), 2,
                             Signer),
          PrepareRef = group_ref(Target, 2, Prepare),
          {ok, I0} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
          {I1, H1, P1} = apply_group_control(
                           I0, 1, maps:get(begin_control, F),
                           maps:get(begin_ref, F),
                           quod_dtx:initial_group_history(),
                           quod_dtx:initial_projection(Target, 0)),
          {I2, _H2, _P2} = apply_group_control(
                              I1, 2, PrepareControl, PrepareRef, H1, P1),
          Projection = maps:get(projection, quod_outcome:dtx_state(I2)),
          Active = maps:get(active, Projection),
          ?assertMatch(#{phase := begun}, maps:get(origin, Active)),
          ?assertMatch(#{phase := prepared}, maps:get(participant, Active)),
          ?assertEqual(maps:get(group_id, F), maps:get(group_id, Active)),
          ok = quod_outcome:close(I2)
      end).

outcome_format_break_resets_the_whole_rebuildable_projection_test() ->
    Ns = <<"quod:outcome-v4-break">>,
    Anchor = <<61:256>>,
    Dir = outcome_dir("format-break"),
    Config = #{data_dir => Dir, outcome_backend => disk},
    Path = filename:join(
             quod_ledger_store:ns_dir(
               quod_ledger_store:data_dir(Config), Ns), "outcomes.dets"),
    try
        {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
        {ok, I1a} = quod_outcome:advance_applied(I0, 1),
        {ok, I1} = quod_outcome:flush(I1a),
        ok = quod_outcome:close(I1),
        {ok, Path} = dets:open_file(
                       Path, [{file, Path}, {type, set}, {keypos, 1},
                              {repair, false}]),
        ok = dets:insert(Path, {meta, 3, Anchor}),
        ok = dets:sync(Path),
        ok = dets:close(Path),
        {ok, Reset} = quod_outcome:open(Ns, Anchor, Config),
        ?assertEqual(0, quod_outcome:applied_floor(Reset)),
        ?assertEqual(none, maps:get(
                             pending_begin,
                             quod_outcome:dtx_state(Reset))),
        ok = quod_outcome:close(Reset)
    after
        _ = file:del_dir_r(Dir)
    end.

transaction(Ns, Anchor, Digest) ->
    {ok, Goal} = quod_durable_term:encode_goal(
                   {assertz, {made, true}}),
    {ok, Result} = quod_durable_term:encode_result(#{'X' => true}),
    Transaction0 = #transaction{
       tx_id = <<>>,
       origin = {<<"quod:origin">>, <<13:256>>},
       proof_id = <<14:256>>, plan_digest = Digest,
       goal = Goal, result = Result,
       diff = [{assert, {{made, true}, true}}],
       read_check = #{}, author = <<15:256>>, author_seq = 1,
       submitted_at = 1, sig = <<16:512>>},
    quod_transaction:bind_id({Ns, Anchor}, Transaction0).

outcome_dir(Suffix) ->
    filename:join(
      "/tmp", "quod-outcome-" ++ Suffix ++ "-" ++
          integer_to_list(erlang:unique_integer([positive]))).

with_group_identity(Fun) ->
    Saved = [{K, application:get_env(quod, K)}
             || K <- [node_pubkey, identity_key]],
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub,
               key => quod_identity:key_term({Pub, Seed})},
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, maps:get(key, Signer)),
    try Fun(Pub, Signer)
    after
        lists:foreach(
          fun({K, {ok, Value}}) -> application:set_env(quod, K, Value);
             ({K, undefined}) -> application:unset_env(quod, K)
          end, Saved)
    end.

group_fixture(Ns, Anchor, Pub, Signer, Verdict) ->
    Origin = {Ns, Anchor},
    Other = {<<"quod:group-b">>, <<32:256>>},
    Admission = <<33:256>>,
    ProofId = <<34:256>>,
    {PlanA, PlanABlob} = group_plan(
                           Origin, ProofId, Origin, {origin_write, true},
                           Signer),
    {PlanB, PlanBBlob} = group_plan(
                           Other, ProofId, Origin, {other_write, true},
                           Signer),
    {ok, GoalBlob} = quod_durable_term:encode_goal({link, bob, tom}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{'X' => linked}),
    Participants = [{Origin, quod_dtx:digest(PlanA)},
                    {Other, quod_dtx:digest(PlanB)}],
    {ok, Manifest} = quod_dtx:new_manifest(
                       #{proof_id => ProofId,
                         coordinator => {Ns, Anchor, Pub, Admission},
                         nonce => <<35:256>>, principal => anonymous,
                         goal => GoalBlob, result => ResultBlob,
                         request_binding => none,
                         participants => Participants}),
    {ok, AttA} = quod_dtx:attest_plan(Origin, PlanA, Manifest, Signer),
    {ok, AttB} = quod_dtx:attest_plan(Other, PlanB, Manifest, Signer),
    {ok, Begin} = quod_dtx:new_begin(
                    Manifest, none, none,
                    [{Origin, quod_dtx:digest(PlanA), PlanABlob, AttA},
                     {Other, quod_dtx:digest(PlanB), PlanBBlob, AttB}]),
    GroupId = quod_dtx:group_id(Begin),
    BeginControl = signed_control(Origin, Begin, Admission, 1, Signer),
    BeginRef = group_ref(Origin, 1, Begin),
    PrepareRows =
        [{Identity, synthetic_ref(Identity, Slot, <<(40 + Slot):256>>)}
         || {Identity, Slot} <- lists:sort([{Origin, 7}, {Other, 8}])],
    {DecisionInput, DecisionRows} =
        case Verdict of
            commit -> {commit, PrepareRows};
            {abort, Reasons} -> {{abort, Reasons}, []}
        end,
    {ok, Decision} = quod_dtx:new_decision(
                       GroupId, BeginRef, DecisionInput, DecisionRows),
    DecisionControl = signed_control(
                        Origin, Decision, Admission, 2, Signer),
    DecisionRef = group_ref(Origin, 2, Decision),
    FinalizeRows =
        [{Identity,
          synthetic_ref(Identity, Slot, <<(60 + Slot):256>>),
          Generation}
         || {Identity, Slot, Generation} <-
                lists:sort([{Origin, 10, 1}, {Other, 11, 2}])],
    {ok, Complete} = quod_dtx:new_complete(
                       GroupId, DecisionRef, FinalizeRows),
    CompleteControl = signed_control(
                        Origin, Complete, Admission, 3, Signer),
    CompleteRef = group_ref(Origin, 3, Complete),
    ParticipantSlots =
        [{Identity, Slot, Generation}
         || {Identity, Ref, Generation} <- FinalizeRows,
            Slot <- [ref_slot(Ref)]],
    #{admission => Admission, group_id => GroupId,
      group_ref => {group, Ns, Anchor, Pub, Admission, GroupId},
      manifest => Manifest, begin_record => Begin,
      plan_a_blob => PlanABlob, plan_a_digest => quod_dtx:digest(PlanA),
      plan_b_blob => PlanBBlob, plan_b_digest => quod_dtx:digest(PlanB),
      begin_control => BeginControl, begin_ref => BeginRef,
      decision_record => Decision, decision_control => DecisionControl,
      decision_ref => DecisionRef,
      complete_control => CompleteControl, complete_ref => CompleteRef,
      participant_slots => ParticipantSlots}.

group_plan(Target, ProofId, Origin, Fact, Signer) ->
    Session = quod_proof_session:start(
                quod_ct:committed_kb([]),
                #{read_set => true, proof_context => {origin, outcome_test},
                  signer => Signer}),
    Invocation = crypto:strong_rand_bytes(16),
    Context = quod_predicates:proof_context(
                element(1, Target), 1, undefined, [Target]),
    try
        ok = quod_proof_session:open(
               Session, Invocation, {assertz, Fact}, allowed, Context,
               quod_transaction_scope:empty_selection()),
        {solution, _} = quod_proof_session:next(Session, Invocation),
        {ok, Plan} = quod_dtx:seal_session(
                       Session,
                       #{target => Target, base_height => 1,
                         proof_id => ProofId, origin => Origin,
                         principal => anonymous, request_binding => none}),
        {ok, Blob} = quod_dtx:encode(Plan),
        {Plan, Blob}
    after
        quod_proof_session:stop(Session)
    end.

signed_control(Target, Record, Admission, Sequence, Signer) ->
    {ok, Control} = quod_dtx:sign_control(
                      Target, Record, Admission,
                      Sequence, Sequence, Signer),
    Control.

group_ref({Ns, Anchor}, Slot, Record) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, <<(100 + Slot):256>>,
                  quod_dtx:record_digest(Record),
                  term_to_binary({qc, Slot}, [deterministic])),
    Ref.

synthetic_ref({Ns, Anchor}, Slot, Digest) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, <<(120 + Slot):256>>, Digest,
                  term_to_binary({qc, Slot}, [deterministic])),
    Ref.

apply_group_control(Index, Slot, Control, Ref, History, Projection) ->
    {Index1, History1, Projection1, none} =
        apply_group_control_with_deferred_ack(
          Index, Slot, Control, Ref, History, Projection),
    {Index1, History1, Projection1}.

apply_group_control_with_deferred_ack(Index, Slot, Control, Ref,
                                     History, Projection) ->
    {ok, History1, Projection1, Effects} =
        quod_dtx:reduce(Control, Ref, History, Projection),
    {ok, Index1, DeferredAck} = quod_outcome:apply_dtx(
                                  Index, Slot, Control, History1,
                                  Projection1, Effects),
    {Index1, History1, Projection1, DeferredAck}.

ref_slot({quod_dtx_ref, 2, _, _, Slot, _, _, _}) -> Slot.
