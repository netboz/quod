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
existing owner tick. Missing material never blocks later ready rows.
""".

-include("quod_dtx_owner.hrl").
-export([new/0, reserve/5, activate/3, cancel/3, admit/4, recheck/2,
         selection_key/3, engine_lost/2,
         next/3, verdict/4, take/2, take_all/1, detach_waiter/2, contains/2,
         trace_context/2, counts/1]).
-export_type([state/0]).

-record(intent, {material, proof = none, waiters = #{}, trace = #{},
                 check = none, retained = none}).
-opaque state() :: [#intent{}].

-doc "Create an empty owner-local admission FIFO.".
-spec new() -> state().
new() -> [].

-doc "Reserve sealed source material before private effects bind; do not activate it.".
-spec reserve(pid(), reference(), quod_atomic:admission_material(), map(), state()) ->
          {ok, state()} | {error, invalid_dtx_intent}.
reserve(Engine, Token, Material, Trace, Rows) ->
    Id = group(Material),
    case contains(Id, Rows) orelse lists:any(fun
        (#intent{proof = {_, Existing}}) -> Existing =:= Token;
        (_) -> false
    end, Rows) of
        true -> {error, invalid_dtx_intent};
        false -> {ok, Rows ++ [#intent{material = Material,
                    proof = {Engine, Token}, trace = Trace}]}
    end.

-doc "Transfer the exact reservation to Simplex; the vote deadline now selects a vote, not deletion.".
-spec activate(pid(), reference(), state()) -> {none | quod_atomic:admission_material(), state()}.
activate(Engine, Token, Rows) ->
    {Updated, Material} = lists:mapfoldl(fun
        (#intent{proof = {E, T}, material = M} = R, none) when E =:= Engine, T =:= Token ->
            {R#intent{proof = none}, M};
        (R, Acc) -> {R, Acc}
    end, none, Rows),
    {Material, Updated}.

-doc "Drop preparation permission, never the already-durable source completion duty.".
-spec cancel(pid(), reference(), state()) -> state().
cancel(Engine, Token, Rows) ->
    [case R of
         #intent{proof = {Engine, Token}} -> abandon(R);
         _ -> R
     end || R <- Rows].

abandon(R = #intent{material = M}) ->
    R#intent{material = quod_atomic:source_presentation(M), proof = none, check = none}.

-doc "Accept own material or an O-only presentation; duplicates attach to the same row.".
-spec admit(quod_atomic:admission_material(), none | {dtx_endpoint, pid()}, map(), state()) -> state().
admit(Material, Waiter, Trace, Rows) ->
    Id = group(Material),
    case contains(Id, Rows) of
        false -> Rows ++ [#intent{material = Material, waiters = waiter(Waiter), trace = Trace}];
        true -> [case group(R#intent.material) =:= Id of
            false -> R;
            true ->
                %% An inbound duplicate cannot activate local private work.
                Chosen = case {R#intent.proof, R#intent.retained} of
                    {none, none} -> prefer_own_material(R#intent.material, Material);
                    _ -> R#intent.material
                end,
                Check = case Chosen =:= R#intent.material of true -> R#intent.check; false -> none end,
                R#intent{material = Chosen, check = Check,
                         waiters = maps:merge(R#intent.waiters, waiter(Waiter))}
        end || R <- Rows]
    end.

-doc "Move a journaled local vote back into the same selection FIFO; retain its envelope for unchanged reuse.".
-spec recheck(#dtx_submission{}, state()) -> state().
recheck(Row = #dtx_submission{control = C, waiters = Waiters, trace_ctx = Trace}, Rows) ->
    false = contains(quod_atomic:group_id(C), Rows),
    Rows ++ [#intent{material = quod_atomic:control_material(C), waiters = Waiters,
                     trace = Trace, retained = Row}].

prefer_own_material({{quod_dtx_vote, _, _, _, none, _}, _, _},
                    {{quod_dtx_vote, _, _, _, Own, _}, _, _} = New)
  when Own =/= none -> New;
prefer_own_material(Old, _) -> Old.
waiter(none) -> #{};
waiter({dtx_endpoint, Pid}) when is_pid(Pid) -> #{Pid => true}.

-doc "Convert lost reservations to missing-material recovery; accepted work and callers survive.".
-spec engine_lost(none | pid(), state()) -> state().
engine_lost(Engine, Rows) ->
    [case R#intent.proof of
         {Engine, _} -> abandon(R);
         _ -> R#intent{check = none}
     end || R <- Rows].

-doc "Return eligible parent-validation requests once, preserving FIFO order without head blocking.".
-spec next(term(), integer(), state()) -> {[{binary(), reference() | selected, term(), map()}], state()}.
next(ParentKey, Now, Rows) ->
    {Next, Reverse} = lists:mapfoldl(fun
        (#intent{proof = Proof} = R, Acc) when Proof =/= none -> {R, Acc};
        (#intent{material = M, check = Check, trace = Trace} = R, Acc) ->
            Key = selection_key(ParentKey, Now, M),
            case Check of
                {selected, Key, _} -> {R, [{group(M), selected, M, Trace} | Acc]};
                {_, Key, _} -> {R, Acc};
                _ ->
                    Tag = make_ref(),
                    {R#intent{check = {checking, Key, Tag}},
                     [{group(M), Tag, M, Trace} | Acc]}
            end
    end, [], Rows),
    {lists:reverse(Reverse), Next}.

-doc "Bind one cached selection to the exact parent/engine and the immutable deadline region.".
-spec selection_key(term(), integer(), quod_atomic:admission_material()) -> term().
selection_key(ParentKey, Now, {_, _, #{group := #{vote_deadline_ms := Deadline}}}) ->
    {ParentKey, Now > Deadline}.

-doc "Cache a verdict for its exact parent; keep custody until the sole journal writer takes it.".
-spec verdict(reference(), term(), term(), state()) ->
          {selected, map(), state()} | {waiting, state()} | stale.
verdict(Tag, ParentKey, Result, Rows) ->
    case lists:search(fun
        (#intent{check = {checking, {ParentKey0, _}, Tag0}}) -> ParentKey0 =:= ParentKey andalso Tag0 =:= Tag;
        (_) -> false
    end, Rows) of
        false -> stale;
        {value, #intent{material = Old, check = {checking, Key, Tag}} = Row} ->
            case Result of
                {vote, Selected} ->
                    case quod_atomic:intent_id(Selected) =:= quod_atomic:intent_id(Old) of
                        true ->
                            Ready = Row#intent{material = Selected, check = {selected, Key, Tag}},
                            {selected, public(Ready),
                             [case R =:= Row of true -> Ready; false -> R end || R <- Rows]};
                        false -> stale
                    end;
                _ -> {waiting, [case R =:= Row of
                        true -> R#intent{check = {waiting, Key, Tag}};
                        false -> R
                    end || R <- Rows]}
            end
    end.

-doc "Remove one group when its committed vote or terminal tombstone already exists.".
-spec take(binary(), state()) -> {map(), state()} | error.
take(Id, Rows) ->
    case lists:search(fun(R) -> group(R#intent.material) =:= Id end, Rows) of
        {value, Row} -> {public(Row), [R || R <- Rows, R =/= Row]};
        false -> error
    end.

public(#intent{material = M, waiters = Ws, trace = Trace, retained = Retained, check = Check}) ->
    Selection = case Check of {selected, Key, _} -> Key; _ -> none end,
    #{material => M, waiters => maps:keys(Ws), trace_ctx => Trace,
      retained => Retained, selection => Selection}.

-doc "Release all volatile work when the installed history removes this owner's admission; this declares no outcome.".
-spec take_all(state()) -> [map()].
take_all(Rows) -> [public(Row) || Row <- Rows].

group({Record, _, _}) -> quod_atomic:group_id(Record).

-doc "Remove a departed caller without removing its accepted work or restarting validation.".
-spec detach_waiter(pid(), state()) -> state().
detach_waiter(Pid, Rows) ->
    [R#intent{waiters = maps:remove(Pid, R#intent.waiters)} || R <- Rows].

-doc "Test exact local group enrollment; this observation never determines an outcome.".
-spec contains(binary(), state()) -> boolean().
contains(Id, Rows) -> lists:any(fun(R) -> group(R#intent.material) =:= Id end, Rows).

-doc "Read the original caller context from an existing admission row; never borrow ambient ancestry.".
-spec trace_context(binary(), state()) -> map().
trace_context(Id, Rows) ->
    case lists:search(fun(R) -> group(R#intent.material) =:= Id end, Rows) of
        {value, #intent{trace = Context}} -> Context;
        false -> #{}
    end.

-doc "Return active/reserved counts from the one FIFO.".
-spec counts(state()) -> {non_neg_integer(), non_neg_integer()}.
counts(Rows) ->
    lists:foldl(fun
        (#intent{proof = none}, {A, R}) -> {A + 1, R};
        (_, {A, R}) -> {A, R + 1}
    end, {0, 0}, Rows).
