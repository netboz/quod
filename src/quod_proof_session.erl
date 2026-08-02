-module(quod_proof_session).
-moduledoc """
Worker-local owner of one staged ontology view and its invocation continuations.

A session wraps one committed Erlog state once. Every invocation starts with a
fresh proof frame over the session's current immutable overlay revision. After a
step, that revision becomes the session's canonical view; a later invocation—or
an older continuation resumed after it—therefore sees every staged write.

The small session record lives in its worker's process dictionary. This is not
an OTP process or a second database owner: it is the private rendezvous needed
while an Erlog call is suspended inside a nested ontology selector. The selector
publishes its current revision before waiting and refreshes its continuation
after a re-entrant invocation advances the same ontology. The opaque handle is
carried in `quod_erlog_db_local_prove`, outside Prolog-visible flags.
""".

-include_lib("erlog/src/erlog_int.hrl").
-include("quod_proof_limits.hrl").

-export([start/2, stop/1,
         open/4, next/2, cancel/2,
         publish/1, refresh/1, context/1,
         committed_state/1, local_changes/1, read_set/1, dirty/1,
         bindings/2, run_first/3]).

-ifdef(TEST).
-export([test_invocation_state/2]).
-endif.

-record(session_ref, {owner :: pid(), id :: reference()}).
-opaque session() :: #session_ref{}.
-export_type([session/0]).

-record(session_state, {
          current     :: tuple(),
          invocations = #{} :: #{term() => invocation_state()}
         }).

-type invocation_state() :: active | {idle, quod_proof_scope:scope()}.

-doc "Start one worker-local session over a committed ontology state.".
-spec start(tuple(), map()) -> session().
start(#est{} = Committed, OverlayOpts) when is_map(OverlayOpts) ->
    Handle = #session_ref{owner = self(), id = make_ref()},
    Metadata = maps:get(proof_context, OverlayOpts, undefined),
    PrivateContext = {session_ref, Handle, Metadata},
    Wrapped = quod_erlog_db_local_prove:wrap_state(
                Committed, OverlayOpts#{proof_context => PrivateContext}),
    put_session(Handle, #session_state{current = Wrapped}),
    Handle.

-doc "Stop a session and release its one shared read-set table. Idempotent.".
-spec stop(session()) -> ok.
stop(Handle) ->
    ensure_owner(Handle),
    case erase(session_key(Handle)) of
        #session_state{current = Current} ->
            quod_erlog_db_local_prove:cleanup_read_set(Current);
        undefined ->
            ok
    end.

-doc "Open a named invocation with a fresh proof frame and its semantic context.".
-spec open(session(), term(), term(), quod_predicates:ctx()) ->
          ok | {error, already_open | too_many_invocations}.
open(Handle, InvocationId, Goal, Context) ->
    State = get_session(Handle),
    Invocations = State#session_state.invocations,
    case maps:is_key(InvocationId, Invocations) of
        true ->
            {error, already_open};
        false when map_size(Invocations) >= ?QUOD_MAX_INVOCATIONS_PER_SCOPE ->
            {error, too_many_invocations};
        false ->
            Scope = quod_proof_scope:open_invocation(
                      Goal, State#session_state.current, Context),
            put_session(
              Handle,
              State#session_state{
                invocations = Invocations#{InvocationId => {idle, Scope}}}),
            ok
    end.

-doc "Derive one answer from an invocation, rebased onto the latest staged view.".
-spec next(session(), term()) ->
          {solution, term()} |
          {complete, [term()]} |
          {error, term()}.
next(Handle, InvocationId) ->
    State0 = get_session(Handle),
    case maps:find(InvocationId, State0#session_state.invocations) of
        error ->
            {error, unknown_invocation};
        {ok, active} ->
            {error, invocation_active};
        {ok, {idle, Scope0}} ->
            Scope1 = quod_proof_scope:rebase(
                       Scope0, State0#session_state.current),
            mark_active(Handle, InvocationId, State0),
            finish_step(
              Handle, InvocationId, quod_proof_scope:next(Scope1))
    end.

-doc "Discard one continuation without rolling back staged ontology writes.".
-spec cancel(session(), term()) -> ok.
cancel(Handle, InvocationId) ->
    State = get_session(Handle),
    put_session(
      Handle,
      State#session_state{
        invocations = maps:remove(
                        InvocationId, State#session_state.invocations)}),
    ok.

-doc "Publish the running invocation's current overlay before a nested hop.".
-spec publish(tuple()) -> ok.
publish(#est{} = St) ->
    Handle = state_handle(St),
    State = get_session(Handle),
    Current = install_state_revision(State#session_state.current, St),
    put_session(Handle, State#session_state{current = Current}),
    ok.

-doc "Refresh a suspended continuation after a nested hop advanced this ontology.".
-spec refresh(tuple()) -> tuple().
refresh(#est{} = St) ->
    Handle = state_handle(St),
    State = get_session(Handle),
    install_state_revision(St, State#session_state.current).

-doc "Return worker-owned proof metadata from a session-wrapped Erlog state.".
-spec context(tuple()) -> term().
context(#est{} = St) ->
    case quod_erlog_db_local_prove:proof_context(St) of
        {ok, {session_ref, #session_ref{}, Metadata}} -> Metadata;
        _ -> erlang:error(badarg)
    end.

-doc "Return a fresh proof frame over the session's pinned committed view.".
-spec committed_state(session()) -> tuple().
committed_state(Handle) ->
    quod_erlog_db_local_prove:committed_state(
      (get_session(Handle))#session_state.current).

-doc "Return all writes staged in the session's current ontology view.".
-spec local_changes(session()) -> list().
local_changes(Handle) ->
    overlay_local_changes((get_session(Handle))#session_state.current).

-doc "Return the session's monotonic committed-read dependencies.".
-spec read_set(session()) -> map().
read_set(Handle) ->
    overlay_read_set((get_session(Handle))#session_state.current).

-doc "Whether the session currently stages at least one effective content operation.".
-spec dirty(session()) -> boolean().
dirty(Handle) -> local_changes(Handle) =/= [].

-doc "Return the bindings retained by a suspended invocation.".
-spec bindings(session(), term()) ->
          {ok, map()} | {error, unknown_invocation | invocation_active}.
bindings(Handle, InvocationId) ->
    State = get_session(Handle),
    case maps:find(InvocationId, State#session_state.invocations) of
        {ok, {idle, Scope}} -> {ok, quod_proof_scope:bindings(Scope)};
        {ok, active} -> {error, invocation_active};
        error -> {error, unknown_invocation}
    end.

-doc "Run a root invocation to its first solution using the shared-session path.".
-spec run_first(term(), tuple(), map()) ->
          {ok, map(), list(), map()} | {fail, [term()]} | {error, term()}.
run_first(Goal, #est{} = Est, OverlayOpts) when is_map(OverlayOpts) ->
    Handle = start(Est, OverlayOpts),
    InvocationId = make_ref(),
    try
        ok = open(
               Handle, InvocationId, Goal, quod_predicates:context(Est)),
        case next(Handle, InvocationId) of
            {solution, _Solution} ->
                {ok, Bindings} = bindings(Handle, InvocationId),
                {ok, Bindings,
                 local_changes(Handle), read_set(Handle)};
            {complete, Reasons} ->
                {fail, Reasons};
            {error, Reason} ->
                {error, Reason}
        end
    after
        stop(Handle)
    end.

mark_active(Handle, InvocationId,
            #session_state{invocations = Invocations} = State) ->
    put_session(
      Handle,
      State#session_state{
        invocations = Invocations#{InvocationId => active}}).

finish_step(Handle, InvocationId, {solution, Solution, Scope}) ->
    update_after_step(Handle, InvocationId, Scope, keep),
    {solution, Solution};
finish_step(Handle, InvocationId, {complete, Reasons, Scope}) ->
    update_after_step(Handle, InvocationId, Scope, remove),
    {complete, Reasons};
finish_step(Handle, InvocationId, {error, Reason, Scope, RevisionPolicy}) ->
    update_after_step(Handle, InvocationId, Scope, remove, RevisionPolicy),
    {error, Reason}.

update_after_step(Handle, InvocationId, Scope, Retention) ->
    update_after_step(Handle, InvocationId, Scope, Retention, adopt).

update_after_step(Handle, InvocationId, Scope, Retention, RevisionPolicy) ->
    %% Fetch again: nested selector handling may have opened or advanced other
    %% invocations while this step was suspended.
    State = get_session(Handle),
    Current =
        case RevisionPolicy of
            adopt ->
                install_state_revision(
                  State#session_state.current,
                  quod_proof_scope:state(Scope));
            %% A state-less infrastructure error poisons the complete proof.
            %% Until cleanup, retain the last revision published before the
            %% nested hop instead of rewinding over re-entrant work.
            keep_current ->
                State#session_state.current
        end,
    Invocations0 = State#session_state.invocations,
    Invocations1 =
        case maps:find(InvocationId, Invocations0) of
            {ok, active} when Retention =:= keep ->
                Invocations0#{InvocationId => {idle, Scope}};
            {ok, active} ->
                maps:remove(InvocationId, Invocations0);
            %% A re-entrant cancellation wins and the continuation stays gone.
            _ ->
                Invocations0
        end,
    put_session(
      Handle,
      State#session_state{current = Current,
                          invocations = Invocations1}).

install_state_revision(Target, Source) ->
    quod_erlog_db_local_prove:replace_revision(
      Target, quod_erlog_db_local_prove:revision(Source)).

overlay_local_changes(#est{db = #db{ref = Overlay}}) ->
    quod_erlog_db_local_prove:get_local_changes(Overlay).

overlay_read_set(#est{db = #db{ref = Overlay}}) ->
    quod_erlog_db_local_prove:get_read_set(Overlay).

state_handle(St) ->
    case quod_erlog_db_local_prove:proof_context(St) of
        {ok, {session_ref, #session_ref{} = Handle, _Metadata}} -> Handle;
        _ -> erlang:error(badarg)
    end.

-ifdef(TEST).
test_invocation_state(Handle, InvocationId) ->
    State = get_session(Handle),
    case maps:find(InvocationId, State#session_state.invocations) of
        {ok, {idle, Scope}} -> {ok, quod_proof_scope:state(Scope)};
        {ok, active} -> {error, invocation_active};
        error -> {error, unknown_invocation}
    end.
-endif.

get_session(Handle) ->
    ensure_owner(Handle),
    case get(session_key(Handle)) of
        #session_state{} = State -> State;
        undefined -> erlang:error(badarg)
    end.

put_session(Handle, #session_state{} = State) ->
    ensure_owner(Handle),
    _ = put(session_key(Handle), State),
    ok.

session_key(#session_ref{id = Id}) -> {?MODULE, Id}.

ensure_owner(#session_ref{owner = Owner}) when Owner =:= self() -> ok;
ensure_owner(_Handle) -> erlang:error(badarg).
