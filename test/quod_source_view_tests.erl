-module(quod_source_view_tests).
-include_lib("eunit/include/eunit.hrl").

committed_signed_read_preserves_bindings_and_scope_restrictions_test_() ->
    {timeout, 120, fun() ->
        Dir = filename:join("/tmp", "quod-committed-read-" ++
            binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
        Ctx = quod_lobby_tests:start(Dir),
        {ontology_ref, Lobby, _} = maps:get(lobby, Ctx),
        {_, Config} = maps:get(Lobby, maps:get(ontologies, Ctx)),
        Owner = <<"committed-class-owner">>, Store = <<"committed-store">>,
        Grant = {can_invoke, {'_'}, {'_'}, {'_'}, Owner},
        {OwnerSup, _} = quod_lobby_tests:start_namespace(Owner, Config#{
            data_dir => filename:join(Dir, "owner"),
            genesis_diff => quod_prolog:terms_to_diff([Grant, {isa, room, space}])}),
        {StoreSup, _} = quod_lobby_tests:start_namespace(Store, Config#{
            data_dir => filename:join(Dir, "store"),
            genesis_diff => quod_prolog:terms_to_diff([
                {instance_of, {':', 'committed-class-owner', room}, item}])}),
        StoreIdentity = {Store,quod_simplex:genesis_hash(Store)},
        {ok,Follow} = quod_foreign_log:follow(StoreIdentity,projection),
        {Reader,Generation} = retained_reader(Follow,StoreIdentity),
        Read = fun(Query = {'::',Target,Goal}) when Target =:= Store ->
            Deadline = quod_time:mono_ms() + 30000,
            {Bytes,Signature} = quod_lobby_tests:signed_request(Ctx,read,Query),
            {ok,Evidence} = quod_client_goal:verify(Bytes,Signature),
            quod_foreign_projection:read(Reader,Generation,Deadline,
                fun(#{est := Est,height := Height}) ->
                    Context = quod_predicates:proof_context(Store,Height,[]),
                    quod_prolog:prove_est(Goal,quod_predicates:set_context(Est,Context),
                        #{identity => StoreIdentity,height => Height,
                          deadline_ms => Deadline,evidence => Evidence})
                end)
        end,
        Query = {'::', Store, {',', {instance_of, {0}, item},
                                  {isa, {0}, {':', 'committed-class-owner', space}}}},
        try
            {read, Dependencies, {ok, Bindings, [], _}} = Read(Query),
            ?assertMatch({Owner,_,1,[_|_]},lists:keyfind(Owner,1,Dependencies)),
            {Owner,OwnerAnchor,1,OwnerReads} = lists:keyfind(Owner,1,Dependencies),
            ?assertEqual(quod_simplex:genesis_hash(Owner),OwnerAnchor),
            ?assert(lists:keymember({isa,2},1,OwnerReads)),
            ?assertEqual({':', 'committed-class-owner', room},maps:get(0,Bindings)),
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                ?assertMatch({read, _, {ok, _, [], _}}, Read(Query))
            end),
            lists:foreach(fun({Forbidden,Reason}) ->
                ?assertMatch({read, _, {error, {erlog,Reason}}},
                    Read({'::', Store, {'::', Owner, Forbidden}}))
            end, [{{assertz, leaked},{permission_error,modify,static_procedure,{'/',leaked,0}}},
                  {{'$quod_ontology_routes', []},
                    {context_violation,{'$quod_ontology_routes',1},query,operation_guard}},
                  {{limit_reaction_expiry, 1000},
                    {context_violation,{limit_reaction_expiry,1},reaction,operation_guard}}]),
            ?assertMatch({fail, _}, quod_lobby_tests:read(Ctx, {'::', Owner, leaked})),
            scene_commit(Ctx, Owner, {'$quod_retract_exact', Grant}),
            ?assertMatch({read, _, {fail, _}}, Read(Query))
        after
            ok = quod_foreign_log:unfollow(Follow),
            [quod_lobby_tests:stop_process(Sup) || Sup <- [StoreSup, OwnerSup]],
            quod_lobby_tests:stop(Ctx)
        end
    end}.

retained_reader(Follow,Identity) ->
    receive
        {quod_foreign_follow,Follow,Notice,Identity,State} ->
            ok = quod_foreign_log:ack(Follow,Notice),
            case State of
                {resnapshot,_,_,#{reader := Reader}} -> Reader;
                {advanced,_,_,_,#{reader := Reader},_,_} -> Reader;
                _ -> retained_reader(Follow,Identity)
            end
    after 10000 -> error(retained_reader_not_ready)
    end.

class_owned_scene_uses_storing_slots_and_separate_recipe_test_() ->
    {timeout, 120, fun class_owned_scene/0}.

class_owned_scene() ->
    Dir = filename:join("/tmp", "quod-class-scene-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Ctx = quod_lobby_tests:start(Dir),
    {ontology_ref, Lobby, _} = maps:get(lobby, Ctx),
    {_, Config} = maps:get(Lobby, maps:get(ontologies, Ctx)),
    RecipeNs = <<"display-recipes">>, ClassNs = <<"display-class">>,
    BaseNs = <<"display-base">>, Store = <<"display-store">>,
    {ok, RecipeTerms} = erlog_io:read_string_terms(
        "eidolon(card,subject(ontology_ref(Ns,A),I),"
        "[part(<<\"card\">>,group,transform(0,0,0,0,0,0),"
        "no_surface,label(Title,<<\"above\">>),depicts_nothing)]) :- "
        "in_ontology(Ns,A,attribute(I,title,Title))."),
    Start = fun(Ns, Terms) -> quod_lobby_tests:start_namespace(Ns, Config#{
        data_dir => filename:join(Dir, binary_to_list(Ns)),
        genesis_diff => quod_prolog:terms_to_diff([
            {can_invoke, {'_'}, {'_'}, {'_'}, Ns} | Terms])}) end,
    {RecipeSup, _} = Start(RecipeNs, RecipeTerms),
    Recipe = {recipe, RecipeNs, quod_simplex:genesis_hash(RecipeNs), card},
    {BaseSup, _} = Start(BaseNs, [{isa, card, thing},
        {entity_scene, {subject, {'_'}, {'_'}}, playing, hidden}]),
    {ok, ClassTerms} = erlog_io:read_string_terms(
        "isa(card,'display-base':card). "
        "entity_scene(subject(ontology_ref(Ns,A),I),Mode,"
        "appearance(I,solid,subject(ontology_ref(Ns,A),I),Pose,Choices)) :- "
        "in_ontology(Ns,A,(attribute(I,transform,Pose),"
        "entity_eidolons(I,Mode,solid,Choices)))."),
    {ClassSup, _} = Start(ClassNs,
        [{class_eidolon, card, playing, solid, Recipe} | ClassTerms]),
    Pose = {transform, 100, 200, 300, 0, 45, 0},
    ModelNs = <<"lobby-test-modelling">>,
    {StoreSup, _} = Start(Store, [
        {instance_of, {':', 'display-class', card}, item},
        {attribute, item, title, <<"Original">>}, {attribute, item, transform, Pose},
        {modelling_vocabulary, ModelNs, quod_simplex:genesis_hash(ModelNs)}]),
    Anchor = quod_simplex:genesis_hash(Store),
    Choice = {eidolon, playing, solid, Recipe},
    Query = {'::', Store, {client_eidolon, item, Choice, {0}}},
    Read = fun(Title) ->
        {ok, [#{<<"V0">> := {eidolon_scene, {entity_ref, Store, Anchor, item},
                            Marks, nonphysical, []}}], _} = quod_lobby_tests:read(Ctx, Query),
        ?assert(lists:any(fun(M) -> element(7, M) =:= {label, Title, <<"above">>} end, Marks)),
        ?assertEqual(Pose, element(5, hd(Marks)))
    end,
    try
        Read(<<"Original">>),
        quod_lobby_tests:assert_read_has_no_io(fun() ->
            [Read(<<"Original">>) || _ <- lists:seq(1, 3)]
        end),
        scene_commit(Ctx, Store, {',', {retract, {attribute, item, title, <<"Original">>}},
                                     {assertz, {attribute, item, title, <<"Updated">>}}}),
        Read(<<"Updated">>),
        scene_commit(Ctx, Store, {assertz, {entity_scene, item, playing, hidden}}),
        ?assertMatch({ok, [#{}], _}, quod_lobby_tests:read(Ctx,
            {'::', Store, {client_entity_scene, item, playing, hidden}})),
        HiddenRead = quod_lobby_tests:read(Ctx, Query),
        ?assertMatch({fail, _}, HiddenRead),
        scene_commit(Ctx, Store, {retract, {entity_scene, item, playing, hidden}}),
        Read(<<"Updated">>),
        %% Revoking class-owner access must not select the ancestor's scene.
        scene_commit(Ctx, ClassNs,
            {'$quod_retract_exact', {can_invoke, {'_'}, {'_'}, {'_'}, ClassNs}}),
        RevokedRead = quod_lobby_tests:read(Ctx, Query),
        ?assertMatch({fail, _}, RevokedRead)
    after
        [quod_lobby_tests:stop_process(Sup) || Sup <- [StoreSup, ClassSup, BaseSup, RecipeSup]],
        quod_lobby_tests:stop(Ctx)
    end.

scene_commit(Ctx, Ns, Goal) ->
    {ok, Evidence, {normalized, {committed, _, _}}} =
        quod_lobby_tests:submit(Ctx, execute, {'::', Ns, Goal}),
    Ref = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state := terminal},
        quod_ct:await_operation_complete(element(2, Ref), Ref, 10000)).

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
