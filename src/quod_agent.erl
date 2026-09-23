-module(quod_agent).
-moduledoc """
One disposable hosted incarnation, owned by its ontology's runtime.

The bounded live request queue contains no durable message custody or Prolog
state. Runtime releases requests only after its installed projection frontier.
Each request uses the shared governed signing and signed-goal ingress paths.
There is no automatic resubmission; domain recovery belongs to ontology rules.
""".
-behaviour(gen_server).

-export([start/3]).
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
    {noreply, pump(complete(Ref, Result, S#s{worker = none}))};
handle_info({timeout, Timer, {agent_deadline, Ref}},
            S = #s{worker = #{pid := Worker, timer := Timer, ref := Ref} = Job}) ->
    exit(Worker, kill),
    {noreply, S#s{worker = Job#{expired => true}}};
handle_info({'DOWN', Monitor, process, Owner, _},
            S = #s{owner = Owner, owner_monitor = Monitor}) ->
    {stop, shutdown, S};
handle_info({'DOWN', Monitor, process, Worker, Reason},
            S = #s{worker = #{pid := Worker, monitor := Monitor, ref := Ref,
                              timer := Timer, expired := Expired, timeout_result := Result}}) ->
    _ = erlang:cancel_timer(Timer),
    case Expired of
        true -> {noreply, pump(complete(Ref, Result, S#s{worker = none}))};
        false -> {stop, {request_worker_down, Reason}, S#s{worker = none}}
    end;
handle_info(_Message, S) -> {noreply, S}.

terminate(_Reason, #s{worker = none}) -> ok;
terminate(_Reason, #s{worker = #{pid := Worker, monitor := Monitor, timer := Timer}}) ->
    _ = erlang:cancel_timer(Timer),
    exit(Worker, kill),
    receive {'DOWN', Monitor, process, Worker, _} -> ok end.

pump(S = #s{worker = none, pending = Pending, released = Released}) ->
    case queue:out(Pending) of
        {{value, {Ref, Height, Request, QueuedAt}}, Rest} when Height =< Released ->
            {_, _, _, Deadline} = Request,
            case Deadline > quod_time:mono_ms() of
                false -> pump(complete(Ref, {error, deadline_exceeded}, S#s{pending = Rest}));
                true -> start_request(Ref, Request, Deadline, QueuedAt, S#s{pending = Rest})
            end;
        _ -> S
    end;
pump(S) -> S.

complete(Ref, Result, S = #s{owner = Owner, slot = Slot, binding = Binding}) ->
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
                       'quod.agent.mode' => atom_to_binary(Mode),
                       'quod.agent.queue_us' => erlang:monotonic_time(microsecond) - QueuedAt},
        Result = quod_trace:with_span(otel_ctx:new(), <<"quod.agent.request">>, internal,
          Attributes, fun(Span) ->
              Reply = try
                          case prepare_goal(Slot, Binding, Goal, Deadline) of
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
    {agent_instance_ref, Ns, Anchor, _} = AgentRef = maps:get(reference, Binding),
    {ok, Blob} = quod_wire_term:encode_canonical(AgentRef),
    OperationRef = quod_client_goal:operation_ref(Ns, Anchor, Blob, Operation),
    TimeoutResult = case Mode of
        read -> {error, deadline_exceeded};
        execute -> {error, {outcome_unknown, OperationRef}}
    end,
    S#s{worker = #{pid => Worker, monitor => Monitor, ref => Ref, timer => Timer,
                   expired => false, timeout_result => TimeoutResult}}.

%% The result variable belongs to this one queued continuation. Binding it
%% uses Erlog's term machinery without retaining a proof or another executor.
prepare_goal(node, #{source := {Ns, Anchor}},
             {custody, {agent_instance_ref, Ns, Anchor, _} = AgentRef,
              Epoch, {_} = Variable, Template}, Deadline) ->
    {ok, Blob} = quod_wire_term:encode_canonical(AgentRef),
    Prepared = trace_stage(<<"quod.agent.custody_prepare">>,
                           fun() -> quod_agent_vault:prepare(Blob, Epoch, Deadline) end),
    Result = case Prepared of
                 {ok, Key} -> {prepared, Key};
                 {error, Reason} when is_atom(Reason) -> {unavailable, Reason};
                 {error, _} -> {unavailable, vault_storage_unavailable}
             end,
    Bound = erlog_int:add_binding(Variable, Result, erlog_int:new_bindings()),
    Goal = erlog_int:dderef(Template, Bound),
    case {Deadline > quod_time:mono_ms(), quod_wire_term:is_ground(Goal)} of
        {true, true} -> {ok, Goal};
        {false, _} -> {error, deadline_exceeded};
        _ -> {error, invalid_preparation_request}
    end;
prepare_goal(_, _, {custody, _, _, {_}, _}, _) -> {error, invalid_preparation_request};
prepare_goal(_, _, Goal, _) -> {ok, Goal}.

invoke_live(Slot, Binding, Request, Operation) ->
    case trace_stage(<<"quod.agent.governed_sign">>,
                      fun() -> sign_request(Slot, Binding, Request, Operation) end) of
        {ok, Bytes, Signature} ->
            trace_stage(<<"quod.agent.submit">>,
                        fun() -> quod_client_goal_ingress:submit(Bytes, Signature) end);
        {error, _} = Error -> Error
    end.

sign_request(node, #{reference := NodeRef, public_key := Key,
                    source := {SourceNs, SourceAnchor}}, {Mode, Goal, Expires}, Operation) ->
    %% Node execution is an explicit credential kind. Its delegation grant is
    %% proved in the node's own ontology inside the very transaction that
    %% executes the goal, not as a preceding permission read.
    Wrapped = {node_authorized_goal, SourceNs, SourceAnchor, Goal},
    quod_node_actor:signed_goal(Mode, Wrapped, Operation, Expires, {NodeRef, Key});
sign_request({agent, _}, #{reference := {agent_instance_ref, Ns, Anchor, Instance} = Agent,
         epoch := Epoch, public_key := Key}, {Mode, Goal, Expires}, Operation) ->
    {ok, Network} = quod_ontology:network_identity(),
    {ok, InstanceText} = quod_client_goal_parser:format(Instance),
    {ok, GoalText} = quod_client_goal_parser:format(Goal),
    Request = #{network_identity => Network, agent_namespace => Ns,
      agent_genesis_anchor => Anchor, agent_instance_text => InstanceText,
      signing_public_key => Key, operation_id => Operation,
      not_after_ms => Expires, mode => Mode, parser_version => 2, goal_text => GoalText},
    Typed = {agent_goal_v1, Network, Agent, InstanceText, Key,
             maps:get(operation_id, Request), Expires, Mode, 2, GoalText},
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
            {ok, [{<<"V0">>, Signature}]} = quod_durable_term:decode_result(Answer),
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
