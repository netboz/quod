-module(quod_gui_predicates).
-moduledoc "Governed native presentation operations; policy and questions remain in Prolog.".
-include_lib("erlog/src/erlog_int.hrl").
-export([quod_predicate_module/0, load/1, receiver_prepare/3, receiver_activate/3, request/3, stage/3, prepared/3]).

quod_predicate_module() -> true.
load(St) ->
    Native = lists:foldl(fun({Name,Arity,Function},Acc) ->
        quod_predicates:register(Acc,{Name,Arity},query,?MODULE,Function)
    end,St,[{'$quod_gui_receiver_prepare',6,receiver_prepare},
            {'$quod_gui_receiver_activate',4,receiver_activate}]),
    Request = quod_predicates:register(Native,{gui_prepare_question,1},staging,?MODULE,request),
    Stage = quod_predicates:register(Request,{'$quod_stage_gui',3},staging,?MODULE,stage),
    quod_predicates:register(Stage,{'$quod_gui_prepared',1},query,proof_bound,?MODULE,prepared).

receiver_prepare({'$quod_gui_receiver_prepare',H,R,Q,D,C,Receipt},Next,St = #est{bs = Bs}) ->
    {Digest,Expiry,Deadline} = native_context(St),
    [Human,Receiver,Question,Descriptor,Capacity] = erlog_int:dderef([H,R,Q,D,C],Bs),
    ground([Human,Receiver,Question,Descriptor,Capacity],St),
    HumanBytes = human_bytes(Human,St),
    case {Receiver,application:get_env(quod,node_pubkey)} of
        {{receiver,Node,<<_:256>> = Connection},{ok,Node}} when is_integer(Capacity), Capacity > 0 ->
            case quod_client_view:prepare_gui(HumanBytes,Connection,Digest,Question,Descriptor,Capacity,Expiry,Deadline) of
                {ok,Prepared} -> erlog_int:unify_prove_body(Receipt,Prepared,Next,St);
                {error,presentation_timeout} -> erlog_int:erlog_error(gui_presentation_timeout,St);
                {error,Reason} -> quod_predicates:fail_reason({gui_presentation_failed,Reason},St)
            end;
        _ -> erlog_int:domain_error(gui_receiver,Receiver,St)
    end.

receiver_activate({'$quod_gui_receiver_activate',H,C,T,Status},Next,St = #est{bs = Bs}) ->
    {Digest,_,Deadline} = native_context(St),
    [Human,Connection,Token] = erlog_int:dderef([H,C,T],Bs),
    ground([Human,Connection,Token],St),
    HumanBytes = human_bytes(Human,St),
    case {Connection,Token} of
        {<<_:256>>,<<_:256>>} ->
            case quod_client_view:activate_gui(HumanBytes,Connection,Digest,Token,Deadline) of
                {ok,State} -> erlog_int:unify_prove_body(Status,State,Next,St);
                {error,Reason} -> erlog_int:erlog_error({gui_activation_unavailable,Reason},St)
            end;
        _ -> erlog_int:domain_error(gui_receipt,{Connection,Token},St)
    end.

native_context(St) ->
    Context = quod_predicates:context(St),
    case {quod_predicates:ctx_ns(Context),quod_predicates:ctx_kind(Context),
          quod_proof_session:read_only_state(St)} of
        {<<"quod:gui">>,proof,true} -> ok;
        _ -> erlog_int:erlog_error({context_violation,gui_presentation,query,native_read_required},St)
    end,
    {Digest,Expiry,Deadline,_} = request_context(St),
    {Digest,Expiry,Deadline}.

request_context(St) ->
    Auth = case quod_scope_session:request_auth() of
        {ok,Value} -> Value;
        error -> quod_proof_context:request_auth()
    end,
    case Auth of
        {agent_goal_v1,Digest,Bytes,_} ->
            case quod_client_goal:request_identity(Bytes) of
                {ok,#{request := #{mode := execute,not_after_ms := Expiry}}} ->
                    Remaining = case quod_scope_session:remaining_ms() of
                        {ok,Ms} -> Ms;
                        error -> quod_proof_context:remaining_ms()
                    end,
                    {Digest,Expiry,quod_time:mono_ms()+Remaining,Auth};
                _ -> erlog_int:erlog_error(invalid_gui_request_context,St)
            end;
        _ -> erlog_int:erlog_error(invalid_gui_request_context,St)
    end.

ground(Value,St) ->
    case quod_wire_term:is_ground(Value) of true -> ok; false -> erlog_int:instantiation_error(St) end.
human_bytes(Human,St) ->
    case quod_wire_term:encode_canonical(Human) of
        {ok,Bytes} ->
            case quod_agent_ref:decode(Bytes) of
                {ok,_} -> Bytes;
                _ -> erlog_int:domain_error(agent_reference,Human,St)
            end;
        _ -> erlog_int:domain_error(agent_reference,Human,St)
    end.

request({gui_prepare_question,Opening0},Next,St = #est{bs = Bs,vn = Vn}) ->
    Opening = erlog_int:dderef(Opening0,Bs),
    ground(Opening,St),
    case quod_proof_session:read_only_state(St) of
        true -> erlog_int:erlog_error({context_violation,gui_prepare_question,staging,read_proof},St);
        false -> ok
    end,
    case {quod_runtime_predicates:scope_identity(St),Opening} of
        {{ok,{<<"quod:gui">> = Ns,Anchor}},
         {gui_opening,{ontology_ref,Ns,Anchor},_,_,_,_,{form_view,_,_,_,_,_},_,_,_}} ->
            Action = {gui_prepare_question,Opening},
            {Handle,St1} = quod_erlog_db_local_prove:register_action_request(St,Action,Opening),
            Transition = {'$quod_stage_gui',Handle,Opening,{Vn}},
            erlog_int:prove_body([{run_declared_action,Transition}|Next],St1#est{vn = Vn+1});
        _ -> erlog_int:domain_error(gui_opening,Opening,St)
    end.

stage({'$quod_stage_gui',H,O,D},Next,St = #est{bs = Bs}) ->
    [Handle,Opening,Desired] = erlog_int:dderef([H,O,D],Bs),
    Action = {gui_prepare_question,Opening},
    case {quod_erlog_db_local_prove:action_request(St,Handle,Action),Desired} of
        {{ok,Opening},{gui_prepared,Opening}} ->
            {_,_,Deadline,Auth} = request_context(St),
            case quod_gui_presentation:prepare(Opening,Auth,Deadline) of
                {ok,Prepared} ->
                    {ok,#{agent_ref_blob := Agent}} = quod_client_goal:request_identity(element(3,Auth)),
                    case quod_proof_session:signer_from_state(St) of
                        #{pubkey := Executor} ->
                            {gui_opening,{ontology_ref,Ns,Anchor},_,_,_,_,_,_,_,_} = Opening,
                            {ok,ActionBytes} = quod_durable_term:encode_goal(Action),
                            {ok,Bytes} = quod_gui_presentation:prepared_bytes(Prepared),
                            {ok,Effect} = quod_effect:new(present,Executor,{agent,Agent},{Ns,Anchor},
                                crypto:hash(sha256,ActionBytes),crypto:hash(sha256,Bytes)),
                            St1 = quod_erlog_db_local_prove:put_prepared_effect(St,Action,Desired,Effect,Prepared),
                            erlog_int:prove_body(Next,St1);
                        none -> quod_predicates:fail_reason(gui_executor_unavailable,St)
                    end;
                {fail,Reasons} -> quod_predicates:fail_reason({gui_open_failed,Reasons},St);
                {error,Reason} -> erlog_int:erlog_error({gui_preparation_unavailable,Reason},St)
            end;
        _ -> erlog_int:domain_error(gui_request_handle,Handle,St)
    end.

prepared({'$quod_gui_prepared',Opening0},Next,St = #est{bs = Bs}) ->
    Opening = erlog_int:dderef(Opening0,Bs),
    ground(Opening,St),
    case quod_erlog_db_local_prove:staged_desired_state(St,{gui_prepared,Opening}) of
        true -> erlog_int:prove_body(Next,St);
        false -> erlog_int:fail(St)
    end.
