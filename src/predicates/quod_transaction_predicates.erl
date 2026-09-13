-module(quod_transaction_predicates).
-moduledoc """
Transactional Prolog control over Quod's staged ontology overlay.

`transaction(Goal)` selects public atomic intent and uses the shared internal
savepoint for the conventional semidet search/rollback contract. The action
evaluator reuses that savepoint without choosing public commit intent. Reads
remain monotonic OCC dependencies. `trigger_event(Term)` stages an ordered
occurrence in the same overlay. Checkpoint mode is enabled only within a
transaction or action-candidate savepoint, not for ordinary backtracking.

`independent(Goal)` preserves ordinary staging and search, and marks only the
surviving successful proof for independent multi-ontology routing. It requires
an authenticated signed request, rejects nested commit-intent wrappers, and
does not itself submit or commit any change.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([load/1, transaction_1/3, trigger_event_1/3,
         independent_1/3, independent_success_1/3]).

-define(INDEPENDENT_SUCCESS, '$quod_independent_success').

-record(independent, {ref, bs, vn, next}).

-doc "Register staged-write control constructs and their private continuations.".
-spec load(tuple()) -> tuple().
load(#est{db = Db0} = Est0) ->
    Db1 = erlog_int:add_compiled_proc(
            {transaction, 1}, ?MODULE, transaction_1, Db0),
    Db3 = erlog_int:add_compiled_proc(
            {independent, 1}, ?MODULE, independent_1, Db1),
    Est1 = Est0#est{db = erlog_int:add_compiled_proc(
                     {?INDEPENDENT_SUCCESS, 1}, ?MODULE,
                     independent_success_1, Db3)},
    quod_predicates:register(
      quod_proof_savepoint:load(Est1),
      {trigger_event, 1}, staging, ?MODULE, trigger_event_1).

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
transaction_1(Goal, Next, #est{bs = Bs} = St) ->
    {transaction, Inner} = erlog_int:dderef(Goal, Bs),
    case quod_erlog_db_local_prove:write_intent(St) of
        independent -> throw({quod_ask_error, independent_nesting});
        ordinary -> ok;
        atomic -> ok
    end,
    quod_proof_savepoint:run(Inner, Next, St, atomic).

%% Unlike transaction/1 this construct neither checkpoints the DB nor commits
%% to the first answer. Entry/redo boundaries only restore invocation mode;
%% the successful intent is a private Erlog binding and staged provenance stays
%% with the writes. call/1 supplies the ordinary opaque cut boundary.
-spec independent_1(term(), list(), tuple()) -> term().
independent_1(Goal, Next, #est{bs = Bs, vn = Vn, cps = Cps} = St) ->
    {independent, Inner} = erlog_int:dderef(Goal, Bs),
    case quod_erlog_db_local_prove:write_intent(St) =/= ordinary of
        true -> throw({quod_ask_error, independent_nesting});
        false -> ok
    end,
    case quod_erlog_db_local_prove:signed_request(St) of
        false -> throw({quod_ask_error, independent_requires_signed_request});
        true -> ok
    end,
    Ref = make_ref(),
    Frame = #independent{ref = Ref, bs = Bs, vn = Vn, next = Next},
    Sentinel = #cp{type = compiled, label = {?INDEPENDENT_SUCCESS, Ref},
                   next = Frame, data = fun independent_failed/3,
                   bs = Bs, vn = Vn},
    Active = quod_erlog_db_local_prove:set_write_intent(
               St#est{cps = [Sentinel | Cps]}, independent),
    independent_step(fun() -> erlog_int:prove_body(
                      [{call, Inner}, {?INDEPENDENT_SUCCESS, Ref}], Active) end).

%% A later redo runs after the original callback returned. It needs the same
%% seam-scoped unwind as the first step; a stateless error stays stateless.
independent_step(Fun) ->
    try Fun()
    catch
        throw:{erlog_error, Error, ErrorSt} ->
            erlog_int:erlog_error(
              Error, quod_erlog_db_local_prove:set_write_intent(ErrorSt, ordinary))
    end.

-spec independent_success_1(term(), list(), tuple()) -> term().
independent_success_1(Goal, _InternalNext, #est{bs = Bs, vn = Vn, cps = Cps} = St) ->
    {?INDEPENDENT_SUCCESS, Ref} = erlog_int:dderef(Goal, Bs),
    #independent{next = Next} = independent_frame(Ref, Cps),
    Redo = #cp{type = compiled, data = fun independent_redo/3, bs = Bs, vn = Vn},
    Selected = quod_erlog_db_local_prove:accept_independent(
                 quod_erlog_db_local_prove:set_write_intent(
                   St#est{cps = [Redo | Cps]}, ordinary), true),
    erlog_int:prove_body(Next, Selected).

independent_redo(#cp{bs = Bs, vn = Vn}, Cps, St) ->
    independent_step(fun() ->
        erlog_int:fail(quod_erlog_db_local_prove:set_write_intent(
                         St#est{bs = Bs, vn = Vn, cps = Cps}, independent))
    end).

independent_failed(#cp{next = #independent{bs = Bs, vn = Vn}}, Cps, St) ->
    erlog_int:fail(quod_erlog_db_local_prove:set_write_intent(
                     St#est{bs = Bs, vn = Vn, cps = Cps}, ordinary)).

independent_frame(Ref, [#cp{next = #independent{ref = Ref} = Frame} | _]) -> Frame;
independent_frame(Ref, [_ | Rest]) -> independent_frame(Ref, Rest);
independent_frame(_Ref, []) -> erlang:error(missing_independent_boundary).
