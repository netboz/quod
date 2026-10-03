-module(quod_reaction_metadata_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-export([inspect_metadata/3]).

node_manifest_gets_metadata_without_agent_bridges_test() ->
    with_node(fun(Est) ->
        ?assertEqual({query, proof_bound, quod_runtime_predicates, current_request_expiry},
                     quod_predicates:descriptor(Est, {current_request_expiry, 1})),
        lists:foreach(fun({Name, Arity}) ->
            ?assertEqual({reaction, none, quod_runtime_predicates, Name},
                         quod_predicates:descriptor(Est, {Name, Arity}))
        end, [{limit_reaction_expiry, 1}, {prepare_agent_custody, 3}]),
        ?assertEqual(undefined, quod_predicates:descriptor(Est, {sign_agent_request, 2})),
        %% Loading the ordinary agent manifest afterwards must not re-register
        %% these functors under another implementation.
        ?assertMatch(#est{}, quod_agent_predicates:load(Est))
    end).

recovery_notice_requires_private_owned_envelope_test() ->
    with_node(fun(Est) ->
        Event = {agent_recovery_ready, node_ref(), target()},
        Meta = metadata(), Recovery = maps:get(recovery, Meta),
        ?assertMatch({fail, _}, match(Est, Meta, {recovery_observation, Event}, true)),
        Owned = Meta#{recovery => Recovery#{event => Event}},
        ?assertMatch({ok, _, [], _}, match(Est, Owned, {recovery_observation, Event}, true)),
        ?assertMatch({fail, _}, match(Est, Owned,
                                     {recovery_observation, {agent_recovery_ready, node_ref(), wrong}}, true))
    end).

preparation_keeps_target_separate_from_behavior_scope_test() ->
    with_node(fun(Est) ->
        Target = target(),
        {ok, #{'Request' := {request, {record, Variable}, 2000,
                            {custody, Target, 1, Variable}}}, [], _} =
            match(Est, metadata(), {prepare_agent_custody, Target, 1, {'Result'}},
                  {record, {'Result'}}),
        ?assertMatch({_}, Variable),
        ?assertNotEqual(element(2, node_ref()), element(2, Target))
    end).

preparation_rejects_unowned_or_invalid_target_test_() ->
    Target = target(), Node = node_ref(), Meta = metadata(),
    [?_test(with_node(fun(Est) ->
        ?assertMatch({fail, _}, match(Est, Context, Goal, {record, {'Result'}}))
    end)) || {Context, Goal} <-
        [{Meta, {prepare_agent_custody, actor, 1, {'Result'}}},
         {Meta, {prepare_agent_custody, setelement(2, Target, <<"other">>), 1, {'Result'}}},
         {Meta, {prepare_agent_custody, setelement(3, Target, <<3:256>>), 1, {'Result'}}},
         {Meta, {prepare_agent_custody, setelement(4, Target, {'Instance'}), 1, {'Result'}}},
         {Meta, {prepare_agent_custody, Target, 2, {'Result'}}},
         {Meta, {prepare_agent_custody, Target, 1, already_bound}},
         {maps:remove(recovery, Meta), {prepare_agent_custody, Target, 1, {'Result'}}},
         {Meta#{mode => execute}, {prepare_agent_custody, Target, 1, {'Result'}}},
         {Meta#{recovery => #{target => Target, epoch => 1,
                             observer => setelement(4, Node, other)}},
          {prepare_agent_custody, Target, 1, {'Result'}}}]].

metadata_backtracking_and_expiry_bounds_test() ->
    with_node(fun(Est) ->
        Abandoned = {',', {limit_reaction_expiry, 1000},
                     {',', {prepare_agent_custody, target(), 1, {'Result'}}, fail}},
        Chosen = {',', {limit_reaction_expiry, 1500},
                  {',', {current_request_expiry, {'Expiry'}},
                   {'=', {'Result'}, untouched}}},
        ?assertMatch({ok, #{'Request' :=
                           {request, {record, untouched, 1500}, 1500, none}}, [], _},
          match(Est, metadata(), {';', Abandoned, Chosen},
                {record, {'Result'}, {'Expiry'}})),
        ?assertMatch({fail, _}, match(Est, metadata(),
                                     {limit_reaction_expiry, 2001}, true)),
        %% A cut retains the narrowed metadata of its successful branch.
        ?assertMatch({ok, #{'Request' := {request, true, 1000, none}}, [], _},
          match(Est, metadata(), {',', {limit_reaction_expiry, 1000}, '!'}, true))
    end).

preparation_template_still_requires_one_shared_result_variable_test_() ->
    [?_test(with_node(fun(Est) ->
        ?assertMatch({fail, _}, match(Est, metadata(),
                                     {prepare_agent_custody, target(), 1, {'Result'}},
                                     Template))
    end)) || Template <- [true, {record, {'Other'}}, {record, {'Result'}, {'Other'}}]].

proof_expiry_remains_authenticated_without_agent_module_test() ->
    with_node(fun(Est) ->
        Ref = node_ref(), Target = {element(2, Ref), element(3, Ref)},
        Ctx = quod_predicates:proof_context(element(1, Target), 1, undefined, [Target]),
        St = quod_predicates:set_context(Est, Ctx),
        ?assertMatch({fail, _}, run({current_request_expiry, {'Expiry'}}, St)),
        #{principal := Principal, evidence := Evidence} = quod_ct:signed_goal_fixture(
            #{target => Target, deadline => 123456}),
        _ = quod_proof_context:start(<<4:256>>, false, Target,
                                    quod_time:mono_ms() + 5000, Principal, Evidence),
        try
            ?assertMatch({ok, #{'Expiry' := 123456}, [], _},
                         run({current_request_expiry, {'Expiry'}}, St)),
            lists:foreach(fun(Goal) ->
                ?assertMatch({error, {erlog, {context_violation, _, reaction, proof}}}, run(Goal, St))
            end, [{limit_reaction_expiry, 1000},
                  {prepare_agent_custody, target(), 1, {'Result'}}])
        after quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end) end
    end).

matching_copies_only_recovery_metadata_from_binding_test() ->
    with_node(fun(Est0) ->
        Est = quod_predicates:register(Est0, {inspect_metadata, 0}, reaction,
                                       ?MODULE, inspect_metadata),
        Ref = node_ref(), Ns = element(2, Ref), Anchor = element(3, Ref),
        Recovery = maps:get(recovery, metadata()),
        Binding = #{reference => Ref, epoch => 1, public_key => <<5:256>>,
                    request_timeout_ms => 10000, request_expiry => 2000,
                    recovery => Recovery, ceiling => 999999,
                    mode => local_execute, source => {<<"forged">>, <<9:256>>}},
        ?assertEqual(unmatched, quod_runtime_predicates:run_reaction(
          Ns, 1, Binding, {':-', {react_on, event, true}, inspect_metadata}, event, Est)),
        receive
            {reaction_metadata_probe, Seen} ->
                ?assertEqual(Recovery, maps:get(recovery, Seen)),
                ?assertEqual(2000, maps:get(ceiling, Seen)),
                ?assertEqual(execute, maps:get(mode, Seen)),
                ?assertEqual({Ns, Anchor}, maps:get(source, Seen))
        after 0 -> error(metadata_probe_not_executed)
        end
    end).

inspect_metadata(inspect_metadata, _Next, St) ->
    {ok, Metadata} = quod_runtime_predicates:reaction_metadata(St),
    self() ! {reaction_metadata_probe, Metadata},
    erlog_int:fail(St).

match(Est, Metadata, Guard, Goal) ->
    Ref = node_ref(),
    Ctx = quod_predicates:with_executor(
            quod_predicates:reaction_context(element(2, Ref), 1), {actor, Ref, Metadata}),
    run({'$quod_reaction_match', event, event, Guard, Goal, {'Request'}},
        quod_predicates:set_context(Est, Ctx)).

run(Goal, Est) ->
    quod_proof_session:run_first(Goal, Est, #{read_set => true, read_only => true}).

metadata() ->
    Ref = node_ref(),
    #{ceiling => 2000, source => {element(2, Ref), element(3, Ref)},
      mode => {node, Ref, execute},
      recovery => #{target => target(), epoch => 1, observer => Ref}}.

node_ref() -> {agent_instance_ref, <<"node">>, <<1:256>>, node}.
target() -> {agent_instance_ref, <<"affected">>, <<2:256>>, actor}.

with_node(Evaluate) ->
    #est{db = #db{ref = Ref}} = Est =
        quod_ct:action_kb(<<>>, [quod_ontology_predicates], []),
    try Evaluate(Est) after quod_erlog_db_mvcc:delete(Ref) end.
