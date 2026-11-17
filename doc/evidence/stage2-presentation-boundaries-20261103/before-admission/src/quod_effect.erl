-module(quod_effect).
-moduledoc """
Closed, canonical descriptors for durable direct effects.

Descriptors are data, never callbacks or executable goals.  Consensus admits
only the fixed handlers and operations defined here; the node-local runtime
maps an admitted descriptor to its internal implementation after ordered
apply.
""".

-include("quod_proof_limits.hrl").

-define(VERSION, 2).

-export([new/6, validate/1, validate_list/1, validate_plan/2,
         validate_transaction/4,
         operation/1, effect_id/1, executor/1, actor/1, target/1,
         request_digest/1, prepared_digest/1, prepared_bytes/2, decode_prepared/2]).
-export_type([effect/0]).
-export([valid_transient/1, release_transient/2]).

%% Ephemeral control effects never enter validate/1, consensus or the journal.
%% One successful proof can release one indivisible operation to a local owner.
valid_transient({physics_input,Pid,Expected,{control,_,Epoch,_},Sequence,_,Expiry}) ->
    is_pid(Pid) andalso node(Pid) =:= node() andalso is_map(Expected)
    andalso is_integer(Epoch) andalso Epoch > 0
    andalso is_integer(Sequence) andalso Sequence >= 0
    andalso is_integer(Expiry) andalso Expiry > 0;
valid_transient(_) -> false.

release_transient(none,_) -> ok;
release_transient({physics_input,Pid,Expected,Control,Sequence,Input,Expiry},Deadline) ->
    try quod_physics:input(Pid,Expected,Control,Sequence,Input,Expiry,Deadline)
    %% A lost reply does not prove the owner rejected the action.
    catch exit:_ -> {unknown,owner_unavailable} end.

-type identity() :: {binary(), <<_:256>>}.
-type actor() :: {node, <<_:256>>} | {agent, binary()}.
-type effect() ::
        {quod_direct_effect, ?VERSION, local_durable, ontology_lifecycle | gui_presentation,
         create | join | present, <<_:256>>, <<_:256>>, actor(), identity(),
         <<_:256>>, <<_:256>>}.

-doc "Construct one closed direct-effect descriptor in the current format.".
-spec new(create | join | present, <<_:256>>, actor(), identity(), <<_:256>>, <<_:256>>) ->
          {ok, effect()} | {error, invalid_direct_effect}.
new(Operation, <<_:256>> = Executor, Actor,
    {Ns, <<_:256>> = Anchor}, <<_:256>> = RequestDigest,
    <<_:256>> = PreparedDigest)
  when (Operation =:= create orelse Operation =:= join orelse Operation =:= present),
       is_binary(Ns), byte_size(Ns) > 0 ->
    Effect =
        {quod_direct_effect, ?VERSION, local_durable, handler(Operation),
         Operation, crypto:strong_rand_bytes(32), Executor, Actor,
         {Ns, Anchor}, RequestDigest, PreparedDigest},
    case validate(Effect) of
        true -> {ok, Effect};
        false -> {error, invalid_direct_effect}
    end;
new(_, _, _, _, _, _) ->
    {error, invalid_direct_effect}.

-spec validate(term()) -> boolean().
validate({quod_direct_effect, ?VERSION, local_durable, Handler,
          Operation, <<_:256>>, <<_:256>>, Actor,
          {Ns, <<_:256>>}, <<_:256>>, <<_:256>>})
  when Operation =:= create; Operation =:= join; Operation =:= present ->
    Handler =:= handler(Operation) andalso is_binary(Ns) andalso byte_size(Ns) > 0 andalso valid_actor(Actor);
validate(_) ->
    false.

-spec validate_list(term()) -> boolean().
validate_list(Effects) ->
    validate_list(Effects, 0, #{}).

validate_list([], Count, _Ids) ->
    Count =< ?QUOD_MAX_DIRECT_EFFECTS;
validate_list([Effect | Rest], Count, Ids)
  when Count < ?QUOD_MAX_DIRECT_EFFECTS ->
    case validate(Effect) of
        true ->
            Id = effect_id(Effect),
            case maps:is_key(Id, Ids) of
                false -> validate_list(Rest, Count + 1, Ids#{Id => true});
                true -> false
            end;
        false ->
            false
    end;
validate_list(_, _Count, _Ids) ->
    false.

-doc "Validate direct effects in their sealed, target-owned plan context.".
-spec validate_plan(quod_dtx:plan(), map()) -> boolean().
validate_plan(Plan, #{effects := Effects}) ->
    case Effects of
        [] ->
            true;
        [Effect] ->
            validate(Effect) andalso
                executor(Effect) =:= quod_dtx:signer(Plan) andalso
                actor(Effect) =:= quod_dtx:principal(Plan) andalso
                quod_dtx:diff_ops(Plan) =:= 0;
        _ ->
            false
    end;
validate_plan(_Plan, _Material) ->
    false.

-doc "Validate effects in their signed transaction context.".
-spec validate_transaction(binary(), <<_:256>>, none | <<_:256>>, term()) ->
          boolean().
validate_transaction(Ns, Anchor, Author, Effects)
  when is_binary(Ns), is_binary(Anchor), byte_size(Anchor) =:= 32 ->
    validate_list(Effects) andalso
        lists:all(
          fun(Effect) ->
                  is_binary(Author) andalso byte_size(Author) =:= 32 andalso
                      executor(Effect) =:= Author
          end,
          Effects);
validate_transaction(_, _, _, _) ->
    false.

-spec operation(effect()) -> create | join | present.
operation({quod_direct_effect, ?VERSION, local_durable, _,
           Operation, _, _, _, _, _, _}) -> Operation.

-spec effect_id(effect()) -> <<_:256>>.
effect_id({quod_direct_effect, ?VERSION, local_durable, _,
           _, Id, _, _, _, _, _}) -> Id.

-spec executor(effect()) -> <<_:256>>.
executor({quod_direct_effect, ?VERSION, local_durable, _,
          _, _, Executor, _, _, _, _}) -> Executor.

-spec actor(effect()) -> actor().
actor({quod_direct_effect, ?VERSION, local_durable, _,
       _, _, _, Actor, _, _, _}) -> Actor.

-spec target(effect()) -> identity().
target({quod_direct_effect, ?VERSION, local_durable, _,
        _, _, _, _, Target, _, _}) -> Target.

-spec request_digest(effect()) -> <<_:256>>.
request_digest({quod_direct_effect, ?VERSION, local_durable, _,
                _, _, _, _, _, Digest, _}) -> Digest.

-spec prepared_digest(effect()) -> <<_:256>>.
prepared_digest({quod_direct_effect, ?VERSION, local_durable, _,
                 _, _, _, _, _, _, Digest}) -> Digest.

valid_actor({node, <<_:256>>}) -> true;
valid_actor(Actor = {agent, _}) -> quod_agent_ref:valid_principal(Actor);
valid_actor(_) -> false.

%% The effect catalogue owns handler dispatch; each native owner keeps its
%% exact private codec. Unknown handler/operation pairs are never executable.
handler(create) -> ontology_lifecycle;
handler(join) -> ontology_lifecycle;
handler(present) -> gui_presentation.

prepared_bytes(Effect, Prepared) ->
    case validate(Effect) of
        false -> {error, invalid_direct_effect};
        true -> case operation(Effect) of
            present ->
                case quod_gui_presentation:matches(Effect,Prepared) of
                    true -> quod_gui_presentation:prepared_bytes(Prepared);
                    false -> {error,invalid_direct_effect}
                end;
            _ -> quod_ontology:prepared_bytes(Prepared)
        end
    end.

decode_prepared(Effect, Bytes) ->
    case validate(Effect) of
        false -> {error, invalid_direct_effect};
        true -> case operation(Effect) of
            present ->
                case quod_gui_presentation:decode_prepared(Bytes) of
                    {ok,Prepared} = Result ->
                        case quod_gui_presentation:matches(Effect,Prepared) of
                            true -> Result;
                            false -> {error,invalid_direct_effect}
                        end;
                    Error -> Error
                end;
            _ -> quod_ontology:decode_prepared(Bytes)
        end
    end.
