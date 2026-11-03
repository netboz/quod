-module(quod_predicate_failure_tests).
-include_lib("eunit/include/eunit.hrl").
-include("retired_remaining_sizes.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ingress_limits.hrl").

%% These contracts cannot be violated by signed ingress: it creates the scope
%% and staging authority itself. Exercise their real overlay owners directly,
%% rather than adding a public way to forge those private values.
physics_private_contracts_test() ->
    with_state(fun(Base) ->
        Read = quod_predicates:set_context(overlay(Base,
            #{read_only => true,signed_request => true,transient_allowed => true}),
            quod_predicates:proof_context(<<"failure:test">>,1,undefined)),
        assert_reason({scope_identity_unavailable,room},
            quod_proof_session:run_first({physics_body_state,room,1,{0}},
                quod_predicates:set_context(Base,quod_predicates:context(Read)),#{read_only => true})),
        assert_reason({scope_identity_unavailable,room},
            quod_proof_session:run_first({physics_control_input,room,frame,1,1,input,{0}},
                quod_predicates:set_context(Base,quod_predicates:context(Read)),
                #{read_only => true,signed_request => true,transient_allowed => true})),
        Anchor = <<1:256>>, World = {world_ref,<<"failure:test">>,Anchor,room},
        Frame = {physics_frame,World,{agent_instance_ref,<<"failure:test">>,Anchor,actor},1,1,<<2:256>>,1},
        Action = {physics_control_input,room,{control_frame,Frame,<<3:256>>},1,1,
                  {drive,{vector,0,0,0},{angular,0,0,0}}},
        {Handle,Bound} = quod_erlog_db_local_prove:register_action_request(Read,Action,{<<"failure:test">>,Anchor}),
        Stage = {'$quod_stage_physics_input',Handle,Action,{control,principal,1,configuration},
                 500,{query_limits,2,0,8,128},{0}},
        ?assertMatch({erlog_error,{context_violation,physics_control_input,staging,unsigned},_},
            catch erlog_int:prove_goal(Stage,Bound)),
        ?assertMatch({erlog_error,{domain_error,physics_lease,0},_},
            catch erlog_int:prove_goal(setelement(5,Stage,0),Bound)),
        ?assertMatch({erlog_error,{domain_error,physics_limits,invalid},_},
            catch erlog_int:prove_goal(setelement(6,Stage,invalid),Bound)),
        ?assertMatch({erlog_error,{domain_error,physics_request_handle,Handle},_},
            catch erlog_int:prove_goal(setelement(3,Stage,setelement(3,Action,invalid)),Bound))
    end).

transient_context_and_descriptor_test() ->
    with_state(fun(Base) ->
        Allowed = #{read_only => true,signed_request => true,transient_allowed => true},
        St = overlay(Base,Allowed),
        ?assertMatch({erlog_error,{domain_error,transient_effect,invalid},_},
            catch quod_erlog_db_local_prove:stage_transient(St,invalid)),
        Effect = {physics_input,self(),#{},{control,principal,1,configuration},1,input,1},
        {ok,Once} = quod_erlog_db_local_prove:stage_transient(St,Effect),
        ?assertEqual({error,transient_already_staged},quod_erlog_db_local_prove:stage_transient(Once,Effect)),
        lists:foreach(fun({Opts,Mode}) ->
            ?assertMatch({erlog_error,{context_violation,physics_control_input,staging,Mode},_},
                catch quod_erlog_db_local_prove:stage_transient(overlay(Base,Opts),Effect))
        end,[{Allowed#{signed_request => false},unsigned},
             {Allowed#{transient_allowed => false},non_control},
             {Allowed#{read_only => false},write_proof}]),
        ?assertMatch({erlog_error,{context_violation,physics_control_input,staging,atomic},_},
            catch quod_erlog_db_local_prove:stage_transient(
                quod_erlog_db_local_prove:set_write_intent(St,atomic),Effect))
    end).

audited_argument_errors_test() ->
    with_state(fun(Base) ->
        Ctx = quod_predicates:proof_context(<<"failure:test">>,1,undefined,[{<<"failure:test">>,<<1:256>>}]),
        St = quod_predicates:set_context(overlay(Base,#{}),Ctx),
        ?assertMatch({erlog_error,{domain_error,signed_goal,#{}},_},
            catch quod_physics_predicates:signed_physics_request(
                {signed_physics_request,#{},not_bytes,not_signature},[],St)),
        ?assertMatch({erlog_error,{context_violation,{absent,0},unregistered,proof},_},
            catch quod_predicates:dispatch(absent,[],St)),
        lists:foreach(fun({Goal,Error}) ->
            ?assertMatch({erlog_error,Error,_},catch erlog_int:prove_goal(Goal,St))
        end,[{{trigger_event,{0}},instantiation_error},
             {{trigger_event,{assert,forbidden}},{domain_error,event,{assert,forbidden}}},
             {{continue_agent_work,actor,wrong},{domain_error,agent_work_wake,wrong}},
             {{continue_agent_work,{0},changed},instantiation_error},
             {{admit,{0},<<"host">>,1},instantiation_error},
             {{remove,bad},{type_error,binary,bad}},
             {{peer_ready,bad},{type_error,binary,bad}},
             {{'$quod_predicate_source',bad,{0}},{domain_error,predicate_indicator,bad}},
             {{ontology_join_state,{0},{1}},instantiation_error},
             {{ontology_join_state,<<>>,{0}},{domain_error,ontology_name,<<>>}},
             {{ontology_genesis_anchor,{0},{1}},instantiation_error},
             {{ontology_genesis_anchor,<<>>,{0}},{domain_error,ontology_name,<<>>}}])
    end).

assert_reason(Reason,{fail,Reasons}) when is_list(Reasons) -> ?assert(lists:member(Reason,Reasons)).

committee_refusal_reasons_test() ->
    Key = <<1:256>>,
    with_state([{peer_admitted,Key,<<"host">>,1,Key}],fun(Base) ->
        assert_reason(last_committee_member,quod_proof_session:run_first(
            {remove,Key},proof_state(Base),#{})),
        ?assertMatch({fail,_},quod_proof_session:run_first(
            {remove,<<2:256>>},proof_state(Base),#{}))
    end),
    Facts = [{peer_admitted,<<I:256>>,<<"host">>,1,<<I:256>>}
             || I <- lists:seq(1,?LEGACY_MAX_VALIDATORS)],
    with_state(Facts,fun(Base) ->
        assert_reason(committee_full,quod_proof_session:run_first(
            {admit,<<0:256>>,<<"host">>,1},proof_state(Base),#{}))
    end).

missing_ontology_anchor_reason_test() ->
    {ok,_} = application:ensure_all_started(gproc),
    with_state(fun(Base) ->
        assert_reason({ontology_anchor_failed,not_hosted},quod_proof_session:run_first(
            {ontology_genesis_anchor,<<"failure:unhosted">>,{0}},proof_state(Base),#{read_only => true}))
    end).

proof_state(Base) ->
    quod_predicates:set_context(Base,quod_predicates:proof_context(<<"failure:test">>,1,undefined)).

overlay(Base,Opts) -> quod_erlog_db_local_prove:wrap_state(Base,Opts).
with_state(Fun) -> with_state([],Fun).
with_state(Facts,Fun) ->
    Est0 = quod_predicates:load_modules(quod_committed_projection:new_est(),
        [quod_agent_work_predicates,quod_ontology_predicates]),
    Est = lists:foldl(fun(Fact,State) ->
        {succeed,Next} = erlog_int:prove_goal({assertz,Fact},State),Next
    end,Est0,Facts),
    #est{db = #db{ref = Ref}} = Base = quod_ct:commit_kb(Est),
    try Fun(Base) after quod_erlog_db_mvcc:delete(Ref) end.
