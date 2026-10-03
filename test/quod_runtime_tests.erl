-module(quod_runtime_tests).
-export([quod_predicate_module/0, load/1, test_resource_snapshot/3]).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").
-import(quod_ct, [rp/2, diff_for/1, change/2, batch/1, wait_until/1, wait_until/2]).

%%%===================================================================
%%% quod_runtime — current declarations and transaction ordering (pure core), the
%%% attach/reconcile lifecycle against a bare kb, and the real founded-namespace
%%% acceptance paths, shared subscriptions and owned resource lifecycles.
%%%===================================================================

reaction_clause(Pattern, Goal) ->
    {':-', {react_on, Pattern, Goal}, true}.

subscription_clause(Ns, Anchor) ->
    {{subscribes, Ns, Anchor}, {[], false}}.

ae(Ns, Index, Data, Origin) ->
    quod_prolog:apply_entry(
      Ns, quod_ct:committed_entry(Ns, Index, Data), Origin).

applied_fact_and_explicit_operations_are_reaction_events_test() ->
    Ops = [{assert, {{fact, 1}, {[], false}}},
           {asserta, {{front, 1}, {[], false}}},
           {retract, {{gone, 2}, {[], false}}},
           {assert, {{rule, {0}}, {[{other, {0}}], false}}},
           {event, {alarm, disk}},
           {event, {alarm, disk}}],
    ?assertEqual(
       [{assert, {fact, 1}}, {assert, {front, 1}}, {retract, {gone, 2}},
        {alarm, disk}, {alarm, disk}],
       quod_runtime_predicates:diff_to_events(Ops)).

alpha_normalization_preserves_reaction_bindings_test() ->
    A = reaction_clause(
          {from, <<"target">>, <<1:256>>,
           {assert, {pose, {name_a}, {value_a}}}},
          {notify, {name_a}, {value_a}}),
    B = reaction_clause(
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
    {ok, Plan} = quod_runtime:plan_runtime_catalog(Stored),
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
    {ok, Plan} = quod_runtime:plan_runtime_catalog(#{subscriptions => [Rule], reactions => []}),
    ?assertEqual([], maps:get(subscriptions, Plan)),
    ?assertEqual(0, maps:get(rejected_subscriptions, Plan)).

large_subscription_catalog_keeps_every_exact_identity_test() ->
    Clauses =
        [subscription_clause(
           <<"target:", (integer_to_binary(I))/binary>>, <<I:256>>)
         || I <- lists:seq(1, 1000)],
    {ok, Plan} = quod_runtime:plan_runtime_catalog(#{subscriptions => Clauses, reactions => []}),
    ?assertEqual(1000, length(maps:get(subscriptions, Plan))),
    ?assertEqual(0, maps:get(rejected_subscriptions, Plan)).

source_reaction_is_alpha_normalized_and_indexed_test() ->
    Ns = <<"target">>,
    Anchor = <<3:256>>,
    Stored = reaction_clause(
               {from, Ns, Anchor, {assert, {pose, {51}, {72}}}},
               {notify, {51}, {72}}),
    {ok, Plan} = quod_runtime:plan_runtime_catalog(#{subscriptions => [], reactions => [Stored]}),
    [Canonical] = maps:get(reactions, Plan),
    TargetIndex = maps:get({Ns, Anchor}, maps:get(source_interests, Plan)),
    ?assertEqual([Canonical], maps:get({assert, 1}, TargetIndex)),
    ?assert(is_map(Plan)).

local_reaction_has_no_remote_source_interest_test() ->
    Reaction = reaction_clause(
                 {assert, {service_ready, {service_name}, {payload}}},
                 {refresh_service, {service_name}, {payload}}),
    {ok, Plan} = quod_runtime:plan_runtime_catalog(#{subscriptions => [], reactions => [Reaction]}),
    ?assertEqual(1, length(maps:get(reactions, Plan))),
    ?assertEqual(#{}, maps:get(source_interests, Plan)).

explicit_event_reaction_is_a_local_catalogue_entry_test() ->
    Reaction = reaction_clause(
                 {alarm, {service_name}, {severity}},
                 {notify, {service_name}, {severity}}),
    {ok, Plan} = quod_runtime:plan_runtime_catalog(#{subscriptions => [], reactions => [Reaction]}),
    ?assertEqual(1, length(maps:get(reactions, Plan))),
    ?assertEqual(#{}, maps:get(source_interests, Plan)),
    Reserved = reaction_clause(
                 {from, one, two, three}, {notify, one}),
    ?assertMatch(
       {error, {invalid_reaction, _}},
       quod_runtime:plan_runtime_catalog(#{subscriptions => [], reactions => [Reserved]})).

current_reaction_preserves_authored_order_test() ->
    First = reaction_clause(ping, z_first),
    Second = reaction_clause(ping, a_second),
    {ok, Plan} = quod_runtime:plan_runtime_catalog(
      #{subscriptions => [], reactions => [First, Second]}),
    ?assertEqual([First, Second], maps:get(reactions, Plan)),
    ?assertEqual(maps:get(reactions, Plan), maps:get({ping, 0}, maps:get(reaction_index, Plan))).

ordinary_reaction_keeps_its_guard_and_variable_sharing_test() ->
    Clause = {':-', {react_on, {wake, {'Value'}}, {act, {'Me'}, {'Value'}}},
              {',', {me, {'Me'}}, {instance_of, worker, {'Me'}}}},
    {ok, Plan} = quod_runtime:plan_runtime_catalog(
                   #{subscriptions => [], reactions => [Clause]}),
    [Stored] = maps:get(reactions, Plan),
    ?assertEqual(quod_runtime:alpha_normalize(Clause), Stored),
    ?assertEqual([Stored], maps:get({wake, 1}, maps:get(reaction_index, Plan))).

reaction_goal_may_bind_its_own_result_variables_test() ->
    Clause = reaction_clause(ping, {record_identity, {'Identity'}}),
    ?assertMatch({ok, #{reactions := [_]}},
                 quod_runtime:plan_runtime_catalog(#{reactions => [Clause]})).

removed_reaction_is_absent_from_current_catalog_test() ->
    ?assertMatch({ok, #{reactions := []}},
                 quod_runtime:plan_runtime_catalog(#{subscriptions => [], reactions => []})).

transaction_catalog_changes_are_ordered_inside_one_block_test_() ->
    {timeout, 30, fun() ->
        F = {Ns, _, _} = setup_bare(),
        try
            ok = quod_prolog:mark_ready(Ns),
            ok = wait_stats(Ns, fun(#{mode := live}) -> true; (_) -> false end),
            Reaction = {react_on, {ping, {'Value'}},
                        {member, {'Value'}, [two, three]}},
            [Assert] = diff_for(Reaction),
            {assert, Clause} = Assert,
            Transactions = [change(Ns, [Assert, {event, {ping, one}}]),
                            change(Ns, [{event, {ping, two}}]),
                            change(Ns, [{retract, Clause}, {event, {ping, three}}]),
                            change(Ns, [{event, {ping, four}}])],
            true = quod_reg:subscribe({runtime, Ns}),
            trace_dispatch(Ns),
            ok = ae(Ns, 1, {batch, Transactions}, live),
            [await_route(Ns, {ping, Value}, Count)
             || {Value, Count} <- [{one, 0}, {two, 1}, {three, 1}, {four, 0}]],
            ok = wait_stats(Ns,
                fun(#{mode := live, reaction_candidates := 0, reactions_executed := 0,
                      reaction_failures := 0, reactions_active := 0,
                      events_seen := 4, e_frontier := 1,
                      runner_active := false, queue_len := 0}) -> true;
                   (_) -> false end),
            Catalogs = [receive {applied_live, #{ns := Ns, runtime_catalog := C}} -> C
                        after 1000 -> error(missing_transaction_envelope) end
                        || _ <- Transactions],
            ?assertMatch([{ok, #{reactions := [_]}}, keep,
                          {ok, #{reactions := []}}, keep], Catalogs),
            ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {react_on, {'_'}, {'_'}}))
        after quod_reg:unsubscribe({runtime, Ns}), cleanup_bare(F) end
    end}.

correcting_a_malformed_reaction_recovers_the_runtime_test_() ->
    {timeout, 30, fun() ->
        F = {Ns, _, _} = setup_bare(),
        try
            ok = quod_prolog:mark_ready(Ns),
            ok = wait_stats(Ns, fun(#{mode := live}) -> true; (_) -> false end),
            [Bad] = diff_for({react_on, {'UnboundPattern'}, true}),
            {assert, Clause} = Bad,
            ok = ae(Ns, 1, batch(change(Ns, [Bad])), live),
            ok = wait_stats(Ns, fun(#{mode := unhealthy}) -> true; (_) -> false end),
            ok = ae(Ns, 2, batch(change(Ns, [{retract, Clause}])), live),
            ok = wait_stats(Ns, fun(#{mode := live, height := 2, reactions_active := 0}) -> true;
                                   (_) -> false end)
        after cleanup_bare(F) end
    end}.

setup_bare() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"rt:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Kb} = quod_prolog:start_link(
                 Ns, #{node_id => {"127.0.0.1", 5000},
                       outcome_backend => memory}),
    {ok, Rt} = quod_runtime:start_link(Ns, #{node_id => <<82:256>>}),
    {Ns, Kb, Rt}.

cleanup_bare({_Ns, Kb, Rt}) ->
    stop_dispatch_trace(Rt),
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
               fun t_replay_cycle_reconciles_current_declarations/1,
               fun t_frontier_follows_and_no_history_leak/1]]}.

%% Booting until the KB ready edge, then install current declarations.
t_boot_edge_reconciles_to_live({Ns, _Kb, _Rt}) ->
    fun() ->
        ?assertEqual(booting, maps:get(mode, quod_runtime:stats(Ns))),
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := live, reconciles := R}) -> R >= 1;
                               (_) -> false end),
        ?assertEqual(0, maps:get(reactions_active, quod_runtime:stats(Ns)))
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
%% dynamically-written declaration is discovered and activated from current state
t_replay_cycle_reconciles_current_declarations({Ns, _Kb, _Rt}) ->
    fun() ->
        ok = quod_prolog:mark_ready(Ns),
        ok = wait_stats(Ns, fun(#{mode := M}) -> M =:= live; (_) -> false end),
        Dyn = {react_on, {wake, {'Value'}}, {remember, {'Value'}}},
        ok = ae(Ns, 1, batch(change(Ns, diff_for(Dyn))), live),
        %% open a replay run and close it with a live block: replay_ready fires
        ok = ae(Ns, 2, batch(change(Ns, diff_for({r, 2}))), replay),
        ok = ae(Ns, 3, batch(change(Ns, diff_for({r, 3}))), live),
        ok = wait_stats(Ns, fun(#{reconciles := R, reactions_active := D, mode := M}) ->
                                R =:= 2 andalso D =:= 1 andalso M =:= live;
                               (_) -> false end)
    end.

%% With no matching reactions the frontier follows every
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

zero_resource_notice_capacity_fails_once_test_() ->
    {timeout, 30, fun() ->
        {Ns, Kb, Old} = setup_bare(),
        ok = gen_server:stop(Old),
        {ok, Runtime} = quod_runtime:start_link(Ns, #{runtime_max_queued_events => 0}),
        try
            ok = quod_prolog:mark_ready(Ns),
            ok = wait_stats(Ns, fun(#{mode := unhealthy, reconciles := 1}) -> true;
                                   (_) -> false end),
            ok = ae(Ns, 1, batch(change(Ns, diff_for({still_committed, yes}))), live),
            ok = wait_stats(Ns, fun(#{mode := unhealthy, events_seen := Seen,
                                     reconciles := 1, runner_active := false, queue_len := 0}) ->
                                       Seen >= 1; (_) -> false end),
            ?assertEqual(1, quod_prolog:applied(Ns))
        after cleanup_bare({Ns, Kb, Runtime}) end
    end}.

%%%===================================================================
%%% real namespace acceptance (quod_ns, mode=create)
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

setup_founded_terms(Terms) -> setup_founded_terms(Terms, #{}).

setup_founded_terms(Terms, ExtraConfig) ->
    {ok, _} = application:ensure_all_started(gproc),
    U   = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_rt_terms_" ++ U),
    ok  = filelib:ensure_path(Dir),
    Ns  = list_to_binary("rtterms:" ++ U),
    {Pub, Seed} = quod_identity:generate(),
    Key = quod_identity:key_term({Pub, Seed}),
    Id  = #{pubkey => Pub, key => Key},
    Cfg = maps:merge(#{node_id => Pub, identity => Id, data_dir => Dir,
            mode => create, genesis_diff => quod_prolog:terms_to_diff(Terms)}, ExtraConfig),
    {ok, Sup} = quod_ns:start_link(Ns, Cfg),
    unlink(Sup),
    {Dir, Ns, Sup}.

setup_founded_terms_with_identity(TermsFun) ->
    {ok, _} = application:ensure_all_started(gproc),
    U = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_rt_identity_terms_" ++ U),
    ok = filelib:ensure_path(Dir),
    Ns = list_to_binary("rtidentity:" ++ U),
    {Pub, Seed} = quod_identity:generate(),
    Key = quod_identity:key_term({Pub, Seed}),
    Id = #{pubkey => Pub, key => Key},
    Terms = TermsFun(Pub),
    Cfg = #{node_id => Pub, identity => Id, data_dir => Dir,
            mode => create, genesis_diff => quod_prolog:terms_to_diff(Terms)},
    {ok, Sup} = quod_ns:start_link(Ns, Cfg),
    unlink(Sup),
    {Dir, Ns, Sup}.

setup_founded_terms_on_node(Terms, Identity) ->
    setup_founded_terms_on_node_with_identity(fun(_Self) -> Terms end, Identity).

setup_founded_terms_on_node_with_identity(TermsFun, Identity) ->
    {ok, _} = application:ensure_all_started(gproc),
    U = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_rt_node_terms_" ++ U),
    ok = filelib:ensure_path(Dir),
    Ns = list_to_binary("rtnode:" ++ U),
    Pub = maps:get(pubkey, Identity),
    Terms = TermsFun(Pub),
    Cfg = #{node_id => Pub, identity => Identity, data_dir => Dir,
            mode => create, genesis_diff => quod_prolog:terms_to_diff(Terms)},
    {ok, Sup} = quod_ns:start_link(Ns, Cfg),
    unlink(Sup),
    {Dir, Ns, Sup}.

cleanup_founded({Dir, Ns, _Sup}) ->
    stop_dispatch_trace(quod_reg:where({quod_runtime, Ns})),
    case quod_reg:where({quod_ns, Ns}) of
        undefined -> ok;
        Pid -> Ref = monitor(process, Pid),
               exit(Pid, shutdown),
               receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end
    end,
    _ = file:del_dir_r(Dir),
    ok.

restore_env(Key, {ok, Value}) -> application:set_env(quod, Key, Value);
restore_env(Key, undefined) -> application:unset_env(quod, Key).

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

%% Missing local ownership parks every durable subscription without a timer.
%% The one gproc name-follow edge from the replacement owner then attaches the
%% complete catalogue through mailbox turns. Forty is deliberately above the
%% deleted sweep's batch of sixteen: this test would leave most rows waiting on
%% the old bounded pass, while the message-driven path attaches all of them.
subscription_catalogue_attaches_on_foreign_owner_registration_test_() ->
    {timeout, 60, fun() ->
    F = setup_founded(<<>>),
    {_, Ns, _} = F,
    ForeignDir = temp_runtime_dir("foreign-owner-registration"),
    Targets = 40,
    stop_route_owners(),
    {ok, Directory} = quod_directory:start_link(
                        #{expire_tick_ms => 60000, ttl_ms => 10000}),
    {ok, DirectoryControl} = quod_directory_control:start_link(#{}),
    try
        ?assertEqual(undefined, quod_reg:where({foreign_log, node})),
        ok = wait_stats(Ns, fun(#{mode := live, subscriptions_active := 0}) -> true;
                               (_) -> false end),
        lists:foreach(
          fun(N) ->
              Fact = {subscribes, <<"private:attach-", (integer_to_binary(N))/binary>>,
                      <<N:256>>},
              ?assertMatch({ok, _, _}, rp(Ns, {assertz, Fact}))
          end, lists:seq(1, Targets)),
        ok = wait_stats(
               Ns,
               fun(#{mode := live, subscriptions_active := Active,
                     source_views_active := Views})
                     when Active =:= Targets, Views =:= Targets -> true;
                  (_) -> false end),
        #{source_attempts := Before} = quod_runtime:stats(Ns),
        {ok, ForeignOwner} = quod_foreign_log:start_link(
                               #{cache_dir => ForeignDir,
                                 page_timeout_ms => 1000}),
        try
            ok = wait_until(
                   fun() ->
                           case quod_foreign_log:stats() of
                               #{followed_histories := Targets,
                                 follow_consumers := Targets} -> true;
                               _ -> false
                           end
                   end),
            ok = wait_stats(
                   Ns,
                   fun(#{source_attempts := After,
                         source_attach_queued := 0})
                         when After >= Before + Targets -> true;
                      (_) -> false
                   end),
            %% Subscription attachment reaches the same exact demand owner as
            %% proofs, joins and DTX verification; no subscription-only route
            %% registry or retry loop exists.
            ok = wait_until(
                   fun() ->
                       case quod_directory_control:stats() of
                           #{route_demands := Targets,
                             route_demanded := Targets} -> true;
                           _ -> false
                       end
                   end),
            %% Removing the catalogue drops every exact consumer and the
            %% name-follow monitor; no delayed timer may recreate either.
            lists:foreach(
              fun(N) ->
                  Fact = {subscribes,
                          <<"private:attach-", (integer_to_binary(N))/binary>>,
                          <<N:256>>},
                  ?assertMatch({ok, _, _}, rp(Ns, {retract, Fact}))
              end, lists:seq(1, Targets)),
            ok = wait_stats(
                   Ns,
                   fun(#{mode := live, source_views_active := 0,
                         source_attach_queued := 0}) -> true;
                      (_) -> false
                   end),
            ?assertMatch(#{follow_consumers := 0}, quod_foreign_log:stats())
        after
            stop_foreign_owner(ForeignOwner, true)
        end
    after
        cleanup_founded(F),
        catch gen_server:stop(DirectoryControl),
        catch gen_server:stop(Directory),
        stop_route_owners(),
        _ = file:del_dir_r(ForeignDir)
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

%% Baseline materialization is state only. Only a later contiguous certified
%% advance selects the matching authored clause, with its exact source wrapper.
%% These unhosted fixtures may route candidates but cannot borrow node authority.
subscribed_reaction_routes_live_certified_advance_once_test_() ->
    {timeout, 90, fun() ->
    Target = setup_founded_terms([{remote_ping, old}]),
    {_, TargetNs, _} = Target,
    Anchor = quod_simplex:genesis_hash(TargetNs),
    ForeignDir = temp_runtime_dir("foreign-reaction"),
    {ForeignOwner, OwnForeignOwner} = ensure_foreign_owner(ForeignDir),
    Subscriber = setup_founded_terms_with_identity(
                   fun(_Self) ->
                           [{subscribes, TargetNs, Anchor},
                            {react_on,
                             {from, TargetNs, Anchor,
                              {assert, {remote_ping, {'Value'}}}},
                             {member, {'Value'},
                              [fresh, fresh_after_restart,
                               fresh_after_cache_rebuild]}}]
                   end),
    {_, SubscriberNs, _} = Subscriber,
    try
        ok = wait_stats(
               SubscriberNs,
               fun(#{mode := live, subscriptions_active := 1,
                     source_views_ready := 1,
                     reactions_executed := 0,
                     reaction_candidates := 0}) -> true;
                  (_) -> false
               end),
        %% Only the exact owner-issued FollowRef may enter the queue. A forged
        %% but otherwise well-shaped notice is ignored before its payload is
        %% interpreted and cannot disturb the real follow that succeeds next.
        RuntimePid = quod_reg:where({quod_runtime, SubscriberNs}),
        RuntimePid !
            {quod_foreign_follow, make_ref(), make_ref(), {TargetNs, Anchor},
             {advanced, 1, 2, <<99:256>>, #{}, [],
              [{2, [{assert, {{remote_ping, forged}, {[], false}}}]}]}},
        ForgedStats = quod_runtime:stats(SubscriberNs),
        ?assertEqual(0, maps:get(reaction_candidates, ForgedStats)),
        ?assertEqual(0, maps:get(reactions_executed, ForgedStats)),
        %% Inspect the real dispatcher without inventing a hosted principal.
        %% Signed execution of these candidates is covered by agent_reaction_tests.
        trace_dispatch(SubscriberNs),
        ?assertMatch({ok, _, _}, rp(TargetNs, {assertz, {remote_ping, fresh}})),
        await_route(SubscriberNs, {from, TargetNs, Anchor, {assert, {remote_ping, fresh}}}, 1),
        await_source_processed(SubscriberNs),
        ok = wait_stats(
               SubscriberNs,
               fun(#{reaction_candidates := 0, reaction_matches := 0,
                     reactions_executed := 0, reaction_failures := 0}) -> true;
                  (_) -> false
               end),
        assert_no_route(SubscriberNs),
        %% The canonical reducer suppresses this duplicate; the follower cannot
        %% manufacture a second occurrence from the requested diff.
        #{follow_entries := FollowedBefore} = quod_foreign_log:stats(),
        ?assertMatch({ok, _, _}, rp(TargetNs, {assertz, {remote_ping, fresh}})),
        ok = wait_until(
               fun() ->
                       case quod_foreign_log:stats() of
                           #{follow_entries := Followed}
                             when Followed > FollowedBefore -> true;
                           _ -> false
                       end
               end),
        await_source_processed(SubscriberNs),
        assert_no_route(SubscriberNs),
        Stats = quod_runtime:stats(SubscriberNs),
        ?assertEqual(0, maps:get(reaction_candidates, Stats)),
        ?assertEqual(0, maps:get(reactions_executed, Stats)),

        %% A runtime restart reattaches to the current certified projection as
        %% a state baseline. It must not replay the already observed event.
        Runtime0 = quod_reg:where({quod_runtime, SubscriberNs}),
        ok = gen_server:stop(Runtime0),
        ok = wait_until(
               fun() ->
                       Runtime1 = quod_reg:where({quod_runtime, SubscriberNs}),
                       is_pid(Runtime1) andalso Runtime1 =/= Runtime0
                           andalso case quod_runtime:stats(SubscriberNs) of
                                       #{mode := live, source_views_ready := 1,
                                         reaction_candidates := 0,
                                         reactions_executed := 0} -> true;
                                       _ -> false
                                   end
               end),
        trace_dispatch(SubscriberNs),
        assert_no_route(SubscriberNs),
        ?assertMatch(
           {ok, _, _},
           rp(TargetNs, {assertz, {remote_ping, fresh_after_restart}})),
        await_route(SubscriberNs, {from, TargetNs, Anchor,
                                  {assert, {remote_ping, fresh_after_restart}}}, 1),
        await_source_processed(SubscriberNs),
        ok = wait_stats(
               SubscriberNs,
               fun(#{reaction_candidates := 0, reaction_matches := 0,
                     reactions_executed := 0}) -> true;
                  (_) -> false
               end),

        %% Rebuilding the node-wide owner and materializer from certified cache
        %% is also a baseline, not history replay.
        true = OwnForeignOwner,
        #{source_attempts := AttemptsBeforeRebuild} =
            quod_runtime:stats(SubscriberNs),
        stop_foreign_owner(ForeignOwner, true),
        {ok, RebuiltOwner} = quod_foreign_log:start_link(
                               #{cache_dir => ForeignDir,
                                 page_timeout_ms => 1000}),
        try
            ok = wait_stats(
                   SubscriberNs,
                   fun(#{source_views_ready := 1,
                         source_attempts := Attempts,
                         reaction_candidates := 0,
                         reactions_executed := 0})
                         when Attempts > AttemptsBeforeRebuild -> true;
                      (_) -> false
                   end),
            trace_dispatch(SubscriberNs),
            ?assertMatch(
               {ok, _, _},
               rp(TargetNs,
                  {assertz, {remote_ping, fresh_after_cache_rebuild}})),
            await_route(SubscriberNs, {from, TargetNs, Anchor,
                                      {assert, {remote_ping, fresh_after_cache_rebuild}}}, 1),
            await_source_processed(SubscriberNs),
            ok = wait_stats(
                   SubscriberNs,
                   fun(#{reaction_candidates := 0, reaction_matches := 0,
                         reactions_executed := 0}) -> true;
                      (_) -> false
                   end)
        after
            stop_foreign_owner(RebuiltOwner, true)
        end
    after
        cleanup_founded(Subscriber),
        cleanup_founded(Target),
        stop_foreign_owner(ForeignOwner, OwnForeignOwner),
        _ = file:del_dir_r(ForeignDir)
    end
    end}.

%% A local catalogue change and a remote occurrence share one ordered fold.
%% If the local block removes the subscription first, the later queued remote
%% item is dropped even though the batch began with that subscription active.
subscription_retraction_precedes_later_queued_remote_reaction_test() ->
    TargetNs = <<"private:queued-target">>,
    Anchor = <<81:256>>,
    Identity = {TargetNs, Anchor},
    Reaction =
        {react_on,
         {from, TargetNs, Anchor, {assert, {remote_ping, {'Value'}}}},
         {member, {'Value'}, [must_not_run]}},
    ReactionClause = reaction_clause(
                       element(2, Reaction), element(3, Reaction)),
    SubscriptionClause = subscription_clause(TargetNs, Anchor),
    {ok, Plan} = quod_runtime:plan_runtime_catalog(#{subscriptions => [SubscriptionClause],
                     reactions => [ReactionClause]}),
    with_reaction_est(
      [Reaction],
      fun(EstAfterRetraction) ->
              Work =
                  [{local, 2, EstAfterRetraction,
                    [{subscribes, TargetNs, Anchor}], [], [],
                    {ok, #{subscriptions => [], reactions => [ReactionClause]}}},
                   {remote, make_ref(), make_ref(), Identity,
                    [{2, [{assert,
                           {{remote_ping, must_not_run}, {[], false}}}]}]}],
              ?assertMatch(
                 {ok, 2, _, [], #{subscriptions := []},
                  #{candidates := 0, executed := 0, dropped := 1}, _},
                 quod_runtime:test_run_events(
                   Work, Plan, 1,
                   EstAfterRetraction))
      end).

%% A participant's event-only plan becomes visible only through atomic Resolve.
%% Vote and Complete are silent; the certified follower
%% exposes the explicit occurrence once, through the normal reaction path,
%% without creating a fact or adding DTX-specific dispatch.
subscribed_reaction_observes_event_only_atomic_resolve_once_test_() ->
    {timeout, 90, fun() ->
    %% Applied votes are bound to the root anchor. These standalone namespace
    %% fixtures deliberately do not start quod:root, so install that one piece
    %% of network configuration while exercising the real DTX path.
    quod_ct:with_network_identity(
      crypto:strong_rand_bytes(32),
      fun() ->
    PreviousPub = application:get_env(quod, node_pubkey),
    PreviousKey = application:get_env(quod, identity_key),
    {NodePub, NodeSeed} = quod_identity:generate(),
    NodeKey = quod_identity:key_term({NodePub, NodeSeed}),
    NodeIdentity = #{pubkey => NodePub, key => NodeKey},
    application:set_env(quod, node_pubkey, NodePub),
    application:set_env(quod, identity_key, NodeKey),
    Target = setup_founded_terms_on_node([], NodeIdentity),
    Other = setup_founded_terms_on_node(
              [{can_invoke, {'Goal'}, {'Principal'}, {'Chain'}, {'Ns'}}],
              NodeIdentity),
    {_, TargetNs, _} = Target,
    {_, OtherNs, _} = Other,
    Anchor = quod_simplex:genesis_hash(TargetNs),
    ForeignDir = temp_runtime_dir("foreign-reaction-dtx"),
    {ForeignOwner, OwnForeignOwner} = ensure_foreign_owner(ForeignDir),
    Subscriber = setup_founded_terms_on_node_with_identity(
                   fun(_Self) ->
                           [{subscribes, TargetNs, Anchor},
                            {react_on,
                             {from, TargetNs, Anchor,
                              {dtx_remote_ping, {'Value'}}},
                             {member, {'Value'}, [committed_once]}}]
                   end, NodeIdentity),
    {_, SubscriberNs, _} = Subscriber,
    try
        ok = wait_stats(
               SubscriberNs,
               fun(#{mode := live, source_views_ready := 1,
                     reaction_candidates := 0,
                     reactions_executed := 0}) -> true;
                  (_) -> false
               end),
        trace_dispatch(SubscriberNs),
        Goal =
            {',', {trigger_event, {dtx_remote_ping, committed_once}},
             {'::', OtherNs,
              {assertz, {dtx_other_marker, committed_once}}}},
        ?assertMatch(
           {ok, [_],
            #{ref := {group, _, _, _, _, _}, participant_slots := [_, _]}},
           rp(TargetNs, Goal)),
        await_route(SubscriberNs, {from, TargetNs, Anchor, {dtx_remote_ping, committed_once}}, 1),
        await_source_processed(SubscriberNs),
        assert_no_route(SubscriberNs),
        ok = wait_stats(
               SubscriberNs,
               fun(#{reaction_candidates := 0, reaction_matches := 0,
                     reactions_executed := 0, reaction_failures := 0}) -> true;
                  (_) -> false
               end),
        ?assertMatch({fail, _}, quod_prolog:prove(
                                  TargetNs,
                                  {dtx_remote_ping, committed_once})),
        ?assertMatch({ok, _, _}, rp(OtherNs,
                                     {dtx_other_marker, committed_once})),
        Stats = quod_runtime:stats(SubscriberNs),
        ?assertEqual(0, maps:get(reaction_candidates, Stats)),
        ?assertEqual(0, maps:get(reactions_executed, Stats))
    after
        cleanup_founded(Subscriber),
        cleanup_founded(Other),
        cleanup_founded(Target),
        stop_foreign_owner(ForeignOwner, OwnForeignOwner),
        _ = file:del_dir_r(ForeignDir),
        restore_env(node_pubkey, PreviousPub),
        restore_env(identity_key, PreviousKey)
    end
    end)
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

%% A stored variable-bearing reaction survives different Erlog variable ids because the
%% one declaration gate compares alpha-normalized exact clauses. An interest alone does not
%% create a follow; the durable subscribes/2 fact remains independently required.
founding_source_reaction_compiles_locally_test_() ->
    {timeout, 60, fun() ->
    TargetNs = <<"private:events">>,
    Anchor = <<9:256>>,
    Reaction =
        {react_on,
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
        %% Compiling an interest cannot create a subscription relation, follow,
        %% or D mutation.
        ?assertEqual(1, quod_prolog:applied(Ns))
    after cleanup_founded(F) end
    end}.

local_reaction_routes_only_applied_ops_test_() ->
    {timeout, 60, fun() ->
    F = setup_founded_terms_with_identity(
          fun(_Self) ->
                  [{':-', {reaction_accept, one}, {reaction_ping, one}},
                   {react_on,
                    {assert, {reaction_ping, {'Value'}}},
                    {reaction_accept, {'Value'}}}]
          end),
    {_, Ns, _} = F,
    try
        ok = wait_stats(
               Ns,
               fun(#{mode := live, reactions_active := 1,
                     reactions_executed := 0}) -> true;
                  (_) -> false
               end),
        trace_dispatch(Ns),
        ?assertMatch({ok, _, _}, rp(Ns, {assertz, {reaction_ping, one}})),
        await_route(Ns, {assert, {reaction_ping, one}}, 1),
        ok = wait_stats(
               Ns,
               fun(#{reaction_candidates := 0, reaction_matches := 0,
                     reactions_executed := 0, reaction_failures := 0}) -> true;
                  (_) -> false
               end),
        %% Both transactions commit, but the canonical reducer reports no
        %% applied operation, so neither may manufacture a second occurrence.
        ?assertMatch({ok, _, _}, rp(Ns, {assertz, {reaction_ping, one}})),
        Applied = quod_prolog:applied(Ns),
        ok = wait_stats(
               Ns,
               fun(#{e_frontier := Frontier}) -> Frontier >= Applied;
                  (_) -> false
               end),
        assert_no_route(Ns),
        Stats = quod_runtime:stats(Ns),
        ?assertEqual(0, maps:get(reaction_candidates, Stats)),
        ?assertEqual(0, maps:get(reactions_executed, Stats)),
        %% A second occurrence is routed too, but this ontology has no hosted
        %% agent. Domain events must not borrow the physical node authority.
        ?assertMatch({ok, _, _}, rp(Ns, {assertz, {reaction_ping, two}})),
        await_route(Ns, {assert, {reaction_ping, two}}, 1),
        ok = wait_stats(
               Ns,
               fun(#{mode := live, reaction_candidates := 0,
                     reaction_matches := 0, reactions_executed := 0,
                     reaction_failures := 0}) -> true;
                  (_) -> false
               end)
    after cleanup_founded(F) end
    end}.

local_explicit_event_repeats_without_mutating_facts_test_() ->
    {timeout, 60, fun() ->
    F = setup_founded_terms_with_identity(
          fun(_Self) ->
                  [{react_on,
                    {alarm, {'Level'}},
                    {member, {'Level'}, [critical]}}]
          end),
    {_, Ns, _} = F,
    try
        ok = wait_stats(
               Ns,
               fun(#{mode := live, reactions_active := 1,
                     reactions_executed := 0}) -> true;
                  (_) -> false
               end),
        trace_dispatch(Ns),
        ?assertMatch({ok, _, _}, rp(Ns, {trigger_event, {alarm, critical}})),
        await_route(Ns, {alarm, critical}, 1),
        ok = wait_stats(
               Ns,
               fun(#{reaction_candidates := 0, reaction_matches := 0,
                     reactions_executed := 0}) -> true;
                  (_) -> false
               end),
        trace_dispatch(Ns),
        ?assertMatch({ok, _, _}, rp(Ns, {trigger_event, {alarm, critical}})),
        await_route(Ns, {alarm, critical}, 1),
        ok = wait_stats(
               Ns,
               fun(#{reaction_candidates := 0, reaction_matches := 0,
                     reactions_executed := 0}) -> true;
                  (_) -> false
               end),
        ?assertMatch({fail, _}, quod_prolog:prove(Ns, {alarm, critical}))
    after cleanup_founded(F) end
    end}.

reaction_removal_takes_effect_after_its_transaction_test_() ->
    {timeout, 60, fun() ->
    Reaction =
        {react_on,
         {assert, {reaction_ping, one}}, reaction_accept},
    F = setup_founded_terms_with_identity(
          fun(_Self) ->
                  [reaction_accept,
                   Reaction]
          end),
    {_, Ns, _} = F,
    try
        ok = wait_stats(
               Ns,
               fun(#{mode := live, reactions_active := 1,
                     reactions_executed := 0}) -> true;
                  (_) -> false
               end),
        %% T matches its events before its declaration removal becomes active.
        Goal = {',', {retract, Reaction},
                     {assertz, {reaction_ping, one}}},
        trace_dispatch(Ns),
        ?assertMatch({ok, _, _}, rp(Ns, Goal)),
        await_route(Ns, {assert, {reaction_ping, one}}, 1),
        ok = wait_stats(
               Ns,
               fun(#{mode := live, reactions_active := 0, reactions_executed := 0}) -> true;
                  (_) -> false
               end)
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

%% Later committed declarations activate under the ordinary ontology authority.
%% Trace measurements run in fresh EUnit processes: suite callers may retain
%% unrelated earlier trace messages. The observed functions and zero-IO checks
%% remain the same for both isolated measurement fixtures.
dynamic_source_reaction_activates_test_() ->
    {spawn, {timeout, 60, fun() ->
    F = setup_founded(<<>>),
    {_, Ns, Sup} = F,
    TargetNs = <<"private:dynamic-reaction">>,
    Anchor = <<11:256>>,
    Reaction =
        {react_on,
         {from, TargetNs, Anchor, {assert, {pose, {'Agent'}}}},
         {notify, {'Agent'}}},
    try
        ok = wait_stats(Ns, fun(#{mode := live}) -> true; (_) -> false end),
        ?assertMatch({ok, _, _}, rp(Ns, {assertz, Reaction})),
        ok = wait_stats(
               Ns,
               fun(#{mode := live, reactions_active := 1,
                     source_interests_active := 1}) -> true;
                  (_) -> false
               end),
        %% A runtime restart restores current declarations, including edits
        %% after genesis, without a ledger read or a historical reaction.
        Runtime = quod_reg:where({quod_runtime, Ns}),
        Engine = quod_reg:where({quod_prolog, Ns}),
        Height = quod_prolog:applied(Ns),
        MFAs = [{quod_simplex, history_view, 3},
                {quod_ledger_store, open_ro_snapshot, 1},
                {quod_ledger_store, read_at, 2},
                {file, sync, 1}, {file, datasync, 1}],
        [erlang:trace_pattern(MFA, true, [local]) || MFA <- MFAs],
        _ = erlang:trace(Sup, true, [call, set_on_spawn]),
        try
            ok = gen_server:stop(Runtime),
            ok = wait_until(fun() ->
                New = quod_reg:where({quod_runtime, Ns}),
                New =/= undefined andalso New =/= Runtime andalso
                maps:get(mode, quod_runtime:stats(Ns), booting) =:= live
            end),
            ?assertMatch(#{reactions_active := 1, source_interests_active := 1,
                           reactions_executed := 0}, quod_runtime:stats(Ns)),
            ?assertEqual(Engine, quod_reg:where({quod_prolog, Ns})),
            ?assertEqual(Height, quod_prolog:applied(Ns)),
            Reconciles = maps:get(reconciles, quod_runtime:stats(Ns)),
            quod_runtime:reconcile_now(Ns),
            ok = wait_stats(Ns, fun(#{mode := live, queue_len := 0, runner_active := false}) -> true;
                                   (_) -> false end),
            ?assertEqual(Reconciles, maps:get(reconciles, quod_runtime:stats(Ns))),
            Barrier = erlang:trace_delivered(all),
            receive {trace_delivered, all, Barrier} -> ok
            after 1000 -> error(missing_runtime_trace_barrier) end,
            receive
                {trace, _, call, {M, Function, Args}} ->
                    error({unexpected_runtime_io, {M, Function, length(Args)}})
            after 0 -> ok end
        after
            _ = erlang:trace(Sup, false, [call, set_on_spawn]),
            [erlang:trace_pattern(MFA, false, [local]) || MFA <- MFAs]
        end
    after cleanup_founded(F) end
    end}}.

%%% Owned resource requests select only the retained committed snapshot.

resource_minimum_height_advances_without_material_events_test_() ->
    {timeout, 60, fun() -> with_resource_fixture(fun(Ns, _Sup) ->
        H = quod_prolog:applied(Ns),
        Before = quod_runtime:stats(Ns),
        {Caller, Ref} = resource_request(Ns, H + 1, read),
        %% A stale-incarnation or already-consumed progress notice cannot
        %% replace the reader's snapshot, even while a newer height is needed.
        Runtime = quod_reg:where({quod_runtime, Ns}),
        Runtime ! {runtime_snapshot_advanced, self(), H + 10, invalid_snapshot},
        Runtime ! {runtime_snapshot_advanced, quod_reg:where({quod_prolog, Ns}), H, invalid_snapshot},
        ?assertEqual(H, maps:get(height, quod_runtime:stats(Ns))),
        %% A rejected write advances the canonical read floor with no applied
        %% domain occurrence. DTX control-only blocks have this same boundary.
        Stale = quod_ct:change(Ns, diff_for(must_not_apply),
                               #{{resource_value, 1} => never_present}),
        ok = ae(Ns, H + 1, batch(Stale), live),
        {_, Height, initial} = resource_snapshot(),
        ?assertEqual(H + 1, Height),
        ?assertEqual(ok, resource_reply(Caller, Ref)),
        After = quod_runtime:stats(Ns),
        [ ?assertEqual(maps:get(Key, Before), maps:get(Key, After))
          || Key <- [events_seen, reaction_candidates, reactions_executed, reconciles] ]
    end) end}.

resource_minimum_height_and_unchanged_repeats_test_() ->
    {spawn, {timeout, 60, fun() -> with_resource_fixture(fun(Ns, Sup) ->
        H = quod_prolog:applied(Ns),
        {Caller, Ref} = resource_request(Ns, H + 1, read),
        ok = wait_stats(Ns, fun(#{queue_len := N}) -> N >= 1; (_) -> false end),
        receive {resource_snapshot, _, _, _} -> error(selected_before_required_commit)
        after 0 -> ok end,
        ?assertMatch({ok, _, _}, rp(Ns, {',', {retract, {resource_value, initial}},
                                            {assertz, {resource_value, updated}}})),
        {_, Height, updated} = resource_snapshot(),
        ?assert(Height >= H + 1),
        ?assertEqual(ok, resource_reply(Caller, Ref)),
        Runtime = quod_reg:where({quod_runtime, Ns}),
        MFAs = [{quod_simplex, history_view, 3}, {quod_ledger_store, open_ro_snapshot, 1},
                {quod_ledger_store, read_at, 2}, {file, sync, 1}, {file, datasync, 1}],
        [erlang:trace_pattern(MFA, true, [local]) || MFA <- MFAs],
        erlang:trace(Runtime, true, [call, set_on_spawn]),
        erlang:trace(Sup, true, [call, set_on_spawn]),
        try
            [begin
                {P, R} = resource_request(Ns, Height, read),
                {_, Height, updated} = resource_snapshot(),
                ?assertEqual(ok, resource_reply(P, R))
             end || _ <- lists:seq(1, 3)],
            Barrier = erlang:trace_delivered(all),
            receive {trace_delivered, all, Barrier} -> ok after 1000 -> error(trace_barrier) end,
            receive {trace, _, call, MFA} -> error({unchanged_resource_io, MFA})
            after 0 -> ok end
        after
            erlang:trace(Runtime, false, [call, set_on_spawn]),
            erlang:trace(Sup, false, [call, set_on_spawn]),
            [erlang:trace_pattern(MFA, false, [local]) || MFA <- MFAs]
        end
    end) end}}.

failed_resource_is_not_installed_by_later_events_test_() ->
    {timeout, 60, fun() -> with_resource_fixture(fun(Ns, _Sup) ->
        H = quod_prolog:applied(Ns),
        ?assertMatch({error, {resource_selection_failed, _}},
                     quod_runtime:reconcile_resource(Ns, H, agent_hosts, fail,
                                                     quod_time:mono_ms() + 5000)),
        ?assertMatch({error, {resource_selection_failed, _}},
                     quod_runtime:reconcile_resource(Ns, H, agent_hosts, write,
                                                     quod_time:mono_ms() + 5000)),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, illegal_selector_write)),
        ?assertMatch({ok, _, _}, rp(Ns, {assertz, unrelated})),
        ok = wait_stats(Ns, fun(#{height := Height, runner_active := false, queue_len := 0}) ->
                                    Height > H; (_) -> false end),
        ?assertMatch({_, []}, quod_runtime:agents(Ns)),
        ?assertEqual({error, stale_resource_owner}, quod_runtime:project_agents(Ns, all, [])),
        {Caller, Ref} = resource_request(Ns, H + 1, read),
        {_, _, initial} = resource_snapshot(),
        ?assertEqual(ok, resource_reply(Caller, Ref))
    end) end}.

resource_caller_death_reaps_its_reader_test_() ->
    {timeout, 60, fun() -> with_resource_fixture(fun(Ns, _Sup) ->
        {Caller, Ref} = resource_request(Ns, quod_prolog:applied(Ns), block),
        {Reader, _, initial} = resource_snapshot(),
        Monitor = monitor(process, Reader),
        exit(Caller, kill),
        await_reader_down(Monitor, Reader),
        receive {'DOWN', Ref, process, Caller, killed} -> ok after 5000 -> error(caller_alive) end,
        ok = wait_stats(Ns, fun(#{runner_active := false, queue_len := 0}) -> true; (_) -> false end)
    end) end}.

runtime_owner_death_reaps_reader_and_recovers_current_state_test_() ->
    {timeout, 60, fun() -> with_resource_fixture(fun(Ns, _Sup) ->
        Runtime = quod_reg:where({quod_runtime, Ns}),
        Engine = quod_reg:where({quod_prolog, Ns}),
        {Caller, Ref} = resource_request(Ns, quod_prolog:applied(Ns), block),
        {Reader, _, initial} = resource_snapshot(),
        Monitor = monitor(process, Reader),
        ok = gen_server:stop(Runtime),
        await_reader_down(Monitor, Reader),
        ?assertEqual({error, runtime_recovering}, resource_reply(Caller, Ref)),
        ok = wait_until(fun() ->
            New = quod_reg:where({quod_runtime, Ns}),
            is_pid(New) andalso New =/= Runtime andalso
            maps:get(mode, quod_runtime:stats(Ns), booting) =:= live
        end),
        ?assertEqual(Engine, quod_reg:where({quod_prolog, Ns})),
        {Next, NextRef} = resource_request(Ns, quod_prolog:applied(Ns), read),
        {_, _, initial} = resource_snapshot(),
        ?assertEqual(ok, resource_reply(Next, NextRef))
    end) end}.

replay_quiesces_resource_snapshot_reader_test_() ->
    {timeout, 60, fun() -> with_resource_fixture(fun(Ns, _Sup) ->
        H = quod_prolog:applied(Ns),
        {Caller, Ref} = resource_request(Ns, H, block),
        {Reader, H, initial} = resource_snapshot(),
        Monitor = monitor(process, Reader),
        ok = ae(Ns, H + 1, batch(change(Ns, diff_for({during_replay, 1}))), replay),
        ok = quod_prolog:mark_ready(Ns),
        await_reader_down(Monitor, Reader),
        ?assertEqual({error, runtime_recovering}, resource_reply(Caller, Ref)),
        ok = wait_stats(Ns, fun(#{mode := live, height := Height, runner_active := false}) ->
                                   Height =:= H + 1; (_) -> false end),
        ?assertEqual(H + 1, quod_prolog:applied(Ns))
    end) end}.

ready_boundary_waits_for_resource_snapshot_reader_test_() ->
    {timeout, 60, fun() -> with_resource_fixture(fun(Ns, _Sup) ->
        H = quod_prolog:applied(Ns),
        R0 = maps:get(reconciles, quod_runtime:stats(Ns)),
        {Caller, Ref} = resource_request(Ns, H, block),
        {Reader, H, initial} = resource_snapshot(),
        Monitor = monitor(process, Reader),
        quod_reg:where({quod_runtime, Ns}) ! {replay_ready, {boundary, make_ref()}, H},
        %% This call is processed after the ready message. The old reader still
        %% pins its snapshot; replacement cannot occur until it finishes.
        ?assertEqual(R0, maps:get(reconciles, quod_runtime:stats(Ns))),
        ?assert(is_process_alive(Reader)),
        Reader ! release,
        ?assertEqual(ok, resource_reply(Caller, Ref)),
        await_reader_down(Monitor, Reader),
        ok = wait_stats(Ns, fun(#{mode := live, reconciles := R}) -> R > R0; (_) -> false end)
    end) end}.

resource_admission_overflow_retains_committed_readiness_test_() ->
    {timeout, 60, fun() ->
        Ready = {':-', {agent_hosting_projection, all, {'Node'}, all, []},
                 {',', resource_recovery_enabled,
                  {agent_hosting_projection, read, {'Node'}, all, []}}},
        with_resource_fixture(fun(Ns, _Sup) ->
            H = quod_prolog:applied(Ns),
            Runtime = quod_reg:where({quod_runtime, Ns}),
            Before = quod_runtime:stats(Ns),
            {Caller, Ref} = resource_request(Ns, H, block),
            {Reader, H, initial} = resource_snapshot(),
            Monitor = monitor(process, Reader),
            1 = erlang:trace(Runtime, true, ['receive']),
            try
                Diff = [{retract, {{resource_value, initial}, {[], false}}}] ++
                       diff_for({resource_value, updated}) ++ diff_for(resource_recovery_enabled),
                ok = ae(Ns, H + 1, batch(change(Ns, Diff)), live),
                receive
                    {trace, Runtime, 'receive', {runtime_snapshot_advanced, _, NextH, _}}
                      when NextH =:= H + 1 -> ok
                after 5000 -> error(committed_snapshot_not_delivered) end,
                %% The receive trace plus this call joins processing of both
                %% the transaction and its final snapshot; capacity is exact.
                ?assertMatch(#{queue_len := 2, collapses := 0}, quod_runtime:stats(Ns)),
                ?assertEqual({error, overloaded}, quod_runtime:reconcile_resource(
                    Ns, H + 1, agent_hosts, read, quod_time:mono_ms() + 5000)),
                await_reader_down(Monitor, Reader),
                ?assertEqual({error, runtime_recovering}, resource_reply(Caller, Ref)),
                %% No manual retry: the typed worker selects current committed
                %% resources directly after overflow recovery.
                {_, RestoredH, updated} = resource_snapshot(),
                ?assertEqual(H + 1, RestoredH),
                After = quod_runtime:stats(Ns),
                ?assertEqual(maps:get(reconciles, Before) + 1, maps:get(reconciles, After)),
                ?assertEqual(maps:get(events_seen, Before) + 1, maps:get(events_seen, After))
            after erlang:trace(Runtime, false, ['receive']) end
        end, #{runtime_max_queued_events => 2,
               external_predicate_modules => [quod_agent_predicates]}, [Ready])
    end}.

resource_queue_overflow_recovers_current_state_test_() ->
    {timeout, 60, fun() -> with_resource_fixture(fun(Ns, _Sup) ->
        H = quod_prolog:applied(Ns),
        R0 = maps:get(reconciles, quod_runtime:stats(Ns)),
        {Caller, Ref} = resource_request(Ns, H, block),
        {Reader, H, initial} = resource_snapshot(),
        Monitor = monitor(process, Reader),
        Transactions = [change(Ns, diff_for({overflow_marker, N})) || N <- [one, two]],
        ok = ae(Ns, H + 1, {batch, Transactions}, live),
        await_reader_down(Monitor, Reader),
        ?assertEqual({error, runtime_recovering}, resource_reply(Caller, Ref)),
        ok = wait_stats(Ns, fun(#{mode := live, height := Height, reconciles := R,
                                 collapses := C, runner_active := false, queue_len := 0}) ->
                                   Height =:= H + 1 andalso R > R0 andalso C >= 1;
                              (_) -> false end),
        ?assertMatch({ok, [#{'Markers' := [one, two]}], _}, quod_prolog:prove_ro(
          Ns, {findall, {'Marker'}, {overflow_marker, {'Marker'}}, {'Markers'}})),
        {Next, NextRef} = resource_request(Ns, H + 1, read),
        {_, _, initial} = resource_snapshot(),
        ?assertEqual(ok, resource_reply(Next, NextRef))
    end, #{runtime_max_queued_events => 1}) end}.

%% A raw native fixture predicate is solely a deterministic scheduling probe.
%% It is not a governed bridge and is never present in deployed ontologies.
quod_predicate_module() -> true.
load(Est = #est{db = Db}) ->
    Est#est{db = erlog_int:add_compiled_proc({test_resource_snapshot, 2},
                                            ?MODULE, test_resource_snapshot, Db)}.

test_resource_snapshot({test_resource_snapshot, Mode0, Value0}, Next, Est) ->
    Mode = erlog_int:dderef(Mode0, Est#est.bs),
    Value = erlog_int:dderef(Value0, Est#est.bs),
    Height = quod_predicates:ctx_height(quod_predicates:context(Est)),
    quod_reg:where({runtime_test, resource_reader}) ! {resource_snapshot, self(), Height, Value},
    case Mode of block -> receive release -> ok end; read -> ok end,
    erlog_int:prove_body(Next, Est).

with_resource_fixture(Fun) -> with_resource_fixture(Fun, #{}).

with_resource_fixture(Fun, Config) -> with_resource_fixture(Fun, Config, []).

with_resource_fixture(Fun, Config, ExtraTerms) ->
    {ok, _} = application:ensure_all_started(gproc),
    true = quod_reg:reg({runtime_test, resource_reader}),
    BeamPath = filename:join(filename:dirname(code:which(quod_predicates)),
                             atom_to_list(?MODULE) ++ ".beam"),
    {ok, _} = file:copy(code:which(?MODULE), BeamPath),
    Terms = [{resource_value, initial},
             {':-', {agent_hosting_projection, {'Mode'}, {'Node'}, all, []},
              {',', {member, {'Mode'}, [read, block]},
               {',', {resource_value, {'Value'}}, {test_resource_snapshot, {'Mode'}, {'Value'}}}}},
             {':-', {agent_hosting_projection, write, {'Node'}, all, []},
              {assertz, illegal_selector_write}}],
    Modules = [?MODULE | maps:get(external_predicate_modules, Config, [])],
    F = {_, Ns, Sup} = setup_founded_terms(Terms ++ ExtraTerms,
                                           Config#{external_predicate_modules => Modules}),
    try
        ok = wait_stats(Ns, fun(#{mode := live, runner_active := false, queue_len := 0}) -> true;
                               (_) -> false end),
        Fun(Ns, Sup)
    after
        cleanup_founded(F),
        gproc:unreg(quod_reg:name({runtime_test, resource_reader})),
        file:delete(BeamPath)
    end.

resource_request(Ns, Height, Scope) ->
    Parent = self(),
    spawn_monitor(fun() ->
        Reply = quod_runtime:reconcile_resource(Ns, Height, agent_hosts, Scope,
                                                quod_time:mono_ms() + 10000),
        Parent ! {resource_reply, self(), Reply}
    end).

resource_snapshot() ->
    receive {resource_snapshot, Reader, Height, Value} -> {Reader, Height, Value}
    after 5000 -> error(resource_selector_not_started) end.

resource_reply(Caller, Ref) ->
    receive {resource_reply, Caller, Reply} ->
        receive {'DOWN', Ref, process, Caller, normal} -> Reply
        after 5000 -> error(resource_caller_not_finished) end
    after 5000 -> error(resource_request_not_finished) end.

await_reader_down(Monitor, Reader) ->
    receive {'DOWN', Monitor, process, Reader, _} -> ok
    after 5000 -> error(resource_reader_not_reaped) end.

%%%===================================================================
%%% helpers
%%%===================================================================

with_reaction_est(Terms, Fun) ->
    Est0 = quod_committed_projection:new_est(),
    Est =
        case Terms of
            [] ->
                Est0;
            _ ->
                Diff = quod_prolog:terms_to_diff(Terms),
                {ok, Draft, _Applied} =
                    quod_diff:apply_ops_report(Est0, Diff),
                #est{db = #db{ref = DraftRef} = Db} = Draft,
                Draft#est{db = Db#db{
                                 ref = quod_erlog_db_mvcc:commit(
                                         DraftRef, 1, 0)}}
        end,
    try Fun(Est)
    after
        #est{db = #db{ref = Ref}} = Est,
        quod_erlog_db_mvcc:delete(Ref)
    end.

%% poll the runtime's stats until Pred approves them (Pred must handle #{} — a restart gap)
wait_stats(Ns, Pred) ->
    wait_until(fun() -> Pred(quod_runtime:stats(Ns)) end).

ensure_foreign_owner(Dir) ->
    case quod_reg:where({foreign_log, node}) of
        Pid when is_pid(Pid) -> {Pid, false};
        undefined ->
        {ok, Pid} = quod_foreign_log:start_link(
                          #{cache_dir => Dir, page_timeout_ms => 1000}),
            {Pid, true}
    end.

stop_foreign_owner(_Pid, false) -> ok;
stop_foreign_owner(Pid, true) ->
    unlink(Pid),
    try gen_server:stop(Pid) catch exit:_ -> ok end.

stop_route_owners() ->
    stop_route_owner({directory, control}),
    stop_route_owner({directory, node}).

stop_route_owner(Key) ->
    case quod_reg:where(Key) of
        Pid when is_pid(Pid) -> catch gen_server:stop(Pid);
        _ -> ok
    end.

temp_runtime_dir(Label) ->
    filename:join(
      "/tmp",
      Label ++ "_" ++
          integer_to_list(erlang:unique_integer([positive, monotonic]))).

%% Trace the existing dispatcher, not a substitute actor. These catalogue tests
%% have no hosted agent and explicitly verify that domain events get no node authority.
trace_dispatch(Ns) ->
    erlang:trace_pattern({quod_runtime, dispatch_candidates, 7}, true, [local]),
    erlang:trace_pattern({quod_foreign_log, ack, 2}, true, [local]),
    case quod_reg:where({quod_ns, Ns}) of
        Sup when is_pid(Sup) -> erlang:trace(Sup, true, [call, set_on_spawn]);
        _ -> ok
    end,
    erlang:trace(quod_reg:where({quod_runtime, Ns}), true, [call, set_on_spawn]),
    Barrier = erlang:trace_delivered(all),
    receive {trace_delivered, all, Barrier} -> ok after 1000 -> error(trace_barrier) end,
    drain_source_acks().

drain_source_acks() ->
    receive {trace, _, call, {quod_foreign_log, ack, _}} -> drain_source_acks()
    after 0 -> ok end.

await_route(Ns, Event, Count) ->
    receive
        {trace, _, call, {quod_runtime, dispatch_candidates,
                         [Ns, _, _, _, Event, Candidates, _]}} ->
            ?assertEqual(Count, length(Candidates))
    after 5000 -> error({missing_routed_event, Ns, Event})
    end.

await_source_processed(Ns) ->
    Runtime = quod_reg:where({quod_runtime, Ns}),
    receive {trace, Runtime, call, {quod_foreign_log, ack, [_, _]}} -> ok
    after 5000 -> error(source_notice_not_processed) end.

assert_no_route(Ns) ->
    Barrier = erlang:trace_delivered(all),
    receive {trace_delivered, all, Barrier} -> ok after 1000 -> error(trace_barrier) end,
    receive
        {trace, _, call, {quod_runtime, dispatch_candidates,
                         [Ns, _, _, _, Event, [_|_], _]}} ->
            error({duplicate_routed_event, Event})
    after 0 -> ok end.

stop_dispatch_trace(Pid) ->
    case is_pid(Pid) andalso is_process_alive(Pid) of
        true -> erlang:trace(Pid, false, [call, set_on_spawn]);
        false -> ok
    end,
    erlang:trace_pattern({quod_runtime, dispatch_candidates, 7}, false, [local]),
    erlang:trace_pattern({quod_foreign_log, ack, 2}, false, [local]),
    Barrier = erlang:trace_delivered(all),
    receive {trace_delivered, all, Barrier} -> ok after 1000 -> error(trace_barrier) end,
    drain_dispatch_traces().

drain_dispatch_traces() ->
    receive
        {trace, _, call, {quod_runtime, dispatch_candidates, _}} -> drain_dispatch_traces();
        {trace, _, call, {quod_foreign_log, ack, _}} -> drain_dispatch_traces()
    after 0 -> ok end.
