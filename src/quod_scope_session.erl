-module(quod_scope_session).
-moduledoc """
One selected-ontology scope for one top-level proof.

The target ontology engine owns and monitors this worker whether the origin is
co-hosted or remote. The worker keeps one
`quod_proof_session`—one staged overlay and read set—while separate logical
invocations retain their own Erlog continuations. Commands are bound to an
opaque scope id, an unguessable session reference, the 32-byte proof id, and
the origin worker.

`dispatch/1` is also used while an invocation is suspended inside `::`.  This
lets the same scope service a re-entrant invocation without a second worker or
a synchronous call to itself.
""".

-include("quod_proof_limits.hrl").
-include("quod_ledger.hrl").

-export([start/9, invoke_open/5, invoke_next/3, invoke_cancel/2, close/1,
         seal/4, attest_plan/3, certify_reads/2, bind_group_effects/3,
         bind_operation_effect/3, submit_plan/4,
         materialize/4, restore_many/2, release_many/2,
         dispatch/1, remaining_ms/0, principal/0,
         pid/1, scope_id/1, identity/1, failure_reason/2]).

-ifdef(TEST).
-export([test_answer_disposition/1, test_committed_submit_outcome/3,
         test_await_remote_submit/5,
         test_normalize_read_certificate_result/1]).
-endif.

-record(runtime, {
          scope_id  :: <<_:128>>,
          proof_id  :: <<_:256>>,
          origin    :: pid(),
          namespace :: binary(),
          anchor    :: <<_:256>>,
          principal :: quod_dtx:principal(),
          request_binding = none :: quod_client_goal:request_binding(),
          height    :: non_neg_integer(),
          engine    :: pid(),
          ref       :: reference(),
          deadline_ms :: integer(),
          session   :: quod_proof_session:session(),
          invocations = #{} :: map(),
          step_depth = 0 :: non_neg_integer()
         }).

-type local_handle() :: {quod_scope_session, pid(), <<_:128>>, <<_:256>>,
                         reference(), binary(), <<_:256>>}.
-type handle() :: local_handle() | quod_ask_router:remote_handle().
-export_type([handle/0]).

-define(RUNTIME, '$quod_scope_session').
-doc "Spawn a reusable target scope and return the engine-owned monitor immediately.".
-spec start(<<_:128>>, <<_:256>>, pid(), binary(), <<_:256>>,
            non_neg_integer(), tuple(), pid(), map()) ->
          {handle(), reference()}.
start(<<_:128>> = ScopeId, <<_:256>> = ProofId, Origin,
      Ns, <<_:256>> = Anchor, Height,
      Est, Engine,
      Opts = #{deadline_ms := DeadlineMs,
               principal := Principal,
               request_binding := RequestBinding})
  when is_pid(Origin), is_binary(Ns), is_integer(Height), Height >= 0,
       is_pid(Engine), is_integer(DeadlineMs) ->
    true = quod_dtx:valid_principal(Principal),
    true = quod_client_goal:valid_request_binding(RequestBinding),
    Ref = make_ref(),
    MaxHeapWords = bytes_to_heap_words(?QUOD_SCOPE_WORKER_MAX_HEAP_BYTES),
    {Pid, WorkerMRef} =
        spawn_opt(
          fun() -> init(ScopeId, ProofId, Origin, Ns, Anchor, Height,
                        Est, Engine, Ref, Opts) end,
          [monitor,
           {max_heap_size,
            #{size => MaxHeapWords, kill => true, error_logger => true}}]),
    {{quod_scope_session, Pid, ScopeId, ProofId, Ref, Ns, Anchor},
     WorkerMRef}.

-doc "Open one logical invocation through the local or remote scope facade.".
-spec invoke_open(handle(), <<_:128>>, term(),
                  [quod_proof_context:identity()],
                  quod_transaction_scope:selection()) ->
          {ok, reference() | binary()} | {error, term()}.
invoke_open(
  {quod_scope_session, Pid, _ScopeId, ProofId, SessionRef, _Ns, _Anchor},
  InvocationId, Goal, Chain, Selection) ->
    RequestRef = make_ref(),
    Pid ! {scope_invoke_open, self(), ProofId, SessionRef,
           RequestRef, InvocationId, Goal, Chain, Selection},
    {ok, RequestRef};
invoke_open({remote_scope, _, _, _, _} = Handle,
            InvocationId, Goal, Chain, Selection) ->
    case quod_scope_wire:encode_payload(goal, Goal) of
        {ok, GoalBlob} ->
            remote_ack_command(
              Handle,
              {invoke_open, InvocationId, Selection, Chain, GoalBlob});
        {error, _} = Error -> Error
    end;
invoke_open(_Handle, _InvocationId, _Goal, _Chain, _Selection) ->
    {error, {protocol_error, session_binding}}.

-doc "Request the next answer and return its opaque local/remote correlation.".
-spec invoke_next(handle(), <<_:128>>, pos_integer()) ->
          {ok, reference() | binary()} | {error, term()}.
invoke_next(
  {quod_scope_session, Pid, _ScopeId, ProofId, SessionRef, _Ns, _Anchor},
  InvocationId, ExpectedSeq) ->
    RequestRef = make_ref(),
    Pid ! {scope_invoke_next, self(), ProofId, SessionRef,
           RequestRef, InvocationId, ExpectedSeq},
    {ok, RequestRef};
invoke_next({remote_scope, _, _, _, _} = Handle,
            InvocationId, ExpectedSeq) ->
    remote_ack_command(Handle, {invoke_next, InvocationId, ExpectedSeq});
invoke_next(_Handle, _InvocationId, _ExpectedSeq) ->
    {error, {protocol_error, session_binding}}.

-doc "Drop one invocation continuation without rolling back its staged writes.".
-spec invoke_cancel(handle(), <<_:128>>) -> ok | {error, term()}.
invoke_cancel(
  {quod_scope_session, Pid, _ScopeId, ProofId, SessionRef, _Ns, _Anchor},
  InvocationId) ->
    Pid ! {scope_invoke_cancel, self(), ProofId, SessionRef, InvocationId},
    ok;
invoke_cancel({remote_scope, _, _, _, _} = Handle, InvocationId) ->
    remote_no_ack_command(Handle, {invoke_cancel, InvocationId});
invoke_cancel(_Handle, _InvocationId) ->
    {error, {protocol_error, session_binding}}.

-doc """
Seal this scope's local plan (`m:quod_dtx`) before the proof closes it.

One function serves every scope location: the origin's own session seals in
place, a co-hosted worker seals over the session message protocol, and a
remote scope seals over the wire — where the returned plan must decode, carry
the exact bound identities, and verify under the authenticated target key.
""".
-spec seal(handle() | term(), quod_proof_context:identity(),
           quod_dtx:principal(), quod_client_goal:request_binding()) ->
          {ok, quod_dtx:plan()} | not_material | {error, term()}.
seal({local_scope, _ScopeId, Ns, Anchor, Height, Session},
     OriginIdentity, Principal, RequestBinding) ->
    quod_proof_session:seal(
      Session,
      #{target => {Ns, Anchor}, base_height => Height,
        proof_id => quod_proof_context:proof_id(),
        origin => OriginIdentity,
        principal => Principal,
        request_binding => RequestBinding});
seal({quod_scope_session, Pid, _ScopeId, ProofId, SessionRef,
      _Ns, _Anchor} = Handle,
     OriginIdentity, _Principal, _RequestBinding) ->
    case command_remaining_ms() of
        0 ->
            {error, current_execution_limit()};
        RemainingMs ->
            RequestRef = make_ref(),
            Pid ! {scope_seal, self(), ProofId, SessionRef,
                   RequestRef, OriginIdentity},
            MRef = monitor(process, Pid),
            try
                receive
                    {scope_reply, Pid, ProofId, SessionRef, RequestRef,
                     {sealed, Result}} ->
                        Result;
                    {'DOWN', MRef, process, Pid, Reason} ->
                        {error, failure_reason(Handle, Reason)}
                after RemainingMs ->
                    {error, current_execution_limit()}
                end
            after
                demonitor(MRef, [flush])
            end
    end;
seal({remote_scope, _, _, _, _} = Handle, _OriginIdentity, Principal,
     RequestBinding) ->
    remote_seal(Handle, Principal, RequestBinding);
seal(_Handle, _OriginIdentity, _Principal, _RequestBinding) ->
    {error, {protocol_error, session_binding}}.

remote_seal(Handle, Principal, RequestBinding) ->
    case bind_remote_router(Handle) of
        {ok, Router, MRef} ->
            case command_remaining_ms() of
                0 ->
                    {error, current_execution_limit()};
                RemainingMs ->
                    case quod_ask_router:command(
                           Handle, RemainingMs, scope_seal) of
                        {ok, RequestId} ->
                            await_remote_seal(
                              Handle, Principal, RequestBinding,
                              RequestId, Router, MRef, RemainingMs);
                        {sent, _RequestId} ->
                            {error, {protocol_error, request_binding}};
                        {error, _} = Error ->
                            Error
                    end
            end;
        {error, _} = Error ->
            Error
    end.

await_remote_seal(
  Handle, Principal, RequestBinding,
  RequestId, Router, MRef, RemainingMs) ->
    receive
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {plan_sealed, Blob}} ->
            checked_remote_plan(Handle, Principal, RequestBinding, Blob);
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         plan_not_material} ->
            not_material;
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {scope_error, Reason}} ->
            {error, Reason};
        {quod_scope_down, Handle, Reason} ->
            {error, failure_reason(Handle, Reason)};
        {'DOWN', MRef, process, Router, _Reason} ->
            {error, failure_reason(Handle, unavailable)}
    after RemainingMs ->
        remote_timeout(
          Handle, RequestId, {error, current_execution_limit()})
    end.

%% The remote target authored this plan: accept it only if it decodes within
%% bounds, binds exactly the identities this scope was opened under, and its
%% witness signature verifies under the authenticated target key — a plan
%% signed by anyone else (or unsigned) is not this scope's plan.
checked_remote_plan(
  {remote_scope, _Router, _Generation,
   {scope_binding, _OriginKey, TargetKey, ProofId, _ScopeId,
    OriginIdentity, TargetIdentity, _Mode,
    Principal, _AuthenticationDigest}, _RequestLink},
  Principal, RequestBinding, Blob) ->
    case quod_scope_wire:decode_plan_payload(Blob) of
        {ok, Plan} ->
            case quod_dtx:signer(Plan) =:= TargetKey andalso
                 quod_dtx:verify(Plan) andalso
                 quod_dtx:target(Plan) =:= TargetIdentity andalso
                 quod_dtx:origin(Plan) =:= OriginIdentity andalso
                 quod_dtx:proof_id(Plan) =:= ProofId andalso
                 quod_dtx:principal(Plan) =:= Principal andalso
                 quod_dtx:request_binding(Plan) =:= RequestBinding of
                true -> {ok, Plan};
                false -> {error, {protocol_error, bad_payload}}
            end;
        {error, _} = Error ->
            Error
    end.

-doc "Attest one sealed scope plan into the first exact coordination manifest.".
-spec attest_plan(handle() | term(), quod_dtx:plan(), quod_dtx:manifest()) ->
          {ok, quod_dtx:attestation()} | {error, term()}.
attest_plan(
  {local_scope, _ScopeId, _Ns, _Anchor, _Height, Session} = Handle,
  Plan, Manifest) ->
    checked_attestation_result(
      Handle, Plan, Manifest, quod_proof_session:attest(Session, Manifest));
attest_plan(
  {quod_scope_session, Pid, _ScopeId, ProofId, SessionRef,
   _Ns, _Anchor} = Handle,
  Plan, Manifest) ->
    case command_remaining_ms() of
        0 ->
            {error, current_execution_limit()};
        RemainingMs ->
            RequestRef = make_ref(),
            Pid ! {scope_attest, self(), ProofId, SessionRef,
                   RequestRef, Manifest},
            MRef = monitor(process, Pid),
            try
                receive
                    {scope_reply, Pid, ProofId, SessionRef, RequestRef,
                     {attested, Result}} ->
                        checked_attestation_result(
                          Handle, Plan, Manifest, Result);
                    {'DOWN', MRef, process, Pid, Reason} ->
                        {error, failure_reason(Handle, Reason)}
                after RemainingMs ->
                    {error, current_execution_limit()}
                end
            after
                demonitor(MRef, [flush])
            end
    end;
attest_plan({remote_scope, _, _, _, _} = Handle, Plan, Manifest) ->
    remote_attest(Handle, Plan, Manifest);
attest_plan(_Handle, _Plan, _Manifest) ->
    {error, {protocol_error, session_binding}}.

remote_attest(Handle, Plan, Manifest) ->
    case {bind_remote_router(Handle),
          quod_scope_wire:encode_payload(manifest, Manifest)} of
        {{ok, Router, MRef}, {ok, ManifestBlob}} ->
            case command_remaining_ms() of
                0 ->
                    {error, current_execution_limit()};
                RemainingMs ->
                    case quod_ask_router:command(
                           Handle, RemainingMs,
                           {scope_attest, ManifestBlob}) of
                        {ok, RequestId} ->
                            await_remote_attestation(
                              Handle, Plan, Manifest, RequestId,
                              Router, MRef, RemainingMs);
                        {sent, _RequestId} ->
                            {error, {protocol_error, request_binding}};
                        {error, _} = Error -> Error
                    end
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

await_remote_attestation(
  Handle, Plan, Manifest, RequestId, Router, MRef, RemainingMs) ->
    receive
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {plan_attested, Blob}} ->
            case quod_scope_wire:decode_payload(attestation, Blob) of
                {ok, Attestation} ->
                    checked_attestation_result(
                      Handle, Plan, Manifest, {ok, Attestation});
                {error, _} = Error -> Error
            end;
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {scope_error, Reason}} ->
            {error, Reason};
        {quod_scope_down, Handle, Reason} ->
            {error, failure_reason(Handle, Reason)};
        {'DOWN', MRef, process, Router, _Reason} ->
            {error, failure_reason(Handle, unavailable)}
    after RemainingMs ->
        remote_timeout(
          Handle, RequestId, {error, current_execution_limit()})
    end.

checked_attestation_result(Handle, Plan, Manifest, {ok, Attestation}) ->
    Target = identity(Handle),
    case quod_dtx:verify_plan_attestation(
           Target, Plan, Manifest, Attestation) of
        true -> {ok, Attestation};
        false -> {error, {protocol_error, bad_payload}}
    end;
checked_attestation_result(_Handle, _Plan, _Manifest, {error, _} = Error) ->
    Error.

-doc "Persist every prepared direct effect under one dormant DTX group.".
-spec bind_group_effects([{handle(), <<_:256>>}], term(), non_neg_integer()) ->
          ok | {error, term()}.
bind_group_effects(Rows, GroupRef, TimeoutMs)
  when is_list(Rows), is_integer(TimeoutMs), TimeoutMs >= 0 ->
    Deadline = quod_time:mono_ms() + TimeoutMs,
    %% Start every remote/co-hosted command from this proof process before
    %% waiting for any reply.  Scope ownership remains exact while all targets
    %% prepare concurrently under one deadline.
    {LocalRows, AsyncRows} =
        lists:partition(fun is_local_group_effect_row/1, Rows),
    case start_group_effect_binds(AsyncRows, GroupRef, Deadline, []) of
        {ok, Pending} ->
            case bind_local_group_effects(LocalRows, GroupRef) of
                ok -> await_group_effect_binds(Pending, Deadline);
                {error, _} = Error ->
                    cleanup_group_effect_binds(Pending),
                    Error
            end;
        {error, Error, Pending} ->
            cleanup_group_effect_binds(Pending),
            Error
    end;
bind_group_effects(_Rows, _GroupRef, _TimeoutMs) ->
    {error, {protocol_error, session_binding}}.

-doc "Persist one sealed prepared effect under an exact dormant source claim.".
-spec bind_operation_effect(handle(), term(), non_neg_integer()) ->
          {ok, binary()} | {error, term()}.
bind_operation_effect(Handle, Submission, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs >= 0 ->
    case quod_transaction:encode_operation_submission(Submission) of
        {ok, SubmissionBlob} ->
            bind_operation_effect_handle(
              Handle, SubmissionBlob, TimeoutMs);
        {error, _} ->
            {error, {protocol_error, bad_payload}}
    end;
bind_operation_effect(_Handle, _Submission, _TimeoutMs) ->
    {error, {protocol_error, session_binding}}.

bind_operation_effect_handle(
  {local_scope, _ScopeId, Ns, Anchor, _Height, Session},
  SubmissionBlob, _TimeoutMs) ->
    bind_session_operation_effect(
      Session, {Ns, Anchor}, SubmissionBlob);
bind_operation_effect_handle(
  {quod_scope_session, Pid, _ScopeId, ProofId, SessionRef,
   _Ns, _Anchor} = Handle,
  SubmissionBlob, TimeoutMs) ->
    RequestRef = make_ref(),
    Pid ! {scope_bind_operation_effect, self(), ProofId, SessionRef,
           RequestRef, SubmissionBlob},
    MRef = monitor(process, Pid),
    try
        receive
            {scope_reply, Pid, ProofId, SessionRef, RequestRef,
             {operation_effect_bound, Result}} -> Result;
            {'DOWN', MRef, process, Pid, Reason} ->
                {error, failure_reason(Handle, Reason)}
        after TimeoutMs ->
            {Ns, _} = identity(Handle),
            {error, {proof_limit_exceeded, Ns}}
        end
    after
        demonitor(MRef, [flush])
    end;
bind_operation_effect_handle(
  {remote_scope, _, _, _, _} = Handle, SubmissionBlob, TimeoutMs) ->
    case bind_remote_router(Handle) of
        {ok, Router, MRef} ->
            case quod_ask_router:command(
                   Handle, TimeoutMs,
                   {bind_operation_effect, SubmissionBlob}) of
                {ok, RequestId} ->
                    await_remote_operation_effect(
                      Handle, RequestId, Router, MRef, TimeoutMs);
                {sent, _RequestId} ->
                    demonitor(MRef, [flush]),
                    {error, {protocol_error, request_binding}};
                {error, _} = Error ->
                    demonitor(MRef, [flush]),
                    Error
            end;
        {error, _} = Error -> Error
    end;
bind_operation_effect_handle(_Handle, _SubmissionBlob, _TimeoutMs) ->
    {error, {protocol_error, session_binding}}.

await_remote_operation_effect(Handle, RequestId, Router, MRef, TimeoutMs) ->
    try
        receive
            {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
             {operation_effect_bound, EffectId}} ->
                {ok, EffectId};
            {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
             {scope_error, Reason}} ->
                {error, Reason};
            {quod_scope_down, Handle, Reason} ->
                {error, failure_reason(Handle, Reason)};
            {'DOWN', MRef, process, Router, _Reason} ->
                {error, failure_reason(Handle, unavailable)}
        after TimeoutMs ->
            {Ns, _Anchor} = identity(Handle),
            remote_timeout(
              Handle, RequestId,
              {error, {proof_limit_exceeded, Ns}})
        end
    after
        demonitor(MRef, [flush])
    end.

-doc """
Certify the exact read-only plan already sealed by this scope.

Failures use the one closed public scope-error catalog owned by
`quod_scope_wire`, including payload-size and execution-limit errors.
""".
-spec certify_reads(handle() | term(), quod_dtx:plan()) ->
          {ok, quod_read_certificate:certificate()} | {error, term()}.
certify_reads(
  {local_scope, _ScopeId, Ns, Anchor, _Height, Session}, Plan) ->
    checked_read_certificate_result(
      Plan, certify_session_reads(Ns, {Ns, Anchor}, Session, Plan));
certify_reads(
  {quod_scope_session, Pid, _ScopeId, ProofId, SessionRef,
   _Ns, _Anchor} = Handle, Plan) ->
    case command_remaining_ms() of
        0 ->
            {error, current_execution_limit()};
        RemainingMs ->
            RequestRef = make_ref(),
            Pid ! {scope_certify_reads, self(), ProofId, SessionRef,
                   RequestRef},
            MRef = monitor(process, Pid),
            try
                receive
                    {scope_reply, Pid, ProofId, SessionRef, RequestRef,
                     {reads_certified, Result}} ->
                        checked_read_certificate_result(Plan, Result);
                    {'DOWN', MRef, process, Pid, Reason} ->
                        {error, failure_reason(Handle, Reason)}
                after RemainingMs ->
                    {error, current_execution_limit()}
                end
            after
                demonitor(MRef, [flush])
            end
    end;
certify_reads({remote_scope, _, _, _, _} = Handle, Plan) ->
    remote_certify_reads(Handle, Plan);
certify_reads(_Handle, _Plan) ->
    {error, {protocol_error, session_binding}}.

remote_certify_reads(Handle, Plan) ->
    case bind_remote_router(Handle) of
        {ok, Router, MRef} ->
            case command_remaining_ms() of
                0 ->
                    {error, current_execution_limit()};
                RemainingMs ->
                    case quod_ask_router:command(
                           Handle, RemainingMs, certify_reads) of
                        {ok, RequestId} ->
                            await_remote_read_certificate(
                              Handle, Plan, RequestId, Router, MRef,
                              RemainingMs);
                        {sent, _RequestId} ->
                            {error, {protocol_error, request_binding}};
                        {error, _} = Error ->
                            Error
                    end
            end;
        {error, _} = Error ->
            Error
    end.

await_remote_read_certificate(
  Handle, Plan, RequestId, Router, MRef, RemainingMs) ->
    receive
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {reads_certified, Blob}} ->
            case quod_scope_wire:decode_payload(read_certificate, Blob) of
                {ok, Certificate} ->
                    checked_read_certificate_result(
                      Plan, {ok, Certificate});
                {error, _} = Error -> Error
            end;
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {scope_error, Reason}} ->
            {error, Reason};
        {quod_scope_down, Handle, Reason} ->
            {error, failure_reason(Handle, Reason)};
        {'DOWN', MRef, process, Router, _Reason} ->
            {error, failure_reason(Handle, unavailable)}
    after RemainingMs ->
        remote_timeout(
          Handle, RequestId, {error, current_execution_limit()})
    end.

checked_read_certificate_result(Plan, {ok, Certificate}) ->
    case quod_read_certificate:binding(Certificate) of
        {ok, #{target := Target, proof_id := ProofId,
               plan_digest := PlanDigest}} ->
            case Target =:= quod_dtx:target(Plan) andalso
                 ProofId =:= quod_dtx:proof_id(Plan) andalso
                 PlanDigest =:= quod_dtx:digest(Plan) of
                true -> {ok, Certificate};
                false -> {error, {protocol_error, request_binding}}
            end;
        error ->
            {error, {protocol_error, bad_payload}}
    end;
checked_read_certificate_result(_Plan, {error, _} = Error) ->
    Error;
checked_read_certificate_result(_Plan, _Malformed) ->
    {error, {protocol_error, bad_payload}}.

certify_session_reads(Ns, Target, Session, ExpectedPlan) ->
    Result =
        case quod_proof_session:sealed_plan(Session) of
            {ok, Plan}
              when ExpectedPlan =:= own_sealed_plan;
                   Plan =:= ExpectedPlan ->
                certify_local_read_plan(Ns, Target, Plan);
            {ok, _OtherPlan} ->
                {error, {protocol_error, request_binding}};
            {error, _Reason} ->
                {error, {protocol_error, proof_engine}}
        end,
    normalize_read_certificate_result(Result).

certify_local_read_plan(Ns, Target, Plan) ->
    RemainingMs = min(command_remaining_ms(),
                      ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS),
    case RemainingMs of
        0 ->
            {error, current_execution_limit()};
        _ ->
            certify_local_read_plan(
              Ns, Target, Plan, RemainingMs)
    end.

certify_local_read_plan(Ns, Target, Plan, RemainingMs) ->
    case quod_dtx:encode(Plan) of
        {ok, PlanBlob} ->
            case quod_simplex:history_source(Target, validator) of
                {ok, LedgerRoot} ->
                    quod_dtx_current_view:certify_reads(
                      Ns, {{local, LedgerRoot}, PlanBlob}, RemainingMs);
                {error, _} ->
                    {error, read_certificate_unavailable}
            end;
        {error, _} ->
            {error, {protocol_error, proof_engine}}
    end.

normalize_read_certificate_result({ok, _} = Result) -> Result;
normalize_read_certificate_result({error, retry}) ->
    {error, read_certificate_unavailable};
normalize_read_certificate_result({error, invalid_request}) ->
    {error, {protocol_error, proof_engine}};
normalize_read_certificate_result({error, Reason} = Error) ->
    case quod_scope_wire:valid_public_error(Reason) of
        true -> Error;
        false -> {error, {protocol_error, proof_engine}}
    end.

is_local_group_effect_row(
  {{local_scope, _ScopeId, _Ns, _Anchor, _Height, _Session},
   <<_:256>>}) -> true;
is_local_group_effect_row(_Row) -> false.

bind_local_group_effects([], _GroupRef) ->
    ok;
bind_local_group_effects(
  [{{local_scope, _ScopeId, Ns, Anchor, _Height, Session}, PlanDigest} | Rest],
  GroupRef) ->
    case bind_session_group_effect(
           Session, {Ns, Anchor}, GroupRef, PlanDigest) of
        ok -> bind_local_group_effects(Rest, GroupRef);
        {error, _} = Error -> Error
    end.

start_group_effect_binds([], _GroupRef, _Deadline, RevPending) ->
    {ok, lists:reverse(RevPending)};
start_group_effect_binds(
  [{Handle, PlanDigest} | Rest], GroupRef, Deadline, RevPending) ->
    RemainingMs = max(0, Deadline - quod_time:mono_ms()),
    case start_group_effect_bind(Handle, GroupRef, PlanDigest, RemainingMs) of
        {ok, Pending} ->
            start_group_effect_binds(
              Rest, GroupRef, Deadline, [Pending | RevPending]);
        {error, _} = Error ->
            {error, Error, lists:reverse(RevPending)}
    end.

start_group_effect_bind(
  {quod_scope_session, Pid, _ScopeId, ProofId, SessionRef,
   _Ns, _Anchor} = Handle,
  GroupRef, PlanDigest, _RemainingMs) ->
    RequestRef = make_ref(),
    Pid ! {scope_bind_group_effects, self(), ProofId, SessionRef,
           RequestRef, GroupRef, PlanDigest},
    MRef = monitor(process, Pid),
    {ok, {cohosted, Handle, Pid, ProofId, SessionRef, RequestRef, MRef}};
start_group_effect_bind(
  {remote_scope, _, _, _, _} = Handle,
  GroupRef, PlanDigest, RemainingMs) ->
    case bind_remote_router(Handle) of
        {ok, Router, MRef} ->
            case quod_ask_router:command(
                   Handle, RemainingMs,
                   {bind_group_effects, GroupRef, PlanDigest}) of
                {ok, RequestId} ->
                    {ok, {remote, Handle, RequestId, Router, MRef}};
                {sent, _RequestId} ->
                    {error, {protocol_error, request_binding}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
start_group_effect_bind(_Handle, _GroupRef, _PlanDigest, _RemainingMs) ->
    {error, {protocol_error, session_binding}}.

await_group_effect_binds([], _Deadline) ->
    ok;
await_group_effect_binds([Pending | Rest], Deadline) ->
    RemainingMs = max(0, Deadline - quod_time:mono_ms()),
    case await_group_effect_bind(Pending, RemainingMs) of
        ok -> await_group_effect_binds(Rest, Deadline);
        {error, _} = Error ->
            cleanup_group_effect_binds(Rest),
            Error
    end.

await_group_effect_bind(
  {cohosted, Handle, Pid, ProofId, SessionRef, RequestRef, MRef}, TimeoutMs) ->
    try
        receive
            {scope_reply, Pid, ProofId, SessionRef, RequestRef,
             {group_effects_bound, Result}} ->
                Result;
            {'DOWN', MRef, process, Pid, Reason} ->
                {error, failure_reason(Handle, Reason)}
        after TimeoutMs ->
            {Ns, _Anchor} = identity(Handle),
            {error, {proof_limit_exceeded, Ns}}
        end
    after
        demonitor(MRef, [flush])
    end;
await_group_effect_bind(
  {remote, Handle, RequestId, Router, MRef}, TimeoutMs) ->
    receive
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         group_effects_bound} ->
            ok;
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {scope_error, Reason}} ->
            {error, Reason};
        {quod_scope_down, Handle, Reason} ->
            {error, failure_reason(Handle, Reason)};
        {'DOWN', MRef, process, Router, _Reason} ->
            {error, failure_reason(Handle, unavailable)}
    after TimeoutMs ->
        {Ns, _Anchor} = identity(Handle),
        remote_timeout(
          Handle, RequestId,
          {error, {proof_limit_exceeded, Ns}})
    end.

cleanup_group_effect_binds(Pending) ->
    lists:foreach(fun cleanup_group_effect_bind/1, Pending).

cleanup_group_effect_bind(
  {cohosted, _Handle, Pid, ProofId, SessionRef, RequestRef, MRef}) ->
    demonitor(MRef, [flush]),
    receive
        {scope_reply, Pid, ProofId, SessionRef, RequestRef, _Reply} -> ok
    after 0 -> ok
    end;
cleanup_group_effect_bind(
  {remote, Handle, RequestId, _Router, _MRef}) ->
    _ = quod_ask_router:cancel(Handle, RequestId),
    drain_remote_event(Handle, RequestId).

bind_session_group_effect(Session, Target, GroupRef, PlanDigest) ->
    case quod_proof_session:sealed_plan(Session) of
        {ok, Plan} ->
            bind_sealed_group_effect(
              Session, Target, Plan, GroupRef, PlanDigest);
        {error, _} = Error -> Error
    end.

bind_sealed_group_effect(Session, Target, Plan, GroupRef, PlanDigest) ->
    case {quod_dtx:digest(Plan) =:= PlanDigest,
          quod_dtx:target(Plan) =:= Target,
          quod_dtx:material(Plan),
          quod_proof_session:effect_reservation(Session)} of
        {true, true, {ok, #{effects := [Effect]} = Material},
         {ok, #{token := Reservation, effect := Effect,
                plan_digest := PlanDigest}}} ->
            case quod_effect:validate_plan(Plan, Material) of
                true ->
                    quod_effect_journal:bind_group(
                      Plan, GroupRef, Target, PlanDigest, Reservation);
                false ->
                    {error, invalid_group_effect}
            end;
        {true, true, {ok, #{effects := [_]}},
         {error, missing_effect_preparation}} ->
            {error, missing_effect_preparation};
        _ ->
            {error, invalid_group_effect}
    end.

bind_session_operation_effect(
  Session, Target, SubmissionBlob) ->
    case quod_proof_session:effect_reservation(Session) of
        {ok, #{token := Reservation, target := Target}} ->
            %% The journal is the one semantic decoder and durable owner for
            %% the exact signed submission. This scope contributes only its
            %% unforgeable reservation capability and authenticated target.
            quod_effect_journal:bind_operation(
              Reservation, SubmissionBlob);
        {ok, _OtherReservation} ->
            {error, invalid_operation_effect};
        {error, _} = Error -> Error
    end.

-doc """
Submit a sealed plan to a REMOTE target validator through its open scope.

Local and co-hosted targets submit engine-direct (`quod_prolog:submit_plan/4`)
— only a genuinely remote target needs the wire, and only the bounded outcome
comes back: the transaction is authored, signed, and parked entirely on the
target node.
""".
-spec submit_plan(handle() | term(), quod_dtx:plan(), term(), map()) ->
          {ok, pos_integer(), binary()} | {error, term()}.
submit_plan({remote_scope, _, _, _, _} = Handle, Plan, Goal, DurableResult) ->
    case bind_remote_router(Handle) of
        {ok, Router, MRef} ->
            case command_remaining_ms() of
                0 ->
                    {error, current_execution_limit()};
                RemainingMs ->
                    remote_submit(
                      Handle, Plan, Goal, DurableResult,
                      quod_proof_context:request_auth(), RemainingMs,
                      Router, MRef)
            end;
        {error, _} = Error ->
            Error
    end;
submit_plan(_Handle, _Plan, _Goal, _DurableResult) ->
    {error, {protocol_error, session_binding}}.

remote_submit(
  Handle, Plan, Goal, DurableResult, RequestAuth,
  RemainingMs, Router, MRef) ->
    case encode_submit_operation(Plan, Goal, DurableResult, RequestAuth) of
        {ok, Operation, OutcomeRef} ->
            case quod_ask_router:command(Handle, RemainingMs, Operation) of
                {ok, RequestId} ->
                    await_remote_submit(
                      Handle, RequestId, Router, MRef, OutcomeRef,
                      RemainingMs);
                {sent, _RequestId} ->
                    {error, {protocol_error, request_binding}};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

encode_submit_operation(Plan, Goal, Bindings, RequestAuth) ->
    case quod_scope_wire:encode_payload(plan, Plan) of
        {ok, PlanBlob} ->
            case quod_transaction:encode_durable_submission(Goal, Bindings) of
                {ok, GoalBlob, ResultBlob} ->
                    OutcomeRef = quod_transaction:plan_outcome_ref(
                                   Plan, GoalBlob, ResultBlob, RequestAuth),
                    {ok, {submit_plan, PlanBlob, GoalBlob,
                          ResultBlob,
                          quod_trace:inject(quod_trace:context())},
                     OutcomeRef};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

await_remote_submit(
  Handle, RequestId, Router, MRef,
  OutcomeRef = {transaction, _Ns, _Anchor, _ExpectedTxId}, RemainingMs) ->
    receive
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {plan_submitted, {committed, Slot, TxId}}} ->
            committed_submit_outcome(Slot, TxId, OutcomeRef);
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {plan_submitted, {outcome_unknown, ReturnedRef}}}
          when ReturnedRef =:= OutcomeRef ->
            {error, {outcome_unknown, OutcomeRef}};
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {plan_submitted, {rejected, Reason}}} ->
            {error, Reason};
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {scope_error, Reason}} ->
            {error, Reason};
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {plan_submitted, _UnexpectedOutcome}} ->
            {error, {outcome_unknown, OutcomeRef}};
        {quod_scope_down, Handle, Reason} ->
            _ = Reason,
            {error, {outcome_unknown, OutcomeRef}};
        {'DOWN', MRef, process, Router, _Reason} ->
            {error, {outcome_unknown, OutcomeRef}}
    after RemainingMs ->
        remote_timeout(
          Handle, RequestId, {error, {outcome_unknown, OutcomeRef}})
    end.

committed_submit_outcome(
  Slot, ExpectedTxId,
  {transaction, _Ns, _Anchor, ExpectedTxId}) ->
    {ok, Slot, ExpectedTxId};
committed_submit_outcome(_Slot, _OtherTxId, OutcomeRef) ->
    {error, {outcome_unknown, OutcomeRef}}.

-ifdef(TEST).
test_committed_submit_outcome(Slot, TxId, OutcomeRef) ->
    committed_submit_outcome(Slot, TxId, OutcomeRef).

test_await_remote_submit(Handle, RequestId, Router, OutcomeRef, RemainingMs) ->
    MRef = monitor(process, Router),
    try await_remote_submit(
          Handle, RequestId, Router, MRef, OutcomeRef, RemainingMs)
    after
        demonitor(MRef, [flush])
    end.

test_normalize_read_certificate_result(Result) ->
    normalize_read_certificate_result(Result).
-endif.

-doc "Close the complete ontology scope. Idempotent at the origin.".
-spec close(handle() | term()) -> ok.
close({quod_scope_session, Pid, _ScopeId, ProofId, SessionRef, _Ns, _Anchor}) ->
    Pid ! {scope_close, self(), ProofId, SessionRef},
    ok;
close({remote_scope, _, _, _, _} = Handle) ->
    quod_ask_router:close(Handle, 0);
close(_) ->
    ok.

-doc "Materialize the actor's exact transaction selection on this scope.".
-spec materialize(handle() | term(), quod_transaction_scope:actor(),
                  quod_transaction_scope:lineage(), [binary()]) ->
          {ok, boolean(), non_neg_integer()} | {error, term()}.
materialize(Handle, {ActorScopeId, ActorInvocationId}, Lineage, BatchIds) ->
    case validate_materialize_request(
           Handle, ActorScopeId, ActorInvocationId, Lineage, BatchIds) of
        ok ->
            materialize_validated(
              Handle, ActorScopeId, ActorInvocationId, Lineage, BatchIds);
        {error, _} = Error ->
            Error
    end;
materialize(_Handle, _Actor, _Lineage, _BatchIds) ->
    {error, {protocol_error, request_binding}}.

-doc "Restore a retained scope revision and report its exact current dirty state.".
-spec restore_many(handle() | term(), [term()]) ->
          {ok, boolean(), non_neg_integer()} | {error, term()}.
restore_many({local_scope, _ScopeId, _Ns, _Anchor, _Height, Session},
             BatchIds) ->
    validated_local_control(restore, Session, BatchIds);
restore_many({quod_scope_session, _, _, _, _, _, _} = Handle, BatchIds) ->
    validated_scope_control(restore, Handle, BatchIds);
restore_many({remote_scope, _, _, _, _} = Handle, BatchIds) ->
    validated_remote_control(
      Handle, {batch_restore, BatchIds},
      {batch_restored, BatchIds}, BatchIds);
restore_many(_Handle, _BatchIds) ->
    {error, {protocol_error, session_binding}}.

-doc "Release one retained scope revision. Repeated release is harmless.".
-spec release_many(handle() | term(), [term()]) ->
          {ok, boolean(), non_neg_integer()} | {error, term()}.
release_many({local_scope, _ScopeId, _Ns, _Anchor, _Height, Session},
             BatchIds) ->
    validated_local_control(release, Session, BatchIds);
release_many({quod_scope_session, _, _, _, _, _, _} = Handle, BatchIds) ->
    validated_scope_control(release, Handle, BatchIds);
release_many({remote_scope, _, _, _, _} = Handle, BatchIds) ->
    validated_remote_control(
      Handle, {batch_release, BatchIds},
      {batch_released, BatchIds}, BatchIds);
release_many(_Handle, _BatchIds) ->
    {error, {protocol_error, session_binding}}.

-spec pid(handle()) -> pid().
pid({quod_scope_session, Pid, _ScopeId, _ProofId, _Ref, _Ns, _Anchor}) -> Pid;
pid({remote_scope, RouterPid, _RouterGeneration, _Binding, _RequestLink}) ->
    RouterPid.

-spec scope_id(handle()) -> <<_:128>>.
scope_id({quod_scope_session, _Pid, ScopeId, _ProofId, _Ref,
          _Ns, _Anchor}) ->
    ScopeId;
scope_id({remote_scope, _RouterPid, _RouterGeneration,
          {scope_binding, _OriginKey, _TargetKey, _ProofId, ScopeId,
           _OriginIdentity, _TargetIdentity, _Mode,
           _Principal, _AuthenticationDigest}, _RequestLink}) ->
    ScopeId.

-spec identity(handle()) -> quod_proof_context:identity().
identity({local_scope, _ScopeId, Ns, Anchor, _Height, _Session}) ->
    {Ns, Anchor};
identity({quod_scope_session, _Pid, _ScopeId, _ProofId, _Ref, Ns, Anchor}) ->
    {Ns, Anchor};
identity({remote_scope, _RouterPid, _RouterGeneration,
          {scope_binding, _OriginKey, _TargetKey, _ProofId, _ScopeId,
           _OriginIdentity, TargetIdentity, _Mode,
           _Principal, _AuthenticationDigest}, _RequestLink}) ->
    TargetIdentity.

-doc "Service one scope command re-entrantly while this worker waits in `::`.".
-spec dispatch(term()) -> handled | stop | unhandled.
dispatch(Message) ->
    case get(?RUNTIME) of
        #runtime{} -> dispatch_message(Message);
        undefined -> unhandled
    end.

-doc "Remaining lifetime of the scope currently executing in this process.".
-spec remaining_ms() -> {ok, non_neg_integer()} | error.
remaining_ms() ->
    case get(?RUNTIME) of
        #runtime{deadline_ms = DeadlineMs} ->
            {ok, erlang:max(0, DeadlineMs - quod_time:mono_ms())};
        undefined ->
            error
    end.

-doc "Return the authenticated principal of the scope running in this process.".
-spec principal() -> {ok, quod_dtx:principal()} | error.
principal() ->
    case get(?RUNTIME) of
        #runtime{principal = Principal} -> {ok, Principal};
        undefined -> error
    end.

init(ScopeId, ProofId, Origin, Ns, Anchor, Height,
     Est, Engine, Ref, Opts) ->
    _ = quod_process:kill_when_owner_dies(Engine, self()),
    Metadata = {scope, ProofId, Origin, Ref, ScopeId},
    case start_session(Est, Opts#{scope_id => ScopeId,
                                  read_set => true,
                                  proof_context => Metadata}) of
        {ok, Session} ->
            Runtime = #runtime{scope_id = ScopeId,
                               proof_id = ProofId, origin = Origin,
                               namespace = Ns, anchor = Anchor,
                               principal = maps:get(principal, Opts),
                               request_binding = maps:get(
                                                   request_binding, Opts),
                               height = Height, engine = Engine,
                               ref = Ref,
                               deadline_ms = maps:get(deadline_ms, Opts),
                               session = Session},
            put(?RUNTIME, Runtime),
            run_loop(Ns, Session);
        {error, {Class, Reason, Stack}} ->
            logger:warning(
              "quod_scope_session[~s]: start failed: ~p:~p ~p",
              [Ns, Class, Reason, Stack]),
            exit({scope_error, {protocol_error, proof_engine}})
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
            exit({scope_error, {protocol_error, proof_engine}})
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
                  RequestRef, InvocationId, Goal, Chain, Selection}) ->
    case valid_command(Origin, ProofId, Ref) of
        true -> handle_open(
                  RequestRef, InvocationId, Goal, Chain, Selection);
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
dispatch_message({scope_savepoint, Origin, ProofId, Ref,
                  RequestRef, Operation, BatchIds}) ->
    case valid_command(Origin, ProofId, Ref) of
        true ->
            Reply = session_control(
                      Operation, (runtime())#runtime.session, BatchIds),
            send_reply(RequestRef, {savepoint, Operation, BatchIds, Reply}),
            handled;
        false ->
            handled
    end;
dispatch_message({scope_seal, Origin, ProofId, Ref,
                  RequestRef, OriginIdentity}) ->
    case valid_command(Origin, ProofId, Ref) of
        true ->
            send_reply(RequestRef, {sealed, seal_current(OriginIdentity)}),
            handled;
        false ->
            handled
    end;
dispatch_message({scope_attest, Origin, ProofId, Ref,
                  RequestRef, Manifest}) ->
    case valid_command(Origin, ProofId, Ref) of
        true ->
            Session = (runtime())#runtime.session,
            send_reply(
              RequestRef,
              {attested, quod_proof_session:attest(Session, Manifest)}),
            handled;
        false ->
            handled
    end;
dispatch_message({scope_certify_reads, Origin, ProofId, Ref, RequestRef}) ->
    case valid_command(Origin, ProofId, Ref) of
        true ->
            #runtime{namespace = Ns, anchor = Anchor,
                     session = Session} = runtime(),
            send_reply(
              RequestRef,
              {reads_certified,
               certify_session_reads(
                 Ns, {Ns, Anchor}, Session, own_sealed_plan)}),
            handled;
        false ->
            handled
    end;
dispatch_message({scope_bind_group_effects, Origin, ProofId, Ref,
                  RequestRef, GroupRef, PlanDigest}) ->
    case valid_command(Origin, ProofId, Ref) of
        true ->
            #runtime{namespace = Ns, anchor = Anchor,
                     session = Session} = runtime(),
            Result = bind_session_group_effect(
                       Session, {Ns, Anchor}, GroupRef, PlanDigest),
            send_reply(RequestRef, {group_effects_bound, Result}),
            handled;
        false ->
            handled
    end;
dispatch_message({scope_bind_operation_effect, Origin, ProofId, Ref,
                  RequestRef, SubmissionBlob}) ->
    case valid_command(Origin, ProofId, Ref) of
        true ->
            #runtime{namespace = Ns, anchor = Anchor,
                     session = Session} = runtime(),
            Result = bind_session_operation_effect(
                       Session, {Ns, Anchor}, SubmissionBlob),
            send_reply(RequestRef, {operation_effect_bound, Result}),
            handled;
        false ->
            handled
    end;
dispatch_message({scope_close, Origin, ProofId, Ref}) ->
    case valid_command(Origin, ProofId, Ref) of
        true -> stop;
        false -> handled
    end;
dispatch_message(_) ->
    unhandled.

handle_open(RequestRef, InvocationId, Goal, Chain, Selection) ->
    Runtime0 = runtime(),
    Reply =
        case valid_invocation_input(InvocationId, Goal, Chain, Selection) of
            false -> {error, {protocol_error, request_binding}};
            true ->
                case maps:is_key(InvocationId, Runtime0#runtime.invocations) of
                    true -> {error, already_open};
                    false -> authorize_and_open(
                               InvocationId, Goal, Chain, Selection, Runtime0)
                end
        end,
    send_reply(RequestRef, Reply),
    handled.

authorize_and_open(InvocationId, Goal, Chain, Selection,
                   #runtime{session = Session} = Runtime) ->
    Result =
        case quod_proof_session:check_mutable(Session) of
            ok ->
                with_session_access(
                  Session,
                  fun() ->
                      authorize_and_open_checked(
                        InvocationId, Goal, Chain, Selection, Runtime)
                  end);
            {error, _} = MutableError ->
                MutableError
        end,
    case Result of
        {error, _} = OpenError ->
            %% The guard may close after the invocation was installed but
            %% before its opened reply. Keep no continuation for work the
            %% caller was correctly told it cannot access.
            _ = quod_proof_session:cancel(Session, InvocationId),
            remove_invocation_metadata(InvocationId),
            OpenError;
        _ ->
            Result
    end.

authorize_and_open_checked(InvocationId, Goal, Chain, Selection,
                           #runtime{namespace = Ns, anchor = Anchor,
                                    principal = Principal,
                                    height = Height,
                                    session = Session} = Runtime) ->
    case quod_ask:open_authorized_scope(
           Principal, Goal, Chain, {Ns, Anchor}, Height, Session,
           InvocationId, Selection) of
        ok ->
            Invocations = (runtime())#runtime.invocations,
            put_runtime(Runtime#runtime{
              invocations = Invocations#{InvocationId => {1, 0}}}),
            {opened, InvocationId};
        {error, Reason} -> {error, Reason}
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
            send_next_error(
              RequestRef, {protocol_error, answer_sequence}),
            handled;
        error ->
            send_next_error(
              RequestRef, {protocol_error, request_binding}),
            handled
    end;
handle_next(RequestRef, _InvocationId, _ExpectedSeq) ->
    send_next_error(RequestRef, {protocol_error, bad_sequence}),
    handled.

finish_next(RequestRef, InvocationId, Seq, Count, {solution, Solution}) ->
    Runtime0 = runtime(),
    Session = Runtime0#runtime.session,
    Prepared = with_session_access(
                 Session,
                 fun() ->
                     Dirty = quod_proof_session:dirty(Session),
                     case {Count < ?QUOD_MAX_ANSWERS_PER_INVOCATION,
                           answer_disposition(Solution)} of
                         {true, ok} -> {solution_ready, Dirty};
                         {false, _} -> {result_error, too_many_answers};
                         {_, {error, Reason}} -> {result_error, Reason}
                     end
                 end),
    case Prepared of
        {error, Reason} ->
            remove_invocation(InvocationId),
            send_guard_error(RequestRef, Reason);
        {solution_ready, Dirty} ->
            Invocations = Runtime0#runtime.invocations,
            put_runtime(Runtime0#runtime{
              invocations = Invocations#{
                InvocationId => {Seq + 1, Count + 1}}}),
            send_reply(RequestRef, {solution, Seq, Solution, Dirty});
        {result_error, Reason} ->
            remove_invocation(InvocationId),
            send_next_error(RequestRef, Reason)
    end,
    handled;
finish_next(RequestRef, InvocationId, Seq, _Count, {complete, Reasons}) ->
    case checked_session_dirty((runtime())#runtime.session) of
        {ok, Dirty} ->
            remove_invocation_metadata(InvocationId),
            send_reply(RequestRef, {complete, Seq, Reasons, Dirty});
        {error, Reason} ->
            remove_invocation_metadata(InvocationId),
            send_guard_error(RequestRef, Reason)
    end,
    handled;
finish_next(RequestRef, InvocationId, _Seq, _Count, {error, Reason}) ->
    remove_invocation_metadata(InvocationId),
    send_next_error(RequestRef, Reason),
    handled.

send_next_error(RequestRef, Reason) ->
    case checked_session_dirty((runtime())#runtime.session) of
        {ok, Dirty} -> send_reply(RequestRef, {error, Reason, Dirty});
        {error, AccessReason} -> send_guard_error(RequestRef, AccessReason)
    end.

send_guard_error(RequestRef, Reason) ->
    %% Dirty is not observable state after a fatal access error; false keeps
    %% the fixed reply shape without asking the fenced overlay a second time.
    send_reply(RequestRef, {error, Reason, false}).

handle_cancel(InvocationId) ->
    remove_invocation(InvocationId),
    handled.

%% Seal this worker's session in place. The origin identity is supplied by the
%% requester — the origin's own proof context co-hosted, the authenticated
%% scope binding remotely; the principal is the engine-owned origin key this
%% scope was opened under.
seal_current({OriginNs, <<_:256>>} = OriginIdentity)
  when is_binary(OriginNs), byte_size(OriginNs) > 0 ->
    #runtime{namespace = Ns, anchor = Anchor, height = Height,
             proof_id = ProofId, principal = Principal,
             request_binding = RequestBinding,
             session = Session} = runtime(),
    quod_proof_session:seal(
      Session,
      #{target => {Ns, Anchor}, base_height => Height,
        proof_id => ProofId, origin => OriginIdentity,
        principal => Principal,
        request_binding => RequestBinding});
seal_current(_OriginIdentity) ->
    {error, {protocol_error, request_binding}}.

remove_invocation(InvocationId) ->
    Runtime = runtime(),
    case quod_proof_session:cancel(
           Runtime#runtime.session, InvocationId) of
        ok -> remove_invocation_metadata(InvocationId);
        {error, _} -> ok
    end.

remove_invocation_metadata(InvocationId) ->
    Runtime = runtime(),
    put_runtime(Runtime#runtime{
      invocations = maps:remove(InvocationId, Runtime#runtime.invocations)}).

begin_step() ->
    #runtime{step_depth = Depth, engine = Engine} = Runtime = runtime(),
    case Depth of
        0 -> Engine ! {scope_step_started, self()}, ok;
        _ -> ok
    end,
    put_runtime(Runtime#runtime{step_depth = Depth + 1}).

end_step() ->
    #runtime{step_depth = Depth, engine = Engine} = Runtime = runtime(),
    NextDepth = erlang:max(0, Depth - 1),
    put_runtime(Runtime#runtime{step_depth = NextDepth}),
    case NextDepth of
        0 -> Engine ! {scope_step_finished, self()}, ok;
        _ -> ok
    end.

send_reply(RequestRef, Reply) ->
    #runtime{origin = Origin, proof_id = ProofId, ref = Ref} = runtime(),
    Origin ! {scope_reply, self(), ProofId, Ref, RequestRef, Reply},
    ok.

remote_ack_command(Handle, Operation) ->
    case quod_ask_router:command(
           Handle, quod_proof_context:remaining_ms(), Operation) of
        {ok, RequestId} -> {ok, RequestId};
        {sent, _RequestId} ->
            {error, {protocol_error, request_binding}};
        {error, _} = Error -> Error
    end.

remote_no_ack_command(Handle, Operation) ->
    case quod_ask_router:command(
           Handle, quod_proof_context:remaining_ms(), Operation) of
        {sent, _RequestId} -> ok;
        {ok, _RequestId} -> {error, {protocol_error, request_binding}};
        {error, _} = Error -> Error
    end.

validate_materialize_request(
  Handle, ActorScopeId, ActorInvocationId, Lineage, BatchIds) ->
    case valid_opaque_id(ActorScopeId) andalso
         valid_opaque_id(ActorInvocationId) andalso
         valid_opaque_id(Lineage) andalso
         valid_batch_ids(BatchIds) of
        false ->
            {error, {protocol_error, request_binding}};
        true ->
            case handle_scope_id(Handle) of
                {ok, ActorScopeId} -> ok;
                {ok, _OtherScopeId} -> {error, not_allowed};
                error -> {error, {protocol_error, session_binding}}
            end
    end.

materialize_validated(
  {local_scope, _ScopeId, _Ns, _Anchor, _Height, Session},
  _ActorScopeId, _ActorInvocationId, _Lineage, BatchIds) ->
    session_control(checkpoint, Session, BatchIds);
materialize_validated(
  {quod_scope_session, _, _, _, _, _, _} = Handle,
  _ActorScopeId, _ActorInvocationId, _Lineage, BatchIds) ->
    scope_control(checkpoint, Handle, BatchIds);
materialize_validated(
  {remote_scope, _, _, _, _} = Handle,
  ActorScopeId, ActorInvocationId, Lineage, BatchIds) ->
    validated_remote_control(
      Handle,
      {materialize, ActorScopeId, ActorInvocationId, Lineage, BatchIds},
      {materialized, ActorScopeId, BatchIds}, BatchIds).

handle_scope_id(
  {local_scope, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>> = ScopeId,
   _Ns, _Anchor, _Height, _Session}) ->
    {ok, ScopeId};
handle_scope_id(
  {quod_scope_session, _Pid,
   <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>> = ScopeId,
   _ProofId, _Ref, _Ns, _Anchor}) ->
    {ok, ScopeId};
handle_scope_id(
  {remote_scope, _RouterPid, _RouterGeneration,
   {scope_binding, _OriginKey, _TargetKey, _ProofId,
    <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>> = ScopeId,
    _OriginIdentity, _TargetIdentity, _Mode,
    _Principal, _AuthenticationDigest}, _RequestLink}) ->
    {ok, ScopeId};
handle_scope_id(_) ->
    error.

validated_local_control(Operation, Session, BatchIds) ->
    case valid_batch_ids(BatchIds) of
        true -> session_control(Operation, Session, BatchIds);
        false -> {error, {protocol_error, request_binding}}
    end.

validated_scope_control(Operation, Handle, BatchIds) ->
    case valid_batch_ids(BatchIds) of
        true -> scope_control(Operation, Handle, BatchIds);
        false -> {error, {protocol_error, request_binding}}
    end.

validated_remote_control(Handle, Operation, ExpectedAck, BatchIds) ->
    case valid_batch_ids(BatchIds) of
        true -> remote_control(Handle, Operation, ExpectedAck);
        false -> {error, {protocol_error, request_binding}}
    end.

remote_control(Handle, Operation, ExpectedAck) ->
    case bind_remote_router(Handle) of
        {ok, Router, MRef} ->
            case command_remaining_ms() of
                0 ->
                    {error, current_execution_limit()};
                RemainingMs ->
                    case quod_ask_router:command(
                           Handle, RemainingMs, Operation) of
                        {ok, RequestId} ->
                            await_remote_control(
                              Handle, RequestId, ExpectedAck, Router, MRef,
                              RemainingMs);
                        {sent, _RequestId} ->
                            {error, {protocol_error, request_binding}};
                        {error, _} = Error ->
                            Error
                    end
            end;
        {error, _} = Error ->
            Error
    end.

bind_remote_router(
  {remote_scope, Router, Generation,
   {scope_binding, _, _, _, _, _, {TargetNs, _}, _, _, _}, _RequestLink}) ->
    case quod_proof_context:bind_router(Router, Generation, TargetNs) of
        {ok, MRef} -> {ok, Router, MRef};
        {error, _} = Error -> Error
    end;
bind_remote_router(_Handle) ->
    {error, {protocol_error, session_binding}}.

await_remote_control(
  Handle, RequestId, ExpectedAck, Router, MRef, RemainingMs) ->
    receive
        {quod_scope_event, Handle, RequestId, Generation, Dirty, ExpectedAck}
          when is_integer(Generation), Generation >= 0, is_boolean(Dirty) ->
            {ok, Dirty, Generation};
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty,
         {scope_error, Reason}} ->
            {error, Reason};
        {quod_scope_down, Handle, Reason} ->
            {error, failure_reason(Handle, Reason)};
        {'DOWN', MRef, process, Router, _Reason} ->
            {error, failure_reason(Handle, unavailable)}
    after RemainingMs ->
        remote_timeout(
          Handle, RequestId, {error, current_execution_limit()})
    end.

remote_timeout(Handle, RequestId, Result) ->
    _ = quod_ask_router:cancel(Handle, RequestId),
    drain_remote_event(Handle, RequestId),
    Result.

drain_remote_event(Handle, RequestId) ->
    receive
        {quod_scope_event, Handle, RequestId, _Generation, _Dirty, _Operation} ->
            drain_remote_event(Handle, RequestId)
    after 0 ->
        ok
    end.

valid_batch_ids([First | Rest]) ->
    valid_opaque_id(First) andalso valid_batch_ids(Rest, First, 1);
valid_batch_ids(_) ->
    false.

valid_batch_ids([], _Previous, _Count) ->
    true;
valid_batch_ids(_Ids, _Previous,
                ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF) ->
    false;
valid_batch_ids([Id | Rest], Previous, Count) ->
    valid_opaque_id(Id) andalso Previous < Id andalso
        valid_batch_ids(Rest, Id, Count + 1);
valid_batch_ids(_Improper, _Previous, _Count) ->
    false.

valid_opaque_id(<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>) -> true;
valid_opaque_id(_) -> false.

session_control(Operation, Session, BatchIds) ->
    with_session_access(
      Session,
      fun() -> session_control_checked(Operation, Session, BatchIds) end).

session_control_checked(checkpoint, Session, BatchIds) ->
    case quod_proof_session:checkpoint_many(Session, BatchIds) of
        ok -> session_control_reply(Session);
        {error, Reason} -> {error, Reason}
    end;
session_control_checked(restore, Session, BatchIds) ->
    case quod_proof_session:restore_many(Session, BatchIds) of
        ok -> session_control_reply(Session);
        {error, Reason} -> {error, Reason}
    end;
session_control_checked(release, Session, BatchIds) ->
    case quod_proof_session:release_many(Session, BatchIds) of
        ok -> session_control_reply(Session);
        {error, Reason} -> {error, Reason}
    end;
session_control_checked(_Operation, _Session, _BatchIds) ->
    {error, {protocol_error, request_binding}}.

session_control_reply(Session) ->
    {ok, quod_proof_session:dirty(Session),
     quod_proof_session:overlay_generation(Session)}.

checked_session_dirty(Session) ->
    with_session_access(
      Session, fun() -> {ok, quod_proof_session:dirty(Session)} end).

%% One narrow boundary for every worker-side session operation. It preserves
%% only the typed proof-access throw; unrelated bugs still crash and are logged
%% by the worker loop. The post-check prevents a result produced just before a
%% gate transition from crossing the scope boundary.
with_session_access(Session, Fun) ->
    try
        case quod_proof_session:check_access(Session) of
            {error, _} = Error ->
                Error;
            ok ->
                Result = Fun(),
                case quod_proof_session:check_access(Session) of
                    ok -> Result;
                    {error, _} = Error -> Error
                end
        end
    catch
        throw:{quod_ask_error, Reason} -> {error, Reason}
    end.

scope_control(Operation,
              Handle = {quod_scope_session, Pid, _ScopeId, ProofId, SessionRef,
                        _Ns, _Anchor},
              BatchIds) ->
    case command_remaining_ms() of
        0 ->
            {error, current_execution_limit()};
        RemainingMs ->
            RequestRef = make_ref(),
            Pid ! {scope_savepoint, self(), ProofId, SessionRef,
                   RequestRef, Operation, BatchIds},
            MRef = monitor(process, Pid),
            try
                receive
                    {scope_reply, Pid, ProofId, SessionRef, RequestRef,
                     {savepoint, Operation, BatchIds, Reply}} ->
                        Reply;
                    {'DOWN', MRef, process, Pid, Reason} ->
                        {error, failure_reason(Handle, Reason)}
                after RemainingMs ->
                    {error, current_execution_limit()}
                end
            after
                demonitor(MRef, [flush])
            end
    end.

command_remaining_ms() ->
    case remaining_ms() of
        {ok, RemainingMs} -> RemainingMs;
        error ->
            try quod_proof_context:remaining_ms()
            catch error:no_proof_context -> 0
            end
    end.

current_execution_limit() ->
    {proof_limit_exceeded, current_execution_namespace()}.

current_execution_namespace() ->
    case get(?RUNTIME) of
        #runtime{namespace = Ns} -> Ns;
        undefined ->
            {Ns, _Anchor} = quod_proof_context:origin_identity(),
            Ns
    end.

-doc "Normalize a monitored scope's terminal reason at its transport boundary.".
-spec failure_reason(handle(), term()) -> term().
failure_reason(
  {quod_scope_session, _, _, _, _, _, _}, {scope_error, Reason}) ->
    Reason;
failure_reason(
  {quod_scope_session, _, _, _, _, _, _} = Handle, killed) ->
    {proof_limit_exceeded, handle_namespace(Handle)};
failure_reason({quod_scope_session, _, _, _, _, _, _}, _Reason) ->
    {protocol_error, proof_engine};
failure_reason({remote_scope, _, _, _, _}, {scope_error, Reason}) ->
    Reason;
failure_reason({remote_scope, _, _, _, _},
               {protocol_error, _} = Reason) ->
    Reason;
failure_reason({remote_scope, _, _, _, _},
               {ontology_unreachable, _} = Reason) ->
    Reason;
failure_reason({remote_scope, _, _, _, _} = Handle, _Reason) ->
    {ontology_unreachable, handle_namespace(Handle)}.

handle_namespace(Handle) ->
    {Ns, _Anchor} = identity(Handle),
    Ns.

valid_command(Origin, ProofId, Ref) ->
    case runtime() of
        #runtime{origin = Origin, proof_id = ProofId, ref = Ref} -> true;
        _ -> false
    end.

valid_invocation_input(InvocationId, Goal, Chain, Selection) ->
    is_binary(InvocationId) andalso byte_size(InvocationId) =:= 16 andalso
    %% A wire/co-hosted invocation ALWAYS carries its origin, so the chain is
    %% never empty here. This is load-bearing for the genesis host-entry policy:
    %% an empty chain means "this node's own top-level proof" and only the local
    %% engine can present one, so a remote peer cannot forge `[]` to borrow the
    %% host-entry default admission.
    is_list(Chain) andalso Chain =/= [] andalso
    length(Chain) < ?QUOD_MAX_ACTIVE_PROOF_DEPTH andalso
    lists:all(fun valid_identity/1, Chain) andalso
    quod_transaction_scope:valid_selection(Selection) andalso
    erlang:external_size(Goal) =< ?QUOD_MAX_NESTED_GOAL_BYTES.

answer_disposition(Answer) ->
    case erlang:external_size(Answer) =< ?QUOD_MAX_PROOF_ANSWER_BYTES of
        true -> ok;
        false -> {error, {too_large, answer}}
    end.

-ifdef(TEST).
test_answer_disposition(Answer) -> answer_disposition(Answer).
-endif.

valid_identity({Ns, <<_:256>>}) when is_binary(Ns), byte_size(Ns) > 0 -> true;
valid_identity(_) -> false.

bytes_to_heap_words(Bytes) when is_integer(Bytes), Bytes > 0 ->
    WordBytes = erlang:system_info(wordsize),
    (Bytes + WordBytes - 1) div WordBytes.

runtime() ->
    case get(?RUNTIME) of
        #runtime{} = Runtime -> Runtime;
        undefined -> erlang:error(no_scope_session)
    end.

put_runtime(#runtime{} = Runtime) -> put(?RUNTIME, Runtime), ok.
