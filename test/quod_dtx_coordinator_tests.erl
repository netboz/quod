-module(quod_dtx_coordinator_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

options_are_strict_and_share_the_endpoint_deadline_test() ->
    ?assertMatch({ok, _}, quod_dtx_coordinator:test_options(#{})),
    ?assertMatch(
       {ok, _},
       quod_dtx_coordinator:test_options(
         #{request_timeout_ms => 1})),
    ?assertEqual(
       {error, invalid_coordinator_options},
       quod_dtx_coordinator:test_options(#{unknown => 1})),
    ?assertEqual(
       {error, invalid_coordinator_options},
       quod_dtx_coordinator:test_options(
         #{request_timeout_ms =>
               ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS + 1})),
    ?assertEqual(
       {error, invalid_coordinator_options},
       quod_dtx_coordinator:test_options(
         #{request_timeout_ms => 0})).

remote_operation_temporary_reply_parks_on_progress_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    {ok, ClaimEvidence} = quod_transaction:encode_evidence(
                            maps:get(certified_claim_ref, Fixture),
                            maps:get(claim, Fixture)),
    RequestId = <<199:128>>,
    Request = {apply_claim, RequestId, ClaimEvidence},
    lists:foreach(
      fun(Reason) ->
          ?assertEqual(
             wait,
             quod_dtx_coordinator:
               test_operation_target_response_disposition(
                 Request, {error, RequestId, Reason}))
      end,
      [busy, not_ready, not_found, conflict_retry,
       read_certificate_unavailable]),
    ?assertEqual(
       invalid_operation_claim,
       quod_dtx_coordinator:test_operation_target_response_disposition(
         Request, {error, RequestId, invalid_request})),
    ?assertEqual(
       invalid_target_response,
       quod_dtx_coordinator:test_operation_target_response_disposition(
         Request, {error, <<200:128>>, not_ready})),
    ?assertEqual(
       invalid_target_response,
       quod_dtx_coordinator:test_operation_target_response_disposition(
         Request, malformed)).

cohosted_submit_falls_through_only_on_retryable_local_results_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          {ok, RecordBlob} = quod_dtx:encode_record(Begin),
          Request = {submit, <<200:128>>, RecordBlob},
          RequestId = element(2, Request),
          Digest = quod_dtx:record_digest(Begin),
          {_Target, _Control, Ref} = evidence(maps:get(origin, F), Begin, 1, F),
          ?assertEqual(
             uncertain,
             quod_dtx_coordinator:test_local_submit_result(
               Request,
               {ok, {error, RequestId, not_ready},
                {reply_source, local, []}})),
          ?assertEqual(
             uncertain,
             quod_dtx_coordinator:test_local_submit_result(
               Request,
               {ok, {error, RequestId, busy},
                {reply_source, local, []}})),
          ?assertEqual(
             uncertain,
             quod_dtx_coordinator:test_local_submit_result(
               Request, {error, unavailable})),
          ?assertEqual(
             terminal,
             quod_dtx_coordinator:test_local_submit_result(
               Request,
               {ok, {accepted, RequestId, Digest, Ref},
                {reply_source, local, []}})),
          ?assertEqual(
             terminal,
             quod_dtx_coordinator:test_local_submit_result(
               Request,
               {ok, {error, RequestId, invalid_request},
                {reply_source, local, []}})),
          %% A Byzantine first route cannot turn its fabricated rejection or
          %% malformed response into a group-terminal result; traversal reaches
          %% the next pinned validator. Only correlated acceptance/refusal ends
          %% remote iteration.
          ?assertEqual(
             next,
             quod_dtx_coordinator:test_remote_submit_result(
               Request, {error, RequestId, invalid_request})),
          ?assertEqual(
             next,
             quod_dtx_coordinator:test_remote_submit_result(
               Request, {accepted, <<204:128>>, Digest, Ref})),
          ?assertEqual(
             next,
             quod_dtx_coordinator:test_remote_submit_result(
               Request, malformed)),
          ?assertEqual(
             terminal,
             quod_dtx_coordinator:test_remote_submit_result(
               Request, {accepted, RequestId, Digest, Ref}))
      end).

remote_endpoint_fallback_preserves_uncertainty_and_correlation_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          {ok, RecordBlob} = quod_dtx:encode_record(Begin),
          Request = {submit, <<205:128>>, RecordBlob},
          RequestId = element(2, Request),
          Digest = quod_dtx:record_digest(Begin),
          {_Target, _Control, Ref} = evidence(
                                      maps:get(origin, F), Begin, 1, F),
          Peer = digest(214),
          Live = {"127.0.0.1", 3214},
          Historical = {"127.0.0.1", 3215},

          TimeoutThenClosed =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  case Endpoint of
                      Live -> {error, timeout};
                      Historical -> {error, closed}
                  end
              end,
          ?assertEqual(
             {error, timeout},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000,
               TimeoutThenClosed)),
          assert_fallback_attempts(Live, Historical, Request),

          BusyThenClosed =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  case Endpoint of
                      Live -> {ok, {error, RequestId, busy}, []};
                      Historical -> {error, closed}
                  end
              end,
          ?assertEqual(
             {ok, {error, RequestId, busy},
              {reply_source, remote, Peer, []}},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000, BusyThenClosed)),
          assert_fallback_attempts(Live, Historical, Request),

          AcceptedFallback =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  case Endpoint of
                      Live -> {error, closed};
                      Historical ->
                          {ok, {accepted, RequestId, Digest, Ref}, []}
                  end
              end,
          ?assertEqual(
             {ok, {accepted, RequestId, Digest, Ref},
              {reply_source, remote, Peer, []}},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000,
               AcceptedFallback)),
          assert_fallback_attempts(Live, Historical, Request),

          InvalidRequest =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  {ok, {error, RequestId, invalid_request}, []}
              end,
          ?assertEqual(
             {ok, {error, RequestId, invalid_request},
              {reply_source, remote, Peer, []}},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000, InvalidRequest)),
          receive
              {fallback_attempt, Live, Request} -> ok
          after 1000 -> error(missing_authoritative_rejection)
          end,
          receive
              {fallback_attempt, Historical, _} ->
                  error(redialed_authoritative_rejection)
          after 0 -> ok
          end
      end).

assert_fallback_attempts(First, Second, Request) ->
    receive {fallback_attempt, First, Request} -> ok
    after 1000 -> error({missing_fallback_attempt, First})
    end,
    receive {fallback_attempt, Second, Request} -> ok
    after 1000 -> error({missing_fallback_attempt, Second})
    end,
    receive {fallback_attempt, _, _} -> error(extra_fallback_attempt)
    after 0 -> ok
    end.

submit_fanout_starts_every_source_and_cleans_losers_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          {ok, RecordBlob} = quod_dtx:encode_record(Begin),
          Request = {submit, <<201:128>>, RecordBlob},
          RequestId = element(2, Request),
          Digest = quod_dtx:record_digest(Begin),
          {_Target, _Control, Ref} = evidence(maps:get(origin, F), Begin, 1, F),
          Sources = [{remote, digest(211), [{"127.0.0.1", 3211}]},
                     {remote, digest(212), [{"127.0.0.1", 3212}]},
                     {remote, digest(213), [{"127.0.0.1", 3213}]}],
          Parent = self(),
          RequestFun =
              fun(Source) ->
                  Parent ! {fanout_started, Source, self()},
                  receive {fanout_result, Result} -> Result end
              end,
          Caller = spawn(
                     fun() ->
                         Parent !
                           {fanout_reply, self(),
                            quod_dtx_coordinator:
                              test_submit_endpoint_requests(
                                Sources, Request, 2000, RequestFun)}
                     end),
          Started = receive_fanout_started(length(Sources), #{}),
          ?assertEqual(lists:sort(Sources), lists:sort(maps:keys(Started))),
          Monitors = maps:map(
                       fun(_Source, Pid) ->
                           erlang:monitor(process, Pid)
                       end, Started),
          Winner = hd(Sources),
          maps:get(Winner, Started) !
              {fanout_result,
               {ok, {accepted, RequestId, Digest, Ref}, Winner}},
          receive
              {fanout_reply, Caller,
               {reply, {accepted, RequestId, Digest, Ref}, Winner}} -> ok
          after 1000 ->
              error(missing_fanout_terminal_reply)
          end,
          lists:foreach(
            fun({Source, Pid}) when Source =:= Winner ->
                    MRef = maps:get(Source, Monitors),
                    receive {'DOWN', MRef, process, Pid, normal} -> ok
                    after 1000 -> error({fanout_winner_not_reaped, Pid})
                    end;
               ({Source, Pid}) ->
                    MRef = maps:get(Source, Monitors),
                    receive {'DOWN', MRef, process, Pid, killed} -> ok
                    after 1000 -> error({fanout_worker_not_cleaned, Pid})
                    end
            end, maps:to_list(Started))
      end).

receive_fanout_started(0, Acc) ->
    Acc;
receive_fanout_started(N, Acc) ->
    receive
        {fanout_started, Source, Pid} ->
            receive_fanout_started(N - 1, Acc#{Source => Pid})
    after 1000 ->
        error({missing_fanout_workers, N})
    end.

historical_routes_may_be_a_valid_committee_subset_test() ->
    KeyA = digest(2),
    KeyB = digest(3),
    KeyC = digest(4),
    EndpointA = {"127.0.0.1", 4001},
    EndpointB = {"127.0.0.1", 4002},
    Committee = [KeyA, KeyB],
    ?assert(
       quod_dtx_coordinator:test_valid_validator_routes(
         #{KeyA => EndpointA}, Committee)),
    ?assert(
       quod_dtx_coordinator:test_valid_validator_routes(#{}, Committee)),
    ?assertNot(
       quod_dtx_coordinator:test_valid_validator_routes(
         #{KeyA => EndpointA, KeyC => EndpointB}, Committee)),
    ?assertNot(
       quod_dtx_coordinator:test_valid_validator_routes(
         #{KeyA => bad_endpoint}, Committee)).

phase_evidence_structure_fails_loudly_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Target = maps:get(origin, F),
          {Control, Entry, Ref} = certified_control(Target, Begin, 1, F),
          Pub = maps:get(pubkey, maps:get(signer, F)),
          Evidence =
              #{identity => Target, phase => 'begin', generation => 0,
                control => Control, ref => Ref,
                entry => Entry,
                committee => [Pub], committee_id => digest(211),
                routes => #{}},
          ?assertMatch(
             {ok, Control, 0,
              #{identity := Target, phase := 'begin', control := Control,
                ref := Ref, generation := 0, entry := Entry,
                committee := [Pub], committee_id := _, routes := #{}},
              Entry},
             quod_dtx_coordinator:test_valid_phase_evidence(
               Target, quod_dtx:group_id(Begin), 'begin', Ref, Evidence)),
          ?assertError(
             {badkey, routes},
             quod_dtx_coordinator:test_valid_phase_evidence(
               Target, quod_dtx:group_id(Begin), 'begin', Ref,
               maps:remove(routes, Evidence)))
      end).

snapshot_rows_are_canonical_idempotent_and_conflict_closed_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [Origin, Target] = maps:get(targets, F),
          BeginEvidence = evidence(Origin, Begin, 1, F),
          {ok, {independent, prepare,
                [{submit, Target, Prepare}]}} =
              quod_dtx_recovery:next(
                Begin,
                (quod_dtx_recovery:empty())#{evidence := [BeginEvidence]}),
          PrepareEvidence = evidence(Target, Prepare, 2, F),
          S0 = quod_dtx_recovery:empty(),
          {progress, S1} = quod_dtx_coordinator:test_put_evidence(
                             PrepareEvidence, S0),
          {progress, S2} = quod_dtx_coordinator:test_put_evidence(
                             BeginEvidence, S1),
          ?assertEqual(
             [BeginEvidence, PrepareEvidence],
             maps:get(evidence, S2)),
          ?assertEqual(
             {same, S2},
             quod_dtx_coordinator:test_put_evidence(
               PrepareEvidence, S2)),
          {Target, Control, Ref} = PrepareEvidence,
          Conflicting = {Target, setelement(8, Control, 99), Ref},
          ?assertEqual(
             {error, conflicting_phase_evidence},
             quod_dtx_coordinator:test_put_evidence(Conflicting, S2))
      end).

committed_begin_bootstrap_starts_with_prepare_not_begin_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = {Ns, _Anchor} = maps:get(origin, F),
          {Control, Entry, Ref} = certified_control(Origin, Begin, 1, F),
          Pub = maps:get(pubkey, maps:get(signer, F)),
          Evidence =
              #{identity => Origin, slot => 1,
                record_digest => quod_dtx:record_digest(Control),
                phase => 'begin', generation => 0,
                control => Control, ref => Ref,
                entry => Entry,
                committee => [Pub], committee_id => digest(210),
                routes => #{}},
          {ok, {independent, prepare, Commands}} =
              quod_dtx_coordinator:test_initial_commands(
                             Ns, Begin, Ref, Evidence),
          ?assertMatch([{submit, _, {quod_dtx_prepare, 3, _, _, _, _, _}}],
                       Commands),
          ?assertNot(
             lists:any(
               fun({submit, _, {quod_dtx_begin, 3, _, _, _}}) -> true;
                  (_) -> false
               end, Commands))
      end).

material_source_begin_seeds_the_plan_generation_not_the_current_view_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = {Ns, _Anchor} = maps:get(origin, F),
          {Control, Entry, Ref} = certified_control(Origin, Begin, 1, F),
          Pub = maps:get(pubkey, maps:get(signer, F)),
          CurrentGeneration = 37,
          {ok, _Manifest, _PlanDigest, PlanBlob} =
              quod_dtx:begin_participant_payload(Begin, Origin),
          {ok, Plan} = quod_dtx:decode(PlanBlob),
          PreparedGeneration = quod_dtx:overlay_generation(Plan),
          ?assertNotEqual(CurrentGeneration, PreparedGeneration),
          Evidence =
              #{identity => Origin, slot => 1,
                record_digest => quod_dtx:record_digest(Control),
                phase => 'begin', generation => CurrentGeneration,
                control => Control, ref => Ref, entry => Entry,
                committee => [Pub], committee_id => digest(215),
                routes => #{}},
          {ok, Snapshot} =
              quod_dtx_coordinator:test_initial_snapshot(
                Ns, Begin, Ref, Evidence),
          ?assertEqual([{Origin, PreparedGeneration}],
                       maps:get(generations, Snapshot))
      end).

certified_prepare_after_finalize_keeps_its_signed_plan_generation_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = {Ns, _Anchor} = maps:get(origin, F),
          [_Origin, Target] = maps:get(targets, F),
          {BeginControl, BeginEntry, BeginRef} =
              certified_control(Origin, Begin, 1, F),
          Pub = maps:get(pubkey, maps:get(signer, F)),
          BeginEvidence =
              #{identity => Origin, slot => 1,
                record_digest => quod_dtx:record_digest(BeginControl),
                phase => 'begin', generation => 0,
                control => BeginControl, ref => BeginRef,
                entry => BeginEntry,
                committee => [Pub], committee_id => digest(216),
                routes => #{}},
          {ok, {independent, prepare,
                [{submit, Target, Prepare}]}} =
              quod_dtx_coordinator:test_initial_commands(
                Ns, Begin, BeginRef, BeginEvidence),
          {PrepareControl, PrepareEntry, PrepareRef} =
              certified_control(Target, Prepare, 2, F),
          {ok, _Manifest, _PlanDigest, PlanBlob} =
              quod_dtx:prepare_payload(PrepareControl),
          {ok, Plan} = quod_dtx:decode(PlanBlob),
          PreparedGeneration = quod_dtx:overlay_generation(Plan),
          %% A verifier recovering after Finalize observes the current view at
          %% base+1.  The certified Prepare still owns the immutable base used
          %% to reconstruct the exact Decision/Finalize chain.
          CurrentGeneration = PreparedGeneration + 1,
          PrepareEvidence =
              #{identity => Target, slot => 2,
                record_digest => quod_dtx:record_digest(PrepareControl),
                phase => prepare, generation => CurrentGeneration,
                control => PrepareControl, ref => PrepareRef,
                entry => PrepareEntry,
                committee => [Pub], committee_id => digest(217),
                routes => #{}},
          {ok, Snapshot} =
              quod_dtx_coordinator:test_install_phase_snapshot(
                Ns, Begin, BeginRef, BeginEvidence,
                Target, quod_dtx:group_id(Begin), prepare,
                PrepareRef, PrepareEvidence),
          {ok, _OriginManifest, _OriginPlanDigest, OriginPlanBlob} =
              quod_dtx:begin_participant_payload(Begin, Origin),
          {ok, OriginPlan} = quod_dtx:decode(OriginPlanBlob),
          ?assertEqual(
             lists:keysort(1,
                           [{Origin,
                             quod_dtx:overlay_generation(OriginPlan)},
                            {Target, PreparedGeneration}]),
             maps:get(generations, Snapshot)),
          ?assertMatch(
             {ok, {ordered, decision,
                   [{submit, Origin,
                     {quod_dtx_decision, 3, _, _, _, _, _}}]}},
             quod_dtx_recovery:next(Begin, Snapshot))
      end).

unsigned_generation_hints_advance_but_certified_prepares_are_exact_test() ->
    A = {<<"quod:a">>, digest(1)},
    B = {<<"quod:b">>, digest(2)},
    S0 = quod_dtx_recovery:empty(),
    {progress, S1} = quod_dtx_coordinator:test_put_generation(B, 4, S0),
    {progress, S2} = quod_dtx_coordinator:test_put_generation(A, 2, S1),
    ?assertEqual([{A, 2}, {B, 4}], maps:get(generations, S2)),
    ?assertEqual(
       {same, S2},
       quod_dtx_coordinator:test_put_generation(B, 4, S2)),
    {progress, S3} = quod_dtx_coordinator:test_put_generation(B, 5, S2),
    ?assertEqual([{A, 2}, {B, 5}], maps:get(generations, S3)),
    ?assertEqual(
       {same, S3},
       quod_dtx_coordinator:test_put_generation(B, 4, S3)),
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [_Origin, Target] = maps:get(targets, F),
          BeginEvidence = evidence(Origin, Begin, 1, F),
          {ok, {independent, prepare, [{submit, Target, Prepare} | _]}} =
              quod_dtx_recovery:next(
                Begin,
                (quod_dtx_recovery:empty())#{evidence := [BeginEvidence]}),
          PrepareEvidence = evidence(Target, Prepare, 2, F),
          Prepared = (quod_dtx_recovery:empty())#{
                       evidence := [BeginEvidence, PrepareEvidence],
                       generations := [{Target, 2}]},
          ?assertEqual(
             {error, conflicting_target_generation},
             quod_dtx_coordinator:test_put_generation(
               Target, 3, Prepared))
      end).

applied_wave_retains_verified_siblings_when_one_target_retries_test() ->
    A = {<<"quod:applied-a">>, digest(218)},
    B = {<<"quod:applied-b">>, digest(219)},
    GroupId = digest(220),
    ARef = dtx_test_ref(A, 7, digest(221)),
    BRef = dtx_test_ref(B, 8, digest(222)),
    ACommand = {applied, A, GroupId, ARef, 2, commit},
    BCommand = {applied, B, GroupId, BRef, 3, commit},
    ACertificate = applied_certificate(ACommand, digest(223)),
    BCertificate = applied_certificate(BCommand, digest(224)),
    {ok, Snapshot, [A], [BCommand], true} =
        quod_dtx_coordinator:test_install_applied_results(
          [ACommand, BCommand],
          [{verified, ACertificate}, retry],
          quod_dtx_recovery:empty()),
    ?assertEqual(
       [{A, ACertificate}],
       maps:get(applied, Snapshot)),
    %% A later observation wave need only carry B. The already-certified A
    %% row survives and cannot be erased by B's temporary unavailability.
    {ok, Snapshot2, [B], [], true} =
        quod_dtx_coordinator:test_install_applied_results(
          [BCommand],
          [{verified, BCertificate}], Snapshot),
    ?assertEqual(
       [{A, ACertificate}, {B, BCertificate}],
       maps:get(applied, Snapshot2)).

worker_is_owned_by_an_exact_monitor_not_a_link_test() ->
    with_fixture(
      fun(F) ->
          Parent = self(),
          Begin = maps:get('begin', F),
          {Ns, _Anchor} = maps:get(origin, F),
          Owner = spawn(
                    fun() ->
                        Result = quod_dtx_coordinator:start_monitor(
                                   self(), Ns, Begin, none,
                                   #{request_timeout_ms => 1}),
                        Parent ! {coordinator_started, self(), Result},
                        receive stop -> ok end
                    end),
          Worker = receive
                       {coordinator_started, Owner, {ok, Pid, Monitor}}
                         when is_pid(Pid), is_reference(Monitor) -> Pid
                   after 1000 -> error(coordinator_start_timeout)
                   end,
          WorkerMonitor = erlang:monitor(process, Worker),
          exit(Owner, kill),
          receive
              {'DOWN', WorkerMonitor, process, Worker, normal} -> ok
          after 1000 ->
              error(coordinator_owner_cleanup_timeout)
          end,
          %% An ordinary monitored worker must not be linked back to this test.
          ?assert(is_process_alive(self()))
      end).

coordinator_close_cancels_wave_timer_and_workers_test() ->
    Workers = [spawn(fun blocked_worker/0) || _ <- lists:seq(1, 3)],
    Monitors = [{Pid, erlang:monitor(process, Pid)} || Pid <- Workers],
    Timer = quod_dtx_coordinator:test_close_wave(Workers),
    ?assertEqual(false, erlang:read_timer(Timer)),
    lists:foreach(
      fun({Pid, Monitor}) ->
          receive
              {'DOWN', Monitor, process, Pid, killed} -> ok
          after 1000 -> error({wave_worker_survived_close, Pid})
          end
      end, Monitors),
    receive test_wave_timeout -> error(wave_timer_survived_close)
    after 0 -> ok
    end.

owned_workers_follow_their_immediate_owner_transitively_test() ->
    Test = self(),
    Owner = spawn(
              fun() ->
                  {Outer, _OuterMonitor} =
                      quod_dtx_coordinator:test_spawn_owned_worker(
                        self(),
                        fun() ->
                            {Nested, _NestedMonitor} =
                                quod_dtx_coordinator:
                                  test_spawn_owned_worker(
                                    self(), fun blocked_worker/0),
                            Test ! {owned_worker_tree, self(), Nested},
                            blocked_worker()
                        end),
                  Test ! {owned_outer, self(), Outer},
                  blocked_worker()
              end),
    Outer = receive {owned_outer, Owner, OuterPid} -> OuterPid
            after 1000 -> error(missing_owned_outer)
            end,
    Nested = receive {owned_worker_tree, Outer, NestedPid} -> NestedPid
             after 1000 -> error(missing_owned_nested)
             end,
    OuterMonitor = erlang:monitor(process, Outer),
    NestedMonitor = erlang:monitor(process, Nested),
    exit(Owner, kill),
    receive {'DOWN', OuterMonitor, process, Outer, killed} -> ok
    after 1000 -> error(outer_worker_survived_owner)
    end,
    receive {'DOWN', NestedMonitor, process, Nested, killed} -> ok
    after 1000 -> error(nested_worker_survived_outer)
    end.

only_submit_death_is_uncertain_and_only_timeout_is_retryable_test() ->
    ?assertEqual(
       uncertain,
       quod_dtx_coordinator:test_worker_down_disposition(
         submit, simulated_crash)),
    lists:foreach(
      fun(Stage) ->
          ?assertEqual(
             retry,
             quod_dtx_coordinator:test_worker_down_disposition(
               Stage, timeout)),
          ?assertEqual(
             {fatal, {dtx_worker_crash, Stage, simulated_crash}},
             quod_dtx_coordinator:test_worker_down_disposition(
               Stage, simulated_crash))
      end, [phase, evidence, applied]).

blocked_worker() ->
    receive stop -> ok end.

source_progress_uses_owner_commit_edge_not_foreign_history_test() ->
    Origin = {<<"quod:source-progress">>, digest(221)},
    Remote = {<<"quod:remote-progress">>, digest(222)},
    SameNameWrongAnchor = {element(1, Origin), digest(223)},
    ?assertEqual(
       owner,
       quod_dtx_coordinator:test_progress_source(Origin, Origin)),
    ?assertEqual(
       foreign,
       quod_dtx_coordinator:test_progress_source(Remote, Origin)),
    ?assertEqual(
       foreign,
       quod_dtx_coordinator:test_progress_source(
         SameNameWrongAnchor, Origin)).

source_progress_accepts_only_its_existing_commit_stream_test() ->
    Identity = {<<"quod:source-progress">>, digest(224)},
    ?assert(
       quod_dtx_coordinator:test_local_progress_event(
         {local_dtx_progress, Identity, 7}, Identity)),
    ?assertNot(
       quod_dtx_coordinator:test_local_progress_event(
         {local_dtx_progress,
          {<<"quod:other">>, element(2, Identity)}, 7}, Identity)),
    ?assertNot(
       quod_dtx_coordinator:test_local_progress_event(
         {local_dtx_progress,
          {element(1, Identity), digest(225)}, 7}, Identity)),
    ?assertNot(
       quod_dtx_coordinator:test_local_progress_event(
         {local_dtx_progress, Identity, -1}, Identity)),
    ?assertNot(
       quod_dtx_coordinator:test_local_progress_event(
         malformed, Identity)).

invalid_begin_allocates_no_worker_test() ->
    ?assertEqual(
       {error, invalid_begin},
       quod_dtx_coordinator:start_monitor(
         self(), <<"quod:a">>, malformed, none, #{})).

dormant_cancel_retires_custody_only_on_explicit_terminal_reply_test() ->
    RequestId = <<230:128>>,
    Request = {cancel_operation_effect, RequestId, <<"signed-submission">>},
    ?assertEqual(
       terminal,
       quod_dtx_coordinator:test_dormant_cancel_disposition(
         Request,
         {operation_effect_cancelled, RequestId, cancelled})),
    ?assertEqual(
       terminal,
       quod_dtx_coordinator:test_dormant_cancel_disposition(
         Request,
         {operation_effect_cancelled, RequestId, not_found})),
    ?assertEqual(
       wait,
       quod_dtx_coordinator:test_dormant_cancel_disposition(
         Request,
         {operation_effect_cancelled, <<231:128>>, cancelled})),
    [?assertEqual(
       wait,
       quod_dtx_coordinator:test_dormant_cancel_disposition(
         Request, {error, RequestId, Reason}))
     || Reason <- [busy, not_ready, not_found, invalid_request]],
    ?assertEqual(
       wait,
       quod_dtx_coordinator:test_dormant_cancel_disposition(
         Request, malformed)).

dormant_cancel_signals_one_exact_directory_demand_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    stop_route_recovery_owners(),
    {ok, Directory} = quod_directory:start_link(
                        #{expire_tick_ms => 60000, ttl_ms => 10000}),
    unlink(Directory),
    {ok, Control} = quod_directory_control:start_link(#{}),
    unlink(Control),
    Fixture = quod_ct:signed_effect_operation_submission(),
    {OriginNs, _} = maps:get(origin, Fixture),
    Target = maps:get(target, Fixture),
    try
        {ok, Worker} = quod_dtx_coordinator:start_dormant_operation_monitor(
                         self(), OriginNs, maps:get(submission, Fixture)),
        ok = wait_route_demand(Target, 100),
        ?assertEqual(
           [Target],
           maps:get(route_demands,
                    quod_directory_control:test_control_state())),
        exit(Worker, kill)
    after
        catch gen_server:stop(Control),
        catch gen_server:stop(Directory),
        stop_route_recovery_owners()
    end.

%% Lost endpoint replies and link failures do not synthesize progress from a
%% foreign-history baseline. Custody remains parked until this exact target's
%% directory owner publishes a real route edge; that wake rebuilds only the
%% outer correlation id around the unchanged signed submission.
dormant_cancel_retries_exact_submission_only_on_target_route_edge_test() ->
    Owner = self(),
    OwnerMonitor = make_ref(),
    Target = {<<"quod:cancel-target">>, <<232:256>>},
    OtherTarget = {<<"quod:other-target">>, <<233:256>>},
    ?assertEqual(
       wait,
       quod_dtx_coordinator:test_dormant_wait_event(
         {quod_foreign_follow, make_ref(), make_ref(), Target,
          {building, 0, 0}},
         Owner, OwnerMonitor, Target)),
    ?assertEqual(
       wait,
       quod_dtx_coordinator:test_dormant_wait_event(
         {directory_route_available, OtherTarget},
         Owner, OwnerMonitor, Target)),
    ?assertEqual(
       retry,
       quod_dtx_coordinator:test_dormant_wait_event(
         {directory_route_available, Target},
         Owner, OwnerMonitor, Target)),
    ?assertEqual(
       stop,
       quod_dtx_coordinator:test_dormant_wait_event(
         {'DOWN', OwnerMonitor, process, Owner, shutdown},
         Owner, OwnerMonitor, Target)),
    SignedSubmission = <<"exact-signed-operation-submission">>,
    Request1 = quod_dtx_coordinator:test_dormant_cancel_request(
                 <<234:128>>, SignedSubmission),
    Request2 = quod_dtx_coordinator:test_dormant_cancel_request(
                 <<235:128>>, SignedSubmission),
    ?assertMatch(
       {cancel_operation_effect, <<234:128>>, SignedSubmission}, Request1),
    ?assertMatch(
       {cancel_operation_effect, <<235:128>>, SignedSubmission}, Request2).

%% ------------------------------------------------------------------
%% Exact two-participant Begin fixture
%% ------------------------------------------------------------------

with_fixture(Fun) ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Fun(fixture(Signer)).

fixture(#{pubkey := Pub} = Signer) ->
    Origin = {<<"quod:coordinator-a">>, digest(11)},
    Other = {<<"quod:coordinator-b">>, digest(12)},
    Targets = [Origin, Other],
    ProofId = digest(13),
    {PlanA, PlanABlob} = plan(Origin, ProofId, Origin, Signer, a),
    {PlanB, PlanBBlob} = plan(Other, ProofId, Origin, Signer, b),
    {ok, GoalBlob} = quod_durable_term:encode_goal({recover, group}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    Admission = digest(14),
    {ok, Manifest} =
        quod_dtx:new_manifest(
          #{proof_id => ProofId,
            coordinator =>
                {element(1, Origin), element(2, Origin), Pub, Admission},
            nonce => digest(15), principal => anonymous,
            goal => GoalBlob, result => ResultBlob,
            request_binding => none,
            participants =>
                [{Origin, quod_dtx:digest(PlanA)},
                 {Other, quod_dtx:digest(PlanB)}]}),
    {ok, AttA} = quod_dtx:attest_plan(Origin, PlanA, Manifest, Signer),
    {ok, AttB} = quod_dtx:attest_plan(Other, PlanB, Manifest, Signer),
    {ok, Begin} =
        quod_dtx:new_begin(
          Manifest, none,
          [{Origin, quod_dtx:digest(PlanA), PlanABlob, AttA},
           {Other, quod_dtx:digest(PlanB), PlanBBlob, AttB}]),
    #{signer => Signer, admission => Admission,
      origin => Origin, targets => Targets, 'begin' => Begin}.

plan(Target = {Ns, _Anchor}, ProofId, Origin, Signer, Value) ->
    Session = quod_proof_session:start(
                quod_ct:committed_kb([]),
                #{read_set => true, proof_context => {origin, test},
                  signer => Signer}),
    try
        InvocationId = crypto:strong_rand_bytes(16),
        Context = quod_predicates:proof_context(
                    Ns, 1, undefined, [Origin]),
        ok = quod_proof_session:open(
               Session, InvocationId, {assertz, {recovery_fact, Value}},
               allowed, Context, quod_transaction_scope:empty_selection()),
        {solution, _} = quod_proof_session:next(Session, InvocationId),
        {ok, Plan} = quod_dtx:seal_session(
                       Session,
                       #{target => Target, base_height => 1,
                         proof_id => ProofId, origin => Origin,
                         principal => anonymous, request_binding => none}),
        {ok, Blob} = quod_dtx:encode(Plan),
        {Plan, Blob}
    after
        quod_proof_session:stop(Session)
    end.

evidence(Target, Record, Slot,
         Fixture) ->
    {Control, _Entry, Ref} = certified_control(
                              Target, Record, Slot, Fixture),
    {Target, Control, Ref}.

certified_control(Target, Record, Slot,
                  #{signer := Signer, admission := Admission}) ->
    {ok, Control} = quod_dtx:sign_control(
                      Target, Record, Admission, Slot, Slot, Signer),
    {ok, Blob} = quod_dtx:encode_control(Control),
    Payload = {batch, [{dtx, Blob}]},
    {ok, Block} = quod_ledger:new_block(
                    Slot, Slot - 1, Payload, 0),
    BlockHash = quod_simplex:block_hash(Block),
    Entry = quod_ledger:entry(
              Block, #cert{kind = commit, slot = Slot,
                           block_hash = BlockHash, sigs = []}),
    {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Control),
    {Control, Entry, Ref}.

dtx_test_ref({Ns, Anchor}, Slot, RecordDigest) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, digest(225), RecordDigest,
                  term_to_binary({qc, Slot}, [deterministic])),
    Ref.

applied_certificate(
  {applied, Target, GroupId, FinalizeRef, Generation, Verdict}, CommitteeId) ->
    Certificate =
        {quod_dtx_applied_certificate, 1,
         digest(226), Target, CommitteeId, GroupId, FinalizeRef,
         Generation, Verdict, [{digest(227), <<228:512>>}]},
    ?assert(quod_dtx_current_view:valid_applied_certificate_shape(
              Certificate)),
    Certificate.

stop_route_recovery_owners() ->
    _ = [catch gen_server:stop(Pid)
         || Key <- [{directory, control}, {directory, node}],
            Pid <- [quod_reg:where(Key)], is_pid(Pid)],
    ok.

wait_route_demand(Identity, 0) ->
    error({route_demand_timeout, Identity,
           quod_directory_control:test_control_state()});
wait_route_demand(Identity, Left) ->
    State = quod_directory_control:test_control_state(),
    case lists:member(Identity, maps:get(route_demands, State)) of
        true -> ok;
        false ->
            receive after 5 -> ok end,
            wait_route_demand(Identity, Left - 1)
    end.

digest(N) -> <<N:256>>.
