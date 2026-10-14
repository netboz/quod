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
        RollbackGrant = {can_invoke, {transaction, {',', {gui_complete, {'Q'}}, fail}},
            {agent_instance_ref, ResponderNs, {'_'}, responder}, {'_'}, ResponderNs},
        HudHelperGrant = {can_invoke,
            {',', {current_ontology_identity, ResponderNs, {'_'}},
             scope(HumanNs, {gui_unlink, HumanInstance, {'Ref'}})},
            {agent_instance_ref, ResponderNs, {'_'}, responder}, {'_'}, ResponderNs},
        {Responder, _} = quod_lobby_tests:start_namespace(ResponderNs, Base#{
            data_dir => filename:join(Dir, "responsible"),
            genesis_diff => quod_prolog:terms_to_diff(source("agent_instance.pl") ++
                source("gui_question.pl") ++ [Admin, RollbackGrant, HudHelperGrant,
                                             {agent_key, responder, PublicKey, active}])}),
        ResponderAnchor = quod_simplex:genesis_hash(ResponderNs),
        Actor = {agent_instance_ref, ResponderNs, ResponderAnchor, responder},
        ActorCtx = Ctx#{agent => {ResponderNs, ResponderAnchor}, instance => <<"responder.">>},
        AppNs = <<"gui:application">>,
        Callback = {':-', {settings_entered, {'N'}, {'M'}, {'L'}, {'A'}},
                    {',', {assertz, {saved, {'N'}, {'M'}, {'L'}, {'A'}}}, {'\\+', reject_save}}},
        SourceHelperGrant = {can_invoke,
            {',', {current_ontology_identity, AppNs, {'_'}},
             scope(ResponderNs, {gui_consume, {'Q'}})}, Actor, {'_'}, AppNs},
        {Application, _} = quod_lobby_tests:start_namespace(AppNs, Base#{
            data_dir => filename:join(Dir, "application"),
            genesis_diff => quod_prolog:terms_to_diff(source("gui_instance.pl") ++
                quod_prolog:read_terms("test/fixtures/gui-components.pl") ++
                [Admin, SourceHelperGrant, Callback, {gui_question_policy, settings, Human, Actor},
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
            ?assertMatch({ok, [#{<<"V0">> := [Reference]}], _},
                read(Ctx, HumanNs, {gui_pending_questions, {0}})),
            ?assertMatch({fail, _}, read(ActorCtx, HumanNs, {gui_pending_questions, {0}})),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs,
                {instance_of, {':', quod, {':', gui, question}}, Question})),
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
            %% A forged event or direct helper entry supplies no authority to
            %% consume a question or remove its HUD reference.
            commit(Ctx, scope(ResponderNs, {trigger_event, {gui_submitted, Question, <<0:256>>}})),
            fail(ActorCtx, scope(AppNs, scope(ResponderNs, {gui_consume, Question}))),
            fail(ActorCtx, scope(ResponderNs, scope(HumanNs,
                {gui_unlink, HumanInstance, Reference}))),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, Submitted)),
            ?assertMatch({ok, [_], _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, Reference})),
            %% A source failure after staging the domain assertion rolls back
            %% that assertion, question consumption and foreign HUD removal.
            commit(Ctx, scope(AppNs, {assertz, reject_save})),
            fail(ActorCtx, {gui_complete, Question}),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, Submitted)),
            ?assertMatch({ok, [_], _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, Reference})),
            ?assertMatch({fail, _}, read(Ctx, AppNs, {saved, {'_'}, {'_'}, {'_'}, {'_'}})),
            commit(Ctx, scope(AppNs, {retract, reject_save})),
            %% All three scopes were changed by completion before the caller
            %% fails. The enclosing ordinary transaction must restore them all.
            fail(ActorCtx, {transaction, {',', {gui_complete, Question}, fail}}),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, Submitted)),
            ?assertMatch({ok, [_], _}, read(Ctx, HumanNs, {gui_pending, HumanInstance, Reference})),
            ?assertMatch({fail, _}, read(Ctx, AppNs, {saved, {'_'}, {'_'}, {'_'}, {'_'}})),
            commit(ActorCtx, {gui_complete, Question}),
            ?assertMatch({ok, [_], _}, read(Ctx, AppNs, {saved, <<"Entered">>, square, 75, 180})),
            ?assertMatch({fail, _}, read(Ctx, ResponderNs, Submitted)),
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
                setelement(7, RaceRow, {submitted, WinningOperation, apply, Fields}))),
            commit(ActorCtx, {gui_complete, RaceQ}),
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
                {ok, _, {normalized, {committed, _, _}}} -> commit(ActorCtx, {gui_complete, CancelQ});
                _ -> ?assertMatch({fail, _}, read(Ctx, ResponderNs,
                    {gui_question, CancelQ, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}))
            end,
            ?assertMatch({ok, [#{<<"V0">> := []}], _},
                read(Ctx, HumanNs, {gui_pending_questions, {0}}))
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
