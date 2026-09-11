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
         {operation, Ns, Anchor,
          agent_ref(<<"quod:agent">>, <<6:256>>, 6), <<7:256>>})),
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
              outcome_ref => TransactionRef, height => 2,
              included => [], operation_state => terminal}},
       quod_outcome:public(Existing)),
    ?assertEqual(Target, maps:get(target, TransactionClaim)),
    ok = quod_outcome:close(Index3).

remote_claim_and_completion_form_one_durable_operation_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    {Ns, Anchor} = maps:get(origin, Fixture),
    Claim = maps:get(claim, Fixture),
    TargetRef = maps:get(target_ref, Fixture),
    References = {applications, [TargetRef]},
    {ok, Receipt} = quod_operation_vector:included([TargetRef]),
    {ok, ClaimData} = quod_transaction:request_claim(Claim),
    OperationRef = maps:get(operation_ref, ClaimData),
    Digest = maps:get(digest, ClaimData),
    {ok, Index0} = quod_outcome:open(
                     Ns, Anchor, #{outcome_backend => memory}),
    {new, Index1} = quod_outcome:claim_operation(
                      Index0, 2, ClaimData, References),
    {ok, Index1a} = quod_outcome:flush(Index1),
    {Unresolved, Index2} = quod_outcome:unresolved_operations(Index1a),
    ?assertMatch([#{ref := OperationRef, outcome_ref := References,
                    state := unresolved}], Unresolved),
    {new, Index3} = quod_outcome:check_completion(
                      Index2, OperationRef, Digest, Receipt),
    {new, Index4} = quod_outcome:complete_operation(
                      Index3, 4, OperationRef, Digest, Receipt),
    {replay, Index4Duplicate} = quod_outcome:complete_operation(
                                  Index4, 5, OperationRef,
                                  Digest, Receipt),
    {{ok, #{state := {terminal, 4}}}, _} =
        quod_outcome:lookup_ref(Index4Duplicate, OperationRef),
    {ok, Index4a} = quod_outcome:flush(Index4Duplicate),
    {[], Index5} = quod_outcome:unresolved_operations(Index4a),
    {{ok, Stored}, Index6} = quod_outcome:lookup_ref(Index5, OperationRef),
    ?assertEqual(
       {ok, #{status => claimed, operation_state => terminal,
              ref => OperationRef, request_digest => Digest,
              outcome_ref => References, included => Receipt, height => 2}},
       quod_outcome:public(Stored)),
    ?assertMatch(
       {replay, _},
       quod_outcome:claim_operation(Index6, 2, ClaimData, References)),
    ?assertMatch({replay, _}, quod_outcome:check_completion(
                               Index6, OperationRef, Digest, Receipt)),
    ?assertMatch({error, outcome_index_conflict},
                 quod_outcome:check_completion(
                   Index6, OperationRef, Digest,
                   [{quod_operation_vector:target(TargetRef),
                     {included, setelement(4, TargetRef, <<0:256>>)}}])),
    ok = quod_outcome:close(Index6).

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

pending_begins_projection_replaces_the_exact_group_snapshot_test() ->
    Ns = <<"quod:pending-reenvelope">>,
    Anchor = <<27:256>>,
    Lane = {<<28:256>>, <<29:256>>},
    GroupId = <<30:256>>,
    {ok, Index0} = quod_outcome:open(
                     Ns, Anchor, #{outcome_backend => memory}),
    Pending2 = #{lane => Lane, sequence => 2, group_id => GroupId},
    {ok, Index1} = quod_outcome:project_pending_begins(Index0, [Pending2]),
    {ok, Index1} = quod_outcome:project_pending_begins(Index1, [Pending2]),
    Pending4 = Pending2#{sequence := 4},
    Other = Pending2#{group_id := <<31:256>>, sequence := 1},
    {ok, Index2} = quod_outcome:project_pending_begins(Index1, [Pending4, Other]),
    ?assertEqual(
       #{GroupId => Pending4, <<31:256>> => Other},
       maps:get(pending_begins, quod_outcome:dtx_state(Index2))),
    {ok, Index3} = quod_outcome:project_pending_begins(Index2, []),
    ?assertEqual(#{}, maps:get(pending_begins, quod_outcome:dtx_state(Index3))),
    ok = quod_outcome:close(Index3).

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
              {ok, I1} = quod_outcome:project_pending_begins(I0, [Pending]),
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
              ?assertEqual(#{}, maps:get(
                                 pending_begins,
                                 quod_outcome:dtx_state(I3))),
              {ok, I4a} = quod_outcome:advance_applied(I3, 1),
              {ok, I4} = quod_outcome:flush(I4a),

              {I5, H2, P2, AbortAppliedAck} =
                  apply_group_control_with_deferred_ack(
                    I4, 2, maps:get(decision_control, F),
                    maps:get(decision_ref, F), H1, P1),
              ?assertEqual(
                 {finalize_applied, maps:get(group_id, F), 2, 1},
                 AbortAppliedAck),
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
              {Reopened4, RH2, RP2, ReplayAbortAppliedAck} =
                  apply_group_control_with_deferred_ack(
                    Reopened3, 2, maps:get(decision_control, F),
                    maps:get(decision_ref, F), RH1, RP1),
              ?assertEqual(
                 {finalize_applied, maps:get(group_id, F), 2, 1},
                 ReplayAbortAppliedAck),
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
          {ok, I0a} = quod_outcome:project_pending_begins(I0, [LocalPending]),
          {I1, H1, P1} = apply_group_control(
                           I0a, 1, maps:get(begin_control, F),
                           maps:get(begin_ref, F),
                           quod_dtx:initial_group_history(),
                           quod_dtx:initial_projection({Ns, Anchor}, 0)),
          ?assertEqual(LocalPending,
                       maps:get(maps:get(group_id, LocalPending),
                                maps:get(pending_begins,
                                         quod_outcome:dtx_state(I1)))),
          {ok, I2a} = quod_outcome:advance_applied(I1, 1),
          {ok, I2} = quod_outcome:flush(I2a),
          {I3, H2, P2a, {finalize_applied, _, 2, 2}} =
              apply_group_control_with_deferred_ack(
                I2, 2, maps:get(decision_control, F),
                maps:get(decision_ref, F), H1, P1),
          {ok, I4a} = quod_outcome:advance_applied(I3, 2),
          {ok, I4} = quod_outcome:flush(I4a),
          {ok, P2} = quod_dtx:acknowledge_finalize(
                       maps:get(group_id, F), 2, 2, P2a),
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

source_fused_prepared_plan_is_hidden_then_replaced_by_exact_applied_state_test() ->
    with_group_identity(
      fun(Pub, Signer) ->
          Ns = <<"quod:participant">>,
          Anchor = <<51:256>>,
          F = group_fixture(Ns, Anchor, Pub, Signer, commit),
          Target = {Ns, Anchor},
          GroupId = maps:get(group_id, F),
          PlanBlob = maps:get(plan_a_blob, F),
          DecisionRef = maps:get(decision_ref, F),
          {ok, I0} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
          P0 = quod_dtx:initial_projection(Target, 0),
          {I1, H1, P1} = apply_group_control(
                           I0, 1, maps:get(begin_control, F),
                           maps:get(begin_ref, F),
                           quod_dtx:initial_group_history(), P0),
          PreparedProjection = maps:get(
                                 projection, quod_outcome:dtx_state(I1)),
          ?assertMatch(
             #{participant := #{plan := PlanBlob}},
             maps:get(GroupId, maps:get(groups, PreparedProjection))),
          {ok, I2a} = quod_outcome:advance_applied(I1, 1),
          {ok, I2} = quod_outcome:flush(I2a),
          {I3, _H2, _P2, DeferredAck} =
              apply_group_control_with_deferred_ack(
                I2, 2, maps:get(decision_control, F), DecisionRef, H1, P1),
          {ok, I4a} = quod_outcome:advance_applied(I3, 2),
          {ok, I4} = quod_outcome:flush(I4a),
          %% The caller may send this token only after this flush and its
          %% common MVCC publication have both succeeded.
          ?assertEqual({finalize_applied, GroupId, 2, 2}, DeferredAck),
          {{ok, AppliedRow}, I5} = quod_outcome:lookup_group(I4, GroupId),
          ?assertEqual(
             #{verdict => commit, finalize_ref => DecisionRef,
               slot => 2, generation => 2,
               group_ref => maps:get(group_ref, F),
               plan_digest => maps:get(plan_a_digest, F),
               manifest_digest =>
                   quod_dtx:manifest_digest(maps:get(manifest, F))},
             maps:get(applied, AppliedRow)),
          StoredProjection = maps:get(
                               projection, quod_outcome:dtx_state(I5)),
          %% Ordered apply has removed the hidden participant plan.  Because
          %% this ontology is also the origin, its exact applied marker stays
          %% nonblocking until Complete consumes it; replay reconstructs the
          %% same state without relying on an off-ledger acknowledgement.
          ?assertMatch(
             #{origin := #{phase := {decided, commit}}, participant := none},
             maps:get(GroupId, maps:get(groups, StoredProjection))),
          ?assertEqual(
             #{GroupId => #{slot => 2, generation => 2,
                            blocking => false}},
             maps:get(apply_fences, StoredProjection)),
          ok = quod_outcome:close(I5)
      end).

restart_reemits_fused_begin_and_decision_effects_test() ->
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
          BeginControl = maps:get(begin_control, F),
          DecisionControl = maps:get(decision_control, F),
          DecisionRef = maps:get(decision_ref, F),
          Dir = outcome_dir("dtx-restart"),
          Config = #{data_dir => Dir, outcome_backend => disk},
          try
              {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
              H0 = quod_dtx:initial_group_history(),
              P0 = quod_dtx:initial_projection(Target, 0),
              {ok, H1, P1,
               [{origin_started, GroupId, BeginRef},
                {prepared, GroupId, BeginRef, Manifest,
                 PlanDigest, PlanBlob, 1}] = PrepareEffects} =
                  quod_dtx:reduce(BeginControl, BeginRef, H0, P0),
              {ok, I4, none} = quod_outcome:apply_dtx(
                                  I0, 1, BeginControl, H1, P1,
                                  PrepareEffects),
              {ok, I5a} = quod_outcome:advance_applied(I4, 1),
              {ok, I5} = quod_outcome:flush(I5a),
              {ok, H2, P2,
               [{decided, GroupId, commit, DecisionRef},
                {apply_prepared, GroupId, Manifest, PlanDigest, PlanBlob,
                                 DecisionRef, 2}] =
                   FinalizeEffects} =
                  quod_dtx:reduce(
                    DecisionControl, DecisionRef, H1, P1),
              {ok, I6, DeferredAck} =
                  quod_outcome:apply_dtx(
                    I5, 2, DecisionControl, H2, P2, FinalizeEffects),
              {ok, I7a} = quod_outcome:advance_applied(I6, 2),
              {ok, I7} = quod_outcome:flush(I7a),
              ?assertEqual(
                 {finalize_applied, GroupId, 2, 2}, DeferredAck),
              ok = quod_outcome:close(I7),

              {ok, R0} = quod_outcome:open(Ns, Anchor, Config),
              ?assertEqual(0, quod_outcome:applied_floor(R0)),
              {ResetHistory, R2} = quod_outcome:group_history(R0, GroupId),
              ?assertEqual(quod_dtx:initial_group_history(), ResetHistory),
              ?assertMatch({not_found, _},
                           quod_outcome:lookup_group(R2, GroupId)),
              ?assertEqual(
                 quod_dtx:initial_projection(Target, 0),
                 maps:get(projection, quod_outcome:dtx_state(R2))),

              {ok, RH1, RP1,
               [{origin_started, GroupId, BeginRef},
                {prepared, GroupId, BeginRef, Manifest, PlanDigest,
                             PlanBlob, 1}] =
                   ReplayPrepareEffects} =
                  quod_dtx:reduce(
                    BeginControl, BeginRef, ResetHistory,
                    quod_dtx:initial_projection(Target, 0)),
              {ok, R4, none} = quod_outcome:apply_dtx(
                                  R2, 1, BeginControl, RH1, RP1,
                                  ReplayPrepareEffects),
              {ok, R5a} = quod_outcome:advance_applied(R4, 1),
              {ok, R5} = quod_outcome:flush(R5a),
              {ok, RH2, RP2,
               [{decided, GroupId, commit, DecisionRef},
                {apply_prepared, GroupId, Manifest, PlanDigest, PlanBlob,
                                 DecisionRef, 2}] =
                   ReplayFinalizeEffects} =
                  quod_dtx:reduce(
                    DecisionControl, DecisionRef, RH1, RP1),
              {ok, R6, ReplayDeferredAck} =
                  quod_outcome:apply_dtx(
                    R5, 2, DecisionControl, RH2, RP2,
                    ReplayFinalizeEffects),
              {ok, R7a} = quod_outcome:advance_applied(R6, 2),
              {ok, R7} = quod_outcome:flush(R7a),
              ?assertEqual(
                 {finalize_applied, GroupId, 2, 2}, ReplayDeferredAck),
              {{ok, RebuiltGroup}, R8} =
                  quod_outcome:lookup_group(R7, GroupId),
              ?assertEqual(
                 #{verdict => commit, finalize_ref => DecisionRef,
                   slot => 2, generation => 2,
                   group_ref => maps:get(group_ref, F),
                   plan_digest => PlanDigest,
                   manifest_digest =>
                       quod_dtx:manifest_digest(maps:get(manifest, F))},
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
              {I1, History, Projection, DeferredAck} =
                  apply_group_control_with_deferred_ack(
                    I0, 1, Control, Ref,
                    quod_dtx:initial_group_history(),
                    quod_dtx:initial_projection(Target, 0)),
              ?assertEqual(
                 {finalize_applied, GroupId, 1, 0}, DeferredAck),
              ?assertEqual(#{}, maps:get(groups, Projection)),
              ?assertEqual([finalize],
                           maps:keys(maps:get(records, History))),
              {ok, I2a} = quod_outcome:advance_applied(I1, 1),
              {ok, I2} = quod_outcome:flush(I2a),
              ok = quod_outcome:close(I2),
              {ok, Reopened0} = quod_outcome:open(Ns, Anchor, Config),
              {EmptyHistory, Reopened1} = quod_outcome:group_history(
                                            Reopened0, GroupId),
              ?assertEqual(quod_dtx:initial_group_history(), EmptyHistory),
              {Replayed0, StoredHistory, _StoredProjection,
               ReplayDeferredAck} =
                  apply_group_control_with_deferred_ack(
                    Reopened1, 1, Control, Ref, EmptyHistory,
                    quod_dtx:initial_projection(Target, 0)),
              ?assertEqual(
                 {finalize_applied, GroupId, 1, 0}, ReplayDeferredAck),
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
          {ok, I0} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
          {I1, _H1, _P1} = apply_group_control(
                           I0, 1, maps:get(begin_control, F),
                           maps:get(begin_ref, F),
                           quod_dtx:initial_group_history(),
                           quod_dtx:initial_projection(Target, 0)),
          Projection = maps:get(projection, quod_outcome:dtx_state(I1)),
          Active = maps:get(maps:get(group_id, F), maps:get(groups, Projection)),
          ?assertMatch(#{phase := begun}, maps:get(origin, Active)),
          ?assertMatch(#{phase := prepared}, maps:get(participant, Active)),
          ok = quod_outcome:close(I1)
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
        ?assertEqual(#{}, maps:get(
                           pending_begins,
                           quod_outcome:dtx_state(Reset))),
        ok = quod_outcome:close(Reset)
    after
        _ = file:del_dir_r(Dir)
    end.

different_valid_decision_quorums_publish_complete_test_() ->
    [{atom_to_list(Backend) ++ " " ++ atom_to_list(Verdict),
      fun() ->
          with_certified_group(Verdict,
            fun(F) ->
                {Ns, Anchor} = maps:get(target, F),
                Dir = outcome_dir("equivalent-quorums"),
                Config = #{data_dir => Dir, outcome_backend => Backend},
                try
                    {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
                    try certified_complete_replay(I0, F)
                    after quod_outcome:close(I0) end,
                    case Backend of
                        disk ->
                            {ok, R0} = quod_outcome:open(Ns, Anchor, Config),
                            try
                                ?assertEqual(0, quod_outcome:applied_floor(R0)),
                                ?assertMatch({not_found, _},
                                  quod_outcome:lookup_group(R0, maps:get(group_id, F))),
                                certified_complete_replay(R0, F)
                            after quod_outcome:close(R0) end;
                        memory -> ok
                    end
                after file:del_dir_r(Dir) end
            end)
      end} || Backend <- [memory, disk], Verdict <- [commit, abort]].

prepared_projection_compares_claims_and_keeps_plan_pins_test() ->
    with_certified_group(commit,
      fun(F) ->
          Phase = maps:get(prepare, F),
          Control = maps:get(control, Phase),
          Target = {Ns, Anchor} = quod_dtx:control_target(Control),
          GroupId = maps:get(group_id, F),
          Ref = maps:get(ref, Phase),
          {ok, H, P, Effects} = quod_dtx:reduce(
                                 Control, Ref, quod_dtx:initial_group_history(),
                                 quod_dtx:initial_projection(Target, 0)),
          {ok, I} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
          try
              %% A contract test of the prepared-effect consistency seam:
              %% the current reducer emits the SAME Ref into both outputs.
              %% Supply its other fully verified representation here. This is
              %% not an incoming-Finalize path or a claimed second live bug.
              Groups = maps:get(groups, P),
              Group = maps:get(GroupId, Groups),
              Participant = maps:get(participant, Group),
              Replace = fun(Part) ->
                            P#{groups := Groups#{GroupId :=
                                                   Group#{participant := Part}}}
                        end,
              Equivalent = Participant#{prepare_ref := maps:get(alternate_ref, Phase)},
              ?assertMatch({ok, _, none}, quod_outcome:apply_dtx(
                             I, 2, Control, H, Replace(Equivalent), Effects)),
              Pins = [{prepare_kind, 'begin'},
                      {manifest, maps:get(manifest, Participant)},
                      {plan_digest, <<99:256>>}, {plan, <<"different">>},
                      {prepared_generation, 2}],
              %% Manifest is a tuple; change an existing field without
              %% changing any other plan pin.
              BadManifest = setelement(3, maps:get(manifest, Participant), <<98:256>>),
              lists:foreach(
                fun({Field, Value}) ->
                    BadP = Replace(Equivalent#{Field := Value}),
                    ?assertMatch({error, _},
                      quod_outcome:apply_dtx(I, 2, Control, H, BadP, Effects))
                end, lists:keyreplace(manifest, 1, Pins, {manifest, BadManifest})),
              [{prepared, GroupId, Ref, Manifest, Digest, Blob, Generation}] = Effects,
              lists:foreach(
                fun(BadRef) ->
                    ?assertMatch({error, _}, quod_outcome:apply_dtx(
                      I, 2, Control, H, P,
                      [{prepared, GroupId, BadRef, Manifest, Digest, Blob, Generation}]))
                end, changed_reference_claims(Ref))
          after quod_outcome:close(I) end
      end).

remote_finalize_accepts_another_valid_prepare_quorum_test_() ->
    [{atom_to_list(Verdict), fun() ->
        with_certified_group(Verdict,
          fun(F) ->
              Prepare = maps:get(prepare, F), Finalize = maps:get(finalize, F),
              Target = {Ns, Anchor} = quod_dtx:control_target(maps:get(control, Prepare)),
              {ok, I0} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
              try
                  {I1, H1, P1} = apply_group_control(
                    I0, 2, maps:get(control, Prepare), maps:get(alternate_ref, Prepare),
                    quod_dtx:initial_group_history(), quod_dtx:initial_projection(Target, 0)),
                  Control = maps:get(control, Finalize), Ref = maps:get(ref, Finalize),
                  {ok, H2, P2, Effects} = quod_dtx:reduce(Control, Ref, H1, P1),
                  GroupId = maps:get(group_id, F),
                  Generation = maps:get(applied_generation, F),
                  {ok, I2, Ack} = quod_outcome:apply_dtx(I1, 3, Control, H2, P2, Effects),
                  ?assertEqual({finalize_applied, GroupId, 3, Generation}, Ack),
                  {{ok, Row}, _} = quod_outcome:lookup_group(I2, GroupId),
                  ?assertMatch(#{verdict := Verdict, generation := Generation},
                               maps:get(applied, Row)),
                  Body = quod_dtx:control_body(Control),
                  WrongGeneration = setelement(7, Body, Generation + 1),
                  BadControl = fixture_control(Target, WrongGeneration, 2, F),
                  BadPhase = certified_phase(Target, BadControl, 3, maps:get(signers, F)),
                  ?assertEqual({error, {invalid_transition, bad_applied_generation}},
                    quod_dtx:reduce(BadControl, maps:get(ref, BadPhase), H1, P1))
              after quod_outcome:close(I0) end
          end)
      end} || Verdict <- [commit, abort]].

equivalent_quorums_do_not_relax_retained_outcome_bytes_test() ->
    with_certified_group(commit,
      fun(F) ->
          {Ns, Anchor} = maps:get(target, F),
          {ok, I0} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
          try
              {I1, H1, P1} = certified_source_begin(I0, F),
              Phase = maps:get(decision, F), Control = maps:get(control, Phase),
              Ref = maps:get(alternate_ref, Phase),
              {ok, H2, P2, Effects} = quod_dtx:reduce(Control, Ref, H1, P1),
              [{decided, G, commit, Ref}, Apply] = Effects,
              ?assertEqual({error, outcome_index_conflict},
                quod_outcome:apply_dtx(I1, 3, Control, H2, P2,
                                      [{decided, G, abort, Ref}, Apply])),
              %% Even a different valid proof cannot rewrite a retained row.
              Records = maps:get(records, H2), Begin = maps:get('begin', Records),
              ChangedHistory = H2#{records := Records#{'begin' :=
                Begin#{ref := maps:get(alternate_ref, maps:get('begin', F))}}},
              ?assertEqual({error, outcome_index_conflict},
                quod_outcome:apply_dtx(I1, 3, Control, ChangedHistory, P2, Effects)),
              {ok, Blob} = quod_durable_term:encode_result(#{'X' => changed}),
              BeginControl = maps:get(control, maps:get('begin', F)),
              BeginBody = quod_dtx:control_body(BeginControl),
              ChangedManifest = setelement(9, maps:get(manifest, F), Blob),
              BadBody = setelement(3, BeginBody, ChangedManifest),
              %% Re-signing is deliberately not used to conceal the changed
              %% signed result: the existing structural validator refuses it.
              BadBegin = setelement(5, BeginControl, BadBody),
              ?assertMatch({error, _}, quod_outcome:apply_dtx(
                I1, 2, BadBegin, H1, P1, []))
          after quod_outcome:close(I0) end
      end).

certified_complete_replay(I0, F) ->
    {I1, H1, P1} = certified_source_begin(I0, F),
    D = maps:get(decision, F),
    {I2, H2, P2, _Ack} = apply_group_control_with_deferred_ack(
      I1, 3, maps:get(control, D), maps:get(alternate_ref, D), H1, P1),
    {ok, I3a} = quod_outcome:advance_applied(I2, 3),
    {ok, I3} = quod_outcome:flush(I3a),
    C = maps:get(complete, F),
    {I4, _H3, _P3} = apply_group_control(
      I3, 4, maps:get(control, C), maps:get(ref, C), H2, P2),
    {ok, I5} = quod_outcome:advance_applied(I4, 4),
    {{ok, Before}, I6} = quod_outcome:lookup_ref(I5, maps:get(group_ref, F)),
    ?assertMatch({ok, #{status := pending, phase := publication}},
                 quod_outcome:public(Before)),
    ?assertEqual(3, quod_outcome:applied_floor(I6)),
    {ok, I7} = quod_outcome:flush(I6),
    {{ok, After}, _} = quod_outcome:lookup_ref(I7, maps:get(group_ref, F)),
    {ok, Public} = quod_outcome:public(After),
    case maps:get(verdict, F) of
        commit -> ?assertMatch(#{status := committed, bindings := [{<<"X">>, linked}]}, Public);
        abort -> ?assertMatch(#{status := aborted, reasons := [{test_abort, quorum}]}, Public)
    end,
    ?assertEqual(4, quod_outcome:applied_floor(I7)).

certified_source_begin(I0, F) ->
    {ok, I0a} = quod_outcome:advance_applied(I0, 1),
    {ok, I0b} = quod_outcome:flush(I0a),
    B = maps:get('begin', F),
    {I1, H1, P1} = apply_group_control(
      I0b, 2, maps:get(control, B), maps:get(ref, B),
      quod_dtx:initial_group_history(), quod_dtx:initial_projection(maps:get(target, F), 0)),
    {ok, I2a} = quod_outcome:advance_applied(I1, 2),
    {ok, I2} = quod_outcome:flush(I2a),
    {I2, H1, P1}.

changed_reference_claims(Ref) ->
    [setelement(3, Ref, <<"quod:another-identity">>),
     setelement(4, Ref, <<91:256>>), setelement(5, Ref, ref_slot(Ref) + 1),
     setelement(6, Ref, <<92:256>>), setelement(7, Ref, <<93:256>>)].

with_certified_group(Verdict, Fun) ->
    with_group_identity(fun(Pub, Signer) ->
        Target = {Ns, Anchor} = {<<"quod:group-origin">>, <<81:256>>},
        Other = {<<"quod:group-b">>, <<32:256>>},
        Choice = case Verdict of commit -> commit; abort -> {abort, [{test_abort, quorum}]} end,
        Base = group_fixture(Ns, Anchor, Pub, Signer, Choice),
        Signers = [Signer | [begin
          {P, Seed} = quod_identity:generate(),
          #{pubkey => P, key => quod_identity:key_term({P, Seed})}
        end || _ <- lists:seq(1, 3)]],
        F0 = Base#{target => Target, signer => Signer, signers => Signers, verdict => Verdict},
        Begin = maps:get(begin_record, Base),
        B = certified_phase(Target, maps:get(begin_control, Base), 2, Signers),
        BeginRef = maps:get(ref, B),
        {ok, Prepare} = quod_dtx:new_prepare(Begin, BeginRef, Other),
        P = certified_phase(Other, fixture_control(Other, Prepare, 1, F0), 2, Signers),
        Rows = case Verdict of commit -> [{Target, BeginRef}, {Other, maps:get(ref, P)}];
                               abort -> [{Target, BeginRef}] end,
        {ok, Decision} = quod_dtx:new_decision(maps:get(group_id, Base), BeginRef, Choice, Rows),
        D = certified_phase(Target, fixture_control(Target, Decision, 2, F0), 3, Signers),
        Generation = case Verdict of commit -> 2; abort -> 1 end,
        {ok, Finalize} = quod_dtx:new_finalize(maps:get(group_id, Base), maps:get(ref, D),
                                             Verdict, maps:get(ref, P), Generation),
        Z = certified_phase(Other, fixture_control(Other, Finalize, 2, F0), 3, Signers),
        {ok, Complete} = quod_dtx:new_complete(maps:get(group_id, Base), maps:get(ref, D),
          [{Target, maps:get(ref, D), Generation}, {Other, maps:get(ref, Z), Generation}]),
        C = certified_phase(Target, fixture_control(Target, Complete, 3, F0), 4, Signers),
        Fun(F0#{'begin' => B, prepare => P, decision => D, finalize => Z, complete => C,
                applied_generation => Generation})
    end).

fixture_control(Target, Record, Sequence, F) ->
    signed_control(Target, Record, maps:get(admission, F), Sequence, maps:get(signer, F)).

certified_phase(Target = {Ns, Anchor}, Control, Slot, Signers) ->
    {ok, Blob} = quod_dtx:encode_control(Control),
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, {batch, [{dtx, Blob}]}, Slot),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Hash = quod_simplex:block_hash(Block),
    Committee = lists:sort([maps:get(pubkey, S) || S <- Signers]),
    Shares = maps:from_list([{maps:get(pubkey, S),
               quod_simplex:make_share(Domain, commit, Slot, Hash, S)} || S <- Signers]),
    [A, B, C, D] = Committee,
    Make = fun(Keys) ->
        {ok, Cert} = quod_simplex:form_cert(Domain, commit, Slot, Hash,
                       [maps:get(K, Shares) || K <- Keys], Committee),
        Entry = quod_ledger:entry(Block, Cert),
        {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Control),
        {Entry, Ref}
    end,
    {Entry, Ref} = Make([A, B, C]), {OtherEntry, OtherRef} = Make([B, C, D]),
    ?assertNotEqual(Ref, OtherRef),
    ?assert(quod_dtx:same_certified_ref(Ref, OtherRef)),
    ?assert(quod_dtx:certified_entry_ref_matches(Target, Entry, Control, OtherRef, Committee)),
    ?assert(quod_dtx:certified_entry_ref_matches(Target, OtherEntry, Control, Ref, Committee)),
    #{control => Control, entry => Entry, ref => Ref, alternate_ref => OtherRef,
      committee => Committee}.

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
          binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))).

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
                    Manifest, none,
                    [{Origin, quod_dtx:digest(PlanA), PlanABlob, AttA},
                     {Other, quod_dtx:digest(PlanB), PlanBBlob, AttB}]),
    GroupId = quod_dtx:group_id(Begin),
    BeginControl = signed_control(Origin, Begin, Admission, 1, Signer),
    BeginRef = group_ref(Origin, 1, Begin),
    OtherPrepareRef = synthetic_ref(Other, 8, <<48:256>>),
    PrepareRows = [{Origin, BeginRef}, {Other, OtherPrepareRef}],
    {DecisionInput, DecisionRows} =
        case Verdict of
            commit -> {commit, PrepareRows};
            {abort, Reasons} -> {{abort, Reasons}, [{Origin, BeginRef}]}
        end,
    {ok, Decision} = quod_dtx:new_decision(
                       GroupId, BeginRef, DecisionInput, DecisionRows),
    DecisionControl = signed_control(
                        Origin, Decision, Admission, 2, Signer),
    DecisionRef = group_ref(Origin, 2, Decision),
    SourceGeneration = case Verdict of commit -> 2; {abort, _} -> 1 end,
    FinalizeRows =
        [{Origin, DecisionRef, SourceGeneration},
         {Other, synthetic_ref(Other, 11, <<71:256>>), 2}],
    {ok, Complete} = quod_dtx:new_complete(
                       GroupId, DecisionRef, FinalizeRows),
    CompleteControl = signed_control(
                        Origin, Complete, Admission, 3, Signer),
    CompleteRef = group_ref(Origin, 3, Complete),
    ParticipantSlots = lists:sort(
        [{Identity, Slot, Generation}
         || {Identity, Ref, Generation} <- FinalizeRows,
            Slot <- [ref_slot(Ref)]]),
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

agent_ref(Ns, Anchor, N) ->
    {ok, #{blob := Blob}} = quod_agent_ref:from_text(
                              Ns, Anchor,
                              <<"human_user(", (integer_to_binary(N))/binary,
                                ").">>,
                              2),
    Blob.
