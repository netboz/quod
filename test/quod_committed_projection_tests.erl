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
    HostPolicy =
        (change(
           Ns,
           diff_for({can_invoke, {'Goal'}, {'Principal'}, [], {'Namespace'}}),
           #{}))#transaction{proof_id = none, plan_digest = none,
                             goal = undefined, result = undefined},
    FactTx = change(Ns, diff_for({projection_fact, one}), #{}),
    ConflictTx = change(
                   Ns, diff_for({must_not_land, true}),
                   #{{projection_fact, 1} => never_present}),
    Author = crypto:hash(sha256, <<"projection-effect-author">>),
    Effect = {quod_direct_effect, 1, local_durable,
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
    EffectTx = quod_transaction:bind_id(
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
                    sig = none}),
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
        {ok, Projection6, #{kind := noop}} =
            project(6, noop, Projection5),
        ?assertEqual(6, quod_committed_projection:applied(Projection6)),
        ?assertEqual(6, quod_outcome:applied_floor(
                          quod_committed_projection:outcomes(Projection6)))
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
    Admission = <<91:256>>,
    HostDiff =
        diff_for({can_invoke, {'Goal'}, {'Principal'}, [], {'Namespace'}})
        ++ diff_for({peer_admitted, Pubkey, "127.0.0.1", 14567, Pubkey}),
    %% Membership is the one deliberate OCC exception: consensus already
    %% validated it against its parent and both local and foreign projections
    %% must apply it even when an ordinary transaction would conflict here.
    Host =
        (change(Ns, HostDiff,
                #{{membership_guard, 1} => never_present}))#transaction{
          proof_id = none, plan_digest = none,
          goal = undefined, result = undefined},
    GroupId = <<92:256>>,
    {ok, DecisionRef} = quod_dtx:certified_ref(
                          <<"projection-origin">>, <<93:256>>, 1,
                          <<94:256>>, <<95:256>>, <<"decision-qc">>),
    {ok, Finalize} = quod_dtx:new_finalize(
                       GroupId, DecisionRef, abort, none, 0),
    {ok, Control} = quod_dtx:sign_control(
                      Target, Finalize, Admission, 1, 1, Signer),
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
        Entry = dtx_entry(2, Control),
        {ok, Projection2,
         #{kind := dtx, group_id := GroupId, publication := none,
           applied_ops := [],
           deferred_ack := none}} =
            quod_committed_projection:apply_entry(Entry, 2, Projection1),
        ?assertEqual(2, quod_committed_projection:applied(Projection2)),
        ?assertEqual(open,
                     maps:get(proof_fence,
                              maps:get(projection,
                                       quod_outcome:dtx_state(
                                         quod_committed_projection:outcomes(
                                           Projection2)))))
    after
        #est{db = #db{ref = Ref}} = quod_committed_projection:est(Projection0),
        quod_erlog_db_mvcc:delete(Ref),
        ok = quod_outcome:close(Outcomes)
    end.

project(Index, Data, Projection) ->
    quod_committed_projection:apply_entry(
      #entry{index = Index, data = Data, timestamp = Index},
      Index, Projection).

proves(Goal, Projection) ->
    case quod_prolog:prove_est(Goal, quod_committed_projection:est(Projection)) of
        {ok, _Bindings, _Diff, _ReadCheck} -> true;
        fail -> false
    end.

dtx_entry(Index, Control) ->
    {ok, Blob} = quod_dtx:encode_control(Control),
    EmptyCert = #cert{kind = commit, slot = Index,
                      block_hash = <<0:256>>, sigs = []},
    Entry0 = #entry{index = Index, data = {dtx, Blob},
                    timestamp = Index, cert = EmptyCert},
    {ok, Block} = quod_simplex:block_from_entry(Entry0),
    Hash = quod_simplex:block_hash(Block),
    Entry0#entry{cert = EmptyCert#cert{block_hash = Hash}}.
