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

reaction_clause(Executor, Pattern, Effect) ->
    {{react_on, Executor, Pattern, Effect}, {[], false}}.

subscription_clause(Ns, Anchor) ->
    {{subscribes, Ns, Anchor}, {[], false}}.

ae(Ns, Index, Data, Origin) ->
    quod_prolog:apply_entry(
      Ns, #entry{index = Index, data = Data}, Origin).

%% Erlog's vars_in/1 deliberately skips `_`; projection jobs must reject it just like every
%% other unbound variable, because a queue entry must be stable and fully ground.
anonymous_projection_argument_refused_test() ->
    ?assertNot(quod_predicates:is_ground({'_'})),
    ?assertNot(quod_predicates:is_ground({job, {'_'}})),
    ?assertNot(quod_predicates:is_ground([resource, {'X'}])),
    ?assert(quod_predicates:is_ground({job, [resource, 1]})).

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
    Tx = #transaction{tx_id = <<"g">>, origin = {<<"x">>, <<0:256>>},
                      diff = [{assert, {d(a, []), {[], false}}},
                              {assert, {{other, fact}, {[], false}}},
                              {retract, {d(b, []), {[], false}}}],
                      read_check = #{}, author = <<0:256>>, sig = none},
    ?assertEqual([d(a, [])], quod_runtime:founding_heads([Tx])).

%%%===================================================================
%%% ontology-subscription Slice 1: pure local catalogue
%%%===================================================================

alpha_normalization_preserves_reaction_bindings_test() ->
    A = reaction_clause(
          {agent, {name_a}},
          {from, <<"target">>, <<1:256>>,
           {assert, {pose, {name_a}, {value_a}}}},
          {notify, {name_a}, {value_a}}),
    B = reaction_clause(
          {agent, {17}},
          {from, <<"target">>, <<1:256>>,
           {assert, {pose, {17}, {42}}}},
          {notify, {17}, {42}}),
    ?assertEqual(quod_runtime:alpha_normalize(A),
                 quod_runtime:alpha_normalize(B)).

subscription_catalog_accepts_only_exact_anchored_facts_test() ->
    Ns = <<"target">>,
    Anchor = <<2:256>>,
    Stored = #{subscriptions =>
                   [subscription_clause(Ns, Anchor),
                    subscription_clause(Ns, Anchor),
                     {{subscribes, Ns, Anchor}, {['not', a, fact], false}},
                    {{subscribes, invalid_namespace, Anchor}, {[], false}},
                    {{subscribes, Ns, <<1, 2, 3>>}, {[], false}}],
               reactions => []},
    {ok, Plan} = quod_runtime:plan_runtime_catalog([], Stored),
    ?assertEqual([{Ns, Anchor}], maps:get(subscriptions, Plan)),
    %% The body-bearing clause is an ordinary inert rule, not malformed
    %% runtime configuration. Only the two malformed fact heads are counted.
    ?assertEqual(2, maps:get(rejected_subscriptions, Plan)),
    ?assertEqual(#{}, maps:get(source_interests, Plan)).

subscription_rule_is_neutral_application_logic_test() ->
    Ns = <<"target">>,
    Anchor = <<13:256>>,
    Rule = {{subscribes, Ns, Anchor},
            {[{subscription_enabled, Ns, Anchor}], false}},
    {ok, Plan} = quod_runtime:plan_runtime_catalog(
                   [], #{subscriptions => [Rule], reactions => []}),
    ?assertEqual([], maps:get(subscriptions, Plan)),
    ?assertEqual(0, maps:get(rejected_subscriptions, Plan)).

large_subscription_catalog_keeps_every_exact_identity_test() ->
    Clauses =
        [subscription_clause(
           <<"target:", (integer_to_binary(I))/binary>>, <<I:256>>)
         || I <- lists:seq(1, 1000)],
    {ok, Plan} = quod_runtime:plan_runtime_catalog(
                   [], #{subscriptions => Clauses, reactions => []}),
    ?assertEqual(1000, length(maps:get(subscriptions, Plan))),
    ?assertEqual(0, maps:get(rejected_subscriptions, Plan)).

founding_source_reaction_is_alpha_matched_and_indexed_test() ->
    Ns = <<"target">>,
    Anchor = <<3:256>>,
    Founding = reaction_clause(
                 {agent, {agent_name}},
                 {from, Ns, Anchor,
                  {assert, {pose, {agent_name}, {pose_value}}}},
                 {notify, {agent_name}, {pose_value}}),
    Stored = reaction_clause(
               {agent, {51}},
               {from, Ns, Anchor, {assert, {pose, {51}, {72}}}},
               {notify, {51}, {72}}),
    {ok, Plan} = quod_runtime:plan_runtime_catalog(
                   [Founding], #{subscriptions => [], reactions => [Stored]}),
    [Canonical] = maps:get(reactions, Plan),
    ?assertEqual([Canonical], maps:get({Ns, Anchor}, maps:get(source_interests, Plan))),
    ?assertEqual(0, maps:get(rejected_dynamic, Plan)).

%% Executor is a logical single-owner term, not an agent class. The catalogue
%% accepts any callable ontology vocabulary whose variables are supplied by
%% the event pattern; later execution resolves that bound term to one host.
non_agent_executor_is_alpha_matched_and_indexed_test() ->
    Ns = <<"target">>,
    Anchor = <<12:256>>,
    Founding = reaction_clause(
                 {service, {service_name}},
                 {from, Ns, Anchor,
                  {assert, {service_ready, {service_name}, {payload}}}},
                 {refresh_service, {service_name}, {payload}}),
    Stored = reaction_clause(
               {service, {81}},
               {from, Ns, Anchor,
                {assert, {service_ready, {81}, {93}}}},
               {refresh_service, {81}, {93}}),
    {ok, Plan} = quod_runtime:plan_runtime_catalog(
                   [Founding], #{subscriptions => [], reactions => [Stored]}),
    [Canonical] = maps:get(reactions, Plan),
    ?assertMatch({react_on, {service, _}, _, _}, Canonical),
    ?assertEqual([Canonical],
                 maps:get({Ns, Anchor}, maps:get(source_interests, Plan))).

%% A bare variable is not a logical owner. It cannot select one effect host,
%% even if an unrelated event variable happens to be bound.
bare_variable_executor_is_refused_test() ->
    Bad = reaction_clause(
            {executor},
            {assert, {service_ready, {executor}}},
            {refresh_service, {executor}}),
    ?assertMatch(
       {error, {invalid_founding_reaction, _}},
       quod_runtime:plan_runtime_catalog(
         [Bad], #{subscriptions => [], reactions => [Bad]})).

local_reaction_has_no_remote_source_interest_test() ->
    Reaction = reaction_clause(
                 {service, {service_name}},
                 {assert, {service_ready, {service_name}, {payload}}},
                 {refresh_service, {service_name}, {payload}}),
    {ok, Plan} = quod_runtime:plan_runtime_catalog(
                   [Reaction],
                   #{subscriptions => [], reactions => [Reaction]}),
    ?assertEqual(1, length(maps:get(reactions, Plan))),
    ?assertEqual(#{}, maps:get(source_interests, Plan)).

reaction_rule_is_neutral_application_logic_test() ->
    Head = {react_on,
            {service, {service_name}},
            {assert, {service_ready, {service_name}}},
            {refresh_service, {service_name}}},
    Rule = {Head, {[{reaction_enabled, {service_name}}], false}},
    {ok, Plan} = quod_runtime:plan_runtime_catalog(
                   [], #{subscriptions => [], reactions => [Rule]}),
    ?assertEqual([], maps:get(reactions, Plan)),
    ?assertEqual(0, maps:get(rejected_dynamic, Plan)).

dynamic_reaction_is_inert_and_counted_test() ->
    Ns = <<"target">>,
    Anchor = <<4:256>>,
    Dynamic = reaction_clause(
                {agent, {0}},
                {from, Ns, Anchor, {assert, {pose, {0}, {1}}}},
                {notify, {0}, {1}}),
    {ok, Plan} = quod_runtime:plan_runtime_catalog(
                   [], #{subscriptions => [], reactions => [Dynamic]}),
    ?assertEqual([], maps:get(reactions, Plan)),
    ?assertEqual(#{}, maps:get(source_interests, Plan)),
    ?assertEqual(1, maps:get(rejected_dynamic, Plan)).

reaction_effect_cannot_introduce_unbound_variables_test() ->
    Ns = <<"target">>,
    Anchor = <<5:256>>,
    Bad = reaction_clause(
            {agent, {0}},
            {from, Ns, Anchor, {assert, {pose, {0}}}},
            {notify, {0}, {not_bound_by_pattern}}),
    ?assertMatch(
       {error, {invalid_founding_reaction, _}},
       quod_runtime:plan_runtime_catalog(
         [Bad], #{subscriptions => [], reactions => [Bad]})).

reaction_rule_cannot_impersonate_a_founding_fact_test() ->
    Ns = <<"target">>,
    Anchor = <<6:256>>,
    Fact = reaction_clause(
             {agent, {0}},
             {from, Ns, Anchor, {assert, {pose, {0}}}},
             {notify, {0}}),
    {Head, _FactBody} = Fact,
    Rule = {Head, {[{call, true}], false}},
    ?assertMatch(
       {error, {missing_founding_reaction, _}},
       quod_runtime:plan_runtime_catalog(
         [Fact], #{subscriptions => [], reactions => [Rule]})).

retracted_founding_reaction_is_loud_test() ->
    Ns = <<"target">>,
    Anchor = <<7:256>>,
    Fact = reaction_clause(
             {agent, {0}},
             {from, Ns, Anchor, {assert, {pose, {0}}}},
             {notify, {0}}),
    ?assertMatch(
       {error, {missing_founding_reaction, _}},
       quod_runtime:plan_runtime_catalog(
         [Fact], #{subscriptions => [], reactions => []})).

%% Slot 1 is ontology content, never an empty skip or malformed payload. The
%% old catch-all silently turned either into an ontology with no founding
%% handlers, hiding ledger corruption.
non_content_founding_payload_is_rejected_test() ->
    lists:foreach(
      fun assert_bad_founding/1,
      [noop, {batch, []}, quod_ct:dtx_decision_payload()]).

assert_bad_founding(Data) ->
    U = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_rt_bad_genesis_" ++ U),
    Ns = list_to_binary("rtbad:" ++ U),
    try
        {ok, Store0} = quod_ledger_store:open(Ns, Dir),
        {ok, Store1} = quod_ledger_store:append(
                         Store0, [#entry{index = 1, data = Data}]),
        ok = quod_ledger_store:close(Store1),
        ?assertEqual(
           {error, invalid_genesis_payload},
           quod_runtime:test_read_founding(Ns, #{data_dir => Dir}))
    after
        _ = file:del_dir_r(Dir)
    end.

%%%===================================================================
%%% lifecycle against a bare kb (no store on disk => founding = ∅)
%%%===================================================================

setup_bare() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"rt:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Kb} = quod_prolog:start_link(
                 Ns, #{node_id => {"127.0.0.1", 5000},
                       outcome_backend => memory}),
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
        ok = ae(Ns, 1, batch(change(Ns, diff_for({ping, 1}))), live),
        ok = wait_stats(Ns, fun(#{events_seen := E}) -> E >= 1; (_) -> false end)
    end.

%% a replay run re-triggers reconciliation on its ready edge — EXACTLY once per edge — and a
%% dynamically-written declaration is discovered there and refused (counted), staying live
t_replay_cycle_reconciles_and_rejects_dynamic({Ns, _Kb, _Rt}) ->
    fun() ->
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        Dyn = d(sneaky, []),
        ok = ae(Ns, 1, batch(change(Ns, diff_for(Dyn))), live),
        %% open a replay run and close it with a live block: replay_ready fires
        ok = ae(Ns, 2, batch(change(Ns, diff_for({r, 2}))), replay),
        ok = ae(Ns, 3, batch(change(Ns, diff_for({r, 3}))), live),
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
        [ok = ae(Ns, N, batch(change(Ns, diff_for(C(K)))), live)
         || {N, K} <- [{1, 1}, {2, 2}, {3, 3}, {4, 1}, {5, 2}, {6, 3}]],
        ok = wait_stats(Ns, fun(#{p_height := P, e_frontier := E}) ->
                                P =:= 6 andalso E =:= 6;
                               (_) -> false end),
        %% two more commits give the raised floor a prune opportunity past every change
        [ok = ae(Ns, N, batch(change(Ns, diff_for({tick, N}))), live)
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
        ok = ae(Ns, 1, batch(change(Ns, diff_for({ping, 1}))), live),
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
        ok = ae(Ns, 1, batch(change(Ns, diff_for({ping, 1}))), live),
        ok = wait_stats(Ns, fun(#{e_frontier := E}) -> E =:= 1; (_) -> false end),
        ok = quod_runtime:enqueue_heavy(Ns, broken_resource, 1, definitely_missing_goal),
        ok = wait_stats(Ns, fun(#{heavy_failures := N}) -> N >= 1; (_) -> false end),
        ok = ae(Ns, 2, batch(change(Ns, diff_for({ping, 2}))), live),
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
        ok = ae(Ns, 1, batch(change(Ns, diff_for({ping, 1}))), live),
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
    Key = quod_identity:key_term({Pub, Seed}),
    Id  = #{pubkey => Pub, key => Key},
    Cfg = #{node_id => Pub, identity => Id, data_dir => Dir,
            mode => create, genesis_file => Pl},
    {ok, Sup} = quod_ns:start_link(Ns, Cfg),
    unlink(Sup),
    {Dir, Ns, Sup}.

setup_founded_terms(Terms) ->
    {ok, _} = application:ensure_all_started(gproc),
    U   = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_rt_terms_" ++ U),
    ok  = filelib:ensure_path(Dir),
    Ns  = list_to_binary("rtterms:" ++ U),
    {Pub, Seed} = quod_identity:generate(),
    Key = quod_identity:key_term({Pub, Seed}),
    Id  = #{pubkey => Pub, key => Key},
    Cfg = #{node_id => Pub, identity => Id, data_dir => Dir,
            mode => create, genesis_diff => quod_prolog:terms_to_diff(Terms)},
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

%% subscriptions are ordinary D: the normal prove/transaction/apply path changes the
%% runtime's local catalogue. No subscription-specific consensus record or executor exists.
subscription_create_remove_uses_ordinary_transactions_test_() ->
    {timeout, 60, fun() ->
    F = setup_founded(<<>>),
    {_, Ns, _} = F,
    TargetNs = <<"private:target">>,
    Anchor = <<8:256>>,
    Fact = {subscribes, TargetNs, Anchor},
    try
        ok = wait_stats(Ns, fun(#{mode := live, subscriptions_active := 0}) -> true;
                               (_) -> false end),
        H0 = quod_prolog:applied(Ns),
        ?assertMatch({ok, _, _}, rp(Ns, {assertz, Fact})),
        ok = wait_stats(Ns, fun(#{mode := live, subscriptions_active := 1,
                                  source_targets_active := 0,
                                  source_views_active := 1}) -> true;
                               (_) -> false end),
        ?assert(quod_prolog:applied(Ns) > H0),
        ?assertMatch({ok, _, _}, rp(Ns, Fact)),
        ?assertMatch({ok, _, _}, rp(Ns, {retract, Fact})),
        ok = wait_stats(Ns, fun(#{mode := live, subscriptions_active := 0,
                                  source_views_active := 0}) -> true;
                               (_) -> false end)
    after cleanup_founded(F) end
    end}.

%% A catalogue far larger than the node's foreign-history capacity must cost one
%% shared retry lane, not one timer and one attach per durable fact. With no
%% foreign-log owner every follow attempt fails, so every view stays in the
%% waiting set and the sweep bound is the only thing keeping attempts finite.
subscription_catalogue_retries_through_one_bounded_sweep_test_() ->
    {timeout, 60, fun() ->
    Previous = application:get_env(quod, subscription_follow_retry_ms),
    application:set_env(quod, subscription_follow_retry_ms, 200),
    F = setup_founded(<<>>),
    {_, Ns, _} = F,
    Targets = 40,
    try
        ok = wait_stats(Ns, fun(#{mode := live, subscriptions_active := 0}) -> true;
                               (_) -> false end),
        lists:foreach(
          fun(N) ->
              Fact = {subscribes, <<"private:sweep-", (integer_to_binary(N))/binary>>,
                      <<N:256>>},
              ?assertMatch({ok, _, _}, rp(Ns, {assertz, Fact}))
          end, lists:seq(1, Targets)),
        ok = wait_stats(
               Ns,
               fun(#{mode := live, subscriptions_active := Active,
                     source_views_active := Views})
                     when Active =:= Targets, Views =:= Targets -> true;
                  (_) -> false end),
        %% Every view is tracked and waiting, and one armed sweep serves them
        %% all. Its next turn attaches at most a batch rather than all forty,
        %% which is what keeps a large catalogue off a per-target timer.
        #{source_sweep_armed := Armed, source_attempts := Before} =
            quod_runtime:stats(Ns),
        ?assert(Armed),
        ok = wait_stats(
               Ns,
               fun(#{source_attempts := Now}) -> Now > Before;
                  (_) -> false end),
        #{source_attempts := After} = quod_runtime:stats(Ns),
        ?assert(After - Before =< 16),
        %% Removing the catalogue drops every view and disarms the lane.
        lists:foreach(
          fun(N) ->
              Fact = {subscribes, <<"private:sweep-", (integer_to_binary(N))/binary>>,
                      <<N:256>>},
              ?assertMatch({ok, _, _}, rp(Ns, {retract, Fact}))
          end, lists:seq(1, Targets)),
        ok = wait_stats(Ns, fun(#{mode := live, source_views_active := 0}) -> true;
                               (_) -> false end)
    after
        cleanup_founded(F),
        case Previous of
            {ok, Value} ->
                application:set_env(quod, subscription_follow_retry_ms, Value);
            undefined ->
                application:unset_env(quod, subscription_follow_retry_ms)
        end
    end
    end}.

%% A co-hosted target uses the same certified foreign-history cache and the
%% same committed reducer.  Runtime owns only its consumer reference/state.
local_subscription_reaches_one_shared_ready_projection_test_() ->
    {timeout, 60, fun() ->
    Target = setup_founded(<<>>),
    ForeignDir = temp_runtime_dir("foreign-follow"),
    {ForeignOwner, OwnForeignOwner} = ensure_foreign_owner(ForeignDir),
    Subscriber = setup_founded(<<>>),
    {_, TargetNs, _} = Target,
    {_, SubscriberNs, _} = Subscriber,
    try
        ok = wait_stats(TargetNs, fun(#{mode := live}) -> true; (_) -> false end),
        ok = wait_stats(SubscriberNs,
                        fun(#{mode := live}) -> true; (_) -> false end),
        Anchor = quod_simplex:genesis_hash(TargetNs),
        ?assertMatch(<<_:256>>, Anchor),
        ?assertMatch(
           {ok, _, _},
           rp(SubscriberNs, {assertz, {subscribes, TargetNs, Anchor}})),
        ok = wait_stats(
               SubscriberNs,
               fun(#{mode := live, subscriptions_active := 1,
                     source_views_active := 1,
                     source_views_ready := 1}) -> true;
                  (_) -> false
               end),
        FollowStats = quod_foreign_log:stats(),
        ?assertMatch(
           #{followed_histories := 1, follow_consumers := 1,
             projection_workers := 1, follow_building := 0,
             follow_unreachable := 0}, FollowStats),
        ?assert(maps:get(follow_pages, FollowStats) > 0),
        ?assert(maps:get(follow_entries, FollowStats) > 0),
        ?assert(maps:get(projection_rebuilds, FollowStats) > 0),
        ?assertMatch(
           {ok, _, _},
           rp(SubscriberNs, {retract, {subscribes, TargetNs, Anchor}})),
        ok = wait_stats(
               SubscriberNs,
               fun(#{subscriptions_active := 0, source_views_active := 0}) -> true;
                  (_) -> false
               end)
    after
        cleanup_founded(Subscriber),
        cleanup_founded(Target),
        stop_foreign_owner(ForeignOwner, OwnForeignOwner),
        _ = file:del_dir_r(ForeignDir)
    end
    end}.

%% The catalogue is P, not another status store: killing only the runtime loses
%% the in-memory list, and the supervisor rebuilds the identical list from D.
subscription_reconciles_after_runtime_restart_test_() ->
    {timeout, 60, fun() ->
    F = setup_founded(<<>>),
    {_, Ns, _} = F,
    Fact = {subscribes, <<"private:restart-target">>, <<12:256>>},
    try
        ok = wait_stats(Ns, fun(#{mode := live}) -> true; (_) -> false end),
        ?assertMatch({ok, _, _}, rp(Ns, {assertz, Fact})),
        ok = wait_stats(Ns, fun(#{mode := live, subscriptions_active := 1}) -> true;
                               (_) -> false end),
        Height = quod_prolog:applied(Ns),
        Runtime0 = quod_reg:where({quod_runtime, Ns}),
        ok = gen_server:stop(Runtime0),
        ok = wait_until(
               fun() ->
                       Runtime1 = quod_reg:where({quod_runtime, Ns}),
                       is_pid(Runtime1) andalso Runtime1 =/= Runtime0
                           andalso case quod_runtime:stats(Ns) of
                                       #{mode := live, subscriptions_active := 1} -> true;
                                       _ -> false
                                   end
               end),
        ?assertEqual(Height, quod_prolog:applied(Ns))
    after cleanup_founded(F) end
    end}.

%% A founding variable-bearing reaction survives different Erlog variable ids because the
%% one declaration gate compares alpha-normalized exact clauses. Slice 1 only indexes it.
founding_source_reaction_compiles_locally_test_() ->
    {timeout, 60, fun() ->
    TargetNs = <<"private:events">>,
    Anchor = <<9:256>>,
    Reaction =
        {react_on, {agent, {'Agent'}},
         {from, TargetNs, Anchor, {assert, {pose, {'Agent'}, {'Value'}}}},
         {notify, {'Agent'}, {'Value'}}},
    F = setup_founded_terms([Reaction]),
    {_, Ns, _} = F,
    try
        ok = wait_stats(
               Ns,
               fun(#{mode := live, reactions_active := 1,
                     source_targets_active := 1, source_interests_active := 1,
                     subscriptions_active := 0}) -> true;
                  (_) -> false
               end),
        %% No network/follower product exists in Slice 1: compiling an interest
        %% cannot create a subscription relation or mutate D.
        ?assertEqual(1, quod_prolog:applied(Ns))
    after cleanup_founded(F) end
    end}.

%% A derived Prolog answer is not a subscription declaration. Runtime reads exact clauses,
%% while the ordinary query engine remains free to prove the application rule.
derived_subscription_answer_is_not_runtime_vocabulary_test_() ->
    {timeout, 60, fun() ->
    TargetNs = <<"private:derived">>,
    Anchor = <<10:256>>,
    Enabled = {subscription_enabled, TargetNs, Anchor},
    Rule = {':-', {subscribes, TargetNs, Anchor}, Enabled},
    F = setup_founded_terms([Enabled, Rule]),
    {_, Ns, _} = F,
    try
        ok = wait_stats(Ns, fun(#{mode := live}) -> true; (_) -> false end),
        Stats = quod_runtime:stats(Ns),
        ?assertEqual(0, maps:get(subscriptions_active, Stats)),
        ?assertEqual(0, maps:get(rejected_subscriptions, Stats)),
        ?assertMatch({ok, _, _}, rp(Ns, {subscribes, TargetNs, Anchor}))
    after cleanup_founded(F) end
    end}.

%% A later writable reaction fact remains durable content but is inert until the one
%% can_declare_runtime authority exists. There is no reaction-only authorization shortcut.
dynamic_source_reaction_stays_inert_test_() ->
    {timeout, 60, fun() ->
    F = setup_founded(<<>>),
    {_, Ns, _} = F,
    TargetNs = <<"private:dynamic-reaction">>,
    Anchor = <<11:256>>,
    Reaction =
        {react_on, {agent, {'Agent'}},
         {from, TargetNs, Anchor, {assert, {pose, {'Agent'}}}},
         {notify, {'Agent'}}},
    try
        ok = wait_stats(Ns, fun(#{mode := live}) -> true; (_) -> false end),
        ?assertMatch({ok, _, _}, rp(Ns, {assertz, Reaction})),
        ok = wait_stats(
               Ns,
               fun(#{mode := live, reactions_active := 0,
                     source_interests_active := 0,
                     rejected_dynamic := Rejected}) -> Rejected >= 1;
                  (_) -> false
               end)
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
            ok = ae(
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

ensure_foreign_owner(Dir) ->
    case quod_reg:where({foreign_log, node}) of
        Pid when is_pid(Pid) -> {Pid, false};
        undefined ->
            {ok, Pid} = quod_foreign_log:start_link(
                          #{cache_dir => Dir, page_timeout_ms => 1000,
                            follow_poll_ms => 50,
                            follow_retry_ms => 10,
                            follow_max_retry_ms => 50}),
            {Pid, true}
    end.

stop_foreign_owner(_Pid, false) -> ok;
stop_foreign_owner(Pid, true) ->
    unlink(Pid),
    try gen_server:stop(Pid) catch exit:_ -> ok end.

temp_runtime_dir(Label) ->
    filename:join(
      "/tmp",
      Label ++ "_" ++
          integer_to_list(erlang:unique_integer([positive, monotonic]))).
