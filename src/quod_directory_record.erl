-module(quod_directory_record).
-moduledoc """
Canonical signed wire record for the live ontology directory.

The signed body contains every authoritative field. Relays and resync peers
forward the original encoded record unchanged; every receiver decodes it under
the same byte/cardinality bounds and verifies the author's Ed25519 signature.
""".

-export([sign/6, decode/1, node_key/1, endpoint/1, hosted/1,
         epoch/1, sequence/1]).

-include("quod_directory_limits.hrl").

%% v2: the V3 ledger break. Routes advertise anchored hosted descriptors for a
%% chain whose entry, transaction and vote formats all changed, so a record
%% signed under v1 must not decode here.
-define(VERSION, 2).
-define(MAX_BYTES, 16 * 1024).

-type record() :: #{node_key := binary(),
                    endpoint := {term(), inet:port_number()},
                    hosted := [{binary(), <<_:256>>,
                                validator | observer}],
                    epoch := non_neg_integer(),
                    sequence := non_neg_integer()}.

-spec sign(binary(), term(),
           [{binary(), <<_:256>>, validator | observer}], non_neg_integer(),
           non_neg_integer(), term()) -> {ok, binary()} | {error, term()}.
sign(NodeKey, Endpoint, Hosted, Epoch, Sequence, Signer) ->
    case validate(NodeKey, Endpoint, Hosted, Epoch, Sequence) of
        ok ->
            Body = body(NodeKey, Endpoint, Hosted, Epoch, Sequence),
            Signature = quod_identity:sign(Body, Signer),
            Encoded = term_to_binary(
                        {quod_directory_record, ?VERSION, Body, Signature},
                        [deterministic]),
            case byte_size(Encoded) =< ?MAX_BYTES of
                true -> {ok, Encoded};
                false -> {error, too_large}
            end;
        {error, _} = Error ->
            Error
    end.

-spec decode(binary()) -> {ok, record()} | {error, term()}.
decode(Encoded) when is_binary(Encoded), byte_size(Encoded) =< ?MAX_BYTES ->
    case quod_safe_term:decode(Encoded, ?MAX_BYTES) of
        {ok, {quod_directory_record, ?VERSION, Body, Signature}}
          when is_binary(Body), is_binary(Signature),
               byte_size(Signature) =:= 64 ->
            decode_body(Body, Signature);
        _ ->
            {error, bad_record}
    end;
decode(Encoded) when is_binary(Encoded) ->
    {error, too_large};
decode(_) ->
    {error, bad_record}.

decode_body(Body, Signature) ->
    case quod_safe_term:decode(Body, ?MAX_BYTES) of
        {ok, {quod_directory_body, ?VERSION, NodeKey, Host, Port,
              Hosted, Epoch, Sequence}} ->
            Endpoint = {Host, Port},
            case validate(NodeKey, Endpoint, Hosted, Epoch, Sequence) of
                ok ->
                    Canonical = body(
                                  NodeKey, Endpoint, Hosted,
                                  Epoch, Sequence),
                    case Body =:= Canonical andalso
                             quod_identity:verify(
                               Signature, Body, NodeKey) of
                        true ->
                            {ok, #{node_key => NodeKey,
                                   endpoint => Endpoint,
                                   hosted => Hosted,
                                   epoch => Epoch,
                                   sequence => Sequence}};
                        false ->
                            {error, bad_signature}
                    end;
                {error, _} = Error ->
                    Error
            end;
        _ ->
            {error, bad_record}
    end.

body(NodeKey, {Host, Port}, Hosted, Epoch, Sequence) ->
    term_to_binary(
      {quod_directory_body, ?VERSION, NodeKey, Host, Port,
       Hosted, Epoch, Sequence},
      [deterministic]).

validate(NodeKey, Endpoint, Hosted, Epoch, Sequence)
  when is_binary(NodeKey), byte_size(NodeKey) =:= 32,
       is_integer(Epoch), Epoch >= 0,
       is_integer(Sequence), Sequence >= 0 ->
    case {quod_quic:valid_endpoint(Endpoint),
          quod_directory_auth:validate_hosted(
            Hosted, ?DIRECTORY_MAX_NAMESPACES)} of
        {true, {ok, Hosted}} -> ok;
        _ -> {error, bad_record}
    end;
validate(_, _, _, _, _) ->
    {error, bad_record}.

-spec node_key(record()) -> binary().
node_key(Record) -> maps:get(node_key, Record).

-spec endpoint(record()) -> term().
endpoint(Record) -> maps:get(endpoint, Record).

-spec hosted(record()) ->
          [{binary(), <<_:256>>, validator | observer}].
hosted(Record) -> maps:get(hosted, Record).

-spec epoch(record()) -> non_neg_integer().
epoch(Record) -> maps:get(epoch, Record).

-spec sequence(record()) -> non_neg_integer().
sequence(Record) -> maps:get(sequence, Record).
