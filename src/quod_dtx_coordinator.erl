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
coordinator.
""".

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([start_monitor/5, start_operation_monitor/5,
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
         test_dormant_wait_event/4,
         test_dormant_cancel_request/2,
         test_operation_target_response_disposition/2,
         test_local_submit_result/2, test_remote_submit_result/2,
         test_submit_endpoint_requests/4,
         test_endpoint_request_candidates/5,
         test_spawn_owned_worker/2, test_close_wave/1,
         test_worker_down_disposition/2]).
-endif.

-define(DEFAULT_REQUEST_TIMEOUT_MS, 5000).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).

%% A Common Test may stop the coordinator at an exact certified phase.  The
%% production build expands this to `ok`: no hook lookup, message, state, or
%% exported test API exists outside the TEST profile.
-ifdef(TEST).
-define(TEST_PHASE_BARRIER(Owner, GroupId, Event),
        test_phase_barrier(Owner, GroupId, Event)).
-else.
-define(TEST_PHASE_BARRIER(_Owner, _GroupId, _Event), ok).
-endif.

-record(config, {
    request_timeout_ms = ?DEFAULT_REQUEST_TIMEOUT_MS :: pos_integer()
}).

-record(wave, {
    ref :: reference(),
    stage :: phase_command | phase_verify | applied,
    items :: [term()],
    workers = #{} ::
      #{pid() => {reference(), non_neg_integer()}},
    results = #{} :: #{non_neg_integer() => term()},
    meta = #{} :: map(),
    timer :: reference(),
    started_native :: integer(),
    trace_span = undefined :: undefined | quod_trace:span_ctx()
}).

-record(state, {
    owner :: pid(),
    owner_monitor = undefined :: undefined | reference(),
    owner_ns :: binary(),
    origin :: {binary(), <<_:256>>},
    group_id :: <<_:256>>,
    begin_record :: quod_dtx:control_record(),
    snapshot :: quod_dtx_recovery:snapshot(),
    %% Exact entries retained only after the shared local/foreign evidence
    %% verifier accepted their certified references.  They are acceleration
    %% material for the next semantic phase, never a second source of truth.
    phase_entries = #{} :: #{quod_dtx:certified_ref() => #entry{}},
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
    follows = #{} :: #{{binary(), <<_:256>>} => reference()},
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
            {Pid, Monitor} = spawn_monitor(fun() -> init(Initial) end),
            {ok, Pid, Monitor};
        {error, _} = Error ->
            Error
    end;
start_monitor(_Owner, _OwnerNs, _Begin, _BeginEvidence, _Options) ->
    {error, invalid_coordinator_start}.

-doc """
Start recovery for one already-committed one-target foreign claim.

The worker owns no durable state.  It reconstructs the exact target
transaction from certified local claim evidence, submits that deterministic
transaction through the shared endpoint owner, and appends the deterministic
completion receipt.  Temporary target unavailability is driven by the shared
foreign-history follower's messages; source progress is supplied by the
owning Simplex.  No retry polling loop is created here.
""".
-spec start_operation_monitor(pid(), binary(), pos_integer(), term(), map()) ->
          {ok, pid(), reference()} | {error, term()}.
start_operation_monitor(Owner, OwnerNs, ClaimSlot, OperationRef, Options)
  when is_pid(Owner), Owner =:= self(),
       is_binary(OwnerNs), byte_size(OwnerNs) > 0,
       is_integer(ClaimSlot), ClaimSlot > 0,
       is_map(Options), map_size(Options) =:= 0 ->
    case valid_operation_ref(OwnerNs, OperationRef) of
        true ->
            {Pid, Monitor} = spawn_monitor(
                               fun() ->
                                   operation_init(
                                     Owner, OwnerNs, ClaimSlot,
                                     OperationRef)
                               end),
            {ok, Pid, Monitor};
        false ->
            {error, invalid_operation_start}
    end;
start_operation_monitor(_Owner, _OwnerNs, _ClaimSlot, _OperationRef,
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
    case quod_transaction:encode_operation_submission(Submission) of
        {ok, SubmissionBlob} ->
            dormant_operation_binding(
              OwnerNs, SubmissionBlob,
              quod_transaction:decode_operation_submission(SubmissionBlob));
        {error, _} ->
            {error, invalid_operation_claim}
    end.

dormant_operation_binding(
  OwnerNs, SubmissionBlob,
  {ok,
   #{claim := #transaction{origin = {OwnerNs, _},
                           tx_id = ClaimTxId},
     target := Target, plan := Plan}}) ->
    case quod_dtx:signer(Plan) of
        <<_:256>> = TargetNode ->
            {ok, #{owner_ns => OwnerNs,
                   claim_tx_id => ClaimTxId,
                   target => Target,
                   target_node => TargetNode,
                   submission_blob => SubmissionBlob}};
        _ -> {error, invalid_operation_claim}
    end;
dormant_operation_binding(_OwnerNs, _SubmissionBlob, _Decoded) ->
    {error, invalid_operation_claim}.

dormant_operation_init(Owner, Context = #{target := Target}) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    %% Subscribe before the first endpoint attempt so a route edge concurrent
    %% with link failure is already in this process's mailbox. The signed
    %% cancellation remains the exact same blob on every later wake.
    true = quod_reg:subscribe({directory_route, Target}),
    dormant_operation_cancel(Owner, OwnerMonitor, Context).

dormant_operation_cancel(
  Owner, OwnerMonitor,
  #{owner_ns := OwnerNs, target := Target, target_node := TargetNode,
    submission_blob := SubmissionBlob} = Context) ->
    Request = dormant_cancel_request(
                crypto:strong_rand_bytes(
                  ?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS div 8),
                SubmissionBlob),
    case quod_dtx_current_view:submit_operation_to(
           OwnerNs, Target, TargetNode, Request,
           ?DEFAULT_REQUEST_TIMEOUT_MS) of
        {ok, Response} ->
            case dormant_cancel_disposition(Request, Response) of
                terminal -> dormant_operation_finish(Owner, Context);
                wait -> dormant_operation_wait(
                          Owner, OwnerMonitor, Context)
            end;
        {error, _} ->
            dormant_operation_wait(Owner, OwnerMonitor, Context)
    end.

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

dormant_cancel_request(RequestId, SubmissionBlob)
  when is_binary(RequestId),
       bit_size(RequestId) =:= ?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS,
       is_binary(SubmissionBlob) ->
    {cancel_operation_effect, RequestId, SubmissionBlob}.

dormant_operation_finish(
  _Owner, #{owner_ns := OwnerNs, claim_tx_id := ClaimTxId} = Context) ->
    _ = quod_simplex:cancel_transaction_custody(OwnerNs, ClaimTxId),
    dormant_operation_cleanup(Context),
    ok.

dormant_operation_wait(Owner, OwnerMonitor,
                       Context = #{target := Target}) ->
    receive
        Message ->
            case dormant_wait_event(
                   Message, Owner, OwnerMonitor, Target) of
                stop ->
                    dormant_operation_cleanup(Context);
                retry ->
                    dormant_operation_cancel(
                      Owner, OwnerMonitor, Context);
                wait ->
                    dormant_operation_wait(Owner, OwnerMonitor, Context)
            end
    end.

dormant_wait_event(
  {'DOWN', OwnerMonitor, process, Owner, _Reason},
  Owner, OwnerMonitor, _Target) ->
    stop;
dormant_wait_event(
  {directory_route_available, Target},
  _Owner, _OwnerMonitor, Target) ->
    retry;
dormant_wait_event(_Message, _Owner, _OwnerMonitor, _Target) ->
    wait.

dormant_operation_cleanup(#{target := Target}) ->
    _ = catch quod_reg:unsubscribe({directory_route, Target}),
    ok.

valid_operation_ref(
  Ns, {operation, Ns, <<_:256>>, AgentRef, <<_:256>>}) ->
    quod_agent_ref:valid_principal({agent, AgentRef});
valid_operation_ref(_Ns, _OperationRef) ->
    false.

operation_init(Owner, OwnerNs, ClaimSlot, OperationRef) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    operation_load_claim(
      Owner, OwnerMonitor, OwnerNs, ClaimSlot, OperationRef).

operation_load_claim(Owner, OwnerMonitor, OwnerNs, ClaimSlot, OperationRef) ->
    case quod_simplex:operation_claim_evidence(
           OwnerNs, ClaimSlot, OperationRef) of
        {ok, ClaimRef, Claim} ->
            case operation_context(OwnerNs, OperationRef, ClaimRef, Claim) of
                {ok, Context} ->
                    operation_drive(
                      Owner, OwnerMonitor, Context#{claim_ref => ClaimRef,
                                                   claim => Claim});
                {error, Reason} ->
                    operation_stop(Owner, OperationRef, Reason)
            end;
        {error, Reason} ->
            operation_stop(Owner, OperationRef, Reason)
    end.

operation_context(
  OwnerNs, OperationRef,
  ClaimRef,
  #transaction{origin = {OwnerNs, <<_:256>>} = Origin,
               role = {remote_claim, _Manifest,
                       {{TargetNs, <<_:256>> = TargetAnchor} = Target,
                        _PlanDigest, _PlanBlob, _Attestation},
                       <<_:256>> = TargetTxId}} = Claim)
  when is_binary(TargetNs), byte_size(TargetNs) > 0 ->
    case {quod_dtx:certified_ref_binding(ClaimRef),
          quod_transaction:request_claim(Claim)} of
        {{ok, Origin, _Slot, ClaimTxId},
         {ok, #{operation_ref := OperationRef,
                digest := <<_:256>> = RequestDigest}}}
          when ClaimTxId =:= Claim#transaction.tx_id ->
            case quod_transaction:remote_claim_route(Claim) of
                Route when Route =:= shared; element(1, Route) =:= private ->
                    {ok, #{owner_ns => OwnerNs, origin => Origin,
                           operation_ref => OperationRef,
                           request_digest => RequestDigest,
                           target => Target,
                           target_ref => {transaction, TargetNs,
                                          TargetAnchor, TargetTxId},
                           follow => none, foreign_monitor => none,
                           state => target}};
                error ->
                    {error, invalid_operation_claim}
            end;
        _ ->
            {error, invalid_operation_claim}
    end;
operation_context(_OwnerNs, _OperationRef, _ClaimRef, _Claim) ->
    {error, invalid_operation_claim}.

operation_drive(Owner, OwnerMonitor,
                #{state := target, owner_ns := OwnerNs,
                  operation_ref := OperationRef, target := Target,
                  claim_ref := ClaimRef, claim := Claim} = Context) ->
    RequestId = crypto:strong_rand_bytes(
                  ?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS div 8),
    case quod_transaction:encode_evidence(ClaimRef, Claim) of
        {ok, ClaimEvidence} ->
            Request = {apply_claim, RequestId, ClaimEvidence},
            Started = erlang:monotonic_time(),
            Submission = quod_dtx_current_view:submit_claim_application(
                           OwnerNs, Target, Claim, Request,
                           ?DEFAULT_REQUEST_TIMEOUT_MS),
            ok = quod_metrics:observe_remote_operation_stage(
                   element(1, Target), target_application,
                   operation_target_metric_result(Submission),
                   erlang:monotonic_time() - Started),
            case Submission of
                {ok, Response} ->
                    operation_target_response(
                      Owner, OwnerMonitor, Request, Response, Context);
                {error, invalid_request} ->
                    operation_stop(
                      Owner, OperationRef, invalid_operation_claim);
                {error, _Temporary} ->
                    operation_wait_target(Owner, OwnerMonitor, Context)
            end;
        {error, _} ->
            operation_stop(Owner, OperationRef, invalid_operation_claim)
    end;
operation_drive(Owner, OwnerMonitor,
                #{state := source} = Context) ->
    operation_submit_complete(Owner, OwnerMonitor, Context).

operation_target_response(
  Owner, OwnerMonitor, Request,
  {application, _RequestId, committed, EvidenceBlob} = Response,
  Context) ->
    operation_target_result(
      Owner, OwnerMonitor, Request, Response,
      committed, EvidenceBlob, Context);
operation_target_response(
  Owner, OwnerMonitor, Request,
  {application, _RequestId, {rejected, Reason}, EvidenceBlob} = Response,
  Context) when is_atom(Reason) ->
    operation_target_result(
      Owner, OwnerMonitor, Request, Response,
      {rejected, Reason}, EvidenceBlob, Context);
operation_target_response(
  Owner, OwnerMonitor, Request, Response,
  Context = #{operation_ref := OperationRef}) ->
    case operation_target_response_disposition(Request, Response) of
        wait ->
            operation_wait_target(Owner, OwnerMonitor, Context);
        invalid_operation_claim ->
            operation_stop(Owner, OperationRef, invalid_operation_claim);
        invalid_target_response ->
            operation_stop(Owner, OperationRef, invalid_target_response)
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
test_operation_target_response_disposition(Request, Response) ->
    operation_target_response_disposition(Request, Response).
-endif.

operation_target_result(
  Owner, OwnerMonitor, Request, Response, Result, EvidenceBlob,
  Context = #{operation_ref := OperationRef,
              target_ref := TargetRef}) ->
    case {quod_dtx_endpoint:correlates(Request, Response),
          quod_transaction:decode_evidence(EvidenceBlob)} of
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
                    Owner ! {dtx_coordinator, self(), OperationRef,
                             {target_result, Result, TargetRef}},
                    operation_drive(
                      Owner, OwnerMonitor,
                      Context#{state => source,
                               target_certified_ref => TargetCertifiedRef,
                               target_transaction => TargetTransaction});
                _ ->
                    operation_stop(
                      Owner, OperationRef, invalid_target_evidence)
            end;
        _ ->
            operation_stop(Owner, OperationRef, invalid_target_evidence)
    end.

stable_transaction_ref(Ref, TxId) ->
    case quod_transaction:stable_ref(Ref) of
        {transaction, _Ns, _Anchor, TxId} = StableRef -> StableRef;
        _ -> invalid
    end.

operation_submit_complete(
  Owner, OwnerMonitor,
  #{owner_ns := OwnerNs, origin := Origin,
    operation_ref := OperationRef, request_digest := RequestDigest,
    target_ref := TargetRef, target_certified_ref := TargetCertifiedRef,
    target_transaction := TargetTransaction} = Context) ->
    try
        Complete0 = quod_transaction:remote_complete(
                      Origin, OperationRef, RequestDigest, TargetRef),
        Complete = quod_transaction:attach_evidence(
                     Complete0, TargetCertifiedRef, TargetTransaction),
        Started = erlang:monotonic_time(),
        Submission = quod_prolog:submit_role(
                       OwnerNs, Complete, [], ?DEFAULT_REQUEST_TIMEOUT_MS),
        ok = quod_metrics:observe_remote_operation_stage(
               OwnerNs, completion,
               operation_completion_metric_result(Submission),
               erlang:monotonic_time() - Started),
        case Submission of
            {ok, _Bindings, _Slot, _TxId} ->
                operation_stop(Owner, OperationRef, done);
            {error, {outcome_unknown, _}} ->
                operation_wait_source(Owner, OwnerMonitor, Context);
            {error, _Temporary} ->
                operation_wait_source(Owner, OwnerMonitor, Context)
        end
    catch _:_ ->
        operation_stop(Owner, OperationRef, invalid_completion)
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

operation_wait_target(Owner, OwnerMonitor,
                      Context = #{target := Target}) ->
    operation_wait(
      Owner, OwnerMonitor,
      operation_attach_follow(Context#{state => target}, Target)).

operation_wait_source(Owner, OwnerMonitor, Context) ->
    operation_wait(Owner, OwnerMonitor, Context#{state => source}).

operation_wait(Owner, OwnerMonitor,
               Context = #{operation_ref := OperationRef,
                           follow := FollowRef,
                           foreign_monitor := ForeignMonitor}) ->
    receive
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            operation_cleanup_wait(Context);
        {gproc, unreg, ForeignMonitor, _Key}
          when is_reference(ForeignMonitor) ->
            operation_wait(
              Owner, OwnerMonitor, Context#{follow => none});
        {gproc, registered, ForeignMonitor, _Key}
          when is_reference(ForeignMonitor),
               map_get(state, Context) =:= target ->
            operation_wait_target(Owner, OwnerMonitor, Context);
        {operation_wake, OperationRef}
          when map_get(state, Context) =:= source ->
            operation_drive(
              Owner, OwnerMonitor, operation_clear_follow(Context));
        {operation_wake, OperationRef} ->
            operation_wait(Owner, OwnerMonitor, Context);
        {quod_foreign_follow, FollowRef, NoticeRef, _Identity, _Notice}
          when is_reference(FollowRef) ->
            ok = quod_foreign_log:ack(FollowRef, NoticeRef),
            operation_drive(
              Owner, OwnerMonitor, operation_clear_follow(Context));
        _Other ->
            operation_wait(Owner, OwnerMonitor, Context)
    end.

operation_attach_follow(Context0, Target) ->
    Context = operation_ensure_foreign_monitor(Context0),
    case map_get(follow, Context) of
        FollowRef when is_reference(FollowRef) ->
            Context;
        none ->
            case quod_foreign_log:follow(Target) of
                {ok, FollowRef} ->
                    ok = quod_foreign_log:refresh(FollowRef),
                    Context#{follow => FollowRef};
                {error, _} ->
                    %% The gproc follow monitor wakes this process as soon as
                    %% the one shared verifier registers again.
                    Context
            end
    end.

operation_ensure_foreign_monitor(
  Context = #{foreign_monitor := ForeignMonitor})
  when is_reference(ForeignMonitor) ->
    Context;
operation_ensure_foreign_monitor(Context) ->
    ForeignMonitor = quod_reg:monitor_name({foreign_log, node}, follow),
    Context#{foreign_monitor => ForeignMonitor}.

operation_clear_follow(Context = #{follow := none}) -> Context;
operation_clear_follow(Context = #{follow := FollowRef}) ->
    operation_cleanup_follow(FollowRef),
    Context#{follow => none}.

operation_cleanup_follow(none) -> ok;
operation_cleanup_follow(FollowRef) ->
    quod_foreign_log:unfollow(FollowRef).

operation_cleanup_wait(Context) ->
    operation_cleanup_follow(map_get(follow, Context)),
    case map_get(foreign_monitor, Context) of
        none -> ok;
        ForeignMonitor ->
            quod_reg:demonitor_name({foreign_log, node}, ForeignMonitor)
    end.

operation_stop(Owner, OperationRef, done) ->
    Owner ! {dtx_coordinator, self(), OperationRef, {done, OperationRef}},
    ok;
operation_stop(Owner, OperationRef, Reason) ->
    Owner ! {dtx_coordinator, self(), OperationRef, {error, Reason}},
    ok.

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

init(S0 = #state{owner = Owner, owner_ns = OwnerNs,
                 group_id = GroupId}) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    queue_drive(),
    S = S0#state{owner_monitor = OwnerMonitor,
                 total_started_native = erlang:monotonic_time()},
    quod_trace:with_span(
      quod_trace:context(), <<"quod.dtx.coordinate">>, internal,
      #{'quod.namespace' => OwnerNs,
        'quod.dtx.group_id' => quod_trace:tx_id(GroupId)},
      fun(_SpanCtx) -> loop(S) end).

loop(S) ->
    receive
        Message -> handle_loop_message(Message, S)
    end.

handle_loop_message(
  {drive, EnqueuedNative}, S = #state{wave = #wave{}}) ->
    %% A progress edge cannot be consumed while its current observation wave
    %% is still running. `finish_wave/1` re-enqueues the retained edge.
    observe_stage(S, coordinator_mailbox, ok, EnqueuedNative),
    loop(S#state{progress_pending = true});
handle_loop_message({drive, EnqueuedNative}, S) ->
    observe_stage(S, coordinator_mailbox, ok, EnqueuedNative),
    continue(drive(S#state{progress_pending = false}));
handle_loop_message(
  {dtx_wave_result, WaveRef, Worker, Index, Result},
  S = #state{wave = #wave{ref = WaveRef, workers = Workers,
                          results = Results} = Wave}) ->
    case maps:take(Worker, Workers) of
        {{Monitor, Index}, Workers1} ->
            _ = erlang:demonitor(Monitor, [flush]),
            Wave1 = Wave#wave{workers = Workers1,
                              results = Results#{Index => Result}},
            case map_size(Workers1) of
                0 -> continue(finish_wave(S#state{wave = Wave1}));
                _ -> loop(S#state{wave = Wave1})
            end;
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
            case Notice of
                {advanced, _, _, _, _, _, _} ->
                    loop(request_progress_drive(S));
                {resnapshot, _, _, _} ->
                    loop(request_progress_drive(S));
                _ ->
                    loop(S)
            end;
        _ ->
            loop(S)
    end;
handle_loop_message(
  {directory_route_available, Identity},
  S = #state{route_subscriptions = Subscriptions}) ->
    case maps:is_key(Identity, Subscriptions) of
        true ->
            S1 = attach_follow(Identity, S),
            loop(request_progress_drive(S1));
        false ->
            loop(S)
    end;
handle_loop_message(
  {gproc, unreg, Monitor, _Name},
  S = #state{foreign_log_monitor = Monitor}) ->
    %% Follow refs belong to the old owner and can never become live again.
    %% Required identities remain in route_subscriptions for exact reattach.
    loop(S#state{follows = #{}});
handle_loop_message(
  {gproc, registered, Monitor, _Name},
  S = #state{foreign_log_monitor = Monitor,
             route_subscriptions = Subscriptions}) ->
    S1 = lists:foldl(
           fun(Identity, Acc) -> attach_follow(Identity, Acc) end,
           S, maps:keys(Subscriptions)),
    loop(request_progress_drive(S1));
handle_loop_message(
  {'DOWN', Monitor, process, Owner, _Reason},
  S = #state{owner_monitor = Monitor, owner = Owner}) ->
    close_coordinator(uncertain, S),
    ok;
handle_loop_message(
  {'DOWN', Monitor, process, Worker, Reason},
  S = #state{wave = #wave{workers = Workers} = Wave}) ->
    case maps:take(Worker, Workers) of
        {{Monitor, Index}, Workers1} ->
            Results1 = (Wave#wave.results)#{Index => {worker_down, Reason}},
            Wave1 = Wave#wave{workers = Workers1, results = Results1},
            case map_size(Workers1) of
                0 -> continue(finish_wave(S#state{wave = Wave1}));
                _ -> loop(S#state{wave = Wave1})
            end;
        _ ->
            loop(S)
    end;
handle_loop_message(_Message, S) ->
    loop(S).

continue({next, S}) -> loop(S);
continue(stop) -> ok.

drive(S = #state{wave = #wave{}}) ->
    {next, S};
drive(S = #state{pending_phases = Pending}) when map_size(Pending) > 0 ->
    [{Key, Value} | _] = lists:sort(maps:to_list(Pending)),
    drive_pending(Key, Value, S);
drive(S) ->
    drive_commands(S).

drive_pending(Key,
  {reference, Target, GroupId, Kind, Ref, Preferred}, S) ->
    case verify_accepted_phase(
           Target, GroupId, Kind, Ref, Preferred, S) of
        {progress, S1, Phase} ->
            notify(S1, {progress, Phase}),
            queue_drive(),
            {next, drop_pending(Key, S1#state{commands = none})};
        {retry, S1} ->
            {next, wait_for_progress(Target, S1#state{commands = none})};
        {fatal, Reason, S1} ->
            terminate_expected(Reason, S1)
    end;
drive_pending(Key, {submission, Target, GroupId, Kind}, S) ->
    case observe_uncertain_phase(Target, GroupId, Kind, S) of
        {progress, S1, Phase} ->
            notify(S1, {progress, Phase}),
            queue_drive(),
            {next, drop_pending(Key, S1#state{commands = none})};
        {retry, S1} ->
            {next, wait_for_progress(
                     Target, S1#state{commands = none})};
        {absent, S1} ->
            %% Admission and phase inspection serialize in the target
            %% Simplex. A fresh absence after the retained submission has
            %% disappeared therefore proves this process can no longer commit
            %% it; the planner may safely mint the next envelope.
            queue_drive(),
            {next, drop_pending(Key, S1#state{commands = none})};
        {fatal, Reason, S1} ->
            terminate_expected(Reason, S1)
    end.

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
drive_commands(S0 = #state{commands = {independent, Stage, Commands}})
  when Stage =:= prepare; Stage =:= finalize; Stage =:= applied ->
    start_wave(Stage, Commands, S0);
drive_commands(S0 = #state{commands = {Mode, Stage, Commands}})
  when Mode =:= ordered; Mode =:= independent ->
    drive_one_command(Mode, Stage, Commands, S0).

drive_commands_next(S) ->
    case quod_dtx_recovery:next(S#state.begin_record, S#state.snapshot) of
        {done, CompleteRef} ->
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

pending_key({reference, Target, _GroupId, Kind, _Ref, _Preferred}) ->
    {Target, Kind};
pending_key({submission, Target, _GroupId, Kind}) ->
    {Target, Kind}.

drive_one_command(Mode, Stage, [Command | Rest], S0) ->
    case run_command(Command, S0) of
        {progress, S1, Phase} ->
            notify(S1, {progress, Phase}),
            %% Newly certified evidence can invalidate the remainder of the
            %% planner's previous batch. Re-plan from the exact new snapshot.
            queue_drive(),
            {next, S1#state{commands = none}};
        {retry, S1} when Rest =/= [] ->
            queue_drive(),
            {next, S1#state{commands = {Mode, Stage, Rest}}};
        {retry, S1} ->
            {next, wait_for_command_progress(
                     Command, S1#state{commands = none})};
        {wait, S1} ->
            {next, S1#state{commands = none}};
        {fatal, Reason, S1} ->
            terminate_expected(Reason, S1)
    end.

start_wave(Stage, Commands, S0) ->
    case Stage of
        prepare ->
            start_typed_wave(
              phase_command, Commands, #{phase => prepare},
              enter_stage(prepare_wave, S0));
        finalize ->
            start_typed_wave(
              phase_command, Commands, #{phase => finalize},
              enter_stage(finalize_wave, S0));
        applied ->
            start_typed_wave(
              applied, [Commands], #{}, enter_stage(applied_wave, S0))
    end.

start_typed_wave(Stage, Items, Meta, S0) ->
    Ref = make_ref(),
    Parent = self(),
    Context = wave_context(S0),
    {WaveTraceCtx, WaveTraceSpan} = quod_trace:start_span(
                                      quod_trace:context(),
                                      <<"quod.dtx.wave">>, internal,
                                      #{'quod.dtx.stage' =>
                                            atom_to_binary(Stage, utf8),
                                        'quod.dtx.wave.items' =>
                                            length(Items)}),
    WorkerSpecs = lists:zip(lists:seq(1, length(Items)), Items),
    Workers =
        lists:foldl(
          fun({Index, Item}, Acc) ->
                  {Pid, Monitor} =
                      spawn_owned_monitor(
                        Parent,
                        fun() ->
                                Result = quod_trace:with_span(
                                           WaveTraceCtx,
                                           <<"quod.dtx.wave.item">>, internal,
                                           #{'quod.dtx.stage' =>
                                                 atom_to_binary(Stage, utf8),
                                             'quod.dtx.wave.item' => Index},
                                           fun(_SpanCtx) ->
                                                   run_wave_work(
                                                     Stage, Item, Context)
                                           end),
                                Parent ! {dtx_wave_result, Ref, self(),
                                          Index, Result}
                        end),
                  Acc#{Pid => {Monitor, Index}}
          end, #{}, WorkerSpecs),
    Timer = erlang:send_after(
              ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS,
              self(), {dtx_wave_timeout, Ref}),
    Wave = #wave{ref = Ref, stage = Stage, items = Items,
                 workers = Workers, timer = Timer, meta = Meta,
                 started_native = erlang:monotonic_time(),
                 trace_span = WaveTraceSpan},
    {next, S0#state{commands = none, wave = Wave}}.

wave_context(#state{owner_ns = OwnerNs, config = Config,
                    finalize_evidence = FinalizeEvidence,
                    phase_entries = PhaseEntries}) ->
    #{owner_ns => OwnerNs,
      request_timeout_ms => Config#config.request_timeout_ms,
      finalize_evidence => FinalizeEvidence,
      phase_entries => PhaseEntries}.

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
    case Stage of
        applied -> finish_applied_wave(Items, Ordered, S);
        phase_command -> finish_phase_command_wave(Items, Ordered, S);
        phase_verify -> finish_verify_wave(Items, Ordered, Meta, S)
    end.

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

finish_phase_command_wave(Commands, Results, S) ->
    case classify_phase_command_wave(
           Commands, Results, S, [], [], false, false, none) of
        {S1, VerifyRev, PhasesRev, Progress, Waiting, Fatal} ->
            Meta = #{phases => lists:reverse(PhasesRev),
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
            {verify, {Target, GroupId, Kind, Ref, Source}, S};
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
            {waiting, put_pending(
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
    {waiting, put_pending({submission, Target, GroupId, Kind}, S)};
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
    {waiting, put_pending({submission, Target, GroupId, Kind}, S)};
classify_phase_command_result(
  {phase, Target, GroupId, Kind},
  {ok, Target, GroupId, Kind, Request, Result}, S) ->
    case handle_phase_response_deferred(
           Target, GroupId, Kind, Request, Result, S) of
        {verify, Ref, Preferred, S1} ->
            {verify, {Target, GroupId, Kind, Ref, Preferred}, S1};
        {progress, S1, Phase} ->
            {progress, Phase, S1};
        {retry, S1} ->
            {waiting, wait_for_progress(Target, S1)};
        {fatal, Reason, S1} ->
            {fatal, Reason, S1}
    end;
classify_phase_command_result(
  {phase, Target, _GroupId, _Kind}, {worker_down, Reason}, S) ->
    case worker_down_disposition(phase, Reason) of
        retry ->
            %% A silence deadline is an availability failure. The exact
            %% follow/route signal wakes the pure recovery planner.
            {waiting, wait_for_progress(Target, S)};
        {fatal, Failure} ->
            {fatal, Failure, S}
    end;
classify_phase_command_result(_Command, {error, Reason}, S) ->
    {fatal, {invalid_recovery_record, Reason}, S};
classify_phase_command_result(_Command, _Malformed, S) ->
    {fatal, invalid_dtx_wave_result, S}.

finish_verify_wave(Specs, Results, Meta0, S0) ->
    {S, PhasesRev, Progress, Waiting, Fatal} =
        classify_verify_wave(
          Specs, Results, S0, [], maps:get(progress, Meta0),
          maps:get(waiting, Meta0), maps:get(fatal, Meta0)),
    Meta = Meta0#{phases := maps:get(phases, Meta0) ++
                              lists:reverse(PhasesRev),
                  progress := Progress, waiting := Waiting,
                  fatal := Fatal},
    finish_wave_outcome(Meta, S).

classify_verify_wave([], [], S, Phases, Progress, Waiting, Fatal) ->
    {S, Phases, Progress, Waiting, Fatal};
classify_verify_wave(
  [{Target, GroupId, Kind, Ref, Preferred} | Specs],
  [Result | Results], S0, Phases, Progress, Waiting, Fatal0) ->
    case Result of
        {ok, Evidence} ->
            case install_phase_evidence(
                   Target, GroupId, Kind, Ref, Evidence, S0) of
                {progress, S1, Phase} ->
                    classify_verify_wave(
                      Specs, Results, S1, [Phase | Phases], true,
                      Waiting, Fatal0);
                {fatal, Reason, S1} ->
                    classify_verify_wave(
                      Specs, Results, S1, Phases, Progress, Waiting,
                      first_fatal(Fatal0, Reason))
            end;
        {error, retry} ->
            S1 = put_pending(
                   {reference, Target, GroupId, Kind, Ref, Preferred}, S0),
            classify_verify_wave(
              Specs, Results, S1, Phases, Progress, true, Fatal0);
        {worker_down, Reason} ->
            case worker_down_disposition(evidence, Reason) of
                retry ->
                    S1 = put_pending(
                           {reference, Target, GroupId, Kind, Ref,
                            Preferred}, S0),
                    classify_verify_wave(
                      Specs, Results, S1, Phases, Progress, true, Fatal0);
                {fatal, Failure} ->
                    classify_verify_wave(
                      Specs, Results, S0, Phases, Progress, Waiting,
                      first_fatal(Fatal0, Failure))
            end;
        _Malformed ->
            classify_verify_wave(
              Specs, Results, S0, Phases, Progress, Waiting,
              first_fatal(Fatal0, invalid_verified_phase_evidence))
    end;
classify_verify_wave(_Specs, _Results, S, Phases, Progress, Waiting, Fatal) ->
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

stop_wave_workers(#wave{workers = Workers, timer = Timer}) ->
    _ = erlang:cancel_timer(Timer),
    maps:foreach(
      fun(Pid, {Monitor, _Index}) ->
              _ = erlang:demonitor(Monitor, [flush]),
              exit(Pid, kill)
      end, Workers),
    ok.

worker_down_disposition(submit, _Reason) -> uncertain;
worker_down_disposition(_ReadStage, timeout) -> retry;
worker_down_disposition(Stage, Reason)
  when Stage =:= phase; Stage =:= evidence; Stage =:= applied ->
    {fatal, {dtx_worker_crash, Stage, Reason}}.

timeout_wave(Wave = #wave{workers = Workers, results = Results}, S) ->
    stop_wave_workers(Wave),
    finish_wave_trace(Wave, timeout),
    Results1 = maps:fold(
                 fun(_Pid, {_Monitor, Index}, Acc) ->
                         Acc#{Index => {worker_down, timeout}}
                 end, Results, Workers),
    finish_wave(
      S#state{wave = Wave#wave{workers = #{}, results = Results1,
                               trace_span = undefined}}).

submit_command_io({submit, Target, Record}, Context) ->
    try
        Kind = quod_dtx:record_kind(Record),
        true = Kind =/= invalid,
        GroupId = quod_dtx:group_id(Record),
        case quod_dtx:encode_record(Record) of
            {ok, RecordBlob} ->
                Request = {submit, request_id(), RecordBlob},
                {ok, Target, GroupId, Kind, Request,
                 submit_endpoint_request(
                   Target, Request,
                   record_validation_sidecar(
                     Record, maps:get(phase_entries, Context, #{}), []),
                   Context)};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        _:_ -> {error, invalid_recovery_record}
    end.

phase_command_io({submit, _Target, _Record} = Command, Context) ->
    submit_command_io(Command, Context);
phase_command_io({phase, Target, GroupId, Kind}, Context)
  when Kind =:= prepare ->
    Request = {phase, request_id(), GroupId, Kind},
    Result = phase_command_sources(
               endpoint_sources(Target, any), Target, Kind, Request, Context),
    {ok, Target, GroupId, Kind, Request, Result};
phase_command_io(_Command, _Context) ->
    {error, invalid_recovery_record}.

%% A phase command is read-only, so its worker may try every exact current
%% source.  State interpretation remains in the coordinator owner below.  A
%% malformed or hostile remote answer cannot prevent the next validator from
%% answering; a malformed local answer remains a loud implementation error.
phase_command_sources([], _Target, _Kind, _Request, _S) ->
    {error, not_ready};
phase_command_sources([Source | Rest], Target, Kind, Request, S) ->
    Result = endpoint_request(Source, Target, Request, [], S),
    case phase_source_disposition(Source, Kind, Request, Result) of
        terminal -> Result;
        next -> phase_command_sources(Rest, Target, Kind, Request, S)
    end.

phase_source_disposition(
  Source, _Kind, Request, {ok, Response, _ReplySource}) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true ->
            case Response of
                {phase, _, _, {committed, _}} -> terminal;
                {phase, _, _, Status}
                  when Status =:= pending; Status =:= not_found -> terminal;
                {error, _, invalid_request} when Source =:= local -> terminal;
                _ -> next
            end;
        false when Source =:= local -> terminal;
        false -> next
    end;
phase_source_disposition(local, _Kind, _Request, {error, _}) ->
    next;
phase_source_disposition({remote, _, _}, _Kind, _Request, {error, _}) ->
    next.

phase_evidence_io(
  {Target, GroupId, Kind, Ref, Preferred}, Context) ->
    Timeout = maps:get(request_timeout_ms, Context),
    phase_evidence_sources(
      endpoint_sources(Target, Preferred), Target, GroupId, Kind, Ref,
      preferred_entry_hint(Preferred, Ref), Timeout).

phase_evidence_sources([], _Target, _GroupId, _Kind, _Ref, _Hint, _Timeout) ->
    {error, retry};
phase_evidence_sources(
  [Source | Rest], Target, GroupId, Kind, Ref, EntryHint, Timeout) ->
    Result =
        case endpoint_evidence_source(Source) of
            local ->
                {Ns, _Anchor} = Target,
                quod_simplex:dtx_local_evidence(Ns, Ref, Kind);
            {remote, _PeerKey} ->
                quod_foreign_log:verify_reference(
                  Ref, Kind, none, EntryHint, Timeout)
        end,
    case Result of
        {ok, Evidence} -> {ok, Evidence};
        {error, _} ->
            phase_evidence_sources(
              Rest, Target, GroupId, Kind, Ref, EntryHint, Timeout)
    end.

preferred_entry_hint({reply_source, local, Hints}, Ref) ->
    entry_hint(Ref, Hints);
preferred_entry_hint({reply_source, remote, _PeerKey, Hints}, Ref) ->
    entry_hint(Ref, Hints);
preferred_entry_hint(_Preferred, _Ref) -> none.

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
                   maps:get(request_timeout_ms, Context)) of
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

request_progress_drive(S = #state{wave = #wave{}}) ->
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
    _ = quod_trace:add_event(
          quod_trace:context(), <<"dtx.completed">>,
          #{'quod.dtx.result' => atom_to_binary(Result, utf8)}),
    maps:foreach(
      fun(_Identity, FollowRef) ->
              _ = catch quod_foreign_log:unfollow(FollowRef)
      end, S#state.follows),
    case S#state.foreign_log_monitor of
        none -> ok;
        Monitor ->
            _ = catch quod_reg:demonitor_name(
                        {foreign_log, node}, Monitor),
            ok
    end,
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

observe_stage(#state{owner_ns = Ns}, Stage, Result, StartedNative)
  when is_integer(StartedNative) ->
    quod_metrics:observe_dtx_group_stage(
      Ns, Stage, Result, erlang:monotonic_time() - StartedNative);
observe_stage(_S, _Stage, _Result, _StartedNative) ->
    ok.

observe_endpoint_stage(Context, Stage, Result, StartedNative)
  when is_integer(StartedNative) ->
    quod_metrics:observe_dtx_group_stage(
      context_owner_ns(Context), Stage, Result,
      erlang:monotonic_time() - StartedNative).

context_owner_ns(#state{owner_ns = OwnerNs}) ->
    OwnerNs;
context_owner_ns(#{owner_ns := OwnerNs}) ->
    OwnerNs.

context_timeout(#state{config = #config{request_timeout_ms = TimeoutMs}}) ->
    TimeoutMs;
context_timeout(#{request_timeout_ms := TimeoutMs}) ->
    TimeoutMs.

%% ------------------------------------------------------------------
%% One bounded planner command
%% ------------------------------------------------------------------

run_command({submit, Target, Record}, S) ->
    submit_record(Target, Record, S);
run_command(_Malformed, S) ->
    {fatal, invalid_recovery_command, S}.

submit_record(Target, Record, S) ->
    try
        Kind = quod_dtx:record_kind(Record),
        S1 = enter_stage(record_stage(Kind), S),
        GroupId = quod_dtx:group_id(Record),
        case quod_dtx:encode_record(Record) of
            {ok, RecordBlob} ->
                Request = {submit, request_id(), RecordBlob},
                handle_submit_response(
                  Target, GroupId, Kind, Request,
                  submit_endpoint_request(
                    Target, Request,
                    record_validation_sidecar(
                      Record, S1#state.phase_entries,
                      maps:get(applied, S1#state.snapshot)), S1),
                  S1);
            {error, Reason} ->
                {fatal, {invalid_recovery_record, Reason}, S1}
        end
    catch
        _:_ -> {fatal, invalid_recovery_record, S}
    end.

record_stage('begin') -> 'begin';
record_stage(prepare) -> prepare_wave;
record_stage(decision) -> decision;
record_stage(finalize) -> finalize_wave;
record_stage(complete) -> complete.

handle_submit_response(
  Target, GroupId, Kind, Request,
  {reply, {accepted, _RequestId, _Digest, Ref} = Response, Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true ->
            accepted_phase_result(
              Target, GroupId, Kind, Ref, Source,
              verify_accepted_phase(
                Target, GroupId, Kind, Ref, Source, S));
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_submit_response(
  Target, _GroupId, prepare, Request,
  {reply, {refused, _RequestId, Target, SemanticDigest, Generation,
           ReasonsBlob} = Response, _Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> put_refusal(
                  Target, SemanticDigest, Generation, ReasonsBlob, S);
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_submit_response(
  Target, GroupId, Kind, Request,
  {reply, {error, _RequestId, Reason} = Response, _Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true when Reason =:= busy; Reason =:= not_ready;
                  Reason =:= not_found ->
            recover_submitted_phase(Target, GroupId, Kind, S);
        true when Reason =:= invalid_request ->
            {fatal, endpoint_rejected_recovery_record, S};
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_submit_response(Target, GroupId, Kind, _Request,
                       outcome_unknown, S) ->
    {retry, put_pending(
              {submission, Target, GroupId, Kind}, S)};
handle_submit_response(Target, GroupId, Kind, _Request,
                       not_submitted, S) ->
    recover_submitted_phase(Target, GroupId, Kind, S);
handle_submit_response(_Target, _GroupId, _Kind, _Request, _Malformed, S) ->
    {fatal, invalid_endpoint_response, S}.

recover_submitted_phase(Target, GroupId, Kind, S) ->
    case observe_phase(Target, GroupId, Kind, any, S) of
        {retry, S1} when Kind =:= finalize ->
            %% A direct-abort Finalize may lose the target-ledger race to a
            %% previously submitted Prepare. Discovering that certified
            %% Prepare replaces the unsigned generation hint and lets the pure
            %% planner construct the prepared abort Finalize.
            observe_phase(Target, GroupId, prepare, any, S1);
        Result ->
            Result
    end.

accepted_phase_result(_Target, _GroupId, _Kind, _Ref, _Source,
                      {progress, _S1, _Phase} = Progress) ->
    Progress;
accepted_phase_result(Target, GroupId, Kind, Ref, Source,
                      {retry, S}) ->
    {wait,
     wait_for_progress(
       Target,
       put_pending(
         {reference, Target, GroupId, Kind, Ref, Source}, S))};
accepted_phase_result(_Target, _GroupId, _Kind, _Ref, _Source,
                      {fatal, _Reason, _S1} = Fatal) ->
    Fatal.

wait_for_progress(Target, S0) ->
    S = ensure_foreign_log_monitor(
          ensure_route_subscription(Target, S0)),
    attach_follow(Target, S).

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
        undefined ->
            case quod_foreign_log:follow(Target) of
                {ok, FollowRef} ->
                    S#state{follows = Follows#{Target => FollowRef}};
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
            S#state{route_subscriptions = Subscriptions#{Identity => true}}
    end.

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

verify_accepted_phase(Target, GroupId, Kind, Ref, Preferred, S) ->
    verify_accepted_phase_sources(
      endpoint_sources(Target, Preferred),
      Target, GroupId, Kind, Ref, S).

verify_accepted_phase_sources([], _Target, _GroupId, _Kind, _Ref, S) ->
    {retry, S};
verify_accepted_phase_sources(
  [Source | Rest], Target, GroupId, Kind, Ref, S) ->
    EvidenceSource = endpoint_evidence_source(Source),
    case {Source,
          verify_phase(Target, GroupId, Kind, Ref, EvidenceSource, S)} of
        {_Any, {progress, _S1, _Phase} = Progress} ->
            Progress;
        {_Any, {retry, S1}} ->
            verify_accepted_phase_sources(
              Rest, Target, GroupId, Kind, Ref, S1);
        {local, {fatal, _Reason, _S1} = Fatal} ->
            Fatal;
        {{remote, _Peer, _Endpoints}, {fatal, _Reason, S1}} ->
            %% A bad authenticated route cannot override certified evidence
            %% obtainable from another current validator.
            verify_accepted_phase_sources(
              Rest, Target, GroupId, Kind, Ref, S1)
    end.

endpoint_evidence_source(local) ->
    local;
endpoint_evidence_source({remote, PeerKey, _Endpoints}) ->
    {remote, PeerKey};
endpoint_evidence_source({reply_source, local, Hints}) ->
    {local, Hints};
endpoint_evidence_source({reply_source, remote, PeerKey, Hints}) ->
    {remote, PeerKey, Hints}.

observe_phase(Target, GroupId, Kind, Preferred, S) ->
    phase_sources(
      endpoint_sources(Target, Preferred), Target, GroupId, Kind, S).

observe_uncertain_phase(Target, GroupId, Kind, S) ->
    uncertain_phase_sources(
      endpoint_sources(Target, any), Target, GroupId, Kind,
      false, false, S).

uncertain_phase_sources([], _Target, _GroupId, _Kind,
                        SawAbsent, SawPendingOrRetry, S) ->
    case {SawAbsent, SawPendingOrRetry} of
        {true, false} -> {absent, S};
        _ -> {retry, S}
    end;
uncertain_phase_sources(
  [Source | Rest], Target, GroupId, Kind,
  SawAbsent, SawPendingOrRetry, S) ->
    Request = {phase, request_id(), GroupId, Kind},
    Result = classify_uncertain_phase_response(
               Target, GroupId, Kind, Request,
               endpoint_request(Source, Target, Request, [], S), S),
    case {Source, Result} of
        {_Any, {progress, _S1, _Phase} = Progress} ->
            Progress;
        {_Any, {absent, S1}} ->
            uncertain_phase_sources(
              Rest, Target, GroupId, Kind, true,
              SawPendingOrRetry, S1);
        {_Any, {retry, S1}} ->
            uncertain_phase_sources(
              Rest, Target, GroupId, Kind, SawAbsent, true, S1);
        {local, {fatal, _Reason, _S1} = Fatal} ->
            Fatal;
        {{remote, _Peer, _Endpoints}, {fatal, _Reason, S1}} ->
            uncertain_phase_sources(
              Rest, Target, GroupId, Kind, SawAbsent, true, S1)
    end.

classify_uncertain_phase_response(
  Target, GroupId, Kind, Request,
  {ok, {phase, _RequestId, _Generation, {committed, Ref}} = Response,
    Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> verify_phase(
                  Target, GroupId, Kind, Ref,
                  endpoint_evidence_source(Source), S);
        false -> {fatal, invalid_endpoint_response, S}
    end;
classify_uncertain_phase_response(
  _Target, _GroupId, _Kind, Request,
  {ok, {phase, _RequestId, _Generation, pending} = Response, _Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> {retry, S};
        false -> {fatal, invalid_endpoint_response, S}
    end;
classify_uncertain_phase_response(
  Target, _GroupId, Kind, Request,
  {ok, {phase, _RequestId, Generation, not_found} = Response, _Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true when Kind =:= prepare ->
            case put_generation(Target, Generation, S) of
                {progress, S1, _} -> {absent, S1};
                {retry, S1} -> {absent, S1};
                {fatal, Reason, S1} -> {fatal, Reason, S1}
            end;
        true ->
            {absent, S};
        false ->
            {fatal, invalid_endpoint_response, S}
    end;
classify_uncertain_phase_response(
  _Target, _GroupId, _Kind, Request,
  {ok, {error, _RequestId, Reason} = Response, _Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true when Reason =:= busy; Reason =:= not_ready;
                  Reason =:= not_found -> {retry, S};
        true when Reason =:= invalid_request ->
            {fatal, endpoint_rejected_phase_query, S};
        false ->
            {fatal, invalid_endpoint_response, S}
    end;
classify_uncertain_phase_response(
  _Target, _GroupId, _Kind, _Request, {error, _}, S) ->
    {retry, S};
classify_uncertain_phase_response(
  _Target, _GroupId, _Kind, _Request, _Malformed, S) ->
    {fatal, invalid_endpoint_response, S}.

phase_sources([], _Target, _GroupId, _Kind, S) ->
    {retry, S};
phase_sources([Source | Rest], Target, GroupId, Kind, S) ->
    Request = {phase, request_id(), GroupId, Kind},
    Result = handle_phase_response(
               Target, GroupId, Kind, Request,
               endpoint_request(Source, Target, Request, [], S), S),
    case {Source, Result} of
        {_Any, {progress, _S1, _Phase} = Progress} -> Progress;
        {_Any, {retry, S1}} ->
            phase_sources(Rest, Target, GroupId, Kind, S1);
        {local, {fatal, _Reason, _S1} = Fatal} -> Fatal;
        {{remote, _Peer, _Endpoints}, {fatal, _Reason, S1}} ->
            %% An authenticated validator may still be Byzantine. A bad
            %% response is a route failure; another exact validator gets the
            %% same request before the round backs off.
            phase_sources(Rest, Target, GroupId, Kind, S1)
    end.

handle_phase_response(Target, GroupId, Kind, Request, Result, S) ->
    case handle_phase_response_deferred(
           Target, GroupId, Kind, Request, Result, S) of
        {verify, Ref, Source, S1} ->
            verify_phase(Target, GroupId, Kind, Ref, Source, S1);
        Classified ->
            Classified
    end.

%% Decode and correlate a phase observation once.  Sequential recovery may
%% verify immediately through `handle_phase_response/6`; a participant wave
%% returns the exact same verification job to the shared evidence wave.
handle_phase_response_deferred(
  _Target, _GroupId, _Kind, Request,
  {ok, {phase, _RequestId, _Generation, {committed, Ref}} = Response,
   Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> {verify, Ref, Source, S};
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_phase_response_deferred(
  Target, _GroupId, prepare, Request,
  {ok, {phase, _RequestId, Generation, Status} = Response, _Source}, S)
  when Status =:= not_found; Status =:= pending ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> put_generation(Target, Generation, S);
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_phase_response_deferred(
  _Target, _GroupId, _Kind, Request,
  {ok, {phase, _RequestId, _Generation, Status} = Response, _Source}, S)
  when Status =:= not_found; Status =:= pending ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> {retry, S};
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_phase_response_deferred(
  _Target, _GroupId, _Kind, Request,
  {ok, {error, _RequestId, Reason} = Response, _Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true when Reason =:= busy; Reason =:= not_ready;
                  Reason =:= not_found -> {retry, S};
        true when Reason =:= invalid_request ->
            {fatal, endpoint_rejected_phase_query, S};
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_phase_response_deferred(_Target, _GroupId, _Kind, _Request,
                               {error, _Transient}, S) ->
    {retry, S};
handle_phase_response_deferred(_Target, _GroupId, _Kind, _Request,
                               _Malformed, S) ->
    {fatal, invalid_endpoint_response, S}.

verify_phase(Target, GroupId, Kind, Ref, Source, S) ->
    StartedNative = erlang:monotonic_time(),
    Result = verify_phase_raw(Target, GroupId, Kind, Ref, Source, S),
    observe_stage(S, phase_verification, coordinator_result(Result),
                  StartedNative),
    Result.

verify_phase_raw(Target = {Ns, _Anchor}, GroupId, Kind, Ref, local, S) ->
    case quod_simplex:dtx_local_evidence(Ns, Ref, Kind) of
        {ok, Evidence} -> install_phase_evidence(
                            Target, GroupId, Kind, Ref, Evidence, S);
        {error, _} -> {retry, S}
    end;
verify_phase_raw(Target, GroupId, Kind, Ref,
                 {remote, _PeerKey}, S = #state{config = Config}) ->
    case quod_foreign_log:verify_reference(
           Ref, Kind, Config#config.request_timeout_ms) of
        {ok, Evidence} -> install_phase_evidence(
                            Target, GroupId, Kind, Ref, Evidence, S);
        {error, _} -> {retry, S}
    end;
verify_phase_raw(Target = {_Ns, _Anchor}, GroupId, Kind, Ref,
                 {local, _Hints}, S) ->
    verify_phase_raw(Target, GroupId, Kind, Ref, local, S);
verify_phase_raw(Target, GroupId, Kind, Ref,
                 {remote, _PeerKey, Hints},
                 S = #state{config = Config}) ->
    case quod_foreign_log:verify_reference(
           Ref, Kind, none, entry_hint(Ref, Hints),
           Config#config.request_timeout_ms) of
        {ok, Evidence} -> install_phase_evidence(
                            Target, GroupId, Kind, Ref, Evidence, S);
        {error, _} -> {retry, S}
    end.

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
            {ok, Ref} = quod_dtx:certified_entry_ref(
                          Target, Entry, Control),
            {ok, Control, Generation,
             #{identity => Target, phase => Kind, control => Control,
               ref => Ref, generation => Generation, entry => Entry,
               committee => Committee, committee_id => CommitteeId,
               routes => Routes}, Entry};
        error ->
            error
    end;
valid_phase_evidence(_Target, _GroupId, _Kind, _Ref, _Evidence) ->
    error.

put_phase_entry(Ref, Entry = #entry{},
                S = #state{phase_entries = Entries}) ->
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
                {ok, {local, _LedgerRoot} = Source} -> {ok, Source};
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

submit_endpoint_request(Target, Request, ValidationSidecar, S) ->
    Sources = endpoint_sources(Target, any),
    submit_endpoint_requests(Sources, Target, Request, ValidationSidecar, S).

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
    Result = endpoint_request_raw(Source, Target, Request, ValidationSidecar, S),
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
    OwnerNs = context_owner_ns(Context),
    Deadline = quod_time:mono_ms() + context_timeout(Context),
    RequestFun =
        fun(Endpoint, CandidateRequest, Timeout) ->
            quod_simplex:dtx_endpoint_request(
              OwnerNs, TargetNs, PeerKey, Endpoint, CandidateRequest,
              ValidationSidecar, Timeout)
        end,
    endpoint_request_candidates(
      Endpoints, PeerKey, Request, Deadline, undefined, RequestFun).

coordinator_result({progress, _S, _Phase}) -> ok;
coordinator_result({retry, _S}) -> uncertain;
coordinator_result({fatal, _Reason, _S}) -> failed.

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

endpoint_sources(Target, Preferred) ->
    Cohosted = cohosted(Target),
    LocalKey = case {Cohosted, application:get_env(quod, node_pubkey)} of
                   {true, {ok, <<_:256>> = Key}} -> Key;
                   _ -> none
               end,
    Remote = [{remote, PeerKey, Endpoints}
              || {PeerKey, Endpoints} <- routes(Target),
                 PeerKey =/= LocalKey],
    All = case Cohosted of true -> [local | Remote]; false -> Remote end,
    case Preferred of
        any -> All;
        local -> [local | lists:delete(local, All)];
        {remote, PreferredKey} ->
            case lists:keytake(PreferredKey, 2, All) of
                {value, PreferredSource, Rest} -> [PreferredSource | Rest];
                false -> All
            end;
        {reply_source, remote, PreferredKey, _Hints} ->
            case lists:keytake(PreferredKey, 2, All) of
                {value, PreferredSource, Rest} -> [PreferredSource | Rest];
                false -> All
            end;
        {reply_source, local, _Hints} ->
            [local | lists:delete(local, All)]
    end.

submit_endpoint_requests([], _Target, _Request, _ValidationSidecar, _S) ->
    not_submitted;
submit_endpoint_requests(Sources, Target, Request, ValidationSidecar,
                         Context) ->
    OwnerNs = context_owner_ns(Context),
    quod_metrics:count_dtx_submit_fanout(
      OwnerNs, attempted, length(Sources)),
    RequestFun = fun(Source) ->
                     endpoint_request(
                       Source, Target, Request, ValidationSidecar, Context)
                 end,
    submit_endpoint_requests_with(
      Sources, Request, context_timeout(Context), RequestFun,
      OwnerNs).

submit_endpoint_requests_with(
  Sources, Request, TimeoutMs, RequestFun, MetricsNs) ->
    Parent = self(),
    BatchRef = make_ref(),
    Pending = maps:from_list(
                [begin
                     {Pid, MRef} = spawn_owned_monitor(
                       Parent,
                       fun() ->
                           Result = RequestFun(Source),
                           Parent ! {dtx_submit_endpoint_result,
                                     BatchRef, self(), Source, Result}
                       end),
                     {Pid, {MRef, Source}}
                 end || Source <- Sources]),
    Deadline = quod_time:mono_ms() + TimeoutMs,
    collect_submit_endpoint_results(
      BatchRef, Pending, Request, false, Deadline, MetricsNs).

%% Every asynchronous child is monitored for its result and independently
%% bound to its immediate owner. A direct shutdown therefore tears down the
%% whole ownership tree even when the owner is killed outside its receive
%% loop; normal completion removes the one-shot watcher automatically.
spawn_owned_monitor(Owner, Fun)
  when is_pid(Owner), is_function(Fun, 0) ->
    spawn_monitor(
      fun() ->
          _ = quod_process:kill_when_owner_dies(Owner, self()),
          Fun()
      end).

-ifdef(TEST).
test_submit_endpoint_requests(Sources, Request, TimeoutMs, RequestFun) ->
    submit_endpoint_requests_with(
      Sources, Request, TimeoutMs, RequestFun, <<"quod:test">>).

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
-endif.

collect_submit_endpoint_results(
  _BatchRef, Pending, _Request, Uncertain, _Deadline, _MetricsNs)
  when map_size(Pending) =:= 0 ->
    case Uncertain of true -> outcome_unknown; false -> not_submitted end;
collect_submit_endpoint_results(
  BatchRef, Pending, Request, Uncertain0, Deadline, MetricsNs) ->
    Remaining = max(0, Deadline - quod_time:mono_ms()),
    receive
        {dtx_submit_endpoint_result, BatchRef, Pid, Source, Result} ->
            case maps:take(Pid, Pending) of
                {{MRef, Source}, Pending1} ->
                    _ = erlang:demonitor(MRef, [flush]),
                    Classification = classify_submit_endpoint_result(
                                       Source, Request, Result),
                    count_submit_endpoint_result(
                      MetricsNs, Classification, Result),
                    case Classification of
                        terminal ->
                            stop_submit_endpoint_workers(Pending1),
                            submit_reply(Result);
                        uncertain ->
                            collect_submit_endpoint_results(
                              BatchRef, Pending1, Request, true, Deadline,
                              MetricsNs);
                        next ->
                            collect_submit_endpoint_results(
                              BatchRef, Pending1, Request, Uncertain0,
                              Deadline, MetricsNs)
                    end;
                error ->
                    collect_submit_endpoint_results(
                      BatchRef, Pending, Request, Uncertain0, Deadline,
                      MetricsNs)
            end;
        {'DOWN', MRef, process, Pid, _Reason} ->
            case maps:get(Pid, Pending, undefined) of
                {MRef, _Source} ->
                    count_submit_endpoint_result(
                      MetricsNs, next, {error, worker_down}),
                    collect_submit_endpoint_results(
                      BatchRef, maps:remove(Pid, Pending), Request,
                      Uncertain0, Deadline, MetricsNs);
                _ ->
                    collect_submit_endpoint_results(
                      BatchRef, Pending, Request, Uncertain0, Deadline,
                      MetricsNs)
            end
    after Remaining ->
        count_submit_endpoint_timeout(MetricsNs, map_size(Pending)),
        stop_submit_endpoint_workers(Pending),
        outcome_unknown
    end.

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

count_submit_endpoint_timeout(Ns, Count) ->
    quod_metrics:count_dtx_submit_fanout(Ns, uncertain, Count).

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

stop_submit_endpoint_workers(Pending) ->
    maps:foreach(
      fun(Pid, {MRef, _Source}) ->
          _ = erlang:demonitor(MRef, [flush]),
          exit(Pid, kill)
      end, Pending),
    ok.

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
test_dormant_wait_event(Message, Owner, OwnerMonitor, Target) ->
    dormant_wait_event(Message, Owner, OwnerMonitor, Target).
test_dormant_cancel_request(RequestId, SubmissionBlob) ->
    dormant_cancel_request(RequestId, SubmissionBlob).
test_remote_submit_result(Request, Response) ->
    remote_submit_result(Request, Response).
-endif.
