-module(quod_physics).
-moduledoc """
One runtime-owned simulation incarnation. Only this process calls its native
resource. The runtime supplies committed selections; the hosted actor owns all
signed work. Frames stay here and are pulled through the runtime's current
fence, rather than flooding its event queue.
""".
-behaviour(gen_server).
-export([start/2, snapshot/2, accepts/2, projection/2, fence/1,
         watch/2, unwatch/2, ack/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-record(s, {owner, monitor, spec, token, native = none, phase = activating,
            pending = none, window = none, resolved = none, uncertain = none, timer = none, tick = 0,
            frame = none, revisions = #{}, controls = #{}, driving = #{}, observations = #{},
            installs = 0, steps = 0, queries = 0, viewer = none}).

start(Owner, Spec) ->
    gen_server:start(quod_reg:via({physics_world, maps:get(world, Spec)}), ?MODULE, {Owner, Spec}, []).
snapshot(Pid, Fence) -> gen_server:call(Pid, {snapshot, Fence}).
watch(Pid, Expected) -> gen_server:call(Pid, {watch, Expected}).
unwatch(Pid, Ref) -> Pid ! {physics_unwatch, self(), Ref}, ok.
ack(Pid, Ref, Tick) -> Pid ! {physics_ack, self(), Ref, Tick}, ok.
accepts(#{fence := Fence, structure := S, tick := Tick},
        #{fence := Fence, structure := S, tick := Previous}) -> Tick > Previous;
accepts(_, _) -> false.

init({Owner, Spec}) ->
    process_flag(trap_exit, true),
    self() ! advance,
    S = #s{owner = Owner, monitor = monitor(process, Owner), spec = Spec,
           token = crypto:strong_rand_bytes(32)},
    case quod_physics_native:available() of
        true -> {ok, notify(activating, S)};
        false -> {ok, fail({native_unavailable, quod_physics_native:load_error()}, S)}
    end.

handle_call({watch, Expected}, {Pid, _}, S = #s{phase = active, viewer = none, frame = Frame}) ->
    case current_projection(Frame, Expected) of
        true ->
            Ref = make_ref(), M = monitor(process, Pid),
            {reply, {ok, Ref, Frame}, S#s{viewer = #{pid => Pid, ref => Ref,
                monitor => M, expected => Expected, tick => maps:get(tick, Frame), credit => false}}};
        false -> {reply, {error, unavailable}, S}
    end;
handle_call({watch, _}, _, S = #s{viewer = V}) when V =/= none ->
    {reply, {error, view_busy}, S};
handle_call({watch, _}, _, S = #s{phase = {failed, _}}) ->
    {reply, {error, simulation_failed}, S};
handle_call({snapshot, Expected}, _From, S = #s{phase = active, frame = Frame}) ->
    Reply = case {accepts(Frame, Expected), Frame, Expected} of
        {true, _, _} -> {ok, Frame, counters(S)};
        {false, #{fence := F, structure := Revision, tick := Tick},
                #{fence := F, structure := Revision, tick := Tick}} ->
            {ok, unchanged, counters(S)};
        _ -> {error, unavailable}
    end,
    {reply, Reply, S#s{queries = S#s.queries + 1}};
handle_call(status, _From, S) ->
    {reply, (counters(S))#{phase => S#s.phase, incarnation => S#s.token,
        observations => maps:map(fun(_,O) -> maps:get(state,O) end,S#s.observations)}, S};
handle_call(_, _, S) -> {reply, {error, unavailable}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info({physics_ack, Pid, Ref, Tick},
            S = #s{viewer = #{pid := Pid, ref := Ref, tick := Tick, credit := false} = V}) ->
    {noreply, deliver_frame(S#s{viewer = V#{credit => true}})};
handle_info({physics_unwatch, Pid, Ref}, S = #s{viewer = #{pid := Pid, ref := Ref}}) ->
    {noreply, clear_viewer(S)};
handle_info({'DOWN', M, process, _, _}, S = #s{viewer = #{monitor := M}}) ->
    {noreply, clear_viewer(S)};
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
    Next = case {maps:get(D,maps:get(doors,Spec,#{}),none),maps:get(D,S#s.observations,none)} of
        {#{outcome_key := Key,state := {closing,R},custody := C},#{state := State} = O}
          when State =:= unresolved; State =:= resolving ->
            case Height > maps:get(outcome_height,O,0) of
                true when State =:= unresolved -> update_observation_height(D,Height,resolve_door(D,R,C,S));
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

advance(S = #s{phase = {failed, _}}) -> S;
advance(S = #s{pending = P}) when P =/= none -> S;
advance(S = #s{phase = active, spec = Spec}) -> resume_observations(install(Spec, S));
%% An uncertain custody write must not be replaced by a newly signed request
%% merely because its selection has not arrived. No timeout implies rejection.
advance(S = #s{uncertain = Issued, spec = Spec}) when Issued =/= none ->
    case activation_state(Spec) =:= Issued of
        true -> S;
        false -> advance(S#s{uncertain = none,phase = activating})
    end;
advance(S = #s{spec = #{custody := none}}) -> request_activation(S);
advance(S = #s{spec = #{custody := {request, Token, Previous, _, _} = Custody,
                         generation := G, run_token := Installed},
               token = Token, resolved = Custody}) ->
    case G =:= Previous + 1 andalso Installed =:= Token of
        true -> start_native(S);
        false -> S#s{phase = awaiting_selection}
    end;
advance(S = #s{spec = #{custody := {request, _, Previous, _, _} = Custody,
                         generation := G}, resolved = Custody}) ->
    case G > Previous of true -> request_activation(S); false -> S#s{phase = awaiting_selection} end;
advance(S = #s{spec = #{custody := {request, _, _, Bytes, Signature}}}) ->
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
    case native(fun() ->
        case quod_physics_native:install(Resource,Bodies) of
            {ok,N} -> case quod_physics_native:install_hinges(Resource,Hinges) of
                {ok,J} -> {ok,N+J}; Error -> Error end;
            Error -> Error
        end
    end) of
        {ok, Changes} ->
            {ControlChanges,Controlled} = install_controls(S#s{spec = Spec,
                revisions = maps:from_list([{Id,Rev} || {Id,Rev,_,_,_,_} <- Bodies])}),
            case {Controlled#s.phase,Changes+ControlChanges,S#s.frame} of
                {{failed,_},_,_} -> Controlled;
                {_,0,none} -> notify(installed,schedule({false,[],[]},publish({false,[],[]},Controlled)));
                {_,0,Frame} ->
                    Updated = Controlled#s{frame = Frame#{structure => maps:get(structure,Spec)}},
                    case maps:get(structure,Frame) =:= maps:get(structure,Spec) of
                        true -> Updated;
                        false -> notify(installed,deliver_frame(Updated))
                    end;
                _ -> notify(installed,do_step(Controlled#s{installs = S#s.installs +
                    case Changes > 0 of true -> 1; false -> 0 end}))
            end;
        {error,Reason} -> fail(Reason,S)
    end.

install_controls(S = #s{spec = Spec, controls = Old, native = Resource, observations = Observations}) ->
    Doors = maps:get(doors,Spec,#{}),
    Desired = maps:map(fun(D,#{state := State}) ->
        Revision = maps:get(D,S#s.revisions),
        case State of {closing,R} -> {Revision,R}; _ -> stopped end
    end,Doors),
    Kept = maps:filter(fun(D,#{request := R}) ->
        case maps:get(D,Desired,stopped) of {_,R} -> true; _ -> false end
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

do_step(S = #s{native = Resource}) ->
    case native(fun() -> quod_physics_native:step(Resource) end) of
        {ok, Sample} -> sample_doors(schedule(Sample, publish(Sample, S#s{tick = S#s.tick + 1, steps = S#s.steps + 1})));
        {error, Reason} -> fail(Reason, S)
    end.

schedule({true, _, _}, S = #s{timer = none, spec = #{dt := Dt}}) ->
    try S#s{timer = erlang:start_timer(max(1, round(Dt * 1000)), self(), step)}
    catch error:badarg -> fail(invalid_step, S) end;
schedule({false, _, _}, S) ->
    _ = case S#s.timer of none -> ok; Timer -> erlang:cancel_timer(Timer) end,
    notify(sleeping, S#s{timer = none});
schedule(_, S) -> S.

publish({_Active, Poses, Contacts}, S = #s{spec = Spec}) ->
    Frame = #{schema => 1, units => metres_seconds, fence => fence(Spec), structure => maps:get(structure, Spec),
              incarnation => S#s.token, tick => S#s.tick,
              poses => [{Id, maps:get(Id, S#s.revisions), world, P, Q, V} || {Id,P,Q,V} <- Poses],
              contacts => [{A,maps:get(A,S#s.revisions),B,maps:get(B,S#s.revisions)} || {A,B} <- Contacts]},
    deliver_frame(S#s{frame = Frame}).

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
                    Pid ! {physics_frame, self(), Ref, Frame},
                    S#s{viewer = V#{credit => false, tick => Tick}};
                false -> S
            end
    end.

current_projection(#{fence := F, structure := R, incarnation := I},
                   #{fence := F, structure := R, incarnation := I}) -> true;
current_projection(_, _) -> false.

clear_viewer(S = #s{viewer = #{monitor := M}}) ->
    demonitor(M, [flush]), S#s{viewer = none};
clear_viewer(S) -> S.

fence(#{world := W, authority := A, epoch := E, generation := G}) -> {W, A, E, G}.
notify(installed, S = #s{phase = {failed, _}}) -> S;
notify(Status, S = #s{owner = Owner, spec = Spec}) ->
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
                  {limits, B, P, C, Coord}, Step, Gravity, Bodies, Budget, Recovery}) ->
    {Checkpoints,Joints,DoorRows} = case Recovery of
        {baseline,CP,JS,DS} -> {CP,JS,DS}; _ -> throw(unsupported_physics_profile)
    end,
    true = is_integer(E) andalso E > 0 andalso is_integer(G) andalso G >= 0,
    true = valid_run(G, Token, Custody),
    true = is_integer(S) andalso S > 0 andalso is_binary(Key) andalso byte_size(Key) =:= 32,
    true = lists:all(fun(X) -> is_integer(X) andalso X >= 0 end, [B,P,C,Coord]),
    true = Coord > 0,
    true = is_integer(Step) andalso Step > 0,
    true = is_integer(Gravity),
    true = is_integer(Budget) andalso Budget > 0,
    Native = [body(Row, S) || Row <- Bodies],
    Hinges = [hinge(Row,Checkpoints,Native,G) || Row <- Joints],
    DoorMap = maps:from_list([door(Row) || Row <- DoorRows]),
    true = length(DoorRows) =:= map_size(DoorMap),
    true = lists:sort(maps:keys(DoorMap)) =:= lists:sort([Id || {{Id,_,_,_,_,_},_} <- Hinges]),
    true = lists:all(fun({hinge,D,_,_,_,_}) -> maps:is_key(D,DoorMap); (_) -> false end,Checkpoints),
    #{world => {world_ref, Ns, Anchor, W}, authority => {agent_instance_ref, Ns, Anchor, I},
      epoch => E, key => Key, generation => G, run_token => Token, custody => Custody,
      structure => S, limits => {B,P,C,Coord / 1000}, dt => Step / 1000000,
      gravity => Gravity / 1000, bodies => Native, hinges => Hinges, doors => DoorMap, budget => Budget}.
body({body, Id, Rev, Kind, {vector,X,Y,Z}, {box,Hx,Hy,Hz}, Density}, Structure) ->
    true = is_integer(Id) andalso Id >= 0 andalso Id < (1 bsl 64),
    true = is_integer(Rev) andalso Rev > 0 andalso Rev =< Structure,
    true = Kind =:= dynamic orelse Kind =:= fixed,
    true = lists:all(fun is_integer/1, [X,Y,Z,Hx,Hy,Hz,Density]),
    {Id, Rev, Kind =:= dynamic, {X/1000,Y/1000,Z/1000}, {Hx/1000,Hy/1000,Hz/1000}, float(Density)}.

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
    {D,Revision,true,_,_,_} = lists:keyfind(D,1,Bodies),
    {Frame,Revision,false,_,_,_} = lists:keyfind(Frame,1,Bodies),
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

door({door,D,Sequence,State,Custody}) when is_integer(D),is_integer(Sequence),Sequence >= 0 ->
    true = quod_wire_term:is_ground({State,Custody}),
    Key = case Custody of
        none -> none;
        {request,_,_,Bytes,Signature} ->
            {ok,#{operation_ref := {operation,_,_,Agent,Id}}} = quod_client_goal:verify(Bytes,Signature),
            {request,{Agent,Id}}
    end,
    {D,#{sequence => Sequence,state => State,custody => Custody,outcome_key => Key}}.

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
                case {maps:get(D,maps:get(doors,Spec,#{})),maps:is_key(D,Acc#s.observations)} of
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

offer_door(D,R,Angle,S = #s{owner = Owner,spec = Spec,frame = #{contacts := Contacts}}) ->
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
            {world_ref,_,_,W} = World = maps:get(world,Spec),
            Sample = {door_sample,W,D,R,maps:get(authority,Spec),maps:get(epoch,Spec),
                maps:get(generation,Spec),S#s.token,maps:get(structure,Spec),Revision,
                maps:get(Frame,S#s.revisions),S#s.tick,Angle,Contact,{validity,At,Expiry}},
            Ref = make_ref(),
            Owner ! {physics_observation,self(),World,S#s.token,Ref,Sample,Window},
            O = #{request => R,state => offered,ref => Ref,sample => Sample,window => Window,
                  basis => observation_basis(Spec),prior => maps:get(custody,maps:get(D,maps:get(doors,Spec)))},
            S#s{observations = (S#s.observations)#{D => O}}
    end.

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
                unresolved -> {unavailable,{door_observation,D,unresolved}};
                _ -> {door_observation,D,State}
            end,Updated),
            case State of
                capacity -> Next;
                committed -> Next;
                _ -> resume_observations(Next)
            end
    end.

resume_observations(S = #s{phase = active,spec = Spec}) ->
    maps:fold(fun(D,#{state := {closing,R},custody := Custody},Acc) ->
        resume_door(D,R,Custody,Acc);
        (_,_,Acc) -> Acc
    end,S,maps:get(doors,Spec,#{}));
resume_observations(S) -> S.

resume_door(D,R,Custody,S = #s{observations = Observations,spec = Spec}) ->
    case maps:get(D,Observations,none) of
        none when Custody =/= none -> resolve_door(D,R,Custody,S);
        #{state := recover} when Custody =/= none -> resolve_door(D,R,Custody,S);
        #{state := unresolved,outcome_changed := true} when Custody =/= none -> resolve_door(D,R,Custody,S);
        #{state := capacity,kind := resolve,window := {Expiry,Deadline}} = O ->
            case Expiry > quod_time:now_ms() andalso Deadline > quod_time:mono_ms() of
                true ->
                    {request,_,_,Bytes,Signature} = Custody,Ref = make_ref(),
                    S#s.owner ! {physics_work,self(),maps:get(world,Spec),Ref,resolve,{Bytes,Signature},{Expiry,Deadline}},
                    S#s{observations = Observations#{D => O#{state => resolving,ref => Ref}}};
                false -> resolve_door(D,R,Custody,S)
            end;
        #{state := capacity,sample := Sample,window := {Expiry,Deadline}} = O ->
            case Expiry > quod_time:now_ms() andalso Deadline > quod_time:mono_ms() of
                true ->
                    Ref = make_ref(),
                    S#s.owner ! {physics_observation,self(),maps:get(world,Spec),S#s.token,Ref,Sample,{Expiry,Deadline}},
                    S#s{observations = Observations#{D => O#{state => offered,ref => Ref}}};
                false -> fresh_door_sample(D,S)
            end;
        #{state := expired} -> fresh_door_sample(D,S);
        #{state := rejected} -> fresh_door_sample(D,S);
        #{state := unresolved,prior := Prior} when Custody =/= none, Custody =/= Prior -> resolve_door(D,R,Custody,S);
        #{state := State,basis := Before} when State =:= stale; State =:= held; State =:= unsent ->
            case observation_basis(Spec) =/= Before of
                true when Custody =:= none -> fresh_door_sample(D,S);
                true -> resolve_door(D,R,Custody,S);
                _ -> S
            end;
        _ -> S
    end.

resolve_door(D,R,{request,_Sample,_Result,Bytes,Signature} = Custody,S = #s{spec = Spec}) ->
    Ref = make_ref(),Budget = maps:get(budget,Spec),
    Window = {quod_time:now_ms()+Budget,quod_time:mono_ms()+Budget},
    S#s.owner ! {physics_work,self(),maps:get(world,Spec),Ref,resolve,{Bytes,Signature},Window},
    O = #{request => R,state => resolving,ref => Ref,prior => Custody,
          basis => observation_basis(Spec),
          kind => resolve,window => Window,
          outcome_height => maps:get(outcome_height,maps:get(D,S#s.observations,#{}),0)},
    S#s{observations = (S#s.observations)#{D => O}}.

fresh_door_sample(D,S = #s{native = Resource}) ->
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
