-module(quod_reaction_authority_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

editable_lobby_notification_cannot_borrow_node_authority_test_() ->
    {timeout, 90, fun() ->
        Dir = filename:join("/tmp", "quod-reaction-authority-" ++
                                   integer_to_list(erlang:unique_integer([positive]))),
        Ctx = quod_lobby_tests:start(Dir),
        Root = quod_ontology:root_ns(),
        {ontology_ref, Lobby, _Anchor} = maps:get(lobby, Ctx),
        try
            Goal = {'::', Root, {assertz, authority_root_marker}},
            ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(Ctx, Goal)),
            ?assertMatch({fail, _}, quod_prolog:prove_ro(Root, authority_root_marker)),
            %% No hosted agent belongs to this personal lobby. Selecting any
            %% actor here, including either kind of node, is an authority leak.
            Reaction = observed_reaction(authority_lobby_tick, Goal, {me, {'Actor'}}),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                         submit(Ctx, {'::', Lobby, {assertz, Reaction}})),
            Trace = trace_notices(Lobby),
            try
                %% An actual committed edit makes the owning runtime publish
                %% ontology_changed; no test-created observed/1 term is sent.
                ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                             submit(Ctx, {'::', Lobby, {assertz, authority_lobby_tick}})),
                Stats = dispatched(Lobby, authority_lobby_tick, [root_write]),
                %% Inspect dispatch as well as the final state: a later root
                %% ACL refusal must not conceal selection of the wrong actor.
                ?assertEqual(0, maps:get(candidates, Stats)),
                ?assertEqual(0, maps:get(matches, Stats)),
                ?assertEqual(0, maps:get(executed, Stats)),
                ?assertMatch({fail, _}, quod_prolog:prove_ro(Root, authority_root_marker))
            after trace:session_destroy(Trace) end
        after quod_lobby_tests:stop(Ctx) end,
        ok = file:del_dir_r(Dir)
    end}.

owned_notification_runs_only_as_the_hosted_agent_test_() ->
    {timeout, 60, fun() ->
        Tick = authority_hosted_tick,
        Actor = {agent_instance_ref, {'Namespace'}, {'Anchor'}, actor},
        Rules = [observed_reaction(Tick, {record_ping, physical_authority_leaked},
                                    {me, {node, {'Key'}}}),
                 observed_reaction(Tick, {record_ping, logical_authority_leaked},
                     {me, {agent_instance_ref, <<"host-test-node">>, {'NodeAnchor'}, physical_node}}),
                 observed_reaction(Tick, {record_ping, {authority_actor, Actor}}, {me, Actor})],
        quod_agent_hosting_tests:with_host(
          fun(#{namespace := Ns, reference := Ref, node := Node, key := Key}) ->
              ?assertMatch({ok, _, _}, quod_ct:rp(
                           Ns, {goal, {agent_hosted, actor, Node, 1, Key}})),
              receive
                  {agent_installed, _, _, #{reference := Ref, epoch := 1}, _} -> ok
              after 10000 -> error(authority_agent_not_installed) end,
              Trace = trace_notices(Ns),
              try
                  ?assertMatch({ok, _, _}, quod_ct:rp(Ns, {assertz, Tick})),
                  Stats = dispatched(Ns, Tick, [physical, logical, hosted]),
                  ?assertEqual(1, maps:get(matches, Stats)),
                  ?assertEqual(1, maps:get(executed, Stats)),
                  receive
                      {agent_request_finished, _, _, #{reference := Ref}, _, Result} ->
                          ?assertMatch({ok, _, {normalized, {committed, _, _}}}, Result)
                  after 10000 -> error(owned_notification_not_committed) end,
                  ?assertMatch({ok, [#{'Values' := [{authority_actor, Ref}]}], _},
                    quod_prolog:prove_ro(Ns, {findall, {'Value'}, {ping, {'Value'}}, {'Values'}}))
              after trace:session_destroy(Trace) end
          end, Rules)
    end}.

observed_reaction(Tick, Goal, Guard) ->
    {':-', {react_on, {observed, {ontology_changed, {'Heads'}}}, Goal},
           {',', {member, Tick, {'Heads'}}, Guard}}.

%% A call followed by its return is evidence that the actual notification was
%% dispatched. The scope filter keeps tracing bounded to this disposable owner.
trace_notices(Ns) ->
    Trace = trace:session_create(reaction_authority, self(), []),
    trace:function(Trace, {quod_runtime, dispatch_candidates, 7},
      [{[Ns, '_', '_', '_', {observed, {ontology_changed, '_'}}, '_', '_'],
        [], [{return_trace}]}], [local]),
    trace:process(Trace, all, true, [call]),
    Trace.

dispatched(Ns, Tick, Required) ->
    dispatched(Ns, Tick, Required, #{candidates => 0, matches => 0, executed => 0},
               erlang:monotonic_time(millisecond) + 10000).

dispatched(_Ns, _Tick, [], Stats, _Deadline) -> Stats;
dispatched(Ns, Tick, Required, Stats, Deadline) ->
    receive
        {trace, Pid, call, {quod_runtime, dispatch_candidates,
          [Ns, _Height, _Est, _Audience, {observed, {ontology_changed, Heads}}, Clauses, Before]}} ->
            After = dispatch_return(Pid, Deadline),
            Seen = case lists:member(Tick, Heads) of
                true -> [Id || Clause <- Clauses,
                               Id <- [reaction_id(Clause)], lists:member(Id, Required)];
                false -> []
            end,
            case Seen of
                [] -> dispatched(Ns, Tick, Required, Stats, Deadline);
                _ ->
                    Next = maps:map(fun(Key, Count) ->
                        Count + maps:get(Key, After) - maps:get(Key, Before)
                    end, Stats),
                    dispatched(Ns, Tick, Required -- Seen, Next, Deadline)
            end
    after remaining(Deadline) -> error({owner_notification_not_dispatched, Ns, Required})
    end.

dispatch_return(Pid, Deadline) ->
    receive
        {trace, Pid, return_from, {quod_runtime, dispatch_candidates, 7}, Stats} -> Stats
    after remaining(Deadline) -> error(owner_notification_did_not_finish)
    end.

reaction_id({':-', {react_on, _, {'::', _, {assertz, authority_root_marker}}}, _}) -> root_write;
reaction_id({':-', {react_on, _, {record_ping, physical_authority_leaked}}, _}) -> physical;
reaction_id({':-', {react_on, _, {record_ping, logical_authority_leaked}}, _}) -> logical;
reaction_id({':-', {react_on, _, {record_ping, {authority_actor, _}}}, _}) -> hosted;
reaction_id(_) -> other.

remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

submit(Ctx, Goal0) ->
    {Goal, _, _} = erlog_int:term_instance(Goal0, 0),
    {ok, Text} = quod_client_goal_parser:format(Goal),
    {Ns, Anchor} = maps:get(agent, Ctx),
    {Public, _} = Pair = maps:get(key_pair, Ctx),
    Request = #{network_identity => maps:get(network, Ctx), signing_public_key => Public,
        operation_id => crypto:strong_rand_bytes(32), agent_namespace => Ns,
        agent_genesis_anchor => Anchor, agent_instance_text => <<"human_user(test_agent).">>,
        mode => execute, parser_version => 3, not_after_ms => quod_time:now_ms() + 30000,
        goal_text => Text},
    {ok, Bytes} = quod_client_goal:encode(Request),
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(Pair)),
    quod_client_goal_ingress:submit(Bytes, Signature).
