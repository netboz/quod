-module(quod_prolog_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-import(quod_ct, [diff_for/1, change/3, batch/1, wait_until/2]).

-export([init/1, callback_mode/0, handle_event/4]).

%%%===================================================================
%%% fixtures
%%%===================================================================

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"test:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Pid} = quod_prolog:start_link(
                  Ns, #{node_id => {"127.0.0.1", 5000}, max_proof_workers => 1,
                        outcome_backend => memory}),
    %% no quod_simplex in these isolated tests — simulate the rebuild handshake completing
    ok = quod_prolog:mark_ready(Ns),
    {Ns, Pid}.

cleanup({_Ns, Pid}) ->
    case is_process_alive(Pid) of true -> gen_server:stop(Pid); false -> ok end,
    ok.

mark_ready_acknowledges_from_the_handling_engine_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"ready-ack:",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    SimplexKey = {quod_simplex, Ns},
    true = quod_reg:reg(SimplexKey),
    {ok, Pid} = quod_prolog:start_link(
                  Ns, #{node_id => {"127.0.0.1", 5000},
                        outcome_backend => memory}),
    try
        %% init requests replay first; readiness must not be acknowledged by
        %% the process that merely queued mark_ready.
        receive {'$gen_cast', rebuild} -> ok
        after 1000 -> error(no_rebuild_request) end,
        receive
            {'$gen_cast', {prolog_ready, _, _}} = Early ->
                error({early_ready_ack, Early})
        after 0 ->
            ok
        end,
        ok = quod_prolog:mark_ready(Ns),
        receive
            {'$gen_cast', {prolog_ready, Pid, 0}} -> ok
        after 1000 ->
            error(no_ready_ack)
        end,
        ?assertMatch({ok, _, 0}, quod_prolog:attach_runtime(Ns))
    after
        case is_process_alive(Pid) of
            true -> gen_server:stop(Pid);
            false -> ok
        end,
        true = gproc:unreg(quod_reg:name(SimplexKey))
    end.

committed_result_survives_scope_cleanup_failure_test() ->
    ProofId = <<41:256>>,
    Ns = <<"quod:cleanup-target">>,
    Anchor = <<42:256>>,
    Identity = {Ns, Anchor},
    _ = quod_proof_context:start(
          ProofId, false, {<<"quod:origin">>, <<43:256>>},
          quod_time:mono_ms() + 1000, anonymous),
    ScopePid = spawn(fun() -> receive stop -> ok end end),
    try
        {ok, _ScopeId, _Handle} =
            quod_proof_context:get_or_open_scope(
              Identity,
              fun(ScopeId) ->
                  Handle = {quod_scope_session, ScopePid, ScopeId, ProofId,
                            make_ref(), Ns, Anchor},
                  {ok, ScopePid, Handle}
              end),
        TestMRef = monitor(process, ScopePid),
        exit(ScopePid, kill),
        receive
            {'DOWN', TestMRef, process, ScopePid, killed} -> ok
        after 1000 ->
            error(scope_did_not_stop)
        end,
        Result = {committed, [#{}],
                  {transaction, Ns, Anchor, <<44:256>>}},
        ?assertEqual(Result, quod_prolog:test_finalize_pinned_result(Result))
    after
        quod_proof_context:stop(fun(_Scope) -> ok end,
                                fun(_Proxy) -> ok end)
    end.

terminal_result_accepts_any_typed_rejection_reason_test() ->
    ?assertEqual(
       {rejected, retry},
       quod_prolog:test_terminal_result(
         #{status => {rejected, retry, 7}, tx_id => <<45:256>>})),
    ?assertEqual(
       {committed, 8, <<46:256>>},
       quod_prolog:test_terminal_result(
         #{status => {committed, 8}, tx_id => <<46:256>>})),
    ?assertEqual(
       error,
       quod_prolog:test_terminal_result(
         #{status => {rejected, <<"not-an-atom">>, 7},
           tx_id => <<47:256>>})).

keyed_engine_threads_its_signer_into_scope_plans_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"keyed-scope:",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {Pubkey, Seed} = quod_identity:generate(),
    Anchor = <<51:256>>,
    GenesisTable = binary_to_atom(
                     <<"quod_simplex_genesis_", Ns/binary>>, utf8),
    GenesisTable = ets:new(GenesisTable, [named_table, protected]),
    true = ets:insert(GenesisTable, {anchor, Anchor}),
    Identity = #{pubkey => Pubkey,
                 key => quod_identity:key_term({Pubkey, Seed})},
    {ok, Pid} = quod_prolog:start_link(
                  Ns, #{node_id => Pubkey, identity => Identity,
                        outcome_backend => memory}),
    try
        Membership = change(
                       Ns,
                       diff_for(
                         {peer_admitted, Pubkey, "127.0.0.1", 9000,
                          Pubkey}),
                       #{}),
        Policy = change(
                   Ns,
                   diff_for(
                     {can_invoke, {'Goal'}, {'Principal'},
                      {'Chain'}, {'Namespace'}}),
                   #{}),
        ok = ab(Ns, 1, {batch, [Membership, Policy]}),
        ok = quod_prolog:mark_ready(Ns),
        ProofId = <<48:256>>,
        ScopeId = <<49:128>>,
        Deadline = quod_time:mono_ms() + 5000,
        {ok, Handle} = gen_server:call(
                         Pid,
                         {scope_open, ScopeId, ProofId, Anchor, false,
                          Deadline}),
        InvocationId = <<50:128>>,
        {ok, OpenRef} = quod_scope_session:invoke_open(
                          Handle, InvocationId,
                          {assertz, {signed_scope_fact, true}},
                          [{Ns, Anchor}],
                          quod_transaction_scope:empty_selection()),
        assert_scope_reply(Handle, OpenRef, {opened, InvocationId}),
        {ok, NextRef} = quod_scope_session:invoke_next(
                          Handle, InvocationId, 1),
        ?assertMatch({solution, 1, _, true},
                     scope_reply(Handle, NextRef)),
        _ = quod_proof_context:start(
              ProofId, false, {Ns, Anchor}, Deadline, {node, Pubkey}),
        try
            {ok, Plan} = quod_scope_session:seal(
                           Handle, {Ns, Anchor}, {node, Pubkey}),
            ?assertEqual(Pubkey, quod_dtx:signer(Plan)),
            ?assert(quod_dtx:verify(Plan))
        after
            quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end)
        end,
        ok = quod_scope_session:close(Handle)
    after
        cleanup({Ns, Pid}),
        ets:delete(GenesisTable)
    end.

assert_scope_reply(Handle, RequestRef, Expected) ->
    ?assertEqual(Expected, scope_reply(Handle, RequestRef)).

scope_reply(Handle, RequestRef) ->
    Worker = quod_scope_session:pid(Handle),
    {quod_scope_session, Worker, _ScopeId, ProofId,
     SessionRef, _Ns, _Anchor} = Handle,
    receive
        {scope_reply, Worker, ProofId, SessionRef, RequestRef, Reply} -> Reply
    after 1000 ->
        error(scope_reply_timeout)
    end.

shared_plan_submission_gate_rejects_rebuilding_target_test() ->
    Ns = <<"quod:rebuilding-target">>,
    ?assertEqual(
       {error, {ontology_rebuilding, Ns}},
       quod_prolog:test_not_ready_plan_submission(Ns)).

remote_submission_preserves_retryable_classification_test() ->
    ?assertEqual(
       {rejected, retry},
       quod_prolog:test_submit_outcome({error, busy})),
    ?assertEqual(
       {rejected, retry},
       quod_prolog:test_submit_outcome(
         {error, {ontology_rebuilding, <<"quod:target">>}})),
    ?assertEqual(
       {rejected, bad_plan},
       quod_prolog:test_submit_outcome({error, malformed_plan})),
    %% Apply-time policy refusal is part of the public ontology contract, not
    %% an internal validation error: a foreign caller must be able to match it.
    ?assertEqual(
       {rejected, policy_self_seal_forbidden},
       quod_prolog:test_submit_outcome(
         {error, policy_self_seal_forbidden})).

retired_pending_group_releases_exact_waiter_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"quod:retired-group-waiter">>,
    Anchor = <<81:256>>,
    Coordinator = <<82:256>>,
    Admission = <<83:256>>,
    GroupId = <<84:256>>,
    GroupRef = {group, Ns, Anchor, Coordinator, Admission, GroupId},
    Pending = #{lane => {Admission, Coordinator},
                sequence => 1, group_id => GroupId},
    {ok, Outcomes0} = quod_outcome:open(
                        Ns, Anchor, #{outcome_backend => memory}),
    {ok, Outcomes1} = quod_outcome:project_pending_begin(
                        Outcomes0, Pending),
    {ok, Outcomes2} = quod_outcome:project_pending_begin(Outcomes1, none),
    {ok, Outcomes3} = quod_outcome:advance_applied(Outcomes2, 1),
    {ok, Outcomes4} = quod_outcome:flush(Outcomes3),
    Owner = self(),
    BarrierPid =
        spawn(
          fun() ->
                  true = quod_reg:reg({quod_simplex, Ns}),
                  Owner ! {barrier_ready, self()},
                  receive
                      {'$gen_call', From,
                       {dtx_group_barrier, GroupRef, 1}} ->
                          gen_statem:reply(
                            From, {ok, {rejected, coordinator_retired}})
                  after 1000 ->
                      exit(barrier_not_called)
                  end
          end),
    receive
        {barrier_ready, BarrierPid} -> ok
    after 1000 ->
        error(barrier_not_ready)
    end,
    try
        {CallRef, Remaining} =
            quod_prolog:test_release_absent_group_waiter(
              Ns, GroupRef, Outcomes4),
        ?assertEqual(0, Remaining),
        receive
            {quod_proof_reply, _Engine, CallRef,
             {error, coordinator_retired}} -> ok
        after 1000 ->
            error(retired_group_waiter_was_not_released)
        end
    after
        case is_process_alive(BarrierPid) of
            true -> exit(BarrierPid, kill);
            false -> ok
        end,
        ok = quod_outcome:close(Outcomes4)
    end.

prolog_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun t_unknown_fails/1,
      fun t_explicit_failure_reason_and_internal_bare_fail/1,
      fun t_apply_and_read/1,
      fun t_user_principal_is_typed_and_server_owned/1,
      fun t_occ_reject/1,
      fun t_policy_self_seal/1,
      fun t_batch_apply/1,
      fun t_duplicate_plan_applies_once/1,
      fun t_same_block_read_after_write/1,
      fun t_submit_plan_validation/1,
      fun t_pending_begin_projection_is_exact_and_clearable/1,
      fun t_worker_limit/1]}.

t_pending_begin_projection_is_exact_and_clearable({Ns, _Pid}) ->
    fun() ->
        Coordinator = <<71:256>>,
        Admission = <<72:256>>,
        GroupId = <<73:256>>,
        GroupRef = {group, Ns, <<0:256>>, Coordinator, Admission, GroupId},
        Pending = #{lane => {Admission, Coordinator},
                    sequence => 1, group_id => GroupId},
        ok = quod_prolog:project_pending_begin(Ns, Pending),
        ?assertEqual(
           {ok, #{applied_floor => 0,
                  outcome => #{status => pending, phase => pending_begin,
                               ref => GroupRef}}},
           quod_prolog:outcome_snapshot(Ns, GroupRef)),
        ?assertEqual(
           {ok, #{history => none, applied => none,
                  applied_floor => 0, generation => 0}},
           quod_prolog:dtx_group_state(Ns, GroupId)),
        ok = quod_prolog:project_pending_begin(Ns, none),
        ?assertEqual(
           {ok, #{applied_floor => 0, outcome => not_found}},
           quod_prolog:outcome_snapshot(Ns, GroupRef))
    end.

%% The one submission primitive refuses anything that is not this node's own
%% freshly sealed plan for this exact engine: a wrong target identity, a
%% foreign witness, a tampered signature, or a base ahead of the applied head.
t_submit_plan_validation({Ns, _}) ->
    fun() ->
        Session = quod_proof_session:start(
                    quod_ct:committed_kb([]), #{read_set => true}),
        try
            InvocationId = crypto:strong_rand_bytes(16),
            ok = quod_proof_session:open(
                   Session, InvocationId, {assertz, {planned, x}}, allowed,
                   quod_predicates:proof_context(Ns, 1, undefined, []),
                   quod_transaction_scope:empty_selection()),
            {solution, _} = quod_proof_session:next(Session, InvocationId),
            Seal = fun(Bind) ->
                       {ok, Plan} = quod_dtx:seal_session(
                                      Session,
                                      maps:merge(
                                        #{target => {Ns, <<0:256>>},
                                          base_height => 0,
                                          proof_id => <<1:256>>,
                                          origin => {Ns, <<0:256>>},
                                          principal => anonymous}, Bind)),
                       Plan
                   end,
            %% (The accepted path commits through consensus and is covered by
            %% the integration tests; here only the immediate refusals.)
            ?assertEqual(
               {error, bad_plan},
               quod_prolog:submit_plan(
                 Ns, Seal(#{target => {<<"elsewhere">>, <<0:256>>}}),
                 {assertz, {planned, x}}, #{})),
            ?assertEqual(
               {error, bad_plan},
               quod_prolog:submit_plan(
                 Ns, Seal(#{base_height => 999}),
                 {assertz, {planned, x}}, #{})),
            %% Witness ownership follows the target engine's actual node id,
            %% never mutable application environment observed later.
            {Pub, Seed} = quod_identity:generate(),
            KeyedIdentity = #{pubkey => Pub,
                              key => quod_identity:key_term({Pub, Seed})},
            KeyedNs = <<Ns/binary, ":keyed">>,
            KeyedAnchor = <<52:256>>,
            GenesisTable = binary_to_atom(
                             <<"quod_simplex_genesis_", KeyedNs/binary>>,
                             utf8),
            GenesisTable = ets:new(
                             GenesisTable, [named_table, protected]),
            true = ets:insert(GenesisTable, {anchor, KeyedAnchor}),
            {ok, KeyedPid} = quod_prolog:start_link(
                               KeyedNs, #{node_id => Pub,
                                          identity => KeyedIdentity,
                                          outcome_backend => memory}),
            ok = quod_prolog:mark_ready(KeyedNs),
            try
                KeyedPlan = Seal(
                              #{target => {KeyedNs, KeyedAnchor}}),
                ?assertEqual(
                   {error, bad_plan},
                   quod_prolog:submit_plan(
                     KeyedNs, KeyedPlan,
                     {assertz, {planned, x}}, #{}))
            after
                gen_server:stop(KeyedPid),
                ets:delete(GenesisTable)
            end
        after
            quod_proof_session:stop(Session)
        end
    end.

absolute_proof_timeout_test_() ->
    {setup,
     fun() ->
         {ok, _} = application:ensure_all_started(gproc),
         Ns = <<"timeout:", (integer_to_binary(
                               erlang:unique_integer([positive])))/binary>>,
         {ok, Pid} = quod_prolog:start_link(
                       Ns, #{node_id => {"127.0.0.1", 5000},
                             proof_timeout_ms => 60,
                             outcome_backend => memory}),
         ok = quod_prolog:mark_ready(Ns),
         {Ns, Pid}
     end,
     fun cleanup/1,
     fun({Ns, _Pid}) ->
         Rule = {':-', loop, loop},
         ok = ab(
                Ns, 1,
                with_host_policy(
                  Ns, batch(change(Ns, diff_for(Rule), #{})))),
         ?_assertEqual({error, {proof_limit_exceeded, Ns}},
                       quod_prolog:prove(Ns, loop))
     end}.

outcome_unknown_timeout_test_() ->
    {setup,
     fun() ->
         {ok, _} = application:ensure_all_started(gproc),
         Ns = <<"write-timeout:", (integer_to_binary(
                                     erlang:unique_integer([positive])))/binary>>,
         {ok, Pid} = quod_prolog:start_link(
                       Ns, #{node_id => {"127.0.0.1", 5000},
                             max_proof_workers => 1,
                             proof_timeout_ms => 60,
                             transaction_ttl_ms => 200,
                             outcome_backend => memory}),
         ok = install_host_policy(Ns),
         ok = quod_prolog:mark_ready(Ns),
         {Ns, Pid}
     end,
     fun cleanup/1,
     fun({Ns, _Pid}) ->
         fun() ->
             Parent = self(),
             ProofRef = make_ref(),
             _Caller = spawn(
                         fun() ->
                             Parent !
                               {ProofRef,
                                quod_prolog:prove(
                                  Ns, {assertz, {timeout_fact, x}})}
                         end),
             ?assertEqual(ok, wait_proof_waiters(Ns, 1, 100)),
             ?assertEqual(0, maps:get(proof_workers, quod_prolog:stats(Ns))),
             %% Waiting for consensus no longer consumes the sole derivation
             %% slot: an independent read can still run immediately.
             ?assertMatch({fail, [_ | _]},
                          quod_prolog:prove(Ns, {missing, fact})),
             Result = receive
                          {ProofRef, ProofResult} -> ProofResult
                      after 1000 ->
                          error(missing_outcome_unknown)
                      end,
             ?assertMatch({error, {outcome_unknown, _}}, Result),
             {error, {outcome_unknown,
                      Ref = {transaction, Ns, <<0:256>>, TxId}}} = Result,
             ?assert(is_binary(TxId)),
             %% The polling reference remains durable because the already
             %% submitted transaction may still commit after caller timeout.
             ?assertEqual(
                {ok, #{status => pending, ref => Ref}},
                quod_prolog:outcome(Ref)),
             ?assertEqual(1, maps:get(park_timeouts, quod_prolog:stats(Ns))),
             ?assertEqual(0, maps:get(proof_waiters, quod_prolog:stats(Ns))),
             ?assertMatch({fail, [_ | _]},
                          quod_prolog:prove(Ns, {timeout_fact, x})),
             ?assertEqual(1, maps:get(park_timeouts, quod_prolog:stats(Ns)))
         end
     end}.

%% The retained-custody deadline is intentionally ambiguous: Simplex reports
%% `unavailable`, but the exact signed transaction may still commit. Exercise a
%% real asynchronous gen_statem append response and pin the Prolog contract:
%% keep the caller parked, never retry or reject it, then return outcome_unknown
%% only when the caller's transaction TTL expires.
unavailable_append_reply_waits_for_outcome_unknown_test_() ->
    TransactionTtl = 180,
    {setup,
     fun() ->
         {ok, _} = application:ensure_all_started(gproc),
         Ns = <<"unavailable-reply:",
                (integer_to_binary(
                   erlang:unique_integer([positive])))/binary>>,
         {ok, Pid} = quod_prolog:start_link(
                       Ns, #{node_id => {"127.0.0.1", 5000},
                             transaction_ttl_ms => TransactionTtl,
                             outcome_backend => memory}),
         ok = install_host_policy(Ns),
         ok = quod_prolog:mark_ready(Ns),
         {Ns, Pid}
     end,
     fun cleanup/1,
     fun({Ns, _Pid}) ->
         fun() ->
             {ok, Simplex} =
                 gen_statem:start_link(
                   quod_reg:via({quod_simplex, Ns}), ?MODULE,
                   {fake_unavailable_simplex, self(), Ns}, []),
             try
                 Ref = make_ref(),
                 Parent = self(),
                 StartedAt = quod_time:mono_ms(),
                 _Caller =
                     spawn(
                       fun() ->
                           Parent !
                               {Ref,
                                quod_prolog:prove(
                                  Ns,
                                  {assertz,
                                   {unavailable_fact, x}})}
                       end),

                 {SeenChange, TxId, AppendReply} =
                     receive
                         {fake_unavailable_append, Simplex, 1,
                          #transaction{tx_id = SeenTxId} = Change,
                          SeenReply, ReplyStats} ->
                             ?assertEqual(
                                {error, not_in_charge, unavailable},
                                SeenReply),
                             %% The fake statem takes this snapshot only after
                             %% gen_statem:reply/2 has reached quod_prolog.
                             ?assertEqual(
                                1, maps:get(parked, ReplyStats)),
                             ?assertEqual(
                                0, maps:get(
                                     park_timeouts, ReplyStats)),
                             {Change, SeenTxId, SeenReply}
                     after 1000 ->
                         error(missing_unavailable_append_reply)
                     end,
                 ?assertEqual(
                    {error, not_in_charge, unavailable}, AppendReply),

                 %% No definite rejection and no resubmission may occur before
                 %% the original caller deadline.
                 receive
                     {Ref, EarlyResult} ->
                         error({early_append_result, EarlyResult});
                     {fake_unavailable_append, Simplex, EarlyN,
                      _, _, _} ->
                         error({unexpected_append_retry, EarlyN})
                 after 60 ->
                     ok
                 end,
                 ?assertEqual(
                    1, maps:get(parked, quod_prolog:stats(Ns))),

                 Result =
                     receive
                         {Ref, FinalResult} -> FinalResult;
                         {fake_unavailable_append, Simplex, RetryN,
                          _, _, _} ->
                             error({unexpected_append_retry, RetryN})
                     after 1000 ->
                         error(missing_outcome_unknown)
                     end,
                 OutcomeRef = {transaction, Ns, <<0:256>>, TxId},
                 ?assertEqual(
                    {error, {outcome_unknown, OutcomeRef}}, Result),
                 ?assert(
                    quod_time:mono_ms() - StartedAt >= TransactionTtl),
                 ?assertEqual(
                    #{parked => 0, park_timeouts => 1},
                    maps:with(
                      [parked, park_timeouts],
                      quod_prolog:stats(Ns))),
                 ?assertMatch(
                    {fail, [_ | _]},
                    quod_prolog:prove(
                      Ns, {unavailable_fact, x})),
                 %% The exact transaction may still finalize. Applying the
                 %% captured envelope resolves the anchored reference and
                 %% retains the compact terminal classification after caller loss.
                 ok = ab(Ns, 2, batch(SeenChange)),
                 ?assertEqual({ok, [#{}], 2},
                              quod_prolog:prove(Ns, {unavailable_fact, x})),
                 ?assertEqual(
                    {ok, #{status => committed, height => 2,
                           ref => OutcomeRef}},
                    quod_prolog:outcome(OutcomeRef)),
                 receive
                     {fake_unavailable_append, Simplex, LateN,
                      _, _, _} ->
                         error({unexpected_append_retry, LateN})
                 after 0 ->
                     ok
                 end
             after
                 gen_statem:stop(Simplex)
             end
         end
     end}.

%% Slice B: the Prolog-side membership verdict + projection lockstep. Small validation TTL so the
%% reap-to-abstain case runs fast.
setup_mem() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"memtest:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Pid} = quod_prolog:start_link(
                  Ns, #{node_id => {"127.0.0.1", 5000}, validation_ttl_ms => 500,
                        outcome_backend => memory}),
    ok = quod_prolog:mark_ready(Ns),
    {Ns, Pid}.

membership_test_() ->
    {foreach, fun setup_mem/0, fun cleanup/1,
     [fun t_verdict_basic/1,
      fun t_verdict_can_join_fail/1,
      fun t_verdict_side_effects/1,
      fun t_verdict_lifecycle/1,
      fun t_verdict_tag_reuse/1,
      fun t_lockstep/1]}.

%% Slice 1 increment 2: the post-apply event layer (doc/agent-fipa-plan.md §7) — apply origin drives
%% the applied_live event and the replay boundaries on the {runtime, Ns} property.
runtime_event_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun t_live_emits_event/1,
      fun t_live_reject_emits_event/1,
      fun t_replay_no_event/1,
      fun t_replay_reentry/1,
      fun t_no_boundary_without_advance/1]}.

%%%===================================================================
%%% helpers
%%%===================================================================

%% Minimal real gen_statem used by the unavailable-reply contract test. Replying
%% first and then synchronously reading Prolog stats creates a same-sender
%% mailbox barrier: the notification observed by the test proves append_result/3
%% already consumed the exact consensus response.
init({fake_unavailable_simplex, Owner, Ns}) ->
    {ok, running, #{owner => Owner, ns => Ns, appends => 0}}.

callback_mode() ->
    handle_event_function.

handle_event(
  {call, From}, {append, Change, _TransactionCtx}, running,
  Data = #{owner := Owner, ns := Ns, appends := Count}) ->
    Reply = {error, not_in_charge, unavailable},
    gen_statem:reply(From, Reply),
    Stats = quod_prolog:stats(Ns),
    Count1 = Count + 1,
    Owner !
        {fake_unavailable_append, self(), Count1,
         Change, Reply, Stats},
    {keep_state, Data#{appends => Count1}};
handle_event(_EventType, _EventContent, _State, _Data) ->
    keep_state_and_data.


%% Apply a block as a LIVE commit (the common case these tests simulate). Increment-2 tests that need
%% the replay path call quod_prolog:apply_entry/3 with `replay` explicitly.
ab(Ns, Index, Change) -> ae(Ns, Index, Change, live).

ae(Ns, Index, Data, Origin) ->
    quod_prolog:apply_entry(
      Ns, #entry{index = Index, data = Data}, Origin).

%% These bare-engine tests do not run Simplex slot 1, so include the same
%% unconditional host-entry policy that founding injects into every real
%% genesis. Keeping it in the committed batch exercises the production
%% authorization path without adding a test-only engine bypass.
host_policy_tx(Ns) ->
    (change(
       Ns,
       diff_for({can_invoke, {'Goal'}, {'Principal'}, [], {'Namespace'}}),
       #{}))#transaction{proof_id = none, plan_digest = none,
                         goal = undefined, result = undefined}.

with_host_policy(Ns, {batch, Transactions}) ->
    {batch, [host_policy_tx(Ns) | Transactions]}.

install_host_policy(Ns) ->
    ok = ab(Ns, 1, {batch, [host_policy_tx(Ns)]}),
    _ = quod_prolog:applied(Ns),
    ok.

%%%===================================================================
%%% tests
%%%===================================================================

t_unknown_fails({Ns, _}) ->
    fun() ->
        ok = install_host_policy(Ns),
        %% A missing predicate fails with its call as the default diagnostic.
        ?assertEqual(
           {fail, [{nonexistent, foo}]},
           quod_prolog:prove(Ns, {nonexistent, foo})),
        %% routing: unknown namespace is distinct from goal-failure
        ?assertEqual({error, no_such_namespace},
                     quod_prolog:prove(<<"nope">>, {anything, x}))
    end.

t_explicit_failure_reason_and_internal_bare_fail({Ns, _}) ->
    fun() ->
        Rule = {':-', {blocked, {'X'}},
                       {fail_with_reason, {impossible_to_link, {'X'}}}},
        ok = ab(Ns, 1, with_host_policy(
                         Ns, batch(change(Ns, diff_for(Rule), #{})))),
        ?assertEqual(
           {fail, [{blocked, bob}, {impossible_to_link, bob}]},
           quod_prolog:prove(Ns, {blocked, bob})),
        {ok, Est, 1} = quod_prolog:attach_runtime(Ns),
        ?assertEqual(fail, quod_prolog:prove_est({blocked, bob}, Est)),
        quod_prolog:runtime_detach(Ns)
    end.

t_apply_and_read({Ns, _}) ->
    fun() ->
        ok = ab(Ns, 1, with_host_policy(
                         Ns,
                         batch(change(Ns, diff_for({parent, tom, bob}), #{})))),
        %% a bound read returns the binding and the height read
        ?assertMatch({ok, [#{'X' := bob}], 1}, quod_prolog:prove(Ns, {parent, tom, {'X'}})),
        %% a ground read succeeds with an empty binding set
        ?assertEqual({ok, [#{}], 1}, quod_prolog:prove(Ns, {parent, tom, bob})),
        %% a second committed block advances the applied height
        ok = ab(Ns, 2, batch(change(Ns, diff_for({parent, ann, eve}), #{}))),
        ?assertMatch({ok, [#{'P' := ann}], 2}, quod_prolog:prove(Ns, {parent, {'P'}, eve}))
    end.

t_user_principal_is_typed_and_server_owned({Ns, _}) ->
    fun() ->
        AllowedKey = <<42:256>>,
        User = {user, AllowedKey},
        OtherUser = {user, <<43:256>>},
        %% The founding host-entry clause admits only an empty chain. A user
        %% proof must take the non-host path and match this explicit policy;
        %% otherwise `prove_as/3` would silently grant every user host power.
        UserPolicy = {can_invoke, {user_visible, true}, User, {'Chain'}, Ns},
        ok = ab(Ns, 1, with_host_policy(
                         Ns,
                         batch(change(Ns, diff_for({user_visible, true}), #{})))),
        %% The injected host-entry policy grants only an empty chain. It still
        %% admits the engine's own top-level proof, but not a browser user.
        ?assertEqual(
           {ok, [#{}], 1},
           quod_prolog:prove(Ns, {user_visible, true})),
        ?assertMatch(
           {fail, _},
           quod_prolog:prove_as(Ns, {user_visible, true}, User)),
        ok = ab(Ns, 2, batch(change(Ns, diff_for(UserPolicy), #{}))),
        %% This trusted in-VM entry point is the bridge used by the typed
        %% client-command dispatcher; it is deliberately not an HTTP goal API.
        ?assertEqual(
           {ok, [#{}], 2},
           quod_prolog:prove_as(Ns, {user_visible, true}, User)),
        ?assertMatch(
           {fail, _},
           quod_prolog:prove_as(Ns, {user_visible, true}, OtherUser)),
        ?assertEqual(
           {error, invalid_user_principal},
           quod_prolog:prove_as(Ns, {user_visible, true}, anonymous))
    end.

t_occ_reject({Ns, _}) ->
    fun() ->
        ok = ab(Ns, 1, with_host_policy(
                         Ns,
                         batch(change(Ns, diff_for({parent, tom, bob}), #{})))),
        %% a change whose read-set carries a stale token for parent/2 → rejected at apply.
        %% apply_entry is an async cast (returns ok); the OCC reject is observed by its
        %% EFFECT — the block changes no facts (sibling/1 stays absent). The apply_entry cast
        %% is FIFO-ordered before the following prove call, so the effect is visible.
        Stale = change(Ns, diff_for({sibling, x}), #{{parent, 2} => never_present}),
        ok = ab(Ns, 2, batch(Stale)),
        ?assertMatch({fail, [_ | _]}, quod_prolog:prove(Ns, {sibling, x})),
        %% a non-stale read-set (parent/2 last mutated at height 1) commits fine
        Good = change(Ns, diff_for({sibling, y}), #{{parent, 2} => {present, 1}}),
        ?assertEqual(ok, ab(Ns, 3, batch(Good))),
        ?assertEqual({ok, [#{}], 3}, quod_prolog:prove(Ns, {sibling, y}))
    end.

t_policy_self_seal({Ns, _}) ->
    fun() ->
        Host = host_policy_tx(Ns),
        [{assert, HostClause}] = Host#transaction.diff,
        ok = ab(Ns, 1, {batch, [Host]}),

        %% Live removal of the last policy is a typed rejection. The exact
        %% reason is retained for outcome polling and for a parked local or
        %% cross-ontology proof caller.
        Removal = change(Ns, [{retract, HostClause}], #{}),
        ok = ae(Ns, 2, batch(Removal), live),
        ?assertEqual(
           {ok, #{status => rejected,
                  reason => policy_self_seal_forbidden,
                  height => 2,
                  ref => outcome_ref(Ns, Removal)}},
           quod_prolog:outcome(outcome_ref(Ns, Removal))),
        ?assertMatch({fail, [_ | _]}, quod_prolog:prove(Ns, missing_after_reject)),

        %% One transaction may atomically replace the last clause because the
        %% invariant observes the final candidate rather than operation order.
        NewPolicy = {can_invoke, {'Goal'}, {'Principal'}, {'Chain'}, {'Namespace'}},
        [NewAssert] = diff_for(NewPolicy),
        Replacement = change(
                        Ns, [{retract, HostClause}, NewAssert], #{}),
        ok = ae(Ns, 3, batch(Replacement), live),
        ?assertMatch(
           {ok, #{status := committed, height := 3}},
           quod_prolog:outcome(outcome_ref(Ns, Replacement))),

        %% Catch-up/replay uses the same apply path and returns the same exact
        %% rejection while preserving the replacement policy.
        {assert, NewClause} = NewAssert,
        ReplayRemoval = change(Ns, [{retract, NewClause}], #{}),
        ok = ae(Ns, 4, batch(ReplayRemoval), replay),
        ?assertMatch(
           {ok, #{status := rejected,
                  reason := policy_self_seal_forbidden,
                  height := 4}},
           quod_prolog:outcome(outcome_ref(Ns, ReplayRemoval))),
        ?assertMatch({fail, [_ | _]}, quod_prolog:prove(Ns, missing_after_replay))
    end.

outcome_ref(Ns, #transaction{tx_id = Tx}) ->
    {transaction, Ns, <<0:256>>, Tx}.

t_batch_apply({Ns, _}) ->
    fun() ->
        Parent = change(Ns, diff_for({parent, tom, bob}), #{}),
        Child = change(Ns, diff_for({child, bob}), #{}),
        ok = ab(Ns, 1, with_host_policy(Ns, {batch, [Parent, Child]})),
        ?assertEqual({ok, [#{}], 1}, quod_prolog:prove(Ns, {parent, tom, bob})),
        ?assertEqual({ok, [#{}], 1}, quod_prolog:prove(Ns, {child, bob})),
        Stats = quod_prolog:stats(Ns),
        ?assertEqual(1, maps:get(applied, Stats)),
        ?assertEqual(3, maps:get(applies, Stats)),
        %% An improper batch is rejected as a whole: no prefix transaction can leak into the KB.
        Partial = change(Ns, diff_for({must_not_apply, x}), #{}),
        ok = ab(Ns, 2, {batch, [Partial | bad_tail]}),
        ?assertMatch({fail, [_ | _]},
                     quod_prolog:prove(Ns, {must_not_apply, x})),
        Stats2 = quod_prolog:stats(Ns),
        ?assertEqual(2, maps:get(applied, Stats2)),
        ?assertEqual(3, maps:get(applies, Stats2))
    end.

%% Recommitting the same sealed semantic plan at a later slot advances the
%% ledger cursor but must not execute its diff or emit a second apply outcome.
t_duplicate_plan_applies_once({Ns, _}) ->
    fun() ->
        Change = change(Ns, diff_for({once_only, true}), #{}),
        ok = ab(Ns, 1, with_host_policy(Ns, batch(Change))),
        ok = ab(Ns, 2, batch(Change#transaction{author_seq = 2,
                                                submitted_at = 2})),
        ?assertEqual({ok, [#{}], 2},
                     quod_prolog:prove(Ns, {once_only, true})),
        Stats = quod_prolog:stats(Ns),
        ?assertEqual(2, maps:get(applied, Stats)),
        ?assertEqual(2, maps:get(applies, Stats)),
        Ref = {transaction, Ns, <<0:256>>, Change#transaction.tx_id},
        ?assertMatch({ok, #{status := committed, height := 1}},
                     quod_prolog:outcome(Ref))
    end.

%% A transaction whose read set names a functor written EARLIER in the same
%% block hits the `staged` token at its exact block position and is rejected
%% deterministically; the writer, a blind later write, and a transaction that
%% reads what it writes itself all apply normally.
t_same_block_read_after_write({Ns, _}) ->
    fun() ->
        ok = ab(Ns, 1, with_host_policy(
                         Ns,
                         batch(change(Ns, diff_for({parent, tom, bob}), #{})))),
        W = change(Ns, diff_for({k, one}), #{}),
        %% honest capture against height 1 — stale only because W precedes it
        Raw = change(Ns, diff_for({dependent, x}), #{{k, 1} => never_present}),
        Blind = change(Ns, diff_for({independent, y}), #{}),
        %% self read-modify-write: reads parent/2 at its committed height and
        %% rewrites it — its own writes stage after its validation
        Self = change(Ns, diff_for({parent, tom, sue}),
                      #{{parent, 2} => {present, 1}}),
        ok = ab(Ns, 2, {batch, [W, Raw, Blind, Self]}),
        ?assertEqual({ok, [#{}], 2}, quod_prolog:prove(Ns, {k, one})),
        ?assertMatch({fail, [_ | _]}, quod_prolog:prove(Ns, {dependent, x})),
        ?assertEqual({ok, [#{}], 2}, quod_prolog:prove(Ns, {independent, y})),
        ?assertEqual({ok, [#{}], 2}, quod_prolog:prove(Ns, {parent, tom, sue}))
    end.

t_worker_limit({Ns, _}) ->
    fun() ->
        Rule = {':-', loop, loop},
        ok = ab(Ns, 1, with_host_policy(
                         Ns, batch(change(Ns, diff_for(Rule), #{})))),
        Caller = spawn(fun() -> quod_prolog:prove(Ns, loop) end),
        ?assertEqual(ok, wait_proof_workers(Ns, 1, 100)),
        ?assertEqual({error, busy}, quod_prolog:prove(Ns, {anything, x})),
        exit(Caller, kill),
        ?assertEqual(ok, wait_proof_workers(Ns, 0, 100))
    end.

wait_proof_workers(_Ns, _Expected, 0) -> timeout;
wait_proof_workers(Ns, Expected, Retries) ->
    case maps:get(proof_workers, quod_prolog:stats(Ns), undefined) of
        Expected -> ok;
        _ -> timer:sleep(10), wait_proof_workers(Ns, Expected, Retries - 1)
    end.

wait_proof_waiters(_Ns, _Expected, 0) -> timeout;
wait_proof_waiters(Ns, Expected, Retries) ->
    case maps:get(proof_waiters, quod_prolog:stats(Ns), undefined) of
        Expected -> ok;
        _ -> timer:sleep(10), wait_proof_waiters(Ns, Expected, Retries - 1)
    end.

%%%===================================================================
%%% Slice B — membership verdict + lockstep
%%%===================================================================

%% helpers
mem_assert(Ns, Pk, H, P)  -> change(Ns, [{assert,  {{peer_admitted, Pk, H, P, Pk}, true}}], #{}).
mem_retract(Ns, Pk, H, P) -> change(Ns, [{retract, {{peer_admitted, Pk, H, P, Pk}, true}}], #{}).
canjoin_open(Ns)          -> change(Ns, diff_for({can_join, {'A'}, {'B'}, {'C'}}), #{}).

recv_verdict(Tag) -> receive {membership_verdict, Tag, V} -> V after 2000 -> timeout end.
no_verdict(Tag)   -> receive {membership_verdict, Tag, V} -> {unexpected, V} after 150 -> ok end.

%% ask + receive (used when applied == Slot-1, so the verdict is delivered immediately)
verdict(Ns, Change, Slot, Tag) ->
    ok = quod_prolog:request_membership_verdict(Ns, Change, Slot, self(), Tag),
    recv_verdict(Tag).

%% assert/dup/retract-present/retract-absent, judged against the parent-height kb.
t_verdict_basic({Ns, _}) ->
    fun() ->
        PkA = <<"pkA">>, PkB = <<"pkB">>,
        ok = ab(Ns, 1, batch(canjoin_open(Ns))),               %% default-open can_join
        ok = ab(Ns, 2, batch(mem_assert(Ns, PkA, "ha", 1))),   %% founder (lockstep applies it)
        %% applied == 2, so a verdict for Slot 3 (parent 2) is answered now
        ?assertEqual(valid, verdict(Ns, mem_assert(Ns, PkB, "hb", 2), 3, v1)),          %% new member
        ?assertEqual({invalid, already_admitted},
                     verdict(Ns, mem_assert(Ns, PkA, "ha", 1), 3, v2)),                 %% pubkey already admitted
        ?assertEqual(valid, verdict(Ns, mem_retract(Ns, PkA, "ha", 1), 3, v3)),         %% exact clause present
        ?assertEqual({invalid, no_such_member},
                     verdict(Ns, mem_retract(Ns, PkA, "WRONG", 9), 3, v4))              %% fabricated address
    end.

%% a narrowed can_join (only PkAllowed) rejects everyone else.
t_verdict_can_join_fail({Ns, _}) ->
    fun() ->
        PkAllowed = <<"pkAllowed">>, PkOther = <<"pkOther">>,
        ok = ab(Ns, 1, batch(change(Ns, diff_for({can_join, {'A'}, {'B'}, PkAllowed}), #{}))),
        ?assertEqual({invalid, can_join}, verdict(Ns, mem_assert(Ns, PkOther, "h", 1), 2, cf)),
        ?assertEqual(valid, verdict(Ns, mem_assert(Ns, PkAllowed, "h", 1), 2, cok))
    end.

%% a can_join that STAGES A WRITE is rejected (it must be side-effect-free).
t_verdict_side_effects({Ns, _}) ->
    fun() ->
        PkB = <<"pkB">>,
        Rule = {':-', {can_join, {'A'}, {'B'}, {'C'}}, {assertz, {sidelog, ok}}},
        ok = ab(Ns, 1, batch(change(Ns, diff_for(Rule), #{}))),
        ?assertEqual({invalid, can_join_side_effects}, verdict(Ns, mem_assert(Ns, PkB, "h", 1), 2, se))
    end.

%% park-until-parent-height (even when the parent lands on a noop), abstain-when-late, TTL reap.
t_verdict_lifecycle({Ns, _}) ->
    fun() ->
        PkB = <<"pkB">>,
        ok = ab(Ns, 1, batch(canjoin_open(Ns))),   %% applied == 1
        %% a verdict for Slot 3 (parent 2 > applied 1) parks — nothing delivered yet
        ok = quod_prolog:request_membership_verdict(Ns, mem_assert(Ns, PkB, "h", 1), 3, self(), park),
        ?assertEqual(ok, no_verdict(park)),
        %% advancing to height 2 via a NOOP still resolves it (shared tail across every apply path)
        ok = ab(Ns, 2, noop),
        ?assertEqual(valid, recv_verdict(park)),
        %% applied == 2: a verdict for Slot 2 (parent 1, already passed) abstains
        ?assertEqual(abstain, verdict(Ns, mem_assert(Ns, PkB, "h", 1), 2, late)),
        %% a verdict whose parent never arrives is reaped to abstain after the TTL (validation_ttl_ms=500)
        ok = quod_prolog:request_membership_verdict(Ns, mem_assert(Ns, PkB, "h", 1), 9, self(), ttl),
        ?assertEqual(abstain, recv_verdict(ttl))
    end.

%% Re-issuing a Tag still parked supersedes the old request: its timer is cancelled so it can't reap the
%% new one to a premature abstain, and the new request resolves at ITS own parent height — exactly once.
t_verdict_tag_reuse({Ns, _}) ->
    fun() ->
        PkB = <<"pkB">>,
        ok = ab(Ns, 1, batch(canjoin_open(Ns))),   %% applied == 1
        %% park Tag `t` for a far slot (parent 8, never reached)
        ok = quod_prolog:request_membership_verdict(Ns, mem_assert(Ns, PkB, "h", 1), 9, self(), t),
        %% re-issue the SAME Tag for a near slot (parent 2) — supersedes the far one + cancels its timer
        ok = quod_prolog:request_membership_verdict(Ns, mem_assert(Ns, PkB, "h", 1), 3, self(), t),
        ?assertEqual(ok, no_verdict(t)),                         %% neither has delivered yet
        ok = ab(Ns, 2, noop),               %% reach parent 2 → the NEW request resolves
        ?assertEqual(valid, recv_verdict(t)),
        %% the superseded far-slot timer was cancelled, so no stray abstain follows
        ?assertEqual(ok, no_verdict(t))
    end.

dtx_validation_waits_for_published_outcome_floor_test() ->
    Ns = <<"validation-floor">>,
    Anchor = <<71:256>>,
    {ok, Outcomes0} = quod_outcome:open(
                        Ns, Anchor, #{outcome_backend => memory}),
    {ok, OutcomesStaged} = quod_outcome:advance_applied(Outcomes0, 1),
    %% The KB has reached the proposal parent, but the outcome floor is only
    %% staged.  The DTX request must remain parked; the old applied-only scan
    %% would consume this deliberately malformed request immediately.
    ?assert(quod_prolog:test_resolve_validation(
              {dtx, malformed}, 2, 1, OutcomesStaged)),
    {ok, OutcomesPublished} = quod_outcome:flush(OutcomesStaged),
    ?assertNot(quod_prolog:test_resolve_validation(
                 {dtx, malformed}, 2, 1, OutcomesPublished)),
    ok = quod_outcome:close(OutcomesPublished).

%% a committed membership tx applies UNCONDITIONALLY (skip OCC) — its projections stay in lockstep —
%% while a content tx with an equally-stale read_check is still OCC-rejected (the skip is scoped).
t_lockstep({Ns, _}) ->
    fun() ->
        PkB = <<"pkB">>,
        ok = ab(Ns, 1, batch(canjoin_open(Ns))),
        %% membership assert with a DELIBERATELY STALE read_check → still applies
        StaleMem = #{{peer_admitted, 4} => 999999},
        MemTx0 = (mem_assert(Ns, PkB, "h", 1))#transaction{
                   read_check = StaleMem},
        MemTx = quod_transaction:bind_id({Ns, <<0:256>>}, MemTx0),
        ok = ab(Ns, 2, batch(MemTx)),
        %% the fact WAS applied (despite the stale read_check): PkB is now an admitted pubkey, so a fresh
        %% admit of it is rejected as already_admitted — this reads the committee via the same
        %% get_procedure path production uses (a direct prove of peer_admitted is a separate erlog quirk).
        ?assertEqual({invalid, already_admitted}, verdict(Ns, mem_assert(Ns, PkB, "h", 1), 3, lk)),
        %% content tx with an equally-stale read_check → still rejected (widget/z never asserted)
        StaleContent = change(Ns, diff_for({widget, z}), #{{widget, 1} => 12345}),
        ok = ab(Ns, 3, batch(StaleContent)),
        ?assertMatch({fail, [_ | _]}, quod_prolog:prove(Ns, {widget, z}))
    end.

%% A cast that does NOT advance the height — an already-applied no-op (Index =< applied) or a forward
%% gap (Index > applied+1, which bails to rebuild) — must NOT emit a replay boundary, even while the
%% engine is {replaying}. Regression for the note_origin ordering fix (boundaries gate on real advance).
t_no_boundary_without_advance({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        ok = ae(
               Ns, 1,
               with_host_policy(
                 Ns, batch(change(Ns, diff_for({a, 1}), #{}))),
               replay),
        {replay_started, Id, 0} = recv_rt(replay_started),
        %% already-applied live cast (Index 1 =< applied 1): no close, no event
        ok = ae(Ns, 1, batch(change(Ns, diff_for({a, 1}), #{})), live),
        _ = quod_prolog:applied(Ns),        %% sync barrier: the cast above has been processed
        ok = refute_rt(replay_ready),
        ok = refute_rt(applied_live),
        %% forward-gap live cast (Index 5 > applied 1 + 1): no close either
        ok = ae(Ns, 5, batch(change(Ns, diff_for({b, 5}), #{})), live),
        _ = quod_prolog:applied(Ns),
        ok = refute_rt(replay_ready),
        %% only a genuine advancing live apply closes the run (ready at the height replay reached)
        ok = ae(Ns, 2, batch(change(Ns, diff_for({c, 2}), #{})), live),
        ?assertMatch({replay_ready, Id, 1}, recv_rt(replay_ready))
    end.

%% receive the next {runtime, Ns} message tagged Tag (selective — skips other tags), or fail.
recv_rt(Tag) ->
    receive M when element(1, M) =:= Tag -> M
    after 1000 -> erlang:error({no_runtime_msg, Tag}) end.

%% assert NO message tagged Tag arrives within a short window.
refute_rt(Tag) ->
    receive M when element(1, M) =:= Tag -> erlang:error({unexpected_runtime_msg, M})
    after 200 -> ok end.

%% (c) a LIVE commit publishes exactly one applied_live envelope at its height, carrying the diff and
%% tx id, and the committed fact is readable at that height (the event observes committed facts).
t_live_emits_event({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        Diff = diff_for({parent, tom, bob}),
        Tx = change(Ns, Diff, #{}),
        ok = ae(
               Ns, 1, with_host_policy(Ns, batch(Tx)), live),
        {applied_live, Env} = recv_rt(applied_live),
        ?assertEqual(1, maps:get(height, Env)),
        ?assertEqual(Diff, maps:get(diff, Env)),
        ?assertEqual(Tx#transaction.tx_id, maps:get(tx_id, Env)),
        ?assertMatch({ok, [_], 1}, quod_prolog:prove(Ns, {parent, tom, {'X'}}))
    end.

%% (c2) a committed-but-OCC-rejected LIVE tx publishes exactly one rejected_live envelope at its height
%% (tx id + goal, no diff — D is unchanged), and NO applied_live. So an observer sees the outcome of every
%% committed tx without inferring it from a later commit.
t_live_reject_emits_event({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        ok = ae(
               Ns, 1,
               with_host_policy(
                 Ns, batch(change(Ns, diff_for({parent, tom, bob}), #{}))),
               live),
        ?assertMatch({applied_live, _}, recv_rt(applied_live)),
        %% a stale read-set token for parent/2 → rejected at apply
        Stale = change(Ns, diff_for({sibling, x}), #{{parent, 2} => never_present}),
        ok = ae(Ns, 2, batch(Stale), live),
        {rejected_live, Env} = recv_rt(rejected_live),
        ?assertEqual(2, maps:get(height, Env)),
        ?assertEqual(Stale#transaction.tx_id, maps:get(tx_id, Env)),
        ?assertNot(maps:is_key(diff, Env)),
        ok = refute_rt(applied_live),
        %% and the rejected diff did not touch D
        ?assertMatch({fail, [_ | _]}, quod_prolog:prove(Ns, {sibling, x}))
    end.

%% (b) a REPLAY apply rebuilds D (fact readable) but publishes NO applied_live event — only the
%% replay_started boundary, carrying the height replay opened from.
t_replay_no_event({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        Tx = change(Ns, diff_for({parent, tom, bob}), #{}),
        ok = ae(
               Ns, 1, with_host_policy(Ns, batch(Tx)), replay),
        ?assertMatch({replay_started, _Id, 0}, recv_rt(replay_started)),
        ok = refute_rt(applied_live),
        ?assertMatch({ok, [_], 1}, quod_prolog:prove(Ns, {parent, tom, {'X'}}))
    end.

%% (d) live -> replaying -> live -> replaying, without restarting quod_prolog: a replay run opens
%% (started), the resuming live apply closes the SAME run (ready, correlating Id) and fires its event,
%% and a second replay run mints a DISTINCT Id — so a consumer can ignore a stale boundary.
t_replay_reentry({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        ok = ae(
               Ns, 1,
               with_host_policy(
                 Ns, batch(change(Ns, diff_for({a, 1}), #{}))),
               live),
        ?assertMatch({applied_live, _}, recv_rt(applied_live)),
        %% gap-fill: replay at 2 opens a run from height 1; it is silent
        ok = ae(Ns, 2, batch(change(Ns, diff_for({b, 2}), #{})), replay),
        {replay_started, Id, 1} = recv_rt(replay_started),
        ok = refute_rt(applied_live),
        %% the resuming live apply at 3 closes the run (same Id, ready height 2), then fires the event
        ok = ae(Ns, 3, batch(change(Ns, diff_for({c, 3}), #{})), live),
        ?assertMatch({replay_ready, Id, 2}, recv_rt(replay_ready)),
        ?assertMatch({applied_live, #{height := 3}}, recv_rt(applied_live)),
        %% a second replay run mints a DISTINCT Id (stale-boundary immunity)
        ok = ae(Ns, 4, batch(change(Ns, diff_for({d, 4}), #{})), replay),
        {replay_started, Id2, 3} = recv_rt(replay_started),
        ?assertNotEqual(Id, Id2)
    end.

%%%===================================================================
%%% Slice 2 increment 1: the runtime attach seam (plan resilient-frolicking-valley) —
%%% post-commit direct envelopes with the snapshot handle, the MVCC floor pin, and the
%%% quiet-boot ready edge.
%%%===================================================================

runtime_attach_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun t_attach_refused_until_ready/1,
      fun t_direct_envelope_carries_committed_snapshot/1,
      fun t_reject_not_direct_sent/1,
      fun t_floor_pins_and_raises/1,
      fun t_runtime_down_clears_floor/1,
      fun t_quiet_boot_ready_edge_once/1]}.

%% attach is refused until the KB is ready (a pin must never span a rebuild); after the ready
%% edge it returns the committed snapshot handle and height.
t_attach_refused_until_ready({_Ns, _}) ->
    fun() ->
        Fresh = <<"attach:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
        {ok, Pid} = quod_prolog:start_link(
                      Fresh, #{node_id => {"127.0.0.1", 5000},
                               outcome_backend => memory}),
        ?assertEqual({error, not_ready}, quod_prolog:attach_runtime(Fresh)),
        ok = quod_prolog:mark_ready(Fresh),
        ?assertMatch({ok, _Est, 0}, quod_prolog:attach_runtime(Fresh)),
        gen_server:stop(Pid)
    end.

%% the attached runtime receives {applied_live, Env, Est} directly, post-commit: the fact is
%% provable THROUGH the carried snapshot handle. The shared property stays est-free.
t_direct_envelope_carries_committed_snapshot({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        ?assertMatch({ok, _, 0}, quod_prolog:attach_runtime(Ns)),
        ok = ab(Ns, 1, batch(change(Ns, diff_for({parent, tom, bob}), #{}))),
        {Env, Est} = receive {applied_live, E, S} -> {E, S}
                     after 1000 -> erlang:error(no_direct_envelope) end,
        ?assertEqual(1, maps:get(height, Env)),
        ?assertMatch({ok, _, _, _}, quod_prolog:prove_est({parent, tom, bob}, Est)),
        %% the property copy is the SAME envelope without the handle
        PropEnv = receive {applied_live, E2} -> E2
                  after 1000 -> erlang:error(no_property_envelope) end,
        ?assertEqual(Env, PropEnv)
    end.

%% an OCC-rejected committed tx announces rejected_live on the property but never a direct
%% envelope — D did not change, so the runtime has nothing to converge.
t_reject_not_direct_sent({Ns, _}) ->
    fun() ->
        true = quod_reg:subscribe({runtime, Ns}),
        ?assertMatch({ok, _, 0}, quod_prolog:attach_runtime(Ns)),
        ok = ab(Ns, 1, batch(change(Ns, diff_for({widget, z}), #{{widget, 1} => 12345}))),
        ?assertMatch({rejected_live, _}, recv_rt(rejected_live)),
        receive {applied_live, _, _} = M -> erlang:error({unexpected_direct, M})
        after 200 -> ok end
    end.

%% the pin holds MVCC history at its floor (history grows while pinned low), and a floor
%% raise lets the next commit prune it.
t_floor_pins_and_raises({Ns, _}) ->
    fun() ->
        ?assertMatch({ok, _, 0}, quod_prolog:attach_runtime(Ns)),
        [ok = ab(Ns, N, batch(change(Ns, diff_for({counter, N}), #{})))
         || N <- [1, 2, 3]],
        H1 = hist(Ns),
        ?assert(H1 > 0),
        %% raise the floor past every retained version: the next commit prunes in full
        %% (kb_history_predicates counts PREDICATES with history, so only a full release
        %% moves it — the partial-floor keep-newest-version case is mvcc-internal)
        ok = quod_prolog:runtime_floor(Ns, 4),
        ok = ab(Ns, 4, batch(change(Ns, diff_for({counter, 4}), #{}))),
        ?assertEqual(0, hist(Ns))
    end.

%% a dead runtime cannot wedge pruning: its DOWN clears the pin and the next commit prunes.
t_runtime_down_clears_floor({Ns, _}) ->
    fun() ->
        Parent = self(),
        Rt = spawn(fun() ->
                       Parent ! {attached, quod_prolog:attach_runtime(Ns)},
                       receive stop -> ok end
                   end),
        receive {attached, {ok, _, 0}} -> ok
        after 1000 -> erlang:error(attach_failed) end,
        [ok = ab(Ns, N, batch(change(Ns, diff_for({counter, N}), #{})))
         || N <- [1, 2]],
        ?assert(hist(Ns) > 0),
        exit(Rt, kill),
        ok = wait_until(fun() ->
                            ok = ab_next(Ns, batch(change(Ns, diff_for({counter, 99}), #{}))),
                            hist(Ns) =:= 0
                        end, 20)
    end.

%% the quiet-boot ready edge fires exactly once, on the actual false->true transition.
t_quiet_boot_ready_edge_once({_Ns, _}) ->
    fun() ->
        Fresh = <<"bootedge:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
        {ok, Pid} = quod_prolog:start_link(
                      Fresh, #{node_id => {"127.0.0.1", 5000},
                               outcome_backend => memory}),
        true = quod_reg:subscribe({runtime, Fresh}),
        ok = quod_prolog:mark_ready(Fresh),
        receive {replay_ready, boot, 0} -> ok
        after 1000 -> erlang:error(no_boot_ready_edge) end,
        ok = quod_prolog:mark_ready(Fresh),
        _ = quod_prolog:applied(Fresh),   %% barrier: the second cast has been processed
        receive {replay_ready, _, _} = M2 -> erlang:error({spurious_ready_edge, M2})
        after 200 -> ok end,
        gen_server:stop(Pid)
    end.

hist(Ns) -> maps:get(kb_history_predicates, quod_prolog:stats(Ns), 0).

%% apply one more block at the next height (reads the current applied height first).
ab_next(Ns, Change) -> ab(Ns, quod_prolog:applied(Ns) + 1, Change).
