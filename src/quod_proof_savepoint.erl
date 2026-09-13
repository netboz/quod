-module(quod_proof_savepoint).
-moduledoc """
Internal semidet proof savepoints shared by public transaction intent and the
ordinary action evaluator. No Prolog savepoint control, process or second DB.

The existing immutable overlay and distributed checkpoint machinery own all
rollback. Reads remain monotonic; facts, events, effects and provenance restore
together. Invocation mode is a separate concern and is restored before every
caller continuation. Public nesting policy belongs to the caller, not here.
""".
-include_lib("erlog/src/erlog_int.hrl").
-export([load/1, run/4, commit_1/3]).
-define(COMMIT, '$quod_savepoint_commit').
-define(FAILED, '$quod_savepoint_failed').
-record(savepoint, {ref :: reference(),
                    scope_tx :: disabled | <<_:128>>,
                    entry :: term(),
                    parent_depth :: non_neg_integer(),
                    parent_mode :: ordinary | atomic | independent,
                    entry_bs :: term(), entry_vn :: non_neg_integer(),
                    outer_cps :: list(), caller_next :: list()}).

-doc "Install only the unforgeable-reference continuation, not a public control.".
-spec load(tuple()) -> tuple().
load(#est{db = Db} = St) ->
    St#est{db = erlog_int:add_compiled_proc({?COMMIT, 1}, ?MODULE, commit_1, Db)}.

-doc "Retain the first complete solution under one rollback boundary and invocation mode.".
-spec run(term(), list(), tuple(), ordinary | atomic | independent) -> term().
run(Inner, Next, #est{bs = Bs, cps = OuterCps, vn = Vn,
                     checkpoint_depth = ParentDepth,
                     db = #db{mod = DbMod, ref = DbRef}} = St, Mode) ->
    ParentMode = quod_erlog_db_local_prove:write_intent(St),
    ScopeTx = quod_transaction_scope:enter(St),
    Enabled = erlog_int:enter_choicepoint_checkpoints(
                quod_erlog_db_local_prove:set_write_intent(St, Mode)),
    Entry = DbMod:choicepoint_checkpoint(DbRef),
    Ref = make_ref(),
    Savepoint = #savepoint{ref = Ref, scope_tx = ScopeTx, entry = Entry,
                           parent_depth = ParentDepth, parent_mode = ParentMode,
                           entry_bs = Bs, entry_vn = Vn, outer_cps = OuterCps,
                           caller_next = Next},
    Sentinel = #cp{type = compiled, label = {?MODULE, Ref},
                   data = fun failed/3, next = Savepoint, bs = Bs, vn = Vn},
    run_inner(Savepoint, Inner, Enabled#est{cps = [Sentinel | OuterCps]}).

run_inner(#savepoint{ref = Ref} = Savepoint, Inner, Active) ->
    quod_proof_continuation:run(Ref, fun() ->
        %% The candidate cut is local; only its first complete answer survives.
        erlog_int:prove_body([{call, {once, Inner}}, {?COMMIT, Ref}], Active)
    end, fun inner_error/4, {Savepoint, Active}).

inner_error(throw, {?FAILED, Ref, Clean}, _, {#savepoint{ref = Ref}, _}) ->
    erlog_int:fail(Clean);
inner_error(throw, {erlog_error, Error, ErrorSt}, _, {Savepoint, _}) ->
    erlog_int:erlog_error(Error, rollback(ErrorSt, Savepoint));
inner_error(throw, {erlog_error, Error}, _, {Savepoint, Active}) ->
    erlog_int:erlog_error(Error, rollback(Active, Savepoint));
inner_error(Class, Reason, Stacktrace, {Savepoint, _}) ->
    %% An aborted whole proof has no reusable state. Existing proof cleanup
    %% remains authoritative if remote custody is already lost.
    ok = quod_transaction_scope:discard(Savepoint#savepoint.scope_tx),
    erlang:raise(Class, Reason, Stacktrace).

-doc "Consume the exact internal continuation once; never callable with wire data.".
-spec commit_1(term(), list(), tuple()) -> term().
commit_1(Goal, _InternalNext, #est{bs = Bs, cps = Cps} = St) ->
    {?COMMIT, Ref} = erlog_int:dderef(Goal, Bs),
    case take_sentinel(Ref, Cps) of
        {ok, #savepoint{caller_next = CallerNext, parent_mode = ParentMode} = S,
         OuterCps} ->
            ok = quod_transaction_scope:finish(S#savepoint.scope_tx),
            Writable = quod_erlog_db_local_prove:set_write_intent(
                         erlog_int:leave_choicepoint_checkpoints(
                           St#est{cps = OuterCps}), ParentMode),
            quod_proof_continuation:prove(Ref, CallerNext, Writable);
        error -> erlog_int:erlog_error({system_error, missing_savepoint_boundary}, St)
    end.

-spec failed(tuple(), list(), tuple()) -> no_return().
failed(#cp{next = #savepoint{ref = Ref} = Savepoint}, OuterCps, St) ->
    throw({?FAILED, Ref, rollback(St, Savepoint#savepoint{outer_cps = OuterCps})}).

rollback(#est{db = #db{mod = DbMod, ref = CurrentRef} = Db} = St,
         #savepoint{entry = Entry, parent_depth = ParentDepth,
                    parent_mode = ParentMode, scope_tx = ScopeTx,
                    entry_bs = Bs, entry_vn = Vn, outer_cps = OuterCps}) ->
    RestoredRef = DbMod:choicepoint_restore(CurrentRef, Entry),
    ok = quod_transaction_scope:finish(ScopeTx),
    quod_erlog_db_local_prove:set_write_intent(
      St#est{db = Db#db{ref = RestoredRef}, cps = OuterCps,
             bs = Bs, vn = Vn, checkpoint_depth = ParentDepth}, ParentMode).

take_sentinel(Ref, [#cp{type = compiled, label = {?MODULE, Ref},
                        next = #savepoint{ref = Ref} = Savepoint} | Rest]) ->
    {ok, Savepoint, Rest};
take_sentinel(Ref, [#cp{} | Rest]) -> take_sentinel(Ref, Rest);
take_sentinel(Ref, [#cut{} | Rest]) -> take_sentinel(Ref, Rest);
take_sentinel(_Ref, []) -> error.
