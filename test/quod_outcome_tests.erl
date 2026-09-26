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

one_operation_projection_arbitrates_transaction_and_vote_test() ->
    Fixture = quod_ct:signed_atomic_fixture(#{}),
    {Ns, Anchor} = Target = maps:get(target, Fixture),
    Transaction = maps:get(transaction, Fixture),
    {ok, TransactionClaim} = quod_transaction:request_claim(Transaction),
    Material = quod_atomic:control_material(maps:get(vote_control, Fixture)),
    {_, _, #{group := #{request := #{claim := VoteClaim}}}} = Material,
    ?assertEqual(TransactionClaim, VoteClaim),
    TransactionRef =
        {transaction, Ns, Anchor, Transaction#transaction.tx_id},
    {ok, GroupRef} = quod_atomic:source_group_ref(Material),
    {ok, Index0} = quod_outcome:open(
                     Ns, Anchor, #{outcome_backend => memory}),
    {new, Index1} = quod_outcome:claim_operation(
                      Index0, 2, TransactionClaim, TransactionRef),
    {{claimed, Existing}, Index2} = quod_outcome:check_operation(
                                      Index1, VoteClaim, GroupRef),
    ?assertEqual(TransactionRef, maps:get(outcome_ref, Existing)),
    ?assertEqual(
       {error, outcome_index_conflict},
       quod_outcome:claim_operation(
         Index2, 3, VoteClaim, GroupRef)),
    OperationRef = maps:get(operation_ref, TransactionClaim),
    {{ok, Existing}, Index3} = quod_outcome:lookup_ref(Index2, OperationRef),
    ?assertEqual(
       {ok, #{status => claimed, ref => OperationRef,
              request_digest => maps:get(digest, TransactionClaim),
              outcome_ref => TransactionRef, height => 2,
              included => [], operation_state => terminal, receipt_height => 2}},
       quod_outcome:public(Existing)),
    ?assertEqual(Target, maps:get(target, TransactionClaim)),
    ok = quod_outcome:close(Index3).

remote_claim_and_completion_form_one_durable_operation_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    {Ns, Anchor} = maps:get(origin, Fixture),
    Claim = maps:get(claim, Fixture),
    TargetRef = maps:get(target_ref, Fixture),
    References = {applications, [TargetRef]},
    {ok, Receipt} = quod_ct:certified_receipt([TargetRef]),
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
              outcome_ref => References, included => Receipt, height => 2, receipt_height => 4}},
       quod_outcome:public(Stored)),
    ?assertMatch(
       {replay, _},
       quod_outcome:claim_operation(Index6, 2, ClaimData, References)),
    ?assertMatch({replay, _}, quod_outcome:check_completion(
                               Index6, OperationRef, Digest, Receipt)),
    {ok, ChangedReceipt} = quod_ct:certified_receipt(
                             [setelement(4, TargetRef, <<0:256>>)]),
    ?assertMatch({error, outcome_index_conflict},
                 quod_outcome:check_completion(
                   Index6, OperationRef, Digest, ChangedReceipt)),
    ok = quod_outcome:close(Index6).

same_operation_id_conflicts_across_transaction_and_vote_after_reopen_test() ->
    First = quod_ct:signed_atomic_fixture(#{}),
    {Ns, Anchor} = Target = maps:get(target, First),
    Second = quod_ct:signed_atomic_fixture(
               #{target => Target,
                 key_pair => maps:get(key_pair, First),
                 operation_id => maps:get(operation_id, First),
                 goal_text => <<"assertz(saved(other)).">>}),
    {ok, FirstClaim} = quod_transaction:request_claim(
                         maps:get(transaction, First)),
    SecondMaterial = quod_atomic:control_material(maps:get(vote_control, Second)),
    {_, _, #{group := #{request := #{claim := SecondClaim}}}} = SecondMaterial,
    ?assertEqual(maps:get(key, FirstClaim), maps:get(key, SecondClaim)),
    ?assertNotEqual(maps:get(digest, FirstClaim), maps:get(digest, SecondClaim)),
    FirstRef = {transaction, Ns, Anchor,
                (maps:get(transaction, First))#transaction.tx_id},
    {ok, SecondRef} = quod_atomic:source_group_ref(SecondMaterial),
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

pending_votes_projection_replaces_the_exact_group_snapshot_test() ->
    Ns = <<"quod:pending-reenvelope">>,
    Anchor = <<27:256>>,
    GroupId = <<30:256>>,
    {ok, Index0} = quod_outcome:open(
                     Ns, Anchor, #{outcome_backend => memory}),
    Pending = {group, Ns, Anchor, <<29:256>>, <<28:256>>, GroupId},
    {ok, Index1} = quod_outcome:project_pending_votes(Index0, [Pending]),
    {ok, Index1} = quod_outcome:project_pending_votes(Index1, [Pending]),
    Replacement = setelement(4, Pending, <<32:256>>),
    Other = setelement(6, Pending, <<31:256>>),
    Foreign = setelement(2, Pending, <<"quod:foreign">>),
    {ok, Index2} = quod_outcome:project_pending_votes(
                     Index1, [Replacement, Other, Foreign]),
    ?assertEqual(
       #{GroupId => Replacement, <<31:256>> => Other},
       maps:get(pending_votes, quod_outcome:dtx_state(Index2))),
    ?assertMatch({not_found, _}, quod_outcome:lookup_ref(Index2, Pending)),
    ?assertMatch({{ok, #{status := {pending, pending_vote}}}, _},
                 quod_outcome:lookup_ref(Index2, Replacement)),
    ?assertEqual({error, outcome_index_bad_group},
                 quod_outcome:project_pending_votes(Index2, [Other, Other])),
    {ok, Index3} = quod_outcome:project_pending_votes(Index2, []),
    ?assertEqual(#{}, maps:get(pending_votes, quod_outcome:dtx_state(Index3))),
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

pending_vote_and_abort_reasons_survive_the_ordered_disk_projection_test() ->
    F = certified_group(abort),
    {Ns, Anchor} = maps:get(origin, F),
    Ref = maps:get(group_ref, F),
    Id = maps:get(group_id, F),
    Dir = outcome_dir("atomic-abort"),
    Config = #{data_dir => Dir, outcome_backend => disk},
    try
        {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
        {ok, I1} = quod_outcome:project_pending_votes(I0, [Ref]),
        ?assertEqual({ok, #{status => pending, phase => pending_vote, ref => Ref}},
                     public_group(I1, F)),
        I2 = certified_complete_replay(I1, F),
        ?assertEqual(#{}, maps:get(pending_votes, quod_outcome:dtx_state(I2))),
        {{ok, Stored}, _} = quod_outcome:lookup_group(I2, Id),
        %% Bypass the owner cache to exercise the actual current disk grammar.
        {{ok, Stored}, _} = quod_outcome:lookup_group(I0, Id),
        #{applied := Applied, terminal := Terminal, history := History} = Stored,
        ?assertEqual(maps:get(reasons, F), maps:get(reasons, Applied)),
        ?assertEqual([complete_ref, participant_slots], lists:sort(maps:keys(Terminal))),
        ?assertEqual(maps:get(result_blob, F), maps:get(result, Stored)),
        assert_compact_history(History),
        ExpectedPublic = public_group(I2, F),
        ok = quod_outcome:close(I2),

        {ok, R0} = quod_outcome:open(Ns, Anchor, Config),
        assert_empty_atomic_index(R0, F),
        %% Replay derives the same reasons/result and exact first references;
        %% no retained terminal history can suppress the Resolve effect.
        R1 = certified_complete_replay(R0, F),
        {{ok, Stored}, _} = quod_outcome:lookup_group(R1, Id),
        ?assertEqual(ExpectedPublic, public_group(R1, F)),
        ok = quod_outcome:close(R1)
    after
        _ = file:del_dir_r(Dir)
    end.

commit_result_and_participant_slots_are_published_from_complete_test() ->
    F = certified_group(commit),
    {Ns, Anchor} = maps:get(origin, F),
    {ok, I0} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
    Ref = maps:get(group_ref, F),
    Other = setelement(6, Ref, <<71:256>>),
    {ok, I1} = quod_outcome:project_pending_votes(I0, [Ref, Other]),
    I2 = certified_complete_replay(I1, F),
    ?assertEqual(#{<<71:256>> => Other},
                 maps:get(pending_votes, quod_outcome:dtx_state(I2))),
    ?assertEqual(
       {ok, #{status => committed, height => 3, ref => Ref,
              bindings => [{<<"X">>, linked}],
              participant_slots => maps:get(participant_slots, F)}},
       public_group(I2, F)),
    ok = quod_outcome:close(I2).

own_vote_material_becomes_exact_resolve_state_test_() ->
    [{atom_to_list(Role), fun() ->
        F = certified_group(commit),
        Target = {Ns, Anchor} = maps:get(Role, F),
        Id = maps:get(group_id, F),
        Vote = maps:get(Target, maps:get(votes, F)),
        Resolve = maps:get(Target, maps:get(resolves, F)),
        Material = quod_atomic:control_material(maps:get(control, Vote)),
        {_, _, #{plans := Plans}} = Material,
        ?assertEqual([Target], maps:keys(Plans)),
        {ok, I0} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
        {I1, #{effects := []}, none} = apply_atomic_phase(publish(I0, 1), Vote),
        P1 = outcome_projection(I1),
        ?assertEqual(#{material => Material, ref => maps:get(ref, Vote),
                       resolution => none}, maps:get(Id, maps:get(groups, P1))),
        {I2, #{effects := Effects}, Ack} =
            apply_atomic_phase(publish(I1, 2), Resolve),
        ResolveRef = maps:get(ref, Resolve),
        ?assertEqual([{resolved, Id, commit, Material, ResolveRef, 2}], Effects),
        ?assertEqual({resolve_applied, Id, 3, 2}, Ack),
        ?assertEqual(#{Id => #{slot => 3, generation => 2, blocking => true}},
                     maps:get(apply_fences, outcome_projection(I2))),
        I3 = publish(I2, 3),
        {{ok, Row}, _} = quod_outcome:lookup_group(I3, Id),
        ?assertEqual(#{verdict => commit, resolve_ref => ResolveRef,
                       slot => 3, generation => 2, reasons => none,
                       manifest_digest => quod_dtx:manifest_digest(maps:get(manifest, F)),
                       plan_digest => quod_dtx:digest(maps:get(Target, maps:get(plans, F)))},
                     maps:get(applied, Row)),
        P3 = outcome_projection(I3),
        case Role of
            origin ->
                ?assertMatch(#{Id := #{material := Material, resolution := #{outcome := commit}}},
                             maps:get(groups, P3)),
                ?assertEqual(#{Id => #{slot => 3, generation => 2, blocking => false}},
                             maps:get(apply_fences, P3));
            other ->
                ?assertEqual(#{}, maps:get(groups, P3)),
                ?assertEqual(#{}, maps:get(apply_fences, P3))
        end,
        ?assert(quod_atomic:valid_projection(P3)),
        ok = quod_outcome:close(I3)
      end} || Role <- [origin, other]].

own_plan_and_manifest_survive_commit_abort_disk_replay_test_() ->
    [{atom_to_list(Role) ++ " " ++ atom_to_list(Verdict), fun() ->
        F = certified_group(Verdict),
        Target = {Ns, Anchor} = maps:get(Role, F),
        Id = maps:get(group_id, F),
        Vote = maps:get(Target, maps:get(votes, F)),
        Resolve = maps:get(Target, maps:get(resolves, F)),
        Generation = maps:get(generation, F),
        PlanDigest = quod_dtx:digest(maps:get(Target, maps:get(plans, F))),
        Dir = outcome_dir("atomic-restart"),
        Config = #{data_dir => Dir, outcome_backend => disk},
        try
            {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
            {I1, VoteItem, none} = apply_atomic_phase(publish(I0, 1), Vote),
            {I2, ResolveItem, Ack} = apply_atomic_phase(publish(I1, 2), Resolve),
            ?assertMatch(#{effects := [{resolved, Id, Verdict, _, _, Generation}]}, ResolveItem),
            ?assertEqual({resolve_applied, Id, 3, Generation}, Ack),
            {{ok, Row}, _} = quod_outcome:lookup_group(I2, Id),
            assert_resolve_bindings(Row, F, Resolve, PlanDigest),
            I3 = publish(I2, 3),
            %% I0 has no cached group: equality checks the persisted decoder,
            %% not just the staged owner row used by private-effect recovery.
            {{ok, Row}, _} = quod_outcome:lookup_group(I0, Id),
            ok = quod_outcome:close(I3),

            {ok, R0} = quod_outcome:open(Ns, Anchor, Config),
            ?assertEqual(0, quod_outcome:applied_floor(R0)),
            ?assertMatch({not_found, _}, quod_outcome:lookup_group(R0, Id)),
            {Empty, _} = quod_outcome:group_history(R0, Id),
            ?assertEqual(quod_atomic:initial_group_history(), Empty),
            ?assertEqual(quod_atomic:initial_projection(Target, 0), outcome_projection(R0)),
            {R1, VoteItem, none} = apply_atomic_phase(publish(R0, 1), Vote),
            {R2, ResolveItem, Ack} = apply_atomic_phase(publish(R1, 2), Resolve),
            R3 = publish(R2, 3),
            {{ok, Row}, _} = quod_outcome:lookup_group(R0, Id),
            ?assertEqual(outcome_projection(I3), outcome_projection(R3)),
            ok = quod_outcome:close(R3)
        after
            _ = file:del_dir_r(Dir)
        end
      end} || Role <- [origin, other], Verdict <- [commit, abort]].

unvoted_abort_persists_manifest_without_inventing_own_plan_test() ->
    F = certified_group(abort),
    Target = {Ns, Anchor} = maps:get(other, F),
    Id = maps:get(group_id, F),
    Resolve = certified_unvoted_abort(F),
    Dir = outcome_dir("unvoted-abort-bindings"),
    Config = #{data_dir => Dir, outcome_backend => disk},
    try
        {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
        {I1, Item, Ack} = apply_atomic_phase(publish(publish(I0, 1), 2), Resolve),
        Ref = maps:get(ref, Resolve),
        ?assertMatch(#{effects := [{resolved, Id, abort, none, Ref, 0}]}, Item),
        ?assertEqual({resolve_applied, Id, 3, 0}, Ack),
        {{ok, Row}, _} = quod_outcome:lookup_group(I1, Id),
        assert_resolve_bindings(Row, F, Resolve, none),
        ?assertMatch(#{ref := none, result := none, terminal := none}, Row),
        ?assertEqual([resolve], maps:keys(maps:get(records, maps:get(history, Row)))),
        ?assertEqual(quod_atomic:initial_projection(Target, 0), outcome_projection(I1)),
        I2 = publish(I1, 3),
        {{ok, Row}, _} = quod_outcome:lookup_group(I0, Id),
        ok = quod_outcome:close(I2),

        {ok, R0} = quod_outcome:open(Ns, Anchor, Config),
        ?assertMatch({not_found, _}, quod_outcome:lookup_group(R0, Id)),
        {R1, Item, Ack} = apply_atomic_phase(publish(publish(R0, 1), 2), Resolve),
        R2 = publish(R1, 3),
        {{ok, Row}, _} = quod_outcome:lookup_group(R0, Id),
        ok = quod_outcome:close(R2)
    after
        _ = file:del_dir_r(Dir)
    end.

persisted_resolve_rejects_malformed_manifest_and_plan_digest_types_test_() ->
    [{atom_to_list(Mode) ++ " " ++ atom_to_list(Field), fun() ->
        Verdict = case Mode of commit -> commit; _ -> abort end,
        F = certified_group(Verdict),
        Target = {Ns, Anchor} = maps:get(other, F),
        Id = maps:get(group_id, F),
        Dir = outcome_dir("malformed-resolve-bindings"),
        Config = #{data_dir => Dir, outcome_backend => disk},
        try
            {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
            {Prefix, Resolve, PlanDigest} = case Mode of
                unvoted_abort ->
                    {publish(publish(I0, 1), 2), certified_unvoted_abort(F), none};
                _ ->
                    Vote = maps:get(Target, maps:get(votes, F)),
                    {Voted, _, none} = apply_atomic_phase(publish(I0, 1), Vote),
                    {publish(Voted, 2), maps:get(Target, maps:get(resolves, F)),
                     quod_dtx:digest(maps:get(Target, maps:get(plans, F)))}
            end,
            {I1, _, _} = apply_atomic_phase(Prefix, Resolve),
            _Published = publish(I1, 3),
            {{ok, Row}, _} = quod_outcome:lookup_group(I0, Id),
            assert_resolve_bindings(Row, F, Resolve, PlanDigest),
            Path = filename:join(quod_ledger_store:ns_dir(
                quod_ledger_store:ledger_dir(Config), Ns), "outcomes.dets"),
            Bad = Row#{applied := (maps:get(applied, Row))#{Field := Malformed}},
            ok = dets:insert(Path, {{group, Anchor, Id}, Bad}),
            ok = dets:sync(Path),
            %% The malformed field cannot enter effect reconciliation as a
            %% conflict verdict: the cold reader rejects the whole row.
            ?assertMatch({{error, {outcome_index_io, _}}, _},
                         quod_outcome:lookup_group(I0, Id)),
            ?assertNot(filelib:is_file(Path)),
            {ok, Fresh} = quod_outcome:open(Ns, Anchor, Config),
            ?assertMatch({not_found, _}, quod_outcome:lookup_group(Fresh, Id)),
            ok = quod_outcome:close(Fresh)
        after
            _ = file:del_dir_r(Dir)
        end
      end} || Mode <- [commit, abort, unvoted_abort],
               {Field, Malformed} <- [{manifest_digest, <<"short">>},
                                      {plan_digest, #{digest => <<99:256>>}}]].

different_valid_resolve_quorums_publish_complete_test_() ->
    [{atom_to_list(Backend) ++ " " ++ atom_to_list(Verdict), fun() ->
        F = certified_group(Verdict),
        {Ns, Anchor} = maps:get(origin, F),
        Dir = outcome_dir("equivalent-quorums"),
        Config = #{data_dir => Dir, outcome_backend => Backend},
        try
            {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
            I1 = certified_complete_replay(I0, F),
            ok = quod_outcome:close(I1),
            case Backend of
                disk ->
                    {ok, R0} = quod_outcome:open(Ns, Anchor, Config),
                    assert_empty_atomic_index(R0, F),
                    R1 = certified_complete_replay(R0, F),
                    ok = quod_outcome:close(R1);
                memory -> ok
            end
        after
            _ = file:del_dir_r(Dir)
        end
      end} || Backend <- [memory, disk], Verdict <- [commit, abort]].

remote_resolve_accepts_another_valid_vote_quorum_test_() ->
    [{atom_to_list(Verdict), fun() ->
        F = certified_group(Verdict),
        Target = {Ns, Anchor} = maps:get(other, F),
        Vote = maps:get(Target, maps:get(votes, F)),
        Resolve = maps:get(Target, maps:get(resolves, F)),
        Id = maps:get(group_id, F),
        Generation = maps:get(generation, F),
        {ok, I0} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
        {I1, _, none} = apply_atomic_phase(publish(I0, 1), alternate_phase(Vote)),
        I2 = publish(I1, 2),
        {H1, _} = quod_outcome:group_history(I2, Id),
        {I3, _, Ack} = apply_atomic_phase(I2, Resolve),
        ?assertEqual({resolve_applied, Id, 3, Generation}, Ack),
        {{ok, Row}, _} = quod_outcome:lookup_group(I3, Id),
        ?assertMatch(#{verdict := Verdict, generation := Generation}, maps:get(applied, Row)),
        %% A different valid QC does not relax the exact own-plan generation.
        Wrong = setelement(10, quod_atomic:control_body(maps:get(control, Resolve)),
                           Generation + 1),
        Bad = certified_phase(Target, signed_control(Target, Wrong, 2, F), 3,
                              maps:get(signers, F)),
        ?assertEqual({error, {invalid_transition, participant_phase}},
                     reduce_phase(Bad, H1, outcome_projection(I2))),
        ok = quod_outcome:close(I3)
      end} || Verdict <- [commit, abort]].

vote_material_and_certified_reference_pins_are_not_relaxed_by_quorum_equivalence_test() ->
    F = certified_group(commit),
    Target = maps:get(other, F),
    Phase = maps:get(Target, maps:get(votes, F)),
    Control = maps:get(control, Phase),
    Ref = maps:get(ref, Phase),
    {ok, Wire} = quod_atomic:encode_control(Control),
    {ok, Decoded} = quod_atomic:decode_control(Wire),
    ?assertEqual(quod_atomic:control_material(Control), quod_atomic:control_material(Decoded)),
    lists:foreach(fun(BadRef) ->
        ?assertNot(quod_dtx:certified_entry_claim_matches(
                     Target, maps:get(entry, Phase), Control, BadRef))
    end, changed_reference_claims(Ref)),
    {quod_dtx_vote, 4, Group, Target, Bundle, prepared} = quod_atomic:control_body(Control),
    BadBundles = [setelement(1, Bundle, maps:get(origin, F)),
                  setelement(2, Bundle, <<99:256>>),
                  setelement(3, Bundle, <<"different">>),
                  setelement(4, Bundle, maps:get(maps:get(origin, F), maps:get(attestations, F)))],
    [?assertEqual({error, invalid_record},
                   quod_atomic:new_vote(Group, Target, Bad, prepared)) || Bad <- BadBundles],
    %% The signed manifest/result and own plan remain pinned at the codec
    %% boundary; apply_dtx/2 is deliberately not a second authenticator.
    {ok, OtherResult} = quod_durable_term:encode_result(#{'X' => changed}),
    BadManifest = setelement(10, setelement(9, maps:get(manifest, F), OtherResult),
                             crypto:hash(sha256, OtherResult)),
    ?assertMatch({ok, _}, quod_dtx:manifest_binding(BadManifest)),
    BadGroup = setelement(3, Group, BadManifest),
    ?assertEqual({error, invalid_record},
                 quod_atomic:new_vote(BadGroup, Target, Bundle, prepared)).

equivalent_quorums_preserve_first_outcome_history_and_reject_changed_vote_test() ->
    F = certified_group(commit),
    Target = {Ns, Anchor} = maps:get(origin, F),
    Id = maps:get(group_id, F),
    Vote = maps:get(Target, maps:get(votes, F)),
    {ok, I0} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
    I1 = certified_complete_replay(I0, F),
    {History, _} = quod_outcome:group_history(I1, Id),
    {{ok, Row}, _} = quod_outcome:lookup_group(I1, Id),
    {I2, #{history := History, effects := []}, none} =
        apply_atomic_phase(I1, alternate_phase(Vote)),
    {{ok, Row}, _} = quod_outcome:lookup_group(I2, Id),
    Resolve = maps:get(Target, maps:get(resolves, F)),
    ChangedGeneration = setelement(
                          10, quod_atomic:control_body(maps:get(control, Resolve)), 3),
    ConflictingResolve = certified_phase(
                           Target, signed_control(Target, ChangedGeneration, 4, F),
                           5, maps:get(signers, F)),
    ?assertEqual({error, {invalid_transition, semantic_conflict}},
                 reduce_phase(ConflictingResolve, History, outcome_projection(I2))),
    {quod_dtx_vote, 4, Group, Target, Bundle, prepared} =
        quod_atomic:control_body(maps:get(control, Vote)),
    {ok, Negative} = quod_atomic:new_vote(Group, Target, Bundle, {refused, [vote_deadline]}),
    Conflicting = certified_phase(Target, signed_control(Target, Negative, 4, F), 5,
                                  maps:get(signers, F)),
    ?assertEqual({error, {invalid_transition, semantic_conflict}},
                 reduce_phase(Conflicting, History, outcome_projection(I2))),
    {{ok, Row}, _} = quod_outcome:lookup_group(I2, Id),
    ?assertEqual(public_group(I1, F), public_group(I2, F)),
    ok = quod_outcome:close(I2).

phase_index_and_outcome_retain_the_same_first_atomic_references_test() ->
    F = certified_group(commit),
    Target = {Ns, Anchor} = maps:get(origin, F),
    Id = maps:get(group_id, F),
    Dir = outcome_dir("atomic-phase-index"),
    try
        {ok, PhaseIndex} = quod_dtx_phase_index:open(Dir, Ns),
        {ok, I0} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
        try
            Vote = maps:get(Target, maps:get(votes, F)),
            Resolve = alternate_phase(maps:get(Target, maps:get(resolves, F))),
            Complete = maps:get(complete, F),
            I1 = lists:foldl(fun(Phase, Index) ->
                #{control := Control, ref := Ref} = Phase,
                {ok, _P, [Item]} = quod_dtx_phase_index:apply_batch(
                    PhaseIndex, [{Control, Ref}], outcome_projection(Index)),
                {ok, Next, _Ack} = quod_outcome:apply_dtx(Index, Item),
                {ok, History} = quod_dtx_phase_index:history(PhaseIndex, Id),
                {History, _} = quod_outcome:group_history(Next, Id),
                publish(Next, ref_slot(Ref))
            end, publish(I0, 1), [Vote, Resolve, Complete]),
            {ok, History} = quod_dtx_phase_index:history(PhaseIndex, Id),
            {ok, Capture} = quod_dtx_phase_index:capture(PhaseIndex, 2),
            {ok, #{records := Captured}} = quod_dtx_phase_index:history(Capture, Id),
            ?assertEqual([vote], maps:keys(Captured)),
            #{control := C, ref := R} = alternate_phase(Vote),
            {ok, P, [#{history := History, effects := []} = Duplicate]} =
                quod_dtx_phase_index:apply_batch(
                  PhaseIndex, [{C, R}], outcome_projection(I1)),
            ?assertEqual(outcome_projection(I1), P),
            {ok, I2, none} = quod_outcome:apply_dtx(I1, Duplicate),
            {History, _} = quod_outcome:group_history(I2, Id),
            assert_compact_history(History),
            ok = quod_outcome:close(I2)
        after
            ok = quod_dtx_phase_index:close(PhaseIndex)
        end
    after
        _ = file:del_dir_r(Dir)
    end.

stored_source_height_must_match_its_exact_resolve_reference_test() ->
    F = certified_group(commit),
    {Ns, Anchor} = maps:get(origin, F),
    Id = maps:get(group_id, F),
    Dir = outcome_dir("stored-source-height"),
    Config = #{data_dir => Dir, outcome_backend => disk},
    try
        {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
        I1 = certified_complete_replay(I0, F),
        {{ok, Row}, _} = quod_outcome:lookup_group(I1, Id),
        Path = filename:join(quod_ledger_store:ns_dir(
                               quod_ledger_store:ledger_dir(Config), Ns), "outcomes.dets"),
        %% Complete is at 4, but public/stored source height must remain the
        %% Resolve's 3. A syntactically positive replacement is still corrupt.
        Bad = Row#{applied := (maps:get(applied, Row))#{slot := 4}},
        ok = dets:insert(Path, {{group, Anchor, Id}, Bad}),
        ok = dets:sync(Path),
        ?assertMatch({{error, {outcome_index_io, _}}, _},
                     quod_outcome:lookup_group(I0, Id)),
        ?assertNot(filelib:is_file(Path)),
        {ok, Fresh} = quod_outcome:open(Ns, Anchor, Config),
        assert_empty_atomic_index(Fresh, F),
        ok = quod_outcome:close(Fresh)
    after
        _ = file:del_dir_r(Dir)
    end.

public_group_grammar_checks_phases_results_reasons_and_participant_slots_test() ->
    Ref = {group, <<"quod:grammar">>, <<1:256>>, <<2:256>>, <<3:256>>, <<4:256>>},
    Public = fun(Status) -> quod_outcome:public(#{type => group, ref => Ref, status => Status}) end,
    [?assertEqual({ok, #{status => pending, phase => Phase, ref => Ref}},
                  Public({pending, Phase})) ||
        Phase <- [pending_vote, voted, resolving_commit, resolving_abort, publication]],
    {ok, Result} = quod_durable_term:encode_result(#{'X' => linked}),
    Slots = [{{<<"quod:a">>, <<1:256>>}, 3, 2}, {{<<"quod:b">>, <<2:256>>}, 7, 0}],
    ?assertMatch({ok, #{status := committed, height := 3, bindings := [{<<"X">>, linked}]}},
                 Public({committed, 3, Result, Slots})),
    ?assertMatch({ok, #{status := aborted, reasons := [vote_deadline]}},
                 Public({aborted, 3, [vote_deadline], Slots})),
    BadStatuses = [{pending, unknown_phase}, {committed, 0, Result, Slots},
                   {committed, 3, <<"corrupt-result">>, Slots},
                   {aborted, 3, [], Slots}, {aborted, 3, <<"not-reasons">>, Slots}],
    [?assertEqual({error, outcome_index_corrupt}, Public(Status)) || Status <- BadStatuses],
    BadSlots = [[], [hd(Slots)], lists:reverse(Slots), [hd(Slots), hd(Slots)],
                [setelement(2, hd(Slots), 0), lists:last(Slots)],
                [setelement(3, hd(Slots), -1), lists:last(Slots)]],
    lists:foreach(fun(S) ->
        ?assertEqual({error, outcome_index_corrupt}, Public({committed, 3, Result, S})),
        ?assertEqual({error, outcome_index_corrupt}, Public({aborted, 3, [vote_deadline], S}))
    end, BadSlots).

applied_floor_is_ordered_idempotent_and_only_published_by_flush_test() ->
    {ok, I0} = quod_outcome:open(<<"quod:ordered-floor">>, <<1:256>>,
                                #{outcome_backend => memory}),
    ?assertEqual({error, outcome_index_gap}, quod_outcome:advance_applied(I0, 2)),
    {ok, I1} = quod_outcome:advance_applied(I0, 1),
    ?assertEqual(0, quod_outcome:applied_floor(I1)),
    ?assertEqual({ok, I1}, quod_outcome:advance_applied(I1, 1)),
    ?assertEqual({ok, I1}, quod_outcome:advance_applied(I1, 0)),
    {ok, I2} = quod_outcome:flush(I1),
    ?assertEqual(1, quod_outcome:applied_floor(I2)),
    [?assertEqual({error, outcome_index_gap}, quod_outcome:advance_applied(I2, H)) ||
        H <- [-1, 3, 16#10000000000000000]],
    ok = quod_outcome:close(I2).

%% Retired shape-only obligations are covered more strongly in
%% quod_atomic_projection_tests:
%% source_and_target_use_the_same_vote_and_resolve_transition_test/0 and
%% outcome_disk_replay_rebuilds_own_projection_and_retains_tombstones_test/0.
%% Recognized old outcome bytes are refused unchanged, not reset; see
%% quod_atomic_format_tests:real_v7_outcome_index_is_named_and_unchanged_test/0.

certified_complete_replay(I0, F) ->
    Origin = maps:get(origin, F),
    Id = maps:get(group_id, F),
    Ref = maps:get(group_ref, F),
    Vote = maps:get(Origin, maps:get(votes, F)),
    Resolve = maps:get(Origin, maps:get(resolves, F)),
    Generation = maps:get(generation, F),
    Verdict = maps:get(verdict, F),
    {I1, #{effects := []}, none} = apply_atomic_phase(publish(I0, 1), Vote),
    ?assertEqual({ok, #{status => pending, phase => voted, ref => Ref}}, public_group(I1, F)),
    {I2, #{effects := Effects}, Ack} =
        apply_atomic_phase(publish(I1, 2), alternate_phase(Resolve)),
    ?assertEqual([{resolved, Id, Verdict,
                  quod_atomic:control_material(maps:get(control, Vote)),
                  maps:get(alternate_ref, Resolve), Generation}], Effects),
    ?assertEqual({resolve_applied, Id, 3, Generation}, Ack),
    Phase = case Verdict of commit -> resolving_commit; abort -> resolving_abort end,
    ?assertEqual({ok, #{status => pending, phase => Phase, ref => Ref}}, public_group(I2, F)),
    I3 = publish(I2, 3),
    {I4, _, none} = apply_atomic_phase(I3, maps:get(complete, F)),
    ?assertEqual({ok, #{status => pending, phase => publication, ref => Ref}}, public_group(I4, F)),
    {ok, I5} = quod_outcome:advance_applied(I4, 4),
    ?assertEqual(3, quod_outcome:applied_floor(I5)),
    ?assertEqual(public_group(I4, F), public_group(I5, F)),
    {ok, I6} = quod_outcome:flush(I5),
    ?assertEqual(4, quod_outcome:applied_floor(I6)),
    {ok, Public} = public_group(I6, F),
    ?assertEqual(3, maps:get(height, Public)),
    ?assertEqual(maps:get(participant_slots, F), maps:get(participant_slots, Public)),
    case Verdict of
        commit -> ?assertMatch(#{status := committed, bindings := [{<<"X">>, linked}]}, Public);
        abort ->
            ?assertEqual(aborted, maps:get(status, Public)),
            ?assertEqual(maps:get(reasons, F), maps:get(reasons, Public))
    end,
    {History, _} = quod_outcome:group_history(I6, Id),
    ?assertEqual({ok, maps:get(alternate_ref, Resolve)}, quod_atomic:history_phase(resolve, History)),
    %% Complete refers to the other valid Resolve quorum. A late duplicate
    %% retains the first bytes and cannot resurrect an acknowledged fence.
    {I7, #{history := History, effects := []}, none} = apply_atomic_phase(I6, Resolve),
    ?assertEqual(#{}, maps:get(apply_fences, outcome_projection(I7))),
    ?assertEqual(public_group(I6, F), public_group(I7, F)),
    I7.

assert_empty_atomic_index(Index, F) ->
    ?assertEqual(0, quod_outcome:applied_floor(Index)),
    ?assertEqual(#{}, maps:get(pending_votes, quod_outcome:dtx_state(Index))),
    ?assertEqual(quod_atomic:initial_projection(maps:get(origin, F), 0),
                 outcome_projection(Index)),
    Id = maps:get(group_id, F),
    ?assertMatch({not_found, _}, quod_outcome:lookup_group(Index, Id)),
    {History, _} = quod_outcome:group_history(Index, Id),
    ?assertEqual(quod_atomic:initial_group_history(), History).

assert_compact_history(#{records := Records} = History) ->
    ?assert(quod_atomic:valid_group_history(History)),
    ?assertEqual([complete, resolve, vote], lists:sort(maps:keys(Records))),
    [?assertEqual([digest, ref], lists:sort(maps:keys(Row))) || Row <- maps:values(Records)].

assert_resolve_bindings(Row, F, #{control := Control, ref := Ref}, PlanDigest) ->
    {quod_dtx_resolve, 4, Id, Target, ManifestDigest, Verdict,
     _, _, _, Generation, ReasonsBlob} = quod_atomic:control_body(Control),
    ?assertEqual(maps:get(group_id, F), Id),
    ?assertEqual(quod_atomic:control_target(Control), Target),
    ?assertEqual(quod_dtx:manifest_digest(maps:get(manifest, F)), ManifestDigest),
    Reasons = case Verdict of
        commit -> none;
        abort ->
            {ok, Decoded} = quod_wire_term:decode_failure_reasons(ReasonsBlob),
            Decoded
    end,
    ?assertEqual(#{verdict => Verdict, resolve_ref => Ref,
                   slot => ref_slot(Ref), generation => Generation, reasons => Reasons,
                   manifest_digest => ManifestDigest, plan_digest => PlanDigest},
                 maps:get(applied, Row)).

certified_unvoted_abort(F) ->
    Group = maps:get(group, F),
    Origin = maps:get(origin, F),
    Target = maps:get(other, F),
    Reasons = [vote_deadline],
    {ok, Negative} = quod_atomic:new_vote(Group, Origin, none, {refused, Reasons}),
    Vote = certified_phase(Origin, signed_control(Origin, Negative, 1, F),
                           2, maps:get(signers, F)),
    Ref = maps:get(ref, Vote),
    {ok, Resolve} = quod_atomic:new_resolve(
                      Group, Ref, Target, {abort, Reasons}, {refused, Ref}, none, 0),
    checked_phase(certified_phase(Target, signed_control(Target, Resolve, 2, F),
                                  3, maps:get(signers, F)), [Vote]).

%% Certified control/index fixtures, not full founding, consensus admission
%% or MVCC application witnesses. All entries use native control objects;
%% foreign reference bindings and both 3-of-4 QC subsets are checked explicitly.
certified_group(Verdict) ->
    Base = quod_ct:signed_atomic_fixture(#{}),
    [?assertEqual(1, quod_dtx:overlay_generation(P)) || P <- maps:values(maps:get(plans, Base))],
    Origin = {Ns, Anchor} = maps:get(origin, Base),
    [Other] = maps:get(participant_targets, Base) -- [Origin],
    Signer = maps:get(node_identity, Base),
    {ok, Result} = quod_durable_term:encode_result(#{'X' => linked}),
    {ok, Manifest} = quod_dtx:new_manifest(
        #{proof_id => maps:get(proof_id, Base),
          coordinator => {Ns, Anchor, maps:get(pubkey, Signer), maps:get(admission, Base)},
          nonce => <<207:256>>, principal => maps:get(principal, Base),
          goal => maps:get(goal_blob, Base), result => Result,
          request_binding => maps:get(binding, Base),
          vote_deadline_ms => maps:get(deadline, Base),
          participants => [{T, D} || {T, D, _, _} <- maps:get(bundles, Base)]}),
    Bundles = [begin
        {ok, A} = quod_dtx:attest_plan(1, T, maps:get(T, maps:get(plans, Base)), Manifest, Signer),
        {T, D, B, A}
    end || {T, D, B, _} <- maps:get(bundles, Base)],
    Attestations = maps:from_list([{T, A} || {T, _, _, A} <- Bundles]),
    {ok, Group} = quod_atomic:new_group(Manifest, maps:get(auth, Base), maps:get(Origin, Attestations)),
    Id = quod_atomic:group_id(Group),
    {ok, GroupRef} = quod_dtx:manifest_group_ref(Manifest, Id),
    Signers = [Signer | [new_signer() || _ <- lists:seq(1, 3)]],
    Reasons = [{vote_refused, {ontology, element(1, Other), element(2, Other)}},
               {goal, {cannot_link, bob, tom}}],
    Generation = case Verdict of commit -> 2; abort -> 1 end,
    F = Base#{manifest := Manifest, group := Group, bundles := Bundles,
              attestations := Attestations, result_blob := Result,
              other => Other, group_id => Id, group_ref => GroupRef,
              signers => Signers, verdict => Verdict, reasons => Reasons,
              generation => Generation},
    Votes = maps:from_list([begin
        Choice = case {Verdict, T} of {abort, Other} -> {refused, Reasons}; _ -> prepared end,
        {ok, V} = quod_atomic:new_vote(Group, T, lists:keyfind(T, 1, Bundles), Choice),
        {T, certified_phase(T, signed_control(T, V, 1, F), 2, Signers)}
    end || T <- maps:get(participant_targets, F)]),
    SourceRef = maps:get(ref, maps:get(Origin, Votes)),
    Evidence = case Verdict of
        commit -> {all_prepared, lists:sort([{T, maps:get(ref, V)} || {T, V} <- maps:to_list(Votes)])};
        abort -> {refused, maps:get(ref, maps:get(Other, Votes))}
    end,
    ResultChoice = case Verdict of commit -> commit; abort -> {abort, Reasons} end,
    Resolves = maps:from_list([begin
        {ok, R} = quod_atomic:new_resolve(Group, SourceRef, T, ResultChoice, Evidence,
                                         maps:get(ref, maps:get(T, Votes)), Generation),
        Phase = certified_phase(T, signed_control(T, R, 2, F), 3, Signers),
        {T, checked_phase(Phase, maps:values(Votes))}
    end || T <- maps:get(participant_targets, F)]),
    Rows = lists:sort([{T, maps:get(ref, R), Generation} || {T, R} <- maps:to_list(Resolves)]),
    Applied = [{Other, applied_certificate(F, maps:get(Other, Resolves))}],
    {ok, C} = quod_atomic:new_complete(Group, Verdict, Rows, Applied),
    Complete = checked_phase(certified_phase(Origin, signed_control(Origin, C, 3, F), 4, Signers),
                             maps:values(Resolves)),
    F#{votes => Votes, resolves => Resolves, complete => Complete,
       participant_slots => [{T, ref_slot(R), G} || {T, R, G} <- Rows]}.

applied_certificate(F, #{ref := Ref, control := Control, entry := Entry, committee := Committee}) ->
    {ok, Target, _, _} = quod_dtx:certified_ref_binding(Ref),
    Network = maps:get(network, F),
    CommitteeId = <<88:256>>,
    Id = maps:get(group_id, F),
    Generation = maps:get(generation, F),
    Verdict = maps:get(verdict, F),
    Votes = [begin
        {ok, V} = quod_applied_certificate:sign_applied_vote(
                    Network, Target, CommitteeId, Id, Ref, Generation, Verdict, S),
        V
    end || S <- lists:sublist(maps:get(signers, F),
                              quod_quorum:honest_threshold(length(Committee)))],
    {ok, Certificate} = quod_applied_certificate:applied_certificate(
        {Network, Target, CommitteeId, Id, Ref, Generation, Verdict}, lists:sort(Votes)),
    ?assert(quod_applied_certificate:verify_applied_certificate(
              Certificate, Network, #{identity => Target, phase => resolve,
                control => Control, entry => Entry, committee => Committee,
                committee_id => CommitteeId})),
    Certificate.

checked_phase(#{control := Control} = Phase, Evidence) ->
    Required = quod_atomic:reference_requirements(Control),
    Rows = [begin
        [C] = [EC || #{control := EC, ref := R} <- Evidence, quod_dtx:same_certified_ref(R, Ref)],
        {Kind, Ref, quod_atomic:control_material(C)}
    end || {Kind, Ref} <- Required],
    ok = quod_atomic:validate_references(Control, Rows),
    Phase.

signed_control(Target, Record, Sequence, F) ->
    {ok, Material} = quod_atomic:admission_material(Record),
    {ok, Control} = quod_atomic:sign_control(Target, Material, maps:get(admission, F),
                                            Sequence, Sequence, maps:get(node_identity, F)),
    Control.

certified_phase(Target = {Ns, Anchor}, Control, Slot, Signers) ->
    Era = quod_ledger:initial_era(Target),
    Position = {Era, Slot - 1},
    %% Reducer fixture, not a complete source history. The quorum signatures
    %% below authenticate the same exact block under independent signer sets.
    {ok, Block} = quod_ledger:new_block(Position, {Era, Slot - 2, <<0:256>>},
                                      {batch, [{dtx, Control}]}, Slot),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Hash = quod_simplex:block_hash(Block),
    Committee = lists:sort([maps:get(pubkey, S) || S <- Signers]),
    Shares = maps:from_list([{maps:get(pubkey, S),
               quod_simplex:make_share(Domain, commit, Position, Hash, S)} || S <- Signers]),
    [A, B, C, D] = Committee,
    Make = fun(Keys) ->
        {ok, Cert} = quod_simplex:form_cert(Domain, commit, Position, Hash,
                       [maps:get(K, Shares) || K <- Keys], Committee),
        ?assert(quod_simplex:verify_cert(Domain, Cert, Committee)),
        Entry = quod_ledger:entry(Slot, Block, Cert),
        {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Control),
        {Entry, Ref}
    end,
    {Entry, Ref} = Make([A, B, C]),
    {OtherEntry, OtherRef} = Make([B, C, D]),
    ?assertNotEqual(Ref, OtherRef),
    ?assert(quod_dtx:same_certified_ref(Ref, OtherRef)),
    ?assert(quod_dtx:certified_entry_claim_matches(Target, Entry, Control, OtherRef)),
    ?assert(quod_dtx:certified_entry_claim_matches(Target, OtherEntry, Control, Ref)),
    #{control => Control, entry => Entry, ref => Ref, alternate_ref => OtherRef,
      committee => Committee}.

new_signer() ->
    {Pub, Seed} = quod_identity:generate(),
    #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}.

alternate_phase(Phase) -> Phase#{ref := maps:get(alternate_ref, Phase)}.

changed_reference_claims(Ref) ->
    [setelement(3, Ref, <<"quod:another-identity">>),
     setelement(4, Ref, <<91:256>>), setelement(5, Ref, ref_slot(Ref) + 1),
     setelement(6, Ref, <<92:256>>), setelement(7, Ref, <<93:256>>)].

%% Consume native reducer items, never synthesize old-format adapter inputs.
apply_atomic_phase(Index, #{control := Control, ref := Ref}) ->
    Id = quod_atomic:group_id(Control),
    {History, I1} = quod_outcome:group_history(Index, Id),
    {ok, _, _, [Item]} = quod_atomic:reduce_batch(
        [{Control, Ref}], #{Id => History}, outcome_projection(I1)),
    {ok, I2, Ack} = quod_outcome:apply_dtx(I1, Item),
    {I2, Item, Ack}.

reduce_phase(#{control := Control, ref := Ref}, History, Projection) ->
    quod_atomic:reduce(Control, Ref, History, Projection).

outcome_projection(Index) -> maps:get(projection, quod_outcome:dtx_state(Index)).

publish(Index, Slot) ->
    {ok, I1} = quod_outcome:advance_applied(Index, Slot),
    {ok, I2} = quod_outcome:flush(I1),
    I2.

public_group(Index, F) ->
    {{ok, Row}, _} = quod_outcome:lookup_ref(Index, maps:get(group_ref, F)),
    quod_outcome:public(Row).

ref_slot(Ref) ->
    {ok, _, Slot, _} = quod_dtx:certified_ref_binding(Ref),
    Slot.

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

agent_ref(Ns, Anchor, N) ->
    {ok, #{blob := Blob}} = quod_agent_ref:from_text(
                              Ns, Anchor,
                              <<"human_user(", (integer_to_binary(N))/binary,
                                ").">>,
                              2),
    Blob.
