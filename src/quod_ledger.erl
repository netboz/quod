-module(quod_ledger).
-moduledoc """
The single enumeration of what one consensus block and committed ledger slot
may carry.

Blocks and entries have one tagged payload family: `{batch, Items}`.  A batch
contains either ordinary transactions or canonical DTX-control envelopes, never
both. A control batch contains one protocol phase in strict signed-journal order.
The log is indexed by consensus slot, not by item, so one slot may carry many
transactions or many independent controls. Complaint-certified skips use the
distinct entry-only atom `noop`.

`classify/1` is the one place the `entry_data()` variants are listed. Consumers that
react per variant — committee projection, author-sequence high-water, endpoint
learning, the apply fold — dispatch on its result and enumerate every kind
explicitly, with no catch-all. A future variant is therefore introduced here once
and fails loudly at every site that has not yet decided what it means, instead of
folding silently as nothing.

Malformed input is a separate classification, not a crash. Checked entry
construction and byte ingress refuse it before it becomes an artifact.

Committed entries carry their exact existing envelope bytes and decoded views
in a private, process-local artifact. Consumers read views or extract bytes;
they do not reconstruct an entry or authenticate it by serializing it again.
Finality, slot-era authority and replay semantics remain with their existing
verifiers. The native prepared-genesis descriptor is the sole checked view
import; artifacts themselves never cross a wire or persistence boundary.
""".

-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").
-include("quod_transport_limits.hrl").

-export([payload/1, classify/1,
         encoded_payload_size/1,
         new_block/4, decode_block/1, decode_block/2,
         block_bytes/1, valid_block_view/1,
         new_entry/4, entry/2, noop_entry/2, block_from_entry/1,
         entry_view/1, from_entry_view/1,
         encode_entry/1, decode_entry/1, decode_entry/2]).

-export_type([kind/0, entry_artifact/0]).

%% One canonical envelope and the interpretations established at its checked
%% construction/decoding boundary. This is process-local data, never a wire or
%% disk term, and carries no assertion of finality or committee authority.
-record(canonical_entry, {bytes :: binary(), view :: #entry{},
                          block :: #block{} | none}).
-opaque entry_artifact() :: #canonical_entry{}.

-type control_kind() :: 'begin' | prepare | decision | finalize | complete.
-type kind() :: {content, [#transaction{}]}
              | {controls, [{control_kind(), term()}]}
              | noop
              | invalid.

-doc """
Classify one committed slot's `data`:

- `{content, Transactions}` — a well-formed transaction batch;
- `{controls, Controls}` — decoded canonical DTX controls from one phase in
  strict signed-journal order;
- `noop` — a complaint-certified skip, carrying nothing to fold;
- `invalid` — not a recognized variant, a malformed batch, or an invalid DTX
  blob (untrusted input reaches here, so this is tolerated).
""".
-spec classify(term()) -> kind().
classify({batch, [#transaction{} | _] = Transactions}) ->
    case transaction_list(Transactions) of
        true  -> {content, Transactions};
        false -> invalid
    end;
classify({batch, [{dtx, Blob} | _] = Items}) when is_binary(Blob) ->
    classify_controls(Items);
classify(noop) ->
    noop;
classify(_) ->
    invalid.

-doc "The transaction batch of a content slot, or `error` for DTX, noop, and invalid data.".
-spec payload(term()) -> {ok, [#transaction{}]} | error.
payload(Data) ->
    case classify(Data) of
        {content, Transactions} -> {ok, Transactions};
        {controls, _Controls}   -> error;
        noop                    -> error;
        invalid                 -> error
    end.

%% The total DTX decoder owns untrusted bytes.  Decoding also proves each
%% envelope canonical; the batch check below owns phase equality, uniqueness,
%% and ordering once for every consumer.
classify_controls(Items) ->
    try
        Controls = [decode_control_item(Item) || Item <- Items],
        Wave = [Control || {_Kind, Control} <- Controls],
        case quod_dtx:canonical_control_wave(Wave) of
            true -> {controls, Controls};
            false -> invalid
        end
    catch
        _:_ -> invalid
    end.

decode_control_item({dtx, Blob}) when is_binary(Blob) ->
    {ok, Control} = quod_dtx:decode_control(Blob),
    {quod_dtx:control_kind(Control), Control}.

transaction_list([#transaction{} | Rest]) -> transaction_list(Rest);
transaction_list([]) -> true;
transaction_list(_) -> false.

%% The block's byte form is the consensus identity. `#block{}` is only the
%% materialized local view used by the engine and reducers.
-spec new_block(non_neg_integer(), non_neg_integer(), block_payload(),
                non_neg_integer()) -> {ok, #block{}} | {error, bad_block}.
new_block(Slot, Parent, Payload, Timestamp)
  when is_integer(Slot), Slot >= 0,
       is_integer(Parent), Parent >= 0,
       is_integer(Timestamp), Timestamp >= 0 ->
    case encode_payload(Payload) of
        {ok, PayloadWire} ->
            case {quod_safe_term:encode_canonical(
                    PayloadWire, ?MAX_BLOCK_BYTES),
                  quod_safe_term:encode_canonical(
                    {quod_block, 1, Slot, Parent, PayloadWire, Timestamp},
                    ?QUOD_MAX_CANONICAL_BLOCK_BYTES)} of
                {{ok, _PayloadBytes}, {ok, Bytes}} ->
                    Block = #block{slot = Slot, parent = Parent,
                                   payload = Payload, timestamp = Timestamp,
                                   block_bytes = Bytes},
                    case decode_block(Bytes) of
                        {ok, Block} -> {ok, Block};
                        _ -> {error, bad_block}
                    end;
                _ ->
                    {error, bad_block}
            end;
        error ->
            {error, bad_block}
    end;
new_block(_Slot, _Parent, _Payload, _Timestamp) ->
    {error, bad_block}.

-spec encoded_payload_size(term()) -> {ok, non_neg_integer()} | error.
encoded_payload_size(Payload) ->
    case encode_payload(Payload) of
        {ok, PayloadWire} ->
            case quod_safe_term:encode_canonical(
                   PayloadWire, ?MAX_BLOCK_BYTES) of
                {ok, Bytes} -> {ok, byte_size(Bytes)};
                {error, _} -> error
            end;
        error -> error
    end.

-spec decode_block(binary()) -> {ok, #block{}} | {error, bad_block}.
decode_block(Bytes) ->
    decode_block(Bytes, materialized).

-spec decode_block(binary(), materialized | wrapped) ->
          {ok, #block{}} | {error, bad_block}.
decode_block(Bytes, SymbolMode)
  when is_binary(Bytes),
       byte_size(Bytes) =< ?QUOD_MAX_CANONICAL_BLOCK_BYTES,
       (SymbolMode =:= materialized orelse SymbolMode =:= wrapped) ->
    case {quod_safe_term:validate_canonical(
            Bytes, ?QUOD_MAX_CANONICAL_BLOCK_BYTES),
          quod_safe_term:decode(
            Bytes, ?QUOD_MAX_CANONICAL_BLOCK_BYTES)} of
        {ok, {ok, {quod_block, 1, Slot, Parent, PayloadWire, Timestamp}}}
          when is_integer(Slot), Slot >= 0,
               is_integer(Parent), Parent >= 0,
               is_integer(Timestamp), Timestamp >= 0 ->
            case decode_payload(PayloadWire, SymbolMode) of
                {ok, Payload} ->
                    {ok, #block{slot = Slot, parent = Parent,
                                payload = Payload, timestamp = Timestamp,
                                block_bytes = Bytes}};
                error ->
                    {error, bad_block}
            end;
        _ ->
            {error, bad_block}
    end;
decode_block(_Bytes, _SymbolMode) ->
    {error, bad_block}.

-spec block_bytes(#block{}) -> binary() | error.
block_bytes(#block{block_bytes = Bytes}) when is_binary(Bytes) -> Bytes;
block_bytes(#block{}) -> error.

-spec valid_block_view(term()) -> boolean().
valid_block_view(#block{block_bytes = Bytes} = Block) when is_binary(Bytes) ->
    case encode_block_view(Block) of
        {ok, Bytes} -> true;
        _ -> false
    end;
valid_block_view(_) -> false.

encode_block_view(#block{slot = Slot, parent = Parent, payload = Payload,
                         timestamp = Timestamp})
  when is_integer(Slot), Slot >= 0,
       is_integer(Parent), Parent >= 0,
       is_integer(Timestamp), Timestamp >= 0 ->
    case encode_payload(Payload) of
        {ok, PayloadWire} ->
            quod_safe_term:encode_canonical(
              {quod_block, 1, Slot, Parent, PayloadWire, Timestamp},
              ?QUOD_MAX_CANONICAL_BLOCK_BYTES);
        error ->
            {error, bad_term}
    end;
encode_block_view(_) ->
    {error, bad_term}.

encode_payload(Payload) ->
    case classify(Payload) of
        {content, Transactions} ->
            try
                Blobs = [begin
                             {ok, Blob} =
                                 quod_transaction:encode_ledger_transaction(Tx),
                             {transaction, Blob}
                         end || Tx <- Transactions],
                {ok, {batch, Blobs}}
            catch
                _:_ -> error
            end;
        {controls, _Controls} ->
            {ok, Payload};
        noop ->
            error;
        invalid ->
            error
    end.

decode_payload({batch, [{transaction, Blob} | _] = Items}, SymbolMode)
  when is_binary(Blob) ->
    try
        Transactions = [begin
                            {transaction, TxBlob} = Item,
                            {ok, Tx} =
                                quod_transaction:decode_ledger_transaction(
                                  TxBlob, SymbolMode),
                            Tx
                        end || Item <- Items],
        case transaction_list(Transactions) of
            true -> {ok, {batch, Transactions}};
            false -> error
        end
    catch
        _:_ -> error
    end;
decode_payload(Payload = {batch, [{dtx, Blob} | _]}, _SymbolMode)
  when is_binary(Blob) ->
    case classify(Payload) of
        {controls, _} -> {ok, Payload};
        _ -> error
    end;
decode_payload(_, _SymbolMode) ->
    error.

-spec entry(#block{}, term()) -> entry_artifact().
entry(#block{block_bytes = Bytes} = Block, Cert)
  when is_binary(Bytes) ->
    true = valid_block_view(Block),
    {ok, Artifact} = encode_entry_view(entry_view_from_block(Block, Cert), Block),
    Artifact.

entry_view_from_block(
  #block{slot = Slot, payload = Payload, timestamp = Timestamp,
         block_bytes = Bytes}, Cert) ->
    #entry{index = Slot, data = Payload, timestamp = Timestamp,
           block_bytes = Bytes, cert = Cert}.

-doc "Build one checked canonical committed-entry artifact from payload fields.".
-spec new_entry(pos_integer(), block_payload() | noop,
                non_neg_integer(), term()) ->
          {ok, entry_artifact()} | {error, bad_entry}.
new_entry(Index, noop, 0, Cert)
  when is_integer(Index), Index >= 1 ->
    encode_entry_view(#entry{index = Index, data = noop, cert = Cert}, none);
new_entry(Index, Payload, Timestamp, Cert)
  when is_integer(Index), Index >= 1,
       is_integer(Timestamp), Timestamp >= 0 ->
    case new_block(Index, Index - 1, Payload, Timestamp) of
        {ok, Block} -> encode_entry_view(entry_view_from_block(Block, Cert), Block);
        {error, bad_block} -> {error, bad_entry}
    end;
new_entry(_Index, _Payload, _Timestamp, _Cert) ->
    {error, bad_entry}.

-spec noop_entry(pos_integer(), term()) -> entry_artifact().
noop_entry(Index, Cert) when is_integer(Index), Index >= 1 ->
    {ok, Artifact} = encode_entry_view(
                       #entry{index = Index, data = noop, cert = Cert}, none),
    Artifact.

-doc "Read the already-bound interpretation; never reconstruct or authenticate it.".
-spec entry_view(entry_artifact()) -> #entry{}.
entry_view(#canonical_entry{view = View}) -> View.

-spec block_from_entry(term()) -> {ok, #block{}} | error.
block_from_entry(#canonical_entry{block = #block{} = Block}) -> {ok, Block};
block_from_entry(_) -> error.

-doc """
Checked import of the native prepared-genesis view retained in lifecycle
descriptors. This is a constructor, not a raw-record append or fast path.
The caller still verifies the prepared identity, author and genesis anchor.
""".
-spec from_entry_view(term()) -> {ok, entry_artifact()} | {error, bad_entry}.
from_entry_view(#entry{index = Index, data = noop, timestamp = 0,
                       block_bytes = none} = View)
  when is_integer(Index), Index >= 1 ->
    encode_entry_view(View, none);
from_entry_view(#entry{index = Index} = View)
  when is_integer(Index), Index >= 1 ->
    case import_entry_block(View) of
        {ok, Block} -> encode_entry_view(View, Block);
        error -> {error, bad_entry}
    end;
from_entry_view(_) -> {error, bad_entry}.

import_entry_block(
  #entry{index = Index, data = Data, timestamp = Timestamp,
         block_bytes = Bytes})
  when is_binary(Bytes) ->
    %% Only the checked native-view import needs to recover a parent this way.
    %% Re-encoding binds either symbol interpretation to the same bytes; the
    %% public block accessor above never repeats these checks.
    case decode_block(Bytes, wrapped) of
        {ok, #block{slot = Index, parent = Parent,
                    timestamp = Timestamp}} ->
            Block = #block{slot = Index, parent = Parent, payload = Data,
                           timestamp = Timestamp, block_bytes = Bytes},
            case valid_block_view(Block) of
                true -> {ok, Block};
                false -> error
            end;
        _ ->
            error
    end;
import_entry_block(_) -> error.

-doc "Return the exact checked envelope, without encoding or signature work.".
-spec encode_entry(entry_artifact()) -> {ok, binary()} | {error, bad_entry}.
encode_entry(#canonical_entry{bytes = Bytes}) -> {ok, Bytes};
encode_entry(_) ->
    {error, bad_entry}.

encode_entry_view(#entry{index = Index, block_bytes = BlockBytes, cert = Cert} = View,
                  Block) when is_integer(Index), Index >= 1 ->
    case cert_wire(Cert) of
        {ok, CertWire} ->
            case encode_entry_term({quod_entry, 1, Index, BlockBytes, CertWire}) of
                {ok, Bytes} -> {ok, mint_artifact(Bytes, View, Block)};
                {error, _} = Error -> Error
            end;
        error -> {error, bad_entry}
    end;
encode_entry_view(_, _) -> {error, bad_entry}.

mint_artifact(Bytes, View, Block) ->
    #canonical_entry{bytes = Bytes, view = View, block = Block}.

encode_entry_term(Term) ->
    case quod_safe_term:encode_canonical(
           Term, ?QUOD_TRANSPORT_MAX_FRAME_BYTES) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _} -> {error, bad_entry}
    end.

-spec decode_entry(binary()) -> {ok, entry_artifact()} | {error, bad_entry}.
decode_entry(Bytes) ->
    decode_entry(Bytes, materialized).

-spec decode_entry(binary(), materialized | wrapped) ->
          {ok, entry_artifact()} | {error, bad_entry}.
decode_entry(Bytes, SymbolMode)
  when is_binary(Bytes),
       byte_size(Bytes) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES,
       (SymbolMode =:= materialized orelse SymbolMode =:= wrapped) ->
    case {quod_safe_term:validate_canonical(
            Bytes, ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
          quod_safe_term:decode(
            Bytes, ?QUOD_TRANSPORT_MAX_FRAME_BYTES)} of
        {ok, {ok, {quod_entry, 1, Index, none, CertWire}}}
          when is_integer(Index), Index >= 1 ->
            case decode_cert_wire(CertWire, SymbolMode) of
                {ok, Cert} ->
                    {ok, mint_artifact(Bytes, #entry{index = Index, data = noop,
                                                    cert = Cert}, none)};
                error -> {error, bad_entry}
            end;
        {ok, {ok, {quod_entry, 1, Index, BlockBytes, CertWire}}}
          when is_integer(Index), Index >= 1, is_binary(BlockBytes) ->
            case {decode_block(BlockBytes, SymbolMode),
                  decode_cert_wire(CertWire, SymbolMode)} of
                {{ok, #block{slot = Index} = Block}, {ok, Cert}} ->
                    %% Both parent and implicit child have been decoded at
                    %% this boundary. Retain the exact envelope, not a new
                    %% serialization of their selected symbol interpretation.
                    {ok, mint_artifact(Bytes, entry_view_from_block(Block, Cert), Block)};
                _ ->
                    {error, bad_entry}
            end;
        _ ->
            {error, bad_entry}
    end;
decode_entry(_, _SymbolMode) ->
    {error, bad_entry}.

cert_wire(#implicit_cert{support = Support,
                         child = Child, commit = Commit}) ->
    case valid_block_view(Child) of
        true -> {ok, {implicit, Support, Child#block.block_bytes, Commit}};
        false -> error
    end;
%% This is the wire-only form. Accepting it as a native certificate view
%% would change that view on the first disk/wire decode of the same bytes.
cert_wire({implicit, _, _, _}) -> error;
cert_wire(Cert) -> {ok, Cert}.

decode_cert_wire({implicit, Support, ChildBytes, Commit}, SymbolMode)
  when is_binary(ChildBytes) ->
    case decode_block(ChildBytes, SymbolMode) of
        {ok, Child} ->
            {ok, #implicit_cert{support = Support,
                                child = Child, commit = Commit}};
        {error, _} -> error
    end;
%% An implicit child arrives only as bytes through the grammar above. Never
%% accept a serialized native child view as if this decoder had established it.
decode_cert_wire(#implicit_cert{}, _SymbolMode) -> error;
decode_cert_wire({implicit, _, _, _}, _SymbolMode) -> error;
decode_cert_wire(Cert, _SymbolMode) -> {ok, Cert}.
