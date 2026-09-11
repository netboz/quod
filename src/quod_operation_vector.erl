-module(quod_operation_vector).
-moduledoc """
Canonical target-keyed application references for source operation metadata.

Inclusion is not an execution verdict. Slice 7 deliberately has only the
`included` receipt arm; no committed/rejected label is inferred from a block
certificate. This module owns no state and does not dispatch operations.
""".

-include("quod_proof_limits.hrl").

-export([references/1, receipt/1, receipt_references/1, included/1,
         target/1, lookup/2]).

-type target() :: {binary(), <<_:256>>}.
-type application_ref() :: {transaction, binary(), <<_:256>>, <<_:256>>}.
-type receipt_row() :: {target(), {included, application_ref()}}.
-export_type([target/0, application_ref/0, receipt_row/0]).

-spec references(term()) -> {ok, [application_ref()]} | error.
references(Refs) when is_list(Refs), length(Refs) > 0,
                      length(Refs) =< ?QUOD_MAX_DTX_PARTICIPANTS ->
    case lists:all(fun valid_ref/1, Refs) of
        true ->
            Sorted = lists:sort(Refs),
            case unique_targets(Sorted, none) of
                true -> {ok, Sorted};
                false -> error
            end;
        false -> error
    end;
references(_) -> error.

-spec receipt(term()) -> {ok, [receipt_row()]} | error.
receipt(Rows) when is_list(Rows), length(Rows) > 0,
                   length(Rows) =< ?QUOD_MAX_DTX_PARTICIPANTS ->
    case receipt_refs(Rows, []) of
        {ok, Refs} ->
            case references(Refs) of
                {ok, Canonical} -> {ok, [{target(R), {included, R}} || R <- Canonical]};
                error -> error
            end;
        error -> error
    end;
receipt(_) -> error.

%% Validation paths insist on canonical stored bytes, not a normalized view
%% which would conceal a duplicate, omission or noncanonical target order.
-spec receipt_references(term()) -> {ok, [application_ref()]} | error.
receipt_references(Rows) ->
    case receipt(Rows) of
        {ok, Rows} -> {ok, [R || {_, {included, R}} <- Rows]};
        _ -> error
    end.

-spec included(term()) -> {ok, [receipt_row()]} | error.
included(Refs) ->
    case references(Refs) of
        {ok, Sorted} -> {ok, [{target(R), {included, R}} || R <- Sorted]};
        error -> error
    end.

-spec target(application_ref()) -> target().
target({transaction, Ns, Anchor, _TxId}) -> {Ns, Anchor}.

-spec lookup(target(), term()) -> {ok, application_ref()} | error.
lookup(Target, Refs) ->
    case references(Refs) of
        {ok, Refs} ->
            case [R || R <- Refs, target(R) =:= Target] of
                [Ref] -> {ok, Ref};
                [] -> error
            end;
        _ -> error
    end.

valid_ref({transaction, Ns, <<_:256>>, <<_:256>>}) ->
    is_binary(Ns) andalso byte_size(Ns) > 0;
valid_ref(_) -> false.

unique_targets([], _) -> true;
unique_targets([Ref | Rest], Previous) ->
    Target = target(Ref),
    Target =/= Previous andalso unique_targets(Rest, Target).

receipt_refs([], Refs) -> {ok, Refs};
receipt_refs([{Target, {included, Ref}} | Rest], Refs) ->
    case valid_ref(Ref) andalso target(Ref) =:= Target of
        true -> receipt_refs(Rest, [Ref | Refs]);
        false -> error
    end;
receipt_refs(_, _) -> error.
