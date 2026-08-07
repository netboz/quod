-module(quod_dtx_tests).

%% Slice-4 sealing: signed local plans, invocation transcripts, and the
%% live-bridge gate (`m:quod_dtx`), driven through real proof sessions over a
%% committed MVCC kb so the sealed diff and read tokens are the exact values
%% the OCC validator would later check.

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_proof_limits.hrl").

-define(NS, <<"quod:dtx">>).

%% ------------------------------------------------------------------
%% harness
%% ------------------------------------------------------------------

session(Facts) ->
    quod_proof_session:start(
      quod_ct:committed_kb(Facts),
      #{read_set => true, proof_context => {origin, test}}).

ctx() ->
    quod_predicates:proof_context(
      ?NS, 1, undefined, [{?NS, <<0:256>>}]).

open(Session, InvocationId, Goal) ->
    quod_proof_session:open(
      Session, InvocationId, Goal, ctx(),
      quod_transaction_scope:empty_selection()).

first(Session, Goal) ->
    InvocationId = crypto:strong_rand_bytes(16),
    ok = open(Session, InvocationId, Goal),
    {InvocationId, quod_proof_session:next(Session, InvocationId)}.

bind() ->
    #{target => {?NS, key(1)}, base_height => 1,
      proof_id => key(2), origin => {<<"quod:origin">>, key(3)},
      principal => anonymous}.

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
        %% The transcript binds this exact invocation: goal bytes, the full
        %% semantic chain, and the chained digest of the one answer taken.
        [{_InvocationId, Chain, GoalBin, 1, Digest, active}] =
            quod_dtx:transcript(Plan),
        ?assertEqual([{?NS, <<0:256>>}], Chain),
        ?assertEqual(term_to_binary(Goal, [deterministic]), GoalBin),
        SolutionDigest =
            crypto:hash(sha256, term_to_binary(Solution, [deterministic])),
        ?assertEqual(
           crypto:hash(sha256, <<0:256, 1:64, SolutionDigest/binary>>),
           Digest)
    after
        quod_proof_session:stop(Session)
    end.

untouched_scope_is_not_material_test() ->
    Session = session([{parent, tom, bob}]),
    try
        {_Id, {solution, _}} = first(Session, true),
        ?assertEqual(not_material, quod_dtx:seal_session(Session, bind()))
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
                 Core#{diff := term_to_binary([], [deterministic])}]),
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
           [{A, _, _, 2, _, complete},
            {B, _, _, 1, _, active},
            {C, _, _, 0, _, cancelled}],
           Entries),
        %% A cleanup cancel after completion is not a second outcome.
        ok = quod_proof_session:cancel(Session, A),
        {[{A, _, _, 2, _, complete} | _], _} =
            quod_proof_session:transcript(Session)
    after
        quod_proof_session:stop(Session)
    end.

transcript_charge_is_taken_before_the_goal_runs_test() ->
    Session = session([]),
    try
        %% Fill the transcript to exactly the limit, then show the next open
        %% is refused at admission — the goal never runs, so nothing escapes
        %% the transcript's accounting.
        Id = <<1:128>>,
        BaseCost = charged_cost(Id, pad_goal(0)),
        PadBytes = ?QUOD_MAX_SCOPE_TRANSCRIPT_BYTES - BaseCost,
        ok = open(Session, Id, pad_goal(PadBytes)),
        ?assertEqual({error, {too_large, transcript}},
                     open(Session, <<2:128>>, pad_goal(0))),
        %% The refused invocation does not exist afterwards.
        ?assertEqual({error, unknown_invocation},
                     quod_proof_session:next(Session, <<2:128>>))
    after
        quod_proof_session:stop(Session)
    end.

transcript_boundary_is_exact_test() ->
    Boundary = fun(Slack) ->
        Session = session([]),
        try
            Id = <<1:128>>,
            PadBytes = ?QUOD_MAX_SCOPE_TRANSCRIPT_BYTES
                - charged_cost(Id, pad_goal(0)) + Slack,
            open(Session, Id, pad_goal(PadBytes))
        after
            quod_proof_session:stop(Session)
        end
    end,
    ?assertEqual(ok, Boundary(0)),
    ?assertEqual({error, {too_large, transcript}}, Boundary(1)).

pad_goal(PadBytes) -> {pad, binary:copy(<<$p>>, PadBytes)}.

%% Mirrors the session's charge: the entry's external size plus the fixed
%% per-invocation slack for count, chained digest, and completion tag.
charged_cost(Id, Goal) ->
    Chain = quod_predicates:ctx_chain(ctx()),
    GoalBin = term_to_binary(Goal, [deterministic]),
    erlang:external_size({Id, Chain, GoalBin}) + 96.

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
%% finalize/0 seals every material scope before closing
%% ------------------------------------------------------------------

finalize_seals_local_scope_and_stores_the_plan_test() ->
    ProofId = key(21),
    Anchor = key(22),
    Identity = {?NS, Anchor},
    _Handle = quod_proof_context:start(
                ProofId, false, Identity, quod_time:mono_ms() + 5000),
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
        ?assertEqual(ok, quod_proof_context:finalize()),
        #{Identity := Plan} = quod_proof_context:sealed_plans(),
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
                ProofId, false, Identity, quod_time:mono_ms() + 5000),
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
        ?assertEqual(ok, quod_proof_context:finalize()),
        ?assertEqual(#{}, quod_proof_context:sealed_plans())
    after
        quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end),
        quod_proof_session:stop(Session)
    end.

finalize_fails_the_proof_on_a_refused_seal_test() ->
    ProofId = key(41),
    Anchor = key(42),
    Identity = {?NS, Anchor},
    _Handle = quod_proof_context:start(
                ProofId, false, Identity, quod_time:mono_ms() + 5000),
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
           quod_proof_context:finalize()),
        ?assertEqual(#{}, quod_proof_context:sealed_plans())
    after
        quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end),
        quod_proof_session:stop(Session)
    end.

%% quod_dtx:plan() is opaque to dialyzer; these two are the tests' only
%% deliberate representation crossings.
tuple(Plan) -> Plan.
plan(Tuple) -> Tuple.
