-module(quod_dtx_tests).

%% Slice-4 sealing: signed local plans, invocation transcripts, and the
%% live-bridge gate (`m:quod_dtx`), driven through real proof sessions over a
%% committed MVCC kb so the sealed diff and read tokens are the exact values
%% the OCC validator would later check.

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").
-include("quod_client_goal_limits.hrl").
-include("quod_proof_limits.hrl").
-include("quod_vm_limits.hrl").

-define(NS, <<"quod:dtx">>).

%% ------------------------------------------------------------------
%% harness
%% ------------------------------------------------------------------

session(Facts) ->
    quod_proof_session:start(
      quod_ct:committed_kb(Facts),
      #{read_set => true, proof_context => {origin, test},
        signer => configured_test_signer()}).

configured_test_signer() ->
    case {application:get_env(quod, node_pubkey),
          application:get_env(quod, identity_key)} of
        {{ok, <<_:256>> = Pubkey}, {ok, Key}} ->
            #{pubkey => Pubkey, key => Key};
        _ ->
            none
    end.

ctx() ->
    quod_predicates:proof_context(
      ?NS, 1, undefined, [{?NS, <<0:256>>}]).

open(Session, InvocationId, Goal) ->
    quod_proof_session:open(
      Session, InvocationId, Goal, allowed, ctx(),
      quod_transaction_scope:empty_selection()).

first(Session, Goal) ->
    InvocationId = crypto:strong_rand_bytes(16),
    ok = open(Session, InvocationId, Goal),
    {InvocationId, quod_proof_session:next(Session, InvocationId)}.

bind() ->
    #{target => {?NS, key(1)}, base_height => 1,
      proof_id => key(2), origin => {<<"quod:origin">>, key(3)},
      principal => anonymous, request_binding => none}.

key(N) -> <<N:256>>.

with_identity(Fun) ->
    Saved = [{K, application:get_env(quod, K)}
             || K <- [node_pubkey, identity_key]],
    {Pub, Seed} = quod_identity:generate(),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, quod_identity:key_term({Pub, Seed})),
    try Fun(Pub)
    after
        lists:foreach(
          fun({K, {ok, V}}) -> application:set_env(quod, K, V);
             ({K, undefined}) -> application:unset_env(quod, K)
          end, Saved)
    end.

%% ------------------------------------------------------------------
%% seal exactness, materiality, and the read-only participant
%% ------------------------------------------------------------------

sealed_plan_carries_exact_diff_and_read_tokens_test() ->
    Session = session([{parent, tom, bob}]),
    try
        Goal = {',', {parent, tom, {'X'}}, {assertz, {child, {'X'}}}},
        {_Id, {solution, Solution}} = first(Session, Goal),
        {ok, Plan} = quod_dtx:seal_session(Session, bind()),
        ?assertEqual(quod_proof_session:local_changes(Session),
                     quod_ct:plan_material(diff, Plan)),
        ?assertEqual(quod_proof_session:read_set(Session),
                     quod_ct:plan_material(read_check, Plan)),
        ?assertMatch(#{{parent, 2} := {present, 1}},
                     quod_ct:plan_material(read_check, Plan)),
        ?assertEqual({?NS, key(1)}, quod_dtx:target(Plan)),
        ?assertEqual(1, quod_dtx:base_height(Plan)),
        ?assertEqual(key(2), quod_dtx:proof_id(Plan)),
        ?assertEqual({<<"quod:origin">>, key(3)}, quod_dtx:origin(Plan)),
        ?assertEqual(anonymous, quod_dtx:principal(Plan)),
        %% Unkeyed node: an unsigned witness that still verifies as unsigned.
        ?assertEqual(none, quod_dtx:signer(Plan)),
        ?assert(quod_dtx:verify(Plan)),
        %% The signed op count lets a foreign holder classify the plan as a
        %% writer without decoding its atoms; the digest is what an ordinary
        %% transaction envelope binds.
        ?assertEqual(length(quod_ct:plan_material(diff, Plan)), quod_dtx:diff_ops(Plan)),
        ?assertMatch(<<_:256>>, quod_dtx:digest(Plan)),
        %% The transcript binds this exact invocation: goal bytes, the full
        %% semantic chain, and the chained digest of the one answer taken.
        [{_InvocationId, Chain, GoalBin, allowed, 1, Digest, active}] =
            quod_ct:plan_material(transcript, Plan),
        ?assertEqual([{?NS, <<0:256>>}], Chain),
        ?assertEqual(wire_blob(Goal), GoalBin),
        SolutionDigest =
            crypto:hash(sha256, term_to_binary(Solution, [deterministic])),
        ?assertEqual(
           crypto:hash(sha256, <<0:256, 1:64, SolutionDigest/binary>>),
           Digest)
    after
        quod_proof_session:stop(Session)
    end.

seal_rechecks_namespace_gate_before_exposing_plan_test() ->
    with_proof_gate(
      fun(Tab, AccessGuard) ->
          Session = quod_proof_session:start(
                      quod_ct:committed_kb([]),
                      #{read_set => true,
                        proof_context => {origin, test},
                        signer => configured_test_signer(),
                        access_guard => AccessGuard}),
          GroupId = key(90),
          try
              {_Id, {solution, _}} =
                  first(Session, {assertz, {staged, value}}),
              true = ets:insert(
                       Tab,
                       quod_ct:proof_gate_row(
                         true, 7, [{GroupId, 1, 7}])),
              ?assertEqual(
                 {error, {transaction_pending, GroupId}},
                 quod_dtx:seal_session(Session, bind()))
          after
              quod_proof_session:stop(Session)
          end
      end).

untouched_scope_is_not_material_test() ->
    Session = session([{parent, tom, bob}]),
    try
        {_Id, {solution, _}} = first(Session, true),
        ?assertEqual(not_material, quod_dtx:seal_session(Session, bind()))
    after
        quod_proof_session:stop(Session)
    end.

signed_origin_scope_seals_operation_claim_without_database_diff_test() ->
    Session = session([]),
    try
        {_Id, {solution, _}} = first(Session, true),
        Identity = {?NS, key(1)},
        Binding = {agent_goal_v1, key(44)},
        {ok, Plan} = quod_dtx:seal_session(
                       Session,
                       (bind())#{origin := Identity,
                                 request_binding := Binding}),
        ?assertEqual(Identity, quod_dtx:target(Plan)),
        ?assertEqual(Identity, quod_dtx:origin(Plan)),
        ?assertEqual(Binding, quod_dtx:request_binding(Plan)),
        ?assertEqual([], quod_ct:plan_material(diff, Plan)),
        ?assertEqual(#{}, quod_ct:plan_material(read_check, Plan)),
        ?assert(quod_dtx:participates(Plan)),
        ?assertNot(quod_dtx:writes(Plan)),
        ?assertNot(quod_dtx:reads_only(Plan))
    after
        quod_proof_session:stop(Session)
    end.

signed_non_origin_empty_scope_remains_not_material_test() ->
    Session = session([]),
    try
        {_Id, {solution, _}} = first(Session, true),
        ?assertEqual(
           not_material,
           quod_dtx:seal_session(
             Session,
             (bind())#{request_binding := {agent_goal_v1, key(45)}}))
    after
        quod_proof_session:stop(Session)
    end.

read_only_participant_seals_empty_diff_with_read_check_test() ->
    Session = session([{parent, tom, bob}]),
    try
        {_Id, {solution, _}} = first(Session, {parent, tom, {'X'}}),
        {ok, Plan} = quod_dtx:seal_session(Session, bind()),
        ?assertEqual([], quod_ct:plan_material(diff, Plan)),
        ?assertMatch(#{{parent, 2} := {present, 1}},
                     quod_ct:plan_material(read_check, Plan))
    after
        quod_proof_session:stop(Session)
    end.

independent_lane_is_explicit_and_selects_the_canonical_vector_test() ->
    Origin = {<<"quod:origin">>, key(3)},
    Target = {<<"quod:target">>, key(4)},
    Binding = {agent_goal_v1, key(45)},
    OriginPlan = sealed_route_plan([], {assertz, p}, Origin, Origin, Binding),
    TargetPlan = sealed_route_plan([], {assertz, q}, Target, Origin, Binding),
    Plans = #{Origin => OriginPlan, Target => TargetPlan},
    ?assertEqual({remote_claim, lists:sort([Origin, Target]), []},
                 quod_prolog:test_route_plans(Plans, Origin, true, true)),
    ?assertMatch({group, [_, _]},
                 quod_prolog:test_route_plans(Plans, Origin, true, false)),
    ?assertEqual(read, quod_prolog:test_route_plans(#{}, Origin, true, true)),
    ?assertMatch({single, Origin, []},
                 quod_prolog:test_route_plans(#{Origin => OriginPlan}, Origin, true, true)),
    ?assertMatch({remote_claim, [Target], []},
                 quod_prolog:test_route_plans(#{Target => TargetPlan}, Origin, true, true)),
    lists:foreach(fun(P) ->
        ?assertEqual({error, independent_requires_signed_request},
                     quod_prolog:test_route_plans(P, Origin, false, true))
    end, [#{}, #{Origin => OriginPlan}, Plans]).

write_lane_routing_is_derived_only_from_sealed_plans_test() ->
    Origin = {<<"quod:origin">>, key(3)},
    RemoteA = {<<"quod:remote-a">>, key(4)},
    RemoteB = {<<"quod:remote-b">>, key(5)},
    RemoteC = {<<"quod:remote-c">>, key(6)},
    Binding = {agent_goal_v1, key(45)},
    OriginWrite = sealed_route_plan([], {assertz, {origin_mark, one}},
                                    Origin, Origin, Binding),
    OriginRead = sealed_route_plan([{origin_fact, one}],
                                   {origin_fact, one},
                                   Origin, Origin, Binding),
    OriginClaim = sealed_route_plan([], true, Origin, Origin, Binding),
    RemoteRead = sealed_route_plan([{remote_fact, one}],
                                   {remote_fact, one},
                                   RemoteA, Origin, Binding),
    RemoteReadC = sealed_route_plan([{remote_fact, three}],
                                    {remote_fact, three},
                                    RemoteC, Origin, Binding),
    RemoteWriteA = sealed_route_plan([], {assertz, {remote_mark, one}},
                                     RemoteA, Origin, Binding),
    RemoteWriteB = sealed_route_plan([], {assertz, {remote_mark, two}},
                                     RemoteB, Origin, Binding),
    ?assertEqual(
       read,
       quod_prolog:test_route_plans(
         #{Origin => OriginRead, RemoteA => RemoteRead}, Origin, true)),
    ?assertMatch(
       {single, Origin, [_, _]},
       quod_prolog:test_route_plans(
         #{Origin => OriginWrite, RemoteA => RemoteRead,
           RemoteC => RemoteReadC}, Origin, true)),
    ?assertMatch(
       {single, Origin, []},
       quod_prolog:test_route_plans(
         #{Origin => OriginWrite}, Origin, true)),
    ?assertMatch(
       {remote_claim, [RemoteA], [_, _]},
       quod_prolog:test_route_plans(
         #{Origin => OriginRead, RemoteA => RemoteWriteA,
           RemoteC => RemoteReadC}, Origin, true)),
    ?assertMatch(
       {remote_claim, [RemoteA], []},
       quod_prolog:test_route_plans(
         #{Origin => OriginClaim, RemoteA => RemoteWriteA}, Origin, true)),
    ?assertMatch(
       {single, RemoteA, [_]},
       quod_prolog:test_route_plans(
         #{Origin => OriginRead, RemoteA => RemoteWriteA}, Origin, false)),
    {group, Participants} = quod_prolog:test_route_plans(
                              #{Origin => OriginClaim,
                                RemoteA => RemoteWriteA,
                                RemoteB => RemoteWriteB}, Origin, true),
    ?assertEqual(lists:sort([Origin, RemoteA, RemoteB]), Participants),
    {group, ParticipantsWithOriginRead} = quod_prolog:test_route_plans(
                                            #{Origin => OriginRead,
                                              RemoteA => RemoteWriteA,
                                              RemoteB => RemoteWriteB},
                                            Origin, true),
    ?assertEqual(
       lists:sort([Origin, RemoteA, RemoteB]), ParticipantsWithOriginRead).

sealed_route_plan(Facts, Goal, Target, Origin, RequestBinding) ->
    Session = session(Facts),
    try
        {_Id, {solution, _}} = first(Session, Goal),
        {ok, Plan} = quod_dtx:seal_session(
                       Session,
                       (bind())#{target := Target, origin := Origin,
                                 request_binding := RequestBinding}),
        Plan
    after
        quod_proof_session:stop(Session)
    end.

%% ------------------------------------------------------------------
%% witness signing, tamper, and the wire codec
%% ------------------------------------------------------------------

signed_plan_verifies_and_rejects_tamper_test() ->
    with_identity(
      fun(Pub) ->
          Session = session([]),
          try
              {_Id, {solution, _}} = first(Session, {assertz, {t, 1}}),
              {ok, Plan} = quod_dtx:seal_session(Session, bind()),
              ?assertEqual(Pub, quod_dtx:signer(Plan)),
              ?assert(quod_dtx:verify(Plan)),
              {quod_plan, Core, Signer, Signature} = tuple(Plan),
              %% Any bound field flip breaks the witness signature.
              lists:foreach(
                fun(TamperedCore) ->
                    ?assertNot(
                       quod_dtx:verify(
                         plan({quod_plan, TamperedCore, Signer, Signature})))
                end,
                [Core#{base_height := 2},
                 Core#{proof_id := key(9)},
                 Core#{target := {?NS, key(9)}},
                 Core#{principal := {node, key(9)}},
                 Core#{diff := wire_blob([])}]),
              %% A different signer cannot claim this plan.
              {OtherPub, _} = quod_identity:generate(),
              ?assertNot(
                 quod_dtx:verify(
                   plan({quod_plan, Core, OtherPub, Signature}))),
              %% Wire round trip preserves the plan bit-for-bit.
              {ok, Blob} = quod_dtx:encode(Plan),
              ?assertEqual({ok, Plan}, quod_dtx:decode(Blob))
          after
              quod_proof_session:stop(Session)
          end
      end).

decode_is_bounded_and_shape_checked_test() ->
    ?assertEqual({error, {too_large, plan}},
                 quod_dtx:decode(
                   <<0:(?QUOD_MAX_PLAN_ENVELOPE_BYTES + 1)/unit:8>>)),
    ?assertMatch({error, {protocol_error, bad_payload}},
                 quod_dtx:decode(<<"not etf">>)),
    ?assertMatch({error, {protocol_error, bad_payload}},
                 quod_dtx:decode(
                   term_to_binary({quod_plan, #{}, none, none},
                                  [deterministic]))),
    %% A signed shape with a truncated signer key is not a plan.
    Session = session([]),
    try
        {_Id, {solution, _}} = first(Session, {assertz, {t, 1}}),
        {ok, Plan} = quod_dtx:seal_session(Session, bind()),
        {quod_plan, Core, none, none} = tuple(Plan),
        ?assertMatch(
           {error, {protocol_error, bad_payload}},
           quod_dtx:decode(
             term_to_binary({quod_plan, Core, <<1, 2, 3>>, <<4>>},
                            [deterministic])))
    after
        quod_proof_session:stop(Session)
    end.

origin_outcome_identity_keeps_foreign_payloads_opaque_test() ->
    Session = session([]),
    try
        {_Id, {solution, _}} = first(Session, {assertz, {t, 1}}),
        {ok, Plan} = quod_dtx:seal_session(Session, bind()),
        {ok, GoalBlob, ResultBlob} =
            quod_transaction:encode_durable_submission(
              {'::', ?NS, {assertz, {t, 1}}}, #{}),
        Ref = quod_transaction:plan_outcome_ref(
                Plan, GoalBlob, ResultBlob, none),
        {ok, Material} = quod_dtx:material(Plan),
        Transaction = quod_transaction:from_plan(
                        Plan, Material, GoalBlob, ResultBlob, none),
        {TargetNs, TargetAnchor} = quod_dtx:target(Plan),
        ?assertEqual(
           Ref,
           {transaction, TargetNs, TargetAnchor,
            Transaction#transaction.tx_id}),
        {quod_plan, Core, Signer, Signature} = tuple(Plan),
        %% This wire symbol has never existed as an atom in this VM. The origin
        %% must derive the expected reference without minting it; only the
        %% owning ontology may interpret foreign bytes.
        ForeignAtomName =
            <<"quod_foreign_atom_",
              (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
        ForeignDiff = wire_blob([{'$quod_symbol', ForeignAtomName}]),
        OpaquePlan = plan(
                       {quod_plan,
                        Core#{diff := ForeignDiff},
                        Signer, Signature}),
        AtomsBefore = erlang:system_info(atom_count),
        OpaqueRef = quod_transaction:plan_outcome_ref(
                      OpaquePlan, GoalBlob, ResultBlob, none),
        ?assertEqual(AtomsBefore, erlang:system_info(atom_count)),
        ?assertMatch(
           {transaction, ?NS, <<_:256>>, <<_:256>>}, OpaqueRef),
        ?assertNotEqual(Ref, OpaqueRef),
        NonCanonicalPlan = plan(
                             {quod_plan,
                              Core#{diff := noncanonical_wire_blob(wire_blob([]))},
                              Signer, Signature}),
        ?assertEqual(
           {error, {protocol_error, bad_payload}},
           quod_dtx:material(NonCanonicalPlan)),
        %% Plan v3 has one format. Raw atom-bearing ETF is not a fallback.
        LegacyRawPlan =
            plan({quod_plan,
                  Core#{diff := term_to_binary(
                                   [{assert, {{legacy_raw, true}, true}}],
                                   [deterministic])},
                  Signer, Signature}),
        ?assertEqual(
           {error, {protocol_error, bad_payload}},
           quod_dtx:material(LegacyRawPlan))
    after
        quod_proof_session:stop(Session)
    end.

verified_plan_restart_materializes_new_functor_at_owner_test() ->
    with_identity(
      fun(_Pub) ->
          Name = unique_symbol(
                   <<"quod_dtx_restart_functor">>,
                   erlang:unique_integer([positive])),
          assert_symbols_absent([Name]),
          Plan = signed_material_plan(
                   [{assert, {{'$quod_symbol', Name}, true}}], [], []),
          ?assert(quod_dtx:verify(Plan)),
          {ok, Blob} = quod_dtx:encode(Plan),
          AtomsBefore = erlang:system_info(atom_count),
          {ok, Decoded} = quod_dtx:decode(Blob),
          ?assertEqual(AtomsBefore, erlang:system_info(atom_count)),
          ?assert(quod_dtx:verify(Decoded)),
          {ok, #{diff := [{assert, {Functor, true}}]}} =
              quod_dtx:material(Decoded),
          ?assert(is_atom(Functor)),
          ?assertEqual(Name, atom_to_binary(Functor, utf8))
      end).

superseded_keyed_plan_v5_is_rejected_test() ->
    with_identity(
      fun(_Pub) ->
          Current = signed_material_plan([], [], []),
          {quod_plan, Core, Pubkey, _CurrentSignature} = tuple(Current),
          #{pubkey := Pubkey} = Signer = configured_test_signer(),
          V5Bytes = term_to_binary(
                      {<<"quod.dtx.plan">>, 5, Core}, [deterministic]),
          V5 = plan(
                 {quod_plan, Core, Pubkey,
                  quod_identity:sign(V5Bytes, Signer)}),
          ?assertNot(quod_dtx:verify(V5)),
          {ok, Blob} = quod_dtx:encode(V5),
          {ok, Decoded} = quod_dtx:decode(Blob),
          ?assertNot(quod_dtx:verify(Decoded))
      end).

plan_material_has_one_aggregate_64_symbol_budget_test() ->
    with_identity(
      fun(_Pub) ->
          Prefix = <<"quod_dtx_material_",
                     (integer_to_binary(
                        erlang:unique_integer([positive])))/binary>>,
          DiffNames = [unique_symbol(Prefix, N) || N <- lists:seq(1, 32)],
          ReadNames = [unique_symbol(Prefix, N) || N <- lists:seq(33, 63)],
          GoalNames = [unique_symbol(Prefix, N) || N <- lists:seq(64, 65)],
          AllNames = DiffNames ++ ReadNames ++ GoalNames,
          assert_symbols_absent(AllNames),
          Diff = [{assert, {{'$quod_symbol', Name}, true}}
                  || Name <- DiffNames],
          ReadPairs = [{{{'$quod_symbol', Name}, 0}, never_present}
                       || Name <- ReadNames],

          %% The 65th symbol lives only inside RequestedGoalBin. It must still
          %% be charged with diff/read vocabulary, and rejection must happen
          %% before any member of the aggregate is allocated.
          TooManyTranscript =
              [transcript_with_goal(
                 {{'$quod_symbol', hd(GoalNames)},
                  {'$quod_symbol', lists:last(GoalNames)}})],
          TooMany = signed_material_plan(Diff, ReadPairs, TooManyTranscript),
          {ok, TooManyBlob} = quod_dtx:encode(TooMany),
          {ok, TooManyDecoded} = quod_dtx:decode(TooManyBlob),
          ?assert(quod_dtx:verify(TooManyDecoded)),
          ?assertEqual({error, too_many_new_atoms},
                       quod_dtx:material(TooManyDecoded)),
          assert_symbols_absent(AllNames),

          AtLimitTranscript =
              [transcript_with_goal({'$quod_symbol', hd(GoalNames)})],
          AtLimit = signed_material_plan(Diff, ReadPairs, AtLimitTranscript),
          {ok, AtLimitBlob} = quod_dtx:encode(AtLimit),
          {ok, AtLimitDecoded} = quod_dtx:decode(AtLimitBlob),
          ?assert(quod_dtx:verify(AtLimitDecoded)),
          {ok, #{diff := MaterialDiff, read_check := MaterialRead,
                 transcript := [{_, _, GoalBlob, _, _, _, _}]}} =
              quod_dtx:material(AtLimitDecoded),
          ?assertEqual(32, length(MaterialDiff)),
          ?assertEqual(31, map_size(MaterialRead)),
          ?assertEqual(
             {ok, binary_to_existing_atom(hd(GoalNames), utf8)},
             quod_wire_term:decode_canonical(
               GoalBlob, ?QUOD_MAX_NESTED_GOAL_BYTES)),
          ?assertEqual(64, ?QUOD_MAX_NEW_MATERIAL_ATOMS),
          [?assert(is_atom(binary_to_existing_atom(Name, utf8)))
           || Name <- lists:droplast(AllNames)],
          ?assertException(
             error, badarg,
             binary_to_existing_atom(lists:last(AllNames), utf8))
      end).

plan_material_rejects_invalid_diff_and_duplicate_reads_test() ->
    with_identity(
      fun(_Pub) ->
          BadDiff = signed_material_plan([{assert, {42, true}}], [], []),
          ?assert(quod_dtx:verify(BadDiff)),
          ?assertEqual(
             {error, {protocol_error, bad_payload}},
             quod_dtx:material(BadDiff)),
          DuplicateReads =
              signed_material_plan(
                [], [{{duplicate_read, 1}, never_present},
                     {{duplicate_read, 1}, static}], []),
          ?assert(quod_dtx:verify(DuplicateReads)),
          ?assertEqual(
             {error, {protocol_error, bad_payload}},
             quod_dtx:material(DuplicateReads))
      end).

legacy_or_unclassified_transcript_is_rejected_test() ->
    Session = session([]),
    try
        {_Id, {solution, _}} = first(Session, {assertz, {t, 1}}),
        {ok, Plan} = quod_dtx:seal_session(Session, bind()),
        {quod_plan, Core, Signer, Signature} = tuple(Plan),
        [{InvocationId, Chain, GoalBin, allowed,
          Count, Digest, Tag}] = quod_ct:plan_material(transcript, Plan),
        Legacy = [{InvocationId, Chain, GoalBin, Count, Digest, Tag}],
        Unclassified =
            [{InvocationId, Chain, GoalBin, undecided,
              Count, Digest, Tag}],
        lists:foreach(
          fun(Transcript) ->
              Candidate = plan(
                            {quod_plan,
                             Core#{transcript := wire_blob(Transcript)},
                             Signer, Signature}),
              ?assertEqual(
                 {error, {protocol_error, bad_payload}},
                 quod_dtx:material(Candidate))
          end,
          [Legacy, Unclassified])
    after
        quod_proof_session:stop(Session)
    end.

%% ------------------------------------------------------------------
%% the live-bridge gate
%% ------------------------------------------------------------------

material_diff_with_live_bridge_fails_seal_test() ->
    Session = session([]),
    try
        {_Id, {solution, _}} = first(Session, {assertz, {t, 1}}),
        %% The absorption seam is exactly how a policy sub-proof's bridge use
        %% reaches the scope: markers ride the dependency map unchanged.
        ok = quod_proof_session:absorb_read_set(
               Session, #{{'$quod_live_bridge', {directory_host, 5}} => true}),
        ?assertEqual([{directory_host, 5}],
                     quod_proof_session:live_bridges(Session)),
        ?assertEqual(
           {error, {non_transactional_dependency, {directory_host, 5}}},
           quod_dtx:seal_session(Session, bind()))
    after
        quod_proof_session:stop(Session)
    end.

bridge_use_without_a_diff_still_seals_test() ->
    Session = session([{parent, tom, bob}]),
    try
        {_Id, {solution, _}} = first(Session, {parent, tom, {'X'}}),
        ok = quod_proof_session:absorb_read_set(
               Session, #{{'$quod_live_bridge', {directory_host, 5}} => true}),
        {ok, Plan} = quod_dtx:seal_session(Session, bind()),
        ?assertEqual([], quod_ct:plan_material(diff, Plan)),
        %% The marker never leaks into the OCC read tokens.
        ?assertNot(maps:is_key({'$quod_live_bridge', {directory_host, 5}},
                               quod_ct:plan_material(read_check, Plan)))
    after
        quod_proof_session:stop(Session)
    end.

overlay_separates_tokens_from_bridge_markers_test() ->
    Est = quod_ct:committed_kb([{parent, tom, bob}]),
    Wrapped = quod_erlog_db_local_prove:wrap_state(Est, #{read_set => true}),
    {succeed, Wrapped1} =
        erlog_int:prove_goal({parent, tom, {'X'}}, Wrapped),
    ok = quod_erlog_db_local_prove:record_live_bridge(
           Wrapped1, {peer_probe, 2}),
    Overlay = (Wrapped1#est.db)#db.ref,
    ReadSet = quod_erlog_db_local_prove:get_read_set(Overlay),
    ?assertMatch(#{{parent, 2} := {present, 1}}, ReadSet),
    ?assertNot(maps:is_key({'$quod_live_bridge', {peer_probe, 2}}, ReadSet)),
    ?assertEqual([{peer_probe, 2}],
                 quod_erlog_db_local_prove:get_live_bridges(Overlay)),
    ?assertEqual(
       ReadSet#{{'$quod_live_bridge', {peer_probe, 2}} => true},
       quod_erlog_db_local_prove:get_dependencies(Overlay)),
    quod_erlog_db_local_prove:cleanup_read_set(Wrapped1).

%% ------------------------------------------------------------------
%% transcript ordering, terminal tags, and the pre-run byte bound
%% ------------------------------------------------------------------

transcript_orders_invocations_and_tags_terminals_test() ->
    Session = session([{parent, tom, bob}, {parent, tom, ann}]),
    try
        A = <<1:128>>, B = <<2:128>>, C = <<3:128>>,
        ok = open(Session, A, {parent, tom, {'X'}}),
        ok = open(Session, B, {parent, tom, {'X'}}),
        ok = open(Session, C, {parent, tom, {'X'}}),
        {solution, _} = quod_proof_session:next(Session, A),
        {solution, _} = quod_proof_session:next(Session, B),
        {solution, _} = quod_proof_session:next(Session, A),
        {complete, _} = quod_proof_session:next(Session, A),
        ok = quod_proof_session:cancel(Session, C),
        {Entries, _Generation} = quod_proof_session:transcript(Session),
        ?assertMatch(
           [{A, _, _, allowed, 2, _, complete},
            {B, _, _, allowed, 1, _, active},
            {C, _, _, allowed, 0, _, cancelled}],
           Entries),
        %% A cleanup cancel after completion is not a second outcome.
        ok = quod_proof_session:cancel(Session, A),
        {[{A, _, _, allowed, 2, _, complete} | _], _} =
            quod_proof_session:transcript(Session)
    after
        quod_proof_session:stop(Session)
    end.

transcript_invocation_ids_are_never_reused_test() ->
    Session = session([{parent, tom, bob}, {parent, tom, ann}]),
    Id = <<17:128>>,
    try
        ok = open(Session, Id, {parent, tom, {'X'}}),
        {solution, _} = quod_proof_session:next(Session, Id),
        ok = quod_proof_session:cancel(Session, Id),
        ?assertEqual(
           {error, {protocol_error, bad_binding}},
           open(Session, Id, {assertz, {different_goal, true}})),
        ?assertMatch(
           {[{Id, _, _, allowed, 1, _, cancelled}], _},
           quod_proof_session:transcript(Session))
    after
        quod_proof_session:stop(Session)
    end.

peer_ready_taint_is_exempt_only_for_membership_diff_test() ->
    Bridge = #{{'$quod_live_bridge', {peer_ready, 1}} => true},
    Content = session([]),
    try
        {_Id, {solution, _}} = first(Content, {assertz, {trusted, peer}}),
        ok = quod_proof_session:absorb_read_set(Content, Bridge),
        ?assertEqual(
           {error, {non_transactional_dependency, {peer_ready, 1}}},
           quod_dtx:seal_session(Content, bind()))
    after
        quod_proof_session:stop(Content)
    end,
    Membership = session([]),
    Pubkey = key(18),
    try
        {_MembershipId, {solution, _}} = first(
          Membership,
          {assertz, {peer_admitted, Pubkey, "127.0.0.1", 9000, Pubkey}}),
        ok = quod_proof_session:absorb_read_set(Membership, Bridge),
        ?assertMatch({ok, _}, quod_dtx:seal_session(Membership, bind()))
    after
        quod_proof_session:stop(Membership)
    end.

transcript_charge_is_taken_before_the_goal_runs_test() ->
    Session = session([]),
    try
        %% Fill the transcript to exactly the limit, then show the next open
        %% is refused at admission — the goal never runs, so nothing escapes
        %% the transcript's accounting.
        ok = fill_transcript_to_limit(Session, 0),
        ?assertEqual({error, {too_large, transcript}},
                     open(Session, <<3:128>>, pad_goal(0))),
        %% The refused invocation does not exist afterwards.
        ?assertEqual({error, unknown_invocation},
                     quod_proof_session:next(Session, <<3:128>>))
    after
        quod_proof_session:stop(Session)
    end.

transcript_boundary_is_exact_test() ->
    Boundary = fun(Slack) ->
        Session = session([]),
        try
            fill_transcript_to_limit(Session, Slack)
        after
            quod_proof_session:stop(Session)
        end
    end,
    ?assertEqual(ok, Boundary(0)),
    ?assertEqual({error, {too_large, transcript}}, Boundary(1)).

pad_goal(PadBytes) -> {pad, binary:copy(<<$p>>, PadBytes)}.

fill_transcript_to_limit(Session, Slack) ->
    Id1 = <<1:128>>,
    Id2 = <<2:128>>,
    FirstPad = 6000,
    SecondPad = ?QUOD_MAX_SCOPE_TRANSCRIPT_BYTES
        - charged_cost(Id1, pad_goal(FirstPad))
        - charged_cost(Id2, pad_goal(0)) + Slack,
    true = SecondPad >= 0,
    ok = open(Session, Id1, pad_goal(FirstPad)),
    open(Session, Id2, pad_goal(SecondPad)).

%% Mirrors the session's charge: the entry's external size plus the fixed
%% per-invocation slack for count, chained digest, and completion tag.
charged_cost(Id, Goal) ->
    Chain = quod_predicates:ctx_chain(ctx()),
    GoalBin = wire_blob(Goal),
    erlang:external_size({Id, Chain, GoalBin, allowed}) + 96.

denied_transcript_keeps_request_and_never_executes_it_test() ->
    Session = session([]),
    InvocationId = <<19:128>>,
    RequestedGoal = {assertz, {must_not_run, true}},
    try
        ok = quod_proof_session:open(
               Session, InvocationId, RequestedGoal, denied, ctx(),
               quod_transaction_scope:empty_selection()),
        ?assertMatch(
           {complete, [{not_allowed, ?NS} | _]},
           quod_proof_session:next(Session, InvocationId)),
        ?assertEqual([], quod_proof_session:local_changes(Session)),
        ?assertEqual(
           [{InvocationId, quod_predicates:ctx_chain(ctx()),
             wire_blob(RequestedGoal), denied,
             0, <<0:256>>, complete}],
           element(1, quod_proof_session:transcript(Session)))
    after
        quod_proof_session:stop(Session)
    end.

read_only_session_records_no_transcript_test() ->
    Est = quod_ct:committed_kb([{parent, tom, bob}]),
    Session = quod_proof_session:start(
                Est, #{read_set => true, read_only => true,
                       proof_context => {origin, test}}),
    try
        {_Id, {solution, _}} = first(Session, {parent, tom, {'X'}}),
        ?assertEqual({[], 0}, quod_proof_session:transcript(Session))
    after
        quod_proof_session:stop(Session)
    end.

%% ------------------------------------------------------------------
%% finalize/1 seals successful material work or aborts without sealing
%% ------------------------------------------------------------------

finalize_seals_local_scope_and_stores_the_plan_test() ->
    ProofId = key(21),
    Anchor = key(22),
    Identity = {?NS, Anchor},
    _Handle = quod_proof_context:start(
                ProofId, false, Identity, quod_time:mono_ms() + 5000,
                anonymous),
    Session = session([{parent, tom, bob}]),
    try
        {ok, _ScopeId, _Scope} =
            quod_proof_context:get_or_open_scope(
              Identity,
              fun(ScopeId) ->
                  {ok, self(),
                   {local_scope, ScopeId, ?NS, Anchor, 1, Session}}
              end),
        {_Id, {solution, _}} =
            first(Session, {',', {parent, tom, {'X'}},
                            {assertz, {child, {'X'}}}}),
        {ok, Plans} = quod_proof_context:seal_plans(),
        ?assertEqual(ok, quod_proof_context:finalize(commit)),
        #{Identity := Plan} = Plans,
        ?assertEqual(quod_proof_session:local_changes(Session),
                     quod_ct:plan_material(diff, Plan)),
        ?assertEqual(Identity, quod_dtx:target(Plan)),
        ?assertEqual(Identity, quod_dtx:origin(Plan)),
        ?assertEqual(ProofId, quod_dtx:proof_id(Plan)),
        ?assertEqual(anonymous, quod_dtx:principal(Plan)),
        ?assert(quod_dtx:verify(Plan))
    after
        quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end),
        quod_proof_session:stop(Session)
    end.

finalize_of_a_clean_proof_seals_nothing_test() ->
    ProofId = key(31),
    Anchor = key(32),
    Identity = {?NS, Anchor},
    _Handle = quod_proof_context:start(
                ProofId, false, Identity, quod_time:mono_ms() + 5000,
                anonymous),
    Session = session([{parent, tom, bob}]),
    try
        {ok, _ScopeId, _Scope} =
            quod_proof_context:get_or_open_scope(
              Identity,
              fun(ScopeId) ->
                  {ok, self(),
                   {local_scope, ScopeId, ?NS, Anchor, 1, Session}}
              end),
        %% Reads without any staged write anywhere: no plan exists to carry.
        {_Id, {solution, _}} = first(Session, {parent, tom, {'X'}}),
        ?assertEqual({ok, #{}}, quod_proof_context:seal_plans()),
        ?assertEqual(ok, quod_proof_context:finalize(commit))
    after
        quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end),
        quod_proof_session:stop(Session)
    end.

finalize_fails_the_proof_on_a_refused_seal_test() ->
    ProofId = key(41),
    Anchor = key(42),
    Identity = {?NS, Anchor},
    _Handle = quod_proof_context:start(
                ProofId, false, Identity, quod_time:mono_ms() + 5000,
                anonymous),
    Session = session([]),
    try
        {ok, _ScopeId, _Scope} =
            quod_proof_context:get_or_open_scope(
              Identity,
              fun(ScopeId) ->
                  {ok, self(),
                   {local_scope, ScopeId, ?NS, Anchor, 1, Session}}
              end),
        {_Id, {solution, _}} = first(Session, {assertz, {t, 1}}),
        ok = quod_proof_session:absorb_read_set(
               Session, #{{'$quod_live_bridge', {directory_host, 5}} => true}),
        ?assertEqual(
           {error, {non_transactional_dependency, {directory_host, 5}}},
           quod_proof_context:seal_plans()),
        ?assertEqual(
           {error, {non_transactional_dependency, {directory_host, 5}}},
           quod_proof_context:finalize(commit))
    after
        quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end),
        quod_proof_session:stop(Session)
    end.

failed_material_proof_aborts_without_sealing_test() ->
    ProofId = key(45),
    Anchor = key(46),
    Identity = {?NS, Anchor},
    _Handle = quod_proof_context:start(
                ProofId, false, Identity, quod_time:mono_ms() + 5000,
                anonymous),
    Session = session([]),
    Result = {fail, [expected_failure]},
    try
        {ok, _ScopeId, _Scope} =
            quod_proof_context:get_or_open_scope(
              Identity,
              fun(ScopeId) ->
                  {ok, self(),
                   {local_scope, ScopeId, ?NS, Anchor, 1, Session}}
              end),
        {_Id, {complete, _}} =
            first(Session,
                  {',', {assertz, {must_not_commit, true}}, fail}),
        ok = quod_proof_session:absorb_read_set(
               Session,
               #{{'$quod_live_bridge', {directory_host, 5}} => true}),
        ?assert(quod_proof_session:dirty(Session)),
        ?assertEqual(Result, quod_prolog:test_finalize_pinned_result(Result))
    after
        quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end),
        quod_proof_session:stop(Session)
    end.

%% ------------------------------------------------------------------
%% Manifest and atomic control boundaries
%% ------------------------------------------------------------------

maximum_signed_request_is_preserved_by_transaction_and_vote_test() ->
    Goal = <<"assertz(saved(ok)).">>,
    GoalText =
        <<(binary:copy(
             <<" ">>, ?QUOD_CLIENT_GOAL_TEXT_BYTES - byte_size(Goal)))/binary,
          Goal/binary>>,
    Ns = binary:copy(<<"n">>, ?DIRECTORY_MAX_NAMESPACE_BYTES),
    Target = {Ns, key(221)},
    Fixture = quod_ct:signed_atomic_fixture(
                #{target => Target, goal_text => GoalText}),
    Transaction = maps:get(transaction, Fixture),
    Vote = maps:get(vote, Fixture),
    {ok, Material} = quod_atomic:admission_material(Vote),
    Network = maps:get(network, Fixture),
    Deadline = maps:get(deadline, Fixture),
    ?assertMatch(
       {ok, #{claim := _}},
       quod_transaction:validate_request(
         Network, Target, Deadline, Transaction)),
    ?assertMatch(
       {ok, #{claim := _}},
       quod_atomic:validate_request(Network, Target, Deadline, Material)),
    ?assert(quod_atomic:requires_network_identity(Material)),
    ?assertMatch({ok, _}, quod_atomic:encode_record(Vote)),
    Request = maps:get(request, Fixture),
    ?assertEqual(
       {error, {too_large, goal_text}},
       quod_client_goal:encode(
         Request#{goal_text => <<GoalText/binary, " ">>})).

plan_attestation_rejects_a_different_valid_plan_test() ->
    F = quod_ct:signed_atomic_fixture(#{}),
    Target = maps:get(origin, F),
    Plan = maps:get(plan, F),
    Other = quod_ct:signed_atomic_fixture(
              #{target => Target, node_identity => maps:get(node_identity, F),
                goal_text => <<"assertz(other_valid_plan(ok)).">>}),
    OtherPlan = maps:get(plan, Other),
    Manifest = maps:get(manifest, F),
    {Target, _, _, Attestation} = lists:keyfind(Target, 1, maps:get(bundles, F)),
    ?assert(quod_dtx:verify_plan_attestation(
              Target, Plan, Manifest, Attestation)),
    ?assertNot(quod_dtx:verify_plan_attestation(
                 Target, OtherPlan, Manifest, Attestation)),
    ?assertEqual(
       {error, invalid_plan_attestation},
       quod_dtx:attest_plan(1,
         Target, OtherPlan, Manifest, maps:get(node_identity, F))),
    ?assertNot(quod_dtx:verify_plan_attestation(
                 Target, malformed_plan, Manifest, Attestation)).

effect_only_plan_is_admitted_once_by_the_shared_dtx_validator_test() ->
    with_identity(
      fun(Pub) ->
          Signer = configured_test_signer(),
          Origin = {<<"quod:effect-origin">>, key(241)},
          TargetA = {<<"quod:effect-a">>, key(242)},
          ProofId = key(244),
          Principal = {node, Pub},
          {ok, Effect} = quod_effect:new(
                           create, Pub, Principal,
                           {<<"quod:created-by-group">>, key(245)},
                           key(246), key(247)),
          EffectPlan = signed_effect_material_plan(
                         TargetA, ProofId, Origin, Principal, [], [Effect]),
          PlainPlan = signed_effect_material_plan(
                        Origin, ProofId, Origin, Principal, [], []),
          {ok, Goal} = quod_durable_term:encode_goal({create, grouped}),
          {ok, Result} = quod_durable_term:encode_result(#{}),
          Participants = lists:sort(
                           [{TargetA, quod_dtx:digest(EffectPlan)},
                            {Origin, quod_dtx:digest(PlainPlan)}]),
          {ok, Manifest} = quod_dtx:new_manifest(
                             #{proof_id => ProofId,
                               coordinator =>
                                   {element(1, Origin), element(2, Origin),
                                    Pub, key(248)},
                               nonce => key(249), principal => Principal,
                               vote_deadline_ms => 1800000000000,
                               goal => Goal, result => Result,
                               request_binding => none,
                               participants => Participants}),
          {ok, EffectAttestation} = quod_dtx:attest_plan(1,
                                      TargetA, EffectPlan, Manifest, Signer),
          {ok, PlainAttestation} = quod_dtx:attest_plan(1,
                                     Origin, PlainPlan, Manifest, Signer),
          {ok, EffectBlob} = quod_dtx:encode(EffectPlan),
          {ok, Group} = quod_atomic:new_group(Manifest, none, PlainAttestation),
          ?assertMatch(
             {ok, _},
             quod_atomic:new_vote(Group, TargetA,
               {TargetA, quod_dtx:digest(EffectPlan), EffectBlob,
                EffectAttestation}, prepared)),

          {ok, WrongActorEffect} = quod_effect:new(
                                     create, Pub, {node, key(250)},
                                     {<<"quod:created-by-group">>, key(245)},
                                     key(246), key(247)),
          WrongActorPlan = signed_effect_material_plan(
                             TargetA, ProofId, Origin, Principal, [],
                             [WrongActorEffect]),
          DiffAndEffectPlan = signed_effect_material_plan(
                                TargetA, ProofId, Origin, Principal,
                                [{assert, {{forbidden_mix, true}, true}}],
                                [Effect]),
          ?assert(quod_dtx:verify(WrongActorPlan)),
          {ok, WrongActorMaterial} = quod_dtx:material(WrongActorPlan),
          ?assertNot(quod_effect:validate_plan(
                       WrongActorPlan, WrongActorMaterial)),
          ?assertEqual(
             {error, invalid_plan_attestation},
             quod_dtx:attest_plan(1,
               TargetA, WrongActorPlan,
               manifest_with_plan(
                 Manifest, TargetA, quod_dtx:digest(WrongActorPlan)),
               Signer)),
          ?assert(quod_dtx:verify(DiffAndEffectPlan)),
          ?assertEqual(
             {error, {protocol_error, bad_payload}},
             quod_dtx:material(DiffAndEffectPlan)),
          ?assertEqual(
             {error, invalid_plan_attestation},
             quod_dtx:attest_plan(1,
               TargetA, DiffAndEffectPlan,
               manifest_with_plan(
                 Manifest, TargetA, quod_dtx:digest(DiffAndEffectPlan)),
               Signer))
      end).

noncanonical_plan_envelope_cannot_change_a_group_id_test() ->
    F = quod_ct:signed_atomic_fixture(#{}),
    Plan = maps:get(plan, F),
    NonCanonicalBlob = noncanonical_plan_blob(Plan),
    {ok, CanonicalBlob} = quod_dtx:encode(Plan),
    ?assertNotEqual(CanonicalBlob, NonCanonicalBlob),
    %% Both ETF encodings denote the same signed Erlang term. Only the one
    %% canonical byte identity is admissible inside a semantic DTX record.
    ?assertEqual(Plan, binary_to_term(NonCanonicalBlob, [safe])),
    ?assertEqual(
       {error, {protocol_error, bad_payload}},
       quod_dtx:decode(NonCanonicalBlob)),
    Target = maps:get(origin, F),
    {Target, Digest, _Blob, Attestation} = lists:keyfind(Target, 1, maps:get(bundles, F)),
    ?assertEqual(
       {error, invalid_record},
       quod_atomic:new_vote(maps:get(group, F), Target,
                             {Target, Digest, NonCanonicalBlob, Attestation}, prepared)).

manifest_yields_exact_event_context_test() ->
    F = quod_ct:signed_atomic_fixture(#{}), Plan = maps:get(plan, F),
    Manifest = maps:get(manifest, F),
    {ok, Context} = quod_dtx:event_context(Manifest, Plan),
    ?assertEqual(maps:get(proof_id, F), maps:get(proof_id, Context)),
    ?assertEqual(maps:get(origin, F), maps:get(origin, Context)),
    ?assertEqual(maps:get(principal, F), maps:get(principal, Context)),
    ?assertEqual(quod_dtx:digest(Plan), maps:get(plan_digest, Context)),
    ?assert(is_binary(maps:get(goal, Context))),
    ?assert(is_binary(maps:get(result, Context))),
    ?assertEqual(error, quod_dtx:event_context(
                         setelement(6, Manifest, {node, key(199)}), Plan)).

more_than_sixty_four_disjoint_groups_vote_without_a_cap_test() ->
    with_identity(fun(_) ->
        Target = {<<"quod:many-groups">>, key(210)},
        P0 = quod_atomic:initial_projection(Target, 0),
        P = lists:foldl(fun(N, Acc) ->
            Name = list_to_atom("quod_dtx_disjoint_" ++ integer_to_list(N)),
            F = participant_vote_fixture(Target, {Name, N}, N),
            {ok, _, Next, []} = quod_atomic:reduce(maps:get(control, F),
                maps:get(ref, F), quod_atomic:initial_group_history(), Acc),
            Next
        end, P0, lists:seq(1, 65)),
        ?assertEqual(65, map_size(maps:get(groups, P))),
        ?assertNot(maps:is_key(conflicts, P)),
        ?assertEqual(0, maps:get(generation, P)),
        ?assertEqual(#{}, maps:get(apply_fences, P))
    end).

batch_rejects_duplicate_signed_lane_sequence_test() ->
    with_identity(fun(_) ->
        T = {<<"quod:duplicate-lane-sequence">>, key(220)},
        A = participant_vote_fixture(T, {lane_a, a}, 85),
        B = participant_vote_fixture(T, {lane_b, b}, 86),
        Controls = [signed(T, quod_atomic:control_body(maps:get(control, F)),
                          key(221), 500, configured_test_signer()) || F <- [A,B]],
        Batch = control_batch([{C, protocol_ref(T, 500, quod_atomic:control_body(C))}
                                || C <- Controls]),
        ?assertEqual({error, {invalid_transition, malformed_batch}},
            quod_atomic:reduce_batch(Batch, #{}, quod_atomic:initial_projection(T, 0)))
    end).

batch_reducer_preserves_per_control_attribution_test() ->
    with_identity(fun(_) ->
        T = {<<"quod:batch-attribution">>, key(226)},
        A = participant_vote_fixture(T, {attributed_a, a}, 89),
        B = participant_vote_fixture(T, {attributed_b, b}, 90),
        Batch = control_batch([{maps:get(control,F),maps:get(ref,F)} || F <- [A,B]]),
        {ok, Histories, P, Items} = quod_atomic:reduce_batch(
            Batch, #{}, quod_atomic:initial_projection(T, 0)),
        ?assertEqual(2, map_size(Histories)),
        ?assertEqual([C || {C,_} <- Batch], [maps:get(control,I) || I <- Items]),
        ?assertEqual([R || {_,R} <- Batch], [maps:get(ref,I) || I <- Items]),
        ?assert(lists:all(fun(#{history := H, projection := IP, effects := []}) ->
            quod_atomic:valid_group_history(H) andalso quod_atomic:valid_projection(IP)
        end, Items)),
        ?assertEqual(P, maps:get(projection, lists:last(Items)))
    end).

overlapping_writes_block_and_batch_failure_is_atomic_test() ->
    with_identity(fun(_) ->
        T = {<<"quod:conflict-groups">>, key(211)},
        A = participant_vote_fixture(T, {shared_conflict, a}, 70),
        B = participant_vote_fixture(T, {shared_conflict, b}, 71),
        P0 = quod_atomic:initial_projection(T, 0),
        {ok, _, P1, []} = quod_atomic:reduce(maps:get(control,A),maps:get(ref,A),
                                            quod_atomic:initial_group_history(),P0),
        ?assertEqual(expected_conflict_readiness(A,B), readiness(maps:get(control,B),P1)),
        ?assertEqual(expected_conflict_reduction(A,B), quod_atomic:reduce(
            maps:get(control,B),maps:get(ref,B),quod_atomic:initial_group_history(),P1)),
        Batch = control_batch([{maps:get(control,F),maps:get(ref,F)} || F <- [A,B]]),
        [{First,_},{Second,_}] = Batch,
        Expected = expected_conflict_reduction(
            #{group_id => quod_atomic:group_id(First)}, #{group_id => quod_atomic:group_id(Second)}),
        ?assertEqual(Expected, quod_atomic:reduce_batch(Batch,#{},P0)),
        ?assertEqual(#{},maps:get(groups,P0)),
        ?assert(quod_atomic:valid_projection(P1))
    end).

ordinary_content_blocks_only_on_an_exact_active_conflict_test() ->
    with_identity(fun(_) ->
        T = {<<"quod:content-conflict">>, key(225)},
        A = participant_vote_fixture(T, {shared_content,a},87),
        B = participant_vote_fixture(T, {other_content,b},88),
        {ok,_,P,[]} = quod_atomic:reduce(maps:get(control,A),maps:get(ref,A),
            quod_atomic:initial_group_history(),quod_atomic:initial_projection(T,0)),
        ?assertEqual({blocked,active_group},quod_atomic:content_readiness(transaction_from_vote(A),P)),
        ?assertEqual(ready,quod_atomic:content_readiness(transaction_from_vote(B),P))
    end).

read_write_and_write_read_conflicts_are_symmetric_test() ->
    with_identity(fun(_) ->
        T = {<<"quod:rw-conflicts">>,key(212)},
        Reader = participant_vote_goal_fixture(T,[{shared_rw,seed}],{shared_rw,seed},80),
        Writer = participant_vote_goal_fixture(T,[{shared_rw,seed}],{assertz,{shared_rw,changed}},81),
        ?assert(lists:member({<<"shared_rw">>,1},maps:get(reads,plan_descriptor_from_vote(Reader)))),
        ?assert(lists:member({<<"shared_rw">>,1},maps:get(writes,plan_descriptor_from_vote(Writer)))),
        assert_second_vote_conflicts(T,Reader,Writer),
        assert_second_vote_conflicts(T,Writer,Reader)
    end).

same_effect_custody_conflicts_even_when_effect_ids_differ_test() ->
    with_identity(fun(Pub) ->
        T = {<<"quod:custody-source">>,key(213)}, Custody = {<<"quod:custody-target">>,key(214)},
        A = participant_effect_vote_fixture(T,Custody,Pub,82),
        B = participant_effect_vote_fixture(T,Custody,Pub,83),
        assert_second_vote_conflicts(T,A,B),
        assert_second_vote_conflicts(T,B,A)
    end).

event_only_resolve_retains_only_the_source_completion_marker_test() ->
    with_identity(fun(_) ->
        lists:foreach(fun(Source) ->
            O = {<<"quod:event-source">>,key(219)}, B = {<<"quod:event-target">>,key(220)},
            T = case Source of true -> O; false -> B end,
            Plan = signed_effect_material_plan(T,key(221),O,anonymous,[{event,{fixture_event,84}}],[]),
            Other = case Source of true -> B; false -> O end,
            Empty = signed_effect_material_plan(Other,key(221),O,anonymous,[],[]),
            F = atomic_fixture(O,[{T,Plan},{Other,Empty}],T,84),
            {ok,H,P,[]} = quod_atomic:reduce(maps:get(control,F),maps:get(ref,F),
                quod_atomic:initial_group_history(),quod_atomic:initial_projection(T,0)),
            {C,R} = participant_commit_resolve(T,F,420),
            {ok,_,P1,[_]} = quod_atomic:reduce(C,R,H,P),
            ?assertEqual(1,maps:get(generation,P1)),
            Expected = case Source of
                true -> #{maps:get(group_id,F) => #{slot => 420,generation => 1,blocking => false}};
                false -> #{}
            end,
            ?assertEqual(Expected,maps:get(apply_fences,P1)),
            ?assert(quod_atomic:valid_projection(P1))
        end,[true,false])
    end).

independent_commit_fences_acknowledge_in_reverse_order_test() ->
    with_identity(fun(_) ->
        T = {<<"quod:reverse-acks">>,key(215)},
        A = participant_vote_fixture(T,{reverse_a,true},84),
        B = participant_vote_fixture(T,{reverse_b,true},85),
        P0 = quod_atomic:initial_projection(T,7),
        {ok,HA,P1,[]} = quod_atomic:reduce(maps:get(control,A),maps:get(ref,A),
                                          quod_atomic:initial_group_history(),P0),
        {ok,HB,P2,[]} = quod_atomic:reduce(maps:get(control,B),maps:get(ref,B),
                                          quod_atomic:initial_group_history(),P1),
        {CA,RA} = participant_commit_resolve(T,A,400),
        {CB,RB} = participant_commit_resolve(T,B,401),
        {ok,_,P3,[_]} = quod_atomic:reduce(CA,RA,HA,P2),
        {ok,_,P4,[_]} = quod_atomic:reduce(CB,RB,HB,P3),
        ?assertEqual(9,maps:get(generation,P4)),
        ?assertEqual(2,map_size(maps:get(apply_fences,P4))),
        {ok,P5} = quod_atomic:acknowledge_resolve(maps:get(group_id,B),401,2,P4),
        ?assert(maps:is_key(maps:get(group_id,A),maps:get(apply_fences,P5))),
        {ok,P6} = quod_atomic:acknowledge_resolve(maps:get(group_id,A),400,2,P5),
        ?assertEqual(#{},maps:get(apply_fences,P6)),
        ?assertEqual(9,maps:get(generation,P6))
    end).

assert_second_vote_conflicts(T,First,Second) ->
    {ok,_,P,[]} = quod_atomic:reduce(maps:get(control,First),maps:get(ref,First),
        quod_atomic:initial_group_history(),quod_atomic:initial_projection(T,0)),
    ?assertEqual(expected_conflict_readiness(First,Second),readiness(maps:get(control,Second),P)).

expected_conflict_readiness(Holder,Contender) ->
    case maps:get(group_id,Contender) < maps:get(group_id,Holder) of
        true -> {blocked,active_group}; false -> {refused,conflict}
    end.
expected_conflict_reduction(Holder,Contender) ->
    case expected_conflict_readiness(Holder,Contender) of
        {blocked,active_group} -> {error,{invalid_transition,active_group}};
        {refused,conflict} -> {error,{invalid_transition,conflict_refused}}
    end.
plan_descriptor_from_vote(#{plan := Plan}) -> maps:get(conflict_descriptor,quod_dtx:core(Plan)).
transaction_from_vote(#{plan := Plan}) ->
    {ok,M} = quod_dtx:material(Plan),
    #transaction{diff = maps:get(diff,M),read_check = maps:get(read_check,M),effects = maps:get(effects,M)}.
control_batch(Rows) ->
    lists:sort(fun({A,_},{B,_}) -> quod_atomic:control_order_key(A) < quod_atomic:control_order_key(B) end,Rows).

certified_entry_ref_binds_exact_entry_test() ->
    F = quod_ct:signed_atomic_fixture(#{}),
    {Ns, Anchor} = Target = maps:get(origin, F),
    Control = maps:get(vote_control, F),
    Slot = 9,
    Timestamp = 1234,
    Payload = {batch, [{dtx, Control}]},
    {ok, Block} = quod_ledger:new_block(
                    Slot, Slot - 1, Payload, Timestamp),
    BlockHash = quod_simplex:block_hash(Block),
    Cert = #cert{kind = commit, slot = Slot,
                 block_hash = BlockHash, sigs = []},
    Entry = quod_ledger:entry(Block, Cert),
    View = quod_ledger:entry_view(Entry),
    {{ok, Ref}, {call_count, Counts}} = tprof:profile(fun() ->
        quod_dtx:certified_entry_ref(Target, Entry, Control)
    end, #{type => call_count, report => return,
           pattern => [{quod_ledger, classify, 1}, {quod_identity, verify, 3}]}),
    ?assertEqual([], Counts),
    {ok, Expected} =
        quod_dtx:certified_ref(
          Ns, Anchor, Slot, BlockHash, quod_atomic:record_digest(Control),
          term_to_binary(Cert, [deterministic])),
    ?assertEqual(Expected, Ref),
    {ok, RefusedMaterial} = quod_atomic:select_vote(
                            quod_atomic:control_material(Control), {refused, [vote_deadline]}),
    {ok, OtherControl} = quod_atomic:sign_control(Target, RefusedMaterial,
                          maps:get(admission, F), 2, Timestamp, maps:get(node_identity, F)),
    ?assertEqual({error, invalid_certified_entry},
                 quod_dtx:certified_entry_ref(Target, Entry, OtherControl)),
    ?assertEqual({error, invalid_certified_entry},
                 quod_dtx:certified_entry_ref({Ns, key(252)}, Entry, Control)),
    %% Every hash-covered entry field and the certificate's own slot binding
    %% are checked; neither can be replaced while retaining the same ref.
    ?assertEqual({error, bad_entry},
                 quod_ledger:from_entry_view(
                   View#entry{timestamp = Timestamp + 1})),
    ?assertEqual({error, invalid_certified_entry},
                 quod_dtx:certified_entry_ref(Target, View, Control)),
    ?assertEqual(
       {error, invalid_certified_entry},
       quod_dtx:certified_entry_ref(
         Target, quod_ledger:entry(Block, Cert#cert{slot = Slot + 1}), Control)).

certified_entry_ref_accepts_another_valid_quorum_subset_test() ->
    F = quod_ct:signed_atomic_fixture(#{}),
    {Ns, Anchor} = Target = maps:get(origin, F),
    Control = maps:get(vote_control, F),
    Slot = 9,
    Timestamp = 1234,
    Payload = {batch, [{dtx, Control}]},
    {ok, Block} = quod_ledger:new_block(
                    Slot, Slot - 1, Payload, Timestamp),
    BlockHash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Identities = [begin
                      {Pub, Seed} = quod_identity:generate(),
                      {Pub, #{pubkey => Pub,
                              key => quod_identity:key_term({Pub, Seed})}}
                  end || _ <- lists:seq(1, 4)],
    Committee = lists:sort([Pub || {Pub, _} <- Identities]),
    Shares = maps:from_list(
               [{Pub, quod_simplex:make_share(
                        Domain, commit, Slot, BlockHash, Signer)}
                || {Pub, Signer} <- Identities]),
    [A, B, C, D] = Committee,
    Form = fun(Keys) ->
                   {ok, Cert} = quod_simplex:form_cert(
                                  Domain, commit, Slot, BlockHash,
                                  [maps:get(Key, Shares) || Key <- Keys],
                                  Committee),
                   Cert
           end,
    RefCert = Form([A, B, C]),
    LocalCert = Form([B, C, D]),
    RefEntry = quod_ledger:entry(Block, RefCert),
    LocalEntry = quod_ledger:entry(Block, LocalCert),
    {ok, Ref} = quod_dtx:certified_entry_ref(Target, RefEntry, Control),
    %% This is the live N=4 case: both replicas certified the same immutable
    %% block, but each retained a different valid three-of-four proof.
    ?assertNotEqual(term_to_binary(RefCert, [deterministic]),
                    term_to_binary(LocalCert, [deterministic])),
    ?assert(quod_dtx:certified_entry_ref_matches(
              Target, LocalEntry, Control, Ref, Committee)),
    BadDigestRef = setelement(7, Ref, key(16#d1)),
    ?assertNot(quod_dtx:certified_entry_ref_matches(
                 Target, LocalEntry, Control, BadDigestRef, Committee)),
    OtherHash = key(16#d2),
    OtherShares = [quod_simplex:make_share(
                     Domain, commit, Slot, OtherHash, Signer)
                   || {_Pub, Signer} <- Identities],
    {ok, OtherCert} = quod_simplex:form_cert(
                        Domain, commit, Slot, OtherHash,
                        lists:sublist(OtherShares, 3), Committee),
    BadProofRef = setelement(
                    8, Ref, term_to_binary(OtherCert, [deterministic])),
    ?assertNot(quod_dtx:certified_entry_ref_matches(
                 Target, LocalEntry, Control, BadProofRef, Committee)).

certified_entry_ref_binds_pinned_genesis_test() ->
    Ns = <<"quod:certified-genesis">>,
    Genesis = #transaction{
                 tx_id = <<71:256>>, origin = {Ns, <<0:256>>},
                 diff = [], read_check = #{}, author = <<71:256>>,
                 sig = none},
    {ok, Block} = quod_ledger:new_block(
                    1, 0, {batch, [Genesis]}, 0),
    Entry = quod_ledger:entry(Block, none),
    Anchor = quod_simplex:block_hash(Block),
    Target = {Ns, Anchor},
    {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Genesis),
    ?assertMatch({ok, Target, 1, _},
                 quod_dtx:certified_ref_binding(Ref)),
    {ok, Target, 1, GenesisDigest} = quod_dtx:certified_ref_binding(Ref),
    ?assertEqual(crypto:hash(sha256, Genesis#transaction.tx_id),
                 GenesisDigest),
    %% Genesis finality comes only from the exact pinned block hash.  Merely
    %% being an unsigned slot-1 transaction cannot manufacture a reference.
    ?assertEqual(
       {error, invalid_certified_entry},
       quod_dtx:certified_entry_ref(
         {Ns, <<72:256>>}, Entry, Genesis)),
    ?assertEqual({error, bad_entry},
                 quod_ledger:from_entry_view(
                   (quod_ledger:entry_view(Entry))#entry{timestamp = 1})),
    {ok, OtherBlock} = quod_ledger:new_block(1, 0, {batch, [Genesis]}, 1),
    ?assertEqual({error, invalid_certified_entry},
                 quod_dtx:certified_entry_ref(
                   Target, quod_ledger:entry(OtherBlock, none), Genesis)).

%% ------------------------------------------------------------------
%% V1 control fixtures
%% ------------------------------------------------------------------

protocol_goal_plan(Target, ProofId, Origin, Facts, Goal) ->
    Session = session(Facts),
    try
        {_Id, {solution, _}} = first(Session, Goal),
        {ok, Plan} = quod_dtx:seal_session(Session,
          #{target => Target, base_height => 1, proof_id => ProofId,
            origin => Origin, principal => anonymous, request_binding => none}),
        {ok, Blob} = quod_dtx:encode(Plan),
        {Plan, Blob}
    after quod_proof_session:stop(Session) end.

signed(Target, Record, Admission, Sequence, Signer) ->
    {ok, Material} = quod_atomic:admission_material(Record),
    {ok, Control} = quod_atomic:sign_control(Target, Material, Admission, Sequence, Sequence, Signer),
    Control.

protocol_ref({Ns, Anchor}, Slot, Record) ->
    {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, Slot, key(150 + Slot),
                  quod_atomic:record_digest(Record), <<"shape-only-not-certified">>),
    Ref.

noncanonical_plan_blob(Plan) ->
    Canonical = term_to_binary(Plan, [deterministic]),
    <<131, 104, 4, 119, 9, "quod_plan", Rest/binary>> = Canonical,
    <<131, 104, 4, 118, 0, 9, "quod_plan", Rest/binary>>.

wire_blob(Term) ->
    {ok, Blob} = quod_wire_term:encode_canonical(Term),
    Blob.

noncanonical_wire_blob(<<131, 104, 1, Rest/binary>>) ->
    <<131, 105, 0, 0, 0, 1, Rest/binary>>.

signed_material_plan(Diff, ReadPairs, Transcript) ->
    Signer = #{pubkey := Pubkey} = configured_test_signer(),
    Core = #{target => {?NS, key(1)},
             base_height => 1,
             proof_id => key(2),
             origin => {<<"quod:origin">>, key(3)},
             principal => anonymous,
             request_binding => none,
             overlay_generation => 0,
             diff_ops => length(Diff),
             read_functors => length(ReadPairs),
             effects_count => 0,
             conflict_descriptor => test_conflict_descriptor(Diff, ReadPairs, []),
             diff => wire_blob(Diff),
             read_check => wire_blob(ReadPairs),
             effects => wire_blob([]),
             live_bridges => wire_blob([]),
             transcript => wire_blob(Transcript)},
    Bytes = term_to_binary(
              {<<"quod.dtx.plan">>, 8, Core}, [deterministic]),
    plan({quod_plan, Core, Pubkey, quod_identity:sign(Bytes, Signer)}).

signed_effect_material_plan(
  Target, ProofId, Origin, Principal, Diff, Effects) ->
    Signer = #{pubkey := Pubkey} = configured_test_signer(),
    Core = #{target => Target,
             base_height => 1,
             proof_id => ProofId,
             origin => Origin,
             principal => Principal,
             request_binding => none,
             overlay_generation => 0,
             diff_ops => length(Diff),
             read_functors => 0,
             effects_count => length(Effects),
             conflict_descriptor => test_conflict_descriptor(Diff, [], Effects),
             diff => wire_blob(Diff),
             read_check => wire_blob([]),
             effects => wire_blob(Effects),
             live_bridges => wire_blob([]),
             transcript => wire_blob([])},
    Bytes = term_to_binary(
              {<<"quod.dtx.plan">>, 8, Core}, [deterministic]),
    plan({quod_plan, Core, Pubkey, quod_identity:sign(Bytes, Signer)}).

test_conflict_descriptor(Diff, ReadPairs, Effects) ->
    #{reads => lists:usort(
                  [test_conflict_functor(Key) || {Key, _} <- ReadPairs,
                                                     test_valid_functor(Key)]),
      writes => lists:usort(
                   [test_conflict_functor(test_head_functor(Head))
                    || {Op, {Head, _}} <- Diff,
                       (Op =:= assert orelse Op =:= retract),
                       test_valid_head(Head)]),
      custody => lists:usort([quod_effect:target(E) || E <- Effects])}.

test_valid_head(Head) ->
    try test_valid_functor(test_head_functor(Head)) catch _:_ -> false end.
test_head_functor({'$quod_symbol', Name}) -> {{'$quod_symbol', Name}, 0};
test_head_functor(Head) -> erlog_int:functor(Head).
test_valid_functor({Name, Arity}) ->
    (is_atom(Name) orelse
     (is_tuple(Name) andalso tuple_size(Name) =:= 2 andalso
      element(1, Name) =:= '$quod_symbol' andalso is_binary(element(2, Name))))
        andalso is_integer(Arity) andalso Arity >= 0;
test_valid_functor(_) -> false.

test_conflict_functor({{'$quod_symbol', Name}, Arity}) -> {Name, Arity};
test_conflict_functor({Name, Arity}) -> {atom_to_binary(Name, utf8), Arity}.

participant_vote_fixture(Target, Fact, N) ->
    participant_vote_goal_fixture(Target, [], {assertz, Fact}, N).

participant_vote_goal_fixture(Target, Facts, Goal, N) ->
    Origin = {<<"quod:many-origin-", (integer_to_binary(N))/binary>>, crypto:hash(sha256, <<N:64>>)},
    ProofId = crypto:hash(sha256, <<"proof", N:64>>),
    {Plan, _Blob} = protocol_goal_plan(Target, ProofId, Origin, Facts, Goal),
    participant_vote_from_plan(Target, Origin, ProofId, Plan, N).

participant_effect_vote_fixture(Target, Custody, _Pub, N) ->
    #{pubkey := Pub} = configured_test_signer(),
    Origin = {<<"quod:effect-origin-", (integer_to_binary(N))/binary>>,
              crypto:hash(sha256, <<"effect-origin", N:64>>)},
    ProofId = crypto:hash(sha256, <<"effect-proof", N:64>>),
    {ok, Effect} = quod_effect:new(create, Pub, {node, Pub}, Custody,
                    crypto:hash(sha256, <<"request", N:64>>),
                    crypto:hash(sha256, <<"prepared", N:64>>)),
    Plan = signed_effect_material_plan(Target, ProofId, Origin, {node, Pub}, [], [Effect]),
    participant_vote_from_plan(Target, Origin, ProofId, Plan, N).

participant_vote_from_plan(Target, Origin, ProofId, Plan, N) ->
    SourcePlan = signed_effect_material_plan(Origin, ProofId, Origin,
                                             quod_dtx:principal(Plan), [], []),
    atomic_fixture(Origin, [{Target, Plan}, {Origin, SourcePlan}], Target, N).

%% Real signed own material; source-empty and event/effect plans are explicit
%% codec fixtures. References are shape-only: no consensus-admission claim.
atomic_fixture(Origin = {Ns, Anchor}, PlanRows, Target, N) ->
    Signer = #{pubkey := Pub} = configured_test_signer(),
    Plans = maps:from_list(PlanRows), Plan = maps:get(Target, Plans),
    Admission = crypto:hash(sha256, <<"admission", N:64>>),
    {ok, Goal} = quod_durable_term:encode_goal({fixture, N}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    {ok, Manifest} = quod_dtx:new_manifest(
        #{proof_id => maps:get(proof_id, quod_dtx:core(Plan)),
          coordinator => {Ns, Anchor, Pub, Admission},
          nonce => crypto:hash(sha256, <<"nonce", N:64>>),
          principal => quod_dtx:principal(Plan), goal => Goal, result => Result,
          request_binding => none, vote_deadline_ms => 1800000000000,
          participants => [{T, quod_dtx:digest(P)} || {T, P} <- PlanRows]}),
    Bundles = maps:from_list([begin
        {ok, B} = quod_dtx:encode(P),
        {ok, A} = quod_dtx:attest_plan(1, T, P, Manifest, Signer),
        {T, {T, quod_dtx:digest(P), B, A}}
    end || {T, P} <- PlanRows]),
    {_, _, _, SourceAttestation} = maps:get(Origin, Bundles),
    {ok, G} = quod_atomic:new_group(Manifest, none, SourceAttestation),
    Votes = maps:from_list([begin
        {ok, V} = quod_atomic:new_vote(G, T, Bundle, prepared),
        {T, {signed(T, V, Admission, N + 200, Signer), protocol_ref(T, N + 200, V)}}
    end || {T, Bundle} <- maps:to_list(Bundles)]),
    {C, Ref} = maps:get(Target, Votes),
    #{control => C, ref => Ref, origin => Origin, group => G,
      group_id => quod_atomic:group_id(G), plan => Plan, votes => Votes, plans => Plans}.

participant_commit_resolve(Target, F, Slot) ->
    {_, SourceRef} = maps:get(maps:get(origin, F), maps:get(votes, F)),
    {_, OwnRef} = maps:get(Target, maps:get(votes, F)),
    Rows = lists:sort([{T, Ref} || {T, {_, Ref}} <- maps:to_list(maps:get(votes, F))]),
    Generation = quod_dtx:overlay_generation(maps:get(Target, maps:get(plans, F))) + 1,
    {ok, Resolve} = quod_atomic:new_resolve(maps:get(group, F), SourceRef, Target,
                      commit, {all_prepared, Rows}, OwnRef, Generation),
    Control = signed(Target, Resolve, key(218), Slot, configured_test_signer()),
    Evidence = [{vote, Ref, quod_atomic:control_material(C)}
                 || {_, {C, Ref}} <- maps:to_list(maps:get(votes, F))],
    ok = quod_atomic:validate_references(Control, Evidence),
    {Control, protocol_ref(Target, Slot, Resolve)}.

manifest_with_plan(Manifest, Target, PlanDigest) ->
    setelement(12, Manifest, lists:keyreplace(Target, 1,
      quod_dtx:manifest_participants(Manifest), {Target, PlanDigest})).

transcript_with_goal(Goal) ->
    {<<1:128>>, [{?NS, key(1)}], wire_blob(Goal), allowed,
     0, <<0:256>>, complete}.

unique_symbol(Prefix, N) ->
    <<Prefix/binary, "_", (integer_to_binary(N))/binary>>.

assert_symbols_absent(Names) ->
    [?assertException(error, badarg, binary_to_existing_atom(Name, utf8))
     || Name <- Names].

with_proof_gate(Fun) ->
    Namespace = <<"quod:dtx-guard-test">>,
    Table = 'quod_simplex_genesis_quod:dtx-guard-test',
    Tab = ets:new(Table, [named_table, protected, set]),
    true = ets:insert(Tab, quod_ct:proof_gate_row(true, 7, [])),
    try Fun(Tab, {quod_proof_access, Namespace, 7})
    after
        ets:delete(Tab)
    end.

%% quod_dtx:plan() is opaque to dialyzer; these two are the tests' only
%% deliberate representation crossings.
tuple(Plan) -> Plan.
plan(Tuple) -> Tuple.
readiness(Control, Projection) ->
    quod_atomic:proposal_readiness(quod_atomic:control_material(Control), Projection).
