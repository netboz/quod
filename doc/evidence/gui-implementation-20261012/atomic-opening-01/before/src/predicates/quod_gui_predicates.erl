-module(quod_gui_predicates).
-moduledoc "Governed native presentation operations; policy and questions remain in Prolog.".
-include_lib("erlog/src/erlog_int.hrl").
-export([quod_predicate_module/0, load/1, receiver_prepare/3, receiver_activate/3]).

quod_predicate_module() -> true.
load(St) ->
    lists:foldl(fun({Name,Arity,Function},Acc) ->
        quod_predicates:register(Acc,{Name,Arity},query,?MODULE,Function)
    end,St,[{'$quod_gui_receiver_prepare',6,receiver_prepare},
            {'$quod_gui_receiver_activate',4,receiver_activate}]).

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
                    {Digest,Expiry,quod_time:mono_ms()+Remaining};
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
