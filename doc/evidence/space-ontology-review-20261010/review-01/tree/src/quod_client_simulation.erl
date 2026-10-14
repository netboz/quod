-module(quod_client_simulation).
-moduledoc """
One local signed simulation view. Prolog selects its marks and permission;
the existing simulation owns current poses. Browser acknowledgements release
one delivery credit, not a replay cursor. Any durable advance closes the old
projection. Reopening requires a fresh ordinary signed read.
""".
-behaviour(cowboy_websocket).
-include("quod_client_goal_limits.hrl").
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

init(Req, _) ->
    {Peer, _} = cowboy_req:peer(Req),
    {cowboy_websocket, Req, #{peer => Peer},
     #{max_frame_size => 2 * ?QUOD_CLIENT_GOAL_REQUEST_BYTES + 4096}}.
websocket_init(S) -> {ok, S}.

websocket_handle({text, Bytes}, S) ->
    case decode_command(Bytes) of
        error -> {reply, {close, 1008, <<"invalid simulation request">>}, S};
        Command -> command(Command, S)
    end;
websocket_handle(_, S) -> {ok, S}.

decode_command(Bytes) ->
    try
        case json:decode(Bytes) of
            #{<<"type">> := <<"open">>, <<"session_id">> := Session64,
              <<"request">> := Request64, <<"signature">> := Signature64,
              <<"world_namespace">> := Ns, <<"world_anchor">> := Anchor64} when is_binary(Ns) ->
                Decode = fun(B) -> base64:decode(B, #{mode => urlsafe, padding => false}) end,
                <<_:256>> = Session = Decode(Session64),
                <<_:512>> = Signature = Decode(Signature64),
                <<_:256>> = Anchor = Decode(Anchor64),
                {open, Session, Decode(Request64), Signature, Ns, Anchor};
            #{<<"type">> := <<"ack">>} = Ack -> Ack;
            _ -> error
        end
    catch error:_ -> error end.

command({open, Session, Bytes, Signature, Ns, Anchor}, S0) ->
    S = release(S0),
    case quod_client_goal:decode(Bytes) of
        {ok, #{mode := read, agent_namespace := Source, agent_genesis_anchor := SourceAnchor} = Request} ->
            case valid_view_request(Request,Ns,Anchor) andalso
                 quod_client_goal_target:available({Ns, Anchor}) =:= ok andalso
                 quod_client_goal_target:available({Source, SourceAnchor}) =:= ok of
                true ->
                    Namespaces = lists:usort([Source,Ns]),
                    [true = quod_reg:subscribe({runtime, N}) || N <- Namespaces],
                    true = quod_reg:subscribe({physics, Ns}),
                    Heights = maps:from_list([{N,quod_prolog:applied(N)} || N <- Namespaces]),
                    Owners = maps:from_list([{quod_reg:where({quod_prolog,N}),N} || N <- Namespaces]),
                    Subscribed = S#{namespace => Ns, anchor => Anchor, source => Source,
                                    heights => Heights, owners => Owners},
                    Result = quod_client_goal_ingress:submit(read, Session, Bytes, Signature, maps:get(peer, S)),
                    open_result(Result, Subscribed);
                _ -> reply(#{type => unavailable, reason => local_authority_required}, S)
            end;
        _ -> reply(#{type => unavailable, reason => invalid_view_request}, S)
    end;
command(#{<<"type">> := <<"ack">>, <<"view">> := View, <<"tick">> := Tick},
        S = #{view := View, pid := Pid, ref := Ref, tick := Tick}) ->
    quod_physics:ack(Pid, Ref, binary_to_integer(Tick)), {ok, S};
command(#{<<"type">> := <<"ack">>}, S) -> {ok, S};
command(_, S) -> {reply, {close, 1008, <<"invalid simulation command">>}, S}.

%% The endpoint accepts exactly this anchored read, not arbitrary goals which
%% could manufacture a View binding. Signature/principal admission remains in
%% the ordinary ingress. Canonical comparison is atom-safe and parser-owned.
valid_view_request(#{goal_text := Text,parser_version := Version},Ns,Anchor) ->
    Expected = {'::',Ns,{',',{current_ontology_identity,Ns,Anchor},{physics_client_view,{0}}}},
    case quod_client_goal_parser:parse(Text,Version) of
        {ok,#{goal := Goal}} ->
            quod_wire_term:encode_canonical(Goal) =:= quod_wire_term:encode_canonical(Expected);
        _ -> false
    end.

open_result({ok, #{request_digest := Digest, request := #{not_after_ms := Expiry}},
             {normalized, {answers, Height, [Binding]}}}, S) ->
    {ok, Pairs} = quod_client_result:decode_binding(Binding),
    case proplists:get_value(<<"View">>, Pairs) of
        {simulation_view, World = {world_ref, Ns, Anchor, _}, Authority,
         Epoch, Generation, Token, Structure, Marks, Control}
          when Ns =:= map_get(namespace, S), Anchor =:= map_get(anchor, S), is_list(Marks) ->
            Expected = #{fence => {World, Authority, Epoch, Generation},
                         structure => Structure, incarnation => Token,control => Control},
            case quod_reg:where({physics_world, World}) of
                Pid when is_pid(Pid) ->
                    attach(Pid, Expected, Marks, Digest, Height, Expiry, S);
                _ -> waiting(S, World, Height, Expiry)
            end;
        _ -> reply(#{type => unavailable, reason => invalid_projection}, release(S))
    end;
open_result(_, S) -> reply(#{type => unavailable, reason => view_not_authorized_or_ready}, release(S)).

attach(Pid, Expected, Marks, Digest, Height, Expiry, S) ->
    M = monitor(process, Pid),
    Result = try quod_physics:watch(Pid, Expected) catch exit:_ -> {error, unavailable} end,
    case Result of
        {ok, Ref, Frame} ->
            Watched = S#{pid => Pid, ref => Ref, monitor => M},
            case body_bindings(Marks, maps:get(control,Expected), Frame) of
                {ok, Bodies} ->
                    Remaining = Expiry - quod_time:now_ms(),
                    case Remaining > 0 andalso Height =:= maps:get(maps:get(source,S),maps:get(heights,S))
                         andalso maps:fold(fun(N,H,Valid) -> Valid andalso quod_prolog:applied(N) =:= H end,
                                           true,maps:get(heights,S)) of
                        true ->
                            Timer = erlang:start_timer(Remaining, self(), expired),
                            View = b64(Digest), Tick = decimal(maps:get(tick, Frame)),
                            Next = Watched#{view => View, tick => Tick, height => Height,
                                bodies => Bodies, control => maps:get(control,Expected),
                                world => element(1, maps:get(fence, Expected)), timer => Timer},
                            reply(#{type => projection, view => View, height => decimal(Height),expires_ms => decimal(Expiry),
                                    marks => quod_client_goal_parser:value_text(Marks),
                                    control => quod_client_goal_parser:value_text(maps:get(control,Expected)),
                                    frame => frame_json(Frame, Bodies, maps:get(control,Expected))}, Next);
                        false -> refresh(Watched, durable_gap)
                    end;
                error -> reply(#{type => unavailable, reason => invalid_body_binding}, release(Watched))
            end;
        {error, Reason} when Reason =:= view_busy; Reason =:= simulation_failed ->
            demonitor(M, [flush]), reply(#{type => unavailable, reason => Reason}, release(S));
        _ ->
            demonitor(M, [flush]), waiting(S, element(1, maps:get(fence, Expected)), Height, Expiry)
    end.

waiting(S, World, Height, Expiry) ->
    Remaining = Expiry - quod_time:now_ms(),
    case Remaining > 0 of
        true ->
            Timer = erlang:start_timer(Remaining, self(), waiting_expired),
            reply(#{type => unavailable, reason => waiting_for_installation},
                  S#{world => World, height => Height, timer => Timer});
        false -> reply(#{type => unavailable, reason => expired}, release(S))
    end.

%% The ontology's subject and the body identity remain separate. Duplicate
%% occurrences may depict one body, but every occurrence has exactly one source.
body_bindings(Marks, Control, #{poses := Poses}) ->
    try
        Available = maps:from_list([{{Id, R}, true} || {Id, R, world, _, _, _} <- Poses]),
        Rows = [{Mark, {Id, R}} || {mark, Mark, _, _, {body_pose, Id, R}, _, _,
                                  {depicts, _, <<_:256>>, _}} <- Marks],
        true = length(Rows) =:= length(Marks),
        true = map_size(maps:from_list(Rows)) =:= length(Rows),
        true = lists:all(fun({Mark, Body}) -> is_binary(Mark) andalso maps:is_key(Body, Available) end, Rows),
        Controlled = case Control of
            none -> [];
            {control,_,_,{controlled_agent,_,_,Id,Revision,_,_}} ->
                true = maps:is_key({Id,Revision},Available), [{{Id,Revision},true}]
        end,
        {ok, maps:from_list(Controlled ++ [{Body, true} || {_, Body} <- Rows])}
    catch error:_ -> error end.

websocket_info({physics_frame, Pid, Ref, Frame}, S = #{pid := Pid, ref := Ref, view := View, bodies := Bodies,control := Control}) ->
    Tick = decimal(maps:get(tick, Frame)),
    reply(#{type => simulation_frame, view => View, frame => frame_json(Frame, Bodies,Control)}, S#{tick => Tick});
websocket_info({physics_refresh, Pid, Ref}, S = #{pid := Pid, ref := Ref}) -> refresh(S, structure_changed);
websocket_info({'DOWN', M, process, _, _}, S = #{monitor := M}) -> refresh(S, owner_changed);
websocket_info({timeout, Timer, expired}, S = #{timer := Timer}) -> refresh(S, expired);
websocket_info({timeout, Timer, waiting_expired}, S = #{timer := Timer}) ->
    reply(#{type => unavailable, reason => expired}, release(S));
websocket_info({projection_advanced, Owner, Height}, S = #{owners := Owners}) ->
    durable_advance(maps:get(Owner,Owners,undefined),Height,S);
websocket_info({applied_live, #{ns := Ns,height := Height}}, S = #{heights := _}) ->
    durable_advance(Ns,Height,S);
websocket_info({replay_started, _, _}, S = #{namespace := _}) -> refresh(S, durable_gap);
websocket_info({physics_status, Runtime, Pid, World, _, Status}, S = #{world := World, namespace := Ns}) ->
    case Runtime =:= quod_reg:where({quod_runtime, Ns}) andalso
         Pid =:= quod_reg:where({physics_world, World}) andalso not maps:is_key(pid, S) of
        true -> case Status of
            installed -> refresh(S, installed);
            {failed, _} -> reply(#{type => unavailable, reason => simulation_failed}, release(S));
            _ -> {ok, S}
        end;
        false -> {ok, S}
    end;
websocket_info(_, S) -> {ok, S}.

refresh(S, Reason) -> reply(#{type => refresh, reason => Reason}, release(S)).
durable_advance(Ns,Height,S = #{heights := Heights}) ->
    case maps:find(Ns,Heights) of
        {ok,Before} when Height > Before -> refresh(S,durable_gap);
        _ -> {ok,S}
    end.

frame_json(Frame = #{fence := {World, Authority, Epoch, Generation}, structure := Structure,
             incarnation := Token, tick := Tick, poses := Poses}, Bodies,Control) ->
    #{schema => 1, units => metres_seconds, space => world,
      world => quod_client_goal_parser:value_text(World),
      authority => quod_client_goal_parser:value_text(Authority),
      epoch => decimal(Epoch), generation => decimal(Generation),
      incarnation => b64(Token), structure => decimal(Structure), tick => decimal(Tick),
      registration => b64(maps:get(registration,Frame)),
      view_clearance => maps:get(view_clearance,Frame,null),
      control_state => control_feedback(Frame,Control),
      poses => [#{body => decimal(Id), revision => decimal(R),
                  position => tuple_to_list(P), rotation => tuple_to_list(Q)}
                || {Id, R, world, P, Q, _} <- Poses, maps:is_key({Id, R}, Bodies)]}.

control_feedback(_,none) -> null;
control_feedback(Frame,Control = {control,Principal,_,_}) ->
    case maps:get(Principal,maps:get(inputs,Frame,#{}),none) of
        #{control := Control,sequence := Seq,pending := Pending,result := Result} ->
            #{sequence => decimal(Seq),pending => Pending,
              result => quod_client_goal_parser:value_text(quod_physics_predicates:motion_answer(Result))};
        #{sequence := Seq} ->
            #{sequence => decimal(Seq),pending => false,result => <<"suspended">>};
        _ -> #{sequence => <<"-1">>,pending => false,result => <<"idle">>}
    end.

reply(Message, S) ->
    Encoded = iolist_to_binary(json:encode(Message)),
    case byte_size(Encoded) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES of
        true -> {reply, {text, Encoded}, S};
        false -> {reply, {close, 1009, <<"simulation projection exceeds reply encoding limit">>}, release(S)}
    end.
decimal(N) -> integer_to_binary(N).
b64(B) -> base64:encode(B, #{mode => urlsafe, padding => false}).

release(S) ->
    case S of #{pid := Pid, ref := Ref, monitor := M} ->
        quod_physics:unwatch(Pid, Ref), demonitor(M, [flush]); _ -> ok end,
    _ = case S of #{timer := T} -> erlang:cancel_timer(T); _ -> ok end,
    case S of #{namespace := Ns,heights := Heights} ->
        [quod_reg:unsubscribe({runtime, N}) || N <- maps:keys(Heights)],
        quod_reg:unsubscribe({physics, Ns}); _ -> ok end,
    maps:with([peer], S).
terminate(_, _, S) -> _ = release(S), ok.
