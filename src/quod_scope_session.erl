-module(quod_scope_session).
-moduledoc """
One co-hosted ontology scope for one top-level proof.

The target ontology engine owns and monitors this worker.  The worker keeps one
`quod_proof_session`—one staged overlay and read set—while separate logical
invocations retain their own Erlog continuations.  Commands are bound to an
unguessable session reference, the 32-byte proof id, and the origin worker.

`dispatch/1` is also used while an invocation is suspended inside `::`.  This
lets the same scope service a re-entrant invocation without a second worker or
a synchronous call to itself.
""".

-include("quod_proof_limits.hrl").

-export([start/8, open/5, next/4, cancel/2, close/1,
         dispatch/1, pid/1, identity/1]).

-record(runtime, {
          proof_id  :: <<_:256>>,
          origin    :: pid(),
          namespace :: binary(),
          height    :: non_neg_integer(),
          engine    :: pid(),
          ref       :: reference(),
          session   :: quod_proof_session:session(),
          invocations = #{} :: map(),
          step_depth = 0 :: non_neg_integer()
         }).

-type handle() :: {quod_scope_session, pid(), <<_:256>>, reference(),
                   binary(), <<_:256>>}.
-export_type([handle/0]).

-define(RUNTIME, '$quod_scope_session').
-doc "Spawn a reusable target scope and return the engine-owned monitor immediately.".
-spec start(<<_:256>>, pid(), binary(), <<_:256>>, non_neg_integer(), tuple(),
            pid(), map()) -> {handle(), reference()}.
start(<<_:256>> = ProofId, Origin, Ns, <<_:256>> = Anchor, Height,
      Est, Engine, Opts)
  when is_pid(Origin), is_binary(Ns), is_integer(Height), Height >= 0,
       is_pid(Engine), is_map(Opts) ->
    Ref = make_ref(),
    {Pid, WorkerMRef} =
        spawn_monitor(
          fun() -> init(ProofId, Origin, Ns, Height, Est, Engine, Ref, Opts) end),
    {{quod_scope_session, Pid, ProofId, Ref, Ns, Anchor}, WorkerMRef}.

-doc "Open one logical invocation. The calling process must be the bound origin.".
-spec open(handle(), reference(), term(), term(), [binary()]) -> ok.
open({quod_scope_session, Pid, ProofId, SessionRef, _Ns, _Anchor},
     RequestRef, InvocationId, Goal, Chain) ->
    Pid ! {scope_invoke_open, self(), ProofId, SessionRef,
           RequestRef, InvocationId, Goal, Chain},
    ok.

-doc "Request the next answer of an existing invocation.".
-spec next(handle(), reference(), term(), pos_integer()) -> ok.
next({quod_scope_session, Pid, ProofId, SessionRef, _Ns, _Anchor},
     RequestRef, InvocationId, ExpectedSeq) ->
    Pid ! {scope_invoke_next, self(), ProofId, SessionRef,
           RequestRef, InvocationId, ExpectedSeq},
    ok.

-doc "Drop one invocation continuation without rolling back its staged writes.".
-spec cancel(handle(), term()) -> ok.
cancel({quod_scope_session, Pid, ProofId, SessionRef, _Ns, _Anchor},
       InvocationId) ->
    Pid ! {scope_invoke_cancel, self(), ProofId, SessionRef, InvocationId},
    ok.

-doc "Close the complete ontology scope. Idempotent at the origin.".
-spec close(handle() | term()) -> ok.
close({quod_scope_session, Pid, ProofId, SessionRef, _Ns, _Anchor}) ->
    Pid ! {scope_close, self(), ProofId, SessionRef},
    ok;
close(_) ->
    ok.

-spec pid(handle()) -> pid().
pid({quod_scope_session, Pid, _ProofId, _Ref, _Ns, _Anchor}) -> Pid.

-spec identity(handle()) -> quod_proof_context:identity().
identity({quod_scope_session, _Pid, _ProofId, _Ref, Ns, Anchor}) ->
    {Ns, Anchor}.

-doc "Service one scope command re-entrantly while this worker waits in `::`.".
-spec dispatch(term()) -> handled | stop | unhandled.
dispatch(Message) ->
    case get(?RUNTIME) of
        #runtime{} -> dispatch_message(Message);
        undefined -> unhandled
    end.

init(ProofId, Origin, Ns, Height, Est, Engine, Ref, Opts) ->
    _ = quod_process:kill_when_owner_dies(Engine, self()),
    Metadata = {scope, ProofId, Origin, Ref, self()},
    case start_session(Est, Opts#{read_set => true,
                                  proof_context => Metadata}) of
        {ok, Session} ->
            Runtime = #runtime{proof_id = ProofId, origin = Origin,
                               namespace = Ns, height = Height, engine = Engine,
                               ref = Ref, session = Session},
            put(?RUNTIME, Runtime),
            run_loop(Ns, Session);
        {error, {Class, Reason, Stack}} ->
            logger:warning(
              "quod_scope_session[~s]: start failed: ~p:~p ~p",
              [Ns, Class, Reason, Stack])
    end.

start_session(Est, Opts) ->
    try {ok, quod_proof_session:start(Est, Opts)}
    catch Class:Reason:Stack -> {error, {Class, Reason, Stack}}
    end.

run_loop(Ns, Session) ->
    try loop()
    catch
        Class:Reason:Stack ->
            logger:warning(
              "quod_scope_session[~s]: worker crashed: ~p:~p ~p",
              [Ns, Class, Reason, Stack]),
            erlang:raise(Class, Reason, Stack)
    after
        _ = erase(?RUNTIME),
        quod_proof_session:stop(Session)
    end.

loop() ->
    receive
        Message ->
            case dispatch_message(Message) of
                stop -> ok;
                _ -> loop()
            end
    end.

dispatch_message({scope_invoke_open, Origin, ProofId, Ref,
                  RequestRef, InvocationId, Goal, Chain}) ->
    case valid_command(Origin, ProofId, Ref) of
        true -> handle_open(RequestRef, InvocationId, Goal, Chain);
        false -> handled
    end;
dispatch_message({scope_invoke_next, Origin, ProofId, Ref,
                  RequestRef, InvocationId, ExpectedSeq}) ->
    case valid_command(Origin, ProofId, Ref) of
        true -> handle_next(RequestRef, InvocationId, ExpectedSeq);
        false -> handled
    end;
dispatch_message({scope_invoke_cancel, Origin, ProofId, Ref, InvocationId}) ->
    case valid_command(Origin, ProofId, Ref) of
        true -> handle_cancel(InvocationId);
        false -> handled
    end;
dispatch_message({scope_close, Origin, ProofId, Ref}) ->
    case valid_command(Origin, ProofId, Ref) of
        true -> stop;
        false -> handled
    end;
dispatch_message(_) ->
    unhandled.

handle_open(RequestRef, InvocationId, Goal, Chain) ->
    Runtime0 = runtime(),
    Reply =
        case valid_invocation_input(Goal, Chain) of
            false -> {error, bad_request};
            true ->
                case maps:is_key(InvocationId, Runtime0#runtime.invocations) of
                    true -> {error, already_open};
                    false -> authorize_and_open(InvocationId, Goal, Chain, Runtime0)
                end
        end,
    send_reply(RequestRef, Reply),
    handled.

authorize_and_open(InvocationId, Goal, Chain,
                   #runtime{namespace = Ns, height = Height,
                            session = Session} = Runtime) ->
    case quod_ask:authorize_scope(Goal, Chain, Ns, Height, Session) of
        false -> {error, not_allowed};
        true ->
            Context = quod_predicates:proof_context(
                        Ns, Height, undefined, [Ns | Chain]),
            case quod_proof_session:open(
                   Session, InvocationId, Goal, Context) of
                ok ->
                    Invocations = (runtime())#runtime.invocations,
                    put_runtime(Runtime#runtime{
                      invocations = Invocations#{InvocationId => {1, 0}}}),
                    {opened, InvocationId};
                {error, Reason} -> {error, Reason}
            end
    end.

handle_next(RequestRef, InvocationId, ExpectedSeq)
  when is_integer(ExpectedSeq), ExpectedSeq > 0 ->
    Runtime0 = runtime(),
    case maps:find(InvocationId, Runtime0#runtime.invocations) of
        {ok, {ExpectedSeq, Count}} ->
            begin_step(),
            Result = try quod_proof_session:next(
                           Runtime0#runtime.session, InvocationId)
                     after end_step()
                     end,
            finish_next(RequestRef, InvocationId, ExpectedSeq, Count, Result);
        {ok, _Other} ->
            send_next_error(RequestRef, broken_stream),
            handled;
        error ->
            send_next_error(RequestRef, unknown_invocation),
            handled
    end;
handle_next(RequestRef, _InvocationId, _ExpectedSeq) ->
    send_next_error(RequestRef, broken_stream),
    handled.

finish_next(RequestRef, InvocationId, Seq, Count, {solution, Solution}) ->
    Runtime0 = runtime(),
    Dirty = quod_proof_session:dirty(Runtime0#runtime.session),
    case {Count < ?QUOD_MAX_ANSWERS_PER_INVOCATION,
          bounded_answer(Solution)} of
        {true, true} ->
            Invocations = Runtime0#runtime.invocations,
            put_runtime(Runtime0#runtime{
              invocations = Invocations#{InvocationId => {Seq + 1, Count + 1}}}),
            send_reply(RequestRef, {solution, Seq, Solution, Dirty});
        {false, _} ->
            remove_invocation(InvocationId),
            send_next_error(RequestRef, too_many_answers);
        {_, false} ->
            remove_invocation(InvocationId),
            send_next_error(RequestRef, answer_too_big)
    end,
    handled;
finish_next(RequestRef, InvocationId, Seq, _Count, {complete, Reasons}) ->
    Dirty = quod_proof_session:dirty((runtime())#runtime.session),
    remove_invocation_metadata(InvocationId),
    send_reply(RequestRef, {complete, Seq, Reasons, Dirty}),
    handled;
finish_next(RequestRef, InvocationId, _Seq, _Count, {error, Reason}) ->
    remove_invocation_metadata(InvocationId),
    send_next_error(RequestRef, Reason),
    handled.

send_next_error(RequestRef, Reason) ->
    Dirty = quod_proof_session:dirty((runtime())#runtime.session),
    send_reply(RequestRef, {error, Reason, Dirty}).

handle_cancel(InvocationId) ->
    remove_invocation(InvocationId),
    handled.

remove_invocation(InvocationId) ->
    Runtime = runtime(),
    ok = quod_proof_session:cancel(Runtime#runtime.session, InvocationId),
    remove_invocation_metadata(InvocationId).

remove_invocation_metadata(InvocationId) ->
    Runtime = runtime(),
    put_runtime(Runtime#runtime{
      invocations = maps:remove(InvocationId, Runtime#runtime.invocations)}).

begin_step() ->
    #runtime{step_depth = Depth, engine = Engine} = Runtime = runtime(),
    case Depth of
        0 -> Engine ! {ask_step_started, self()}, ok;
        _ -> ok
    end,
    put_runtime(Runtime#runtime{step_depth = Depth + 1}).

end_step() ->
    #runtime{step_depth = Depth, engine = Engine} = Runtime = runtime(),
    NextDepth = erlang:max(0, Depth - 1),
    put_runtime(Runtime#runtime{step_depth = NextDepth}),
    case NextDepth of
        0 -> Engine ! {ask_step_finished, self()}, ok;
        _ -> ok
    end.

send_reply(RequestRef, Reply) ->
    #runtime{origin = Origin, proof_id = ProofId, ref = Ref} = runtime(),
    Origin ! {scope_reply, self(), ProofId, Ref, RequestRef, Reply},
    ok.

valid_command(Origin, ProofId, Ref) ->
    case runtime() of
        #runtime{origin = Origin, proof_id = ProofId, ref = Ref} -> true;
        _ -> false
    end.

valid_invocation_input(Goal, Chain) ->
    is_list(Chain) andalso Chain =/= [] andalso
    length(Chain) < ?QUOD_MAX_ACTIVE_PROOF_DEPTH andalso
    lists:all(fun is_binary/1, Chain) andalso
    erlang:external_size(Goal) =< ?QUOD_MAX_NESTED_GOAL_BYTES.

bounded_answer(Answer) ->
    erlang:external_size(Answer) =< ?QUOD_MAX_PROOF_ANSWER_BYTES.

runtime() ->
    case get(?RUNTIME) of
        #runtime{} = Runtime -> Runtime;
        undefined -> erlang:error(no_scope_session)
    end.

put_runtime(#runtime{} = Runtime) -> put(?RUNTIME, Runtime), ok.
