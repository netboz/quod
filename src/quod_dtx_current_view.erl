-module(quod_dtx_current_view).
-moduledoc """
Bounded current-view corroboration for DTX recovery reads.

Each operation first freezes one certificate-verified committee view for the
exact `{Namespace, GenesisAnchor}` identity. It then asks distinct members of
that frozen view for a response bound to its committee id and minimum certified
slot. `f + 1` matching current-validator replies are required, so one Byzantine
responder can never decide an applied claim or public outcome.

Routes are identity-pinned transport hints, never committee evidence. There is
no owner process, second history cache, or retained proof object: every call
uses the shared `quod_foreign_log` cache and bounded temporary probes, and
returns `retry` whenever history, routing, membership, application, or a reply
is uncertain. One probe is created per validator key; that probe may try two
ordered endpoints sequentially without creating another vote or request id.
""".

-include("quod_proof_limits.hrl").

-export([verify_applied/4, verify_applied_many/3, lookup_outcome/4]).
-export_type([source/0, claim/0]).

-ifdef(TEST).
-export([test_verify_applied/5, test_verify_applied_many/4,
         test_lookup_outcome/5, test_threshold/1]).
-endif.

-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).
-define(PROBE_CLEANUP_MS, 1000).

-type identity() :: {binary(), <<_:256>>}.
-type source() ::
        {local, file:filename_all()} |
        {remote, [{<<_:256>>, [term()]}]}.
-type claim() ::
        #{target := identity(),
          group_id := <<_:256>>,
          finalize_ref := quod_dtx:certified_ref(),
          generation := non_neg_integer(),
          verdict := commit | abort}.
-type result() :: {ok, map()} | {error, retry | invalid_request}.
-type outcome_result() ::
        {ok, map()} | {error, retry | not_found | invalid_request}.

-doc """
Verify one exact participant-applied claim against a certified current view.

`OwnerNs` is the namespace whose engine owns remote endpoint correlations.
For a co-hosted target, `Source` names its ledger root; otherwise it carries
the exact-anchor route hints used to establish the certified current view.
`TimeoutMs` bounds the complete view-and-probe operation.
""".
-spec verify_applied(binary(), source(), claim(), pos_integer()) -> result().
verify_applied(OwnerNs, Source, Claim, TimeoutMs) ->
    verify_applied_with(
      OwnerNs, Source, Claim, TimeoutMs, production_dependencies()).

-doc "Verify every participant claim concurrently under one bounded deadline.".
-spec verify_applied_many(binary(), [{source(), claim()}], pos_integer()) ->
          {ok, [map()]} | {error, retry | invalid_request}.
verify_applied_many(OwnerNs, Requests, TimeoutMs) ->
    verify_applied_many_with(
      OwnerNs, Requests, TimeoutMs, production_dependencies()).

-doc """
Resolve one anchored public outcome through a frozen certified current view.

Terminal and ledger-derived pending statuses require `f + 1` identical
current-validator replies. After a group is absent from that quorum snapshot,
the certified view may prove its coordinator retired; if that key is still
current, only its exact admission-bound coordinator barrier may decide local
pre-Begin state. Ordinary absence is never made definitive by this API and
remains `retry`.
""".
-spec lookup_outcome(binary(), source(), term(), pos_integer()) ->
          outcome_result().
lookup_outcome(OwnerNs, Source, OutcomeRef, TimeoutMs) ->
    lookup_outcome_with(
      OwnerNs, Source, OutcomeRef, TimeoutMs, production_dependencies()).

lookup_outcome_with(OwnerNs, Source, OutcomeRef, TimeoutMs, Dependencies) ->
    case valid_outcome_request(OwnerNs, Source, OutcomeRef, TimeoutMs) of
        {ok, Target} ->
            Deadline = quod_time:mono_ms() + TimeoutMs,
            case call_current_view(
                   Source, {identity, Target}, Deadline, Dependencies) of
                {ok, View} ->
                    lookup_outcome_view(
                      OwnerNs, Source, OutcomeRef, Target, View,
                      Deadline, Dependencies);
                {error, _} ->
                    {error, retry}
            end;
        error ->
            {error, invalid_request}
    end.

production_dependencies() ->
    #{view =>
          fun({local, LedgerRoot}, {finalize, Ref}, Timeout) ->
                  quod_foreign_log:verify_local_current(
                    LedgerRoot, Ref, Timeout);
             ({remote, Routes}, {finalize, Ref}, Timeout) ->
                  quod_foreign_log:verify_current(Routes, Ref, Timeout);
             ({local, LedgerRoot}, {identity, Identity}, Timeout) ->
                  quod_foreign_log:local_current(
                    LedgerRoot, Identity, Timeout);
             ({remote, Routes}, {identity, Identity}, Timeout) ->
                  quod_foreign_log:current(Routes, Identity, Timeout)
          end,
      local =>
          fun(TargetNs, Request, Timeout) ->
                  quod_simplex:dtx_endpoint_local(TargetNs, Request, Timeout)
          end,
      remote =>
          fun(Owner, TargetNs, PeerKey, Endpoint, Request, Timeout) ->
                  quod_simplex:dtx_endpoint_request(
                    Owner, TargetNs, PeerKey, Endpoint, Request, Timeout)
          end,
      node_key => fun node_key/0}.

verify_applied_with(OwnerNs, Source, Claim, TimeoutMs, Dependencies) ->
    case valid_request(OwnerNs, Source, Claim, TimeoutMs) of
        {ok, Target, GroupId, FinalizeRef, Generation, Verdict} ->
            Deadline = quod_time:mono_ms() + TimeoutMs,
            case call_current_view(
                   Source, {finalize, FinalizeRef}, Deadline,
                   Dependencies) of
                {ok, View} ->
                    verify_view(
                      OwnerNs, Source, Target, GroupId, FinalizeRef,
                      Generation, Verdict, View, Deadline, Dependencies);
                {error, _} ->
                    {error, retry}
            end;
        error ->
            {error, invalid_request}
    end.

verify_applied_many_with(OwnerNs, Requests, TimeoutMs, Dependencies)
  when is_list(Requests), Requests =/= [],
       length(Requests) =< ?QUOD_MAX_DTX_PARTICIPANTS,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS ->
    case lists:all(
           fun({Source, Claim}) ->
                   case valid_request(
                          OwnerNs, Source, Claim, TimeoutMs) of
                       {ok, _, _, _, _, _} -> true;
                       error -> false
                   end;
              (_) -> false
           end, Requests) of
        true ->
            verify_applied_many_requests(
              OwnerNs, Requests, TimeoutMs, Dependencies);
        false ->
            {error, invalid_request}
    end;
verify_applied_many_with(_OwnerNs, _Requests, _TimeoutMs, _Dependencies) ->
    {error, invalid_request}.

verify_applied_many_requests(OwnerNs, Requests, TimeoutMs, Dependencies) ->
    Parent = self(),
    VerifyRef = make_ref(),
    Pending =
        lists:foldl(
          fun({Index, {Source, Claim}}, Acc) ->
                  {Pid, Monitor} = spawn_opt(
                    fun() ->
                        Result = verify_applied_with(
                                   OwnerNs, Source, Claim, TimeoutMs,
                                   Dependencies),
                        Parent ! {dtx_current_view_many, VerifyRef, self(),
                                  Index, Result}
                    end, [link, monitor]),
                  Acc#{Pid => {Monitor, Index}}
          end, #{}, lists:enumerate(Requests)),
    Deadline = quod_time:mono_ms() + TimeoutMs,
    collect_many_results(VerifyRef, Pending, #{}, Deadline).

collect_many_results(VerifyRef, Pending, Results, _Deadline)
  when map_size(Pending) =:= 0 ->
    flush_worker_results(dtx_current_view_many, VerifyRef),
    {ok, [View || {_Index, View} <- lists:keysort(1, maps:to_list(Results))]};
collect_many_results(VerifyRef, Pending, Results, Deadline) ->
    case remaining(Deadline) of
        0 ->
            stop_workers(dtx_current_view_many, VerifyRef, Pending),
            {error, retry};
        Wait ->
            receive
                {dtx_current_view_many, VerifyRef, Pid, Index, {ok, View}}
                  when is_map_key(Pid, Pending) ->
                    case maps:take(Pid, Pending) of
                        {{Monitor, Index}, Rest} ->
                            _ = erlang:demonitor(Monitor, [flush]),
                            collect_many_results(
                              VerifyRef, Rest, Results#{Index => View},
                              Deadline);
                        {{Monitor, _OtherIndex}, Rest} ->
                            _ = erlang:demonitor(Monitor, [flush]),
                            stop_workers(dtx_current_view_many, VerifyRef, Rest),
                            {error, retry}
                    end;
                {dtx_current_view_many, VerifyRef, Pid, _Index, {error, Reason}}
                  when is_map_key(Pid, Pending),
                       (Reason =:= retry orelse Reason =:= invalid_request) ->
                    {{Monitor, _}, Rest} = maps:take(Pid, Pending),
                    _ = erlang:demonitor(Monitor, [flush]),
                    stop_workers(dtx_current_view_many, VerifyRef, Rest),
                    {error, Reason};
                {'DOWN', Monitor, process, Pid, _Reason}
                  when is_map_key(Pid, Pending) ->
                    case maps:get(Pid, Pending) of
                        {Monitor, _Index} ->
                            Rest = maps:remove(Pid, Pending),
                            stop_workers(
                              dtx_current_view_many, VerifyRef, Rest),
                            {error, retry};
                        _ ->
                            collect_many_results(
                              VerifyRef, Pending, Results, Deadline)
                    end
            after Wait ->
                stop_workers(dtx_current_view_many, VerifyRef, Pending),
                {error, retry}
            end
    end.

valid_request(OwnerNs, Source,
              #{target := {TargetNs, <<_:256>> = Anchor} = Target,
                group_id := <<_:256>> = GroupId,
                finalize_ref := FinalizeRef,
                generation := Generation,
                verdict := Verdict} = Claim,
              TimeoutMs)
  when is_binary(OwnerNs), byte_size(OwnerNs) > 0,
       is_binary(TargetNs), byte_size(TargetNs) > 0,
       map_size(Claim) =:= 5,
       is_integer(Generation), Generation >= 0, Generation =< ?MAX_UINT64,
       (Verdict =:= commit orelse Verdict =:= abort),
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS ->
    case {valid_source(Source),
          quod_dtx:certified_ref_binding(FinalizeRef)} of
        {true, {ok, {TargetNs, Anchor}, _Slot, <<_:256>>}} ->
            {ok, Target, GroupId, FinalizeRef, Generation, Verdict};
        _ ->
            error
    end;
valid_request(_OwnerNs, _Source, _Claim, _TimeoutMs) ->
    error.

valid_outcome_request(OwnerNs, Source, OutcomeRef, TimeoutMs)
  when is_binary(OwnerNs), byte_size(OwnerNs) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS ->
    case {valid_source(Source), quod_outcome:ref_identity(OutcomeRef)} of
        {true, {ok, Target}} -> {ok, Target};
        _ -> error
    end;
valid_outcome_request(_OwnerNs, _Source, _OutcomeRef, _TimeoutMs) ->
    error.

lookup_outcome_view(OwnerNs, Source, OutcomeRef, Target, View,
                    Deadline, Dependencies) ->
    case valid_identity_current_view(Target, View) of
        {ok, Committee, CommitteeId, MinimumSlot, Routes} ->
            Sources = probe_sources(
                        Source, Committee, Routes, Dependencies),
            Needed = threshold(length(Committee)),
            case length(Sources) >= Needed andalso remaining(Deadline) > 0 of
                true ->
                    Claim = {Target, CommitteeId, MinimumSlot, OutcomeRef},
                    case collect_outcomes(
                           OwnerNs, Sources, Claim, Needed, Deadline,
                           Dependencies) of
                        {ok, not_found} ->
                            resolve_quorum_absence(
                              OwnerNs, Sources, Committee, Claim,
                              Deadline, Dependencies);
                        {ok, Status} ->
                            {ok, Status};
                        retry ->
                            {error, retry}
                    end;
                false ->
                    {error, retry}
            end;
        error ->
            {error, retry}
    end.

resolve_quorum_absence(
  _OwnerNs, _Sources, _Committee,
  {_Target, _CommitteeId, _MinimumSlot,
   {transaction, _, _, _}}, _Deadline, _Dependencies) ->
    %% A quorum can corroborate that an ordinary transaction is absent from
    %% its applied snapshots, but no durable exclusion barrier proves that it
    %% was never handed off. Preserve uncertainty.
    {error, retry};
resolve_quorum_absence(
  OwnerNs, Sources, Committee,
  {Target, CommitteeId, MinimumSlot,
   {group, _, _, Coordinator, _, _} = GroupRef},
  Deadline, Dependencies) ->
    case lists:member(Coordinator, Committee) of
        false ->
            %% The certified current view itself proves that the admission
            %% generation named by GroupRef can no longer author Begin.
            {ok, #{status => rejected, reason => coordinator_retired,
                   ref => GroupRef}};
        true ->
            case lists:keyfind(Coordinator, 1, Sources) of
                {Coordinator, CoordinatorSource} ->
                    probe_outcome_barrier(
                      OwnerNs, Coordinator, CoordinatorSource,
                      {Target, CommitteeId, MinimumSlot, GroupRef},
                      Deadline, Dependencies);
                false ->
                    {error, retry}
            end
    end;
resolve_quorum_absence(
  _OwnerNs, _Sources, _Committee, _Claim, _Deadline, _Dependencies) ->
    {error, retry}.

valid_source({local, LedgerRoot}) ->
    is_list(LedgerRoot) orelse is_binary(LedgerRoot);
valid_source({remote, Routes}) when is_list(Routes), Routes =/= [],
                                    length(Routes) =< ?MAX_VALIDATORS ->
    quod_foreign_log:valid_route_candidates(Routes);
valid_source(_) ->
    false.

call_current_view(Source, Basis, Deadline, Dependencies) ->
    case remaining(Deadline) of
        0 -> {error, retry};
        Remaining ->
            %% Freezing the committee and asking that committee are one
            %% operation. Do not let a cold history fetch consume the caller's
            %% entire deadline and make the mandatory corroboration probe
            %% impossible. A retry can reuse the shared history cache.
            Timeout = erlang:max(1, Remaining - erlang:max(1, Remaining div 4)),
            View = maps:get(view, Dependencies),
            try View(Source, Basis, Timeout)
            catch exit:_ -> {error, retry}
            end
    end.

verify_view(OwnerNs, Source, Target, GroupId, FinalizeRef,
            Generation, Verdict, View, Deadline, Dependencies) ->
    case valid_current_view(Target, FinalizeRef, Generation, View) of
        {ok, Committee, CommitteeId, Routes} ->
            Sources = probe_sources(
                        Source, Committee, Routes, Dependencies),
            Needed = threshold(length(Committee)),
            case length(Sources) >= Needed andalso remaining(Deadline) > 0 of
                true ->
                    Claim = {Target, CommitteeId, GroupId, FinalizeRef,
                             Generation, Verdict},
                    case collect_applied(
                           OwnerNs, Sources, Claim, Needed, Deadline,
                           Dependencies) of
                        true -> {ok, View};
                        false -> {error, retry}
                    end;
                false ->
                    {error, retry}
            end;
        error ->
            {error, retry}
    end.

valid_current_view(Target, FinalizeRef, ClaimedGeneration,
                   #{generation := Generation} = View)
  when is_integer(Generation), Generation >= ClaimedGeneration,
       Generation =< ?MAX_UINT64 ->
    case {valid_identity_current_view(Target, View),
          quod_dtx:certified_ref_binding(FinalizeRef)} of
        {{ok, Committee, CommitteeId, Slot, Routes},
         {ok, Target, RefSlot, _Digest}}
          when Slot >= RefSlot ->
            {ok, Committee, CommitteeId, Routes};
        _ -> error
    end;
valid_current_view(_Target, _FinalizeRef, _ClaimedGeneration, _View) ->
    error.

valid_identity_current_view(
  Target,
  #{identity := Target, slot := Slot, generation := Generation,
    committee := Committee, committee_id := <<_:256>> = CommitteeId,
    route_candidates := Routes} = View)
  when map_size(View) =:= 6,
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_integer(Generation), Generation >= 0, Generation =< ?MAX_UINT64,
       is_list(Committee), Committee =/= [],
       length(Committee) =< ?MAX_VALIDATORS,
       is_list(Routes), length(Routes) =< ?MAX_VALIDATORS ->
    case Committee =:= lists:usort(Committee) andalso
         lists:all(fun valid_key/1, Committee) andalso
         valid_routes(Routes, Committee) of
        true -> {ok, Committee, CommitteeId, Slot, Routes};
        false -> error
    end;
valid_identity_current_view(_Target, _View) ->
    error.

valid_key(<<_:256>>) -> true;
valid_key(_) -> false.

valid_routes(Routes, Committee) ->
    quod_foreign_log:valid_route_candidates(Routes) andalso
        lists:all(
          fun({Key, _Endpoints}) -> lists:member(Key, Committee) end,
          Routes).

probe_sources(Source, Committee, Routes, Dependencies) ->
    LocalKey = case Source of
                   {local, _} -> dependency_node_key(Dependencies);
                   {remote, _} -> none
               end,
    lists:filtermap(
      fun(Key) when Key =:= LocalKey, LocalKey =/= none ->
              {true, {Key, local}};
         (Key) ->
              case lists:keyfind(Key, 1, Routes) of
                  {Key, Endpoints} ->
                      {true, {Key, {remote, Endpoints}}};
                  false -> false
              end
      end, Committee).

dependency_node_key(Dependencies) ->
    NodeKey = maps:get(node_key, Dependencies),
    case NodeKey() of
        <<_:256>> = Key -> Key;
        _ -> none
    end.

node_key() ->
    case application:get_env(quod, node_pubkey) of
        {ok, <<_:256>> = Key} -> Key;
        _ -> none
    end.

collect_applied(OwnerNs, Sources, Claim, Needed, Deadline, Dependencies) ->
    Probe = fun(Key, Source) ->
                    case probe_applied(
                           OwnerNs, Key, Source, Claim, Deadline,
                           Dependencies) of
                        true -> {ok, applied};
                        false -> ignore
                    end
            end,
    collect_quorum(dtx_applied_probe, Sources, Needed, Deadline, Probe)
        =:= {ok, applied}.

collect_outcomes(OwnerNs, Sources, Claim, Needed, Deadline, Dependencies) ->
    Probe = fun(Key, Source) ->
                    probe_outcome(
                      OwnerNs, Key, Source, Claim, Deadline, Dependencies)
            end,
    case collect_quorum(
           dtx_outcome_probe, Sources, Needed, Deadline, Probe) of
        {ok, Outcome} -> {ok, Outcome};
        retry -> retry
    end.

collect_quorum(Tag, Sources, Needed, Deadline, Probe) ->
    Parent = self(),
    ProbeRef = make_ref(),
    Pending = lists:foldl(
                fun({Key, Source}, Acc) ->
                    {Pid, Monitor} = spawn_opt(
                      fun() ->
                          Result = Probe(Key, Source),
                          Parent ! {Tag, ProbeRef, self(), Key, Result}
                      end, [link, monitor]),
                    Acc#{Pid => {Monitor, Key}}
                end, #{}, Sources),
    collect_quorum_results(
      Tag, ProbeRef, Pending, Needed, #{}, Deadline).

collect_quorum_results(Tag, ProbeRef, Pending, _Needed, _Counts, _Deadline)
  when map_size(Pending) =:= 0 ->
    flush_worker_results(Tag, ProbeRef),
    retry;
collect_quorum_results(Tag, ProbeRef, Pending, Needed, Counts, Deadline) ->
    case remaining(Deadline) of
        0 ->
            stop_workers(Tag, ProbeRef, Pending),
            retry;
        Wait ->
            receive
                {Tag, ProbeRef, Pid, Key, Result}
                  when is_map_key(Pid, Pending) ->
                    case maps:take(Pid, Pending) of
                        {{Monitor, Key}, Rest} ->
                            _ = erlang:demonitor(Monitor, [flush]),
                            case count_match(Result, Needed, Counts) of
                                {reached, Value} ->
                                    stop_workers(Tag, ProbeRef, Rest),
                                    {ok, Value};
                                {continue, Counts1} ->
                                    collect_quorum_results(
                                      Tag, ProbeRef, Rest, Needed,
                                      Counts1, Deadline)
                            end;
                        {{Monitor, _OtherKey}, Rest} ->
                            _ = erlang:demonitor(Monitor, [flush]),
                            collect_quorum_results(
                              Tag, ProbeRef, Rest, Needed, Counts, Deadline)
                    end;
                {'DOWN', Monitor, process, Pid, _Reason}
                  when is_map_key(Pid, Pending) ->
                    case maps:get(Pid, Pending) of
                        {Monitor, _Key} ->
                            collect_quorum_results(
                              Tag, ProbeRef, maps:remove(Pid, Pending),
                              Needed, Counts, Deadline);
                        _ ->
                            collect_quorum_results(
                              Tag, ProbeRef, Pending, Needed,
                              Counts, Deadline)
                    end
            after Wait ->
                stop_workers(Tag, ProbeRef, Pending),
                retry
            end
    end.

count_match({ok, Value}, Needed, Counts) ->
    Count = maps:get(Value, Counts, 0) + 1,
    case Count >= Needed of
        true -> {reached, Value};
        false -> {continue, Counts#{Value => Count}}
    end;
count_match(_Ignored, _Needed, Counts) ->
    {continue, Counts}.

stop_workers(Tag, Ref, Pending) ->
    maps:foreach(
      fun(Pid, _MonitorAndKey) ->
              _ = unlink(Pid),
              exit(Pid, kill)
      end, Pending),
    CleanupDeadline = quod_time:mono_ms() + ?PROBE_CLEANUP_MS,
    await_worker_downs(Tag, Ref, Pending, CleanupDeadline),
    flush_worker_results(Tag, Ref).

await_worker_downs(_Tag, _Ref, Pending, _Deadline)
  when map_size(Pending) =:= 0 ->
    ok;
await_worker_downs(Tag, Ref, Pending, Deadline) ->
    case remaining(Deadline) of
        0 ->
            maps:foreach(
              fun(_Pid, {Monitor, _Key}) ->
                      _ = erlang:demonitor(Monitor, [flush])
              end, Pending);
        Wait ->
            receive
                {'DOWN', Monitor, process, Pid, _Reason}
                  when is_map_key(Pid, Pending) ->
                    case maps:get(Pid, Pending) of
                        {Monitor, _Key} ->
                            await_worker_downs(
                              Tag, Ref, maps:remove(Pid, Pending), Deadline);
                        _ ->
                            await_worker_downs(Tag, Ref, Pending, Deadline)
                    end;
                {Tag, Ref, _Pid, _Key, _Result} ->
                    await_worker_downs(Tag, Ref, Pending, Deadline)
            after Wait ->
                maps:foreach(
                  fun(_Pid, {Monitor, _Key}) ->
                          _ = erlang:demonitor(Monitor, [flush])
                  end, Pending)
            end
    end.

flush_worker_results(Tag, Ref) ->
    receive
        {Tag, Ref, _Pid, _Key, _Result} ->
            flush_worker_results(Tag, Ref)
    after 0 ->
        ok
    end.

probe_outcome(OwnerNs, PeerKey, Source,
              {{TargetNs, _Anchor} = Target, CommitteeId, MinimumSlot,
               OutcomeRef},
              Deadline, Dependencies) ->
    Request = {outcome, request_id(), OutcomeRef,
               CommitteeId, MinimumSlot},
    probe_outcome_source(
      Source, OwnerNs, TargetNs, PeerKey, Request, Target,
      CommitteeId, Deadline, Dependencies).

probe_outcome_source(
  {remote, Endpoints}, OwnerNs, TargetNs, PeerKey, Request,
  Target, CommitteeId, Deadline, Dependencies) ->
    walk_remote_candidates(
      Endpoints, Deadline,
      fun(Endpoint, AttemptDeadline) ->
          call_endpoint(
            OwnerNs, TargetNs, PeerKey, {remote, Endpoint}, Request,
            AttemptDeadline, Dependencies)
      end,
      fun(Result) ->
          case outcome_response(Request, Target, CommitteeId, Result) of
              ignore -> continue;
              Accepted -> {done, Accepted}
          end
      end,
      ignore);
probe_outcome_source(
  local, OwnerNs, TargetNs, PeerKey, Request, Target,
  CommitteeId, Deadline, Dependencies) ->
    outcome_response(
      Request, Target, CommitteeId,
      call_endpoint(
        OwnerNs, TargetNs, PeerKey, local, Request,
        Deadline, Dependencies)).

outcome_response(
  Request, Target, CommitteeId,
  {ok, {outcome, _RequestId, Target, CommitteeId, _AppliedFloor,
        Outcome} = Response}) ->
    case quod_dtx_endpoint:correlates(Request, Response) andalso
         quorum_outcome_allowed(Outcome) of
        true -> {ok, Outcome};
        false -> ignore
    end;
outcome_response(_Request, _Target, _CommitteeId, _Result) ->
    ignore.

%% `pending_begin` is journal/handoff state owned only by the exact
%% coordinator. It is deliberately excluded from current-view voting and is
%% obtained only through the barrier below after quorum-certified absence.
quorum_outcome_allowed(
  #{status := pending, phase := pending_begin}) -> false;
quorum_outcome_allowed(not_found) -> true;
quorum_outcome_allowed(#{status := _}) -> true;
quorum_outcome_allowed(_) -> false.

probe_outcome_barrier(
  OwnerNs, Coordinator, Source,
  {{TargetNs, _Anchor} = Target, CommitteeId, MinimumSlot, GroupRef},
  Deadline, Dependencies) ->
    Request = {outcome_barrier, request_id(), GroupRef,
               CommitteeId, MinimumSlot},
    probe_outcome_barrier_source(
      Source, OwnerNs, TargetNs, Coordinator, Request, Target,
      CommitteeId, GroupRef, Deadline, Dependencies).

probe_outcome_barrier_source(
  {remote, Endpoints}, OwnerNs, TargetNs, Coordinator, Request,
  Target, CommitteeId, GroupRef, Deadline, Dependencies) ->
    walk_remote_candidates(
      Endpoints, Deadline,
      fun(Endpoint, AttemptDeadline) ->
          call_endpoint(
            OwnerNs, TargetNs, Coordinator, {remote, Endpoint}, Request,
            AttemptDeadline, Dependencies)
      end,
      fun(Result) ->
          case barrier_response(
                 Request, Target, CommitteeId, GroupRef, Result) of
              {error, retry} -> continue;
              Accepted -> {done, Accepted}
          end
      end,
      {error, retry});
probe_outcome_barrier_source(
  local, OwnerNs, TargetNs, Coordinator, Request, Target,
  CommitteeId, GroupRef, Deadline, Dependencies) ->
    barrier_response(
      Request, Target, CommitteeId, GroupRef,
      call_endpoint(
        OwnerNs, TargetNs, Coordinator, local, Request,
        Deadline, Dependencies)).

barrier_response(
  Request, Target, CommitteeId, GroupRef,
  {ok, {outcome_barrier, _RequestId, Target, CommitteeId,
        _AppliedFloor, Status} = Response}) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> barrier_result(Status, GroupRef);
        false -> {error, retry}
    end;
barrier_response(_Request, _Target, _CommitteeId, _GroupRef, _Result) ->
    {error, retry}.

barrier_result(pending_begin, GroupRef) ->
    {ok, #{status => pending, phase => pending_begin, ref => GroupRef}};
barrier_result(coordinator_retired, GroupRef) ->
    {ok, #{status => rejected, reason => coordinator_retired,
           ref => GroupRef}};
barrier_result(not_found, _GroupRef) ->
    {error, not_found};
barrier_result(_Status, _GroupRef) ->
    {error, retry}.

call_endpoint(OwnerNs, TargetNs, PeerKey, Source, Request,
              Deadline, Dependencies) ->
    case remaining(Deadline) of
        0 -> {error, timeout};
        Timeout ->
            try
                case Source of
                    local ->
                        Local = maps:get(local, Dependencies),
                        Local(TargetNs, Request, Timeout);
                    {remote, Endpoint} ->
                        Remote = maps:get(remote, Dependencies),
                        Remote(OwnerNs, TargetNs, PeerKey, Endpoint,
                               Request, Timeout)
                end
            catch exit:_ -> {error, not_ready}
            end
    end.

probe_applied(OwnerNs, PeerKey, Source,
              {{TargetNs, _Anchor} = Target, CommitteeId, GroupId,
               FinalizeRef, Generation, Verdict},
              Deadline, Dependencies) ->
    Request = {applied, request_id(), GroupId, FinalizeRef,
               Generation, Verdict},
    probe_applied_source(
      Source, OwnerNs, TargetNs, PeerKey, Request, Target,
      CommitteeId, Deadline, Dependencies).

probe_applied_source(
  {remote, Endpoints}, OwnerNs, TargetNs, PeerKey, Request,
  Target, CommitteeId, Deadline, Dependencies) ->
    walk_remote_candidates(
      Endpoints, Deadline,
      fun(Endpoint, AttemptDeadline) ->
          call_endpoint(
            OwnerNs, TargetNs, PeerKey, {remote, Endpoint}, Request,
            AttemptDeadline, Dependencies)
      end,
      fun(Result) ->
          case applied_response_valid(
                 Request, Target, CommitteeId, Result) of
              true -> {done, true};
              false -> continue
          end
      end,
      false);
probe_applied_source(
  local, OwnerNs, TargetNs, PeerKey, Request,
  Target, CommitteeId, Deadline, Dependencies) ->
    Result = call_endpoint(
               OwnerNs, TargetNs, PeerKey, local, Request,
               Deadline, Dependencies),
    applied_response_valid(Request, Target, CommitteeId, Result).

applied_response_valid(
  Request, Target, CommitteeId,
  {ok, {applied, _RequestId, Target, CommitteeId, _GroupId,
         _FinalizeRef, _Generation, _Verdict} = Response}) ->
    quod_dtx_endpoint:correlates(Request, Response);
applied_response_valid(_Request, _Target, _CommitteeId, _Result) ->
    false.

request_id() ->
    crypto:strong_rand_bytes(?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS div 8).

threshold(N) ->
    N - quod_simplex:quorum(N) + 1.

remaining(Deadline) ->
    max(0, Deadline - quod_time:mono_ms()).

candidate_deadline(Deadline, CandidatesLeft) ->
    Now = quod_time:mono_ms(),
    Remaining = max(0, Deadline - Now),
    case Remaining of
        0 -> Deadline;
        _ -> Now + max(1, Remaining div max(1, CandidatesLeft))
    end.

walk_remote_candidates([], _Deadline, _Attempt, _Accept, Exhausted) ->
    Exhausted;
walk_remote_candidates(
  [Endpoint | Rest], Deadline, Attempt, Accept, Exhausted) ->
    Result = Attempt(
               Endpoint, candidate_deadline(Deadline, length(Rest) + 1)),
    case Accept(Result) of
        {done, Accepted} -> Accepted;
        continue ->
            walk_remote_candidates(
              Rest, Deadline, Attempt, Accept, Exhausted)
    end.

-ifdef(TEST).
test_verify_applied(OwnerNs, Source, Claim, TimeoutMs, Dependencies) ->
    verify_applied_with(OwnerNs, Source, Claim, TimeoutMs, Dependencies).

test_verify_applied_many(OwnerNs, Requests, TimeoutMs, Dependencies) ->
    verify_applied_many_with(
      OwnerNs, Requests, TimeoutMs, Dependencies).

test_lookup_outcome(OwnerNs, Source, OutcomeRef, TimeoutMs, Dependencies) ->
    lookup_outcome_with(
      OwnerNs, Source, OutcomeRef, TimeoutMs, Dependencies).

test_threshold(N) when is_integer(N), N > 0, N =< ?MAX_VALIDATORS ->
    threshold(N).
-endif.
