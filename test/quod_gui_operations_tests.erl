-module(quod_gui_operations_tests).
-include_lib("eunit/include/eunit.hrl").

prebound_creation_output_is_refused_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        Subject = class_ref(Ns,space),
        {operation_view,create,Subject,Revision,_,_,Values,create,_,_} = create_view(C,Ns),
        denied(C,Ns,conj([
            {gui_operation_bind,Subject,create,Revision,create,Values,{'Goal'},{'Results'}},
            {'=',{'Results'},[{result,space,ref(Ns,space_name)}]},
            {call,{'Goal'}}])),
        fails(Ns,{instance_of,space,space_name})
    end) end}.

execution_preserves_authored_output_aliases_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        Subject = class_ref(Ns,space),
        Original = hd([Clause || Clause = {':-',{gui_form,space_create,_,_},_} <-
            quod_prolog:read_terms("test/fixtures/gui-operations.pl")]),
        edit(Ns,{retract,Original}),
        Fields = [{field,space_name,{'Name'}},{field,space_extent,{'Extent'}}],
        Inputs = [{attribute,name,{'Name'}},{attribute,dimensions,{'Extent'}}],
        Create = fun(Id) -> {with_build_plan,Inputs,{assert,{instance_of,space,Id}}} end,
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
        Subject = class_ref(Ns,space),
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
        ?assertEqual(26,byte_size(Id)), holds(Ns,{instance_of,space,Id}),
        wait_complete(Created),
        {ok,_,{operation_outcome,_,Outcome}} = quod_personal_agent_tests:lookup(C,Bytes),
        ?assert(lists:member([{result,space,Ref}],[V || {_,V} <- maps:get(bindings,Outcome)]))
    end) end}.

offered_creation_and_instance_operation_test_() ->
    {timeout, 120, fun() -> with_operations(fun(C = #{storage := Ns, namespace := ActorNs}) ->
        Subject = class_ref(Ns, space),
        View = create_view(C, Ns),
        {operation_view, create, Subject, Revision, Tree, _, Values, create, [space], requires_input} = View,
        ?assertMatch({component, space_create, form, _, _}, Tree),
        ?assertEqual([{field,space_name,<<"Space">>},
                      {field,space_extent,default_dimensions()}], Values),
        %% An unplaced class has a create offer without an existing instance.
        edit(Ns, {retract,{instance_of,space,room}}),
        edit(Ns, {retract,{instance_of,space,closed}}),
        ?assertEqual(View, create_view(C, Ns)),
        %% Repeated discovery neither creates identities nor changes disk state.
        quod_lobby_tests:assert_read_has_no_io(fun() ->
            [begin
                {ok,[_],_} = quod_prolog:prove_ro(Ns,{gui_operations,Subject,{'Views'}})
             end || _ <- [first,repeat]]
        end),
        Values2 = lists:keyreplace(space_name,2,Values,{field,space_name,<<"Offered">>}),
        %% One submitted ordinary goal binds a named output through the real
        %% assertion hook, constructor, U->A instruction and outcome owners.
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
        edit(Ns,{assertz,{class_permission,space,space_enter,allow}}),
        edit(Ns,{retract,{class_permission,space,space_enter,{check,creation_entry}}}),
        {Placed,_} = signed(C,scoped(Ns,{space_place,Id,0,Destination})), wait_complete(Placed),
        [Withdraw] = views(C,Ns,Ref),
        {operation_view,withdraw,Ref,WR,_,_,WV,WC,[],available} = Withdraw,
        ?assertEqual([{field,{destination,Id},Destination}],WV),
        Bad = [{field,{destination,Id},ref(ActorNs,room)}],
        denied(C,Ns,{gui_operation_bind,Ref,withdraw,WR,WC,Bad,{'G'},{'R'}}),
        denied(C,Ns,{gui_operation_bind,ref(Ns,closed),withdraw,WR,WC,WV,{'G'},{'R'}}),
        {Withdrawn,_} = signed(C,scoped(Ns,conj([
            {gui_operation_bind,Ref,withdraw,WR,WC,WV,{'G'},{'R'}},{call,{'G'}}]))),
        wait_complete(Withdrawn), holds(Ns,{space_assignment,Id,2,none}),
        ?assertEqual([],views(C,Ns,Ref)),
        denied(C,Ns,{gui_operation_bind,Ref,withdraw,WR,WC,WV,{'G'},{'R'}}),
        NextDestination = ref(ActorNs,room),
        {Replaced,_} = signed(C,scoped(Ns,{space_place,Id,2,NextDestination})), wait_complete(Replaced),
        [{operation_view,withdraw,Ref,NextR,_,_,NextV,WC,[],available}] = views(C,Ns,Ref),
        ?assertNotEqual(WR,NextR),
        ?assertEqual([{field,{destination,Id},NextDestination}],NextV),
        denied(C,Ns,{gui_operation_bind,Ref,withdraw,WR,WC,WV,{'G'},{'R'}}),
        denied(C,Ns,{gui_operation_bind,Ref,withdraw,NextR,WC,WV,{'G'},{'R'}})
    end) end}.

binding_refuses_invalid_or_changed_contract_test_() ->
    {timeout, 120, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        Subject = class_ref(Ns,space),
        {operation_view,create,Subject,R,_,_,Values,create,_,_} = create_view(C,Ns),
        Bind = fun(S,Rev,V) -> {gui_operation_bind,S,create,Rev,create,V,{'G'},{'R'}} end,
        [denied(C,Ns,Bind(S,R,Values)) || S <- [class_ref(Ns,missing),
            setelement(3,Subject,<<0:256>>),ref(Ns,room),class_ref(<<"wrong">>,space)]],
        [denied(C,Ns,Bind(Subject,R,V)) || V <- [tl(Values),Values++[hd(Values)],
            Values++[{field,space,chosen_id}], Values++[{field,continuation,{assertz,injected}}],
            lists:keyreplace(space_name,2,Values,{field,space_name,<<"Forbidden">>}),
            lists:keyreplace(space_name,2,Values,{field,space_name,42}),
            lists:keyreplace(space_extent,2,Values,{field,space_extent,bad_extent})]],
        denied(C,Ns,{gui_operation_bind,Subject,create,R,create,Values,{assertz,injected},{'R'}}),
        denied(C,Ns,{gui_operation_bind,Subject,create,R,create,Values,{'G'},[{result,space,chosen_id}]}),
        {SchemaReply,_} = signed(C,scoped(Ns,
            {gui_definition,space_create,{'Schema'},{'_'},{'_'},{'_'},{'_'}})),
        Schema = proplists:get_value(<<"V0">>,bindings(SchemaReply)),
        denied(C,Ns,{gui_bind,space_create,Schema,create,Values,{'G'}}),
        denied(C,Ns,{gui_schema,space_create,{'Revision'},{'Tree'}}),
        denied(C,Ns,{with_build_plan,[{attribute,name,<<"Forbidden">>}],
                    {assert,{instance_of,space,{'Space'}}}}),
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
        denied(C,Ns,{with_build_plan,[],{assert,{instance_of,space,{'Space'}}}}),
        denied(C,Ns,conj([{assertz,creation_enabled},Bind(Subject,R2,Values)])),
        fails(Ns,creation_enabled), fails(Ns,injected), fails(Ns,unoffered)
    end) end}.

foreign_recipe_is_anchored_and_selects_target_owned_form_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns,destination := Recipes}) ->
        Subject = class_ref(Ns,space),
        Original = hd([Clause || Clause = {':-',{class_eidolon,space,{operation,class},create,_},_} <-
            quod_prolog:read_terms("test/fixtures/gui-operations.pl")]),
        edit(Ns,{retract,Original}),
        Offer = {class_eidolon,space,{operation,class},create,
                 {recipe,Recipes,quod_simplex:genesis_hash(Recipes),remote_create}},
        edit(Ns,{assertz,Offer}),
        edit(Recipes,{assertz,{eidolon,remote_create,
            {subject,{ontology_ref,Ns,quod_simplex:genesis_hash(Ns)},{class,space}},
            {operation,space_create}}}),
        {operation_view,create,Subject,R,_,_,Values,create,[space],requires_input} = create_view(C,Ns),
        {Created,_} = signed(C,scoped(Ns,conj([
            {gui_operation_bind,Subject,create,R,create,Values,{'G'},{'Results'}},{call,{'G'}}]))),
        wait_complete(Created),
        edit(Ns,{retract,Offer}),
        edit(Ns,{assertz,setelement(5,Offer,{recipe,Recipes,<<0:256>>,remote_create})}),
        ?assertEqual([],views(C,Ns,Subject))
    end) end}.

malformed_outputs_and_ambiguous_offers_are_refused_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        Subject = class_ref(Ns,space),
        [_] = views(C,Ns,Subject),
        edit(Ns,{assertz,{class_eidolon,space,{operation,class},create,
                         {recipe,Ns,quod_simplex:genesis_hash(Ns),other_recipe}}}),
        ?assertEqual([],views(C,Ns,Subject)),
        edit(Ns,{retract,{class_eidolon,space,{operation,class},create,
                          {recipe,Ns,quod_simplex:genesis_hash(Ns),other_recipe}}}),
        Original = hd([Clause || Clause = {':-',{gui_form,space_create,_,_},_} <-
            quod_prolog:read_terms("test/fixtures/gui-operations.pl")]),
        edit(Ns,{retract,Original}),
        Name = {'Name'}, Extent = {'Extent'}, Output = {'Output'},
        Fields = [{field,space_name,Name},{field,space_extent,Extent}],
        Inputs = [{attribute,name,Name},{attribute,dimensions,Extent}],
        Goal = {with_build_plan,Inputs,{assert,{instance_of,space,Output}}},
        Valid = [{result,space,Output}],
        [begin
            Form = {gui_form,space_create,Fields,{submit,create,G,{operation,P,Results}}},
            edit(Ns,{assertz,Form}),
            ?assertEqual([],views(C,Ns,Subject)),
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
        [_] = views(C,Ns,Subject)
    end) end}.

discovery_is_read_only_even_in_execute_test_() ->
    {timeout, 90, fun() -> with_operations(fun(C = #{storage := Ns}) ->
        %% Authored recipe discovery cannot smuggle a mutation through an
        %% execute request; the existing read-only proof boundary rejects it.
        Head = {eidolon,space_create,{subject,{'Target'},{class,space}},{operation,space_create}},
        edit(Ns,{retract,{':-',Head,{'Body'}}}),
        edit(Ns,{assertz,{':-',Head,{assertz,discovery_mutated}}}),
        {Reply,_} = signed(C,scoped(Ns,{gui_operations,class_ref(Ns,space),{'Views'}})),
        ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},Reply),
        fails(Ns,discovery_mutated)
    end) end}.

with_operations(Fun) ->
    Sources = source("gui_instance.pl") ++ source("gui_operation.pl") ++
              quod_prolog:read_terms("test/fixtures/gui-operations.pl"),
    quod_space_creation_tests:with_spaces(fun(C = #{identity := Node,directory := Dir}) ->
        Gui = <<"quod:gui">>,
        Sup = quod_agent_hosting_tests:start_ontology(Gui,Dir,Node,[],source("quod_gui.pl")),
        try
            [edit(Ns,{assertz,{gui_vocabulary,Gui,quod_simplex:genesis_hash(Gui)}})
             || Ns <- [maps:get(namespace,C),maps:get(storage,C),maps:get(destination,C)]],
            Fun(C)
        after quod_agent_hosting_tests:stop_ontology(Sup) end
    end,Sources).

create_view(C,Ns) -> [View] = views(C,Ns,class_ref(Ns,space)), View.
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
    ?assertMatch({ok,_,{normalized,{failed,_}}},Reply).
wait_complete({ok,Evidence,{normalized,{committed,_,_}}}) ->
    Op = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state:=terminal},quod_ct:await_operation_complete(element(2,Op),Op,10000)).
edit(Ns,Goal) -> ?assertMatch({ok,_,_},quod_prolog:execute(Ns,Goal)).
holds(Ns,Goal) -> ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,Goal)).
fails(Ns,Goal) -> ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Goal)).
source(File) -> quod_prolog:read_terms(filename:join(code:priv_dir(quod),"ontologies/"++File)).
ref(Ns,Id) -> {entity_ref,Ns,quod_simplex:genesis_hash(Ns),Id}.
class_ref(Ns,Class) -> {class_ref,Ns,quod_simplex:genesis_hash(Ns),Class}.
scoped(Ns,Goal) -> {'::',Ns,{',',{current_ontology_identity,Ns,quod_simplex:genesis_hash(Ns)},Goal}}.
conj([G]) -> G;
conj([G|Rest]) -> {',',G,conj(Rest)}.
default_dimensions() -> {box,{q,100,<<"m">>},{q,100,<<"m">>},{q,100,<<"m">>}}.
