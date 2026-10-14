-module(quod_gui_presentation).
-moduledoc """
Private native presentation preparation retained by the existing effect journal.
This payload owns no question state. Its bounded activation uses the original
authenticated request through the existing selected read-only scope transport.
""".
-export([new/6, prepared_bytes/1, decode_prepared/1, matches/2, release/2]).

new(Node, Identity, Human, Connection, {gui_receipt,Token,Expiry}, Auth) ->
    Prepared = {quod_prepared_presentation,1,Node,Identity,Human,Connection,Token,Expiry,Auth},
    case prepared_bytes(Prepared) of
        {ok,_} -> {ok,Prepared};
        Error -> Error
    end;
new(_,_,_,_,_,_) -> {error,invalid_presentation}.

prepared_bytes(Prepared) ->
    case valid(Prepared) of
        true -> {ok,term_to_binary(Prepared,[deterministic])};
        false -> {error,invalid_presentation}
    end.

decode_prepared(Bytes) when is_binary(Bytes) ->
    try binary_to_term(Bytes,[safe]) of
        Prepared ->
            case prepared_bytes(Prepared) of
                {ok,Bytes} -> {ok,Prepared};
                _ -> {error,invalid_presentation}
            end
    catch error:_ -> {error,invalid_presentation} end;
decode_prepared(_) -> {error,invalid_presentation}.

valid({quod_prepared_presentation,1,<<_:256>>,{<<"quod:gui">>,<<_:256>>},
       Human,<<_:256>>,<<_:256>>,Expiry,{agent_goal_v1,Digest,Bytes,<<_:512>>}})
  when is_integer(Expiry), Expiry > 0 ->
    case {quod_agent_ref:decode(Human),quod_client_goal:request_identity(Bytes)} of
        {{ok,_},{ok,#{request_digest := Digest,request := #{mode := execute,not_after_ms := Bound}}}} ->
            Expiry =< Bound;
        _ -> false
    end;
valid(_) -> false.

release(Effect, Prepared = {quod_prepared_presentation,1,Node,Identity,Human,Connection,Token,Expiry,
                           Auth}) ->
    case matches(Effect,Prepared) of
        true ->
            Remaining = max(0,Expiry-quod_time:now_ms()),
            case Remaining of
                0 -> ok;
                _ ->
                    {ok,HumanRef} = quod_agent_ref:materialize(Human),
                    Goal = {gui_native_activate,HumanRef,Connection,Token,{0}},
                    case quod_ask:native_read(Node,Identity,Goal,Auth,quod_time:mono_ms()+Remaining) of
                        {ok,{gui_native_activate,HumanRef,Connection,Token,Status}}
                          when Status =:= active; Status =:= expired -> ok;
                        _ -> expire(Prepared)
                    end
            end;
        false -> {error,invalid_presentation_binding}
    end.

matches(Effect,{quod_prepared_presentation,1,_,Identity,_,_,_,_,{agent_goal_v1,_,Bytes,_}}) ->
    case quod_client_goal:request_identity(Bytes) of
        {ok,#{agent_ref_blob := Agent}} ->
            quod_effect:validate(Effect) andalso quod_effect:operation(Effect) =:= present
            andalso quod_effect:target(Effect) =:= Identity andalso quod_effect:actor(Effect) =:= {agent,Agent};
        _ -> false
    end;
matches(_,_) -> false.

%% Lost activation acknowledgement cannot justify a second native call. The
%% one original resource deadline discharges this opportunity, not the signed
%% material operation. A journal-worker restart observes the same receipt.
expire({quod_prepared_presentation,1,_,_,_,_,_,Expiry,_}) ->
    receive after max(0,Expiry-quod_time:now_ms()) -> ok end.
