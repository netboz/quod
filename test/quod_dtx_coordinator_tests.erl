-module(quod_dtx_coordinator_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

options_are_strict_and_share_the_endpoint_deadline_test() ->
    ?assertMatch({ok, _}, quod_dtx_coordinator:test_options(#{})),
    ?assertMatch(
       {ok, _},
       quod_dtx_coordinator:test_options(
         #{request_timeout_ms => 1, retry_initial_ms => 2,
           retry_max_ms => 8})),
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
       #{retry_initial_ms => 10, retry_max_ms => 9})).

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
               Request, {ok, {error, RequestId, not_ready}, local})),
          ?assertEqual(
             uncertain,
             quod_dtx_coordinator:test_local_submit_result(
               Request, {ok, {error, RequestId, busy}, local})),
          ?assertEqual(
             uncertain,
             quod_dtx_coordinator:test_local_submit_result(
               Request, {error, unavailable})),
          ?assertEqual(
             terminal,
             quod_dtx_coordinator:test_local_submit_result(
               Request,
               {ok, {accepted, RequestId, Digest, Ref}, local})),
          ?assertEqual(
             terminal,
             quod_dtx_coordinator:test_local_submit_result(
               Request,
               {ok, {error, RequestId, invalid_request}, local})),
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
                      Live -> {ok, {error, RequestId, busy}};
                      Historical -> {error, closed}
                  end
              end,
          ?assertEqual(
             {ok, {error, RequestId, busy}, {remote, Peer}},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000, BusyThenClosed)),
          assert_fallback_attempts(Live, Historical, Request),

          AcceptedFallback =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  case Endpoint of
                      Live -> {error, closed};
                      Historical ->
                          {ok, {accepted, RequestId, Digest, Ref}}
                  end
              end,
          ?assertEqual(
             {ok, {accepted, RequestId, Digest, Ref}, {remote, Peer}},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000,
               AcceptedFallback)),
          assert_fallback_attempts(Live, Historical, Request),

          InvalidRequest =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  {ok, {error, RequestId, invalid_request}}
              end,
          ?assertEqual(
             {ok, {error, RequestId, invalid_request}, {remote, Peer}},
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
          {Target, Control, Ref} = evidence(Target, Begin, 1, F),
          Pub = maps:get(pubkey, maps:get(signer, F)),
          Evidence =
              #{identity => Target, phase => 'begin', generation => 0,
                control => Control, ref => Ref,
                committee => [Pub], committee_id => digest(211),
                routes => #{}},
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
          [A, B] = maps:get(targets, F),
          BeginEvidence = evidence(Origin, Begin, 1, F),
          {ok, [{submit, A, PrepareA}, {submit, B, PrepareB}]} =
              quod_dtx_recovery:next(
                Begin,
                (quod_dtx_recovery:empty())#{evidence := [BeginEvidence]}),
          PrepareAEvidence = evidence(A, PrepareA, 2, F),
          PrepareBEvidence = evidence(B, PrepareB, 3, F),
          S0 = quod_dtx_recovery:empty(),
          {progress, S1} = quod_dtx_coordinator:test_put_evidence(
                             PrepareBEvidence, S0),
          {progress, S2} = quod_dtx_coordinator:test_put_evidence(
                             BeginEvidence, S1),
          {progress, S3} = quod_dtx_coordinator:test_put_evidence(
                             PrepareAEvidence, S2),
          ?assertEqual(
             [BeginEvidence, PrepareAEvidence, PrepareBEvidence],
             maps:get(evidence, S3)),
          ?assertEqual(
             {same, S3},
             quod_dtx_coordinator:test_put_evidence(
               PrepareAEvidence, S3)),
          {Target, Control, Ref} = PrepareAEvidence,
          Conflicting = {Target, setelement(8, Control, 99), Ref},
          ?assertEqual(
             {error, conflicting_phase_evidence},
             quod_dtx_coordinator:test_put_evidence(Conflicting, S3))
      end).

committed_begin_bootstrap_starts_with_prepare_not_begin_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = {Ns, _Anchor} = maps:get(origin, F),
          {Origin, Control, Ref} = evidence(Origin, Begin, 1, F),
          Pub = maps:get(pubkey, maps:get(signer, F)),
          Evidence =
              #{identity => Origin, slot => 1,
                record_digest => quod_dtx:record_digest(Control),
                phase => 'begin', generation => 0,
                control => Control, ref => Ref,
                committee => [Pub], committee_id => digest(210),
                routes => #{}},
          {ok, Commands} = quod_dtx_coordinator:test_initial_commands(
                             Ns, Begin, Ref, Evidence),
          ?assertMatch([{submit, _, {quod_dtx_prepare, 3, _, _, _, _, _}},
                        {submit, _, {quod_dtx_prepare, 3, _, _, _, _, _}}],
                       Commands),
          ?assertNot(
             lists:any(
               fun({submit, _, {quod_dtx_begin, 3, _, _, _}}) -> true;
                  (_) -> false
               end, Commands))
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
          [Target | _] = maps:get(targets, F),
          BeginEvidence = evidence(Origin, Begin, 1, F),
          {ok, [{submit, Target, Prepare} | _]} =
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
                                   #{request_timeout_ms => 1,
                                     retry_initial_ms => 1,
                                     retry_max_ms => 2}),
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

invalid_begin_allocates_no_worker_test() ->
    ?assertEqual(
       {error, invalid_begin},
       quod_dtx_coordinator:start_monitor(
         self(), <<"quod:a">>, malformed, none, #{})).

one_participant_begin_allocates_the_ordinary_coordinator_test() ->
    with_fixture(
      fun(F) ->
          {ok, Pid, Monitor} = quod_dtx_coordinator:start_monitor(
                                 self(), element(1, maps:get(origin, F)),
                                 maps:get(single_begin, F), none,
                                 #{retry_initial_ms => 1,
                                   retry_max_ms => 2}),
          exit(Pid, kill),
          receive
              {'DOWN', Monitor, process, Pid, killed} -> ok
          after 1000 -> error(single_participant_coordinator_leaked)
          end,
          {quod_dtx_begin, Version, Manifest, RequestAuth, _Bundles} =
              maps:get(single_begin, F),
          EmptyBegin =
              {quod_dtx_begin, Version, setelement(12, Manifest, []),
               RequestAuth, []},
          ?assertEqual(
             {error, invalid_begin},
             quod_dtx_coordinator:start_monitor(
               self(), element(1, maps:get(origin, F)), EmptyBegin,
               none, #{}))
      end).

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
    {ok, SingleManifest} =
        quod_dtx:new_manifest(
          #{proof_id => ProofId,
            coordinator =>
                {element(1, Origin), element(2, Origin), Pub, Admission},
            nonce => digest(16), principal => anonymous,
            goal => GoalBlob, result => ResultBlob,
            request_binding => none,
            participants => [{Other, quod_dtx:digest(PlanB)}]}),
    {ok, SingleAttestation} =
        quod_dtx:attest_plan(Other, PlanB, SingleManifest, Signer),
    {ok, SingleBegin} =
        quod_dtx:new_begin(
          SingleManifest, none,
          [{Other, quod_dtx:digest(PlanB), PlanBBlob,
            SingleAttestation}]),
    #{signer => Signer, admission => Admission,
      origin => Origin, targets => Targets, 'begin' => Begin,
      single_begin => SingleBegin}.

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
         #{signer := Signer, admission := Admission}) ->
    {ok, Control} = quod_dtx:sign_control(
                      Target, Record, Admission, Slot, Slot, Signer),
    {Ns, Anchor} = Target,
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, digest(100 + Slot),
                  quod_dtx:record_digest(Control), <<"qc">>),
    {Target, Control, Ref}.

digest(N) -> <<N:256>>.
