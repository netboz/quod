-module(quod_ledger).
-moduledoc """
Canonical conversion between a consensus block payload and the value stored in one
durable ledger entry.

The log is indexed by consensus slot, not by transaction. A slot may therefore hold
many transactions, represented on disk as `{batch, Transactions}`. Complaint-certified
skips use the distinct atom `noop` and are not block payloads.
""".

-include("quod_ledger.hrl").

-export([data/1, payload/1]).

-spec data([#transaction{}]) -> {batch, [#transaction{}]}.
data([#transaction{} | _] = Transactions) ->
    {batch, Transactions}.

-spec payload(term()) -> {ok, [#transaction{}]} | error.
payload({batch, [#transaction{} | _] = Transactions}) ->
    case transaction_list(Transactions) of
        true  -> {ok, Transactions};
        false -> error
    end;
payload(_) ->
    error.

transaction_list([#transaction{} | Rest]) -> transaction_list(Rest);
transaction_list([]) -> true;
transaction_list(_) -> false.
