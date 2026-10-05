-module(quod_physics).
-moduledoc """
One runtime-owned simulation incarnation. Only this process calls its native
resource. The runtime supplies committed selections; the hosted actor owns all
signed work. Frames stay here and are pulled through the runtime's current
fence, rather than flooding its event queue.
""".
-behaviour(gen_server).
-export([start/2, snapshot/2, accepts/2, projection/2, fence/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-record(s, {owner, monitor, spec, token, native = none, phase = activating,
            pending = none, window = none, resolved = none, uncertain = none, timer = none, tick = 0,
            frame = none, revisions = #{}, installs = 0, steps = 0, queries = 0}).

start(Owner, Spec) ->
    gen_server:start(quod_reg:via({physics_world, maps:get(world, Spec)}), ?MODULE, {Owner, Spec}, []).
snapshot(Pid, Fence) -> gen_server:call(Pid, {snapshot, Fence}).
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
    {reply, (counters(S))#{phase => S#s.phase, incarnation => S#s.token}, S};
handle_call(_, _, S) -> {reply, {error, unavailable}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info({physics_selected, Owner, Ref, Spec}, S = #s{owner = Owner, spec = Old}) ->
    Owner ! {physics_selection_applied, self(), maps:get(world, Spec), Ref},
    ChangedRun = S#s.phase =:= active andalso fence(Old) =/= fence(Spec),
    Cancelled = maps:get(custody, Old) =/= none andalso maps:get(custody, Spec) =:= none,
    ChangedFailed = case S#s.phase of
        {failed, _} -> maps:with([bodies, structure, limits], Old) =/= maps:with([bodies, structure, limits], Spec);
        _ -> false
    end,
    case same_run(Old, Spec) andalso not ChangedRun andalso not ChangedFailed andalso not Cancelled of
        true -> {noreply, advance(S#s{spec = Spec})};
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
advance(S = #s{phase = active, spec = Spec}) -> install(Spec, S);
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
outcome(activate, {error, {activation_not_submitted, _}}, S) ->
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
        {ok, Resource} -> install(S#s.spec, S#s{native = Resource, phase = active});
        {error, Reason} -> fail(Reason, S)
    end.

install(Spec = #{bodies := Bodies}, S = #s{native = Resource}) ->
    case native(fun() -> quod_physics_native:install(Resource, Bodies) end) of
        {ok, 0} when S#s.frame =:= none ->
            notify(installed, schedule({false,[],[]}, publish({false,[],[]}, S)));
        {ok, 0} ->
            case maps:get(structure, S#s.frame) =:= maps:get(structure, Spec) of
                true -> S;
                false -> notify(installed, S#s{frame = (S#s.frame)#{structure => maps:get(structure, Spec)}})
            end;
        {ok, _} ->
            case native(fun() -> quod_physics_native:step(Resource) end) of
                {ok, Sample} -> notify(installed, schedule(Sample, publish(Sample, S#s{installs = S#s.installs + 1,
                    steps = S#s.steps + 1, tick = S#s.tick + 1, spec = Spec,
                    revisions = maps:from_list([{Id,Rev} || {Id,Rev,_,_,_,_} <- Bodies])})));
                {error, Reason} -> fail(Reason, S)
            end;
        {error, Reason} -> fail(Reason, S)
    end.

do_step(S = #s{native = Resource}) ->
    case native(fun() -> quod_physics_native:step(Resource) end) of
        {ok, Sample} -> schedule(Sample, publish(Sample, S#s{tick = S#s.tick + 1, steps = S#s.steps + 1}));
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
    S#s{frame = Frame}.

fence(#{world := W, authority := A, epoch := E, generation := G}) -> {W, A, E, G}.
notify(installed, S = #s{phase = {failed, _}}) -> S;
notify(Status, S = #s{owner = Owner, spec = Spec}) ->
    Owner ! {physics_status, self(), maps:get(world, Spec), S#s.token, Status}, S.
fail(Reason, S) ->
    retire(S),
    notify({failed, Reason}, S#s{native = none, timer = none, frame = none, phase = {failed, Reason}}).

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
    case Recovery of {baseline,[],[]} -> ok; _ -> throw(unsupported_physics_profile) end,
    true = is_integer(E) andalso E > 0 andalso is_integer(G) andalso G >= 0,
    true = valid_run(G, Token, Custody),
    true = is_integer(S) andalso S > 0 andalso is_binary(Key) andalso byte_size(Key) =:= 32,
    true = lists:all(fun(X) -> is_integer(X) andalso X >= 0 end, [B,P,C,Coord]),
    true = Coord > 0,
    true = is_integer(Step) andalso Step > 0,
    true = is_integer(Gravity),
    true = is_integer(Budget) andalso Budget > 0,
    Native = [body(Row, S) || Row <- Bodies],
    #{world => {world_ref, Ns, Anchor, W}, authority => {agent_instance_ref, Ns, Anchor, I},
      epoch => E, key => Key, generation => G, run_token => Token, custody => Custody,
      structure => S, limits => {B,P,C,Coord / 1000}, dt => Step / 1000000,
      gravity => Gravity / 1000, bodies => Native, budget => Budget}.
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
