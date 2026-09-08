-module(quod_proof_scope).
-moduledoc """
The shared resumable Erlog runner for one ontology invocation.

Each invocation retains its continuation over its proof session's shared
staged view. `next/1` yields one solution at a time and retains exact ordinary
Prolog backtracking. The synchronous one-solution adapter also lives in
`quod_proof_session`, so every proof uses the same session path.

This module is deliberately a worker-loop library, not an OTP process or a
second database owner. Co-hosted and remote transports decide when to request
the next answer; the proof semantics live here.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([open_invocation/4,
         next/1, rebase/2, state/1, bindings/1]).

-record(scope, {goal  :: term(),
                vars  :: term(),
                state :: tuple(),
                phase = fresh :: fresh | more}).

-opaque scope() :: #scope{}.
-export_type([scope/0]).

open_wrapped(Goal, #est{} = Wrapped) ->
    #scope{goal = Goal, vars = erlog:vars_in(Goal), state = Wrapped}.

-doc "Open an invocation with a fresh interpreter frame over a shared overlay revision.".
-spec open_invocation(term(), tuple(), quod_predicates:ctx(), non_neg_integer()) ->
          scope().
open_invocation(Goal, Shared, Context, CheckpointDepth)
  when is_integer(CheckpointDepth), CheckpointDepth >= 0 ->
    quod_trace:with_span(
      quod_trace:context(), <<"quod.erlog.open_invocation">>, internal,
      #{'quod.proof.checkpoint_depth' => CheckpointDepth},
      fun(_SpanCtx) ->
          Fresh0 = quod_erlog_db_local_prove:fresh_proof_state(Shared),
          Fresh = Fresh0#est{checkpoint_depth = CheckpointDepth},
          open_wrapped(Goal, set_context(Fresh, Context))
      end).

-doc "Derive the next solution, or report logical exhaustion or a bounded error.".
-spec next(scope()) ->
          {solution, term(), scope()} |
          {complete, [term()], scope()} |
          {error, term(), scope(), adopt | keep_current}.
next(#scope{goal = Goal, state = St, phase = Phase} = Scope) ->
    case quod_erlog_db_local_prove:check_access(St) of
        {error, Reason} ->
            {error, Reason, Scope, keep_current};
        ok ->
            Result = quod_trace:with_span(
                       quod_trace:context(), <<"quod.erlog.step">>, internal,
                       #{'quod.proof.step' => atom_to_binary(Phase, utf8)},
                       fun(_SpanCtx) -> run_step(Phase, Goal, St) end),
            Driven = quod_trace:with_span(
                       quod_trace:context(), <<"quod.erlog.interpret_result">>,
                       internal, #{},
                       fun(_SpanCtx) -> drive(Result, Goal, Scope) end),
            quod_trace:with_span(
              quod_trace:context(), <<"quod.erlog.exposure_guard">>, internal,
              #{}, fun(_SpanCtx) -> guard_exposure(Driven) end)
    end.

-doc "Rebase a suspended continuation onto its session's current overlay revision.".
-spec rebase(scope(), tuple()) -> scope().
rebase(#scope{state = St} = Scope, Shared) ->
    Revision = quod_erlog_db_local_prove:revision(Shared),
    Scope#scope{state = quod_erlog_db_local_prove:replace_revision(St, Revision)}.

-doc "Return the invocation's current Erlog state for worker-local coordination.".
-spec state(scope()) -> tuple().
state(#scope{state = St}) -> St.

-doc "Return the invocation's current variable bindings as a map.".
-spec bindings(scope()) -> map().
bindings(#scope{vars = Vars, state = #est{} = St}) ->
    quod_trace:with_span(
      quod_trace:context(), <<"quod.erlog.materialize_bindings">>, internal,
      #{},
      fun(_SpanCtx) ->
          case quod_erlog_db_local_prove:check_access(St) of
              ok -> bindings_map(erlog_int:dderef(Vars, St#est.bs));
              {error, Reason} -> throw({quod_ask_error, Reason})
          end
      end).

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
        throw:{erlog_error, Error, #est{} = St} ->
            {erlog_error, Error, St};
        throw:{erlog_error, Error} ->
            {scope_error, {erlog, Error}};
        Class:Reason:Stack ->
            logger:warning(
              "quod_proof_scope[~p]: proof crashed: ~p:~p ~p",
              [self(), Class, Reason, Stack]),
            {scope_error, {protocol_error, proof_engine}}
    end.

drive({succeed, St}, Goal, Scope) ->
    {solution, erlog_int:dderef(Goal, St#est.bs),
     Scope#scope{state = St, phase = more}};
drive({fail, St}, _Goal, Scope) ->
    {complete, St#est.fail_reasons, Scope#scope{state = St}};
drive({erlog_error, Error, #est{} = St}, _Goal, Scope) ->
    {error, {erlog, Error}, Scope#scope{state = St}, adopt};
drive({scope_error, Reason}, _Goal, Scope) ->
    {error, Reason, Scope, keep_current};
drive(_Other, _Goal, Scope) ->
    {error, {protocol_error, proof_engine}, Scope, keep_current}.

%% No solution, exhaustion report, or interpreter error crosses the scope
%% boundary without one final generation check. This catches a Prepare or
%% Finalize transition that raced the interpreter step, including a goal made
%% only of built-ins and therefore containing no database callback.
guard_exposure({solution, _Solution, #scope{state = St}} = Result) ->
    checked_exposure(St, Result);
guard_exposure({complete, _Reasons, #scope{state = St}} = Result) ->
    checked_exposure(St, Result);
guard_exposure({error, _Reason, #scope{state = St}, _Policy} = Result) ->
    checked_exposure(St, Result).

checked_exposure(St, Result) ->
    case quod_erlog_db_local_prove:check_access(St) of
        ok -> Result;
        {error, Reason} ->
            {error, Reason, result_scope(Result), keep_current}
    end.

result_scope({solution, _Solution, Scope}) -> Scope;
result_scope({complete, _Reasons, Scope}) -> Scope;
result_scope({error, _Reason, Scope, _Policy}) -> Scope.

bindings_map(Pairs) when is_list(Pairs) -> maps:from_list(Pairs);
bindings_map(_) -> #{}.

set_context(St, undefined) -> St;
set_context(St, Context) -> quod_predicates:set_context(St, Context).
