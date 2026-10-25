-module(quod_class_permissions_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

requirements_and_most_specific_grants_test() ->
    with_policy([{editor_actor, alice}, {approved_actor, alice}], fun(St) ->
        allowed(alice, {instance, report1}, {edit, 3}, St),
        denied(bob, {instance, report1}, {edit, 3}, St),
        denied(alice, {instance, report1}, {edit, 12}, St),
        denied(alice, {instance, missing}, {edit, 3}, St),
        denied(alice, {instance, report1}, unknown, St),
        allowed(alice, {class, report}, {create, [{attribute, name, <<"Report">>}]}, St),
        denied(alice, {class, report}, {create, [invalid]}, St)
    end),
    with_policy([{editor_actor, alice}, {instance_permission, report1, edit, allow}], fun(St) ->
        denied(alice, {instance, report1}, {edit, 3}, St),
        denied(alice, {class, report}, {create, [{attribute, name, <<"Report">>}]}, St)
    end).

direct_memberships_and_derived_memberships_need_no_parent_edge_test() ->
    with_policy([{instance_of, standalone, local},
                 {class_permission, standalone, edit, allow},
                 {class_permission, standalone, create, allow},
                 {derived, inferred},
                 {':-', {instance_of, standalone, {'I'}}, {derived, {'I'}}}], fun(St) ->
        allowed(alice, {instance, local}, {edit, 3}, St),
        allowed(alice, {instance, inferred}, {edit, 3}, St),
        allowed(alice, {class, standalone}, {create, []}, St)
    end).

ambiguity_overrides_and_constructor_order_test() ->
    Facts = [{editor_actor, alice}, {approved_actor, alice},
             {class_permission, reviewed, edit, deny}],
    lists:foreach(fun(Order) ->
        with_policy([{constructor_order, report, Order} | Facts], fun(St) ->
            denied(alice, {instance, report1}, {edit, 3}, St)
        end)
    end, [[secured, reviewed], [reviewed, secured]]),
    with_policy([{class_permission, report, edit, allow} | Facts], fun(St) ->
        allowed(alice, {instance, report1}, {edit, 3}, St)
    end),
    with_policy([{instance_permission, report1, edit, allow} | Facts], fun(St) ->
        allowed(alice, {instance, report1}, {edit, 3}, St),
        denied(alice, {instance, report1}, {edit, 12}, St),
        denied(alice, {instance, report2}, {edit, 3}, St)
    end),
    lists:foreach(fun(Overrides) ->
        with_policy(Overrides ++ Facts, fun(St) ->
            denied(alice, {instance, report1}, {edit, 3}, St)
        end)
    end, [[{instance_permission, report1, edit, allow},
           {instance_permission, report1, edit, deny}],
          [{instance_permission, report1, edit, {'Unbound'}}],
          [{instance_permission, report1, edit, malformed}]]).

cycles_and_multiple_memberships_preserve_all_requirements_test() ->
    with_policy([{isa, secured, report}, {approved_actor, alice},
                 {editor_actor, alice}, {class_permission, report, edit, deny}], fun(St) ->
        ?assertMatch({succeed, _}, erlog_int:prove_goal({isa, report, thing}, St)),
        denied(alice, {instance, report1}, {edit, 3}, St)
    end),
    with_policy([{instance_of, extra, report1}, {isa, extra, thing},
                 {class_requirement, extra, edit, absent_check},
                 {editor_actor, alice}, {approved_actor, alice}], fun(St) ->
        denied(alice, {instance, report1}, {edit, 3}, St)
    end).

equal_unrelated_defaults_agree_test() ->
    with_policy([{editor_actor, alice}, {approved_actor, alice},
                 {class_permission, reviewed, edit, {check, editor}}], fun(St) ->
        allowed(alice, {instance, report1}, {edit, 3}, St),
        denied(bob, {instance, report1}, {edit, 3}, St)
    end).

reserved_permission_edit_requires_an_instance_test() ->
    with_policy([{class_permission, report, set_permission, allow}], fun(St) ->
        denied(alice, {class, report}, {set_permission, edit, allow}, St)
    end).

administrator_rules_check_the_ground_actor_test() ->
    with_policy([{':-', {permission_administrator, report2, {'Actor'}},
                  {',', {atom, {'Actor'}}, {'==', {'Actor'}, alice}}}], fun(St) ->
        allowed(alice, {instance, report2}, {set_permission, edit, allow}, St),
        denied(bob, {instance, report2}, {set_permission, edit, allow}, St)
    end).

foreign_ancestry_and_callbacks_are_invalid_local_policy_test() ->
    Cases = [
        {[{isa, report, {':', animals, dog}}], {class, report}},
        {[{class_requirement, report, edit, foreign_check},
          {':-', {foreign_check, {'_'}, {'_'}, {'_'}},
           {'::', animals, true}}], {instance, report1}}],
    lists:foreach(fun({Facts, Subject}) ->
        with_policy(Facts ++ [{approved_actor, alice}, {editor_actor, alice}], fun(St) ->
            Policy = {operation_policy, alice, Subject, {edit, 3}},
            ?assertEqual(invalid, quod_ask:committed_authorization_result(Policy, St)),
            ?assertThrow({erlog_error, invalid_committed_policy, _},
                erlog_int:prove_goal({'$quod_committed_check', Policy}, St)),
            ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(ref(St)))
        end)
    end, Cases).

ontology_membership_requires_a_forbidden_identity_bridge_test() ->
    with_policy([{class_permission, ontology, edit, allow}], fun(St) ->
        Identity = {<<"class:test">>, <<1:256>>},
        Context = quod_predicates:with_chain(quod_predicates:context(St), [Identity]),
        Scoped = quod_predicates:set_context(St, Context),
        Subject = {ontology_ref, element(1, Identity), element(2, Identity)},
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
            {instance_of, ontology, Subject}, Scoped)),
        ?assertEqual(invalid, quod_ask:committed_authorization_result(
            {operation_policy, alice, {instance, Subject}, {edit, 3}}, Scoped))
    end).

owner_and_administrator_are_subject_specific_test() ->
    with_policy([{attribute, report1, owner, alice},
                 {permission_administrator, report2, bob}], fun(St) ->
        allowed(alice, {instance, report1}, {set_permission, edit, allow}, St),
        allowed(alice, {instance, report1}, {set_permission, edit, deny}, St),
        allowed(alice, {instance, report1}, {set_permission, edit, inherit}, St),
        allowed(bob, {instance, report2}, {set_permission, edit, allow}, St),
        denied(bob, {instance, report1}, {set_permission, edit, allow}, St),
        denied(alice, {instance, report2}, {set_permission, edit, allow}, St),
        denied(alice, {instance, report1}, {set_permission, set_permission, allow}, St)
    end),
    with_policy([{attribute, report1, owner, alice},
                 {class_requirement, reviewed, set_permission, absent_check}], fun(St) ->
        denied(alice, {instance, report1}, {set_permission, edit, allow}, St)
    end).

ambiguous_or_nonground_owners_do_not_grant_edit_authority_test() ->
    lists:foreach(fun(Owners) ->
        with_policy(Owners ++ [{class_permission, report, set_permission, allow}], fun(St) ->
            denied(alice, {instance, report1}, {set_permission, edit, allow}, St)
        end)
    end, [[], [{attribute, report1, owner, {'Anyone'}}],
          [{attribute, report1, owner, alice}, {attribute, report1, owner, bob}]]).

committed_guard_retains_negative_reads_and_conflicts_test() ->
    with_policy([{approved_actor, alice}], fun(St) ->
        Goal = {operation_policy, alice, {instance, report1}, {edit, 3}},
        ?assertEqual(denied, quod_ask:committed_authorization_result(Goal, St)),
        Reads = quod_erlog_db_local_prove:get_read_set(ref(St)),
        ?assertEqual(never_present, maps:get({editor_actor, 1}, Reads)),
        ?assert(maps:is_key({instance_permission, 3}, Reads)),
        Committed = quod_erlog_db_local_prove:committed_state(St),
        {ok, Changed} = quod_diff:apply_ops(Committed, quod_ct:diff_for({editor_actor, alice})),
        Published = quod_ct:commit_kb(Changed, 2, 1),
        ?assertMatch({conflict, _}, quod_diff:validate(Reads, ref(Published)))
    end).

sealed_policy_dependencies_conflict_on_committed_changes_test() ->
    Changes = [{instance_permission, report1, edit, deny},
               {class_permission, report, edit, deny},
               {class_requirement, report, edit, absent_check},
               {isa, report, extra}, {instance_of, extra, report1},
               {approved_actor, another}, {editor_actor, another}],
    Cases = [{{instance, report1}, {edit, 3}, Change} || Change <- Changes] ++
            [{{instance, report1}, {set_permission, edit, allow},
              {attribute, report1, owner, bob}},
             {{instance, report2}, {set_permission, edit, deny},
              {permission_administrator, report2, bob}}],
    lists:foreach(fun({Subject, Operation, Change}) ->
        with_policy([{approved_actor, alice}, {editor_actor, alice},
                     {attribute, report1, owner, alice},
                     {permission_administrator, report2, alice}], fun(St) ->
            Base = quod_erlog_db_local_prove:committed_state(St),
            Session = quod_proof_session:start(Base,
                #{read_set => true, proof_context => {origin, test}, signer => none}),
            Identity = {<<"class:test">>, <<1:256>>},
            Id = <<1:128>>,
            try
                Check = {'$quod_committed_check',
                         {operation_policy, alice, Subject, Operation}},
                Goal = {',', Check, {assertz, payload}},
                ok = quod_proof_session:open(Session, Id, Goal, allowed,
                    quod_predicates:proof_context(element(1, Identity), 1, undefined),
                    quod_transaction_scope:empty_selection()),
                ?assertMatch({solution, _}, quod_proof_session:next(Session, Id)),
                {ok, Plan} = quod_proof_session:seal(Session,
                    #{target => Identity, base_height => 1, proof_id => <<2:256>>,
                      origin => Identity, principal => anonymous, request_binding => none}),
                {ok, #{read_check := Reads}} = quod_dtx:material(Plan),
                ?assertEqual(ok, quod_diff:validate(Reads, ref(Base))),
                {ok, Changed} = quod_diff:apply_ops(Base, quod_ct:diff_for(Change)),
                Published = quod_ct:commit_kb(Changed, 2, 1),
                ?assertMatch({conflict, _}, quod_diff:validate(Reads, ref(Published)))
            after quod_proof_session:stop(Session) end
        end)
    end, Cases).

staged_policy_and_class_changes_cannot_grant_authority_test() ->
    with_policy([{approved_actor, alice}], fun(St) ->
        {succeed, Staged} = erlog_int:prove_goal(conjunction([
            {assertz, {editor_actor, alice}},
            {assertz, {instance_permission, report1, edit, allow}},
            {retract, {class_requirement, reviewed, edit, reviewed_actor}}]), St),
        ?assertEqual(denied, quod_ask:committed_authorization_result(
            {operation_policy, alice, {instance, report1}, {edit, 3}}, Staged))
    end).

policy_discovery_is_strictly_read_only_test() ->
    with_policy([{class_requirement, report, create, mutating},
                 {':-', {mutating, {'_'}, {'_'}, {'_'}}, {assertz, leaked}},
                 {approved_actor, alice}], fun(St) ->
        ?assertEqual(invalid, quod_ask:committed_authorization_result(
            {operation_policy, alice, {class, report}, {create, [{attribute, name, <<"Report">>}]}}, St)),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(ref(St))),
        ?assertMatch({fail, _}, erlog_int:prove_goal(leaked, St))
    end).

signed_direct_offered_creation_and_edit_boundaries_test_() ->
    {timeout, 120, fun signed_boundaries/0}.

signed_boundaries() ->
    Dir = filename:join("/tmp", "quod-class-permissions-" ++
                       binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Ctx = quod_lobby_tests:start(Dir),
    {AgentNs, AgentAnchor} = maps:get(agent, Ctx),
    Owner = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, test_agent}},
    Guest = {agent_instance_ref, AgentNs, AgentAnchor, {human_user, other_agent}},
    GuestCtx = Ctx#{instance => <<"human_user(other_agent).">>},
    {ontology_ref, Lobby, _} = maps:get(lobby, Ctx),
    {_, Base} = maps:get(Lobby, maps:get(ontologies, Ctx)),
    Ns = <<"class-permission-target">>,
    Terms = fixture() ++ [
        {can_invoke, {'_'}, Owner, {'_'}, Ns},
        {':-', {can_invoke, {'_'}, Guest, {'_'}, Ns}, guest_admitted},
        guest_admitted,
        {attribute, report1, owner, Owner},
        {permission_administrator, report2, Owner},
        {approved_actor, Owner}, {approved_actor, Guest}, {editor_actor, Owner}],
    {Sup, _} = quod_lobby_tests:start_namespace(Ns, Base#{
        data_dir => filename:join(Dir, "target"),
        genesis_diff => quod_prolog:terms_to_diff(Terms)}),
    Scope = fun(G) -> {'::', Ns, G} end,
    try
        commit(Ctx, Scope({edit_document, report1, 3})),
        commit(Ctx, Scope({offered_edit, report1, 4})),
        refuse(GuestCtx, Scope({edit_document, report1, 3})),
        refuse(GuestCtx, Scope({offered_edit, report1, 3})),
        refuse(Ctx, Scope({edit_document, report1, 12})),
        refuse(Ctx, Scope({offered_edit, report1, 12})),
        refuse(Ctx, Scope({edit_document, missing, 3})),
        %% A broad ontology ACL does not bypass the guard. Proposed grants and
        %% memberships remain invisible to authorization in the same write.
        refuse(GuestCtx, Scope(conjunction([
            {assertz, {instance_permission, report1, edit, allow}},
            {edit_document, report1, 3}]))),
        refuse(GuestCtx, Scope(conjunction([
            {assertz, {attribute, report1, owner, Guest}},
            {set_instance_permission, report1, edit, allow}]))),
        refuse(GuestCtx, Scope(conjunction([
            {assertz, {permission_administrator, report1, Guest}},
            {set_instance_permission, report1, edit, allow}]))),
        commit(Ctx, Scope({assertz, {class_permission, report, create, deny}})),
        refuse(GuestCtx, Scope(conjunction([
            {retract, {class_permission, report, create, deny}},
            {assertz, {class_permission, report, create, allow}},
            {with_build_plan, [{attribute, name, <<"Report">>}], {assert, {instance_of, report, {'_'}}}}]))),
        commit(Ctx, Scope({retract, {class_permission, report, create, deny}})),
        ?assertMatch({fail, _}, quod_lobby_tests:read(Ctx,
            Scope({instance_permission, report1, edit, {'_'}}))),
        ?assertMatch({fail, _}, quod_lobby_tests:read(Ctx,
            Scope({permission_administrator, report1, Guest}))),
        ?assertMatch({fail, _}, quod_lobby_tests:read(Ctx, Scope(constructor_ran))),
        commit(Ctx, Scope({set_instance_permission, report1, edit, allow})),
        commit(GuestCtx, Scope({edit_document, report1, 5})),
        refuse(GuestCtx, Scope({edit_document, report1, 12})),
        commit(Ctx, Scope({set_instance_permission, report1, edit, deny})),
        refuse(Ctx, Scope({edit_document, report1, 3})),
        commit(Ctx, Scope({set_instance_permission, report1, edit, inherit})),
        commit(Ctx, Scope({edit_document, report1, 6})),
        refuse(GuestCtx, Scope({edit_document, report1, 3})),
        commit(Ctx, Scope({set_instance_permission, report2, edit, allow})),
        commit(GuestCtx, Scope({edit_document, report2, 3})),
        commit(Ctx, Scope({with_build_plan, [{attribute, name, <<"Report">>}], {assert, {instance_of, report, {'_'}}}})),
        %% Warm ordinary read path, then measure actual forbidden work.
        Advisory = Scope({operation_authorized, {instance, report1}, {edit, 3}}),
        ?assertMatch({ok, [#{}], _}, quod_lobby_tests:read(Ctx, Advisory)),
        ?assertMatch({fail, _}, quod_lobby_tests:read(Ctx,
            Scope({operation_authorized, {instance, report1}, {edit, {'_'}}}))),
        Before = quod_prolog:applied(Ns),
        quod_lobby_tests:assert_read_has_no_io(fun() ->
            [?assertMatch({ok, [#{}], _}, quod_lobby_tests:read(Ctx, Advisory))
             || _ <- lists:seq(1, 3)]
        end),
        ?assertEqual(Before, quod_prolog:applied(Ns)),
        commit(Ctx, Scope({set_instance_permission, report1, edit, deny})),
        ?assertMatch({fail, _}, quod_lobby_tests:read(Ctx, Advisory)),
        %% Target admission remains independent, even with a class grant.
        commit(Ctx, Scope({retract, guest_admitted})),
        refuse(GuestCtx, Scope({edit_document, report2, 3}))
    after
        quod_lobby_tests:stop_process(Sup), quod_lobby_tests:stop(Ctx)
    end.

commit(Ctx, Goal) ->
    {ok, Evidence, {normalized, {committed, _, _}}} =
        quod_lobby_tests:submit(Ctx, execute, Goal),
    %% Client completion precedes asynchronous source-receipt publication.
    %% Settle the actual operation before measuring unrelated advisory reads.
    Ref = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state := terminal},
        quod_ct:await_operation_complete(element(2, Ref), Ref, 10000)).
refuse(Ctx, Goal) ->
    ?assertMatch({ok, _, {normalized, {failed, _}}},
                 quod_lobby_tests:submit(Ctx, execute, Goal)).

fixture() -> quod_prolog:read_terms("test/fixtures/class-permissions.pl").
with_policy(Facts, Fun) ->
    Base = quod_ct:action_kb(<<>>, [], fixture() ++ Facts),
    Wrapped = quod_erlog_db_local_prove:wrap_state(Base, #{read_set => true}),
    St = quod_predicates:set_context(Wrapped,
        quod_predicates:proof_context(<<"class:test">>, 1, undefined)),
    try Fun(St)
    after
        quod_erlog_db_local_prove:cleanup_read_set(St),
        quod_erlog_db_mvcc:delete(ref(Base))
    end.
ref(#est{db = #db{ref = Ref}}) -> Ref.
allowed(Actor, Subject, Operation, St) ->
    ?assertEqual(allowed, quod_ask:committed_authorization_result(
        {operation_policy, Actor, Subject, Operation}, St)).
denied(Actor, Subject, Operation, St) ->
    ?assertEqual(denied, quod_ask:committed_authorization_result(
        {operation_policy, Actor, Subject, Operation}, St)).
conjunction([G]) -> G;
conjunction([G | Rest]) -> {',', G, conjunction(Rest)}.
