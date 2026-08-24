-module(quod_agent_ref).
-moduledoc """
Canonical, atom-safe identity for one ontology-backed agent instance.

The durable identity is the canonical wire encoding of the exact ground
Prolog term `agent_instance_ref(Namespace, GenesisAnchor, Instance)`.  Parsing
uses the signed-goal grammar; decoding never allocates atoms.  Materialization
is the sole transition into an ontology proof and remains under the shared VM
atom-safety budget.

This module owns no registry, key binding, ACL, process, or cache.  It defines
only representation and validation; `agent_key/3` and `can_invoke/4` remain
ordinary ontology policy.
""".

-include("quod_client_goal_limits.hrl").
-include("quod_proof_limits.hrl").
-include("quod_vm_limits.hrl").

-export([from_text/4, decode/1, materialize/1, materialize_principal/1,
         identity/1, principal/1, valid_principal/1]).
-export_type([blob/0, decoded/0]).

-type blob() :: binary().
-type decoded() ::
        #{blob := blob(),
          identity := {binary(), <<_:256>>},
          instance := term(),
          reference := term()}.

-type error_reason() :: invalid_agent_reference | {too_large, agent_reference}.

-doc "Parse and canonically encode one dot-terminated ground instance term.".
-spec from_text(binary(), <<_:256>>, binary(), 1 | 2) ->
          {ok, decoded()} | {error, error_reason()}.
from_text(Namespace, <<_:256>> = Anchor, InstanceText, ParserVersion)
  when is_binary(Namespace), byte_size(Namespace) > 0,
       byte_size(Namespace) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
       is_binary(InstanceText) ->
    case quod_client_goal_parser:parse(InstanceText, ParserVersion) of
        {ok, #{goal := Instance, variables := []}} ->
            encode_reference(Namespace, Anchor, Instance);
        _ ->
            {error, invalid_agent_reference}
    end;
from_text(_Namespace, _Anchor, _InstanceText, _ParserVersion) ->
    {error, invalid_agent_reference}.

-doc "Decode and validate one canonical agent-reference blob without allocating atoms.".
-spec decode(term()) -> {ok, decoded()} | {error, error_reason()}.
decode(Blob) when is_binary(Blob) ->
    case quod_wire_term:decode_canonical(Blob, ?QUOD_MAX_TOPLEVEL_GOAL_BYTES) of
        {ok, {agent_instance_ref, Namespace, <<_:256>> = Anchor, Instance} = Ref}
          when is_binary(Namespace), byte_size(Namespace) > 0,
               byte_size(Namespace) =< ?DIRECTORY_MAX_NAMESPACE_BYTES ->
            case valid_instance(Instance) of
                true ->
                    {ok, #{blob => Blob,
                           identity => {Namespace, Anchor},
                           instance => Instance,
                           reference => Ref}};
                false ->
                    {error, invalid_agent_reference}
            end;
        {error, too_large} ->
            {error, {too_large, agent_reference}};
        _ ->
            {error, invalid_agent_reference}
    end;
decode(_Blob) ->
    {error, invalid_agent_reference}.

-doc "Materialize the validated reference for entry into the shared Prolog proof helper.".
-spec materialize(term()) -> {ok, term()} | {error, term()}.
materialize(Blob) ->
    case decode(Blob) of
        {ok, #{reference := Ref}} -> quod_wire_term:materialize_symbols(Ref);
        {error, _} = Error -> Error
    end.

-doc "Return the exact anchored containing-ontology identity.".
-spec identity(term()) -> {ok, {binary(), <<_:256>>}} | {error, error_reason()}.
identity(Blob) ->
    case decode(Blob) of
        {ok, #{identity := Identity}} -> {ok, Identity};
        {error, _} = Error -> Error
    end.

-doc "Return the durable Erlang principal after validating its canonical blob.".
-spec principal(term()) -> {ok, {agent, blob()}} | {error, error_reason()}.
principal(Blob) ->
    case decode(Blob) of
        {ok, _} -> {ok, {agent, Blob}};
        {error, _} = Error -> Error
    end.

-doc "Materialize one validated durable agent principal for a Prolog policy call.".
-spec materialize_principal(term()) -> {ok, term()} | {error, error_reason()}.
materialize_principal({agent, Blob}) -> materialize(Blob);
materialize_principal(_Principal) -> {error, invalid_agent_reference}.

-doc "Validate the durable agent-principal alphabet without materializing atoms.".
-spec valid_principal(term()) -> boolean().
valid_principal({agent, Blob}) ->
    case decode(Blob) of {ok, _} -> true; {error, _} -> false end;
valid_principal(_Principal) -> false.

encode_reference(Namespace, Anchor, Instance) ->
    case valid_instance(Instance) of
        false ->
            {error, invalid_agent_reference};
        true ->
            Ref = {agent_instance_ref, Namespace, Anchor, Instance},
            case quod_wire_term:encode_canonical(Ref) of
                {ok, Blob} when byte_size(Blob) =< ?QUOD_MAX_TOPLEVEL_GOAL_BYTES ->
                    {ok, #{blob => Blob,
                           identity => {Namespace, Anchor},
                           instance => Instance,
                           reference => Ref}};
                {ok, _TooLarge} ->
                    {error, {too_large, agent_reference}};
                {error, _} ->
                    {error, invalid_agent_reference}
            end
    end.

valid_instance(Instance) ->
    quod_wire_term:is_ground(Instance) andalso
        case quod_wire_term:symbol_names(Instance) of
            {ok, Names} -> length(Names) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS;
            {error, _} -> false
        end.
