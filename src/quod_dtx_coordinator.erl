-module(quod_dtx_coordinator).
-moduledoc """
Volatile recovery driver for one already-durable distributed transaction.

The owning namespace Simplex starts one monitored worker from the exact
journaled/committed Begin.  This process owns only bounded observations and
retry timing: `quod_dtx_recovery:next/2` remains the sole phase planner, target
Simplex ledgers remain authoritative, and a worker restart reconstructs every
decision from certified evidence.

There is deliberately no durable file, registry name, compatibility protocol,
or wall-clock abort.  Once Begin may be durable, temporary unavailability can
only delay recovery.  Every network wait and every retry interval is bounded;
owner death terminates the worker.
""".

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([start_monitor/5, start_operation_monitor/5,
         start_dormant_operation_monitor/4]).

-ifdef(TEST).
-export([test_options/1, test_put_evidence/2,
         test_put_generation/3,
         test_valid_validator_routes/2,
         test_valid_phase_evidence/5,
         test_initial_commands/4,
         test_local_submit_result/2, test_remote_submit_result/2,
         test_submit_endpoint_requests/4,
         test_endpoint_request_candidates/5,
         test_status/1]).
-endif.

-define(DEFAULT_REQUEST_TIMEOUT_MS, 5000).
-define(DEFAULT_RETRY_INITIAL_MS, 100).
-define(DEFAULT_RETRY_MAX_MS, 5000).
-define(MAX_RETRY_MS, 60000).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).

%% A Common Test may stop the coordinator at an exact certified phase.  The
%% production build expands this to `ok`: no hook lookup, message, state, or
%% exported test API exists outside the TEST profile.
-ifdef(TEST).
-define(TEST_PHASE_BARRIER(Owner, GroupId, Event),
        test_phase_barrier(Owner, GroupId, Event)).
-define(TEST_HANDLE_LOOP_MESSAGE(Message, State),
        test_handle_loop_message(Message, State)).
-else.
-define(TEST_PHASE_BARRIER(_Owner, _GroupId, _Event), ok).
-define(TEST_HANDLE_LOOP_MESSAGE(_Message, State), loop(State)).
-endif.

-record(config, {
    request_timeout_ms = ?DEFAULT_REQUEST_TIMEOUT_MS :: pos_integer(),
    retry_initial_ms = ?DEFAULT_RETRY_INITIAL_MS :: pos_integer(),
    retry_max_ms = ?DEFAULT_RETRY_MAX_MS :: pos_integer()
}).

-record(state, {
    owner :: pid(),
    owner_monitor = undefined :: undefined | reference(),
    owner_ns :: binary(),
    origin :: {binary(), <<_:256>>},
    group_id :: <<_:256>>,
    begin_record :: quod_dtx:control_record(),
    snapshot :: quod_dtx_recovery:snapshot(),
    %% Exact post-Finalize routes are only authenticated bootstrap hints for
    %% the shared current-view verifier. At most one row per participant.
    finalize_routes = #{} :: map(),
    %% A submit acknowledgement carries an exact certified reference.  If the
    %% local/foreign history verifier is momentarily behind that commit, retain
    %% the reference and retry verification; never submit the semantic phase a
    %% second time merely because its durable evidence is not readable yet.
    pending_phase = none ::
      none |
      {reference, {binary(), <<_:256>>}, <<_:256>>,
       'begin' | prepare | decision | finalize | complete,
       quod_dtx:certified_ref(), term()} |
      {submission, {binary(), <<_:256>>}, <<_:256>>,
       'begin' | prepare | decision | finalize | complete},
    follows = #{} :: #{{binary(), <<_:256>>} => reference()},
    commands = [] :: [quod_dtx_recovery:command()],
    retry_ms :: pos_integer(),
    retry_timer = none :: none | {reference(), reference()},
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
Start recovery for one already-committed foreign singleton claim.

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
-spec start_dormant_operation_monitor(
        pid(), binary(), #transaction{}, <<_:256>>) ->
          {ok, pid()} | {error, term()}.
start_dormant_operation_monitor(
  Owner, OwnerNs, Claim = #transaction{}, <<_:256>> = CancelToken)
  when is_pid(Owner), is_binary(OwnerNs), byte_size(OwnerNs) > 0 ->
    case dormant_operation_context(OwnerNs, Claim, CancelToken) of
        {ok, Context} ->
            {ok, spawn(fun() ->
                               dormant_operation_init(Owner, Context)
                       end)};
        {error, _} = Error ->
            Error
    end;
start_dormant_operation_monitor(_Owner, _OwnerNs, _Claim, _CancelToken) ->
    {error, invalid_operation_start}.

dormant_operation_context(
  OwnerNs,
  #transaction{origin = {OwnerNs, <<_:256>> = OriginAnchor},
               tx_id = <<_:256>> = ClaimTxId,
               role = {remote_claim, _Manifest,
                       {{TargetNs, <<_:256>> = TargetAnchor} = Target,
                        _PlanDigest, PlanBlob, _Attestation},
                       <<_:256>> = TargetTxId}},
  CancelToken) ->
    case quod_dtx:decode(PlanBlob) of
        {ok, Plan} ->
            case quod_dtx:signer(Plan) of
                <<_:256>> = TargetNode ->
                    {ok, #{owner_ns => OwnerNs,
                           claim_tx_id => ClaimTxId,
                           claim_ref => {transaction, OwnerNs, OriginAnchor,
                                         ClaimTxId},
                           target => Target, target_node => TargetNode,
                           target_ref => {transaction, TargetNs,
                                          TargetAnchor, TargetTxId},
                           cancel_token => CancelToken,
                           follow => none,
                           foreign_monitor => none}};
                _ -> {error, invalid_operation_claim}
            end;
        {error, _} -> {error, invalid_operation_claim}
    end;
dormant_operation_context(_OwnerNs, _Claim, _CancelToken) ->
    {error, invalid_operation_claim}.

dormant_operation_init(Owner, Context) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    dormant_operation_cancel(Owner, OwnerMonitor, Context).

dormant_operation_cancel(
  Owner, OwnerMonitor,
  #{owner_ns := OwnerNs, target := Target, target_node := TargetNode,
    claim_ref := ClaimRef, target_ref := TargetRef,
    cancel_token := CancelToken} = Context) ->
    RequestId = crypto:strong_rand_bytes(
                  ?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS div 8),
    Request = {cancel_operation_effect, RequestId, ClaimRef, TargetRef,
               CancelToken},
    case quod_dtx_current_view:submit_operation_to(
           OwnerNs, Target, TargetNode, Request,
           ?DEFAULT_REQUEST_TIMEOUT_MS) of
        {ok, Response} ->
            case quod_dtx_endpoint:correlates(Request, Response) of
                true -> dormant_operation_finish(Owner, Context);
                false -> dormant_operation_wait(
                           Owner, OwnerMonitor, Context)
            end;
        {error, _} ->
            dormant_operation_wait(Owner, OwnerMonitor, Context)
    end.

dormant_operation_finish(
  _Owner, #{owner_ns := OwnerNs, claim_tx_id := ClaimTxId}) ->
    _ = quod_simplex:cancel_transaction_custody(OwnerNs, ClaimTxId),
    ok.

dormant_operation_wait(Owner, OwnerMonitor,
                       Context = #{target := Target}) ->
    Waiting = operation_attach_follow(Context, Target),
    FollowRef = map_get(follow, Waiting),
    ForeignMonitor = map_get(foreign_monitor, Waiting),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            operation_cleanup_wait(Waiting);
        {gproc, unreg, ForeignMonitor, _Key}
          when is_reference(ForeignMonitor) ->
            dormant_operation_wait(
              Owner, OwnerMonitor, Waiting#{follow => none});
        {gproc, registered, ForeignMonitor, _Key}
          when is_reference(ForeignMonitor) ->
            dormant_operation_wait(Owner, OwnerMonitor, Waiting);
        {quod_foreign_follow, FollowRef, NoticeRef, _Identity, _Notice}
          when is_reference(FollowRef) ->
            ok = quod_foreign_log:ack(FollowRef, NoticeRef),
            dormant_operation_cancel(
              Owner, OwnerMonitor, operation_clear_follow(Waiting));
        _Other ->
            dormant_operation_wait(Owner, OwnerMonitor, Waiting)
    end.

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
  Owner, _OwnerMonitor, _Request, _Response,
  #{operation_ref := OperationRef}) ->
    operation_stop(Owner, OperationRef, invalid_target_response).

operation_target_result(
  Owner, OwnerMonitor, Request, Response, _Result, EvidenceBlob,
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
                     retry_ms = Config#config.retry_initial_ms,
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

options(Options) when map_size(Options) =< 3 ->
    Allowed = [request_timeout_ms, retry_initial_ms, retry_max_ms],
    case lists:all(fun(Key) -> lists:member(Key, Allowed) end,
                   maps:keys(Options)) of
        true ->
            Request = maps:get(request_timeout_ms, Options,
                               ?DEFAULT_REQUEST_TIMEOUT_MS),
            Initial = maps:get(retry_initial_ms, Options,
                               ?DEFAULT_RETRY_INITIAL_MS),
            Maximum = maps:get(retry_max_ms, Options,
                               ?DEFAULT_RETRY_MAX_MS),
            case is_integer(Request) andalso Request > 0 andalso
                 Request =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS andalso
                 is_integer(Initial) andalso Initial > 0 andalso
                 is_integer(Maximum) andalso Maximum >= Initial andalso
                 Maximum =< ?MAX_RETRY_MS of
                true ->
                    {ok, #config{request_timeout_ms = Request,
                                 retry_initial_ms = Initial,
                                 retry_max_ms = Maximum}};
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
    self() ! drive,
    loop(S0#state{owner_monitor = OwnerMonitor}).

loop(S) ->
    receive
        Message -> handle_loop_message(Message, S)
    end.

handle_loop_message(drive, S) ->
    continue(drive(S));
handle_loop_message({retry, Tag}, S) ->
    case S#state.retry_timer of
        {Tag, _Timer} ->
            continue(drive(S#state{retry_timer = none}));
        _Stale ->
            loop(S)
    end;
handle_loop_message(
  {quod_foreign_follow, FollowRef, NoticeRef, Identity, Notice},
  S = #state{follows = Follows}) ->
    case maps:get(Identity, Follows, undefined) of
        FollowRef ->
            ok = quod_foreign_log:ack(FollowRef, NoticeRef),
            case Notice of
                {advanced, _, _, _, _, _, _} -> self() ! drive;
                {resnapshot, _, _, _} -> self() ! drive;
                _ -> ok
            end,
            loop(S);
        _ ->
            loop(S)
    end;
handle_loop_message(
  {'DOWN', Monitor, process, Owner, _Reason},
  #state{owner_monitor = Monitor, owner = Owner}) ->
    ok;
handle_loop_message(_Message, S) ->
    ?TEST_HANDLE_LOOP_MESSAGE(_Message, S).

continue({next, S}) -> loop(S);
continue(stop) -> ok.

drive(S = #state{pending_phase =
                   {reference, Target, GroupId, Kind, Ref, Preferred}}) ->
    case verify_accepted_phase(
           Target, GroupId, Kind, Ref, Preferred, S) of
        {progress, S1, Phase} ->
            notify(S1, {progress, Phase}),
            self() ! drive,
            {next,
             reset_backoff(
               S1#state{pending_phase = none, commands = []})};
        {retry, S1} ->
            {next, wait_for_progress(Target, S1#state{commands = []})};
        {fatal, Reason, S1} ->
            terminate_expected(Reason, S1)
    end;
drive(S = #state{pending_phase =
                   {submission, Target, GroupId, Kind}}) ->
    case observe_uncertain_phase(Target, GroupId, Kind, S) of
        {progress, S1, Phase} ->
            notify(S1, {progress, Phase}),
            self() ! drive,
            {next,
             reset_backoff(
               S1#state{pending_phase = none, commands = []})};
        {retry, S1} ->
            {next, schedule_retry(S1#state{commands = []})};
        {absent, S1} ->
            %% Admission and phase inspection serialize in the target
            %% Simplex. A fresh absence after the retained submission has
            %% disappeared therefore proves this process can no longer commit
            %% it; the planner may safely mint the next envelope.
            self() ! drive,
            {next,
             reset_backoff(
               S1#state{pending_phase = none, commands = []})};
        {fatal, Reason, S1} ->
            terminate_expected(Reason, S1)
    end;
drive(S = #state{commands = []}) ->
    case quod_dtx_recovery:next(S#state.begin_record, S#state.snapshot) of
        {done, CompleteRef} ->
            notify(S, {done, CompleteRef}),
            stop;
        {ok, [_ | _] = Commands}
          when length(Commands) =< ?QUOD_MAX_DTX_PARTICIPANTS ->
            self() ! drive,
            {next, S#state{commands = Commands}};
        {ok, _MalformedCommands} ->
            terminate_expected(invalid_recovery_commands, S);
        {error, Reason} ->
            terminate_expected({invalid_recovery_state, Reason}, S)
    end;
drive(S0 = #state{commands = [Command | Rest]}) ->
    case run_command(Command, S0) of
        {progress, S1, Phase} ->
            notify(S1, {progress, Phase}),
            %% Newly certified evidence can invalidate the remainder of the
            %% planner's previous batch. Re-plan from the exact new snapshot.
            self() ! drive,
            {next, reset_backoff(S1#state{commands = []})};
        {retry, S1} when Rest =/= [] ->
            self() ! drive,
            {next, S1#state{commands = Rest}};
        {retry, S1} ->
            {next, schedule_retry(S1#state{commands = []})};
        {wait, S1} ->
            {next, S1#state{commands = []}};
        {fatal, Reason, S1} ->
            terminate_expected(Reason, S1)
    end.

terminate_expected(Reason, S) ->
    notify(S, {error, Reason}),
    stop.

notify(#state{owner = Owner, group_id = GroupId}, Event) ->
    Owner ! {dtx_coordinator, self(), GroupId, Event},
    ?TEST_PHASE_BARRIER(Owner, GroupId, Event),
    ok.

-ifdef(TEST).
test_handle_loop_message({dtx_coordinator_test_status, From, Ref}, S)
  when is_pid(From), is_reference(Ref) ->
    From ! {Ref, test_status_map(S)},
    loop(S);
test_handle_loop_message(_Message, S) ->
    loop(S).

test_status(Pid) when is_pid(Pid) ->
    Ref = make_ref(),
    MRef = erlang:monitor(process, Pid),
    Pid ! {dtx_coordinator_test_status, self(), Ref},
    receive
        {Ref, Status} ->
            _ = erlang:demonitor(MRef, [flush]),
            {ok, Status};
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, Reason}
    after 6000 ->
        _ = erlang:demonitor(MRef, [flush]),
        {error, timeout}
    end;
test_status(_Pid) ->
    {error, badarg}.

test_status_map(#state{group_id = GroupId, pending_phase = Pending,
                       commands = Commands, retry_ms = RetryMs,
                       retry_timer = RetryTimer}) ->
    #{group_id => GroupId, pending_phase => Pending,
      commands => Commands, retry_ms => RetryMs,
      retry_timer => RetryTimer}.

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

reset_backoff(S = #state{config = Config}) ->
    cancel_retry(S#state.retry_timer),
    S#state{retry_ms = Config#config.retry_initial_ms,
            retry_timer = none}.

schedule_retry(S = #state{retry_timer = none, retry_ms = Delay,
                           config = Config}) ->
    Tag = make_ref(),
    Timer = erlang:send_after(Delay, self(), {retry, Tag}),
    Next = min(Config#config.retry_max_ms, Delay * 2),
    S#state{retry_ms = Next, retry_timer = {Tag, Timer}};
schedule_retry(S) ->
    S.

cancel_retry(none) -> ok;
cancel_retry({_Tag, Timer}) ->
    _ = erlang:cancel_timer(Timer),
    ok.

%% ------------------------------------------------------------------
%% One bounded planner command
%% ------------------------------------------------------------------

run_command({submit, Target, Record}, S) ->
    submit_record(Target, Record, S);
run_command({phase, Target, GroupId, Kind}, S) ->
    phase_request(Target, GroupId, Kind, S);
run_command({applied, Target, GroupId, FinalizeRef, Generation, Verdict}, S) ->
    applied_request(
      Target, GroupId, FinalizeRef, Generation, Verdict, S).

submit_record(Target, Record, S) ->
    try
        Kind = quod_dtx:record_kind(Record),
        GroupId = quod_dtx:group_id(Record),
        case quod_dtx:encode_record(Record) of
            {ok, RecordBlob} ->
                Request = {submit, request_id(), RecordBlob},
                handle_submit_response(
                  Target, GroupId, Kind, Request,
                  submit_endpoint_request(Target, Request, S), S);
            {error, Reason} ->
                {fatal, {invalid_recovery_record, Reason}, S}
        end
    catch
        _:_ -> {fatal, invalid_recovery_record, S}
    end.

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
    {retry,
     S#state{pending_phase =
               {submission, Target, GroupId, Kind}}};
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
       S#state{pending_phase =
                 {reference, Target, GroupId, Kind, Ref, Source}})};
accepted_phase_result(_Target, _GroupId, _Kind, _Ref, _Source,
                      {fatal, _Reason, _S1} = Fatal) ->
    Fatal.

wait_for_progress(Target, S = #state{follows = Follows}) ->
    case maps:get(Target, Follows, undefined) of
        FollowRef when is_reference(FollowRef) ->
            ok = quod_foreign_log:refresh(FollowRef),
            S;
        undefined ->
            case quod_foreign_log:follow(Target) of
                {ok, FollowRef} ->
                    ok = quod_foreign_log:refresh(FollowRef),
                    S#state{follows = Follows#{Target => FollowRef}};
                {error, _} ->
                    schedule_retry(S)
            end
    end.

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
    {remote, PeerKey}.

phase_request(Target, GroupId, Kind, S) ->
    observe_phase(Target, GroupId, Kind, any, S).

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
               endpoint_request(Source, Target, Request, S), S),
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
        true -> verify_phase(Target, GroupId, Kind, Ref, Source, S);
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
               endpoint_request(Source, Target, Request, S), S),
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

handle_phase_response(
  Target, GroupId, Kind, Request,
  {ok, {phase, _RequestId, _Generation, {committed, Ref}} = Response,
   Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> verify_phase(Target, GroupId, Kind, Ref, Source, S);
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_phase_response(
  Target, _GroupId, prepare, Request,
  {ok, {phase, _RequestId, Generation, Status} = Response, _Source}, S)
  when Status =:= not_found; Status =:= pending ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> put_generation(Target, Generation, S);
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_phase_response(
  _Target, _GroupId, _Kind, Request,
  {ok, {phase, _RequestId, _Generation, Status} = Response, _Source}, S)
  when Status =:= not_found; Status =:= pending ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> {retry, S};
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_phase_response(
  _Target, _GroupId, _Kind, Request,
  {ok, {error, _RequestId, Reason} = Response, _Source}, S) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true when Reason =:= busy; Reason =:= not_ready;
                  Reason =:= not_found -> {retry, S};
        true when Reason =:= invalid_request ->
            {fatal, endpoint_rejected_phase_query, S};
        false -> {fatal, invalid_endpoint_response, S}
    end;
handle_phase_response(_Target, _GroupId, _Kind, _Request,
                      {error, _Transient}, S) ->
    {retry, S};
handle_phase_response(_Target, _GroupId, _Kind, _Request, _Malformed, S) ->
    {fatal, invalid_endpoint_response, S}.

verify_phase(Target = {Ns, _Anchor}, GroupId, Kind, Ref, local, S) ->
    case quod_simplex:dtx_local_evidence(Ns, Ref, Kind) of
        {ok, Evidence} -> install_phase_evidence(
                            Target, GroupId, Kind, Ref, Evidence, S);
        {error, _} -> {retry, S}
    end;
verify_phase(Target, GroupId, Kind, Ref,
             {remote, _PeerKey}, S = #state{config = Config}) ->
    case quod_foreign_log:verify_reference(
           Ref, Kind, Config#config.request_timeout_ms) of
        {ok, Evidence} -> install_phase_evidence(
                            Target, GroupId, Kind, Ref, Evidence, S);
        {error, _} -> {retry, S}
    end.

install_phase_evidence(Target, GroupId, Kind, Ref, Evidence, S) ->
    case valid_phase_evidence(Target, GroupId, Kind, Ref, Evidence) of
        {ok, Control, Generation, View} ->
            case put_evidence({Target, Control, Ref}, S) of
                {progress, S1} ->
                    install_phase_metadata(
                      Target, Kind, Generation, Ref, View, new, S1);
                {same, S1} ->
                    install_phase_metadata(
                      Target, Kind, Generation, Ref, View, known, S1);
                {error, Reason} ->
                    {fatal, Reason, S}
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
    true = valid_generation(Generation),
    true = valid_committee(Committee),
    true = valid_validator_routes(Routes, Committee),
    true = is_binary(CommitteeId) andalso byte_size(CommitteeId) =:= 32,
    case signed_phase_binding(Target, GroupId, Kind, Ref, Control) of
        ok ->
            {ok, Control, Generation,
             #{committee => Committee, committee_id => CommitteeId,
               routes => Routes}};
        error ->
            error
    end;
valid_phase_evidence(_Target, _GroupId, _Kind, _Ref, _Evidence) ->
    error.

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

install_phase_metadata(Target, prepare, Generation, _Ref, _View, Freshness,
                       S0) ->
    S = clear_refusal(Target, S0),
    Result = case Freshness of
                 new -> put_verified_generation(Target, Generation, S);
                 known -> put_generation(Target, Generation, S)
             end,
    case Result of
        {progress, S1, _} -> {progress, S1, {prepared, Target}};
        {retry, S1} -> {progress, S1, {prepared, Target}};
        {fatal, Reason, S1} -> {fatal, Reason, S1}
    end;
install_phase_metadata(Target, finalize, _Generation, Ref, View, _Freshness,
                       S = #state{finalize_routes = FinalizeRoutes}) ->
    Routes = maps:get(routes, View),
    case maps:get(Target, FinalizeRoutes, undefined) of
        undefined ->
            {progress, S#state{finalize_routes =
                                  FinalizeRoutes#{Target => {Ref, Routes}}},
             {finalized, Target}};
        {Ref, Routes} ->
            {progress, S, {finalized, Target}};
        _Conflicting ->
            {fatal, conflicting_finalize_view, S}
    end;
install_phase_metadata(_Target, decision, _Generation, _Ref, _View,
                       _Freshness, S) ->
    %% A certified Decision already carries the exact abort reason stack.
    %% The pre-Decision refusal was only volatile construction input; retaining
    %% it would wrongly pin the target's unsigned generation hint forever.
    {progress, clear_refusal(S), decided};
install_phase_metadata(Target, Kind, _Generation, _Ref, _View, _Freshness, S) ->
    {progress, S, phase_progress(Kind, Target)}.

phase_progress('begin', _Target) -> begun;
phase_progress(complete, _Target) -> completed.

applied_request(Target, GroupId, FinalizeRef, Generation, Verdict,
                S = #state{finalize_routes = FinalizeRoutes}) ->
    case maps:get(Target, FinalizeRoutes, undefined) of
        {FinalizeRef, HistoricalRoutes} ->
            case applied_source(Target, FinalizeRef, HistoricalRoutes) of
                {ok, Source} ->
                    Claim = #{target => Target, group_id => GroupId,
                              finalize_ref => FinalizeRef,
                              generation => Generation, verdict => Verdict},
                    Timeout = (S#state.config)#config.request_timeout_ms,
                    case quod_dtx_current_view:verify_applied(
                           S#state.owner_ns, Source, Claim, Timeout) of
                        {ok, #{committee_id := CommitteeId}} ->
                            put_applied(
                              {Target, CommitteeId, GroupId, FinalizeRef,
                               Generation, Verdict}, S);
                        {error, retry} ->
                            {retry, S};
                        {error, invalid_request} ->
                            {fatal, invalid_applied_claim, S}
                    end;
                {error, retry} ->
                    {retry, S}
            end;
        undefined ->
            {fatal, missing_finalize_view, S};
        _Conflicting ->
            {fatal, conflicting_finalize_view, S}
    end.

applied_source({Ns, _Anchor} = Target, FinalizeRef, HistoricalRoutes) ->
    case cohosted(Target) of
        true ->
            case quod_simplex:dtx_applied_source(Ns, FinalizeRef) of
                {ok, {local, _LedgerRoot} = Source} -> {ok, Source};
                {error, _} -> {error, retry}
            end;
        false ->
            Historical =
                [{PeerKey, Endpoint}
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

submit_endpoint_request(Target, Request, S) ->
    Sources = endpoint_sources(Target, any),
    submit_endpoint_requests(Sources, Target, Request, S).

submit_reply({ok, Response, Source}) -> {reply, Response, Source}.

local_submit_result(
  Request, {ok, Response, local}) ->
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

endpoint_request(local, {Ns, _Anchor}, Request,
                 #state{config = Config}) ->
    case quod_simplex:dtx_endpoint_local(
           Ns, Request, Config#config.request_timeout_ms) of
        {ok, Response} -> {ok, Response, local};
        {error, _} = Error -> Error
    end;
endpoint_request({remote, PeerKey, Endpoints}, Target, Request, S) ->
    {TargetNs, _Anchor} = Target,
    #state{owner_ns = OwnerNs, config = Config} = S,
    Deadline = quod_time:mono_ms() + Config#config.request_timeout_ms,
    RequestFun =
        fun(Endpoint, CandidateRequest, Timeout) ->
            quod_simplex:dtx_endpoint_request(
              OwnerNs, TargetNs, PeerKey, Endpoint, CandidateRequest, Timeout)
        end,
    endpoint_request_candidates(
      Endpoints, PeerKey, Request, Deadline, undefined, RequestFun).

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
                {ok, Response} ->
                    Candidate = {ok, Response, {remote, PeerKey}},
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
            end
    end.

submit_endpoint_requests([], _Target, _Request, _S) ->
    not_submitted;
submit_endpoint_requests(Sources, Target, Request,
                         #state{owner_ns = OwnerNs, config = Config} = S) ->
    quod_metrics:count_dtx_submit_fanout(
      OwnerNs, attempted, length(Sources)),
    RequestFun = fun(Source) ->
                     endpoint_request(Source, Target, Request, S)
                 end,
    submit_endpoint_requests_with(
      Sources, Request, Config#config.request_timeout_ms, RequestFun,
      OwnerNs).

submit_endpoint_requests_with(
  Sources, Request, TimeoutMs, RequestFun, MetricsNs) ->
    Parent = self(),
    BatchRef = make_ref(),
    Pending = maps:from_list(
                [begin
                     {Pid, MRef} = spawn_monitor(
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

-ifdef(TEST).
test_submit_endpoint_requests(Sources, Request, TimeoutMs, RequestFun) ->
    submit_endpoint_requests_with(
      Sources, Request, TimeoutMs, RequestFun, <<"quod:test">>).

test_endpoint_request_candidates(
  Endpoints, PeerKey, Request, TimeoutMs, RequestFun) ->
    endpoint_request_candidates(
      Endpoints, PeerKey, Request,
      quod_time:mono_ms() + TimeoutMs, undefined, RequestFun).
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

put_applied(Row = {Target, _CommitteeId, _GroupId, _FinalizeRef,
                   _Generation, _Verdict},
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
test_remote_submit_result(Request, Response) ->
    remote_submit_result(Request, Response).
-endif.
