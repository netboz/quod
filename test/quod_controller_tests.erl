-module(quod_controller_tests).
-include_lib("eunit/include/eunit.hrl").

preferences_use_existing_instruction_and_form_test_() ->
    {timeout,120,fun() -> with_controller(fun(C = #{namespace := Ns, controllers := Gui}) ->
        %% Default reads have no preference write or view-side registration.
        Defaults = read(Gui,{controller_default,{'V'}}),
        Mapping = read(Gui,{controller_configuration,Defaults,{'V'}}),
        ?assertMatch({mapping,1,_,[_|_],[{profile,htc_vive_controller,_}]},Mapping),
        {mapping,1,_,_,[{profile,htc_vive_controller,
          {controller,_,_,_,{tracked_model,grip,{asset,_,_,Bounds,_}}}}]} = Mapping,
        %% The real projection must carry numbers, not unevaluated unary terms.
        ?assertEqual({bounds,-59,-70,-117,59,23,106},Bounds),
        Digest = read(Ns,{term_digest,Mapping,{'V'}}),
        Read = fun() ->
            Result = submit_read(C,{'::',<<"quod:user">>,{controller_preferences_view,reference(C,me),{'V'}}}),
            ?assertMatch({controller_view,0,Digest,Mapping},value(Result))
        end,
        quod_outcome_result_tests:assert_unchanged_reads([Ns,Gui],Read,0),
        ?assertMatch(fail,quod_prolog:prove_ro(Ns,{attribute,me,controller_preferences,{'_'}})),
        Subject = {entity_ref,Ns,quod_simplex:genesis_hash(Ns),me},
        [Offer] = value(submit_read(C,{gui_operations,Subject,{'V'}})),
        {operation_view,controller_settings,Subject,Revision,_,_,Fields,controller_save,_,requires_input} = Offer,
        {Reply,Bytes} = instruct(C,{gui_operation,Subject,controller_settings,Revision,controller_save,Fields,{'V'}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Reply),
        ?assertEqual([{result,revision,1}],value(Reply)),
        %% Original outcome lookup does not replay Save.
        ?assertMatch({ok,_,{operation_outcome,_,#{status:=committed}}},quod_personal_agent_tests:lookup(C,Bytes)),
        ?assertMatch({preferences,1,_},read(Ns,{attribute,me,controller_preferences,{'V'}})),
        {Stale,_} = instruct(C,{'::',<<"quod:user">>,{controller_preferences_set,reference(C,me),0,Digest,Defaults,{'V'}}}),
        ?assertMatch({ok,_,{normalized,{failed,_}}},Stale),
        %% Explicit defaults is still a new revision, not absent revision zero.
        Current = value(submit_read(C,{'::',<<"quod:user">>,{controller_preferences_view,reference(C,me),{'V'}}})),
        {controller_view,1,CurrentDigest,_} = Current,
        {Reset,_} = instruct(C,{'::',<<"quod:user">>,{controller_preferences_set,reference(C,me),1,CurrentDigest,Defaults,{'V'}}}),
        ?assertEqual(2,value(Reset)),
        {Refused,_} = instruct(C,{'::',<<"quod:user">>,{controller_preferences_set,reference(C,other),0,Digest,Defaults,{'V'}}}),
        ?assertMatch({ok,_,{normalized,{failed,_}}},Refused)
    end) end}.

shared_mapping_rejects_conflicts_and_unknown_outputs_test_() ->
    {timeout,90,fun() -> with_controller(fun(#{controllers:=Gui}) ->
        {settings,Roles,Set,[]} = read(Gui,{controller_default,{'V'}}),
        Invalid = [
          {settings,Roles,Set,[{disable,select}]},
          {settings,Roles,Set,[{disable,menu},{disable,menu}]},
          {settings,Roles,Set,[{replace,{bind,menu,navigation,pad,{radial,240},{local,menu}}}]},
          {settings,Roles,Set,[{replace,{bind,select,any,trigger,press_release,{local,execute}}}]},
          {settings,Roles,Set,[{replace,{bind,select,any,grip,press_release,{local,select}}}]},
          {settings,Roles,Set,[{replace,{bind,drive,navigation,pad,{axes_while,trigger},{control,drive}}}]},
          {settings,Roles,Set,[{disable,menu},{replace,{bind,drive,any,pad,{axes_while,grip},{control,drive}}}]},
          {settings,Roles,Set,[{replace,{bind,teleport,navigation,pad,{sector,forward,500,grip},{control,{teleport,1001}}}}]}],
        [?assertMatch(fail,quod_prolog:prove_ro(Gui,{controller_configuration,S,{'_'}})) || S <- Invalid],
        Swapped = {settings,[{role,navigation,{hand,right}},{role,menu,{hand,left}}],Set,[]},
        ?assertMatch({mapping,1,_,_,_},read(Gui,{controller_configuration,Swapped,{'V'}}))
    end) end}.

invalid_saved_preferences_offer_fenced_reset_test_() ->
    {timeout,120,fun() -> with_controller(fun(C=#{namespace:=Ns,controllers:=Shared}) ->
        Defaults=read(Shared,{controller_default,{'V'}}),
        Invalid={settings,[],removed_binding_set,[]},
        Row={attribute,me,controller_preferences,{preferences,7,Invalid}},
        ?assertMatch({ok,_,_},quod_prolog:execute(Ns,{assertz,Row})),
        ?assertMatch({controller_view,7,_,invalid_settings},
            value(submit_read(C,{'::',<<"quod:user">>,{controller_preferences_view,reference(C,me),{'V'}}}))),
        Subject={entity_ref,Ns,quod_simplex:genesis_hash(Ns),me},
        [Offer]=value(submit_read(C,{gui_operations,Subject,{'V'}})),
        {operation_view,controller_settings,Subject,Revision,_,_,[],controller_restore,_,_}=Offer,
        Digest=read(Ns,{term_digest,{invalid_controller_settings,Invalid},{'V'}}),
        %% Even an administrative edit at the same revision invalidates the offer.
        Other={settings,[],another_removed_set,[]},
        OtherRow={attribute,me,controller_preferences,{preferences,7,Other}},
        ?assertMatch({ok,_,_},quod_prolog:execute(Ns,{',',{retract,Row},{assertz,OtherRow}})),
        {Stale,_}=instruct(C,{'::',<<"quod:user">>,{controller_preferences_set,reference(C,me),7,Digest,Defaults,{'V'}}}),
        ?assertMatch({ok,_,{normalized,{failed,_}}},Stale),
        {OldForm,_}=instruct(C,{gui_operation,Subject,controller_settings,Revision,controller_restore,[],{'V'}}),
        ?assertMatch({ok,_,{normalized,{failed,_}}},OldForm),
        [Fresh]=value(submit_read(C,{gui_operations,Subject,{'V'}})),
        {operation_view,controller_settings,Subject,NextRevision,_,_,[],controller_restore,_,_}=Fresh,
        {Reset,_}=instruct(C,{gui_operation,Subject,controller_settings,NextRevision,controller_restore,[],{'V'}}),
        ?assertEqual([{result,revision,8}],value(Reset)),
        ?assertMatch({controller_view,8,_,_},value(submit_read(C,{'::',<<"quod:user">>,{controller_preferences_view,reference(C,me),{'V'}}}))),
        %% Duplicate rows have no safe implicit repair revision.
        ?assertMatch({ok,_,_},quod_prolog:execute(Ns,{assertz,OtherRow})),
        ?assertEqual([],value(submit_read(C,{gui_operations,Subject,{'V'}})))
    end) end}.

private_preferences_follow_the_storing_owner_acl_test_() ->
    {timeout,90,fun() -> with_controller(fun(C=#{namespace:=Ns,controllers:=Shared,directory:=Dir,identity:=Node}) ->
        Defaults=read(Shared,{controller_default,{'V'}}),
        Mapping=read(Shared,{controller_configuration,Defaults,{'V'}}),
        Digest=read(Ns,{term_digest,Mapping,{'V'}}),
        Save={'::',<<"quod:user">>,{controller_preferences_set,reference(C,me),0,Digest,Defaults,{'V'}}},
        {Direct,DirectSig}=quod_personal_agent_tests:request(C,execute,Save),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(Direct,DirectSig)),
        {Key,_}=Pair=quod_identity:generate(),OtherNs = <<"controller-other-human">>,
        Sup=quod_agent_hosting_tests:start_ontology(OtherNs,Dir,Node,[],
            quod_personal_agent_tests:user_terms()++[{instance_of,{':',quod,{':',user,human_user}},me},{agent_key,me,Key,active}]),
        Other=C#{human=>{agent_instance_ref,OtherNs,quod_simplex:genesis_hash(OtherNs),me},human_pair=>Pair},
        try
            ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},
                submit_read(Other,{'::',Ns,{'::',<<"quod:user">>,{controller_preferences_view,reference(C,me),{'V'}}}})),
            {Bytes,Signature}=quod_personal_agent_tests:request(Other,execute,{'::',Ns,Save}),
            ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(Bytes,Signature)),
            ?assertMatch({preferences,1,_},read(Ns,{attribute,me,controller_preferences,{'V'}}))
        after quod_agent_hosting_tests:stop_ontology(Sup) end
    end) end}.

with_controller(Fun) ->
    Sources = lists:append([source(F) || F <- ["gui_instance.pl"]]),
    quod_personal_agent_tests:with_personal(fun(C=#{namespace:=Ns,directory:=Dir,identity:=Node}) ->
        Gui = <<"quod:gui">>,
        Sup=quod_agent_hosting_tests:start_ontology(Gui,Dir,Node,[],quod_ct:gui_terms()),
        Shared = <<"quod:controllers">>,
        CSup=quod_agent_hosting_tests:start_ontology(Shared,Dir,Node,[],source("quod_controllers.pl")),
        try
            ?assertMatch({ok,_,_},quod_prolog:execute(Ns,{assertz,{gui_vocabulary,Gui,quod_simplex:genesis_hash(Gui)}})),
            ?assertMatch({ok,_,_},quod_prolog:execute(Ns,{assertz,{controllers_vocabulary,Shared,quod_simplex:genesis_hash(Shared)}})),
            ?assertMatch({ok,_,_},quod_prolog:execute(<<"quod:user">>,{assertz,{gui_vocabulary,Gui,quod_simplex:genesis_hash(Gui)}})),
            ?assertMatch({ok,_,_},quod_prolog:execute(<<"quod:user">>,{assertz,{controllers_vocabulary,Shared,quod_simplex:genesis_hash(Shared)}})),
            Fun(C#{controllers=>Shared})
        after quod_agent_hosting_tests:stop_ontology(CSup),quod_agent_hosting_tests:stop_ontology(Sup) end
    end,Sources).
reference(#{namespace:=Ns},Human) -> {entity_ref,Ns,quod_simplex:genesis_hash(Ns),Human}.
source(F) ->
    case F of
        "gui_measure.pl" -> quod_ct:gui_terms();
        "gui_scene.pl" -> quod_ct:gui_terms();
        "gui_tools.pl" -> quod_ct:gui_terms();
        "quod_gui.pl" -> quod_ct:gui_terms();
        _ -> quod_prolog:read_terms(filename:join(code:priv_dir(quod),"ontologies/"++F))
    end.
read(Ns,Goal) -> {ok,[#{'V':=V}],_}=quod_prolog:prove_ro(Ns,Goal),V.
submit_read(C,G) ->
    {Bytes,Signature}=quod_personal_agent_tests:request(C,read,G),
    quod_client_goal_ingress:submit(Bytes,Signature).
instruct(C,G) ->
    quod_personal_agent_tests:await_runtime_ready(maps:get(namespace,C)),
    {I,B}=quod_personal_agent_tests:instruction(C,G),
    {quod_personal_agent_tests:instruct(C,submit,I),B}.
value({ok,_,{normalized,{read,_,{answers,_,[B]}}}}) -> binding(B);
value({ok,_,{normalized,{committed,[B],_}}}) -> binding(B).
binding(B) -> {ok,[{_,V}]}=quod_client_result:decode_binding(B),V.

signed_controller_view_uses_existing_subscription_owner_test_() ->
    {timeout,90,fun() -> with_controller(fun(C=#{namespace:=Ns,controllers:=Shared}) ->
        Parent=self(),
        Socket=spawn_link(fun() -> quod_gui_question_tests:gui_socket(Parent,#{peer=>{{127,0,0,1},0}},false) end),
        try
            Socket ! {client,view_message(C,me)},
            First=receive {gui_view,Socket,Frame} -> Frame after 10000 -> error(no_controller_view) end,
            ?assertMatch(#{<<"type">>:=<<"projection">>,<<"kind">>:=<<"controller_preferences">>},First),
            Defaults=read(Shared,{controller_default,{'V'}}),
            Mapping=read(Shared,{controller_configuration,Defaults,{'V'}}),
            Digest=read(Ns,{term_digest,Mapping,{'V'}}),
            {Saved,_}=instruct(C,{'::',<<"quod:user">>,{controller_preferences_set,reference(C,me),0,Digest,Defaults,{'V'}}}),
            ?assertEqual(1,value(Saved)),
            receive {gui_view,Socket,#{<<"type">>:=<<"refresh">>}} -> ok
            after 10000 -> error(missing_controller_refresh) end,
            Socket ! {client,view_message(C,me)},
            Next=receive {gui_view,Socket,Frame2} -> Frame2 after 10000 -> error(no_updated_view) end,
            ?assertMatch(#{<<"type">>:=<<"projection">>},Next),
            ?assertNotEqual(maps:get(<<"value">>,First),maps:get(<<"value">>,Next)),
            Socket ! {client,view_message(C,other)},
            receive {gui_view,Socket,#{<<"type">>:=<<"unavailable">>}} -> ok
            after 10000 -> error(private_settings_disclosed) end
        after Socket ! stop end
    end) end}.

view_message(#{namespace:=Ns,human_pair:={Pub,_}=Pair,session:=Session},Human) ->
    Anchor=quod_simplex:genesis_hash(Ns),
    Text=fun quod_client_goal_parser:value_text/1,
    Goal=iolist_to_binary([Text(Ns)," :: (current_ontology_identity(",Text(Ns),",",Text(Anchor),
        "),",Text(<<"quod:user">>),"::controller_preferences_view(",Text({entity_ref,Ns,Anchor,Human}),",View))."]),
    {ok,Bytes}=quod_client_goal:encode(#{network_identity=><<42:256>>,agent_namespace=>Ns,
        agent_genesis_anchor=>Anchor,agent_instance_text=><<"me.">>,signing_public_key=>Pub,
        operation_id=>crypto:strong_rand_bytes(32),not_after_ms=>quod_time:now_ms()+25000,
        mode=>read,parser_version=>3,goal_text=>Goal}),
    Enc=fun(B)->base64:encode(B,#{mode=>urlsafe,padding=>false}) end,
    iolist_to_binary(json:encode(#{type=>open,view_kind=>controller_preferences,session_id=>Enc(Session),
        view_namespace=>Ns,view_anchor=>Enc(Anchor),request=>Enc(Bytes),
        signature=>Enc(quod_identity:sign(Bytes,quod_identity:key_term(Pair)))})).

invalid_controller_projection_retains_repair_subscription_test_() ->
    {timeout,90,fun() -> with_controller(fun(C=#{namespace:=Ns,controllers:=Shared}) ->
        Invalid={settings,[],removed_set,[]},
        ?assertMatch({ok,_,_},quod_prolog:execute(Ns,
            {assertz,{attribute,me,controller_preferences,{preferences,7,Invalid}}})),
        Parent=self(),
        Socket=spawn_link(fun() -> quod_gui_question_tests:gui_socket(Parent,#{peer=>{{127,0,0,1},0}},false) end),
        try
            Socket ! {client,view_message(C,me)},
            First=receive {gui_view,Socket,Frame} -> Frame after 10000 -> error(no_invalid_controller_view) end,
            ?assertMatch(#{<<"type">>:=<<"projection">>},First),
            ?assertNotEqual(nomatch,binary:match(maps:get(<<"value">>,First),<<"invalid_settings">>)),
            Subject={entity_ref,Ns,quod_simplex:genesis_hash(Ns),me},
            [Offer]=value(submit_read(C,{gui_operations,Subject,{'V'}})),
            {operation_view,controller_settings,Subject,Revision,_,_,[],controller_restore,_,available}=Offer,
            {Reset,_}=instruct(C,{gui_operation,Subject,controller_settings,Revision,controller_restore,[],{'V'}}),
            ?assertEqual([{result,revision,8}],value(Reset)),
            receive {gui_view,Socket,#{<<"type">>:=<<"refresh">>}} -> ok
            after 10000 -> error(repair_subscription_lost) end,
            Socket ! {client,view_message(C,me)},
            Next=receive {gui_view,Socket,Frame2} -> Frame2 after 10000 -> error(no_repaired_controller_view) end,
            ?assertMatch(#{<<"type">>:=<<"projection">>},Next),
            ?assertEqual(nomatch,binary:match(maps:get(<<"value">>,Next),<<"invalid_settings">>)),
            Defaults=read(Shared,{controller_default,{'V'}}),
            ?assertEqual({preferences,8,Defaults},read(Ns,{attribute,me,controller_preferences,{'V'}}))
        after Socket ! stop end
    end) end}.
