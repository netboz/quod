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
                     quod_dtx:diff(Plan)),
        ?assertEqual(quod_proof_session:read_set(Session),
                     quod_dtx:read_check(Plan)),
        ?assertMatch(#{{parent, 2} := {present, 1}},
                     quod_dtx:read_check(Plan)),
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
        ?assertEqual(length(quod_dtx:diff(Plan)), quod_dtx:diff_ops(Plan)),
        ?assertMatch(<<_:256>>, quod_dtx:digest(Plan)),
        %% The transcript binds this exact invocation: goal bytes, the full
        %% semantic chain, and the chained digest of the one answer taken.
        [{_InvocationId, Chain, GoalBin, allowed, 1, Digest, active}] =
            quod_dtx:transcript(Plan),
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
        ?assertEqual([], quod_dtx:diff(Plan)),
        ?assertEqual(#{}, quod_dtx:read_check(Plan)),
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
        ?assertEqual([], quod_dtx:diff(Plan)),
        ?assertMatch(#{{parent, 2} := {present, 1}},
                     quod_dtx:read_check(Plan))
    after
        quod_proof_session:stop(Session)
    end.

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
       {remote_claim, RemoteA, [_, _]},
       quod_prolog:test_route_plans(
         #{Origin => OriginRead, RemoteA => RemoteWriteA,
           RemoteC => RemoteReadC}, Origin, true)),
    ?assertMatch(
       {remote_claim, RemoteA, []},
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
    ?assertEqual(lists:sort([RemoteA, RemoteB]), Participants),
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
          Count, Digest, Tag}] = quod_dtx:transcript(Plan),
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
        ?assertEqual([], quod_dtx:diff(Plan)),
        %% The marker never leaks into the OCC read tokens.
        ?assertNot(maps:is_key({'$quod_live_bridge', {directory_host, 5}},
                               quod_dtx:read_check(Plan)))
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
                     quod_dtx:diff(Plan)),
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
%% V2 durable control protocol
%% ------------------------------------------------------------------

control_codec_roundtrips_all_five_fixed_records_test() ->
    F = protocol_fixture(),
    GroupId = maps:get(group_id, F),
    Controls =
        [{'begin', maps:get(begin_control, F)},
         {prepare, maps:get(prepare_a_control, F)},
         {decision, maps:get(decision_control, F)},
         {finalize, maps:get(finalize_a_control, F)},
         {complete, maps:get(complete_control, F)}],
    lists:foreach(
      fun({Kind, Control}) ->
          {ok, Blob} = quod_dtx:encode_control(Control),
          ?assert(byte_size(Blob) =< ?QUOD_MAX_DTX_CONTROL_BYTES),
          ?assert(byte_size(
                    term_to_binary({batch, [{dtx, Blob}]}, [deterministic]))
                  =< ?MAX_BLOCK_BYTES),
          ?assertEqual({ok, Control}, quod_dtx:decode_control(Blob)),
          ?assertEqual(Kind, quod_dtx:control_kind(Control)),
          ?assert(quod_dtx:verify_control(
                    quod_dtx:control_target(Control), Control)),
          ?assertEqual(GroupId, quod_dtx:group_id(Control)),
          ?assertMatch(<<_:256>>, quod_dtx:record_digest(Control)),
          Metadata = quod_dtx:control_metadata(Control),
          ?assertEqual(Kind, maps:get(kind, Metadata)),
          ?assertEqual(quod_dtx:control_target(Control),
                       maps:get(target, Metadata))
      end, Controls),
    ?assertEqual(
       28,
       byte_size(
         term_to_binary({batch, [{dtx, <<>>}]}, [deterministic]))),
    ?assertEqual(
       ?MAX_BLOCK_BYTES - ?QUOD_DTX_BATCH_PAYLOAD_OVERHEAD_BYTES,
       ?QUOD_MAX_DTX_CONTROL_BYTES).

superseded_v2_begin_record_is_rejected_test() ->
    F = protocol_fixture(),
    {quod_dtx_begin, 3,
     {quod_dtx_manifest, 3, ProofId, Coordinator, Nonce, Principal,
      Goal, GoalDigest, Result, ResultDigest, _RequestBinding,
      Participants}, _RequestAuth, Bundles} =
        maps:get(begin_record, F),
    OldManifest =
        {quod_dtx_manifest, 2, ProofId, Coordinator, Nonce, Principal,
         Goal, GoalDigest, Result, ResultDigest, none, Participants},
    OldBegin = {quod_dtx_begin, 2, OldManifest, none, none, Bundles},
    ?assertEqual(
       {error, {protocol_error, bad_payload}},
       quod_dtx:decode_record(term_to_binary(OldBegin, [deterministic]))).

manifest_and_record_constructors_canonicalize_bounded_rows_test() ->
    F = protocol_fixture(),
    Manifest = maps:get(manifest, F),
    Input = maps:get(manifest_input, F),
    Participants = maps:get(participants, Input),
    {ok, Manifest} =
        quod_dtx:new_manifest(Input#{participants := lists:reverse(Participants)}),
    Bundles = maps:get(bundles, F),
    {ok, Begin} = quod_dtx:new_begin(
                    Manifest, none, lists:reverse(Bundles)),
    ?assertEqual(maps:get(begin_record, F), Begin),
    PrepareRows = maps:get(prepare_rows, F),
    {ok, Decision} =
        quod_dtx:new_decision(
          maps:get(group_id, F), maps:get(begin_ref, F), commit,
          lists:reverse(PrepareRows)),
    ?assertEqual(maps:get(decision_record, F), Decision),
    FinalizeRows = maps:get(finalize_rows, F),
    {ok, Complete} =
        quod_dtx:new_complete(
          maps:get(group_id, F), maps:get(decision_ref, F),
          lists:reverse(FinalizeRows)),
    ?assertEqual(maps:get(complete_record, F), Complete),
    Nine = [{identity(N), key(N)} || N <- lists:seq(1, 9)],
    ?assertEqual(
       {error, invalid_manifest},
       quod_dtx:new_manifest(Input#{participants := Nine})),
    ?assertEqual(
       {error, invalid_manifest},
       quod_dtx:new_manifest(Input#{participants := [hd(Participants) | bad_tail]})).

signed_foreign_only_synthetic_begin_is_not_a_dtx_group_test() ->
    with_identity(
      fun(_) ->
          Signer = configured_test_signer(),
          #{pubkey := Pub} = Signer,
          Origin = {<<"quod:synthetic-origin">>, key(220)},
          Foreign = {<<"quod:signed-foreign">>, key(221)},
          ProofId = key(222),
          {Plan, PlanBlob} = protocol_plan(
                               Foreign, ProofId, Origin, {foreign_only, ok}),
          {ok, Goal} = quod_durable_term:encode_goal(foreign_only),
          {ok, Result} = quod_durable_term:encode_result(#{}),
          {ok, Manifest} = quod_dtx:new_manifest(
                             #{proof_id => ProofId,
                               coordinator => {element(1, Origin),
                                               element(2, Origin), Pub, key(223)},
                               nonce => key(224), principal => anonymous,
                               goal => Goal, result => Result,
                               request_binding => none,
                               participants =>
                                   [{Foreign, quod_dtx:digest(Plan)}]}),
          {ok, Attestation} = quod_dtx:attest_plan(
                                Foreign, Plan, Manifest, Signer),
          SingleBundle =
              {Foreign, quod_dtx:digest(Plan), PlanBlob, Attestation},
          SingleBegin =
              {quod_dtx_begin, 3, Manifest, none, [SingleBundle]},
          SingleBeginBlob =
              forge_control_blob(
                'begin', Origin, SingleBegin, key(225), 1, 1, Signer),
          %% One foreign target is an ordinary claim/application/receipt,
          %% never a legacy one-participant DTX group.  Reject that stale
          %% shape at the shared wire/classification boundary, not only later
          %% during semantic verification.
          ?assertEqual(
             {error, {protocol_error, bad_payload}},
             quod_dtx:decode_control(SingleBeginBlob)),
          ?assertEqual(
             invalid,
             quod_ledger:classify(
               {batch, [{dtx, SingleBeginBlob}]})),
          ?assertEqual(
             {error, invalid_begin},
             quod_dtx:new_begin(
               Manifest, none,
               [SingleBundle]))
      end).

unsigned_begin_does_not_require_network_identity_test() ->
    Fixture = protocol_fixture(),
    Begin = maps:get(begin_record, Fixture),
    Origin = maps:get(origin, Fixture),
    ?assertNot(quod_dtx:requires_network_identity(Begin)),
    ?assertEqual(
       {ok, none},
       quod_dtx:validate_request(none, Origin, 0, Begin)),
    Signed = maps:get('begin', quod_ct:signed_dtx_begin_fixture(#{})),
    ?assert(quod_dtx:requires_network_identity(Signed)),
    ?assert(quod_dtx:requires_network_identity(malformed)).

maximum_signed_request_is_preserved_by_transaction_and_begin_test() ->
    Goal = <<"assertz(saved(ok)).">>,
    GoalText =
        <<(binary:copy(
             <<" ">>, ?QUOD_CLIENT_GOAL_TEXT_BYTES - byte_size(Goal)))/binary,
          Goal/binary>>,
    Ns = binary:copy(<<"n">>, ?DIRECTORY_MAX_NAMESPACE_BYTES),
    Target = {Ns, key(221)},
    Fixture = quod_ct:signed_dtx_begin_fixture(
                #{target => Target, goal_text => GoalText}),
    Transaction = maps:get(transaction, Fixture),
    Begin = maps:get('begin', Fixture),
    Network = maps:get(network, Fixture),
    Deadline = maps:get(deadline, Fixture),
    ?assertMatch(
       {ok, #{claim := _}},
       quod_transaction:validate_request(
         Network, Target, Deadline, Transaction)),
    ?assertMatch(
       {ok, #{claim := _}},
       quod_dtx:validate_request(Network, Target, Deadline, Begin)),
    ?assertMatch({ok, _}, quod_dtx:encode_record(Begin)),
    Request = maps:get(request, Fixture),
    ?assertEqual(
       {error, {too_large, goal_text}},
       quod_client_goal:encode(
         Request#{goal_text => <<GoalText/binary, " ">>})).

signed_begin_rejects_changed_request_bytes_even_with_valid_outer_shape_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    Begin = maps:get('begin', Fixture),
    {agent_goal_v1, Digest, <<First, Rest/binary>>, Signature} =
        maps:get(auth, Fixture),
    ForgedAuth =
        {agent_goal_v1, Digest, <<(First bxor 1), Rest/binary>>, Signature},
    ForgedBegin = setelement(4, Begin, ForgedAuth),
    ?assertEqual(
       {error, invalid_request},
       quod_dtx:validate_request(
         maps:get(network, Fixture), maps:get(target, Fixture),
         maps:get(deadline, Fixture), ForgedBegin)),
    ?assertEqual(error, quod_dtx:request_claim(ForgedBegin)).

abort_decision_uses_one_canonical_atom_safe_reason_blob_test() ->
    F = protocol_fixture(),
    Unknown =
        <<"quod_dtx_reason_",
          (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    ?assertException(error, badarg, binary_to_existing_atom(Unknown, utf8)),
    Reasons =
        [{{'$quod_symbol', Unknown},
          reason_identity(maps:get(target_b, F))},
         {prepare_refused, reason_identity(maps:get(target_a, F))}],
    {ok, Abort} =
        quod_dtx:new_decision(
          maps:get(group_id, F), maps:get(begin_ref, F),
          {abort, Reasons}, []),
    ?assertEqual({ok, Reasons}, quod_dtx:decision_failure_reasons(Abort)),
    {quod_dtx_decision, 3, _, _, abort, [], ReasonsBlob} =
        record_tuple(Abort),
    ?assertEqual(
       {ok, ReasonsBlob},
       quod_wire_term:encode_failure_reasons(Reasons)),
    {ok, WireReasons} =
        quod_safe_term:decode(ReasonsBlob, ?ERLOG_MAX_FAILURE_REASONS_BYTES),
    ?assertEqual(
       ReasonsBlob, term_to_binary(WireReasons, [deterministic])),
    Control =
        signed(
          maps:get(origin, F), Abort, maps:get(admission, F), 60,
          maps:get(signer, F)),
    {ok, Encoded} = quod_dtx:encode_control(Control),
    {ok, Decoded} = quod_dtx:decode_control(Encoded),
    ?assertEqual(
       {ok, Reasons}, quod_dtx:decision_failure_reasons(Decoded)),
    ?assertException(error, badarg, binary_to_existing_atom(Unknown, utf8)),
    ?assertEqual(
       none,
       quod_dtx:decision_failure_reasons(maps:get(decision_record, F))),
    %% No old reasonless abort or empty diagnostic stack is accepted.
    ?assertEqual(
       {error, invalid_decision},
       quod_dtx:new_decision(
         maps:get(group_id, F), maps:get(begin_ref, F), abort, [])),
    ?assertEqual(
       {error, invalid_decision},
       quod_dtx:new_decision(
         maps:get(group_id, F), maps:get(begin_ref, F), {abort, []}, [])).

abort_reason_limits_are_exact_and_consensus_deterministic_test() ->
    F = protocol_fixture(),
    GroupId = maps:get(group_id, F),
    BeginRef = maps:get(begin_ref, F),
    AtCount = lists:duplicate(?ERLOG_MAX_FAILURE_REASONS, refused),
    ?assertMatch(
       {ok, _},
       quod_dtx:new_decision(GroupId, BeginRef, {abort, AtCount}, [])),
    ?assertEqual(
       {error, invalid_decision},
       quod_dtx:new_decision(
         GroupId, BeginRef, {abort, [refused | AtCount]}, [])),

    AtReason = reason_binary_at_wire_size(?ERLOG_MAX_FAILURE_REASON_BYTES),
    ?assertEqual(
       ?ERLOG_MAX_FAILURE_REASON_BYTES, reason_wire_size(AtReason)),
    ?assertMatch(
       {ok, _},
       quod_dtx:new_decision(GroupId, BeginRef, {abort, [AtReason]}, [])),
    ?assertEqual(
       {error, invalid_decision},
       quod_dtx:new_decision(
         GroupId, BeginRef, {abort, [<<AtReason/binary, 0>>]}, [])),

    AtStack = failure_reason_stack_at_wire_limit(),
    ?assertEqual(
       ?ERLOG_MAX_FAILURE_REASONS_BYTES, reason_stack_wire_size(AtStack)),
    {ok, AtLimitDecision} =
        quod_dtx:new_decision(GroupId, BeginRef, {abort, AtStack}, []),
    ?assertEqual(
       {ok, AtStack},
       quod_dtx:decision_failure_reasons(AtLimitDecision)),
    Prefix = lists:droplast(AtStack),
    Last = lists:last(AtStack),
    TooLarge = Prefix ++ [<<Last/binary, 0>>],
    ?assert(reason_wire_size(lists:last(TooLarge)) =<
                ?ERLOG_MAX_FAILURE_REASON_BYTES),
    ?assertEqual(
       ?ERLOG_MAX_FAILURE_REASONS_BYTES + 1,
       reason_stack_wire_size(TooLarge)),
    ?assertEqual(
       {error, invalid_decision},
       quod_dtx:new_decision(GroupId, BeginRef, {abort, TooLarge}, [])).

abort_reason_bytes_are_canonical_signed_and_digest_bound_test() ->
    F = protocol_fixture(),
    GroupId = maps:get(group_id, F),
    BeginRef = maps:get(begin_ref, F),
    {ok, First} =
        quod_dtx:new_decision(
          GroupId, BeginRef, {abort, [{failed_at, a}]}, []),
    {ok, Second} =
        quod_dtx:new_decision(
          GroupId, BeginRef, {abort, [{failed_at, b}]}, []),
    ?assertNotEqual(
       quod_dtx:record_digest(First), quod_dtx:record_digest(Second)),
    Signed =
        signed(
          maps:get(origin, F), First, maps:get(admission, F), 61,
          maps:get(signer, F)),
    {quod_dtx_control, 2, decision, Target, _FirstRecord, Author, Admission,
     Sequence, SubmittedAt, Signature} = tuple(Signed),
    Tampered =
        {quod_dtx_control, 2, decision, Target, Second, Author, Admission,
         Sequence, SubmittedAt, Signature},
    ?assertNot(quod_dtx:verify_control(Target, Tampered)),

    {quod_dtx_decision, 3, GroupId, BeginRef, abort, Rows, CanonicalBlob} =
        record_tuple(First),
    NonCanonicalBlob = noncanonical_reason_blob(CanonicalBlob),
    NonCanonical =
        record(
          {quod_dtx_decision, 3, GroupId, BeginRef, abort, Rows,
           NonCanonicalBlob}),
    NonCanonicalControl =
        forge_control_blob(
          decision, Target, NonCanonical, Admission, 62, 62,
          maps:get(signer, F)),
    ?assertEqual(
       {error, {protocol_error, bad_payload}},
       quod_dtx:decode_control(NonCanonicalControl)),
    OldReasonless =
        record({quod_dtx_decision, 3, GroupId, BeginRef, abort, Rows}),
    OldControl =
        forge_control_blob(
          decision, Target, OldReasonless, Admission, 63, 63,
          maps:get(signer, F)),
    ?assertEqual(
       {error, {protocol_error, bad_payload}},
       quod_dtx:decode_control(OldControl)),
    ReasonBearingCommit =
        record(
          {quod_dtx_decision, 3, GroupId, BeginRef, commit,
           lists:keysort(1, maps:get(prepare_rows, F)), CanonicalBlob}),
    CommitControl =
        forge_control_blob(
          decision, Target, ReasonBearingCommit, Admission, 64, 64,
          maps:get(signer, F)),
    ?assertEqual(
       {error, {protocol_error, bad_payload}},
       quod_dtx:decode_control(CommitControl)).

group_id_excludes_only_the_outer_begin_envelope_test() ->
    F = protocol_fixture(),
    Begin = maps:get(begin_record, F),
    Target = maps:get(origin, F),
    Admission = maps:get(admission, F),
    Signer = maps:get(signer, F),
    {ok, A} = quod_dtx:sign_control(Target, Begin, Admission, 1, 10, Signer),
    {ok, B} = quod_dtx:sign_control(Target, Begin, Admission, 99, 20, Signer),
    ?assertNotEqual(A, B),
    ?assertEqual(quod_dtx:record_digest(A), quod_dtx:record_digest(B)),
    ?assertEqual(quod_dtx:group_id(A), quod_dtx:group_id(B)),
    ?assertEqual(quod_dtx:record_digest(Begin), quod_dtx:group_id(Begin)).

forged_attestation_is_structurally_decodable_but_never_verifies_test() ->
    F = protocol_fixture(),
    {quod_dtx_begin, 3, Manifest, RequestAuth, [First | Rest]} =
        record_tuple(maps:get(begin_record, F)),
    {Target, PlanDigest, PlanBlob,
     {quod_dtx_attestation, 2, Target, PlanDigest, ManifestDigest,
      Attestor, Signature}} = First,
    <<Bit:1, Tail/bitstring>> = Signature,
    ForgedAttestation =
        {quod_dtx_attestation, 2, Target, PlanDigest, ManifestDigest,
         Attestor, <<(Bit bxor 1):1, Tail/bitstring>>},
    ForgedBegin =
        record(
          {quod_dtx_begin, 3, Manifest, RequestAuth,
           [{Target, PlanDigest, PlanBlob, ForgedAttestation} | Rest]}),
    ?assertEqual(
       {error, invalid_control},
       quod_dtx:sign_control(
         maps:get(origin, F), ForgedBegin, maps:get(admission, F), 1, 1,
         maps:get(signer, F))),
    ForgedBlob = forge_control_blob(
                   'begin', maps:get(origin, F), ForgedBegin,
                   maps:get(admission, F), 1, 1, maps:get(signer, F)),
    {ok, Decoded} = quod_dtx:decode_control(ForgedBlob),
    ?assertNot(quod_dtx:verify_control(maps:get(origin, F), Decoded)).

plan_attestation_rejects_a_different_valid_plan_test() ->
    F = protocol_fixture(),
    Target = maps:get(target_a, F),
    Plan = maps:get(plan_a, F),
    OtherPlan = maps:get(other_plan_a, F),
    Manifest = maps:get(manifest, F),
    Attestation = bundle_attestation(Target, maps:get(bundles, F)),
    ?assert(quod_dtx:verify_plan_attestation(
              Target, Plan, Manifest, Attestation)),
    ?assertNot(quod_dtx:verify_plan_attestation(
                 Target, OtherPlan, Manifest, Attestation)),
    ?assertEqual(
       {error, invalid_plan_attestation},
       quod_dtx:attest_plan(
         Target, OtherPlan, Manifest, maps:get(signer, F))),
    ?assertNot(quod_dtx:verify_plan_attestation(
                 Target, malformed_plan, Manifest, Attestation)).

effect_only_plan_is_admitted_once_by_the_shared_dtx_validator_test() ->
    with_identity(
      fun(Pub) ->
          Signer = configured_test_signer(),
          Origin = {<<"quod:effect-origin">>, key(241)},
          TargetA = {<<"quod:effect-a">>, key(242)},
          TargetB = {<<"quod:effect-b">>, key(243)},
          ProofId = key(244),
          Principal = {node, Pub},
          {ok, Effect} = quod_effect:new(
                           create, Pub, Principal,
                           {<<"quod:created-by-group">>, key(245)},
                           key(246), key(247)),
          EffectPlan = signed_effect_material_plan(
                         TargetA, ProofId, Origin, Principal, [], [Effect]),
          PlainPlan = signed_effect_material_plan(
                        TargetB, ProofId, Origin, Principal, [], []),
          {ok, Goal} = quod_durable_term:encode_goal({create, grouped}),
          {ok, Result} = quod_durable_term:encode_result(#{}),
          Participants = lists:sort(
                           [{TargetA, quod_dtx:digest(EffectPlan)},
                            {TargetB, quod_dtx:digest(PlainPlan)}]),
          {ok, Manifest} = quod_dtx:new_manifest(
                             #{proof_id => ProofId,
                               coordinator =>
                                   {element(1, Origin), element(2, Origin),
                                    Pub, key(248)},
                               nonce => key(249), principal => Principal,
                               goal => Goal, result => Result,
                               request_binding => none,
                               participants => Participants}),
          {ok, EffectAttestation} = quod_dtx:attest_plan(
                                      TargetA, EffectPlan, Manifest, Signer),
          {ok, PlainAttestation} = quod_dtx:attest_plan(
                                     TargetB, PlainPlan, Manifest, Signer),
          {ok, EffectBlob} = quod_dtx:encode(EffectPlan),
          {ok, PlainBlob} = quod_dtx:encode(PlainPlan),
          ?assertMatch(
             {ok, _},
             quod_dtx:new_begin(
               Manifest, none,
               [{TargetA, quod_dtx:digest(EffectPlan), EffectBlob,
                 EffectAttestation},
                {TargetB, quod_dtx:digest(PlainPlan), PlainBlob,
                 PlainAttestation}])),

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
             quod_dtx:attest_plan(
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
             quod_dtx:attest_plan(
               TargetA, DiffAndEffectPlan,
               manifest_with_plan(
                 Manifest, TargetA, quod_dtx:digest(DiffAndEffectPlan)),
               Signer))
      end).

noncanonical_plan_envelope_cannot_change_a_group_id_test() ->
    F = protocol_fixture(),
    Plan = maps:get(plan_a, F),
    NonCanonicalBlob = noncanonical_plan_blob(Plan),
    {ok, CanonicalBlob} = quod_dtx:encode(Plan),
    ?assertNotEqual(CanonicalBlob, NonCanonicalBlob),
    %% Both ETF encodings denote the same signed Erlang term. Only the one
    %% canonical byte identity is admissible inside a semantic DTX record.
    ?assertEqual(Plan, binary_to_term(NonCanonicalBlob, [safe])),
    ?assertEqual(
       {error, {protocol_error, bad_payload}},
       quod_dtx:decode(NonCanonicalBlob)),
    Target = maps:get(target_a, F),
    Bundles =
        [case Bundle of
             {Target, Digest, _Blob, Attestation} ->
                 {Target, Digest, NonCanonicalBlob, Attestation};
             Other -> Other
         end || Bundle <- maps:get(bundles, F)],
    ?assertEqual(
       {error, invalid_begin},
       quod_dtx:new_begin(maps:get(manifest, F), none, Bundles)).

phase_target_bindings_reject_substitution_test() ->
    F = protocol_fixture(),
    WrongTarget = {<<"quod:wrong">>, key(250)},
    Admission = maps:get(admission, F),
    Signer = maps:get(signer, F),
    Records =
        [maps:get(begin_record, F), maps:get(prepare_a_record, F),
         maps:get(decision_record, F), maps:get(finalize_a_record, F),
         maps:get(complete_record, F)],
    lists:foreach(
      fun(Record) ->
          ?assertEqual(
             {error, invalid_control},
             quod_dtx:sign_control(
               WrongTarget, Record, Admission, 11, 1, Signer))
      end, Records).

decode_is_total_and_rejects_noncanonical_or_oversized_controls_test() ->
    F = protocol_fixture(),
    ?assertEqual(
       {error, {too_large, dtx_control}},
       quod_dtx:decode_control(
         <<0:(?QUOD_MAX_DTX_CONTROL_BYTES + 1)/unit:8>>)),
    ?assertMatch(
       {error, {protocol_error, bad_payload}},
       quod_dtx:decode_control(term_to_binary({'not', a, control}))),
    {quod_dtx_begin, 3, Manifest, RequestAuth, Bundles} =
        record_tuple(maps:get(begin_record, F)),
    NonCanonical =
        record({quod_dtx_begin, 3, Manifest, RequestAuth,
                lists:reverse(Bundles)}),
    Blob = forge_control_blob(
             'begin', maps:get(origin, F), NonCanonical,
             maps:get(admission, F), 1, 1, maps:get(signer, F)),
    ?assertMatch(
       {error, {protocol_error, bad_payload}},
       quod_dtx:decode_control(Blob)).

prepare_payload_is_self_contained_and_confined_to_prepare_controls_test() ->
    F = protocol_fixture(),
    {ok, PlanBlob} = quod_dtx:encode(maps:get(plan_a, F)),
    ?assertEqual(
       {ok, maps:get(manifest, F), quod_dtx:digest(maps:get(plan_a, F)),
        PlanBlob},
       quod_dtx:prepare_payload(maps:get(prepare_a_control, F))),
    ?assert(
       quod_dtx:prepare_matches_begin(
         maps:get(prepare_a_control, F), maps:get(begin_control, F))),
    ?assertEqual(
       error,
       quod_dtx:prepare_payload(maps:get(begin_control, F))),
    ?assertEqual(error, quod_dtx:prepare_payload(malformed)).

prepare_is_derived_from_the_exact_begin_target_without_legacy_shape_test() ->
    F = protocol_fixture(),
    Begin = maps:get(begin_record, F),
    BeginRef = maps:get(begin_ref, F),
    Target = maps:get(target_a, F),
    {ok, Prepare} = quod_dtx:new_prepare(Begin, BeginRef, Target),
    ?assertEqual(maps:get(prepare_a_record, F), Prepare),
    ?assert(quod_dtx:prepare_matches_begin(Prepare, Begin)),
    ?assertEqual(
       {error, invalid_prepare},
       quod_dtx:new_prepare(Begin, BeginRef, {<<"quod:absent">>, key(198)})),
    WrongRef = protocol_ref(maps:get(origin, F), 99, Prepare),
    ?assertEqual(
       {error, invalid_prepare},
       quod_dtx:new_prepare(Begin, WrongRef, Target)),
    %% The former six-field Prepare is a deliberate protocol hard break.
    {quod_dtx_prepare, 3, GroupId, _, _, PlanDigest, PlanBlob} = Prepare,
    Legacy = {quod_dtx_prepare, 3, GroupId, BeginRef, PlanDigest, PlanBlob},
    ?assertEqual(
       {error, {protocol_error, bad_payload}},
       quod_dtx:decode_record(term_to_binary(Legacy, [deterministic]))).

prepare_manifest_is_checked_against_begin_and_yields_exact_event_context_test() ->
    F = protocol_fixture(),
    Prepare = maps:get(prepare_a_record, F),
    Begin = maps:get(begin_record, F),
    Manifest = maps:get(manifest, F),
    Plan = maps:get(plan_a, F),
    {quod_dtx_prepare, 3, GroupId, BeginRef, _, PlanDigest, PlanBlob} = Prepare,
    TamperedManifest = setelement(6, Manifest, {node, key(199)}),
    Tampered = {quod_dtx_prepare, 3, GroupId, BeginRef, TamperedManifest,
                PlanDigest, PlanBlob},
    ?assertEqual(error, quod_dtx:prepare_payload(Tampered)),
    ?assertNot(quod_dtx:prepare_matches_begin(Tampered, Begin)),
    {ok, Context} = quod_dtx:event_context(Manifest, Plan),
    ?assertEqual(maps:get(proof_id, F), maps:get(proof_id, Context)),
    ?assertEqual(maps:get(origin, F), maps:get(origin, Context)),
    ?assertEqual(anonymous, maps:get(principal, Context)),
    ?assertEqual(PlanDigest, maps:get(plan_digest, Context)),
    ?assert(is_binary(maps:get(goal, Context))),
    ?assert(is_binary(maps:get(result, Context))),
    ?assertEqual(error, quod_dtx:event_context(TamperedManifest, Plan)).

reference_validation_is_exhaustive_and_rejects_cross_group_or_verdict_test() ->
    F = protocol_fixture(),
    BeginControl = maps:get(begin_control, F),
    BeginRef = maps:get(begin_ref, F),
    PrepareAControl = maps:get(prepare_a_control, F),
    PrepareARef = maps:get(prepare_a_ref, F),
    DecisionControl = maps:get(decision_control, F),
    DecisionRef = maps:get(decision_ref, F),
    ?assertEqual(ok, quod_dtx:validate_references(BeginControl, [])),
    ?assertEqual(
       ok,
       quod_dtx:validate_references(
         PrepareAControl, [{'begin', BeginRef, BeginControl}])),
    {quod_dtx_decision, 3, _, _, commit, PrepareRows, _} =
        maps:get(decision_record, F),
    DecisionEvidence =
        [{'begin', BeginRef, BeginControl} |
         [{prepare, Ref, fixture_prepare_control(F, Ref)}
          || {_Target, Ref} <- PrepareRows]],
    ?assertEqual(
       ok, quod_dtx:validate_references(DecisionControl, DecisionEvidence)),
    ?assertEqual(
       ok,
       quod_dtx:validate_references(
         maps:get(finalize_a_control, F),
         [{decision, DecisionRef, DecisionControl},
          {prepare, PrepareARef, PrepareAControl}])),
    {quod_dtx_complete, 3, _, _, FinalizeRows} =
        maps:get(complete_record, F),
    CompleteEvidence =
        [{decision, DecisionRef, DecisionControl} |
         [{finalize, Ref, fixture_finalize_control(F, Ref)}
          || {_Target, Ref, _Generation} <- FinalizeRows]],
    ?assertEqual(
       ok,
       quod_dtx:validate_references(
         maps:get(complete_control, F), CompleteEvidence)),

    %% A fully signed and exactly referenced Prepare from another group cannot
    %% be smuggled into this Decision.
    PlanA = maps:get(plan_a, F),
    PlanB = maps:get(plan_b, F),
    {ok, PlanABlob} = quod_dtx:encode(PlanA),
    {ok, PlanBBlob} = quod_dtx:encode(PlanB),
    ForeignManifestInput =
        (maps:get(manifest_input, F))#{nonce := key(197)},
    {ok, ForeignManifest} = quod_dtx:new_manifest(ForeignManifestInput),
    {ok, ForeignAttA} = quod_dtx:attest_plan(
                          maps:get(target_a, F), PlanA,
                          ForeignManifest, maps:get(signer, F)),
    {ok, ForeignAttB} = quod_dtx:attest_plan(
                          maps:get(target_b, F), PlanB,
                          ForeignManifest, maps:get(signer, F)),
    {ok, ForeignBegin} = quod_dtx:new_begin(
                           ForeignManifest, none,
                           [{maps:get(target_a, F), quod_dtx:digest(PlanA),
                             PlanABlob, ForeignAttA},
                            {maps:get(target_b, F), quod_dtx:digest(PlanB),
                             PlanBBlob, ForeignAttB}]),
    ForeignBeginRef = protocol_ref(maps:get(origin, F), 69, ForeignBegin),
    {ok, ForeignPrepare} = quod_dtx:new_prepare(
                             ForeignBegin, ForeignBeginRef,
                             maps:get(target_a, F)),
    ForeignPrepareControl = signed(
                              maps:get(target_a, F), ForeignPrepare,
                              maps:get(admission, F), 70,
                              maps:get(signer, F)),
    ForeignPrepareRef = protocol_ref(
                          maps:get(target_a, F), 70, ForeignPrepare),
    {ok, CrossDecision} = quod_dtx:new_decision(
                            maps:get(group_id, F), BeginRef, commit,
                            [{maps:get(target_a, F), ForeignPrepareRef},
                             {maps:get(target_b, F),
                              maps:get(prepare_b_ref, F)}]),
    CrossDecisionControl = signed(
                             maps:get(origin, F), CrossDecision,
                             maps:get(admission, F), 71,
                             maps:get(signer, F)),
    {quod_dtx_decision, 3, _, _, _, CrossRows, _} = CrossDecision,
    CrossEvidence =
        [{'begin', BeginRef, BeginControl} |
         [{prepare, Ref,
           case Ref of
               ForeignPrepareRef -> ForeignPrepareControl;
               _ -> maps:get(prepare_b_control, F)
           end}
          || {_Target, Ref} <- CrossRows]],
    ?assertEqual(
       {error, invalid_references},
       quod_dtx:validate_references(
         CrossDecisionControl, CrossEvidence)),

    %% A Finalize cannot contradict the certified Decision verdict.
    {ok, WrongVerdictFinalize} = quod_dtx:new_finalize(
                                   maps:get(group_id, F), DecisionRef, abort,
                                   PrepareARef, 1),
    WrongVerdictControl = signed(
                            maps:get(target_a, F), WrongVerdictFinalize,
                            maps:get(admission, F), 72,
                            maps:get(signer, F)),
    ?assertEqual(
       {error, invalid_references},
       quod_dtx:validate_references(
         WrongVerdictControl,
         [{decision, DecisionRef, DecisionControl},
          {prepare, PrepareARef, PrepareAControl}])).

preview_uses_the_shared_reducer_with_an_exact_candidate_ref_test() ->
    F = protocol_fixture(),
    {Ns, Anchor} = Target = maps:get(origin, F),
    Control = maps:get(begin_control, F),
    Slot = 17,
    BlockHash = key(240),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Target, 0),
    Preview = dtx_preview(
                Control, Target, Slot, BlockHash, H0, P0),
    {ok, H1, P1, [_]} = Preview,
    BeginEntry = maps:get('begin', maps:get(records, H1)),
    CandidateRef = maps:get(ref, BeginEntry),
    ?assertMatch(
       {quod_dtx_ref, 2, Ns, Anchor, Slot, BlockHash, _Digest,
        <<_/binary>>},
       CandidateRef),
    ?assertEqual(
       quod_dtx:record_digest(Control), element(7, CandidateRef)),
    %% This is the reducer's exact result, not a second transition model.
    ?assertEqual(
       Preview,
       quod_dtx:reduce(Control, CandidateRef, H0, P0)),
    %% A parent-state rejection and malformed candidate inputs stay fail-closed.
    ?assertEqual(
       {error, {invalid_transition, stale}},
       dtx_preview(
         Control, Target, Slot + 1, key(241), H0, P1)),
    ?assertEqual(
       {error, {invalid_transition, malformed_batch}},
       dtx_preview(
         Control, Target, 0, BlockHash, H0, P0)),
    ?assertEqual(
       {error, {invalid_transition, bad_binding}},
       dtx_preview(
         Control, {Ns, key(242)}, Slot, BlockHash, H0, P0)).

material_source_is_prepared_by_begin_and_applied_by_decision_test() ->
    F = source_fused_protocol_fixture(),
    Origin = maps:get(origin, F),
    Begin = maps:get(begin_record, F),
    BeginRef = maps:get(begin_ref, F),
    ?assertEqual(
       {error, invalid_prepare},
       quod_dtx:new_prepare(Begin, BeginRef, Origin)),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Origin, 0),
    {ok, H1, P1,
     [{origin_started, _, BeginRef},
      {prepared, _, BeginRef, _, _, _, 1}]} =
        quod_dtx:reduce(
          maps:get(begin_control, F), BeginRef, H0, P0),
    ?assertMatch(
       #{prepare_kind := 'begin', prepare_ref := BeginRef},
       maps:get(participant, test_group(P1, maps:get(group_id, F)))),
    ?assertEqual(0, maps:get(generation, P1)),
    ?assertEqual(#{}, maps:get(apply_fences, P1)),
    DecisionRef = maps:get(decision_ref, F),
    {ok, H2, P2,
     [{decided, _, commit, DecisionRef},
      {apply_prepared, _, _, _, _, DecisionRef, 2}]} =
        quod_dtx:reduce(
          maps:get(decision_control, F), DecisionRef, H1, P1),
    ?assertEqual(none, maps:get(participant, test_group(P2, maps:get(group_id, F)))),
    ?assertMatch(#{slot := _, generation := 2},
                 maps:get(maps:get(group_id, F), maps:get(apply_fences, P2))),
    ?assertEqual(1, maps:get(generation, P2)),
    %% A prospective Complete is blocked until this validator has applied the
    %% source Decision.  Certified replay has no live apply callback, so the
    %% exact terminal Complete consumes the matching reconstructed fence.
    ?assertEqual(
       {error, {invalid_transition, apply}},
       dtx_preview(
         maps:get(complete_control, F), Origin, 40, key(244), H2, P2)),
    {ok, _ReplayHistory, ReplayProjection, [_]} =
        quod_dtx:reduce(
          maps:get(complete_control, F), maps:get(complete_ref, F), H2, P2),
    ?assertEqual(#{}, maps:get(apply_fences, ReplayProjection)),
    ?assertEqual(#{}, maps:get(groups, ReplayProjection)),
    GroupId = maps:get(group_id, F),
    Fence = maps:get(GroupId, maps:get(apply_fences, P2)),
    WrongGeneration =
        P2#{apply_fences :=
                #{GroupId => Fence#{generation := 3}}},
    WrongSlot =
        P2#{apply_fences :=
                #{GroupId => Fence#{slot := maps:get(slot, Fence) + 1}}},
    ?assertEqual(
       {error, {invalid_transition, bad_completion_set}},
       quod_dtx:reduce(
         maps:get(complete_control, F), maps:get(complete_ref, F),
         H2, WrongGeneration)),
    ?assertEqual(
       {error, {invalid_transition, bad_completion_set}},
       quod_dtx:reduce(
         maps:get(complete_control, F), maps:get(complete_ref, F),
         H2, WrongSlot)),
    ?assertEqual(
       {error, {invalid_transition, bad_completion_set}},
       quod_dtx:reduce(
         maps:get(complete_control, F), maps:get(complete_ref, F),
         H2, P2#{apply_fences := #{}})),
    {ok, P3} = quod_dtx:acknowledge_finalize(
                 GroupId, ref_slot_test(DecisionRef), 2, P2),
    ?assertEqual(
       Fence#{blocking := false},
       maps:get(GroupId, maps:get(apply_fences, P3))),
    %% The exact ordered-apply acknowledgement is idempotent. It opens proof
    %% access but Complete remains the sole consumer of the source marker.
    {ok, P3} = quod_dtx:acknowledge_finalize(
                 GroupId, ref_slot_test(DecisionRef), 2, P3),
    {ok, _H3, P4, [_]} = quod_dtx:reduce(
                           maps:get(complete_control, F),
                           maps:get(complete_ref, F), H2, P3),
    ?assertEqual(#{}, maps:get(groups, P4)),
    ?assertEqual(#{}, maps:get(apply_fences, P4)),
    ?assertEqual(
       ok,
       quod_dtx:validate_references(
         maps:get(decision_control, F),
         [{'begin', BeginRef, maps:get(begin_control, F)},
          {prepare, maps:get(prepare_remote_ref, F),
           maps:get(prepare_remote_control, F)}])),
    ?assertEqual(
       ok,
       quod_dtx:validate_references(
         maps:get(complete_control, F),
         [{decision, DecisionRef, maps:get(decision_control, F)},
          {finalize, maps:get(finalize_remote_ref, F),
         maps:get(finalize_remote_control, F)}])).

%% Live proposal validation requires the ephemeral applied certificate for a
%% prepared remote Finalize.  Certified replay/catch-up does not: it rebuilds
%% state solely from the committed Begin, Decision and Complete records.  This
%% test deliberately calls the reducer API, which has no sidecar argument, and
%% compares that replay result with the ordinary live applied-fence path.
prepared_remote_complete_replay_needs_no_applied_sidecar_test() ->
    F = source_fused_protocol_fixture(),
    Origin = maps:get(origin, F),
    Remote = maps:get(remote, F),
    GroupId = maps:get(group_id, F),
    BeginControl = maps:get(begin_control, F),
    BeginRef = maps:get(begin_ref, F),
    DecisionControl = maps:get(decision_control, F),
    DecisionRef = maps:get(decision_ref, F),
    FinalizeControl = maps:get(finalize_remote_control, F),
    FinalizeRef = maps:get(finalize_remote_ref, F),
    CompleteControl = maps:get(complete_control, F),
    CompleteRef = maps:get(complete_ref, F),
    {ok, #{kind := finalize, prepare_ref := PrepareRef}} =
        quod_dtx:recovery_phase(quod_dtx:control_body(FinalizeControl)),
    ?assertNotEqual(none, PrepareRef),
    {quod_dtx_complete, 3, GroupId, DecisionRef, CompleteRows} =
        quod_dtx:control_body(CompleteControl),
    ?assertEqual(
       {Remote, FinalizeRef, 2},
       lists:keyfind(Remote, 1, CompleteRows)),

    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Origin, 0),
    {ok, H1, P1, _} =
        quod_dtx:reduce(BeginControl, BeginRef, H0, P0),
    {ok, H2, P2, _} =
        quod_dtx:reduce(DecisionControl, DecisionRef, H1, P1),
    ?assertEqual(
       {blocked, apply},
       quod_dtx:proposal_readiness(
         quod_dtx:control_body(CompleteControl), P2)),

    %% The live owner opens its source fence after ordered apply.  The
    %% certified replay path instead consumes the exact committed Complete
    %% directly; both must rebuild the same durable state.
    {ok, LiveP2} = quod_dtx:acknowledge_finalize(
                     GroupId, ref_slot_test(DecisionRef), 2, P2),
    {ok, LiveH3, LiveP3, LiveEffects} =
        quod_dtx:reduce(
          CompleteControl, CompleteRef, H2, LiveP2),
    {ok, ReplayH1, ReplayP1, _} =
        quod_dtx:reduce(BeginControl, BeginRef, H0, P0),
    {ok, ReplayH2, ReplayP2, _} =
        quod_dtx:reduce(
          DecisionControl, DecisionRef, ReplayH1, ReplayP1),
    {ok, ReplayH3, ReplayP3, ReplayEffects} =
        quod_dtx:reduce(
          CompleteControl, CompleteRef, ReplayH2, ReplayP2),
    ?assertEqual(LiveH3, ReplayH3),
    ?assertEqual(LiveP3, ReplayP3),
    ?assertEqual(LiveEffects, ReplayEffects),
    ?assertEqual(#{}, maps:get(groups, ReplayP3)),
    ?assertEqual(#{}, maps:get(apply_fences, ReplayP3)),
    ?assertEqual([], quod_dtx:origin_recoveries(ReplayP3)).

source_event_only_commit_retains_nonblocking_marker_until_complete_test() ->
    F = source_fused_event_protocol_fixture(),
    Origin = maps:get(origin, F),
    GroupId = maps:get(group_id, F),
    DecisionRef = maps:get(decision_ref, F),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Origin, 0),
    {ok, H1, P1, _} = quod_dtx:reduce(
                         maps:get(begin_control, F), maps:get(begin_ref, F),
                         H0, P0),
    {ok, H2, P2, _} = quod_dtx:reduce(
                         maps:get(decision_control, F), DecisionRef, H1, P1),
    ?assertEqual(
       #{slot => ref_slot_test(DecisionRef), generation => 1,
         blocking => false},
       maps:get(GroupId, maps:get(apply_fences, P2))),
    ?assert(quod_dtx:valid_projection(P2)),
    ?assertEqual(
       ready,
       quod_dtx:proposal_readiness(
         quod_dtx:control_body(maps:get(complete_control, F)), P2)),
    {ok, _H3, P3, [_]} = quod_dtx:reduce(
                           maps:get(complete_control, F),
                           maps:get(complete_ref, F), H2, P2),
    ?assertEqual(#{}, maps:get(apply_fences, P3)),
    ?assertEqual(#{}, maps:get(groups, P3)).

source_abort_retains_exact_nonblocking_marker_until_complete_test() ->
    with_identity(fun source_abort_retains_exact_nonblocking_marker/1).

source_abort_retains_exact_nonblocking_marker(Pub) ->
    F = source_fused_protocol_fixture(Pub),
    Origin = maps:get(origin, F),
    Remote = maps:get(remote, F),
    GroupId = maps:get(group_id, F),
    BeginRef = maps:get(begin_ref, F),
    Signer = configured_test_signer(),
    Reasons = [{prepare_refused, reason_identity(Remote)}],
    {ok, Decision} = quod_dtx:new_decision(
                       GroupId, BeginRef, {abort, Reasons},
                       [{Origin, BeginRef}]),
    ?assertMatch({ok, _}, quod_dtx:encode_record(Decision)),
    ?assertMatch({ok, Origin, _, GroupId},
                 quod_dtx:certified_ref_binding(BeginRef)),
    DecisionControl = signed(Origin, Decision, key(180), 2, Signer),
    DecisionRef = protocol_ref(Origin, 2, Decision),
    {ok, RemoteFinalize} = quod_dtx:new_finalize(
                             GroupId, DecisionRef, abort, none, 1),
    RemoteFinalizeRef = protocol_ref(Remote, 2, RemoteFinalize),
    {ok, Complete} = quod_dtx:new_complete(
                       GroupId, DecisionRef,
                       [{Origin, DecisionRef, 1},
                        {Remote, RemoteFinalizeRef, 1}]),
    CompleteControl = signed(Origin, Complete, key(180), 3, Signer),
    CompleteRef = protocol_ref(Origin, 3, Complete),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Origin, 0),
    {ok, H1, P1, _} = quod_dtx:reduce(
                         maps:get(begin_control, F), BeginRef, H0, P0),
    {ok, H2, P2, _} = quod_dtx:reduce(
                         DecisionControl, DecisionRef, H1, P1),
    ?assertEqual(
       #{slot => ref_slot_test(DecisionRef), generation => 1,
         blocking => false},
       maps:get(GroupId, maps:get(apply_fences, P2))),
    ?assert(quod_dtx:valid_projection(P2)),
    ?assertEqual(ready, quod_dtx:proposal_readiness(
                          quod_dtx:control_body(CompleteControl), P2)),
    {ok, _H3, P3, [{completed, GroupId, abort, CompleteRef, Reasons}]} =
        quod_dtx:reduce(CompleteControl, CompleteRef, H2, P2),
    ?assertEqual(#{}, maps:get(apply_fences, P3)),
    ?assertEqual(#{}, maps:get(groups, P3)).

material_source_generation_exhaustion_is_rejected_not_crashed_test() ->
    F = source_fused_protocol_fixture_at_generation(16#FFFFFFFFFFFFFFFF),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(maps:get(origin, F), 0),
    {ok, H1, P1, [_, _]} =
        quod_dtx:reduce(
          maps:get(begin_control, F), maps:get(begin_ref, F), H0, P0),
    ?assert(quod_dtx:valid_projection(P1)),
    ?assertEqual(
       {error, {invalid_transition, generation_exhausted}},
       quod_dtx:reduce(
         maps:get(decision_control, F), maps:get(decision_ref, F),
         H1, P1)).

source_fusion_preserves_origin_and_participant_roles_test() ->
    F = source_fused_protocol_fixture(),
    Target = maps:get(origin, F),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Target, 0),
    {ok, H1, P1, [_, _]} =
        quod_dtx:reduce(
          maps:get(begin_control, F), maps:get(begin_ref, F), H0, P0),
    ?assertEqual(
       [{maps:get(group_id, F), maps:get(begin_ref, F)}],
       quod_dtx:origin_recoveries(P1)),
    Active2 = test_group(P1, maps:get(group_id, F)),
    ?assertNotEqual(none, maps:get(origin, Active2)),
    ?assertNotEqual(none, maps:get(participant, Active2)),
    {ok, H3, P3, [_, _]} =
        quod_dtx:reduce(
          maps:get(decision_control, F), maps:get(decision_ref, F), H1, P1),
    Active4 = test_group(P3, maps:get(group_id, F)),
    ?assertNotEqual(none, maps:get(origin, Active4)),
    ?assertEqual(none, maps:get(participant, Active4)),
    ?assertMatch(#{generation := 2},
                 maps:get(maps:get(group_id, F), maps:get(apply_fences, P3))),
    {ok, P5} = quod_dtx:acknowledge_finalize(
                 maps:get(group_id, F), ref_slot_test(maps:get(decision_ref, F)),
                 2, P3),
    {ok, H5, P6, [_]} =
        quod_dtx:reduce(
          maps:get(complete_control, F), maps:get(complete_ref, F), H3, P5),
    ?assertEqual(#{}, maps:get(groups, P6)),
    ?assertEqual([], quod_dtx:origin_recoveries(P6)),
    ?assertEqual([], quod_dtx:origin_recoveries(P6#{generation := broken})),
    %% The exact same semantic Decision under another valid envelope is a no-op.
    {ok, H3, P3, []} =
        quod_dtx:reduce(
          maps:get(decision_control, F),
          maps:get(decision_ref, F), H3, P3),
    ?assertEqual(3, map_size(maps:get(records, H5))).

proposal_admission_follows_the_active_group_phase_test() ->
    F = source_fused_protocol_fixture(),
    Target = maps:get(origin, F),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Target, 0),
    Begin = maps:get(begin_record, F),
    Decision = quod_dtx:control_body(maps:get(decision_control, F)),
    Complete = quod_dtx:control_body(maps:get(complete_control, F)),
    ?assertEqual(ready, quod_dtx:proposal_readiness(Begin, P0)),
    ?assertEqual(stale, quod_dtx:proposal_readiness(Decision, P0)),
    ApplyWindow0 = P0#{apply_fences :=
                           #{<<99:256>> => #{slot => 1, generation => 0,
                                             blocking => true}}},
    ?assertEqual(ready, quod_dtx:proposal_readiness(Begin, ApplyWindow0)),
    ?assertMatch(
       {ok, _, _, _},
       quod_dtx:reduce(
         maps:get(begin_control, F), maps:get(begin_ref, F),
         H0, ApplyWindow0)),
    {ok, H1, P1, [_, _]} =
        quod_dtx:reduce(
          maps:get(begin_control, F), maps:get(begin_ref, F), H0, P0),
    ?assertEqual(#{}, maps:get(apply_fences, P1)),
    ?assertEqual(ready, quod_dtx:proposal_readiness(Decision, P1)),
    {ok, H2, P2, [_, _]} =
        quod_dtx:reduce(
          maps:get(decision_control, F), maps:get(decision_ref, F), H1, P1),
    ?assertEqual(
       {blocked, apply}, quod_dtx:proposal_readiness(Complete, P2)),
    ?assertEqual(
       {error, {invalid_transition, apply}},
       dtx_preview(
         maps:get(complete_control, F), Target, 60, key(245), H2, P2)),
    {ok, _CertifiedH, CertifiedP, [_]} =
        quod_dtx:reduce(
          maps:get(complete_control, F), maps:get(complete_ref, F), H2, P2),
    ?assertEqual(#{}, maps:get(apply_fences, CertifiedP)),
    {ok, P5} = quod_dtx:acknowledge_finalize(
                 maps:get(group_id, F),
                 ref_slot_test(maps:get(decision_ref, F)), 2, P2),
    {ok, _H3, P6, _} = quod_dtx:reduce(
                           maps:get(complete_control, F),
                           maps:get(complete_ref, F), H2, P5),
    ?assertEqual(ready, quod_dtx:proposal_readiness(Complete, P5)),
    ?assertEqual([], quod_dtx:origin_recoveries(P6)).

%% The valid local gate shapes are a closed set. Cross every phase with every
%% reachable local protocol/gate shape, and use the reducer before/after the
%% exact local apply acknowledgement as the oracle.
%% This prevents a newly added readiness clause from silently forgetting one
%% pending-apply cell.  The prospective preview is the admission authority;
%% the reducer consumes only already-certified history.
proposal_readiness_covers_the_reducer_gate_matrix_test() ->
    F = source_fused_protocol_fixture(),
    Target = maps:get(origin, F),
    GroupId = maps:get(group_id, F),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Target, 0),
    Begin = maps:get(begin_record, F),
    Decision = quod_dtx:control_body(maps:get(decision_control, F)),
    Complete = quod_dtx:control_body(maps:get(complete_control, F)),
    ?assertEqual(ready, quod_dtx:proposal_readiness(Begin, P0)),
    ?assertEqual(stale, quod_dtx:proposal_readiness(Decision, P0)),
    ?assertEqual(stale, quod_dtx:proposal_readiness(Complete, P0)),
    {ok, H1, P1, [_, _]} = quod_dtx:reduce(
                         maps:get(begin_control, F),
                         maps:get(begin_ref, F), H0, P0),
    ?assertEqual(ready, quod_dtx:proposal_readiness(Decision, P1)),
    {ok, H2, P2, [_, _]} = quod_dtx:reduce(
                         maps:get(decision_control, F),
                         maps:get(decision_ref, F), H1, P1),
    ?assertEqual(
       {blocked, apply}, quod_dtx:proposal_readiness(Complete, P2)),
    ?assertEqual(
       {error, {invalid_transition, apply}},
       dtx_preview(
         maps:get(complete_control, F), Target, 61, key(246), H2, P2)),
    {ok, P3} = quod_dtx:acknowledge_finalize(
                 GroupId, ref_slot_test(maps:get(decision_ref, F)), 2, P2),
    ?assertEqual(ready, quod_dtx:proposal_readiness(Complete, P3)),
    ?assertMatch(
       {ok, _, _, _},
       quod_dtx:reduce(
         maps:get(complete_control, F), maps:get(complete_ref, F), H2, P3)).

abort_reducer_retains_exact_reasons_until_complete_live_and_replay_test() ->
    with_identity(fun abort_reducer_retains_exact_reasons/1).

abort_reducer_retains_exact_reasons(Pub) ->
    F = protocol_fixture(Pub),
    Origin = maps:get(origin, F),
    G = origin_only_group(F, Origin),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Origin, 0),
    {ok, H1, P1, [_]} =
        quod_dtx:reduce(
          maps:get(begin_control, G), maps:get(begin_ref, G), H0, P0),
    {ok, H2, P2, [{decided, GroupId, abort, DecisionRef}]} =
        quod_dtx:reduce(
          maps:get(decision_control, G), maps:get(decision_ref, G), H1, P1),
    Reasons = maps:get(abort_reasons, G),
    OriginRole = maps:get(origin, test_group(P2, GroupId)),
    DecisionEntry = maps:get(decision, maps:get(records, H2)),
    StoredDecision = maps:get(record, DecisionEntry),
    {quod_dtx_decision, 3, _, _, abort, _, ReasonsBlob} =
        record_tuple(StoredDecision),
    ?assert(is_binary(ReasonsBlob)),
    ?assertEqual(
       {ok, Reasons},
       quod_dtx:decision_failure_reasons(maps:get(decision_control, G))),
    {ok, OtherDecision} =
        quod_dtx:new_decision(
          GroupId, maps:get(begin_ref, G),
          {abort, [{different_failure, reason_identity(Origin)}]}, []),
    TamperedHistory =
        H2#{records :=
              (maps:get(records, H2))#{
                decision => DecisionEntry#{record := OtherDecision}}},
    ?assertEqual(
       {error, {invalid_transition, malformed_state}},
       quod_dtx:reduce(
         maps:get(complete_control, G), maps:get(complete_ref, G),
         TamperedHistory, P2)),
    ExpectedEffect =
        {completed, GroupId, abort, maps:get(complete_ref, G), Reasons},
    %% This origin did not fuse a source participant. Even an otherwise
    %% well-shaped marker for its Decision cannot be consumed by a Complete
    %% whose rows contain no source entry.
    SpuriousMarker =
        P2#{apply_fences :=
                #{GroupId =>
                      #{slot => ref_slot_test(DecisionRef), generation => 0,
                        blocking => false}}},
    ?assert(quod_dtx:valid_projection(SpuriousMarker)),
    ?assertEqual(
       {error, {invalid_transition, bad_completion_set}},
       quod_dtx:reduce(
         maps:get(complete_control, G), maps:get(complete_ref, G),
         H2, SpuriousMarker)),
    Live =
        quod_dtx:reduce(
          maps:get(complete_control, G), maps:get(complete_ref, G), H2, P2),
    Replay =
        begin
            {ok, RH1, RP1, _} =
                quod_dtx:reduce(
                  maps:get(begin_control, G), maps:get(begin_ref, G), H0, P0),
            {ok, RH2, RP2, _} =
                quod_dtx:reduce(
                  maps:get(decision_control, G), maps:get(decision_ref, G),
                  RH1, RP1),
            quod_dtx:reduce(
              maps:get(complete_control, G), maps:get(complete_ref, G),
              RH2, RP2)
        end,
    ?assertEqual(Live, Replay),
    {ok, _H3, P3, [ExpectedEffect]} = Live,
    ?assertEqual(#{}, maps:get(groups, P3)),
    %% Complete binds the exact Decision reference, not merely its digest.
    WrongDecisionRef =
        protocol_ref(Origin, 56, maps:get(decision_record, G)),
    {ok, WrongComplete} =
        quod_dtx:new_complete(
          GroupId, WrongDecisionRef, maps:get(finalize_rows, G)),
    WrongControl =
        signed(
          Origin, WrongComplete, maps:get(admission, F), 56,
          maps:get(signer, F)),
    WrongRef = protocol_ref(Origin, 56, WrongComplete),
    ?assertEqual(
       {error, {invalid_transition, bad_completion_set}},
       quod_dtx:reduce(WrongControl, WrongRef, H2, P2)),
    ?assertEqual(DecisionRef, maps:get(decision_ref, OriginRole)).

prepared_abort_requires_the_exact_prepare_ref_test() ->
    F = protocol_fixture(),
    Target = maps:get(target_a, F),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Target, 0),
    {ok, H2, P2, _} =
        quod_dtx:reduce(
          maps:get(prepare_a_control, F), maps:get(prepare_a_ref, F), H0, P0),
    {_AbortControl, _AbortRef, DirectControl, DirectRef,
     FinalizeControl, FinalizeRef} =
        abort_controls(F),
    ?assertEqual(
       {error, {invalid_transition, origin_phase}},
       quod_dtx:reduce(DirectControl, DirectRef, H2, P2)),
    {ok, _H4, P4, [{discard_prepared, _, _, _, _, _, 1}]} =
        quod_dtx:reduce(FinalizeControl, FinalizeRef, H2, P2),
    ?assertEqual(#{}, maps:get(apply_fences, P4)),
    ?assertEqual(0, maps:get(generation, P4)).

direct_abort_is_independent_of_an_unrelated_active_lock_test() ->
    F = protocol_fixture(),
    Target = maps:get(target_a, F),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Target, 0),
    {ok, _H2, Locked, _} =
        quod_dtx:reduce(
          maps:get(prepare_a_control, F), maps:get(prepare_a_ref, F), H0, P0),
    {DirectControl, DirectRef} =
        unrelated_direct_abort(F, Target, maps:get(generation, Locked)),
    {ok, DirectHistory, Locked, [{direct_applied_abort, _, _, 0}]} =
        quod_dtx:reduce(
          DirectControl, DirectRef, quod_dtx:initial_group_history(), Locked),
    ?assert(maps:is_key(finalize, maps:get(records, DirectHistory))).

metadata_origin_progresses_while_older_apply_is_pending_test() ->
    with_identity(
      fun(Pub) ->
          F = protocol_fixture(Pub),
          Target = maps:get(target_b, F),
          H0 = quod_dtx:initial_group_history(),
          P0 = quod_dtx:initial_projection(Target, 0),
          {ok, H1, P1, _} =
              quod_dtx:reduce(
                maps:get(prepare_b_control, F),
                maps:get(prepare_b_ref, F), H0, P0),
          {ok, _H2, Pending, _} =
              quod_dtx:reduce(
                maps:get(finalize_b_control, F),
                maps:get(finalize_b_ref, F), H1, P1),
          OldFences = maps:get(apply_fences, Pending),
          ?assertMatch(#{generation := 2},
                       maps:get(maps:get(group_id, F), OldFences)),
          ?assertEqual(1, maps:get(generation, Pending)),

          %% Generation is a consensus projection, not an apply-ack side
          %% effect.  A metadata-only tombstone is therefore identical live
          %% and on replay while the older local apply is still pending.
          {Direct, DirectRef} = unrelated_direct_abort(F, Target, 2),
          DirectInput = quod_dtx:initial_group_history(),
          Live = quod_dtx:reduce(Direct, DirectRef, DirectInput, Pending),
          Replay = quod_dtx:reduce(Direct, DirectRef, DirectInput, Pending),
          ?assertEqual(Live, Replay),
          {ok, _DirectHistory, Pending, [_]} = Live,

          %% The fence blocks new proofs and Prepare only.  It does not block
          %% this ontology from coordinating a newer metadata group.
          G2 = origin_only_group(F, Target),
          {ok, G2H1, Begun, [_]} =
              quod_dtx:reduce(
                maps:get(begin_control, G2), maps:get(begin_ref, G2),
                quod_dtx:initial_group_history(), Pending),
          ?assertEqual(OldFences, maps:get(apply_fences, Begun)),
          {ok, G2H2, Decided, [_]} =
              quod_dtx:reduce(
                maps:get(decision_control, G2), maps:get(decision_ref, G2),
                G2H1, Begun),
          {ok, _G2H3, Completed, [_]} =
              quod_dtx:reduce(
                maps:get(complete_control, G2), maps:get(complete_ref, G2),
                G2H2, Decided),
          ?assertEqual(OldFences, maps:get(apply_fences, Completed)),
          {ok, Acknowledged} =
              quod_dtx:acknowledge_finalize(
                maps:get(group_id, F),
                ref_slot_test(maps:get(finalize_b_ref, F)), 2, Completed),
          ?assertEqual(#{}, maps:get(apply_fences, Acknowledged)),
          ?assertEqual(1, maps:get(generation, Acknowledged))
      end).

generation_reserves_finalize_commit_before_prepare_test() ->
    F = protocol_fixture(),
    Target = maps:get(target_b, F),
    Prepare = maps:get(prepare_b_control, F),
    PrepareRef = maps:get(prepare_b_ref, F),
    Max = 16#FFFFFFFFFFFFFFFF,
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Target, Max - 2),
    {ok, H1, P1, _} = quod_dtx:reduce(Prepare, PrepareRef, H0, P0),
    {Finalize, FinalizeRef} = finalize_at_generation(F, Target, PrepareRef, 2),
    {ok, _H2, P2, _} = quod_dtx:reduce(Finalize, FinalizeRef, H1, P1),
    {ok, P3} = quod_dtx:acknowledge_finalize(
                 maps:get(group_id, F), ref_slot_test(FinalizeRef), 2, P2),
    ?assertEqual(Max - 1, maps:get(generation, P3)),
    PTooLate = quod_dtx:initial_projection(Target, Max - 1),
    ?assertMatch(
       {ok, _, _, _},
       quod_dtx:reduce(Prepare, PrepareRef, H0, PTooLate)),
    ?assertEqual(#{}, maps:get(apply_fences, PTooLate)).

malformed_group_history_fails_closed_test() ->
    F = protocol_fixture(),
    Target = maps:get(target_a, F),
    Projection = quod_dtx:initial_projection(Target, 0),
    Ref = maps:get(begin_ref, F),
    Control = maps:get(begin_control, F),
    Entry = #{group_id => none,
              digest => quod_dtx:record_digest(Control), ref => Ref},
    ?assertEqual(
       {error, {invalid_transition, malformed_state}},
       quod_dtx:reduce(
         Control, Ref,
         #{group_id => none, records => #{'begin' => Entry}}, Projection)),
    ?assertEqual(
       {error, {invalid_transition, malformed_state}},
       quod_dtx:reduce(
         Control, Ref,
         #{group_id => maps:get(group_id, F), records => #{}}, Projection)).

nonblocking_apply_marker_requires_exact_decided_source_group_test() ->
    Target = {<<"quod:marker-validation">>, key(247)},
    GroupId = key(248),
    P0 = quod_dtx:initial_projection(Target, 0),
    Invented =
        P0#{apply_fences :=
                #{GroupId =>
                      #{slot => 1, generation => 0, blocking => false}}},
    ?assertNot(quod_dtx:valid_projection(Invented)),
    %% A blocking row may be participant-owned: its origin group is recorded
    %% in a different ontology and therefore need not be present here.
    ParticipantOwned =
        P0#{apply_fences :=
                #{GroupId =>
                      #{slot => 1, generation => 0, blocking => true}}},
    ?assert(quod_dtx:valid_projection(ParticipantOwned)).

prepared_projection_retains_and_validates_exact_event_context_test() ->
    F = protocol_fixture(),
    Target = maps:get(target_a, F),
    {ok, _History, Projection, _Effects} =
        quod_dtx:reduce(
          maps:get(prepare_a_control, F), maps:get(prepare_a_ref, F),
          quod_dtx:initial_group_history(),
          quod_dtx:initial_projection(Target, 0)),
    ?assert(quod_dtx:valid_projection(Projection)),
    GroupId = maps:get(group_id, F),
    Active = test_group(Projection, GroupId),
    Participant = maps:get(participant, Active),
    ?assertEqual(maps:get(manifest, F), maps:get(manifest, Participant)),
    ?assertEqual(
       quod_dtx:digest(maps:get(plan_a, F)),
       maps:get(plan_digest, Participant)),
    WrongManifest = setelement(
                      6, maps:get(manifest, Participant), {node, key(196)}),
    WrongContext =
        Projection#{groups :=
                        (maps:get(groups, Projection))#{GroupId :=
                          Active#{participant :=
                                    Participant#{manifest := WrongManifest}}}},
    ?assertNot(quod_dtx:valid_projection(WrongContext)),
    WrongDigest =
        Projection#{groups :=
                        (maps:get(groups, Projection))#{GroupId :=
                          Active#{participant :=
                                    Participant#{plan_digest := key(195)}}}},
    ?assertNot(quod_dtx:valid_projection(WrongDigest)).

more_than_sixty_four_disjoint_groups_prepare_without_a_cap_test() ->
    with_identity(fun(_) -> more_than_sixty_four_disjoint_groups_prepare() end).

more_than_sixty_four_disjoint_groups_prepare() ->
    Target = {<<"quod:many-groups">>, key(210)},
    Projection0 = quod_dtx:initial_projection(Target, 0),
    Projection =
        lists:foldl(
          fun(N, P0) ->
              Name = list_to_atom("quod_dtx_disjoint_" ++ integer_to_list(N)),
              #{control := Control, ref := Ref} =
                  participant_prepare_fixture(Target, {Name, N}, N),
              {ok, _History, P1, [_]} = quod_dtx:reduce(
                                         Control, Ref,
                                         quod_dtx:initial_group_history(), P0),
              P1
          end, Projection0, lists:seq(1, 65)),
    ?assertEqual(65, map_size(maps:get(groups, Projection))),
    ?assertEqual(65, map_size(maps:get(conflicts, Projection))),
    ?assertEqual(0, maps:get(generation, Projection)),
    ?assertEqual(#{}, maps:get(apply_fences, Projection)).

overlapping_writes_block_and_batch_failure_is_atomic_test() ->
    with_identity(fun(_) -> overlapping_writes_block_and_batch_failure_is_atomic() end).

batch_rejects_duplicate_signed_lane_sequence_test() ->
    with_identity(
      fun(_) ->
          Target = {<<"quod:duplicate-lane-sequence">>, key(220)},
          A0 = participant_prepare_fixture(Target, {lane_a, a}, 85),
          B0 = participant_prepare_fixture(Target, {lane_b, b}, 86),
          Signer = configured_test_signer(),
          Admission = key(221),
          Sequence = 500,
          A = signed(Target, quod_dtx:control_body(maps:get(control, A0)),
                     Admission, Sequence, Signer),
          B = signed(Target, quod_dtx:control_body(maps:get(control, B0)),
                     Admission, Sequence, Signer),
          Batch = lists:sort(
                    fun({L, _}, {R, _}) ->
                        quod_dtx:control_order_key(L) <
                            quod_dtx:control_order_key(R)
                    end,
                    [{A, maps:get(ref, A0)}, {B, maps:get(ref, B0)}]),
          ?assertEqual(
             {error, {invalid_transition, malformed_batch}},
             quod_dtx:reduce_batch(
               Batch, #{}, quod_dtx:initial_projection(Target, 0)))
      end).

batch_reducer_preserves_per_control_attribution_test() ->
    with_identity(
      fun(_) ->
          Target = {<<"quod:batch-attribution">>, key(226)},
          A = participant_prepare_fixture(Target, {attributed_a, a}, 89),
          B = participant_prepare_fixture(Target, {attributed_b, b}, 90),
          Batch = lists:sort(
                    fun({L, _}, {R, _}) ->
                        quod_dtx:control_order_key(L) <
                            quod_dtx:control_order_key(R)
                    end,
                    [{maps:get(control, A), maps:get(ref, A)},
                     {maps:get(control, B), maps:get(ref, B)}]),
          {ok, Histories, Projection, Items} = quod_dtx:reduce_batch(
                                                  Batch, #{},
                                                  quod_dtx:initial_projection(
                                                    Target, 0)),
          ?assertEqual(2, map_size(Histories)),
          ?assertEqual(2, length(Items)),
          ?assertEqual([C || {C, _} <- Batch],
                       [maps:get(control, Item) || Item <- Items]),
          ?assert(lists:all(
                    fun(#{ref := Ref, history := History,
                          projection := ItemProjection, effects := [_]}) ->
                            quod_dtx:validate_certified_ref(Ref) andalso
                                quod_dtx:valid_projection(ItemProjection) andalso
                                maps:get(group_id, History) =/= none
                    end, Items)),
          ?assertEqual(Projection,
                       maps:get(projection, lists:last(Items)))
      end).

overlapping_writes_block_and_batch_failure_is_atomic() ->
    Target = {<<"quod:conflict-groups">>, key(211)},
    A = participant_prepare_fixture(Target, {shared_conflict, a}, 70),
    B = participant_prepare_fixture(Target, {shared_conflict, b}, 71),
    P0 = quod_dtx:initial_projection(Target, 0),
    {ok, HA, P1, [_]} = quod_dtx:reduce(
                          maps:get(control, A), maps:get(ref, A),
                          quod_dtx:initial_group_history(), P0),
    ?assertEqual(
       expected_conflict_readiness(A, B),
       quod_dtx:proposal_readiness(
         quod_dtx:control_body(maps:get(control, B)), P1)),
    ?assertEqual(
       expected_conflict_reduction(A, B),
       quod_dtx:reduce(
         maps:get(control, B), maps:get(ref, B),
         quod_dtx:initial_group_history(), P1)),
    Batch = lists:sort(
              fun({Left, _}, {Right, _}) ->
                  quod_dtx:control_order_key(Left) <
                      quod_dtx:control_order_key(Right)
              end,
              [{maps:get(control, A), maps:get(ref, A)},
               {maps:get(control, B), maps:get(ref, B)}]),
    [{BatchFirst, _}, {BatchSecond, _}] = Batch,
    BatchExpected = expected_conflict_reduction(
                      #{group_id => quod_dtx:group_id(BatchFirst)},
                      #{group_id => quod_dtx:group_id(BatchSecond)}),
    ?assertEqual(BatchExpected, quod_dtx:reduce_batch(Batch, #{}, P0)),
    ?assert(quod_dtx:valid_projection(P0)),
    ?assert(quod_dtx:valid_projection(P1)),
    ?assertMatch(#{records := #{}}, quod_dtx:initial_group_history()),
    ?assertMatch(#{records := _}, HA).

ordinary_content_blocks_only_on_an_exact_active_conflict_test() ->
    with_identity(
      fun(_) ->
          Target = {<<"quod:content-conflict">>, key(225)},
          Active = participant_prepare_fixture(Target, {shared_content, a}, 87),
          Disjoint = participant_prepare_fixture(Target, {other_content, b}, 88),
          P0 = quod_dtx:initial_projection(Target, 0),
          {ok, _, P1, [_]} = quod_dtx:reduce(
                               maps:get(control, Active), maps:get(ref, Active),
                               quod_dtx:initial_group_history(), P0),
          ConflictTx = transaction_from_prepare(Active),
          DisjointTx = transaction_from_prepare(Disjoint),
          ?assertEqual({blocked, active_group},
                       quod_dtx:content_readiness(ConflictTx, P1)),
          ?assertEqual(ready, quod_dtx:content_readiness(DisjointTx, P1))
      end).

read_write_and_write_read_conflicts_are_symmetric_test() ->
    with_identity(
      fun(_) ->
          Target = {<<"quod:rw-conflicts">>, key(212)},
          Reader = participant_prepare_goal_fixture(
                     Target, [{shared_rw, seed}], {shared_rw, seed}, 80),
          Writer = participant_prepare_goal_fixture(
                     Target, [{shared_rw, seed}],
                     {assertz, {shared_rw, changed}}, 81),
          ?assert(lists:member(
                    {<<"shared_rw">>, 1},
                    maps:get(reads, plan_descriptor_from_prepare(Reader)))),
          ?assert(lists:member(
                    {<<"shared_rw">>, 1},
                    maps:get(writes, plan_descriptor_from_prepare(Writer)))),
          assert_second_prepare_conflicts(Target, Reader, Writer),
          assert_second_prepare_conflicts(Target, Writer, Reader)
      end).

same_effect_custody_conflicts_even_when_effect_ids_differ_test() ->
    with_identity(
      fun(Pub) ->
          Target = {<<"quod:custody-source">>, key(213)},
          Custody = {<<"quod:custody-target">>, key(214)},
          A = participant_effect_prepare_fixture(Target, Custody, Pub, 82),
          B = participant_effect_prepare_fixture(Target, Custody, Pub, 83),
          assert_second_prepare_conflicts(Target, A, B)
      end).

event_only_commit_does_not_create_apply_fence_test() ->
    with_identity(
      fun(_) ->
          Target = {<<"quod:event-only">>, key(219)},
          F = participant_event_prepare_fixture(Target, 84),
          P0 = quod_dtx:initial_projection(Target, 0),
          {ok, H1, P1, [_]} = quod_dtx:reduce(
                               maps:get(control, F), maps:get(ref, F),
                               quod_dtx:initial_group_history(), P0),
          {ok, DecisionRef} = quod_dtx:certified_ref(
                                element(1, maps:get(origin, F)),
                                element(2, maps:get(origin, F)), 419,
                                key(216), key(217), <<"qc">>),
          {ok, FinalizeBody} = quod_dtx:new_finalize(
                                 maps:get(group_id, F), DecisionRef, commit,
                                 maps:get(ref, F), 1),
          Finalize = signed(Target, FinalizeBody, key(218), 420,
                            configured_test_signer()),
          FinalizeRef = protocol_ref(Target, 420, FinalizeBody),
          {ok, _, P2, [_]} = quod_dtx:reduce(Finalize, FinalizeRef, H1, P1),
          ?assertEqual(1, maps:get(generation, P2)),
          ?assertEqual(#{}, maps:get(apply_fences, P2))
      end).

multiple_origin_recoveries_are_canonical_test() ->
    with_identity(
      fun(Pub) ->
          F1 = protocol_fixture(Pub),
          F2 = protocol_fixture(Pub),
          Target = maps:get(origin, F1),
          G1 = origin_only_group(F1, Target),
          G2 = origin_only_group(F2, Target),
          P0 = quod_dtx:initial_projection(Target, 0),
          {ok, _, P1, [_]} = quod_dtx:reduce(
                               maps:get(begin_control, G1),
                               maps:get(begin_ref, G1),
                               quod_dtx:initial_group_history(), P0),
          {ok, _, P2, [_]} = quod_dtx:reduce(
                               maps:get(begin_control, G2),
                               maps:get(begin_ref, G2),
                               quod_dtx:initial_group_history(), P1),
          Expected = lists:sort(
                       [{maps:get(group_id, G1), maps:get(begin_ref, G1)},
                        {maps:get(group_id, G2), maps:get(begin_ref, G2)}]),
          ?assertEqual(Expected, quod_dtx:origin_recoveries(P2))
      end).

independent_commit_fences_acknowledge_in_reverse_order_test() ->
    with_identity(
      fun(_) ->
          Target = {<<"quod:reverse-acks">>, key(215)},
          A = participant_prepare_fixture(Target, {reverse_a, true}, 84),
          B = participant_prepare_fixture(Target, {reverse_b, true}, 85),
          P0 = quod_dtx:initial_projection(Target, 7),
          {ok, HA, P1, [_]} = quod_dtx:reduce(
                               maps:get(control, A), maps:get(ref, A),
                               quod_dtx:initial_group_history(), P0),
          {ok, HB, P2, [_]} = quod_dtx:reduce(
                               maps:get(control, B), maps:get(ref, B),
                               quod_dtx:initial_group_history(), P1),
          {FinalizeA, FinalizeARef} = participant_commit_finalize(Target, A, 400),
          {FinalizeB, FinalizeBRef} = participant_commit_finalize(Target, B, 401),
          {ok, _, P3, [_]} = quod_dtx:reduce(FinalizeA, FinalizeARef, HA, P2),
          {ok, _, P4, [_]} = quod_dtx:reduce(FinalizeB, FinalizeBRef, HB, P3),
          ?assertEqual(9, maps:get(generation, P4)),
          ?assertEqual(2, map_size(maps:get(apply_fences, P4))),
          {ok, P5} = quod_dtx:acknowledge_finalize(
                       maps:get(group_id, B), ref_slot_test(FinalizeBRef), 2, P4),
          ?assert(maps:is_key(maps:get(group_id, A), maps:get(apply_fences, P5))),
          {ok, P6} = quod_dtx:acknowledge_finalize(
                       maps:get(group_id, A), ref_slot_test(FinalizeARef), 2, P5),
          ?assertEqual(#{}, maps:get(apply_fences, P6)),
          ?assertEqual(9, maps:get(generation, P6))
      end).

assert_second_prepare_conflicts(Target, First, Second) ->
    P0 = quod_dtx:initial_projection(Target, 0),
    {ok, _, P1, [_]} = quod_dtx:reduce(
                         maps:get(control, First), maps:get(ref, First),
                         quod_dtx:initial_group_history(), P0),
    ?assertEqual(
       expected_conflict_readiness(First, Second),
       quod_dtx:proposal_readiness(
         quod_dtx:control_body(maps:get(control, Second)), P1)).

expected_conflict_readiness(Holder, Contender) ->
    case maps:get(group_id, Contender) < maps:get(group_id, Holder) of
        true -> {blocked, active_group};
        false -> {refused, conflict}
    end.

expected_conflict_reduction(Holder, Contender) ->
    case expected_conflict_readiness(Holder, Contender) of
        {blocked, active_group} -> {error, {invalid_transition, active_group}};
        {refused, conflict} -> {error, {invalid_transition, conflict_refused}}
    end.

plan_descriptor_from_prepare(#{control := Control}) ->
    {ok, _Manifest, _Digest, Blob} = quod_dtx:prepare_payload(Control),
    {ok, Plan} = quod_dtx:decode(Blob),
    quod_dtx:conflict_descriptor(Plan).

transaction_from_prepare(#{control := Control}) ->
    {ok, _Manifest, _Digest, Blob} = quod_dtx:prepare_payload(Control),
    {ok, Plan} = quod_dtx:decode(Blob),
    {ok, Material} = quod_dtx:material(Plan),
    #transaction{diff = maps:get(diff, Material),
                 read_check = maps:get(read_check, Material),
                 effects = maps:get(effects, Material)}.

certified_entry_ref_binds_exact_entry_test() ->
    F = protocol_fixture(),
    {Ns, Anchor} = Target = maps:get(target_a, F),
    Control = maps:get(begin_control, F),
    {ok, Blob} = quod_dtx:encode_control(Control),
    Slot = 9,
    Timestamp = 1234,
    Payload = {batch, [{dtx, Blob}]},
    Block = #block{slot = Slot, parent = Slot - 1,
                   payload = Payload, timestamp = Timestamp},
    BlockHash = quod_simplex:block_hash(Block),
    Cert = #cert{kind = commit, slot = Slot,
                 block_hash = BlockHash, sigs = []},
    Entry = #entry{index = Slot, data = Payload,
                   timestamp = Timestamp, cert = Cert},
    {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Control),
    {ok, Expected} =
        quod_dtx:certified_ref(
          Ns, Anchor, Slot, BlockHash, quod_dtx:record_digest(Control),
          term_to_binary(Cert, [deterministic])),
    ?assertEqual(Expected, Ref),
    %% Every hash-covered entry field and the certificate's own slot binding
    %% are checked; neither can be replaced while retaining the same ref.
    ?assertEqual(
       {error, invalid_certified_entry},
       quod_dtx:certified_entry_ref(
         Target, Entry#entry{timestamp = Timestamp + 1}, Control)),
    ?assertEqual(
       {error, invalid_certified_entry},
       quod_dtx:certified_entry_ref(
         Target, Entry#entry{cert = Cert#cert{slot = Slot + 1}}, Control)).

certified_entry_ref_accepts_another_valid_quorum_subset_test() ->
    F = protocol_fixture(),
    {Ns, Anchor} = Target = maps:get(target_a, F),
    Control = maps:get(begin_control, F),
    {ok, Blob} = quod_dtx:encode_control(Control),
    Slot = 9,
    Timestamp = 1234,
    Payload = {batch, [{dtx, Blob}]},
    Block = #block{slot = Slot, parent = Slot - 1,
                   payload = Payload, timestamp = Timestamp},
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
    RefEntry = #entry{index = Slot, data = Payload,
                      timestamp = Timestamp, cert = RefCert},
    LocalEntry = RefEntry#entry{cert = LocalCert},
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
                 diff = [], read_check = #{}, sig = none},
    Entry = #entry{index = 1, data = {batch, [Genesis]},
                   timestamp = 0, cert = none},
    {ok, Block} = quod_simplex:block_from_entry(Entry),
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
    ?assertEqual(
       {error, invalid_certified_entry},
       quod_dtx:certified_entry_ref(
         Target, Entry#entry{timestamp = 1}, Genesis)).

%% ------------------------------------------------------------------
%% V1 control fixtures
%% ------------------------------------------------------------------

protocol_fixture() ->
    with_identity(fun protocol_fixture/1).

source_fused_protocol_fixture() ->
    with_identity(fun source_fused_protocol_fixture/1).

source_fused_protocol_fixture_at_generation(Generation) ->
    with_identity(
      fun(Pub) -> source_fused_protocol_fixture(Pub, Generation) end).

source_fused_protocol_fixture(Pub) ->
    source_fused_protocol_fixture(Pub, default).

source_fused_protocol_fixture(Pub, SourceGeneration) ->
    Origin = {<<"quod:source">>, key(181)},
    ProofId = key(183),
    {SourcePlan0, _SourceBlob0} =
        protocol_plan(Origin, ProofId, Origin, {source_fact, true}),
    SourcePlan = plan_at_generation(SourcePlan0, SourceGeneration),
    source_fused_protocol_fixture_with_plan(Pub, SourcePlan, 2).

source_fused_event_protocol_fixture() ->
    with_identity(
      fun(Pub) ->
              Origin = {<<"quod:source">>, key(181)},
              SourcePlan = signed_effect_material_plan(
                             Origin, key(183), Origin, anonymous,
                             [{event, {source_event, true}}], []),
              source_fused_protocol_fixture_with_plan(Pub, SourcePlan, 1)
      end).

source_fused_protocol_fixture_with_plan(
  Pub, SourcePlan, SourceAppliedGeneration) ->
    Signer = configured_test_signer(),
    Admission = key(180),
    Origin = {<<"quod:source">>, key(181)},
    Remote = {<<"quod:remote">>, key(182)},
    ProofId = key(183),
    {ok, SourceBlob} = quod_dtx:encode(SourcePlan),
    {RemotePlan, RemoteBlob} =
        protocol_plan(Remote, ProofId, Origin, {remote_fact, true}),
    {ok, GoalBlob} = quod_durable_term:encode_goal({fixture_goal, fused}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    {ok, Manifest} = quod_dtx:new_manifest(
                       #{proof_id => ProofId,
                         coordinator =>
                             {element(1, Origin), element(2, Origin), Pub,
                              Admission},
                         nonce => key(184), principal => anonymous,
                         goal => GoalBlob, result => ResultBlob,
                         request_binding => none,
                         participants =>
                             [{Origin, quod_dtx:digest(SourcePlan)},
                              {Remote, quod_dtx:digest(RemotePlan)}]}),
    {ok, SourceAtt} = quod_dtx:attest_plan(
                        Origin, SourcePlan, Manifest, Signer),
    {ok, RemoteAtt} = quod_dtx:attest_plan(
                        Remote, RemotePlan, Manifest, Signer),
    {ok, Begin} = quod_dtx:new_begin(
                    Manifest, none,
                    [{Origin, quod_dtx:digest(SourcePlan), SourceBlob,
                      SourceAtt},
                     {Remote, quod_dtx:digest(RemotePlan), RemoteBlob,
                      RemoteAtt}]),
    GroupId = quod_dtx:group_id(Begin),
    BeginControl = signed(Origin, Begin, Admission, 1, Signer),
    BeginRef = protocol_ref(Origin, 1, Begin),
    {ok, PrepareRemote} = quod_dtx:new_prepare(Begin, BeginRef, Remote),
    PrepareRemoteControl = signed(
                             Remote, PrepareRemote, Admission, 1, Signer),
    PrepareRemoteRef = protocol_ref(Remote, 1, PrepareRemote),
    {ok, Decision} = quod_dtx:new_decision(
                       GroupId, BeginRef, commit,
                       [{Origin, BeginRef}, {Remote, PrepareRemoteRef}]),
    DecisionControl = signed(Origin, Decision, Admission, 2, Signer),
    DecisionRef = protocol_ref(Origin, 2, Decision),
    {ok, FinalizeRemote} = quod_dtx:new_finalize(
                             GroupId, DecisionRef, commit,
                             PrepareRemoteRef, 2),
    FinalizeRemoteControl = signed(
                              Remote, FinalizeRemote, Admission, 2, Signer),
    FinalizeRemoteRef = protocol_ref(Remote, 2, FinalizeRemote),
    {ok, Complete} = quod_dtx:new_complete(
                       GroupId, DecisionRef,
                       [{Origin, DecisionRef, SourceAppliedGeneration},
                        {Remote, FinalizeRemoteRef, 2}]),
    CompleteControl = signed(Origin, Complete, Admission, 3, Signer),
    CompleteRef = protocol_ref(Origin, 3, Complete),
    #{origin => Origin, remote => Remote, group_id => GroupId,
      begin_record => Begin, begin_control => BeginControl,
      begin_ref => BeginRef,
      prepare_remote_control => PrepareRemoteControl,
      prepare_remote_ref => PrepareRemoteRef,
      decision_control => DecisionControl, decision_ref => DecisionRef,
      finalize_remote_control => FinalizeRemoteControl,
      finalize_remote_ref => FinalizeRemoteRef,
      complete_control => CompleteControl, complete_ref => CompleteRef}.

plan_at_generation(Plan, default) ->
    Plan;
plan_at_generation(Plan0, Generation) ->
    {quod_plan, Core0, Pubkey, _Signature} = tuple(Plan0),
    Signer = #{pubkey := Pubkey} = configured_test_signer(),
    Core = Core0#{overlay_generation := Generation},
    Bytes = term_to_binary(
              {<<"quod.dtx.plan">>, 8, Core}, [deterministic]),
    plan({quod_plan, Core, Pubkey, quod_identity:sign(Bytes, Signer)}).

protocol_fixture(Pub) ->
          Signer = configured_test_signer(),
          Admission = key(90),
          Origin = {<<"quod:origin">>, key(90)},
          A = {<<"quod:a">>, key(91)},
          B = {<<"quod:b">>, key(92)},
          ProofId = key(93),
          {PlanA, PlanABlob} =
              protocol_plan(A, ProofId, Origin, {fixture_a, true}),
          {OtherPlanA, _} =
              protocol_plan(A, ProofId, Origin, {fixture_a, different}),
          {PlanB, PlanBBlob} =
              protocol_plan(B, ProofId, Origin, {fixture_b, true}),
          {ok, GoalBlob} = quod_durable_term:encode_goal({fixture_goal, true}),
          {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
          Participants =
              [{B, quod_dtx:digest(PlanB)},
               {A, quod_dtx:digest(PlanA)}],
          ManifestInput =
              #{proof_id => ProofId,
                coordinator =>
                    {element(1, Origin), element(2, Origin), Pub, Admission},
                nonce => key(94), principal => anonymous,
                goal => GoalBlob, result => ResultBlob,
                request_binding => none,
                participants => Participants},
          {ok, Manifest} = quod_dtx:new_manifest(ManifestInput),
          {ok, AttA} = quod_dtx:attest_plan(A, PlanA, Manifest, Signer),
          {ok, AttB} = quod_dtx:attest_plan(B, PlanB, Manifest, Signer),
          Bundles =
              [{B, quod_dtx:digest(PlanB), PlanBBlob, AttB},
               {A, quod_dtx:digest(PlanA), PlanABlob, AttA}],
          {ok, Begin} = quod_dtx:new_begin(
                          Manifest, none, Bundles),
          GroupId = quod_dtx:group_id(Begin),
          BeginControl = signed(Origin, Begin, Admission, 1, Signer),
          BeginRef = protocol_ref(Origin, 1, Begin),
          {ok, PrepareA} = quod_dtx:new_prepare(Begin, BeginRef, A),
          {ok, PrepareB} = quod_dtx:new_prepare(Begin, BeginRef, B),
          PrepareAControl = signed(A, PrepareA, Admission, 2, Signer),
          PrepareBControl = signed(B, PrepareB, Admission, 1, Signer),
          PrepareARef = protocol_ref(A, 2, PrepareA),
          PrepareBRef = protocol_ref(B, 1, PrepareB),
          PrepareRows = [{B, PrepareBRef}, {A, PrepareARef}],
          {ok, Decision} =
              quod_dtx:new_decision(GroupId, BeginRef, commit, PrepareRows),
          DecisionControl = signed(Origin, Decision, Admission, 3, Signer),
          DecisionRetryControl = signed(Origin, Decision, Admission, 30, Signer),
          DecisionRef = protocol_ref(Origin, 3, Decision),
          DecisionRetryRef = protocol_ref(Origin, 30, Decision),
          {ok, FinalizeA} =
              quod_dtx:new_finalize(
                GroupId, DecisionRef, commit, PrepareARef, 2),
          {ok, FinalizeB} =
              quod_dtx:new_finalize(
                GroupId, DecisionRef, commit, PrepareBRef, 2),
          FinalizeAControl = signed(A, FinalizeA, Admission, 4, Signer),
          FinalizeBControl = signed(B, FinalizeB, Admission, 2, Signer),
          FinalizeARef = protocol_ref(A, 4, FinalizeA),
          FinalizeBRef = protocol_ref(B, 2, FinalizeB),
          FinalizeRows = [{B, FinalizeBRef, 2}, {A, FinalizeARef, 2}],
          {ok, Complete} =
              quod_dtx:new_complete(GroupId, DecisionRef, FinalizeRows),
          CompleteControl = signed(Origin, Complete, Admission, 5, Signer),
          CompleteRef = protocol_ref(Origin, 5, Complete),
          #{signer => Signer, admission => Admission, origin => Origin,
            target_a => A, target_b => B, proof_id => ProofId,
            plan_a => PlanA, other_plan_a => OtherPlanA, plan_b => PlanB,
            manifest => Manifest, manifest_input => ManifestInput,
            bundles => Bundles, group_id => GroupId,
            begin_record => Begin, begin_control => BeginControl,
            begin_ref => BeginRef,
            prepare_a_record => PrepareA,
            prepare_a_control => PrepareAControl, prepare_a_ref => PrepareARef,
            prepare_b_record => PrepareB,
            prepare_b_control => PrepareBControl, prepare_b_ref => PrepareBRef,
            prepare_rows => PrepareRows,
            decision_record => Decision, decision_control => DecisionControl,
            decision_retry_control => DecisionRetryControl,
            decision_ref => DecisionRef, decision_retry_ref => DecisionRetryRef,
            finalize_a_record => FinalizeA,
            finalize_a_control => FinalizeAControl, finalize_a_ref => FinalizeARef,
            finalize_b_record => FinalizeB,
            finalize_b_control => FinalizeBControl, finalize_b_ref => FinalizeBRef,
            finalize_rows => FinalizeRows,
            complete_record => Complete, complete_control => CompleteControl,
            complete_ref => CompleteRef}.

protocol_plan(Target, ProofId, Origin, Fact) ->
    protocol_goal_plan(Target, ProofId, Origin, [], {assertz, Fact}).

protocol_goal_plan(Target, ProofId, Origin, Facts, Goal) ->
    Session = session(Facts),
    try
        {_Id, {solution, _}} = first(Session, Goal),
        {ok, Plan} =
            quod_dtx:seal_session(
              Session,
              #{target => Target, base_height => 1, proof_id => ProofId,
                origin => Origin, principal => anonymous,
                request_binding => none}),
        {ok, Blob} = quod_dtx:encode(Plan),
        {Plan, Blob}
    after
        quod_proof_session:stop(Session)
    end.

signed(Target, Record, Admission, Sequence, Signer) ->
    {ok, Control} =
        quod_dtx:sign_control(
          Target, Record, Admission, Sequence, Sequence, Signer),
    Control.

protocol_ref({Ns, Anchor}, Slot, Record) ->
    {ok, Ref} =
        quod_dtx:certified_ref(
          Ns, Anchor, Slot, key(150 + Slot), quod_dtx:record_digest(Record),
          term_to_binary({qc, Slot}, [deterministic])),
    Ref.

bundle_attestation(Target, Bundles) ->
    {Target, _Digest, _Blob, Attestation} = lists:keyfind(Target, 1, Bundles),
    Attestation.

fixture_prepare_control(F, Ref) ->
    case {Ref =:= maps:get(prepare_a_ref, F),
          Ref =:= maps:get(prepare_b_ref, F)} of
        {true, false} ->
            maps:get(prepare_a_control, F);
        {false, true} ->
            maps:get(prepare_b_control, F)
    end.

fixture_finalize_control(F, Ref) ->
    case {Ref =:= maps:get(finalize_a_ref, F),
          Ref =:= maps:get(finalize_b_ref, F)} of
        {true, false} ->
            maps:get(finalize_a_control, F);
        {false, true} ->
            maps:get(finalize_b_control, F)
    end.

forge_control_blob(Kind, Target, Record, Admission, Sequence, SubmittedAt,
                   #{pubkey := Author} = Signer) ->
    BodyBlob = term_to_binary(Record, [deterministic]),
    Domain =
        case Kind of
            'begin' -> <<"quod.dtx.control.begin">>;
            prepare -> <<"quod.dtx.control.prepare">>;
            decision -> <<"quod.dtx.control.decision">>;
            finalize -> <<"quod.dtx.control.finalize">>;
            complete -> <<"quod.dtx.control.complete">>
        end,
    Bytes =
        term_to_binary(
          {Domain, 2, Target, BodyBlob, Author, Admission, Sequence,
           SubmittedAt}, [deterministic]),
    Signature = quod_identity:sign(Bytes, Signer),
    term_to_binary(
      {quod_dtx_control, 2, Kind, Target, BodyBlob, Author, Admission,
       Sequence, SubmittedAt, Signature}, [deterministic]).

abort_controls(F) ->
    GroupId = maps:get(group_id, F),
    BeginRef = maps:get(begin_ref, F),
    Signer = maps:get(signer, F),
    Admission = maps:get(admission, F),
    Target = maps:get(target_a, F),
    {ok, Abort} =
        quod_dtx:new_decision(
          GroupId, BeginRef,
          {abort, [{prepare_refused, reason_identity(Target)}]}, []),
    Origin = maps:get(origin, F),
    AbortControl = signed(Origin, Abort, Admission, 6, Signer),
    AbortRef = protocol_ref(Origin, 6, Abort),
    {ok, DirectFinalize} =
        quod_dtx:new_finalize(GroupId, AbortRef, abort, none, 1),
    DirectControl = signed(Target, DirectFinalize, Admission, 7, Signer),
    DirectRef = protocol_ref(Target, 7, DirectFinalize),
    {ok, Finalize} =
        quod_dtx:new_finalize(
          GroupId, AbortRef, abort, maps:get(prepare_a_ref, F), 1),
    FinalizeControl = signed(Target, Finalize, Admission, 8, Signer),
    FinalizeRef = protocol_ref(Target, 8, Finalize),
    {AbortControl, AbortRef, DirectControl, DirectRef,
     FinalizeControl, FinalizeRef}.

unrelated_direct_abort(F, Target, Generation) ->
    GroupId = key(220),
    {Ns, Anchor} = maps:get(origin, F),
    {ok, DecisionRef} =
        quod_dtx:certified_ref(
          Ns, Anchor, 20, key(221), key(222), <<"foreign-qc">>),
    {ok, Finalize} =
        quod_dtx:new_finalize(GroupId, DecisionRef, abort, none, Generation),
    Control = signed(
                Target, Finalize, maps:get(admission, F), 20,
                maps:get(signer, F)),
    {Control, protocol_ref(Target, 20, Finalize)}.

origin_only_group(F, Origin) ->
    A = maps:get(target_a, F),
    C = {<<"quod:c">>, key(232)},
    Signer = maps:get(signer, F),
    Admission = maps:get(admission, F),
    ProofId = key(230),
    {PlanA, PlanABlob} = protocol_plan(A, ProofId, Origin, {g2_a, true}),
    {PlanC, PlanCBlob} = protocol_plan(C, ProofId, Origin, {g2_c, true}),
    {ok, GoalBlob} = quod_durable_term:encode_goal({g2_goal, true}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    {OriginNs, OriginAnchor} = Origin,
    ManifestInput =
        #{proof_id => ProofId,
          coordinator =>
              {OriginNs, OriginAnchor, maps:get(pubkey, Signer), Admission},
          nonce => key(231), principal => anonymous,
              goal => GoalBlob, result => ResultBlob,
              request_binding => none,
          participants =>
              [{C, quod_dtx:digest(PlanC)},
               {A, quod_dtx:digest(PlanA)}]},
    {ok, Manifest} = quod_dtx:new_manifest(ManifestInput),
    {ok, AttA} = quod_dtx:attest_plan(A, PlanA, Manifest, Signer),
    {ok, AttC} = quod_dtx:attest_plan(C, PlanC, Manifest, Signer),
    {ok, Begin} =
        quod_dtx:new_begin(
          Manifest, none,
          [{C, quod_dtx:digest(PlanC), PlanCBlob, AttC},
           {A, quod_dtx:digest(PlanA), PlanABlob, AttA}]),
    GroupId = quod_dtx:group_id(Begin),
    BeginControl = signed(Origin, Begin, Admission, 51, Signer),
    BeginRef = protocol_ref(Origin, 51, Begin),
    AbortReasons = [{participant_unavailable, reason_identity(C)}],
    {ok, Decision} =
        quod_dtx:new_decision(
          GroupId, BeginRef, {abort, AbortReasons}, []),
    DecisionControl = signed(Origin, Decision, Admission, 52, Signer),
    DecisionRef = protocol_ref(Origin, 52, Decision),
    FinalizeRows =
        [{Target,
          begin
              {ok, Finalize} =
                  quod_dtx:new_finalize(
                    GroupId, DecisionRef, abort, none, 2),
              protocol_ref(Target, Slot, Finalize)
          end,
          2}
         || {Target, Slot} <- [{A, 53}, {C, 54}]],
    {ok, Complete} =
        quod_dtx:new_complete(GroupId, DecisionRef, FinalizeRows),
    CompleteControl = signed(Origin, Complete, Admission, 55, Signer),
    #{group_id => GroupId,
      begin_control => BeginControl, begin_ref => BeginRef,
      decision_record => Decision, decision_control => DecisionControl,
      decision_ref => DecisionRef, abort_reasons => AbortReasons,
      finalize_rows => FinalizeRows,
      complete_control => CompleteControl,
      complete_ref => protocol_ref(Origin, 55, Complete)}.

finalize_at_generation(F, Target, PrepareRef, Generation) ->
    {ok, Record} =
        quod_dtx:new_finalize(
          maps:get(group_id, F), maps:get(decision_ref, F), commit,
          PrepareRef, Generation),
    Control = signed(
                Target, Record, maps:get(admission, F), 40,
                maps:get(signer, F)),
    {Control, protocol_ref(Target, 40, Record)}.

identity(N) -> {<<"quod:bounded">>, key(180 + N)}.

reason_identity({Ns, <<_:256>> = Anchor}) when is_binary(Ns) ->
    {ontology, Ns, Anchor}.

ref_slot_test({quod_dtx_ref, 2, _, _, Slot, _, _, _}) -> Slot.

reason_wire_size(Reason) ->
    {ok, Wire} = quod_wire_term:encode(Reason),
    byte_size(term_to_binary(Wire, [deterministic])).

reason_stack_wire_size(Reasons) ->
    {ok, Wire} = quod_wire_term:encode(Reasons),
    byte_size(term_to_binary(Wire, [deterministic])).

reason_binary_at_wire_size(Size) ->
    EmptySize = reason_wire_size(<<>>),
    true = Size >= EmptySize,
    Binary = binary:copy(<<"r">>, Size - EmptySize),
    Size = reason_wire_size(Binary),
    Binary.

failure_reason_stack_at_wire_limit() ->
    MaxReason = reason_binary_at_wire_size(?ERLOG_MAX_FAILURE_REASON_BYTES),
    Prefix = lists:duplicate(7, MaxReason),
    BaseSize = reason_stack_wire_size(Prefix ++ [<<>>]),
    Growth = ?ERLOG_MAX_FAILURE_REASONS_BYTES - BaseSize,
    true = Growth >= 0,
    Last = binary:copy(<<"s">>, Growth),
    true = reason_wire_size(Last) =< ?ERLOG_MAX_FAILURE_REASON_BYTES,
    Reasons = Prefix ++ [Last],
    ?ERLOG_MAX_FAILURE_REASONS_BYTES = reason_stack_wire_size(Reasons),
    Reasons.

noncanonical_reason_blob(Canonical) ->
    <<131, 104, 3, Rest/binary>> = Canonical,
    <<131, 105, 0, 0, 0, 3, Rest/binary>>.

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

test_group(Projection, GroupId) ->
    maps:get(GroupId, maps:get(groups, Projection)).

participant_prepare_fixture(Target, Fact, N) ->
    Origin = {<<"quod:many-origin-", (integer_to_binary(N))/binary>>,
              crypto:hash(sha256, <<N:64>>)},
    ProofId = crypto:hash(sha256, <<"proof", N:64>>),
    {Plan, PlanBlob} = protocol_plan(Target, ProofId, Origin, Fact),
    participant_prepare_from_plan(Target, Origin, ProofId, Plan, PlanBlob, N).

participant_prepare_goal_fixture(Target, Facts, Goal, N) ->
    Origin = {<<"quod:many-origin-", (integer_to_binary(N))/binary>>,
              crypto:hash(sha256, <<N:64>>)},
    ProofId = crypto:hash(sha256, <<"proof", N:64>>),
    {Plan, PlanBlob} = protocol_goal_plan(Target, ProofId, Origin, Facts, Goal),
    participant_prepare_from_plan(Target, Origin, ProofId, Plan, PlanBlob, N).

participant_effect_prepare_fixture(Target, Custody, _Pub, N) ->
    #{pubkey := EffectPub} = configured_test_signer(),
    Origin = {<<"quod:effect-origin-", (integer_to_binary(N))/binary>>,
              crypto:hash(sha256, <<"effect-origin", N:64>>)},
    ProofId = crypto:hash(sha256, <<"effect-proof", N:64>>),
    {ok, Effect} = quod_effect:new(
                     create, EffectPub, {node, EffectPub}, Custody,
                     crypto:hash(sha256, <<"request", N:64>>),
                     crypto:hash(sha256, <<"prepared", N:64>>)),
    Plan = signed_effect_material_plan(
             Target, ProofId, Origin, {node, EffectPub}, [], [Effect]),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    participant_prepare_from_plan(Target, Origin, ProofId, Plan, PlanBlob, N).

participant_event_prepare_fixture(Target, N) ->
    Origin = {<<"quod:event-origin-", (integer_to_binary(N))/binary>>,
              crypto:hash(sha256, <<"event-origin", N:64>>)},
    ProofId = crypto:hash(sha256, <<"event-proof", N:64>>),
    Plan = signed_effect_material_plan(
             Target, ProofId, Origin, anonymous,
             [{event, {fixture_event, N}}], []),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    participant_prepare_from_plan(Target, Origin, ProofId, Plan, PlanBlob, N).

participant_prepare_from_plan(Target, Origin, ProofId, Plan, PlanBlob, N) ->
    Signer = configured_test_signer(),
    #{pubkey := Pub} = Signer,
    Admission = crypto:hash(sha256, <<"admission", N:64>>),
    {ok, Goal} = quod_durable_term:encode_goal({fixture, N}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    DummyTarget = {<<"quod:dummy-participant-", (integer_to_binary(N))/binary>>,
                   crypto:hash(sha256, <<"dummy-target", N:64>>)},
    DummyPlan = signed_effect_material_plan(
                  DummyTarget, ProofId, Origin,
                  quod_dtx:principal(Plan), [], []),
    {ok, DummyBlob} = quod_dtx:encode(DummyPlan),
    {ok, Manifest} = quod_dtx:new_manifest(
                       #{proof_id => ProofId,
                         coordinator => {element(1, Origin), element(2, Origin),
                                         Pub, Admission},
                         nonce => crypto:hash(sha256, <<"nonce", N:64>>),
                         principal => quod_dtx:principal(Plan),
                         goal => Goal, result => Result,
                         request_binding => none,
                         participants =>
                             [{Target, quod_dtx:digest(Plan)},
                              {DummyTarget, quod_dtx:digest(DummyPlan)}]}),
    {ok, Attestation} = quod_dtx:attest_plan(Target, Plan, Manifest, Signer),
    {ok, DummyAttestation} = quod_dtx:attest_plan(
                               DummyTarget, DummyPlan, Manifest, Signer),
    {ok, Begin} = quod_dtx:new_begin(
                    Manifest, none,
                    [{Target, quod_dtx:digest(Plan), PlanBlob, Attestation},
                     {DummyTarget, quod_dtx:digest(DummyPlan), DummyBlob,
                      DummyAttestation}]),
    BeginRef = protocol_ref(Origin, N + 100, Begin),
    {ok, Prepare} = quod_dtx:new_prepare(Begin, BeginRef, Target),
    Control = signed(Target, Prepare, Admission, N + 200, Signer),
    Ref = protocol_ref(Target, N + 200, Prepare),
    #{control => Control, ref => Ref, origin => Origin,
      group_id => quod_dtx:group_id(Begin), begin_ref => BeginRef}.

participant_commit_finalize(Target, Fixture, Slot) ->
    Origin = maps:get(origin, Fixture),
    {ok, DecisionRef} = quod_dtx:certified_ref(
                          element(1, Origin), element(2, Origin), Slot - 1,
                          key(216), key(217), <<"qc">>),
    {ok, Finalize} = quod_dtx:new_finalize(
                       maps:get(group_id, Fixture), DecisionRef, commit,
                       maps:get(ref, Fixture), 2),
    Control = signed(Target, Finalize, key(218), Slot, configured_test_signer()),
    {Control, protocol_ref(Target, Slot, Finalize)}.

manifest_with_plan(Manifest, Target, PlanDigest) ->
    {quod_dtx_manifest, Version, ProofId, Coordinator, Nonce, Principal,
     Goal, GoalDigest, Result, ResultDigest, RequestBinding, Participants} =
        Manifest,
    {quod_dtx_manifest, Version, ProofId, Coordinator, Nonce, Principal,
     Goal, GoalDigest, Result, ResultDigest, RequestBinding,
     lists:keyreplace(Target, 1, Participants, {Target, PlanDigest})}.

transcript_with_goal(Goal) ->
    {<<1:128>>, [{?NS, key(1)}], wire_blob(Goal), allowed,
     0, <<0:256>>, complete}.

unique_symbol(Prefix, N) ->
    <<Prefix/binary, "_", (integer_to_binary(N))/binary>>.

assert_symbols_absent(Names) ->
    [?assertException(error, badarg, binary_to_existing_atom(Name, utf8))
     || Name <- Names].

dtx_preview(Control, Target, Slot, BlockHash, History, Projection) ->
    GroupId = quod_dtx:group_id(Control),
    case quod_dtx:preview_batch(
           [{Control, Target, Slot, BlockHash}],
           #{GroupId => History}, Projection) of
        {ok, Histories, Projection1, [#{effects := Effects}]} ->
            {ok, maps:get(GroupId, Histories), Projection1, Effects};
        Other -> Other
    end.

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
record_tuple(Record) -> Record.
record(Tuple) -> Tuple.
