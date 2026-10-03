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

-export([start/3, valid_preparation_goal/2]).
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
            case Deadline > quod_time:mono_ms() of
                false -> pump(complete(Ref, {error, deadline_exceeded},
                                       report_binding(Mode, S#s.binding), Ready));
                true -> start_request(Ref, Request, Deadline, QueuedAt, Ready)
            end;
        none -> S
    end;
pump(S) -> S.

take_ready([], _, _) -> none;
take_ready([Item = {_, Height, _, _} | Rest], Released, Before)
  when Height =< Released ->
    {Item, lists:reverse(Before, Rest)};
take_ready([Item | Rest], Released, Before) ->
    take_ready(Rest, Released, [Item | Before]).

complete(Ref, Result, Binding, S = #s{owner = Owner, slot = Slot}) ->
    Owner ! {agent_completed, Slot, self(), Ref},
    quod_reg:publish({agent, maps:get(reference, Binding)},
      {agent_request_finished, Owner, self(), Binding, Ref, Result}),
    S.

start_request(Ref, {Mode, Goal, Expires, _Deadline}, Deadline, QueuedAt,
              S = #s{slot = Slot, binding = Binding}) ->
    Parent = self(),
    Operation = crypto:strong_rand_bytes(32),
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

request_mode({node, _, Mode}) -> Mode;
request_mode(Mode) -> Mode.

report_binding({node, NodeRef, _}, Binding) -> Binding#{reference => NodeRef};
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
    case {quod_node_actor:principal(), application:get_env(quod, node_pubkey)} of
        {{ok, Principal}, {ok, Key}} ->
            quod_agent_ref:materialize_principal(Principal) =:= {ok, NodeRef};
        _ -> false
    end.

invoke_live(Slot, Binding, Request, Operation) ->
    case trace_stage(<<"quod.agent.governed_sign">>,
                      fun() -> sign_request(Slot, Binding, Request, Operation) end) of
        {ok, Bytes, Signature} ->
            trace_stage(<<"quod.agent.submit">>,
                        fun() -> quod_client_goal_ingress:submit(Bytes, Signature) end);
        {error, _} = Error -> Error
    end.

sign_request(node, #{reference := NodeRef, public_key := Key},
             {{node, NodeRef, Mode}, Goal, Expires}, Operation) ->
    %% The goal was chosen in the node's own behavior scope. Its handler uses
    %% node_authorized_goal/3 for permitted foreign work within the same proof.
    quod_node_actor:signed_goal(Mode, Goal, Operation, Expires, {NodeRef, Key});
sign_request({agent, _}, #{reference := {agent_instance_ref, Ns, Anchor, Instance} = Agent,
         epoch := Epoch, public_key := Key}, {Mode, Goal, Expires}, Operation) ->
    {ok, Network} = quod_ontology:network_identity(),
    {ok, InstanceText} = quod_client_goal_parser:format(Instance),
    {CanonicalGoal, _Variables, _NextVn} = erlog_int:term_instance(Goal, 0),
    {ok, GoalText} = quod_client_goal_parser:format(CanonicalGoal),
    Request = #{network_identity => Network, agent_namespace => Ns,
      agent_genesis_anchor => Anchor, agent_instance_text => InstanceText,
      signing_public_key => Key, operation_id => Operation,
      not_after_ms => Expires, mode => Mode, parser_version => 3, goal_text => GoalText},
    Typed = {agent_goal_v1, Network, Agent, InstanceText, Key,
             maps:get(operation_id, Request), Expires, Mode, 3, GoalText},
    {ok, NodePrincipal} = quod_node_actor:principal(),
    {ok, NodeRef} =
        quod_agent_ref:materialize_principal(NodePrincipal),
    SignGoal =
      {'::', Ns, {',', {agent_hosted, Instance, NodeRef, Epoch, Key},
                       {sign_agent_request, Typed, {0}}}},
    {ok, SignBytes, SignSignature} = quod_node_actor:signed_goal(
      read, SignGoal, crypto:strong_rand_bytes(32), Expires),
    case quod_client_goal_ingress:submit(SignBytes, SignSignature) of
        {ok, _, {normalized, {answers, _Height, [Answer]}}} ->
            {ok, [{<<"V0">>, Signature}]} = quod_client_result:decode_binding(Answer),
            {ok, Bytes} = quod_client_goal:encode(Request),
            {ok, Bytes, Signature};
        {ok, _, {normalized, {failed, _}}} -> {error, signing_not_authorized};
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
