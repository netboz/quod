-module(quod_gui_operations_tests).
-include_lib("eunit/include/eunit.hrl").

prebound_creation_output_is_refused_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        Subject = class_ref(Ns,test_space),
        {operation_view,create,Subject,Revision,_,_,Values,create,_,_} = create_view(C,Ns),
        denied(C,Ns,conj([
            {gui_operation_bind,Subject,create,Revision,create,Values,{'Goal'},{'Results'}},
            {'=',{'Results'},[{result,space,ref(Ns,example_name)}]},
            {call,{'Goal'}}])),
        fails(Ns,{instance_of,test_space,example_name})
    end) end}.

execution_preserves_authored_output_aliases_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        Subject = class_ref(Ns,test_space),
        Original = hd([Clause || Clause = {':-',{gui_form,space_create,_,_},_} <-
            quod_prolog:read_terms("test/fixtures/gui-operations.pl")]),
        edit(Ns,{retract,Original}),
        Fields = [{field,example_name,{'Name'}},{field,space_extent,{'Extent'}}],
        Inputs = [{attribute,name,{'Name'}},{attribute,dimensions,{'Extent'}}],
        Create = fun(Id) -> {with_build_plan,Inputs,{assert,{instance_of,test_space,Id}}} end,
        Distinct = {gui_form,space_create,Fields,{submit,create,
            conj([Create({'First'}),Create({'Second'})]),
            {operation,{create,Inputs},[{result,first,{'First'}},{result,second,{'Second'}}]}}},
        edit(Ns,{assertz,Distinct}),
        {operation_view,create,Subject,R,_,_,Values,create,_,_} = create_view(C,Ns),
        denied(C,Ns,conj([
            {gui_operation_bind,Subject,create,R,create,Values,{'G'},{'Results'}},
            {'=',{'Results'},[{result,first,{'Same'}},{result,second,{'Same'}}]},
            {call,{'G'}}])),
        edit(Ns,{retract,Distinct}),
        Shared = {gui_form,space_create,Fields,{submit,create,Create({'Same'}),
            {operation,{create,Inputs},[{result,first,{'Same'}},{result,second,{'Same'}}]}}},
        edit(Ns,{assertz,Shared}),
        {operation_view,create,Subject,R2,_,_,Values,create,_,_} = create_view(C,Ns),
        {Reply,_} = signed(C,scoped(Ns,conj([
            {gui_operation_bind,Subject,create,R2,create,Values,{'G'},{'Results'}},
            {call,{'G'}}]))),
        [[{result,first,Id},{result,second,Id}]] =
            [V || {_,V = [{result,first,_},{result,second,_}]} <- bindings(Reply)],
        ?assertEqual(26,byte_size(Id)), wait_complete(Reply)
    end) end}.

transported_bound_goal_preserves_named_creation_result_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        Subject = class_ref(Ns,test_space),
        {operation_view,create,Subject,Revision,_,_,Values,create,_,_} = create_view(C,Ns),
        {Prepared,_} = signed(C,scoped(Ns,
            {gui_operation_bind,Subject,create,Revision,create,Values,{'Goal'},{'Results'}})),
        [{_,Goal},{_,Results}] = bindings(Prepared),
        [{result,space,{entity_ref,Ns,_,Output}}] = Results,
        ?assertMatch({_},Output),
        %% The ordinary result codec preserves sharing between the goal and
        %% named results across a separate signed request, without rebinding.
        {Created,Bytes} = signed(C,scoped(Ns,conj([Goal,{'=',{'Created'},Results}]))),
        Bindings = bindings(Created),
        [[{result,space,Ref = {entity_ref,Ns,_,Id}}]] =
            [V || {_,V = [{result,space,_}]} <- Bindings],
        ?assertEqual(26,byte_size(Id)), holds(Ns,{instance_of,test_space,Id}),
        wait_complete(Created),
        {ok,_,{operation_outcome,_,Outcome}} = quod_personal_agent_tests:lookup(C,Bytes),
        ?assert(lists:member([{result,space,Ref}],[V || {_,V} <- maps:get(bindings,Outcome)]))
    end) end}.

offered_creation_and_instance_operation_test_() ->
    {timeout, 120, fun() -> with_operations(fun(C = #{storage := Ns, namespace := ActorNs}) ->
        Subject = class_ref(Ns, test_space),
        View = create_view(C, Ns),
        {operation_view, create, Subject, Revision, Tree, _, Values, create, [space], requires_input} = View,
        ?assertMatch({component, space_create, form, _, _}, Tree),
        ?assertEqual([{field,example_name,<<"Space">>},
                      {field,space_extent,default_dimensions()}], Values),
        %% An unplaced class has a create offer without an existing instance.
        edit(Ns, {retract,{instance_of,space_class(),room}}),
        edit(Ns, {retract,{instance_of,space_class(),closed}}),
        ?assertEqual(View, create_view(C, Ns)),
        %% Repeated discovery neither creates identities nor changes disk state.
        quod_lobby_tests:assert_read_has_no_io(fun() ->
            [begin
                {ok,[_],_} = quod_prolog:prove_ro(Ns,{gui_operations,Subject,{'Views'}})
             end || _ <- [first,repeat]]
        end),
        Values2 = lists:keyreplace(example_name,2,Values,{field,example_name,<<"Offered">>}),
        %% One submitted ordinary goal binds a named output through the real
        %% assertion hook, class slots, personal instruction and outcome owners.
        Bound = {gui_operation_bind,Subject,create,Revision,create,Values2,{'Goal'},{'Results'}},
        {Reply,Bytes} = signed(C, scoped(Ns, conj([Bound, {call,{'Goal'}}]))),
        Bindings = bindings(Reply),
        [{result,space,Ref = {entity_ref,Ns,_,Id}}] = proplists:get_value(<<"V1">>,Bindings),
        ?assertEqual(26,byte_size(Id)),
        holds(Ns,{attribute,Id,name,<<"Offered">>}),
        holds(Ns,{attribute,Id,owner,maps:get(human,C)}),
        wait_complete(Reply),
        %% The retained result includes exactly the selected named result list.
        {ok,_,{operation_outcome,_,Outcome}} = quod_personal_agent_tests:lookup(C,Bytes),
        ?assertEqual(Bindings,maps:get(bindings,Outcome)),
        Destination = ref(maps:get(destination,C),room),
        %% A real authorized placement makes the same subject's instance offer
        %% available; it uses existing withdrawal, not a GUI executor.
        {Placed,_} = signed(C,space({goal,{inside,Destination,Ref,{transform,0,0,0,0,0,0}}})), wait_complete(Placed),
        %% The instance also offers how its inside looks (Show as).
        ?assertEqual([show_matrix,show_wireframe],lists:sort([N || {operation_view,N,_,_,_,_,_,_,_,_} <- views(C,Ns,Ref), lists:member(N,[show_matrix,show_wireframe])])),
        [Withdraw] = withdraw_views(C,Ns,Ref),
        {operation_view,withdraw,Ref,WR,_,_,WV,WC,[],available} = Withdraw,
        ?assertEqual([{field,{destination,Id},Destination}],WV),
        Bad = [{field,{destination,Id},ref(ActorNs,room)}],
        denied(C,Ns,{gui_operation_bind,Ref,withdraw,WR,WC,Bad,{'G'},{'R'}}),
        denied(C,Ns,{gui_operation_bind,ref(Ns,closed),withdraw,WR,WC,WV,{'G'},{'R'}}),
        {Withdrawn,_} = signed(C,scoped(Ns,conj([
            {gui_operation_bind,Ref,withdraw,WR,WC,WV,{'G'},{'R'}},{call,{'G'}}]))),
        wait_complete(Withdrawn), holds(Ns,{space_assignment_state,Id,2,none}),
        ?assertEqual([],withdraw_views(C,Ns,Ref)),
        denied(C,Ns,{gui_operation_bind,Ref,withdraw,WR,WC,WV,{'G'},{'R'}}),
        NextDestination = ref(ActorNs,room),
        {Replaced,_} = signed(C,space({goal,{inside,NextDestination,Ref,{transform,0,0,0,0,0,0}}})), wait_complete(Replaced),
        [{operation_view,withdraw,Ref,NextR,_,_,NextV,WC,[],available}] = withdraw_views(C,Ns,Ref),
        ?assertNotEqual(WR,NextR),
        ?assertEqual([{field,{destination,Id},NextDestination}],NextV),
        denied(C,Ns,{gui_operation_bind,Ref,withdraw,WR,WC,WV,{'G'},{'R'}}),
        denied(C,Ns,{gui_operation_bind,Ref,withdraw,NextR,WC,WV,{'G'},{'R'}})
    end) end}.

binding_refuses_invalid_or_changed_contract_test_() ->
    {timeout, 120, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        Subject = class_ref(Ns,test_space),
        {operation_view,create,Subject,R,_,_,Values,create,_,_} = create_view(C,Ns),
        Bind = fun(S,Rev,V) -> {gui_operation_bind,S,create,Rev,create,V,{'G'},{'R'}} end,
        [denied(C,Ns,Bind(S,R,Values)) || S <- [class_ref(Ns,missing),
            setelement(3,Subject,<<0:256>>),ref(Ns,room),class_ref(maps:get(destination,C),test_space)]],
        [denied(C,Ns,Bind(Subject,R,V)) || V <- [tl(Values),Values++[hd(Values)],
            Values++[{field,space,chosen_id}], Values++[{field,continuation,{assertz,injected}}],
            lists:keyreplace(example_name,2,Values,{field,example_name,<<"Forbidden">>}),
            lists:keyreplace(example_name,2,Values,{field,example_name,42}),
            lists:keyreplace(space_extent,2,Values,{field,space_extent,bad_extent})]],
        denied(C,Ns,{gui_operation_bind,Subject,create,R,create,Values,{assertz,injected},{'R'}}),
        denied(C,Ns,{gui_operation_bind,Subject,create,R,create,Values,{'G'},[{result,space,chosen_id}]}),
        {SchemaReply,_} = signed(C,scoped(Ns,
            {gui_definition,space_create,{'Schema'},{'_'},{'_'},{'_'},{'_'}})),
        Schema = proplists:get_value(<<"V0">>,bindings(SchemaReply)),
        denied(C,Ns,{gui_bind,space_create,Schema,create,Values,{'G'}}),
        denied(C,Ns,{gui_schema,space_create,{'Revision'},{'Tree'}}),
        denied(C,Ns,{with_build_plan,[{attribute,name,<<"Forbidden">>}],
                    {assert,{instance_of,test_space,{'Space'}}}}),
        %% Stale checks cover both binding and a previously bound goal.
        {BoundReply,_} = signed(C,scoped(Ns,Bind(Subject,R,Values))),
        Goal = proplists:get_value(<<"V0">>,bindings(BoundReply)),
        edit(Ns,{assertz,{gui_validation_context,space_create,{version,2}}}),
        denied(C,Ns,Bind(Subject,R,Values)), denied(C,Ns,Goal),
        {operation_view,create,Subject,R2,_,_,_,create,_,_} = create_view(C,Ns),
        ?assertNotEqual(R,R2),
        %% Changed committed policy is rechecked after inputs and at execution.
        {CurrentReply,_} = signed(C,scoped(Ns,Bind(Subject,R2,Values))),
        Current = proplists:get_value(<<"V0">>,bindings(CurrentReply)),
        edit(Ns,{retract,creation_enabled}),
        denied(C,Ns,Bind(Subject,R2,Values)), denied(C,Ns,Current),
        denied(C,Ns,{with_build_plan,[],{assert,{instance_of,test_space,{'Space'}}}}),
        denied(C,Ns,conj([{assertz,creation_enabled},Bind(Subject,R2,Values)])),
        fails(Ns,creation_enabled), fails(Ns,injected), fails(Ns,unoffered)
    end) end}.

foreign_recipe_compiles_at_owner_and_executes_at_storage_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns,destination := Recipes}) ->
        Subject = class_ref(Ns,test_space),
        Original = hd([Clause || Clause = {':-',{class_eidolon,test_space,{operation,class},create,_},_} <-
            quod_prolog:read_terms("test/fixtures/gui-operations.pl")]),
        edit(Ns,{retract,Original}),
        Offer = {class_eidolon,test_space,{operation,class},create,
                 {recipe,Recipes,quod_simplex:genesis_hash(Recipes),remote_create}},
        edit(Ns,{assertz,Offer}),
        edit(Recipes,{assertz,{eidolon,remote_create,
            {subject,{ontology_ref,Ns,quod_simplex:genesis_hash(Ns)},{class,test_space}},
            {operation,space_create}}}),
        Form = hd([Clause || Clause = {':-',{gui_form,space_create,_,_},_} <-
            quod_prolog:read_terms("test/fixtures/gui-operations.pl")]),
        edit(Ns,{retract,Form}),
        edit(Recipes,{retract,Form}),
        Inputs = [{attribute,name,{'Name'}},{attribute,dimensions,{'Extent'}}],
        edit(Recipes,{assertz,{gui_form,space_create,
            [{field,example_name,{'Name'}},{field,space_extent,{'Extent'}}],
            {submit,create,conj([{current_ontology_identity,{'Store'},{'Anchor'}},
                {with_build_plan,Inputs,{assert,{instance_of,test_space,{'Space'}}}}]),
                {operation,{create,Inputs},
                    [{result,space,{entity_ref,{'Store'},{'Anchor'},{'Space'}}}]}}}}),
        {operation_view,create,Subject,R,_,_,Values,create,[space],requires_input} = create_view(C,Ns),
        {Created,_} = signed(C,scoped(Ns,conj([
            {gui_operation_bind,Subject,create,R,create,Values,{'G'},{'Results'}},{call,{'G'}}]))),
        wait_complete(Created),
        [[{result,space,{entity_ref,Ns,_,Id}}]] =
            [V || {_,V = [{result,space,_}]} <- bindings(Created)],
        holds(Ns,{instance_of,test_space,Id}), fails(Recipes,{instance_of,test_space,Id}),
        edit(Ns,{retract,Offer}),
        edit(Ns,{assertz,setelement(5,Offer,{recipe,Recipes,<<0:256>>,remote_create})}),
        ?assertEqual([], [V || V={operation_view,create,_,_,_,_,_,_,_,_} <- views(C,Ns,Subject)])
    end) end}.

malformed_outputs_and_ambiguous_offers_are_refused_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        Subject = class_ref(Ns,test_space),
        _ = create_view(C,Ns),
        edit(Ns,{assertz,{class_eidolon,test_space,{operation,class},create,
                         {recipe,Ns,quod_simplex:genesis_hash(Ns),other_recipe}}}),
        ?assertEqual([], [V || V={operation_view,create,_,_,_,_,_,_,_,_} <- views(C,Ns,Subject)]),
        edit(Ns,{retract,{class_eidolon,test_space,{operation,class},create,
                          {recipe,Ns,quod_simplex:genesis_hash(Ns),other_recipe}}}),
        Original = hd([Clause || Clause = {':-',{gui_form,space_create,_,_},_} <-
            quod_prolog:read_terms("test/fixtures/gui-operations.pl")]),
        edit(Ns,{retract,Original}),
        Name = {'Name'}, Extent = {'Extent'}, Output = {'Output'},
        Fields = [{field,example_name,Name},{field,space_extent,Extent}],
        Inputs = [{attribute,name,Name},{attribute,dimensions,Extent}],
        Goal = {with_build_plan,Inputs,{assert,{instance_of,test_space,Output}}},
        Valid = [{result,space,Output}],
        [begin
            Form = {gui_form,space_create,Fields,{submit,create,G,{operation,P,Results}}},
            edit(Ns,{assertz,Form}),
            ?assertEqual([], [V || V={operation_view,create,_,_,_,_,_,_,_,_} <- views(C,Ns,Subject)]),
            edit(Ns,{retract,Form})
         end || {G,P,Results} <- [
            {Goal,{create,Inputs},[{result,space,Name}]},
            {Goal,{create,Inputs},Valid++Valid},
            {Goal,{create,Inputs},[]},
            {Goal,{create,Inputs},[{result,space,{'Unused'}}]},
            {Goal,{create,Output},Valid},
            {conj([Goal,{'extra',{'Undeclared'}}]),{create,Inputs},Valid},
            {Goal,{create,Inputs},[{result,{'Name'},Output}]}]],
        edit(Ns,{assertz,Original}),
        _ = create_view(C,Ns)
    end) end}.

discovery_is_read_only_even_in_execute_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        %% Class listing selects an exact recipe but does not compile its form.
        BadForm = {':-',{gui_form,space_create,{'_'},{'_'}},{assertz,discovery_mutated}},
        edit(Ns,{assertz,BadForm}),
        {ok,[#{'Classes':=Classes}],_} = quod_prolog:prove_ro(Ns,{gui_operation_classes,{'Classes'}}),
        ?assert(lists:member({class_ref,Ns,quod_simplex:genesis_hash(Ns),test_space},Classes)), fails(Ns,discovery_mutated),
        edit(Ns,{retract,BadForm}),
        %% Authored recipe discovery cannot smuggle a mutation through an
        %% execute request; the existing read-only proof boundary rejects it.
        Head = {eidolon,space_create,{subject,{'Target'},{class,test_space}},{operation,space_create}},
        edit(Ns,{retract,{':-',Head,{'Body'}}}),
        edit(Ns,{assertz,{':-',Head,{assertz,discovery_mutated}}}),
        {Reply,_} = signed(C,scoped(Ns,{gui_operations,class_ref(Ns,test_space),{'Views'}})),
        ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},Reply),
        fails(Ns,discovery_mutated)
    end) end}.

with_operations(Fun) ->
    Sources = source("gui_instance.pl") ++
              quod_prolog:read_terms("test/fixtures/gui-operations.pl"),
    %% A local subclass authors its own forms and inherits the real space owner.
    %% Stage1 exercises the production creation forms directly.
    quod_space_creation_tests:with_spaces(fun(C = #{identity := Node,directory := Dir}) ->
        Gui = <<"quod:gui">>,
        Sup = quod_agent_hosting_tests:start_ontology(Gui,Dir,Node,[],quod_ct:gui_terms()),
        try
            [edit(Ns,{assertz,{gui_vocabulary,Gui,quod_simplex:genesis_hash(Gui)}})
             || Ns <- [maps:get(namespace,C),maps:get(storage,C),maps:get(destination,C),<<"quod:space">>]],
            Fun(C)
        after quod_agent_hosting_tests:stop_ontology(Sup) end
    end,Sources).

create_view(C,Ns) ->
    [View] = [V || V={operation_view,create,_,_,_,_,_,_,_,_} <- views(C,Ns,class_ref(Ns,test_space))], View.
views(C,Ns,Subject) ->
    {Reply,_} = signed(C,scoped(Ns,{gui_operations,Subject,{'Views'}})),
    [{_,Views}] = bindings(Reply), Views.
signed(C,Goal) ->
    {Instruction,Bytes} = quod_personal_agent_tests:instruction(C,Goal),
    {quod_personal_agent_tests:instruct(C,submit,Instruction),Bytes}.
bindings({ok,_,{normalized,{read,_,{answers,_,[Binding]}}}}) ->
    {ok,Bindings} = quod_client_result:decode_binding(Binding), Bindings;
bindings({ok,_,{normalized,{answers,_,[Binding]}}}) ->
    {ok,Bindings} = quod_client_result:decode_binding(Binding), Bindings;
bindings({ok,_,{normalized,{committed,[Binding],_}}}) ->
    {ok,Bindings} = quod_client_result:decode_binding(Binding), Bindings;
bindings({ok,_,{normalized,Other}}) -> error({unexpected_result,Other}).
denied(C,Ns,Goal) ->
    {Reply,_} = signed(C,scoped(Ns,Goal)),
    case Reply of
        {ok,_,{normalized,{failed,_}}} -> ok;
        {ok,_,{normalized,Result}} -> error({unexpected_acceptance,Goal,element(1,Result)})
    end.
wait_complete({ok,Evidence,{normalized,{committed,_,_}}}) ->
    Op = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state:=terminal},quod_ct:await_operation_complete(element(2,Op),Op,10000)).
edit(Ns,Goal) -> ?assertMatch({ok,_,_},quod_prolog:execute(Ns,Goal)).
holds(Ns,Goal) -> ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,Goal)).
fails(Ns,Goal) -> ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Goal)).
source(File) ->
    case File of
        "gui_measure.pl" -> quod_ct:gui_terms();
        "gui_scene.pl" -> quod_ct:gui_terms();
        "gui_tools.pl" -> quod_ct:gui_terms();
        "quod_gui.pl" -> quod_ct:gui_terms();
        _ -> quod_prolog:read_terms(filename:join(code:priv_dir(quod),"ontologies/"++File))
    end.
ref(Ns,Id) -> {entity_ref,Ns,quod_simplex:genesis_hash(Ns),Id}.
class_ref(Ns,Class) -> {class_ref,Ns,quod_simplex:genesis_hash(Ns),Class}.
scoped(Ns,Goal) -> {'::',Ns,{',',{current_ontology_identity,Ns,quod_simplex:genesis_hash(Ns)},Goal}}.
conj([G]) -> G;
conj([G|Rest]) -> {',',G,conj(Rest)}.
default_dimensions() -> {box,{q,10,<<"m">>},{q,10,<<"m">>},{q,10,<<"m">>}}.

withdraw_views(C,Ns,Ref) -> [V || V = {operation_view,withdraw,_,_,_,_,_,_,_,_} <- views(C,Ns,Ref)].

space_class() -> {':',quod,{':',space,space}}.
space(Goal) -> {'::',<<"quod:space">>,Goal}.
