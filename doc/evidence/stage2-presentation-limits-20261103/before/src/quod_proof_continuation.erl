-module(quod_proof_continuation).
-moduledoc """
Exception boundary for proof controls that release their local scope before
running the caller. A caller error must never restore an already-released
savepoint or read-only frame. The reference is invocation-local and cannot
be forged by a Prolog term; no process or retained state is involved.
""".
-export([run/4, prove/3, take_boundary/2]).
-include_lib("erlog/src/erlog_int.hrl").
-define(CALLER_ERROR, '$quod_proof_caller_error').

-doc "Run a scoped proof, handling only its errors and preserving caller errors unchanged.".
-spec run(reference(), fun(() -> term()),
          fun((atom(), term(), list(), term()) -> term()), term()) -> term().
run(Ref, Inner, OnError, Context) ->
    try Inner()
    catch
        throw:{?CALLER_ERROR, Ref, Class, Reason, Stack} ->
            erlang:raise(Class, Reason, Stack);
        Class:Reason:Stack -> OnError(Class, Reason, Stack, Context)
    end.

-doc "Enter the caller after scope release, tagging errors for the matching invocation only.".
-spec prove(reference(), list(), tuple()) -> term().
prove(Ref, Next, St) ->
    try erlog_int:prove_body(Next, St)
    catch Class:Reason:Stack -> throw({?CALLER_ERROR, Ref, Class, Reason, Stack})
    end.

%% Keep scope records out of Prolog goals: dereferencing a yield must not walk
%% the saved caller continuation. Labels identify native invocation boundaries.
-spec take_boundary(term(), list()) -> {ok, list(), tuple(), term(), list()} | error.
take_boundary(Label, Cps) ->
    case lists:splitwith(fun
        (#cp{type = compiled, label = Found}) -> Found =/= Label;
        (_) -> true
    end, Cps) of
        {Inner, [#cp{next = Scope} = Boundary | Outer]} ->
            {ok, lists:reverse(Inner), Boundary, Scope, Outer};
        {_, []} -> error
    end.
