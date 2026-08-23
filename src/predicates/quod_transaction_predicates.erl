-module(quod_transaction_predicates).
-moduledoc """
Transactional Prolog control over Quod's staged ontology overlay.

`transaction(Goal)` follows the conventional semidet contract: it searches
`Goal` until its first complete solution and commits that staged result. Failed
alternatives restore their exact immutable overlay checkpoint. Total failure or
an Erlog exception restores the entry checkpoint; reads remain monotonic OCC
dependencies. `trigger_event(Term)` stages an explicit ordered occurrence in
that same overlay; it is governed by the ordinary staging context. Ordinary
Erlog proofs never enable checkpoint mode.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([load/1, transaction_1/3, commit_1/3, trigger_event_1/3]).

-define(COMMIT, '$quod_transaction_commit').
-define(FAILED, '$quod_transaction_failed').
-define(CALLER_ERROR, '$quod_transaction_caller_error').

-record(tx, {ref              :: reference(),
             scope_tx         :: disabled | <<_:128>>,
             entry            :: term(),
             parent_depth     :: non_neg_integer(),
             entry_bs         :: term(),
             entry_vn         :: non_neg_integer(),
             outer_cps        :: list(),
             caller_next      :: list()}).

-doc "Register transaction/1 and its private success continuation.".
-spec load(tuple()) -> tuple().
load(#est{db = Db0} = Est0) ->
    Db1 = erlog_int:add_compiled_proc(
            {transaction, 1}, ?MODULE, transaction_1, Db0),
    Est1 = Est0#est{db = erlog_int:add_compiled_proc(
                     {?COMMIT, 1}, ?MODULE, commit_1, Db1)},
    quod_predicates:register(
      Est1, {trigger_event, 1}, staging, ?MODULE, trigger_event_1).

-spec trigger_event_1(term(), list(), tuple()) -> term().
trigger_event_1({trigger_event, Term0}, Next, #est{bs = Bs} = St) ->
    Term = erlog_int:dderef(Term0, Bs),
    case quod_diff:valid_event(Term) of
        true ->
            case quod_erlog_db_local_prove:stage_event(St, Term) of
                {ok, St1} -> erlog_int:prove_body(Next, St1);
                error ->
                    erlog_int:erlog_error(
                      {permission_error, modify, trigger_event}, St)
            end;
        false ->
            erlog_int:fail(St)
    end.

-spec transaction_1(term(), list(), tuple()) -> term().
transaction_1(Goal, Next,
              #est{bs = Bs, cps = OuterCps, vn = Vn,
                   checkpoint_depth = ParentDepth,
                   db = #db{mod = DbMod, ref = DbRef}} = St) ->
    {transaction, Inner} = erlog_int:dderef(Goal, Bs),
    ScopeTx = quod_transaction_scope:enter(St),
    Enabled = erlog_int:enter_choicepoint_checkpoints(St),
    Entry = DbMod:choicepoint_checkpoint(DbRef),
    Ref = make_ref(),
    Tx = #tx{ref = Ref, scope_tx = ScopeTx,
             entry = Entry, parent_depth = ParentDepth,
             entry_bs = Bs, entry_vn = Vn, outer_cps = OuterCps,
             caller_next = Next},
    Sentinel = #cp{type = compiled, label = {?MODULE, Ref},
                   data = fun transaction_failed/3,
                   next = Tx, bs = Bs, vn = Vn},
    Active = Enabled#est{cps = [Sentinel | OuterCps]},
    run_inner(Tx, Inner, Active).

run_inner(#tx{ref = Ref} = Tx, Inner, Active) ->
    try
        %% call/1 supplies a fresh cut barrier; once/1 commits the first complete
        %% solution without exposing inner alternatives to the caller.
        erlog_int:prove_body(
          [{call, {once, Inner}}, {?COMMIT, Ref}], Active)
    catch
        throw:{?FAILED, Ref, Clean} ->
            erlog_int:fail(Clean);
        throw:{?CALLER_ERROR, Ref, Class, Reason, Stacktrace} ->
            erlang:raise(Class, Reason, Stacktrace);
        throw:{erlog_error, Error, ErrorSt} ->
            erlog_int:erlog_error(Error, rollback(ErrorSt, Tx));
        throw:{erlog_error, Error} ->
            erlog_int:erlog_error(Error, rollback(Active, Tx));
        Class:Reason:Stacktrace ->
            %% Non-Erlog exceptions abort the whole proof and carry no reusable
            %% interpreter state. Release any distributed savepoint references;
            %% proof cleanup remains authoritative if a peer is already gone.
            ok = quod_transaction_scope:discard(Tx#tx.scope_tx),
            erlang:raise(Class, Reason, Stacktrace)
    end.

-spec commit_1(term(), list(), tuple()) -> term().
commit_1(Goal, _InternalNext, #est{bs = Bs, cps = Cps} = St) ->
    {?COMMIT, Ref} = erlog_int:dderef(Goal, Bs),
    case take_sentinel(Ref, Cps) of
        {ok, #tx{caller_next = CallerNext} = Tx, OuterCps} ->
            ok = quod_transaction_scope:finish(Tx#tx.scope_tx),
            Writable = erlog_int:leave_choicepoint_checkpoints(
                         St#est{cps = OuterCps}),
            prove_caller(Tx, CallerNext, Writable);
        error ->
            erlog_int:erlog_error(
              {system_error, missing_transaction_boundary}, St)
    end.

prove_caller(#tx{ref = Ref}, Next, St) ->
    try erlog_int:prove_body(Next, St)
    catch
        Class:Reason:Stacktrace ->
            throw({?CALLER_ERROR, Ref, Class, Reason, Stacktrace})
    end.

-spec transaction_failed(tuple(), list(), tuple()) -> no_return().
transaction_failed(#cp{next = #tx{ref = Ref} = Tx}, OuterCps, St) ->
    throw({?FAILED, Ref, rollback(St, Tx#tx{outer_cps = OuterCps})}).

rollback(#est{db = #db{mod = DbMod, ref = CurrentRef} = Db} = St,
         #tx{entry = Entry, parent_depth = ParentDepth,
             scope_tx = ScopeTx,
             entry_bs = Bs, entry_vn = Vn, outer_cps = OuterCps}) ->
    RestoredRef = DbMod:choicepoint_restore(CurrentRef, Entry),
    ok = quod_transaction_scope:finish(ScopeTx),
    St#est{db = Db#db{ref = RestoredRef}, cps = OuterCps,
           bs = Bs, vn = Vn, checkpoint_depth = ParentDepth}.

take_sentinel(Ref, [#cp{type = compiled,
                        label = {?MODULE, Ref},
                        next = #tx{ref = Ref} = Tx} | Rest]) ->
    {ok, Tx, Rest};
take_sentinel(Ref, [#cp{} | Rest]) ->
    take_sentinel(Ref, Rest);
take_sentinel(Ref, [#cut{} | Rest]) ->
    take_sentinel(Ref, Rest);
take_sentinel(_Ref, []) ->
    error.
