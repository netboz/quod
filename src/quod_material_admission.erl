-module(quod_material_admission).
-moduledoc """
Pure material measurement and admission through the existing Prolog proof.

Callers retain the returned policy reads in their existing proof scope. Policy
is selected from its pinned committed state, never the proposed write. Historical
decoding has no admission dependency and retains only encoding and VM checks.
""".

-export([policy/2, validate_update/4, check/3, usage/1]).
-export_type([limits/0]).

-type limits() :: #{atom() => non_neg_integer() | unlimited}.

-spec policy(founding | plan | proof, tuple()) ->
          {ok, limits(), map()} | {error, term()}.
policy(Kind, Committed) ->
    select_policy(Kind, Committed, true).

%% Validate a proposed policy with the same read-only selector. Its reads are
%% not OCC tokens: admission still belongs to the published parent policy.
-spec validate_update(founding | plan | proof, tuple(), list(), map()) -> ok | {error, term()}.
validate_update(Kind, Committed, Diff, PolicyReads) ->
    case lists:any(fun(F) -> quod_read_set:kind(F) =:= predicate andalso
                             quod_diff:touches_functor(Diff, F) end,
                   maps:keys(PolicyReads)) of
        false -> ok;
        true ->
            {ok, Candidate} = quod_diff:apply_ops(Committed, Diff),
            case select_policy(Kind, Candidate, false) of
                {ok, _, _} -> ok;
                {error, _} = Error -> Error
            end
    end.

select_policy(Kind, Committed, CaptureReads) ->
    Context = quod_predicates:context(Committed),
    Strict = quod_predicates:policy_verdict_context(
               quod_predicates:ctx_ns(Context),
               case quod_predicates:ctx_height(Context) of
                   undefined -> 0;
                   Height -> Height
               end),
    Goal = {findall, {limit, {'Resource'}, {'Limit'}},
            {material_limit, Kind, {'Resource'}, {'Limit'}}, {'Limits'}},
    case quod_proof_session:run_first(
           Goal, quod_predicates:set_context(Committed, Strict),
           #{read_only => true, read_set => CaptureReads}) of
        {ok, #{'Limits' := Rows}, [], Reads} ->
            case valid_limits(Kind, Rows) of
                {ok, Limits} -> {ok, Limits, Reads};
                error -> {error, {invalid_material_policy, Kind}}
            end;
        _ -> {error, {invalid_material_policy, Kind}}
    end.

valid_limits(Kind, Rows) ->
    Keys = case Kind of
               founding -> [canonical_bytes, symbols];
               plan -> [canonical_bytes, operations, reads, symbols];
               proof -> [heap_bytes]
           end,
    Pairs = [{Resource, Limit} || {limit, Resource, Limit} <- Rows,
                Limit =:= unlimited orelse (is_integer(Limit) andalso Limit >= 0)],
    case length(Pairs) =:= length(Rows) andalso
         lists:sort([Key || {Key, _} <- Pairs]) =:= Keys of
        true -> {ok, maps:from_list(Pairs)};
        false -> error
    end.

-spec usage(term()) -> {ok, map()} | {error, term()}.
usage(Term) ->
    case {quod_wire_term:encode_canonical(Term),
          quod_wire_term:symbol_names(Term)} of
        {{ok, Bytes}, {ok, Names}} ->
            {ok, #{canonical_bytes => byte_size(Bytes), symbols => length(Names)}};
        _ -> {error, malformed_material}
    end.

-spec check(founding | plan | proof, map(), limits()) -> ok | {error, term()}.
check(Kind, Usage, Limits) ->
    check_resources(Kind, lists:sort(maps:to_list(Usage)), Limits).

check_resources(_Kind, [], _Limits) -> ok;
check_resources(Kind, [{Resource, Actual} | Rest], Limits) ->
    case maps:get(Resource, Limits) of
        unlimited -> check_resources(Kind, Rest, Limits);
        Limit when Actual =< Limit -> check_resources(Kind, Rest, Limits);
        Limit -> {error, {material_limit, Kind, Resource, Actual, Limit}}
    end.
