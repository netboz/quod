-module(quod_gui_question_tests).
-include_lib("eunit/include/eunit.hrl").

%% Pending rows are explicit fixture inputs. This tests transitions after an
%% accepted opening, not a substitute for the unimplemented live acceptance.
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
                [Admin, SourceHelperGrant, Callback, {gui_question_policy, settings, Human, Actor},
                 {gui_question_policy, settings, OtherHuman, Actor},
                 {gui_question_policy, another_form, Human, OtherActor},
                 {gui_vocabulary, <<"quod:gui">>, quod_simplex:genesis_hash(<<"quod:gui">>)}])}),
        try
            commit(Ctx, scope(HumanNs, assertions(source("gui_hud.pl") ++
                [{instance_of, human_user, HumanInstance},
                 {instance_of, human_user, OtherHumanInstance},
                 {agent_key, OtherHumanInstance, PublicKey, active}]))),
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
            quod_lobby_tests:assert_read_has_no_io(fun() ->
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
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                ?assertMatch({ok, [#{<<"V0">> := [Reference]}], _},
                    read(Ctx, HumanNs, {gui_pending_questions, {0}}))
            end),
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs,
                {instance_of, {':', quod, {':', gui, question}}, Question})),
            Submit = {gui_submit, Question, Revision, apply, Fields},
            View = {gui_question_view, Question, Source, Revision, awaiting},
            ?assertMatch({ok, [_], _}, read(Ctx, ResponderNs, View)),
            fail(OtherHumanCtx, scope(ResponderNs, View)),
            quod_lobby_tests:assert_read_has_no_io(fun() ->
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
            ?assertMatch({fail, _}, read(OtherHumanCtx, ResponderNs, FormQuery)),
            ?assertMatch({fail, _}, read(ActorCtx, ResponderNs, FormQuery)),
            quod_lobby_tests:assert_read_has_no_io(fun() ->
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
            ?assertMatch({error, _},
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
            end, [{6, reject_save}, {7, reject_after_consume}])
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

completion_bytes(Ctx, Ns, Q) ->
    {ok, [#{<<"V0">> := Bytes}], _} = read(Ctx, Ns,
        {',', {'=', {0}, {'Bytes'}},
         {gui_question, Q, {'_'}, {'_'}, {'_'}, {'_'},
          {submitted, {'_'}, {'_'}, {'_'}, {'Bytes'}}}}),
    Bytes.

complete(Ctx, Bytes) ->
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(maps:get(key_pair, Ctx))),
    quod_client_goal_ingress:submit(Bytes, Signature).
