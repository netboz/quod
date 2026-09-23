-module(quod_agent).
-moduledoc """
One disposable hosted incarnation, owned by its ontology's runtime.

The bounded live request queue contains no durable message custody or Prolog
state. Runtime releases requests only after its installed projection frontier.
Each request uses the shared governed signing and signed-goal ingress paths.
There is no automatic resubmission; domain recovery belongs to ontology rules.
""".
-behaviour(gen_server).

-export([start/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(s, {owner, owner_monitor, binding, released = 0,
            pending = {[], []}, worker = none}).

-spec start(pid(), map()) -> {ok, pid()} | {error, term()}.
start(Owner, Binding) -> gen_server:start(?MODULE, {Owner, Binding}, []).

init({Owner, Binding}) ->
    process_flag(trap_exit, true),
    {ok, #s{owner = Owner, owner_monitor = monitor(process, Owner), binding = Binding}}.

handle_call(_Request, _From, S) -> {reply, {error, unsupported}, S}.
handle_cast(_Message, S) -> {noreply, S}.

handle_info({agent_stop, Owner}, S = #s{owner = Owner}) ->
    {stop, shutdown, S};
handle_info({agent_request, Owner, Ref, Height, Request}, S = #s{owner = Owner}) ->
    {noreply, pump(S#s{pending = queue:in({Ref, Height, Request}, S#s.pending)})};
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
        {{value, {Ref, Height, Request}}, Rest} when Height =< Released ->
            {_, _, _, Deadline} = Request,
            case Deadline > quod_time:mono_ms() of
                false -> pump(complete(Ref, {error, deadline_exceeded}, S#s{pending = Rest}));
                true -> start_request(Ref, Request, Deadline, S#s{pending = Rest})
            end;
        _ -> S
    end;
pump(S) -> S.

complete(Ref, Result, S = #s{owner = Owner, binding = Binding}) ->
    {agent_instance_ref, _, _, Instance} = maps:get(reference, Binding),
    Owner ! {agent_completed, Instance, self(), Ref},
    quod_reg:publish({agent, maps:get(reference, Binding)},
      {agent_request_finished, Owner, self(), Binding, Ref, Result}),
    S.

start_request(Ref, {Mode, Goal, Expires, _Deadline}, Deadline, S = #s{binding = Binding}) ->
    Parent = self(),
    Operation = crypto:strong_rand_bytes(32),
    {Worker, Monitor} = spawn_opt(fun() ->
        Result = try invoke_live(Binding, {Mode, Goal, Expires}, Operation)
                 catch _:_ -> {error, agent_request_failed}
                 end,
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

invoke_live(#{reference := {agent_instance_ref, Ns, Anchor, Instance} = Agent,
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
        {ok, _, {normalized, {answers, 1, [Answer]}}} ->
            {ok, [{<<"V0">>, Signature}]} = quod_durable_term:decode_result(Answer),
            {ok, Bytes} = quod_client_goal:encode(Request),
            quod_client_goal_ingress:submit(Bytes, Signature);
        {ok, _, {normalized, {failed, _}}} -> {error, signing_not_authorized};
        {error, _} = Error -> Error;
        _ -> {error, signing_unavailable}
    end.
