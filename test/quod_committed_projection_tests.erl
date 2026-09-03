-module(quod_committed_projection_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-import(quod_ct, [change/3, diff_for/1]).

mixed_content_duplicate_rejection_and_noop_projection_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"projection:",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Anchor = <<0:256>>,
    {ok, Outcomes} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
    Projection0 = quod_committed_projection:new(
                    {Ns, Anchor}, 0,
                    quod_committed_projection:new_est(), Outcomes, none),
    {Author, Seed} = crypto:generate_key(eddsa, ed25519, <<42:256>>),
    Signer = #{pubkey => Author,
               key => quod_identity:key_term({Author, Seed})},
    Self = <<0:256>>,
    HostPolicy = quod_simplex:test_genesis_tx(
                   #{node_id => Self, mode => create, committee => [],
                     genesis_diff =>
                         diff_for(
                           {can_invoke, {'Goal'}, {'Principal'}, [],
                            {'Namespace'}})},
                   Ns, Self, <<1:256>>),
    FactTx = signed_change(
               {Ns, Anchor},
               change(Ns, diff_for({projection_fact, one}), #{}), Signer),
    ConflictTx = signed_change(
                   {Ns, Anchor},
                   change(
                     Ns, diff_for({must_not_land, true}),
                     #{{projection_fact, 1} => never_present}), Signer),
    Effect = {quod_direct_effect, 2, local_durable,
              ontology_lifecycle, create,
              crypto:hash(sha256, <<"projection-effect-id">>), Author,
              {node, Author},
              {<<"projection:effect-target">>,
               crypto:hash(sha256, <<"projection-effect-anchor">>)},
              crypto:hash(sha256, <<"projection-effect-request">>),
              crypto:hash(sha256, <<"projection-effect-prepared">>)},
    {ok, EffectGoal} = quod_durable_term:encode_goal(
                         {create_ontology,
                          <<"projection:effect-target">>, []}),
    {ok, EffectResult} = quod_durable_term:encode_result(#{}),
    EffectTx = signed_change(
                 {Ns, Anchor},
                 #transaction{
                    tx_id = <<>>, origin = {Ns, Anchor},
                    proof_id = crypto:hash(
                                 sha256, <<"projection-effect-proof">>),
                    plan_digest = crypto:hash(
                                    sha256, <<"projection-effect-plan">>),
                    goal = EffectGoal, result = EffectResult,
                    diff = [], read_check = #{}, effects = [Effect],
                    author = Author, author_seq = 1, submitted_at = 1,
                    sig = none}, Signer),
    EventTx = signed_change(
                {Ns, Anchor}, change(Ns, [{event, {alarm, disk}}], #{}),
                Signer),
    try
        {ok, Projection1,
         #{kind := content,
           transactions := [#{status := applied}]}} =
            project(1, {batch, [HostPolicy]}, Projection0),
        ?assertEqual(true, proves({can_invoke, anything, anonymous, [], Ns},
                                  Projection1)),

        {ok, Projection2,
         #{kind := content,
           transactions := [#{status := applied,
                              applied_ops := [_],
                              changed_heads := [{projection_fact, one}]}]}} =
            project(2, {batch, [FactTx]}, Projection1),
        ?assertEqual(true, proves({projection_fact, one}, Projection2)),

        {ok, Projection3,
         #{kind := content,
           transactions := [#{status := duplicate_committed,
                              applied_ops := []}]}} =
            project(3, {batch, [FactTx]}, Projection2),
        ?assertEqual(true, proves({projection_fact, one}, Projection3)),

        {ok, Projection4,
         #{kind := content,
           transactions := [#{status := rejected,
                              reason := conflict_retry,
                              applied_ops := []}],
           stats := #{conflicts := 1, rejects := 1}}} =
            project(4, {batch, [ConflictTx]}, Projection3),
        ?assertEqual(false, proves({must_not_land, true}, Projection4)),

        {ok, Projection5,
         #{kind := content,
           transactions := [#{status := applied, diff := [],
                              applied_ops := [], changed_heads := []}]}} =
            project(5, {batch, [EffectTx]}, Projection4),
        {ok, Projection6,
         #{kind := content,
           transactions := [#{status := applied,
                              applied_ops := [{event, {alarm, disk}}],
                              changed_heads := []}]}} =
            project(6, {batch, [EventTx]}, Projection5),
        ?assertEqual(false, proves({alarm, disk}, Projection6)),
        {ok, Projection7, #{kind := noop}} =
            project(7, noop, Projection6),
        ?assertEqual(7, quod_committed_projection:applied(Projection7)),
        ?assertEqual(7, quod_outcome:applied_floor(
                          quod_committed_projection:outcomes(Projection7)))
    after
        #est{db = #db{ref = Ref}} = quod_committed_projection:est(Projection0),
        quod_erlog_db_mvcc:delete(Ref),
        ok = quod_outcome:close(Outcomes)
    end.

direct_abort_dtx_uses_the_same_ordered_projection_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"projection-dtx:",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Anchor = <<0:256>>,
    Target = {Ns, Anchor},
    {Pubkey, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pubkey,
               key => quod_identity:key_term({Pubkey, Seed})},
    Admission = Pubkey,
    HostDiff =
        diff_for({can_invoke, {'Goal'}, {'Principal'}, [], {'Namespace'}}),
    %% Membership is the one deliberate OCC exception: consensus already
    %% validated it against its parent and both local and foreign projections
    %% must apply it even when an ordinary transaction would conflict here.
    Host = quod_simplex:test_genesis_tx(
             #{node_id => Pubkey, mode => create, committee => [],
               node_addr => {"127.0.0.1", 14567},
               genesis_diff => HostDiff},
             Ns, Pubkey, <<90:256>>),
    GroupId = <<92:256>>,
    {ok, DecisionRef} = quod_dtx:certified_ref(
                          <<"projection-origin">>, <<93:256>>, 1,
                          <<94:256>>, <<95:256>>, <<"decision-qc">>),
    {ok, Finalize} = quod_dtx:new_finalize(
                       GroupId, DecisionRef, abort, none, 0),
    {ok, Control} = quod_dtx:sign_control(
                      Target, Finalize, Admission, 1, 1, Signer),
    GroupId2 = <<96:256>>,
    {ok, DecisionRef2} = quod_dtx:certified_ref(
                           <<"projection-origin-2">>, <<97:256>>, 1,
                           <<98:256>>, <<99:256>>, <<"decision-qc-2">>),
    {ok, Finalize2} = quod_dtx:new_finalize(
                        GroupId2, DecisionRef2, abort, none, 0),
    {ok, Control2} = quod_dtx:sign_control(
                       Target, Finalize2, Admission, 2, 2, Signer),
    Ops1 = [{assert, {{group_one_fact, one}, {[], false}}}],
    Ops2 = [{event, {group_two_event, two}}],
    Item1 = quod_committed_projection:test_publication_item(
              Control, {group_applied, GroupId, one}, Ops1, none,
              #{applies => 1, rejects => 0, conflicts => 0}),
    Item2 = quod_committed_projection:test_publication_item(
              Control2, {group_applied, GroupId2, two}, Ops2,
              {finalize_applied, GroupId2, 2, 0},
              #{applies => 1, rejects => 0, conflicts => 0}),
    ?assertEqual(Ops1, maps:get(applied_ops, Item1)),
    ?assertEqual([{group_one_fact, one}], maps:get(changed_heads, Item1)),
    ?assertEqual(Ops2, maps:get(applied_ops, Item2)),
    ?assertEqual([], maps:get(changed_heads, Item2)),
    ?assertEqual(GroupId, maps:get(group_id, Item1)),
    ?assertEqual(GroupId2, maps:get(group_id, Item2)),
    {ok, Outcomes} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
    Projection0 = quod_committed_projection:new(
                    Target, 0, quod_committed_projection:new_est(),
                    Outcomes, Signer),
    try
        {ok, Projection1, #{kind := content}} =
            project(1, {batch, [Host]}, Projection0),
        ?assertEqual(
           true,
           proves({peer_admitted, Pubkey, "127.0.0.1", 14567, Pubkey},
                  Projection1)),
        Entry = dtx_entry(2, [Control, Control2]),
        {ok, Projection2,
         #{kind := dtx_batch, controls := [Control, Control2], publications := [],
           items := BatchItems, applied_ops := [],
           deferred_acks :=
             [{finalize_applied, GroupId, 2, 0},
              {finalize_applied, GroupId2, 2, 0}]}} =
            quod_committed_projection:apply_entry(Entry, 2, Projection1),
        ?assertEqual([GroupId, GroupId2],
                     [maps:get(group_id, Item) || Item <- BatchItems]),
        ?assertEqual([Control, Control2],
                     [maps:get(control, Item) || Item <- BatchItems]),
        ?assertEqual(2, quod_committed_projection:applied(Projection2)),
        ?assertEqual(#{},
                     maps:get(apply_fences,
                              maps:get(projection,
                                       quod_outcome:dtx_state(
                                         quod_committed_projection:outcomes(
                                           Projection2)))))
    after
        #est{db = #db{ref = Ref}} = quod_committed_projection:est(Projection0),
        quod_erlog_db_mvcc:delete(Ref),
        ok = quod_outcome:close(Outcomes)
    end.

genesis_manifest_loads_the_same_predicates_in_projection_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"projection-manifest:",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Anchor = <<0:256>>,
    Self = <<0:256>>,
    Genesis = quod_simplex:test_genesis_tx(
                #{node_id => Self, mode => create, committee => [],
                  external_predicate_modules =>
                      [quod_directory_predicates]},
                Ns, Self, <<96:256>>),
    {ok, Outcomes} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
    Projection0 = quod_committed_projection:new(
                    {Ns, Anchor}, 0,
                    quod_committed_projection:new_est(), Outcomes, none),
    try
        ?assertEqual(
           undefined,
           quod_predicates:descriptor(
             quod_committed_projection:est(Projection0),
             {directory_host, 5})),
        {ok, Projection1, #{kind := content}} =
            project(1, {batch, [Genesis]}, Projection0),
        ?assertMatch(
           {query, quod_directory_predicates, directory_host_5},
           quod_predicates:descriptor(
             quod_committed_projection:est(Projection1),
             {directory_host, 5}))
    after
        #est{db = #db{ref = Ref}} = quod_committed_projection:est(Projection0),
        quod_erlog_db_mvcc:delete(Ref),
        ok = quod_outcome:close(Outcomes)
    end.

wrong_genesis_module_digest_keeps_projection_unavailable_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"projection-manifest-wrong:",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Anchor = <<0:256>>,
    Self = <<0:256>>,
    Genesis0 = quod_simplex:test_genesis_tx(
                 #{node_id => Self, mode => create, committee => [],
                   external_predicate_modules =>
                       [quod_directory_predicates]},
                 Ns, Self, <<97:256>>),
    #transaction{diff = Diff0} = Genesis0,
    Diff =
        [case Op of
             {assert,
              {{external_predicate_modules,
                [{quod_directory_predicates, Digest}]}, Body}} ->
                 <<First, Rest/binary>> = Digest,
                 {assert,
                  {{external_predicate_modules,
                    [{quod_directory_predicates,
                      <<(First bxor 1), Rest/binary>>}]}, Body}};
             _ -> Op
         end || Op <- Diff0],
    Genesis = Genesis0#transaction{diff = Diff},
    {ok, Outcomes} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
    Projection0 = quod_committed_projection:new(
                    {Ns, Anchor}, 0,
                    quod_committed_projection:new_est(), Outcomes, none),
    try
        ?assertEqual(
           {error,
            {predicate_modules_unavailable,
             {predicate_module_digest_mismatch,
              quod_directory_predicates}}},
           project(1, {batch, [Genesis]}, Projection0)),
        ?assertEqual(0, quod_committed_projection:applied(Projection0))
    after
        #est{db = #db{ref = Ref}} = quod_committed_projection:est(Projection0),
        quod_erlog_db_mvcc:delete(Ref),
        ok = quod_outcome:close(Outcomes)
    end.

project(Index, Data, Projection) ->
    Timestamp = case Data of noop -> 0; _ -> Index end,
    {ok, Entry} = quod_ledger:new_entry(Index, Data, Timestamp, none),
    quod_committed_projection:apply_entry(
      Entry,
      Index, Projection).

proves(Goal, Projection) ->
    case quod_prolog:prove_est(Goal, quod_committed_projection:est(Projection)) of
        {ok, _Bindings, _Diff, _ReadCheck} -> true;
        fail -> false
    end.

signed_change({Ns, Anchor} = Target, Transaction0, Signer) ->
    Author = maps:get(pubkey, Signer),
    Transaction = quod_transaction:bind_id(
                    Target,
                    Transaction0#transaction{tx_id = <<>>, author = Author,
                                             sig = none,
                                             signed_bytes = none}),
    {ok, Signed} = quod_transaction:sign(
                     {Ns, Anchor, Author}, Transaction, Signer),
    Signed.

dtx_entry(Index, Controls) ->
    Items = [{dtx, begin {ok, Blob} = quod_dtx:encode_control(Control), Blob end}
             || Control <- Controls],
    EmptyCert = #cert{kind = commit, slot = Index,
                      block_hash = <<0:256>>, sigs = []},
    {ok, Block} = quod_ledger:new_block(
                    Index, Index - 1, {batch, Items}, Index),
    Hash = quod_simplex:block_hash(Block),
    quod_ledger:entry(
      Block, EmptyCert#cert{block_hash = Hash}).
