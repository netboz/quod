-module(quod_agent).
-moduledoc """
One disposable hosted incarnation, owned by its ontology's runtime.

The bounded live request queue contains no durable message custody or Prolog
state. Runtime releases requests only after its installed projection frontier.
Actor requests use governed signing and signed-goal ingress. Runtime resource
restoration does not enter an actor queue or borrow an actor identity.
There is no automatic resubmission; domain recovery belongs to ontology rules.
""".
-behaviour(gen_server).

-export([start/3, valid_preparation_goal/2, valid_signed_preparation/3,
         retained_request/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(s, {owner, owner_monitor, slot, binding, released = 0,
            pending = {[], []}, worker = none}).

-spec start(pid(), node | {agent, term()}, map()) -> {ok, pid()} | {error, term()}.
start(Owner, Slot, Binding) -> gen_server:start(?MODULE, {Owner, Slot, Binding}, []).

init({Owner, Slot, Binding}) ->
    process_flag(trap_exit, true),
    {ok, #s{owner = Owner, owner_monitor = monitor(process, Owner), slot = Slot, binding = Binding}}.

handle_call(_Request, _From, S) -> {reply, {error, unsupported}, S}.
handle_cast(_Message, S) -> {noreply, S}.

handle_info({agent_stop, Owner}, S = #s{owner = Owner}) ->
    {stop, shutdown, S};
handle_info({agent_request, Owner, Ref, Height, Request, QueuedAt}, S = #s{owner = Owner}) ->
    {noreply, pump(S#s{pending = queue:in({Ref, Height, Request, QueuedAt}, S#s.pending)})};
handle_info({agent_release, Owner, Height}, S = #s{owner = Owner}) ->
    {noreply, pump(S#s{released = max(Height, S#s.released)})};
handle_info({agent_result, Worker, Ref, Result},
            S = #s{worker = #{pid := Worker, ref := Ref, expired := false} = Job}) ->
    _ = erlang:cancel_timer(maps:get(timer, Job)),
    demonitor(maps:get(monitor, Job), [flush]),
    {noreply, pump(complete(Ref, Result, maps:get(report_binding, Job), S#s{worker = none}))};
handle_info({timeout, Timer, {agent_deadline, Ref}},
            S = #s{worker = #{pid := Worker, timer := Timer, ref := Ref} = Job}) ->
    exit(Worker, kill),
    {noreply, S#s{worker = Job#{expired => true}}};
handle_info({'DOWN', Monitor, process, Owner, _},
            S = #s{owner = Owner, owner_monitor = Monitor}) ->
    {stop, shutdown, S};
handle_info({'DOWN', Monitor, process, _, _},
            S = #s{worker = #{report_binding := #{reply_to := {_, Monitor}}, pid := Worker} = Job}) ->
    exit(Worker, kill),
    {noreply, S#s{worker = Job#{expired => true}}};
handle_info({'DOWN', Monitor, process, Worker, Reason},
            S = #s{worker = #{pid := Worker, monitor := Monitor, ref := Ref,
                              timer := Timer, expired := Expired, timeout_result := Result,
                              report_binding := ReportBinding}}) ->
    _ = erlang:cancel_timer(Timer),
    case Expired of
        true -> {noreply, pump(complete(Ref, Result, ReportBinding, S#s{worker = none}))};
        false -> {stop, {request_worker_down, Reason}, S#s{worker = none}}
    end;
handle_info(_Message, S) -> {noreply, S}.

terminate(_Reason, #s{worker = none}) -> ok;
terminate(_Reason, #s{worker = #{pid := Worker, monitor := Monitor, timer := Timer}}) ->
    _ = erlang:cancel_timer(Timer),
    exit(Worker, kill),
    receive {'DOWN', Monitor, process, Worker, _} -> ok end.

pump(S = #s{worker = none, pending = Pending, released = Released}) ->
    case take_ready(queue:to_list(Pending), Released, []) of
        {{Ref, _Height, Request, QueuedAt}, Rest} ->
            {Mode, _, _, Deadline} = Request,
            Ready = S#s{pending = queue:from_list(Rest)},
            CallerAlive = case Mode of
                {instruction, Caller, _, _, _, _} -> is_process_alive(Caller);
                _ -> true
            end,
            case CallerAlive andalso Deadline > quod_time:mono_ms() of
                false -> pump(complete(Ref, unsent_expiry(Mode),
                                       report_binding(Mode, S#s.binding), Ready));
                true -> start_request(Ref, Request, Deadline, QueuedAt, Ready)
            end;
        none -> S
    end;
pump(S) -> S.

unsent_expiry({custodied, _, _, _, _}) -> {error, {request_not_submitted, deadline_exceeded}};
unsent_expiry(_) -> {error, deadline_exceeded}.

take_ready([], _, _) -> none;
take_ready([Item = {_, Height, _, _} | Rest], Released, Before)
  when Height =< Released ->
    {Item, lists:reverse(Before, Rest)};
take_ready([Item | Rest], Released, Before) ->
    take_ready(Rest, Released, [Item | Before]).

complete(Ref, Result, Binding, S = #s{owner = Owner, slot = Slot}) ->
    case maps:get(reply_to, Binding, none) of
        {Caller, Monitor} ->
            demonitor(Monitor, [flush]),
            Caller ! {agent_instruction_result, Ref, Result};
        none -> ok
    end,
    Owner ! {agent_completed, Slot, self(), Ref},
    Owner ! {agent_owned_result, Slot, self(), Ref, Result},
    quod_reg:publish({agent, maps:get(reference, Binding)},
      {agent_request_finished, Owner, self(), Binding, Ref, Result}),
    S.

start_request(Ref, {Mode, Goal, Expires, _Deadline}, Deadline, QueuedAt,
              S = #s{slot = Slot, binding = Binding}) ->
    Parent = self(),
    Operation = case Mode of
        {retained, Bytes} ->
            {ok, #{request := #{operation_id := Id}}} = quod_client_goal:request_identity(Bytes), Id;
        {instruction, _, _, _, Bytes, _} ->
            {ok, #{request := #{operation_id := Id}}} = quod_client_goal:request_identity(Bytes), Id;
        _ -> crypto:strong_rand_bytes(32)
    end,
    {Worker, Monitor} = spawn_opt(fun() ->
        %% Queue time includes projection release and earlier requests. A killed
        %% worker may never export this span; absence is not a completed request.
        Attributes = #{'quod.agent.executor_kind' =>
                           case Slot of node -> <<"node">>; {agent, _} -> <<"agent">> end,
                       'quod.agent.mode' => atom_to_binary(request_mode(Mode)),
                       'quod.agent.queue_us' => erlang:monotonic_time(microsecond) - QueuedAt},
        Result = quod_trace:with_span(otel_ctx:new(), <<"quod.agent.request">>, internal,
          Attributes, fun(Span) ->
              Reply = try
                          case prepare_goal(Slot, Binding, Mode, Goal, Deadline) of
                              {ok, Prepared} -> invoke_live(Slot, Binding, {Mode, Prepared, Expires}, Operation);
                              {error, _} = Error -> Error
                          end
                      catch _:_ -> {error, agent_request_failed}
                      end,
              trace_result(Span, Reply),
              Reply
          end),
        Parent ! {agent_result, self(), Ref, Result}
    end, [link, monitor]),
    Timer = erlang:start_timer(Deadline, self(), {agent_deadline, Ref}, [{abs, true}]),
    ReportBinding = report_binding(Mode, Binding),
    {agent_instance_ref, Ns, Anchor, _} = AgentRef = maps:get(reference, ReportBinding),
    {ok, Blob} = quod_wire_term:encode_canonical(AgentRef),
    OperationRef = quod_client_goal:operation_ref(Ns, Anchor, Blob, Operation),
    TimeoutResult = case request_mode(Mode) of
        read -> {error, deadline_exceeded};
        execute -> {error, {outcome_unknown, OperationRef}}
    end,
    S#s{worker = #{pid => Worker, monitor => Monitor, ref => Ref, timer => Timer,
                   expired => false, timeout_result => TimeoutResult,
                   report_binding => ReportBinding}}.

request_mode({custodied, _, _, _, _}) -> execute;
request_mode({instruction, _, _, _, _, _}) -> execute;
request_mode({retained, _}) -> execute;
request_mode(resolve) -> read;
request_mode({node, _, Mode}) -> Mode;
request_mode(Mode) -> Mode.

report_binding({node, NodeRef, _}, Binding) -> Binding#{reference => NodeRef};
report_binding({instruction, Caller, _, _, _, _}, Binding) ->
    Binding#{reply_to => {Caller, monitor(process, Caller)}};
report_binding(_, Binding) -> Binding.

%% The result variable belongs to this one queued continuation. Binding it
%% uses Erlog's term machinery without retaining a proof or another executor.
prepare_goal(node, #{public_key := Key}, {node, NodeRef, execute},
             {custody, {agent_instance_ref, Ns, _, _} = AgentRef,
              Epoch, {_} = Variable, Template}, Deadline) ->
    case valid_preparation_goal(Variable, Template) of
        false -> {error, invalid_preparation_request};
        true -> prepare_goal_result(Ns, AgentRef, Epoch, NodeRef, Key, Variable, Template, Deadline)
    end;
prepare_goal(_, _, _, {custody, _, _, {_}, _}, _) -> {error, invalid_preparation_request};
prepare_goal(_, _, _, Goal, _) -> {ok, Goal}.

valid_preparation_goal({Name}, Template) ->
    {_Canonical, Variables, _Next} = erlog_int:term_instance(Template, 0),
    case Variables of [{Name, _}] -> true; _ -> false end;
valid_preparation_goal(_, _) -> false.

valid_signed_preparation({B}, {S}, Template) when B =/= S ->
    {_Canonical, Variables, _} = erlog_int:term_instance(Template, 0),
    lists:sort([Name || {Name,_} <- Variables]) =:= lists:sort([B,S]);
valid_signed_preparation(_,_,_) -> false.

%% Pure selection only. The selected authored goal must be exactly the goal in
%% the retained bytes; signature release and ingress still perform authorization.
retained_request(Actor, Bytes, Goal) ->
    case {quod_client_goal:request_identity(Bytes),
          quod_wire_term:encode_canonical(Actor), quod_durable_term:encode_goal(Goal)} of
        {{ok, #{agent_ref_blob := Blob,
                request := #{mode := execute, goal_text := Text,
                             parser_version := Parser} = Request}},
         {ok, Blob}, {ok, GoalBlob}} ->
            case quod_client_goal_parser:parse(Text, Parser) of
                {ok, #{goal := Parsed, variables := []}} ->
                    case quod_durable_term:encode_goal(Parsed) of
                        {ok, GoalBlob} -> {ok, Request};
                        _ -> error
                    end;
                _ -> error
            end;
        _ -> error
    end.


prepare_goal_result(Ns, AgentRef, Epoch, NodeRef, Key, Variable, Template, Deadline) ->
    Prepared = prepare_custody(Ns, AgentRef, Epoch, NodeRef, Key, Deadline),
    Result = case Prepared of
                 {ok, PreparedKey} -> {prepared, PreparedKey};
                 {error, Reason} when is_atom(Reason) -> {unavailable, Reason};
                 {error, _} -> {unavailable, vault_storage_unavailable}
             end,
    Bound = erlog_int:add_binding(Variable, Result, erlog_int:new_bindings()),
    Goal = erlog_int:dderef(Template, Bound),
    case {Deadline > quod_time:mono_ms(), quod_wire_term:is_ground(Goal)} of
        {true, true} -> {ok, Goal};
        {false, _} -> {error, deadline_exceeded};
        _ -> {error, invalid_preparation_request}
    end.

prepare_custody(Ns, {agent_instance_ref, Ns, _, _} = AgentRef,
                Epoch, NodeRef, Key, Deadline) ->
    case current_node(NodeRef, Key) of
        true ->
            case quod_runtime:reconcile_resource(
                   Ns, 0, agent_custody, {AgentRef, Epoch, NodeRef}, Deadline) of
                ok ->
                    case current_node(NodeRef, Key) andalso Deadline > quod_time:mono_ms() of
                        true ->
                            {ok, Blob} = quod_wire_term:encode_canonical(AgentRef),
                            trace_stage(<<"quod.agent.custody_prepare">>,
                              fun() -> quod_agent_vault:prepare(Blob, Epoch, Deadline) end);
                        false -> {error, stale_node_executor}
                    end;
                _ -> {error, preparation_not_authorized}
            end;
        false -> {error, stale_node_executor}
    end.

current_node(NodeRef, Key) ->
    quod_node_actor:reference() =:= {ok, NodeRef} andalso
    application:get_env(quod, node_pubkey) =:= {ok, Key}.

invoke_live(_Slot, _Binding, {resolve, {Bytes, Signature}, _Expires}, _Operation) ->
    quod_client_goal_ingress:resolve_operation(Bytes, Signature);
invoke_live(Slot, Binding, {{instruction, _, UBytes, USig, Bytes, Signature}, _, Expires}, Operation) ->
    Store = {retain_personal_instruction, UBytes, USig, {'Signature'}},
    Result = establish_custody(Slot, Binding, none, {'Bytes'}, {'Signature'}, Store,
                               {exact_request, Bytes, Signature}, Expires, Operation),
    instruction_result(Result, Binding, Bytes, Expires);
invoke_live(Slot, Binding, {{custodied, Retention, BytesVar, SignatureVar, Template}, Goal, Expires}, Operation) ->
    case custody_scope(Retention) of
        none -> establish_custody(Slot, Binding, none, BytesVar, SignatureVar, Template, Goal, Expires, Operation);
        {ok, Scope, Fence} ->
            case quod_agent_vault:retained(Scope) of
                none -> establish_custody(Slot, Binding, {Scope,Fence}, BytesVar, SignatureVar,
                                          Template, Goal, Expires, Operation);
                {ok, Receipt} -> resolve_custody(Slot, Binding, Scope, Receipt, Expires);
                Error -> {error, {request_not_submitted, Error}}
            end;
        Error -> {error, {request_not_submitted, Error}}
    end;
invoke_live(Slot, Binding, Request, Operation) ->
    case trace_stage(<<"quod.agent.governed_sign">>,
                      fun() -> sign_request(Slot, Binding, Request, Operation) end) of
        {ok, Bytes, Signature} ->
            trace_stage(<<"quod.agent.submit">>,
                        fun() -> quod_client_goal_ingress:submit(Bytes, Signature) end);
        {error, _} = Error -> Error
    end.

%% A refusal describes this attempt only. Before declaring the original
%% operation unsent, consult its existing committed association under node ACL.
instruction_result({error, {request_not_submitted, _}} = Refused,
                   #{reference := {agent_instance_ref, Ns, Anchor, _}}, Bytes, Expires) ->
    Goal = {'::', Ns, {',', {current_ontology_identity, Ns, Anchor},
                      {personal_instruction_retained, Bytes, false}}},
    case quod_node_actor:signed_goal(read, Goal, crypto:strong_rand_bytes(32), Expires) of
        {ok, B, S} ->
            case quod_client_goal_ingress:submit(B, S) of
                {ok, _, {normalized, {read, _, {answers, _, [_]}}}} ->
                    {error, {instruction_not_submitted, instruction_refused}};
                _ -> Refused
            end;
        _ -> Refused
    end;
instruction_result(Result, _, _, _) -> Result.

custody_scope(none) -> none;
custody_scope({Scope, Fence}) ->
    case {quod_ontology:network_identity(), quod_wire_term:encode_canonical(Scope)} of
        {{ok, Network}, {ok, Bytes}} -> {ok, {Network, Bytes}, Fence};
        _ -> {error, invalid_custody_scope}
    end.

establish_custody(Slot, Binding, Retention, BVar, SVar, Template, Goal, Expires, Operation) ->
    case sign_request(Slot, Binding, {execute, Goal, Expires}, Operation) of
        {ok, Bytes, Signature} ->
            Bs0 = erlog_int:add_binding(BVar, Bytes, erlog_int:new_bindings()),
            Bs = erlog_int:add_binding(SVar, Signature, Bs0),
            Store = erlog_int:dderef(Template, Bs),
            case sign_request(Slot, Binding, {execute, Store, Expires}, crypto:strong_rand_bytes(32)) of
                {ok, CBytes, CSig} ->
                    submit_custody(Slot, Binding, Retention, Bs,
                                   {CBytes,CSig}, {Bytes,Signature}, Expires);
                Error -> {error, {request_not_submitted, Error}}
            end;
        Error -> {error, {request_not_submitted, Error}}
    end.

submit_custody(_Slot, _Binding, none, _Bs, Store, Request, _Expires) ->
    finish_custody(none, none, submit_signed(Store), Request);
submit_custody(Slot, Binding, {Scope,Fence}, Bs, Store, Request, Expires) ->
    {ok, FenceBytes} = quod_durable_term:encode_goal(erlog_int:dderef(Fence, Bs)),
    {ok, AgentBytes} = quod_wire_term:encode_canonical(maps:get(reference, Binding)),
    Receipt = #{store => Store, request => Request, fence => FenceBytes,
                binding => (maps:with([epoch,public_key], Binding))#{reference => AgentBytes}},
    Deadline = quod_time:mono_ms() + max(0, Expires - quod_time:now_ms()),
    case quod_agent_vault:retain(Scope, Receipt, Deadline) of
        {ok, retained} -> finish_custody(Scope, Receipt, submit_signed(Store), Request);
        {ok, {existing, Existing}} -> resolve_custody(Slot, Binding, Scope, Existing, Expires);
        Error -> {error, {request_not_submitted, Error}}
    end.

submit_signed({Bytes,Signature}) -> quod_client_goal_ingress:submit(Bytes,Signature).

finish_custody(Scope, Receipt, {ok, _, {normalized, {committed, _, _}}}, Request) ->
    case retire_custody(Scope, Receipt) of
        ok -> submit_signed(Request);
        Error -> {error, {custody_unresolved, Error}}
    end;
finish_custody(Scope, Receipt, {ok, _, {normalized, {failed, _}}} = Failed, _) ->
    _ = retire_custody(Scope, Receipt),
    {error, {request_not_submitted, Failed}};
finish_custody(_, _, Other, _) -> {error, {custody_unresolved, Other}}.

retire_custody(none, none) -> ok;
retire_custody(Scope, Receipt) -> quod_agent_vault:retire(Scope, Receipt).

%% A recovered receipt can only be resolved or fenced, never submitted again.
resolve_custody(Slot, Binding, Scope, Receipt = #{store := {Bytes,Signature}, fence := FenceBytes}, Expires) ->
    Result = quod_client_goal_ingress:resolve_operation(Bytes,Signature),
    Terminal = case Result of
        {ok, _, {operation_outcome, _, #{status := Status}}}
          when Status =:= committed; Status =:= rejected; Status =:= aborted -> true;
        _ -> false
    end,
    Fenced = case Terminal of
        true -> true;
        false ->
            {ok, Fence} = quod_durable_term:decode_goal(FenceBytes),
            case invoke_live(Slot, Binding, {read, Fence, Expires}, crypto:strong_rand_bytes(32)) of
                {ok, _, {normalized, {read, _, {answers, _, [_|_]}}}} -> true;
                _ -> false
            end
    end,
    case Fenced of
        true ->
            case retire_custody(Scope, Receipt) of
                ok -> {error, custody_retired};
                Error -> {error, {custody_unresolved, Error}}
            end;
        false -> {error, {custody_unresolved, Result}}
    end.

sign_request(node, #{reference := NodeRef, public_key := Key},
             {{node, NodeRef, Mode}, Goal, Expires}, Operation) ->
    %% The goal was chosen in the node's own behavior scope. Its handler uses
    %% node_authorized_goal/3 for permitted foreign work within the same proof.
    quod_node_actor:signed_goal(Mode, Goal, Operation, Expires, {NodeRef, Key});
sign_request({agent, _}, #{reference := Agent, public_key := Key},
             {execute, {exact_request, Bytes, Signature}, _Expires}, _Operation) ->
    case quod_client_goal:verify(Bytes, Signature) of
        {ok, #{request := #{signing_public_key := Key}, agent_ref_blob := Blob}} ->
            case quod_wire_term:encode_canonical(Agent) of
                {ok, Blob} -> {ok, Bytes, Signature};
                _ -> {error, retained_request_mismatch}
            end;
        _ -> {error, retained_request_mismatch}
    end;
sign_request({agent, _}, #{reference := Agent, public_key := Key} = Binding,
             {{retained, Bytes}, Goal, Expires}, _Operation) ->
    case retained_request(Agent, Bytes, Goal) of
        {ok, #{signing_public_key := Key} = Request} ->
            sign_agent_request(Binding, Request, Expires);
        _ -> {error, retained_request_mismatch}
    end;
sign_request({agent, _}, #{reference := {agent_instance_ref, Ns, Anchor, Instance},
         public_key := Key} = Binding, {Mode, Goal, Expires}, Operation) ->
    {ok, Network} = quod_ontology:network_identity(),
    {ok, InstanceText} = quod_client_goal_parser:format(Instance),
    {CanonicalGoal, _Variables, _NextVn} = erlog_int:term_instance(Goal, 0),
    {ok, GoalText} = quod_client_goal_parser:format_clause(CanonicalGoal),
    Request = #{network_identity => Network, agent_namespace => Ns,
      agent_genesis_anchor => Anchor, agent_instance_text => InstanceText,
      signing_public_key => Key, operation_id => Operation,
      not_after_ms => Expires, mode => Mode, parser_version => 3, goal_text => GoalText},
    sign_agent_request(Binding, Request, Expires).

sign_agent_request(#{reference := {agent_instance_ref, Ns, _, Instance} = Agent,
                     epoch := Epoch, public_key := Key},
                   #{network_identity := Network, agent_instance_text := InstanceText,
                     operation_id := Operation, not_after_ms := RequestExpiry,
                     mode := Mode, parser_version := Parser, goal_text := GoalText} = Request,
                   Expires) ->
    Typed = {agent_goal_v1, Network, Agent, InstanceText, Key,
             Operation, RequestExpiry, Mode, Parser, GoalText},
    {ok, NodePrincipal} = quod_node_actor:principal(),
    {ok, NodeRef} =
        quod_agent_ref:materialize_principal(NodePrincipal),
    SignGoal =
      {'::', Ns, {',', {agent_hosted, Instance, NodeRef, Epoch, Key},
                       {sign_agent_request, Typed, {0}}}},
    {ok, SignBytes, SignSignature} = quod_node_actor:signed_goal(
      read, SignGoal, crypto:strong_rand_bytes(32), Expires),
    case quod_client_goal_ingress:submit(SignBytes, SignSignature) of
        {ok, _, {normalized, {read, _Dependencies, {answers, _Height, [Answer]}}}} ->
            {ok, [{<<"V0">>, Signature}]} = quod_client_result:decode_binding(Answer),
            {ok, Bytes} = quod_client_goal:encode(Request),
            {ok, Bytes, Signature};
        {ok, _, {normalized, {read, _, {failed, _}}}} -> {error, signing_not_authorized};
        {error, _} = Error -> Error;
        _ -> {error, signing_unavailable}
    end.

trace_stage(Name, Fun) ->
    quod_trace:with_span(quod_trace:context(), Name, internal, #{}, fun(Span) ->
        Result = Fun(),
        trace_result(Span, Result),
        Result
    end).

trace_result(Span, Result) ->
    %% A successful transport return can still be uncertain. Never attach the
    %% returned evidence, key, payload, or an arbitrary error reason.
    _ = catch quod_trace:set_attributes(Span, #{'quod.agent.result' => result_class(Result)}),
    ok.

result_class({ok, Evidence, {normalized, {read, _, Outcome}}}) ->
    result_class({ok, Evidence, {normalized, Outcome}});
result_class({ok, _, {normalized, {committed, _, _}}}) -> <<"committed">>;
result_class({ok, _, {normalized, {pending, _}}}) -> <<"pending">>;
result_class({ok, _, {normalized, {answers, _, _}}}) -> <<"answers">>;
result_class({ok, _, {normalized, {failed, _}}}) -> <<"failed">>;
result_class({ok, _, {normalized, fail}}) -> <<"failed">>;
result_class({ok, _, {normalized, {error, _}}}) -> <<"other_error">>;
result_class({ok, _, {normalized, _}}) -> <<"other">>;
result_class({error, {outcome_unknown, _}}) -> <<"outcome_unknown">>;
result_class({error, deadline_exceeded}) -> <<"deadline_exceeded">>;
result_class({error, signing_not_authorized}) -> <<"refused">>;
result_class({error, _}) -> <<"other_error">>;
result_class({ok, _}) -> <<"ok">>;
result_class({ok, _, _}) -> <<"ok">>;
result_class(_) -> <<"other">>.
