-module(quod_operation_claim_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Real signed proof/plan/codec tests, not consensus-admitted N-target claims.
%% The dedicated target matrix below hand-builds and cryptographically checks
%% real quorum certificates. The older shape-only evidence case explicitly
%% uses arbitrary QC bytes and claims no finality. Admitted N>1 partial-outcome
%% control 7.4 is deferred by ruling to L2-S8-DEFERRED-7.4-ADMITTED-PARTIAL-OUTCOME.
canonical_prediction_one_two_four_test() ->
    lists:foreach(fun(N) ->
        F = fixture(N, false),
        Claim = claim(F, maps:get(bundles, F)),
        ?assertEqual(Claim, claim(F, lists:reverse(maps:get(bundles, F)))),
        {ok, Refs} = quod_transaction:remote_claim_references(Claim),
        ?assertEqual(N, length(Refs)),
        ?assertEqual([], Claim#transaction.diff),
        ?assertEqual(#{}, Claim#transaction.read_check),
        ?assertEqual([], Claim#transaction.effects),
        ClaimRef = ref(maps:get(origin, F), Claim#transaction.tx_id),
        lists:foreach(fun(R) ->
            Target = quod_operation_vector:target(R),
            App = quod_transaction:remote_application(ClaimRef, Claim, Target),
            ?assertEqual(R, ref(Target, App#transaction.tx_id)),
            ?assert(quod_transaction:valid_id(Target, App)),
            ?assertEqual(shared, quod_transaction:remote_claim_route(Claim, Target)),
            {ok, Plan} = quod_transaction:remote_claim_plan(Claim, Target),
            {ok, Material} = quod_dtx:material(Plan),
            ?assertEqual(maps:get(diff, Material), App#transaction.diff)
        end, Refs)
    end, [1, 2, 4]).

source_writer_remains_an_ordinary_post_claim_application_test() ->
    F = fixture(2, true), Claim = claim(F, maps:get(bundles, F)),
    Origin = maps:get(origin, F),
    App = quod_transaction:remote_application(ref(Origin, Claim#transaction.tx_id), Claim, Origin),
    ?assertEqual([], Claim#transaction.diff),
    ?assertNotEqual([], App#transaction.diff),
    ?assertMatch({remote_application, _, _, _}, App#transaction.role),
    ?assertNotEqual(Claim#transaction.tx_id, App#transaction.tx_id).

direct_multi_claim_cannot_bypass_slice8_authority_gate_test() ->
    F = fixture(2, true), Claim = claim(F, maps:get(bundles, F)),
    Origin = {Ns, Anchor} = maps:get(origin, F),
    {ok, Index} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
    Context = quod_commit_validation:new(Origin, 1, quod_ct:committed_kb([]), Index, none),
    try
        quod_ct:with_network_identity(maps:get(network, F), fun() ->
            lists:foreach(fun(Mode) ->
                ?assertMatch({ok, {invalid, independent_lane_unavailable}, _},
                             quod_commit_validation:content([Claim], 1, Mode, Context))
            end, [check, {claim, 2}])
        end)
    after ok = quod_outcome:close(Index)
    end.

complete_receipt_is_monotone_and_target_complete_across_reopen_test() ->
    F = fixture(2, true), Claim = claim(F, maps:get(bundles, F)),
    {Ns, Anchor} = maps:get(origin, F),
    {ok, ClaimData} = quod_transaction:request_claim(Claim),
    Op = maps:get(operation_ref, ClaimData), Digest = maps:get(digest, ClaimData),
    {ok, Refs} = quod_transaction:remote_claim_references(Claim),
    {ok, Receipt} = quod_operation_vector:included(Refs),
    Dir = filename:join("/tmp", "quod_s7_projection_" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    Config = #{data_dir => Dir, outcome_backend => disk},
    try
        {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
        {new, I1} = quod_outcome:claim_operation(I0, 2, ClaimData, {applications, Refs}),
        {{ok, #{state := unresolved, included := []}}, I2} = quod_outcome:lookup_ref(I1, Op),
        ?assertMatch({error, outcome_index_conflict},
            quod_outcome:complete_operation(I2, 3, Op, Digest, [hd(Receipt)])),
        {new, I3} = quod_outcome:complete_operation(I2, 4, Op, Digest, Receipt),
        {ok, I4} = quod_outcome:flush(I3),
        ok = quod_outcome:close(I4),
        {ok, I5} = quod_outcome:open(Ns, Anchor, Config),
        {replay, I6} = quod_outcome:claim_operation(I5, 2, ClaimData, {applications, Refs}),
        {replay, I7} = quod_outcome:complete_operation(I6, 5, Op, Digest, Receipt),
        {{ok, #{state := {terminal, 4}, included := Receipt,
                 outcome_ref := {applications, Refs}}}, I8} = quod_outcome:lookup_ref(I7, Op),
        ?assertMatch({error, outcome_index_conflict},
            quod_outcome:complete_operation(I8, 6, Op, Digest, [hd(Receipt)])),
        ok = quod_outcome:close(I8)
    after _ = file:del_dir_r(Dir)
    end.

exact_bundle_set_required_test() ->
    F = fixture(2, false), [A, B] = maps:get(bundles, F),
    lists:foreach(fun(Bundles) ->
        ?assertError({badmatch, error}, claim(F, Bundles))
    end, [[A], [A, A], [A, A, B], [A, B, setelement(1, B, {<<"extra">>, <<9:256>>})]]).

wrong_anchored_selector_refused_before_materialization_test() ->
    F = fixture(2, false), Claim = claim(F, maps:get(bundles, F)),
    [Target | _] = maps:get(participant_targets, F),
    Wrong = setelement(2, Target, <<999:256>>),
    ?assertEqual(error, quod_transaction:remote_claim_plan(Claim, Wrong)),
    ?assertError({badmatch, error}, quod_transaction:remote_application(
        ref(maps:get(origin, F), Claim#transaction.tx_id), Claim, Wrong)),
    ?assertEqual(error, quod_transaction:remote_claim_route(Claim, Wrong)).

altered_bundle_and_request_bindings_refused_test() ->
    F = fixture(2, false), [A, B] = maps:get(bundles, F),
    {Target, Digest, Blob, Attestation} = A,
    lists:foreach(fun(Bad) ->
        ?assertError({badmatch, error}, claim(F, [Bad, B]))
    end, [{setelement(2, Target, <<999:256>>), Digest, Blob, Attestation},
          {Target, <<999:256>>, Blob, Attestation},
          {Target, Digest, element(3, B), Attestation},
          {Target, Digest, Blob, element(4, B)}]),
    OtherRequest = quod_ct:signed_goal_fixture(#{target => maps:get(origin, F),
      operation_id => <<999:256>>}),
    ?assertException(error, _, quod_transaction:remote_claim(maps:get(origin, F),
      maps:get(manifest, F), [A, B], maps:get(auth, OtherRequest), [])).

%% Certificate family and target validation only: no source consensus
%% admission is called or implied. In particular, certificate inclusion is
%% not an authenticated execution verdict and is never persisted as one.
certified_vector_selects_each_target_and_preserves_ids_test() ->
    F = fixture(4, true), Origin = maps:get(origin, F),
    Claim = signed(F, Origin, claim(F, maps:get(bundles, F))),
    ClaimRef = ref(Origin, Claim#transaction.tx_id),
    {CertA, CertB} = certificate_variants(Origin, Claim),
    ?assertNotEqual(CertA, CertB),
    {ok, Refs} = quod_transaction:remote_claim_references(Claim),
    lists:foreach(fun(R) ->
        Target = {Ns, Anchor} = quod_operation_vector:target(R),
        Base = quod_transaction:remote_application(ClaimRef, Claim, Target),
        Apps = [signed(F, Target, quod_transaction:attach_evidence(Base, Cert, Claim))
                || Cert <- [CertA, CertB]],
        [AppA, AppB] = Apps,
        ?assertEqual(element(4, R), AppA#transaction.tx_id),
        ?assertEqual(AppA#transaction.tx_id, AppB#transaction.tx_id),
        lists:foreach(fun(App) ->
            ?assert(quod_transaction:valid_id(Target, App)),
            {ok, Bytes} = quod_transaction:encode_ledger_transaction(App),
            ?assertEqual({ok, App}, quod_transaction:decode_ledger_transaction(Bytes))
        end, Apps),
        Plan = maps:get(Target, maps:get(plans, F)),
        [{_, Chain, GoalBlob, _, _, _, _}] = quod_dtx:transcript(Plan),
        {ok, Goal} = quod_durable_term:decode_goal(GoalBlob),
        {ok, Principal} = quod_agent_ref:materialize_principal(quod_dtx:principal(Plan)),
        Signer = maps:get(pubkey, maps:get(node_identity, F)),
        Member = {peer_admitted, Signer, "validator", 14567, Signer},
        Policy = {can_invoke, Goal, Principal, [N || {N, _} <- tl(Chain)], Ns},
        {ok, Index} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
        try
            Good = quod_commit_validation:new(Target, 1,
              quod_ct:committed_kb([Member, Policy]), Index, none),
            BadPolicy = quod_commit_validation:new(Target, 1,
              quod_ct:committed_kb([Member]), Index, none),
            ?assertMatch({apply, _, #{diff := [_ | _]}},
              quod_commit_validation:remote_application(AppA, Good)),
            ?assertEqual({reject, not_authorized},
              quod_commit_validation:remote_application(AppA, BadPolicy)),
            %% Rejecting this target changes no sibling or sealed input.
            ?assertEqual({ok, Refs}, quod_transaction:remote_claim_references(Claim))
        after ok = quod_outcome:close(Index)
        end
    end, Refs).

signed(F, {Ns, Anchor}, Tx) ->
    Identity = maps:get(node_identity, F), Pub = maps:get(pubkey, Identity),
    {ok, Signed} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)},
      Tx#transaction{author = Pub, author_seq = 1, submitted_at = 1}, Identity),
    Signed.

certificate_variants({Ns, Anchor} = Target, Tx) ->
    Identities = [begin {P, S} = quod_identity:generate(),
      #{pubkey => P, key => quod_identity:key_term({P, S})} end || _ <- lists:seq(1, 4)],
    Validators = [maps:get(pubkey, I) || I <- Identities],
    {ok, Block} = quod_ledger:new_block(2, 1, {batch, [Tx]}, 0),
    Hash = quod_simplex:block_hash(Block), Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Sigs = [begin #share{sig = S} = quod_simplex:make_share(Domain, commit, 2, Hash, I),
                  {maps:get(pubkey, I), S} end || I <- Identities],
    [A, B] = [begin
        Cert = #cert{kind = commit, slot = 2, block_hash = Hash, sigs = lists:sort(Subset)},
        ?assert(quod_simplex:verify_cert(Domain, Cert, Validators)),
        {ok, Ref} = quod_dtx:certified_entry_ref(Target, quod_ledger:entry(Block, Cert), Tx),
        Ref
    end || Subset <- [lists:sublist(Sigs, 3), Sigs]],
    {A, B}.

receipt_complete_set_and_evidence_independence_test() ->
    F = fixture(4, true), Claim = claim(F, maps:get(bundles, F)),
    Origin = maps:get(origin, F), ClaimRef = ref(Origin, Claim#transaction.tx_id),
    {ok, Refs} = quod_transaction:remote_claim_references(Claim),
    {ok, Receipt} = quod_operation_vector:included(Refs),
    {ok, #{operation_ref := Op, digest := Digest}} = quod_transaction:request_claim(Claim),
    Complete = quod_transaction:remote_complete(Origin, Op, Digest, Receipt),
    ?assertEqual(Complete, quod_transaction:remote_complete(
        Origin, Op, Digest, lists:reverse(Receipt))),
    Pairs = [begin
        T = quod_operation_vector:target(R),
        App = quod_transaction:remote_application(ClaimRef, Claim, T),
        {Ns, Anchor} = T,
        {ok, CRef} = quod_dtx:certified_ref(Ns, Anchor, 3, <<214:256>>,
                                         App#transaction.tx_id, <<"shape-only-qc">>),
        {CRef, App}
    end || R <- Refs],
    Attached = quod_transaction:attach_receipt_evidence(Complete, lists:reverse(Pairs)),
    ?assertEqual(Complete#transaction.tx_id, Attached#transaction.tx_id),
    ?assertEqual([{transaction, R} || {R, _} <- Pairs],
                 quod_transaction:required_references(Attached)),
    ?assertError(bad_remote_evidence, quod_transaction:attach_receipt_evidence(Complete, tl(Pairs))),
    ?assertError(bad_remote_evidence, quod_transaction:attach_receipt_evidence(Complete, Pairs++[hd(Pairs)])),
    ?assertError(bad_remote_evidence, quod_transaction:attach_receipt_evidence(Complete, [hd(Pairs) || _ <- Pairs])).

fixture(N, Local) ->
    Origin = {<<"quod:operation-source">>, <<201:256>>},
    Foreign = [{<<"quod:operation-target", (integer_to_binary(I))/binary>>, <<I:256>>}
               || I <- lists:seq(1, N)],
    Targets = case Local of true -> [Origin | tl(Foreign)]; false -> Foreign end,
    quod_ct:operation_plan_fixture(#{target => Origin, participant_target => hd(Targets)}, Targets).

claim(F, Bundles) -> quod_transaction:remote_claim(maps:get(origin, F),
    maps:get(manifest, F), Bundles, maps:get(auth, F), []).
ref({Ns, Anchor}, TxId) -> {transaction, Ns, Anchor, TxId}.
