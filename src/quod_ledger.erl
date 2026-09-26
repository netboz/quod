-module(quod_ledger).
-moduledoc """
The single enumeration of what one consensus block and committed ledger slot
may carry.

Blocks and entries have one tagged payload family: `{batch, Items}`.  A batch
contains either ordinary transactions or canonical DTX-control envelopes, never
both. Protocol blocks additionally admit `empty`. A control batch contains one protocol phase in strict signed-journal order.
The log is indexed by material height, independently of protocol views. One
entry may carry many transactions or independent controls. Empty protocol
carriers carry proof only; they never become entries or ontology changes.

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
-include("quod_proof_limits.hrl").

-export([payload/1, classify/1,
         encoded_payload_size/1,
         new_block/4, decode_block/1, decode_block/2, decode_block/3,
         block_ref/1, block_parent/1, initial_era/1, next_era/3,
         encode_finality_head/1, decode_finality_head/1,
         block_bytes/1, valid_block_view/1,
         entry/3, block_from_entry/1, entry_block_hash/1,
         entry_view/1, from_entry_view/1,
         encode_entry/1, decode_entry/1, decode_entry/2, decode_entry/3,
         select_entry/3, selected_record/1, entry_index/1, record_commitment/2,
         hint_bytes/1]).

-export_type([kind/0, entry_artifact/0, selected_entry/0]).

%% One canonical envelope and the interpretations established at its checked
%% construction/decoding boundary. This is process-local data, never a wire or
%% disk term, and carries no assertion of finality or committee authority.
-record(canonical_entry, {bytes :: binary(), view :: #entry{},
                          block :: #block{}}).
-opaque entry_artifact() :: #canonical_entry{}.

%% A point reader authenticates only its selected item. This value cannot be
%% appended, replayed or mistaken for a fully materialized artifact. Original
%% envelope bytes may be forwarded as an untrusted hint; importing that hint
%% into history still requires full decoding and forward verification.
%% Finality still binds the hash of ALL the original block bytes.
-record(selected_entry, {index, hash, cert, count, record = none, bytes}).
-opaque selected_entry() :: #selected_entry{}.

-type control_kind() :: vote | resolve | complete.
-type kind() :: {content, [#transaction{}]}
              | {controls, [{control_kind(), term()}]}
              | empty
              | invalid.

-doc """
Classify one committed slot's `data`:

- `{content, Transactions}` — a well-formed transaction batch;
- `{controls, Controls}` — decoded canonical DTX controls from one phase in
  strict signed-journal order;
- `empty` — a protocol carrier, inadmissible as a material entry;
- `invalid` — not a recognized native variant or a malformed batch.

Control payloads carry codec-created material, not wire blobs. Byte ingress
authenticates each control in the payload decoder; classification and serialization
do not discard that result and repeat its signature/plan walk.
""".
-spec classify(term()) -> kind().
classify({batch, [#transaction{} | _] = Transactions}) ->
    case transaction_list(Transactions) of
        true  -> {content, Transactions};
        false -> invalid
    end;
classify({batch, [{dtx, _Control} | _] = Items}) ->
    classify_controls(Items);
classify(empty) ->
    empty;
classify(_) ->
    invalid.

-doc "The transaction batch of a content slot, or `error` for DTX, empty carriers, and invalid data.".
-spec payload(term()) -> {ok, [#transaction{}]} | error.
payload(Data) ->
    case classify(Data) of
        {content, Transactions} -> {ok, Transactions};
        {controls, _Controls}   -> error;
        empty                   -> error;
        invalid                 -> error
    end.

%% These opaque controls have crossed their codec boundary, like the native
%% transactions above. The batch check owns phase, target and signed-lane order.
classify_controls(Items) ->
    try
        Controls = [Control || {dtx, Control} <- Items],
        case length(Controls) =:= length(Items) andalso
             quod_atomic:canonical_control_wave(Controls) of
            true -> {controls, [{quod_atomic:control_kind(C), C} || C <- Controls]};
            false -> invalid
        end
    catch
        _:_ -> invalid
    end.

transaction_list([#transaction{} | Rest]) -> transaction_list(Rest);
transaction_list([]) -> true;
transaction_list(_) -> false.

%% The block's byte form is the consensus identity. `#block{}` is only the
%% materialized local view used by the engine and reducers.
-spec new_block({consensus_era(), slot()}, none | protocol_ref(),
                block_payload(), non_neg_integer()) ->
          {ok, #block{}} | {error, bad_block}.
new_block({Era, View}, Parent, Payload, Timestamp) ->
    case valid_position(Era, View, Parent, Timestamp) andalso
         not (Era =:= genesis andalso Payload =:= empty) of
        true ->
            case encode_payload(Payload) of
                {ok, PayloadWire} ->
                    case {quod_safe_term:encode_canonical(PayloadWire, ?MAX_BLOCK_BYTES),
                          quod_safe_term:encode_canonical(
                            {quod_block, 2, Era, View, Parent, PayloadWire, Timestamp},
                            ?QUOD_MAX_CANONICAL_BLOCK_BYTES)} of
                        {{ok, _}, {ok, Bytes}} ->
                            {ok, #block{era = Era, slot = View, parent = Parent,
                                        payload = Payload, timestamp = Timestamp,
                                        block_bytes = Bytes}};
                        _ -> {error, bad_block}
                    end;
                error -> {error, bad_block}
            end;
        false -> {error, bad_block}
    end;
new_block(_, _, _, _) -> {error, bad_block}.

valid_position(genesis, 0, none, 0) -> true;
valid_position(<<_:256>> = Era, View, {Era, ParentView, <<_:256>>}, Timestamp)
  when is_integer(View), View > 0, View =< 16#FFFFFFFFFFFFFFFF,
       is_integer(ParentView), ParentView >= 0, ParentView < View,
       is_integer(Timestamp), Timestamp >= 0 -> true;
valid_position(_, _, _, _) -> false.

-doc "The exact protocol identity; its numeric view is never a ledger index.".
-spec block_ref(#block{}) -> protocol_ref().
block_ref(#block{era = Era, slot = View, block_bytes = Bytes}) when is_binary(Bytes) ->
    {Era, View, crypto:hash(sha256, Bytes)}.

-doc "Derive the first era only after the genesis bytes and anchor exist.".
-spec initial_era({binary(), <<_:256>>}) -> <<_:256>>.
initial_era({Ns, <<_:256>> = Anchor} = Identity) when is_binary(Ns), byte_size(Ns) > 0 ->
    era_digest(Identity, genesis, Anchor).

-doc "A terminal material block determines the next era, independently of its finality witness.".
-spec next_era({binary(), <<_:256>>}, <<_:256>>, <<_:256>>) -> <<_:256>>.
next_era({Ns, <<_:256>>} = Identity, <<_:256>> = Era, <<_:256>> = MembershipHash)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    era_digest(Identity, Era, MembershipHash).

era_digest(Identity, ParentEra, RootHash) ->
    crypto:hash(sha256, term_to_binary(
      {quod_consensus_era, 1, Identity, ParentEra, RootHash}, [deterministic])).

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
decode_block(Bytes, SymbolMode) ->
    decoded_result(decode_block(Bytes, SymbolMode, quod_transaction:decode_context())).

-doc "Decode using the same bounded call-local transaction context as adjacent entries; this grants no finality authority.".
-spec decode_block(binary(), materialized | wrapped, quod_transaction:decode_context()) ->
          {ok, #block{}, quod_transaction:decode_context()} | {error, bad_block}.
decode_block(Bytes, SymbolMode, Context)
  when SymbolMode =:= materialized; SymbolMode =:= wrapped ->
    case block_envelope(Bytes) of
        {ok, {quod_block, 2, Era, Slot, Parent, PayloadWire, Timestamp}} ->
            case decode_payload(PayloadWire, SymbolMode, Context) of
                {ok, Payload, Next} ->
                    {ok, #block{era = Era, slot = Slot, parent = Parent,
                                payload = Payload, timestamp = Timestamp,
                                block_bytes = Bytes}, Next};
                error -> {error, bad_block}
            end;
        error -> {error, bad_block}
    end;
decode_block(_Bytes, _SymbolMode, _Context) -> {error, bad_block}.

block_envelope(Bytes)
  when is_binary(Bytes), byte_size(Bytes) =< ?QUOD_MAX_CANONICAL_BLOCK_BYTES ->
    case {quod_safe_term:validate_canonical(Bytes, ?QUOD_MAX_CANONICAL_BLOCK_BYTES),
          quod_safe_term:decode(Bytes, ?QUOD_MAX_CANONICAL_BLOCK_BYTES)} of
        {ok, {ok, {quod_block, 2, Era, View, Parent, Payload, Timestamp} = Wire}} ->
            case valid_position(Era, View, Parent, Timestamp) andalso
                 not (Era =:= genesis andalso Payload =:= empty) of
                true -> {ok, Wire};
                false -> error
            end;
        _ -> error
    end;
block_envelope(_) -> error.

-doc "Read a canonical block's parent for opaque archive transport; this does not authenticate its payload or finality.".
-spec block_parent(binary()) -> {ok, none | protocol_ref()} | {error, bad_block}.
block_parent(Bytes) ->
    case block_envelope(Bytes) of
        {ok, {quod_block, 2, _Era, _View, Parent, _Payload, _Timestamp}} -> {ok, Parent};
        error -> {error, bad_block}
    end.

-spec block_bytes(#block{}) -> binary() | error.
block_bytes(#block{block_bytes = Bytes}) when is_binary(Bytes) -> Bytes;
block_bytes(#block{}) -> error.

-doc "Check canonical byte binding and both byte limits through the block constructor.".
-spec valid_block_view(term()) -> boolean().
valid_block_view(#block{era = Era, slot = Slot, parent = Parent, payload = Payload,
                         timestamp = Timestamp, block_bytes = Bytes}) when is_binary(Bytes) ->
    case new_block({Era, Slot}, Parent, Payload, Timestamp) of
        {ok, #block{block_bytes = Bytes}} -> true;
        _ -> false
    end;
valid_block_view(_) -> false.

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
        {controls, Controls} ->
            try
                {ok, {batch, [begin
                    {ok, Blob} = quod_atomic:encode_control(Control), {dtx, Blob}
                end || {_, Control} <- Controls]}}
            catch _:_ -> error end;
        empty ->
            {ok, empty};
        invalid ->
            error
    end.

decode_payload(empty, _SymbolMode, Context) -> {ok, empty, Context};
decode_payload({batch, [{transaction, Blob} | _] = Items}, SymbolMode, Context)
  when is_binary(Blob) ->
    try
        {Transactions, Next} = lists:mapfoldl(fun({transaction, TxBlob}, Acc) ->
            {ok, #transaction{} = Tx, Decoded} =
                quod_transaction:decode_ledger_transaction(TxBlob, SymbolMode, Acc),
            {Tx, Decoded}
        end, Context, Items),
        {ok, {batch, Transactions}, Next}
    catch
        _:_ -> error
    end;
decode_payload({batch, [{dtx, Blob} | _] = Items}, _SymbolMode, Context)
  when is_binary(Blob) ->
    try
        Controls = [begin
            {dtx, Bytes} = Item,
            {ok, Control} = quod_atomic:decode_control(Bytes), {dtx, Control}
        end || Item <- Items],
        Payload = {batch, Controls},
        case classify(Payload) of
            {controls, _} -> {ok, Payload, Context};
            _ -> error
        end
    catch _:_ -> error end;
decode_payload(_, _SymbolMode, _Context) ->
    error.

-doc "Bind a material height to an exact block and compact finality descriptor.".
-spec entry(pos_integer(), #block{}, none | #cert{}) -> entry_artifact().
entry(Index, #block{} = Block, Cert) ->
    true = valid_block_view(Block),
    true = valid_entry_binding(Index, Block, Cert),
    {ok, Artifact} = encode_entry_view(entry_view_from_block(Index, Block, Cert), Block),
    Artifact.

entry_view_from_block(Index,
  #block{payload = Payload, timestamp = Timestamp, block_bytes = Bytes}, Cert) ->
    #entry{index = Index, data = Payload, timestamp = Timestamp,
           block_bytes = Bytes, cert = Cert}.

valid_entry_binding(1, #block{era = genesis, slot = 0, parent = none,
                               payload = {batch, [_ | _]}, timestamp = 0}, none) -> true;
valid_entry_binding(Index, #block{era = Era, slot = View, payload = {batch, [_ | _]}} = Block,
                    #cert{era = Era, kind = commit, slot = HeadView, block_hash = Hash})
  when is_integer(Index), Index > 1, is_binary(Era), byte_size(Era) =:= 32,
       is_integer(HeadView), HeadView > 0, HeadView =< 16#FFFFFFFFFFFFFFFF ->
    HeadView > View orelse (HeadView =:= View andalso block_ref(Block) =:= {Era, View, Hash});
valid_entry_binding(_, _, _) -> false.

-doc "Read the already-bound interpretation; never reconstruct or authenticate it.".
-spec entry_view(entry_artifact()) -> #entry{}.
entry_view(#canonical_entry{view = View}) -> View.

-spec block_from_entry(term()) -> {ok, #block{}} | error.
block_from_entry(#canonical_entry{block = #block{} = Block}) -> {ok, Block};
block_from_entry(_) -> error.

-doc "Read an opaque entry's block hash for archive transport; this authenticates neither its payload nor finality.".
-spec entry_block_hash(binary()) -> {ok, <<_:256>>} | {error, bad_entry}.
entry_block_hash(Bytes) ->
    case entry_wire(Bytes) of
        {ok, _, BlockBytes, _} ->
            case block_envelope(BlockBytes) of
                {ok, _} -> {ok, crypto:hash(sha256, BlockBytes)};
                error -> {error, bad_entry}
            end;
        error -> {error, bad_entry}
    end.

-doc """
Checked import of the native prepared-genesis view retained in lifecycle
descriptors. This is a constructor, not a raw-record append or fast path.
The caller still verifies the prepared identity, author and genesis anchor.
""".
-spec from_entry_view(term()) -> {ok, entry_artifact()} | {error, bad_entry}.
from_entry_view(#entry{index = Index} = View)
  when is_integer(Index), Index >= 1 ->
    case import_entry_block(View) of
        {ok, Block} ->
            case valid_entry_binding(Index, Block, View#entry.cert) of
                true -> encode_entry_view(View, Block);
                false -> {error, bad_entry}
            end;
        error -> {error, bad_entry}
    end;
from_entry_view(_) -> {error, bad_entry}.

import_entry_block(
  #entry{data = Data, timestamp = Timestamp,
         block_bytes = Bytes})
  when is_binary(Bytes) ->
    %% Only the checked native-view import needs to recover a parent this way.
    %% Re-encoding binds either symbol interpretation to the same bytes; the
    %% public block accessor above never repeats these checks.
    case decode_block(Bytes, wrapped) of
        {ok, #block{timestamp = Timestamp} = Decoded} ->
            Block = Decoded#block{payload = Data},
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
            case encode_entry_term({quod_entry, 2, Index, BlockBytes, CertWire}) of
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
decode_entry(Bytes, SymbolMode) ->
    decoded_result(decode_entry(Bytes, SymbolMode, quod_transaction:decode_context())).

-doc "Decode one entry in a bounded page's transaction context; discard that context on page return or failure.".
-spec decode_entry(binary(), materialized | wrapped, quod_transaction:decode_context()) ->
          {ok, entry_artifact(), quod_transaction:decode_context()} | {error, bad_entry}.
decode_entry(Bytes, SymbolMode, Context)
  when SymbolMode =:= materialized; SymbolMode =:= wrapped ->
    case entry_envelope(Bytes, SymbolMode, Context) of
        {ok, {Index, BlockBytes, Cert}, Next} ->
            case decode_block(BlockBytes, SymbolMode, Next) of
                {ok, Block, Decoded} ->
                    case valid_entry_binding(Index, Block, Cert) of
                        true -> {ok, mint_artifact(Bytes,
                                  entry_view_from_block(Index, Block, Cert), Block), Decoded};
                        false -> {error, bad_entry}
                    end;
                _ ->
                    {error, bad_entry}
            end;
        _ ->
            {error, bad_entry}
    end;
decode_entry(_, _SymbolMode, _Context) ->
    {error, bad_entry}.

entry_envelope(Bytes, Mode, Context) ->
    case entry_wire(Bytes) of
        {ok, I, BlockBytes, CertWire} ->
            case decode_cert_wire(CertWire, Mode, Context) of
                {ok, Cert, Next} -> {ok, {I, BlockBytes, Cert}, Next};
                error -> error
            end;
        error -> error
    end.

entry_wire(Bytes) when is_binary(Bytes),
                       byte_size(Bytes) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    case {quod_safe_term:validate_canonical(Bytes, ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
          quod_safe_term:decode(Bytes, ?QUOD_TRANSPORT_MAX_FRAME_BYTES)} of
        {ok, {ok, {quod_entry, 2, I, BlockBytes, CertWire}}}
          when is_integer(I), I >= 1, is_binary(BlockBytes) ->
            {ok, I, BlockBytes, CertWire};
        _ -> error
    end;
entry_wire(_) -> error.

-doc "Select one exact item from checked history or canonical bytes; never mint a partial full-entry artifact.".
-spec select_entry(binary() | entry_artifact() | selected_entry(), term(), materialized | wrapped) ->
          {ok, selected_entry()} | {error, bad_entry}.
select_entry(#selected_entry{record = Record} = Entry, Selection, _Mode) ->
    case Record =/= none andalso selected_match(Selection, Record) of
        true -> {ok, Entry};
        false -> {ok, Entry#selected_entry{record = none}}
    end;
select_entry(#canonical_entry{bytes = Bytes, view = #entry{index = I, data = Data, cert = Cert},
                              block = Block}, Selection, _Mode) ->
    {ok, (selected(I, entry_hash(Block), Cert, Data, Selection))#selected_entry{bytes = Bytes}};
select_entry(Bytes, Selection, Mode) when Mode =:= materialized; Mode =:= wrapped ->
    case entry_envelope(Bytes, Mode, quod_transaction:decode_context()) of
        {ok, {I, BlockBytes, Cert}, Context} ->
            case block_envelope(BlockBytes) of
                {ok, {quod_block, 2, Era, View, Parent, Wire, Timestamp}} ->
                    Block = #block{era = Era, slot = View, parent = Parent,
                                   payload = Wire, timestamp = Timestamp,
                                   block_bytes = BlockBytes},
                    case valid_entry_binding(I, Block, Cert) andalso
                         selected_payload(Wire, Selection, Mode, Context) of
                        {ok, Count, Record} ->
                            {ok, #selected_entry{index = I,
                              hash = crypto:hash(sha256, BlockBytes), cert = Cert,
                              count = Count, record = Record, bytes = Bytes}};
                        _ -> {error, bad_entry}
                    end;
                _ -> {error, bad_entry}
            end;
        _ -> {error, bad_entry}
    end;
select_entry(_, _, _) -> {error, bad_entry}.

-doc "Extract original envelope bytes for bounded, untrusted evidence transport; this grants no append authority.".
-spec hint_bytes(entry_artifact() | selected_entry()) -> {ok, binary()} | {error, bad_entry}.
hint_bytes(#selected_entry{bytes = Bytes}) when is_binary(Bytes) -> {ok, Bytes};
hint_bytes(Entry) -> encode_entry(Entry).

selected_payload({batch, [{transaction, _} | _] = Items}, Selection, Mode, Context) ->
    try
        Blobs = [B || {transaction, B} <- Items, is_binary(B)],
        true = length(Blobs) =:= length(Items),
        Matches = [B || B <- Blobs, quod_transaction:matches_selection(Selection, B)],
        Record = case Matches of
            [Blob] -> {ok, Tx, _} = quod_transaction:decode_ledger_transaction(Blob, Mode, Context), Tx;
            _ -> none
        end,
        {ok, length(Items), Record}
    catch _:_ -> error end;
selected_payload(Wire, Selection, Mode, Context) ->
    %% Controls have a whole-wave ordering invariant. Keep its one validator;
    %% selective transaction decoding does not weaken that separate grammar.
    case decode_payload(Wire, Mode, Context) of
        {ok, {batch, Items}, _Next} -> {ok, length(Items), select_record(Items, Selection)};
        error -> error
    end.

selected(I, Hash, Cert, {batch, Items}, Selection) ->
    #selected_entry{index = I, hash = Hash, cert = Cert, count = length(Items),
                    record = select_record(Items, Selection)}.

select_record(Items, Selection) ->
    case [R || Item <- Items, R <- [item_record(Item)], selected_match(Selection, R)] of
        [Record] -> Record;
        _ -> none
    end.
item_record({dtx, Control}) -> Control;
item_record(Tx = #transaction{}) -> Tx.

selected_match({record, #transaction{tx_id = Id}}, #transaction{tx_id = Id}) -> true;
selected_match({record, R}, R) -> true;
selected_match({record, _}, _) -> false;
selected_match(Selection, Tx = #transaction{}) -> quod_transaction:matches_selection(Selection, Tx);
selected_match({digest, _, Digest}, Control) -> quod_atomic:record_digest(Control) =:= Digest;
selected_match(_, _) -> false.

entry_hash(#block{block_bytes = Bytes}) -> crypto:hash(sha256, Bytes).

-doc "Read the single selected authenticated record; missing or ambiguous matches return none.".
-spec selected_record(selected_entry()) -> term().
selected_record(#selected_entry{record = Record}) -> Record.

-doc "Read an artifact's index, or only the canonical outer index of untrusted transport bytes; the latter grants no decoding or append authority.".
-spec entry_index(entry_artifact() | selected_entry() | binary()) -> pos_integer().
entry_index(#canonical_entry{view = #entry{index = I}}) -> I;
entry_index(#selected_entry{index = I}) -> I;
entry_index(Bytes) when is_binary(Bytes) ->
    case entry_wire(Bytes) of
        {ok, I, _, _} -> I;
        error -> error(bad_entry)
    end.

-doc "Bind an exact unique record to its full block hash, certificate and item count, without asserting finality.".
-spec record_commitment(entry_artifact() | selected_entry(), term()) ->
          {ok, pos_integer(), binary() | none, term(), non_neg_integer()} | error.
record_commitment(#canonical_entry{} = Entry, Record) ->
    {ok, Selected} = select_entry(Entry, {record, Record}, wrapped),
    record_commitment(Selected, Record);
record_commitment(#selected_entry{record = Record, index = I, hash = Hash,
                                  cert = Cert, count = Count}, Record)
  when Record =/= none -> {ok, I, Hash, Cert, Count};
record_commitment(_, _) -> error.

-doc "Encode the compact preferred witness head with the ledger's one certificate grammar.".
-spec encode_finality_head(#cert{}) -> {ok, binary()} | {error, bad_finality_head}.
encode_finality_head(#cert{} = Cert) ->
    case cert_wire(Cert) of
        {ok, Wire} ->
            case quod_safe_term:encode_canonical(Wire, ?QUOD_MAX_DTX_BODY_BYTES) of
                {ok, _} = Result -> Result;
                _ -> {error, bad_finality_head}
            end;
        error -> {error, bad_finality_head}
    end;
encode_finality_head(_) -> {error, bad_finality_head}.

-doc "Decode a canonical head descriptor without creating symbols or asserting finality.".
-spec decode_finality_head(binary()) -> {ok, #cert{}} | {error, bad_finality_head}.
decode_finality_head(Bytes) ->
    case quod_safe_term:decode_wrapped(Bytes, ?QUOD_MAX_DTX_BODY_BYTES) of
        {ok, Wire} ->
            case decode_cert_wire(Wire, wrapped, none) of
                {ok, #cert{} = Cert, none} -> {ok, Cert};
                _ -> {error, bad_finality_head}
            end;
        _ -> {error, bad_finality_head}
    end.

cert_wire(none) -> {ok, none};
cert_wire(#cert{kind = commit, era = <<_:256>> = Era, slot = View,
                block_hash = <<_:256>> = Hash, sigs = Sigs})
  when is_integer(View), View > 0, View =< 16#FFFFFFFFFFFFFFFF ->
    case quod_quorum:canonical_signatures(Sigs) of
        true -> {ok, {quod_finality, 1, Era, View, Hash, Sigs}};
        false -> error
    end;
cert_wire(_) -> error.

decode_cert_wire(none, _Mode, Context) -> {ok, none, Context};
decode_cert_wire({quod_finality, 1, <<_:256>> = Era, View, <<_:256>> = Hash, Sigs},
                 _Mode, Context)
  when is_integer(View), View > 0, View =< 16#FFFFFFFFFFFFFFFF ->
    case quod_quorum:canonical_signatures(Sigs) of
        true -> {ok, #cert{kind = commit, era = Era, slot = View,
                           block_hash = Hash, sigs = Sigs}, Context};
        false -> error
    end;
decode_cert_wire(_, _, _) -> error.

decoded_result({ok, Value, _Context}) -> {ok, Value};
decoded_result({error, _} = Error) -> Error.
