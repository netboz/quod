-module(quod_dtx_coordinator_trace_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include("quod_ledger.hrl").

%% The owner and worker seams below are production functions, with a real SDK
%% and real monitored coordinator. The TEST-only initial-state hook supplies
%% a pre-verified planner snapshot. This is not a full consensus admission or
%% quorum-verification test: the reducer and planner still validate their own
%% actual control-chain inputs, and existing group tests pin the wire carrier.
-export([with_case/1, owner_row/2, start/3, adopt/2, projection_state/3,
         with_attempt_trace/1, attempts/1, end_calls/1, assert_no_root/0, root/0,
         stop/2, wait_down/2]).

complete_projection_retires_held_child_once_test() ->
    with_case(fun(F, S0, Parent) ->
        G = maps:get(group_id, F),
        with_env(dtx_test_observation_state,
                 {G, maps:get(complete_snapshot, F), #{}}, fun() ->
          with_env(dtx_test_phase_barrier, {hold, done}, fun() ->
            with_attempt_trace(fun(Trace) ->
                Running = start(F, Parent, S0),
                #{pid := Pid, monitor := MRef} = owner_row(F, Running),
                Complete = maps:get(complete_ref, F),
                receive {dtx_coordinator, Pid, G, {done, Complete}} -> ok
                after 2000 -> error(no_real_done) end,
                _Barrier = held(G, done),
                ?assert(is_process_alive(Pid)),
                assert_no_root(),
                Adopted = adopt(F, Running),
                Before = projection_state(F, pre_complete, Adopted),
                ?assertMatch(#{G := _}, quod_atomic:recovery_rows(
                  maps:get(pre_complete_projection, F), quod_time:now_ms())),
                ?assertEqual(owner_row(F, Before), owner_row(F,
                  quod_simplex:test_reconcile_dtx_coordinator(Before))),
                %% The real Complete reducer removed this desired row. No
                %% timer or hand-written empty desired map causes retirement.
                Completed = projection_state(F, complete, Before),
                ?assertEqual(#{}, quod_atomic:recovery_rows(
                  maps:get(complete_projection, F), quod_time:now_ms())),
                {keep_state, Released, _} = quod_simplex:running(
                  info, {dtx_coordinator, Pid, G, {done, Complete}}, Completed),
                ?assertEqual(#{}, quod_simplex:test_dtx_coordinator_state(Released)),
                Span = root(),
                ?assertEqual(<<"retirement_requested">>, closure(Span)),
                ?assertEqual(lists:sort([<<"dtx.done_observed">>, <<"dtx.completed">>,
                                        <<"dtx.coordinator.close_observed">>]),
                             lists:sort(event_names(Span))),
                assert_child_events_precede_notification(Trace, Pid, done, Span#span.span_id),
                ?assertEqual(otel_span:span_id(otel_tracer:current_span_ctx(Parent)),
                             Span#span.parent_span_id),
                ?assertEqual(1, length(attempts(Trace))),
                %% Existing retirement demonitor-flushes the exact monitor.
                ?assertNot(lists:member({process, Pid}, element(2, process_info(self(), monitors)))),
                wait_dead(Pid),
                ?assertEqual(false, quod_simplex:test_drop_dtx_coordinator(
                  MRef, Pid, shutdown, Released)),
                {keep_state, Released} = quod_simplex:running(
                  info, {dtx_coordinator, Pid, G, {done, Complete}}, Released),
                ?assertEqual([Span#span.span_id], end_calls(Trace)),
                assert_no_root()
            end)
          end)
        end)
    end).

done_precedes_follow_cleanup_and_natural_down_test() ->
    with_case(fun(F, S0, Parent) ->
        G = maps:get(group_id, F), Follow = make_ref(),
        with_foreign_sink(fun(Sink) ->
          with_env(dtx_test_observation_state,
                   {G, maps:get(complete_snapshot, F), #{maps:get(origin, F) => Follow}}, fun() ->
           with_env(dtx_test_phase_barrier, {hold, done}, fun() ->
            with_attempt_trace(fun(Trace) ->
                Running = start(F, Parent, S0),
                #{pid := Pid, monitor := MRef} = owner_row(F, Running),
                Complete = maps:get(complete_ref, F),
                receive {dtx_coordinator, Pid, G, {done, Complete}} -> ok
                after 2000 -> error(no_real_done) end,
                Barrier = held(G, done),
                ?assert(is_process_alive(Pid)),
                assert_no_root(),
                %% The same B ownership assertion, now held at the existing
                %% notification barrier rather than a deleted blocking cleanup.
                Before = projection_state(F, pre_complete, adopt(F, Running)),
                {keep_state, Kept, _} = quod_simplex:running(info,
                  {dtx_coordinator, Pid, G, {done, Complete}}, Before),
                ?assertEqual(owner_row(F, Before), owner_row(F, Kept)),
                assert_no_root(),
                ?assertEqual([], end_calls(Trace)),
                Pid ! {quod_dtx_test_release, Barrier},
                From = receive {unfollow, Sink, Pid, Follow, CallFrom} -> CallFrom
                       after 2000 -> error(no_actual_unfollow) end,
                %% The real cleanup request is unanswered. It cannot block
                %% coordinator termination; consumer death also owns cleanup.
                ?assertEqual(normal, wait_down(Pid, MRef)),
                gen_server:reply(From, ok),
                Finished = projection_state(F, complete, Kept),
                {true, Released} = quod_simplex:test_drop_dtx_coordinator(
                  MRef, Pid, normal, Finished),
                ?assertEqual(#{}, quod_simplex:test_dtx_coordinator_state(Released)),
                Span = root(),
                ?assertEqual(<<"worker_exit">>, closure(Span)),
                ?assertEqual(<<"normal">>, attr('quod.dtx.exit_class', Span)),
                Names = event_names(Span),
                ?assert(lists:member(<<"dtx.completed">>, Names)),
                ?assert(lists:member(<<"dtx.coordinator.close_observed">>, Names)),
                ?assert(lists:member(<<"dtx.done_observed">>, Names)),
                ?assertEqual(1, length(attempts(Trace))),
                ?assertEqual([Span#span.span_id], end_calls(Trace)),
                assert_no_root()
            end)
           end)
          end)
        end)
    end).

public_terminal_keeps_root_open_test() ->
    with_case(fun(F, S0, Parent) ->
        G = maps:get(group_id, F),
        {Ns, _} = maps:get(origin, F),
        true = quod_reg:reg({quod_prolog, Ns}),
        try with_env(dtx_test_observation_state,
                     {G, maps:get(terminal_snapshot, F), #{}}, fun() ->
          with_env(dtx_test_phase_barrier, {hold, terminal}, fun() ->
            Running = projection_state(F, pre_complete,
                        adopt(F, start(F, Parent, S0))),
            #{pid := Pid} = owner_row(F, Running),
            Terminal = receive {dtx_coordinator, Pid, G, {terminal, T}} -> T
                       after 2000 -> error(no_real_terminal) end,
            _ = held(G, terminal),
            ?assertEqual({keep_state, Running}, quod_simplex:running(
              info, {dtx_coordinator, Pid, G, {terminal, Terminal}}, Running)),
            GroupRef = maps:get(group_ref, F),
            receive {'$gen_cast', {dtx_group_terminal, GroupRef, Terminal}} -> ok
            after 1000 -> error(no_public_terminal_cast) end,
            assert_no_root(),
            ?assert(is_process_alive(Pid)),
            _ = stop(F, Running),
            Span = root(),
            ?assertEqual(<<"retirement_requested">>, closure(Span)),
            ?assertNot(lists:member(<<"dtx.completed">>, event_names(Span)))
          end)
        end)
        after gproc:unreg(quod_reg:name({quod_prolog, Ns})) end
    end).

abnormal_down_and_stale_messages_test_() ->
    [{atom_to_list(Class), fun() ->
      with_case(fun(F, S0, Parent) ->
        Running = projection_state(F, complete, adopt(F, start(F, Parent, S0))),
        #{pid := Pid, monitor := MRef} = owner_row(F, Running),
        G = maps:get(group_id, F),
        ?assertEqual(false, quod_simplex:test_drop_dtx_coordinator(make_ref(), Pid, Reason, Running)),
        ?assertEqual(false, quod_simplex:test_drop_dtx_coordinator(MRef, self(), Reason, Running)),
        ?assertEqual({keep_state, Running}, quod_simplex:running(
          info, {dtx_coordinator, self(), G, {error, <<"secret-stale">>}}, Running)),
        assert_no_root(),
        exit(Pid, Reason),
        ?assertEqual(Reason, wait_down(Pid, MRef)),
        {true, Released} = quod_simplex:test_drop_dtx_coordinator(MRef, Pid, Reason, Running),
        ?assertEqual(#{}, quod_simplex:test_dtx_coordinator_state(Released)),
        Span = root(),
        ?assertEqual(<<"worker_exit">>, closure(Span)),
        ?assertEqual(atom_to_binary(Class), attr('quod.dtx.exit_class', Span)),
        ?assertNot(lists:member(<<"dtx.completed">>, event_names(Span))),
        ?assertEqual(nomatch, binary:match(term_to_binary(Span), <<"PRIVATE-TEMPLATE">>)),
        ?assertEqual(false, quod_simplex:test_drop_dtx_coordinator(MRef, Pid, Reason, Released)),
        assert_no_root()
      end) end}
     || {Class, Reason} <- [{shutdown, shutdown}, {killed, killed},
                            {abnormal, {fixture_error, <<"PRIVATE-TEMPLATE">>}}]].

adoption_and_row_preserving_replacement_keep_original_parent_test() ->
    with_case(fun(F, S0, Parent) ->
      Other = phase_fixture(quod_ct:signed_atomic_fixture(#{
        target => maps:get(target, F), node_identity => maps:get(node_identity, F),
        key_pair => maps:get(key_pair, F), admission => maps:get(admission, F),
        proof_id => <<51:256>>, operation_id => <<52:256>>})),
      with_attempt_trace(fun(Trace) ->
        Running = start(F, Parent, S0),
        Old = owner_row(F, Running),
        Adopted = adopt(F, Running),
        AdoptedRow = owner_row(F, Adopted),
        ?assertEqual(maps:get(pid, Old), maps:get(pid, AdoptedRow)),
        ?assertEqual(maps:get(monitor, Old), maps:get(monitor, AdoptedRow)),
        ?assertEqual(maps:get(coordinate_span, Old), maps:get(coordinate_span, AdoptedRow)),
        ?assertEqual(Parent, maps:get(trace_ctx, AdoptedRow)),
        assert_no_root(),
        ?assertEqual(1, length(attempts(Trace))),
        G = maps:get(group_id, F),
        %% Same-group pending/committed own rows now always adopt. Inject a
        %% crossed-group desired index to exercise defensive replacement with
        %% real immutable material, not a retired phase representation. This
        %% deliberately inconsistent index is not a normal owner transition.
        Replaced = quod_simplex:test_reconcile_dtx_coordinators(
          #{G => maps:get(own_row, Other)}, Adopted),
        New = owner_row(Other, Replaced),
        ?assertNotEqual(maps:get(pid, Old), maps:get(pid, New)),
        ?assertEqual(Parent, maps:get(trace_ctx, New)),
        First = root(),
        ?assertEqual(<<"retirement_requested">>, closure(First)),
        ?assertEqual(false, quod_simplex:test_drop_dtx_coordinator(
          maps:get(monitor, Old), maps:get(pid, Old), shutdown, Replaced)),
        ?assertEqual({keep_state, Replaced}, quod_simplex:running(info,
          {dtx_coordinator, maps:get(pid, Old), G, {done, maps:get(complete_ref, F)}}, Replaced)),
        assert_no_root(),
        _ = stop(Other, Replaced),
        Second = root(),
        ExpectedParent = otel_span:span_id(otel_tracer:current_span_ctx(Parent)),
        ?assertEqual(ExpectedParent, First#span.parent_span_id),
        ?assertEqual(ExpectedParent, Second#span.parent_span_id),
        ?assertNotEqual(First#span.span_id, Second#span.parent_span_id),
        ?assertEqual(2, length(attempts(Trace))),
        ?assertEqual([First#span.span_id, Second#span.span_id], end_calls(Trace)),
        assert_no_root()
      end)
    end).

post_adoption_down_rebuild_is_honestly_parentless_test_() ->
    [{atom_to_list(Exit), fun() ->
      with_case(fun(F, S0, Parent) ->
        G = maps:get(group_id, F),
        Origin = maps:get(origin, F),
        Snapshot = case Exit of normal -> maps:get(complete_snapshot, F);
                                killed -> quod_dtx_recovery:empty() end,
        with_env(dtx_test_observation_state, {G, Snapshot, #{}}, fun() ->
          with_attempt_trace(fun(Trace) ->
                Running = start(F, Parent, S0),
                Adopted = adopt(F, Running),
                ?assertEqual(Parent, maps:get(trace_ctx, owner_row(F, Adopted))),
                %% The installed Vote projection already owns authenticated
                %% material. Restart is direct: no loader, ledger read or
                %% bootstrap result is needed to create the new attempt.
                Ready = projection_state(F, vote, Adopted),
                #{pid := Pid, monitor := MRef} = owner_row(F, Ready),
                case Exit of killed -> exit(Pid, kill); normal -> ok end,
                ?assertEqual(Exit, wait_down(Pid, MRef)),
                {true, Rebuilt} = quod_simplex:test_drop_dtx_coordinator(MRef, Pid, Exit, Ready),
                First = root(),
                ?assertEqual(<<"worker_exit">>, closure(First)),
                #{pid := NewPid, trace_ctx := Empty,
                  coordinate_span := {_, NewSpan}} = owner_row(F, Rebuilt),
                ?assertNotEqual(Pid, NewPid),
                ?assertEqual(otel_ctx:new(), Empty),
                ?assertEqual(2, length(attempts(Trace))),
                ?assertNotEqual(First#span.trace_id, otel_span:trace_id(NewSpan)),
                %% The fixture supplies no readable ledger capability. A new
                %% owner row exists even while its child remains parked.
                ?assertMatch(#{execution_ready := false, wave := none},
                             quod_dtx_coordinator:test_state(NewPid)),
                _ = stop(F, Rebuilt),
                Second = quod_trace_tests:take_span(<<"quod.dtx.coordinate">>, otel_span:trace_id(NewSpan)),
                ?assertEqual(undefined, Second#span.parent_span_id),
                ?assertEqual(<<"no_retained_parent">>, attr('quod.dtx.ancestry', Second)),
                ?assertEqual(Origin, maps:get(target, F))
          end)
        end)
      end) end} || Exit <- [normal, killed]].

disabled_tracer_never_owns_or_ends_a_borrowed_recording_parent_test() ->
    with_case(fun(F, S0, Parent) ->
        Key = {opentelemetry, global, tracer, opentelemetry:get_application(quod_trace)},
        Tracer = persistent_term:get(Key),
        true = opentelemetry:verify_and_set_term({otel_tracer_noop, []}, Key, otel_tracer),
        try
            Running = start(F, Parent, S0),
            ?assertEqual(none, maps:get(coordinate_span, owner_row(F, Running))),
            _ = stop(F, Running),
            %% Calling end on the API's noop alias would prematurely export
            %% B.request itself. The caller still owns that SDK span here.
            TraceId = current_trace(),
            receive {quod_test_span, #span{trace_id = TraceId}} ->
                error(disabled_coordinator_ended_its_parent)
            after 0 -> ok end,
            ?assertEqual(Parent, quod_trace:context())
        after persistent_term:put(Key, Tracer) end
    end).

unsampled_attempt_under_unrelated_ambient_is_not_exported_test() ->
    with_case(fun(F, S0, Ambient) ->
        Unsampled = quod_trace:extract([{<<"traceparent">>,
          <<"00-123456789abcdef0123456789abcdef0-123456789abcdef0-00">>}]),
        with_attempt_trace(fun(Trace) ->
            Running = start(F, Unsampled, S0),
            #{coordinate_span := {_, Handle}} = owner_row(F, Running),
            ?assertNot(otel_span:is_recording(Handle)),
            ?assertEqual(otel_span:trace_id(otel_tracer:current_span_ctx(Unsampled)),
                         otel_span:trace_id(Handle)),
            _ = stop(F, Running),
            ?assertEqual([Handle], attempts(Trace)),
            ?assertEqual([otel_span:span_id(Handle)], end_calls(Trace)),
            ?assertEqual(Ambient, quod_trace:context()),
            TraceIds = [current_trace(), otel_span:trace_id(Handle)],
            assert_no_trace_exports(TraceIds)
        end)
    end).

failed_child_cleanup_never_means_semantic_complete_test_() ->
    [{atom_to_list(Edge), fun() ->
      with_case(fun(F, S0, Parent) ->
        G = maps:get(group_id, F),
        {Ns, _} = maps:get(origin, F),
        %% Corrupt one pre-verified Resolve fact: its commit claim conflicts
        %% with the certified negative source Vote. The real planner must
        %% return an error, not interpret obsolete snapshot fields.
        Snapshot = maps:get(terminal_snapshot, F),
        Evidence = maps:get(evidence, Snapshot),
        Remote = maps:get(remote, F),
        Resolve = maps:get({resolve, Remote}, Evidence),
        Invalid = Snapshot#{evidence := Evidence#{
          {resolve, Remote} := Resolve#{outcome := commit}}},
        with_env(dtx_test_observation_state, {G, Invalid, #{}}, fun() ->
          with_attempt_trace(fun(Trace) ->
            Running = start(F, Parent, S0),
            #{pid := Pid, monitor := M} = owner_row(F, Running),
            Reason = receive {dtx_coordinator, Pid, G, {error, R}} -> R
                     after 2000 -> error(no_real_child_error) end,
            ?assertEqual({invalid_recovery_state, conflicting_resolve_outcome}, Reason),
            ?assertEqual(normal, wait_down(Pid, M)),
            assert_no_root(),
            ExpectedClosure = case Edge of
                fatal_event ->
                    ?assertError({dtx_coordinator_failed, Ns, G, Reason},
                      quod_simplex:running(info, {dtx_coordinator, Pid, G, {error, Reason}}, Running)),
                    ?assertEqual([], end_calls(Trace)),
                    ok = quod_simplex:terminate(Reason, running, Running),
                    <<"owner_terminating">>;
                normal_down ->
                    %% Isolate the DOWN seam after observing the child's
                    %% error; this is not a claim that OTP reorders signals.
                    Finished = projection_state(F, complete, adopt(F, Running)),
                    {true, _} = quod_simplex:test_drop_dtx_coordinator(M, Pid, normal, Finished),
                    <<"worker_exit">>
            end,
            Span = root(),
            ?assertEqual(ExpectedClosure, closure(Span)),
            ?assert(lists:member(<<"dtx.coordinator.close_observed">>, event_names(Span))),
            assert_child_events_precede_notification(Trace, Pid, error, Span#span.span_id),
            ?assertEqual(Edge =:= fatal_event,
              lists:member(<<"dtx.worker_error">>, event_names(Span))),
            ?assertNot(lists:member(<<"dtx.completed">>, event_names(Span))),
            ?assertEqual([Span#span.span_id], end_calls(Trace)),
            assert_no_root()
          end)
        end)
      end) end} || Edge <- [fatal_event, normal_down]].

recording_exact_worker_error_preserves_exception_without_exporting_secret_test() ->
    with_case(fun(F, S0, Parent) ->
      G = maps:get(group_id, F),
      with_env(dtx_test_observation_state,
               {G, maps:get(terminal_snapshot, F), #{}}, fun() ->
       with_env(dtx_test_phase_barrier, {hold, terminal}, fun() ->
      with_attempt_trace(fun(Trace) ->
        Running = start(F, Parent, S0),
        #{pid := Pid} = owner_row(F, Running),
        %% Inject the callback error only after the real child reaches its
        %% existing barrier. An actively driving child may legitimately emit
        %% stage events, and must not race this synthetic owner notification.
        _ = held(G, terminal),
        {Ns, _} = maps:get(origin, F),
        Secret = <<"B-recording-private-template-must-not-export">>,
        Expected = {dtx_coordinator_failed, Ns, G, {fixture, Secret}},
        ?assertError(Expected, quod_simplex:running(info,
          {dtx_coordinator, Pid, G, {error, {fixture, Secret}}}, Running)),
        assert_no_root(),
        ?assertEqual([], end_calls(Trace)),
        ok = quod_simplex:terminate(Expected, running, Running),
        wait_dead(Pid),
        Span = root(),
        ?assertEqual(<<"owner_terminating">>, closure(Span)),
        ?assertEqual(1, length([N || N <- event_names(Span), N =:= <<"dtx.worker_error">>])),
        ?assertNot(lists:member(<<"dtx.completed">>, event_names(Span))),
        ?assertEqual(nomatch, binary:match(term_to_binary(Span), Secret)),
        ?assertEqual([Span#span.span_id], end_calls(Trace))
      end)
       end)
      end)
    end).

assert_no_trace_exports(TraceIds) ->
    receive {quod_test_span, #span{trace_id = TraceId}} ->
        ?assertNot(lists:member(TraceId, TraceIds)),
        assert_no_trace_exports(TraceIds)
    after 0 -> ok end.

%% Helpers shared by the narrow SDK-unwind matrix. Every fixture namespace,
%% journal and live worker is test-owned. No hardware ledger is opened.
with_case(Fun) ->
    isolated(fun() -> with_case_local(Fun) end).

%% EUnit can reuse a process across modules. A private mailbox prevents real
%% production casts and exporter messages from leaking into another case.
isolated(Fun) ->
    Parent = self(),
    {Pid, M} = spawn_monitor(fun() ->
        _ = quod_process:kill_when_owner_dies(Parent, self()),
        Result = try {ok, Fun()} catch C:R:S -> {raised, C, R, S} end,
        Parent ! {isolated_result, self(), Result}
    end),
    receive
        {isolated_result, Pid, Result} ->
            normal = wait_down(Pid, M),
            case Result of {ok, Value} -> Value;
                           {raised, C, R, S} -> erlang:raise(C, R, S) end;
        {'DOWN', M, process, Pid, Reason} -> error({isolated_fixture_exit, Reason})
    end.

with_case_local(Fun) ->
    quod_trace_tests:with_tracer(fun() ->
      quod_dtx_group_trace_tests:with_fixture(fun(Base, S0, _Storage) ->
        F = phase_fixture(Base),
        {Parent, ParentSpan} = quod_trace:start_span(
          otel_ctx:new(), <<"B.request">>, internal, #{}),
        try quod_trace:with_context(Parent, fun() -> Fun(F, S0, Parent) end)
        after quod_trace:finish_span(ParentSpan, ok) end
      end)
    end).

phase_fixture(F) ->
    Origin = maps:get(target, F),
    Group = maps:get(group, F),
    G = quod_atomic:group_id(Group),
    Bundles = maps:get(bundles, F),
    [Remote] = [T || {T, _, _, _} <- Bundles, T =/= Origin],
    Reasons = [conflict],
    {ok, Vote} = quod_atomic:new_vote(Group, Origin,
      lists:keyfind(Origin, 1, Bundles), {refused, Reasons}),
    VoteControl = sign(Origin, Vote, 1, F),
    Material = quod_atomic:control_material(VoteControl),
    Own = #{material => Material, ref => none, resolution => none},
    {ok, GroupRef} = quod_atomic:source_group_ref(Material),
    {VoteEntry, VotePayload, VoteRef} = entry(Origin, VoteControl, 2, F),
    {ok, RemoteVote} = quod_atomic:new_vote(Group, Remote,
      lists:keyfind(Remote, 1, Bundles), prepared),
    RemoteControl = sign(Remote, RemoteVote, 1, F),
    {_, _, RemoteRef} = entry(Remote, RemoteControl, 2, F),
    Plans = maps:get(plans, F),
    SourceGeneration = quod_dtx:overlay_generation(maps:get(Origin, Plans)),
    TargetGeneration = quod_dtx:overlay_generation(maps:get(Remote, Plans)),
    Proof = {refused, VoteRef},
    {ok, Resolve} = quod_atomic:new_resolve(Group, VoteRef, Origin,
      {abort, Reasons}, Proof, VoteRef, SourceGeneration),
    ResolveControl = sign(Origin, Resolve, 2, F),
    {_, _, ResolveRef} = entry(Origin, ResolveControl, 3, F),
    {ok, RemoteResolve} = quod_atomic:new_resolve(Group, VoteRef, Remote,
      {abort, Reasons}, Proof, RemoteRef, TargetGeneration),
    RemoteResolveControl = sign(Remote, RemoteResolve, 2, F),
    {_, _, RemoteResolveRef} = entry(Remote, RemoteResolveControl, 3, F),
    %% Real AM3 signature under a supplied one-member committee identity.
    %% The TEST hook treats history/application as pre-verified: this does
    %% not prove admitted membership, foreign verification or durable apply.
    Network = maps:get(network, F),
    Committee = crypto:hash(sha256, <<"B-test-committee">>),
    {ok, AppliedVote} = quod_applied_certificate:sign_applied_vote(
      Network, Remote, Committee, G, RemoteResolveRef, TargetGeneration,
      abort, maps:get(node_identity, F)),
    {ok, Certificate} = quod_applied_certificate:applied_certificate(
      {Network, Remote, Committee, G, RemoteResolveRef, TargetGeneration, abort},
      [AppliedVote]),
    {ok, Complete} = quod_atomic:new_complete(Group, abort,
      lists:sort([{Origin, ResolveRef, SourceGeneration},
                  {Remote, RemoteResolveRef, TargetGeneration}]), [{Remote, Certificate}]),
    CompleteControl = sign(Origin, Complete, 3, F),
    {_, _, CompleteRef} = entry(Origin, CompleteControl, 4, F),
    Evidence = [{Origin, VoteControl, VoteRef}, {Remote, RemoteControl, RemoteRef},
                {Origin, ResolveControl, ResolveRef}, {Remote, RemoteResolveControl, RemoteResolveRef}],
    Observed = lists:foldl(fun(Row, Snapshot) ->
        {ok, Next} = quod_dtx_recovery:observe(Own, Row, Snapshot), Next
    end, quod_dtx_recovery:empty(), Evidence),
    {ok, TerminalSnapshot} = quod_dtx_recovery:applied(Own, Remote, Certificate, Observed),
    {ok, CompleteSnapshot} = quod_dtx_recovery:observe(
      Own, {Origin, CompleteControl, CompleteRef}, TerminalSnapshot),
    ?assertEqual({ok, {ordered, complete, [{submit, Origin, Complete}]}},
                 quod_dtx_recovery:next(Own, TerminalSnapshot)),
    ?assertMatch({ok, _}, quod_dtx_recovery:terminal(Own, TerminalSnapshot)),
    ?assertEqual({done, CompleteRef}, quod_dtx_recovery:next(Own, CompleteSnapshot)),
    {ok, H1, P1, _} = quod_atomic:reduce(VoteControl, VoteRef,
      quod_atomic:initial_group_history(), quod_atomic:initial_projection(Origin, 1)),
    {ok, H2, P2, _} = quod_atomic:reduce(ResolveControl, ResolveRef, H1, P1),
    {ok, _, P3, _} = quod_atomic:reduce(CompleteControl, CompleteRef, H2, P2),
    F#{origin => Origin, remote => Remote, group_id => G, group_ref => GroupRef,
       own_row => Own, vote => Vote, vote_control => VoteControl, vote_entry => VoteEntry,
       vote_payload => VotePayload, vote_ref => VoteRef, vote_projection => P1,
       pre_complete_projection => P2, complete_projection => P3,
       complete_ref => CompleteRef, terminal_snapshot => TerminalSnapshot,
       complete_snapshot => CompleteSnapshot}.

sign(Target, Record, Seq, F) ->
    {ok, Material} = quod_atomic:admission_material(Record),
    {ok, Control} = quod_atomic:sign_control(Target, Material, maps:get(admission, F),
                                            Seq, Seq, maps:get(node_identity, F)),
    Control.

entry({Ns, Anchor} = Target, Control, Slot, F) ->
    Payload = {batch, [{dtx, Control}]},
    Era = quod_ledger:initial_era(Target),
    {ok, Block} = quod_ledger:new_block({Era, Slot - 1}, {Era, 0, Anchor}, Slot, Payload, 0),
    Hash = quod_simplex:block_hash(Block),
    Signer = maps:get(node_identity, F),
    #share{sig = Sig} = quod_simplex:make_share(
      quod_simplex:consensus_domain(Ns, Anchor), commit, {Era, Slot - 1}, Hash, Signer),
    Entry = quod_ledger:entry(Slot, Block, #cert{kind = commit, era = Era, slot = Slot - 1,
      block_hash = Hash, sigs = [{maps:get(pubkey, Signer), Sig}]}),
    {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Control),
    {Entry, Payload, Ref}.

start(F, Parent, S0) ->
    %% These span tests supply pre-verified snapshots and exercise active
    %% coordination. Readiness-specific tests start parked explicitly.
    Ready = quod_simplex:test_state_set(prolog_ready, true, S0),
    Seed = quod_simplex:test_seed_dtx_submission(maps:get(vote_control, F), [], Ready),
    Running = quod_simplex:test_start_dtx_coordinator_worker(maps:get(own_row, F), Parent, Seed),
    #{pid := Pid} = owner_row(F, Running),
    %% Pre-verified snapshots need no ledger reader. Grant execution through
    %% the existing TEST capability seam, not a fabricated endpoint/store.
    ok = quod_simplex:test_activate_dtx_coordinator(Pid, Running),
    Running.

adopt(F, S) ->
    Installed = projection_state(F, vote,
      quod_simplex:test_resolve_committed_dtx(maps:get(vote_entry, F), maps:get(vote_payload, F), S)),
    quod_simplex:test_reconcile_dtx_coordinator(Installed).

projection_state(F, Stage, S) ->
    Key = case Stage of vote -> vote_projection;
                        pre_complete -> pre_complete_projection;
                        complete -> complete_projection end,
    quod_simplex:test_state_set(prolog_ready, true,
      quod_simplex:test_state_set(dtx_projection, maps:get(Key, F), S)).

owner_row(F, S) -> maps:get(maps:get(group_id, F), quod_simplex:test_dtx_coordinator_state(S)).
stop(F, S) ->
    #{pid := Pid} = owner_row(F, S),
    Released = quod_simplex:test_stop_dtx_coordinator(S),
    wait_dead(Pid),
    Released.
wait_dead(Pid) -> M = monitor(process, Pid), _ = wait_down(Pid, M), ok.
wait_down(Pid, M) ->
    receive {'DOWN', M, process, Pid, Reason} -> Reason
    after 3000 -> error({worker_did_not_exit, Pid}) end.
root() -> quod_trace_tests:take_span(<<"quod.dtx.coordinate">>, current_trace()).
assert_no_root() ->
    TraceId = current_trace(),
    receive {quod_test_span, #span{name = <<"quod.dtx.coordinate">>, trace_id = TraceId}} -> error(unexpected_coordinate_export)
    after 0 -> ok end.
current_trace() -> otel_span:trace_id(otel_tracer:current_span_ctx()).
closure(Span) -> attr('quod.dtx.closure', Span).
attr(Key, Span) -> maps:get(Key, otel_attributes:map(Span#span.attributes)).
event_names(Span) -> [E#event.name || E <- otel_events:list(Span#span.events)].

with_env(Key, Value, Fun) ->
    Before = application:get_env(quod, Key),
    application:set_env(quod, Key, Value),
    try Fun() after
        case Before of undefined -> application:unset_env(quod, Key);
                       {ok, Old} -> application:set_env(quod, Key, Old) end
    end.
held(G, Phase) -> held(G, Phase, 1000).
held(G, Phase, Left) when Left > 0 ->
    case application:get_env(quod, dtx_test_phase_barrier) of
        {ok, {held, G, Phase, Ref}} -> Ref;
        _ -> receive after 1 -> held(G, Phase, Left - 1) end
    end;
held(_, _, _) -> error(child_not_held).

with_foreign_sink(Fun) ->
    undefined = quod_reg:where({foreign_log, node}),
    Parent = self(),
    {Pid, M} = spawn_monitor(fun() ->
        true = quod_reg:reg({foreign_log, node}),
        Parent ! {sink_ready, self()}, foreign_sink(Parent)
    end),
    receive {sink_ready, Pid} -> ok after 1000 -> error(no_foreign_sink) end,
    try Fun(Pid) after exit(Pid, shutdown), _ = wait_down(Pid, M) end.
foreign_sink(Parent) ->
    receive
        {'$gen_call', From = {Pid, _}, {unfollow, Ref}} ->
            Parent ! {unfollow, self(), Pid, Ref, From}, foreign_sink(Parent);
        {'$gen_call', From, _Other} -> gen_server:reply(From, {error, unavailable}), foreign_sink(Parent)
    end.

with_attempt_trace(Fun) ->
    Tracer = spawn(fun() -> attempt_loop([], [], [], #{}) end),
    1 = erlang:trace_pattern({quod_trace, start_span, 4},
      [{['_', <<"quod.dtx.coordinate">>, '_', '_'], [], [{return_trace}]}], [local]),
    1 = erlang:trace_pattern({otel_span, end_span, 1}, true, [local]),
    1 = erlang:trace_pattern({quod_trace, add_event, 3}, [{'_', [], [{return_trace}]}], [local]),
    1 = erlang:trace(self(), true, [call, send, set_on_spawn, {tracer, Tracer}]),
    try Fun(Tracer) after
        erlang:trace(self(), false, [call, send, set_on_spawn]),
        erlang:trace_pattern({quod_trace, start_span, 4}, false, [local]),
        erlang:trace_pattern({otel_span, end_span, 1}, false, [local]),
        erlang:trace_pattern({quod_trace, add_event, 3}, false, [local]),
        Tracer ! stop
    end.
attempts(Tracer) ->
    maps:get(starts, attempt_calls(Tracer)).
end_calls(Tracer) ->
    Calls = attempt_calls(Tracer),
    Ids = [otel_span:span_id(Span) || Span <- maps:get(starts, Calls)],
    [Id || Id <- maps:get(ends, Calls), lists:member(Id, Ids)].

assert_child_events_precede_notification(Tracer, Pid, Kind, SpanId) ->
    Timeline = maps:get(timeline, attempt_calls(Tracer)),
    Indexed = lists:zip(lists:seq(1, length(Timeline)), Timeline),
    [Sent] = [I || {I, {notify, Worker, Event}} <- Indexed, Worker =:= Pid, Event =:= Kind],
    Writes = [{I, Name} || {I, {event_done, Writer, Id, Name}} <- Indexed,
                          Writer =:= Pid, Id =:= SpanId],
    ?assert(lists:keymember(<<"dtx.coordinator.close_observed">>, 2, Writes)),
    ?assert(lists:all(fun({I, _}) -> I < Sent end, Writes)),
    case Kind of done -> ?assert(lists:keymember(<<"dtx.completed">>, 2, Writes));
                 error -> ?assertNot(lists:keymember(<<"dtx.completed">>, 2, Writes)) end.
attempt_calls(Tracer) ->
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, _, Ref} -> ok after 1000 -> error(trace_barrier) end,
    Tracer ! {get, self()},
    receive {attempts, Tracer, Spans} -> Spans after 1000 -> error(no_attempt_count) end.
attempt_loop(Spans, Ends, Timeline, PendingEvents) ->
    receive
        {trace, _, return_from, {quod_trace, start_span, 4}, {_Ctx, Span}} ->
            attempt_loop([Span | Spans], Ends, Timeline, PendingEvents);
        {trace, _, call, {otel_span, end_span, [Span]}} ->
            attempt_loop(Spans, [otel_span:span_id(Span) | Ends], Timeline, PendingEvents);
        {trace, Pid, call, {quod_trace, add_event, [Ctx, Name, _]}} ->
            Id = otel_span:span_id(otel_tracer:current_span_ctx(Ctx)),
            attempt_loop(Spans, Ends, Timeline, PendingEvents#{Pid => {Id, Name}});
        {trace, Pid, return_from, {quod_trace, add_event, 3}, _} ->
            {{Id, Name}, Rest} = maps:take(Pid, PendingEvents),
            attempt_loop(Spans, Ends, [{event_done, Pid, Id, Name} | Timeline], Rest);
        {trace, Pid, send, {dtx_coordinator, Pid, _, {Kind, _}}, _}
          when Kind =:= done; Kind =:= error ->
            attempt_loop(Spans, Ends, [{notify, Pid, Kind} | Timeline], PendingEvents);
        {get, From} ->
            From ! {attempts, self(), #{starts => lists:reverse(Spans), ends => lists:reverse(Ends),
                                       timeline => lists:reverse(Timeline)}},
            attempt_loop(Spans, Ends, Timeline, PendingEvents);
        stop -> ok;
        _ -> attempt_loop(Spans, Ends, Timeline, PendingEvents)
    end.
