-module(quod_dtx_coordinator).
-moduledoc """
Volatile recovery driver for one already-durable distributed transaction.

The owning namespace Simplex starts one monitored worker from the exact
journaled/committed Begin.  This process owns only bounded observations and
message-driven progress subscriptions: `quod_dtx_recovery:next/2` remains the
sole phase planner, target
Simplex ledgers remain authoritative, and a worker restart reconstructs every
decision from certified evidence.

There is deliberately no durable file, registry name, compatibility protocol,
or wall-clock abort.  Once Begin may be durable, temporary unavailability can
only delay recovery. Exact owner notifications wake parked work; request
deadlines only bound a silent peer or dead worker. Owner death terminates the
coordinator. A persistently temporary target reply therefore remains parked
under that durable owner until progress or owner shutdown; the client deadline
does not cancel or resubmit the uncertain operation.
""".

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([start_monitor/5, start_operation_monitor/4,
         start_dormant_operation_monitor/3]).

-ifdef(TEST).
-export([test_options/1, test_put_evidence/2,
         test_put_generation/3,
         test_valid_validator_routes/2,
         test_valid_phase_evidence/5,
         test_initial_commands/4, test_initial_snapshot/4,
         test_install_phase_snapshot/9,
         test_install_applied_results/3,
         test_dormant_cancel_disposition/2,
         test_dormant_cancel_request/3,
         test_operation_target_response_disposition/2,
         test_operation_target_result/7,
         test_local_submit_result/2, test_remote_submit_result/2,
         test_submit_endpoint_requests/4,
         test_endpoint_request_candidates/5,
         test_submit_phase_evidence/4, test_phase_reply_evidence/8,
         test_observe_phase_evidence/6,
         test_spawn_owned_worker/2, test_close_wave/1,
         test_worker_down_disposition/2,
         test_progress_source/2, test_local_progress_event/2, test_state/1,
         test_pending_phase_reference/5, test_submission_observation_transition/3,
         test_finalize_rediscovery/4, test_phase_verification_deadline/5,
         test_consume_applied_wave/3]).
-endif.

-define(DEFAULT_REQUEST_TIMEOUT_MS, 5000).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).

%% A Common Test may stop the coordinator at an exact certified phase.  The
%% production build expands this to `ok`: no hook lookup, message, state, or
%% exported test API exists outside the TEST profile.
-ifdef(TEST).
-define(TEST_PHASE_BARRIER(Owner, GroupId, Event),
        test_phase_barrier(Owner, GroupId, Event)).
-define(TEST_OBSERVATION_STATE(Initial), test_observation_state(Initial)).
-define(TEST_LOOP_MESSAGE(Message, State), test_loop_message(Message, State)).
-define(ENDPOINT_IO(Source, Target, Request, Sidecar, Context),
        test_endpoint_io(Source, Target, Request, Sidecar, Context)).
-define(FINISH_WAVE(Stage, Items, Results, Meta, State),
        test_finish_wave(Stage, Items, Results, Meta, State)).
-else.
-define(TEST_PHASE_BARRIER(_Owner, _GroupId, _Event), ok).
-define(TEST_OBSERVATION_STATE(Initial), Initial).
-define(TEST_LOOP_MESSAGE(_Message, State), loop(State)).
-define(ENDPOINT_IO(Source, Target, Request, Sidecar, Context),
        endpoint_request(Source, Target, Request, Sidecar, Context)).
-define(FINISH_WAVE(Stage, Items, Results, Meta, State),
        finish_typed_wave(Stage, Items, Results, Meta, State)).
-endif.

-record(config, {
    request_timeout_ms = ?DEFAULT_REQUEST_TIMEOUT_MS :: pos_integer()
}).

-record(wave, {
    ref = undefined :: undefined | reference(),
    stage :: phase_command | phase_verify | applied | operation | dormant,
    items :: [term()],
    workers = #{} ::
      #{pid() | gen_statem:request_id() =>
          {reference() | owner_call, non_neg_integer() | {pos_integer(), pos_integer()}}},
    results = #{} :: #{non_neg_integer() => term()},
    context = #{} :: map(),
    trace_context = undefined :: undefined | quod_trace:context(),
    meta = #{} :: map(),
    timer = undefined :: undefined | reference(),
    started_native = undefined :: undefined | integer(),
    trace_span = undefined :: undefined | quod_trace:span_ctx()
}).

-record(state, {
    owner :: pid(),
    owner_monitor = undefined :: undefined | reference(),
    %% Protocol state shares one owner loop and one I/O wave. It is not
    %% another executor or durable projection.
    protocol = group :: group | {operation, map()} | {dormant, map()},
    %% Capability arrives on the existing exact-owner progress stream.
    %% Pausing changes neither the owner nor the verified recovery snapshot.
    execution_ready = false :: boolean(),
    owner_ns :: binary(),
    origin :: {binary(), <<_:256>>},
    group_id :: undefined | <<_:256>>,
    begin_record :: undefined | quod_dtx:control_record(),
    snapshot :: undefined | quod_dtx_recovery:snapshot(),
    %% Exact entries retained only after the shared local/foreign evidence
    %% verifier accepted their certified references.  They are acceleration
    %% material for the next semantic phase, never a second source of truth.
    phase_entries = #{} :: #{quod_dtx:certified_ref() => quod_ledger:entry_artifact()},
    %% Exact certified Finalize evidence is retained for the one applied-vote
    %% collector. Its historical committee fixes who may sign; routes remain
    %% reachability hints only. At most one row per participant.
    finalize_evidence = #{} :: map(),
    %% A submit acknowledgement carries an exact certified reference.  If the
    %% local/foreign history verifier is momentarily behind that commit, retain
    %% the reference and await the exact history-advance notification; never
    %% submit the semantic phase a second time merely because its durable
    %% evidence is not readable yet.
    pending_phases = #{} :: map(),
    follows = #{} :: #{{binary(), <<_:256>>} =>
                       reference() | {pending, gen_server:request_id()}},
    route_subscriptions = #{} :: #{{binary(), <<_:256>>} => true},
    foreign_log_monitor = none :: none | reference(),
    %% A progress edge received while I/O is in flight must survive that
    %% wave. One boolean coalesces any number of exact follow/route/owner
    %% notifications into one immediate re-plan after the wave finishes.
    progress_pending = false :: boolean(),
    %% Once every participant Finalize is certified applied, the visible
    %% result is already safe.  Notify the namespace owner once, then keep this
    %% same recovery process alive to append mandatory Complete bookkeeping in
    %% the background.  A restart may emit the same terminal value again; the
    %% owner resolves an exact GroupId waiter idempotently.
    terminal_notified = false :: boolean(),
    commands = none :: none | quod_dtx_recovery:command_batch(),
    wave = none :: none | #wave{},
    total_started_native = undefined :: undefined | integer(),
    stage = none :: none | atom(),
    stage_started_native = undefined :: undefined | integer(),
    config :: #config{}
}).

-doc """
Start one unlinked worker and install an exact owner-side monitor.

The caller must be `Owner`; this makes the returned monitor useful by
construction and prevents a third process from creating an unowned recovery
worker.  The worker separately monitors Owner and exits when the namespace
owner disappears.
""".
-spec start_monitor(
        pid(), binary(), quod_dtx:control_record(),
        none | {quod_dtx:certified_ref(), map()}, map()) ->
          {ok, pid(), reference()} | {error, term()}.
start_monitor(Owner, OwnerNs, Begin, BeginEvidence, Options)
  when is_pid(Owner), Owner =:= self(), is_binary(OwnerNs),
       byte_size(OwnerNs) > 0, is_map(Options) ->
    case initial_state(Owner, OwnerNs, Begin, BeginEvidence, Options) of
        {ok, Initial} ->
            TraceCtx = quod_trace:context(),
            {Pid, Monitor} = spawn_monitor(fun() ->
                quod_trace:with_context(TraceCtx, fun() ->
                    init(?TEST_OBSERVATION_STATE(Initial))
                end)
            end),
            {ok, Pid, Monitor};
        {error, _} = Error ->
            Error
    end;
start_monitor(_Owner, _OwnerNs, _Begin, _BeginEvidence, _Options) ->
    {error, invalid_coordinator_start}.

-doc """
Start the one recovery/result worker for an exact foreign operation.

The worker owns no durable state. The existing local outcome index decides
whether the claim still needs target/receipt recovery or only certified result
delivery. A completed operation is resolved read-only, never reapplied. An
unresolved claim reconstructs its exact target transaction from certified local
evidence and uses the existing endpoint and receipt path. Unavailability uses
the shared
foreign-history follower's messages; source progress is supplied by the
owning Simplex.  No retry polling loop is created here.
""".
-spec start_operation_monitor(pid(), binary(), term(), map()) ->
          {ok, pid(), reference()} | {error, term()}.
start_operation_monitor(Owner, OwnerNs, OperationRef, Options)
  when is_pid(Owner), Owner =:= self(),
       is_binary(OwnerNs), byte_size(OwnerNs) > 0,
       is_map(Options), map_size(Options) =:= 0 ->
    case valid_operation_ref(OwnerNs, OperationRef) of
        true ->
            TraceCtx = quod_trace:context(),
            {Pid, Monitor} = spawn_monitor(
                               fun() ->
                                   quod_trace:with_optional_span(
                                     TraceCtx, <<"quod.operation.recover">>, internal,
                                     #{'quod.namespace' => OwnerNs,
                                       'quod.operation.id' => quod_trace:tx_id(element(5, OperationRef))},
                                     fun() -> operation_init(Owner, OwnerNs, OperationRef) end)
                               end),
            {ok, Pid, Monitor};
        false ->
            {error, invalid_operation_start}
    end;
start_operation_monitor(_Owner, _OwnerNs, _OperationRef,
                        _Options) ->
    {error, invalid_operation_start}.

-doc "Cancel an unactivated source claim and its exact private target binding.".
-spec start_dormant_operation_monitor(pid(), binary(), term()) ->
          {ok, pid()} | {error, term()}.
start_dormant_operation_monitor(Owner, OwnerNs, Submission)
  when is_pid(Owner), is_binary(OwnerNs), byte_size(OwnerNs) > 0 ->
    case dormant_operation_context(OwnerNs, Submission) of
        {ok, Context} ->
            {ok, spawn(fun() ->
                               dormant_operation_init(Owner, Context)
                       end)};
        {error, _} = Error ->
            Error
    end;
start_dormant_operation_monitor(_Owner, _OwnerNs, _Submission) ->
    {error, invalid_operation_start}.

dormant_operation_context(OwnerNs, Submission) ->
    try
        {ok, SubmissionBlob} = quod_transaction:encode_operation_submission(Submission),
        {ok, Targets} = quod_transaction:operation_submission_targets(Submission),
        Contexts = [begin
            {ok, C} = dormant_operation_binding(OwnerNs, SubmissionBlob,
                quod_transaction:decode_operation_submission(SubmissionBlob, Target)), C
        end || Target <- Targets],
        [First | Rest] = Contexts,
        {ok, First#{remaining_targets => Rest}}
    catch _:_ -> {error, invalid_operation_claim}
    end.

dormant_operation_binding(
  OwnerNs, SubmissionBlob,
  {ok,
   #{claim := #transaction{origin = {OwnerNs, _} = Origin,
                           tx_id = ClaimTxId},
     target := Target, plan := Plan}}) ->
    case quod_dtx:signer(Plan) of
        <<_:256>> = TargetNode ->
            {ok, #{owner_ns => OwnerNs, origin => Origin,
                   claim_tx_id => ClaimTxId,
                   target => Target,
                   target_node => TargetNode,
                   submission_blob => SubmissionBlob}};
        _ -> {error, invalid_operation_claim}
    end;
dormant_operation_binding(_OwnerNs, _SubmissionBlob, _Decoded) ->
    {error, invalid_operation_claim}.

dormant_operation_init(Owner, Context = #{owner_ns := OwnerNs, origin := Origin,
                                          target := Target}) ->
    %% Subscribe before the first endpoint attempt so a route edge concurrent
    %% with link failure is already in this process's mailbox. The signed
    %% cancellation remains the exact same blob on every later wake.
    S = ensure_route_subscription(Target,
          #state{owner = Owner, owner_monitor = erlang:monitor(process, Owner),
                 owner_ns = OwnerNs, origin = Origin, execution_ready = true,
                 protocol = {dormant, Context#{state => cancel}},
                 config = #config{}}),
    queue_drive(),
    loop(S).

dormant_operation_drive(S = #state{owner = Owner,
  protocol = {dormant, #{state := release, claim_tx_id := ClaimTxId}}}) ->
    %% Preserve the existing caller-pid capability and 8s call allowance.
    %% Source retirement stops this exact cancellation process itself; a lost
    %% reply cannot turn into a new submission or another cancellation owner.
    start_typed_wave(dormant,
      [{owner_call, Owner, {cancel_transaction_custody, ClaimTxId}}],
      #{request_deadline => quod_time:mono_ms() + 8000}, S);
dormant_operation_drive(S = #state{protocol = {dormant,
  #{owner_ns := OwnerNs, target := Target, target_node := TargetNode,
    submission_blob := SubmissionBlob}}}) ->
    Request = dormant_cancel_request(
                crypto:strong_rand_bytes(
                  ?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS div 8),
                Target, SubmissionBlob),
    start_typed_wave(dormant,
      [{cancel, OwnerNs, Target, TargetNode, Request}], #{}, S).

dormant_wave_io({cancel, OwnerNs, Target, TargetNode, Request}, Context) ->
    case context_timeout(Context) of
        0 -> {error, timeout};
        Remaining -> quod_dtx_current_view:submit_operation_to(
                       OwnerNs, Target, TargetNode, Request, Remaining)
    end.

finish_dormant_wave([{owner_call, _, _}], [Result], _Meta, S)
  when Result =:= ok; Result =:= {error, not_in_charge};
       Result =:= {error, already_active}; Result =:= {error, not_found} ->
    close_coordinator(ok, S),
    stop;
finish_dormant_wave([{cancel, _, _, _, Request}], [{ok, Response}],
                     #{request_deadline := Deadline}, S) ->
    case quod_time:mono_ms() < Deadline andalso
         dormant_cancel_disposition(Request, Response) =:= terminal of
        true -> dormant_operation_next(S);
        false -> {next, S}
    end;
finish_dormant_wave(_Items, [{worker_down, Reason}], _Meta, _S) when Reason =/= timeout ->
    error({dormant_worker_crash, Reason});
finish_dormant_wave(_Items, _Results, _Meta, S) ->
    {next, S}.

dormant_cancel_disposition(
  Request,
  {operation_effect_cancelled, _RequestId, Status} = Response)
  when Status =:= cancelled; Status =:= not_found ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> terminal;
        false -> wait
    end;
dormant_cancel_disposition(_Request, _Response) ->
            %% Endpoint errors do not prove that the target prerequisite is
            %% gone. Keep source custody and wait for a real progress edge.
    wait.

dormant_cancel_request(RequestId, Target, SubmissionBlob)
  when is_binary(RequestId),
       bit_size(RequestId) =:= ?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS,
       is_binary(SubmissionBlob) ->
    {cancel_operation_effect, RequestId, Target, SubmissionBlob}.

%% Cancellation is of never-activated private prerequisites, not a target
%% application fan-out. The existing owner walks the canonical set and cannot
%% retire source custody on only one target's acknowledgement.
dormant_operation_next(S0 = #state{protocol = {dormant,
  #{target := OldTarget, remaining_targets := [Next | Rest]}}}) ->
    S = drop_route_subscription(OldTarget, S0),
    Target = maps:get(target, Next),
    queue_drive(),
    {next, ensure_route_subscription(Target,
      S#state{protocol = {dormant, Next#{remaining_targets => Rest, state => cancel}}})};
dormant_operation_next(S = #state{protocol = {dormant,
  #{remaining_targets := []} = Context}}) ->
    queue_drive(),
    {next, S#state{protocol = {dormant, Context#{state => release}}}}.

valid_operation_ref(
  Ns, {operation, Ns, <<_:256>>, AgentRef, <<_:256>>}) ->
    quod_agent_ref:valid_principal({agent, AgentRef});
valid_operation_ref(_Ns, _OperationRef) ->
    false.

operation_init(Owner, OwnerNs, OperationRef) ->
    _ = quod_trace:add_event(
          quod_trace:context(), <<"operation.worker_started">>, #{}),
    {operation, OwnerNs, Anchor, _, _} = OperationRef,
    loop(#state{owner = Owner, owner_monitor = erlang:monitor(process, Owner),
                owner_ns = OwnerNs, origin = {OwnerNs, Anchor}, config = #config{},
                protocol = {operation, #{owner_ns => OwnerNs,
                  operation_ref => OperationRef, state => claim}}}).

%% Source publication can precede the waiter, or follow a relay reply. Read
%% the same durable index on start and on a real progress edge; absence is not
%% completion and a completion receipt is not the target's verdict.
operation_refresh(S) ->
    %% This is one recovery read attempt, not the lifetime of durable custody.
    %% Only startup or a genuine source/follower progress event calls here;
    %% capture and outcome corroboration share the existing request budget.
    Deadline = quod_time:mono_ms() + ?DEFAULT_REQUEST_TIMEOUT_MS,
    start_typed_wave(operation, [local_outcome], #{request_deadline => Deadline}, S).

operation_refresh_result(Outcome, Deadline,
  S = #state{owner = Owner, owner_ns = OwnerNs, protocol = {operation,
    #{operation_ref := OperationRef} = Context}}) ->
    case Outcome of
        {ok, #{status := claimed, ref := OperationRef,
               operation_state := ClaimState, height := Slot,
               request_digest := <<_:256>> = Digest,
               outcome_ref := {applications,
                 [{transaction, TargetNs, <<_:256>> = Anchor, <<_:256>>} = TargetRef]}}}
          when (ClaimState =:= unresolved orelse ClaimState =:= terminal),
               is_integer(Slot), Slot > 0,
               is_binary(TargetNs), byte_size(TargetNs) > 0 ->
            Owner ! {dtx_coordinator, self(), OperationRef,
                     {claim_state, ClaimState, Slot, Digest, [TargetRef]}},
            Bound = set_operation_context(Context#{target => {TargetNs, Anchor},
                             target_ref => TargetRef, request_digest => Digest}, S),
            case {ClaimState, map_get(state, Context)} of
                {terminal, source} ->
                    %% This worker already delivered the verified result.
                    operation_stop(done, Bound);
                {terminal, _} ->
                    operation_resolve_target(Deadline, operation_mode(resolve, Bound));
                {unresolved, claim} ->
                    start_typed_wave(operation, [{claim_evidence, Slot}],
                                      #{request_deadline => Deadline}, Bound);
                {unresolved, resolve} ->
                    %% Replay can temporarily expose an earlier source row.
                    %% Once terminal was observed, this worker stays read-only.
                    operation_resolve_target(Deadline, Bound);
                {unresolved, _} ->
                    operation_drive(Bound)
            end;
        {ok, #{outcome_ref := {applications, Refs}}} when length(Refs) > 1 ->
            %% Temporary release boundary ruled in C1: the canonical storage
            %% and target applier accept vectors, but the N-target execution
            %% owner is slice 8. Never pick the first target or fall back to L3.
            operation_stop(independent_lane_unavailable, S);
        {error, not_found} ->
            {next, S};
        {error, {outcome_unknown, OperationRef}} ->
            {next, S};
        {error, {ontology_unreachable, OwnerNs}} ->
            {next, S};
        {error, {ontology_rebuilding, OwnerNs}} ->
            {next, S};
        {error, Reason} ->
            operation_stop(Reason, S);
        _ ->
            operation_stop(invalid_operation_claim, S)
    end.

operation_claim_result(Result, S = #state{owner_ns = OwnerNs, protocol = {operation,
  #{operation_ref := OperationRef, target_ref := TargetRef, request_digest := Digest} = Bound}}) ->
    case Result of
        {ok, ClaimRef, Claim} ->
            case operation_context(OwnerNs, OperationRef, ClaimRef, Claim) of
                {ok, #{target_ref := TargetRef, request_digest := Digest} = Context} ->
                    {ok, ClaimBytes} = quod_transaction:encode_evidence(ClaimRef, Claim),
                    Target = maps:get(target, Context),
                    StableClaim = quod_transaction:stable_ref(ClaimRef),
                    #transaction{tx_id = ApplicationId} =
                        quod_transaction:remote_application(StableClaim, Claim, Target),
                    {transaction, _, _, ApplicationId} = TargetRef,
                    operation_drive(set_operation_context(
                      (maps:merge(Bound, Context))#{claim_ref => ClaimRef,
                                                   claim => Claim, claim_bytes => ClaimBytes}, S));
                {ok, _WrongBinding} ->
                    operation_stop(invalid_operation_claim, S);
                {error, Reason} ->
                    operation_stop(Reason, S)
            end;
        {error, Reason} when Reason =:= not_ready; Reason =:= timeout ->
            {next, S};
        {error, Reason} ->
            operation_stop(Reason, S)
    end.

operation_resolve_target(Deadline, S) ->
    start_typed_wave(operation, [resolve_outcome], #{request_deadline => Deadline}, S).

operation_resolve_io(#{owner_ns := OwnerNs, target := Target, target_ref := TargetRef}, Deadline) ->
    case operation_outcome_source(Target, Deadline) of
        {ok, Source} ->
            quod_dtx_current_view:lookup_outcome(OwnerNs, Source, TargetRef, Deadline);
        {error, _} = Error -> Error
    end.

operation_resolve_result(Result, S = #state{protocol = {operation, #{target_ref := TargetRef}}}) ->
    case Result of
        {ok, #{ref := TargetRef, status := committed}} ->
            operation_deliver_resolved(committed, S);
        {ok, #{ref := TargetRef, status := rejected, reason := Reason}} when is_atom(Reason) ->
            operation_deliver_resolved({rejected, Reason}, S);
        _ -> operation_wait_target(S)
    end.

operation_outcome_source(Target, Deadline) ->
    %% A co-hosted observer is a byte source, not a voting source. If the
    %% local validator is unavailable, use the ordinary certified routes.
    case quod_simplex:history_view(Target, validator, Deadline) of
        {ok, View} -> {ok, {local, View}};
        {error, timeout} -> {error, retry};
        {error, _} ->
            case routes(Target) of
                [] -> {error, retry};
                Rows -> {ok, {remote, Rows}}
            end
    end.

operation_deliver_resolved(Result, S = #state{owner = Owner,
  protocol = {operation, #{operation_ref := OperationRef, target_ref := TargetRef}}}) ->
    notify_operation_target_result(Owner, OperationRef, Result, TargetRef),
    operation_stop(done, S).

%% One existing owner-message seam for fresh application and read-only
%% recovery alike. Finish this short span before driving the receipt: the
%% enclosing recovery span may still be open (or retired) after client reply.
%% The event precedes the unchanged send so the source owner's receive event
%% exposes its mailbox delay on this node's clock.
notify_operation_target_result(
  Owner, {operation, Ns, _Anchor, _Principal, OperationId} = OperationRef,
  Result, TargetRef) ->
    quod_trace:with_optional_span(
      quod_trace:context(), <<"quod.operation.result_notify">>, internal,
      #{'quod.namespace' => Ns, 'quod.operation.id' => quod_trace:tx_id(OperationId)},
      fun() ->
          _ = quod_trace:add_event(
                quod_trace:context(), <<"operation.result_sent">>, #{}),
          Owner ! {dtx_coordinator, self(), OperationRef,
                   {target_result, Result, TargetRef}}
      end).

operation_context(
  OwnerNs, OperationRef,
  ClaimRef,
  #transaction{origin = {OwnerNs, <<_:256>>} = Origin,
               role = {remote_claim, _Manifest, _Bundles,
                       [{transaction, TargetNs, <<_:256>> = TargetAnchor,
                         <<_:256>> = TargetTxId}]}} = Claim)
  when is_binary(TargetNs), byte_size(TargetNs) > 0 ->
    case {quod_dtx:certified_ref_binding(ClaimRef),
          quod_transaction:request_claim(Claim)} of
        {{ok, Origin, _Slot, ClaimTxId},
         {ok, #{operation_ref := OperationRef,
                digest := <<_:256>> = RequestDigest}}}
          when ClaimTxId =:= Claim#transaction.tx_id ->
            Target = {TargetNs, TargetAnchor},
            case quod_transaction:remote_claim_route(Claim, Target) of
                Route when Route =:= shared; element(1, Route) =:= private ->
                    {ok, #{owner_ns => OwnerNs, origin => Origin,
                           operation_ref => OperationRef,
                           request_digest => RequestDigest,
                           target => Target,
                           target_ref => {transaction, TargetNs,
                                          TargetAnchor, TargetTxId},
                           state => target}};
                error ->
                    {error, invalid_operation_claim}
            end;
        _ ->
            {error, invalid_operation_claim}
    end;
operation_context(_OwnerNs, _OperationRef, _ClaimRef, _Claim) ->
    {error, invalid_operation_claim}.

operation_drive(S = #state{protocol = {operation,
  #{state := target, target := Target, claim_bytes := ClaimBytes}}}) ->
    RequestId = crypto:strong_rand_bytes(
                  ?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS div 8),
    %% Only the transport correlation id changes. The durable signed claim
    %% artifact and its deterministic application identity stay pinned.
    Request = {apply_claim, RequestId, Target, ClaimBytes},
    start_typed_wave(operation, [{target_application, Request}], #{}, S);
operation_drive(S = #state{protocol = {operation, #{state := source}}}) ->
    operation_submit_complete(S).

operation_target_response(
  Request,
  {application, _RequestId, committed, EvidenceBlob} = Response,
  S) ->
    operation_target_result(
      Request, Response, committed, EvidenceBlob, S);
operation_target_response(
  Request,
  {application, _RequestId, {rejected, Reason}, EvidenceBlob} = Response,
  S) when is_atom(Reason) ->
    operation_target_result(
      Request, Response, {rejected, Reason}, EvidenceBlob, S);
operation_target_response(
  Request, Response, S) ->
    case operation_target_response_disposition(Request, Response) of
        wait ->
            operation_wait_target(S);
        invalid_operation_claim ->
            operation_stop(invalid_operation_claim, S);
        invalid_target_response ->
            operation_stop(invalid_target_response, S)
    end.

operation_target_response_disposition(Request, Response) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> operation_target_error_disposition(Response);
        false -> invalid_target_response
    end.

operation_target_error_disposition({error, _RequestId, invalid_request}) ->
    invalid_operation_claim;
operation_target_error_disposition({error, _RequestId, _Temporary}) ->
    wait;
operation_target_error_disposition(_Response) ->
    invalid_target_response.

-ifdef(TEST).
%% Observation fixtures enter with a pre-verified planner snapshot, not a
%% fabricated endpoint reply. The production expansion is just Initial; no
%% option, lookup or alternate admission path exists in release code.
test_observation_state(S = #state{group_id = GroupId}) ->
    case application:get_env(quod, dtx_test_observation_state) of
        {ok, {GroupId, Snapshot, Follows}} ->
            S#state{snapshot = Snapshot, follows = Follows};
        _ -> S
    end.

test_operation_target_response_disposition(Request, Response) ->
    operation_target_response_disposition(Request, Response).
test_operation_target_result(
  Owner, OwnerMonitor, Request, Response, Result, EvidenceBlob, Context) ->
    S = #state{owner = Owner, owner_monitor = OwnerMonitor,
                owner_ns = maps:get(owner_ns, Context), origin = maps:get(origin, Context),
                protocol = {operation, Context}, config = #config{}, execution_ready = true},
    continue(operation_target_result(Request, Response, Result, EvidenceBlob, S)).
-endif.

operation_target_result(
  Request, Response, Result, EvidenceBlob,
  S = #state{owner = Owner, protocol = {operation,
    #{operation_ref := OperationRef, target_ref := TargetRef} = Context}}) ->
    case {quod_dtx_endpoint:correlates(Request, Response),
          %% This is codec/shape checking of the existing reply, not a new
          %% authentication step. Keep it inside the same eager tuple so
          %% malformed or mismatched replies follow the unchanged contract.
          quod_trace:with_optional_span(
            quod_trace:context(), <<"quod.operation.result_evidence_decode">>, internal,
            #{}, fun() -> quod_transaction:decode_evidence(EvidenceBlob) end)} of
        {true, {ok, TargetCertifiedRef,
                #transaction{tx_id = TargetTxId,
                             role = {remote_application, _, _, _}}
                  = TargetTransaction}} ->
            case stable_transaction_ref(TargetCertifiedRef, TargetTxId) of
                TargetRef ->
                    %% The durable operation owner is also the sole live
                    %% submission owner.  Publish its certified target result
                    %% before asynchronously appending the source receipt so a
                    %% waiting client never needs a second target submission.
                    notify_operation_target_result(
                      Owner, OperationRef, Result, TargetRef),
                    operation_drive(set_operation_context(
                      Context#{state => source,
                               target_certified_ref => TargetCertifiedRef,
                               target_transaction => TargetTransaction}, S));
                _ ->
                    operation_stop(invalid_target_evidence, S)
            end;
        _ ->
            operation_stop(invalid_target_evidence, S)
    end.

stable_transaction_ref(Ref, TxId) ->
    case quod_transaction:stable_ref(Ref) of
        {transaction, _Ns, _Anchor, TxId} = StableRef -> StableRef;
        _ -> invalid
    end.

operation_submit_complete(
  S = #state{protocol = {operation, #{origin := Origin,
    operation_ref := OperationRef, request_digest := RequestDigest,
    target_ref := TargetRef, target_certified_ref := TargetCertifiedRef,
    target_transaction := TargetTransaction}}}) ->
    try
        Complete0 = quod_transaction:remote_complete(
                      Origin, OperationRef, RequestDigest,
                      [{quod_operation_vector:target(TargetRef), {included, TargetRef}}]),
        quod_transaction:attach_receipt_evidence(
                     Complete0, [{TargetCertifiedRef, TargetTransaction}])
    of Complete -> start_typed_wave(operation, [{receipt, Complete}], #{}, S)
    catch _:_ ->
        operation_stop(invalid_completion, S)
    end.

operation_target_metric_result(
  {ok, {application, _, committed, _}}) -> ok;
operation_target_metric_result(
  {ok, {application, _, {rejected, _}, _}}) -> rejected;
operation_target_metric_result({error, _}) -> uncertain;
operation_target_metric_result(_) -> failed.

operation_completion_metric_result({ok, _, _, _}) -> ok;
operation_completion_metric_result({error, {outcome_unknown, _}}) -> uncertain;
operation_completion_metric_result({error, _}) -> uncertain.

operation_wait_target(S = #state{protocol = {operation, #{target := Target}}}) ->
    {next, wait_for_progress(Target, S)}.

set_operation_context(Context, S) -> S#state{protocol = {operation, Context}}.
operation_mode(Mode, S = #state{protocol = {operation, Context}}) ->
    set_operation_context(Context#{state => Mode}, S).

operation_stop(Reason, S = #state{owner = Owner,
  protocol = {operation, #{operation_ref := OperationRef}}}) ->
    Event = case Reason of done -> {done, OperationRef}; _ -> {error, Reason} end,
    Owner ! {dtx_coordinator, self(), OperationRef, Event},
    close_coordinator(case Reason of done -> ok; _ -> failed end, S),
    stop.

operation_wave_io(Item, #{operation := Context, request_deadline := Deadline} = WaveContext) ->
    case context_timeout(WaveContext) of
        0 -> {error, timeout};
        Remaining -> operation_item_io(Item, Context, Deadline, Remaining)
    end.

operation_item_io(local_outcome, #{owner_ns := Ns, operation_ref := Ref}, _Deadline, _Remaining) ->
    quod_trace:with_optional_span(quod_trace:context(), <<"quod.operation.local_outcome">>,
      internal, #{'quod.namespace' => Ns}, fun() -> quod_prolog:local_outcome(Ns, Ref) end);
operation_item_io({claim_evidence, Slot}, #{owner_ns := Ns, operation_ref := Ref}, Deadline, _Remaining) ->
    quod_trace:with_optional_span(quod_trace:context(), <<"quod.operation.claim_evidence">>,
      internal, #{'quod.namespace' => Ns, 'quod.ledger.slot' => Slot},
      fun() -> quod_simplex:operation_claim_evidence(Ns, Slot, Ref, Deadline) end);
operation_item_io(resolve_outcome, #{target := {Ns, _}} = Context, Deadline, _Remaining) ->
    quod_trace:with_optional_span(quod_trace:context(), <<"quod.operation.resolve_outcome">>,
      internal, #{'quod.namespace' => Ns}, fun() -> operation_resolve_io(Context, Deadline) end);
operation_item_io({target_application, Request},
  #{owner_ns := Ns, target := {TargetNs, _} = Target, claim := Claim}, _Deadline, Remaining) ->
    Started = erlang:monotonic_time(),
    Result = quod_trace:with_optional_span(quod_trace:context(), <<"quod.operation.target_application">>,
      client, #{'quod.namespace' => TargetNs},
      fun() -> quod_dtx_current_view:submit_claim_application(Ns, Target, Claim, Request, Remaining) end),
    ok = quod_metrics:observe_remote_operation_stage(TargetNs, target_application,
           operation_target_metric_result(Result), erlang:monotonic_time() - Started),
    Result;
operation_item_io({receipt, Complete}, #{owner_ns := Ns}, _Deadline, Remaining) ->
    Started = erlang:monotonic_time(),
    Result = quod_trace:with_optional_span(quod_trace:context(), <<"quod.operation.receipt">>,
      internal, #{'quod.namespace' => Ns},
      fun() -> quod_prolog:submit_role(Ns, Complete, [], Remaining) end),
    ok = quod_metrics:observe_remote_operation_stage(Ns, completion,
           operation_completion_metric_result(Result), erlang:monotonic_time() - Started),
    Result.

finish_operation_wave([Item], [Result], #{request_deadline := Deadline}, S) ->
    %% A completed worker may still have queued its reply past the admitted
    %% deadline. Late success is uncertainty, never a newly published verdict.
    case quod_time:mono_ms() < Deadline of
        true -> operation_item_result(Item, Result, Deadline, S);
        false -> operation_item_wait(Item, S)
    end.

operation_item_result(Item, {worker_down, timeout}, _Deadline, S) -> operation_item_wait(Item, S);
operation_item_result(Item, {worker_down, Reason}, _Deadline, S) ->
    Stage = case is_atom(Item) of true -> Item; false -> element(1, Item) end,
    operation_stop({operation_worker_crash, Stage, Reason}, S);
operation_item_result(local_outcome, Result, Deadline, S) ->
    operation_refresh_result(Result, Deadline, S);
operation_item_result({claim_evidence, _}, Result, _Deadline, S) -> operation_claim_result(Result, S);
operation_item_result(resolve_outcome, Result, _Deadline, S) -> operation_resolve_result(Result, S);
operation_item_result({target_application, Request}, {ok, Response}, _Deadline, S) ->
    operation_target_response(Request, Response, S);
operation_item_result({target_application, _}, {error, invalid_request}, _Deadline, S) ->
    operation_stop(invalid_operation_claim, S);
operation_item_result({target_application, _}, _Temporary, _Deadline, S) -> operation_wait_target(S);
operation_item_result({receipt, _}, {ok, _Bindings, _Slot, _TxId}, _Deadline, S) -> operation_stop(done, S);
operation_item_result({receipt, _}, _Temporary, _Deadline, S) -> {next, S}.

operation_item_wait({target_application, _}, S) -> operation_wait_target(S);
operation_item_wait(resolve_outcome, S) -> operation_wait_target(S);
operation_item_wait(_Item, S) -> {next, S}.

initial_state(Owner, OwnerNs, Begin, BeginEvidence, Options) ->
    case {options(Options), quod_dtx:begin_recovery_rows(Begin),
          quod_dtx:begin_group_ref(Begin)} of
        {{ok, Config},
         {ok, {OwnerNs, <<_:256>>} = Origin, <<_:256>> = GroupId, Rows},
         {ok, {group, OwnerNs, _Anchor, _Coordinator, _Admission, GroupId}}}
          when length(Rows) >= 2,
               length(Rows) =< ?QUOD_MAX_DTX_PARTICIPANTS ->
            seed_begin_evidence(
              BeginEvidence,
              #state{owner = Owner, owner_ns = OwnerNs, origin = Origin,
                     group_id = GroupId, begin_record = Begin,
                     snapshot = quod_dtx_recovery:empty(),
                     config = Config});
        {{error, _} = Error, _, _} ->
            Error;
        _ ->
            {error, invalid_begin}
    end.

seed_begin_evidence(none, S) ->
    {ok, S};
seed_begin_evidence(
  {BeginRef, Evidence},
  S = #state{origin = Origin, group_id = GroupId}) ->
    case install_phase_evidence(
           Origin, GroupId, 'begin', BeginRef, Evidence, S) of
        {progress, Seeded, begun} -> {ok, Seeded};
        _ -> {error, invalid_begin_evidence}
    end;
seed_begin_evidence(_Malformed, _S) ->
    {error, invalid_begin_evidence}.

options(Options) when map_size(Options) =< 1 ->
    Allowed = [request_timeout_ms],
    case lists:all(fun(Key) -> lists:member(Key, Allowed) end,
                   maps:keys(Options)) of
        true ->
            Request = maps:get(request_timeout_ms, Options,
                               ?DEFAULT_REQUEST_TIMEOUT_MS),
            case is_integer(Request) andalso Request > 0 andalso
                 Request =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS of
                true ->
                    {ok, #config{request_timeout_ms = Request}};
                false ->
                    {error, invalid_coordinator_options}
            end;
        false ->
            {error, invalid_coordinator_options}
    end;
options(_) ->
    {error, invalid_coordinator_options}.

init(S0 = #state{owner = Owner}) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    queue_drive(),
    S = S0#state{owner_monitor = OwnerMonitor,
                 total_started_native = erlang:monotonic_time()},
    %% The monitor holder owns the attempt span. This child inherits its
    %% context, but external retirement cannot reliably run child cleanup.
    loop(S).

loop(S) ->
    receive
        Message -> handle_loop_message(Message, S)
    end.

handle_loop_message(
  {drive, EnqueuedNative}, S = #state{wave = #wave{ref = Ref}})
  when is_reference(Ref) ->
    %% A progress edge cannot be consumed while its current observation wave
    %% is still running. `finish_wave/1` re-enqueues the retained edge.
    observe_stage(S, coordinator_mailbox, ok, EnqueuedNative),
    loop(S#state{progress_pending = true});
handle_loop_message({drive, EnqueuedNative}, S) ->
    observe_stage(S, coordinator_mailbox, ok, EnqueuedNative),
    continue(drive(S#state{progress_pending = false}));
handle_loop_message(
  {dtx_wave_result, WaveRef, Worker, Index, Result},
  S = #state{wave = #wave{ref = WaveRef, workers = Workers} = Wave}) ->
    case maps:take(Worker, Workers) of
        {{Monitor, Index}, Workers1} ->
            _ = erlang:demonitor(Monitor, [flush]),
            S1 = record_wave_result(Index, Result,
                     S#state{wave = Wave#wave{workers = Workers1}}),
            continue(advance_wave(S1));
        _CrossedOrDuplicate ->
            loop(S)
    end;
handle_loop_message(
  {dtx_wave_timeout, WaveRef},
  S = #state{wave = #wave{ref = WaveRef} = Wave}) ->
    continue(timeout_wave(Wave, S));
handle_loop_message(
  {quod_foreign_follow, FollowRef, NoticeRef, Identity, Notice},
  S = #state{follows = Follows}) ->
    case maps:get(Identity, Follows, undefined) of
        FollowRef ->
            ok = quod_foreign_log:ack(FollowRef, NoticeRef),
            case foreign_progress_notice(Notice) of
                true -> loop(request_progress_drive(S));
                false -> loop(S)
            end;
        _ ->
            loop(S)
    end;
handle_loop_message(
  {local_dtx_progress, Owner, _, _, Ready} = Message,
  S = #state{owner = Owner, origin = Origin}) ->
    case local_progress_event(Message, Origin) of
        true ->
            S1 = request_progress_drive(
                   S#state{execution_ready = execution_capability(S, Ready)}),
            case S1#state.wave of
                #wave{ref = Ref} when is_reference(Ref) ->
                    continue(advance_wave(S1));
                _ -> loop(S1)
            end;
        false -> loop(S)
    end;
handle_loop_message(
  {directory_route_available, Identity},
  S = #state{route_subscriptions = Subscriptions}) ->
    case maps:is_key(Identity, Subscriptions) of
        true ->
            S1 = route_progress_follow(Identity, S),
            loop(request_progress_drive(S1));
        false ->
            loop(S)
    end;
handle_loop_message(
  {gproc, unreg, Monitor, _Name},
  S = #state{foreign_log_monitor = Monitor}) ->
    %% Follow refs belong to the old owner and can never become live again.
    %% Required identities remain in route_subscriptions for exact reattach.
    maps:foreach(fun(_Identity, Follow) -> cancel_pending_follow(Follow) end,
                 S#state.follows),
    loop(S#state{follows = #{}});
handle_loop_message(
  {gproc, registered, Monitor, _Name},
  S = #state{foreign_log_monitor = Monitor,
             route_subscriptions = Subscriptions}) ->
    S1 = lists:foldl(
           fun(Identity, Acc) -> attach_follow(Identity, Acc) end,
           S, maps:keys(Subscriptions)),
    loop(registration_progress(S1));
handle_loop_message(
  {'DOWN', Monitor, process, Owner, _Reason},
  S = #state{owner_monitor = Monitor, owner = Owner}) ->
    observe_coordinator_close(uncertain),
    close_coordinator(uncertain, S),
    ok;
handle_loop_message(
  {'DOWN', Monitor, process, Worker, Reason} = Message,
  S = #state{wave = #wave{workers = Workers} = Wave}) ->
    case maps:take(Worker, Workers) of
        {{Monitor, Index}, Workers1} ->
            S1 = record_wave_result(Index, {worker_down, Reason},
                     S#state{wave = Wave#wave{workers = Workers1}}),
            continue(advance_wave(S1));
        _ ->
            handle_aux_message(Message, S)
    end;
handle_loop_message(Message, S) ->
    handle_aux_message(Message, S).

handle_aux_message(Message, S = #state{wave = #wave{workers = Workers} = Wave}) ->
    case owner_call_response(Message, maps:to_list(Workers)) of
        {RequestId, Index, Response} ->
            S1 = record_wave_result(Index, Response,
                   S#state{wave = Wave#wave{workers = maps:remove(RequestId, Workers)}}),
            continue(advance_wave(S1));
        none -> handle_follow_message(Message, S)
    end;
handle_aux_message(Message, S) ->
    handle_follow_message(Message, S).

%% Native owner calls must be sent by this process: the source's custody
%% authorization checks the actual caller pid. Their OTP aliases participate
%% in the same pending wave, deadline, cancellation and result ordering as I/O
%% workers; no proxy is allowed to impersonate the cancellation owner.
owner_call_response(_Message, []) -> none;
owner_call_response(Message, [{RequestId, {owner_call, Index}} | Rest]) ->
    case gen_statem:check_response(Message, RequestId) of
        no_reply -> owner_call_response(Message, Rest);
        {reply, Reply} -> {RequestId, Index, Reply};
        {error, {Reason, _Server}} -> {RequestId, Index, {worker_down, Reason}}
    end;
owner_call_response(Message, [_ | Rest]) -> owner_call_response(Message, Rest).

handle_follow_message(Message, S = #state{follows = Follows}) ->
    case follow_response(Message, maps:to_list(Follows)) of
        {Identity, {reply, {ok, FollowRef}}} when is_reference(FollowRef) ->
            loop(S#state{follows = Follows#{Identity => FollowRef}});
        {Identity, _Unavailable} ->
            loop(S#state{follows = maps:remove(Identity, Follows)});
        none -> ?TEST_LOOP_MESSAGE(Message, S)
    end.

follow_response(_Message, []) -> none;
follow_response(Message, [{Identity, {pending, RequestId}} | Rest]) ->
    case gen_server:check_response(Message, RequestId) of
        no_reply -> follow_response(Message, Rest);
        Response -> {Identity, Response}
    end;
follow_response(Message, [_ | Rest]) -> follow_response(Message, Rest).

cancel_pending_follow({pending, RequestId}) ->
    %% Zero-time cancellation abandons this one alias/monitor. It is not a
    %% retry, poll, or wait for the server; consumer DOWN also removes custody.
    _ = gen_server:receive_response(RequestId, 0), ok;
cancel_pending_follow(_Active) -> ok.

close_follow({pending, _} = Pending) -> cancel_pending_follow(Pending);
close_follow(FollowRef) ->
    case quod_foreign_log:unfollow_request(FollowRef) of
        {ok, RequestId} -> cancel_pending_follow({pending, RequestId});
        {error, _} -> ok
    end.

continue({next, S}) -> loop(S);
continue(stop) -> ok.

drive(S = #state{execution_ready = false}) ->
    {next, S};
drive(S = #state{wave = #wave{ref = undefined, stage = Stage,
                              items = Items, meta = Meta}}) ->
    start_typed_wave(Stage, Items, Meta, S#state{wave = none});
drive(S = #state{wave = #wave{}}) ->
    {next, S};
drive(S = #state{protocol = {operation, _}}) ->
    operation_refresh(S);
drive(S = #state{protocol = {dormant, _}}) ->
    dormant_operation_drive(S);
drive(S = #state{pending_phases = Pending}) when map_size(Pending) > 0 ->
    [{Key, Value} | _] = lists:sort(maps:to_list(Pending)),
    drive_pending(Key, Value, S);
drive(S) ->
    drive_commands(S).

drive_pending(_Key, {reference, Target, GroupId, Kind, Ref, Preferred}, S) ->
    start_typed_wave(phase_verify, [{Target, GroupId, Kind, Ref, Preferred}],
                     empty_wave_outcome(), S);
drive_pending(_Key, {submission, Target, GroupId, Kind}, S) ->
    start_typed_wave(phase_command, [{phase, Target, GroupId, Kind, uncertain}],
                     #{}, S).

empty_wave_outcome() ->
    #{phases => [], progress => false, waiting => false, fatal => none}.

drive_commands(S = #state{commands = none, terminal_notified = false}) ->
    case quod_dtx_recovery:terminal(
           S#state.begin_record, S#state.snapshot) of
        {ok, Terminal} ->
            notify(S, {terminal, Terminal}),
            queue_drive(),
            {next, S#state{terminal_notified = true}};
        pending ->
            drive_commands_next(S);
        {error, Reason} ->
            terminate_expected({invalid_recovery_state, Reason}, S)
    end;
drive_commands(S = #state{commands = none}) ->
    drive_commands_next(S);
drive_commands(S = #state{commands = {Mode, Stage, Commands}})
  when Mode =:= ordered; Mode =:= independent ->
    %% The planner's ordering is represented by its vector, not another
    %% executor. Ordered phases contain exactly one command.
    start_wave(Stage, Commands, S).

drive_commands_next(S) ->
    case quod_dtx_recovery:next(S#state.begin_record, S#state.snapshot) of
        {done, CompleteRef} ->
            %% Finish child root-event writes before the existing notification
            %% lets the owner append done_observed to that same SDK event list.
            %% The SDK's event RMW is not atomic across processes. This changes
            %% observation order only: notification still precedes all cleanup.
            _ = catch quod_trace:add_event(
                  quod_trace:context(), <<"dtx.completed">>,
                  #{'quod.dtx.result' => <<"ok">>}),
            observe_coordinator_close(ok),
            notify(S, {done, CompleteRef}),
            close_coordinator(ok, S),
            stop;
        {ok, {Mode, Stage, [_ | _] = Commands} = Batch}
          when (Mode =:= ordered orelse Mode =:= independent),
               is_atom(Stage),
               length(Commands) =< ?QUOD_MAX_DTX_PARTICIPANTS ->
            queue_drive(),
            {next, S#state{commands = Batch}};
        {ok, _MalformedCommands} ->
            terminate_expected(invalid_recovery_commands, S);
        {error, Reason} ->
            terminate_expected({invalid_recovery_state, Reason}, S)
    end.

drop_pending(Key, S = #state{pending_phases = Pending}) ->
    S#state{pending_phases = maps:remove(Key, Pending)}.

put_pending(Value, S = #state{pending_phases = Pending}) ->
    Key = pending_key(Value),
    case maps:get(Key, Pending, none) of
        none -> S#state{pending_phases = Pending#{Key => Value}};
        Value -> S;
        _Conflicting -> error(conflicting_pending_phase)
    end.

pin_pending_reference(Target, GroupId, Kind, Ref, Preferred,
                       S = #state{pending_phases = Pending}) ->
    Key = {Target, Kind},
    S1 = case maps:get(Key, Pending, none) of
        {submission, Target, GroupId, Kind} -> drop_pending(Key, S);
        _ -> S
    end,
    put_pending({reference, Target, GroupId, Kind, Ref, Preferred}, S1).

pending_key({reference, Target, _GroupId, Kind, _Ref, _Preferred}) ->
    {Target, Kind};
pending_key({submission, Target, _GroupId, Kind}) ->
    {Target, Kind}.

start_wave(applied, Commands, S) ->
    start_typed_wave(applied, [Commands], #{}, enter_stage(applied_wave, S));
start_wave(Stage, Commands, S) ->
    start_typed_wave(phase_command, Commands, #{},
                     enter_stage(record_stage(Stage), S)).

start_typed_wave(Stage, Items, Meta, S = #state{execution_ready = false}) ->
    %% No worker has been admitted for this next action yet. Preserve any
    %% existing deadline; a ready edge cannot renew already admitted work.
    {next, S#state{commands = none,
                   wave = #wave{stage = Stage, items = Items, meta = Meta}}};
start_typed_wave(Stage, Items, Meta, S) ->
    launch_wave(Stage, Items, Meta, S).

launch_wave(Stage, Items, Meta0, S) ->
    Ref = make_ref(),
    Timeout = (S#state.config)#config.request_timeout_ms,
    Deadline = maps:get(request_deadline, Meta0, quod_time:mono_ms() + Timeout),
    Meta = case Stage of
        phase_verify -> Meta0#{request_deadline => Deadline,
            evidence_deadline => maps:get(evidence_deadline, Meta0, Deadline)};
        _ -> Meta0#{request_deadline => Deadline}
    end,
    Context0 = (wave_context(S))#{request_deadline => Deadline},
    %% Capture before admission. Route discovery, endpoint expansion and
    %% result mailbox residence all spend this same allowance.
    Context = case Stage of
        phase_verify -> Context0#{evidence_deadline => maps:get(evidence_deadline, Meta)};
        _ -> Context0
    end,
    {TraceCtx, TraceSpan} = quod_trace:start_span(
        quod_trace:context(), <<"quod.dtx.wave">>, internal,
        #{'quod.dtx.stage' => atom_to_binary(Stage, utf8),
          'quod.dtx.wave.items' => length(Items)}),
    Wave0 = #wave{ref = Ref, stage = Stage, items = Items, meta = Meta,
                   context = Context, trace_context = TraceCtx,
                   trace_span = TraceSpan, started_native = erlang:monotonic_time()},
    Workers = spawn_wave_items(lists:zip(lists:seq(1, length(Items)), Items), Wave0),
    Timer = erlang:send_after(max(0, Deadline - quod_time:mono_ms()),
                              self(), {dtx_wave_timeout, Ref}),
    {next, S#state{commands = none, wave = Wave0#wave{workers = Workers, timer = Timer}}}.

spawn_wave_items(Items, Wave) ->
    maps:from_list([start_wave_item(Key, Item, Wave) || {Key, Item} <- Items]).

start_wave_item(Key, {owner_call, Owner, Request}, _Wave) ->
    {gen_statem:send_request(Owner, Request), {owner_call, Key}};
start_wave_item(Key, Item, #wave{ref = Ref, stage = Stage, context = Context,
                                trace_context = TraceCtx}) ->
    Parent = self(),
        {Pid, Monitor} = spawn_owned_monitor(Parent, fun() ->
            Result = quod_trace:with_span(
                TraceCtx, <<"quod.dtx.wave.item">>, internal,
                #{'quod.dtx.stage' => atom_to_binary(Stage, utf8),
                  'quod.dtx.wave.item' => logical_item(Key)},
                fun(_) -> run_wave_work(Stage, Item, Context) end),
            Parent ! {dtx_wave_result, Ref, self(), Key, Result}
        end),
    {Pid, {Monitor, Key}}.

logical_item({Index, _Endpoint}) -> Index;
logical_item(Index) -> Index.

%% Expand one target's prepared routes in this SAME wave. A fast target
%% does not wait for another target's discovery, and a paused owner retains
%% preparations without starting another endpoint. Results stay target-keyed.
record_wave_result(Index, {prepared_submit, Plan}, S) when is_integer(Index) ->
    put_wave_result(Index, {prepared_submit, Plan}, S);
record_wave_result({Index, Endpoint}, Result,
                   S = #state{wave = Wave = #wave{results = Results}}) ->
    {dispatching, Plan, Uncertain} = maps:get(Index, Results),
    {_Target, _GroupId, _Kind, Request, _Sidecar, Sources} = Plan,
    Source = lists:nth(Endpoint, Sources),
    Classification = case Result of
        {worker_down, _} -> uncertain;
        _ -> classify_submit_endpoint_result(Source, Request, Result)
    end,
    count_submit_endpoint_result(S#state.owner_ns, Classification, Result),
    case Classification of
        terminal ->
            Wave1 = stop_wave_item(Index, Wave),
            put_wave_result(Index, submit_plan_result(Plan, submit_reply(Result)),
                            S#state{wave = Wave1});
        _ ->
            Pending = has_wave_item(Index, Wave#wave.workers),
            Uncertain1 = Uncertain orelse Classification =:= uncertain,
            case Pending of
                true -> put_wave_result(Index, {dispatching, Plan, Uncertain1}, S);
                false ->
                    Outcome = case Uncertain1 of true -> outcome_unknown; false -> not_submitted end,
                    put_wave_result(Index, submit_plan_result(Plan, Outcome), S)
            end
    end;
record_wave_result(Index, Result, S) ->
    put_wave_result(Index, Result, S).

put_wave_result(Index, Result, S = #state{wave = Wave = #wave{results = Results}}) ->
    S#state{wave = Wave#wave{results = Results#{Index => Result}}}.

has_wave_item(Index, Workers) ->
    lists:any(fun({_Monitor, Key}) -> logical_item(Key) =:= Index end, maps:values(Workers)).

stop_wave_item(Index, Wave = #wave{workers = Workers}) ->
    Remaining = maps:filter(fun(Pid, {Monitor, Key}) ->
        case logical_item(Key) =:= Index of
            true -> stop_wave_item_owner(Pid, Monitor), false;
            false -> true
        end
    end, Workers),
    Wave#wave{workers = Remaining}.

submit_plan_result({Target, GroupId, Kind, Request, _Sidecar, _Sources}, Outcome) ->
    {ok, Target, GroupId, Kind, Request, Outcome}.

advance_wave(S0) ->
    S = resume_wave_submissions(S0),
    #wave{workers = Workers, results = Results} = S#state.wave,
    Prepared = lists:any(fun({prepared_submit, _}) -> true; (_) -> false end,
                         maps:values(Results)),
    case map_size(Workers) =:= 0 andalso not Prepared of
        true -> finish_wave(S);
        false -> {next, S}
    end.

resume_wave_submissions(S = #state{execution_ready = false}) -> S;
resume_wave_submissions(S0 = #state{wave = #wave{results = Results}}) ->
    lists:foldl(fun
        ({Index, {prepared_submit, Plan}}, S) -> dispatch_wave_submission(Index, Plan, S);
        (_, S) -> S
    end, S0, lists:sort(maps:to_list(Results))).

dispatch_wave_submission(Index,
  Plan = {Target, _GroupId, _Kind, Request, Sidecar, Sources},
  S = #state{wave = Wave = #wave{context = Context, workers = Workers}}) ->
    case Sources =/= [] andalso context_timeout(Context) > 0 of
        false -> put_wave_result(Index, submit_plan_result(Plan, not_submitted), S);
        true ->
            quod_metrics:count_dtx_submit_fanout(S#state.owner_ns, attempted, length(Sources)),
            Jobs = [{{Index, N}, {endpoint, Source, Target, Request, Sidecar}}
                    || {N, Source} <- lists:zip(lists:seq(1, length(Sources)), Sources)],
            More = spawn_wave_items(Jobs, Wave),
            put_wave_result(Index, {dispatching, Plan, false},
                            S#state{wave = Wave#wave{workers = maps:merge(Workers, More)}})
    end.

wave_context(#state{protocol = {operation, Context}, owner_ns = OwnerNs}) ->
    #{owner_ns => OwnerNs, operation => Context};
wave_context(#state{protocol = Protocol, owner_ns = OwnerNs}) when Protocol =/= group ->
    #{owner_ns => OwnerNs};
wave_context(#state{owner_ns = OwnerNs, snapshot = Snapshot,
                    finalize_evidence = FinalizeEvidence,
                    phase_entries = PhaseEntries}) ->
    #{owner_ns => OwnerNs,
      applied => maps:get(applied, Snapshot),
      finalize_evidence => FinalizeEvidence,
      phase_entries => PhaseEntries}.

run_wave_work(operation, Item, Context) ->
    operation_wave_io(Item, Context);
run_wave_work(dormant, Item, Context) ->
    dormant_wave_io(Item, Context);
run_wave_work(phase_command, Command, Context) ->
    phase_command_io(Command, Context);
run_wave_work(phase_verify, Spec, Context) ->
    phase_evidence_io(Spec, Context);
run_wave_work(applied, Commands, Context) ->
    applied_wave_io(Commands, Context).

finish_wave(S0 = #state{wave = #wave{stage = Stage,
                                      items = Items,
                                      results = Results,
                                      meta = Meta,
                                      timer = Timer,
                                      started_native = StartedNative} = Wave}) ->
    _ = erlang:cancel_timer(Timer),
    finish_wave_trace(Wave, ok),
    %% The public prepare/finalize/applied stage spans all of its submit,
    %% evidence, and wait turns.  It is closed by `enter_stage/2` at the next
    %% protocol stage (or by coordinator termination), not at a sub-wave.
    _ = StartedNative,
    S = release_progress_drive(
          S0#state{wave = none, commands = none}),
    Ordered = [maps:get(Index, Results)
               || Index <- lists:seq(1, map_size(Results))],
    ?FINISH_WAVE(Stage, Items, Ordered, Meta, S).

finish_typed_wave(operation, Items, Results, Meta, S) ->
    finish_operation_wave(Items, Results, Meta, S);
finish_typed_wave(dormant, Items, Results, Meta, S) ->
    finish_dormant_wave(Items, Results, Meta, S);
finish_typed_wave(applied, [Commands], [{ok, Views}],
                  #{request_deadline := Deadline}, S)
  when length(Commands) =:= length(Views) ->
    %% A collector's checked reply may have waited in this owner's mailbox.
    %% Expiry is uncertainty, never an applied claim or an invented rejection.
    Consumed = case quod_time:mono_ms() < Deadline of
        true -> Views;
        false -> [retry || _ <- Commands]
    end,
    finish_applied_wave([Commands], [{ok, Consumed}], S);
finish_typed_wave(applied, Items, Results, _Meta, S) ->
    finish_applied_wave(Items, Results, S);
finish_typed_wave(phase_command, Items, Results, Meta, S) ->
    finish_phase_command_wave(Items, Results, Meta, S);
finish_typed_wave(phase_verify, Items, Results, Meta, S) ->
    finish_verify_wave(Items, Results, Meta, S).

finish_applied_wave([Commands], [{ok, Views}], S) ->
    case install_applied_wave(Commands, Views, S) of
        {ok, S1, Targets, Waiting, Progress} ->
            S2 = wait_for_commands_progress(Waiting, S1),
            case {Progress, Waiting} of
                {true, _} ->
                    notify(S2, {progress, {applied, Targets}}),
                    queue_drive();
                {false, []} ->
                    %% Every positive was already installed; re-plan once
                    %% from that complete snapshot rather than parking.
                    queue_drive();
                {false, [_ | _]} ->
                    %% Exact follow/route/local-commit signals wake only the
                    %% unresolved targets. There is no progress polling.
                    ok
            end,
            {next, S2};
        {fatal, Reason, S1} ->
            terminate_expected(Reason, S1)
    end;
finish_applied_wave([_Commands], [{error, invalid_request}], S) ->
    terminate_expected(invalid_applied_claim, S);
finish_applied_wave([Commands], [{worker_down, Reason}], S) ->
    case worker_down_disposition(applied, Reason) of
        retry -> {next, wait_for_commands_progress(Commands, S)};
        {fatal, Failure} -> terminate_expected(Failure, S)
    end;
finish_applied_wave(_Items, _Results, S) ->
    terminate_expected(invalid_applied_wave_result, S).

finish_phase_command_wave(Commands, Results, Meta0, S) ->
    case classify_phase_command_wave(
           Commands, Results, S, [], [], false, false, none) of
        {S1, VerifyRev, PhasesRev, Progress, Waiting, Fatal} ->
            Meta = Meta0#{phases => lists:reverse(PhasesRev),
                     progress => Progress, waiting => Waiting,
                     fatal => Fatal},
            case lists:reverse(VerifyRev) of
                [_ | _] = Verify ->
                    start_typed_wave(phase_verify, Verify, Meta, S1);
                [] ->
                    finish_wave_outcome(Meta, S1)
            end
    end.

classify_phase_command_wave([], [], S, Verify, Phases,
                            Progress, Waiting, Fatal) ->
    {S, Verify, Phases, Progress, Waiting, Fatal};
classify_phase_command_wave(
  [Command | Commands], [Result | Results], S0,
  Verify, Phases, Progress, Waiting, Fatal0) ->
    case classify_phase_command_result(Command, Result, S0) of
        {verify, Spec, S1} ->
            classify_phase_command_wave(
              Commands, Results, S1, [Spec | Verify], Phases,
              Progress, Waiting, Fatal0);
        {progress, Phase, S1} ->
            classify_phase_command_wave(
              Commands, Results, S1, Verify, [Phase | Phases],
              true, Waiting, Fatal0);
        {absent, S1} ->
            %% Exact absence discharges uncertainty, not a certified phase.
            %% Re-plan without manufacturing a phase-progress notification.
            classify_phase_command_wave(
              Commands, Results, S1, Verify, Phases,
              true, Waiting, Fatal0);
        {observe, S1} ->
            %% A completed submission attempt admits one read-only outcome
            %% observation. Its refusal may mean the phase already committed,
            %% including before this coordinator existed. Waiting for another
            %% commit before that first read would strand a quiet owner.
            %% This is a workflow transition, not certified phase progress.
            classify_phase_command_wave(
              Commands, Results, S1, Verify, Phases,
              true, Waiting, Fatal0);
        {waiting, S1} ->
            classify_phase_command_wave(
              Commands, Results, S1, Verify, Phases,
              Progress, true, Fatal0);
        {retry, S1} ->
            classify_phase_command_wave(
              Commands, Results, S1, Verify, Phases,
              Progress, Waiting, Fatal0);
        {fatal, Reason, S1} ->
            Fatal = first_fatal(Fatal0, Reason),
            classify_phase_command_wave(
              Commands, Results, S1, Verify, Phases,
              Progress, Waiting, Fatal)
    end;
classify_phase_command_wave(_Commands, _Results, S, Verify, Phases,
                            Progress, Waiting, Fatal) ->
    {S, Verify, Phases, Progress, Waiting,
     first_fatal(Fatal, invalid_dtx_wave_result)}.

classify_phase_command_result(
  {submit, Target, _Record},
  {ok, Target, GroupId, Kind, Request,
   {reply, {accepted, _RequestId, _Digest, Ref} = Response, Source}}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true ->
            {verify, {Target, GroupId, Kind, Ref, Source},
             pin_pending_reference(Target, GroupId, Kind, Ref, Source, S)};
        false ->
            {fatal, invalid_endpoint_response, S}
    end;
classify_phase_command_result(
  {submit, Target, _Record},
  {ok, Target, _GroupId, prepare, Request,
   {reply, {refused, _RequestId, Target, Digest, Generation,
            ReasonsBlob} = Response, _Source}}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true ->
            case put_refusal(Target, Digest, Generation, ReasonsBlob, S) of
                {progress, S1, Phase} -> {progress, Phase, S1};
                {retry, S1} -> {retry, S1};
                {fatal, Reason, S1} -> {fatal, Reason, S1}
            end;
        false ->
            {fatal, invalid_endpoint_response, S}
    end;
classify_phase_command_result(
  {submit, Target, _Record},
  {ok, Target, GroupId, Kind, Request,
   {reply, {error, _RequestId, Reason} = Response, _Source}}, S)
  when Reason =:= busy; Reason =:= not_ready; Reason =:= not_found ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true ->
            {observe, put_pending(
                        {submission, Target, GroupId, Kind}, S)};
        false ->
            {fatal, invalid_endpoint_response, S}
    end;
classify_phase_command_result(
  {submit, Target, _Record},
  {ok, Target, _GroupId, _Kind, Request,
   {reply, {error, _RequestId, invalid_request} = Response, _Source}}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> {fatal, endpoint_rejected_recovery_record, S};
        false -> {fatal, invalid_endpoint_response, S}
    end;
classify_phase_command_result(
  {submit, Target, Record},
  {ok, Target, GroupId, Kind, _Request, outcome_unknown}, S) ->
    true = quod_dtx:group_id(Record) =:= GroupId,
    {observe, put_pending({submission, Target, GroupId, Kind}, S)};
classify_phase_command_result(
  {submit, _Target, _Record},
  {ok, _Target2, _GroupId, _Kind, _Request, not_submitted}, S) ->
    {waiting, wait_for_progress(_Target, S)};
classify_phase_command_result(
  {submit, Target, Record}, {worker_down, Reason}, S) ->
    %% The worker can die after the peer accepted the request but before its
    %% reply reached this owner.  Preserve uncertainty; never resubmit merely
    %% because a volatile worker disappeared.
    uncertain = worker_down_disposition(submit, Reason),
    GroupId = quod_dtx:group_id(Record),
    Kind = quod_dtx:record_kind(Record),
    {observe, put_pending({submission, Target, GroupId, Kind}, S)};
classify_phase_command_result(
  {phase, Target, GroupId, Kind},
  {ok, Target, GroupId, Kind, _Request, Observation}, S) ->
    classify_phase_observation(Target, GroupId, Kind, Observation, S);
classify_phase_command_result(
  {phase, Target, GroupId, Kind, uncertain},
  {ok, Target, GroupId, Kind, _Request, Observation}, S) ->
    classify_phase_observation(Target, GroupId, Kind, Observation, S);
classify_phase_command_result(
  {phase, Target, _GroupId, _Kind, uncertain}, {worker_down, Reason}, S) ->
    phase_worker_failed(Target, Reason, S);
classify_phase_command_result(
  {phase, Target, _GroupId, _Kind}, {worker_down, Reason}, S) ->
    phase_worker_failed(Target, Reason, S);
classify_phase_command_result(_Command, {error, Reason}, S) ->
    {fatal, {invalid_recovery_record, Reason}, S};
classify_phase_command_result(_Command, _Malformed, S) ->
    {fatal, invalid_dtx_wave_result, S}.

phase_worker_failed(Target, Reason, S) ->
    case worker_down_disposition(phase, Reason) of
        retry ->
            %% A silence deadline is an availability failure. The exact
            %% follow/route signal wakes the pure recovery planner.
            {waiting, wait_for_progress(Target, S)};
        {fatal, Failure} ->
            {fatal, Failure, S}
    end.

classify_phase_observation(Target, GroupId, finalize,
                           {finalize_absent, PrepareObservation}, S) ->
    %% Only the normal complete absence walk discharges this submission.
    %% Any discovered Prepare then takes the same pinned verification path.
    classify_phase_observation(Target, GroupId, prepare, PrepareObservation,
                               drop_pending({Target, finalize}, S));
classify_phase_observation(Target, GroupId, Kind, Observation, S) ->
    case install_phase_observation(Target, Observation, S) of
        {verify, Ref, Preferred, S1} ->
            {verify, {Target, GroupId, Kind, Ref, Preferred},
             pin_pending_reference(Target, GroupId, Kind, Ref, Preferred, S1)};
        {progress, S1, Phase} -> {progress, Phase, S1};
        {absent, S1} -> {absent, drop_pending({Target, Kind}, S1)};
        {retry, S1} -> {waiting, wait_for_progress(Target, S1)};
        {fatal, Reason, S1} -> {fatal, Reason, S1}
    end.

finish_verify_wave(Specs, Results,
                   #{evidence_deadline := Deadline} = Meta0, S0) ->
    {S, PhasesRev, Progress, Waiting, Fatal} =
        classify_verify_wave(
          Specs, Results, S0, [], maps:get(progress, Meta0),
          maps:get(waiting, Meta0), maps:get(fatal, Meta0), Deadline),
    Meta = Meta0#{phases := maps:get(phases, Meta0) ++
                              lists:reverse(PhasesRev),
                  progress := Progress, waiting := Waiting,
                  fatal := Fatal},
    finish_wave_outcome(Meta, S).

classify_verify_wave([], [], S, Phases, Progress, Waiting, Fatal, _Deadline) ->
    {S, Phases, Progress, Waiting, Fatal};
classify_verify_wave(
  [{Target, GroupId, Kind, Ref, Preferred} | Specs],
  [Result | Results], S0, Phases, Progress, Waiting, Fatal0, Deadline) ->
    case phase_evidence_result(Result, Deadline) of
        {ok, Evidence} ->
            case install_phase_evidence(
                   Target, GroupId, Kind, Ref, Evidence, S0) of
                {progress, S1, Phase} ->
                    classify_verify_wave(
                      Specs, Results, drop_pending({Target, Kind}, S1),
                      [Phase | Phases], true,
                      Waiting, Fatal0, Deadline);
                {fatal, Reason, S1} ->
                    classify_verify_wave(
                      Specs, Results, S1, Phases, Progress, Waiting,
                      first_fatal(Fatal0, Reason), Deadline)
            end;
        {error, retry} ->
            S1 = put_pending(
                   {reference, Target, GroupId, Kind, Ref, Preferred}, S0),
            classify_verify_wave(
              Specs, Results, S1, Phases, Progress, true, Fatal0, Deadline);
        {worker_down, Reason} ->
            case worker_down_disposition(evidence, Reason) of
                retry ->
                    S1 = put_pending(
                           {reference, Target, GroupId, Kind, Ref,
                            Preferred}, S0),
                    classify_verify_wave(
                      Specs, Results, S1, Phases, Progress, true, Fatal0, Deadline);
                {fatal, Failure} ->
                    classify_verify_wave(
                      Specs, Results, S0, Phases, Progress, Waiting,
                      first_fatal(Fatal0, Failure), Deadline)
            end;
        _Malformed ->
            classify_verify_wave(
              Specs, Results, S0, Phases, Progress, Waiting,
              first_fatal(Fatal0, invalid_verified_phase_evidence), Deadline)
    end;
classify_verify_wave(_Specs, _Results, S, Phases, Progress, Waiting, Fatal, _Deadline) ->
    {S, Phases, Progress, Waiting,
     first_fatal(Fatal, invalid_dtx_wave_result)}.

finish_wave_outcome(#{fatal := Reason}, S) when Reason =/= none ->
    terminate_expected(Reason, S);
finish_wave_outcome(#{phases := Phases, progress := true}, S) ->
    lists:foreach(fun(Phase) -> notify(S, {progress, Phase}) end, Phases),
    queue_drive(),
    {next, S};
finish_wave_outcome(#{waiting := true}, S) ->
    {next, ensure_pending_follows(S)};
finish_wave_outcome(_Meta, S) ->
    {next, ensure_pending_follows(S)}.

first_fatal(none, Reason) -> Reason;
first_fatal(Reason, _Later) -> Reason.

ensure_pending_follows(S = #state{pending_phases = Pending}) ->
    lists:foldl(
      fun({_Key, Value}, Acc) ->
              wait_for_progress(pending_target(Value), Acc)
      end, S, maps:to_list(Pending)).

pending_target({reference, Target, _, _, _, _}) -> Target;
pending_target({submission, Target, _, _}) -> Target.

stop_wave_workers(#wave{ref = undefined}) -> ok;
stop_wave_workers(#wave{workers = Workers, timer = Timer}) ->
    _ = erlang:cancel_timer(Timer),
    maps:foreach(
      fun(Pid, {Monitor, _Index}) ->
              stop_wave_item_owner(Pid, Monitor)
      end, Workers),
    ok.

stop_wave_item_owner(RequestId, owner_call) ->
    %% Abandon this alias without waiting; a late source application is still
    %% authoritative and retires custody through its unchanged owner path.
    _ = gen_statem:receive_response(RequestId, 0),
    ok;
stop_wave_item_owner(Pid, Monitor) ->
    _ = erlang:demonitor(Monitor, [flush]),
    exit(Pid, kill),
    ok.

worker_down_disposition(submit, _Reason) -> uncertain;
worker_down_disposition(_ReadStage, timeout) -> retry;
worker_down_disposition(Stage, Reason)
  when Stage =:= phase; Stage =:= evidence; Stage =:= applied ->
    {fatal, {dtx_worker_crash, Stage, Reason}}.

timeout_wave(Wave = #wave{workers = Workers}, S0) ->
    stop_wave_workers(Wave),
    %% Missing replies after dispatch are uncertain; preparations that never
    %% dispatched are known not to have submitted anything.
    S1 = maps:fold(fun(Pid, {_Monitor, Key}, Acc = #state{wave = W}) ->
        W1 = W#wave{workers = maps:remove(Pid, W#wave.workers)},
        record_wave_result(Key, {worker_down, timeout}, Acc#state{wave = W1})
    end, S0, Workers),
    #wave{results = Results} = S1#state.wave,
    S2 = maps:fold(fun
        (Index, {prepared_submit, Plan}, Acc) ->
            put_wave_result(Index, submit_plan_result(Plan, not_submitted), Acc);
        (_Index, _Result, Acc) -> Acc
    end, S1, Results),
    finish_wave(S2).

submit_command_io({submit, Target, Record}, Context) ->
    %% No write here: the owner receives routes and expands endpoint work.
    case quod_dtx:encode_record(Record) of
        {ok, RecordBlob} ->
            Kind = quod_dtx:record_kind(Record),
            GroupId = quod_dtx:group_id(Record),
            Request = {submit, request_id(), RecordBlob},
            Sidecar = record_validation_sidecar(
                Record, maps:get(phase_entries, Context), maps:get(applied, Context)),
            {prepared_submit, {Target, GroupId, Kind, Request, Sidecar, endpoint_sources(Target)}};
        {error, Reason} -> {error, Reason}
    end.

phase_command_io({endpoint, Source, Target, Request, Sidecar}, Context) ->
    ?ENDPOINT_IO(Source, Target, Request, Sidecar, Context);
phase_command_io({submit, _Target, _Record} = Command, Context) ->
    submit_command_io(Command, Context);
phase_command_io({phase, Target, GroupId, Kind}, Context) ->
    phase_query_io(ordinary, Target, GroupId, Kind, Context);
phase_command_io({phase, Target, GroupId, Kind, uncertain}, Context) ->
    phase_query_io(uncertain, Target, GroupId, Kind, Context);
phase_command_io(_Command, _Context) ->
    {error, invalid_recovery_record}.

phase_query_io(Mode, Target, GroupId, Kind, Context) ->
    Request = {phase, request_id(), GroupId, Kind},
    Observation = phase_command_sources(
      endpoint_sources(Target), Target, Kind, Request, Context,
      Mode, false, false, none),
    case {Mode, Kind, Observation} of
        {uncertain, finalize, {absent, _}} ->
            %% A direct abort can lose to an already committed Prepare. Read
            %% that phase before replanning with an unsigned generation hint.
            %% Same worker/walk/deadline; no write or extra retry allowance.
            {ok, Target, GroupId, prepare, _, PrepareObservation} =
                phase_query_io(ordinary, Target, GroupId, prepare, Context),
            {ok, Target, GroupId, Kind, Request,
             {finalize_absent, PrepareObservation}};
        _ -> {ok, Target, GroupId, Kind, Request, Observation}
    end.

%% One read-only delivery walk. Ordinary discovery may use an unsigned
%% generation hint; clearing uncertain submission requires absence from every
%% reachable exact source, with no pending/unavailable source. Both modes stop
%% at the FIRST correlated reference. Evidence then has one separate pinned
%% verification wave, never another peer walk or renewed per-peer allowance.
phase_command_sources([], _Target, _Kind, _Request, _Context,
                      uncertain, true, false, Generation) ->
    {absent, Generation};
phase_command_sources([], _Target, _Kind, _Request, _Context,
                      _Mode, _Absent, _Blocked, Generation) ->
    {unresolved, Generation};
phase_command_sources([Source | Rest], Target, Kind, Request, Context,
                      Mode, Absent, Blocked, Generation) ->
    Result = phase_response(
      Request, endpoint_request(Source, Target, Request, [], Context)),
    case Result of
        {committed, _, _} -> Result;
        {uncommitted, Hint, Status} when Kind =:= prepare, Mode =:= ordinary,
                                       (Status =:= pending orelse Status =:= not_found) ->
            {generation, Hint};
        {uncommitted, Hint, not_found} ->
            NextGeneration = case Kind of
                prepare -> max_generation(Generation, Hint);
                _ -> Generation
            end,
            phase_command_sources(Rest, Target, Kind, Request, Context,
                                  Mode, true, Blocked, NextGeneration);
        {error, _} when Source =:= local -> Result;
        _RetryOrInvalidRemote ->
            phase_command_sources(Rest, Target, Kind, Request, Context,
                                  Mode, Absent, true, Generation)
    end.

max_generation(none, Generation) -> Generation;
max_generation(Previous, Generation) -> max(Previous, Generation).

phase_response(Request, {ok, Response, Source}) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        false -> {error, invalid_endpoint_response};
        true ->
            case Response of
                {phase, _, _, {committed, Ref}} -> {committed, Ref, Source};
                {phase, _, Generation, Status}
                  when Status =:= pending; Status =:= not_found ->
                    case valid_generation(Generation) of
                        true -> {uncommitted, Generation, Status};
                        false -> {error, invalid_target_generation}
                    end;
                {error, _, Reason}
                  when Reason =:= busy; Reason =:= not_ready; Reason =:= not_found ->
                    retry;
                {error, _, invalid_request} -> {error, endpoint_rejected_phase_query};
                _ -> {error, invalid_endpoint_response}
            end
    end;
phase_response(_Request, {error, _}) -> retry.

install_phase_observation(_Target, {committed, Ref, Source}, S) ->
    {verify, Ref, Source, S};
install_phase_observation(Target, {generation, Generation}, S) ->
    put_generation(Target, Generation, S);
install_phase_observation(Target, {Status, Generation}, S)
  when Status =:= absent; Status =:= unresolved ->
    case install_observed_generation(Target, Generation, S) of
        {ok, S1} when Status =:= absent -> {absent, S1};
        {ok, S1} -> {retry, S1};
        {fatal, _, _} = Fatal -> Fatal
    end;
install_phase_observation(_Target, {error, Reason}, S) -> {fatal, Reason, S}.

install_observed_generation(_Target, none, S) -> {ok, S};
install_observed_generation(Target, Generation, S) ->
    case put_generation(Target, Generation, S) of
        {progress, S1, _} -> {ok, S1};
        {retry, S1} -> {ok, S1};
        {fatal, _, _} = Fatal -> Fatal
    end.

phase_evidence_io(
  {Target, _GroupId, Kind, Ref, Preferred},
  #{evidence_deadline := Deadline}) ->
    %% A reply's preferred peer key is a delivery hint, not an authenticated
    %% contact. The evidence owner alone selects local versus routed storage.
    case quod_foreign_log:resolve_reference(
           Target, Ref, Kind, none, preferred_entry_hint(Preferred, Ref),
           Deadline) of
        {ok, Evidence} -> {ok, Evidence};
        {error, _} -> {error, retry}
    end.

preferred_entry_hint({reply_source, local, Hints}, Ref) ->
    entry_hint(Ref, Hints);
preferred_entry_hint({reply_source, remote, _PeerKey, Hints}, Ref) ->
    entry_hint(Ref, Hints);
preferred_entry_hint(_Preferred, _Ref) -> none.

%% The worker's checked success can wait in the coordinator mailbox. It may
%% not install evidence after this same attempt's allowance has expired.
phase_evidence_result({ok, _} = Result, Deadline) ->
    case quod_time:mono_ms() < Deadline of
        true -> Result;
        false -> {error, retry}
    end;
phase_evidence_result(Result, _Deadline) -> Result.

entry_hint(Ref, Hints) when is_list(Hints) ->
    case maps:from_list(quod_dtx_endpoint:normalize_sidecar(Hints)) of
        #{Ref := Entry} -> Entry;
        _ -> none
    end;
entry_hint(_Ref, _Hints) ->
    none.

applied_wave_io(Commands, Context) ->
    case applied_wave_requests(Commands, Context, []) of
        {ok, Prepared} ->
            verify_prepared_applied(Prepared, Context);
        {error, Reason} ->
            {error, Reason}
    end.

verify_prepared_applied(Prepared, Context) ->
    Requests = [Request || {ready, Request} <- Prepared],
    case Requests of
        [] ->
            {ok, [retry || _ <- Prepared]};
        [_ | _] ->
            case quod_dtx_current_view:certify_applied_many(
                   maps:get(owner_ns, Context), Requests,
                   maps:get(request_deadline, Context)) of
                {ok, Results} ->
                    expand_applied_results(Prepared, Results, []);
                {error, _} = Error ->
                    Error
            end
    end.

expand_applied_results([], [], Acc) ->
    {ok, lists:reverse(Acc)};
expand_applied_results([retry | Rest], Results, Acc) ->
    expand_applied_results(Rest, Results, [retry | Acc]);
expand_applied_results([{ready, _Request} | Rest], [Result | Results], Acc) ->
    expand_applied_results(Rest, Results, [Result | Acc]);
expand_applied_results(_Prepared, _Results, _Acc) ->
    {error, invalid_request}.

record_validation_sidecar(Record, PhaseEntries, Applied) ->
    case quod_foreign_log:required_references(Record) of
        {ok, References} ->
            Certificates =
                [{{applied, Target, Ref}, Certificate}
                 || {Target, Ref, _Generation} <- complete_rows(Record),
                    {ok, Certificate} <-
                        [applied_certificate(Target, Ref, Applied)]],
            Entries =
                [{Ref, Entry}
                 || {_Phase, Ref} <- References,
                    {ok, Entry} <- [maps:find(Ref, PhaseEntries)]],
            quod_dtx_endpoint:normalize_sidecar(Certificates ++ Entries);
        {error, _} ->
            []
    end.

complete_rows({quod_dtx_complete, 3, _GroupId, _DecisionRef, Rows}) -> Rows;
complete_rows(_Record) -> [].

applied_certificate(Target, Ref, Applied) ->
    case lists:keyfind(Target, 1, Applied) of
        {Target, Certificate} ->
            case quod_dtx_current_view:applied_certificate_binding(
                   Certificate) of
                {ok, #{target := Target, finalize_ref := Ref}} ->
                    {ok, Certificate};
                _ -> error
            end;
        false -> error
    end.

applied_wave_requests([], _S, Acc) ->
    {ok, lists:reverse(Acc)};
applied_wave_requests(
  [{applied, Target, GroupId, FinalizeRef, Generation, Verdict} | Rest],
  #{finalize_evidence := FinalizeEvidence} = Context, Acc) ->
    case maps:get(Target, FinalizeEvidence, undefined) of
        {FinalizeRef, Evidence} ->
            HistoricalRoutes = maps:get(routes, Evidence, #{}),
            case applied_source(Target, FinalizeRef, HistoricalRoutes) of
                {ok, Source} ->
                    Claim = #{target => Target, group_id => GroupId,
                              finalize_ref => FinalizeRef,
                              generation => Generation, verdict => Verdict},
                    applied_wave_requests(
                      Rest, Context,
                      [{ready, {Source, Claim, Evidence}} | Acc]);
                {error, retry} ->
                    applied_wave_requests(Rest, Context, [retry | Acc])
            end;
        undefined ->
            {error, missing_finalize_evidence};
        _Conflicting ->
            {error, conflicting_finalize_evidence}
    end.

install_applied_wave(Commands, Views, S) when length(Commands) =:= length(Views) ->
    install_applied_wave(Commands, Views, S, [], [], false);
install_applied_wave(_Commands, _Views, S) ->
    {fatal, invalid_applied_claim, S}.

install_applied_wave([], [], S, Targets, Waiting, Progress) ->
    {ok, S, lists:reverse(Targets), lists:reverse(Waiting), Progress};
install_applied_wave(
  [{applied, Target, GroupId, FinalizeRef, Generation, Verdict} | Commands],
  [{verified, Certificate} | Views],
  S0, Targets, Waiting, Progress0) ->
    case quod_dtx_current_view:applied_certificate_binding(Certificate) of
        {ok, #{target := Target, group_id := GroupId,
               finalize_ref := FinalizeRef, generation := Generation,
               verdict := Verdict}} ->
            case put_applied({Target, Certificate}, S0) of
                {progress, S1, _} ->
                    install_applied_wave(
                      Commands, Views, S1, [Target | Targets], Waiting, true);
                {retry, S1} ->
                    install_applied_wave(
                      Commands, Views, S1, [Target | Targets], Waiting,
                      Progress0);
                {fatal, Reason, S1} ->
                    {fatal, Reason, S1}
            end;
        _ ->
            {fatal, invalid_applied_claim, S0}
    end;
install_applied_wave(
  [Command | Commands], [retry | Views], S,
  Targets, Waiting, Progress) ->
    install_applied_wave(
      Commands, Views, S, Targets, [Command | Waiting], Progress);
install_applied_wave(_Commands, _Views, S, _Targets, _Waiting, _Progress) ->
    {fatal, invalid_applied_claim, S}.

terminate_expected(Reason, S) ->
    observe_coordinator_close(failed),
    notify(S, {error, Reason}),
    close_coordinator(failed, S),
    stop.

notify(#state{owner = Owner, group_id = GroupId}, Event) ->
    Owner ! {dtx_coordinator, self(), GroupId, Event},
    ?TEST_PHASE_BARRIER(Owner, GroupId, Event),
    ok.

-ifdef(TEST).
%% Deterministic crash injection for full-stack tests.  Configure
%% `{dtx_test_phase_barrier, {hold, Phase}}`; after the exact phase is
%% certified, the coordinator records the held phase in the application env
%% and pauses before planning the next phase.  The CT polls that state over its
%% existing peer RPC channel, rather than relying on a one-way message from a
%% peer into the CT controller.  Monitoring Owner plus a hard bound prevents a
%% failed test from stranding recovery.  This remains generic over every
%% progress phase instead of encoding a Decision-specific protocol branch.
test_phase_barrier(Owner, GroupId, {done, _CompleteRef}) ->
    test_phase_barrier(Owner, GroupId, {progress, done});
test_phase_barrier(Owner, GroupId, {terminal, _Terminal}) ->
    test_phase_barrier(Owner, GroupId, {progress, terminal});
test_phase_barrier(Owner, GroupId, {progress, Phase}) ->
    case application:get_env(quod, dtx_test_phase_barrier) of
        {ok, {hold, Phase}} ->
            BarrierRef = make_ref(),
            OwnerMonitor = erlang:monitor(process, Owner),
            ok = application:set_env(
                   quod, dtx_test_phase_barrier,
                   {held, GroupId, Phase, BarrierRef}),
            receive
                {quod_dtx_test_release, BarrierRef} -> ok;
                {'DOWN', OwnerMonitor, process, Owner, _} -> ok
            after 10000 ->
                ok
            end,
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            ok;
        _ ->
            ok
    end;
test_phase_barrier(_Owner, _GroupId, _Event) ->
    ok.
-endif.

queue_drive() ->
    self() ! {drive, erlang:monotonic_time()},
    ok.

request_progress_drive(S = #state{wave = #wave{ref = Ref}}) when is_reference(Ref) ->
    S#state{progress_pending = true};
request_progress_drive(S = #state{progress_pending = true}) ->
    S;
request_progress_drive(S) ->
    queue_drive(),
    S#state{progress_pending = true}.

release_progress_drive(S = #state{progress_pending = true}) ->
    queue_drive(),
    S;
release_progress_drive(S) ->
    S.

enter_stage(Stage, S = #state{stage = Stage}) ->
    S;
enter_stage(Stage, S) ->
    close_active_stage(ok, S),
    _ = quod_trace:add_event(
          quod_trace:context(), <<"dtx.stage">>,
          #{'quod.dtx.group_id' => quod_trace:tx_id(S#state.group_id),
            'quod.dtx.stage' => atom_to_binary(Stage, utf8)}),
    S#state{stage = Stage,
            stage_started_native = erlang:monotonic_time()}.

close_active_stage(_Result, #state{stage = none}) ->
    ok;
close_active_stage(Result,
                   S = #state{stage = Stage,
                              stage_started_native = StartedNative}) ->
    observe_stage(S, Stage, Result, StartedNative).

close_coordinator(Result,
                  S = #state{total_started_native = StartedNative}) ->
    stop_active_wave(S#state.wave),
    close_active_stage(Result, S),
    observe_stage(S, coordinator_total, Result, StartedNative),
    maps:foreach(
      fun(_Identity, FollowRef) ->
              _ = catch close_follow(FollowRef)
      end, S#state.follows),
    case S#state.foreign_log_monitor of
        none -> ok;
        Monitor ->
            _ = catch quod_reg:demonitor_name(
                        {foreign_log, node}, Monitor),
            ok
    end,
    ok.

%% A bounded close decision, not completed cleanup or a child-duration end.
%% All notifying branches emit it before sending their final owner event, so
%% the owner's subsequent event append cannot overlap this child's append.
observe_coordinator_close(Result) ->
    _ = catch quod_trace:add_event(
          quod_trace:context(), <<"dtx.coordinator.close_observed">>,
          #{'quod.dtx.result' => atom_to_binary(Result, utf8)}),
    ok.

stop_active_wave(none) -> ok;
stop_active_wave(#wave{} = Wave) ->
    stop_wave_workers(Wave),
    finish_wave_trace(Wave, cancelled).

finish_wave_trace(#wave{trace_span = undefined}, _Result) ->
    ok;
finish_wave_trace(#wave{trace_span = SpanCtx}, ok) ->
    quod_trace:finish_span(SpanCtx, ok);
finish_wave_trace(#wave{trace_span = SpanCtx}, Result) ->
    quod_trace:finish_span(SpanCtx, {error, Result}).

observe_stage(#state{protocol = group, owner_ns = Ns}, Stage, Result, StartedNative)
  when is_integer(StartedNative) ->
    quod_metrics:observe_dtx_group_stage(
      Ns, Stage, Result, erlang:monotonic_time() - StartedNative);
observe_stage(_S, _Stage, _Result, _StartedNative) ->
    ok.

observe_endpoint_stage(Context, Stage, Result, StartedNative)
  when is_integer(StartedNative) ->
    quod_metrics:observe_dtx_group_stage(
      maps:get(owner_ns, Context), Stage, Result,
      erlang:monotonic_time() - StartedNative).

context_timeout(#{request_deadline := Deadline}) ->
    max(0, Deadline - quod_time:mono_ms()).

%% ------------------------------------------------------------------
%% One bounded planner command
%% ------------------------------------------------------------------


record_stage('begin') -> 'begin';
record_stage(prepare) -> prepare_wave;
record_stage(decision) -> decision;
record_stage(finalize) -> finalize_wave;
record_stage(complete) -> complete.


wait_for_progress(Target, S0 = #state{origin = Origin}) ->
    case progress_source(Target, Origin) of
        owner ->
            %% The owning Simplex supplies source progress directly. Following
            %% our own ledger as foreign history would only replay certified
            %% state the owner already has.
            S0;
        foreign ->
            wait_for_foreign_progress(Target, S0)
    end.

wait_for_foreign_progress(Target, S0) ->
    S = ensure_foreign_log_monitor(
          ensure_route_subscription(Target, S0)),
    attach_follow(Target, S).

progress_source(Target, Target) -> owner;
progress_source(_Target, _Origin) -> foreign.

%% Both operation and group recovery consume the same follower contract.
%% Building/unreachable are status, not progress. In particular a new follow
%% emits building immediately: treating it as a retry can manufacture a loop
%% without any network or ledger change.
foreign_progress_notice({advanced, _, _, _, _, _, _}) -> true;
foreign_progress_notice({resnapshot, _, _, _}) -> true;
foreign_progress_notice(_) -> false.

local_progress_event({local_dtx_progress, Owner, Identity, Slot, Ready}, Identity)
  when is_pid(Owner), is_integer(Slot), Slot >= 0, is_boolean(Ready) ->
    true;
local_progress_event(_Message, _OwnerNs) ->
    false.

ensure_foreign_log_monitor(
  S = #state{foreign_log_monitor = Monitor}) when is_reference(Monitor) ->
    S;
ensure_foreign_log_monitor(S) ->
    Monitor = quod_reg:monitor_name({foreign_log, node}, follow),
    S#state{foreign_log_monitor = Monitor}.

attach_follow(Target, S = #state{follows = Follows}) ->
    case maps:get(Target, Follows, undefined) of
        FollowRef when is_reference(FollowRef) ->
            S;
        {pending, _} -> S;
        undefined ->
            case quod_foreign_log:follow_request(Target) of
                {ok, RequestId} ->
                    S#state{follows = Follows#{Target => {pending, RequestId}}};
                {error, _} ->
                    S
            end
    end.

ensure_route_subscription(
  Identity, S = #state{route_subscriptions = Subscriptions}) ->
    case maps:is_key(Identity, Subscriptions) of
        true -> S;
        false ->
            true = quod_reg:subscribe({directory_route, Identity}),
            ok = quod_directory:route_needed(Identity),
            S#state{route_subscriptions = Subscriptions#{Identity => true}}
    end.

route_progress_follow(_Identity, S = #state{protocol = {dormant, _}}) -> S;
route_progress_follow(Identity, S) -> attach_follow(Identity, S).

%% The foreign verifier's registration is not a new source projection or
%% target verdict. Reattach operation follows and await their actual progress.
registration_progress(S = #state{protocol = {operation, _}}) -> S;
registration_progress(S) -> request_progress_drive(S).

%% Releasing never-activated private custody is not proof execution. It must
%% remain possible while that source's projection is rebuilding.
execution_capability(#state{protocol = {dormant, _}}, _Ready) -> true;
execution_capability(_S, Ready) -> Ready.

drop_route_subscription(Identity, S = #state{route_subscriptions = Subscriptions}) ->
    true = quod_reg:unsubscribe({directory_route, Identity}),
    S#state{route_subscriptions = maps:remove(Identity, Subscriptions)}.

wait_for_command_progress({submit, Target, _Record}, S) ->
    wait_for_progress(Target, S);
wait_for_command_progress({phase, Target, _GroupId, _Kind}, S) ->
    wait_for_progress(Target, S);
wait_for_command_progress(
  {applied, Target, _GroupId, _Ref, _Generation, _Verdict}, S) ->
    wait_for_progress(Target, S).

wait_for_commands_progress(Commands, S) ->
    lists:foldl(
      fun(Command, Acc) -> wait_for_command_progress(Command, Acc) end,
      S, Commands).


install_phase_evidence(Target, GroupId, Kind, Ref, Evidence, S) ->
    case valid_phase_evidence(Target, GroupId, Kind, Ref, Evidence) of
        {ok, Control, Generation, VerifiedEvidence, Entry} ->
            S0 = put_phase_entry(Ref, Entry, S),
            case put_evidence({Target, Control, Ref}, S0) of
                {progress, S1} ->
                    install_phase_metadata(
                      Target, Kind, Control, Generation, Ref,
                      VerifiedEvidence, new, S1);
                {same, S1} ->
                    install_phase_metadata(
                      Target, Kind, Control, Generation, Ref,
                      VerifiedEvidence, known, S1);
                {error, Reason} ->
                    {fatal, Reason, S0}
            end;
        error ->
            {fatal, invalid_verified_phase_evidence, S}
    end.

valid_phase_evidence(Target, GroupId, Kind, Ref, Evidence)
  when is_map(Evidence) ->
    %% Evidence is constructed by our local or foreign-log verifier.  Keep
    %% its structural contract loud: a missing field is an implementation
    %% defect, not hostile peer evidence.  Only the signed record/ref decode
    %% below consumes peer-derived bytes and is deliberately classified.
    Target = maps:get(identity, Evidence),
    Kind = maps:get(phase, Evidence),
    Control = maps:get(control, Evidence),
    Ref = maps:get(ref, Evidence, Ref),
    Generation = maps:get(generation, Evidence),
    Committee = maps:get(committee, Evidence),
    CommitteeId = maps:get(committee_id, Evidence),
    Routes = maps:get(routes, Evidence),
    Entry = maps:get(entry, Evidence),
    true = valid_generation(Generation),
    true = valid_committee(Committee),
    true = valid_validator_routes(Routes, Committee),
    true = is_binary(CommitteeId) andalso byte_size(CommitteeId) =:= 32,
    case signed_phase_binding(Target, GroupId, Kind, Ref, Control) of
        ok ->
            %% The evidence owner already verified Ref's finality proof.  This
            %% replica may retain another valid quorum subset for the same
            %% entry, so bind the immutable claim rather than proof bytes.
            case quod_dtx:certified_entry_ref(Target, Entry, Control) of
                {ok, EntryRef} ->
                    case quod_dtx:same_certified_ref(EntryRef, Ref) of
                        true ->
                            {ok, Control, Generation,
                             #{identity => Target, phase => Kind,
                               control => Control, ref => Ref,
                               generation => Generation, entry => Entry,
                               committee => Committee,
                               committee_id => CommitteeId, routes => Routes},
                             Entry};
                        false ->
                            error
                    end;
                {error, _} ->
                    error
            end;
        error ->
            error
    end;
valid_phase_evidence(_Target, _GroupId, _Kind, _Ref, _Evidence) ->
    error.

put_phase_entry(Ref, Entry,
                S = #state{phase_entries = Entries}) ->
    #entry{} = quod_ledger:entry_view(Entry),
    case maps:get(Ref, Entries, undefined) of
        undefined -> S#state{phase_entries = Entries#{Ref => Entry}};
        Entry -> S;
        _Conflicting -> error(conflicting_phase_entry)
    end.

signed_phase_binding(Target, GroupId, Kind, Ref, Control) ->
    try
        true = quod_dtx:verify_control(Target, Control),
        true = quod_dtx:control_kind(Control) =:= Kind,
        true = quod_dtx:group_id(Control) =:= GroupId,
        {ok, Target, _Slot, Digest} = quod_dtx:certified_ref_binding(Ref),
        true = Digest =:= quod_dtx:record_digest(Control),
        ok
    catch
        _:_ -> error
    end.

install_phase_metadata(Target, 'begin', _Control, _CurrentGeneration,
                       _Ref, _VerifiedEvidence, Freshness,
                       S = #state{begin_record = Begin}) ->
    %% A reference verifier reports the target's current projection
    %% generation. After Decision that is newer than the generation at which
    %% Begin prepared the source plan, so it is not recovery evidence. The
    %% immutable signed plan carried by Begin owns that exact base generation,
    %% just as it does in the consensus reducer's install_prepared/8 path.
    case phase_prepared_generation('begin', Begin, Target) of
        {ok, PreparedGeneration} ->
            install_phase_generation(
              Target, PreparedGeneration, Freshness, begun, S);
        not_found ->
            {progress, S, begun};
        error ->
            {fatal, invalid_begin, S}
    end;
install_phase_metadata(Target, prepare, Control, _CurrentGeneration,
                       _Ref, _VerifiedEvidence, Freshness, S0) ->
    S = clear_refusal(Target, S0),
    case phase_prepared_generation(prepare, Control, Target) of
        {ok, PreparedGeneration} ->
            install_phase_generation(
              Target, PreparedGeneration, Freshness, {prepared, Target}, S);
        error ->
            {fatal, invalid_prepare, S}
    end;
install_phase_metadata(Target, finalize, _Control, _Generation,
                       Ref, VerifiedEvidence, _Freshness,
                       S = #state{finalize_evidence = FinalizeEvidence}) ->
    case maps:get(Target, FinalizeEvidence, undefined) of
        undefined ->
            {progress, S#state{finalize_evidence =
                                  FinalizeEvidence#{
                                    Target => {Ref, VerifiedEvidence}}},
             {finalized, Target}};
        {Ref, VerifiedEvidence} ->
            {progress, S, {finalized, Target}};
        _Conflicting ->
            {fatal, conflicting_finalize_evidence, S}
    end;
install_phase_metadata(_Target, decision, _Control, _Generation, _Ref,
                       _VerifiedEvidence,
                       _Freshness, S) ->
    %% A certified Decision already carries the exact abort reason stack.
    %% The pre-Decision refusal was only volatile construction input; retaining
    %% it would wrongly pin the target's unsigned generation hint forever.
    {progress, clear_refusal(S), decided};
install_phase_metadata(Target, Kind, _Control, _Generation,
                       _Ref, _VerifiedEvidence, _Freshness, S) ->
    {progress, S, phase_progress(Kind, Target)}.

install_phase_generation(Target, Generation, Freshness, Phase, S) ->
    Result = case Freshness of
                 new -> put_verified_generation(Target, Generation, S);
                 known -> put_generation(Target, Generation, S)
             end,
    case Result of
        {progress, S1, _} -> {progress, S1, Phase};
        {retry, S1} -> {progress, S1, Phase};
        {fatal, Reason, S1} -> {fatal, Reason, S1}
    end.

phase_prepared_generation('begin', Begin, Target) ->
    case quod_dtx:begin_participant_payload(Begin, Target) of
        {ok, _Manifest, _PlanDigest, PlanBlob} ->
            decode_plan_generation(PlanBlob);
        not_found ->
            not_found;
        error ->
            error
    end;
phase_prepared_generation(prepare, Control, Target) ->
    case {quod_dtx:control_target(Control) =:= Target,
          quod_dtx:prepare_payload(Control)} of
        {true, {ok, _Manifest, _PlanDigest, PlanBlob}} ->
            decode_plan_generation(PlanBlob);
        _ ->
            error
    end.

decode_plan_generation(PlanBlob) ->
    case quod_dtx:decode(PlanBlob) of
        {ok, Plan} -> {ok, quod_dtx:overlay_generation(Plan)};
        {error, _} -> error
    end.

phase_progress('begin', _Target) -> begun;
phase_progress(complete, _Target) -> completed.

applied_source({Ns, _Anchor} = Target, FinalizeRef, HistoricalRoutes) ->
    case cohosted(Target) of
        true ->
            case quod_simplex:dtx_applied_source(Ns, FinalizeRef) of
                {ok, {local, _View} = Source} -> {ok, Source};
                {error, _} -> {error, retry}
            end;
        false ->
            Historical =
                [{PeerKey, [Endpoint]}
                 || {PeerKey, Endpoint} <- maps:to_list(HistoricalRoutes),
                    quod_quic:valid_endpoint(Endpoint)],
            case quod_foreign_log:route_hints(Target, Historical) of
                {ok, [_ | _] = Hints} -> {ok, {remote, Hints}};
                {error, _} -> {error, retry}
            end
    end.

%% ------------------------------------------------------------------
%% Endpoint selection
%% ------------------------------------------------------------------


submit_reply({ok, Response, Source}) -> {reply, Response, Source}.

local_submit_result(
  Request, {ok, Response, {reply_source, local, _Hints}}) ->
    case endpoint_retryable(Response, Request) of
        true -> uncertain;
        false -> terminal
    end;
local_submit_result(_Request, {error, _}) ->
    uncertain.

-ifdef(TEST).
test_local_submit_result(Request, Result) ->
    local_submit_result(Request, Result).
-endif.

endpoint_request(Source, Target, Request, ValidationSidecar, S) ->
    StartedNative = erlang:monotonic_time(),
    Result = case context_timeout(S) of
        0 -> {error, timeout};
        _ -> endpoint_request_raw(Source, Target, Request, ValidationSidecar, S)
    end,
    observe_endpoint_stage(
      S, endpoint_wait, endpoint_result(Result), StartedNative),
    Result.

endpoint_request_raw(local, {Ns, _Anchor}, Request, ValidationSidecar,
                     Context) ->
    case quod_simplex:dtx_endpoint_local(
           Ns, Request, ValidationSidecar, context_timeout(Context)) of
        {ok, Response, ResponseHints} ->
            {ok, Response, {reply_source, local, ResponseHints}};
        {error, _} = Error -> Error
    end;
endpoint_request_raw({remote, PeerKey, Endpoints}, Target, Request,
                     ValidationSidecar, Context) ->
    {TargetNs, _Anchor} = Target,
    OwnerNs = maps:get(owner_ns, Context),
    Deadline = maps:get(request_deadline, Context),
    RequestFun =
        fun(Endpoint, CandidateRequest, Timeout) ->
            quod_simplex:dtx_endpoint_request(
              OwnerNs, TargetNs, PeerKey, Endpoint, CandidateRequest,
              ValidationSidecar, Timeout)
        end,
    endpoint_request_candidates(
      Endpoints, PeerKey, Request, Deadline, undefined, RequestFun).


endpoint_result({ok, _Response, _Source}) -> ok;
endpoint_result({error, _}) -> uncertain.

endpoint_request_candidates([], _PeerKey, _Request, _Deadline,
                            undefined, _RequestFun) ->
    {error, not_ready};
endpoint_request_candidates([], _PeerKey, _Request, _Deadline,
                            Last, _RequestFun) ->
    Last;
endpoint_request_candidates([Endpoint | Rest], PeerKey, Request,
                            Deadline, Last, RequestFun) ->
    case max(0, Deadline - quod_time:mono_ms()) of
        0 ->
            case Last of undefined -> {error, timeout}; _ -> Last end;
        Timeout ->
            AttemptTimeout = max(1, Timeout div (length(Rest) + 1)),
            Result = RequestFun(Endpoint, Request, AttemptTimeout),
            case Result of
                {ok, Response, ResponseHints} ->
                    Candidate = {ok, Response,
                                 {reply_source, remote, PeerKey,
                                  ResponseHints}},
                    case endpoint_candidate_terminal(Request, Response) of
                        true -> Candidate;
                        false -> endpoint_request_candidates(
                                   Rest, PeerKey, Request, Deadline,
                                   preferred_candidate_result(
                                     Request, Candidate, Last),
                                   RequestFun)
                    end;
                {error, _} ->
                    endpoint_request_candidates(
                      Rest, PeerKey, Request, Deadline,
                      preferred_candidate_result(Request, Result, Last),
                      RequestFun)
            end
    end.

endpoint_candidate_terminal(Request, Response) ->
    quod_dtx_endpoint:correlates(Request, Response) andalso
        case Response of
            {accepted, _, _, _} -> true;
            {refused, _, _, _, _, _} -> true;
            {phase, _, _, _} -> true;
            {error, _, invalid_request} -> true;
            _ -> false
        end.

preferred_candidate_result(_Request, Candidate, undefined) ->
    Candidate;
preferred_candidate_result(Request, Candidate, Current) ->
    case candidate_result_rank(Request, Candidate) >
         candidate_result_rank(Request, Current) of
        true -> Candidate;
        false -> Current
    end.

candidate_result_rank(Request, {ok, Response, _Source}) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> 3;
        false -> 1
    end;
candidate_result_rank(_Request, {error, timeout}) ->
    2;
candidate_result_rank(_Request, _Result) ->
    1.

endpoint_sources(Target) ->
    Cohosted = cohosted(Target),
    LocalKey = case {Cohosted, application:get_env(quod, node_pubkey)} of
                   {true, {ok, <<_:256>> = Key}} -> Key;
                   _ -> none
               end,
    Remote = [{remote, PeerKey, Endpoints}
              || {PeerKey, Endpoints} <- routes(Target),
                 PeerKey =/= LocalKey],
    case Cohosted of true -> [local | Remote]; false -> Remote end.


%% Every asynchronous child is monitored for its result and independently
%% bound to its immediate owner. A direct shutdown therefore tears down the
%% whole ownership tree even when the owner is killed outside its receive
%% loop; normal completion removes the one-shot watcher automatically. The
%% transient context also crosses this boundary: otherwise submit fan-out
%% silently loses the parent before reaching the existing endpoint carrier.
spawn_owned_monitor(Owner, Fun)
  when is_pid(Owner), is_function(Fun, 0) ->
    TraceCtx = quod_trace:context(),
    spawn_monitor(
      fun() ->
          _ = quod_process:kill_when_owner_dies(Owner, self()),
          quod_trace:with_context(TraceCtx, Fun)
      end).

-ifdef(TEST).
test_submit_endpoint_requests(Sources, Request, TimeoutMs, RequestFun)
  when is_integer(TimeoutMs) ->
    test_submit_endpoint_requests(Sources, Request,
      #{deadline => quod_time:mono_ms() + TimeoutMs,
        owner => self(), ready => true}, RequestFun);
test_submit_endpoint_requests(Sources, Request,
                             #{deadline := Deadline, owner := Owner, ready := Ready},
                             RequestFun) ->
    %% This fixture enters at prepared routes, as the old transport-only
    %% control did. Actual endpoint children and the ordinary owner receive
    %% loop perform fanout, uncertainty handling and loser cleanup.
    Ref = make_ref(), ReplyRef = make_ref(),
    Target = {<<"quod:test">>, <<0:256>>},
    Plan = {Target, <<0:256>>, 'begin', Request, [], Sources},
    Wave = #wave{ref = Ref, stage = phase_command, items = [transport_fixture],
        results = #{1 => {prepared_submit, Plan}},
        context = #{owner_ns => <<"quod:test">>,
                    request_deadline => Deadline, test_request_fun => RequestFun},
        meta = #{test_result_to => {self(), ReplyRef}, request_deadline => Deadline},
        trace_context = quod_trace:context(),
        timer = erlang:send_after(max(0, Deadline - quod_time:mono_ms()),
                                  self(), {dtx_wave_timeout, Ref})},
    S = #state{owner = Owner, owner_ns = <<"quod:test">>, origin = Target,
               execution_ready = Ready,
               wave = Wave},
    continue(advance_wave(S)),
    [{ok, _, _, _, _, Outcome}] = test_wave_results(ReplyRef),
    Outcome.

test_endpoint_io(Source, Target, Request, Sidecar, Context) ->
    case maps:find(test_request_fun, Context) of
        {ok, Fun} -> Fun(Source);
        error -> endpoint_request(Source, Target, Request, Sidecar, Context)
    end.

test_finish_wave(_Stage, _Items, Results,
                 #{test_result_to := {Test, Ref}}, _S) ->
    Test ! {test_wave_results, Ref, Results}, stop;
test_finish_wave(Stage, Items, Results, Meta, S) ->
    finish_typed_wave(Stage, Items, Results, Meta, S).

test_wave_results(Ref) ->
    receive {test_wave_results, Ref, Results} -> Results
    after 1000 -> error(missing_wave_results)
    end.

test_run_wave(Stage, Items, S) ->
    Ref = make_ref(),
    {next, Started} = start_typed_wave(
        Stage, Items, #{test_result_to => {self(), Ref}},
        S#state{owner = self(), execution_ready = true}),
    loop(Started),
    test_wave_results(Ref).

test_endpoint_request_candidates(
  Endpoints, PeerKey, Request, TimeoutMs, RequestFun) ->
    endpoint_request_candidates(
      Endpoints, PeerKey, Request,
      quod_time:mono_ms() + TimeoutMs, undefined, RequestFun).

test_spawn_owned_worker(Owner, Fun) ->
    spawn_owned_monitor(Owner, Fun).

test_close_wave(Pids) when is_list(Pids) ->
    Timer = erlang:send_after(60000, self(), test_wave_timeout),
    Workers = maps:from_list(
                [{Pid, {erlang:monitor(process, Pid), Index}}
                 || {Index, Pid} <-
                        lists:zip(lists:seq(1, length(Pids)), Pids)]),
    Wave = #wave{ref = make_ref(), stage = phase_command, items = [],
                 workers = Workers, results = #{}, meta = #{}, timer = Timer,
                 started_native = erlang:monotonic_time()},
    close_coordinator(failed, #state{wave = Wave}),
    Timer.

test_worker_down_disposition(Stage, Reason) ->
    worker_down_disposition(Stage, Reason).
test_progress_source(Target, Origin) ->
    progress_source(Target, Origin).
test_pending_phase_reference(Target, GroupId, Kind, Ref, Source) ->
    S = put_pending({submission, Target, GroupId, Kind}, #state{}),
    {verify, Spec, Pinned} = classify_phase_observation(
        Target, GroupId, Kind, {committed, Ref, Source}, S),
    {Retained, [], false, true, none} = classify_verify_wave(
        [Spec], [{error, retry}], Pinned, [], false, false, none,
        quod_time:mono_ms() + 1000),
    Retained#state.pending_phases.
test_local_progress_event(Message, OwnerNs) ->
    local_progress_event(Message, OwnerNs).

test_submission_observation_transition(Target, Record, Form) ->
    Group = quod_dtx:group_id(Record), Kind = quod_dtx:record_kind(Record),
    {ok, Blob} = quod_dtx:encode_record(Record),
    Id = request_id(), Request = {submit, Id, Blob},
    Result = case Form of
        refused -> {ok, Target, Group, Kind, Request,
                    {reply, {error, Id, not_ready}, local}};
        unknown -> {ok, Target, Group, Kind, Request, outcome_unknown};
        worker_down -> {worker_down, timeout}
    end,
    Meta = #{request_deadline => quod_time:mono_ms() + 1000},
    {next, S1} = finish_phase_command_wave(
        [{submit, Target, Record}], [Result], Meta, #state{origin = Target}),
    First = receive {drive, _} -> observe after 0 -> parked end,
    %% A read that is itself unavailable parks. It cannot turn into a second
    %% observation or a write without the normal external progress edge.
    Query = {phase, request_id(), Group, Kind},
    {next, S2} = finish_phase_command_wave(
        [{phase, Target, Group, Kind, uncertain}],
        [{ok, Target, Group, Kind, Query, {unresolved, none}}], Meta, S1),
    Second = receive {drive, _} -> observe after 0 -> parked end,
    {First, Second, S2#state.pending_phases}.

test_finalize_rediscovery(OwnerNs, Target, Group, Deadline) ->
    %% Callback-state fixture, not consensus admission. The endpoint codec and
    %% historical evidence verifier remain real; origin=Target avoids an
    %% unrelated follow lease when the read-only observation must park.
    Snapshot = (quod_dtx_recovery:empty())#{generations := [{Target, 999}]},
    S = put_pending({submission, Target, Group, finalize},
                   #state{owner_ns = OwnerNs, origin = Target, snapshot = Snapshot}),
    Command = {phase, Target, Group, finalize, uncertain},
    Context = (wave_context(S))#{request_deadline => Deadline,
                                evidence_deadline => Deadline},
    Result = phase_command_io(Command, Context),
    case classify_phase_command_result(Command, Result, S) of
        {verify, Spec, S1} ->
            Evidence = phase_evidence_io(Spec, Context),
            {S2, Phases, Progress, Waiting, Fatal} = classify_verify_wave(
                [Spec], [Evidence], S1, [], false, false, none, Deadline),
            {verified, Spec, S1#state.pending_phases, S2#state.pending_phases,
             S2#state.snapshot, Phases, Progress, Waiting, Fatal};
        {Disposition, S1} -> {Disposition, S1#state.pending_phases};
        {fatal, Reason, _} -> {fatal, Reason}
    end.

test_phase_verification_deadline(Target, Group, Kind, Ref, Deadline) ->
    Command = {phase, Target, Group, Kind, uncertain},
    Query = {phase, request_id(), Group, Kind},
    S = put_pending({submission, Target, Group, Kind},
        #state{origin = Target, snapshot = quod_dtx_recovery:empty(),
               execution_ready = false}),
    {next, #state{wave = Wave, pending_phases = Pending}} =
        finish_typed_wave(phase_command, [Command],
                         [{ok, Target, Group, Kind, Query, {committed, Ref, local}}],
                         #{request_deadline => Deadline}, S),
    {Wave#wave.meta, Pending}.

test_consume_applied_wave(Command, Certificate, Deadline) ->
    {applied, Target, Group, _, _, _} = Command,
    S = #state{owner = self(), origin = Target, group_id = Group,
               snapshot = quod_dtx_recovery:empty()},
    {next, S1} = finish_typed_wave(applied, [[Command]],
                                 [{ok, [{verified, Certificate}]}],
                                 #{request_deadline => Deadline}, S),
    maps:get(applied, S1#state.snapshot).

test_state(Pid) ->
    Ref = make_ref(),
    Pid ! {test_state, self(), Ref},
    receive {Ref, State} -> State
    after 1000 -> error(coordinator_mailbox_not_responsive)
    end.

test_loop_message({test_state, From, Ref}, S) ->
    Wave = case S#state.wave of
        none -> none;
        #wave{ref = WaveRef, stage = Stage, items = Items, meta = Meta,
              workers = Workers, results = Results} ->
            #{running => is_reference(WaveRef), stage => Stage,
              items => Items, meta => Meta, workers => map_size(Workers),
              results => Results}
    end,
    View = #{execution_ready => S#state.execution_ready,
                  trace_context => quod_trace:context(),
                  snapshot => S#state.snapshot, phase_entries => S#state.phase_entries,
                  pending_phases => S#state.pending_phases, wave => Wave},
    %% Keep the existing group fixture's semantic snapshot unchanged. The
    %% coalesced-drive bit is transient scheduling, not retained proof state.
    Extended = case S#state.protocol of
        group -> View;
        Protocol -> View#{protocol => Protocol, progress_pending => S#state.progress_pending}
    end,
    From ! {Ref, Extended},
    loop(S);
test_loop_message(_Message, S) -> loop(S).
-endif.


count_submit_endpoint_result(
  Ns, terminal, {ok, {accepted, _, _, _}, _Source}) ->
    quod_metrics:count_dtx_submit_fanout(Ns, accepted, 1);
count_submit_endpoint_result(
  Ns, terminal, {ok, {refused, _, _, _, _, _}, _Source}) ->
    quod_metrics:count_dtx_submit_fanout(Ns, refused, 1);
count_submit_endpoint_result(Ns, terminal, _Result) ->
    quod_metrics:count_dtx_submit_fanout(Ns, unavailable, 1);
count_submit_endpoint_result(Ns, uncertain, _Result) ->
    quod_metrics:count_dtx_submit_fanout(Ns, uncertain, 1);
count_submit_endpoint_result(Ns, next, _Result) ->
    quod_metrics:count_dtx_submit_fanout(Ns, unavailable, 1).


classify_submit_endpoint_result(local, Request, Result) ->
    local_submit_result(Request, Result);
classify_submit_endpoint_result(
  {remote, _PeerKey, _Endpoints}, Request,
  {ok, Response, _Source}) ->
    remote_submit_result(Request, Response);
classify_submit_endpoint_result(
  {remote, _PeerKey, _Endpoints}, _Request, {error, timeout}) ->
    uncertain;
classify_submit_endpoint_result(
  {remote, _PeerKey, _Endpoints}, _Request, {error, _}) ->
    next.


remote_submit_result(
  Request, {accepted, _RequestId, _Digest, _Ref} = Response) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> terminal;
        false -> next
    end;
remote_submit_result(
  Request, {refused, _RequestId, _Target, _Digest,
            _Generation, _ReasonsBlob} = Response) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> terminal;
        false -> next
    end;
remote_submit_result(
  Request, {error, _RequestId, Reason} = Response)
  when Reason =:= busy; Reason =:= not_ready; Reason =:= not_found ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> uncertain;
        false -> next
    end;
remote_submit_result(_Request, _ErrorOrMalformed) ->
    next.

endpoint_retryable({error, _RequestId, Reason} = Response, Request)
  when Reason =:= busy; Reason =:= not_ready; Reason =:= not_found ->
    quod_dtx_endpoint:correlates(Request, Response);
endpoint_retryable(_Response, _Request) ->
    false.

cohosted({Ns, Anchor}) ->
    case quod_reg:where({quod_simplex, Ns}) of
        Pid when is_pid(Pid) -> quod_simplex:genesis_hash(Ns) =:= Anchor;
        undefined -> false
    end.

routes(Identity) ->
    case quod_foreign_log:route_hints(Identity, []) of
        {ok, Rows} ->
            Rows;
        {error, _} ->
            []
    end.

%% ------------------------------------------------------------------
%% Bounded canonical snapshot updates
%% ------------------------------------------------------------------

put_evidence(Row = {Target, Control, _Ref},
             S = #state{snapshot = Snapshot}) ->
    Kind = quod_dtx:control_kind(Control),
    Key = {phase_rank(Kind), Target},
    Rows = maps:get(evidence, Snapshot),
    case evidence_by_key(Key, Rows) of
        none ->
            Rows1 = sort_evidence([Row | Rows]),
            {progress, S#state{snapshot = Snapshot#{evidence := Rows1}}};
        Row ->
            {same, S};
        _Different ->
            {error, conflicting_phase_evidence}
    end.

evidence_by_key(_Key, []) -> none;
evidence_by_key(Key, [Row = {Target, Control, _Ref} | Rest]) ->
    case {phase_rank(quod_dtx:control_kind(Control)), Target} of
        Key -> Row;
        _ -> evidence_by_key(Key, Rest)
    end.

sort_evidence(Rows) ->
    [Row || {_Key, Row} <-
                lists:keysort(
                  1,
                  [{{phase_rank(quod_dtx:control_kind(Control)), Target}, Row}
                   || Row = {Target, Control, _Ref} <- Rows])].

phase_rank('begin') -> 1;
phase_rank(prepare) -> 2;
phase_rank(decision) -> 3;
phase_rank(finalize) -> 4;
phase_rank(complete) -> 5.

put_generation(Target, Generation,
               S = #state{snapshot = Snapshot}) ->
    case valid_generation(Generation) of
        false -> {fatal, invalid_target_generation, S};
        true ->
            Rows = maps:get(generations, Snapshot),
            case lists:keyfind(Target, 1, Rows) of
                false ->
                    Rows1 = lists:keysort(1, [{Target, Generation} | Rows]),
                    {progress,
                     S#state{snapshot = Snapshot#{generations := Rows1}},
                     {generation, Target}};
                {Target, Generation} ->
                    {retry, S};
                {Target, Previous} ->
                    update_generation_hint(
                      Target, Previous, Generation, Rows, Snapshot, S)
            end
    end.

update_generation_hint(Target, Previous, Generation, Rows, Snapshot, S)
  when Generation > Previous ->
    case has_prepare_evidence(Target, Snapshot) of
        false ->
            Rows1 = lists:keyreplace(
                      Target, 1, Rows, {Target, Generation}),
            {progress,
             S#state{snapshot = Snapshot#{generations := Rows1}},
             {generation, Target}};
        true ->
            {fatal, conflicting_target_generation, S}
    end;
update_generation_hint(_Target, _Previous, _Generation, _Rows, _Snapshot, S) ->
    %% A lower unsigned value came from a stale replica.  It is not evidence
    %% that the monotonic target generation moved backwards.
    {retry, S}.

has_prepare_evidence(Target, Snapshot) ->
    lists:any(
      fun({RowTarget, Control, _Ref}) ->
              RowTarget =:= Target andalso
                  quod_dtx:control_kind(Control) =:= prepare
      end, maps:get(evidence, Snapshot)).

%% A certified Prepare projection is authoritative; an earlier not-found or
%% refusal generation was only an availability hint.  Replacing that hint is
%% what lets an abort recover cleanly when Prepare won the target-ledger race.
put_verified_generation(Target, Generation,
                        S = #state{snapshot = Snapshot}) ->
    case valid_generation(Generation) of
        false -> {fatal, invalid_target_generation, S};
        true ->
            Rows0 = maps:get(generations, Snapshot),
            Rows1 = lists:keysort(
                      1, lists:keystore(
                           Target, 1, Rows0, {Target, Generation})),
            {progress,
             S#state{snapshot = Snapshot#{generations := Rows1}},
             {generation, Target}}
    end.

clear_refusal(S = #state{snapshot = Snapshot}) ->
    S#state{snapshot = Snapshot#{refusal := none}}.

clear_refusal(Target, S = #state{snapshot = Snapshot}) ->
    case maps:get(refusal, Snapshot) of
        {Target, _Digest, _Generation, _ReasonsBlob} ->
            S#state{snapshot = Snapshot#{refusal := none}};
        _ ->
            S
    end.

put_refusal(Target, SemanticDigest, Generation, ReasonsBlob,
            S = #state{snapshot = Snapshot}) ->
    Refusal = {Target, SemanticDigest, Generation, ReasonsBlob},
    case maps:get(refusal, Snapshot) of
        none ->
            case valid_generation(Generation) of
                true ->
                    S1 = S#state{snapshot = Snapshot#{refusal := Refusal}},
                    case put_generation(Target, Generation, S1) of
                        {progress, S2, _} ->
                            {progress, S2, {refused, Target}};
                        {retry, S2} ->
                            {progress, S2, {refused, Target}};
                        {fatal, Reason, S2} ->
                            {fatal, Reason, S2}
                    end;
                false ->
                    {fatal, invalid_target_generation, S}
            end;
        Refusal ->
            {retry, S};
        _Other ->
            %% The first canonical target refusal is sufficient to make abort
            %% safe. Later refusals cannot replace its exact reason stack.
            {retry, S}
    end.

put_applied(Row = {Target, _Certificate},
            S = #state{snapshot = Snapshot}) ->
    Rows = maps:get(applied, Snapshot),
    case lists:keyfind(Target, 1, Rows) of
        false ->
            Rows1 = lists:keysort(1, [Row | Rows]),
            {progress, S#state{snapshot = Snapshot#{applied := Rows1}},
             {applied, Target}};
        Row ->
            {retry, S};
        _Different ->
            {fatal, conflicting_applied_evidence, S}
    end.

valid_generation(G) ->
    is_integer(G) andalso G >= 0 andalso G =< ?MAX_UINT64.

valid_committee(Committee) when is_list(Committee), Committee =/= [],
                                length(Committee) =< ?MAX_VALIDATORS ->
    Committee =:= lists:usort(Committee) andalso
        lists:all(
          fun(Key) -> is_binary(Key) andalso byte_size(Key) =:= 32 end,
          Committee);
valid_committee(_) ->
    false.

valid_validator_routes(Routes, Committee)
  when is_map(Routes), map_size(Routes) =< ?MAX_VALIDATORS ->
    lists:all(fun(Key) -> lists:member(Key, Committee) end,
              maps:keys(Routes)) andalso
        maps:fold(
          fun(Key, Endpoint, Valid) ->
              Valid andalso is_binary(Key) andalso byte_size(Key) =:= 32
                  andalso quod_quic:valid_endpoint(Endpoint)
          end, true, Routes);
valid_validator_routes(_Routes, _Committee) ->
    false.

request_id() ->
    crypto:strong_rand_bytes(?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS div 8).

-ifdef(TEST).
test_options(Options) -> options(Options).
test_put_evidence(Row, Snapshot) ->
    S = #state{snapshot = Snapshot},
    case put_evidence(Row, S) of
        {progress, #state{snapshot = Snapshot1}} -> {progress, Snapshot1};
        {same, #state{snapshot = Snapshot1}} -> {same, Snapshot1};
        {error, Reason} -> {error, Reason}
    end.
test_put_generation(Target, Generation, Snapshot) ->
    S = #state{snapshot = Snapshot},
    case put_generation(Target, Generation, S) of
        {progress, #state{snapshot = Snapshot1}, _} ->
            {progress, Snapshot1};
        {retry, #state{snapshot = Snapshot1}} ->
            {same, Snapshot1};
        {fatal, Reason, _} -> {error, Reason}
    end.
test_install_applied_results(Commands, Results, Snapshot) ->
    case install_applied_wave(
           Commands, Results, #state{snapshot = Snapshot}) of
        {ok, #state{snapshot = Snapshot1}, Targets, Waiting, Progress} ->
            {ok, Snapshot1, Targets, Waiting, Progress};
        {fatal, Reason, _} ->
            {error, Reason}
    end.
test_valid_validator_routes(Routes, Committee) ->
    valid_validator_routes(Routes, Committee).
test_valid_phase_evidence(Target, GroupId, Kind, Ref, Evidence) ->
    valid_phase_evidence(Target, GroupId, Kind, Ref, Evidence).
%% Exercise actual endpoint fanout/selection and the consuming evidence paths.
%% The fixture supplies encoded replies and certified history, never a verifier answer.
test_submit_phase_evidence(Mode, {submit, Target, _} = Command, OwnerNs, Timeout) ->
    S = #state{owner_ns = OwnerNs, snapshot = quod_dtx_recovery:empty(),
               config = #config{request_timeout_ms = Timeout}},
    [{ok, Target, GroupId, Kind, _Request,
      {reply, {accepted, _, _, Ref}, Source}}] =
        test_run_wave(phase_command, [Command], S),
    {Source, test_phase_reply_evidence(
               Mode, OwnerNs, Target, GroupId, Kind, Ref, Source, Timeout)}.

test_phase_reply_evidence(Mode, OwnerNs, Target, GroupId, Kind, Ref, Source, Timeout) ->
    S = #state{owner_ns = OwnerNs, execution_ready = true,
               snapshot = quod_dtx_recovery:empty(),
               config = #config{request_timeout_ms = Timeout}},
    %% These labels name the historical ingress fixtures. All three now use
    %% the same production evidence stage; there is no synchronous executor.
    WaveMode = case Mode of
        accepted -> wave;
        observed ->
            RequestId = request_id(),
            {committed, Ref, Source} = phase_response(
                {phase, RequestId, GroupId, Kind},
                {ok, {phase, RequestId, 0, {committed, Ref}}, Source}),
            wave;
        Other -> Other
    end,
    begin
            Spec = {Target, GroupId, Kind, Ref, Source},
            {next, #state{wave = #wave{ref = WaveRef, meta = Meta} = Wave}} =
                start_typed_wave(phase_verify, [Spec], #{}, S),
            Deadline = maps:get(evidence_deadline, Meta),
            try
                receive
                    {dtx_wave_result, WaveRef, _Worker, 1, Result} ->
                        case WaveMode of
                            {queued_wave, Test} ->
                                Test ! {evidence_queued, self(), Deadline, Result},
                                receive consume_evidence -> ok end;
                            wave -> ok
                        end,
                        case classify_verify_wave(
                               [Spec], [Result], S, [], false, false, none, Deadline) of
                            {#state{snapshot = Snapshot}, _, true, false, none} ->
                                {ok, Snapshot};
                            {_, _, false, true, none} -> retry;
                            {_, _, _, _, Reason} -> {error, Reason}
                        end
                after 5000 -> error(evidence_wave_stalled)
                end
            after stop_active_wave(Wave)
            end
    end.

test_observe_phase_evidence(Mode, OwnerNs, Target, GroupId, Kind, Timeout) ->
    S = #state{owner_ns = OwnerNs, snapshot = quod_dtx_recovery:empty(),
               config = #config{request_timeout_ms = Timeout}},
    {ok, Target, GroupId, Kind, _Request, Observation} =
        phase_query_io(Mode, Target, GroupId, Kind,
            (wave_context(S))#{request_deadline => quod_time:mono_ms() + Timeout}),
    case install_phase_observation(Target, Observation, S) of
        {verify, Ref, Source, _} ->
            test_phase_reply_evidence(wave, OwnerNs, Target, GroupId, Kind,
                                      Ref, Source, Timeout);
        Result -> test_phase_evidence_result(Result)
    end.

test_phase_evidence_result({progress, #state{snapshot = Snapshot}, _Phase}) ->
    {ok, Snapshot};
test_phase_evidence_result({retry, _S}) -> retry;
test_phase_evidence_result({absent, _S}) -> absent;
test_phase_evidence_result({fatal, Reason, _S}) -> {error, Reason}.

test_initial_commands(Ns, Begin, BeginRef, Evidence) ->
    case initial_state(self(), Ns, Begin, {BeginRef, Evidence}, #{}) of
        {ok, #state{snapshot = Snapshot}} ->
            quod_dtx_recovery:next(Begin, Snapshot);
        {error, _} = Error ->
            Error
    end.
test_initial_snapshot(Ns, Begin, BeginRef, Evidence) ->
    case initial_state(self(), Ns, Begin, {BeginRef, Evidence}, #{}) of
        {ok, #state{snapshot = Snapshot}} -> {ok, Snapshot};
        {error, _} = Error -> Error
    end.
test_install_phase_snapshot(
  Ns, Begin, BeginRef, BeginEvidence,
  Target, GroupId, Kind, Ref, Evidence) ->
    case initial_state(self(), Ns, Begin, {BeginRef, BeginEvidence}, #{}) of
        {ok, S0} ->
            case install_phase_evidence(
                   Target, GroupId, Kind, Ref, Evidence, S0) of
                {progress, #state{snapshot = Snapshot}, _} -> {ok, Snapshot};
                {retry, #state{snapshot = Snapshot}} -> {ok, Snapshot};
                {fatal, Reason, _} -> {error, Reason}
            end;
        {error, _} = Error -> Error
    end.
test_dormant_cancel_disposition(Request, Response) ->
    dormant_cancel_disposition(Request, Response).
test_dormant_cancel_request(RequestId, Target, SubmissionBlob) ->
    dormant_cancel_request(RequestId, Target, SubmissionBlob).
test_remote_submit_result(Request, Response) ->
    remote_submit_result(Request, Response).
-endif.
