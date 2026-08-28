-module(quod_dtx_current_view_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

thresholds_are_f_plus_one_at_every_committee_boundary_test() ->
    ?assertEqual(
       [{1, 1}, {4, 2}, {7, 3}, {64, 22}],
       [{N, quod_dtx_current_view:test_threshold(N)} || N <- [1, 4, 7, 64]]).

%% Cancellation has one event-driven retry owner: endpoint failure returns to
%% that owner instead of walking another route immediately. For every other
%% request, a silent timeout or authenticated-link loss is uncertain and must
%% likewise return to existing recovery rather than resubmit the operation.
endpoint_failure_never_immediately_resubmits_uncertain_work_test() ->
    Cancellation =
        {cancel_operation_effect, <<1:128>>, <<"signed-submission">>},
    lists:foreach(
      fun(Reason) ->
              ?assertEqual(
                 stop,
                 quod_dtx_current_view:test_endpoint_failure_disposition(
                   Cancellation, Reason))
      end, [not_ready, busy, timeout, connection_lost]),
    Write = {submit, <<2:128>>, <<"signed-control">>},
    ?assertEqual(
       stop,
       quod_dtx_current_view:test_endpoint_failure_disposition(
         Write, timeout)),
    ?assertEqual(
       stop,
       quod_dtx_current_view:test_endpoint_failure_disposition(
         Write, connection_lost)),
    ?assertEqual(
       next,
       quod_dtx_current_view:test_endpoint_failure_disposition(
         Write, not_ready)),

    %% Drive the real flattened candidate walker. A stop result must end the
    %% whole route list, not merely the current peer's endpoint sub-list.
    ?assertEqual(
       {{error, not_ready}, 1},
       quod_dtx_current_view:test_submit_operation_candidates(
         Cancellation, [{error, not_ready}, {error, timeout}])),
    ?assertEqual(
       {{error, timeout}, 1},
       quod_dtx_current_view:test_submit_operation_candidates(
         Write, [{error, timeout}, {error, not_ready}])),
    Phase = {phase, <<3:128>>, <<4:256>>, prepare},
    PhaseReply = {phase, <<3:128>>, 1, pending},
    ?assertEqual(
       {{ok, PhaseReply}, 2},
       quod_dtx_current_view:test_submit_operation_candidates(
         Phase, [{error, not_ready}, {ok, PhaseReply, []}])).

exact_f_plus_one_finalize_committee_certificate_succeeds_test() ->
    F = fixture(4),
    [A, B | _] = maps:get(committee, F),
    Certificate = certificate(F, [A, B], #{}),
    ?assert(quod_dtx_current_view:valid_applied_certificate_shape(Certificate)),
    ?assert(quod_dtx_current_view:verify_applied_certificate(
              Certificate, maps:get(network_identity, F),
              maps:get(evidence, F))).

insufficient_duplicate_nonmember_and_bad_signatures_fail_test() ->
    F = fixture(4),
    [A, B | _] = maps:get(committee, F),
    One = certificate(F, [A], #{}),
    {quod_dtx_applied_certificate, 1, Network, Target, CommitteeId,
     GroupId, FinalizeRef, Generation, Verdict, [{A, Signature}]} = One,
    Duplicate = {quod_dtx_applied_certificate, 1, Network, Target, CommitteeId,
                 GroupId, FinalizeRef, Generation, Verdict,
                 [{A, Signature}, {A, Signature}]},
    Outsider = signer(),
    NonMember = certificate_with_signers(
                  F, [Outsider, maps:get(B, maps:get(signers, F))], #{}),
    BadSignature = {quod_dtx_applied_certificate, 1, Network, Target,
                    CommitteeId, GroupId, FinalizeRef, Generation, Verdict,
                    lists:keysort(1, [{A, <<0:512>>},
                                      signed_row(F, B, #{})])},
    lists:foreach(
      fun(Certificate) ->
          ?assertNot(quod_dtx_current_view:verify_applied_certificate(
                       Certificate, Network, maps:get(evidence, F)))
      end, [One, Duplicate, NonMember, BadSignature]).

every_signed_statement_field_is_bound_test() ->
    F = fixture(4),
    [A, B | _] = maps:get(committee, F),
    Keys = [A, B],
    Network = maps:get(network_identity, F),
    Claim = maps:get(claim, F),
    Target = maps:get(target, F),
    WrongTarget = {<<"quod:wrong-target">>, digest(201)},
    WrongRef = certified_ref(Target, 17, digest(202)),
    WrongTargetRef = certified_ref(WrongTarget, 18, digest(203)),
    Cases =
        [{#{network_identity => digest(204)}, Network},
         {#{target => WrongTarget, finalize_ref => WrongTargetRef}, Network},
         {#{committee_id => digest(205)}, Network},
         {#{group_id => digest(206)}, Network},
         {#{finalize_ref => WrongRef}, Network},
         {#{generation => maps:get(generation, Claim) + 1}, Network},
         {#{verdict => abort}, Network}],
    lists:foreach(
      fun({Overrides, ExpectedNetwork}) ->
          Certificate = certificate(F, Keys, Overrides),
          ?assert(quod_dtx_current_view:valid_applied_certificate_shape(
                    Certificate)),
          ?assertNot(quod_dtx_current_view:verify_applied_certificate(
                       Certificate, ExpectedNetwork, maps:get(evidence, F)))
      end, Cases).

certification_uses_exact_finalize_committee_without_current_view_lookup_test() ->
    F = fixture(4),
    [A, B | _] = maps:get(committee, F),
    Successes = maps:from_keys([A, B], true),
    Deps0 = dependencies(
              F,
              fun(Key, Request) ->
                  case maps:is_key(Key, Successes) of
                      true -> applied_reply(F, Key, Request);
                      false -> {error, not_ready}
                  end
              end),
    %% A later current committee is irrelevant: this function must never ask
    %% for one, because the exact certified Finalize freezes its signer set.
    Deps = Deps0#{view => fun(_, _, _) -> error(stale_current_view_path) end},
    {ok, Certificate} = certify(F, Deps),
    ?assert(quod_dtx_current_view:verify_applied_certificate(
              Certificate, maps:get(network_identity, F),
              maps:get(evidence, F))).

cohosted_certification_uses_the_local_member_without_a_route_test() ->
    F0 = fixture(1),
    [Key] = maps:get(committee, F0),
    Evidence = (maps:get(evidence, F0))#{routes => #{}},
    F = F0#{evidence => Evidence},
    TestPid = self(),
    Deps0 = dependencies(F, fun(_, _) -> {error, unused} end),
    Deps = Deps0#{
      node_key => fun() -> Key end,
      local =>
          fun(TargetNs, Request, _Timeout) ->
              TestPid ! {local_applied_probe, TargetNs},
              applied_reply(F, Key, Request)
          end,
      remote =>
          fun(_, _, _, _, _, _) -> error(unexpected_remote_probe) end},
    ?assertMatch(
       {ok, {quod_dtx_applied_certificate, 1, _, _, _, _, _, _, _, _}},
       quod_dtx_current_view:test_certify_applied(
         maps:get(owner_ns, F), {local, <<"/tmp/cohosted">>},
         maps:get(claim, F), Evidence, 1000, Deps)),
    receive
        {local_applied_probe, TargetNs} ->
            ?assertEqual(element(1, maps:get(target, F)), TargetNs)
    after 1000 ->
        error(local_member_was_not_probed)
    end.

one_below_f_plus_one_is_retry_test() ->
    F = fixture(7),
    [A, B | _] = maps:get(committee, F),
    Successes = maps:from_keys([A, B], true),
    Deps = dependencies(
             F,
             fun(Key, Request) ->
                 case maps:is_key(Key, Successes) of
                     true -> applied_reply(F, Key, Request);
                     false -> {error, not_ready}
                 end
             end),
    ?assertEqual({error, retry}, certify(F, Deps)).

retired_finalize_member_uses_shared_resolver_after_endpoint_move_test() ->
    F0 = fixture(1),
    [OldKey] = maps:get(committee, F0),
    CurrentSigner = signer(),
    CurrentKey = maps:get(pubkey, CurrentSigner),
    Stale = {"127.0.0.1", 21001},
    Fresh = {"127.0.0.1", 21002},
    CurrentEndpoint = {"127.0.0.1", 21003},
    Evidence0 = maps:get(evidence, F0),
    Evidence = Evidence0#{routes => #{OldKey => Stale}},
    %% The ordinary current-route view has advanced past OldKey. Only the
    %% shared key resolver knows where that retired holder moved; the endpoint
    %% request remains pinned to OldKey at the transport boundary.
    F = F0#{evidence => Evidence,
            source_routes => [{CurrentKey, [CurrentEndpoint]}]},
    TestPid = self(),
    Deps0 = dependencies(F, fun(_, _) -> {error, unused} end),
    Deps = Deps0#{
      resolve =>
          fun(Key) when Key =:= OldKey -> {ok, Fresh};
             (Key) when Key =:= CurrentKey -> {ok, CurrentEndpoint};
             (_) -> error
          end,
      remote =>
          fun(_OwnerNs, _TargetNs, PinnedKey, Endpoint, Request, _Timeout) ->
              TestPid ! {applied_request, PinnedKey, Endpoint,
                         element(2, Request)},
              case {PinnedKey, Endpoint} of
                  {OldKey, Fresh} -> applied_reply(F, OldKey, Request);
                  {OldKey, Stale} -> {error, not_ready};
                  {CurrentKey, CurrentEndpoint} ->
                      error(current_committee_key_was_probed)
              end
          end},
    %% Before the resolver merge the exact old key has only Stale and retries.
    %% The current committee key is reachable but must never become a signer.
    ?assertMatch({ok, _}, certify(F, Deps)),
    receive {applied_request, OldKey, Fresh, <<_:128>>} -> ok
    after 1000 -> error(missing_resolved_retired_member_route)
    end,
    receive {applied_request, _, _, _} -> error(extra_probe)
    after 0 -> ok
    end.

live_route_for_a_nonmember_is_never_probed_or_counted_test() ->
    F0 = fixture(1),
    [Member] = maps:get(committee, F0),
    Outsider = signer(),
    OutsiderKey = maps:get(pubkey, Outsider),
    MemberEndpoint = {"127.0.0.1", 21101},
    OutsiderEndpoint = {"127.0.0.1", 21102},
    Evidence0 = maps:get(evidence, F0),
    Evidence = Evidence0#{routes => #{Member => MemberEndpoint}},
    SourceRoutes = lists:keysort(
                     1, [{Member, [MemberEndpoint]},
                         {OutsiderKey, [OutsiderEndpoint]}]),
    F = F0#{evidence => Evidence, source_routes => SourceRoutes},
    TestPid = self(),
    Deps0 = dependencies(F, fun(_, _) -> {error, unused} end),
    Deps = Deps0#{
      remote =>
          fun(_OwnerNs, _TargetNs, Key, Endpoint, Request, _Timeout) ->
              case {Key, Endpoint} of
                  {Member, MemberEndpoint} -> {error, not_ready};
                  {OutsiderKey, OutsiderEndpoint} ->
                      TestPid ! outsider_was_probed,
                      applied_reply(F, Outsider, Request)
              end
          end},
    %% The outsider could produce a well-formed signed response, but exact
    %% Finalize membership—not route presence—decides who may attest.
    ?assertEqual({error, retry}, certify(F, Deps)),
    receive outsider_was_probed -> error(nonmember_route_was_used)
    after 0 -> ok
    end.

malformed_finalize_evidence_and_reply_are_retryable_test() ->
    F = fixture(1),
    BadEvidence = maps:remove(committee_id, maps:get(evidence, F)),
    ?assertEqual(
       {error, retry},
       quod_dtx_current_view:test_certify_applied(
         maps:get(owner_ns, F), source(F), maps:get(claim, F), BadEvidence,
         1000, dependencies(F, fun(_, _) -> {error, unused} end))),
    BadReplyDeps = dependencies(F, fun(_Key, _Request) -> {ok, malformed} end),
    ?assertEqual({error, retry}, certify(F, BadReplyDeps)).

wrong_signer_or_bad_signature_reply_never_counts_test() ->
    F = fixture(1),
    [Key] = maps:get(committee, F),
    Outsider = signer(),
    WrongSignerDeps = dependencies(
                        F,
                        fun(_Expected, Request) ->
                            applied_reply(F, Outsider, Request)
                        end),
    ?assertEqual({error, retry}, certify(F, WrongSignerDeps)),
    BadSignatureDeps = dependencies(
                         F,
                         fun(_Expected, Request) ->
                             {ok, Response, []} = applied_reply(F, Key, Request),
                             {ok, setelement(10, Response, <<0:512>>), []}
                         end),
    ?assertEqual({error, retry}, certify(F, BadSignatureDeps)).

programmer_fault_in_probe_terminates_monitored_certifier_test() ->
    F = fixture(1),
    Deps0 = dependencies(F, fun(_, _) -> {error, unused} end),
    Deps = Deps0#{remote =>
                   fun(_OwnerNs, _TargetNs, _Key, _Endpoint,
                       _Request, _Timeout) ->
                       error(endpoint_dependency_fault)
                   end},
    {Certifier, Monitor} = spawn_monitor(fun() -> certify(F, Deps) end),
    receive
        {'DOWN', Monitor, process, Certifier,
         {endpoint_dependency_fault, [_ | _]}} -> ok
    after 2000 ->
        error(certifier_fault_was_hidden)
    end.

successful_early_certificate_reaps_other_probe_processes_test() ->
    F = fixture(4),
    TestPid = self(),
    [A, B | _] = maps:get(committee, F),
    Fast = maps:from_keys([A, B], true),
    Reply = fun(Key, Request) ->
                    TestPid ! {probe_started, Key, self()},
                    case maps:is_key(Key, Fast) of
                        true ->
                            receive {release_probe, Key} -> ok end,
                            applied_reply(F, Key, Request);
                        false ->
                            receive never -> {error, impossible} end
                    end
            end,
    Deps = dependencies(F, Reply),
    {Certifier, CertifierMonitor} = spawn_monitor(
      fun() -> TestPid ! {certify_result, certify(F, Deps)} end),
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
    receive {certify_result, {ok, _}} -> ok
    after 2000 -> error(certifier_did_not_finish)
    end,
    receive {'DOWN', CertifierMonitor, process, Certifier, normal} -> ok
    after 2000 -> error(certifier_process_survived)
    end,
    maps:foreach(
      fun(Key, Pid) ->
          Monitor = maps:get(Key, ProbeMonitors),
          receive {'DOWN', Monitor, process, Pid, _Reason} -> ok
          after 2000 -> error({probe_process_survived, Key})
          end
      end, Started).

many_certification_preserves_aligned_successes_and_retries_test() ->
    Good = fixture(1),
    Retry = fixture(1),
    GoodSource = source(Good),
    RetrySource = source(Retry),
    GoodRoute = hd(maps:get(source_routes, Good)),
    RetryRoute = hd(maps:get(source_routes, Retry)),
    Deps0 = dependencies(Good, fun(_, _) -> {error, unused} end),
    Deps = Deps0#{
      network_identity => fun() -> {ok, maps:get(network_identity, Good)} end,
      remote =>
          fun(_OwnerNs, _TargetNs, Key, Endpoint, Request, _Timeout) ->
              case {Key, Endpoint} of
                  {GoodKey, GoodEndpoint}
                    when {GoodKey, [GoodEndpoint]} =:= GoodRoute ->
                      applied_reply(Good, Key, Request);
                  {RetryKey, RetryEndpoint}
                    when {RetryKey, [RetryEndpoint]} =:= RetryRoute ->
                      {error, not_ready}
              end
          end},
    Requests = [{GoodSource, maps:get(claim, Good), maps:get(evidence, Good)},
                {RetrySource, maps:get(claim, Retry), maps:get(evidence, Retry)}],
    ?assertMatch(
       {ok, [{verified, {quod_dtx_applied_certificate, 1, _, _, _, _, _, _, _, _}},
             retry]},
       quod_dtx_current_view:test_certify_applied_many(
         maps:get(owner_ns, Good), Requests, 1000, Deps)).

many_certification_children_follow_caller_death_test() ->
    F = fixture(1),
    Requests = many_requests(F, 2),
    TestPid = self(),
    Deps0 = dependencies(F, fun(_, _) -> {error, unused} end),
    BlockedDeps = Deps0#{remote =>
                          fun(_OwnerNs, _TargetNs, _Key, _Endpoint,
                              _Request, _Timeout) ->
                              TestPid ! {many_probe_started, self()},
                              receive never -> {error, impossible} end
                          end},
    {Certifier, CertifierMonitor} = spawn_monitor(
      fun() ->
          _ = quod_dtx_current_view:test_certify_applied_many(
                maps:get(owner_ns, F), Requests, 1000, BlockedDeps),
          ok
      end),
    Children = collect_many_children(2, []),
    ChildMonitors = [{Pid, erlang:monitor(process, Pid)} || Pid <- Children],
    exit(Certifier, kill),
    receive {'DOWN', CertifierMonitor, process, Certifier, killed} -> ok
    after 2000 -> error(many_certifier_survived)
    end,
    lists:foreach(
      fun({Pid, Monitor}) ->
          receive {'DOWN', Monitor, process, Pid, killed} -> ok
          after 2000 -> error({many_child_survived, Pid})
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

operation_outcome_requires_f_plus_one_current_validators_test() ->
    F = fixture(4),
    [A, B | _] = maps:get(committee, F),
    Ref = outcome_operation_ref(F),
    Status = #{status => claimed, operation_state => terminal,
               height => 14, ref => Ref,
               request_digest => digest(13),
               outcome_ref => outcome_transaction_ref(F)},
    Matching = maps:from_keys([A, B], true),
    Deps = outcome_dependencies(
             maps:get(view, F),
             fun(Key, Request, Target, CommitteeId, Slot) ->
                     case maps:is_key(Key, Matching) of
                         true -> outcome_reply(
                                   Request, Target, CommitteeId, Slot,
                                   Status);
                         false -> {error, not_ready}
                     end
             end),
    ?assertEqual({ok, Status}, lookup(F, Ref, Deps)).

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

certify(F, Dependencies) ->
    quod_dtx_current_view:test_certify_applied(
      maps:get(owner_ns, F), source(F), maps:get(claim, F),
      maps:get(evidence, F), 1000, Dependencies).

source(F) ->
    {remote, maps:get(source_routes, F)}.

lookup(F, OutcomeRef, Dependencies) ->
    quod_dtx_current_view:test_lookup_outcome(
      maps:get(owner_ns, F),
      {remote, maps:get(source_routes, F)},
      OutcomeRef, 1000, Dependencies).

many_requests(F, Count) ->
    lists:duplicate(
      Count, {source(F), maps:get(claim, F), maps:get(evidence, F)}).

dependencies(F, Reply) ->
    View = maps:get(view, F),
    #{view => fun(_Source, _Ref, _Timeout) -> {ok, View} end,
      local =>
          fun(_Ns, Request, _Timeout) ->
                  [Key | _] = maps:get(committee, View),
                  Reply(Key, Request)
          end,
      remote =>
          fun(_OwnerNs, _TargetNs, Key, _Endpoint, Request, _Timeout) ->
                  Reply(Key, Request)
          end,
      resolve => fun(_Key) -> error end,
      node_key => fun() -> none end,
      network_identity =>
          fun() -> {ok, maps:get(network_identity, F)} end}.

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
      resolve => fun(_Key) -> error end,
      node_key => fun() -> none end}.

outcome_reply(
  {outcome, RequestId, _OutcomeRef, _CommitteeId, _MinimumSlot},
  Target, CommitteeId, AppliedFloor, Outcome) ->
    {ok, {outcome, RequestId, Target, CommitteeId, AppliedFloor, Outcome}, []}.

barrier_reply(
  {outcome_barrier, RequestId, _GroupRef, _CommitteeId, _MinimumSlot},
  Target, CommitteeId, AppliedFloor, Status) ->
    {ok, {outcome_barrier, RequestId, Target, CommitteeId,
          AppliedFloor, Status}, []}.

outcome_transaction_ref(F) ->
    {TargetNs, Anchor} = maps:get(identity, maps:get(view, F)),
    {transaction, TargetNs, Anchor, digest(220)}.

outcome_group_ref(F, Coordinator) ->
    {TargetNs, Anchor} = maps:get(identity, maps:get(view, F)),
    {group, TargetNs, Anchor, Coordinator, digest(221), digest(222)}.

outcome_operation_ref(F) ->
    {TargetNs, Anchor} = maps:get(identity, maps:get(view, F)),
    {operation, TargetNs, Anchor,
     agent_ref(<<"quod:agent">>, digest(223), 223), digest(13)}.

group_committed(Ref) ->
    #{status => committed, height => 9, ref => Ref,
      bindings => [{<<"X">>, linked}],
      participant_slots =>
          [{{<<"quod:a">>, digest(230)}, 7, 1},
           {{<<"quod:b">>, digest(231)}, 8, 2}]}.

applied_reply(F, Key, Request) when is_binary(Key) ->
    applied_reply(F, maps:get(Key, maps:get(signers, F)), Request);
applied_reply(
  F, #{pubkey := Signer} = Identity,
  {applied, RequestId, GroupId, FinalizeRef, Generation, Verdict}) ->
    Target = maps:get(target, F),
    CommitteeId = maps:get(committee_id, F),
    {ok, {Signer, Signature}} = quod_dtx_current_view:sign_applied_vote(
                                 maps:get(network_identity, F), Target,
                                 CommitteeId, GroupId, FinalizeRef,
                                 Generation, Verdict, Identity),
    {ok, {applied, RequestId, Target, CommitteeId, GroupId, FinalizeRef,
          Generation, Verdict, Signer, Signature}, []}.

fixture(N) ->
    OwnerNs = <<"quod:owner">>,
    Target = {<<"quod:target">>, digest(1)},
    SignerRows = [signer() || _ <- lists:seq(1, N)],
    Signers = maps:from_list(
                [{maps:get(pubkey, Signer), Signer} || Signer <- SignerRows]),
    Committee = lists:sort(maps:keys(Signers)),
    CommitteeId = digest(2),
    NetworkIdentity = digest(250),
    RouteMap = maps:from_list(
               [{Key, {"127.0.0.1", 20000 + I}}
                || {Key, I} <- lists:zip(Committee, lists:seq(1, N))]),
    Routes = [{Key, [Endpoint]}
              || {Key, Endpoint} <- maps:to_list(RouteMap)],
    GroupId = digest(5),
    Generation = 9,
    Verdict = commit,
    {Evidence, FinalizeRef} = finalize_evidence(
                                Target, GroupId, Generation, Verdict,
                                Committee, CommitteeId, RouteMap,
                                hd(SignerRows)),
    Claim = #{target => Target, group_id => GroupId,
              finalize_ref => FinalizeRef, generation => Generation,
              verdict => commit},
    View = #{identity => Target, slot => 8, generation => 9,
             committee => Committee, committee_id => CommitteeId,
             route_candidates => Routes},
    #{owner_ns => OwnerNs, target => Target, claim => Claim,
      evidence => Evidence, view => View, committee => Committee,
      committee_id => CommitteeId, source_routes => Routes,
      signers => Signers, network_identity => NetworkIdentity}.

finalize_evidence(Target, GroupId, Generation, Verdict,
                  Committee, CommitteeId, Routes, ControlSigner) ->
    DecisionRef = certified_ref({<<"quod:origin">>, digest(6)}, 2, digest(7)),
    PrepareRef = certified_ref(Target, 3, digest(8)),
    {ok, Finalize} = quod_dtx:new_finalize(
                       GroupId, DecisionRef, Verdict, PrepareRef, Generation),
    {ok, Control} = quod_dtx:sign_control(
                      Target, Finalize, digest(9), 1, 1, ControlSigner),
    {ok, Blob} = quod_dtx:encode_control(Control),
    Slot = 7,
    Payload = {batch, [{dtx, Blob}]},
    Block = #block{slot = Slot, parent = Slot - 1,
                   payload = Payload, timestamp = 0},
    BlockHash = quod_simplex:block_hash(Block),
    Entry = #entry{index = Slot, data = Payload,
                   cert = #cert{kind = commit, slot = Slot,
                                block_hash = BlockHash, sigs = []}},
    {ok, FinalizeRef} = quod_dtx:certified_entry_ref(Target, Entry, Control),
    {#{identity => Target, phase => finalize, control => Control,
       entry => Entry, committee => Committee, committee_id => CommitteeId,
       routes => Routes},
     FinalizeRef}.

certificate(F, Keys, Overrides) ->
    Signers = maps:get(signers, F),
    certificate_with_signers(
      F, [maps:get(Key, Signers) || Key <- Keys], Overrides).

certificate_with_signers(F, Signers, Overrides) ->
    Binding = certificate_binding(F, Overrides),
    Rows = lists:keysort(
             1, [signed_row_with_signer(Binding, Signer)
                 || Signer <- Signers]),
    #{network_identity := NetworkIdentity, target := Target,
      committee_id := CommitteeId, group_id := GroupId,
      finalize_ref := FinalizeRef, generation := Generation,
      verdict := Verdict} = Binding,
    {quod_dtx_applied_certificate, 1, NetworkIdentity, Target, CommitteeId,
     GroupId, FinalizeRef, Generation, Verdict, Rows}.

certificate_binding(F, Overrides) ->
    Claim = maps:get(claim, F),
    maps:merge(
      #{network_identity => maps:get(network_identity, F),
        target => maps:get(target, F),
        committee_id => maps:get(committee_id, F),
        group_id => maps:get(group_id, Claim),
        finalize_ref => maps:get(finalize_ref, Claim),
        generation => maps:get(generation, Claim),
        verdict => maps:get(verdict, Claim)},
      Overrides).

signed_row(F, Key, Overrides) ->
    signed_row_with_signer(
      certificate_binding(F, Overrides),
      maps:get(Key, maps:get(signers, F))).

signed_row_with_signer(
  #{network_identity := NetworkIdentity, target := Target,
    committee_id := CommitteeId, group_id := GroupId,
    finalize_ref := FinalizeRef, generation := Generation,
    verdict := Verdict},
  Signer) ->
    {ok, Row} = quod_dtx_current_view:sign_applied_vote(
                  NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
                  Generation, Verdict, Signer),
    Row.

signer() ->
    {Pub, Seed} = quod_identity:generate(),
    #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}.

certified_ref({Ns, Anchor}, Slot, Digest) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, digest(240), Digest,
                  term_to_binary({qc, Slot}, [deterministic])),
    Ref.

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
        {many_probe_started, Pid} ->
            collect_many_children(Left - 1, [Pid | Acc])
    after 2000 ->
        error({missing_many_children, Left})
    end.

digest(N) ->
    crypto:hash(sha256, <<N:64/unsigned-big>>).

agent_ref(Ns, Anchor, N) ->
    {ok, #{blob := Blob}} = quod_agent_ref:from_text(
                              Ns, Anchor,
                              <<"human_user(", (integer_to_binary(N))/binary,
                                ").">>,
                              2),
    Blob.
