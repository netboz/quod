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

Malformed data is a separate, expected case: catch-up windows and replay walk
untrusted payloads, so `invalid` is a tolerated classification, not a crash.
""".

-include("quod_ledger.hrl").

-export([payload/1, classify/1]).

-export_type([kind/0]).

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
