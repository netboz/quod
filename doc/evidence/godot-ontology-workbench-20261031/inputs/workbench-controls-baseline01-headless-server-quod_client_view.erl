-module(quod_client_view).
-moduledoc """
One signed ontology view. Prolog selects its data and permission; world views
may additionally attach to the existing simulation for current poses. Browser acknowledgements release
one delivery credit, not a replay cursor. Any durable advance closes the old
projection. Reopening requires a fresh ordinary signed read.
""".
-behaviour(cowboy_websocket).
-include("quod_client_goal_limits.hrl").
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3,
         prepare_gui/8, activate_gui/5]).

%% Only the existing native preparation worker calls these local resource
%% operations. Domain policy and question state remain in the ontology proof.
prepare_gui(Agent, Connection, Request, Question, Descriptor, Capacity, Expiry, Deadline) ->
    gui_call(Agent, Connection,
        {gui_prepare, Agent, Connection, Request, Question, Descriptor, Capacity, Expiry, Deadline}, Deadline).

activate_gui(Agent, Connection, Request, Token, Deadline) ->
    case gui_call(Agent, Connection, {gui_activate, Request, Token}, Deadline) of
        {error, human_unavailable} -> {ok, expired};
        Result -> Result
    end.

gui_call(Agent, <<_:256>> = Connection, Message, Deadline)
  when is_binary(Agent), is_integer(Deadline) ->
    case quod_reg:where({client_view, {gui_hud, Agent, Connection}}) of
        undefined -> {error, human_unavailable};
        Owner ->
            %% Cowboy reserves '$gen_call' for its supervisor interface.
            %% A labelled OTP call retains monitored replies and late-reply
            %% cancellation while reaching the existing websocket owner.
            try gen:call(Owner, quod_gui_request, Message, max(0, Deadline-quod_time:mono_ms())) of
                {ok, Reply} -> Reply
            catch exit:timeout -> {error, presentation_timeout};
                  exit:_ -> {error, human_unavailable}
            end
    end;
gui_call(_, _, _, _) -> {error, invalid_presentation}.

init(Req, _) ->
    {Peer, _} = cowboy_req:peer(Req),
    {cowboy_websocket, Req, #{peer => Peer},
     #{max_frame_size => 2 * ?QUOD_CLIENT_GOAL_REQUEST_BYTES + 4096}}.
websocket_init(S) -> {ok, S}.

websocket_handle({text, Bytes}, S) ->
    case decode_command(Bytes) of
        error -> {reply, {close, 1008, <<"invalid view request">>}, S};
        Command -> command(Command, S)
    end;
websocket_handle(_, S) -> {ok, S}.

decode_command(Bytes) ->
    try
        case json:decode(Bytes) of
            #{<<"type">> := <<"open">>, <<"session_id">> := Session64,
              <<"request">> := Request64, <<"signature">> := Signature64,
              <<"view_namespace">> := Ns, <<"view_anchor">> := Anchor64,
              <<"view_kind">> := KindText} when is_binary(Ns) ->
                Decode = fun(B) -> base64:decode(B, #{mode => urlsafe, padding => false}) end,
                <<_:256>> = Session = Decode(Session64),
                <<_:512>> = Signature = Decode(Signature64),
                <<_:256>> = Anchor = Decode(Anchor64),
                Kind = case KindText of <<"world">> -> world; <<"gui_hud">> -> gui_hud;
                         <<"navigation">> -> navigation;
                         <<"gui_question">> -> gui_question; <<"gui_operations">> -> gui_operations;
                         <<"source_access">> -> source_access;
                         <<"eidolons">> -> eidolons; <<"eidolon">> -> eidolon;
                         <<"eidolon_scene">> -> eidolon_scene;
                         <<"controller_preferences">> -> controller_preferences end,
                {open, Session, Decode(Request64), Signature, Ns, Anchor, Kind};
            #{<<"type">> := <<"gui_prepared">>, <<"token">> := Token64,
              <<"accepted">> := Accepted} when is_boolean(Accepted) ->
                <<_:256>> = Token = base64:decode(Token64, #{mode => urlsafe, padding => false}),
                {gui_prepared, Token, Accepted};
            #{<<"type">> := <<"gui_activated">>, <<"token">> := Token64,
              <<"status">> := Status} when Status =:= <<"active">>; Status =:= <<"expired">> ->
                <<_:256>> = Token = base64:decode(Token64, #{mode => urlsafe, padding => false}),
                {gui_activated, Token, Status};
            #{<<"type">> := <<"terrain_ack">>,<<"view">> := View,<<"token">> := Token64} = Ack ->
                <<_:256>> = Token = base64:decode(Token64,#{mode => urlsafe,padding => false}),
                Value = case Ack of
                    #{<<"want">> := Ids} when is_list(Ids) -> {want,Ids};
                    #{<<"through">> := Index} when is_integer(Index),Index >= 0 -> {through,Index};
                    #{<<"complete">> := true} -> complete
                end,
                {terrain_ack,View,Token,Value};
            #{<<"type">> := <<"terrain_interest">>,<<"view">> := View,
              <<"sequence">> := Sequence,<<"centre_mm">> := Centre} ->
                [X,Y,Z] = [begin N = binary_to_integer(B), B = integer_to_binary(N), N end || B <- Centre],
                Seq = binary_to_integer(Sequence), Sequence = integer_to_binary(Seq),
                true = Seq > 0 andalso Seq < (1 bsl 64),
                {terrain_interest,View,Seq,{X,Y,Z}};
            #{<<"type">> := <<"ack">>} = Ack -> Ack;
            #{<<"type">> := <<"close">>} -> close_view;
            _ -> error
        end
    catch error:_ -> error end.

command({terrain_interest,View,Sequence,Centre},S = #{view := View,pid := Pid,ref := Ref,expires := Expiry}) ->
    case Expiry > quod_time:now_ms() of
        true -> quod_physics:view_interest(Pid,Ref,Sequence,Centre),{ok,S};
        false -> reply(#{type => unavailable,reason => expired},release(S))
    end;
command({terrain_interest,_,_,_},S) -> {ok,S};
command({terrain_ack,View,Token,Ack},S = #{view := View,pid := Pid,ref := Ref,expires := Expiry}) ->
    case Expiry > quod_time:now_ms() of
        true -> quod_physics:resource_ack(Pid,Ref,Token,Ack),{ok,S};
        false -> reply(#{type => unavailable,reason => expired},release(S))
    end;
command({terrain_ack,_,_,_},S) -> {ok,S};
command({gui_prepared, Token, Accepted}, S) -> gui_prepared(Token, Accepted, S);
command({gui_activated, Token, Status}, S) -> gui_activated(Token, Status, S);
command({open, Session, Bytes, Signature, Ns, Anchor, Kind}, S) ->
    open_request(Session,Bytes,Signature,Ns,Anchor,Kind,S);
command(close_view,S) -> {ok,release(S)};
command(#{<<"type">> := <<"ack">>, <<"view">> := View, <<"tick">> := Tick,<<"origin_seq">> := OriginSequence},
        S = #{view := View, pid := Pid, ref := Ref, tick := Tick,origin_sequence := OriginSequence}) ->
    quod_physics:ack(Pid, Ref, binary_to_integer(Tick),binary_to_integer(OriginSequence)), {ok, S};
command(#{<<"type">> := <<"ack">>}, S) -> {ok, S};
command(_, S) -> {reply, {close, 1008, <<"invalid view command">>}, S}.

open_request(Session,Bytes,Signature,Ns,Anchor,Kind,S) ->
    case quod_client_goal:decode(Bytes) of
        {ok, #{mode := read, agent_namespace := Source, agent_genesis_anchor := SourceAnchor,
               not_after_ms := Expiry} = Request} ->
            case {view_request(Kind,Request,Ns,Anchor),Expiry - quod_time:now_ms()} of
                {{ok,Instance,Dependencies},Remaining} when Remaining > 0 ->
                    Scope = {Kind,Session,Ns,Anchor,maps:without([operation_id,not_after_ms],Request)},
                    Renew = maps:get(installed,S,false) andalso
                        maps:get(request_scope,S,none) =:= Scope andalso
                        maps:get(expires,S,0) > quod_time:now_ms() andalso
                        not maps:is_key(opening,S) andalso not maps:is_key(candidate_timer,S) andalso
                        dependencies_ready(S) andalso dependency_owners_current(S),
                    Next = case Renew of true -> S; false -> release(S) end,
                    case Renew orelse not (maps:is_key(follow_requests,Next) orelse maps:is_key(opening,Next)) of
                        true -> open_worker(Session,Bytes,Signature,Expiry,
                            Next#{kind => Kind,namespace => Ns,anchor => Anchor,source => Source,
                                source_anchor => SourceAnchor,instance => Instance,
                                request_scope => Scope,expected_dependencies => Dependencies});
                        false -> reply(#{type => unavailable,reason => dependency_recovering},
                                       Next#{awaiting_cleanup => true})
                    end;
                _ -> reply(#{type => unavailable, reason => invalid_view_request}, release(S))
            end;
        _ -> reply(#{type => unavailable, reason => invalid_view_request}, release(S))
    end.

open_worker(Session,Bytes,Signature,Expiry,S = #{namespace := Ns}) ->
    %% Reject a deadline outside the VM timer representation before allocating
    %% an opening worker. Ingress still owns signature/session admission.
    TimerResult = try {ok,erlang:start_timer(Expiry-quod_time:now_ms(),self(),expired)}
                  catch error:badarg -> error end,
    case TimerResult of
        {ok,Timer} ->
            Timed = case maps:get(installed,S,false) of
                true -> S#{candidate_timer => Timer};
                false ->
                    case maps:get(kind,S) of
                        K when K =:= world; K =:= eidolon_scene -> true = quod_reg:subscribe({physics,Ns});
                        _ -> ok
                    end,
                    S#{timer => Timer}
            end,
            Owner = self(), Ref = make_ref(), Peer = maps:get(peer,S),
            {Pid,M} = spawn_monitor(fun() ->
                receive {open,Ref} ->
                    Result = quod_client_goal_ingress:submit(read,Session,Bytes,Signature,Peer),
                    Owner ! {view_opened,Ref,Result}
                end
            end),
            _ = quod_process:kill_when_owner_dies(Owner,Pid),
            Pid ! {open,Ref},
            {ok,Timed#{opening => {Ref,Pid,M}}};
        error -> reply(#{type => unavailable,reason => invalid_view_deadline},release(S))
    end.

%% The endpoint accepts exactly this anchored read, not arbitrary goals which
%% could manufacture a View binding. Signature/principal admission remains in
%% the ordinary ingress. Canonical comparison is atom-safe and parser-owned.
view_request(world,#{goal_text := Text,parser_version := Version},Ns,Anchor) ->
    case quod_client_goal_parser:parse(Text,Version) of
        {ok,#{goal := {_,Ns,{_,{_,Ns,Anchor},
                    {_,Instance,Mode,Rows,{0}}}} = Goal,variables := [{<<"View">>,0}]}}
          when is_list(Rows) ->
            Dependencies = [{N,A,H} || {_,N,A,H} <- Rows],
            Expected = {'::',Ns,{',',{current_ontology_identity,Ns,Anchor},
                {client_world_view,Instance,Mode,[{dependency,N,A,H} || {N,A,H} <- Dependencies],{0}}}},
            case quod_wire_term:is_ground(Instance) andalso quod_wire_term:is_symbol(Mode)
                 andalso length(Dependencies) =:= length(Rows)
                 andalso quod_wire_term:encode_canonical(Goal) =:= quod_wire_term:encode_canonical(Expected)
                 andalso element(1,quod_client_result:encode({read,Dependencies,fail})) =:= ok of
                true -> {ok,Instance,Dependencies};
                false -> error
            end;
        _ -> error
    end;
view_request(Kind,#{goal_text := Text,parser_version := Version},Ns,Anchor) ->
    case quod_client_goal_parser:parse(Text,Version) of
        {ok,#{goal := {_,Ns,{_,{_,Ns,Anchor},Inner}} = Goal,variables := [{<<"View">>,0}]}} ->
            case gui_view_goal(Kind,Inner) of
                {ok,Subject,Read} ->
                    Expected = {'::',Ns,{',',{current_ontology_identity,Ns,Anchor},Read}},
                    case quod_wire_term:encode_canonical(Goal) =:= quod_wire_term:encode_canonical(Expected) of
                        true -> {ok,Subject,[]};
                        false -> error
                    end;
                error -> error
            end;
        _ -> error
    end.

gui_view_goal(gui_hud,{_,{0}}) ->
    {ok,hud,{gui_pending_questions,{0}}};
gui_view_goal(navigation,{_,{0}}) ->
    {ok,navigation,{account_navigation,{0}}};
gui_view_goal(gui_question,{_,Question,{0}}) ->
    case quod_wire_term:is_ground(Question) of
        true -> {ok,Question,{gui_question_form,Question,{0}}};
        false -> error
    end;
gui_view_goal(gui_operations,{_,Subject,{0}}) ->
    case quod_wire_term:is_ground(Subject) of
        true -> {ok,Subject,{gui_operations,Subject,{0}}};
        false -> error
    end;
gui_view_goal(controller_preferences,{_,Human,{0}}) ->
    case quod_wire_term:is_ground(Human) of
        true -> {ok,Human,{controller_preferences_view,Human,{0}}};
        false -> error
    end;
gui_view_goal(source_access,{_,Target = {_,Ns,Anchor},_,{0}})
  when is_binary(Ns), byte_size(Ns) > 0, byte_size(Ns) =< 255,
       is_binary(Anchor), byte_size(Anchor) =:= 32 ->
    case quod_wire_term:encode_canonical(Target) =:=
         quod_wire_term:encode_canonical({ontology_ref,Ns,Anchor}) of
        true -> {ok,Target,{prolog_inspect,Target,presentation,{0}}};
        false -> error
    end;
gui_view_goal(eidolons,{_,Entity,{0}}) ->
    case quod_wire_term:is_ground(Entity) of
        true -> {ok,Entity,{entity_eidolons,Entity,{0}}};
        false -> error
    end;
gui_view_goal(Kind,{_,Entity,Choice,{0}}) when Kind =:= eidolon; Kind =:= eidolon_scene ->
    case quod_wire_term:is_ground({Entity,Choice}) of
        true -> {ok,Entity,{client_eidolon,Entity,Choice,{0}}};
        false -> error
    end;
gui_view_goal(_,_) -> error.

open_result({ok, #{request_digest := Digest, request := #{not_after_ms := Expiry}} = Evidence,
             {normalized, {read, Dependencies, Outcome}}}, S) ->
    case Outcome of
        {error, _} -> reply(#{type => unavailable, reason => proof_unavailable}, release(S));
        _ ->
            Remaining = Expiry - quod_time:now_ms(),
            Expected = maps:get(expected_dependencies,S),
            Matches = lists:all(fun(D) -> lists:member(D,Dependencies) end,Expected),
            case {Remaining > 0,Matches,lists:keyfind(maps:get(source,S),1,Dependencies)} of
                {true,true,{_, SourceAnchor, _}} when SourceAnchor =:= map_get(source_anchor,S) ->
                    Agent = maps:get(agent_ref_blob,Evidence,none),
                    Bound = case maps:get(receiver_seed,S,none) of
                        {Agent,_,_} -> S;
                        none -> S;
                        _ -> discard_gui_resources(S)
                    end,
                    install_dependencies(Dependencies,{Digest,Expiry,Outcome},
                        Bound#{authenticated_agent => Agent});
                {false,_,_} -> reply(#{type => unavailable, reason => expired}, release(S));
                {true,false,_} -> refresh(S,navigation_changed);
                _ -> reply(#{type => unavailable, reason => invalid_dependencies}, release(S))
            end
    end;
open_result(_, S) -> reply(#{type => unavailable, reason => view_not_authorized_or_ready}, release(S)).

%% A fresh proof may replace an unchanged view without retiring its consumer.
%% Actual dependency changes still take the ordinary invalidation/read path.
install_dependencies(Dependencies,Pending,S = #{candidate_timer := _}) ->
    Retained = view_dependencies(S),
    case lists:sort(Dependencies) =:= Retained andalso dependencies_ready(S)
         andalso dependency_owners_current(S) of
        true -> snapshot_dependencies(S#{pending => Pending});
        false -> refresh(S,durable_gap)
    end;
install_dependencies(Dependencies,Pending,S) ->
    Next = S#{pending => Pending,heights => #{},owners => #{},anchors => #{},follows => #{},
        dependency_monitors => #{},dependency_names => #{},follow_requests => gen_server:reqids_new(),
        local_ready => #{},snapshots => gen_server:reqids_new()},
    case follow_dependencies(Dependencies,Next) of
        {ok,Followed} -> snapshot_dependencies(Followed);
        {error,Followed} -> reply(#{type => unavailable,reason => dependency_unavailable},release(Followed))
    end.

view_dependencies(S) ->
    lists:sort([{Ns,maps:get(Ns,maps:get(anchors,S)),H} ||
        {Ns,H} <- maps:to_list(maps:get(heights,S))] ++
        [{Ns,Anchor,H} || {Ns,Anchor,H,_} <- maps:values(maps:get(follows,S))]).

dependency_owners_current(S) ->
    Owners = maps:get(owners,S),
    maps:fold(fun(Pid,Ns,Ready) -> Ready andalso quod_reg:where({quod_prolog,Ns}) =:= Pid
        andalso quod_simplex:genesis_hash(Ns) =:= maps:get(Ns,maps:get(anchors,S)) end,true,Owners)
    andalso lists:all(fun(Pid) -> maps:is_key(Pid,Owners) orelse
        Pid =:= quod_reg:where({foreign_log,node}) end,maps:values(maps:get(dependency_monitors,S))).

%% Register every dependency before taking any current snapshot. These are
%% the scopes actually opened by the proof, including failed alternatives.
follow_dependencies([], S) -> {ok, S};
follow_dependencies([{Ns, Anchor, Height} | Rest], S) ->
    case {quod_simplex:genesis_hash(Ns),quod_reg:where({quod_prolog,Ns})} of
        {Other,_} when is_binary(Other), Other =/= Anchor -> {error,S};
        {Anchor,Pid} when is_pid(Pid) ->
            true = quod_reg:subscribe({runtime,Ns}),
            M = monitor(process,Pid),
            follow_dependencies(Rest, S#{
                heights := (maps:get(heights,S))#{Ns => Height},
                anchors := (maps:get(anchors,S))#{Ns => Anchor},
                owners := (maps:get(owners,S))#{Pid => Ns},
                local_ready := (maps:get(local_ready,S))#{Ns => false},
                dependency_monitors := (maps:get(dependency_monitors,S))#{M => Pid}});
        {KnownAnchor,undefined} ->
            case {KnownAnchor,quod_reg:where({quod_ns,Ns})} of
                {undefined,undefined} -> follow_foreign_dependency(Ns,Anchor,Height,Rest,S);
                _ ->
                    true = quod_reg:subscribe({runtime,Ns}),
                    M = quod_reg:monitor_name({quod_prolog,Ns},follow),
                    follow_dependencies(Rest,S#{
                        heights := (maps:get(heights,S))#{Ns => Height},
                        anchors := (maps:get(anchors,S))#{Ns => Anchor},
                        local_ready := (maps:get(local_ready,S))#{Ns => false},
                        dependency_names := (maps:get(dependency_names,S))#{M => Ns}})
            end;
        _ -> {error,S}
    end.

follow_foreign_dependency(Ns,Anchor,Height,Rest,S) ->
    case quod_reg:where({foreign_log,node}) of
        Pid when is_pid(Pid) ->
            M = monitor(process,Pid),
            Bound = S#{dependency_monitors :=
                (maps:get(dependency_monitors,S))#{M => Pid}},
            case quod_foreign_log:follow_request({Ns,Anchor},progress) of
                {ok, Request} ->
                    Followed = Bound#{follow_requests := gen_server:reqids_add(
                        Request,{Pid,Ns,Anchor,Height},maps:get(follow_requests,S))},
                    follow_dependencies(Rest,Followed);
                {error, _} -> {error,Bound}
            end;
        undefined -> {error,S}
    end.

%% One asynchronous snapshot per exact engine, after all subscriptions exist.
%% A busy engine cannot turn a statistics timeout into a fresh-proof loop.
snapshot_dependencies(S) ->
    case gen_server:reqids_size(maps:get(follow_requests,S)) of
        0 ->
            Requests = maps:fold(fun(Pid,Ns,Acc) ->
                gen_server:send_request(Pid,get_stats,{Pid,Ns},Acc)
            end,maps:get(snapshots,S),maps:get(owners,S)),
            resume_projection(S#{snapshots := Requests});
        _ -> {ok,S}
    end.

%% Keep pending registrations until their reply even after view cancellation:
%% only then is the owner-issued reference known and can be released. At most
%% one opening batch is retained; a new open waits for this cleanup notice.
follow_response(Message,S = #{follow_requests := Requests}) ->
    case gen_server:check_response(Message,Requests,true) of
        {Reply,{Pid,Ns,Anchor,Height},Remaining} ->
            Next = S#{follow_requests := Remaining},
            case {maps:is_key(pending,S),Reply,quod_reg:where({foreign_log,node})} of
                {true,{reply,{ok,Ref}},Pid} ->
                    snapshot_dependencies(Next#{follows :=
                        (maps:get(follows,S))#{Ref => {Ns,Anchor,Height,false}}});
                {Active,_,_} ->
                    case Reply of {reply,{ok,Ref}} -> unfollow(Ref); _ -> ok end,
                    case Active of
                        true -> reply(#{type => unavailable,reason => dependency_unavailable},release(Next));
                        false -> finish_follow_cleanup(Next)
                    end
            end;
        _ -> snapshot_response(Message,S)
    end;
follow_response(Message,S) -> snapshot_response(Message,S).

finish_follow_cleanup(S = #{follow_requests := Requests}) ->
    case gen_server:reqids_size(Requests) of
        0 ->
            finish_cleanup(maps:remove(follow_requests,S));
        _ -> {ok,S}
    end.

finish_cleanup(S) ->
    case maps:get(awaiting_cleanup,S,false) andalso
         not maps:is_key(opening,S) andalso not maps:is_key(follow_requests,S) of
        true -> refresh(S,dependency_recovered);
        false -> {ok,S}
    end.

unfollow(Ref) ->
    case quod_foreign_log:unfollow_request(Ref) of
        {ok, Request} -> _ = gen_server:receive_response(Request,0), ok;
        {error,_} -> ok
    end.

snapshot_response(Message,S = #{snapshots := Requests}) ->
    case gen_server:check_response(Message,Requests,true) of
        {{reply,#{applied := Height,readiness := Readiness}},{Pid,Ns},Remaining} ->
            Next = S#{snapshots := Remaining},
            case quod_reg:where({quod_prolog,Ns}) =:= Pid andalso
                 quod_simplex:genesis_hash(Ns) =:= maps:get(Ns,maps:get(anchors,S)) of
                true ->
                    case Readiness of
                        ready -> dependency_height(Ns,Height,Next);
                        {recovering,Recovery} -> dependency_recovering(Recovery,Next)
                    end;
                false -> refresh(Next,dependency_owner_changed)
            end;
        {{error,_},_,Remaining} -> refresh(S#{snapshots := Remaining},dependency_owner_changed);
        _ -> {ok,S}
    end;
snapshot_response(_,S) -> {ok,S}.

resume_projection(S = #{pending := {Digest, Expiry, Outcome}}) ->
    case {Expiry > quod_time:now_ms() andalso candidate_live(S),dependencies_ready(S)} of
        {false,_} -> reply(#{type => unavailable,reason => expired},release(S));
        {true,true} -> open_view(Outcome,Digest,Expiry,maps:remove(pending,S));
        {true,false} -> {ok,S}
    end;
resume_projection(S) -> {ok,S}.

dependencies_ready(S) ->
    gen_server:reqids_size(maps:get(follow_requests,S)) =:= 0 andalso
    gen_server:reqids_size(maps:get(snapshots,S)) =:= 0 andalso
    lists:all(fun(R) -> R =:= true end,maps:values(maps:get(local_ready,S))) andalso
    lists:all(fun({_,_,_,R}) -> R end,maps:values(maps:get(follows,S))).

open_view({answers, Height, [Binding]}, Digest, Expiry, S = #{kind := eidolon_scene}) ->
    {ok, Pairs} = quod_client_result:decode_binding(Binding),
    case proplists:get_value(<<"View">>,Pairs,missing) of
        {eidolon_scene,{entity_ref,Ns,A,Entity},Marks,Selection,Exposures}
          when Ns =:= map_get(namespace,S), A =:= map_get(anchor,S),
               is_list(Marks), is_list(Exposures) ->
            open_subject(Entity,Selection,Marks,Digest,Height,Expiry,S#{exposures => Exposures});
        _ -> reply(#{type => unavailable,reason => invalid_projection},release(S))
    end;
open_view({answers, Height, [Binding]}, Digest, Expiry, S = #{kind := Kind})
  when Kind =:= gui_hud; Kind =:= gui_question; Kind =:= gui_operations;
       Kind =:= controller_preferences; Kind =:= source_access; Kind =:= navigation; Kind =:= eidolons; Kind =:= eidolon ->
    {ok, Pairs} = quod_client_result:decode_binding(Binding),
    case proplists:get_value(<<"View">>, Pairs, missing) of
        missing -> reply(#{type => unavailable, reason => invalid_projection},release(S));
        View -> open_value(View,Height,Digest,Expiry,S)
    end;
open_view({answers, Height, [Binding]}, Digest, Expiry, S) ->
    {ok, Pairs} = quod_client_result:decode_binding(Binding),
    case proplists:get_value(<<"View">>, Pairs) of
        {world_view,{entity_ref,Ns,Anchor,Instance},Marks,Selection}
          when Ns =:= map_get(namespace,S), Anchor =:= map_get(anchor,S),is_list(Marks) ->
            open_subject(Instance,Selection,Marks,Digest,Height,Expiry,S);
        _ -> reply(#{type => unavailable, reason => invalid_projection}, release(S))
    end;
open_view(_, _, _, S) ->
    reply(#{type => unavailable, reason => view_not_authorized_or_ready}, release(S)).

open_subject(Instance,Selection,Marks,Digest,Height,Expiry,S) ->
    case quod_wire_term:encode_canonical(Instance) =:=
         quod_wire_term:encode_canonical(maps:get(instance,S)) of
        true -> open_selection(Selection,Marks,Digest,Height,Expiry,S#{instance := Instance});
        false -> reply(#{type => unavailable,reason => invalid_projection},release(S))
    end.

open_value(View,Height,Digest,Expiry,S = #{kind := Kind}) ->
    Next = projection_deadline(S,Expiry),
    case view_receiver(Kind,Next) of
        {ok,Receiver,Registered} ->
            reply(maps:merge(#{type => projection,kind => Kind,view => b64(Digest),height => decimal(Height),
                expires_ms => decimal(Expiry),value => quod_client_goal_parser:value_text(View),
                dependencies => quod_client_goal_parser:value_text(
                    [{dependency,N,A,H} || {N,A,H} <- view_dependencies(Next)])},Receiver),
                retire_gui_presentations(Kind,View,Registered#{installed => true}));
        {error,Reason} -> reply(#{type => unavailable,reason => Reason},release(Next))
    end.

%% The signed read identifies the human; its session token alone does not.
%% This is a process address, not a presence fact or a pending-question list.
%% Refresh retains the socket incarnation and any accepted native receipts.
view_receiver(gui_hud, S = #{source := Ns,namespace := Ns,source_anchor := Anchor,
                             anchor := Anchor,authenticated_agent := Agent}) when is_binary(Agent) ->
    case application:get_env(quod,node_pubkey) of
        {ok,<<_:256>> = Node} ->
            Token = case maps:get(receiver_seed,S,none) of
                {Agent,Node,Previous} -> Previous;
                _ -> crypto:strong_rand_bytes(32)
            end,
            Key = {client_view,{gui_hud,Agent,Token}},
            case quod_reg:where(Key) of
                Pid when Pid =:= self() -> ok;
                undefined -> true = quod_reg:reg(Key)
            end,
            {ok,#{receiver => #{node => b64(Node),token => b64(Token)}},
                S#{receiver_seed => {Agent,Node,Token},receiver_key => Key}};
        _ -> {error,node_identity_unavailable}
    end;
view_receiver(gui_hud,_) -> {error,invalid_receiver_identity};
view_receiver(_,S) -> {ok,#{},S}.

open_selection({simulation_view,World = {world_ref,_,_,_},Authority,
                Epoch,Generation,Token,Structure,Control,
                ViewFrame = {view_frame,{entity_ref,Ns,Anchor,Instance},Frames,BodyFrames}},Marks,Digest,Height,Expiry,S)
  when Ns =:= map_get(namespace,S), Anchor =:= map_get(anchor,S),
       Instance =:= map_get(instance,S), is_list(Frames), is_list(BodyFrames) ->
            Expected = #{fence => {World, Authority, Epoch, Generation},
                         structure => Structure, incarnation => Token,control => Control,
                         terrain => terrain_bindings(Marks),view_frame => ViewFrame},
            case quod_reg:where({physics_world, World}) of
                Pid when is_pid(Pid) ->
                    attach(Pid, Expected, Marks, Digest, Height, Expiry, S);
                _ -> waiting(projection_deadline(detach(S),Expiry),World)
            end;
open_selection(Selection,Marks,Digest,Height,Expiry,S)
  when Selection =:= nonphysical; Selection =:= disabled; Selection =:= denied;
       Selection =:= recovering; Selection =:= unavailable ->
    Next = projection_deadline(detach(S),Expiry),
    reply(#{type => projection,view => b64(Digest),height => decimal(Height),
            expires_ms => decimal(Expiry),selection => Selection,
            marks => quod_client_goal_parser:value_text(Marks)},Next#{installed => true});
open_selection(_,_,_,_,_,S) ->
    reply(#{type => unavailable,reason => invalid_projection},release(S)).

attach(Pid, Expected, Marks, Digest, Height, Expiry, S) ->
    case {candidate_live(S),maps:get(pid,S,Pid) =:= Pid} of
        {false,_} -> reply(#{type => unavailable,reason => expired},release(S));
        {true,true} -> attach_current(Pid,Expected,Marks,Digest,Height,Expiry,S);
        {true,false} -> refresh(S,owner_changed)
    end.

attach_current(Pid,Expected,Marks,Digest,Height,Expiry,S) ->
    M = case maps:find(monitor,S) of {ok,Existing} -> Existing; error -> monitor(process,Pid) end,
    Result = try quod_physics:watch(Pid,Expected,maps:get(ref,S,none))
             catch exit:_ -> unknown end,
    case Result of
        {ok, Ref, Frame} ->
            Watched = S#{pid => Pid, ref => Ref, monitor => M},
            case body_bindings(Marks, maps:get(control,Expected), Frame) of
                {ok, Bodies} ->
                    case Expiry > quod_time:now_ms() andalso candidate_live(S) of
                        true ->
                            View = b64(Digest), Tick = decimal(maps:get(tick, Frame)),
                            Next = (projection_deadline(Watched,Expiry))#{installed => true,view => View, tick => Tick, origin_sequence => decimal(maps:get(origin_sequence,Frame)), height => Height,
                                bodies => Bodies, control => maps:get(control,Expected),
                                world => element(1, maps:get(fence, Expected))},
                            reply(#{type => projection,selection => active,view => View, height => decimal(Height),expires_ms => decimal(Expiry),
                                    marks => quod_client_goal_parser:value_text(Marks),
                                    control => quod_client_goal_parser:value_text(maps:get(control,Expected)),
                                    view_frame => quod_client_goal_parser:value_text(maps:get(view_frame,Expected)),
                                    frame => frame_json(Frame, Bodies, maps:get(control,Expected))}, Next);
                        false -> reply(#{type => unavailable,reason => expired},release(Watched))
                    end;
                error -> reply(#{type => unavailable, reason => invalid_body_binding}, release(Watched))
            end;
        {error, Reason} when Reason =:= view_busy; Reason =:= simulation_failed ->
            demonitor(M, [flush]), reply(#{type => unavailable, reason => Reason}, release(S));
        unknown ->
            %% A timed-out local call may still install a reference whose reply
            %% was lost. Socket death releases that registration by its monitor.
            demonitor(M,[flush]),
            {reply,{close,1011,<<"simulation attachment unavailable">>},release(S)};
        _ ->
            demonitor(M, [flush]), waiting(projection_deadline(detach(S),Expiry),
                                           element(1, maps:get(fence, Expected)))
    end.

waiting(S, World) ->
    reply(#{type => unavailable, reason => waiting_for_installation},
          (maps:remove(installed,S))#{world => World}).

candidate_live(#{candidate_timer := _,expires := Expiry}) -> Expiry > quod_time:now_ms();
candidate_live(_) -> true.

projection_deadline(S,Expiry) ->
    case maps:take(candidate_timer,S) of
        {Timer,Rest} -> _ = erlang:cancel_timer(maps:get(timer,Rest)), Rest#{timer := Timer,expires => Expiry};
        error -> S#{expires => Expiry}
    end.

%% The ontology's subject and the body identity remain separate. Duplicate
%% occurrences may depict one body, but every occurrence has exactly one source.
body_bindings(Marks, Control, #{poses := Poses}) ->
    try
        Available = maps:from_list([{{Id, R}, true} || {Id, R, world, _, _, _} <- Poses]),
        Rows = [{Mark, mark_body(Pose, Depicts)} ||
                  {mark, Mark, _, _, Pose, _, _, Depicts} <- Marks],
        true = length(Rows) =:= length(Marks),
        true = map_size(maps:from_list(Rows)) =:= length(Rows),
        true = lists:all(fun({Mark, Body}) -> is_binary(Mark) andalso
                            (Body =:= none orelse maps:is_key(Body, Available)) end, Rows),
        Controlled = case Control of
            none -> [];
            {control,_,_,{controlled_agent,_,_,Id,Revision,_,_}} ->
                true = maps:is_key({Id,Revision},Available), [{{Id,Revision},true}]
        end,
        {ok, maps:from_list(Controlled ++ [{Body, true} || {_, Body} <- Rows, Body =/= none])}
    catch error:_ -> error end.

terrain_bindings(Marks) ->
    Bindings = lists:foldl(fun
        ({mark,_,<<"terrain">>,{terrain_geometry,<<"qvt1">>,_,View,{resources,A,B,C,D,E}},Pose,_,_,Depicts},Acc) ->
            Key = mark_body(Pose,Depicts),
            Limits = [A,B,C,D,E],
            {View,Previous} = maps:get(Key,Acc,{View,Limits}),
            Acc#{Key => {View,lists:zipwith(fun erlang:min/2,Limits,Previous)}};
        (_,Acc) -> Acc
    end,#{},Marks),
    [{Id,Revision,View,Limits} || {{Id,Revision},{View,Limits}} <- lists:sort(maps:to_list(Bindings))].

mark_body({relative, _, Pose}, Depicts) -> mark_body(Pose, Depicts);
mark_body({body_pose, Id, R}, {depicts, _, <<_:256>>, _}) -> {Id, R};
mark_body({body_frame_pose, Id, R}, {depicts, _, <<_:256>>, _}) -> {Id, R};
mark_body({transform, _, _, _, _, _, _}, _) -> none.

websocket_info({quod_gui_request, From,
                {gui_prepare, Agent, Connection, Request, Question, Descriptor, Capacity, Expiry, Deadline}}, S) ->
    gui_prepare(From, Agent, Connection, Request, Question, Descriptor, Capacity, Expiry, Deadline, S);
websocket_info({quod_gui_request, From, {gui_activate, Request, Token}}, S) ->
    gui_activate(From, Request, Token, S);
websocket_info({timeout, Timer, {gui_resource, Token}}, S) ->
    case maps:get(Token, maps:get(gui_resources,S,#{}), none) of
        #{timer := Timer} ->
            reply(#{type => gui_expired, token => b64(Token)}, drop_gui_resource(Token,S));
        _ -> {ok,S}
    end;

websocket_info({view_opened,Ref,Result},S = #{opening := {Ref,_,_},timer := _}) ->
    {ok,S#{opening_result => Result}};
websocket_info({'DOWN',M,process,Pid,_},S = #{opening := {_,Pid,M}}) ->
    Clean = maps:without([opening,opening_result],S),
    case maps:find(opening_result,S) of
        {ok,Result} -> open_result(Result,Clean);
        error -> case maps:is_key(timer,Clean) of
            true -> reply(#{type => unavailable,reason => proof_unavailable},release(Clean));
            false -> finish_cleanup(Clean)
        end
    end;
websocket_info({physics_resource,Pid,Ref,Resource},S = #{pid := Pid,ref := Ref,view := View,expires := Expiry}) ->
    case Expiry > quod_time:now_ms() of
        true -> case Resource of
            {terrain_unavailable,Reason} -> reply(#{type => unavailable,reason => Reason},release(S));
            _ -> reply((quod_terrain_wire:message(Resource))#{view => View},S)
        end;
        false -> reply(#{type => unavailable,reason => expired},release(S))
    end;
websocket_info({physics_frame, Pid, Ref, Frame}, S = #{pid := Pid, ref := Ref, view := View, bodies := Bodies,control := Control}) ->
    Tick = decimal(maps:get(tick, Frame)),
    reply(#{type => simulation_frame, view => View, frame => frame_json(Frame, Bodies,Control)}, S#{tick => Tick,origin_sequence => decimal(maps:get(origin_sequence,Frame))});
websocket_info({physics_refresh, Pid, Ref}, S = #{pid := Pid, ref := Ref}) -> refresh(S, structure_changed);
websocket_info({'DOWN', M, process, _, _}, S = #{monitor := M}) -> refresh(S, owner_changed);
websocket_info({timeout, Timer, expired}, S = #{timer := Timer, installed := true}) -> refresh(S, expired);
websocket_info({timeout, Timer, expired}, S = #{timer := Timer}) ->
    reply(#{type => unavailable, reason => expired}, release(S));
websocket_info({timeout,Timer,expired},S = #{candidate_timer := Timer}) ->
    reply(#{type => unavailable,reason => expired},release(S));
websocket_info({'DOWN', M, process, _, _}, S = #{dependency_monitors := Monitors})
  when is_map_key(M,Monitors) -> refresh(S,dependency_owner_changed);
websocket_info({quod_foreign_follow, Ref, NoticeRef, {Ns,Anchor}, Notice},
               S = #{follows := Follows}) ->
    quod_foreign_log:ack(Ref,NoticeRef),
    case maps:get(Ref,Follows,none) of
        {Ns,Anchor,Height,Ready} ->
            case Notice of
                {certified,H,_} when H > Height -> refresh(S,durable_gap);
                {certified,Height,_} when Ready =:= false ->
                    resume_projection(S#{follows := Follows#{Ref => {Ns,Anchor,Height,true}}});
                {certified,Height,_} -> {ok,S};
                _ when Ready -> refresh(S,dependency_recovering);
                _ -> {ok,S}
            end;
        _ -> {ok,S}
    end;
websocket_info({projection_advanced, Owner, Height}, S = #{owners := Owners}) ->
    dependency_height(maps:get(Owner,Owners,undefined),Height,S);
websocket_info({replay_started, Recovery = {_,_}, _}, S = #{owners := _}) ->
    dependency_recovering(Recovery,S);
websocket_info({replay_ready, Recovery = {Owner, _}, _}, S = #{owners := Owners,local_ready := Ready}) ->
    case maps:find(Owner,Owners) of
        {ok,Ns} when map_get(Ns,Ready) =:= {recovering,Recovery} -> refresh(S,dependency_recovered);
        _ -> {ok,S}
    end;
websocket_info({gproc,registered,M,_},S = #{dependency_names := Names})
  when is_map_key(M,Names) -> local_dependency_registered(M,S);
websocket_info({physics_status, Runtime, Pid, World, _, Status}, S = #{world := World, namespace := Ns}) ->
    case Runtime =:= quod_reg:where({quod_runtime, Ns}) andalso
         Pid =:= quod_reg:where({physics_world, World}) andalso not maps:is_key(pid, S)
         andalso dependencies_ready(S) of
        true -> case Status of
            installed -> refresh(S, installed);
            {failed, _} -> reply(#{type => unavailable, reason => simulation_failed}, release(S));
            _ -> {ok, S}
        end;
        false -> {ok, S}
    end;
websocket_info(Message, S) -> follow_response(Message,S).

refresh(S, Reason) -> reply(#{type => refresh, reason => Reason}, release(S)).
dependency_recovering(Recovery = {Owner,_},S = #{owners := Owners,local_ready := Ready}) ->
    case maps:find(Owner,Owners) of
        {ok,Ns} when map_get(Ns,Ready) =:= {recovering,Recovery} -> {ok,S};
        {ok,Ns} ->
            Next = (detach(S))#{local_ready := Ready#{Ns => {recovering,Recovery}}},
            reply(#{type => unavailable,reason => dependency_recovering},Next);
        error -> {ok,S}
    end.

local_dependency_registered(M,S = #{dependency_names := Names}) ->
    Ns = maps:get(M,Names),
    case {quod_reg:where({quod_prolog,Ns}),quod_simplex:genesis_hash(Ns)} of
        {Pid,Anchor} when is_pid(Pid),Anchor =:= map_get(Ns,map_get(anchors,S)) ->
            OwnerMonitor = monitor(process,Pid),
            quod_reg:demonitor_name({quod_prolog,Ns},M),
            Next = S#{dependency_names := maps:remove(M,Names),
                owners := (maps:get(owners,S))#{Pid => Ns},
                dependency_monitors := (maps:get(dependency_monitors,S))#{OwnerMonitor => Pid}},
            case gen_server:reqids_size(maps:get(follow_requests,Next)) of
                0 -> {ok,Next#{snapshots := gen_server:send_request(
                        Pid,get_stats,{Pid,Ns},maps:get(snapshots,Next))}};
                _ -> {ok,Next}
            end;
        _ -> reply(#{type => unavailable,reason => dependency_unavailable},release(S))
    end.

dependency_height(Ns,Height,S = #{heights := Heights,local_ready := Ready}) ->
    case {maps:find(Ns,Heights),maps:get(Ns,Ready,false)} of
        {{ok,_},{recovering,_}} -> {ok,S};
        {{ok,Before},_} when Height > Before -> refresh(S,durable_gap);
        {{ok,Height},_} -> resume_projection(S#{local_ready := Ready#{Ns => true}});
        _ -> {ok,S}
    end.

frame_json(Frame = #{fence := {World, Authority, Epoch, Generation}, structure := Structure,
             incarnation := Token, tick := Tick, poses := Poses}, Bodies,Control) ->
    #{schema => 2, units => metres_seconds, space => local,
      origin_mm => [decimal(N) || N <- tuple_to_list(maps:get(origin,Frame))],
      origin_seq => decimal(maps:get(origin_sequence,Frame)),
      world => quod_client_goal_parser:value_text(World),
      authority => quod_client_goal_parser:value_text(Authority),
      epoch => decimal(Epoch), generation => decimal(Generation),
      incarnation => b64(Token), structure => decimal(Structure), tick => decimal(Tick),
      registration => b64(maps:get(registration,Frame)),
      control_state => control_feedback(Frame,Control),
      poses => [#{body => decimal(Id), revision => decimal(R),
                  position => tuple_to_list(P), rotation => tuple_to_list(Q)}
                || {Id, R, world, P, Q, _} <- Poses, maps:is_key({Id, R}, Bodies)]}.

control_feedback(_,none) -> null;
control_feedback(Frame,Control = {control,Principal,_,_}) ->
    Row = maps:get(Principal,maps:get(inputs,Frame,#{}),none),
    Feedback = case Row of
        #{control := Control,sequence := Seq,pending := Pending,result := Result} ->
            #{sequence => decimal(Seq),pending => Pending,
              result => quod_client_goal_parser:value_text(quod_physics_predicates:motion_answer(Result))};
        #{sequence := Seq} ->
            #{sequence => decimal(Seq),pending => false,result => <<"suspended">>};
        _ -> #{sequence => <<"-1">>,pending => false,result => <<"idle">>}
    end,
    Origin = case Row of #{result_origin := O} -> O; _ -> maps:get(origin,Frame) end,
    Feedback#{origin_mm => [decimal(N) || N <- tuple_to_list(Origin)]}.

reply(Message0, S) ->
    Message = case {maps:get(kind,S,none),Message0} of
        {eidolon_scene,#{type := projection}} -> Message0#{kind => eidolon_scene,
            exposures => quod_client_goal_parser:value_text(maps:get(exposures,S,[]))};
        _ -> Message0
    end,
    Encoded = iolist_to_binary(json:encode(Message)),
    case byte_size(Encoded) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES of
        true ->
            case Message of
                %% Quiet views still own a live signed lease. Only an admitted
                %% projection bounds the transport idle window; the existing
                %% absolute expiry and revocation paths remain authoritative.
                #{type := projection,expires_ms := Expiry} ->
                    {[{set_options,#{idle_timeout => max(0,binary_to_integer(Expiry)-quod_time:now_ms())}},
                      {text,Encoded}],S};
                _ -> {reply,{text,Encoded},S}
            end;
        false -> {reply, {close, 1009, <<"simulation projection exceeds reply encoding limit">>}, release(S)}
    end.
decimal(N) -> integer_to_binary(N).
b64(B) -> base64:encode(B, #{mode => urlsafe, padding => false}).

detach(S) ->
    case S of #{pid := Pid, ref := Ref, monitor := M} ->
        quod_physics:unwatch(Pid, Ref), demonitor(M, [flush]); _ -> ok end,
    maps:without([pid,ref,monitor,view,tick,origin_sequence,height,bodies,control],S).

release(S) ->
    HasGui = map_size(maps:get(gui_resources,S,#{})) > 0,
    case {HasGui,maps:find(receiver_key,S)} of
        {false,{ok,Key}} -> true = gproc:unreg(quod_reg:name(Key));
        _ -> ok
    end,
    RetainGui = case HasGui of true -> [gui_resources,receiver_key]; false -> [] end,
    _ = detach(S),
    case S of #{opening := {_,Worker,_}} -> exit(Worker,kill); _ -> ok end,
    _ = [erlang:cancel_timer(T) || Key <- [timer,candidate_timer],{ok,T} <- [maps:find(Key,S)]],
    [quod_reg:unsubscribe({runtime,N}) || N <- maps:keys(maps:get(heights,S,#{}))],
    [demonitor(M,[flush]) || M <- maps:keys(maps:get(dependency_monitors,S,#{}))],
    [quod_reg:demonitor_name({quod_prolog,Ns},M) ||
        {M,Ns} <- maps:to_list(maps:get(dependency_names,S,#{}))],
    _ = [catch gen_server:receive_response(Request,0) ||
        {Request,_} <- gen_server:reqids_to_list(maps:get(snapshots,S,gen_server:reqids_new()))],
    [unfollow(Ref) || Ref <- maps:keys(maps:get(follows,S,#{}))],
    case S of
        #{kind := K,namespace := Ns,timer := _} when K =:= world; K =:= eidolon_scene -> quod_reg:unsubscribe({physics,Ns});
        _ -> ok
    end,
    case maps:find(follow_requests,S) of
        {ok, Requests} ->
            case gen_server:reqids_size(Requests) of
                0 -> maps:with([peer,opening,receiver_seed] ++ RetainGui,S);
                _ -> maps:with([peer,opening,follow_requests,receiver_seed] ++ RetainGui,S)
            end;
        error -> maps:with([peer,opening,receiver_seed] ++ RetainGui,S)
    end.
terminate(_, _, S) -> _ = release(discard_gui_resources(S)), ok.


%% Provisional resources are private to this authenticated connection. They
%% never make a question visible or substitute for a signed question view.
gui_prepare(From, Agent, Connection, <<_:256>> = Request, Question, Descriptor,
            Capacity, Expiry, Deadline,
            S = #{kind := gui_hud, installed := true, receiver_key := {client_view,{gui_hud,Agent,Connection}},
                  authenticated_agent := Agent, expires := ViewExpiry})
  when is_integer(Capacity), Capacity > 0, is_integer(Expiry), is_integer(Deadline) ->
    Now = quod_time:now_ms(),
    Bound = min(Expiry,Now + max(0,Deadline-quod_time:mono_ms())),
    case {ViewExpiry > Now andalso Bound > Now andalso
          quod_wire_term:is_ground({Question,Descriptor}),
          quod_wire_term:encode_canonical({gui_presentation,Agent,Connection,Request,Question,Descriptor,Expiry})} of
        {true,{ok,Bytes}} ->
            Token = crypto:hash(sha256,Bytes),
            Resources = maps:get(gui_resources,S,#{}),
            case maps:get(Token,Resources,none) of
                #{state := State,expires := PreviousExpiry}
                  when PreviousExpiry > Now,
                       (State =:= prepared orelse State =:= activating orelse State =:= active) ->
                    gui_reply(From,{ok,{gui_receipt,Token,PreviousExpiry}},S);
                #{expires := PreviousExpiry} when PreviousExpiry =< Now ->
                    gui_reply(From,{error,presentation_expired},drop_gui_resource(Token,S));
                #{state := preparing} -> gui_reply(From,{error,presentation_pending},S);
                none when map_size(Resources) < Capacity ->
                    case lists:any(fun(#{question := Q}) -> Q =:= Question end,maps:values(Resources)) of
                        true -> gui_reply(From,{error,presentation_conflict},S);
                        false ->
                            Message = #{type => gui_prepare,token => b64(Token),connection => b64(Connection),
                                expires_ms => decimal(Bound),capacity => Capacity,
                                question => quod_client_goal_parser:value_text(Question),
                                descriptor => quod_client_goal_parser:value_text(Descriptor)},
                            Encoded = iolist_to_binary(json:encode(Message)),
                            case byte_size(Encoded) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES of
                                false -> gui_reply(From,{error,unsupported_presentation},S);
                                true ->
                                    TimerResult = try {ok,erlang:start_timer(Bound-Now,self(),{gui_resource,Token})}
                                                  catch error:badarg -> error end,
                                    case TimerResult of
                                        {ok,Timer} ->
                                            Resource = #{request => Request,question => Question,expires => Bound,
                                                         state => preparing,from => From,timer => Timer},
                                            {reply,{text,Encoded},S#{gui_resources => Resources#{Token => Resource}}};
                                        error -> gui_reply(From,{error,invalid_presentation_deadline},S)
                                    end
                            end
                    end;
                none -> gui_reply(From,{error,presentation_capacity},S)
            end;
        _ -> gui_reply(From,{error,human_unavailable},S)
    end;
gui_prepare(From,_,_,_,_,_,_,_,_,S) -> gui_reply(From,{error,human_unavailable},S).

gui_prepared(Token, Accepted, S) ->
    case maps:get(Token,maps:get(gui_resources,S,#{}),none) of
        #{state := preparing,from := From,expires := Expiry} = Resource ->
            case Accepted andalso Expiry > quod_time:now_ms() of
                true ->
                    gen_server:reply(From,{ok,{gui_receipt,Token,Expiry}}),
                    {ok,put_gui_resource(Token,maps:remove(from,Resource#{state => prepared}),S)};
                false ->
                    gen_server:reply(From,{error,presentation_refused}),
                    {ok,drop_gui_resource(Token,put_gui_resource(Token,maps:remove(from,Resource),S))}
            end;
        _ -> {ok,S}
    end.

gui_activate(From, Request, Token, S) ->
    case maps:get(Token,maps:get(gui_resources,S,#{}),none) of
        #{request := Request,expires := Expiry,state := State} = Resource ->
            case Expiry > quod_time:now_ms() of
                false -> gui_reply(From,{ok,expired},drop_gui_resource(Token,S));
                true when State =:= active -> gui_reply(From,{ok,active},S);
                true when State =:= prepared ->
                    reply(#{type => gui_activate,token => b64(Token)},
                          put_gui_resource(Token,Resource#{state => activating,from => From},S));
                true -> gui_reply(From,{error,presentation_pending},S)
            end;
        _ -> gui_reply(From,{ok,expired},S)
    end.

gui_activated(Token, Status, S) ->
    case maps:get(Token,maps:get(gui_resources,S,#{}),none) of
        #{state := activating,from := From,expires := Expiry} = Resource ->
            case Status =:= <<"active">> andalso Expiry > quod_time:now_ms() of
                true ->
                    gen_server:reply(From,{ok,active}),
                    {ok,put_gui_resource(Token,maps:remove(from,Resource#{state => active}),S)};
                false ->
                    gen_server:reply(From,{ok,expired}),
                    {ok,drop_gui_resource(Token,put_gui_resource(Token,maps:remove(from,Resource),S))}
            end;
        _ -> {ok,S}
    end.

gui_reply(From, Reply, S) -> gen_server:reply(From,Reply), {ok,S}.
%% An activated opportunity is no longer needed once the authenticated HUD
%% confirms its question is gone. Unreleased preparations still keep their
%% original deadline: absence alone does not decide an in-flight opening.
retire_gui_presentations(gui_hud,Questions,S) when is_list(Questions) ->
    maps:fold(fun(Token,#{state := active,question := Q},Acc) ->
        case lists:member(Q,Questions) of true -> Acc; false -> drop_gui_resource(Token,Acc) end;
        (_,_,Acc) -> Acc
    end,S,maps:get(gui_resources,S,#{}));
retire_gui_presentations(_,_,S) -> S.
put_gui_resource(Token, Resource, S) ->
    S#{gui_resources => (maps:get(gui_resources,S,#{}))#{Token => Resource}}.
drop_gui_resource(Token, S) ->
    Resources = maps:get(gui_resources,S,#{}),
    case maps:take(Token,Resources) of
        error -> S;
        {Resource,Rest} ->
            _ = erlang:cancel_timer(maps:get(timer,Resource)),
            case maps:find(from,Resource) of
                {ok,From} -> gen_server:reply(From,{error,presentation_expired});
                error -> ok
            end,
            case {map_size(Rest),maps:get(installed,S,false),maps:find(receiver_key,S)} of
                {0,false,{ok,Key}} ->
                    true = gproc:unreg(quod_reg:name(Key)),
                    maps:without([gui_resources,receiver_key],S);
                _ -> S#{gui_resources => Rest}
            end
    end.
discard_gui_resources(S) ->
    lists:foldl(fun drop_gui_resource/2,S,maps:keys(maps:get(gui_resources,S,#{}))).
