-module(quod_ledger).
-moduledoc """
Canonical conversion between a consensus block payload and the value stored in one
durable ledger entry, plus the single enumeration of what a committed slot may carry.

The log is indexed by consensus slot, not by transaction. A slot may therefore hold
many transactions, represented on disk as `{batch, Transactions}`. Complaint-certified
skips use the distinct atom `noop` and are not block payloads.

`classify/1` is the one place the `entry_data()` variants are listed. Consumers that
react per variant — committee projection, author-sequence high-water, endpoint
learning, the apply fold — dispatch on its result and enumerate every kind
explicitly, with no catch-all. A variant added later (step 4's distributed control
records) is therefore introduced here once and fails loudly at every site that has
not yet decided what it means, instead of folding silently as nothing.

Malformed data is a separate, expected case: catch-up windows and replay walk
untrusted payloads, so `invalid` is a tolerated classification, not a crash.
""".

-include("quod_ledger.hrl").

-export([data/1, payload/1, classify/1]).

-export_type([kind/0]).

-type kind() :: {content, [#transaction{}]} | noop | invalid.

-spec data([#transaction{}]) -> {batch, [#transaction{}]}.
data([#transaction{} | _] = Transactions) ->
    {batch, Transactions}.

-doc """
Classify one committed slot's `data`:

- `{content, Transactions}` — a well-formed transaction batch;
- `noop` — a complaint-certified skip, carrying nothing to fold;
- `invalid` — not a recognized variant, or a batch that is not a proper
  transaction list (untrusted input reaches here, so this is tolerated).
""".
-spec classify(term()) -> kind().
classify({batch, [#transaction{} | _] = Transactions}) ->
    case transaction_list(Transactions) of
        true  -> {content, Transactions};
        false -> invalid
    end;
classify(noop) ->
    noop;
classify(_) ->
    invalid.

-doc "The transaction batch of a committed slot, or `error` for any other classification.".
-spec payload(term()) -> {ok, [#transaction{}]} | error.
payload(Data) ->
    case classify(Data) of
        {content, Transactions} -> {ok, Transactions};
        noop                    -> error;
        invalid                 -> error
    end.

transaction_list([#transaction{} | Rest]) -> transaction_list(Rest);
transaction_list([]) -> true;
transaction_list(_) -> false.
