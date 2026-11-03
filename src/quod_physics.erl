-module(quod_physics).
-moduledoc """
One runtime-owned simulation incarnation. Only this process calls its native
resource. The runtime supplies committed selections; the hosted actor owns all
signed work. Frames stay here and are pulled through the runtime's current
fence, rather than flooding its event queue.
""".
-behaviour(gen_server).
-export([start/2, snapshot/2, body_state/4, motion_query/6, accepts/2, projection/2, fence/1,
         watch/3, unwatch/2, ack/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([input/7,geometry_allowance/2,resource_ack/4,view_interest/4]).
-record(s, {owner, monitor, spec, token, native = none, phase = activating,
            pending = none, window = none, resolved = none, timer = none, tick = 0,
            frame = none, revisions = #{}, controls = #{}, driving = #{}, observations = #{},
            installs = 0, steps = 0, queries = 0, viewer = none, agent_controls = [], inputs = #{},
            installed_guard = none, installed_geometry = none, moving = false,
            origin = {0,0,0}, origin_sequence = 0, native_rows = #{}, restoring = #{},
            terrain_mechanical = initial, terrain_sent = initial}).

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
watch(Pid, Expected, Previous) -> gen_server:call(Pid, {watch, Expected, Previous}).
unwatch(Pid, Ref) -> Pid ! {physics_unwatch, self(), Ref}, ok.
ack(Pid, Ref, Tick, OriginSequence) -> Pid ! {physics_ack, self(), Ref, Tick, OriginSequence}, ok.
resource_ack(Pid,Ref,Token,Ack) -> Pid ! {physics_resource_ack,self(),Ref,Token,Ack},ok.
view_interest(Pid,Ref,Sequence,Centre) -> Pid ! {physics_view_interest,self(),Ref,Sequence,Centre},ok.
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
        {watch,_,_} -> true;
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

handle_current_call({watch, Expected, Previous}, {Pid, _}, S = #s{phase = active, frame = Frame}) ->
    Ownership = case S#s.viewer of
        none when Previous =:= none -> true;
        #{pid := Pid, ref := Previous, expected := Installed} ->
            maps:remove(registration, Installed) =:= Expected;
        _ -> false
    end,
    case Ownership andalso current_projection(Frame, Expected) andalso current_control(Expected, S#s.spec) of
        true ->
            Ref = make_ref(),
            M = case S#s.viewer of none -> monitor(process, Pid); #{monitor := Existing} -> Existing end,
            Registered = Expected#{registration => crypto:strong_rand_bytes(32)},
            %% Replacing this socket's exact registration changes delivery
            %% custody, not admitted inputs or their original deadlines.
            Kept = case S#s.viewer of none -> #{}; Old -> maps:with([terrain_regions,terrain_centre,terrain_direction],Old) end,
            Watched = refresh_terrain(S#s{viewer = Kept#{pid => Pid, ref => Ref,
                monitor => M, expected => Registered, tick => maps:get(tick, Frame),
                terrain_interest => 0, origin_sequence => S#s.origin_sequence, credit => false,delivery => frame}}),
            {reply, {ok, Ref, view_frame(Frame#{inputs => input_feedback(Watched)},Registered)},Watched};
        false when not Ownership, S#s.viewer =/= none -> {reply, {error, view_busy}, S};
        false -> {reply, {error, unavailable}, S}
    end;
handle_current_call({watch, _, _}, _, S = #s{phase = {failed, _}}) ->
    {reply, {error, simulation_failed}, S};
handle_current_call({body_state, Expected, {Id, Revision}}, _, S = #s{phase = active, frame = Frame}) ->
    Reply = case current_projection(Frame, Expected) of
        true -> case lists:keyfind(Id, 1, maps:get(poses, Frame)) of
            {Id, Revision, world, _, _, _} = Pose -> {ok, maps:get(tick, Frame), S#s.origin, Pose};
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
            case query_input(Query,Limits,S#s.origin,coordinate_limit(S)) of
                {ok,Q,L} ->
                    case native(fun() -> quod_physics_native:motion_query(Native,Id,Revision,Q,L) end) of
                        {ok,{terrain_coverage,Ranges}} ->
                            {reply,{ok,maps:get(tick,Frame),S#s.origin,unavailable},request_terrain(Ranges,Counted)};
                        {ok,Answer} -> {reply,{ok,maps:get(tick,Frame),S#s.origin,Answer},Counted};
                        {error,Reason} -> {reply,{error,unavailable},fail(Reason,Counted)}
                    end;
                error -> {reply,{ok,maps:get(tick,Frame),S#s.origin,invalid},Counted}
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
                    pending => true,result => queued,result_origin => S#s.origin},
            Updated = S#s{inputs = Inputs#{Principal => Row}},
            {reply,ok,schedule({true,[],[]},Updated)};
        [{false,Reason}|_] -> {reply,{error,Reason},S}
    end;
handle_current_call({physics_input,_,_,_,_,_,_},_,S) ->
    {reply,{error,physics_world_unavailable},S};
handle_current_call(status, _From, S) ->
    {reply, (counters(S))#{phase => S#s.phase, incarnation => S#s.token,
        navigation_ready => S#s.phase =:= active andalso navigation_current(S),
        terrain_chunks => lists:sort(maps:keys(maps:get(voxel_resources,S#s.spec,#{}))),
        inputs => maps:map(fun(_,R) -> maps:with([sequence,result],R) end,S#s.inputs),
        observations => maps:map(fun(_,O) -> maps:get(state,O) end,S#s.observations)}, S};
handle_current_call(_, _, S) -> {reply, {error, unavailable}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info({physics_view_interest,Pid,Ref,Sequence,Centre},
            S = #s{viewer = #{pid := Pid,ref := Ref,terrain_interest := Before,expected := Expected} = V})
  when is_integer(Sequence),Sequence > Before,Sequence < (1 bsl 64),
       is_tuple(Centre),tuple_size(Centre) =:= 3,
       is_integer(element(1,Centre)),is_integer(element(2,Centre)),is_integer(element(3,Centre)) ->
    case navigation_current(S) andalso current_projection(S#s.frame,Expected) of
        true ->
            case view_regions(Centre,maps:get(terrain,Expected,[]),S) of
                {ok,Regions} ->
                    Direction = quod_physics_coordinates:subtract(Centre,maps:get(terrain_centre,V,Centre)),
                    {noreply,deliver_frame(refresh_terrain(S#s{viewer = V#{terrain_interest => Sequence,
                        terrain_regions => Regions,terrain_centre => Centre,terrain_direction => Direction}}))};
                {error,Reason} -> send_view_resource({terrain_unavailable,Reason},V),{noreply,clear_viewer(S)}
            end;
        false -> {noreply,S}
    end;
handle_info({physics_ack, Pid, Ref, Tick, OriginSequence},
            S = #s{viewer = #{pid := Pid, ref := Ref, tick := Tick, origin_sequence := OriginSequence, credit := false,delivery := frame} = V}) ->
    {noreply, deliver_frame(S#s{viewer = V#{credit => true}})};
handle_info({physics_resource_ack,Pid,Ref,Token,Ack},
            S = #s{viewer = #{pid := Pid,ref := Ref,credit := false} = V}) ->
    Next = case {maps:get(delivery,V),Ack} of
        {{terrain_manifest,Token},{want,Ids}} when is_list(Ids) ->
            Count = length(maps:get(terrain_snapshot,V)),
            case length(Ids) =< Count andalso length(lists:usort(Ids)) =:= length(Ids) andalso
                 lists:all(fun(I) -> is_integer(I) andalso I >= 0 andalso I < Count end,Ids) of
                true -> V#{terrain_wanted => lists:sort(Ids),credit => true};
                false -> V
            end;
        {{terrain_chunks,Token,complete},complete} -> V#{terrain_complete => true,credit => true};
        _ -> V
    end,
    {noreply,deliver_frame(S#s{viewer = Next})};
handle_info({physics_unwatch, Pid, Ref}, S = #s{viewer = #{pid := Pid, ref := Ref}}) ->
    {noreply, remove_viewer(S)};
handle_info({'DOWN', M, process, _, _}, S = #s{viewer = #{monitor := M}}) ->
    {noreply, remove_viewer(S)};
handle_info({physics_source_pending,Owner,Notice},S = #s{owner = Owner,spec = Spec}) ->
    Owner ! {physics_pause_seen,self(),maps:get(world,Spec),Notice},
    %% Pause while a retained source verifies its next delta. An unrelated
    %% change must preserve the viewer and the original input expiry.
    {noreply,pause_steps(S)};
handle_info({physics_invalidated,Owner,Notice},S = #s{owner = Owner,spec = Spec}) ->
    Owner ! {physics_invalidation_seen,self(),maps:get(world,Spec),Notice},
    _ = case S#s.viewer of #{pid := Pid,ref := Ref} -> Pid ! {physics_refresh,self(),Ref}; _ -> ok end,
    Stopped = maps:map(fun(_,Row) -> suspend_input(Row) end,S#s.inputs),
    {noreply,clear_viewer(pause_steps(S#s{inputs = Stopped}))};
handle_info({physics_selected, Owner, Ref, Spec}, S = #s{owner = Owner, spec = Old}) ->
    Owner ! {physics_selection_applied, self(), maps:get(world, Spec), Ref},
    ChangedRun = S#s.native =/= none andalso fence(Old) =/= fence(Spec),
    Cancelled = maps:get(custody, Old) =/= none andalso maps:get(custody, Spec) =:= none,
    ChangedFailed = case S#s.phase of
        {failed, _} -> maps:with([bodies, structure, limits], Old) =/= maps:with([bodies, structure, limits], Spec);
        _ -> false
    end,
    case same_run(Old, Spec) andalso not ChangedRun andalso not ChangedFailed andalso not Cancelled of
        true when element(1,S#s.phase) =:= blocked, Old =:= Spec -> {noreply,S};
        true ->
            Phase = case S#s.phase =:= unresolved andalso Old =/= Spec of
                true -> activating;
                false -> S#s.phase
            end,
            {noreply, advance(selection_observations(S#s{spec = Spec, phase = Phase}))};
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
    Recovered = case {Changed, Next#s.phase} of
        {true, unresolved} -> advance(Next#s{phase = activating});
        {true, not_sent} -> advance(Next);
        {false, unresolved} when Kind =:= activate ->
            notify({unavailable,activation_custody_unresolved},Next);
        _ -> Next
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
advance_current(S = #s{phase = Phase, spec = Spec})
  when Phase =:= active; Phase =:= coverage; element(1,Phase) =:= blocked ->
    resume_observations(install(Spec,S));
%% The vault owns retained outer requests across incarnations. A selection
%% change can wake resolution; an unchanged unavailable owner does no work.
advance_current(S = #s{phase = unresolved}) -> S;
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
    Fence = {physics_store_retired, World, G, Token, maps:get(authority,Spec),
             maps:get(epoch,Spec), maps:get(key,Spec), {'Bytes'}, {'Signature'}},
    Retention = {{maps:get(world, Spec), physics_activation}, Fence},
    request(activate, {Activation, Store, Retention}, S).

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
outcome(activate, {error, custody_retired}, S) ->
    advance(S#s{phase = activating});
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

install(Spec,S) -> install(Spec,S,selection,[]).
install(Spec,S,rebase) -> install(Spec,S,rebase,input_targets(S)).
install(Spec = #{bodies := Bodies}, S,Mode,Targets) ->
    Limit = coordinate_limit(S),
    Restores = restoration_inputs(Spec,S),
    case quod_physics_coordinates:plan(Bodies,Restores,S#s.native_rows,
                                       S#s.frame,S#s.origin,Limit,Targets) of
        {ok,Origin,_,_,_} when Mode =/= selection, Origin =:= S#s.origin -> S;
        {ok,Origin,Delta,Native,Cache} ->
            try
                install_frame(Spec,Origin,Delta,Native,Cache,Restores,S,Mode)
            catch throw:{coordinate_error,Reason} -> block(Reason,S) end;
        {error,_} when Mode =:= rebase, Targets =/= [] -> S;
        {error,Reason} -> block(Reason,S)
    end.

%% A missing-terrain wait continues the original insertion input. Later
%% checkpoint-only updates cannot reposition an already inserted identity.
restoration_inputs(#{bodies := Bodies} = Spec,S) ->
    Fresh = [Row || Row = {Id,Rev,_,_,_} <- maps:get(restores,Spec,[]),
                    maps:get(Id,S#s.revisions,none) =/= Rev],
    Pending = [Row || Row = {Id,Rev,_,_,_} <- maps:values(S#s.restoring),
                     case lists:keyfind(Id,1,Bodies) of {Id,Rev,_,_,_,_} -> true; _ -> false end],
    lists:ukeysort(1,Fresh++Pending).

block(Reason,S) -> notify({unavailable,Reason},pause_steps(S#s{phase = {blocked,Reason}})).
coordinate_limit(#s{spec = #{limits := {_,_,_,Limit,_,_,_}}}) -> round(Limit*1000).
local_restore({Id,Rev,{Position,Q},Tolerance,Checks},Origin,Limit) ->
    {Id,Rev,{local_position(Position,Origin,Limit),Q},Tolerance,Checks}.
local_position(Position,Origin,Limit) ->
    case quod_physics_coordinates:local(Position,Origin,Limit) of
        {ok,P} -> P;
        {error,Reason} -> throw({coordinate_error,Reason})
    end.

install_frame(Spec = #{bodies := Bodies},Origin,Delta,Native,Cache,Restores,S = #s{native = Resource},Mode) ->
    Hinges = maps:get(hinges,Spec,[]),
    LocalRestores = [local_restore(Row,Origin,coordinate_limit(S)) || Row <- Restores],
    %% Checkpoints restore newly installed identities; changing one cannot
    %% rebuild or reposition a retained body/joint with the same revision.
    Geometry = {Bodies,[Row || {Row,_Restore} <- Hinges]},
    Result = case S#s.installed_geometry =:= Geometry andalso Delta =:= {0,0,0} of
        true when map_size(S#s.restoring) > 0 -> {ok,restore_pending};
        true -> {ok,0};
        false -> native(fun() ->
        case quod_physics_native:install(Resource,Delta,Native) of
            {ok,N} when is_integer(N) -> case quod_physics_native:install_hinges(Resource,Hinges) of
                {ok,J} ->
                    case quod_physics_native:restore_rest(Resource,LocalRestores) of
                        {ok,{}} -> {ok,N+J};
                        {ok,{unavailable,{terrain_coverage,Ranges}}} -> {ok,{restore_coverage,N+J,Ranges}};
                        Error -> Error end;
                Error -> Error end;
            Error -> Error
        end
        end)
    end,
    case Result of
        {ok,{unavailable,Reason}} -> block(Reason,S);
        {ok,restore_pending} ->
            installed_frame(Spec,Origin,Cache,Restores,S,Mode,Geometry,0,restore_pending);
        {ok,{restore_coverage,Changes,Ranges}} ->
            installed_frame(Spec,Origin,Cache,Restores,S,Mode,Geometry,Changes,{coverage,Ranges});
        {ok,Changes} -> installed_frame(Spec,Origin,Cache,Restores,S,Mode,Geometry,Changes,none);
        {error,Reason} -> fail(Reason,S)
    end.

installed_frame(Spec,Origin,Cache,Restores,S = #s{native = Resource},Mode,Geometry,Changes,Waiting) ->
    Bodies = maps:get(bodies,Spec),
    {ControlChanges,PhysicalControls} = install_controls(S#s{spec = Spec,installed_geometry = Geometry,
        origin = Origin,origin_sequence = S#s.origin_sequence + case Origin =/= S#s.origin of true -> 1; false -> 0 end,
        native_rows = Cache,restoring = case Waiting of
            none -> #{};
            _ -> maps:from_list([{Id,Row} || Row = {Id,_,_,_,_} <- Restores])
        end,phase = case {Waiting,S#s.phase} of
            {none,{blocked,_}} -> active;
            {none,Phase} -> Phase;
            _ -> coverage
        end,
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
                    (Changes > 0 andalso Geometry =/= S#s.installed_geometry andalso grounded_control(Control))}}

        end
    end,S#s.inputs),
    Guard = maps:get(navigation_guard,Spec),
    GuardChanged = Guard =/= S#s.installed_guard,
    Controlled = reconcile_controller(PhysicalControls#s{agent_controls = AgentControls,inputs = Inputs,installed_guard = Guard}),
    ConsumersChanged = GuardChanged orelse ControlChanged orelse Inputs =/= S#s.inputs,
    case {Waiting,Mode,Controlled#s.phase,Changes+ControlChanges,S#s.frame} of
        {restore_pending,_,_,_,_} -> Controlled;
        {{coverage,Ranges},_,_,_,_} -> hold_terrain(Ranges,Controlled);
        {none,Reframe,active,_,_} when Reframe =:= rebase; Reframe =:= step_envelope ->
            case native(fun() -> quod_physics_native:sample(Resource) end) of
                {ok,Sample} -> publish(Sample,Controlled#s{installs = S#s.installs+1});
                {error,Reason} -> fail(Reason,Controlled)
            end;
        {_,_,{failed,_},_,_} -> Controlled;
        {none,_,coverage,0,_} when ConsumersChanged -> recheck_coverage(Controlled);
        {_,_,coverage,0,_} -> Controlled;
        {none,selection,active,0,_} when element(1,S#s.phase) =:= blocked -> step_native(Controlled);
        {_,_,_,0,none} -> notify(installed,schedule({false,[],[]},publish({false,[],[]},Controlled)));
        {_,_,_,0,Frame} ->
            Updated = Controlled#s{frame = Frame#{structure => maps:get(structure,Spec)}},
            case maps:get(structure,Frame) =:= maps:get(structure,Spec) of
                true when ControlChanged; GuardChanged -> notify(installed, schedule({false,[],[]},Updated));
                true -> deliver_frame(Updated);
                false -> notify(installed,schedule({false,[],[]},deliver_frame(Updated)))
            end;
        _ ->
            Ready = Controlled#s{phase = active,installs = S#s.installs +
                case Changes > 0 of true -> 1; false -> 0 end},
            %% New collider sets need their normal broad-phase step
            %% before a retained discrete input can query them.
            notify(installed,case Changes > 0 of true -> step_native(Ready); false -> do_step(Ready) end)
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
    Desired = maps:filtermap(fun
        ({hinge,_},#{reference := {hinge,_,Revision},request := R,native_command := Command,custody := Custody}) ->
            Effective = case Custody of none -> Command; _ -> hold end,
            {true,{Revision,R,Effective}};
        (_,_) -> false
    end,Activities),
    Kept = maps:filter(fun(Key,#{request := R}) ->
        case maps:get(Key,Activities,none) of #{request := R} -> true; _ -> false end
    end,Observations),
    maps:fold(fun(Key = {hinge,D},Control = {Revision,_,Command},{Count,Acc}) ->
        Changed = maps:get(Key,Old,none) =/= Control,
        case Changed andalso (Command =/= hold orelse maps:get(D,Acc#s.driving,false)) of
            true ->
                case native(fun() -> quod_physics_native:control_hinge(Resource,D,Revision,Command) end) of
                    {ok,{}} -> {Count+1,Acc};
                    {error,Reason} -> {Count,fail(Reason,Acc)}
                end;
            false -> {Count,Acc}
        end
    end,{0,S#s{controls = Desired,observations = Kept}},Desired).

do_step(S0) -> step_native(advance_inputs(reframe(S0))).
reframe(S = #s{phase = active,frame = #{poses := Poses},spec = Spec}) ->
    Half = coordinate_limit(S)/2000,
    case input_targets(S) =/= [] orelse lists:any(fun({_,_,world,{X,Y,Z},_,_}) -> max(abs(X),max(abs(Y),abs(Z))) > Half end,Poses) of
        true -> install(Spec,S,rebase);
        false -> S
    end;
reframe(S) -> S.
input_targets(#s{inputs = Inputs}) ->
    Now = quod_time:now_ms(),
    lists:flatmap(fun
        (#{pending := true,expiry := Expiry,input := {{reposition,Pose},_}}) when Expiry > Now ->
            {world_mm,P,_} = canonical_pose(Pose),[P];
        (#{pending := true,expiry := Expiry,input := {{teleport,{vector,X,Y,Z}},_}}) when Expiry > Now -> [{X,Y,Z}];
        (_) -> []
    end,maps:values(Inputs)).

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
        {ok, {unavailable,{terrain_coverage,Ranges}}} ->
            hold_terrain(Ranges,S);
        {ok, {unavailable,{coordinate_allowance,Bounds}}} ->
            Points = lists:flatmap(fun({Low,High}) ->
                [quod_physics_coordinates:add(list_to_tuple([floor(N*1000) || N <- tuple_to_list(Low)]),S#s.origin),
                 quod_physics_coordinates:add(list_to_tuple([ceil(N*1000) || N <- tuple_to_list(High)]),S#s.origin)]
            end,Bounds),
            Next = install(S#s.spec,S,step_envelope,Points),
            case Next#s.phase of
                active when Next#s.origin =/= S#s.origin -> step_current_native(Next,Refresh);
                {failed,_} -> Next;
                {blocked,_} -> Next;
                _ -> block(coordinate_allowance,Next)
            end;
        {ok,{unavailable,Reason}} -> block(Reason,S);
        {ok, Sample} -> sample_rests(sample_hinges(schedule(Sample, publish(Sample, S#s{tick = S#s.tick + 1, steps = S#s.steps + 1, moving = element(1,Sample)}))));
        {error, Reason} -> fail(Reason, S)
    end.

request_terrain(Ranges,S) ->
    emit_terrain(S#s{terrain_mechanical = canonical_terrain_ranges(Ranges,S)}).

canonical_terrain_ranges(Ranges,S = #s{spec = Spec}) ->
    {Ox,Oy,Oz} = S#s.origin,
    lists:usort([begin
        {Id,_,_,_,{terrain,Spacing,_},_} = lists:keyfind(Id,1,maps:get(bodies,Spec)),
        Width = Spacing*8, Offset = {Ox div Width,Oy div Width,Oz div Width},
        {Id,quod_physics_coordinates:add(Low,Offset),quod_physics_coordinates:add(High,Offset)}
    end || {Id,Low,High} <- Ranges]).

%% Recompute consumers after an installed-state change or an actual step, not
%% while an unchanged proof is renewed. Empty demand after the last consumer
%% leaves is distinct from a world's initial bootstrap selection.
refresh_terrain(S = #s{native = none}) -> S;
refresh_terrain(S = #s{native = Native,spec = Spec}) ->
    case lists:any(fun({_,_,_,_,Shape,_}) -> element(1,Shape) =:= terrain end,maps:get(bodies,Spec)) of
        false -> S;
        true -> case native(fun() -> quod_physics_native:terrain_requirements(Native) end) of
            {ok,[]} when S#s.terrain_mechanical =:= initial -> emit_terrain(S);
            {ok,Ranges} -> emit_terrain(S#s{terrain_mechanical = canonical_terrain_ranges(Ranges,S)});
            {error,Reason} -> fail(Reason,S)
        end
    end.

view_regions(Centre,Requests,S = #s{spec = Spec}) ->
    Source = maps:get(voxel_resources,Spec,#{}),
    try
        Regions = lists:usort(lists:flatmap(fun({Id,Revision,{view_distance,Distance,Prefetch,Retention},[_,_,_,_,Maximum]}) ->
        {Id,Revision,fixed,_,{terrain,Spacing,_},_} = lists:keyfind(Id,1,maps:get(bodies,Spec)),
        Width = Spacing*8,
        {Low,High} = quod_physics_coordinates:chunk_box(Centre,Distance+Prefetch,Width),
        {KeepLow,KeepHigh} = quod_physics_coordinates:chunk_box(Centre,Distance+Retention,Width),
        Kept = [{Id,{X,Y,Z},{X,Y,Z}} || {B,{chunk_v1,X,Y,Z}} <- maps:keys(Source),B =:= Id,
            inside_chunk_box({X,Y,Z},KeepLow,KeepHigh),not inside_chunk_box({X,Y,Z},Low,High)],
        Requested = [{Id,Low,High}|Kept],
        Boxes = [{chunk_box,{chunk_v1,A,B,C},{chunk_v1,X,Y,Z}} || {_,{A,B,C},{X,Y,Z}} <- Requested],
        case quod_voxel:resident_chunks([],Boxes,{chunk_limits,Maximum}) of
            {ok,_} -> Requested;
            {error,_} -> throw(terrain_chunk_allowance_exceeded)
        end
        end,Requests)),
        ok = view_window(Regions,S),
        {ok,Regions}
    catch throw:Reason -> {error,Reason};
          error:_ -> {error,invalid_terrain_binding} end.

%% Validate the replacement visual window together with physical consumers
%% before asking the runtime to generate it. Absolute coordinates remain
%% unrestricted; the existing policy bounds one coherent local frame.
view_window(Visual,S = #s{spec = Spec}) ->
    Bodies = maps:get(bodies,Spec),
    Mechanical = mechanical_terrain(S),
    Ranges = case Mechanical of initial -> Visual; _ -> Mechanical++Visual end,
    Corners = lists:flatmap(fun({Id,Low,High}) ->
        {Id,_,fixed,_,{terrain,Spacing,_},_} = lists:keyfind(Id,1,Bodies),
        Width = Spacing*8,
        Min = list_to_tuple([N*Width || N <- tuple_to_list(Low)]),
        Max = list_to_tuple([(N+1)*Width || N <- tuple_to_list(High)]),
        [Min,Max]
    end,Ranges),
    Widths = [Spacing*8 || {_,_,_,_,{terrain,Spacing,_},_} <- Bodies],
    Saved = maps:from_list([{Id,P} || {Id,_,{P,_},_,_} <- restoration_inputs(Spec,S)]),
    Points = quod_physics_coordinates:body_points(Bodies,Saved,S#s.native_rows,S#s.frame,S#s.origin),
    Limit = coordinate_limit(S),
    case quod_physics_coordinates:origin(Points++Corners,Widths,S#s.origin,Limit) of
        {ok,Origin} ->
            case quod_physics_coordinates:local(Origin,S#s.origin,2*Limit) of
                {ok,_} -> ok;
                {error,Reason} -> throw(Reason)
            end;
        {error,Reason} -> throw(Reason)
    end.

inside_chunk_box(Chunk,Low,High) ->
    lists:all(fun(K) -> N = element(K,Chunk),N >= element(K,Low) andalso N =< element(K,High) end,[1,2,3]).

%% A pending collision query owns its requested coverage until that input is
%% consumed or cancelled. Preparing the collision index cannot reclaim it.
mechanical_terrain(#s{terrain_mechanical = Mechanical,inputs = Inputs}) ->
    Pending = lists:append([R || #{pending := true,terrain := R} <- maps:values(Inputs)]),
    case {Mechanical,Pending} of
        {initial,[]} -> initial;
        {initial,_} -> lists:usort(Pending);
        _ -> lists:usort(Mechanical++Pending)
    end.

emit_terrain(S = #s{owner = Owner,spec = Spec}) ->
    Mechanical = mechanical_terrain(S),
    Visual = case S#s.viewer of #{terrain_regions := Regions} -> Regions; _ -> [] end,
    Ranges = case {Mechanical,Visual} of
        {initial,[]} when S#s.terrain_sent =:= initial -> initial;
        {initial,[]} -> [];
        {initial,_} -> Visual;
        _ -> lists:usort(Mechanical++Visual)
    end,
    case Ranges =:= initial orelse Ranges =:= S#s.terrain_sent of
        true -> S;
        false ->
            Owner ! {physics_terrain_demand,self(),maps:get(world,Spec),S#s.token,
                     maps:get(structure,Spec),Ranges,terrain_focus(S#s.viewer)},
            S#s{terrain_sent = Ranges}
    end.

terrain_focus(#{terrain_centre := Centre,terrain_direction := Direction,expected := Expected}) ->
    maps:from_list([{Id,{Centre,Direction}} || {Id,_,_,_} <- maps:get(terrain,Expected,[])]);
terrain_focus(_) -> #{}.

hold_terrain(Ranges,S) ->
    %% Waiting changes neither the signed registration nor an input's original
    %% expiry. A disconnect or canonical invalidation keeps its existing rules.
    notify({unavailable,terrain_coverage},request_terrain(Ranges,pause_steps(S#s{phase = coverage}))).

hold_input_terrain(Principal,Row,Ranges,S) ->
    Pending = Row#{terrain => canonical_terrain_ranges(Ranges,S)},
    hold_terrain(Ranges,S#s{inputs = (S#s.inputs)#{Principal => Pending}}).

pause_steps(S) ->
    _ = case S#s.timer of none -> ok; Timer -> erlang:cancel_timer(Timer) end,
    S#s{timer = none}.

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
suspend_input(Row) -> cancel_input(Row,suspended).
cancel_input(Row,Result) -> (maps:remove(terrain,Row))#{expiry => 0,pending => false,result => Result}.

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
advance_input(Principal,Row = #{control := {control,_,_,{controlled_agent,_,_,Body,Revision,
                {motion,{grounded,Up},_,_,_,Limits,_},_}},
                input := Jump = {{jump,Speed},Limits},expiry := Expiry},S) ->
    Attempt = case maps:get(pending,Row) of
        false -> {maps:get(result,Row),Row};
        true ->
            case {Expiry > quod_time:now_ms(),maps:get(vertical,Row) =< 0.0,
                    lists:keyfind(Body,1,maps:get(poses,S#s.frame))} of
                {false,_,_} -> {expired,Row};
                {true,false,_} -> {no_support,Row};
                {true,true,{Body,Revision,world,Position,_,_}} ->
                    {ok,_,NativeLimits = {Skin,_,_,_}} = query_input(
                        {travel,{vector,0,0,0},{angular,0,0,0}},Limits),
                    Query = {land,Position,Skin,2*Skin,Up/1000},
                    case native(fun() -> quod_physics_native:motion_query(S#s.native,Body,Revision,Query,NativeLimits) end) of
                        {ok,{clipped,_,_,_}} -> {jumped,Row#{vertical => Speed/1000,falling => true}};
                        {ok,Answer} -> {Answer,Row};
                        {error,Reason} -> {error,Reason}
                    end;
                _ -> {unavailable,Row}
            end
    end,
    case Attempt of
        {error,Failure} -> fail(Failure,S);
        {{terrain_coverage,Ranges},Pending} -> hold_input_terrain(Principal,Pending,Ranges,S);
        {Result,Ready} -> advance_discrete(Principal,Ready,Jump,Result,Limits,S)
    end;
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
    advance_discrete(Principal,Row,Push,Result,MotionLimits,S);
advance_input(Principal,Row = #{control := {control,_,_,{controlled_agent,_,_,Body,Revision,
                {motion,Mode,_,_,_,Limits,Capabilities},_}},input := {Input,Limits},expiry := Expiry},
              S = #s{spec = Spec,native = Resource,inputs = Inputs}) ->
    Dt = maps:get(dt,Spec),
    Unexpired = Expiry > quod_time:now_ms(),
    Current = case Unexpired andalso
                   (maps:get(pending,Row) orelse element(1,Input) =:= drive) of
        true -> Input;
        false -> {drive,{vector,0,0,0},{angular,0,0,0}}
    end,
    Vertical = case Mode of {grounded,_} -> maps:get(vertical,Row)+maps:get(gravity,Spec)*Dt; free -> 0.0 end,
    {ok,_,NativeLimits} = query_input({travel,{vector,0,0,0},{angular,0,0,0}},Limits),
    Query = try movement_query(Current,Mode,Vertical,Dt,Capabilities,S#s.origin,coordinate_limit(S))
            catch throw:{coordinate_error,_} -> invalid end,
    AnswerResult = case Query of invalid -> {ok,invalid};
        _ -> native(fun() -> quod_physics_native:move_body(Resource,Body,Revision,Query,NativeLimits) end) end,
    case AnswerResult of
        {ok,{terrain_coverage,Ranges}} -> hold_input_terrain(Principal,Row,Ranges,S);
        {ok,Answer} ->
            {Usable,Supported} = motion_progress(Answer,Mode),
            Stopped = vertical_stopped(Answer,Current,Vertical,Body,S#s.frame),
            Settled = Supported orelse (Vertical < 0 andalso Stopped),
            Result = case {element(1,Input) =/= drive,maps:get(pending,Row),Unexpired} of
                {true,false,_} -> maps:get(result,Row);
                {true,true,false} -> expired;
                _ -> Answer
            end,
            RefusedDiscrete = element(1,Current) =/= drive andalso not Usable,
            ResultOrigin = case element(1,Input) =/= drive andalso not maps:get(pending,Row) of
                true -> maps:get(result_origin,Row);
                false -> S#s.origin
            end,
            Updated = (maps:remove(terrain,Row))#{pending => false,result => Result,result_origin => ResultOrigin,
                vertical => case {RefusedDiscrete,Settled orelse not Usable orelse Stopped} of
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

%% Discrete inputs share the same retained gravity and collision integration.
advance_discrete(Principal,Row,Input,Result,Limits,S) ->
    Next = advance_input(Principal,Row#{input => {{drive,{vector,0,0,0},{angular,0,0,0}},Limits},
                                       pending => false},S),
    After = maps:get(Principal,Next#s.inputs),
    Next#s{inputs = (Next#s.inputs)#{Principal => After#{input => Input,result => Result,result_origin => case maps:get(pending,Row) of true -> S#s.origin; false -> maps:get(result_origin,Row,S#s.origin) end}}}.

%% Vertical progress identifies blocked ascent/descent. Near-horizontal wall
%% normals can have either sign from floating point and cannot identify a ceiling.
%% A blocked descent settles even when a wedge is too steep for landing support.
vertical_stopped({clipped,{{_,Y,_},_},_,_},{drive,_,_},Vertical,Body,#{poses := Poses}) ->
    case lists:keyfind(Body,1,Poses) of
        {Body,_,world,{_,Before,_},_,_} ->
            (Vertical < 0 andalso Y >= Before) orelse (Vertical > 0 andalso Y =< Before);
        _ -> false
    end;
vertical_stopped(_,_,_,_,_) -> false.

movement_query({drive,{vector,X,Y,Z},{angular,Ax,Ay,Az}},Mode,Vertical,Dt,_,_,_) ->
    Vy = case Mode of free -> Y/1000; {grounded,_} -> Vertical end,
    {travel,{X/1000*Dt,Vy*Dt,Z/1000*Dt},{Ax/1000*Dt,Ay/1000*Dt,Az/1000*Dt}};
movement_query({snap,Angle},_,_,_,_,_,_) -> {travel,{0.0,0.0,0.0},{0.0,Angle/1000,0.0}};
movement_query({reposition,Pose},_,_,_,_,Origin,Limit) -> {place,local_pose(Pose,Origin,Limit)};
movement_query({teleport,{vector,X,Y,Z}},_,_,_,Capabilities,Origin,Limit) ->
    {teleport,Reach,Drop,Up} = lists:keyfind(teleport,1,Capabilities),
    {land,local_position({X,Y,Z},Origin,Limit),Reach/1000,Drop/1000,Up/1000}.
motion_progress({clear,_,_},_) -> {true,false};
motion_progress({clipped,_,Contacts,_},{grounded,Up}) ->
    {true,lists:any(fun({_,{_,Ny,_}}) -> Ny >= Up/1000 end,Contacts)};
motion_progress({clipped,_,_,_},_) -> {true,false};
motion_progress(_,_) -> {false,false}.

publish({_Active, Poses, Contacts}, S = #s{spec = Spec}) ->
    Frame = #{schema => 2, units => metres_seconds,origin => S#s.origin,origin_sequence => S#s.origin_sequence, fence => fence(Spec), structure => maps:get(structure, Spec),
              incarnation => S#s.token, tick => S#s.tick, inputs => input_feedback(S),
              poses => [{Id, maps:get(Id, S#s.revisions), world, P, Q, V} || {Id,P,Q,V} <- Poses],
              contacts => [{A,maps:get(A,S#s.revisions),B,maps:get(B,S#s.revisions)} || {A,B} <- Contacts]},
    Next = refresh_terrain(S#s{frame = Frame}),
    case Next#s.phase of {failed,_} -> Next; _ -> deliver_frame(Next) end.

input_feedback(#s{inputs = Inputs}) ->
    maps:map(fun(_,Row) -> maps:with([control,sequence,pending,result,result_origin],Row) end,Inputs).

%% One retained sample and one outstanding delivery, with no motion queue.
%% A structural/run change revokes the projection even while credit is held.
deliver_frame(S = #s{phase = Phase}) when Phase =:= coverage; element(1,Phase) =:= blocked -> S;
deliver_frame(S) ->
    case navigation_current(S) of true -> deliver_current_frame(S); false -> S end.
deliver_current_frame(S = #s{viewer = none}) -> S;
deliver_current_frame(S = #s{viewer = #{pid := Pid, ref := Ref, expected := Expected,
                               credit := Credit, tick := Previous} = V, frame = Frame}) ->
    case current_projection(Frame, Expected) of
        false -> Pid ! {physics_refresh, self(), Ref}, clear_viewer(S);
        true when Credit ->
            %% Alternate a fresh pose with resources on the same credit. A
            %% long manifest must not freeze motion, nor motion starve chunks.
            Next = case maps:get(delivery,V) of
                frame -> S;
                _ -> deliver_pose(S,Frame,Previous)
            end,
            case Next#s.viewer of
                #{credit := false} -> Next;
                _ -> deliver_resources(S,V,Expected,Frame,Previous)
            end;
        true -> S
    end.

%% Resources share the viewer's single delivery credit. The immutable snapshot
%% is retained until replaced; acknowledgements cannot release another token.
deliver_resources(S = #s{spec = Spec},V,Expected,Frame,Previous) ->
    All = maps:get(voxel_resources,Spec,#{}),
    Source = case V of
        #{terrain_regions := Regions} -> maps:filter(fun({Id,{chunk_v1,X,Y,Z}},_) ->
            lists:any(fun({B,Low,High}) -> B =:= Id andalso inside_chunk_box({X,Y,Z},Low,High) end,Regions)
        end,All);
        _ -> All
    end,
    Interest = maps:get(terrain_interest,V,0), SourceKey = {Source,Interest},
    Selected = case maps:get(terrain_demand,Spec,none) of {_,_,_,R,_} -> R; _ -> initial end,
    case {S#s.terrain_sent =/= initial andalso S#s.terrain_sent =/= Selected,
          maps:get(terrain_source,V,none) =:= SourceKey} of
        {true,_} -> deliver_pose(S,Frame,Previous);
        {false,true} -> deliver_resource_snapshot(S,V,Frame,Previous);
        {false,false} ->
            Requests = maps:get(terrain,Expected,[]),
            case terrain_snapshot(Requests,Spec,Source,terrain_focus(V)) of
                {ok,[]} when Requests =:= [] -> deliver_pose(S#s{viewer = V#{terrain_source => SourceKey}},Frame,Previous);
                {ok,Rows} ->
                    Token = crypto:strong_rand_bytes(32),
                    send_view_resource({terrain_manifest,Token,Interest,[maps:remove(payload,R) || R <- Rows]},V),
                    S#s{viewer = V#{terrain_source => SourceKey,terrain_snapshot => Rows,
                        terrain_token => Token,terrain_complete => false,terrain_wanted => [],
                        delivery => {terrain_manifest,Token},credit => false}};
                {error,Reason} ->
                    send_view_resource({terrain_unavailable,Reason},V),clear_viewer(S)
            end
    end.

deliver_resource_snapshot(S,V,Frame,Previous) ->
    case maps:get(terrain_complete,V,true) of
        true -> deliver_pose(S,Frame,Previous);
        false ->
            Token = maps:get(terrain_token,V),
            Wanted = maps:from_keys(maps:get(terrain_wanted,V),true),
            Chunks = [{I,maps:get(payload,Row)} || Row = #{index := I} <- maps:get(terrain_snapshot,V),
                                                 is_map_key(I,Wanted)],
            send_view_resource({terrain_chunks,Token,Chunks,true},V),
            S#s{viewer = V#{delivery => {terrain_chunks,Token,complete},credit => false}}
    end.

send_view_resource(Message,#{pid := Pid,ref := Ref}) ->
    Pid ! {physics_resource,self(),Ref,Message},ok.

deliver_pose(S = #s{viewer = V,frame = Frame},Frame,Previous) ->
    Tick = maps:get(tick,Frame),
    case Tick > Previous orelse S#s.origin_sequence > maps:get(origin_sequence,V) of
        true ->
            #{pid := Pid,ref := Ref,expected := Expected} = V,
            Pid ! {physics_frame,self(),Ref,view_frame(Frame,Expected)},
            S#s{viewer = V#{credit => false,tick => Tick,origin_sequence => S#s.origin_sequence,delivery => frame}};
        false -> S
    end.

terrain_snapshot(Requests,Spec,Source,Focus) ->
    try
        Bodies = maps:get(bodies,Spec),
        Rows = lists:flatmap(fun({Id,Revision,_View,Allowed}) ->
            {Id,Revision,fixed,_,{terrain,Spacing,_},_} = lists:keyfind(Id,1,Bodies),
            Chunks = quod_voxel:prioritize_chunks(lists:sort([C || {B,C} <- maps:keys(Source),B =:= Id]),
                                                 Spacing,maps:get(Id,Focus,none)),
            Selected = [#{body => Id,revision => Revision,chunk => {X,Y,Z},
                origin => {X*8*Spacing,Y*8*Spacing,Z*8*Spacing},spacing => Spacing,
                digest => maps:get(output_digest,A),payload => maps:get(payload,A),
                costs => [byte_size(maps:get(payload,A)),maps:get(triangles,A)*108,
                          maps:get(triangles,A)*3,maps:get(triangles,A),1]}
                || C = {chunk_v1,X,Y,Z} <- Chunks,A <- [maps:get({Id,C},Source)]],
            Actual = lists:foldl(fun(#{costs := C},Acc) -> lists:zipwith(fun erlang:'+'/2,C,Acc) end,
                                 [0,0,0,0,0],Selected),
            true = length(Allowed) =:= 5,
            lists:foreach(fun({Name,A,L}) ->
                true = L =:= unlimited orelse (is_integer(L) andalso L >= 0),
                case L =:= unlimited orelse A =< L of
                    true -> ok;
                    false -> throw(iolist_to_binary(io_lib:format(
                        "Terrain ~s: required ~B, allowance ~B. Reduce viewing distance.",[Name,A,L])))
                end
            end,lists:zip3(["transfer bytes","geometry bytes","vertices","triangles","chunks"],Actual,Allowed)),
            Selected
        end,Requests),
        {ok,[R#{index => I} || {R,I} <- lists:zip(Rows,lists:seq(0,length(Rows)-1))]}
    catch
        throw:Reason -> {error,Reason};
        error:_ -> {error,invalid_terrain_binding}
    end.

view_frame(Frame,Expected) ->
    Frame#{registration => maps:get(registration,Expected)}.

%% Runtime owns this incarnation-scoped invalidation generation. Reading its
%% shared token costs no mailbox round trip and cannot rebuild domain state.
navigation_current(#s{spec = #{navigation_guard := {Guard,Generation}}}) ->
    atomics:get(Guard,1) =:= Generation.

current_projection(#{fence := F, structure := R, incarnation := I},
                   #{fence := F, structure := R, incarnation := I}) -> true;
current_projection(_, _) -> false.

%% Removing a consumer can remove the query that parked the owner. Recheck
%% actual native coverage once at that dependency change, after cancellation.
%% An unfinished insertion or invalidated source still owns its original wait.
remove_viewer(S) ->
    recheck_coverage(clear_viewer(S)).

recheck_coverage(S = #s{phase = coverage,restoring = Restores}) when map_size(Restores) =:= 0 ->
    case navigation_current(S) of
        true -> notify(installed,step_native(S#s{phase = active},true));
        false -> S
    end;
recheck_coverage(S) -> S.

clear_viewer(S = #s{viewer = #{monitor := M,expected := Expected},inputs = Inputs}) ->
    demonitor(M, [flush]),
    Next = case maps:get(control,Expected,none) of
        Control = {control,Principal,_,_} ->
            case maps:get(Principal,Inputs,none) of
                Row = #{control := Control} -> Inputs#{Principal => cancel_input(Row,disconnected)};
                _ -> Inputs
            end;
        none -> Inputs
    end,
    refresh_terrain(S#s{viewer = none,inputs = Next});
clear_viewer(S) -> S.

fence(#{world := W, authority := A, epoch := E, generation := G}) -> {W, A, E, G}.
notify(installed, S = #s{phase = {failed, _}}) -> S;
notify(installed, S = #s{phase = Phase}) when Phase =:= coverage; element(1,Phase) =:= blocked -> S;
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
    {Checkpoints,Joints,ActivityRows,Bindings,Controls} = case Recovery of
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
    Hinges = [hinge(Row,Checkpoints,Native,G,S) || Row <- Joints],
    ActivityMap = maps:from_list([activity(Row,Native,Hinges) || Row <- ActivityRows]),
    true = length(ActivityRows) =:= map_size(ActivityMap),
    true = lists:sort([Id || {hinge,Id} <- maps:keys(ActivityMap)]) =:=
        lists:sort([Id || {{{Id,_},_,_,_,_,_,_},_} <- Hinges]),
    Restores = [rest_checkpoint(CP,Policy,Native,Hinges,G) || {rest,CP,Policy} <- Checkpoints],
    true = length(Restores) =:= map_size(maps:from_list([{Id,true} || {Id,_,_,_,_} <- Restores])),
    true = lists:all(fun({hinge,D,_,_,_,_,_,_}) -> maps:is_key({hinge,D},ActivityMap);
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
    {Id, Rev, Kind, canonical_pose(Pose), geometry(Shape), float(Density)}.

canonical_pose({vector,X,Y,Z}) when is_integer(X),is_integer(Y),is_integer(Z) ->
    {world_mm,{X,Y,Z},{0.0,0.0,0.0}};
canonical_pose({pose,{vector,X,Y,Z},Rotation}) when is_integer(X),is_integer(Y),is_integer(Z) ->
    {rotation,A,B,C} = Rotation,
    {world_mm,{X,Y,Z},physical_vector({vector,A,B,C})};
canonical_pose({framed,Frames,Local}) -> quod_physics_frames:pose(Frames,Local).

local_pose(Pose,Origin,Limit) ->
    {world_mm,P,R} = canonical_pose(Pose),{local_position(P,Origin,Limit),R}.

physical_pose({vector,_,_,_} = Position) -> {physical_vector(Position), {0.0,0.0,0.0}};
physical_pose({pose, Position, {rotation,X,Y,Z}}) ->
    {physical_vector(Position), physical_vector({vector,X,Y,Z})}.
physical_vector({vector,X,Y,Z}) when is_integer(X),is_integer(Y),is_integer(Z) ->
    {X/1000,Y/1000,Z/1000}.

query_input(Query,Limits) -> query_input(Query,Limits,{0,0,0},1).
query_input(Query,{query_limits,Skin,Tolerance,Slides,Checks},Origin,Coordinate)
  when is_integer(Skin),Skin > 0,is_integer(Tolerance),Tolerance >= 0,Tolerance < Skin,
       is_integer(Slides),Slides > 0,is_integer(Checks),Checks > 0 ->
    try
        Q = case Query of
            {place,Pose} -> {place,local_pose(Pose,Origin,Coordinate)};
            {landing,{vector,X,Y,Z},Reach,Drop,Up} ->
                {land,local_position({X,Y,Z},Origin,Coordinate),Reach/1000,Drop/1000,Up/1000};
            {travel,Translation,{angular,X,Y,Z}} ->
                {travel,physical_vector(Translation),physical_vector({vector,X,Y,Z})}
        end,
        {ok,Q,{Skin/1000,Tolerance/1000,Slides,Checks}}
    catch error:_ -> error; throw:{coordinate_error,_} -> error end;
query_input(_,_,_,_) -> error.

geometry({parts, Parts}) ->
    {parts, lists:map(fun({part,Pose,Shape}) -> {physical_pose(Pose), primitive(Shape)} end,Parts)};
geometry({voxel_resident_v1,Spacing,Chunks}) ->
    true = is_integer(Spacing),
    {terrain,Spacing,lists:map(fun({{vector,X,Y,Z},Handle}) ->
        true = lists:all(fun is_integer/1,[X,Y,Z]) andalso is_reference(Handle),
        {{X,Y,Z},Handle}
    end,Chunks)};
geometry({surface, Vertices, Triangles}) ->
    true = lists:all(fun({triangle,A,B,C}) ->
        lists:all(fun(X) -> is_integer(X) andalso X >= 0 andalso X < (1 bsl 32) end,[A,B,C]);
        (_) -> false end,Triangles),
    {surface, [physical_vector(V) || V <- Vertices], [{A,B,C} || {triangle,A,B,C} <- Triangles]};
geometry(Shape) -> {solid, primitive(Shape)}.

%% Resource workers admit generated selections before the live native owner
%% is touched. Use installation's accounting, including ordinary other bodies.
geometry_allowance(Bodies,{limits,_,_,_,Coordinate,{geometry,P,V,T}}) ->
    try
        Shapes = [geometry(Shape) || {body,_,_,_,_,Shape,_} <- Bodies],
        {Points,Widths} = quod_physics_coordinates:regions(Shapes),
        {ok,Origin} = case quod_physics_coordinates:origin(Points,Widths,{0,0,0},Coordinate) of
            {error,Why} -> throw({coordinate_error,Why}); Good -> Good end,
        Local = [quod_physics_coordinates:shape(Shape,Origin,Coordinate) || Shape <- Shapes],
        case quod_physics_native:geometry_cost(Local,Coordinate/1000) of
            {ok,{Parts,Vertices,Triangles}} ->
                case [{Name,Actual,Maximum} || {Name,Actual,Maximum} <-
                        [{parts,Parts,P},{vertices,Vertices,V},{triangles,Triangles,T}],
                        Actual > Maximum] of
                    [] -> ok;
                    [Exceeded|_] -> {error,{geometry_allowance,Exceeded}}
                end;
            Error -> Error
        end
    catch error:_ -> {error,invalid_physics_projection};
          throw:{coordinate_error,Reason} -> {error,Reason} end.

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

hinge({hinge,{body,D,BodyRevision},Revision,{body,Frame,FrameRevision},Axis,
             {anchors,FixedAnchor,MovingAnchor},{limits,Lower,Upper},Baseline},CPs,Bodies,G,Structure) ->
    {D,BodyRevision,dynamic,_,_,_} = lists:keyfind(D,1,Bodies),
    {Frame,FrameRevision,fixed,_,_,_} = lists:keyfind(Frame,1,Bodies),
    true = D =/= Frame andalso is_integer(Revision) andalso Revision > 0 andalso
        Revision =< Structure andalso Revision < (1 bsl 64),
    true = lists:all(fun is_integer/1,[Baseline,Lower,Upper]),
    true = Lower >= -3141 andalso Upper =< 3141 andalso Lower =< Upper andalso
        Upper-Lower =< 3141 andalso Baseline >= Lower andalso Baseline =< Upper,
    Restore = case [CP || CP = {hinge,Id,_,_,_,_,_,_} <- CPs, Id =:= D] of
        [] -> Baseline;
        [{hinge,D,Revision,{body,D,BodyRevision},{body,Frame,FrameRevision},Generation,Tick,Angle}]
          when is_integer(Generation),Generation > 0,Generation =< G,
               is_integer(Tick),Tick > 0,Tick < (1 bsl 64),
               is_integer(Angle),Angle >= Lower,Angle =< Upper -> Angle
    end,
    Direction = physical_vector(Axis), true = Direction =/= {0.0,0.0,0.0},
    {{{D,BodyRevision},Revision,{Frame,FrameRevision},Direction,
      {physical_vector(FixedAnchor),physical_vector(MovingAnchor)},
      {Lower/1000,Upper/1000},Baseline/1000},Restore/1000};
hinge(_,_,_,_,_) -> throw(unsupported_physics_profile).

activity({activity,Reference,Request,Command,Custody},Bodies,Hinges) ->
    true = quod_wire_term:is_ground({Reference,Request,Command,Custody}),
    {Key,References,NativeCommand} = case Reference of
        {hinge,D,Revision} ->
            [{{{D,DR},Revision,{F,FR},_,_,Limits,_},_}] =
                [H || H = {{{Id,_},_,_,_,_,_,_},_} <- Hinges,Id =:= D],
            true = (Request =:= none) =:= (Command =:= hold),
            {{hinge,D},[{joint,D,Revision},{body,D,DR},{body,F,FR}],joint_command(Command,Limits)};
        {rest,D,Revision} when Command =:= rest ->
            {D,Revision,dynamic,_,_,_} = lists:keyfind(D,1,Bodies),
            true = not constrained(D,Hinges),
            {{rest,D},[{body,D,Revision}],none}
    end,
    Outcome = case Custody of
        none -> none;
        {request,_,_,Bytes,Signature} ->
            {ok,#{operation_ref := {operation,_,_,Agent,Id}}} = quod_client_goal:verify(Bytes,Signature),
            {request,{Agent,Id}}
    end,
    {Key,#{reference => Reference,request => Request,command => Command,native_command => NativeCommand,
           references => References,custody => Custody,outcome_key => Outcome}}.

joint_command(hold,_) -> hold;
joint_command({position,Target,{motor,Stiff,Damp,Force},{stop,Tolerance,target_or_contact}},{Lower,Upper}) ->
    true = is_integer(Target) andalso Target/1000 >= Lower andalso Target/1000 =< Upper,
    true = lists:all(fun(V) -> is_integer(V) andalso V > 0 end,[Stiff,Damp,Force,Tolerance]),
    {position,Target/1000,{float(Stiff),float(Damp),float(Force)},{Tolerance/1000,target_or_contact}}.

constrained(D,Hinges) ->
    lists:any(fun({{{Id,_},_,{Frame,_},_,_,_,_},_}) -> Id =:= D orelse Frame =:= D end,Hinges).

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
    true = not constrained(D,Hinges),
    {vector,Px,Py,Pz} = Position, true = lists:all(fun is_integer/1,[Px,Py,Pz]),
    {D,Revision,{{Px,Py,Pz},{X/1000000,Y/1000000,Z/1000000,Q/1000000}},Tolerance/1000,Checks}.


update_observation_height(D,H,S) ->
    O = maps:get(D,S#s.observations),
    S#s{observations = (S#s.observations)#{D => O#{outcome_height => H}}}.

update_observation(Ref,Fun,S) ->
    S#s{observations = maps:map(fun(_,O = #{ref := R}) when R =:= Ref -> Fun(O);
                                 (_,O) -> O end,S#s.observations)}.

sample_hinges(S = #s{phase = active,native = Resource,spec = Spec}) ->
    case native(fun() -> quod_physics_native:hinge_samples(Resource) end) of
        {ok,Rows} ->
            Next = S#s{driving = maps:from_list([{D,Drive} || {D,_,Drive} <- Rows])},
            lists:foldl(fun({D,Angle,false},Acc) ->
                Key = {hinge,D},
                case {maps:get(Key,maps:get(activities,Spec,#{})),maps:get(Key,Acc#s.observations,none)} of
                    {#{request := R,custody := none},none} when R =/= none -> offer_joint(Key,Angle,Acc);
                    {#{request := R},#{state := resampling}} when R =/= none -> offer_joint(Key,Angle,Acc);
                    _ -> Acc
                end;
                (_,Acc) -> Acc
            end,Next,Rows);
        {error,Reason} -> fail(Reason,S)
    end;
sample_hinges(S) -> S.

offer_joint(Key = {hinge,D},Angle,S = #s{spec = Spec,frame = #{contacts := Contacts}}) ->
    #{references := [_,_,{body,Fixed,_}],
      command := {position,Target,_,{stop,Tolerance,target_or_contact}}} = maps:get(Key,maps:get(activities,Spec)),
    Partners = lists:sort([{B,BR} || {A,_,B,BR} <- Contacts,A =:= D,B =/= Fixed] ++
                          [{A,AR} || {A,AR,B,_} <- Contacts,B =:= D,A =/= Fixed]),
    Contact = case Partners of [{Other,Rev}|_] -> {contact,Other,Rev}; [] -> clear end,
    case Contact =/= clear orelse abs(Angle-Target) =< Tolerance of
        false -> notify({unavailable,{joint_held,D}},S);
        true -> offer_sample(Key,{joint_position_mrad,Angle,Contact},S)
    end.

sample_rests(S = #s{phase = active,spec = Spec}) ->
    maps:fold(fun({rest,D} = Key,#{request := R,reference := {rest,D,Revision}},Acc) when R =/= none ->
        Ready = case maps:get(Key,Acc#s.observations,none) of
            #{state := resampling} -> true;
            _ -> false
        end,
        case Ready andalso navigation_current(Acc) of
            true ->
                case native(fun() -> quod_physics_native:rest_sample(Acc#s.native,D,Revision) end) of
                    {ok,{{X,Y,Z},{Qx,Qy,Qz,Qw}}} ->
                        {A,B,C} = quod_physics_coordinates:add({X,Y,Z},Acc#s.origin),
                        Payload = {rest_pose_mm_quaternion_million,
                            {pose,{vector,A,B,C},{quaternion,Qx,Qy,Qz,Qw}}},
                        offer_sample(Key,Payload,Acc);
                    {ok,nil} -> Acc;
                    {error,Reason} -> fail(Reason,Acc)
                end;
            false -> Acc
        end;
        (_,_,Acc) -> Acc
    end,S,maps:get(activities,Spec,#{}));
sample_rests(S) -> S.

offer_sample(Key,Payload,S = #s{owner = Owner,spec = Spec}) ->
    #{reference := Resource,request := R,command := Command,references := References,custody := Prior} =
        maps:get(Key,maps:get(activities,Spec)),
    {World,Authority,Epoch,Generation} = fence(Spec),
    Frame = {physics_frame,World,Authority,Epoch,Generation,S#s.token,maps:get(structure,Spec)},
    At = quod_time:now_ms(), Budget = maps:get(budget,Spec), Expiry = At+Budget,
    Window = {Expiry,quod_time:mono_ms()+Budget},
    Sample = {physics_sample,Frame,{activity,Resource,R,Command},{revisions,References},
              S#s.tick,{validity,At,Expiry},Payload},
    Ref = make_ref(),
    Owner ! {physics_observation,self(),World,S#s.token,Ref,Sample,Window},
    O = #{request => R,state => offered,ref => Ref,sample => Sample,window => Window,
          basis => observation_basis(Key,Spec),prior => Prior},
    S#s{observations = (S#s.observations)#{Key => O}}.

observation_basis(Key,Spec) ->
    {maps:with([authority,epoch,generation,run_token,structure,budget],Spec),
     maps:with([reference,command,references],maps:get(Key,maps:get(activities,Spec)))}.

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
            case observation_basis(D,Spec) =/= Before of
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
          basis => observation_basis(D,Spec),
          kind => resolve,window => Window,
          outcome_height => maps:get(outcome_height,maps:get(D,S#s.observations,#{}),0)},
    S#s{observations = (S#s.observations)#{D => O}}.

fresh_sample({rest,_} = Key,S) ->
    #{request := R} = maps:get(Key,maps:get(activities,S#s.spec)),
    step_native(S#s{observations = (S#s.observations)#{Key => #{request => R,state => resampling}}},true);
fresh_sample(Key = {hinge,D},S = #s{native = Resource,spec = Spec}) ->
    #{request := R,reference := {hinge,D,Revision},native_command := Command} =
        maps:get(Key,maps:get(activities,Spec)),
    case native(fun() -> quod_physics_native:control_hinge(Resource,D,Revision,Command) end) of
        {ok,{}} ->
            %% A capacity/edit edge obtains a new completed-step observation;
            %% an old expiry is never extended on its retained bytes.
            do_step(S#s{observations = (S#s.observations)#{Key => #{request => R,state => resampling}}});
        {error,Reason} -> fail(Reason,S)
    end.

selection_observations(S = #s{observations = Observations}) ->
    S#s{observations = maps:map(fun(_,O = #{state := unresolved}) -> O#{state => recover};
                                 (_,O) -> O end,Observations)}.
