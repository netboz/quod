-module(quod_atomic_admission).
-moduledoc """
The Simplex owner's single vote-selection FIFO.

Proof reservations and accepted role work are states of the same row, never
two queues. The journal owns responsibility before a proof may bind effects.
Activation supplies bound own material; cancellation or engine loss keeps
only the manifest, for ordinary deadline-refusal selection. This library
owns no process, monitor, timer, durable store or outcome authority.
Journaled votes return here when their selection binding changes. Their exact
envelope stays in that row until the sole writer reuses or supersedes it.

The owner passes a committed-parent key to the existing Prolog validator.
Unrelated callbacks cannot repeat that validation. A changed parent, engine
incarnation or deadline region enables another check; time is supplied by the
existing owner tick. An exact parent-application event releases a validation
which timed out behind that parent; the timer itself never retries it.
Missing material never blocks later ready rows.
""".

-include("quod_dtx_owner.hrl").
-include("quod_ingress_limits.hrl").
-export([new/0, reserve/5, activate/3, cancel/3, admit/4, recheck/2,
         selection_key/3, engine_lost/2, parent_applied/2,
         next/3, verdict/4, take/2, take_all/1, detach_waiter/2, contains/2,
         trace_context/2, counts/1, has_capacity/2]).
-export_type([state/0]).

-record(intent, {material, proof = none, waiters = #{}, trace = #{},
                 check = none, retained = none, order}).
%% The ordered tree contains group IDs only. Material and custody have one
%% location; arbitrary completion removes both indexes without queue tombstones.
-opaque state() :: {#{binary() => #intent{}}, gb_trees:tree(integer(), binary())}.

-doc "Create an empty owner-local admission FIFO.".
-spec new() -> state().
new() -> {#{}, gb_trees:empty()}.

-doc "Reserve sealed source material before private effects bind; do not activate it.".
-spec reserve(pid(), reference(), quod_atomic:admission_material(), map(), state()) ->
          {ok, state()} | {error, invalid_dtx_intent | busy}.
reserve(Engine, Token, Material, Trace, Rows = {ById, _}) ->
    Id = group(Material),
    case contains(Id, Rows) orelse lists:any(fun
        (#intent{proof = {_, Existing}}) -> Existing =:= Token;
        (_) -> false
    end, maps:values(ById)) of
        true -> {error, invalid_dtx_intent};
        false when map_size(ById) >= ?MAX_INGRESS_TXS -> {error, busy};
        false -> {ok, insert(#intent{material = Material,
                    proof = {Engine, Token}, trace = Trace}, Rows)}
    end.

-doc "Transfer the exact reservation to Simplex; the vote deadline now selects a vote, not deletion.".
-spec activate(pid(), reference(), state()) -> {none | quod_atomic:admission_material(), state()}.
activate(Engine, Token, Rows = {ById, _}) ->
    maps:fold(fun
        (Id, #intent{proof = {E, T}, material = M} = R, {none, Acc})
          when E =:= Engine, T =:= Token -> {M, put(Id, R#intent{proof = none}, Acc)};
        (_, _, Acc) -> Acc
    end, {none, Rows}, ById).

-doc "Drop preparation permission, never the already-durable source completion duty.".
-spec cancel(pid(), reference(), state()) -> state().
cancel(Engine, Token, Rows) ->
    map(fun(R) -> case R of
         #intent{proof = {Engine, Token}} -> abandon(R);
         _ -> R
     end end, Rows).

abandon(R = #intent{material = M}) ->
    R#intent{material = quod_atomic:source_presentation(M), proof = none, check = none}.

-doc "Accept own material or an O-only presentation; duplicates attach to the same row.".
-spec admit(quod_atomic:admission_material(), none | {dtx_endpoint, pid()}, map(), state()) -> state().
admit(Material, Waiter, Trace, Rows = {ById, _}) ->
    Id = group(Material),
    case maps:find(Id, ById) of
        error -> insert(#intent{material = Material, waiters = waiter(Waiter), trace = Trace}, Rows);
        {ok, R} ->
                %% An inbound duplicate cannot activate local private work.
                Chosen = case {R#intent.proof, R#intent.retained} of
                    {none, none} -> prefer_own_material(R#intent.material, Material);
                    _ -> R#intent.material
                end,
                Check = case Chosen =:= R#intent.material of true -> R#intent.check; false -> none end,
                put(Id, R#intent{material = Chosen, check = Check,
                         waiters = maps:merge(R#intent.waiters, waiter(Waiter))}, Rows)
    end.

-doc "Move a journaled local vote back into the same selection FIFO; retain its envelope for unchanged reuse.".
-spec recheck(#dtx_submission{}, state()) -> state().
recheck(Row = #dtx_submission{control = C, waiters = Waiters, trace_ctx = Trace}, Rows) ->
    false = contains(quod_atomic:group_id(C), Rows),
    insert(#intent{material = quod_atomic:control_material(C), waiters = Waiters,
                     trace = Trace, retained = Row}, Rows).

prefer_own_material({{quod_dtx_vote, _, _, _, none, _}, _, _},
                    {{quod_dtx_vote, _, _, _, Own, _}, _, _} = New)
  when Own =/= none -> New;
prefer_own_material(Old, _) -> Old.
waiter(none) -> #{};
waiter({dtx_endpoint, Pid}) when is_pid(Pid) -> #{Pid => true}.

-doc "Convert lost reservations to missing-material recovery; accepted work and callers survive.".
-spec engine_lost(none | pid(), state()) -> state().
engine_lost(Engine, Rows) ->
    map(fun(R) -> case R#intent.proof of
         {Engine, _} -> abandon(R);
         _ -> R#intent{check = none}
     end end, Rows).

-doc "Return eligible parent-validation requests once, preserving FIFO order without head blocking.".
-spec next(term(), integer(), state()) -> {[{binary(), {binary(), reference()} | selected, term(), map()}], state()}.
next(ParentKey, Now, {ById, Order}) ->
    {Next, Reverse} = lists:foldl(fun(Id, {Rows, Acc}) ->
        R = #intent{material = M, check = Check, trace = Trace} = maps:get(Id, Rows),
        case R#intent.proof of
          Proof when Proof =/= none -> {Rows, Acc};
          none ->
            Key = selection_key(ParentKey, Now, M),
            case Check of
                {selected, Key, _} -> {Rows, [{Id, selected, M, Trace} | Acc]};
                {_, Key, _} -> {Rows, Acc};
                _ ->
                    Tag = {Id, make_ref()},
                    {Rows#{Id := R#intent{check = {checking, Key, Tag}}},
                     [{Id, Tag, M, Trace} | Acc]}
            end
        end
    end, {ById, []}, gb_trees:values(Order)),
    {lists:reverse(Reverse), {Next, Order}}.

-doc "Bind one cached selection to the exact parent/engine and the immutable deadline region.".
-spec selection_key(term(), integer(), quod_atomic:admission_material()) -> term().
selection_key(ParentKey, Now, {_, _, #{group := #{vote_deadline_ms := Deadline}}}) ->
    {ParentKey, Now > Deadline}.

-doc "Cache a verdict for its exact parent; keep custody until the sole journal writer takes it.".
-spec verdict({binary(), reference()}, term(), term(), state()) ->
          {selected, map(), state()} | {waiting, state()} | stale.
verdict(Tag = {Id, _}, ParentKey, Result, Rows = {ById, _}) ->
    case maps:get(Id, ById, none) of
        #intent{material = Old, check = {checking, {ParentKey, _} = Key, Tag}} = Row ->
            case Result of
                {vote, Selected} ->
                    case quod_atomic:intent_id(Selected) =:= quod_atomic:intent_id(Old) of
                        true ->
                            Ready = Row#intent{material = Selected, check = {selected, Key, Tag}},
                            {selected, public(Ready), put(Id, Ready, Rows)};
                        false -> stale
                    end;
                _ ->
                    Status = case Result of await_parent -> await_parent; _ -> waiting end,
                    {waiting, put(Id, Row#intent{check = {Status, Key, Tag}}, Rows)}
            end;
        _ -> stale
    end.

-doc "Wake only requests waiting for this exact parent's application; a signal grants no vote.".
-spec parent_applied(term(), state()) -> state().
parent_applied(ParentKey, Rows = {ById, _}) ->
    maps:fold(fun
        (Id, R = #intent{check = {await_parent, {ParentKey0, _}, _}}, Acc)
          when ParentKey0 =:= ParentKey -> put(Id, R#intent{check = none}, Acc);
        (_, _, Acc) -> Acc
    end, Rows, ById).

-doc "Remove one group when its committed vote or terminal tombstone already exists.".
-spec take(binary(), state()) -> {map(), state()} | error.
take(Id, {ById, Order}) ->
    case maps:take(Id, ById) of
        {Row, Rest} -> {public(Row), {Rest, gb_trees:delete(Row#intent.order, Order)}};
        error -> error
    end.

public(#intent{material = M, waiters = Ws, trace = Trace, retained = Retained, check = Check}) ->
    Selection = case Check of {selected, Key, _} -> Key; _ -> none end,
    #{material => M, waiters => maps:keys(Ws), trace_ctx => Trace,
      retained => Retained, selection => Selection}.

-doc "Release all volatile work when the installed history removes this owner's admission; this declares no outcome.".
-spec take_all(state()) -> [map()].
take_all({ById, Order}) -> [public(maps:get(Id, ById)) || Id <- gb_trees:values(Order)].

insert(Row = #intent{material = M}, {ById, Order}) ->
    Id = group(M),
    Position = case gb_trees:is_empty(Order) of true -> 1; false -> element(1, gb_trees:largest(Order)) + 1 end,
    {ById#{Id => Row#intent{order = Position}}, gb_trees:insert(Position, Id, Order)}.
put(Id, Row, {ById, Order}) -> {ById#{Id := Row}, Order}.
map(Fun, {ById, Order}) -> {maps:map(fun(_, R) -> Fun(R) end, ById), Order}.

group({Record, _, _}) -> quod_atomic:group_id(Record).

-doc "Remove a departed caller without removing its accepted work or restarting validation.".
-spec detach_waiter(pid(), state()) -> state().
detach_waiter(Pid, Rows) ->
    map(fun(R) -> R#intent{waiters = maps:remove(Pid, R#intent.waiters)} end, Rows).

-doc "Test exact local group enrollment; this observation never determines an outcome.".
-spec contains(binary(), state()) -> boolean().
contains(Id, {ById, _}) -> maps:is_key(Id, ById).

-doc "Bound new volatile groups, not duplicate callers or journal-restored responsibilities.".
-spec has_capacity(binary(), state()) -> boolean().
has_capacity(Id, {ById, _}) -> maps:is_key(Id, ById) orelse map_size(ById) < ?MAX_INGRESS_TXS.

-doc "Read the original caller context from an existing admission row; never borrow ambient ancestry.".
-spec trace_context(binary(), state()) -> map().
trace_context(Id, {ById, _}) ->
    case maps:find(Id, ById) of
        {ok, #intent{trace = Context}} -> Context;
        error -> #{}
    end.

-doc "Return active/reserved counts from the one FIFO.".
-spec counts(state()) -> {non_neg_integer(), non_neg_integer()}.
counts({ById, _}) ->
    maps:fold(fun
        (_, #intent{proof = none}, {A, R}) -> {A + 1, R};
        (_, _, {A, R}) -> {A, R + 1}
    end, {0, 0}, ById).
