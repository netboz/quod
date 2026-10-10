-module(quod_physics).
-moduledoc """
One runtime-owned simulation incarnation. Only this process calls its native
resource. The runtime supplies committed selections; the hosted actor owns all
signed work. Frames stay here and are pulled through the runtime's current
fence, rather than flooding its event queue.
""".
-behaviour(gen_server).
-export([start/2, snapshot/2, body_state/4, motion_query/6, accepts/2, projection/2, fence/1,
         watch/2, unwatch/2, ack/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([input/7]).
-record(s, {owner, monitor, spec, token, native = none, phase = activating,
            pending = none, window = none, resolved = none, uncertain = none, timer = none, tick = 0,
            frame = none, revisions = #{}, controls = #{}, driving = #{}, observations = #{},
            installs = 0, steps = 0, queries = 0, viewer = none, agent_controls = [], inputs = #{},
            installed_guard = none, installed_geometry = none, moving = false}).

start(Owner, Spec) ->
    gen_server:start(quod_reg:via({physics_world, maps:get(world, Spec)}), ?MODULE, {Owner, Spec}, []).
snapshot(Pid, Fence) -> gen_server:call(Pid, {snapshot, Fence}).
body_state(Pid, Expected, Body, Timeout) -> gen_server:call(Pid, {body_state, Expected, Body}, Timeout).
motion_query(Pid, Expected, Body, Query, Limits, Timeout) ->
    gen_server:call(Pid,{motion_query,Expected,Body,Query,Limits},Timeout).
input(Pid,Expected,Control,Sequence,Input,Expiry,Deadline) ->
    case min(Deadline-quod_time:mono_ms(),Expiry-quod_time:now_ms()) of
        Remaining when Remaining > 0 ->
            gen_server:call(Pid,{physics_input,Expected,Control,Sequence,Input,Expiry,Deadline},Remaining);
        _ -> {error,expired}
    end.
watch(Pid, Expected) -> gen_server:call(Pid, {watch, Expected}).
unwatch(Pid, Ref) -> Pid ! {physics_unwatch, self(), Ref}, ok.
ack(Pid, Ref, Tick) -> Pid ! {physics_ack, self(), Ref, Tick}, ok.
accepts(#{fence := Fence, structure := S, tick := Tick},
        #{fence := Fence, structure := S, tick := Previous}) -> Tick > Previous;
accepts(_, _) -> false.

init({Owner, Spec = #{navigation_guard := {_,_}}}) ->
    process_flag(trap_exit, true),
    self() ! advance,
    S = #s{owner = Owner, monitor = monitor(process, Owner), spec = Spec,
           token = crypto:strong_rand_bytes(32)},
    case quod_physics_native:available() of
        true -> {ok, notify(activating, S)};
        false -> {ok, fail({native_unavailable, quod_physics_native:load_error()}, S)}
    end.

handle_call(Request,From,S) ->
    NeedsNavigation = case Request of
        {watch,_} -> true;
        {snapshot,_} -> true;
        {body_state,_,_} -> true;
        {motion_query,_,_,_,_} -> true;
        {physics_input,_,_,_,_,_,_} -> true;
        _ -> false
    end,
    case NeedsNavigation andalso not navigation_current(S) of
        true when element(1,Request) =:= physics_input -> {reply,{error,reinstalling},S};
        true -> {reply,{error,unavailable},S};
        false -> handle_current_call(Request,From,S)
    end.

handle_current_call({watch, Expected}, {Pid, _}, S = #s{phase = active, viewer = none, frame = Frame}) ->
    case current_projection(Frame, Expected) andalso current_control(Expected, S#s.spec) of
        true ->
            Ref = make_ref(), M = monitor(process, Pid),
            Registered = Expected#{registration => crypto:strong_rand_bytes(32)},
            {reply, {ok, Ref, view_frame(Frame#{inputs => input_feedback(S)},Registered,S)}, S#s{viewer = #{pid => Pid, ref => Ref,
                monitor => M, expected => Registered, tick => maps:get(tick, Frame), credit => false}}};
        false -> {reply, {error, unavailable}, S}
    end;
handle_current_call({watch, _}, _, S = #s{viewer = V}) when V =/= none ->
    {reply, {error, view_busy}, S};
handle_current_call({watch, _}, _, S = #s{phase = {failed, _}}) ->
    {reply, {error, simulation_failed}, S};
handle_current_call({body_state, Expected, {Id, Revision}}, _, S = #s{phase = active, frame = Frame}) ->
    Reply = case current_projection(Frame, Expected) of
        true -> case lists:keyfind(Id, 1, maps:get(poses, Frame)) of
            {Id, Revision, world, _, _, _} = Pose -> {ok, maps:get(tick, Frame), Pose};
            _ -> {error, unavailable}
        end;
        false -> {error, unavailable}
    end,
    {reply, Reply, S#s{queries = S#s.queries + 1}};
handle_current_call({motion_query, Expected, {Id,Revision}, Query, Limits}, _,
            S = #s{phase = active,frame = Frame,native = Native}) ->
    case current_projection(Frame,Expected) of
        false -> {reply,{error,unavailable},S};
        true ->
            Counted = S#s{queries = S#s.queries+1},
            case query_input(Query,Limits) of
                {ok,Q,L} ->
                    case native(fun() -> quod_physics_native:motion_query(Native,Id,Revision,Q,L) end) of
                        {ok,Answer} -> {reply,{ok,maps:get(tick,Frame),Answer},Counted};
                        {error,Reason} -> {reply,{error,unavailable},fail(Reason,Counted)}
                    end;
                error -> {reply,{ok,maps:get(tick,Frame),invalid},Counted}
            end
    end;
handle_current_call({snapshot, Expected}, _From, S = #s{phase = active, frame = Frame}) ->
    Reply = case {accepts(Frame, Expected), Frame, Expected} of
        {true, _, _} -> {ok, Frame, counters(S)};
        {false, #{fence := F, structure := Revision, tick := Tick},
                #{fence := F, structure := Revision, tick := Tick}} ->
            {ok, unchanged, counters(S)};
        _ -> {error, unavailable}
    end,
    {reply, Reply, S#s{queries = S#s.queries + 1}};
handle_current_call({physics_input,Expected,Control = {control,Principal,_,_},Sequence,Input,Expiry,Deadline},_,
            S = #s{phase = active,frame = Frame,inputs = Inputs}) ->
    Previous = maps:get(Principal,Inputs,#{sequence => -1}),
    Retained = maps:get(sequence,Previous),
    Checks = [
        {current_projection(Frame,Expected),{stale_projection,maps:get(structure,Frame)}},
        {current_control(Expected#{control => Control},S#s.spec) andalso
         installed_input(Control,Input,S#s.spec),control_not_installed},
        {current_registration(Control,Expected,S#s.viewer),stale_registration},
        {Sequence > Retained,{stale_sequence,Retained}},
        {not pending_discrete(Previous),discrete_pending},
        {Expiry > quod_time:now_ms() andalso Deadline > quod_time:mono_ms(),expired}],
    case lists:dropwhile(fun({Accepted,_}) -> Accepted end,Checks) of
        [] ->
            Row = #{control => Control,expected => Expected,sequence => Sequence,input => Input,expiry => Expiry,
                    vertical => maps:get(vertical,Previous,0.0),falling => maps:get(falling,Previous,true),
                    pending => true,result => queued},
            Updated = S#s{inputs = Inputs#{Principal => Row}},
            {reply,ok,schedule({true,[],[]},Updated)};
        [{false,Reason}|_] -> {reply,{error,Reason},S}
    end;
handle_current_call({physics_input,_,_,_,_,_,_},_,S) ->
    {reply,{error,physics_world_unavailable},S};
handle_current_call(status, _From, S) ->
    {reply, (counters(S))#{phase => S#s.phase, incarnation => S#s.token,navigation_ready => navigation_current(S),
        inputs => maps:map(fun(_,R) -> maps:with([sequence,result],R) end,S#s.inputs),
        observations => maps:map(fun(_,O) -> maps:get(state,O) end,S#s.observations)}, S};
handle_current_call(_, _, S) -> {reply, {error, unavailable}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info({physics_ack, Pid, Ref, Tick},
            S = #s{viewer = #{pid := Pid, ref := Ref, tick := Tick, credit := false} = V}) ->
    {noreply, deliver_frame(S#s{viewer = V#{credit => true}})};
handle_info({physics_unwatch, Pid, Ref}, S = #s{viewer = #{pid := Pid, ref := Ref}}) ->
    {noreply, clear_viewer(S)};
handle_info({'DOWN', M, process, _, _}, S = #s{viewer = #{monitor := M}}) ->
    {noreply, clear_viewer(S)};
handle_info({physics_invalidated,Owner,Notice},S = #s{owner = Owner,spec = Spec}) ->
    Owner ! {physics_invalidation_seen,self(),maps:get(world,Spec),Notice},
    _ = case S#s.viewer of #{pid := Pid,ref := Ref} -> Pid ! {physics_refresh,self(),Ref}; _ -> ok end,
    Stopped = maps:map(fun(_,Row) -> suspend_input(Row) end,S#s.inputs),
    _ = case S#s.timer of none -> ok; Timer -> erlang:cancel_timer(Timer) end,
    {noreply,clear_viewer(S#s{inputs = Stopped,timer = none})};
handle_info({physics_selected, Owner, Ref, Spec}, S = #s{owner = Owner, spec = Old}) ->
    Owner ! {physics_selection_applied, self(), maps:get(world, Spec), Ref},
    ChangedRun = S#s.phase =:= active andalso fence(Old) =/= fence(Spec),
    Cancelled = maps:get(custody, Old) =/= none andalso maps:get(custody, Spec) =:= none,
    ChangedFailed = case S#s.phase of
        {failed, _} -> maps:with([bodies, structure, limits], Old) =/= maps:with([bodies, structure, limits], Spec);
        _ -> false
    end,
    case same_run(Old, Spec) andalso not ChangedRun andalso not ChangedFailed andalso not Cancelled of
        true -> {noreply, advance(selection_observations(S#s{spec = Spec}))};
        false -> {stop, normal, S}
    end;
handle_info(advance, S = #s{phase = unresolved}) -> {noreply, S};
handle_info(advance, S) -> {noreply, advance(S)};
handle_info({physics_result, Owner, Ref, Result},
            S = #s{owner = Owner, pending = {Ref, Kind, Issued}}) ->
    Window = case Result of
        {error, busy} -> S#s.window;
        {error, stale_executor} -> S#s.window;
        _ -> none
    end,
    Ready = S#s{pending = none, window = Window},
    Changed = activation_state(S#s.spec) =/= Issued,
    %% Never attach an old resolve result to newer custody. A committed run
    %% selection can also arrive before its earlier pending resolve reply.
    Next = case Kind =:= resolve andalso Changed of
        true -> advance(Ready#s{phase = activating});
        false -> outcome(Kind, Result, Ready)
    end,
    Classified = case {Kind,Next#s.phase} of
        {activate,unresolved} -> Next#s{uncertain = Issued};
        _ -> Next
    end,
    Recovered = case {Changed, Classified#s.phase} of
        {true, unresolved} -> advance(Classified);
        {true, not_sent} -> advance(Next);
        {false, unresolved} when Kind =:= activate ->
            notify({unavailable,activation_custody_unresolved},Classified);
        _ -> Classified
    end,
    {noreply, Recovered};
handle_info({physics_outcome_changed, Owner, D, Key, Height}, S = #s{owner = Owner,spec = Spec}) ->
    Next = case {maps:get(D,maps:get(activities,Spec,#{}),none),maps:get(D,S#s.observations,none)} of
        {#{outcome_key := Key,request := R,custody := C},#{state := State} = O}
          when State =:= unresolved; State =:= resolving ->
            case Height > maps:get(outcome_height,O,0) of
                true when State =:= unresolved -> update_observation_height(D,Height,resolve_observation(D,R,C,S));
                true -> S#s{observations = (S#s.observations)#{D => O#{outcome_height => Height,outcome_changed => true}}};
                false -> S
            end;
        _ -> S
    end,
    {noreply,Next};
handle_info({physics_admitted, Owner, Ref}, S = #s{owner = Owner}) ->
    {noreply, update_observation(Ref,fun(O) -> O#{state => in_flight} end,S)};
handle_info({physics_result, Owner, Ref, Result}, S = #s{owner = Owner}) ->
    {noreply, observation_result(Ref,Result,S)};
handle_info({timeout, Timer, step}, S = #s{timer = Timer, phase = active}) ->
    {noreply, do_step(S#s{timer = none})};
handle_info({physics_stop, Owner}, S = #s{owner = Owner}) -> {stop, normal, S};
handle_info({'DOWN', M, process, Owner, _}, S = #s{monitor = M, owner = Owner}) -> {stop, normal, S};
handle_info(_, S) -> {noreply, S}.

same_run(A, B) -> maps:with([world, authority, epoch, key], A) =:= maps:with([world, authority, epoch, key], B).
counters(S) -> #{installs => S#s.installs, steps => S#s.steps, queries => S#s.queries, tick => S#s.tick}.
activation_state(Spec) -> maps:with([generation, run_token, custody], Spec).

advance(S) ->
    case navigation_current(S) of true -> advance_current(S); false -> S end.

advance_current(S = #s{phase = {failed, _}}) -> S;
advance_current(S = #s{pending = P}) when P =/= none -> S;
advance_current(S = #s{phase = active, spec = Spec}) -> resume_observations(install(Spec, S));
%% An uncertain custody write must not be replaced by a newly signed request
%% merely because its selection has not arrived. No timeout implies rejection.
advance_current(S = #s{uncertain = Issued, spec = Spec}) when Issued =/= none ->
    case activation_state(Spec) =:= Issued of
        true -> S;
        false -> advance_current(S#s{uncertain = none,phase = activating})
    end;
advance_current(S = #s{spec = #{custody := none}}) -> request_activation(S);
advance_current(S = #s{spec = #{custody := {request, Token, Previous, _, _} = Custody,
                         generation := G, run_token := Installed},
               token = Token, resolved = Custody}) ->
    case G =:= Previous + 1 andalso Installed =:= Token of
        true -> start_native(S);
        false -> S#s{phase = awaiting_selection}
    end;
advance_current(S = #s{spec = #{custody := {request, _, Previous, _, _} = Custody,
                         generation := G}, resolved = Custody}) ->
    case G > Previous of true -> request_activation(S); false -> S#s{phase = awaiting_selection} end;
advance_current(S = #s{spec = #{custody := {request, _, _, Bytes, Signature}}}) ->
    request(resolve, {Bytes, Signature}, S).

request_activation(S = #s{spec = Spec, token = Token}) ->
    #{world := {world_ref, _, _, World}, generation := G, custody := Prior} = Spec,
    Activation = {physics_activate, World, G, Token},
    Store = {physics_store_request, World, G, Prior, Token, {'Bytes'}, {'Signature'}},
    request(activate, {Activation, Store}, S).

request(Kind, Work, S = #s{owner = Owner, spec = Spec}) ->
    Ref = make_ref(),
    Window = case S#s.window of
        none -> Budget = maps:get(budget,Spec), {quod_time:now_ms()+Budget,quod_time:mono_ms()+Budget};
        Original -> Original
    end,
    Owner ! {physics_work, self(), maps:get(world, Spec), Ref, Kind, Work, Window},
    S#s{pending = {Ref, Kind, activation_state(Spec)}, window = Window}.

outcome(_, {error, busy}, S) -> notify(capacity, S#s{phase = capacity});
outcome(_, {error, stale_executor}, S) -> notify(awaiting_actor, S#s{phase = awaiting_actor});
outcome(resolve, {ok, _, {operation_outcome, _, #{status := committed}}}, S = #s{spec = Spec}) ->
    advance(S#s{resolved = maps:get(custody, Spec), phase = activating});
outcome(activate, {ok, _, {normalized, {committed, _, _}}}, S = #s{spec = Spec}) ->
    %% Selection may arrive after the result. Only its matching committed
    %% token plus the original outcome can release native installation.
    case maps:get(custody, Spec) of
        {request, Token, _, _, _} = C when Token =:= S#s.token ->
            advance(S#s{resolved = C});
        _ -> S#s{phase = awaiting_selection}
    end;
outcome(activate, {error, {request_not_submitted, _}}, S) ->
    notify({unavailable, activation_not_sent}, S#s{phase = not_sent});
outcome(resolve, {ok, _, {operation_outcome, _, #{status := Status}}}, S)
  when Status =:= rejected; Status =:= aborted ->
    notify({unavailable, {activation_terminal, Status}}, S#s{phase = unresolved});
outcome(resolve, {error, _}, S) ->
    notify({unavailable, activation_resolution_unavailable}, S#s{phase = unresolved});
outcome(activate, _, S) -> S#s{phase = unresolved};
outcome(_, _, S) -> notify({unavailable, activation_unresolved}, S#s{phase = unresolved}).

start_native(S = #s{spec = #{limits := Limits, dt := Dt, gravity := Gravity}}) ->
    case native(fun() -> quod_physics_native:new_world(Limits, Dt, Gravity) end) of
        {ok, Resource} -> resume_observations(install(S#s.spec, S#s{native = Resource, phase = active}));
        {error, Reason} -> fail(Reason, S)
    end.

install(Spec = #{bodies := Bodies}, S = #s{native = Resource}) ->
    Hinges = maps:get(hinges,Spec,[]),
    Geometry = maps:with([bodies,hinges,restores],Spec),
    Result = case S#s.installed_geometry =:= Geometry of
        true -> {ok,0};
        false -> native(fun() ->
        case quod_physics_native:install(Resource,Bodies) of
            {ok,N} -> case quod_physics_native:install_hinges(Resource,Hinges) of
                {ok,J} ->
                    Restores = [Row || Row = {Id,Rev,_,_,_} <- maps:get(restores,Spec,[]),
                                      maps:get(Id,S#s.revisions,none) =/= Rev],
                    case quod_physics_native:restore_rest(Resource,Restores) of
                        {ok,{}} -> {ok,N+J}; Error -> Error end;
                Error -> Error end;
            Error -> Error
        end
        end)
    end,
    case Result of
        {ok, Changes} ->
            {ControlChanges,DoorsInstalled} = install_controls(S#s{spec = Spec,installed_geometry = Geometry,
                revisions = maps:from_list([{Id,Rev} || {Id,Rev,_,_,_,_} <- Bodies])}),
            AgentControls = maps:get(agent_controls, Spec, []),
            ControlChanged = S#s.agent_controls =/= AgentControls,
            Installed = #{fence => fence(Spec),incarnation => S#s.token,structure => maps:get(structure,Spec)},
            Inputs = maps:filtermap(fun(_,Row = #{control := Control,expected := Expected}) ->
                case retained_binding(Control,maps:get(agent_bindings,Spec,[])) of
                    false -> false;
                    true ->
                        Retained = case lists:member(Control,AgentControls) andalso current_projection(Installed,Expected) of
                            true -> Row;
                            false -> (suspend_input(Row))#{expected => maps:merge(Expected,Installed)}
                        end,
                        %% Changed physical support wakes grounded mechanics,
                        %% even when the previous frame was fully settled.
                        {true,Retained#{falling => maps:get(falling,Retained) orelse
                            (Changes > 0 andalso grounded_control(Control))}}

                end
            end,S#s.inputs),
            Guard = maps:get(navigation_guard,Spec),
            GuardChanged = Guard =/= S#s.installed_guard,
            Controlled = reconcile_controller(DoorsInstalled#s{agent_controls = AgentControls,inputs = Inputs,installed_guard = Guard}),
            case {Controlled#s.phase,Changes+ControlChanges,S#s.frame} of
                {{failed,_},_,_} -> Controlled;
                {_,0,none} -> notify(installed,schedule({false,[],[]},publish({false,[],[]},Controlled)));
                {_,0,Frame} ->
                    Updated = Controlled#s{frame = Frame#{structure => maps:get(structure,Spec)}},
                    case maps:get(structure,Frame) =:= maps:get(structure,Spec) of
                        true when ControlChanged; GuardChanged -> notify(installed, schedule({false,[],[]},Updated));
                        true -> Updated;
                        false -> notify(installed,schedule({false,[],[]},deliver_frame(Updated)))
                    end;
                _ -> notify(installed,do_step(Controlled#s{installs = S#s.installs +
                    case Changes > 0 of true -> 1; false -> 0 end}))
            end;
        {error,Reason} -> fail(Reason,S)
    end.

%% Signed view admission is checked against the same installed domain selection
%% as motion. A control-only change must retire the old registration and wake a
%% reader awaiting installation even when no collider or pose changed.
current_control(Expected, Spec) ->
    case maps:get(control, Expected, none) of
        none -> true;
        Control -> lists:member(Control, maps:get(agent_controls, Spec, []))
    end.

reconcile_controller(S = #s{viewer = #{pid := Pid, ref := Ref, expected := Expected}, spec = Spec}) ->
    case current_control(Expected, Spec) of
        true -> S;
        false -> Pid ! {physics_refresh, self(), Ref}, clear_viewer(S)
    end;
reconcile_controller(S) -> S.

install_controls(S = #s{spec = Spec, controls = Old, native = Resource, observations = Observations}) ->
    Activities = maps:get(activities,Spec,#{}),
    Doors = maps:filter(fun(K,_) -> is_integer(K) end,Activities),
    Desired = maps:map(fun(D,#{state := State}) ->
        Revision = maps:get(D,S#s.revisions),
        case State of {closing,R} -> {Revision,R}; _ -> stopped end
    end,Doors),
    Kept = maps:filter(fun(D,#{request := R}) ->
        case maps:get(D,Activities,none) of #{request := R} -> true; _ -> false end
    end,Observations),
    maps:fold(fun(D,Control,{Count,Acc}) ->
        case maps:get(D,Old,stopped) =:= Control of
            true -> {Count,Acc};
            false ->
                Drive = case {Control,maps:get(D,Doors)} of
                    {{_,_},#{custody := none}} -> true;
                    _ -> false
                end,
                case Drive orelse maps:get(D,Acc#s.driving,false) of
                    true ->
                        case native(fun() -> quod_physics_native:drive_hinge(Resource,D,Drive) end) of
                            {ok,{}} -> {Count+1,Acc};
                            {error,Reason} -> {Count,fail(Reason,Acc)}
                        end;
                    false -> {Count,Acc}
                end
        end
    end,{0,S#s{controls = Desired,observations = Kept}},Desired).

do_step(S0) -> step_native(advance_inputs(S0)).
step_native(S) -> step_native(S,false).
step_native(S = #s{phase = Phase},_) when Phase =/= active -> S;
step_native(S,Refresh) ->
    case navigation_current(S) of true -> step_current_native(S,Refresh); false -> S end.
step_current_native(S = #s{native = Resource},Refresh) ->
    case native(fun() -> quod_physics_native:step(Resource,Refresh) end) of
        %% Rapier's sleeping-step sentinel means unchanged, not an empty world.
        {ok,{false,[],[]}} when S#s.frame =/= none ->
            Feedback = input_feedback(S),
            case maps:get(inputs,S#s.frame,#{}) =:= Feedback of
                true -> schedule({false,[],[]},S);
                false ->
                    Tick = S#s.tick+1,
                    schedule({false,[],[]},deliver_frame(S#s{tick = Tick,
                        frame = (S#s.frame)#{tick => Tick,inputs => Feedback}}))
            end;
        {ok, Sample} -> sample_rests(sample_doors(schedule(Sample, publish(Sample, S#s{tick = S#s.tick + 1, steps = S#s.steps + 1, moving = element(1,Sample)}))));
        {error, Reason} -> fail(Reason, S)
    end.

schedule({Active, Poses, Contacts},S) ->
    schedule_active({Active orelse S#s.moving orelse inputs_active(S),Poses,Contacts},S).
schedule_active({true, _, _}, S = #s{timer = none, spec = #{dt := Dt}}) ->
    try S#s{timer = erlang:start_timer(max(1, round(Dt * 1000)), self(), step)}
    catch error:badarg -> fail(invalid_step, S) end;
schedule_active({false, _, _}, S) ->
    _ = case S#s.timer of none -> ok; Timer -> erlang:cancel_timer(Timer) end,
    notify(sleeping, S#s{timer = none});
schedule_active(_, S) -> S.

inputs_active(S = #s{inputs = Inputs}) ->
    Now = quod_time:now_ms(),
    navigation_current(S) andalso maps:fold(fun(_,Row,Active) -> Active orelse
        (input_current(Row,S) andalso (maps:get(pending,Row) orelse
         maps:get(falling,Row) orelse input_driving(Row,Now))) end,false,Inputs).
input_driving(#{input := {{drive,{vector,0,0,0},{angular,0,0,0}},_}},_) -> false;
input_driving(#{input := {{drive,_,_},_},expiry := Expiry},Now) -> Expiry > Now;
input_driving(_,_) -> false.
pending_discrete(#{pending := true,input := {Input,_}}) -> element(1,Input) =/= drive;
pending_discrete(_) -> false.
current_registration(Control,#{registration := Token},#{expected := #{registration := Token,control := Control}}) -> true;
current_registration(_,_,_) -> false.

installed_input({control,P,_,_},{{push,{body,B,R},_},{push_limits,B,R,I,V}},Spec) ->
    lists:member({push,P,B,R,I,V},maps:get(agent_controls,Spec,[]));
installed_input(_,{{push,_,_},_},_) -> false;
installed_input(_,_,_) -> true.

retained_binding({control,Principal,Epoch,{controlled_agent,Agent,_,_,_,_,{viewpoint,View,_,_}}},Bindings) ->
    lists:member({binding,Principal,Epoch,{controlled,Agent,View}},Bindings).
suspend_input(Row) -> Row#{expiry => 0,pending => false,result => suspended}.

advance_inputs(S = #s{phase = Phase}) when Phase =/= active -> S;
advance_inputs(S = #s{inputs = Inputs}) ->
    maps:fold(fun(Principal,Row,Acc) ->
        case navigation_current(Acc) andalso input_current(Row,Acc) of
            true -> advance_input(Principal,Row,Acc);
            false -> Acc
        end
    end,S,Inputs).
grounded_control({control,_,_,{controlled_agent,_,_,_,_,{motion,{grounded,_},_,_,_,_,_},_}}) -> true;
grounded_control(_) -> false.
input_current(#{control := Control,expected := Expected},S) ->
    current_control(Expected#{control => Control},S#s.spec) andalso current_projection(S#s.frame,Expected).

advance_input(_,_,S = #s{phase = Phase}) when Phase =/= active -> S;
advance_input(Principal,Row = #{control := Control = {control,_,_,{controlled_agent,_,_,_,_,
                {motion,_,_,_,_,MotionLimits,_},_}},
                input := Push = {{push,{body,Body,Revision},Impulse},{push_limits,Body,Revision,_,Speed}},
                expiry := Expiry}, S) ->
    Result = case maps:get(pending,Row) of
        false -> maps:get(result,Row);
        true -> case {Expiry > quod_time:now_ms(),installed_input(Control,Push,S#s.spec)} of
            {true,true} -> case native(fun() -> quod_physics_native:push_body(S#s.native,Body,Revision,
                                               physical_vector(Impulse),Speed/1000) end) of
                {ok,true} -> pushed;
                {ok,false} -> refused;
                _ -> unavailable
            end;
            {true,false} -> refused;
            {false,_} -> expired
        end
    end,
    %% A discrete interaction does not suspend the played body's gravity.
    Next = advance_input(Principal,Row#{input => {{drive,{vector,0,0,0},{angular,0,0,0}},MotionLimits},
                                       pending => false},S),
    After = maps:get(Principal,Next#s.inputs),
    Next#s{inputs = (Next#s.inputs)#{Principal => After#{input => Push,result => Result}}};
advance_input(Principal,Row = #{control := {control,_,_,{controlled_agent,_,_,Body,Revision,
                {motion,Mode,_,_,_,Limits,Capabilities},_}},input := {Input,Limits},expiry := Expiry},
              S = #s{spec = Spec,native = Resource,inputs = Inputs}) ->
    Dt = maps:get(dt,Spec),
    Current = case Expiry > quod_time:now_ms() andalso
                   (maps:get(pending,Row) orelse element(1,Input) =:= drive) of
        true -> Input;
        false -> {drive,{vector,0,0,0},{angular,0,0,0}}
    end,
    Vertical = case Mode of {grounded,_} -> maps:get(vertical,Row)+maps:get(gravity,Spec)*Dt; free -> 0.0 end,
    {ok,_,NativeLimits} = query_input({travel,{vector,0,0,0},{angular,0,0,0}},Limits),
    Query = movement_query(Current,Mode,Vertical,Dt,Capabilities),
    case native(fun() -> quod_physics_native:move_body(Resource,Body,Revision,Query,NativeLimits) end) of
        {ok,Answer} ->
            {Usable,Supported} = motion_progress(Answer,Mode),
            Settled = Supported orelse descent_stopped(Answer,Current,Vertical,Body,S#s.frame),
            Result = case element(1,Input) =/= drive andalso not maps:get(pending,Row) of
                true -> maps:get(result,Row);
                false -> Answer
            end,
            RefusedDiscrete = element(1,Current) =/= drive andalso not Usable,
            Updated = Row#{pending => false,result => Result,
                vertical => case {RefusedDiscrete,Settled orelse not Usable} of
                    {true,_} -> maps:get(vertical,Row);
                    {false,true} -> 0.0;
                    _ -> Vertical
                end,
                falling => case RefusedDiscrete of
                    true -> maps:get(falling,Row);
                    false -> Mode =/= free andalso not Settled andalso Usable
                end},
            S#s{inputs = Inputs#{Principal => Updated}};
        {error,Reason} -> fail(Reason,S)
    end.
%% A clipped descent with no downward progress is mechanically settled even
%% when the touching faces are too steep to count as a teleport landing.
%% New travel or physical-world activity rechecks it; no velocity accumulates
%% while a wedge holds the body still.
descent_stopped({clipped,{{_,Y,_},_},_,_},{drive,_,_},Vertical,Body,#{poses := Poses}) when Vertical < 0 ->
    case lists:keyfind(Body,1,Poses) of
        {Body,_,world,{_,Before,_},_,_} -> Y >= Before;
        _ -> false
    end;
descent_stopped(_,_,_,_,_) -> false.

movement_query({drive,{vector,X,Y,Z},{angular,Ax,Ay,Az}},Mode,Vertical,Dt,_) ->
    Vy = case Mode of free -> Y/1000; {grounded,_} -> Vertical end,
    {travel,{X/1000*Dt,Vy*Dt,Z/1000*Dt},{Ax/1000*Dt,Ay/1000*Dt,Az/1000*Dt}};
movement_query({snap,Angle},_,_,_,_) -> {travel,{0.0,0.0,0.0},{0.0,Angle/1000,0.0}};
movement_query({reposition,Pose},_,_,_,_) -> {place,physical_pose(Pose)};
movement_query({teleport,Position},_,_,_,Capabilities) ->
    {teleport,Reach,Drop,Up} = lists:keyfind(teleport,1,Capabilities),
    {land,physical_vector(Position),Reach/1000,Drop/1000,Up/1000}.
motion_progress({clear,_,_},_) -> {true,false};
motion_progress({clipped,_,Contacts,_},{grounded,Up}) ->
    {true,lists:any(fun({_,{_,Ny,_}}) -> Ny >= Up/1000 end,Contacts)};
motion_progress({clipped,_,_,_},_) -> {true,false};
motion_progress(_,_) -> {false,false}.

publish({_Active, Poses, Contacts}, S = #s{spec = Spec}) ->
    Frame = #{schema => 1, units => metres_seconds, fence => fence(Spec), structure => maps:get(structure, Spec),
              incarnation => S#s.token, tick => S#s.tick, inputs => input_feedback(S),
              poses => [{Id, maps:get(Id, S#s.revisions), world, P, Q, V} || {Id,P,Q,V} <- Poses],
              contacts => [{A,maps:get(A,S#s.revisions),B,maps:get(B,S#s.revisions)} || {A,B} <- Contacts]},
    deliver_frame(S#s{frame = Frame}).

input_feedback(#s{inputs = Inputs}) ->
    maps:map(fun(_,Row) -> maps:with([control,sequence,pending,result],Row) end,Inputs).

%% One retained sample and one outstanding delivery, with no motion queue.
%% A structural/run change revokes the projection even while credit is held.
deliver_frame(S = #s{viewer = none}) -> S;
deliver_frame(S = #s{viewer = #{pid := Pid, ref := Ref, expected := Expected,
                               credit := Credit, tick := Previous} = V, frame = Frame}) ->
    case current_projection(Frame, Expected) of
        false -> Pid ! {physics_refresh, self(), Ref}, clear_viewer(S);
        true ->
            Tick = maps:get(tick, Frame),
            case Credit andalso Tick > Previous of
                true ->
                    Pid ! {physics_frame, self(), Ref, view_frame(Frame,Expected,S)},
                    S#s{viewer = V#{credit => false, tick => Tick}};
                false -> S
            end
    end.

%% A clearance ball is a conservative sensory allowance for tracked viewing,
%% never a player collider. It is measured against the retained physical world
%% and only for the selected viewer, once per delivered authoritative frame.
view_frame(Frame,Expected,S) ->
    (view_clearance(Frame,Expected,S))#{registration => maps:get(registration,Expected)}.
view_clearance(Frame,#{control := {control,_,_,{controlled_agent,_,_,Body,Revision,
        {motion,_,_,_,_,Limits,_},
        {viewpoint,_,{pose,Position,_},{tracking,view_only,Radius}}}}},#s{native = Native})
  when is_integer(Radius),Radius > 0 ->
    Clearance = case query_input({travel,{vector,0,0,0},{angular,0,0,0}},Limits) of
        {ok,_,L} ->
            case native(fun() -> quod_physics_native:motion_query(Native,Body,Revision,
                    {view,physical_vector(Position),Radius/1000},L) end) of
                {ok,{view_clearance,Distance,_}} -> Distance;
                _ -> null
            end;
        error -> null
    end,
    Frame#{view_clearance => Clearance};
view_clearance(Frame,_,_) -> Frame#{view_clearance => null}.

%% Runtime owns this incarnation-scoped invalidation generation. Reading its
%% shared token costs no mailbox round trip and cannot rebuild domain state.
navigation_current(#s{spec = #{navigation_guard := {Guard,Generation}}}) ->
    atomics:get(Guard,1) =:= Generation.

current_projection(#{fence := F, structure := R, incarnation := I},
                   #{fence := F, structure := R, incarnation := I}) -> true;
current_projection(_, _) -> false.

clear_viewer(S = #s{viewer = #{monitor := M,expected := Expected},inputs = Inputs}) ->
    demonitor(M, [flush]),
    Next = case maps:get(control,Expected,none) of
        Control = {control,Principal,_,_} ->
            case maps:get(Principal,Inputs,none) of
                Row = #{control := Control} -> Inputs#{Principal => Row#{expiry => 0,pending => false,result => disconnected}};
                _ -> Inputs
            end;
        none -> Inputs
    end,
    S#s{viewer = none,inputs = Next};
clear_viewer(S) -> S.

fence(#{world := W, authority := A, epoch := E, generation := G}) -> {W, A, E, G}.
notify(installed, S = #s{phase = {failed, _}}) -> S;
notify(installed,S) ->
    case navigation_current(S) of true -> publish_status(installed,S); false -> S end;
notify(Status,S) -> publish_status(Status,S).
publish_status(Status, S = #s{owner = Owner, spec = Spec}) ->
    Owner ! {physics_status, self(), maps:get(world, Spec), S#s.token, Status}, S.
fail(Reason, S) ->
    retire(S),
    notify({failed, Reason}, deliver_frame(S#s{native = none, timer = none, frame = none, phase = {failed, Reason}})).

native(Fun) -> try Fun() catch error:_ -> {error, native_failure} end.
retire(#s{native = Resource, timer = Timer}) ->
    _ = case Timer of none -> ok; _ -> erlang:cancel_timer(Timer) end,
    case Resource of none -> ok; _ -> native(fun() -> quod_physics_native:retire(Resource) end) end,
    ok.
terminate(_, S) -> retire(S).

projection({Ns, Anchor}, Rows) ->
    try
        Specs = [spec(Ns, Anchor, Row) || Row <- Rows],
        true = length(Specs) =:= map_size(maps:from_list([{maps:get(world, X), X} || X <- Specs])),
        {ok, Specs}
    catch throw:unsupported_physics_profile -> {error, unsupported_physics_profile};
          _:_ -> {error, invalid_physics_projection} end.

spec(Ns, Anchor, {world, W, I, E, Key, G, Token, Custody, S,
                  {limits, B, P, C, Coord, {geometry, Parts, Vertices, Triangles}}, Step, Gravity, Bodies, Budget, Recovery}) ->
    {Checkpoints,Joints,DoorRows,Bindings,Controls} = case Recovery of
        {baseline,CP,JS,DS,{control_selection,BS,CS}} -> {CP,JS,DS,BS,CS}; _ -> throw(unsupported_physics_profile)
    end,
    true = is_integer(E) andalso E > 0 andalso is_integer(G) andalso G >= 0,
    true = valid_run(G, Token, Custody),
    true = is_integer(S) andalso S > 0 andalso is_binary(Key) andalso byte_size(Key) =:= 32,
    true = lists:all(fun(X) -> is_integer(X) andalso X >= 0 end, [B,P,C,Coord,Parts,Vertices,Triangles]),
    true = Coord > 0,
    true = is_integer(Step) andalso Step > 0,
    true = is_integer(Gravity),
    true = is_integer(Budget) andalso Budget > 0,
    Native = [body(Row, S) || Row <- Bodies],
    Hinges = [hinge(Row,Checkpoints,Native,G) || Row <- Joints],
    ActivityMap = maps:from_list([activity(Row) || Row <- DoorRows]),
    true = length(DoorRows) =:= map_size(ActivityMap),
    true = lists:sort([Id || Id <- maps:keys(ActivityMap), is_integer(Id)]) =:= lists:sort([Id || {{Id,_,_,_,_,_},_} <- Hinges]),
    Restores = [rest_checkpoint(CP,Policy,Native,Hinges,G) || {rest,CP,Policy} <- Checkpoints],
    true = length(Restores) =:= map_size(maps:from_list([{Id,true} || {Id,_,_,_,_} <- Restores])),
    true = lists:all(fun({hinge,D,_,_,_,_}) -> maps:is_key(D,ActivityMap);
                        ({rest,_,_}) -> true; (_) -> false end,Checkpoints),
    #{world => {world_ref, Ns, Anchor, W}, authority => {agent_instance_ref, Ns, Anchor, I},
      epoch => E, key => Key, generation => G, run_token => Token, custody => Custody,
      structure => S, limits => {B,P,C,Coord / 1000,Parts,Vertices,Triangles}, dt => Step / 1000000,
      gravity => Gravity / 1000, bodies => Native, hinges => Hinges, activities => ActivityMap,
      agent_controls => Controls, agent_bindings => Bindings, restores => Restores, budget => Budget}.
body({body, Id, Rev, Kind, Pose, Shape, Density}, Structure) ->
    true = is_integer(Id) andalso Id >= 0 andalso Id < (1 bsl 64),
    true = is_integer(Rev) andalso Rev > 0 andalso Rev =< Structure,
    true = lists:member(Kind, [dynamic, fixed, controlled]),
    true = is_integer(Density),
    {Id, Rev, Kind, physical_pose(Pose), geometry(Shape), float(Density)}.

physical_pose({vector,_,_,_} = Position) -> {physical_vector(Position), {0.0,0.0,0.0}};
physical_pose({pose, Position, {rotation,X,Y,Z}}) ->
    {physical_vector(Position), physical_vector({vector,X,Y,Z})}.
physical_vector({vector,X,Y,Z}) when is_integer(X),is_integer(Y),is_integer(Z) ->
    {X/1000,Y/1000,Z/1000}.

query_input(Query,{query_limits,Skin,Tolerance,Slides,Checks})
  when is_integer(Skin),Skin > 0,is_integer(Tolerance),Tolerance >= 0,Tolerance < Skin,
       is_integer(Slides),Slides > 0,is_integer(Checks),Checks > 0 ->
    try
        Q = case Query of
            {place,Pose} -> {place,physical_pose(Pose)};
            {landing,Position,Reach,Drop,Up} -> {land,physical_vector(Position),Reach/1000,Drop/1000,Up/1000};
            {travel,Translation,{angular,X,Y,Z}} ->
                {travel,physical_vector(Translation),physical_vector({vector,X,Y,Z})}
        end,
        {ok,Q,{Skin/1000,Tolerance/1000,Slides,Checks}}
    catch error:_ -> error end;
query_input(_,_) -> error.

geometry({parts, Parts}) ->
    {parts, lists:map(fun({part,Pose,Shape}) -> {physical_pose(Pose), primitive(Shape)} end,Parts)};
geometry({surface, Vertices, Triangles}) ->
    true = lists:all(fun({triangle,A,B,C}) ->
        lists:all(fun(X) -> is_integer(X) andalso X >= 0 andalso X < (1 bsl 32) end,[A,B,C]);
        (_) -> false end,Triangles),
    {surface, [physical_vector(V) || V <- Vertices], [{A,B,C} || {triangle,A,B,C} <- Triangles]};
geometry(Shape) -> {solid, primitive(Shape)}.
primitive({box,X,Y,Z}) -> {Hx,Hy,Hz} = physical_vector({vector,X,Y,Z}), {box,Hx,Hy,Hz};
primitive({ball,R}) when is_integer(R) -> {ball,R/1000};
primitive({capsule,H,R}) when is_integer(H),is_integer(R) -> {capsule,H/1000,R/1000};
primitive({convex,Vertices}) -> {convex,[physical_vector(V) || V <- Vertices]}.

valid_run(G, Token, Custody) ->
    ((G =:= 0 andalso Token =:= none) orelse
       (is_binary(Token) andalso byte_size(Token) =:= 32)) andalso valid_custody(Custody, G).
valid_custody(none, _) -> true;
valid_custody({request, Token, Previous, Bytes, Signature}, G) ->
    is_binary(Token) andalso byte_size(Token) =:= 32 andalso
    is_integer(Previous) andalso Previous >= 0 andalso Previous =< G andalso
    is_binary(Bytes) andalso byte_size(Bytes) > 0 andalso
    is_binary(Signature) andalso byte_size(Signature) =:= 64;
valid_custody(_, _) -> false.

hinge({hinge,D,Revision,Frame,{vector,X,Y,Z},Baseline,{motor,Stiff,Damp,Force,Tolerance}},CPs,Bodies,G) ->
    {D,Revision,dynamic,_,_,_} = lists:keyfind(D,1,Bodies),
    {Frame,Revision,fixed,_,_,_} = lists:keyfind(Frame,1,Bodies),
    true = lists:all(fun is_integer/1,[X,Y,Z,Baseline,Stiff,Damp,Force,Tolerance]),
    Restore = case [CP || CP = {hinge,Id,_,_,_,_} <- CPs, Id =:= D] of
        [] -> Baseline;
        [{hinge,D,Revision,Generation,Tick,Angle}]
          when is_integer(Generation),Generation > 0,Generation =< G,
               is_integer(Tick),Tick > 0,is_integer(Angle) -> Angle
    end,
    {{D,Revision,Frame,{X/1000,Y/1000,Z/1000},Baseline/1000,
      {float(Stiff),float(Damp),float(Force),Tolerance/1000}},Restore/1000};
hinge(_,_,_,_) -> throw(unsupported_physics_profile).

activity({rest,D,Sequence,State,Custody}) ->
    {D,Activity} = activity({door,D,Sequence,State,Custody}),
    {{rest,D},Activity};
activity({door,D,Sequence,State,Custody}) when is_integer(D),is_integer(Sequence),Sequence >= 0 ->
    true = quod_wire_term:is_ground({State,Custody}),
    Key = case Custody of
        none -> none;
        {request,_,_,Bytes,Signature} ->
            {ok,#{operation_ref := {operation,_,_,Agent,Id}}} = quod_client_goal:verify(Bytes,Signature),
            {request,{Agent,Id}}
    end,
    {D,#{sequence => Sequence,state => State,request => activity_request(State),custody => Custody,outcome_key => Key}}.

activity_request({closing,R}) -> R;
activity_request({waiting,R}) -> R;
activity_request(_) -> none.

rest_checkpoint({rest_v1,D,Revision,{source,{agent_instance_ref,Ns,Anchor,_},Epoch,G,Token,Structure,Tick},
                 world_mm_quaternion_million,{pose,Position,{quaternion,X,Y,Z,Q}},zero_velocity},
                {recovery,Tolerance,Checks},Bodies,Hinges,Generation) ->
    {D,Revision,dynamic,_,_,_} = lists:keyfind(D,1,Bodies),
    true = is_binary(Ns) andalso is_binary(Anchor) andalso byte_size(Anchor) =:= 32,
    true = is_binary(Token) andalso byte_size(Token) =:= 32,
    true = is_integer(Epoch) andalso Epoch > 0 andalso is_integer(G) andalso G > 0 andalso G =< Generation,
    true = is_integer(Structure) andalso Structure >= Revision andalso is_integer(Tick) andalso Tick > 0,
    true = is_integer(Tolerance) andalso Tolerance >= 0 andalso is_integer(Checks) andalso Checks > 0,
    true = lists:all(fun(V) -> is_integer(V) andalso abs(V) =< 1000000 end,[X,Y,Z,Q]),
    true = not lists:any(fun({{Id,_,Frame,_,_,_},_}) -> Id =:= D orelse Frame =:= D end,Hinges),
    {D,Revision,{physical_vector(Position),{X/1000000,Y/1000000,Z/1000000,Q/1000000}},Tolerance/1000,Checks}.


update_observation_height(D,H,S) ->
    O = maps:get(D,S#s.observations),
    S#s{observations = (S#s.observations)#{D => O#{outcome_height => H}}}.

update_observation(Ref,Fun,S) ->
    S#s{observations = maps:map(fun(_,O = #{ref := R}) when R =:= Ref -> Fun(O);
                                 (_,O) -> O end,S#s.observations)}.

sample_doors(S = #s{phase = active,native = Resource,spec = Spec}) ->
    case native(fun() -> quod_physics_native:hinge_samples(Resource) end) of
        {ok,Rows} ->
            Next = S#s{driving = maps:from_list([{D,Drive} || {D,_,Drive} <- Rows])},
            lists:foldl(fun({D,Angle,false},Acc) ->
                case {maps:get(D,maps:get(activities,Spec,#{})),maps:is_key(D,Acc#s.observations)} of
                    {#{state := {closing,R},custody := none},false} -> offer_door(D,R,Angle,Acc);
                    {#{state := {closing,R}},true} ->
                        case maps:get(D,Acc#s.observations) of
                            #{state := resampling} -> offer_door(D,R,Angle,Acc);
                            _ -> Acc
                        end;
                    _ -> Acc
                end;
                (_,Acc) -> Acc
            end,Next,Rows);
        {error,Reason} -> fail(Reason,S)
    end;
sample_doors(S) -> S.

offer_door(D,R,Angle,S = #s{spec = Spec,frame = #{contacts := Contacts}}) ->
    [{_,Revision,Frame,_,_,{_,_,_,Tolerance}}] =
        [Row || {Row = {Id,_,_,_,_,_},_} <- maps:get(hinges,Spec),Id =:= D],
    Partners = lists:sort([{B,BR} || {A,_,B,BR} <- Contacts,A =:= D,B =/= Frame] ++
                          [{A,AR} || {A,AR,B,_} <- Contacts,B =:= D,A =/= Frame]),
    Contact = case Partners of [{Other,Rev}|_] -> {contact,Other,Rev}; [] -> clear end,
    case Contact =/= clear orelse abs(Angle) =< round(Tolerance*1000) of
        false -> notify({unavailable,{door_held,D}},S);
        true ->
            Budget = maps:get(budget,Spec), At = quod_time:now_ms(), Expiry = At+Budget,
            Window = {Expiry,quod_time:mono_ms()+Budget},
            {world_ref,_,_,W} = maps:get(world,Spec),
            Sample = {door_sample,W,D,R,maps:get(authority,Spec),maps:get(epoch,Spec),
                maps:get(generation,Spec),S#s.token,maps:get(structure,Spec),Revision,
                maps:get(Frame,S#s.revisions),S#s.tick,Angle,Contact,{validity,At,Expiry}},
            offer_sample(D,R,Sample,Window,S)
    end.

sample_rests(S = #s{phase = active,spec = Spec}) ->
    maps:fold(fun({rest,D} = Key,#{request := R},Acc) when R =/= none ->
        Ready = case maps:get(Key,Acc#s.observations,none) of
            #{state := resampling} -> true;
            _ -> false
        end,
        case Ready andalso navigation_current(Acc) of
            true ->
                Revision = maps:get(D,Acc#s.revisions),
                case native(fun() -> quod_physics_native:rest_sample(Acc#s.native,D,Revision) end) of
                    {ok,{{X,Y,Z},{Qx,Qy,Qz,Qw}}} ->
                        At = quod_time:now_ms(), Budget = maps:get(budget,Spec), Expiry = At+Budget,
                        {world_ref,_,_,W} = maps:get(world,Spec),
                        Sample = {rest_sample,W,D,R,maps:get(authority,Spec),maps:get(epoch,Spec),
                            maps:get(generation,Spec),Acc#s.token,maps:get(structure,Spec),Revision,Acc#s.tick,
                            {pose,{vector,X,Y,Z},{quaternion,Qx,Qy,Qz,Qw}},{validity,At,Expiry}},
                        offer_sample(Key,R,Sample,{Expiry,quod_time:mono_ms()+Budget},Acc);
                    {ok,nil} -> Acc;
                    {error,Reason} -> fail(Reason,Acc)
                end;
            false -> Acc
        end;
        (_,_,Acc) -> Acc
    end,S,maps:get(activities,Spec,#{}));
sample_rests(S) -> S.

offer_sample(Key,R,Sample,Window,S = #s{owner = Owner,spec = Spec}) ->
    Ref = make_ref(),
    Owner ! {physics_observation,self(),maps:get(world,Spec),S#s.token,Ref,Sample,Window},
    O = #{request => R,state => offered,ref => Ref,sample => Sample,window => Window,
          basis => observation_basis(Spec),prior => maps:get(custody,maps:get(Key,maps:get(activities,Spec)))},
    S#s{observations = (S#s.observations)#{Key => O}}.

observation_basis(Spec) -> maps:with([authority,epoch,generation,run_token,structure,budget],Spec).

observation_result(Ref,Result,S) ->
    case [{D,O} || {D,O = #{ref := R}} <- maps:to_list(S#s.observations),R =:= Ref] of
        [] -> S;
        [{D,O}] ->
            State = case Result of
                {error,busy} -> capacity;
                {ok,_,{normalized,{committed,_,_}}} -> committed;
                {ok,_,{operation_outcome,_,#{status := committed}}} -> committed;
                {ok,_,{operation_outcome,_,#{status := Status}}} when Status =:= rejected; Status =:= aborted -> rejected;
                {error,{request_not_submitted,deadline_exceeded}} -> expired;
                {error,{request_not_submitted,_}} -> unsent;
                {error,unmatched} -> held;
                {error,{reaction_guard,_}} -> held;
                {error,invalid_reaction_request} -> held;
                {error,stale_executor} -> stale;
                {error,stale_observation} -> stale;
                {error,expired_observation} -> expired;
                _ -> unresolved
            end,
            Updated = S#s{observations = (S#s.observations)#{D => O#{state => State}}},
            Next = notify(case State of
                capacity -> observation_capacity;
                unresolved -> {unavailable,{observation,D,unresolved}};
                _ -> {observation,D,State}
            end,Updated),
            case State of
                capacity -> Next;
                committed -> Next;
                _ -> resume_observations(Next)
            end
    end.

resume_observations(S = #s{phase = active,spec = Spec}) ->
    sample_rests(maps:fold(fun(D,#{request := R,custody := Custody},Acc) when R =/= none ->
        resume_observation(D,R,Custody,Acc);
        (_,_,Acc) -> Acc
    end,S,maps:get(activities,Spec,#{})));
resume_observations(S) -> S.

resume_observation(D,R,Custody,S = #s{observations = Observations,spec = Spec}) ->
    case maps:get(D,Observations,none) of
        none when Custody =/= none -> resolve_observation(D,R,Custody,S);
        none when is_tuple(D), element(1,D) =:= rest -> fresh_sample(D,S);
        #{state := recover} when Custody =/= none -> resolve_observation(D,R,Custody,S);
        #{state := unresolved,outcome_changed := true} when Custody =/= none -> resolve_observation(D,R,Custody,S);
        #{state := capacity,kind := resolve,window := {Expiry,Deadline}} = O ->
            case Expiry > quod_time:now_ms() andalso Deadline > quod_time:mono_ms() of
                true ->
                    {request,_,_,Bytes,Signature} = Custody,Ref = make_ref(),
                    S#s.owner ! {physics_work,self(),maps:get(world,Spec),Ref,resolve,{Bytes,Signature},{Expiry,Deadline}},
                    S#s{observations = Observations#{D => O#{state => resolving,ref => Ref}}};
                false -> resolve_observation(D,R,Custody,S)
            end;
        #{state := capacity,sample := Sample,window := {Expiry,Deadline}} = O ->
            case Expiry > quod_time:now_ms() andalso Deadline > quod_time:mono_ms() of
                true ->
                    Ref = make_ref(),
                    S#s.owner ! {physics_observation,self(),maps:get(world,Spec),S#s.token,Ref,Sample,{Expiry,Deadline}},
                    S#s{observations = Observations#{D => O#{state => offered,ref => Ref}}};
                false -> fresh_sample(D,S)
            end;
        #{state := expired} -> fresh_sample(D,S);
        #{state := rejected} -> fresh_sample(D,S);
        #{state := unresolved,prior := Prior} when Custody =/= none, Custody =/= Prior -> resolve_observation(D,R,Custody,S);
        #{state := State,basis := Before} when State =:= stale; State =:= held; State =:= unsent ->
            case observation_basis(Spec) =/= Before of
                true when Custody =:= none -> fresh_sample(D,S);
                true -> resolve_observation(D,R,Custody,S);
                _ -> S
            end;
        _ -> S
    end.

resolve_observation(D,R,{request,_Sample,_Result,Bytes,Signature} = Custody,S = #s{spec = Spec}) ->
    Ref = make_ref(),Budget = maps:get(budget,Spec),
    Window = {quod_time:now_ms()+Budget,quod_time:mono_ms()+Budget},
    S#s.owner ! {physics_work,self(),maps:get(world,Spec),Ref,resolve,{Bytes,Signature},Window},
    O = #{request => R,state => resolving,ref => Ref,prior => Custody,
          basis => observation_basis(Spec),
          kind => resolve,window => Window,
          outcome_height => maps:get(outcome_height,maps:get(D,S#s.observations,#{}),0)},
    S#s{observations = (S#s.observations)#{D => O}}.

fresh_sample({rest,_} = Key,S) ->
    #{request := R} = maps:get(Key,maps:get(activities,S#s.spec)),
    step_native(S#s{observations = (S#s.observations)#{Key => #{request => R,state => resampling}}},true);
fresh_sample(D,S = #s{native = Resource}) ->
    case native(fun() -> quod_physics_native:drive_hinge(Resource,D,true) end) of
        {ok,{}} ->
            %% A capacity/edit edge obtains a new completed-step observation;
            %% an old expiry is never extended on its retained bytes.
            #{request := R} = maps:get(D,S#s.observations),
            do_step(S#s{observations = (S#s.observations)#{D => #{request => R,state => resampling}}});
        {error,Reason} -> fail(Reason,S)
    end.

selection_observations(S = #s{observations = Observations}) ->
    S#s{observations = maps:map(fun(_,O = #{state := unresolved}) -> O#{state => recover};
                                 (_,O) -> O end,Observations)}.
