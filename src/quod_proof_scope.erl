-module(quod_proof_scope).
-moduledoc """
The shared resumable Erlog runner for one ontology proof scope.

A scope owns one private `quod_erlog_db_local_prove` overlay over a pinned
committed state. `next/1` yields one solution at a time and retains the exact
Erlog continuation for ordinary backtracking. `run_first/3` is the synchronous
one-solution adapter used by local proofs and isolated policy reads.

This module is deliberately a worker-loop library, not an OTP process or a
second database owner. Co-hosted and remote transports decide when to request
the next answer; the proof semantics live here.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([open/3, open_wrapped/2, next/1, close/1,
         local_changes/1, run_first/3]).

-record(scope, {goal  :: term(),
                vars  :: term(),
                state :: tuple(),
                phase = fresh :: fresh | more}).

-opaque scope() :: #scope{}.
-export_type([scope/0]).

-doc "Open a resumable scope over a committed state with one private overlay.".
-spec open(term(), tuple(), map()) -> scope().
open(Goal, Est, OverlayOpts) when is_map(OverlayOpts) ->
    open_wrapped(
      Goal, quod_erlog_db_local_prove:wrap_state(Est, OverlayOpts)).

-doc "Open a scope over an overlay already prepared by its owning worker.".
-spec open_wrapped(term(), tuple()) -> scope().
open_wrapped(Goal, #est{} = Wrapped) ->
    #scope{goal = Goal, vars = erlog:vars_in(Goal), state = Wrapped}.

-doc "Derive the next solution, or report logical exhaustion or a bounded error.".
-spec next(scope()) ->
          {solution, term(), scope()} |
          {complete, [term()], scope()} |
          {error, term(), scope()}.
next(#scope{goal = Goal, state = St, phase = Phase} = Scope) ->
    Result = run_step(Phase, Goal, St),
    drive(Result, Goal, Scope).

-doc "Return the current scope's staged content changes.".
-spec local_changes(scope()) -> list().
local_changes(#scope{state = #est{db = #db{ref = Overlay}}}) ->
    quod_erlog_db_local_prove:get_local_changes(Overlay).

-doc "Release resources owned by a finished or abandoned scope.".
-spec close(scope()) -> ok.
close(#scope{state = St}) ->
    quod_erlog_db_local_prove:cleanup_read_set(St).

-doc "Run one scope to its first complete solution and return its staged plan.".
-spec run_first(term(), tuple(), map()) ->
          {ok, map(), list(), map()} | {fail, [term()]} | {error, term()}.
run_first(Goal, Est, OverlayOpts) when is_map(OverlayOpts) ->
    Scope0 = open(Goal, Est, OverlayOpts),
    try next(Scope0) of
        {solution, _Solution, Scope1} ->
            result(Scope1);
        {complete, Reasons, _Scope1} ->
            {fail, Reasons};
        {error, Reason, _Scope1} ->
            {error, Reason}
    after
        %% Every immutable scope revision shares this overlay's one read-set
        %% table, so the initial handle is the stable cleanup token.
        close(Scope0)
    end.

run_step(fresh, Goal, St) ->
    guarded(fun() -> erlog_int:prove_goal(Goal, St) end);
run_step(more, _Goal, St) ->
    guarded(fun() -> erlog_int:fail(St) end).

guarded(Fun) ->
    try Fun() of
        Result -> Result
    catch
        throw:{quod_ask_error, Reason} ->
            {scope_error, Reason};
        throw:{erlog_error, Error, _St} ->
            {scope_error, {erlog, Error}};
        throw:{erlog_error, Error} ->
            {scope_error, {erlog, Error}};
        Class:Reason:Stack ->
            logger:warning(
              "quod_proof_scope[~p]: proof crashed: ~p:~p ~p",
              [self(), Class, Reason, Stack]),
            {scope_error, prove_failed}
    end.

drive({succeed, St}, Goal, Scope) ->
    {solution, erlog_int:dderef(Goal, St#est.bs),
     Scope#scope{state = St, phase = more}};
drive({fail, St}, _Goal, Scope) ->
    {complete, St#est.fail_reasons, Scope#scope{state = St}};
drive({erlog_error, Error, _St}, _Goal, Scope) ->
    {error, {erlog, Error}, Scope};
drive({scope_error, Reason}, _Goal, Scope) ->
    {error, Reason, Scope};
drive(_Other, _Goal, Scope) ->
    {error, prove_failed, Scope}.

result(#scope{vars = Vars,
              state = #est{db = #db{ref = Overlay}} = Final}) ->
    {ok, bindings_map(erlog_int:dderef(Vars, Final#est.bs)),
     quod_erlog_db_local_prove:get_local_changes(Overlay),
     quod_erlog_db_local_prove:get_read_set(Overlay)}.

bindings_map(Pairs) when is_list(Pairs) -> maps:from_list(Pairs);
bindings_map(_) -> #{}.
