-module(quod_gui_question_tests).
-include_lib("eunit/include/eunit.hrl").
-export([with_receiver/3,commit/2,await_commit/1,await_operation/1]).
-export([gui_socket/3,gui_session/1,gui_open_message/7]).

%% Focused transition fixtures seed accepted rows. The live-opening fixture
%% exercises native acceptance and the original atomic transaction together.
native_scope_is_read_only_and_keeps_original_request_test_() ->
    {timeout,60,fun() ->
        Dir = filename:join("/tmp","quod-gui-native-scope-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        Ctx = quod_lobby_tests:start(Dir),
        try
            {Ns,Anchor} = Identity = maps:get(agent,Ctx),
            #{auth := Auth,operation_ref := Operation} = quod_ct:signed_goal_fixture(#{
                target => Identity,network => maps:get(network,Ctx),key_pair => maps:get(key_pair,Ctx),
                deadline => quod_time:now_ms()+30000}),
            {ok,Node} = application:get_env(quod,node_pubkey),
            Read = fun(Target,Goal) -> quod_ask:native_read(Node,Target,Goal,Auth,quod_time:mono_ms()+10000) end,
            ?assertEqual({ok,{current_request_operation,Operation}},
                         Read(Identity,{current_request_operation,Operation})),
            %% The original signed execute bytes authenticate this native read;
            %% they do not cause its embedded assertz goal to execute.
            ?assertMatch({fail,_},read(Ctx,Ns,{saved,ok})),
            ?assertMatch({error,_},Read(Identity,{assertz,native_scope_write})),
            ?assertMatch({fail,_},read(Ctx,Ns,native_scope_write)),
            ?assertMatch({error,_},Read({Ns,<<0:256>>},{current_ontology_identity,Ns,Anchor})),
            ?assertEqual({error,invalid_native_request},quod_ask:native_read(Node,Identity,true,
                setelement(2,Auth,<<0:256>>),quod_time:mono_ms()+10000)),
            no_io(native_scope_repeat,fun() ->
                ?assertEqual({ok,{current_request_operation,Operation}},Read(Identity,{current_request_operation,Operation}))
            end)
        after quod_lobby_tests:stop(Ctx),file:del_dir_r(Dir) end
    end}.

%% The native caller owns the temporary proof, including when it dies before
%% the receiver can reply. The barrier is the existing test-only proof bridge.
native_scope_cancellation_closes_receiver_worker_test_() ->
    {timeout,60,fun() ->
        Dir = filename:join("/tmp","quod-gui-native-cancel-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        Ctx = quod_lobby_tests:start(Dir),
        {ontology_ref,Lobby,_} = maps:get(lobby,Ctx),
        {_,Base} = maps:get(Lobby,maps:get(ontologies,Ctx)),
        Ns = <<"gui:native:cancel">>,
        BeamPath = filename:join(filename:dirname(code:which(quod_predicates)),
                                 "quod_agent_hosting_tests.beam"),
        {ok,_} = file:copy(code:which(quod_agent_hosting_tests),BeamPath),
        {Target,_} = quod_lobby_tests:start_namespace(Ns,Base#{
            data_dir => filename:join(Dir,"target"),
            external_predicate_modules => [quod_agent_hosting_tests],
            genesis_diff => quod_prolog:terms_to_diff([{can_invoke,{'_'},{'_'},{'_'},{'_'}}])}),
        true = quod_reg:reg({host_test,local_proof}),
        try
            Identity = {Ns,quod_simplex:genesis_hash(Ns)},
            #{auth := Auth} = quod_ct:signed_goal_fixture(#{
                target => maps:get(agent,Ctx),network => maps:get(network,Ctx),
                key_pair => maps:get(key_pair,Ctx),deadline => quod_time:now_ms()+30000}),
            {ok,Node} = application:get_env(quod,node_pubkey),
            Parent = self(),
            {Caller,CallerMonitor} = spawn_monitor(fun() ->
                Parent ! {native_reply,self(),quod_ask:native_read(
                    Node,Identity,test_local_wait,Auth,quod_time:mono_ms()+10000)}
            end),
            Worker = receive {local_proof_waiting,W} -> W
                     after 5000 -> error(native_scope_not_entered) end,
            Monitor = monitor(process,Worker),
            exit(Caller,kill),
            receive {'DOWN',CallerMonitor,process,Caller,killed} -> ok
            after 1000 -> error(native_caller_not_killed) end,
            receive {'DOWN',Monitor,process,Worker,_} -> ok
            after 5000 -> error(native_scope_survived_caller) end,
            {Timed,TimedMonitor} = spawn_monitor(fun() ->
                Parent ! {native_reply,self(),quod_ask:native_read(
                    Node,Identity,test_local_wait,Auth,quod_time:mono_ms()+2000)}
            end),
            TimedWorker = receive {local_proof_waiting,W2} -> W2
                          after 5000 -> error(timed_scope_not_entered) end,
            TimedScopeMonitor = monitor(process,TimedWorker),
            receive {native_reply,Timed,Reply} ->
                ?assert(lists:member(Reply,[{error,{proof_limit_exceeded,Ns}},
                                           {error,{scope_expired,Ns}}]))
            after 5000 -> error(native_deadline_not_enforced) end,
            receive {'DOWN',TimedMonitor,process,Timed,normal} -> ok
            after 1000 -> error(native_caller_not_finished) end,
            receive {'DOWN',TimedScopeMonitor,process,TimedWorker,_} -> ok
            after 5000 -> error(native_scope_survived_deadline) end
        after
            gproc:unreg(quod_reg:name({host_test,local_proof})),
            quod_lobby_tests:stop_process(Target),
            quod_lobby_tests:stop(Ctx),file:del_dir_r(Dir),file:delete(BeamPath)
        end
    end}.

native_presentation_uses_original_scope_and_closed_effect_codec_test_() ->
    {timeout,60,fun() ->
        Dir = filename:join("/tmp","quod-gui-native-effect-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        Ctx = quod_lobby_tests:start(Dir), Parent = self(),
        {HumanNs,HumanAnchor} = maps:get(agent,Ctx), Instance = {human_user,test_agent},
        Human = {agent_instance_ref,HumanNs,HumanAnchor,Instance},
        {ok,HumanBytes} = quod_wire_term:encode_canonical(Human),
        {ok,Node} = application:get_env(quod,node_pubkey),
        GuiIdentity = {<<"quod:gui">>,quod_simplex:genesis_hash(<<"quod:gui">>)},
        {Hud,Monitor} = spawn_monitor(fun() -> gui_socket(Parent,#{peer => {127,0,0,1}}) end),
        try
            commit(Ctx,assertions(source("gui_hud.pl") ++
                [{instance_of,human_user,Instance},{gui_pending_allowance,Instance,2}])),
            Session = gui_session(Ctx),
            Hud ! {client,gui_open_message(Ctx,Session,gui_hud,HumanNs,none,0)},
            _ = gui_reply(Hud,<<"projection">>),
            {client_view,{gui_hud,HumanBytes,Connection}} = maps:get(receiver_key,gui_socket_state(Hud)),
            commit(Ctx,{gui_select_receiver,Instance,Node,Connection}),
            _ = gui_reply(Hud,<<"refresh">>),
            Hud ! {client,gui_open_message(Ctx,Session,gui_hud,HumanNs,none,0)},
            _ = gui_reply(Hud,<<"projection">>),
            #{auth := Auth,principal := Principal} = quod_ct:signed_goal_fixture(#{
                target => maps:get(agent,Ctx),network => maps:get(network,Ctx),
                key_pair => maps:get(key_pair,Ctx),deadline => quod_time:now_ms()+30000}),
            Reference = {question_ref,HumanNs,HumanAnchor,{question,<<71:256>>}},
            %% The native receiver passes this opaque descriptor to the client;
            %% the portable browser adapter independently validates its controls.
            Descriptor = {fixture_form,1},
            Goal = {gui_native_prepare,Human,{receiver,Node,Connection},Reference,Descriptor,2,{0}},
            ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},read(Ctx,<<"quod:gui">>,Goal)),
            ?assertEqual({fail,[{not_allowed,<<"quod:gui">>}]},quod_ask:native_read(Node,GuiIdentity,
                {'$quod_gui_receiver_prepare',Human,{receiver,Node,Connection},Reference,Descriptor,2,{0}},
                Auth,quod_time:mono_ms()+10000)),
            Call = gui_async(fun() -> quod_ask:native_read(Node,GuiIdentity,Goal,Auth,quod_time:mono_ms()+10000) end),
            #{<<"token">> := Token64} = gui_reply(Hud,<<"gui_prepare">>),
            gui_ack(Hud,#{type => gui_prepared,token => Token64,accepted => true}),
            {ok,{gui_native_prepare,Human,_,Reference,Descriptor,2,Receipt}} = gui_result(Call),
            {ok,Prepared} = quod_gui_presentation:new(Node,GuiIdentity,HumanBytes,Connection,Receipt,Auth),
            {ok,Bytes} = quod_gui_presentation:prepared_bytes(Prepared),
            ?assertEqual({ok,Prepared},quod_gui_presentation:decode_prepared(Bytes)),
            ?assertMatch({error,_},quod_gui_presentation:decode_prepared(<<Bytes/binary,0>>)),
            {ok,ActionBytes} = quod_durable_term:encode_goal({gui_present,Reference}),
            {ok,Effect} = quod_effect:new(present,Node,Principal,GuiIdentity,
                crypto:hash(sha256,ActionBytes),crypto:hash(sha256,Bytes)),
            ?assert(quod_effect:validate(Effect)),
            ?assertNot(quod_effect:validate(setelement(4,Effect,ontology_lifecycle))),
            ?assertEqual({ok,Prepared},quod_effect:decode_prepared(Effect,Bytes)),
            ?assertMatch({error,_},quod_effect:decode_prepared(setelement(5,setelement(4,Effect,ontology_lifecycle),create),Bytes)),
            ok = quod_effect_journal:configure_limits(2,unlimited),
            {ok,Reservation} = quod_effect_journal:reserve(self()),
            ?assertEqual({error,invalid_direct_effect},quod_effect_journal:stage(Reservation,
                {gui_present,Reference},{gui_presented,Reference},setelement(8,Effect,{node,Node}),Prepared)),
            ?assertMatch({error,_},quod_effect:decode_prepared(setelement(9,Effect,{<<"quod:gui">>,<<0:256>>}),Bytes)),
            ok = quod_effect_journal:stage(Reservation,{gui_present,Reference},{gui_presented,Reference},Effect,Prepared),
            ok = quod_effect_journal:release_reservation(Reservation),
            Released = gui_async(fun() -> quod_gui_presentation:release(Effect,Prepared) end),
            #{<<"token">> := Token64} = gui_reply(Hud,<<"gui_activate">>),
            gui_ack(Hud,#{type => gui_activated,token => Token64,status => active}),
            ?assertEqual(ok,gui_result(Released)),
            no_io(native_effect_release,fun() -> ?assertEqual(ok,quod_gui_presentation:release(Effect,Prepared)) end),
            %% Lose an activation acknowledgement. This is one bounded native
            %% opportunity, not a readiness retry or material outcome expiry.
            LaterReference = setelement(4,Reference,{question,<<72:256>>}),
            ShortGoal = setelement(4,Goal,LaterReference),
            ShortCall = gui_async(fun() -> quod_ask:native_read(Node,GuiIdentity,ShortGoal,Auth,quod_time:mono_ms()+1500) end),
            #{<<"token">> := ShortToken} = gui_reply(Hud,<<"gui_prepare">>),
            gui_ack(Hud,#{type => gui_prepared,token => ShortToken,accepted => true}),
            {ok,{gui_native_prepare,Human,_,LaterReference,Descriptor,2,ShortReceipt}} = gui_result(ShortCall),
            {ok,ShortPrepared} = quod_gui_presentation:new(Node,GuiIdentity,HumanBytes,Connection,ShortReceipt,Auth),
            {ok,ShortBytes} = quod_gui_presentation:prepared_bytes(ShortPrepared),
            {ok,ShortAction} = quod_durable_term:encode_goal({gui_present,LaterReference}),
            {ok,ShortEffect} = quod_effect:new(present,Node,Principal,GuiIdentity,
                crypto:hash(sha256,ShortAction),crypto:hash(sha256,ShortBytes)),
            Lost = gui_async(fun() -> quod_gui_presentation:release(ShortEffect,ShortPrepared) end),
            #{<<"token">> := ShortToken} = gui_reply(Hud,<<"gui_activate">>),
            %% An extra activation before expiry would be an unexpected frame.
            #{<<"token">> := ShortToken} = gui_reply(Hud,<<"gui_expired">>),
            ?assertEqual(ok,gui_result(Lost)),
            ?assertEqual(ok,quod_gui_presentation:release(ShortEffect,ShortPrepared)),
            ?assertMatch({fail,_},read(Ctx,HumanNs,{saved,ok})),
            ?assertMatch({ok,[#{<<"V0">> := []}],_},read(Ctx,HumanNs,{gui_pending_questions,{0}})),
            ?assertEqual({error,invalid_presentation_binding},quod_gui_presentation:release(setelement(8,Effect,{node,Node}),Prepared))
        after
            Hud ! stop,
            receive {'DOWN',Monitor,process,Hud,normal} -> ok after 5000 -> error(hud_not_stopped) end,
            quod_lobby_tests:stop(Ctx),file:del_dir_r(Dir)
        end
    end}.

live_opening_commits_question_hud_and_presentation_together_test_() ->
    {timeout,120,fun() ->
        quod_agent_hosting_tests:with_host(fun(Ctx = #{namespace := Ns,reference := Actor,
                node := Node,key := Key,directory := Dir,identity := Identity}) ->
            ?assertMatch({ok,_,_},quod_ct:rp(Ns,{goal,{agent_hosted,actor,Node,1,Key}})),
            AgentPid = receive {agent_installed,_,Pid,#{reference := Actor},_} -> Pid
            after 10000 -> error(gui_actor_not_installed) end,
            {ok,Journal} = quod_effect_journal:start_link(#{data_dir => filename:join(Dir,"effects")}),
            ok = quod_effect_journal:configure_limits(8,unlimited),
            Admin = {can_invoke,{'_'},Node,{'_'},{'_'}},
            Start = fun(Name,Terms) -> quod_agent_hosting_tests:start_ontology(Name,Dir,Identity,[],[Admin|Terms]) end,
            {Gui,_} = quod_lobby_tests:start_namespace(<<"quod:gui">>,#{
                node_id => maps:get(pubkey,Identity),identity => Identity,mode => create,
                data_dir => filename:join(Dir,"gui"),genesis_diff => quod_prolog:terms_to_diff(source("quod_gui.pl")),
                external_predicate_modules => [quod_agent_predicates,quod_gui_predicates]}),
            {HumanKey,_} = HumanPair = quod_identity:generate(), HumanNs = <<"gui:open-human">>,
            HumanOwner = Start(HumanNs,source("gui_hud.pl") ++ [
                {instance_of,human_user,person},{agent_key,person,HumanKey,active},{gui_pending_allowance,person,4},
                {can_invoke,{'_'},{agent_instance_ref,HumanNs,{'_'},person},{'_'},HumanNs}]),
            HumanAnchor = quod_simplex:genesis_hash(HumanNs), Human = {agent_instance_ref,HumanNs,HumanAnchor,person},
            HumanCtx = #{agent => {HumanNs,HumanAnchor},instance => <<"person.">>,key_pair => HumanPair,network => <<42:256>>},
            AppNs = <<"gui:open-app">>,
            App = Start(AppNs,source("gui_instance.pl") ++ quod_prolog:read_terms("test/fixtures/gui-components.pl") ++ [
                {gui_question_policy,settings,Human,Actor},
                {gui_vocabulary,<<"quod:gui">>,quod_simplex:genesis_hash(<<"quod:gui">>)}]),
            Source = {form_ref,AppNs,quod_simplex:genesis_hash(AppNs),settings},
            Parent = self(), {Hud,M} = spawn_monitor(fun() -> gui_socket(Parent,#{peer => {127,0,0,1}},true) end),
            try
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},node_request(Ctx,execute,scope(Ns,
                    {assertz,{gui_responder_policy,actor,Source,Human}}))),
                %% Missing selection is a pre-dispatch logical failure.
                ?assertMatch({ok,_,{normalized,{failed,_}}},
                    quod_lobby_tests:submit(HumanCtx,execute,scope(AppNs,{gui_open,settings,{0}}))),
                Session = gui_session(HumanCtx),
                Hud ! {client,gui_open_message(HumanCtx,Session,gui_hud,HumanNs,none,0)},
                _ = gui_projection(Hud),
                {client_view,{gui_hud,_,Connection}} = maps:get(receiver_key,gui_socket_state(Hud)),
                commit(HumanCtx,{gui_select_receiver,person,maps:get(pubkey,Identity),Connection}),
                _ = gui_reply(Hud,<<"refresh">>),
                Hud ! {client,gui_open_message(HumanCtx,Session,gui_hud,HumanNs,none,0)},
                _ = gui_projection(Hud),
                Caller = gui_async(fun() -> quod_lobby_tests:submit(HumanCtx,execute,
                    scope(AppNs,{gui_open,settings,{0}})) end),
                {Result,Frames} = gui_open_result(Caller,Hud,none,[]),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},Result),
                ?assert(lists:member(<<"gui_prepare">>,Frames)),
                ?assert(lists:member(<<"gui_activate">>,Frames)),
                {ok,[#{<<"V0">> := [Reference]}],_} = read(HumanCtx,HumanNs,{gui_pending_questions,{0}}),
                {question_ref,Ns,_,Q} = Reference,
                ?assertMatch({ok,[#{<<"V0">> := Source}],_},read(HumanCtx,Ns,{gui_question_view,Q,{0},{'_'},awaiting})),
                [#{effect_id := EffectId}] = quod_effect_journal:rows(),
                ok = quod_effect_journal:await(EffectId,10000),
                [#{state := applied}] = quod_effect_journal:rows(),
                Hud ! {client,gui_open_message(HumanCtx,Session,gui_hud,HumanNs,none,0)},
                _ = gui_projection(Hud),
                AgentMonitor = monitor(process,AgentPid),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},node_request(Ctx,execute,
                    scope(Ns,{assertz,{agent_hosting_suspended,actor}}))),
                receive {'DOWN',AgentMonitor,process,AgentPid,_} -> ok
                after 5000 -> error(gui_responder_not_stopped) end,
                {fail,HandlerReasons} = read(HumanCtx,Ns,
                    {gui_native_handler,actor,Source,Human,{hosted,Node,1,Key},{0}}),
                ?assert(lists:member(agent_handler_unavailable,HandlerReasons)),
                fail(HumanCtx,scope(AppNs,{gui_open,settings,{0}})),
                ?assertMatch({ok,[#{<<"V0">> := [Reference]}],_},read(HumanCtx,HumanNs,{gui_pending_questions,{0}})),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},node_request(Ctx,execute,
                    scope(Ns,{retract,{agent_hosting_suspended,actor}}))),
                receive {agent_installed,_,Replacement,#{reference := Actor},_} -> ?assertNotEqual(AgentPid,Replacement)
                after 5000 -> error(gui_responder_not_reinstalled) end,
                commit(HumanCtx,scope(Ns,{gui_cancel,Q})),
                ?assertMatch({ok,[#{<<"V0">> := []}],_},read(HumanCtx,HumanNs,{gui_pending_questions,{0}})),
                Hud ! {client,gui_open_message(HumanCtx,Session,gui_hud,HumanNs,none,0)},
                _ = gui_projection(Hud),
                %% Even after creating both private material rows, outer proof
                %% failure aborts every scope and never releases the effect.
                Rollback = gui_async(fun() -> quod_lobby_tests:submit(HumanCtx,execute,
                    {',',scope(AppNs,{gui_open,settings,{0}}),fail}) end),
                _ = gui_reply(Hud,<<"gui_prepare">>),
                ?assertMatch({ok,_,{normalized,{failed,_}}},gui_result(Rollback)),
                ?assertMatch({ok,[#{<<"V0">> := []}],_},read(HumanCtx,HumanNs,{gui_pending_questions,{0}})),
                [#{state := applied}] = quod_effect_journal:rows(),
                ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{gui_question,{'_'},{'_'},{'_'},{'_'},{'_'},{'_'}})),
                Hud ! {automatic,false}, _ = gui_socket_state(Hud),
                Refusal = gui_async(fun() -> quod_lobby_tests:submit(HumanCtx,execute,
                    scope(AppNs,{gui_open,settings,{0}})) end),
                #{<<"token">> := RefusedToken} = gui_reply(Hud,<<"gui_prepare">>),
                gui_ack(Hud,#{type => gui_prepared,token => RefusedToken,accepted => false}),
                ?assertMatch({ok,_,{normalized,{failed,_}}},gui_result(Refusal)),
                %% Both preparations pin the same ordinary question/HUD base.
                %% Accept one, then release the other after that commit. OCC
                %% rejects the stale write rather than leaking a second row.
                RaceA = gui_async(fun() -> quod_lobby_tests:submit(HumanCtx,execute,
                    scope(AppNs,{gui_open,settings,{0}})) end),
                #{<<"token">> := TokenA,<<"question">> := QuestionA} = gui_reply(Hud,<<"gui_prepare">>),
                RaceB = gui_async(fun() -> quod_lobby_tests:submit(HumanCtx,execute,
                    scope(AppNs,{gui_open,settings,{0}})) end),
                #{<<"token">> := TokenB,<<"question">> := QuestionB} = gui_reply(Hud,<<"gui_prepare">>),
                ?assertNotEqual(QuestionA,QuestionB),
                Hud ! {automatic,true},
                gui_ack(Hud,#{type => gui_prepared,token => TokenA,accepted => true}),
                {_,_} = gui_open_result(RaceA,Hud,none,[]),
                gui_ack(Hud,#{type => gui_prepared,token => TokenB,accepted => true}),
                case gui_result(RaceB) of
                    {ok,_,{normalized,{error,conflict_retry}}} -> ok;
                    {ok,_,{normalized,{failed,Conflict}}} ->
                        ?assertEqual({ok,[conflict_retry]},quod_wire_term:decode_failure_reasons(Conflict));
                    RaceOther -> error({unexpected_gui_race_result,RaceOther})
                end,
                {ok,[#{<<"V0">> := [{question_ref,Ns,_,RaceQ}]}],_} = read(HumanCtx,HumanNs,{gui_pending_questions,{0}}),
                commit(HumanCtx,scope(Ns,{gui_cancel,RaceQ})),
                Hud ! {client,gui_open_message(HumanCtx,Session,gui_hud,HumanNs,none,0)},
                _ = gui_projection(Hud),
                %% A retained route is not evidence that its human is connected.
                commit(HumanCtx,{gui_select_receiver,person,maps:get(pubkey,Identity),<<0:256>>}),
                _ = gui_reply(Hud,<<"refresh">>),
                fail(HumanCtx,scope(AppNs,{gui_open,settings,{0}})),
                commit(HumanCtx,{gui_select_receiver,person,maps:get(pubkey,Identity),Connection}),
                Hud ! {client,gui_open_message(HumanCtx,Session,gui_hud,HumanNs,none,0)},
                _ = gui_projection(Hud),
                %% Agent-led opening uses ordinary authored application work.
                %% A configured form/responder cannot bypass human permission.
                Prompt = fun() -> gui_async(fun() ->
                    true = quod_reg:subscribe({agent,Actor}),
                    try
                        ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                            node_request(Ctx,execute,scope(Ns,{trigger_event,gui_prompt}))),
                        receive {agent_request_finished,_,_,#{reference := Actor},_,Reply} -> Reply
                        after 10000 -> error(agent_gui_open_missing) end
                    after quod_reg:unsubscribe({agent,Actor}) end
                end) end,
                PromptRules = [{can_invoke,open_settings,Actor,{'_'},Ns},
                    {':-',open_settings,scope(AppNs,{gui_open,settings,{'_'}})},
                    {':-',{react_on,gui_prompt,open_settings},{me,Actor}}],
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                    node_request(Ctx,execute,scope(Ns,assertions(PromptRules)))),
                ?assertMatch({ok,_,{normalized,{failed,_}}},gui_result(Prompt())),
                ?assertMatch({ok,[#{<<"V0">> := []}],_},
                    read(HumanCtx,HumanNs,{gui_pending_questions,{0}})),
                commit(HumanCtx,{assertz,{gui_receiver_policy,person,Actor}}),
                Hud ! {client,gui_open_message(HumanCtx,Session,gui_hud,HumanNs,none,0)},
                _ = gui_projection(Hud),
                {_,_} = gui_open_result(Prompt(),Hud,none,[]),
                {ok,[#{<<"V0">> := [{question_ref,Ns,_,AgentQ}]}],_} =
                    read(HumanCtx,HumanNs,{gui_pending_questions,{0}}),
                commit(HumanCtx,scope(Ns,{gui_cancel,AgentQ})),
                Hud ! {client,gui_open_message(HumanCtx,Session,gui_hud,HumanNs,none,0)},
                _ = gui_projection(Hud),
                [Handler] = [Clause || Clause = {':-', {react_on,{assert,{gui_question,_,_,_,_,_,_}},
                    {gui_complete,_}},_} <- source("gui_question.pl")],
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},node_request(Ctx,execute,scope(Ns,{retract,Handler}))),
                fail(HumanCtx,scope(AppNs,{gui_open,settings,{0}})),
                ?assertMatch({ok,[#{<<"V0">> := []}],_},read(HumanCtx,HumanNs,{gui_pending_questions,{0}})),
                ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{gui_question,{'_'},{'_'},{'_'},{'_'},{'_'},{'_'}})),
                ?assertEqual(3,length([ok || #{state := applied} <- quod_effect_journal:rows()]))
            after
                Hud ! stop,
                receive {'DOWN',M,process,Hud,normal} -> ok after 5000 -> error(hud_not_stopped) end,
                quod_agent_hosting_tests:stop_ontology(App),
                quod_agent_hosting_tests:stop_ontology(HumanOwner),
                quod_agent_hosting_tests:stop_ontology(Gui),gen_server:stop(Journal)
            end
        end,source("gui_question.pl") ++ [{gui_pending_allowance,actor,4},{gui_completion_allowance,actor,30000}])
    end}.

gui_projection(Hud) ->
    receive
        {gui_view,Hud,#{<<"type">> := <<"projection">>} = Message} -> Message;
        {gui_view,Hud,#{<<"type">> := <<"refresh">>}} -> gui_projection(Hud);
        {gui_view,Hud,Other} -> error({unexpected_gui_projection,Other})
    after 10000 -> error(gui_projection_missing) end.

%% Shared production socket fixture for application examples. Only the native
%% browser acknowledgement is automatic; opening uses the signed public API.
with_receiver(Ctx,HumanNs,Fun) ->
    Session = gui_session(Ctx), Parent = self(),
    {Hud,M} = spawn_monitor(fun() -> gui_socket(Parent,#{peer => {127,0,0,1}},true) end),
    Renew = fun() ->
        Hud ! {client,gui_open_message(Ctx,Session,gui_hud,HumanNs,none,0)},
        gui_projection(Hud)
    end,
    try
        _ = Renew(),
        {client_view,{gui_hud,HumanBytes,Connection}} = maps:get(receiver_key,gui_socket_state(Hud)),
        {ok,{agent_instance_ref,HumanNs,_,Instance}} = quod_agent_ref:materialize(HumanBytes),
        {ok,Node} = application:get_env(quod,node_pubkey),
        commit(Ctx,scope(HumanNs,{gui_select_receiver,Instance,Node,Connection})),
        Open = fun(Ns,Form) ->
            _ = Renew(),
            ?assertEqual(#{},maps:get(gui_resources,gui_socket_state(Hud),#{})),
            Caller = gui_async(fun() -> quod_lobby_tests:submit(Ctx,execute,
                scope(Ns,{gui_open,Form,{0}})) end),
            _ = gui_open_result(Caller,Hud,none,[]),
            {ok,[#{<<"V0">> := [Reference]}],_} = read(Ctx,HumanNs,{gui_pending_questions,{0}}),
            Reference
        end,
        Fun(Open)
    after
        Hud ! stop,
        receive {'DOWN',M,process,Hud,normal} -> ok after 5000 -> error(hud_not_stopped) end
    end.

gui_open_result({Ref,Pid,M} = Caller,Hud,Result,Frames) ->
    case Result =/= none andalso lists:member(<<"gui_activate">>,Frames) of
        true ->
            receive {'DOWN',M,process,Pid,normal} -> {Result,Frames}
            after 5000 -> error(gui_open_caller_not_stopped) end;
        false -> receive
            {Ref,{ok,_,{normalized,{committed,_,_}}} = Value} -> gui_open_result(Caller,Hud,Value,Frames);
            {Ref,{ok,_,{normalized,{failed,Reasons}}}} ->
                error({gui_open_failed,quod_wire_term:decode_failure_reasons(Reasons),Frames});
            {Ref,Other} -> error({gui_open_failed,Other,Frames});
            {gui_view,Hud,#{<<"type">> := Type}} -> gui_open_result(Caller,Hud,Result,[Type|Frames])
        after 20000 -> error({gui_open_missing,Result,Frames}) end
    end.

accepted_question_transitions_use_signed_atomic_owners_test_() ->
    {timeout, 120, fun() ->
        Dir = filename:join("/tmp", "quod-gui-questions-" ++
                            binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        Ctx = quod_lobby_tests:start(Dir),
        {ontology_ref, Lobby, _} = maps:get(lobby, Ctx),
        {_, Base} = maps:get(Lobby, maps:get(ontologies, Ctx)),
        {HumanNs, HumanAnchor} = maps:get(agent, Ctx),
        HumanInstance = {human_user, test_agent},
        Human = {agent_instance_ref, HumanNs, HumanAnchor, HumanInstance},
        OtherHumanInstance = {human_user, other_agent},
        OtherHuman = {agent_instance_ref, HumanNs, HumanAnchor, OtherHumanInstance},
        OtherHumanCtx = Ctx#{instance => <<"human_user(other_agent).">>},
        {PublicKey, _} = maps:get(key_pair, Ctx),
        ResponderNs = <<"gui:responsible">>,
        Admin = {can_invoke, {'_'}, Human, {'_'}, {'_'}},
        HudHelperGrant = {can_invoke,
            {',', {current_ontology_identity, ResponderNs, {'_'}},
             scope(HumanNs, {gui_unlink, HumanInstance, {'Ref'}})},
            {agent_instance_ref, ResponderNs, {'_'}, responder}, {'_'}, ResponderNs},
        {Responder, _} = quod_lobby_tests:start_namespace(ResponderNs, Base#{
            data_dir => filename:join(Dir, "responsible"),
            genesis_diff => quod_prolog:terms_to_diff(source("agent_instance.pl") ++
                source("gui_question.pl") ++ [Admin, HudHelperGrant, {gui_completion_allowance, responder, 30000},
                                             {agent_key, responder, PublicKey, active},
                                             {agent_key, other_responder, PublicKey, active}])}),
        ResponderAnchor = quod_simplex:genesis_hash(ResponderNs),
        Actor = {agent_instance_ref, ResponderNs, ResponderAnchor, responder},
        OtherActor = {agent_instance_ref, ResponderNs, ResponderAnchor, other_responder},
        ActorCtx = Ctx#{agent => {ResponderNs, ResponderAnchor}, instance => <<"responder.">>},
        OtherActorCtx = ActorCtx#{instance => <<"other_responder.">>},
        AppNs = <<"gui:application">>,
        Callback = {':-', {settings_entered, {'N'}, {'M'}, {'L'}, {'A'}},
                    {',', {assertz, {saved, {'N'}, {'M'}, {'L'}, {'A'}}},
                     {',', {'\\+', reject_save},
                      {'\\+', {',', reject_after_consume,
                       {',', {gui_application_active, {question_ref, ResponderNs, {'Anchor'}, {'Q'}}},
                        scope(ResponderNs, {gui_consume, {'Q'}})}}}}}},
        SourceHelperGrant = {can_invoke,
            {',', {current_ontology_identity, AppNs, {'_'}},
             scope(ResponderNs, {gui_consume, {'Q'}})}, Actor, {'_'}, AppNs},
        {Application, _} = quod_lobby_tests:start_namespace(AppNs, Base#{
            data_dir => filename:join(Dir, "application"),
            genesis_diff => quod_prolog:terms_to_diff(source("gui_instance.pl") ++
                quod_prolog:read_terms("test/fixtures/gui-components.pl") ++
                [Admin, SourceHelperGrant, Callback,
                 {agent_key, fixture_admin, PublicKey, active},
                 {can_invoke, {'_'}, {agent_instance_ref, AppNs, {'_'}, fixture_admin}, {'_'}, AppNs},
                 {gui_question_policy, settings, Human, Actor},
                 {gui_question_policy, settings, OtherHuman, Actor},
                 {gui_question_policy, another_form, Human, OtherActor},
                 {gui_vocabulary, <<"quod:gui">>, quod_simplex:genesis_hash(<<"quod:gui">>)}])}),
        try
            commit(Ctx, scope(HumanNs, assertions(source("gui_hud.pl") ++
                [{instance_of, human_user, HumanInstance},
                 {instance_of, human_user, OtherHumanInstance},
                 {agent_key, OtherHumanInstance, PublicKey, active}]))),
            assert_receiver_selection(Ctx, OtherHumanCtx, ActorCtx, HumanNs, HumanInstance, Actor),
            {ok, [#{<<"V0">> := Revision}], _} = read(Ctx, AppNs, {gui_schema, settings, {0}, {'_'}}),
            Source = {form_ref, AppNs, quod_simplex:genesis_hash(AppNs), settings},
            Fields = [{field, name, <<"Entered">>}, {field, mode, square},
                      {field, level, 75}, {field, angle, 180}],
            Question = {question, <<1:256>>},
            %% Constructing future request bytes is pure data work. Exercise it
            %% through signed multi-scope ingress and an actual committed write;
            %% no signer or live bridge may be required to retain the intent.
            {ok, Network} = quod_ontology:network_identity(),
            {ok, CompletionText} = quod_client_goal_parser:format({gui_complete, Question}),
            Intent = {agent_goal_v1, Network, Actor, <<"responder.">>, PublicKey,
                      <<77:256>>, 1800000000000, execute, 3, CompletionText},
            {ok, _, IntentBytes} = quod_client_goal:encode_typed(Intent),
            commit(Ctx, scope(ResponderNs,
                {',', {agent_request_bytes, Intent, {0}},
                 {assertz, {inert_request_intent, {0}}}})),
            no_io(1, fun() ->
                ?assertMatch({ok, [_], _},
                    read(Ctx, ResponderNs, {inert_request_intent, IntentBytes}))
            end),
            commit(Ctx, scope(ResponderNs, {retract, {inert_request_intent, IntentBytes}})),
            Reference = {question_ref, ResponderNs, ResponderAnchor, Question},
            Awaiting = {gui_question, Question, Source, Human, responder, Revision, awaiting},
            seed(Ctx, ResponderNs, HumanNs, HumanInstance, Reference, Awaiting),
            ?assertMatch({ok, [#{<<"V0">> := [Reference]}], _},
                read(Ctx, HumanNs, {gui_pending_questions, {0}})),
            ?assertMatch({fail, _}, read(ActorCtx, HumanNs, {gui_pending_questions, {0}})),
            ?assertMatch({ok, [#{<<"V0">> := []}], _},
                read(OtherHumanCtx, HumanNs, {gui_pending_questions, {0}})),
            no_io(2, fun() ->
                ?assertMatch({ok, [#{<<"V0">> := [Reference]}], _},
                    read(Ctx, HumanNs, {gui_pending_questions, {0}}))
            end),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs,
                {instance_of, {':', quod, {':', gui, question}}, Question})),
            Submit = {gui_submit, Question, Revision, apply, Fields},
            View = {gui_question_view, Question, Source, Revision, awaiting},
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, View)),
            fail(OtherHumanCtx, scope(ResponderNs, View)),
            no_io(3, fun() ->
                ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, View))
            end),
            FormQuery = {gui_question_form, Question, {0}},
            {ok, [#{<<"V0">> := FormView}], _} = read(Ctx, ResponderNs, FormQuery),
            {question_form, Source, Actor, Revision, awaiting,
             {form_view, Revision, Tree, ValuesToken, Initial, apply}} = FormView,
            ?assertMatch({component, settings, form, _, _}, Tree),
            ?assertEqual([{field, name, <<"Oscillator">>}, {field, mode, sine},
                          {field, level, 50}, {field, angle, 90}], Initial),
            ?assertEqual(32, byte_size(ValuesToken)),
            assert_gui_view_lifecycle(Ctx, OtherHumanCtx, HumanNs, ResponderNs, AppNs,
                                      Question, Reference),
            ?assertMatch({fail, _}, read(OtherHumanCtx, ResponderNs, FormQuery)),
            ?assertMatch({fail, _}, read(ActorCtx, ResponderNs, FormQuery)),
            no_io(4, fun() ->
                ?assertMatch({ok, [#{<<"V0">> := FormView}], _},
                    read(Ctx, ResponderNs, FormQuery))
            end),
            %% Presentation rechecks current source policy, even if a question
            %% was accepted before that permission was withdrawn.
            Policy = {gui_question_policy, settings, Human, Actor},
            commit(Ctx, scope(AppNs, {retract, Policy})),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, FormQuery)),
            commit(Ctx, scope(AppNs, {assertz, Policy})),
            commit(Ctx, scope(AppNs, {assertz, {attribute, name, help, <<"New help">>}})),
            {ok, [#{<<"V0">> := {question_form, Source, Actor, Revision, awaiting,
                {form_view, ChangedRevision, _, ValuesToken, Initial, apply}}}], _} =
                read(Ctx, ResponderNs, FormQuery),
            ?assertNotEqual(Revision, ChangedRevision),
            commit(Ctx, scope(AppNs, {retract, {attribute, name, help, <<"New help">>}})),
            %% Source schema validation and the assigned human remain enforced
            %% even where the containing ontology grants its owner broad access.
            fail(Ctx, scope(ResponderNs, setelement(3, Submit, <<0:256>>))),
            fail(Ctx, scope(ResponderNs, setelement(5, Submit, tl(Fields)))),
            fail(ActorCtx, Submit),
            fail(OtherHumanCtx, scope(ResponderNs, Submit)),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, Awaiting)),
            {ok, #{operation_ref := Submission}, {normalized, {committed, _, _}}} =
                quod_lobby_tests:submit(Ctx, execute, scope(ResponderNs, Submit)),
            Bytes = completion_bytes(Ctx, ResponderNs, Question),
            Submitted = setelement(7, Awaiting, {submitted, Submission, apply, Fields, Bytes}),
            {ok, #{request := #{operation_id := CompletionId}, agent_ref_blob := ActorBytes}} =
                quod_client_goal:request_identity(Bytes),
            ?assertEqual(32, byte_size(CompletionId)),
            ?assertMatch({ok, #{reference := Actor}}, quod_agent_ref:decode(ActorBytes)),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, Submitted)),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs,
                setelement(5, View, {submitted, Submission, apply, Fields}))),
            ?assertMatch({ok, [#{<<"V0">> := {question_form, Source, Actor, Revision,
                {submitted, Submission, apply, Fields}, _}}], _},
                read(Ctx, ResponderNs, FormQuery)),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, {gui_submitted, Question, Submission})),
            fail(Ctx, scope(ResponderNs, Submit)),
            ?assertMatch({ok, _, {normalized, {error, proof_unavailable}}},
                quod_lobby_tests:submit(Ctx, execute, scope(ResponderNs, {gui_cancel, Question}))),
            fail(Ctx, scope(ResponderNs, {gui_complete, Question})),
            fail(ActorCtx, {gui_consume, Question}),
            fail(OtherActorCtx, scope(AppNs, {gui_continue, Reference})),
            %% A forged event or direct helper entry supplies no authority to
            %% consume a question or remove its HUD reference.
            commit(Ctx, scope(ResponderNs, {trigger_event, {gui_submitted, Question, <<0:256>>}})),
            fail(ActorCtx, scope(AppNs, scope(ResponderNs, {gui_consume, Question}))),
            fail(ActorCtx, scope(ResponderNs, scope(HumanNs,
                {gui_unlink, HumanInstance, Reference}))),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, Submitted)),
            ?assertMatch({ok, [_], _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, Reference})),
            %% Even the assigned actor cannot replace the exact stored intent
            %% with a fresh signed operation for the same goal.
            fail(ActorCtx, {gui_complete, Question}),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, complete(ActorCtx, Bytes)),
            ?assertMatch({ok, [_], _}, read(Ctx, AppNs, {saved, <<"Entered">>, square, 75, 180})),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, Submitted)),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, setelement(5, View, {'_'}))),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, FormQuery)),
            ?assertMatch({fail, _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, Reference})),
            assert_no_guards(Ctx, AppNs, ResponderNs),
            ?assertMatch({ok, [#{<<"V0">> := []}], _},
                read(Ctx, HumanNs, {gui_pending_questions, {0}})),
            fail(ActorCtx, {gui_complete, Question}),
            fail(Ctx, scope(ResponderNs, Submit)),
            {ok, [#{<<"V0">> := [true]}], _} = read(Ctx, AppNs,
                {findall, true, {saved, <<"Entered">>, square, 75, 180}, {0}}),
            %% A second opening of the same form has an independent identity.
            OtherQ = {question, <<2:256>>},
            OtherRef = setelement(4, Reference, OtherQ),
            OtherRow = setelement(2, Awaiting, OtherQ),
            seed(Ctx, ResponderNs, HumanNs, HumanInstance, OtherRef, OtherRow),
            commit(Ctx, scope(ResponderNs, {gui_cancel, OtherQ})),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, OtherRow)),
            ?assertMatch({fail, _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, OtherRef})),
            assert_no_guards(Ctx, AppNs, ResponderNs),
            fail(Ctx, scope(ResponderNs, {gui_cancel, OtherQ})),
            %% Namespace equality cannot substitute for the exact source history.
            WrongQ = {question, <<5:256>>},
            WrongRef = setelement(4, Reference, WrongQ),
            WrongRow = setelement(3, setelement(2, Awaiting, WrongQ),
                setelement(3, Source, <<0:256>>)),
            seed(Ctx, ResponderNs, HumanNs, HumanInstance, WrongRef, WrongRow),
            fail(Ctx, scope(ResponderNs, setelement(2, Submit, WrongQ))),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, setelement(2, FormQuery, WrongQ))),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, WrongRow)),
            commit(Ctx, scope(ResponderNs, {gui_cancel, WrongQ})),
            %% Simultaneous submitted operations race through the production
            %% owner. Only one replaces the same awaiting row.
            RaceQ = {question, <<3:256>>},
            RaceRef = setelement(4, Reference, RaceQ),
            RaceRow = setelement(2, Awaiting, RaceQ),
            seed(Ctx, ResponderNs, HumanNs, HumanInstance, RaceRef, RaceRow),
            RaceSubmit = scope(ResponderNs, setelement(2, Submit, RaceQ)),
            Results = concurrent_submissions(Ctx, [RaceSubmit, RaceSubmit]),
            [WinningOperation] = [Op || {ok, #{operation_ref := Op},
                {normalized, {committed, _, _}}} <- Results],
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs,
                setelement(7, RaceRow, {submitted, WinningOperation, apply, Fields, {'_'}}))),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                complete(ActorCtx, completion_bytes(Ctx, ResponderNs, RaceQ))),
            ?assertMatch({ok, [#{<<"V0">> := []}], _},
                read(Ctx, HumanNs, {gui_pending_questions, {0}})),
            CancelQ = {question, <<4:256>>},
            CancelRef = setelement(4, Reference, CancelQ),
            CancelRow = setelement(2, Awaiting, CancelQ),
            seed(Ctx, ResponderNs, HumanNs, HumanInstance, CancelRef, CancelRow),
            [SubmitResult, CancelResult] = concurrent_submissions(Ctx,
                [scope(ResponderNs, setelement(2, Submit, CancelQ)),
                 scope(ResponderNs, {gui_cancel, CancelQ})]),
            ?assertEqual(1, length([ok || {ok, _, {normalized, {committed, _, _}}}
                <- [SubmitResult, CancelResult]])),
            case SubmitResult of
                {ok, _, {normalized, {committed, _, _}}} ->
                    ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                        complete(ActorCtx, completion_bytes(Ctx, ResponderNs, CancelQ)));
                _ -> ?assertMatch({fail, _}, read(Ctx, ResponderNs,
                    {gui_question, CancelQ, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}))
            end,
            ?assertMatch({ok, [#{<<"V0">> := []}], _},
                read(Ctx, HumanNs, {gui_pending_questions, {0}})),
            %% Each rollback case owns a distinct accepted intent, executed
            %% once. No failed or uncertain completion is ever resubmitted.
            lists:foreach(fun({Id, Failure}) ->
                Q = {question, <<Id:256>>},
                Ref = setelement(4, Reference, Q),
                Row = setelement(2, Awaiting, Q),
                seed(Ctx, ResponderNs, HumanNs, HumanInstance, Ref, Row),
                UniqueFields = [{field, name, <<Id:32>>} | tl(Fields)],
                commit(Ctx, scope(ResponderNs, {gui_submit, Q, Revision, apply, UniqueFields})),
                Original = completion_bytes(Ctx, ResponderNs, Q),
                commit(Ctx, scope(AppNs, {assertz, Failure})),
                ?assertMatch({ok, _, {normalized, {failed, _}}}, complete(ActorCtx, Original)),
                ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs,
                    {gui_question, Q, Source, Human, responder, Revision,
                     {submitted, {'_'}, apply, UniqueFields, Original}})),
                ?assertMatch({ok, [_], _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, Ref})),
                ?assertMatch({fail, _}, read(Ctx, AppNs, {saved, <<Id:32>>, {'_'}, {'_'}, {'_'}})),
                assert_no_guards(Ctx, AppNs, ResponderNs),
                commit(Ctx, scope(AppNs, {retract, Failure}))
            end, [{6, reject_save}, {7, reject_after_consume}]),
            %% Recovery input whose original request was never claimed. The
            %% seed's certified block is later than its fixed deadline; no
            %% clock-only inference or sleep supplies retirement permission.
            ExpiredQ = {question, <<8:256>>},
            ExpiredRef = setelement(4, Reference, ExpiredQ),
            {ok, #{request := OriginalRequest}} = quod_client_goal:request_identity(Bytes),
            {ok, ExpiredText} = quod_client_goal_parser:format({gui_complete, ExpiredQ}),
            {ok, ExpiredBytes} = quod_client_goal:encode(OriginalRequest#{
                operation_id => <<88:256>>, goal_text => ExpiredText,
                not_after_ms => quod_time:now_ms() - 60000}),
            ExpiredRow = setelement(7, setelement(2, Awaiting, ExpiredQ),
                {submitted, Submission, apply, Fields, ExpiredBytes}),
            seed(Ctx, ResponderNs, HumanNs, HumanInstance, ExpiredRef, ExpiredRow),
            no_io(5, fun() ->
                ?assertMatch({ok, [_], _},
                    read(Ctx, ResponderNs, {gui_question_status, ExpiredQ, expired}))
            end),
            ?assertMatch({fail, _}, read(OtherHumanCtx, ResponderNs,
                {gui_question_status, ExpiredQ, expired})),
            commit(Ctx, scope(ResponderNs, {gui_cancel, ExpiredQ})),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, ExpiredRow)),
            ?assertMatch({fail, _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, ExpiredRef})),
            assert_no_guards(Ctx, AppNs, ResponderNs)
        after
            quod_lobby_tests:stop_process(Application),
            quod_lobby_tests:stop_process(Responder), quod_lobby_tests:stop(Ctx)
        end,
        file:del_dir_r(Dir)
    end}.

assert_no_guards(Ctx, AppNs, ResponderNs) ->
    ?assertMatch({fail, _}, read(Ctx, AppNs, {gui_application_active, {'_'}})),
    ?assertMatch({fail, _}, read(Ctx, ResponderNs, {gui_retiring, {'_'}, {'_'}})).

concurrent_submissions(Ctx, Goals) ->
    Parent = self(),
    Requests = [spawn_monitor(fun() ->
        receive run -> Parent ! {self(), quod_lobby_tests:submit(Ctx, execute, Goal)} end
    end) || Goal <- Goals],
    [Pid ! run || {Pid, _} <- Requests],
    [receive {Pid, Result} ->
         receive {'DOWN', Monitor, process, Pid, normal} -> Result
         after 10000 -> error(submit_worker_not_finished) end;
       {'DOWN', Monitor, process, Pid, Reason} -> error({submit_worker_failed, Reason})
     after 30000 -> error(submit_result_missing) end || {Pid, Monitor} <- Requests].

seed(Ctx, ResponderNs, HumanNs, Instance, Ref, Row) ->
    commit(Ctx, {transaction, {',', scope(ResponderNs, {assertz, Row}),
        scope(HumanNs, {assertz, {gui_pending, Instance, Ref}})}}).

source(Name) -> quod_prolog:read_terms(filename:join(code:priv_dir(quod), "ontologies/" ++ Name)).
read(Ctx, Ns, Goal) -> quod_lobby_tests:read(Ctx, scope(Ns, Goal)).
scope(Ns, Goal) -> {'::', Ns, {',', {current_ontology_identity, Ns, quod_simplex:genesis_hash(Ns)}, Goal}}.
commit(Ctx, Goal) ->
    await_commit(quod_lobby_tests:submit(Ctx, execute, Goal)).

await_commit({ok, #{operation_ref := Operation}, {normalized, {committed, _, _}}}) ->
    await_operation(Operation).

await_operation(Operation) ->
    %% Complete publication can outlive the client result. Join that existing
    %% owner before measuring a later read's disk work.
    Row = quod_ct:await_operation_complete(element(2, Operation), Operation, 10000),
    case maps:get(outcome_ref, Row) of
        {group, Ns, _, _, _, Group} = Ref ->
            await_group_complete(Ns, Group),
            {ok, #{participant_slots := Participants}} = quod_prolog:local_outcome(Ns, Ref),
            lists:foreach(fun({{Target, _}, Slot, _}) -> quod_ct:await_applied(Target, Slot, 10000) end,
                          Participants);
        _ -> ok
    end.
fail(Ctx, Goal) ->
    ?assertMatch({ok, _, {normalized, {failed, _}}}, quod_lobby_tests:submit(Ctx, execute, Goal)).

assertions(Terms) ->
    {Goals, _} = lists:mapfoldl(fun(Term, Vn) ->
        {Fresh, _, Next} = erlog_int:term_instance(Term, Vn), {{assertz, Fresh}, Next}
    end, 0, Terms),
    conjunction(Goals).
conjunction([Goal]) -> Goal;
conjunction(Goals) ->
    {Left, Right} = lists:split(length(Goals) div 2, Goals),
    {',', conjunction(Left), conjunction(Right)}.

completion_bytes(Ctx, Ns, Q) ->
    {ok, [#{<<"V0">> := Bytes}], _} = read(Ctx, Ns,
        {',', {'=', {0}, {'Bytes'}},
         {gui_question, Q, {'_'}, {'_'}, {'_'}, {'_'},
          {submitted, {'_'}, {'_'}, {'_'}, {'Bytes'}}}}),
    Bytes.

complete(Ctx, Bytes) ->
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(maps:get(key_pair, Ctx))),
    quod_client_goal_ingress:submit(Bytes, Signature).

%% The accepted row is seeded, but all dispatch and completion use the shared
%% GUI rules, real hosted actor, governed vault and signed atomic ingress.
committed_answer_automatically_completes_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(Ctx = #{namespace := Ns, reference := Actor,
                node := Node, key := Key, directory := Dir, identity := Identity}) ->
            ?assertMatch({ok, _, _}, quod_ct:rp(Ns, {goal, {agent_hosted, actor, Node, 1, Key}})),
            receive {agent_installed, _, _, #{reference := Actor}, _} -> ok
            after 10000 -> error(gui_actor_not_installed) end,
            Admin = {can_invoke, {'_'}, Node, {'_'}, {'_'}},
            Start = fun(Name, Terms) ->
                quod_agent_hosting_tests:start_ontology(Name, Dir, Identity, [], [Admin | Terms])
            end,
            Vocabulary = Start(<<"quod:gui">>, source("quod_gui.pl")),
            HumanNs = <<"gui:auto-human">>,
            HumanOwner = Start(HumanNs, source("gui_hud.pl") ++ [{instance_of, human_user, person}]),
            Human = {agent_instance_ref, HumanNs, quod_simplex:genesis_hash(HumanNs), person},
            AppNs = <<"gui:auto-app">>,
            Callback = {':-', {settings_entered, {'N'}, {'M'}, {'L'}, {'A'}},
                        {assertz, {saved, {'N'}, {'M'}, {'L'}, {'A'}}}},
            App = Start(AppNs, source("gui_instance.pl") ++
                quod_prolog:read_terms("test/fixtures/gui-components.pl") ++
                [Callback, {gui_question_policy, settings, Human, Actor},
                 {gui_vocabulary, <<"quod:gui">>, quod_simplex:genesis_hash(<<"quod:gui">>)}]),
            try
                {ok, _, {normalized, {read, _, {answers, _, [Bindings]}}}} =
                    node_request(Ctx, read, scope(AppNs, {gui_schema, settings, {0}, {'_'}})),
                {ok, Pairs} = quod_client_result:decode_binding(Bindings),
                Revision = proplists:get_value(<<"V0">>, Pairs),
                Q = {question, <<91:256>>},
                Reference = {question_ref, Ns, element(3, Actor), Q},
                Source = {form_ref, AppNs, quod_simplex:genesis_hash(AppNs), settings},
                Fields = [{field, name, <<"Automatic">>}, {field, mode, square},
                          {field, level, 75}, {field, angle, 180}],
                {ok, Text} = quod_client_goal_parser:format({gui_complete, Q}),
                {ok, Bytes} = quod_client_goal:encode(#{network_identity => <<42:256>>,
                    agent_namespace => Ns, agent_genesis_anchor => element(3, Actor),
                    agent_instance_text => <<"actor.">>, signing_public_key => Key,
                    operation_id => <<92:256>>, not_after_ms => quod_time:now_ms() + 30000,
                    mode => execute, parser_version => 3, goal_text => Text}),
                Row = {gui_question, Q, Source, Human, actor, Revision,
                       {submitted, fixture_submission, apply, Fields, Bytes}},
                %% Remove the fixture's broad signature grant. Only the shared
                %% GUI rule may release the exact retained completion signature.
                ?assertMatch({ok,_,_},quod_ct:rp(Ns,
                    {retract,{can_request_agent_signature,Node,actor,{'_'}}})),
                {ok,Request} = quod_client_goal:decode(Bytes),
                Typed = {agent_goal_v1,<<42:256>>,Actor,<<"actor.">>,Key,<<92:256>>,
                         maps:get(not_after_ms,Request),execute,3,Text},
                %% Remove broad node entry as well. Seed only this fixture row
                %% through an exact grant; governed signing uses GUI's own ACL.
                BroadEntry = {can_invoke,{'_'},Node,{'_'},Ns},
                SeedEntry = {can_invoke,
                    {',',{current_ontology_identity,Ns,element(3,Actor)},{assertz,Row}},
                    Node,{'_'},Ns},
                %% Test setup retains write administration, never a generic
                %% read/signing entry. Actual hosted signature reads must use
                %% the shared GUI ACL even while the fixture can edit rows.
                lists:foreach(fun(Pattern) ->
                    ?assertMatch({ok,_,_},quod_ct:rp(Ns,
                        {assertz,{can_invoke,
                            {',',{current_ontology_identity,Ns,element(3,Actor)},Pattern},
                            Node,{'_'},Ns}}))
                end,[{assertz,{'_'}},{retract,{'_'}},{trigger_event,{'_'}}]),
                ?assertMatch({ok,_,_},quod_ct:rp(Ns,
                    {transaction,{',',{assertz,SeedEntry},{retract,BroadEntry}}})),
                SignRead = {',',{agent_hosted,actor,Node,1,Key},{sign_agent_request,Typed,{0}}},
                ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},
                             node_request(Ctx,read,scope(Ns,SignRead))),
                %% The reference and accepted row become visible together.
                ?assertMatch({ok, _, {normalized, {committed, _, _}}}, node_request(Ctx, execute,
                    {transaction, {',', scope(HumanNs, {assertz, {gui_pending, person, Reference}}),
                                        scope(Ns, {assertz, Row})}})),
                receive
                    {agent_request_finished, _, _, #{reference := Actor}, _, Result} ->
                        ?assertMatch({ok, #{request_bytes := Bytes},
                                           {normalized, {committed, _, _}}}, Result)
                after 10000 -> error(gui_completion_missing) end,
                ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(AppNs,
                    {saved, <<"Automatic">>, square, 75, 180})),
                ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, Row)),
                %% Consumption withdraws the signature grant as part of the
                %% same transaction; expired saved work gets no fresh signature.
                ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},
                             node_request(Ctx,read,scope(Ns,SignRead))),
                ?assertMatch({fail, _}, quod_prolog:prove_ro(HumanNs,
                    {gui_pending, person, Reference})),
                %% Even an administratively forged row cannot authorize
                %% another goal, nor a variable-bearing completion template.
                lists:foreach(fun({BadQ,BadGoal}) ->
                    {ok,BadText} = quod_client_goal_parser:format(BadGoal),
                    BadTyped = setelement(10,Typed,BadText),
                    {ok,_,BadBytes} = quod_client_goal:encode_typed(BadTyped),
                    BadRow = {gui_question,BadQ,Source,Human,actor,Revision,
                              {submitted,fixture_submission,apply,Fields,BadBytes}},
                    ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                                 node_request(Ctx,execute,scope(Ns,{assertz,BadRow}))),
                    BadRead = {',',{agent_hosted,actor,Node,1,Key},
                                  {sign_agent_request,BadTyped,{0}}},
                    ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},
                                 node_request(Ctx,read,scope(Ns,BadRead))),
                    ok = quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),
                        agent_hosts,all,quod_time:mono_ms()+5000),
                    receive {agent_request_finished,_,_,#{reference := Actor},_,_} ->
                        error(invalid_retained_work_dispatched)
                    after 0 -> ok end,
                    ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                                 node_request(Ctx,execute,scope(Ns,{retract,BadRow})))
                end,[{{question,<<93:256>>},{record_ping,unauthorized}},
                      {{question,<<94:256>>},{gui_complete,{0}}}]),
                %% A forged ordinary event cannot recreate an assertion.
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},node_request(Ctx,execute,
                    scope(Ns,{trigger_event,{gui_submitted,Q,fixture_submission}}))),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                             node_request(Ctx,execute,scope(Ns,{assertz,BroadEntry}))),
                ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},
                             node_request(Ctx,read,scope(Ns,{ping,unauthorized}))),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},node_request(Ctx,execute,
                    scope(Ns,{assertz,{can_request_agent_signature,Node,actor,{'_'}}}))),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                             node_request(Ctx,execute,scope(Ns,{trigger_event,{do_work,barrier}}))),
                receive
                    {agent_request_finished, _, _, #{reference := Actor}, _, Barrier} ->
                        ?assertMatch({ok, _, {normalized, {committed, _, _}}}, Barrier)
                after 10000 -> error(gui_event_barrier_missing) end,
                ?assertMatch({ok, [#{'Rows' := [true]}], _}, quod_prolog:prove_ro(AppNs,
                    {findall, true, {saved, <<"Automatic">>, square, 75, 180}, {'Rows'}}))
            after
                quod_agent_hosting_tests:stop_ontology(App),
                quod_agent_hosting_tests:stop_ontology(HumanOwner),
                quod_agent_hosting_tests:stop_ontology(Vocabulary)
            end
        end, source("gui_question.pl"))
    end}.

node_request(#{node := {agent_instance_ref, Ns, Anchor, Instance}, identity := Identity}, Mode, Goal) ->
    {Numbered, _, _} = erlog_int:term_instance(Goal, 0),
    {ok, Text} = quod_client_goal_parser:format(Numbered),
    {ok, InstanceText} = quod_client_goal_parser:format(Instance),
    {ok, Bytes} = quod_client_goal:encode(#{network_identity => <<42:256>>,
        agent_namespace => Ns, agent_genesis_anchor => Anchor, agent_instance_text => InstanceText,
        signing_public_key => maps:get(pubkey, Identity), operation_id => crypto:strong_rand_bytes(32),
        not_after_ms => quod_time:now_ms() + 30000, mode => Mode, parser_version => 3, goal_text => Text}),
    quod_client_goal_ingress:submit(Bytes, quod_identity:sign(Bytes, maps:get(key, Identity))).

no_io(Label, Check) ->
    try quod_lobby_tests:assert_read_has_no_io(Check)
    catch Class:Reason:Stack ->
        io:format("GUI no-I/O check ~p; DETS ownership ~p~n", [Label,
            [{Table, dets:info(Table)} || Table <- dets:all()]]),
        erlang:raise(Class, Reason, Stack)
    end.

%% An operation receipt can precede source Complete. Join that exact group
%% before tracing an unrelated read; roles are joined at certified Resolve slots.
await_group_complete(Ns, Group) ->
    true = quod_reg:subscribe({runtime, Ns}),
    Owner = quod_reg:where({quod_prolog, Ns}),
    Monitor = monitor(process, Owner),
    try await_group_complete(Ns, Group, Owner, Monitor, quod_time:mono_ms() + 10000)
    after demonitor(Monitor, [flush]), quod_reg:unsubscribe({runtime, Ns}) end.

await_group_complete(Ns, Group, Owner, Monitor, Deadline) ->
    {ok, #{history := History, applied_floor := Floor}} =
        gen_server:call(Owner, {dtx_group_state, Group}),
    case quod_atomic:history_phase(complete, History) of
        {ok, {quod_dtx_ref, 3, _, _, Slot, _, _, _}} when Slot =< Floor -> ok;
        _ ->
            Remaining = max(0, Deadline - quod_time:mono_ms()),
            receive
                {projection_advanced, Owner, _} ->
                    await_group_complete(Ns, Group, Owner, Monitor, Deadline);
                {'DOWN', Monitor, process, Owner, Reason} -> error({group_owner_down, Ns, Reason})
            after Remaining -> error({group_complete_missing, Ns, Group}) end
    end.


assert_gui_view_lifecycle(Ctx, OtherCtx, HumanNs, ResponderNs, AppNs, Q, Reference) ->
    Session = gui_session(Ctx), Parent = self(),
    {Hud, HudMonitor} = spawn_monitor(fun() -> gui_socket(Parent, #{peer => {127,0,0,1}}) end),
    {Form, FormMonitor} = spawn_monitor(fun() -> gui_socket(Parent, #{peer => {127,0,0,1}}) end),
    try
        Hud ! {client, gui_open_message(Ctx, Session, gui_hud, HumanNs, none, 0)},
        #{<<"kind">> := <<"gui_hud">>, <<"value">> := Pending,
          <<"receiver">> := Receiver} = gui_reply(Hud, <<"projection">>),
        ?assertEqual(quod_client_goal_parser:value_text([Reference]), Pending),
        HudBefore = gui_socket_state(Hud),
        ReceiverKey = maps:get(receiver_key,HudBefore),
        {client_view,{gui_hud,HumanBytes,ReceiverToken}} = ReceiverKey,
        ?assertMatch({ok,#{reference := {agent_instance_ref,HumanNs,_,{human_user,test_agent}}}},
                     quod_agent_ref:decode(HumanBytes)),
        ?assertEqual(Hud,quod_reg:where(ReceiverKey)),
        ?assertEqual(ReceiverToken,base64:decode(maps:get(<<"token">>,Receiver),#{mode => urlsafe,padding => false})),
        no_io(gui_hud_receiver_renewal, fun() ->
            Hud ! {client, gui_open_message(Ctx, Session, gui_hud, HumanNs, none, 1000)},
            #{<<"receiver">> := Receiver} = gui_reply(Hud, <<"projection">>)
        end),
        ?assertEqual(ReceiverKey,maps:get(receiver_key,gui_socket_state(Hud))),
        %% A second tab has its own address; closing it cannot retire the first.
        {Tab,TabMonitor} = spawn_monitor(fun() -> gui_socket(Parent,#{peer => {127,0,0,1}}) end),
        TabKey = try
            Tab ! {client,gui_open_message(Ctx,Session,gui_hud,HumanNs,none,0)},
            _ = gui_reply(Tab,<<"projection">>),
            maps:get(receiver_key,gui_socket_state(Tab))
        after
            Tab ! stop,
            receive {'DOWN',TabMonitor,process,Tab,normal} -> ok
            after 5000 -> error(tab_not_stopped) end
        end,
        ?assertNotEqual(ReceiverKey,TabKey),
        ?assertEqual(undefined,quod_reg:where(TabKey)),
        ?assertEqual(Hud,quod_reg:where(ReceiverKey)),
        Form ! {client, gui_open_message(Ctx, Session, gui_question, ResponderNs, Q, 0)},
        #{<<"kind">> := <<"gui_question">>} = gui_reply(Form, <<"projection">>),
        Before = gui_socket_state(Form),
        ?assertNot(maps:is_key(receiver_key,Before)),
        ?assertNot(maps:is_key(pid, Before)),
        ?assertNot(maps:is_key(world, Before)),
        ?assert(maps:is_key(AppNs, maps:get(heights, Before))),
        ?assertNot(maps:is_key(AppNs, maps:get(heights, gui_socket_state(Hud)))),
        no_io(gui_renewal, fun() ->
            Form ! {client, gui_open_message(Ctx, Session, gui_question, ResponderNs, Q, 1000)},
            _ = gui_reply(Form, <<"projection">>)
        end),
        Renewed = gui_socket_state(Form),
        ?assertEqual(maps:get(dependency_monitors, Before), maps:get(dependency_monitors, Renewed)),
        ?assertEqual(maps:get(follows, Before), maps:get(follows, Renewed)),
        %% Only the form follows this source. Its installed proof is retired
        %% before another view can be read; the HUD list needs no refresh.
        AppCtx = Ctx#{agent => {AppNs, quod_simplex:genesis_hash(AppNs)}, instance => <<"fixture_admin.">>},
        commit(AppCtx, {assertz, view_probe}),
        #{<<"reason">> := <<"durable_gap">>} = gui_reply(Form, <<"refresh">>),
        ?assertEqual(true, maps:get(installed, gui_socket_state(Hud))),
        commit(AppCtx, {retract, view_probe}),
        Form ! {client, gui_open_message(OtherCtx, Session, gui_question, ResponderNs, Q, 0)},
        _ = gui_reply(Form, <<"unavailable">>),
        ?assertNot(maps:is_key(installed, gui_socket_state(Form))),
        assert_gui_resources(Hud,Ctx,Session,HumanNs,ResponderNs,Q,Reference),
        %% Switching to another authenticated human on the same socket retires
        %% the old human's address, even when both use the same signing key.
        Hud ! {client, gui_open_message(OtherCtx, Session, gui_hud, HumanNs, none, 0)},
        _ = gui_reply(Hud, <<"projection">>),
        ?assertEqual(undefined,quod_reg:where(ReceiverKey)),
        Switched = gui_socket_state(Hud),
        ?assertEqual(#{},maps:get(gui_resources,Switched,#{})),
        SwitchedKey = maps:get(receiver_key,Switched),
        ?assertNotEqual(ReceiverKey,SwitchedKey),
        %% A retired timer cannot remove a replacement projection. The exact
        %% installed timer does remove its address before reporting refresh.
        Hud ! {timeout,maps:get(timer,HudBefore),expired},
        ?assertEqual(SwitchedKey,maps:get(receiver_key,gui_socket_state(Hud))),
        Hud ! {timeout,maps:get(timer,Switched),expired},
        #{<<"reason">> := <<"expired">>} = gui_reply(Hud,<<"refresh">>),
        ?assertEqual(undefined,quod_reg:where(SwitchedKey))
    after
        Hud ! stop, Form ! stop,
        receive {'DOWN', HudMonitor, process, Hud, normal} -> ok after 5000 -> error(hud_not_stopped) end,
        receive {'DOWN', FormMonitor, process, Form, normal} -> ok after 5000 -> error(form_not_stopped) end
    end.

%% Exercise the actual signed socket owner. Native expiry concerns only these
%% provisional handles; it is never negative evidence about a material write.
assert_gui_resources(Hud,Ctx,Session,HumanNs,ResponderNs,Q,Reference) ->
    {client_view,{gui_hud,Human,Connection}} = Key = maps:get(receiver_key,gui_socket_state(Hud)),
    {ok,[#{<<"V0">> := Descriptor}],_} = read(Ctx,ResponderNs,{gui_question_form,Q,{0}}),
    Request = crypto:strong_rand_bytes(32), Expiry = quod_time:now_ms()+30000,
    Deadline = quod_time:mono_ms()+30000,
    Prepare = fun(R,Ref,Form,Capacity) ->
        quod_client_view:prepare_gui(Human,Connection,R,Ref,Form,Capacity,Expiry,Deadline)
    end,
    ?assertEqual({error,human_unavailable},quod_client_view:prepare_gui(
        Human,<<0:256>>,Request,Reference,Descriptor,1,Expiry,Deadline)),
    ?assertEqual({error,human_unavailable},Prepare(Request,Reference,{'_'},1)),
    First = gui_async(fun() -> Prepare(Request,Reference,Descriptor,1) end),
    #{<<"token">> := Encoded,<<"question">> := RefText,<<"descriptor">> := FormText} =
        gui_reply(Hud,<<"gui_prepare">>),
    ?assertEqual(quod_client_goal_parser:value_text(Reference),RefText),
    ?assertEqual(quod_client_goal_parser:value_text(Descriptor),FormText),
    Token = base64:decode(Encoded,#{mode => urlsafe,padding => false}),
    ?assertEqual({error,presentation_pending},Prepare(Request,Reference,Descriptor,1)),
    gui_ack(Hud,#{type => gui_prepared,token => Encoded,accepted => true}),
    {ok,{gui_receipt,Token,Bound}} = Receipt = gui_result(First),
    ?assert(Bound =< Expiry),
    no_io(gui_native_receipt,fun() -> ?assertEqual(Receipt,Prepare(Request,Reference,Descriptor,1)) end),
    ?assertEqual({error,presentation_conflict},Prepare(<<2:256>>,Reference,Descriptor,2)),
    OtherRef = setelement(4,Reference,{question,<<2:256>>}),
    ?assertEqual({error,presentation_capacity},Prepare(<<2:256>>,OtherRef,Descriptor,1)),
    %% Own-commit invalidation can retire the HUD proof, not the accepted
    %% resource. Further prepare requires a new authorized projection.
    Before = gui_socket_state(Hud),
    Hud ! {timeout,maps:get(timer,Before),expired},
    _ = gui_reply(Hud,<<"refresh">>),
    ?assertEqual(Hud,quod_reg:where(Key)),
    ?assertEqual({error,human_unavailable},Prepare(Request,Reference,Descriptor,1)),
    Activated = gui_async(fun() -> quod_client_view:activate_gui(Human,Connection,Request,Token,Deadline) end),
    #{<<"token">> := Encoded} = gui_reply(Hud,<<"gui_activate">>),
    gui_ack(Hud,#{type => gui_activated,token => Encoded,status => active}),
    ?assertEqual({ok,active},gui_result(Activated)),
    no_io(gui_native_activation,fun() ->
        ?assertEqual({ok,active},quod_client_view:activate_gui(Human,Connection,Request,Token,Deadline))
    end),
    ?assertEqual({ok,expired},quod_client_view:activate_gui(Human,Connection,<<0:256>>,Token,Deadline)),
    #{Token := #{timer := Timer}} = maps:get(gui_resources,gui_socket_state(Hud)),
    Hud ! {timeout,make_ref(),{gui_resource,Token}},
    ?assert(maps:is_key(Token,maps:get(gui_resources,gui_socket_state(Hud)))),
    Hud ! {timeout,Timer,{gui_resource,Token}},
    _ = gui_reply(Hud,<<"gui_expired">>),
    ?assertEqual(undefined,quod_reg:where(Key)),
    ?assertEqual({ok,expired},quod_client_view:activate_gui(Human,Connection,Request,Token,Deadline)),
    gui_ack(Hud,#{type => gui_prepared,token => Encoded,accepted => true}),
    ?assertEqual(#{},maps:get(gui_resources,gui_socket_state(Hud),#{})),
    Hud ! {client,gui_open_message(Ctx,Session,gui_hud,HumanNs,none,0)},
    _ = gui_reply(Hud,<<"projection">>),
    ?assertEqual(Key,maps:get(receiver_key,gui_socket_state(Hud))),
    Refused = gui_async(fun() -> Prepare(<<3:256>>,Reference,Descriptor,1) end),
    #{<<"token">> := RefusedToken} = gui_reply(Hud,<<"gui_prepare">>),
    gui_ack(Hud,#{type => gui_prepared,token => RefusedToken,accepted => false}),
    ?assertEqual({error,presentation_refused},gui_result(Refused)),
    ?assertEqual(#{},maps:get(gui_resources,gui_socket_state(Hud),#{})),
    %% Independent preparations correlate correctly even when the browser
    %% accepts them in the reverse order.
    Concurrent1 = gui_async(fun() -> Prepare(<<5:256>>,Reference,Descriptor,2) end),
    #{<<"token">> := ConcurrentToken1} = gui_reply(Hud,<<"gui_prepare">>),
    Concurrent2 = gui_async(fun() -> Prepare(<<6:256>>,OtherRef,Descriptor,2) end),
    #{<<"token">> := ConcurrentToken2} = gui_reply(Hud,<<"gui_prepare">>),
    gui_ack(Hud,#{type => gui_prepared,token => ConcurrentToken2,accepted => true}),
    gui_ack(Hud,#{type => gui_prepared,token => ConcurrentToken1,accepted => true}),
    {ok,{gui_receipt,T1,_}} = gui_result(Concurrent1),
    {ok,{gui_receipt,T2,_}} = gui_result(Concurrent2),
    ?assertNotEqual(T1,T2),
    lists:foreach(fun(T) ->
        #{T := #{timer := RT}} = maps:get(gui_resources,gui_socket_state(Hud)),
        Hud ! {timeout,RT,{gui_resource,T}}, _ = gui_reply(Hud,<<"gui_expired">>)
    end,[T1,T2]),
    Parent = self(),
    {Tab,TabMonitor} = spawn_monitor(fun() -> gui_socket(Parent,#{peer => {127,0,0,1}}) end),
    Tab ! {client,gui_open_message(Ctx,Session,gui_hud,HumanNs,none,0)},
    _ = gui_reply(Tab,<<"projection">>),
    {client_view,{gui_hud,Human,TabConnection}} = maps:get(receiver_key,gui_socket_state(Tab)),
    Lost = gui_async(fun() -> quod_client_view:prepare_gui(
        Human,TabConnection,Request,Reference,Descriptor,1,Expiry,Deadline) end),
    _ = gui_reply(Tab,<<"gui_prepare">>),
    Tab ! stop,
    ?assertEqual({error,presentation_expired},gui_result(Lost)),
    receive {'DOWN',TabMonitor,process,Tab,normal} -> ok after 5000 -> error(tab_not_stopped) end,
    ?assertEqual({ok,expired},quod_client_view:activate_gui(Human,TabConnection,Request,T1,Deadline)),
    %% Leave one accepted resource to test identity replacement above.
    Pending = gui_async(fun() -> Prepare(<<4:256>>,Reference,Descriptor,1) end),
    #{<<"token">> := PendingToken} = gui_reply(Hud,<<"gui_prepare">>),
    gui_ack(Hud,#{type => gui_prepared,token => PendingToken,accepted => true}),
    ?assertMatch({ok,{gui_receipt,_,_}},gui_result(Pending)).

gui_async(Fun) ->
    Parent = self(), Ref = make_ref(),
    {Pid,Monitor} = spawn_monitor(fun() -> Parent ! {Ref,Fun()} end),
    {Ref,Pid,Monitor}.
gui_result({Ref,Pid,Monitor}) ->
    Result = receive {Ref,Value} -> Value after 10000 -> error(native_gui_result_missing) end,
    receive {'DOWN',Monitor,process,Pid,normal} -> Result
    after 5000 -> error(native_gui_caller_not_stopped) end.
gui_ack(Hud,Message) -> Hud ! {client,iolist_to_binary(json:encode(Message))}.

assert_receiver_selection(Ctx, OtherCtx, ActorCtx, HumanNs, Instance, Actor) ->
    {ok,Node} = application:get_env(quod,node_pubkey),
    First = <<71:256>>, Second = <<72:256>>,
    Select = fun(Token) -> scope(HumanNs,{gui_select_receiver,Instance,Node,Token}) end,
    Read = {gui_receiver_for,Instance,{0}},
    commit(Ctx,Select(First)),
    ?assertMatch({ok,[#{<<"V0">> := {receiver,Node,First}}],_},read(Ctx,HumanNs,Read)),
    fail(OtherCtx,Select(Second)),
    fail(ActorCtx,Select(Second)),
    ?assertMatch({fail,_},read(ActorCtx,HumanNs,Read)),
    Policy = {gui_receiver_policy,Instance,Actor},
    commit(Ctx,scope(HumanNs,{assertz,Policy})),
    ?assertMatch({ok,[#{<<"V0">> := {receiver,Node,First}}],_},read(ActorCtx,HumanNs,Read)),
    commit(Ctx,Select(Second)),
    fail(Ctx,scope(HumanNs,{gui_select_receiver,Instance,<<0>>,First})),
    ?assertMatch({ok,[#{<<"V0">> := {receiver,Node,Second}}],_},read(Ctx,HumanNs,Read)),
    no_io(receiver_selection,fun() ->
        ?assertMatch({ok,[#{<<"V0">> := {receiver,Node,Second}}],_},read(Ctx,HumanNs,Read))
    end),
    commit(Ctx,scope(HumanNs,{retract,Policy})),
    ?assertMatch({fail,_},read(ActorCtx,HumanNs,Read)).

gui_session(Ctx) ->
    {Pub, _} = Pair = maps:get(key_pair, Ctx), Nonce = crypto:strong_rand_bytes(32),
    {ok, Challenge} = quod_client_auth:issue_challenge(Pub, Nonce, {127,0,0,1}),
    Id = maps:get(challenge_id, Challenge),
    {ok, NodeKey} = application:get_env(quod, node_pubkey),
    {ok, Bytes} = quod_client_auth:challenge_bytes(maps:get(network, Ctx), NodeKey, Id, Pub, Nonce,
        maps:get(server_nonce, Challenge), maps:get(expires_ms, Challenge)),
    {ok, #{session_id := Session}} = quod_client_auth:complete_challenge(Id,
        quod_identity:sign(Bytes, quod_identity:key_term(Pair))),
    Session.

gui_open_message(Ctx, Session, Kind, Ns, Q, ExtraExpiry) ->
    gui_open_message(Ctx,Session,Kind,Ns,quod_simplex:genesis_hash(Ns),Q,ExtraExpiry).

gui_open_message(Ctx, Session, Kind, Ns, Anchor, Q, ExtraExpiry) ->
    {Source, SourceAnchor} = maps:get(agent, Ctx),
    {Pub, _} = Pair = maps:get(key_pair, Ctx),
    Inner = case Kind of gui_hud -> <<"gui_pending_questions(View)">>;
        gui_question -> [<<"gui_question_form(">>, quod_client_goal_parser:value_text(Q), <<",View)">>] end,
    Goal = iolist_to_binary([quod_client_goal_parser:value_text(Ns), " :: (current_ontology_identity(",
        quod_client_goal_parser:value_text(Ns), ",", quod_client_goal_parser:value_text(Anchor), "),", Inner, ")."]),
    {ok, Bytes} = quod_client_goal:encode(#{network_identity => maps:get(network, Ctx),
        agent_namespace => Source, agent_genesis_anchor => SourceAnchor,
        agent_instance_text => maps:get(instance, Ctx, <<"human_user(test_agent).">>),
        signing_public_key => Pub, operation_id => crypto:strong_rand_bytes(32),
        not_after_ms => quod_time:now_ms() + 30000 + ExtraExpiry, mode => read, parser_version => 3, goal_text => Goal}),
    Enc = fun(B) -> base64:encode(B, #{mode => urlsafe, padding => false}) end,
    iolist_to_binary(json:encode(#{type => open, view_kind => Kind, session_id => Enc(Session),
        view_namespace => Ns, view_anchor => Enc(Anchor), request => Enc(Bytes),
        signature => Enc(quod_identity:sign(Bytes, quod_identity:key_term(Pair)))})).

gui_reply(Socket, Type) ->
    receive {gui_view, Socket, #{<<"type">> := Type} = Message} -> Message;
            {gui_view, Socket, Unexpected} -> error({unexpected_gui_reply, Unexpected})
    after 10000 -> error({missing_gui_reply, Type}) end.

gui_socket_state(Socket) ->
    Ref = make_ref(), Socket ! {inspect, Ref},
    receive {Ref, State} -> State after 5000 -> error(gui_state_missing) end.

gui_socket(Parent, S) -> gui_socket(Parent,S,false).
gui_socket(Parent, S, Automatic) ->
    receive
        stop -> quod_client_view:terminate(normal, unused, S);
        {inspect, Ref} -> Parent ! {Ref, S}, gui_socket(Parent, S, Automatic);
        {automatic, Mode} when is_boolean(Mode) -> gui_socket(Parent,S,Mode);
        Message ->
            Result = case Message of
                {client, Bytes} -> quod_client_view:websocket_handle({text, Bytes}, S);
                _ -> quod_client_view:websocket_info(Message, S)
            end,
            case Result of
                {[{set_options,#{idle_timeout := Idle}},{text,Json}], Next} when is_integer(Idle), Idle >= 0 ->
                    Parent ! {gui_view,self(),json:decode(Json)},
                    gui_socket(Parent, Next, Automatic);
                {ok, Next} -> gui_socket(Parent, Next, Automatic);
                {reply, {text, Json}, Next} ->
                    Frame = json:decode(Json),
                    Parent ! {gui_view, self(), Frame},
                    case {Automatic,Frame} of
                        {true,#{<<"type">> := <<"gui_prepare">>,<<"token">> := Token}} ->
                            gui_ack(self(),#{type => gui_prepared,token => Token,accepted => true});
                        {true,#{<<"type">> := <<"gui_activate">>,<<"token">> := Token}} ->
                            gui_ack(self(),#{type => gui_activated,token => Token,status => active});
                        _ -> ok
                    end,
                    gui_socket(Parent, Next, Automatic);
                {reply, {close, _, _} = Closed, Next} ->
                    Parent ! {gui_view, self(), Closed}, quod_client_view:terminate(normal, unused, Next)
            end
    end.
