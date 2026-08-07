-module(quod_ask_tests).
-include_lib("eunit/include/eunit.hrl").

-define(WAIT_RETRIES, 200).

remote_route_errors_retry_only_before_execution_test() ->
    Target = <<"quod:route-errors">>,
    ?assertEqual(
       unavailable,
       quod_ask:test_remote_open_error(Target, link_binding_mismatch)),
    ?assertEqual(
       {retry, {ontology_busy, Target}},
       quod_ask:test_remote_open_error(
         Target, {ontology_busy, Target})),
    ?assertEqual(
       {retry, {not_allowed, Target}},
       quod_ask:test_remote_open_error(
         Target, {not_allowed, Target})),
    ?assertEqual(
       {retry, {scope_limit_exceeded, 16}},
       quod_ask:test_remote_open_error(
         Target, {scope_limit_exceeded, 16})),
    ?assertEqual(
       {fatal, {protocol_error, event_sequence}},
       quod_ask:test_remote_open_error(
         Target, {protocol_error, event_sequence})),
    ?assertEqual(
       {fatal, {scope_expired, Target}},
       quod_ask:test_remote_open_error(
         Target, {scope_expired, Target})),
    ?assertEqual(
       {fatal, {too_large, scope_envelope}},
       quod_ask:test_remote_open_error(
         Target, {too_large, scope_envelope})),
    ?assertEqual(
       {fatal, {protocol_error, proof_engine}},
       quod_ask:test_remote_open_error(
         Target, {protocol_error, not_in_the_wire_catalog})),
    ?assertEqual(
       {fatal, {anchor_conflict, Target}},
       quod_ask:test_remote_open_error(
         Target, {anchor_conflict, Target})),
    First = {ontology_rate_limited, Target},
    ?assertEqual(
       First, quod_ask:test_remember_route_error(none, First)),
    ?assertEqual(
       First,
       quod_ask:test_remember_route_error(
         First, {ontology_rebuilding, Target})).

direct_seed_confirmation_errors_are_public_and_typed_test() ->
    Target = <<"quod:seed-errors">>,
    ?assertEqual(
       unavailable,
       quod_ask:test_seed_confirmation_error(Target, unknown_seed)),
    lists:foreach(
      fun(Reason) ->
          ?assertEqual(
             {fatal, {protocol_error, identity_binding}},
             quod_ask:test_seed_confirmation_error(Target, Reason))
      end,
      [seed_identity_conflict, ambiguous_seed, bad_seed_identity]),
    ?assertEqual(
       {fatal, {protocol_error, proof_engine}},
       quod_ask:test_seed_confirmation_error(Target, unexpected_internal)).

pending_router_death_is_reported_at_each_opening_wait_test() ->
    Target = <<"quod:router-death">>,
    assert_pending_router_death(
      Target,
      fun(Router, Generation, OpenRef) ->
          quod_ask:test_await_identity(
            Target, Router, Generation, OpenRef)
      end),
    assert_pending_router_death(
      Target,
      fun(Router, Generation, OpenRef) ->
          quod_ask:test_await_remote_scope_open(
            Target, Router, Generation, OpenRef)
      end).

assert_pending_router_death(Target, WaitFun) ->
    Router = spawn(fun wait_for_router_test_stop/0),
    _ = quod_proof_context:start(
          crypto:strong_rand_bytes(32), false,
          {<<"quod:origin">>, crypto:strong_rand_bytes(32)},
          quod_time:mono_ms() + 60000),
    try
        spawn(fun() -> timer:sleep(5), exit(Router, kill) end),
        ?assertEqual(
           {error, {ontology_unreachable, Target}},
           WaitFun(Router, <<77:128>>, make_ref()))
    after
        quod_proof_context:stop(
          fun(_Scope) -> ok end, fun(_Proxy) -> ok end),
        exit(Router, kill)
    end.

wait_for_router_test_stop() ->
    receive stop -> ok end.

nested_source_binding_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Anchor = crypto:strong_rand_bytes(32),
    Parent = self(),
    Registered = spawn(fun() -> forward_messages(Parent) end),
    Stranger = spawn(fun() -> forward_messages(Parent) end),
    InvocationId = invocation_id(1),
    Selection = empty_selection(),
    OriginIdentity = {<<"quod:nested-source-origin">>,
                      crypto:strong_rand_bytes(32)},
    _Context = quod_proof_context:start(
                 ProofId, false, OriginIdentity,
                 quod_time:mono_ms() + 60000),
    try
        {ok, ScopeId, registered_scope} =
            quod_proof_context:get_or_open_scope(
              {<<"quod:nested-source-test">>, Anchor},
              fun(_ScopeId) ->
                  {ok, Registered, registered_scope}
              end),
        ok = quod_proof_context:register_invocation(
               {ScopeId, InvocationId}, Selection),
        WrongProof = crypto:strong_rand_bytes(32),
        WrongRef = make_ref(),
        ok = quod_ask:test_serve_nested(
               {proof_nested_open, WrongProof, Registered, WrongRef,
                {ScopeId, InvocationId}, Selection,
                <<"quod:any">>, true, [<<"quod:caller">>]}),
        ?assertEqual(
           {proof_nested_reply, WrongProof, WrongRef, {error, not_allowed}},
           receive_forwarded(Registered)),
        StrangerRef = make_ref(),
        ok = quod_ask:test_serve_nested(
               {proof_nested_open, ProofId, Stranger, StrangerRef,
                {ScopeId, InvocationId}, Selection,
                <<"quod:any">>, true, [<<"quod:caller">>]}),
        ?assertEqual(
           {proof_nested_reply, ProofId, StrangerRef, {error, not_allowed}},
           receive_forwarded(Stranger))
    after
        quod_proof_context:stop(fun(_Scope) -> ok end,
                                fun(_Proxy) -> ok end),
        exit(Registered, kill),
        exit(Stranger, kill)
    end.

ask_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Ctx) ->
         [?_test(t_single_answer(Ctx)),
          ?_test(t_backtracking_all_answers(Ctx)),
          ?_test(t_default_link_following(Ctx)),
          ?_test(t_multi_position_follow_dedup(Ctx)),
          ?_test(t_repeated_follow_queries_are_independent(Ctx)),
          ?_test(t_cut_follow_dedup_does_not_cross_invocations(Ctx)),
          ?_test(t_grounded_ask(Ctx)),
          ?_test(t_self_ask(Ctx)),
          ?_test(t_raw_snapshot_selector_boundary(Ctx)),
          ?_test(t_loud_routing_errors(Ctx)),
          ?_test(t_recursive_selection(Ctx)),
          ?_test(t_three_scope_chain(Ctx)),
          ?_test(t_failed_foreign_branch_retains_state(Ctx)),
          ?_test(t_transaction_restores_foreign_branch_before_alternative(Ctx)),
          ?_test(t_origin_transaction_is_inherited_by_selected_branch(Ctx)),
          ?_test(t_selected_scope_transaction_restores_descendant(Ctx)),
          ?_test(t_selected_transaction_survives_reentrant_callback(Ctx)),
          ?_test(t_failed_transaction_restores_all_selected_scopes(Ctx)),
          ?_test(t_unrelated_reentrant_invocation_has_no_transaction_lineage(Ctx)),
          ?_test(t_reentrant_scope_reuse(Ctx)),
          ?_test(t_origin_scope_reentry_commits_write(Ctx)),
          ?_test(t_nested_failure_reasons(Ctx)),
          ?_test(t_nested_refusal_fails_logically(Ctx)),
          ?_test(t_read_only_tree_rejects_first_write(Ctx)),
          ?_test(t_scope_session_binding(Ctx)),
          ?_test(t_stateless_scope_error_keeps_published_revision(Ctx)),
          ?_test(t_scope_owner_death_reaps_session(Ctx)),
          ?_test(t_scope_worker_crash_is_protocol_error(Ctx)),
          ?_test(t_permission_gate(Ctx)),
          ?_test(t_failure_reasons_cross_local_ask(Ctx)),
          ?_test(t_foreign_write_rejected(Ctx)),
          ?_test(t_scope_engine_stays_responsive(Ctx)),
          ?_test(t_target_crash_kills_scope(Ctx)),
          ?_test(t_scope_worker_limit(Ctx)),
          ?_test(t_frozen_scope_view(Ctx)),
          ?_test(t_workers_are_reaped(Ctx))]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    {Pub, Seed} = quod_identity:generate(),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, quod_identity:key_term({Pub, Seed})),
    {ok, Router} = quod_ask_router:start_link(),
    Dir = filename:join("/tmp", "quod_ask_" ++
                       integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
    PrivateFile = write_ontology(Dir, "private.pl",
        "can_invoke(secret(_), _Principal, _Chain, _Ns).\n"
        "can_invoke(blocked(_), _Principal, _Chain, _Ns).\n"
        "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
        "blocked(X) :- fail_with_reason(impossible_to_link(X)).\n"
        "secret(42).\n"
        "hidden(denied).\n"),
    SlowFile = write_ontology(Dir, "slow.pl",
        "can_invoke(_Goal, _Principal, _Chain, _Ns).\n"
        "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
        "loop :- loop.\n"
        "ping(ok).\n"),
    ChainBFile = write_ontology(Dir, "chain_b.pl",
        "can_invoke(_Goal, _Principal, _Chain, _Ns).\n"
        "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
        "via_c(X) :- chain_c::leaf(X).\n"
        "stage_and_fail :- assertz(shared_mark), fail.\n"
        "shared_mark_visible :- shared_mark.\n"
        "via_c_back(X) :- assertz(reentry_mark), chain_c::back_to_b(X).\n"
        "reentry_visible(ok) :- reentry_mark.\n"
        "via_origin_write :- pets::assertz(origin_callback_write).\n"
        "via_c_failure :- chain_c::blocked.\n"
        %% a nested `::` into an ontology whose policy refuses the (non-empty)
        %% chain: the refusal must fail logically, not crash the serve path
        "via_private_denied :- private::hidden(x).\n"
        "via_private_denied_recovers :- "
        "(private::hidden(x) ; private::secret(_)).\n"
        "tx_second :- \\+ tx_hidden, assertz(tx_kept).\n"
        "origin_tx_branch :- ((assertz(origin_tx_hidden), fail) ; "
        "\\+ origin_tx_hidden).\n"
        "tx_via_c :- transaction(((chain_c::assertz(c_tx_hidden), fail) ; "
        "chain_c::c_tx_second)).\n"
        "tx_reentry_via_c :- transaction(chain_c::tx_back_to_b).\n"
        "tx_reentry_callback :- ((assertz(tx_reentry_hidden), fail) ; "
        "\\+ tx_reentry_hidden).\n"
        "tx_waits_in_c :- transaction(chain_c::leaf(ok)).\n"),
    ChainCFile = write_ontology(Dir, "chain_c.pl",
        "can_invoke(_Goal, _Principal, _Chain, _Ns).\n"
        "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
        "leaf(ok).\n"
        "back_to_b(X) :- chain_b::reentry_visible(X).\n"
        "blocked :- fail_with_reason(c_blocked).\n"
        "c_tx_second :- \\+ c_tx_hidden, assertz(c_tx_kept).\n"
        "tx_back_to_b :- chain_b::tx_reentry_callback.\n"),
    Namespaces = [
        start_ns(<<"animals">>, <<"ontologies/animals.pl">>, Dir),
        start_ns(<<"pets">>, <<"ontologies/pets.pl">>, Dir),
        start_ns(<<"private">>, list_to_binary(PrivateFile), Dir),
        start_ns(<<"slow">>, list_to_binary(SlowFile), Dir),
        start_ns(<<"chain_b">>, list_to_binary(ChainBFile), Dir),
        start_ns(<<"chain_c">>, list_to_binary(ChainCFile), Dir)
    ],
    [A, P, Private, Slow, ChainB, ChainC] = Namespaces,
    _ = prove_ready(A, {isa, dog, mammal}),
    _ = prove_ready(P, {instance_of, pet, my_dog}),
    _ = prove_ready(Private, {secret, 42}),
    _ = prove_ready(Slow, {ping, ok}),
    #{dir => Dir, router => Router, namespaces => Namespaces, animals => A, pets => P,
      private => Private, slow => Slow, chain_b => ChainB, chain_c => ChainC}.

cleanup(#{dir := Dir, router := Router, namespaces := Namespaces}) ->
    lists:foreach(fun stop_ns/1, Namespaces),
    _ = catch gen_server:stop(Router),
    application:unset_env(quod, node_pubkey),
    application:unset_env(quod, identity_key),
    _ = file:del_dir_r(Dir),
    ok.

t_single_answer(#{pets := P}) ->
    ?assertMatch({ok, [#{'D' := fish}], _},
                 prove(P, {'::', animals, {diet, cat, {'D'}}})).

t_backtracking_all_answers(#{pets := P}) ->
    ?assertMatch({ok, [#{'L' := [kibble, meat]}], _},
                 prove(P, {findall, {'D'},
                           {'::', animals, {diet, dog, {'D'}}}, {'L'}})).

t_default_link_following(#{animals := A}) ->
    ?assertMatch({ok, [#{'D' := kibble}], _},
                 prove(A, {diet, {':', animals, dog}, {'D'}})),
    ?assertMatch({ok, [#{'L' := [kibble, meat]}], _},
                 prove(A, {findall, {'D'},
                           {diet, {':', animals, dog}, {'D'}}, {'L'}})).

t_multi_position_follow_dedup(#{animals := A, pets := P}) ->
    Goal = {isa, {':', animals, dog}, {':', animals, mammal}},
    ?assertMatch({ok, [#{'L' := [ok]}], _},
                 prove(P, {findall, ok, Goal, {'L'}})),
    %% On the owning ontology the stripped self-call has its own nearer clause
    %% choice point. Dedup must still attach to the outer linked relation.
    ?assertMatch({ok, [#{'L' := [ok]}], _},
                 prove(A, {findall, ok, Goal, {'L'}})).

t_repeated_follow_queries_are_independent(#{pets := P}) ->
    First = {findall, {'D1'}, {diet, {':', animals, dog}, {'D1'}}, {'L1'}},
    Second = {findall, {'D2'}, {diet, {':', animals, dog}, {'D2'}}, {'L2'}},
    ?assertMatch({ok, [#{'L1' := [kibble, meat],
                         'L2' := [kibble, meat]}], _},
                 prove(P, {',', First, Second})).

%% Keep the first invocation and its cut continuation alive while the same
%% scope worker runs an identical second invocation. The former process-owned
%% map used the recycled Erlog clause label and suppressed the second answer;
%% choice-point ownership keeps both live invocations isolated.
t_cut_follow_dedup_does_not_cross_invocations(
  #{animals := A, pets := P}) ->
    {ok, Handle} = open_test_scope(A, false, 10),
    Follow = {once, {diet, {':', animals, dog}, kibble}},
    Chain = [{P, quod_simplex:genesis_hash(P)}],
    First = invocation_id(10),
    Second = invocation_id(11),
    try
        {ok, FirstOpen} = quod_scope_session:invoke_open(
                            Handle, First, Follow, Chain,
                            empty_selection()),
        assert_scope_reply(Handle, FirstOpen, {opened, First}),
        {ok, FirstNext} = quod_scope_session:invoke_next(Handle, First, 1),
        ?assertEqual(
           {solution, 1, Follow, false},
           receive_scope_reply(Handle, FirstNext)),

        {ok, SecondOpen} = quod_scope_session:invoke_open(
                             Handle, Second, Follow, Chain,
                             empty_selection()),
        assert_scope_reply(Handle, SecondOpen, {opened, Second}),
        {ok, SecondNext} = quod_scope_session:invoke_next(
                             Handle, Second, 1),
        ?assertEqual(
           {solution, 1, Follow, false},
           receive_scope_reply(Handle, SecondNext))
    after
        ok = quod_scope_session:invoke_cancel(Handle, First),
        ok = quod_scope_session:invoke_cancel(Handle, Second),
        ok = quod_scope_session:close(Handle),
        ok = wait_workers(A, 0, ?WAIT_RETRIES)
    end.

t_grounded_ask(#{pets := P}) ->
    ?assertMatch({ok, [#{}], _}, prove(P, {'::', animals, {diet, dog, meat}})),
    ?assertMatch({fail, [_ | _]},
                 prove(P, {'::', animals, {diet, dog, grass}})).

t_self_ask(#{animals := A}) ->
    ?assertMatch({ok, [#{}], _}, prove(A, {'::', animals, {isa, dog, mammal}})).

%% A content-readable qctx namespace is not distributed-proof authority. The
%% foreign raw call must fail before the target engine opens any worker, while
%% an exact self-selection remains ordinary in-place Prolog. Verdict refusal
%% retains its older, stronger public error.
t_raw_snapshot_selector_boundary(#{pets := P, animals := A}) ->
    {ok, Est0, Height} = quod_prolog:attach_runtime(P),
    try
        Est = quod_predicates:set_context(
                Est0, quod_predicates:proof_context(P, Height, undefined)),
        TargetProves = maps:get(proves, quod_prolog:stats(A)),
        ?assertEqual(
           {error, {ask_requires_anchored_proof, A}},
           quod_prolog:prove_est(
             {'::', A, {diet, cat, fish}}, Est)),
        ?assertMatch(
           {ok, #{}, [], _},
           quod_prolog:prove_est(
             {'::', P, {instance_of, pet, my_dog}}, Est)),
        VerdictEst = quod_predicates:set_context(
                       Est0, quod_predicates:verdict_context(P, Height)),
        ?assertEqual(
           {error, ask_in_membership_verdict},
           quod_prolog:prove_est_read_only(
             {'::', A, {diet, cat, fish}}, VerdictEst)),
        ?assertEqual(TargetProves, maps:get(proves, quod_prolog:stats(A)))
    after
        ok = quod_prolog:runtime_detach(P),
        ok = quod_prolog:sync(P)
    end.

t_loud_routing_errors(#{pets := P}) ->
    ?assertEqual({error, {unknown_ontology, <<"nope">>}},
                 prove(P, {'::', nope, {diet, dog, {'D'}}})),
    ?assertMatch({error, {bad_name, _}},
                 prove(P, {'::', {bad, a, name}, {diet, dog, {'D'}}})).

t_recursive_selection(#{pets := P}) ->
    ?assertMatch({ok, [#{'N' := rex}], _},
                 prove(P, {'::', animals,
                           {'::', pets, {attribute, my_dog, name, {'N'}}}})).

t_three_scope_chain(#{pets := P}) ->
    ?assertMatch({ok, [#{'X' := ok}], _},
                 prove(P, {'::', chain_b, {via_c, {'X'}}})).

%% A failed invocation's writes remain in B's shared proof scope, exactly as
%% ordinary local Prolog backtracking preserves database writes.
t_failed_foreign_branch_retains_state(#{pets := P}) ->
    Goal = {';', {'::', chain_b, stage_and_fail},
                 {'::', chain_b, shared_mark_visible}},
    ?assertEqual({error, foreign_write_unsupported}, prove(P, Goal)).

%% transaction/1 restores B before the enclosing disjunction tries its second
%% alternative. The second branch can therefore observe absence and stage its
%% own write; the temporary final write still hits Step 3's publication gate.
t_transaction_restores_foreign_branch_before_alternative(
  #{pets := P, chain_b := B}) ->
    First = {',', {'::', chain_b, {assertz, tx_hidden}}, fail},
    Goal = {transaction, {';', First, {'::', chain_b, tx_second}}},
    ?assertEqual({error, foreign_write_unsupported}, prove(P, Goal)),
    ?assertMatch({fail, _}, prove(B, tx_hidden)),
    ?assertMatch({fail, _}, prove(B, tx_kept)).

%% The transaction belongs to A, but the choice point and temporary write are
%% both inside B. B must inherit A's active transaction lineage: otherwise the
%% failed first alternative leaves origin_tx_hidden behind and the second one
%% cannot prove its absence.
t_origin_transaction_is_inherited_by_selected_branch(
  #{pets := P, chain_b := B}) ->
    Goal = {transaction, {'::', chain_b, origin_tx_branch}},
    ?assertMatch({ok, [#{}], _}, prove(P, Goal)),
    ?assertMatch({fail, _}, prove(B, origin_tx_hidden)).

%% The transaction begins inside B and selects C. B restores itself through
%% Erlog's local token; the origin controller restores C before B continues.
t_selected_scope_transaction_restores_descendant(
  #{pets := P, chain_c := C}) ->
    ?assertEqual(
       {error, foreign_write_unsupported},
       prove(P, {'::', chain_b, tx_via_c})),
    ?assertMatch({fail, _}, prove(C, c_tx_hidden)),
    ?assertMatch({fail, _}, prove(C, c_tx_kept)).

%% B owns the transaction, selects C, and C calls back into a fresh logical B
%% invocation. The callback's failed alternative must still belong to B's
%% transaction even though its Erlog continuation was opened by C.
t_selected_transaction_survives_reentrant_callback(
  #{pets := P, chain_b := B}) ->
    ?assertMatch(
       {ok, [#{}], _},
       prove(P, {'::', chain_b, tx_reentry_via_c})),
    ?assertMatch({fail, _}, prove(B, tx_reentry_hidden)).

%% Total transaction failure rolls back every selected ontology. The ordinary
%% outer alternative succeeds, proving no stale dirty bit survived the restore.
t_failed_transaction_restores_all_selected_scopes(
  #{pets := P, chain_b := B, chain_c := C}) ->
    Writes =
        {',', {'::', chain_b, {assertz, b_total_rollback}},
         {',', {'::', chain_c, {assertz, c_total_rollback}}, fail}},
    ?assertMatch({ok, [#{}], _}, prove(P, {';', {transaction, Writes}, true})),
    ?assertMatch({fail, _}, prove(B, b_total_rollback)),
    ?assertMatch({fail, _}, prove(C, c_total_rollback)).

%% A scope worker may service a second invocation while the first is suspended
%% in a foreign call. The second invocation is unrelated and must not inherit
%% the first one's transaction merely because both run in the same process.
%% Without lineage isolation its failed write is rolled back, so the alternative
%% succeeds; ordinary Prolog semantics instead retain the write and exhaust.
t_unrelated_reentrant_invocation_has_no_transaction_lineage(
  #{pets := P, chain_b := B}) ->
    ProofId = crypto:strong_rand_bytes(32),
    Anchor = quod_simplex:genesis_hash(B),
    Engine = quod_reg:where({quod_prolog, B}),
    OriginIdentity = {P, quod_simplex:genesis_hash(P)},
    _ = quod_proof_context:start(
          ProofId, false, OriginIdentity,
          quod_time:mono_ms() + 60000),
    try
        {ok, ScopeId, Handle} = quod_proof_context:get_or_open_scope(
                         {B, Anchor},
                         fun(NewScopeId) ->
                             case gen_server:call(
                                    Engine,
                                    {scope_open, NewScopeId, ProofId,
                                     Anchor, false,
                                     quod_proof_context:deadline_ms()}) of
                                 {ok, Opened} ->
                                     {ok, quod_scope_session:pid(Opened), Opened};
                                 {error, _} = Error ->
                                     Error
                             end
                         end),
        Selection = empty_selection(),
        Waiting = invocation_id(1),
        {ok, WaitingOpen} = quod_scope_session:invoke_open(
                              Handle, Waiting, tx_waits_in_c,
                              [OriginIdentity], Selection),
        assert_scope_reply(Handle, WaitingOpen, {opened, Waiting}),
        ok = quod_proof_context:register_invocation(
               {ScopeId, Waiting}, Selection),
        {ok, WaitingNext} = quod_scope_session:invoke_next(
                              Handle, Waiting, 1),
        {ScopePid, NestedRef} = await_nested_open_serving_controller(
                                  ProofId, <<"chain_c">>, {leaf, ok}),

        Unrelated = invocation_id(2),
        Branch = {';', {',', {assertz, unrelated_tx_hidden}, fail},
                       {'\\+', unrelated_tx_hidden}},
        {ok, UnrelatedOpen} = quod_scope_session:invoke_open(
                                Handle, Unrelated, Branch,
                                [OriginIdentity], Selection),
        ?assertEqual(
           {opened, Unrelated},
           receive_scope_reply_serving_controller(Handle, UnrelatedOpen)),
        ok = quod_proof_context:register_invocation(
               {ScopeId, Unrelated}, Selection),
        {ok, UnrelatedNext} = quod_scope_session:invoke_next(
                                Handle, Unrelated, 1),
        ?assertMatch(
           {complete, 1, _, true},
           receive_scope_reply_serving_controller(Handle, UnrelatedNext)),

        ScopePid ! {proof_nested_reply, ProofId, NestedRef,
                    {error, forced_scope_error}},
        ?assertMatch(
           {error, forced_scope_error, _},
           receive_scope_reply_serving_controller(Handle, WaitingNext))
    after
        quod_proof_context:stop(fun quod_scope_session:close/1,
                                fun(_Proxy) -> ok end),
        ok = wait_workers(B, 0, ?WAIT_RETRIES)
    end.

%% C calls back into the already-suspended B scope. The B write must be visible
%% there; opening a second B overlay would make the proof fail instead.
t_reentrant_scope_reuse(#{pets := P}) ->
    ?assertEqual({error, foreign_write_unsupported},
                 prove(P, {'::', chain_b, {via_c_back, ok}})).

%% B selects the already-running origin scope A. The write belongs to A's
%% ordinary transaction diff; no second A overlay is opened.
t_origin_scope_reentry_commits_write(#{pets := P}) ->
    ?assertMatch({ok, [#{}], _},
                 prove(P, {'::', chain_b, via_origin_write})),
    ?assertMatch({ok, [#{}], _}, prove(P, origin_callback_write)).

t_nested_failure_reasons(#{pets := P}) ->
    {fail, Reasons} = prove(P, {'::', chain_b, via_c_failure}),
    ?assert(lists:member(c_blocked, Reasons)).

%% A nested `::` into an ontology whose can_invoke/4 refuses (the private
%% ontology admits only secret/1 and blocked/1, and a nested ask always carries
%% a non-empty chain) must FAIL LOGICALLY, not crash the nested serve path. This
%% is the exact route the refusal refactor closed: a refused invocation runs
%% fail_with_reason(not_allowed(Ns)) and completes with the reason like any goal.
t_nested_refusal_fails_logically(#{pets := P}) ->
    {fail, Reasons} = prove(P, {'::', chain_b, via_private_denied}),
    ?assert(lists:member({not_allowed, <<"private">>}, Reasons)),
    %% ...and the refusal is backtrackable inside the nested proof: the second
    %% branch (an admitted secret/1) succeeds.
    ?assertMatch(
       {ok, [_ | _], _},
       prove(P, {'::', chain_b, via_private_denied_recovers})).

t_read_only_tree_rejects_first_write(#{animals := A, pets := P}) ->
    LocalMarker = {read_only_local_write, blocked},
    ?assertEqual(
       {error, read_only},
       quod_prolog:prove_ro(P, {assertz, LocalMarker}, P)),
    ?assertMatch({fail, [_ | _]}, prove(P, LocalMarker)),
    ForeignMarker = {read_only_foreign_write, blocked},
    ?assertEqual(
       {error, read_only},
       quod_prolog:prove_ro(P, {'::', animals, {assertz, ForeignMarker}}, P)),
    ?assertMatch({fail, [_ | _]}, prove(A, ForeignMarker)).

t_scope_session_binding(#{animals := A}) ->
    Engine = quod_reg:where({quod_prolog, A}),
    Anchor = quod_simplex:genesis_hash(A),
    ProofId = crypto:strong_rand_bytes(32),
    ScopeId = scope_id(1),
    {ok, Handle} = gen_server:call(
                     Engine,
                     {scope_open, ScopeId, ProofId, Anchor, false,
                      test_deadline()}),
    try
        {quod_scope_session, ScopePid, ScopeId, ProofId,
         SessionRef, A, Anchor} = Handle,
        InvocationId = invocation_id(1),
        Goal = {diet, cat, {'D'}},
        Chain = [{<<"pets">>, <<1:256>>}],
        Selection = empty_selection(),
        ScopePid ! {scope_invoke_open, self(), <<0:256>>, SessionRef,
                    make_ref(), InvocationId, Goal, Chain, Selection},
        assert_no_scope_reply(ScopePid, ProofId, SessionRef),
        ScopePid ! {scope_invoke_open, self(), ProofId, make_ref(),
                    make_ref(), InvocationId, Goal, Chain, Selection},
        assert_no_scope_reply(ScopePid, ProofId, SessionRef),
        Stranger = spawn(fun() -> ok end),
        ScopePid ! {scope_invoke_open, Stranger, ProofId, SessionRef,
                    make_ref(), InvocationId, Goal, Chain, Selection},
        assert_no_scope_reply(ScopePid, ProofId, SessionRef),
        OpenRef = make_ref(),
        ScopePid ! {scope_invoke_open, self(), ProofId, SessionRef,
                    OpenRef, InvocationId, Goal, Chain, Selection},
        assert_scope_reply(Handle, OpenRef, {opened, InvocationId}),
        {ok, WrongSeqRef} = quod_scope_session:invoke_next(
                              Handle, InvocationId, 2),
        ?assertEqual({error, {protocol_error, answer_sequence}, false},
                     receive_scope_reply(Handle, WrongSeqRef)),
        {ok, NextRef} = quod_scope_session:invoke_next(
                          Handle, InvocationId, 1),
        ?assertMatch({solution, 1, {diet, cat, fish}, false},
                     receive_scope_reply(Handle, NextRef)),
        ok = quod_scope_session:invoke_cancel(Handle, InvocationId),
        ?assertEqual(
           {ok, Handle},
           gen_server:call(
             Engine, {scope_open, ScopeId, ProofId, Anchor, false,
                      test_deadline()})),
        ?assertEqual(
           {error, {anchor_conflict, A}},
           gen_server:call(
             Engine, {scope_open, ScopeId, ProofId, <<0:256>>, false,
                      test_deadline()})),
        ?assertEqual(
           {error, scope_mode_conflict},
           gen_server:call(
             Engine, {scope_open, ScopeId, ProofId, Anchor, true,
                      test_deadline()})),
        ?assertEqual(
           {error, {anchor_conflict, A}},
             gen_server:call(
               Engine, {scope_open, scope_id(2),
                      crypto:strong_rand_bytes(32), <<0:256>>, false,
                      test_deadline()}))
    after
        ok = quod_scope_session:close(Handle),
        ok = wait_workers(A, 0, ?WAIT_RETRIES)
    end.

%% The scope publishes its write before asking the origin to open the nested
%% target. A state-less nested error must not rewind that published revision.
t_stateless_scope_error_keeps_published_revision(
  #{pets := P, chain_b := ChainB}) ->
    Engine = quod_reg:where({quod_prolog, ChainB}),
    Anchor = quod_simplex:genesis_hash(ChainB),
    ProofId = crypto:strong_rand_bytes(32),
    ScopeId = scope_id(3),
    {ok, Handle} = gen_server:call(
                     Engine,
                     {scope_open, ScopeId, ProofId, Anchor, false,
                      test_deadline()}),
    try
        InvocationId = invocation_id(1),
        Goal = {',', {assertz, {published_before_error, retained}},
                     {'::', chain_c, {leaf, ok}}},
        {ok, OpenRef} = quod_scope_session:invoke_open(
                          Handle, InvocationId, Goal,
                          [{P, quod_simplex:genesis_hash(P)}],
                          empty_selection()),
        assert_scope_reply(Handle, OpenRef, {opened, InvocationId}),
        {ok, NextRef} = quod_scope_session:invoke_next(
                          Handle, InvocationId, 1),
        ScopePid = quod_scope_session:pid(Handle),
        receive
            {proof_nested_open, ProofId, ScopePid, NestedRef,
             {ScopeId, InvocationId}, _Selection,
             <<"chain_c">>, {leaf, ok}, _Chain} ->
                ScopePid ! {proof_nested_reply, ProofId, NestedRef,
                            {error, forced_scope_error}}
        after 1000 ->
            ?assert(false)
        end,
        ?assertEqual(
           {error, forced_scope_error, true},
           receive_scope_reply(Handle, NextRef))
    after
        ok = quod_scope_session:close(Handle),
        ok = wait_workers(ChainB, 0, ?WAIT_RETRIES)
    end.

t_scope_owner_death_reaps_session(#{animals := A}) ->
    Parent = self(),
    Engine = quod_reg:where({quod_prolog, A}),
    Anchor = quod_simplex:genesis_hash(A),
    Owner = spawn(fun() ->
        Result = gen_server:call(
                   Engine, {scope_open, scope_id(4),
                            crypto:strong_rand_bytes(32), Anchor, false,
                            test_deadline()}),
        Parent ! {owner_scope, self(), Result},
        receive stop -> ok end
    end),
    {ok, Handle} = receive
                       {owner_scope, Owner, Result} -> Result
                   after 1000 -> error(scope_open_timeout)
                   end,
    ScopePid = quod_scope_session:pid(Handle),
    ScopeMRef = monitor(process, ScopePid),
    exit(Owner, kill),
    receive
        {'DOWN', ScopeMRef, process, ScopePid, _Reason} -> ok
    after 1000 -> ?assert(false)
    end,
    ?assertEqual(ok, wait_workers(A, 0, ?WAIT_RETRIES)).

t_scope_worker_crash_is_protocol_error(#{pets := P, slow := Slow}) ->
    Engine = quod_reg:where({quod_prolog, Slow}),
    Anchor = quod_simplex:genesis_hash(Slow),
    ProofId = crypto:strong_rand_bytes(32),
    ScopeId = scope_id(5),
    {ok, Handle} = gen_server:call(
                     Engine,
                     {scope_open, ScopeId, ProofId, Anchor, false,
                      test_deadline()}),
    InvocationId = invocation_id(1),
    {ok, OpenRef} = quod_scope_session:invoke_open(
                      Handle, InvocationId, loop,
                      [{P, quod_simplex:genesis_hash(P)}],
                      empty_selection()),
    assert_scope_reply(Handle, OpenRef, {opened, InvocationId}),
    {ok, NextRef} = quod_scope_session:invoke_next(
                      Handle, InvocationId, 1),
    exit(quod_scope_session:pid(Handle), kill),
    _ = quod_proof_context:start(
          crypto:strong_rand_bytes(32), false,
          {P, quod_simplex:genesis_hash(P)}, test_deadline()),
    try
        ?assertEqual(
           {error, {protocol_error, proof_engine}},
           quod_ask:test_await_scope_reply(Handle, NextRef))
    after
        quod_proof_context:stop(
          fun(_Scope) -> ok end, fun(_Proxy) -> ok end)
    end,
    ?assertEqual(ok, wait_workers(Slow, 0, ?WAIT_RETRIES)),
    ?assertMatch({ok, [#{}], _}, prove(Slow, {ping, ok})).

assert_scope_reply(
  Handle,
  RequestRef, Expected) ->
    ?assertEqual(Expected, receive_scope_reply(Handle, RequestRef)).

assert_no_scope_reply(Pid, ProofId, SessionRef) ->
    receive
        {scope_reply, Pid, ProofId, SessionRef, _RequestRef, _Reply} ->
            ?assert(false)
    after 20 -> ok
    end.

receive_scope_reply(
  {quod_scope_session, Pid, _ScopeId, ProofId, SessionRef, _Ns, _Anchor},
  RequestRef) ->
    receive
        {scope_reply, Pid, ProofId, SessionRef, RequestRef, Reply} -> Reply
    after 1000 -> error(scope_reply_timeout)
    end.

receive_scope_reply_serving_controller(
  {quod_scope_session, Pid, _ScopeId, ProofId,
   SessionRef, _Ns, _Anchor} = Handle,
  RequestRef) ->
    receive
        {scope_reply, Pid, ProofId, SessionRef, RequestRef, Reply} ->
            Reply;
        Request = {proof_tx_request, ProofId, Pid, _, _, _, _} ->
            serve_test_tx_request(Request),
            receive_scope_reply_serving_controller(Handle, RequestRef)
    after 1000 ->
        error(scope_reply_timeout)
    end.

await_nested_open_serving_controller(ProofId, Target, Goal) ->
    receive
        {proof_nested_open, ProofId, From, RequestRef,
         _Actor, _Selection, Target, Goal, _Chain} ->
            {From, RequestRef};
        Request = {proof_tx_request, ProofId, _From, _, _, _, _} ->
            serve_test_tx_request(Request),
            await_nested_open_serving_controller(ProofId, Target, Goal)
    after 1000 ->
        error(nested_open_timeout)
    end.

serve_test_tx_request(
  {proof_tx_request, ProofId, From, ScopeId, InvocationId,
   RequestRef, Operation}) ->
    Reply = case quod_proof_context:registered_scope(ScopeId) of
                true -> quod_proof_context:tx_request(
                          {ScopeId, InvocationId}, Operation);
                false -> {error, not_allowed}
            end,
    From ! {proof_tx_reply, ProofId, InvocationId, RequestRef, Reply},
    ok.

forward_messages(Parent) ->
    receive
        Message ->
            Parent ! {forwarded, self(), Message},
            forward_messages(Parent)
    end.

receive_forwarded(Pid) ->
    receive
        {forwarded, Pid, Message} -> Message
    after 1000 ->
        error(nested_reply_timeout)
    end.

%% `can_invoke/4` refusal is ORDINARY logical failure carrying one bounded
%% reason, not an infrastructure error: none of the goal ran, so the target
%% disclosed and mutated nothing, while the caller keeps ordinary Prolog control.
t_permission_gate(#{pets := P, private := Private}) ->
    ?assertMatch({ok, [#{'X' := 42}], _},
                 prove(P, {'::', private, {secret, {'X'}}})),
    Denied = {'::', private, {hidden, {'X'}}},
    ?assertMatch({fail, [_ | _]}, prove(P, Denied)),
    {fail, Reasons} = prove(P, Denied),
    %% the refusal is the root cause, under the automatic failing-call frame
    ?assert(lists:member({not_allowed, Private}, Reasons)),

    %% ...so a caller may inspect it and take another branch: the whole point of
    %% not making denial fatal. `(Denied ; Fallback)` runs Fallback.
    ?assertMatch({ok, [#{'X' := 42}], _},
                 prove(P, {';', Denied, {'::', private, {secret, {'X'}}}})),

    %% and a fallback may branch on WHY it failed, like any other reason: the
    %% refusal sits under the automatic failing-call frame, same as any
    %% fail_with_reason/1 root cause.
    %% (the frame freezes its unbound argument as the ground `unbound` value)
    Recover = {';', Denied,
               {get_fail_reasons, [{'Frame'}, {not_allowed, Private}]}},
    ?assertMatch({ok, [#{'Frame' := {'::', private, {hidden, unbound}}}], _},
                 prove(P, Recover)).

t_failure_reasons_cross_local_ask(#{pets := P}) ->
    Remote = {'::', private, {blocked, bob}},
    Recover = {';', Remote,
               {get_fail_reasons,
                [{'Outer'}, {blocked, bob}, {impossible_to_link, bob}]}},
    ?assertMatch(
       {ok, [#{'Outer' := Remote}], _},
       prove(P, Recover)).

t_foreign_write_rejected(#{animals := A, pets := P}) ->
    ?assertEqual({error, foreign_write_unsupported},
                 prove(P, {'::', animals, {assertz, {stolen, fact}}})),
    ?assertMatch({fail, [_ | _]}, prove(A, {stolen, fact})).

%% A scope may be deriving an unproductive goal without blocking its owning
%% ontology engine. Killing that isolated worker leaves the engine healthy.
t_scope_engine_stays_responsive(#{slow := Slow, pets := P}) ->
    {ok, Handle} = open_test_scope(Slow, false, 6),
    InvocationId = invocation_id(6),
    {ok, OpenRef} = quod_scope_session:invoke_open(
                      Handle, InvocationId, loop,
                      [{P, quod_simplex:genesis_hash(P)}],
                      empty_selection()),
    assert_scope_reply(Handle, OpenRef, {opened, InvocationId}),
    {ok, _NextRef} = quod_scope_session:invoke_next(
                       Handle, InvocationId, 1),
    timer:sleep(20),
    Started = erlang:monotonic_time(millisecond),
    ?assertMatch({ok, [#{}], _}, prove(Slow, {ping, ok})),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000),
    exit(quod_scope_session:pid(Handle), kill),
    ?assertEqual(ok, wait_workers(Slow, 0, ?WAIT_RETRIES)).

t_target_crash_kills_scope(#{slow := Slow}) ->
    {ok, Handle} = open_test_scope(Slow, false, 7),
    ScopePid = quod_scope_session:pid(Handle),
    ScopeMRef = monitor(process, ScopePid),
    Engine = quod_reg:where({quod_prolog, Slow}),
    exit(Engine, kill),
    receive
        {'DOWN', ScopeMRef, process, ScopePid, _Reason} -> ok
    after 1000 -> ?assert(false)
    end,
    ?assertMatch({ok, [#{}], _}, prove_ready(Slow, {ping, ok})).

t_scope_worker_limit(#{animals := A}) ->
    Handles = [begin
                   {ok, Handle} = open_test_scope(A, false, N),
                   Handle
               end || N <- lists:seq(100, 163)],
    Anchor = quod_simplex:genesis_hash(A),
    ?assertEqual(
       {error, {ontology_busy, A}},
       gen_server:call(
         quod_reg:where({quod_prolog, A}),
         {scope_open, scope_id(164), crypto:strong_rand_bytes(32),
          Anchor, false, test_deadline()})),
    lists:foreach(fun quod_scope_session:close/1, Handles),
    ?assertEqual(ok, wait_workers(A, 0, ?WAIT_RETRIES)).

%% A scope remains pinned to its committed base while a later transaction
%% advances the ontology. Subsequent answers cannot observe that new fact.
t_frozen_scope_view(#{animals := A, pets := P}) ->
    {ok, Handle} = open_test_scope(A, false, 8),
    try
        InvocationId = invocation_id(8),
        {ok, OpenRef} = quod_scope_session:invoke_open(
                          Handle, InvocationId, {diet, dog, {'D'}},
                          [{P, quod_simplex:genesis_hash(P)}],
                          empty_selection()),
        assert_scope_reply(Handle, OpenRef, {opened, InvocationId}),
        {ok, FirstRef} = quod_scope_session:invoke_next(
                           Handle, InvocationId, 1),
        ?assertMatch(
           {solution, 1, {diet, dog, kibble}, false},
           receive_scope_reply(Handle, FirstRef)),
        ?assertMatch({ok, [_], _},
                     prove(A, {assertz, {diet, dog, tofu}})),
        {ok, SecondRef} = quod_scope_session:invoke_next(
                            Handle, InvocationId, 2),
        ?assertMatch(
           {solution, 2, {diet, dog, meat}, false},
           receive_scope_reply(Handle, SecondRef)),
        {ok, CompleteRef} = quod_scope_session:invoke_next(
                              Handle, InvocationId, 3),
        ?assertMatch(
           {complete, 3, _, false},
           receive_scope_reply(Handle, CompleteRef))
    after
        ok = quod_scope_session:close(Handle),
        ok = wait_workers(A, 0, ?WAIT_RETRIES)
    end.

t_workers_are_reaped(#{namespaces := Namespaces}) ->
    lists:foreach(
      fun(Ns) ->
          ?assertEqual(ok, wait_workers(Ns, 0, ?WAIT_RETRIES)),
          Stats = quod_prolog:stats(Ns),
          ?assertEqual(0, maps:get(proof_workers, Stats)),
          ?assertEqual(0, maps:get(scope_workers, Stats))
      end, Namespaces).

open_test_scope(Ns, ReadOnly, Id) ->
    Engine = quod_reg:where({quod_prolog, Ns}),
    gen_server:call(
      Engine,
      {scope_open, scope_id(Id), crypto:strong_rand_bytes(32),
       quod_simplex:genesis_hash(Ns), ReadOnly, test_deadline()}).

test_deadline() -> quod_time:mono_ms() + 60000.

write_ontology(Dir, Name, Contents) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, Contents),
    Path.

start_ns(Ns, File, Dir) ->
    {Ns, Cfg} = quod_app:build_ns_config(#{namespace => Ns, mode => create,
                    genesis_file => File, data_dir => list_to_binary(Dir), seeds => []}),
    {ok, Pid} = quod_ns:start_link(Ns, Cfg),
    unlink(Pid),
    Ns.

stop_ns(Ns) ->
    case quod_reg:where({quod_ns, Ns}) of
        undefined -> ok;
        Pid ->
            Ref = monitor(process, Pid),
            exit(Pid, shutdown),
            receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end
    end.

prove(Ns, Goal) -> quod_prolog:prove(Ns, Goal, Ns).

prove_ready(Ns, Goal) -> prove_ready(Ns, Goal, 300).
prove_ready(_Ns, _Goal, 0) -> {error, timeout};
prove_ready(Ns, Goal, N) ->
    case prove(Ns, Goal) of
        {error, rebuilding} -> timer:sleep(10), prove_ready(Ns, Goal, N - 1);
        {error, no_such_namespace} -> timer:sleep(10), prove_ready(Ns, Goal, N - 1);
        Result -> Result
    end.

wait_workers(_Ns, _Expected, 0) -> {error, timeout};
wait_workers(Ns, Expected, N) ->
    case maps:get(scope_workers, quod_prolog:stats(Ns), undefined) of
        Expected -> ok;
        _ -> timer:sleep(10), wait_workers(Ns, Expected, N - 1)
    end.

empty_selection() -> quod_transaction_scope:empty_selection().

invocation_id(N) -> <<N:128>>.

scope_id(N) -> <<N:128>>.
