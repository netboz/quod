-module(quod_transaction_scope).
-moduledoc """
Invocation-local transaction lineage for distributed ontology proofs.

Erlog owns the local immutable overlay checkpoint.  This module adds only the
opaque controller tokens needed when the same proof selects another ontology.
An all-local `transaction/1` therefore creates no proof-context state.  Pending
frames are activated together on the first foreign selection, and later Erlog
choice points retain one bounded controller batch for the active lineage.
""".

-include("quod_proof_limits.hrl").

-export([empty_selection/0, valid_selection/1, selection_lineage/1,
         checkpoint_depth/1, with_invocation/4,
         current_actor/0, current_selection/1,
         enter/1, finish/1, discard/1, activate/1,
         checkpoint_token/0, restore_token/1]).
-export_type([lineage/0, selection/0, actor/0]).

-type opaque_id() :: <<_:128>>.
-type lineage() :: none | opaque_id().
-type selection() :: {tx_selection, lineage(), [opaque_id()]}.
-type actor() :: {opaque_id(), opaque_id()}.
-type distributed_token() :: {batch, opaque_id()} | {pending, opaque_id()}.

-record(frame, {
          frame_id :: opaque_id(),
          tx_id = none :: none | opaque_id(),
          baseline_batch = none :: none | opaque_id()
         }).

-record(state, {
          actor :: actor(),
          metadata :: term(),
          base_batches = [] :: [opaque_id()],
          current_lineage = none :: lineage(),
          frames = [] :: [#frame{}]
         }).

-define(KEY, '$quod_transaction_scope').

valid_lineage(none) -> true;
valid_lineage(<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>) -> true;
valid_lineage(_) -> false.

-spec empty_selection() -> selection().
empty_selection() -> {tx_selection, none, []}.

-spec valid_selection(term()) -> boolean().
valid_selection({tx_selection, Lineage, BatchIds}) ->
    valid_lineage(Lineage) andalso
        valid_sorted_ids(BatchIds, none, 0) andalso
        (Lineage =/= none orelse BatchIds =:= []);
valid_selection(_) -> false.

-spec selection_lineage(selection()) -> lineage().
selection_lineage({tx_selection, Lineage, _BatchIds}) -> Lineage.

-spec checkpoint_depth(selection()) -> 0 | 1.
checkpoint_depth({tx_selection, none, []}) -> 0;
checkpoint_depth({tx_selection, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>,
                  BatchIds}) when is_list(BatchIds) -> 1.

-doc "Run one proof step with an exact actor and inherited live transaction selection.".
-spec with_invocation(actor(), selection(), term(), fun(() -> Result)) ->
          {Result, selection()} when Result :: term().
with_invocation({<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>,
                 <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>} = Actor,
                {tx_selection, Lineage, BaseBatches} = Selection,
                Metadata, Fun)
  when is_function(Fun, 0) ->
    true = valid_selection(Selection),
    Previous = get(?KEY),
    State = #state{actor = Actor, metadata = Metadata,
                   base_batches = BaseBatches,
                   current_lineage = Lineage},
    _ = put(?KEY, State),
    try
        Result = Fun(),
        {Result, result_selection(Result)}
    after
        restore_previous(Previous)
    end.

-spec current_actor() -> actor() | undefined.
current_actor() ->
    case get(?KEY) of
        #state{actor = Actor} -> Actor;
        undefined -> undefined
    end.

-doc "Return the exact active lineage and live distributed CP batches.".
-spec current_selection(tuple()) -> selection().
current_selection(St) ->
    case get(?KEY) of
        #state{base_batches = BaseBatches,
               current_lineage = Lineage,
               frames = Frames} ->
            Tokens = quod_erlog_db_local_prove:live_transaction_tokens(St),
            TokenBatches = lists:filtermap(
                             fun({batch, BatchId}) -> {true, BatchId};
                                ({pending, FrameId}) ->
                                     pending_baseline(FrameId, Frames)
                             end, Tokens),
            EntryBatches = [BatchId ||
                              #frame{tx_id = TxId,
                                     baseline_batch = BatchId} <- Frames,
                              TxId =/= none, BatchId =/= none],
            selection(Lineage,
                      lists:append([BaseBatches, TokenBatches, EntryBatches]));
        undefined ->
            empty_selection()
    end.

-doc "Enter one local transaction frame without allocating controller state.".
-spec enter(tuple()) -> disabled | opaque_id().
enter(St) ->
    case get(?KEY) of
        #state{metadata = Metadata, frames = Frames} = State0 ->
            case metadata(St) of
                Metadata when length(Frames) <
                              ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF ->
                    FrameId = new_frame_id(Frames),
                    put_state(State0#state{
                                frames = [#frame{frame_id = FrameId} | Frames]}),
                    FrameId;
                Metadata ->
                    throw(
                      {quod_ask_error,
                       {savepoint_limit_exceeded,
                        ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF}});
                _ ->
                    erlang:error(transaction_scope_context_changed)
            end;
        undefined ->
            disabled
    end.

-doc "Activate every pending local frame before the first foreign goal runs.".
-spec activate(tuple()) -> ok.
activate(_St) ->
    case get(?KEY) of
        #state{frames = Frames0} = State0 ->
            PendingOuterFirst =
                [FrameId || #frame{frame_id = FrameId, tx_id = none} <-
                                lists:reverse(Frames0)],
            activate_pending(PendingOuterFirst, State0);
        undefined ->
            ok
    end.

activate_pending([], _State) ->
    ok;
activate_pending(FrameIds, #state{current_lineage = Parent} = State0) ->
    case request(State0, {activate, Parent, FrameIds}) of
        {ok, FinalLineage, Activated} ->
            ByFrame = maps:from_list(
                        [{FrameId, {TxId, Baseline}} ||
                            {FrameId, TxId, _FrameLineage, Baseline} <- Activated]),
            case map_size(ByFrame) =:= length(FrameIds) of
                true ->
                    Frames1 = [activate_frame(Frame, ByFrame) ||
                                  Frame <- State0#state.frames],
                    put_state(State0#state{current_lineage = FinalLineage,
                                           frames = Frames1});
                false ->
                    throw({quod_ask_error,
                           {protocol_error, session_binding}})
            end;
        {error, Reason} ->
            throw({quod_ask_error, Reason});
        _ ->
            throw({quod_ask_error, {protocol_error, session_binding}})
    end.

activate_frame(#frame{frame_id = FrameId, tx_id = none} = Frame, ByFrame) ->
    case maps:find(FrameId, ByFrame) of
        {ok, {TxId, Baseline}} ->
            Frame#frame{tx_id = TxId, baseline_batch = Baseline};
        error ->
            Frame
    end;
activate_frame(Frame, _ByFrame) ->
    Frame.

-doc "Finish the exact innermost local transaction frame.".
-spec finish(disabled | opaque_id()) -> ok.
finish(disabled) -> ok;
finish(FrameId) -> finish_frame(FrameId, strict).

-doc "Best-effort frame cleanup while the complete proof is already aborting.".
-spec discard(disabled | opaque_id()) -> ok.
discard(disabled) -> ok;
discard(FrameId) -> finish_frame(FrameId, best_effort).

finish_frame(FrameId, Mode) ->
    case get(?KEY) of
        #state{frames = [#frame{frame_id = FrameId} = Frame | Rest]} = State0 ->
            case finish_active(Frame, State0, Mode) of
                {ok, ParentLineage} ->
                    put_state(State0#state{current_lineage = ParentLineage,
                                           frames = Rest});
                ignored ->
                    put_state(State0#state{frames = Rest})
            end;
        #state{} when Mode =:= best_effort ->
            ok;
        #state{} ->
            erlang:error({transaction_scope_mismatch, FrameId});
        undefined when Mode =:= best_effort ->
            ok;
        undefined ->
            erlang:error({transaction_scope_mismatch, FrameId})
    end.

finish_active(#frame{tx_id = none}, #state{current_lineage = Lineage}, _Mode) ->
    {ok, Lineage};
finish_active(#frame{tx_id = TxId}, #state{current_lineage = Lineage} = State,
              strict) ->
    case request(State, {finish, Lineage, TxId}) of
        {ok, ParentLineage} -> {ok, ParentLineage};
        {error, Reason} -> throw({quod_ask_error, Reason});
        _ -> throw({quod_ask_error, {protocol_error, session_binding}})
    end;
finish_active(#frame{tx_id = TxId}, #state{current_lineage = Lineage} = State,
              best_effort) ->
    try request(State, {discard, Lineage, TxId}) of
        {ok, ParentLineage} -> {ok, ParentLineage};
        _ -> ignored
    catch _:_ -> ignored
    end.

-doc "Retain one distributed batch and pending-frame markers for a choice point.".
-spec checkpoint_token() -> [distributed_token()].
checkpoint_token() ->
    case get(?KEY) of
        #state{current_lineage = Lineage, frames = Frames} = State0 ->
            Pending = [{pending, FrameId} ||
                          #frame{frame_id = FrameId, tx_id = none} <- Frames],
            case Lineage of
                none -> Pending;
                _ ->
                    case request(State0, {allocate, Lineage}) of
                        {ok, BatchId} -> [{batch, BatchId} | Pending];
                        {error, Reason} -> throw({quod_ask_error, Reason});
                        _ -> throw({quod_ask_error,
                                    {protocol_error, session_binding}})
                    end
            end;
        undefined ->
            []
    end.

-doc "Restore the distributed batches correlated with one local DB checkpoint.".
-spec restore_token([distributed_token()]) -> ok.
restore_token([]) -> ok;
restore_token(Tokens) when is_list(Tokens) ->
    case get(?KEY) of
        #state{current_lineage = Lineage, frames = Frames} = State0 ->
            BatchIds = lists:usort(
                         lists:filtermap(
                           fun({batch, BatchId}) -> {true, BatchId};
                              ({pending, FrameId}) ->
                                   pending_baseline(FrameId, Frames)
                           end, Tokens)),
            restore_batches(Lineage, BatchIds, State0);
        undefined ->
            ok
    end.

pending_baseline(FrameId,
                 [#frame{frame_id = FrameId,
                         baseline_batch = none} | _]) -> false;
pending_baseline(FrameId,
                 [#frame{frame_id = FrameId,
                         baseline_batch = BatchId} | _]) -> {true, BatchId};
pending_baseline(FrameId, [_ | Rest]) -> pending_baseline(FrameId, Rest);
pending_baseline(_FrameId, []) -> false.

restore_batches(_Lineage, [], _State) -> ok;
restore_batches(none, _BatchIds, _State) ->
    throw({quod_ask_error, {protocol_error, session_binding}});
restore_batches(Lineage, BatchIds, State) ->
    case request(State, {restore, Lineage, BatchIds}) of
        ok -> ok;
        {error, Reason} -> throw({quod_ask_error, Reason});
        _ -> throw({quod_ask_error, {protocol_error, session_binding}})
    end.

result_selection({solution, _Solution, Scope}) ->
    current_selection(quod_proof_scope:state(Scope));
result_selection({complete, _Reasons, Scope}) ->
    current_selection(quod_proof_scope:state(Scope));
result_selection({error, _Reason, Scope, _RevisionPolicy}) ->
    current_selection(quod_proof_scope:state(Scope));
result_selection(_Result) ->
    #state{current_lineage = Lineage, base_batches = BaseBatches} = state(),
    selection(Lineage, BaseBatches).

selection(Lineage, BatchIds0) ->
    BatchIds = lists:usort(BatchIds0),
    case length(BatchIds) =< ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF andalso
         (Lineage =/= none orelse BatchIds =:= []) of
        true -> {tx_selection, Lineage, BatchIds};
        false ->
            throw(
              {quod_ask_error,
               {savepoint_limit_exceeded,
                ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF}})
    end.

request(#state{actor = Actor,
               metadata = {origin, {quod_proof_context, ProofId, Origin}}},
        Operation)
  when Origin =:= self(), is_binary(ProofId) ->
    quod_proof_context:tx_request(Actor, Operation);
request(#state{actor = {ScopeId, InvocationId},
               metadata = {scope, ProofId, Origin, _SessionRef, ScopeId}},
        Operation)
  when is_pid(Origin), is_binary(ProofId) ->
    RequestRef = make_ref(),
    Origin ! {proof_tx_request, ProofId, self(), ScopeId, InvocationId,
              RequestRef, Operation},
    await_reply(Origin, ProofId, InvocationId, RequestRef);
request(_State, _Operation) ->
    {error, {protocol_error, session_binding}}.

await_reply(Origin, ProofId, InvocationId, RequestRef) ->
    MRef = monitor(process, Origin),
    try await_reply_loop(Origin, ProofId, InvocationId, RequestRef, MRef)
    after demonitor(MRef, [flush])
    end.

await_reply_loop(Origin, ProofId, InvocationId, RequestRef, MRef) ->
    receive
        {proof_tx_reply, ProofId, InvocationId, RequestRef, Reply} ->
            Reply;
        Message = {scope_invoke_open, _, _, _, _, _, _, _, _} ->
            dispatch_while_waiting(Message, Origin, ProofId, InvocationId,
                                   RequestRef, MRef);
        Message = {scope_invoke_next, _, _, _, _, _, _} ->
            dispatch_while_waiting(Message, Origin, ProofId, InvocationId,
                                   RequestRef, MRef);
        Message = {scope_invoke_cancel, _, _, _, _} ->
            dispatch_while_waiting(Message, Origin, ProofId, InvocationId,
                                   RequestRef, MRef);
        Message = {scope_savepoint, _, _, _, _, _, _} ->
            dispatch_while_waiting(Message, Origin, ProofId, InvocationId,
                                   RequestRef, MRef);
        Message = {scope_seal, _, _, _, _, _} ->
            dispatch_while_waiting(Message, Origin, ProofId, InvocationId,
                                   RequestRef, MRef);
        Message = {scope_close, _, _, _} ->
            dispatch_while_waiting(Message, Origin, ProofId, InvocationId,
                                   RequestRef, MRef);
        {'DOWN', MRef, process, Origin, _Reason} ->
            exit(normal)
    end.

dispatch_while_waiting(Message, Origin, ProofId, InvocationId,
                       RequestRef, MRef) ->
    case quod_scope_session:dispatch(Message) of
        stop -> exit(normal);
        handled -> await_reply_loop(Origin, ProofId, InvocationId,
                                    RequestRef, MRef);
        unhandled -> {error, {protocol_error, unexpected_scope_command}}
    end.

metadata(St) ->
    try quod_proof_session:context(St)
    catch error:badarg -> undefined
    end.

new_frame_id(Frames) ->
    Id = crypto:strong_rand_bytes(?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS div 8),
    case lists:any(fun(#frame{frame_id = Existing}) -> Existing =:= Id end,
                   Frames) of
        true -> new_frame_id(Frames);
        false -> Id
    end.

state() ->
    case get(?KEY) of
        #state{} = State -> State;
        undefined -> erlang:error(no_transaction_invocation)
    end.

put_state(#state{} = State) -> _ = put(?KEY, State), ok.

restore_previous(undefined) -> _ = erase(?KEY), ok;
restore_previous(#state{} = Previous) -> _ = put(?KEY, Previous), ok.

valid_sorted_ids([], _Previous, _Count) -> true;
valid_sorted_ids(_Ids, _Previous,
                 ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF) -> false;
valid_sorted_ids([Id | Rest], none, Count) ->
    valid_opaque_id(Id) andalso
        valid_sorted_ids(Rest, Id, Count + 1);
valid_sorted_ids([Id | Rest], Previous, Count) ->
    valid_opaque_id(Id) andalso Previous < Id andalso
        valid_sorted_ids(Rest, Id, Count + 1);
valid_sorted_ids(_Improper, _Previous, _Count) -> false.

valid_opaque_id(<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>) -> true;
valid_opaque_id(_) -> false.
