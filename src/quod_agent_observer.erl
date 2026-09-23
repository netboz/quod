-module(quod_agent_observer).
-moduledoc """
Scoped physical-host interests owned by an ontology runtime.

The transport owns physical episodes and certified contact retention. This
module projects the affected assignments and captures their exact epoch/round
in one immutable occurrence per host. The runtime's existing work queue drains
that occurrence through the ordinary Prolog reaction matcher.
""".
-export([new/1, project/3, handle/2, stop/1, merge/2, next/1, current/2,
         stats/1, capacity_released/2]).

new(SelfKey) ->
    TM = quod_reg:monitor_name({transport, node}, follow),
    DM = quod_reg:monitor_name({directory, node}, follow),
    #{self_key => SelfKey, hosts => #{}, instances => #{}, keys => #{}, requests => #{},
      bytes => 0, capacity => ready, refusals => 0,
      transport => quod_reg:where({transport, node}),
      capacity_transport => none,
      transport_monitor => TM, directory_monitor => DM}.

project(Scope, Rows, S) ->
    case valid_projection(Scope, Rows) of
        false -> {error, invalid_observer_projection};
        true ->
            Old = maps:get(hosts, S), Index = maps:get(instances, S),
            Keys = case Scope of
                all -> lists:usort(maps:keys(Index) ++ [I || {watch, I, _, _, _} <- Rows]);
                {keys, ScopedInstances} -> lists:usort(ScopedInstances)
            end,
            Affected = lists:usort([H || I <- Keys, {ok, H} <- [maps:find(I, Index)]] ++
                                  [H || {watch, _, H, _, _} <- Rows]),
            Trimmed = lists:foldl(fun(H, A) ->
                P = maps:get(H, A, empty_host()),
                A#{H => P#{instances => maps:without(Keys, maps:get(instances, P))}}
            end, Old, Affected),
            Bytes = maps:get(bytes, S) - lists:sum([
                watch_bytes(I, H, maps:get(I, maps:get(instances, maps:get(H, Old))))
                || I <- Keys, {ok, H} <- [maps:find(I, Index)]]),
            %% Existing identities take admission precedence. Withdrawing a
            %% replaced assignment happens first even when its new row is too
            %% large: old host/epoch subscriptions must never survive refusal.
            {Existing, Added} = lists:partition(fun({watch, I, _, _, _}) ->
                maps:is_key(I, Index)
            end, Rows),
            Base = S#{hosts => Trimmed, instances => maps:without(Keys, Index), bytes => Bytes},
            {Admitted, Refused} = lists:foldl(fun admit_watch/2, {Base, []}, Existing ++ Added),
            Hosts = maps:get(hosts, Admitted),
            Changed = [H || H <- Affected,
                not maps:is_key(H, Old) orelse
                maps:get(instances, maps:get(H, Old, empty_host())) =/=
                maps:get(instances, maps:get(H, Hosts, empty_host()))],
            Installed = release_capacity_interest(lists:foldl(
                fun(H, A) -> install_host(H, maps:is_key(H, Old), A) end, Admitted, Changed)),
            case Refused of
                [] ->
                    Status = case Scope of all -> ready; _ -> maps:get(capacity, S) end,
                    {ok, Installed#{capacity => Status}};
                _ ->
                    {blocked, capacity, Installed#{capacity => blocked,
                        refusals => maps:get(refusals, S) + length(Refused)}, lists:reverse(Refused)}
            end
    end.

admit_watch(Row = {watch, I, H, E, R}, {S = #{hosts := Hosts, instances := Index,
                                            bytes := Bytes}, Refused}) ->
    Size = watch_bytes(I, H, {E, R}),
    MaxInstances = application:get_env(quod, runtime_max_agent_observations, 4096),
    MaxBytes = application:get_env(quod, runtime_max_agent_observation_bytes, 1048576),
    case is_integer(MaxInstances) andalso MaxInstances > 0 andalso
         is_integer(MaxBytes) andalso MaxBytes > 0 andalso
         map_size(Index) < MaxInstances andalso Bytes + Size =< MaxBytes of
        true ->
            P = maps:get(H, Hosts),
            Instances = maps:get(instances, P),
            {S#{hosts => Hosts#{H => P#{instances => Instances#{I => {E, R}}}},
                instances => Index#{I => H}, bytes => Bytes + Size}, Refused};
        false -> {S, [Row | Refused]}
    end.

watch_bytes(I, H, {E, R}) -> erlang:external_size({watch, I, H, E, R}).

stats(none) -> stats(#{instances => #{}, bytes => 0, capacity => ready, refusals => 0});
stats(#{instances := Instances, bytes := Bytes, capacity := Status, refusals := Refused}) ->
    #{observed_agent_instances => map_size(Instances), agent_observation_bytes => Bytes,
      agent_observation_capacity => Status, agent_observation_refusals_total => Refused}.

capacity_released(#{capacity := blocked, instances := Before, bytes := OldBytes},
                  #{instances := After, bytes := NewBytes}) ->
    map_size(After) < map_size(Before) orelse NewBytes < OldBytes;
capacity_released(_, _) -> false.

empty_host() ->
    #{instances => #{}, contact => unknown, needed => quod_time:mono_ms(),
      delivered => none, pending => none, contact_blocked => false}.

valid_projection(Scope, Rows) when is_list(Rows) ->
    lists:all(fun
        ({watch, I, {agent_instance_ref, Ns, <<_:256>>, _} = H, E, R}) ->
            is_binary(Ns) andalso is_integer(E) andalso E > 0 andalso
            quod_wire_term:is_ground({I, H}) andalso valid_round(R) andalso
            (Scope =:= all orelse (is_tuple(Scope) andalso tuple_size(Scope) =:= 2 andalso
             element(1, Scope) =:= keys andalso is_list(element(2, Scope)) andalso
             lists:member(I, element(2, Scope))));
        (_) -> false
    end, Rows) andalso length(Rows) =:= length(lists:usort([I || {watch, I, _, _, _} <- Rows])) andalso
    (Scope =:= all orelse (is_tuple(Scope) andalso tuple_size(Scope) =:= 2 andalso
                          element(1, Scope) =:= keys andalso is_list(element(2, Scope))));
valid_projection(_, _) -> false.

valid_round(none) -> true;
valid_round({current, <<_:256>>}) -> true;
valid_round(_) -> false.

install_host(H, Existing, S = #{hosts := Hosts}) ->
    P = maps:get(H, Hosts),
    case map_size(maps:get(instances, P)) of
        0 ->
            S1 = detach_contact(H, S),
            case Existing of true -> quod_reg:unsubscribe_tracked({node_identity_route, H}); false -> ok end,
            S1#{hosts => maps:remove(H, maps:get(hosts, S1))};
        _ ->
            case Existing of false -> true = quod_reg:subscribe_tracked({node_identity_route, H}); true -> ok end,
            S1 = clear_pending(H, put_host(H, P#{needed => quod_time:mono_ms(), delivered => none}, S)),
            request_contact(H, S1)
    end.

request_contact(H = {agent_instance_ref, Ns, Anchor, _}, S = #{transport := T})
  when is_pid(T) ->
    ok = quod_directory:route_needed({Ns, Anchor}),
    S1 = subscribe_capacity(clear_pending(H, S)),
    P = maps:get(H, maps:get(hosts, S1)),
    request(quod_quic:peer_contact(T, H), H, contact, put_host(H, P#{contact_blocked => false}, S1));
request_contact(_, S) -> S.

subscribe_capacity(S = #{capacity_transport := none, transport := T}) ->
    true = quod_reg:subscribe({peer_observation_capacity, T}),
    S#{capacity_transport => T};
subscribe_capacity(S) -> S.

release_capacity_interest(S = #{capacity_transport := none}) -> S;
release_capacity_interest(S = #{hosts := Hosts, requests := Requests}) ->
    Needed = lists:any(fun(#{contact_blocked := Blocked}) -> Blocked end, maps:values(Hosts))
        orelse lists:any(fun({_, Kind, _}) -> Kind =:= contact end, maps:values(Requests)),
    case Needed of true -> S; false -> unsubscribe_capacity(S) end.

unsubscribe_capacity(S = #{capacity_transport := none}) -> S;
unsubscribe_capacity(S = #{capacity_transport := T}) ->
    true = quod_reg:unsubscribe({peer_observation_capacity, T}),
    S#{capacity_transport => none}.

request_loss(H, S = #{transport := T, hosts := Hosts}) when is_pid(T) ->
    case maps:get(H, Hosts) of
        #{contact := #{} = C, pending := none, needed := Since} ->
            request(quod_quic:confirm_peer_loss(T, C, Since), H, {loss, Since}, S);
        _ -> S
    end;
request_loss(_, S) -> S.

request(Ref, H, Kind, S = #{hosts := Hosts, requests := Requests}) ->
    Timer = erlang:start_timer(quod_time:mono_ms()+6000, self(),
                              {observer_request_expired, Ref}, [{abs, true}]),
    put_host(H, (maps:get(H, Hosts))#{pending => Ref},
             S#{requests => Requests#{Ref => {H, Kind, Timer}}}).

handle(Info, S) ->
    {Next, Events} = handle_event(Info, S),
    {release_capacity_interest(Next), Events}.

handle_event({timeout, Timer, {observer_request_expired, Ref}}, S = #{requests := Requests}) ->
    case maps:find(Ref, Requests) of
        {ok, {H, _, Timer}} -> {clear_pending(H, S), []};
        _ -> {S, []}
    end;
handle_event({Ref, Notice}, S = #{requests := Requests}) when is_reference(Ref) ->
    case maps:find(Ref, Requests) of
        {ok, {H, Kind, _}} -> snapshot(H, Kind, Notice, clear_pending(H, S));
        error -> {S, []}
    end;
handle_event({peer_loss, T, Key, _, _, _}, S = #{transport := T, keys := Keys}) ->
    {lists:foldl(fun request_loss/2, S, maps:get(Key, Keys, [])), []};
handle_event({peer_observation_capacity, T, available}, S = #{transport := T, hosts := Hosts}) ->
    Blocked = [H || {H, #{contact_blocked := true}} <- maps:to_list(Hosts)],
    {lists:foldl(fun request_contact/2, S, Blocked), []};
handle_event({node_identity_route_changed, Owner, H}, S = #{hosts := Hosts}) ->
    case maps:is_key(H, Hosts) andalso quod_reg:where({directory, node}) =:= Owner of
        true -> {request_contact(H, S), []};
        false -> {S, []}
    end;
handle_event({gproc, Change, M, _}, S = #{transport_monitor := M})
  when Change =:= registered; Change =:= unreg ->
    T = quod_reg:where({transport, node}),
    case T =:= maps:get(transport, S) of
        true -> {S, []};
        false -> refresh_all(reset_requests((unsubscribe_capacity(S))#{transport => T}))
    end;
handle_event({gproc, Change, M, _}, S = #{directory_monitor := M})
  when Change =:= registered; Change =:= unreg -> refresh_all(S);
handle_event(_, S) -> {S, []}.

refresh_all(S) ->
    {lists:foldl(fun request_contact/2, S, maps:keys(maps:get(hosts, S))), []}.

snapshot(H, contact, {peer_contact, T, H, {blocked, capacity}}, S = #{transport := T}) ->
    Detached = detach_contact(H, S),
    P = maps:get(H, maps:get(hosts, Detached)),
    {put_host(H, P#{contact_blocked => true, delivered => none}, Detached), []};
snapshot(H, contact, {peer_contact, T, H, Result}, S = #{transport := T, hosts := Hosts}) ->
    Contact = case Result of {ok, C} -> C; unknown -> unknown end,
    P = maps:get(H, Hosts),
    S1 = case Contact =:= maps:get(contact, P) of
        true -> S;
        false ->
            Detached = detach_contact(H, S),
            P1 = maps:get(H, maps:get(hosts, Detached)),
            Updated = put_host(H, P1#{contact => Contact, needed => quod_time:mono_ms(),
                                    delivered => none}, Detached),
            case Contact of
                unknown -> Updated;
                #{node_key := Key} ->
                    Keys = maps:get(keys, Updated), Interested = maps:get(Key, Keys, []),
                    case Interested of [] -> true = quod_reg:subscribe({peer_loss, Key}); _ -> ok end,
                    Updated#{keys => Keys#{Key => ordsets:add_element(H, Interested)}}
            end
    end,
    {request_loss(H, S1), []};
snapshot(H, {loss, Since}, {peer_loss, T, Key, Episode, Kind, At},
         S = #{transport := T, hosts := Hosts}) ->
    P = maps:get(H, Hosts),
    case P of
        #{contact := #{node_key := Key} = C, needed := Needed} when Since >= Needed ->
            case quod_directory:node_contact_current(C) of
                false -> {request_contact(H, S), []};
                true when Kind =:= suspected_unreachable; Kind =:= reachable ->
                    observe(H, Episode, Kind, At, S);
                true -> {S, []}
            end;
        _ -> {request_loss(H, S), []}
    end;
snapshot(H, {loss, _}, {unknown, route_unavailable}, S) -> {request_contact(H, S), []};
snapshot(_, _, _, S) -> {S, []}.

observe(H, Episode, Kind, At, S = #{hosts := Hosts, self_key := Self}) when is_integer(At) ->
    P = maps:get(H, Hosts), Token = {Episode, Kind, maps:get(needed, P)},
    case {maps:get(delivered, P) =:= Token, quod_node_actor:principal()} of
        {false, {ok, Principal}} ->
            {ok, Observer} = quod_agent_ref:materialize_principal(Principal),
            Bindings = [{I, E, R} || {I, {E, R}} <- lists:sort(maps:to_list(maps:get(instances, P))),
                                  Kind =/= reachable orelse R =/= none],
            Batch = #{host => H, self => Self, observer => Observer, episode => Episode,
                      transport => maps:get(transport, S), contact => maps:get(contact, P),
                      kind => Kind, at => At, bindings => Bindings},
            {put_host(H, P#{delivered => Token}, S), [{observed_host, Batch}]};
        _ -> {S, []}
    end;
observe(_, _, _, _, S) -> {S, []}.

%% Revalidate unsent physical evidence at admission, after any time waiting in
%% the ordinary queue. Already signed work keeps its original protocol outcome.
current(#{host := H, transport := T, contact := C}, #{transport := T, hosts := Hosts}) ->
    case maps:find(H, Hosts) of
        {ok, #{contact := C}} ->
            quod_reg:where({transport, node}) =:= T andalso is_process_alive(T) andalso
            quod_directory:node_contact_current(C);
        _ -> false
    end;
current(_, _) -> false.

%% A newer physical occurrence replaces unsent evidence, preserving the remaining
%% instances' turn before already-dispatched instances. No signed request is retried.
merge(New = #{bindings := Rows}, #{bindings := Waiting}) ->
    Current = maps:from_list([{I, Row} || Row = {I, _, _} <- Rows]),
    Pending = [maps:get(I, Current) || {I, _, _} <- Waiting, maps:is_key(I, Current)],
    Seen = maps:from_keys([I || {I, _, _} <- Pending], true),
    New#{bindings => Pending ++ [R || R = {I, _, _} <- Rows, not maps:is_key(I, Seen)]}.

next(#{bindings := []}) -> done;
next(Batch = #{host := H, self := Self, observer := Observer, episode := Episode,
               kind := Kind, at := At, bindings := [{I, E, Expected}|Rest]}) ->
    Round = case Expected of none -> Episode; {current, R} -> R end,
    {{agent_host_observed, Self, Observer, I, H, E, Expected, Round, Episode, Kind, At, At+60000},
     Batch#{bindings => Rest}}.

put_host(H, P, S = #{hosts := Hosts}) -> S#{hosts => Hosts#{H => P}}.

clear_pending(H, S = #{hosts := Hosts, requests := Requests}) ->
    P = maps:get(H, Hosts),
    case maps:take(maps:get(pending, P), Requests) of
        {{_, _, Timer}, Rest} ->
            _ = erlang:cancel_timer(Timer),
            put_host(H, P#{pending => none}, S#{requests => Rest});
        error -> S
    end.

detach_contact(H, S0) ->
    S = clear_pending(H, S0), #{hosts := Hosts, keys := Keys} = S,
    P = maps:get(H, Hosts),
    case maps:get(contact, P) of
        unknown -> S;
        #{node_key := Key} ->
            Rest = ordsets:del_element(H, maps:get(Key, Keys)),
            NextKeys = case Rest of
                [] -> true = quod_reg:unsubscribe({peer_loss, Key}), maps:remove(Key, Keys);
                _ -> Keys#{Key => Rest}
            end,
            put_host(H, P#{contact => unknown}, S#{keys => NextKeys})
    end.

reset_requests(S = #{hosts := Hosts, requests := Requests}) ->
    maps:foreach(fun(_, {_, _, Timer}) -> erlang:cancel_timer(Timer) end, Requests),
    S#{requests => #{}, hosts => maps:map(fun(_, P) -> P#{pending => none, delivered => none} end, Hosts)}.

stop(S) ->
    S1 = lists:foldl(fun(H, A) ->
        quod_reg:unsubscribe_tracked({node_identity_route, H}), detach_contact(H, A)
    end, S, maps:keys(maps:get(hosts, S))),
    _ = unsubscribe_capacity(S1),
    quod_reg:demonitor_name({transport, node}, maps:get(transport_monitor, S1)),
    quod_reg:demonitor_name({directory, node}, maps:get(directory_monitor, S1)),
    ok.
