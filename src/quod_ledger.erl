-module(quod_ledger).
-moduledoc """
Canonical conversion between a consensus block payload and the value stored in one
durable ledger entry.

The log is indexed by consensus slot, not by transaction. A slot may therefore hold
many transactions, represented on disk as `{batch, Transactions}`. Legacy stores used
a bare `#transaction{}` for singleton blocks; `payload/1` accepts both shapes so the
format change needs no rewrite.
""".

-include("quod_ledger.hrl").

-export([data/1, payload/1]).

-spec data([#transaction{}]) -> {batch, [#transaction{}]}.
data([#transaction{} | _] = Transactions) ->
    {batch, Transactions}.

-spec payload(term()) -> {ok, [#transaction{}] | [noop]} | error.
payload(#transaction{} = Transaction) ->
    {ok, [Transaction]};
payload({batch, [#transaction{} | _] = Transactions}) ->
    case transaction_list(Transactions) of
        true  -> {ok, Transactions};
        false -> error
    end;
payload(noop) ->
    %% Legacy explicit empty blocks stored the same atom as complaint-skipped slots.
    %% The certificate kind distinguishes the two during catch-up verification.
    {ok, [noop]};
payload(_) ->
    error.

transaction_list([#transaction{} | Rest]) -> transaction_list(Rest);
transaction_list([]) -> true;
transaction_list(_) -> false.
