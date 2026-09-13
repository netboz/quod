-module(quod_operation_vector).
-moduledoc """
Canonical target-keyed application references and complete receipt vectors.

Inclusion is not an execution verdict. The included arm remains valid history;
new receipts carry exact application-result certificates. Shape checking here
does not grant signature authority: admission verifies every certificate against
its exact historical application. This module owns no state or dispatch.
""".

-include("quod_proof_limits.hrl").

-export([references/1, receipt/1, receipt_references/1, included/1,
         receipt_identity/1, same_receipt/2, certified/1, target/1, lookup/2,
         results/2, result_rows/1, aggregate/1]).

-type target() :: {binary(), <<_:256>>}.
-type application_ref() :: {transaction, binary(), <<_:256>>, <<_:256>>}.
-type receipt_row() :: {target(), {included, application_ref()}} |
        {target(), {certified, application_ref(),
                    quod_applied_certificate:operation_certificate()}}.
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
                {ok, _Canonical} -> {ok, lists:keysort(1, Rows)};
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
        {ok, Rows} ->
            {ok, Reversed} = receipt_refs(Rows, []),
            {ok, lists:reverse(Reversed)};
        _ -> error
    end.

%% Certificate proof subsets may differ between honest source replicas. The
%% receipt's semantic identity binds the outcome statement, not which valid
%% f+1 subset arrived first. Included rows keep their unchanged identity.
-spec receipt_identity(term()) -> {ok, list()} | error.
receipt_identity(Rows) ->
    case receipt_references(Rows) of
        {ok, _} -> {ok, [row_identity(Row) || Row <- Rows]};
        error -> error
    end.

-spec same_receipt(term(), term()) -> boolean().
same_receipt(A, B) ->
    case receipt_identity(A) of
        {ok, Identity} -> receipt_identity(B) =:= {ok, Identity};
        error -> false
    end.

row_identity({_Target, {included, _Ref}} = Row) -> Row;
row_identity({Target, {certified, Ref, Certificate}}) ->
    {ok, #{statement := Statement}} =
        quod_applied_certificate:operation_certificate_binding(Certificate),
    {Target, {certified, Ref, Statement}}.

-spec certified(term()) -> boolean().
certified(Rows) ->
    case receipt_references(Rows) of
        {ok, _} -> lists:all(fun({_, {certified, _, _}}) -> true;
                               (_) -> false
                            end, Rows);
        error -> false
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

%% Only an exact, complete target map can become a final result. The result
%% labels here have already passed the certificate authority boundary.
results(Refs, Results) when is_map(Results) ->
    case references(Refs) of
        {ok, Refs} when map_size(Results) =:= length(Refs) ->
            Rows = [{target(Ref), maps:get(target(Ref), Results, pending)} || Ref <- Refs],
            case result_rows(Rows) of
                {ok, Refs} -> {ok, Rows};
                _ -> pending
            end;
        _ -> pending
    end.

result_rows(Rows) when is_list(Rows) ->
    try
        Refs = [begin
            true = valid_ref(Ref) andalso target(Ref) =:= Target,
            true = valid_result_label(Result),
            Ref
        end || {Target, {Result, Ref}} <- Rows],
        true = length(Refs) =:= length(Rows),
        {ok, Refs} = references(Refs),
        {ok, Refs}
    catch _:_ -> error
    end;
result_rows(_) -> error.

valid_result_label(committed) -> true;
valid_result_label({rejected, _} = Result) ->
    quod_applied_certificate:valid_operation_result(Result);
valid_result_label(_) -> false.

aggregate(Rows) ->
    {ok, _} = result_rows(Rows),
    Applied = length([ok || {_, {committed, _}} <- Rows]),
    case Applied of
        0 -> all_rejected;
        N when N =:= length(Rows) -> all_applied;
        _ -> mixed
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
receipt_refs([{Target, {certified, Ref, Certificate}} | Rest], Refs) ->
    case quod_applied_certificate:operation_certificate_binding(Certificate) of
        {ok, #{target := Target, application_ref := Ref}} ->
            receipt_refs(Rest, [Ref | Refs]);
        _ -> error
    end;
receipt_refs(_, _) -> error.
