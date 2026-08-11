-module(quod_proof_session_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_proof_limits.hrl").

-export([close_proof_gate_2/3, close_policy_gate_4/3]).

resumable_invocation_preserves_solution_order_test() ->
    Session = quod_proof_session:start(
                committed([{choice, first}, {choice, second}]),
                #{read_set => true}),
    Invocation = invocation_id(1),
    try
        ok = quod_proof_session:open(
               Session, Invocation, {choice, {'X'}}, allowed, context(),
               empty_selection()),
        ?assertEqual(
           {solution, {choice, first}},
           quod_proof_session:next(Session, Invocation)),
        ?assertEqual(
           {solution, {choice, second}},
           quod_proof_session:next(Session, Invocation)),
        ?assertMatch(
           {complete, _}, quod_proof_session:next(Session, Invocation))
    after
        quod_proof_session:stop(Session)
    end.

repeated_invocations_share_staged_writes_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Context = context(),
    First = invocation_id(1),
    Second = invocation_id(2),
    try
        ok = quod_proof_session:open(
               Session, First, {assertz, {first_write, value}}, allowed, Context,
               empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, First)),

        ok = quod_proof_session:open(
               Session, Second,
               {',', {first_write, value},
                {assertz, {second_write, value}}},
               allowed, Context, empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Second)),

        Changes = quod_proof_session:local_changes(Session),
        ?assert(has_assert({first_write, value}, Changes)),
        ?assert(has_assert({second_write, value}, Changes)),
        ?assert(maps:is_key(
                  {first_write, 1}, quod_proof_session:read_set(Session))),
        ?assert(quod_proof_session:dirty(Session))
    after
        quod_proof_session:stop(Session)
    end.

failed_invocation_keeps_ordinary_prolog_writes_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Failing = invocation_id(1),
    try
        ok = quod_proof_session:open(
               Session, Failing,
               {',', {assertz, {retained, value}}, fail}, allowed, context(),
               empty_selection()),
        ?assertMatch(
           {complete, _}, quod_proof_session:next(Session, Failing)),
        ?assert(has_assert(
                  {retained, value},
                  quod_proof_session:local_changes(Session)))
    after
        quod_proof_session:stop(Session)
    end.

failed_branch_write_is_visible_to_its_next_alternative_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Invocation = invocation_id(1),
    Goal = {';',
            {',', {assertz, {retained, value}}, fail},
            {retained, value}},
    try
        ok = quod_proof_session:open(
               Session, Invocation, Goal, allowed, context(), empty_selection()),
        ?assertEqual(
           {solution, Goal}, quod_proof_session:next(Session, Invocation)),
        ?assert(has_assert(
                  {retained, value},
                  quod_proof_session:local_changes(Session)))
    after
        quod_proof_session:stop(Session)
    end.

stateless_erlog_error_keeps_the_current_revision_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Invocation = invocation_id(1),
    try
        ok = quod_proof_session:open(
               Session, Invocation, {assertz, true}, allowed, context(),
               empty_selection()),
        ?assertMatch(
           {error,
            {erlog,
             {permission_error, modify, static_procedure,
              {'/', true, 0}}}},
           quod_proof_session:next(Session, Invocation)),
        ?assertEqual([], quod_proof_session:local_changes(Session))
    after
        quod_proof_session:stop(Session)
    end.

stateful_erlog_error_preserves_its_revision_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Failing = invocation_id(1),
    Reader = invocation_id(2),
    try
        Goal = {',', {assertz, {before_error, retained}},
                {',', {set_prolog_flag, unknown, error},
                     missing_predicate}},
        ok = quod_proof_session:open(
               Session, Failing, Goal, allowed, context(), empty_selection()),
        ?assertMatch(
           {error,
            {erlog,
             {existence_error, procedure,
              {'/', missing_predicate, 0}}}},
           quod_proof_session:next(Session, Failing)),
        ?assert(has_assert(
                  {before_error, retained},
                  quod_proof_session:local_changes(Session))),
        ok = quod_proof_session:open(
               Session, Reader, {before_error, retained}, allowed, context(),
               empty_selection()),
        ?assertMatch({solution, _}, quod_proof_session:next(Session, Reader))
    after
        quod_proof_session:stop(Session)
    end.

transaction_error_adopts_rolled_back_revision_test() ->
    Committed = quod_transaction_predicates:load(committed([])),
    Session = quod_proof_session:start(Committed, #{read_set => true}),
    Failing = invocation_id(1),
    Reader = invocation_id(2),
    try
        Goal = {transaction,
                {',', {assertz, {rolled_back_on_error, hidden}},
                     {assertz, true}}},
        ok = quod_proof_session:open(
               Session, Failing, Goal, allowed, context(), empty_selection()),
        ?assertMatch(
           {error,
            {erlog,
             {permission_error, modify, static_procedure,
              {'/', true, 0}}}},
           quod_proof_session:next(Session, Failing)),
        ?assertNot(has_assert(
                     {rolled_back_on_error, hidden},
                     quod_proof_session:local_changes(Session))),
        ok = quod_proof_session:open(
               Session, Reader, {rolled_back_on_error, hidden},
               allowed, context(), empty_selection()),
        ?assertMatch({complete, _}, quod_proof_session:next(Session, Reader))
    after
        quod_proof_session:stop(Session)
    end.

older_continuation_rebases_to_newer_overlay_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    Reader = invocation_id(1),
    Writer = invocation_id(2),
    try
        %% The second alternative cannot succeed in the initial ontology view.
        ok = quod_proof_session:open(
               Session, Reader, {';', true, {arrived, later}},
               allowed, context(), empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Reader)),

        ok = quod_proof_session:open(
               Session, Writer, {assertz, {arrived, later}},
               allowed, context(), empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Writer)),

        %% Resuming the old choice point keeps its continuation and bindings,
        %% but reads through the writer invocation's current overlay revision.
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Reader)),
        ?assertMatch(
           {complete, _}, quod_proof_session:next(Session, Reader))
    after
        quod_proof_session:stop(Session)
    end.

publish_then_refresh_preserves_nested_revision_test() ->
    Metadata = {scope, <<"proof-id">>, self()},
    Session = quod_proof_session:start(
                committed([]),
                #{read_set => true, proof_context => Metadata}),
    Outer = invocation_id(1),
    Nested = invocation_id(2),
    try
        ok = quod_proof_session:open(
               Session, Outer, true, allowed, context(), empty_selection()),
        {ok, Outer0} =
            quod_proof_session:test_invocation_state(Session, Outer),
        {succeed, OuterWithWrite} =
            erlog_int:prove_goal(
              {assertz, {outer_write, published}}, Outer0),

        %% This is the selector boundary: the suspended outer invocation makes
        %% its in-progress revision canonical before servicing nested work.
        ok = quod_proof_session:publish(OuterWithWrite),
        ok = quod_proof_session:open(
               Session, Nested,
               {',', {outer_write, published},
                {assertz, {nested_write, published}}},
               allowed, context(), empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Nested)),

        RefreshedOuter = quod_proof_session:refresh(OuterWithWrite),
        ?assertEqual(Metadata, quod_proof_session:context(RefreshedOuter)),
        ?assertMatch(
           {succeed, _},
           erlog_int:prove_goal(
             {',', {outer_write, published},
              {nested_write, published}},
             RefreshedOuter)),
        Changes = quod_proof_session:local_changes(Session),
        ?assert(has_assert({outer_write, published}, Changes)),
        ?assert(has_assert({nested_write, published}, Changes))
    after
        quod_proof_session:stop(Session)
    end.

run_first_keeps_existing_result_contract_test() ->
    Est = quod_predicates:set_context(committed([{parent, tom, bob}]), context()),
    Goal = {',', {parent, tom, {'X'}}, {assertz, {child, {'X'}}}},
    {ok, Bindings, Changes, ReadSet} =
        quod_proof_session:run_first(Goal, Est, #{read_set => true}),
    ?assertEqual(#{'X' => bob}, Bindings),
    ?assert(has_assert({child, bob}, Changes)),
    ?assert(maps:is_key({parent, 2}, ReadSet)),
    ?assertMatch(
       {fail, _},
       quod_proof_session:run_first(
         {child, bob}, Est, #{read_set => true})).

invocation_continuations_are_bounded_test() ->
    Session = quod_proof_session:start(committed([]), #{}),
    try
        lists:foreach(
          fun(Id) ->
              ok = quod_proof_session:open(
                     Session, invocation_id(Id), true, allowed, context(),
                     empty_selection())
          end,
          lists:seq(1, ?QUOD_MAX_INVOCATIONS_PER_SCOPE)),
        ?assertEqual(
           {error,
            {proof_limit_exceeded, <<"quod:session-test">>}},
           quod_proof_session:open(
             Session, invocation_id(65535), true, allowed, context(),
             empty_selection()))
    after
        quod_proof_session:stop(Session)
    end.

seal_latches_state_and_first_manifest_attestation_test() ->
    {Pubkey, Signer} = signer(),
    Target = {<<"quod:session-test">>, key(200)},
    Origin = {<<"quod:origin">>, key(201)},
    ProofId = key(202),
    Bindings = #{target => Target, base_height => 7,
                 proof_id => ProofId, origin => Origin,
                 principal => anonymous},
    Session = quod_proof_session:start(
                committed([]),
                #{read_set => true,
                  proof_context => {test, attestation_lifecycle},
                  signer => Signer}),
    Invocation = invocation_id(40),
    Savepoint = invocation_id(41),
    Goal = {';', {assertz, {sealed_first, true}},
                 {assertz, {sealed_second, true}}},
    try
        ?assertEqual(
           {error, {protocol_error, unexpected_scope_command}},
           quod_proof_session:attest(Session, not_a_manifest)),
        ok = quod_proof_session:checkpoint_many(Session, [Savepoint]),
        ok = quod_proof_session:open(
               Session, Invocation, Goal, allowed, context(),
               empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Invocation)),
        {ok, Plan} = quod_proof_session:seal(Session, Bindings),
        {ok, PlanBytes} = quod_dtx:encode(Plan),
        ?assertEqual({ok, Plan}, quod_proof_session:seal(Session, Bindings)),
        {ok, RetryPlanBytes} = quod_dtx:encode(Plan),
        ?assertEqual(PlanBytes, RetryPlanBytes),
        ?assertEqual(
           {error, {protocol_error, request_binding}},
           quod_proof_session:seal(
             Session, Bindings#{origin => {<<"quod:other">>, key(203)}})),

        Manifest1 = manifest(Plan, key(204), Pubkey),
        Manifest2 = manifest(Plan, key(205), Pubkey),
        %% Manifest2 is independently valid for this exact plan. Its rejection
        %% below therefore proves the first-manifest latch, not shape checking.
        ?assertMatch(
           {ok, _},
           quod_dtx:attest_plan(Target, Plan, Manifest2, Signer)),
        {ok, Attestation} = quod_proof_session:attest(Session, Manifest1),
        {ok, AttestationBytes} =
            quod_dtx:encode_attestation(Attestation),
        {ok, RetryAttestation} =
            quod_proof_session:attest(Session, Manifest1),
        {ok, RetryAttestationBytes} =
            quod_dtx:encode_attestation(RetryAttestation),
        ?assertEqual(AttestationBytes, RetryAttestationBytes),
        ?assertEqual(
           {error, {protocol_error, manifest_binding}},
           quod_proof_session:attest(Session, Manifest2)),
        ?assertEqual(
           {ok, Attestation},
           quod_proof_session:attest(Session, Manifest1)),

        FrozenChanges = quod_proof_session:local_changes(Session),
        FrozenTranscript = quod_proof_session:transcript(Session),
        FrozenGeneration = quod_proof_session:overlay_generation(Session),
        SealedError = {error, {protocol_error, unexpected_scope_command}},
        ?assertEqual(
           SealedError, quod_proof_session:next(Session, Invocation)),
        ?assertEqual(
           SealedError, quod_proof_session:cancel(Session, Invocation)),
        ?assertEqual(
           SealedError,
           quod_proof_session:open(
             Session, invocation_id(42), true, allowed, context(),
             empty_selection())),
        ?assertEqual(
           SealedError,
           quod_proof_session:checkpoint_many(
             Session, [invocation_id(43)])),
        ?assertEqual(
           SealedError,
           quod_proof_session:restore_many(Session, [Savepoint])),
        ?assertEqual(
           SealedError,
           quod_proof_session:release_many(Session, [Savepoint])),
        ?assertEqual(FrozenChanges,
                     quod_proof_session:local_changes(Session)),
        ?assertNot(has_assert(
                     {sealed_second, true},
                     quod_proof_session:local_changes(Session))),
        ?assertEqual(FrozenTranscript,
                     quod_proof_session:transcript(Session)),
        ?assertEqual(FrozenGeneration,
                     quod_proof_session:overlay_generation(Session))
    after
        quod_proof_session:stop(Session)
    end.

not_material_seal_is_also_terminal_test() ->
    {_Pubkey, Signer} = signer(),
    Session = quod_proof_session:start(
                committed([]), #{read_set => true, signer => Signer}),
    Bindings = #{target => {<<"quod:session-test">>, key(210)},
                 base_height => 7, proof_id => key(211),
                 origin => {<<"quod:origin">>, key(212)},
                 principal => anonymous},
    try
        ?assertEqual(not_material,
                     quod_proof_session:seal(Session, Bindings)),
        ?assertEqual(not_material,
                     quod_proof_session:seal(Session, Bindings)),
        ?assertEqual(
           {error, {protocol_error, unexpected_scope_command}},
           quod_proof_session:attest(Session, not_a_manifest)),
        ?assertEqual(
           {error, {protocol_error, unexpected_scope_command}},
           quod_proof_session:open(
             Session, invocation_id(44), true, allowed, context(),
             empty_selection()))
    after
        quod_proof_session:stop(Session)
    end.

pending_generation_rejects_open_and_discards_old_invocation_test() ->
    with_proof_gate(
      fun(Tab, AccessGuard) ->
          Session = quod_proof_session:start(
                      committed([{choice, first}]),
                      #{read_set => true, access_guard => AccessGuard}),
          Invocation = invocation_id(44),
          try
              ok = quod_proof_session:open(
                     Session, Invocation, {choice, {'X'}}, allowed, context(),
                     empty_selection()),
              GroupId = <<101:256>>,
              true = ets:insert(
                       Tab,
                       {proof_gate, true, {pending, GroupId}, 7, GroupId}),
              ?assertEqual(
                 {error, {transaction_pending, GroupId}},
                 quod_proof_session:next(Session, Invocation)),
              ?assertEqual(
                 {error, {transaction_pending, GroupId}},
                 quod_proof_session:open(
                   Session, invocation_id(45), true, allowed, context(),
                   empty_selection()))
          after
              quod_proof_session:stop(Session)
          end
      end).

gate_change_during_step_cannot_expose_solution_test() ->
    with_proof_gate(
      fun(_Tab, AccessGuard) ->
          Session = quod_proof_session:start(
                      with_gate_predicate(committed([])),
                      #{read_set => true, access_guard => AccessGuard}),
          Invocation = invocation_id(46),
          GroupId = <<102:256>>,
          try
              ok = quod_proof_session:open(
                     Session, Invocation,
                     {close_proof_gate, GroupId}, allowed, context(),
                     empty_selection()),
              %% The compiled predicate succeeds after closing the gate. The
              %% post-step access check must replace that would-be solution by
              %% the exact typed fence error.
              ?assertEqual(
                 {error, {transaction_pending, GroupId}},
                 quod_proof_session:next(Session, Invocation))
          after
              quod_proof_session:stop(Session)
          end
      end).

authorization_subproof_retains_the_parent_guard_test() ->
    with_proof_gate(
      fun(_Tab, AccessGuard) ->
          Session = quod_proof_session:start(
                      with_policy_predicate(committed([])),
                      #{read_set => true, access_guard => AccessGuard}),
          GroupId = <<103:256>>,
          try
              ?assertThrow(
                 {quod_ask_error, {transaction_pending, GroupId}},
                 quod_ask:authorize_scope(
                   anonymous, true, [],
                   {<<"quod:session-guard-test">>, <<1:256>>},
                   0, Session))
          after
              quod_proof_session:stop(Session)
          end
      end).

close_proof_gate_2(Goal, Next, #est{bs = Bs} = St) ->
    {close_proof_gate, <<_:256>> = GroupId} = erlog_int:dderef(Goal, Bs),
    true = ets:insert(
             'quod_simplex_genesis_quod:session-guard-test',
             {proof_gate, true, {pending, GroupId}, 7, GroupId}),
    erlog_int:prove_body(Next, St).

close_policy_gate_4(_Goal, Next, St) ->
    GroupId = <<103:256>>,
    true = ets:insert(
             'quod_simplex_genesis_quod:session-guard-test',
             {proof_gate, true, {pending, GroupId}, 7, GroupId}),
    erlog_int:prove_body(Next, St).

context() ->
    quod_predicates:proof_context(<<"quod:session-test">>, 7, undefined).

empty_selection() -> quod_transaction_scope:empty_selection().

invocation_id(N) -> <<N:128>>.

has_assert(Fact, Changes) ->
    lists:any(
      fun({assert, {Fact0, _Body}}) -> Fact0 =:= Fact;
         (_) -> false
      end, Changes).

committed(Facts) -> quod_ct:committed_kb(Facts).

signer() ->
    {Pubkey, Seed} = quod_identity:generate(),
    {Pubkey,
     #{pubkey => Pubkey,
       key => quod_identity:key_term({Pubkey, Seed})}}.

key(N) -> <<N:256>>.

manifest(Plan, Nonce, Coordinator) ->
    {ok, GoalBlob} = quod_durable_term:encode_goal({distributed, true}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    {OriginNs, OriginAnchor} = quod_dtx:origin(Plan),
    Target = quod_dtx:target(Plan),
    OtherTarget = {<<"quod:other-participant">>, key(220)},
    {ok, Manifest} = quod_dtx:new_manifest(
                       #{proof_id => quod_dtx:proof_id(Plan),
                         coordinator =>
                             {OriginNs, OriginAnchor,
                              Coordinator, key(221)},
                         nonce => Nonce,
                         principal => quod_dtx:principal(Plan),
                         goal => GoalBlob,
                         result => ResultBlob,
                         participants =>
                             [{Target, quod_dtx:digest(Plan)},
                              {OtherTarget, key(222)}]}),
    Manifest.

with_gate_predicate(#est{db = Db} = Est) ->
    Est#est{db = erlog_int:add_compiled_proc(
                   {close_proof_gate, 1}, ?MODULE, close_proof_gate_2, Db)}.

with_policy_predicate(#est{db = Db} = Est) ->
    Est#est{db = erlog_int:add_compiled_proc(
                   {can_invoke, 4}, ?MODULE, close_policy_gate_4, Db)}.

with_proof_gate(Fun) ->
    Namespace = <<"quod:session-guard-test">>,
    Table = 'quod_simplex_genesis_quod:session-guard-test',
    Tab = ets:new(Table, [named_table, protected, set]),
    true = ets:insert(Tab, {proof_gate, true, open, 7, none}),
    try Fun(Tab, {quod_proof_access, Namespace, 7})
    after
        ets:delete(Tab)
    end.
