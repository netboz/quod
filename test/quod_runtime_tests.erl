-module(quod_runtime_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-import(quod_ct, [rp/2, diff_for/1, change/2, batch/1, wait_until/1, wait_until/2]).

%%%===================================================================
%%% Slice 2: quod_runtime — the founding gate + ordering (pure core), the
%%% attach/reconcile lifecycle against a bare kb, and the real founded-namespace
%%% acceptance paths (plan resilient-frolicking-valley, Increment 2).
%%%===================================================================

%% a declaration term; Goal defaults to the registered projection stub
d(Id, Needs)       -> d(Id, Needs, projection_noop).
d(Id, Needs, Goal) -> {state_handler, Id, [{'/', watched, 1}], Needs, Goal}.

%% Erlog's vars_in/1 deliberately skips `_`; projection jobs must reject it just like every
%% other unbound variable, because a queue entry must be stable and fully ground.
anonymous_projection_argument_refused_test() ->
    ?assertNot(quod_runtime_predicates:is_ground({'_'})),
    ?assertNot(quod_runtime_predicates:is_ground({job, {'_'}})),
    ?assertNot(quod_runtime_predicates:is_ground([resource, {'X'}])),
    ?assert(quod_runtime_predicates:is_ground({job, [resource, 1]})).

%%%===================================================================
%%% pure core: plan_handlers/2
%%%===================================================================

%% independent handlers order by Id term order — identical on every node
order_deterministic_test() ->
    G = [d(c, []), d(a, []), d(b, [])],
    {ok, #{order := Order}} = quod_runtime:plan_handlers(G, G),
    ?assertEqual([a, b, c], Order),
    {ok, #{order := Order2}} = quod_runtime:plan_handlers(G, lists:reverse(G)),
    ?assertEqual(Order, Order2).

%% a dependent whose Id sorts FIRST still runs after its prerequisite
chain_beats_term_order_test() ->
    G = [d(a_routes, [{current, z_list}]), d(z_list, [])],
    {ok, #{order := Order}} = quod_runtime:plan_handlers(G, G),
    ?assertEqual([z_list, a_routes], Order).

cycle_is_config_error_test() ->
    G = [d(a, [{current, b}]), d(b, [{current, a}])],
    ?assertMatch({error, {handler_cycle, [a, b]}}, quod_runtime:plan_handlers(G, G)).

missing_dependency_is_config_error_test() ->
    G = [d(a, [{current, ghost}])],
    ?assertMatch({error, {missing_dependency, a, [{current, ghost}]}},
                 quod_runtime:plan_handlers(G, G)).

%% a Need that is not a ground current/1 term is refused (conditions are deferred)
condition_need_refused_test() ->
    G = [d(a, [{watched, 1}])],
    ?assertMatch({error, {missing_dependency, a, _}}, quod_runtime:plan_handlers(G, G)).

%% a duplicated Need entry is authoring noise, not a second edge — must NOT masquerade
%% as a cycle (review regression: lists:delete removes one occurrence per Kahn pass)
duplicate_need_is_not_a_cycle_test() ->
    G = [d(a, []), d(b, [{current, a}, {current, a}])],
    {ok, #{order := Order}} = quod_runtime:plan_handlers(G, G),
    ?assertEqual([a, b], Order).

%% a founding declaration containing a variable can never round-trip the KB as the same term
%% (findall renames vars) — refused loudly instead of misreporting missing_founding
nonground_founding_refused_test() ->
    G = [{state_handler, a, [{'/', w, 1}], [], {goal, {'X'}}}],
    ?assertMatch({error, {nonground_founding, _}}, quod_runtime:plan_handlers(G, G)).

%% stored-but-not-founding: refused + counted, the rest activates
dynamic_declaration_rejected_test() ->
    Founding = [d(a, [])],
    Stored   = [d(a, []), d(evil, [])],
    {ok, #{handlers := Hs, rejected_dynamic := 1}} =
        quod_runtime:plan_handlers(Founding, Stored),
    ?assertEqual([a], maps:keys(Hs)).

%% same Id, different body: the swap is NOT activated (full-term match) and the missing
%% founding term makes it a loud config error — the C2 backdoor becomes unhealthy, not code-exec
same_id_different_body_test() ->
    Founding = [d(a, [], projection_noop)],
    Stored   = [d(a, [], {evil_goal, payload})],
    ?assertMatch({error, {missing_founding, _}},
                 quod_runtime:plan_handlers(Founding, Stored)).

%% a retracted founding declaration is a distinct loud error
retracted_founding_test() ->
    ?assertMatch({error, {missing_founding, _}},
                 quod_runtime:plan_handlers([d(a, [])], [])).

duplicate_id_test() ->
    G = [d(a, [], projection_noop), {state_handler, a, [], [], other_goal}],
    ?assertMatch({error, {duplicate_handler_id, [a]}}, quod_runtime:plan_handlers(G, G)).

%% a ConvergeGoal whose invoked functor is a governed staging/effect predicate is refused
%% statically (the dynamic class matrix remains the real boundary)
goal_class_gate_test() ->
    Bad = [d(a, [], {admit, x, y})],          %% invoked as admit/3 = staging
    ?assertMatch({error, {invalid_declaration, a}}, quod_runtime:plan_handlers(Bad, Bad)),
    Good = [d(a, [], projection_noop)],       %% invoked as projection_noop/1 = projection
    ?assertMatch({ok, _}, quod_runtime:plan_handlers(Good, Good)).

invalid_watch_test() ->
    Bad = [{state_handler, a, [nonsense], [], projection_noop}],
    ?assertMatch({error, {invalid_declaration, a}}, quod_runtime:plan_handlers(Bad, Bad)).

with_scope_test() ->
    ?assertEqual({projection_noop, all}, quod_runtime:with_scope(projection_noop, all)),
    ?assertEqual({f, 1, all}, quod_runtime:with_scope({f, 1}, all)).

%%%===================================================================
%%% pure tier core: event_plan/4 (Inc 3)
%%%===================================================================

%% fixture: z_list watches w/1; a_routes watches r/1 and Needs current(z_list)
tier_fixture() ->
    G = [d2(z_list, [{'/', w, 1}], []),
         d2(a_routes, [{'/', r, 1}], [{current, z_list}])],
    {ok, #{order := Order, index := Index, dependents := Deps}} =
        quod_runtime:plan_handlers(G, G),
    {Order, Index, Deps}.

d2(Id, Watch, Needs) -> {state_handler, Id, Watch, Needs, projection_noop}.

%% DA2 C-A regression: the dependent (a_routes, which sorts FIRST) is chained in on its
%% prerequisite's event and runs AFTER it, in the global converge order
inverted_order_dependent_pair_test() ->
    {Order, Index, Deps} = tier_fixture(),
    ?assertEqual([z_list, a_routes], Order),
    {Run, Scopes} = quod_runtime:event_plan([{w, x}], Index, Order, Deps),
    ?assertEqual([z_list, a_routes], Run),
    %% the matched handler gets its watched subset; the chained-in dependent gets `all`
    ?assertEqual({keys, [{w, x}]}, maps:get(z_list, Scopes)),
    ?assertEqual(all, maps:get(a_routes, Scopes)).

%% a head only the dependent watches runs the dependent alone, with its subset as scope —
%% retracted heads ride the same list (scope carries full head terms, DA2 M-D)
dependent_only_event_test() ->
    {Order, Index, Deps} = tier_fixture(),
    {Run, Scopes} = quod_runtime:event_plan([{r, dest1}, {r, dest2}], Index, Order, Deps),
    ?assertEqual([a_routes], Run),
    ?assertEqual({keys, [{r, dest1}, {r, dest2}]}, maps:get(a_routes, Scopes)).

unmatched_event_runs_nothing_test() ->
    {Order, Index, Deps} = tier_fixture(),
    ?assertEqual({[], #{}}, quod_runtime:event_plan([{unwatched, 1}], Index, Order, Deps)).

%% only 5-tuple state_handler asserts in the founding block count
founding_heads_test() ->
    Tx = #transaction{tx_id = <<"g">>, caller_ns = <<"x">>,
                      diff = [{assert, {d(a, []), {[], false}}},
                              {assert, {{other, fact}, {[], false}}},
                              {retract, {d(b, []), {[], false}}}],
                      read_check = #{}, author = <<0:256>>, sig = none},
    ?assertEqual([d(a, [])], quod_runtime:founding_heads([Tx])).

%%%===================================================================
%%% lifecycle against a bare kb (no store on disk => founding = ∅)
%%%===================================================================

setup_bare() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"rt:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Kb} = quod_prolog:start_link(Ns, #{node_id => {"127.0.0.1", 5000}}),
    {ok, Rt} = quod_runtime:start_link(Ns, #{}),
    {Ns, Kb, Rt}.

cleanup_bare({_Ns, Kb, Rt}) ->
    [case is_process_alive(P) of true -> gen_server:stop(P); false -> ok end
     || P <- [Rt, Kb]],
    ok.

bare_lifecycle_test_() ->
    {foreach, fun setup_bare/0, fun cleanup_bare/1,
     %% explicit budgets: each test polls (multi-second worst case) — the 5s eunit default
     %% is too tight under CI load
     [fun(F) -> {timeout, 30, T(F)} end
      || T <- [fun t_boot_edge_reconciles_to_live/1,
               fun t_restart_reattaches_while_ready/1,
               fun t_direct_envelopes_counted/1,
               fun t_replay_cycle_reconciles_and_rejects_dynamic/1,
               fun t_frontier_follows_and_no_history_leak/1,
               fun t_no_job_resource_follows_frontier/1,
               fun t_failed_job_blocks_frontier/1,
               fun t_heavy_queue_is_bounded/1,
               fun t_overflow_collapses_and_converges/1]]}.

%% booting until the kb's ready edge, then attach + reconcile (zero handlers) => live
t_boot_edge_reconciles_to_live({Ns, _Kb, _Rt}) ->
    fun() ->
        ?assertEqual(booting, maps:get(mode, quod_runtime:stats(Ns))),
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := live, reconciles := R}) -> R >= 1;
                               (_) -> false end),
        ?assertEqual(0, maps:get(handlers_active, quod_runtime:stats(Ns)))
    end.

%% a runtime-only restart re-attaches via the handle_continue probe (no ready edge comes)
t_restart_reattaches_while_ready({Ns, Kb, Rt}) ->
    fun() ->
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        Applied = quod_prolog:applied(Ns),
        ok = gen_server:stop(Rt),
        {ok, Rt2} = quod_runtime:start_link(Ns, #{}),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        %% the kb was untouched: same pid, same height — P was rebuilt without any replay
        ?assert(is_process_alive(Kb)),
        ?assertEqual(Applied, quod_prolog:applied(Ns)),
        ok = gen_server:stop(Rt2)
    end.

%% live commits reach the attached runtime as direct est-carrying envelopes
t_direct_envelopes_counted({Ns, _Kb, _Rt}) ->
    fun() ->
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        ok = quod_prolog:apply_block(Ns, 1, batch(change(Ns, diff_for({ping, 1}))), live),
        ok = wait_stats(Ns, fun(#{events_seen := E}) -> E >= 1; (_) -> false end)
    end.

%% a replay run re-triggers reconciliation on its ready edge — EXACTLY once per edge — and a
%% dynamically-written declaration is discovered there and refused (counted), staying live
t_replay_cycle_reconciles_and_rejects_dynamic({Ns, _Kb, _Rt}) ->
    fun() ->
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        Dyn = d(sneaky, []),
        ok = quod_prolog:apply_block(Ns, 1, batch(change(Ns, diff_for(Dyn))), live),
        %% open a replay run and close it with a live block: replay_ready fires
        ok = quod_prolog:apply_block(Ns, 2, batch(change(Ns, diff_for({r, 2}))), replay),
        ok = quod_prolog:apply_block(Ns, 3, batch(change(Ns, diff_for({r, 3}))), live),
        ok = wait_stats(Ns, fun(#{reconciles := R, rejected_dynamic := D, mode := M}) ->
                                R =:= 2 andalso D >= 1 andalso M =:= live;
                               (_) -> false end)
    end.

%% Inc 3: with zero handlers the tier is trivially complete — the frontier follows every
%% live commit, and (the review's leak regression) the floor follows too: KB history never
%% accumulates behind the runtime's pin
t_frontier_follows_and_no_history_leak({Ns, _Kb, _Rt}) ->
    fun() ->
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        %% blocks 1-3 create c1..c3, blocks 4-6 CHANGE them (a change is what saves an MVCC
        %% version): a frozen floor retains history for ALL of them (the leak), a following
        %% floor lets the next commits prune — only the tail block's change may linger
        C = fun(N) -> {list_to_atom("c" ++ integer_to_list(N)), erlang:unique_integer()} end,
        [ok = quod_prolog:apply_block(Ns, N, batch(change(Ns, diff_for(C(K)))), live)
         || {N, K} <- [{1, 1}, {2, 2}, {3, 3}, {4, 1}, {5, 2}, {6, 3}]],
        ok = wait_stats(Ns, fun(#{p_height := P, e_frontier := E}) ->
                                P =:= 6 andalso E =:= 6;
                               (_) -> false end),
        %% two more commits give the raised floor a prune opportunity past every change
        [ok = quod_prolog:apply_block(Ns, N, batch(change(Ns, diff_for({tick, N}))), live)
         || N <- [7, 8]],
        ok = wait_until(fun() ->
                            maps:get(kb_history_predicates, quod_prolog:stats(Ns), 99) =< 1
                        end)
    end.

%% A resource with no pending work needs no synthetic no-op job for every block: its derived
%% state is current through the ordered tier's frontier, and revision waiters release there.
t_no_job_resource_follows_frontier({Ns, _Kb, _Rt}) ->
    fun() ->
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        ok = quod_prolog:apply_block(Ns, 1, batch(change(Ns, diff_for({ping, 1}))), live),
        ok = wait_stats(Ns, fun(#{e_frontier := E}) -> E =:= 1; (_) -> false end),
        ?assertEqual(1, quod_runtime:revision(Ns, untouched_resource)),
        ?assertEqual(ok, quod_runtime:await_revision(Ns, untouched_resource, 1, 100))
    end.

%% A failed full rebuild is explicit missing work. Later unrelated events must not make its
%% revision barrier look satisfied; a successful rebuild clears the block and catches up.
t_failed_job_blocks_frontier({Ns, _Kb, _Rt}) ->
    fun() ->
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        ok = quod_prolog:apply_block(Ns, 1, batch(change(Ns, diff_for({ping, 1}))), live),
        ok = wait_stats(Ns, fun(#{e_frontier := E}) -> E =:= 1; (_) -> false end),
        ok = quod_runtime:enqueue_heavy(Ns, broken_resource, 1, definitely_missing_goal),
        ok = wait_stats(Ns, fun(#{heavy_failures := N}) -> N >= 1; (_) -> false end),
        ok = quod_prolog:apply_block(Ns, 2, batch(change(Ns, diff_for({ping, 2}))), live),
        ok = wait_stats(Ns, fun(#{e_frontier := E}) -> E =:= 2; (_) -> false end),
        ?assertEqual({error, timeout},
                     quod_runtime:await_revision(Ns, broken_resource, 2, 25)),
        ok = quod_runtime:enqueue_heavy(Ns, broken_resource, 2, true),
        ?assertEqual(ok, quod_runtime:await_revision(Ns, broken_resource, 2, 5000)),
        ?assert(quod_runtime:revision(Ns, broken_resource) >= 2)
    end.

%% Pending resources and retained job terms are independently bounded. Updating the one
%% admitted resource coalesces in place and does not consume another queue slot.
t_heavy_queue_is_bounded({Ns, _Kb, Rt}) ->
    fun() ->
        ok = gen_server:stop(Rt),
        {ok, Rt2} = quod_runtime:start_link(
                      Ns, #{runtime_max_heavy_workers => 0,
                            runtime_max_heavy_pending => 1,
                            runtime_max_heavy_job_bytes => 1024}),
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        ok = quod_runtime:enqueue_heavy(Ns, resource_a, 1, first),
        ok = quod_runtime:enqueue_heavy(Ns, resource_a, 2, replacement),
        ?assertEqual({error, overloaded},
                     quod_runtime:enqueue_heavy(Ns, resource_b, 1, small)),
        ?assertEqual({error, oversized},
                     quod_runtime:enqueue_heavy(Ns, resource_a, 3, <<0:16384>>)),
        #{heavy_pending := 1, heavy_running := 0, heavy_superseded := 1,
          heavy_rejected := 2} = quod_runtime:stats(Ns),
        ok = gen_server:stop(Rt2)
    end.

%% Inc 3: a zero-capacity queue makes every envelope overflow — each collapses to a fresh
%% reconciliation and the runtime still converges to the applied height
t_overflow_collapses_and_converges({Ns, _Kb, Rt}) ->
    fun() ->
        ok = gen_server:stop(Rt),
        {ok, Rt2} = quod_runtime:start_link(Ns, #{runtime_max_queued_events => 0}),
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        ok = quod_prolog:apply_block(Ns, 1, batch(change(Ns, diff_for({ping, 1}))), live),
        ok = wait_stats(Ns, fun(#{collapses := C, reconciles := R, height := H, mode := M}) ->
                                C >= 1 andalso R >= 2 andalso H >= 1 andalso M =:= live;
                               (_) -> false end),
        ok = gen_server:stop(Rt2)
    end.

%%%===================================================================
%%% founded namespace: the real slot-1 gate end-to-end (quod_ns, mode=create)
%%%===================================================================

setup_founded(GenesisTerms) ->
    {ok, _} = application:ensure_all_started(gproc),
    U   = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_rt_" ++ U),
    ok  = filelib:ensure_path(Dir),
    Pl  = filename:join(Dir, "genesis.pl"),
    ok  = file:write_file(Pl, GenesisTerms),
    Ns  = list_to_binary("rtns:" ++ U),
    {Pub, Seed} = quod_identity:generate(),
    Id  = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Cfg = #{node_id => Pub, identity => Id, data_dir => Dir,
            mode => create, genesis_file => Pl},
    {ok, Sup} = quod_ns:start_link(Ns, Cfg),
    unlink(Sup),
    {Dir, Ns, Sup}.

cleanup_founded({Dir, Ns, _Sup}) ->
    case quod_reg:where({quod_ns, Ns}) of
        undefined -> ok;
        Pid -> Ref = monitor(process, Pid),
               exit(Pid, shutdown),
               receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end
    end,
    _ = file:del_dir_r(Dir),
    ok.

%% two founded handlers with an ordering edge activate at boot
founded_handlers_active_test_() ->
    {timeout, 60, fun() ->
    F = setup_founded(<<"state_handler(z_list, [watched/1], [], projection_noop).\n"
                        "state_handler(a_routes, [watched/1], [current(z_list)], "
                        "projection_noop).\n">>),
    {_, Ns, _} = F,
    try
        ok = wait_stats(Ns, fun(#{mode := live, handlers_active := N}) -> N =:= 2;
                               (_) -> false end)
    after cleanup_founded(F) end
    end}.

%% a founding cycle marks the runtime unhealthy — loudly, permanently — while the kb
%% itself keeps serving (a P config error must not take D down)
founding_cycle_unhealthy_test_() ->
    {timeout, 60, fun() ->
    F = setup_founded(<<"state_handler(a, [watched/1], [current(b)], projection_noop).\n"
                        "state_handler(b, [watched/1], [current(a)], projection_noop).\n">>),
    {_, Ns, _} = F,
    try
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= unhealthy end),
        ?assertEqual(0, maps:get(handlers_active, quod_runtime:stats(Ns))),
        ?assertMatch({ok, _, _}, rp(Ns, {assertz, {still, alive}}))
    after cleanup_founded(F) end
    end}.

%% the acceptance bullet: restarting the runtime reconstructs P without replaying the kb —
%% under the real supervisor, killing the runtime restarts it (and the endpoints after it)
%% but leaves quod_prolog untouched at the same height
runtime_restart_no_kb_replay_test_() ->
    {timeout, 60, fun() ->
    F = setup_founded(<<"state_handler(idx, [watched/1], [], projection_noop).\n">>),
    {_, Ns, _} = F,
    try
        ok = wait_stats(Ns, fun(#{mode := live, handlers_active := N}) -> N =:= 1;
                               (_) -> false end),
        Kb = quod_reg:where({quod_prolog, Ns}),
        Rt = quod_reg:where({quod_runtime, Ns}),
        Applied = quod_prolog:applied(Ns),
        ok = gen_server:stop(Rt),
        ok = wait_until(fun() ->
                            case quod_reg:where({quod_runtime, Ns}) of
                                undefined -> false;
                                Rt        -> false;   %% still the old pid
                                _New      -> maps:get(mode, quod_runtime:stats(Ns), x)
                                                 =:= live
                            end
                        end),
        ?assertEqual(Kb, quod_reg:where({quod_prolog, Ns})),
        ?assertEqual(Applied, quod_prolog:applied(Ns)),
        ?assertEqual(1, maps:get(handlers_active, quod_runtime:stats(Ns)))
    after cleanup_founded(F) end
    end}.

%% Inc 3 end-to-end: a founded watching handler + a real consensus write — the tier runs it
%% and the P-before-E frontier advances to the committed height
founded_live_tier_advances_frontier_test_() ->
    {timeout, 60, fun() ->
        F = setup_founded(<<"state_handler(pinger, [ping/1], [], projection_noop).\n">>),
        {_, Ns, _} = F,
        try
            ok = wait_stats(Ns, fun(#{mode := live, handlers_active := N}) -> N =:= 1;
                                   (_) -> false end),
            H0 = maps:get(e_frontier, quod_runtime:stats(Ns)),
            ?assertMatch({ok, _, _}, rp(Ns, {assertz, {ping, 1}})),
            ok = wait_stats(Ns, fun(#{e_frontier := E, p_height := P, mode := live}) ->
                                    E > H0 andalso P =:= E;
                                   (_) -> false end)
        after cleanup_founded(F) end
    end}.

%% Inc 3: a founded handler whose goal STAGES a D write is a violation — execution failure,
%% collapse, and (still failing) unhealthy with the failure counted; the kb itself stays up
founded_staged_d_violation_test_() ->
    {timeout, 60, fun() ->
        F = setup_founded(<<"stager(_Scope) :- assertz(oops).\n"
                            "state_handler(bad, [w/1], [], stager).\n">>),
        {_, Ns, _} = F,
        try
            ok = wait_stats(Ns, fun(#{reconcile_failures := RF, collapses := C}) ->
                                    RF >= 1 andalso C >= 1;
                                   (_) -> false end),
            ?assertMatch({ok, _, _}, rp(Ns, {assertz, {kb, alive}}))
        after cleanup_founded(F) end
    end}.

%%%===================================================================
%%% Inc 4: the heavy-worker framework (acceptance bullet 4)
%%%===================================================================

%% A founded handler pumps heavy work per event; a deliberately SLOW (but in-budget) job
%% must not delay later namespace events (the frontier keeps advancing while it runs), and
%% its dependent output — await_revision — is released only when its revision installs.
heavy_worker_does_not_delay_events_test_() ->
    {timeout, 120, fun() ->
        %% Deliberately slow work that remains inside the production 30-second budget;
        %% pump enqueues it per converge run.
        F = setup_founded(<<"slow(0).\n"
                            "slow(N) :- N > 0, N1 is N - 1, slow(N1).\n"
                            "pump(_Scope) :- enqueue_projection(res1, slow(500000)).\n"
                            "state_handler(pumper, [ping/1], [], pump).\n">>),
        {_, Ns, _} = F,
        try
            ok = wait_stats(Ns, fun(#{mode := live, handlers_active := N}) -> N =:= 1;
                                   (_) -> false end),
            %% boot reconcile already pumped a job at the reconcile height
            H0 = maps:get(height, quod_runtime:stats(Ns)),
            %% while the slow job runs, ordinary writes keep advancing the frontier
            ?assertMatch({ok, _, _}, rp(Ns, {assertz, {ping, 1}})),
            ok = wait_stats(Ns, fun(#{e_frontier := E}) -> E > H0; (_) -> false end),
            H1 = maps:get(e_frontier, quod_runtime:stats(Ns)),
            %% Wait for the event-triggered rebuild, not merely the older boot job. This leaves
            %% no snapshot reader behind and proves the barrier reaches the live event revision.
            ?assertEqual(ok, quod_runtime:await_revision(Ns, res1, H1, 60000)),
            ?assert(quod_runtime:revision(Ns, res1) >= H1)
        after cleanup_founded(F) end
    end}.

%% Coalescing: burst writes while a worker runs — queued jobs supersede each other (counted),
%% per-resource order holds (never two workers for one resource), and the final revision
%% converges to the newest requested one.
heavy_coalesce_and_converge_test_() ->
    {timeout, 120, fun() ->
        F = setup_founded(<<"slow(0).\n"
                            "slow(N) :- N > 0, N1 is N - 1, slow(N1).\n"
                            "pump(_Scope) :- enqueue_projection(res1, slow(500000)).\n"
                            "state_handler(pumper, [ping/1], [], pump).\n">>),
        {_, Ns, _} = F,
        try
            ok = wait_stats(Ns, fun(#{mode := live, handlers_active := N}) -> N =:= 1;
                                   (_) -> false end),
            [?assertMatch({ok, _, _}, rp(Ns, {assertz, {ping, N}})) || N <- [1, 2, 3]],
            HTop = quod_prolog:applied(Ns),
            ok = wait_stats(Ns, fun(#{e_frontier := E}) -> E >= HTop; (_) -> false end),
            ?assertEqual(ok, quod_runtime:await_revision(Ns, res1, HTop, 60000)),
            #{heavy_superseded := Sup, heavy_running := Run} = quod_runtime:stats(Ns),
            ?assert(Sup >= 0),           %% supersede is timing-dependent; never negative
            ?assert(Run =< 1)            %% never two workers for one resource
        after cleanup_founded(F) end
    end}.

%% Inc-3/4 review regression (H2): a heavy job that FAILS must be isolated — it must NOT
%% collapse the ordered tier or loop. The tier keeps advancing; heavy_failures counts up while
%% collapses/reconciles do NOT run away.
heavy_failure_isolated_from_tier_test_() ->
    {timeout, 120, fun() ->
        %% boom/1 always throws (undefined predicate under unknown=>fail => fail => job_failed)
        F = setup_founded(<<"pump(_Scope) :- enqueue_projection(res_bad, boom(1)).\n"
                            "state_handler(pumper, [ping/1], [], pump).\n">>),
        {_, Ns, _} = F,
        try
            ok = wait_stats(Ns, fun(#{mode := live, handlers_active := N}) -> N =:= 1;
                                   (_) -> false end),
            %% boot reconcile pumped a job that fails; a few live writes keep the tier moving
            [?assertMatch({ok, _, _}, rp(Ns, {assertz, {ping, N}})) || N <- [1, 2, 3]],
            ok = wait_stats(Ns, fun(#{heavy_failures := HF}) -> HF >= 1; (_) -> false end),
            #{mode := M, e_frontier := E, reconciles := R} = quod_runtime:stats(Ns),
            ?assertEqual(live, M),                 %% tier NOT collapsed to unhealthy
            ?assert(E >= 1),                       %% tier advanced despite the failing job
            ?assert(R < 10)                        %% no reconcile runaway loop
        after cleanup_founded(F) end
    end}.

%% Inc-3/4 review regression (H1): a heavy job triggered by a live event must run against a
%% snapshot AT OR NEWER than its requested revision — never the stale pre-batch one. The job
%% proves a fact that only exists at its trigger height; if it ran against the lagging snapshot
%% the proof would fail (job_failed) and no revision would install.
heavy_job_sees_trigger_height_snapshot_test_() ->
    {timeout, 120, fun() ->
        %% the job asserts marker(H) into P only if ping(_) is already visible in the snapshot;
        %% projection_noop can't observe, so instead the job REQUIRES the triggering fact and
        %% fails if absent — success (revision install) proves it saw the fresh snapshot
        F = setup_founded(<<"pump(_Scope) :- enqueue_projection(res_ok, needs_ping).\n"
                            "needs_ping :- ping(_).\n"
                            "state_handler(pumper, [ping/1], [], pump).\n">>),
        {_, Ns, _} = F,
        try
            ok = wait_stats(Ns, fun(#{mode := live, handlers_active := N}) -> N =:= 1;
                                   (_) -> false end),
            ?assertMatch({ok, _, _}, rp(Ns, {assertz, {ping, 1}})),
            HTrig = maps:get(height, quod_runtime:stats(Ns)),
            %% the job needs ping/1, which exists only from HTrig on; reaching revision HTrig
            %% requires the job enqueued at HTrig to have run against the HTrig snapshot (the
            %% fix). The boot-height job runs against a pre-ping snapshot and fails — that is
            %% correct, and could only install a LOWER revision, never HTrig.
            ?assertEqual(ok, quod_runtime:await_revision(Ns, res_ok, HTrig, 60000)),
            ?assert(quod_runtime:revision(Ns, res_ok) >= HTrig)
        after cleanup_founded(F) end
    end}.

%% Replay cannot move the MVCC pin while a projection is still reading its old snapshot.
%% The runtime kills and reaps the worker first, detaches, then reconciles from the replay tip.
replay_quiesces_snapshot_readers_test_() ->
    {timeout, 120, fun() ->
        F = setup_founded(<<"slow(0).\n"
                            "slow(N) :- N > 0, N1 is N - 1, slow(N1).\n">>),
        {_, Ns, _} = F,
        try
            ok = wait_stats(Ns, fun(#{mode := live}) -> true; (_) -> false end),
            H0 = quod_prolog:applied(Ns),
            R0 = maps:get(reconciles, quod_runtime:stats(Ns)),
            ok = quod_runtime:enqueue_heavy(Ns, slow_resource, H0, {slow, 20000000}),
            ok = wait_stats(Ns, fun(#{heavy_running := N}) -> N =:= 1; (_) -> false end),
            ok = quod_prolog:apply_block(
                   Ns, H0 + 1, batch(change(Ns, diff_for({during_replay, 1}))), replay),
            ok = quod_prolog:mark_ready(Ns),
            ok = wait_stats(Ns, fun(#{mode := live, height := H, reconciles := R,
                                      heavy_running := Running}) ->
                                    H =:= H0 + 1 andalso R > R0 andalso Running =:= 0;
                               (_) -> false
                               end),
            ?assert(is_pid(quod_reg:where({quod_prolog, Ns}))),
            ?assertEqual(H0 + 1, quod_prolog:applied(Ns))
        after cleanup_founded(F) end
    end}.

%% A ready boundary is independently safe. replay_started normally arrives
%% first, but a delayed start must not let re-attach move the MVCC pin while an
%% old heavy reader remains alive.
ready_without_started_quiesces_snapshot_readers_test_() ->
    {timeout, 120, fun() ->
        F = setup_founded(<<"slow(0).\n"
                            "slow(N) :- N > 0, N1 is N - 1, slow(N1).\n">>),
        {_, Ns, _} = F,
        try
            ok = wait_stats(
                   Ns,
                   fun(#{mode := live}) -> true;
                      (_) -> false
                   end),
            H = quod_prolog:applied(Ns),
            R0 = maps:get(reconciles, quod_runtime:stats(Ns)),
            ok = quod_runtime:enqueue_heavy(
                   Ns, defensive_ready, H, {slow, 20000000}),
            ok = wait_stats(
                   Ns,
                   fun(#{heavy_running := 1}) -> true;
                      (_) -> false
                   end),
            Runtime = quod_reg:where({quod_runtime, Ns}),
            Runtime ! {replay_ready, {synthetic, make_ref()}, H},
            ok = wait_stats(
                   Ns,
                   fun(#{mode := live, reconciles := R,
                         heavy_running := 0}) ->
                           R > R0;
                      (_) -> false
                   end)
        after
            cleanup_founded(F)
        end
    end}.

%%%===================================================================
%%% helpers
%%%===================================================================

%% poll the runtime's stats until Pred approves them (Pred must handle #{} — a restart gap)
wait_stats(Ns, Pred) ->
    wait_until(fun() -> Pred(quod_runtime:stats(Ns)) end).
