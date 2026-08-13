-module(quod_effect).
-moduledoc """
Closed, canonical descriptors for durable direct effects.

Descriptors are data, never callbacks or executable goals.  Consensus admits
only the fixed handlers and operations defined here; the node-local runtime
maps an admitted descriptor to its internal implementation after ordered
apply.
""".

-include("quod_proof_limits.hrl").

-export([validate/1, validate_list/1, validate_transaction/4,
         operation/1, effect_id/1, executor/1, actor/1, target/1,
         request_digest/1, prepared_digest/1]).
-export_type([effect/0]).

-type identity() :: {binary(), <<_:256>>}.
-type actor() :: {node, <<_:256>>} | {user, <<_:256>>}.
-type effect() ::
        {quod_direct_effect, 1, local_durable, ontology_lifecycle,
         create | join, <<_:256>>, <<_:256>>, actor(), identity(),
         <<_:256>>, <<_:256>>}.

-spec validate(term()) -> boolean().
validate({quod_direct_effect, 1, local_durable, ontology_lifecycle,
          Operation, <<_:256>>, <<_:256>>, Actor,
          {Ns, <<_:256>>}, <<_:256>>, <<_:256>>})
  when Operation =:= create; Operation =:= join ->
    is_binary(Ns) andalso byte_size(Ns) > 0 andalso valid_actor(Actor);
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

-spec operation(effect()) -> create | join.
operation({quod_direct_effect, 1, local_durable, ontology_lifecycle,
           Operation, _, _, _, _, _, _}) -> Operation.

-spec effect_id(effect()) -> <<_:256>>.
effect_id({quod_direct_effect, 1, local_durable, ontology_lifecycle,
           _, Id, _, _, _, _, _}) -> Id.

-spec executor(effect()) -> <<_:256>>.
executor({quod_direct_effect, 1, local_durable, ontology_lifecycle,
          _, _, Executor, _, _, _, _}) -> Executor.

-spec actor(effect()) -> actor().
actor({quod_direct_effect, 1, local_durable, ontology_lifecycle,
       _, _, _, Actor, _, _, _}) -> Actor.

-spec target(effect()) -> identity().
target({quod_direct_effect, 1, local_durable, ontology_lifecycle,
        _, _, _, _, Target, _, _}) -> Target.

-spec request_digest(effect()) -> <<_:256>>.
request_digest({quod_direct_effect, 1, local_durable, ontology_lifecycle,
                _, _, _, _, _, Digest, _}) -> Digest.

-spec prepared_digest(effect()) -> <<_:256>>.
prepared_digest({quod_direct_effect, 1, local_durable, ontology_lifecycle,
                 _, _, _, _, _, _, Digest}) -> Digest.

valid_actor({node, <<_:256>>}) -> true;
valid_actor({user, <<_:256>>}) -> true;
valid_actor(_) -> false.
