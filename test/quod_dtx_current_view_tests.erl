-module(quod_dtx_current_view_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

aggregate_applied_probe_bound_matches_endpoint_capacity_test() ->
    ?assertEqual(
       ?QUOD_MAX_DTX_PARTICIPANTS * ?MAX_VALIDATORS,
       ?QUOD_DTX_ENDPOINT_MAX_CORRELATIONS).

thresholds_are_f_plus_one_at_every_committee_boundary_test() ->
    ?assertEqual(
       [{1, 1}, {4, 2}, {7, 3}, {64, 22}],
       [{N, quod_dtx_current_view:test_threshold(N)} || N <- [1, 4, 7, 64]]).

exact_threshold_of_distinct_current_validators_succeeds_test() ->
    F = fixture(4),
    [A, B, C, D] = maps:get(committee, F),
    Successes = maps:from_keys([A, B], true),
    Deps = dependencies(
             maps:get(view, F),
             fun(Key, Request, Target, CommitteeId) ->
                     case maps:is_key(Key, Successes) of
                         true -> applied_reply(Request, Target, CommitteeId);
                         false -> {error, not_ready}
                     end
             end),
    ?assertMatch(
       {ok, #{committee := [A, B, C, D]}},
       verify(F, Deps)).

one_below_threshold_is_retry_test() ->
    F = fixture(7),
    [Only | _] = maps:get(committee, F),
    Deps = dependencies(
             maps:get(view, F),
             fun(Key, Request, Target, CommitteeId) ->
                     case Key =:= Only of
                         true -> applied_reply(Request, Target, CommitteeId);
                         false -> {error, not_ready}
                     end
             end),
    ?assertEqual({error, retry}, verify(F, Deps)).

duplicate_committee_keys_are_rejected_and_route_hints_cannot_amplify_test() ->
    F = fixture(4),
    [A, B, C, _D] = maps:get(committee, F),
    DuplicateView = (maps:get(view, F))#{committee => [A, A, B, C]},
    Deps = dependencies(
             DuplicateView,
             fun(_Key, Request, Target, CommitteeId) ->
                     applied_reply(Request, Target, CommitteeId)
             end),
    ?assertEqual({error, retry}, verify(F, Deps)),
    GoodDeps = dependencies(
                 maps:get(view, F),
                 fun(_Key, Request, Target, CommitteeId) ->
                         applied_reply(Request, Target, CommitteeId)
                 end),
    [Route | _] = maps:get(source_routes, F),
    ?assertMatch(
       {ok, _},
       quod_dtx_current_view:test_verify_applied(
         maps:get(owner_ns, F), {remote, [Route, Route]},
         maps:get(claim, F), 1000, GoodDeps)).

malformed_view_and_reply_are_retryable_not_success_test() ->
    F = fixture(1),
    BadView = maps:remove(committee_id, maps:get(view, F)),
    BadViewDeps = dependencies(
                    BadView,
                    fun(_Key, Request, Target, CommitteeId) ->
                            applied_reply(Request, Target, CommitteeId)
                    end),
    ?assertEqual({error, retry}, verify(F, BadViewDeps)),
    BadReplyDeps = dependencies(
                     maps:get(view, F),
                     fun(_Key, _Request, _Target, _CommitteeId) ->
                             {ok, malformed}
                     end),
    ?assertEqual({error, retry}, verify(F, BadReplyDeps)).

ipc_dependency_exit_is_retryable_test() ->
    F = fixture(1),
    ViewExit =
        (dependencies(maps:get(view, F), fun(_, _, _, _) -> false end))#{
          view =>
              fun(_Source, _Basis, _Timeout) ->
                      exit(noproc)
              end},
    ?assertEqual({error, retry}, verify(F, ViewExit)),
    EndpointExit =
        (dependencies(maps:get(view, F), fun(_, _, _, _) -> false end))#{
          remote =>
              fun(_OwnerNs, _TargetNs, _Key, _Endpoint,
                  _Request, _Timeout) ->
                      exit(noproc)
              end},
    ?assertEqual({error, retry}, verify(F, EndpointExit)).

programmer_fault_in_view_dependency_is_visible_test() ->
    F = fixture(1),
    Deps =
        (dependencies(maps:get(view, F), fun(_, _, _, _) -> false end))#{
          view =>
              fun(_Source, _Basis, _Timeout) ->
                      error(view_dependency_fault)
              end},
    ?assertError(view_dependency_fault, verify(F, Deps)).

programmer_fault_in_probe_terminates_monitored_verifier_test() ->
    F = fixture(1),
    Deps =
        (dependencies(maps:get(view, F), fun(_, _, _, _) -> false end))#{
          remote =>
              fun(_OwnerNs, _TargetNs, _Key, _Endpoint,
                  _Request, _Timeout) ->
                      error(endpoint_dependency_fault)
              end},
    {Verifier, Monitor} = spawn_monitor(fun() -> verify(F, Deps) end),
    receive
        {'DOWN', Monitor, process, Verifier,
         {endpoint_dependency_fault, [_ | _]}} ->
            ok
    after 2000 ->
        error(verifier_fault_was_hidden)
    end.

programmer_fault_in_many_worker_terminates_monitored_verifier_test() ->
    F = fixture(1),
    Deps =
        (dependencies(maps:get(view, F), fun(_, _, _, _) -> false end))#{
          view =>
              fun(_Source, _Basis, _Timeout) ->
                      error(many_view_dependency_fault)
              end},
    Requests = many_requests(F, 1),
    OwnerNs = maps:get(owner_ns, F),
    {Verifier, Monitor} = spawn_monitor(
      fun() ->
          quod_dtx_current_view:test_verify_applied_many(
            OwnerNs, Requests, 1000, Deps)
      end),
    receive
        {'DOWN', Monitor, process, Verifier,
         {many_view_dependency_fault, [_ | _]}} ->
            ok
    after 2000 ->
        error(many_worker_fault_was_hidden)
    end.

committee_rotation_mismatch_restarts_the_whole_check_test() ->
    F = fixture(4),
    OldCommitteeId = digest(240),
    Deps = dependencies(
             maps:get(view, F),
             fun(_Key, Request, Target, _CurrentCommitteeId) ->
                     applied_reply(Request, Target, OldCommitteeId)
             end),
    ?assertEqual({error, retry}, verify(F, Deps)).

cohosted_current_view_uses_local_key_and_remote_current_peers_test() ->
    F = fixture(4),
    [LocalKey, RemoteKey | _] = maps:get(committee, F),
    View = maps:get(view, F),
    Target = maps:get(identity, View),
    CommitteeId = maps:get(committee_id, View),
    TestPid = self(),
    Base = dependencies(View, fun(_, _, _, _) -> {error, unused} end),
    Deps = Base#{
      node_key => fun() -> LocalKey end,
      local =>
          fun(_Ns, Request, _Timeout) ->
                  TestPid ! local_applied_probe,
                  applied_reply(Request, Target, CommitteeId)
          end,
      remote =>
          fun(_OwnerNs, _TargetNs, Key, _Endpoint, Request, _Timeout) ->
                  case Key =:= RemoteKey of
                      true ->
                          TestPid ! remote_applied_probe,
                          applied_reply(Request, Target, CommitteeId);
                      false ->
                          {error, not_ready}
                  end
          end},
    ?assertMatch(
       {ok, _},
       quod_dtx_current_view:test_verify_applied(
         maps:get(owner_ns, F), {local, <<"/unused/test/root">>},
         maps:get(claim, F), 1000, Deps)),
    receive local_applied_probe -> ok after 0 -> error(missing_local_probe) end,
    receive remote_applied_probe -> ok after 0 -> error(missing_remote_probe) end.

claim_correlation_is_exact_for_every_field_test() ->
    F = fixture(1),
    View = maps:get(view, F),
    CommitteeId = maps:get(committee_id, View),
    Cases =
        [fun(Request, Target) ->
             applied_reply(setelement(3, Request, digest(201)),
                           Target, CommitteeId)
         end,
         fun(Request, Target) ->
             applied_reply(setelement(5, Request, 999),
                           Target, CommitteeId)
         end,
         fun(Request, Target) ->
             applied_reply(setelement(6, Request, abort),
                           Target, CommitteeId)
         end,
         fun(Request, _Target) ->
             applied_reply(Request, {<<"quod:wrong">>, digest(202)},
                           CommitteeId)
         end],
    lists:foreach(
      fun(MakeReply) ->
          Deps = dependencies(
                   View,
                   fun(_Key, Request, Target, _ExpectedCommitteeId) ->
                           MakeReply(Request, Target)
                   end),
          ?assertEqual({error, retry}, verify(F, Deps))
      end, Cases).

successful_early_quorum_kills_and_reaps_every_other_probe_test() ->
    F = fixture(4),
    TestPid = self(),
    [A, B | _] = maps:get(committee, F),
    Fast = maps:from_keys([A, B], true),
    Reply = fun(Key, Request, Target, CommitteeId) ->
                    TestPid ! {probe_started, Key, self()},
                    case maps:is_key(Key, Fast) of
                        true ->
                            receive {release_probe, Key} -> ok end,
                            applied_reply(Request, Target, CommitteeId);
                        false ->
                            receive never -> {error, impossible} end
                    end
            end,
    Deps = dependencies(maps:get(view, F), Reply),
    {Verifier, VerifierMonitor} = spawn_monitor(
      fun() -> TestPid ! {verify_result, verify(F, Deps)} end),
    Started = collect_started(4, #{}),
    ProbeMonitors = maps:map(
                      fun(_Key, Pid) -> erlang:monitor(process, Pid) end,
                      Started),
    maps:foreach(
      fun(Key, Pid) ->
              case maps:is_key(Key, Fast) of
                  true -> Pid ! {release_probe, Key};
                  false -> ok
              end
      end, Started),
    receive
        {verify_result, {ok, _View}} -> ok
    after 2000 ->
        error(verifier_did_not_finish)
    end,
    receive
        {'DOWN', VerifierMonitor, process, Verifier, normal} -> ok
    after 2000 ->
        error(verifier_process_survived)
    end,
    maps:foreach(
      fun(Key, Pid) ->
              Monitor = maps:get(Key, ProbeMonitors),
              receive
                  {'DOWN', Monitor, process, Pid, _Reason} -> ok
              after 2000 ->
                  error({probe_process_survived, Key})
              end
      end, Started).

caller_death_immediately_reclaims_all_probe_processes_test() ->
    F = fixture(4),
    TestPid = self(),
    Reply = fun(Key, _Request, _Target, _CommitteeId) ->
                    TestPid ! {probe_started, Key, self()},
                    receive never -> {error, impossible} end
            end,
    Deps = dependencies(maps:get(view, F), Reply),
    {Verifier, VerifierMonitor} = spawn_monitor(
      fun() -> _ = verify(F, Deps), ok end),
    Started = collect_started(4, #{}),
    ProbeMonitors = maps:map(
                      fun(_Key, Pid) -> erlang:monitor(process, Pid) end,
                      Started),
    exit(Verifier, kill),
    receive
        {'DOWN', VerifierMonitor, process, Verifier, killed} -> ok
    after 2000 ->
        error(verifier_process_survived)
    end,
    maps:foreach(
      fun(Key, Pid) ->
              Monitor = maps:get(Key, ProbeMonitors),
              receive
                  {'DOWN', Monitor, process, Pid, killed} -> ok
              after 2000 ->
                  error({orphan_probe, Key})
              end
      end, Started).

every_participant_check_runs_concurrently_and_must_succeed_test() ->
    F = fixture(1),
    Deps = dependencies(
             maps:get(view, F),
             fun(_Key, Request, Target, CommitteeId) ->
                     applied_reply(Request, Target, CommitteeId)
             end),
    Requests = many_requests(F, 2),
    ?assertMatch(
       {ok, [#{committee_id := _}, #{committee_id := _}]},
       quod_dtx_current_view:test_verify_applied_many(
         maps:get(owner_ns, F), Requests, 1000, Deps)),
    RetryDeps = Deps#{remote =>
                       fun(_OwnerNs, _TargetNs, _Key, _Endpoint,
                           _Request, _Timeout) ->
                               {error, not_ready}
                       end},
    ?assertEqual(
       {error, retry},
       quod_dtx_current_view:test_verify_applied_many(
         maps:get(owner_ns, F), Requests, 1000, RetryDeps)).

participant_verification_is_bounded_and_children_follow_caller_death_test() ->
    F = fixture(1),
    Requests = many_requests(F, 2),
    ?assertEqual(
       {error, invalid_request},
       quod_dtx_current_view:test_verify_applied_many(
         maps:get(owner_ns, F), many_requests(F, 9), 1000,
         dependencies(maps:get(view, F), fun(_, _, _, _) -> false end))),
    TestPid = self(),
    BlockedDeps =
        (dependencies(maps:get(view, F), fun(_, _, _, _) -> false end))#{
          view =>
              fun(_Source, _Ref, _Timeout) ->
                      TestPid ! {many_view_started, self()},
                      receive never -> {error, impossible} end
              end},
    {Verifier, VerifierMonitor} = spawn_monitor(
      fun() ->
          _ = quod_dtx_current_view:test_verify_applied_many(
                maps:get(owner_ns, F), Requests, 1000, BlockedDeps),
          ok
      end),
    Children = collect_many_children(2, []),
    ChildMonitors = [{Pid, erlang:monitor(process, Pid)} || Pid <- Children],
    exit(Verifier, kill),
    receive
        {'DOWN', VerifierMonitor, process, Verifier, killed} -> ok
    after 2000 ->
        error(many_verifier_survived)
    end,
    lists:foreach(
      fun({Pid, Monitor}) ->
          receive
              {'DOWN', Monitor, process, Pid, killed} -> ok
          after 2000 ->
              error({many_child_survived, Pid})
          end
      end, ChildMonitors).

outcome_needs_f_plus_one_identical_current_validator_replies_test() ->
    F = fixture(4),
    [A, B, C, _D] = maps:get(committee, F),
    Ref = outcome_group_ref(F, A),
    Good = group_committed(Ref),
    Divergent = #{status => pending, phase => begun, ref => Ref},
    Deps = outcome_dependencies(
             maps:get(view, F),
             fun(Key, Request, Target, CommitteeId, Slot) ->
                     case Key of
                         A -> outcome_reply(
                                Request, Target, CommitteeId, Slot, Good);
                         B -> outcome_reply(
                                Request, Target, CommitteeId, Slot + 1, Good);
                         C -> outcome_reply(
                                Request, Target, CommitteeId, Slot,
                                Divergent);
                         _ -> {error, not_ready}
                     end
             end),
    ?assertEqual({ok, Good}, lookup(F, Ref, Deps)).

one_byzantine_outcome_reply_never_decides_test() ->
    F = fixture(4),
    [Byzantine | _] = maps:get(committee, F),
    Ref = outcome_transaction_ref(F),
    Forged = #{status => committed, height => 99, ref => Ref},
    Deps = outcome_dependencies(
             maps:get(view, F),
             fun(Key, Request, Target, CommitteeId, Slot) ->
                     case Key =:= Byzantine of
                         true -> outcome_reply(
                                   Request, Target, CommitteeId, Slot,
                                   Forged);
                         false -> {error, not_ready}
                     end
             end),
    ?assertEqual({error, retry}, lookup(F, Ref, Deps)).

view_mismatch_lag_and_split_valid_statuses_are_retryable_test() ->
    F = fixture(4),
    [A, B, C, D] = maps:get(committee, F),
    Ref = outcome_transaction_ref(F),
    Committed = #{status => committed, height => 9, ref => Ref},
    Pending = #{status => pending, ref => Ref},
    Deps = outcome_dependencies(
             maps:get(view, F),
             fun(Key, Request, Target, CommitteeId, Slot) ->
                     case Key of
                         A -> outcome_reply(
                                Request, Target, digest(250), Slot,
                                Committed);
                         B -> outcome_reply(
                                Request, Target, CommitteeId, Slot - 1,
                                Committed);
                         C -> outcome_reply(
                                Request, Target, CommitteeId, Slot, Pending);
                         D -> outcome_reply(
                                Request, Target, CommitteeId, Slot,
                                Committed)
                     end
             end),
    ?assertEqual({error, retry}, lookup(F, Ref, Deps)).

ordinary_quorum_absence_stays_unknown_without_a_barrier_test() ->
    F = fixture(4),
    Ref = outcome_transaction_ref(F),
    TestPid = self(),
    Deps = outcome_dependencies(
             maps:get(view, F),
             fun(_Key, Request, Target, CommitteeId, Slot) ->
                     case element(1, Request) of
                         outcome ->
                             outcome_reply(
                               Request, Target, CommitteeId, Slot, not_found);
                         outcome_barrier ->
                             TestPid ! unexpected_ordinary_barrier,
                             {error, not_ready}
                     end
             end),
    ?assertEqual({error, retry}, lookup(F, Ref, Deps)),
    receive unexpected_ordinary_barrier -> error(barrier_was_used)
    after 0 -> ok
    end.

group_quorum_absence_uses_only_the_exact_coordinator_barrier_test() ->
    F = fixture(4),
    [Coordinator | _] = maps:get(committee, F),
    Ref = outcome_group_ref(F, Coordinator),
    TestPid = self(),
    Deps = outcome_dependencies(
             maps:get(view, F),
             fun(Key, Request, Target, CommitteeId, Slot) ->
                     case Request of
                         {outcome, _, _, _, _} ->
                             outcome_reply(
                               Request, Target, CommitteeId, Slot, not_found);
                         {outcome_barrier, _, _, _, _} ->
                             TestPid ! {barrier_peer, Key},
                             barrier_reply(
                               Request, Target, CommitteeId, Slot,
                               pending_begin)
                     end
             end),
    ?assertEqual(
       {ok, #{status => pending, phase => pending_begin, ref => Ref}},
       lookup(F, Ref, Deps)),
    receive {barrier_peer, Coordinator} -> ok
    after 0 -> error(missing_exact_coordinator_barrier)
    end,
    receive {barrier_peer, Other} -> error({wrong_barrier_peer, Other})
    after 0 -> ok
    end.

coordinator_barrier_can_prove_pre_handoff_absence_or_retirement_test() ->
    F = fixture(4),
    [Coordinator | _] = maps:get(committee, F),
    Ref = outcome_group_ref(F, Coordinator),
    lists:foreach(
      fun({BarrierStatus, Expected}) ->
          Deps = outcome_dependencies(
                   maps:get(view, F),
                   fun(_Key, Request, Target, CommitteeId, Slot) ->
                           case element(1, Request) of
                               outcome -> outcome_reply(
                                            Request, Target, CommitteeId,
                                            Slot, not_found);
                               outcome_barrier -> barrier_reply(
                                                    Request, Target,
                                                    CommitteeId, Slot,
                                                    BarrierStatus)
                           end
                   end),
          ?assertEqual(Expected, lookup(F, Ref, Deps))
      end,
      [{not_found, {error, not_found}},
       {coordinator_retired,
        {ok, #{status => rejected, reason => coordinator_retired,
               ref => Ref}}}]).

certified_view_without_coordinator_proves_retirement_without_contact_test() ->
    F = fixture(4),
    Coordinator = digest(245),
    Ref = outcome_group_ref(F, Coordinator),
    TestPid = self(),
    Deps = outcome_dependencies(
             maps:get(view, F),
             fun(_Key, Request, Target, CommitteeId, Slot) ->
                     case element(1, Request) of
                         outcome -> outcome_reply(
                                      Request, Target, CommitteeId, Slot,
                                      not_found);
                         outcome_barrier ->
                             TestPid ! unexpected_retired_barrier,
                             {error, not_ready}
                     end
             end),
    ?assertEqual(
       {ok, #{status => rejected, reason => coordinator_retired,
              ref => Ref}},
       lookup(F, Ref, Deps)),
    receive unexpected_retired_barrier -> error(barrier_was_used)
    after 0 -> ok
    end.

pending_begin_is_not_a_validator_quorum_status_test() ->
    F = fixture(4),
    [Coordinator | _] = maps:get(committee, F),
    Ref = outcome_group_ref(F, Coordinator),
    PendingBegin = #{status => pending, phase => pending_begin, ref => Ref},
    TestPid = self(),
    Deps = outcome_dependencies(
             maps:get(view, F),
             fun(_Key, Request, Target, CommitteeId, Slot) ->
                     case element(1, Request) of
                         outcome -> outcome_reply(
                                      Request, Target, CommitteeId, Slot,
                                      PendingBegin);
                         outcome_barrier ->
                             TestPid ! unexpected_pending_barrier,
                             {error, not_ready}
                     end
             end),
    ?assertEqual({error, retry}, lookup(F, Ref, Deps)),
    receive unexpected_pending_barrier -> error(barrier_was_used)
    after 0 -> ok
    end.

verify(F, Dependencies) ->
    quod_dtx_current_view:test_verify_applied(
      maps:get(owner_ns, F),
      {remote, maps:get(source_routes, F)},
      maps:get(claim, F), 1000, Dependencies).

lookup(F, OutcomeRef, Dependencies) ->
    quod_dtx_current_view:test_lookup_outcome(
      maps:get(owner_ns, F),
      {remote, maps:get(source_routes, F)},
      OutcomeRef, 1000, Dependencies).

many_requests(F, Count) ->
    Source = {remote, maps:get(source_routes, F)},
    lists:duplicate(Count, {Source, maps:get(claim, F)}).

dependencies(View, Reply) ->
    #{view => fun(_Source, _Ref, _Timeout) -> {ok, View} end,
      local =>
          fun(_Ns, Request, _Timeout) ->
                  [Key | _] = maps:get(committee, View),
                  Reply(Key, Request, maps:get(identity, View),
                        maps:get(committee_id, View))
          end,
      remote =>
          fun(_OwnerNs, _TargetNs, Key, _Endpoint, Request, _Timeout) ->
                  Reply(Key, Request, maps:get(identity, View),
                        maps:get(committee_id, View))
          end,
      node_key => fun() -> none end}.

outcome_dependencies(View, Reply) ->
    #{view => fun(_Source, _Basis, _Timeout) -> {ok, View} end,
      local =>
          fun(_Ns, Request, _Timeout) ->
                  [Key | _] = maps:get(committee, View),
                  Reply(Key, Request, maps:get(identity, View),
                        maps:get(committee_id, View), maps:get(slot, View))
          end,
      remote =>
          fun(_OwnerNs, _TargetNs, Key, _Endpoint, Request, _Timeout) ->
                  Reply(Key, Request, maps:get(identity, View),
                        maps:get(committee_id, View), maps:get(slot, View))
          end,
      node_key => fun() -> none end}.

outcome_reply(
  {outcome, RequestId, _OutcomeRef, _CommitteeId, _MinimumSlot},
  Target, CommitteeId, AppliedFloor, Outcome) ->
    {ok, {outcome, RequestId, Target, CommitteeId, AppliedFloor, Outcome}}.

barrier_reply(
  {outcome_barrier, RequestId, _GroupRef, _CommitteeId, _MinimumSlot},
  Target, CommitteeId, AppliedFloor, Status) ->
    {ok, {outcome_barrier, RequestId, Target, CommitteeId,
          AppliedFloor, Status}}.

outcome_transaction_ref(F) ->
    {TargetNs, Anchor} = maps:get(identity, maps:get(view, F)),
    {transaction, TargetNs, Anchor, digest(220)}.

outcome_group_ref(F, Coordinator) ->
    {TargetNs, Anchor} = maps:get(identity, maps:get(view, F)),
    {group, TargetNs, Anchor, Coordinator, digest(221), digest(222)}.

group_committed(Ref) ->
    #{status => committed, height => 9, ref => Ref,
      bindings => [{<<"X">>, linked}],
      participant_slots =>
          [{{<<"quod:a">>, digest(230)}, 7, 1},
           {{<<"quod:b">>, digest(231)}, 8, 2}]}.

applied_reply(
  {applied, RequestId, GroupId, FinalizeRef, Generation, Verdict},
  Target, CommitteeId) ->
    {ok, {applied, RequestId, Target, CommitteeId, GroupId, FinalizeRef,
          Generation, Verdict}}.

fixture(N) ->
    OwnerNs = <<"quod:owner">>,
    Target = {<<"quod:target">>, digest(1)},
    Committee = lists:sort([digest(I) || I <- lists:seq(10, 9 + N)]),
    CommitteeId = digest(2),
    Routes = maps:from_list(
               [{Key, {"127.0.0.1", 20000 + I}}
                || {Key, I} <- lists:zip(Committee, lists:seq(1, N))]),
    {TargetNs, Anchor} = Target,
    {ok, FinalizeRef} = quod_dtx:certified_ref(
                          TargetNs, Anchor, 7, digest(3), digest(4), <<1>>),
    Claim = #{target => Target, group_id => digest(5),
              finalize_ref => FinalizeRef, generation => 9,
              verdict => commit},
    View = #{identity => Target, slot => 8, generation => 9,
             committee => Committee, committee_id => CommitteeId,
             routes => Routes},
    #{owner_ns => OwnerNs, claim => Claim, view => View,
      committee => Committee, source_routes => maps:to_list(Routes)}.

collect_started(0, Acc) ->
    Acc;
collect_started(Left, Acc) ->
    receive
        {probe_started, Key, Pid} ->
            collect_started(Left - 1, Acc#{Key => Pid})
    after 2000 ->
        error({missing_probe_starts, Left})
    end.

collect_many_children(0, Acc) ->
    Acc;
collect_many_children(Left, Acc) ->
    receive
        {many_view_started, Pid} ->
            collect_many_children(Left - 1, [Pid | Acc])
    after 2000 ->
        error({missing_many_children, Left})
    end.

digest(N) ->
    crypto:hash(sha256, <<N:64/unsigned-big>>).
