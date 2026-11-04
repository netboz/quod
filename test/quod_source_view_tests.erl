-module(quod_source_view_tests).
-include_lib("eunit/include/eunit.hrl").

source_authorization_is_retained_and_withdrawn_test_() ->
    {timeout,90,fun() ->
        Dir=filename:join("/tmp","quod-source-view-" ++ integer_to_list(erlang:unique_integer([positive]))),
        Ctx=quod_lobby_tests:start(Dir,[],extended_system_catalogue,[]),
        Gui = <<"quod:gui">>, Anchor=quod_simplex:genesis_hash(Gui),
        Target={ontology_ref,Gui,Anchor}, Session=quod_gui_question_tests:gui_session(Ctx), Parent=self(),
        {Socket,Monitor}=spawn_monitor(fun()->quod_gui_question_tests:gui_socket(Parent,#{peer=>{{127,0,0,1},0}},false) end),
        Open=fun(Extra)-> Socket!{client,quod_gui_question_tests:gui_open_message(Ctx,Session,source_access,Gui,Anchor,Target,Extra)} end,
        Root=quod_ontology:root_ns(),
        [Policy]=[T || T={':-',{system_source_access,_,_},_} <-
            quod_prolog:read_terms(filename:join(code:priv_dir(quod),"ontologies/quod_root.pl"))],
        Denied={':-',{system_source_access,{'_'},{'_'}},fail},
        try
            Open(0),
            ?assertMatch(#{<<"kind">>:=<<"source_access">>,<<"value">>:=<<"read_only">>},frame(Socket,<<"projection">>)),
            Before=state(Socket), ?assert(maps:is_key(Root,maps:get(heights,Before))),
            quod_lobby_tests:assert_read_has_no_io(fun()->
                [begin Open(Extra),_=frame(Socket,<<"projection">>) end || Extra<-[1000,2000,3000]]
            end),
            Renewed=state(Socket),
            ?assertEqual(maps:get(dependency_monitors,Before),maps:get(dependency_monitors,Renewed)),
            Socket!{timeout,maps:get(timer,Before),expired},
            ?assertEqual(true,maps:get(installed,state(Socket))),
            %% Revocation advances the actual permission owner; the view loses
            %% content before any subsequent source read can succeed.
            {ok,_,_}=quod_prolog:execute(Root,{transaction,{',',{retract,Policy},{assertz,Denied}}}),
            _=frame(Socket,<<"refresh">>), Open(4000),_=frame(Socket,<<"unavailable">>),
            ?assertNot(maps:is_key(installed,state(Socket))),
            {ok,_,_}=quod_prolog:execute(Root,{transaction,{',',{retract,Denied},{assertz,Policy}}}),
            Open(5000),_=frame(Socket,<<"projection">>),
            Wrong={ontology_ref,Gui,<<0:256>>},
            Socket!{client,quod_gui_question_tests:gui_open_message(Ctx,Session,source_access,Gui,Anchor,Wrong,6000)},
            _=frame(Socket,<<"unavailable">>),?assertNot(maps:is_key(installed,state(Socket)))
        after
            Socket!stop,
            receive {'DOWN',Monitor,process,Socket,_}->ok after 5000->error(source_view_not_disposed) end,
            quod_lobby_tests:stop(Ctx),file:del_dir_r(Dir)
        end
    end}.

long_namespace_source_view_keeps_authorization_test_() ->
    {timeout,120,fun() ->
        Dir=filename:join("/tmp","quod-long-source-view-" ++
                          integer_to_list(erlang:unique_integer([positive]))),
        Ctx=quod_lobby_tests:start(Dir,[],extended_system_catalogue,[]),
        Gui = <<"quod:gui">>, GuiAnchor=quod_simplex:genesis_hash(Gui),
        Long=binary:copy(<<"n">>,1024), Root=quod_ontology:root_ns(),
        {_,GuiConfig}=maps:get(Gui,maps:get(ontologies,Ctx)),
        {LongOwner,_}=quod_lobby_tests:start_namespace(
            Long,GuiConfig#{data_dir=>filename:join(Dir,"long-target")}),
        LongAnchor=quod_simplex:genesis_hash(Long),
        ?assertMatch(<<_:256>>,LongAnchor),
        Target={ontology_ref,Long,LongAnchor},
        try
            ?assertMatch({ok,_,_},quod_prolog:execute(
                Root,{assertz,{system_ontology,Long,LongAnchor}})),
            Session=quod_gui_question_tests:gui_session(Ctx), Parent=self(),
            {Socket,Monitor}=spawn_monitor(fun()->
                quod_gui_question_tests:gui_socket(Parent,#{peer=>{{127,0,0,1},0}},false)
            end),
            Open=fun(Subject,Extra)->Socket!{client,
                quod_gui_question_tests:gui_open_message(
                    Ctx,Session,source_access,Gui,GuiAnchor,Subject,Extra)} end,
            [Policy]=[T || T={':-',{system_source_access,_,_},_} <-
                quod_prolog:read_terms(filename:join(code:priv_dir(quod),
                                                     "ontologies/quod_root.pl"))],
            Denied={':-',{system_source_access,{'_'},{'_'}},fail},
            try
                Open(Target,0),
                ?assertMatch(#{<<"kind">>:=<<"source_access">>,
                               <<"value">>:=<<"read_only">>},
                             frame(Socket,<<"projection">>)),
                quod_lobby_tests:assert_read_has_no_io(fun()->
                    Open(Target,1000),_=frame(Socket,<<"projection">>)
                end),
                Open({ontology_ref,Long,<<0:256>>},2000),
                _=frame(Socket,<<"unavailable">>),
                ?assertMatch({ok,_,_},quod_prolog:execute(
                    Root,{transaction,{',',{retract,Policy},{assertz,Denied}}})),
                Open(Target,3000),_=frame(Socket,<<"unavailable">>),
                ?assertNot(maps:is_key(installed,state(Socket)))
            after
                Socket!stop,
                receive {'DOWN',Monitor,process,Socket,_}->ok
                after 5000->error(long_source_view_not_disposed) end
            end
        after
            quod_lobby_tests:stop_process(LongOwner),
            quod_lobby_tests:stop(Ctx),file:del_dir_r(Dir)
        end
    end}.

frame(Socket,Type) ->
    receive {gui_view,Socket,#{<<"type">>:=Type}=Message}->Message;
            {gui_view,Socket,Unexpected}->error({unexpected_source_view,Unexpected})
    after 10000->error({missing_source_view,Type}) end.
state(Socket) ->
    Ref=make_ref(),Socket!{inspect,Ref},
    receive {Ref,State}->State after 5000->error(source_view_state_missing) end.
