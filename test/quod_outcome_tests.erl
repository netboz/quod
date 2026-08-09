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
