-module(quod_ledger).
-moduledoc """
The single enumeration of what one consensus block and committed ledger slot
may carry.

Blocks and entries share the same tagged payload: `{batch, Transactions}` for
ordinary content, or `{dtx, CanonicalControlBlob}` for one distributed-control
barrier. The log is indexed by consensus slot, not by transaction, so one
content slot may hold many transactions. Complaint-certified skips use the
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
              | {control_kind(), term()}
              | noop
              | invalid.

-doc """
Classify one committed slot's `data`:

- `{content, Transactions}` — a well-formed transaction batch;
- `{Kind, Control}` — one decoded, canonical DTX control, where `Kind` is
  `'begin'`, `prepare`, `decision`, `finalize`, or `complete`;
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
classify({dtx, Blob}) when is_binary(Blob) ->
    classify_control(Blob);
classify(noop) ->
    noop;
classify(_) ->
    invalid.

-doc "The transaction batch of a content slot, or `error` for DTX, noop, and invalid data.".
-spec payload(term()) -> {ok, [#transaction{}]} | error.
payload(Data) ->
    case classify(Data) of
        {content, Transactions} -> {ok, Transactions};
        {'begin', _Control}     -> error;
        {prepare, _Control}     -> error;
        {decision, _Control}    -> error;
        {finalize, _Control}    -> error;
        {complete, _Control}    -> error;
        noop                    -> error;
        invalid                 -> error
    end.

%% The total DTX decoder owns untrusted bytes. Only the five protocol kinds are
%% admitted; an unknown kind cannot become a ledger variant accidentally.
classify_control(Blob) ->
    case quod_dtx:decode_control(Blob) of
        {ok, Control} ->
            case quod_dtx:control_kind(Control) of
                'begin' -> {'begin', Control};
                prepare -> {prepare, Control};
                decision -> {decision, Control};
                finalize -> {finalize, Control};
                complete -> {complete, Control}
            end;
        {error, _Reason} ->
            invalid
    end.

transaction_list([#transaction{} | Rest]) -> transaction_list(Rest);
transaction_list([]) -> true;
transaction_list(_) -> false.
