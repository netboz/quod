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
         open/6, next/2, cancel/2,
         publish/1, refresh/1, context/1,
         access_guard/1, check_access/1, check_mutable/1,
         committed_state/1, local_changes/1, effects/1,
         prepared_effect/2, signer_from_state/1,
         read_set/1, absorb_read_set/2, absorb_live_bridges/2,
         live_bridges/1, transcript/1, signer/1,
         seal/2, attest/2,
         dirty/1,
         checkpoint_many/2, restore_many/2, release_many/2,
         overlay_generation/1,
         bindings/2, open_first/6, run_first/3,
         run_first_with_dependencies/3]).

-ifdef(TEST).
-export([test_invocation_state/2]).
-endif.

-record(session_ref, {owner :: pid(), id :: reference()}).
-opaque session() :: #session_ref{}.
-export_type([session/0]).

-record(session_state, {
          scope_id    :: <<_:128>>,
          current     :: tuple(),
          signer = none :: quod_identity:signer() | none,
          invocations = #{} :: #{term() => invocation_state()},
          %% Invocation ids are transcript identities, not reusable worker
          %% slots. Keep the bounded lifetime set separately from the live
          %% continuations so cancel/exhaustion cannot reopen an old slot.
          used_invocations = #{} :: #{term() => true},
          savepoints  = #{} :: #{term() => quod_erlog_db_local_prove:revision()},
          %% One irreversible lifecycle shared by local, co-hosted, and remote
          %% scope facades.  The exact seal input is retained so only an exact
          %% retry can recover the cached immutable result.
          lifecycle = open ::
              open | {sealed, map(), not_material | {ok, quod_dtx:plan()}},
          attestation = open ::
              open | {<<_:256>>, quod_dtx:attestation()},
          overlay_generation = 0 :: non_neg_integer(),
          %% The bounded canonical invocation transcript (`m:quod_dtx`).
          %% `transcript_rev` holds
          %% `{InvocationId, Chain, RequestedGoalBin, Verdict}` in reverse open
          %% order. RequestedGoalBin is canonical atom-safe wire data, never raw
          %% atom-bearing ETF; `answers` holds each invocation's evolving
          %% `{Count, ChainedDigest, Tag}`. Recording is off (`transcript_bytes
          %% = disabled`) for read-only sessions and sessions without a proof
          %% context — they can never seal a plan.
          transcript_rev = [] ::
              [{binary(), list(), binary(), allowed | denied}],
          transcript_bytes = disabled :: disabled | non_neg_integer(),
          answers = #{} :: #{term() => {non_neg_integer(), binary(),
                                        active | complete | error | cancelled}}
         }).

%% Fixed per-invocation transcript overhead charged at open, covering the
%% final entry's count, chained digest, and completion tag.
-define(TRANSCRIPT_ENTRY_SLACK_BYTES, 96).
-define(TRANSCRIPT_DIGEST_SEED, <<0:256>>).

-type invocation_state() ::
        active |
        {idle, quod_proof_scope:scope(), quod_transaction_scope:selection()}.

-doc "Start one worker-local session over a committed ontology state.".
-spec start(tuple(), map()) -> session().
start(#est{} = Committed, OverlayOpts) when is_map(OverlayOpts) ->
    Handle = #session_ref{owner = self(), id = make_ref()},
    ScopeId = session_scope_id(OverlayOpts),
    Metadata = maps:get(proof_context, OverlayOpts, undefined),
    PrivateContext = {session_ref, Handle, Metadata},
    Wrapped = quod_erlog_db_local_prove:wrap_state(
                Committed, OverlayOpts#{proof_context => PrivateContext}),
    TranscriptBytes =
        case Metadata =/= undefined andalso
             not maps:get(read_only, OverlayOpts, false) of
            true -> 0;
            false -> disabled
        end,
    Signer = maps:get(signer, OverlayOpts, none),
    put_session(Handle, #session_state{scope_id = ScopeId,
                                       current = Wrapped,
                                       signer = Signer,
                                       transcript_bytes = TranscriptBytes}),
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

-doc "Open a policy-decided invocation over its original requested goal.".
-spec open(session(), term(), term(), allowed | denied, quod_predicates:ctx(),
           quod_transaction_scope:selection()) ->
          ok | {error, term()}.
open(Handle, InvocationId, RequestedGoal, Verdict, Context, Selection) ->
    State = get_session(Handle),
    case check_state_mutable(State) of
        {error, _} = Error -> Error;
        ok -> open_checked(Handle, InvocationId, RequestedGoal, Verdict,
                           Context, Selection, State)
    end.

open_checked(Handle, InvocationId, RequestedGoal, Verdict,
             Context, Selection, State) ->
    Invocations = State#session_state.invocations,
    UsedInvocations = State#session_state.used_invocations,
    case {is_binary(InvocationId) andalso byte_size(InvocationId) =:= 16,
          maps:is_key(InvocationId, UsedInvocations),
          quod_transaction_scope:valid_selection(Selection),
          execution_goal(Verdict, RequestedGoal, Context)} of
        {false, _, _, _} ->
            {error, {protocol_error, bad_binding}};
        {_, _, false, _} ->
            {error, {protocol_error, bad_selection}};
        {_, _, _, error} ->
            {error, {protocol_error, bad_binding}};
        {true, true, true, _} ->
            {error, {protocol_error, bad_binding}};
        {true, false, true, _} when map_size(UsedInvocations) >=
                              ?QUOD_MAX_INVOCATIONS_PER_SCOPE ->
            invocation_limit_error(Context);
        {true, false, true, {ok, ExecutionGoal}} ->
            case charge_transcript(State, InvocationId, RequestedGoal,
                                   Verdict, Context) of
                {ok, State1} ->
                    Scope = quod_proof_scope:open_invocation(
                              ExecutionGoal, State1#session_state.current,
                              Context,
                              quod_transaction_scope:checkpoint_depth(
                                Selection)),
                    put_session(
                      Handle,
                      State1#session_state{
                        invocations = Invocations#{
                          InvocationId => {idle, Scope, Selection}},
                        used_invocations = UsedInvocations#{InvocationId => true}}),
                    ok;
                {error, _} = Error ->
                    Error
            end
    end.

execution_goal(allowed, RequestedGoal, _Context) ->
    {ok, RequestedGoal};
execution_goal(denied, _RequestedGoal, Context) ->
    case quod_predicates:ctx_ns(Context) of
        Ns when is_binary(Ns), byte_size(Ns) > 0 ->
            {ok, {fail_with_reason, {not_allowed, Ns}}};
        undefined ->
            error
    end;
execution_goal(_Verdict, _RequestedGoal, _Context) ->
    error.

%% The transcript charge is taken BEFORE the goal runs: an invocation the
%% transcript cannot afford never executes, so a sealed plan's transcript is
%% complete by construction — there is no way to run work it does not record.
charge_transcript(
  #session_state{transcript_bytes = disabled} = State,
  _InvocationId, _RequestedGoal, _Verdict, _Context) ->
    {ok, State};
charge_transcript(
  #session_state{transcript_rev = Entries,
                 transcript_bytes = Bytes,
                 answers = Answers} = State,
  InvocationId, RequestedGoal, Verdict, Context) ->
    Chain = quod_predicates:ctx_chain(Context),
    case quod_wire_term:encode_canonical(RequestedGoal) of
        {ok, RequestedGoalBin}
          when byte_size(RequestedGoalBin) =< ?QUOD_MAX_NESTED_GOAL_BYTES ->
            Entry = {InvocationId, Chain, RequestedGoalBin, Verdict},
            Cost = erlang:external_size(Entry) + ?TRANSCRIPT_ENTRY_SLACK_BYTES,
            case Bytes + Cost =< ?QUOD_MAX_SCOPE_TRANSCRIPT_BYTES of
                true ->
                    {ok, State#session_state{
                           transcript_rev = [Entry | Entries],
                           transcript_bytes = Bytes + Cost,
                           answers = Answers#{
                             InvocationId =>
                                 {0, ?TRANSCRIPT_DIGEST_SEED, active}}}};
                false ->
                    {error, {too_large, transcript}}
            end;
        _ ->
            {error, {too_large, transcript}}
    end.

invocation_limit_error(Context) ->
    case quod_predicates:ctx_ns(Context) of
        Ns when is_binary(Ns) -> {error, {proof_limit_exceeded, Ns}};
        undefined -> {error, {protocol_error, bad_binding}}
    end.

-doc "Derive one answer from an invocation, rebased onto the latest staged view.".
-spec next(session(), term()) ->
          {solution, term()} |
          {complete, [term()]} |
          {error, term()}.
next(Handle, InvocationId) ->
    State0 = get_session(Handle),
    case check_lifecycle_mutable(State0) of
        {error, _} = Error -> Error;
        ok -> next_access_checked(Handle, InvocationId, State0)
    end.

next_access_checked(Handle, InvocationId, State0) ->
    case check_state_access(State0) of
        {error, Reason} ->
            invalidate_invocation(Handle, InvocationId, State0),
            {error, Reason};
        ok ->
            next_checked(Handle, InvocationId, State0)
    end.

next_checked(Handle, InvocationId, State0) ->
    case maps:find(InvocationId, State0#session_state.invocations) of
        error ->
            {error, unknown_invocation};
        {ok, active} ->
            {error, invocation_active};
        {ok, {idle, Scope0, Selection0}} ->
            Scope1 = quod_proof_scope:rebase(
                       Scope0, State0#session_state.current),
            mark_active(Handle, InvocationId, State0),
            Metadata = context(quod_proof_scope:state(Scope1)),
            {Step, Selection1} = quod_transaction_scope:with_invocation(
                                   {State0#session_state.scope_id, InvocationId},
                                   Selection0, Metadata,
                                   fun() -> quod_proof_scope:next(Scope1) end),
            finish_step(Handle, InvocationId, Step, Selection1)
    end.

-doc "Discard one continuation without rolling back staged ontology writes.".
-spec cancel(session(), term()) -> ok | {error, term()}.
cancel(Handle, InvocationId) ->
    State0 = get_session(Handle),
    case check_lifecycle_mutable(State0) of
        {error, _} = Error -> Error;
        ok ->
            State = note_transcript(State0, InvocationId, cancelled),
            put_session(
              Handle,
              State#session_state{
                invocations = maps:remove(
                                InvocationId,
                                State#session_state.invocations)}),
            ok
    end.

-doc "Publish the running invocation's current overlay before a nested hop.".
-spec publish(tuple()) -> ok.
publish(#est{} = St) ->
    Handle = state_handle(St),
    State = get_session(Handle),
    ensure_state_mutable(State),
    Current = install_state_revision(State#session_state.current, St),
    put_current(Handle, State, Current),
    ok.

-doc "Refresh a suspended continuation after a nested hop advanced this ontology.".
-spec refresh(tuple()) -> tuple().
refresh(#est{} = St) ->
    Handle = state_handle(St),
    State = get_session(Handle),
    ensure_state_mutable(State),
    install_state_revision(St, State#session_state.current).

-doc "Return worker-owned proof metadata from a session-wrapped Erlog state.".
-spec context(tuple()) -> term().
context(#est{} = St) ->
    case quod_erlog_db_local_prove:proof_context(St) of
        {ok, {session_ref, #session_ref{}, Metadata}} -> Metadata;
        _ -> erlang:error(badarg)
    end.

-doc "The immutable namespace access token shared by this session and its sub-proofs.".
-spec access_guard(session()) -> quod_erlog_db_local_prove:access_guard().
access_guard(Handle) ->
    quod_erlog_db_local_prove:access_guard(
      (get_session(Handle))#session_state.current).

-doc "Revalidate the session immediately before exposing or sealing its staged state.".
-spec check_access(session()) -> ok | {error, term()}.
check_access(Handle) ->
    check_state_access(get_session(Handle)).

-doc "Revalidate both namespace access and the session's mutable lifecycle.".
-spec check_mutable(session()) -> ok | {error, term()}.
check_mutable(Handle) ->
    check_state_mutable(get_session(Handle)).

-doc "Return a fresh proof frame over the session's pinned committed view.".
-spec committed_state(session()) -> tuple().
committed_state(Handle) ->
    State = get_session(Handle),
    quod_erlog_db_local_prove:committed_state(State#session_state.current).

-doc "Return all writes staged in the session's current ontology view.".
-spec local_changes(session()) -> list().
local_changes(Handle) ->
    State = get_session(Handle),
    overlay_local_changes(State#session_state.current).

-doc "Return the direct effects staged in the current immutable revision.".
-spec effects(session()) -> [quod_effect:effect()].
effects(Handle) ->
    State = get_session(Handle),
    overlay_effects(State#session_state.current).

-doc "Return private preparation for one effect in the current revision.".
-spec prepared_effect(session(), quod_effect:effect()) ->
          {ok, {term(), term(), quod_effect:effect(), term()}} | error.
prepared_effect(Handle, Effect) ->
    State = get_session(Handle),
    quod_erlog_db_local_prove:prepared_effect(
      State#session_state.current, Effect).

-doc "Return the session signer bound to the exact wrapped proof state.".
-spec signer_from_state(tuple()) -> map() | none.
signer_from_state(St) ->
    case quod_erlog_db_local_prove:proof_context(St) of
        {ok, {session_ref, #session_ref{} = Handle, _Metadata}} ->
            signer(Handle);
        _ -> erlang:error(badarg)
    end.

-doc "Return the session's monotonic committed-read dependencies.".
-spec read_set(session()) -> map().
read_set(Handle) ->
    State = get_session(Handle),
    overlay_read_set(State#session_state.current).

-doc """
Merge an authorization proof's committed reads into this session's dependencies.

The policy decision is proved on its own read-only frame over the same pinned
committed base, so its reads belong to the plan this scope seals: a later
committed change to a policy predicate the decision consulted must conflict.
""".
-spec absorb_read_set(session(), map()) -> ok.
absorb_read_set(Handle, Reads) ->
    State = get_session(Handle),
    ensure_lifecycle_mutable(State),
    quod_erlog_db_local_prove:absorb_read_set(
      State#session_state.current, Reads).

-doc "Merge live bridge observations separately from committed OCC reads.".
-spec absorb_live_bridges(session(), [{atom(), arity()}]) -> ok.
absorb_live_bridges(Handle, Bridges) ->
    State = get_session(Handle),
    ensure_lifecycle_mutable(State),
    quod_erlog_db_local_prove:absorb_live_bridges(
      State#session_state.current, Bridges).

-doc "The live reality-bridge predicates this session's proofs consulted.".
-spec live_bridges(session()) -> [{atom(), arity()}].
live_bridges(Handle) ->
    State = get_session(Handle),
    overlay_live_bridges(State#session_state.current).

-doc """
The session's bounded canonical invocation transcript and final overlay
generation, in open order: `{InvocationId, Chain, RequestedGoalBin, Verdict,
AnswerCount, ChainedAnswerDigest, Tag}` per invocation. Empty for a session
that records none (read-only, or no proof context). `RequestedGoalBin` is the
canonical `quod_wire_term` encoding of the original requested goal.
""".
-spec transcript(session()) ->
          {[quod_dtx:transcript_entry()], non_neg_integer()}.
transcript(Handle) ->
    #session_state{transcript_rev = EntriesRev,
                   answers = Answers,
                   overlay_generation = Generation} = State = get_session(Handle),
    ensure_state_access(State),
    Entries =
        [begin
             {Count, Digest, Tag} = maps:get(InvocationId, Answers),
             {InvocationId, Chain, RequestedGoalBin, Verdict,
              Count, Digest, Tag}
         end || {InvocationId, Chain, RequestedGoalBin, Verdict}
                    <- lists:reverse(EntriesRev)],
    {Entries, Generation}.

-doc "Whether the session currently stages content or a durable direct effect.".
-spec dirty(session()) -> boolean().
dirty(Handle) ->
    local_changes(Handle) =/= [] orelse effects(Handle) =/= [].

-doc "Atomically retain one current immutable revision under bounded batch ids.".
-spec checkpoint_many(session(), [term()]) ->
          ok | {error, term()}.
checkpoint_many(Handle, SavepointIds0) when is_list(SavepointIds0) ->
    State = get_session(Handle),
    case check_lifecycle_mutable(State) of
        {error, _} = Error -> Error;
        ok ->
            ensure_state_access(State),
            checkpoint_many_checked(Handle, State, SavepointIds0)
    end.

checkpoint_many_checked(Handle, State, SavepointIds0) ->
    Savepoints = State#session_state.savepoints,
    SavepointIds = lists:usort(SavepointIds0),
    NewIds = [Id || Id <- SavepointIds,
                    not maps:is_key(Id, Savepoints)],
    case map_size(Savepoints) + length(NewIds) =<
           ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF of
        true ->
            Revision = quod_erlog_db_local_prove:revision(
                         State#session_state.current),
            Retained = lists:foldl(
                         fun(Id, Acc) -> Acc#{Id => Revision} end,
                         Savepoints, NewIds),
            put_session(
              Handle,
              State#session_state{savepoints = Retained}),
            ok;
        false ->
            {error,
             {savepoint_limit_exceeded,
              ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF}}
    end.

-doc "The target-node witness configured by the owning ontology engine.".
-spec signer(session()) -> quod_identity:signer() | none.
signer(Handle) ->
    (get_session(Handle))#session_state.signer.

-doc "Seal once and return the byte-identical cached result on an exact retry.".
-spec seal(session(), map()) ->
          {ok, quod_dtx:plan()} | not_material | {error, term()}.
seal(Handle, Bindings) when is_map(Bindings) ->
    State = get_session(Handle),
    case State#session_state.lifecycle of
        open ->
            case check_state_access(State) of
                {error, _} = Error -> Error;
                ok -> latch_seal(Handle, State, Bindings)
            end;
        {sealed, Bindings, Result} ->
            Result;
        {sealed, _OtherBindings, _Result} ->
            {error, {protocol_error, request_binding}}
    end;
seal(_Handle, _Bindings) ->
    {error, {protocol_error, request_binding}}.

latch_seal(Handle, State, Bindings) ->
    case quod_dtx:seal_session(Handle, Bindings) of
        {ok, _Plan} = Result ->
            put_session(
              Handle,
              State#session_state{lifecycle =
                                      {sealed, Bindings, Result}}),
            Result;
        not_material = Result ->
            put_session(
              Handle,
              State#session_state{lifecycle =
                                      {sealed, Bindings, Result}}),
            Result;
        {error, _} = Error ->
            Error
    end.

-doc "Bind a sealed material plan to the first valid coordination manifest.".
-spec attest(session(), quod_dtx:manifest()) ->
          {ok, quod_dtx:attestation()} | {error, term()}.
attest(Handle, Manifest) ->
    State = get_session(Handle),
    case check_state_access(State) of
        ok -> attest_checked(Handle, State, Manifest);
        {error, _} = Error -> Error
    end.

attest_checked(Handle, State, Manifest) ->
    case {State#session_state.lifecycle, State#session_state.attestation} of
        {{sealed, _Bindings, {ok, Plan}}, open} ->
            latch_attestation(Handle, State, Plan, Manifest);
        {{sealed, _Bindings, {ok, _Plan}}, {Digest, Attestation}} ->
            case checked_manifest_digest(Manifest) of
                {ok, Digest} -> {ok, Attestation};
                {ok, _OtherDigest} ->
                    {error, {protocol_error, manifest_binding}};
                {error, _} = Error -> Error
            end;
        _ ->
            {error, {protocol_error, unexpected_scope_command}}
    end.

latch_attestation(Handle, State, Plan, Manifest) ->
    Target = quod_dtx:target(Plan),
    case quod_dtx:attest_plan(
           Target, Plan, Manifest, State#session_state.signer) of
        {ok, Attestation} = Result ->
            Digest = quod_dtx:manifest_digest(Manifest),
            put_session(
              Handle,
              State#session_state{
                attestation = {Digest, Attestation}}),
            Result;
        {error, _} = Error ->
            Error
    end.

checked_manifest_digest(Manifest) ->
    case quod_dtx:encode_manifest(Manifest) of
        {ok, _} -> {ok, quod_dtx:manifest_digest(Manifest)};
        {error, _} -> {error, invalid_plan_attestation}
    end.

-doc "Atomically restore a set of ids that name the same immutable revision.".
-spec restore_many(session(), [term()]) ->
          ok | {error, term()}.
restore_many(Handle, SavepointIds0) when is_list(SavepointIds0) ->
    State = get_session(Handle),
    case check_lifecycle_mutable(State) of
        {error, _} = Error -> Error;
        ok ->
            ensure_state_access(State),
            restore_many_checked(Handle, State, SavepointIds0)
    end.

restore_many_checked(Handle, State, SavepointIds0) ->
    SavepointIds = lists:usort(SavepointIds0),
    case retained_revision(SavepointIds, State#session_state.savepoints) of
        none ->
            ok;
        {ok, Revision} ->
            Current = quod_erlog_db_local_prove:replace_revision(
                        State#session_state.current, Revision),
            put_current(Handle, State, Current),
            ok;
        {error, _} = Error ->
            Error
    end.

-doc "Forget retained batch revisions. Repeated release is harmless.".
-spec release_many(session(), [term()]) -> ok | {error, term()}.
release_many(Handle, SavepointIds0) when is_list(SavepointIds0) ->
    State = get_session(Handle),
    case check_lifecycle_mutable(State) of
        {error, _} = Error -> Error;
        ok ->
            ensure_state_access(State),
            SavepointIds = lists:usort(SavepointIds0),
            Retained = lists:foldl(
                         fun maps:remove/2,
                         State#session_state.savepoints, SavepointIds),
            put_session(
              Handle,
              State#session_state{savepoints = Retained}),
            ok
    end.

retained_revision([], _Savepoints) ->
    none;
retained_revision([Id | Rest], Savepoints) ->
    case maps:find(Id, Savepoints) of
        {ok, Revision} -> retained_revision(Rest, Savepoints, Revision);
        error -> {error, unknown_savepoint}
    end.

retained_revision([Id | Rest], Savepoints, Revision) ->
    case maps:find(Id, Savepoints) of
        {ok, Revision} -> retained_revision(Rest, Savepoints, Revision);
        {ok, _Other} -> {error, inconsistent_savepoint};
        error -> {error, unknown_savepoint}
    end;
retained_revision([], _Savepoints, Revision) ->
    {ok, Revision}.

-doc "Monotonic target-local number for correlating state-bearing events.".
-spec overlay_generation(session()) -> non_neg_integer().
overlay_generation(Handle) ->
    (get_session(Handle))#session_state.overlay_generation.

-doc "Return the bindings retained by a suspended invocation.".
-spec bindings(session(), term()) ->
          {ok, map()} | {error, term()}.
bindings(Handle, InvocationId) ->
    State = get_session(Handle),
    case check_state_access(State) of
        {error, _} = Error -> Error;
        ok ->
            case maps:find(InvocationId, State#session_state.invocations) of
                {ok, {idle, Scope, _Selection}} ->
                    {ok, quod_proof_scope:bindings(Scope)};
                {ok, active} -> {error, invocation_active};
                error -> {error, unknown_invocation}
            end
    end.

-doc "Run a root invocation to its first solution using the shared-session path.".
-spec run_first(term(), tuple(), map()) ->
          {ok, map(), list(), map()} | {fail, [term()]} | {error, term()}.
run_first(Goal, #est{} = Est, OverlayOpts) when is_map(OverlayOpts) ->
    Handle = start(Est, OverlayOpts),
    InvocationId = crypto:strong_rand_bytes(16),
    try
        open_first(Handle, InvocationId, Goal,
                   allowed,
                   quod_predicates:context(Est),
                   quod_transaction_scope:empty_selection())
    after
        stop(Handle)
    end.

-doc "Run one isolated invocation and retain its typed read dependencies.".
-spec run_first_with_dependencies(term(), tuple(), map()) ->
          {{ok, map(), list(), map()} | {fail, [term()]} | {error, term()},
           [{atom(), arity()}]}.
run_first_with_dependencies(Goal, #est{} = Est, OverlayOpts)
  when is_map(OverlayOpts) ->
    Handle = start(Est, OverlayOpts),
    InvocationId = crypto:strong_rand_bytes(16),
    try
        Result = open_first(
                   Handle, InvocationId, Goal, allowed,
                   quod_predicates:context(Est),
                   quod_transaction_scope:empty_selection()),
        {Result, live_bridges(Handle)}
    after
        stop(Handle)
    end.

-doc "Open one invocation and derive its first result, leaving session ownership to the caller.".
-spec open_first(session(), <<_:128>>, term(), allowed | denied,
                 quod_predicates:ctx(),
                 quod_transaction_scope:selection()) ->
          {ok, map(), list(), map()} | {fail, [term()]} | {error, term()}.
open_first(Handle, InvocationId, Goal, Verdict, Context, Selection) ->
    case open(Handle, InvocationId, Goal, Verdict, Context, Selection) of
        ok -> first_result(Handle, InvocationId);
        {error, _} = Error -> Error
    end.

first_result(Handle, InvocationId) ->
    case next(Handle, InvocationId) of
        {solution, _Solution} ->
            first_solution_result(Handle, InvocationId);
        {complete, Reasons} ->
            {fail, Reasons};
        {error, Reason} ->
            {error, Reason}
    end.

first_solution_result(Handle, InvocationId) ->
    try bindings(Handle, InvocationId) of
        {ok, Bindings} ->
            Result = {ok, Bindings, local_changes(Handle), read_set(Handle)},
            case check_access(Handle) of
                ok -> Result;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    catch
        throw:{quod_ask_error, Reason} -> {error, Reason}
    end.

mark_active(Handle, InvocationId,
            #session_state{invocations = Invocations} = State) ->
    put_session(
      Handle,
      State#session_state{
        invocations = Invocations#{InvocationId => active}}).

finish_step(Handle, InvocationId, {solution, Solution, Scope}, Selection) ->
    finish_mutable_step(
      Handle, InvocationId, Scope, Selection, keep,
      adopt, {answer, Solution}, {solution, Solution});
finish_step(Handle, InvocationId, {complete, Reasons, Scope}, Selection) ->
    finish_mutable_step(
      Handle, InvocationId, Scope, Selection, remove,
      adopt, complete, {complete, Reasons});
finish_step(Handle, InvocationId,
            {error, Reason, Scope, RevisionPolicy}, Selection) ->
    case check_lifecycle_mutable(get_session(Handle)) of
        ok ->
            update_after_step(
              Handle, InvocationId, Scope, Selection, remove,
              RevisionPolicy, error),
            {error, Reason};
        {error, _} = Error -> Error
    end.

finish_mutable_step(Handle, InvocationId, Scope, Selection, Retention,
                    RevisionPolicy, TranscriptEvent, Result) ->
    case check_lifecycle_mutable(get_session(Handle)) of
        ok ->
            update_after_step(
              Handle, InvocationId, Scope, Selection, Retention,
              RevisionPolicy, TranscriptEvent),
            expose_step(Handle, InvocationId, Result);
        {error, _} = Error -> Error
    end.

%% The proof-scope runner checks before and after the interpreter step. This
%% final check is deliberately after transcript/revision publication as well,
%% so a gate change during that bookkeeping cannot expose a stale answer.
expose_step(Handle, InvocationId, Result) ->
    State = get_session(Handle),
    case check_state_access(State) of
        ok -> Result;
        {error, Reason} ->
            invalidate_invocation(Handle, InvocationId, State),
            {error, Reason}
    end.

invalidate_invocation(Handle, InvocationId,
                      #session_state{invocations = Invocations} = State) ->
    put_session(
      Handle,
      State#session_state{
        invocations = maps:remove(InvocationId, Invocations)}).

update_after_step(Handle, InvocationId, Scope, Selection,
                  Retention, RevisionPolicy, TranscriptEvent) ->
    %% Fetch again: nested selector handling may have opened or advanced other
    %% invocations while this step was suspended.
    State = note_transcript(get_session(Handle), InvocationId,
                            TranscriptEvent),
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
                Invocations0#{InvocationId => {idle, Scope, Selection}};
            {ok, active} ->
                maps:remove(InvocationId, Invocations0);
            %% A re-entrant cancellation wins and the continuation stays gone.
            _ ->
                Invocations0
        end,
    put_current(
      Handle,
      State#session_state{invocations = Invocations1},
      Current).

%% Fold one step outcome into the invocation's transcript slot. Answers extend
%% the chained digest — `H(Prev ++ Seq ++ H(Solution))` — so the entry stays
%% O(1) per answer while still binding every answer's exact content and order.
%% Only the first terminal tag sticks; a cleanup cancel after completion is not
%% a second outcome.
note_transcript(#session_state{transcript_bytes = disabled} = State,
                _InvocationId, _Event) ->
    State;
note_transcript(#session_state{answers = Answers} = State,
                InvocationId, Event) ->
    case maps:find(InvocationId, Answers) of
        {ok, {Count, Digest, active}} ->
            Slot =
                case Event of
                    {answer, Solution} ->
                        Seq = Count + 1,
                        SolutionDigest =
                            crypto:hash(
                              sha256,
                              term_to_binary(Solution, [deterministic])),
                        {Seq,
                         crypto:hash(
                           sha256,
                           <<Digest/binary, Seq:64/unsigned-big,
                             SolutionDigest/binary>>),
                         active};
                    Tag when Tag =:= complete; Tag =:= error;
                             Tag =:= cancelled ->
                        {Count, Digest, Tag}
                end,
            State#session_state{answers = Answers#{InvocationId => Slot}};
        _ ->
            State
    end.

put_current(Handle, #session_state{current = Current} = State, Current) ->
    %% Publishing an identical immutable revision does not create a new wire
    %% generation. This keeps the number tied to actual canonical state change.
    put_session(Handle, State);
put_current(Handle, #session_state{overlay_generation = Generation} = State,
            Current) ->
    put_session(
      Handle,
      State#session_state{current = Current,
                          overlay_generation = Generation + 1}).

install_state_revision(Target, Source) ->
    quod_erlog_db_local_prove:replace_revision(
      Target, quod_erlog_db_local_prove:revision(Source)).

overlay_local_changes(#est{db = #db{ref = Overlay}}) ->
    quod_erlog_db_local_prove:get_local_changes(Overlay).

overlay_effects(#est{db = #db{ref = Overlay}}) ->
    quod_erlog_db_local_prove:get_effects(Overlay).

overlay_read_set(#est{db = #db{ref = Overlay}}) ->
    quod_erlog_db_local_prove:get_read_set(Overlay).

overlay_live_bridges(#est{db = #db{ref = Overlay}}) ->
    quod_erlog_db_local_prove:get_live_bridges(Overlay).

check_state_access(#session_state{current = Current}) ->
    quod_erlog_db_local_prove:check_access(Current).

check_state_mutable(State) ->
    case check_lifecycle_mutable(State) of
        ok -> check_state_access(State);
        {error, _} = Error -> Error
    end.

check_lifecycle_mutable(#session_state{lifecycle = open}) -> ok;
check_lifecycle_mutable(#session_state{}) ->
    {error, {protocol_error, unexpected_scope_command}}.

ensure_state_access(State) ->
    case check_state_access(State) of
        ok -> ok;
        {error, Reason} -> throw({quod_ask_error, Reason})
    end.

ensure_state_mutable(State) ->
    case check_state_mutable(State) of
        ok -> ok;
        {error, Reason} -> throw({quod_ask_error, Reason})
    end.

ensure_lifecycle_mutable(State) ->
    case check_lifecycle_mutable(State) of
        ok -> ok;
        {error, Reason} -> throw({quod_ask_error, Reason})
    end.

state_handle(St) ->
    case quod_erlog_db_local_prove:proof_context(St) of
        {ok, {session_ref, #session_ref{} = Handle, _Metadata}} -> Handle;
        _ -> erlang:error(badarg)
    end.

-ifdef(TEST).
test_invocation_state(Handle, InvocationId) ->
    State = get_session(Handle),
    case maps:find(InvocationId, State#session_state.invocations) of
        {ok, {idle, Scope, _Selection}} ->
            {ok, quod_proof_scope:state(Scope)};
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

session_scope_id(
  #{scope_id := <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>> = ScopeId}) ->
    ScopeId;
session_scope_id(_OverlayOpts) ->
    crypto:strong_rand_bytes(?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS div 8).

session_key(#session_ref{id = Id}) -> {?MODULE, Id}.

ensure_owner(#session_ref{owner = Owner}) when Owner =:= self() -> ok;
ensure_owner(_Handle) -> erlang:error(badarg).
