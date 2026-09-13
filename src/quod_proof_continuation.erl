-module(quod_proof_continuation).
-moduledoc """
Exception boundary for proof controls that release their local scope before
running the caller. A caller error must never restore an already-released
savepoint or read-only frame. The reference is invocation-local and cannot
be forged by a Prolog term; no process or retained state is involved.
""".
-export([run/4, prove/3]).
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
