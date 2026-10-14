-module(quod_gui_question_tests).
-include_lib("eunit/include/eunit.hrl").

%% Pending rows are explicit fixture inputs. This tests transitions after an
%% accepted opening, not a substitute for the unimplemented live acceptance.
accepted_question_transitions_use_signed_atomic_owners_test_() ->
    {timeout, 120, fun() ->
        Dir = filename:join("/tmp", "quod-gui-questions-" ++
                            integer_to_list(erlang:unique_integer([positive]))),
        Ctx = quod_lobby_tests:start(Dir),
        {ontology_ref, Lobby, _} = maps:get(lobby, Ctx),
        {_, Base} = maps:get(Lobby, maps:get(ontologies, Ctx)),
        {HumanNs, HumanAnchor} = maps:get(agent, Ctx),
        HumanInstance = {human_user, test_agent},
        Human = {agent_instance_ref, HumanNs, HumanAnchor, HumanInstance},
        {PublicKey, _} = maps:get(key_pair, Ctx),
        ResponderNs = <<"gui:responsible">>,
        Admin = {can_invoke, {'_'}, Human, {'_'}, {'_'}},
        {Responder, _} = quod_lobby_tests:start_namespace(ResponderNs, Base#{
            data_dir => filename:join(Dir, "responsible"),
            genesis_diff => quod_prolog:terms_to_diff(source("agent_instance.pl") ++
                source("gui_question.pl") ++ [Admin, {agent_key, responder, PublicKey, active}])}),
        ResponderAnchor = quod_simplex:genesis_hash(ResponderNs),
        Actor = {agent_instance_ref, ResponderNs, ResponderAnchor, responder},
        ActorCtx = Ctx#{agent => {ResponderNs, ResponderAnchor}, instance => <<"responder.">>},
        AppNs = <<"gui:application">>,
        Callback = {':-', {settings_entered, {'N'}, {'M'}, {'L'}, {'A'}},
                    {',', {assertz, {saved, {'N'}, {'M'}, {'L'}, {'A'}}}, {'\\+', reject_save}}},
        {Application, _} = quod_lobby_tests:start_namespace(AppNs, Base#{
            data_dir => filename:join(Dir, "application"),
            genesis_diff => quod_prolog:terms_to_diff(source("gui_instance.pl") ++
                quod_prolog:read_terms("test/fixtures/gui-components.pl") ++
                [Admin, Callback, {gui_question_policy, settings, Human, Actor},
                 {gui_vocabulary, <<"quod:gui">>, quod_simplex:genesis_hash(<<"quod:gui">>)}])}),
        try
            commit(Ctx, scope(HumanNs, assertions(source("gui_hud.pl") ++
                [{instance_of, human_user, HumanInstance}]))),
            {ok, [#{<<"V0">> := Revision}], _} = read(Ctx, AppNs, {gui_schema, settings, {0}, {'_'}}),
            Source = {form_ref, AppNs, quod_simplex:genesis_hash(AppNs), settings},
            Fields = [{field, name, <<"Entered">>}, {field, mode, square},
                      {field, level, 75}, {field, angle, 180}],
            Question = {question, <<1:256>>},
            Reference = {question_ref, ResponderNs, ResponderAnchor, Question},
            Awaiting = {gui_question, Question, Source, Human, responder, Revision, awaiting},
            seed(Ctx, ResponderNs, HumanNs, HumanInstance, Reference, Awaiting),
            Submit = {gui_submit, Question, Revision, apply, Fields},
            %% Source schema validation and the assigned human remain enforced
            %% even where the containing ontology grants its owner broad access.
            fail(Ctx, scope(ResponderNs, setelement(3, Submit, <<0:256>>))),
            fail(Ctx, scope(ResponderNs, setelement(5, Submit, tl(Fields)))),
            fail(ActorCtx, Submit),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, Awaiting)),
            {ok, #{operation_ref := Submission}, {normalized, {committed, _, _}}} =
                quod_lobby_tests:submit(Ctx, execute, scope(ResponderNs, Submit)),
            Submitted = setelement(7, Awaiting, {submitted, Submission, apply, Fields}),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, Submitted)),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, {gui_submitted, Question, Submission})),
            fail(Ctx, scope(ResponderNs, Submit)),
            fail(Ctx, scope(ResponderNs, {gui_cancel, Question})),
            fail(Ctx, scope(ResponderNs, {gui_complete, Question})),
            fail(ActorCtx, {gui_consume, Question}),
            %% A source failure after staging the domain assertion rolls back
            %% that assertion, question consumption and foreign HUD removal.
            commit(Ctx, scope(AppNs, {assertz, reject_save})),
            fail(ActorCtx, {gui_complete, Question}),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, Submitted)),
            ?assertMatch({ok, [_], _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, Reference})),
            ?assertMatch({fail, _}, read(Ctx, AppNs, {saved, {'_'}, {'_'}, {'_'}, {'_'}})),
            commit(Ctx, scope(AppNs, {retract, reject_save})),
            commit(ActorCtx, {gui_complete, Question}),
            ?assertMatch({ok, [_], _}, read(Ctx, AppNs, {saved, <<"Entered">>, square, 75, 180})),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, Submitted)),
            ?assertMatch({fail, _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, Reference})),
            fail(ActorCtx, {gui_complete, Question}),
            fail(Ctx, scope(ResponderNs, Submit)),
            {ok, [#{<<"V0">> := [true]}], _} = read(Ctx, AppNs,
                {findall, true, {saved, {'_'}, {'_'}, {'_'}, {'_'}}, {0}}),
            %% A second opening of the same form has an independent identity.
            OtherQ = {question, <<2:256>>},
            OtherRef = setelement(4, Reference, OtherQ),
            OtherRow = setelement(2, Awaiting, OtherQ),
            seed(Ctx, ResponderNs, HumanNs, HumanInstance, OtherRef, OtherRow),
            commit(Ctx, scope(ResponderNs, {gui_cancel, OtherQ})),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, OtherRow)),
            ?assertMatch({fail, _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, OtherRef})),
            fail(Ctx, scope(ResponderNs, {gui_cancel, OtherQ}))
        after
            quod_lobby_tests:stop_process(Application),
            quod_lobby_tests:stop_process(Responder), quod_lobby_tests:stop(Ctx)
        end,
        file:del_dir_r(Dir)
    end}.

seed(Ctx, ResponderNs, HumanNs, Instance, Ref, Row) ->
    commit(Ctx, {transaction, {',', scope(ResponderNs, {assertz, Row}),
        scope(HumanNs, {assertz, {gui_pending, Instance, Ref}})}}).

source(Name) -> quod_prolog:read_terms(filename:join(code:priv_dir(quod), "ontologies/" ++ Name)).
read(Ctx, Ns, Goal) -> quod_lobby_tests:read(Ctx, scope(Ns, Goal)).
scope(Ns, Goal) -> {'::', Ns, {',', {current_ontology_identity, Ns, quod_simplex:genesis_hash(Ns)}, Goal}}.
commit(Ctx, Goal) ->
    ?assertMatch({ok, _, {normalized, {committed, _, _}}}, quod_lobby_tests:submit(Ctx, execute, Goal)).
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
