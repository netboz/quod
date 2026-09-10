-module(quod_dtx_coordinator_evidence_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Keep the foreign verifier, signed history and sparse-store reader real.
%% Only the consensus endpoint transport boundary is supplied by the fixture:
%% actual coordinator fanout races a held local endpoint against three peers,
%% and the winning response traverses the production wire codec.
remote_first_cohosted_evidence_test_() ->
    [{atom_to_list(Mode), {timeout, 15, fun() -> remote_first_cohosted(Mode) end}}
     || Mode <- [wave, accepted, observed]].

remote_first_cohosted(Mode) ->
    with_fixture(true, fun(F) ->
        #{target := Target, owner_ns := OwnerNs, record := Record,
          ref := Ref, hint := Hint, winner := Winner, local := Local,
          foreign := Foreign} = F,
        ?assertEqual(Local, quod_reg:where({quod_simplex, element(1, Target)})),
        ?assertEqual(element(2, Target), quod_simplex:genesis_hash(element(1, Target))),
        {ok, Routes} = quod_foreign_log:route_hints(Target, []),
        ?assertEqual(3, length(Routes)),
        {Result, Calls} = traced([Foreign, Local], fun() ->
            quod_dtx_coordinator:test_submit_phase_evidence(
              Mode, {submit, Target, Record}, OwnerNs, 2000)
        end),
        %% This assertion is the fail-before work oracle, not a resolver mock.
        ?assertEqual([], calls(quod_foreign_log, spawn_verification_worker, Calls)),
        ?assertEqual([], calls(quod_catchup, verify_forward, Calls)),
        ?assertEqual([], full_opens(Calls)),
        ?assertEqual(1, length(calls(quod_ledger_store, open_ro_snapshot, Calls))),
        ?assertEqual(1, length(calls(quod_ledger_store, read_at, Calls))),
        assert_resolver_admission(F, Hint, Calls),
        ?assertMatch({{reply_source, remote, Winner, [{Ref, Hint}]}, {ok, _}}, Result),
        {_, {ok, Snapshot}} = Result,
        ?assertEqual([{Target, maps:get(control, F), Ref}], maps:get(evidence, Snapshot)),
        receive {local_submit_held, Local} -> ok
        after 1000 -> error(local_endpoint_was_not_in_fanout)
        end,
        receive {remote_submit_replied, Winner} -> ok
        after 1000 -> error(remote_endpoint_did_not_win)
        end
    end).

no_owner_one_routed_job_test_() ->
    [{atom_to_list(Mode), {timeout, 15, fun() ->
        with_fixture(false, fun(F) ->
            {Result, Calls} = traced([maps:get(foreign, F)], fun() ->
                resolve_reply(Mode, F, remote_source(F), 2000)
            end),
            assert_resolver_admission(F, maps:get(hint, F), Calls),
            ?assertMatch({ok, _}, Result),
            ?assertEqual(1, length(calls(quod_foreign_log, spawn_verification_worker, Calls))),
            %% Positive controls: this same trace really sees historical replay
            %% and a full store open on the cold routed path.
            ?assert(length(calls(quod_catchup, verify_forward, Calls)) > 0),
            ?assert(length(full_opens(Calls)) > 0),
            ?assertEqual(1, length(calls(quod_foreign_log, verify_reference_deadline, Calls)))
        end)
    end}} || Mode <- [wave, accepted, observed]].

reply_hints_and_contact_are_route_neutral_test_() ->
    [{lists:flatten(io_lib:format("~p ~p", [Mode, Form])), {timeout, 15, fun() ->
        with_fixture(true, fun(F) ->
            Ref = maps:get(ref, F), Hint = maps:get(hint, F), Peer = maps:get(winner, F),
            Source = case Form of
                local -> local;
                remote -> {remote, Peer};
                local_reply -> {reply_source, local, [{Ref, Hint}]};
                remote_reply -> remote_source(F);
                malformed_hint -> {reply_source, remote, Peer, [{Ref, malformed}]}
            end,
            ExpectedHint = case Form of
                local_reply -> Hint;
                remote_reply -> Hint;
                _ -> none
            end,
            {Result, Calls} = traced([maps:get(foreign, F), maps:get(local, F)], fun() ->
                resolve_reply(Mode, F, Source, 2000)
            end),
            %% Pin the real fourth argument: a contact-promotion mutant must
            %% fail even if the locally hosted entry would still verify.
            assert_resolver_admission(F, ExpectedHint, Calls),
            ?assertMatch({ok, _}, Result),
            ?assertEqual([], calls(quod_foreign_log, spawn_verification_worker, Calls))
        end)
    end}} || Mode <- [wave, accepted, observed],
             Form <- [local, remote, local_reply, remote_reply, malformed_hint]].

authenticated_contact_positive_control_test() ->
    with_fixture(false, fun(F) ->
        #{target := Target, ref := Ref, hint := Hint, winner := Peer,
          endpoint := Endpoint, foreign := Foreign} = F,
        Contact = {Peer, Endpoint}, Deadline = quod_time:mono_ms() + 2000,
        {Result, Calls} = traced([Foreign], fun() ->
            quod_foreign_log:resolve_reference(Target, Ref, finalize, Contact, Hint, Deadline)
        end),
        ?assertMatch({ok, _}, Result),
        ?assertEqual([[Target, Ref, finalize, Contact, Hint, Deadline]],
                     calls(quod_foreign_log, resolve_reference, Calls)),
        ?assertEqual([[Ref, finalize, Contact, Hint, Deadline]],
                     calls(quod_foreign_log, verify_reference_deadline, Calls))
    end).

resolver_errors_keep_coordinator_retry_policy_test_() ->
    [{atom_to_list(Mode), {timeout, 15, fun() ->
        with_fixture(true, fun(F) ->
            Target = maps:get(target, F),
            Wrong = F#{target := {element(1, Target), <<0:256>>}},
            {Result, Calls} = traced([maps:get(foreign, F), maps:get(local, F)], fun() ->
                resolve_reply(Mode, Wrong, remote_source(F), 2000)
            end),
            ?assertEqual(retry, Result),
            ?assertEqual([], calls(quod_simplex, history_view, Calls)),
            ?assertEqual([], calls(quod_foreign_log, spawn_verification_worker, Calls))
        end)
    end}} || Mode <- [wave, accepted, observed]].

queued_success_cannot_install_after_attempt_expiry_test() ->
    with_fixture(true, fun(F) ->
        Parent = self(),
        {Result, Calls} = traced([maps:get(foreign, F), maps:get(local, F)],
          fun() -> resolve_reply({queued_wave, Parent}, F, remote_source(F), 300) end,
          fun(Runner) ->
              receive {evidence_queued, Runner, Deadline, Evidence} ->
                  ?assertMatch({ok, _}, Evidence),
                  ?assert(quod_time:mono_ms() < Deadline),
                  wait_past(Deadline),
                  Runner ! consume_evidence
              after 1000 -> error(no_success_to_hold)
              end
          end),
        ?assertEqual(retry, Result),
        ?assertEqual(1, length(calls(quod_ledger_store, read_at, Calls))),
        ?assertEqual([], calls(quod_foreign_log, spawn_verification_worker, Calls))
    end).

owner_mailbox_spends_original_attempt_budget_test_() ->
    [{atom_to_list(Mode), {timeout, 15, fun() ->
        with_fixture(true, fun(F) ->
            Local = maps:get(local, F), Parent = self(),
            Local ! {hold_capture, Parent},
            receive {capture_gate_ready, Local} -> ok after 1000 -> error(no_capture_gate) end,
            {Result, Calls} = traced([maps:get(foreign, F), Local],
              fun() -> resolve_reply(Mode, F, remote_source(F), 100) end,
              fun(_Runner) ->
                  receive {capture_held, Local, Deadline} ->
                      wait_past(Deadline),
                      Local ! release_capture
                  after 1000 -> error(capture_not_admitted)
                  end
              end),
            ?assertEqual(retry, Result),
            assert_resolver_admission(F, maps:get(hint, F), Calls),
            ?assertEqual([], calls(quod_foreign_log, spawn_verification_worker, Calls)),
            ?assertEqual([], calls(quod_ledger_store, open_ro_snapshot, Calls)),
            ?assertEqual([], full_opens(Calls))
        end)
    end}} || Mode <- [wave, accepted, observed]].

outer_phase_walk_stops_after_committed_reference_test_() ->
    [{atom_to_list(Mode), {timeout, 15, fun() ->
        with_fixture(true, fun(F) ->
            #{local := Local, router := Router, foreign := Foreign,
              target := Target, ref := Ref, hint := Hint} = F,
            {ok, [{FailedPeer, _}, {ReferencePeer, _}, {UnusedPeer, _}]} =
                quod_foreign_log:route_hints(Target, []),
            %% Ordinary delivery failures still traverse the actual source
            %% walk: local not_ready, then a remote transport loss. Both
            %% remaining remote endpoints serve the same real signed Ref.
            Router ! {fail_phase_peer, FailedPeer, self()},
            receive {phase_failure_ready, Router} -> ok
            after 1000 -> error(no_phase_failure_gate)
            end,
            Local ! {hold_capture, self()},
            receive {capture_gate_ready, Local} -> ok
            after 1000 -> error(no_outer_capture_gate)
            end,
            {Result, Calls} = traced([Foreign, Local],
              fun() ->
                  quod_dtx_coordinator:test_observe_phase_evidence(
                    Mode, maps:get(owner_ns, F), Target, maps:get(group_id, F),
                    finalize, 100)
              end,
              fun(_Runner) ->
                  receive {capture_held, Local, Deadline} ->
                      receive {local_phase_unavailable, Local} -> ok
                      after 1000 -> error(local_delivery_was_not_traversed)
                      end,
                      receive {remote_phase_failed, FailedPeer} -> ok
                      after 1000 -> error(remote_transport_failure_was_not_traversed)
                      end,
                      receive {remote_phase_replied, ReferencePeer, Ref} -> ok
                      after 1000 -> error(first_committed_reply_not_received)
                      end,
                      wait_past(Deadline),
                      %% Now let this same owner answer fresh captures. The
                      %% old outer loop takes a new allowance at the next peer
                      %% and succeeds, making the regression non-vacuous.
                      Local ! release_capture
                  after 1000 -> error(outer_walk_never_reached_evidence)
                  end
              end),
            Admissions = calls(quod_foreign_log, resolve_reference, Calls),
            %% EUnit exports this bounded probe on failure. The preserved
            %% old-source run must show renewed deadlines and a second real
            %% capture, not merely an unrelated test setup failure.
            io:format("outer_phase_probe ~p: ~p~n", [Mode,
              #{resolver_attempts => length(Admissions),
                deadlines => [D || [_, _, _, _, _, D] <- Admissions],
                captures => length([ok || [T, committed, _] <-
                                  calls(quod_simplex, history_view, Calls), T =:= Target]),
                foreign_jobs => length(calls(quod_foreign_log, spawn_verification_worker, Calls)),
                outcome => case Result of {ok, _} -> verified; Other -> Other end}]),
            ?assertEqual(1, length(Admissions)),
            assert_resolver_admission(F, Hint, Calls),
            ?assertEqual(retry, Result),
            ?assertEqual([], calls(quod_foreign_log, spawn_verification_worker, Calls)),
            ?assertEqual([], calls(quod_ledger_store, open_ro_snapshot, Calls)),
            ?assertEqual([], calls(quod_catchup, verify_forward, Calls)),
            ?assertEqual([], full_opens(Calls)),
            receive {remote_phase_replied, UnusedPeer, Ref} ->
                error(retried_same_reference_without_progress)
            after 0 -> ok
            end
        end)
    end}} || Mode <- [uncertain, ordinary]].

outer_phase_walk_proof_and_delivery_control_test_() ->
    [{lists:flatten(io_lib:format("~p ~p", [Mode, Proof])), {timeout, 15, fun() ->
        with_fixture(true, fun(F0) ->
            #{target := Target, local := Local, foreign := Foreign,
              router := Router, ref := GoodRef, hint := Hint} = F0,
            {ok, [{FirstPeer, _}, {SecondPeer, _}, {_ThirdPeer, _}]} =
                quod_foreign_log:route_hints(Target, []),
            {Ref, ReferencePeer} = case Proof of
                invalid_signature ->
                    Cert = binary_to_term(element(8, GoodRef), [safe]),
                    [{Pub, _Sig}] = Cert#cert.sigs,
                    BadRef = setelement(8, GoodRef,
                      term_to_binary(Cert#cert{sigs = [{Pub, <<0:512>>}]})),
                    ?assert(quod_dtx:same_certified_ref(GoodRef, BadRef)),
                    %% Every delivery peer serves the same shaped reference;
                    %% only its supplied finality signature is invalid.
                    Router ! {phase_reference, BadRef, self()},
                    receive {phase_reference_ready, Router} -> ok
                    after 1000 -> error(no_bad_proof_configuration)
                    end,
                    {BadRef, FirstPeer};
                valid ->
                    Router ! {fail_phase_peer, FirstPeer, self()},
                    receive {phase_failure_ready, Router} -> ok
                    after 1000 -> error(no_transport_failure_configuration)
                    end,
                    {GoodRef, SecondPeer}
            end,
            F = F0#{ref := Ref},
            {Result, Calls} = traced([Foreign, Local], fun() ->
                quod_dtx_coordinator:test_observe_phase_evidence(
                  Mode, maps:get(owner_ns, F), Target, maps:get(group_id, F),
                  finalize, 2000)
            end),
            Admissions = calls(quod_foreign_log, resolve_reference, Calls),
            io:format("outer_proof_probe ~p/~p: ~p~n", [Mode, Proof,
              #{resolver_attempts => length(Admissions),
                captures => length([ok || [T, committed, _] <-
                                  calls(quod_simplex, history_view, Calls), T =:= Target]),
                outcome => case Result of {ok, _} -> verified; Other -> Other end}]),
            ?assertEqual(1, length(Admissions)),
            assert_resolver_admission(F, Hint, Calls),
            ?assertEqual(1, length(calls(quod_ledger_store, open_ro_snapshot, Calls))),
            ?assertEqual(1, length(calls(quod_ledger_store, read_at, Calls))),
            ?assertEqual([], calls(quod_foreign_log, spawn_verification_worker, Calls)),
            ?assertEqual([], calls(quod_foreign_log, verify_reference_deadline, Calls)),
            ?assertEqual([], full_opens(Calls)),
            receive {local_phase_unavailable, Local} -> ok
            after 1000 -> error(local_delivery_failure_did_not_fall_through)
            end,
            case Proof of
                invalid_signature -> ?assertEqual(retry, Result);
                valid ->
                    ?assertMatch({ok, _}, Result),
                    receive {remote_phase_failed, FirstPeer} -> ok
                    after 1000 -> error(transport_failure_did_not_fall_through)
                    end
            end,
            receive {remote_phase_replied, ReferencePeer, Ref} -> ok
            after 1000 -> error(no_first_committed_reply)
            end,
            receive {remote_phase_replied, _, Ref} ->
                error(advanced_delivery_after_committed_reference)
            after 0 -> ok
            end
        end)
    end}} || Mode <- [uncertain, ordinary], Proof <- [invalid_signature, valid]].

%% Complement the held-owner/runtime checks with a placement guard: moving
%% the allowance calculation into run_wave_work/3 would otherwise hide time
%% spent waiting for the wave worker's first scheduled instruction.
attempt_deadline_is_captured_before_worker_admission_test() ->
    {ok, {quod_dtx_coordinator, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(quod_dtx_coordinator), [abstract_code]),
    [{function, _, start_typed_wave, 4, [{clause, _, _, _, Body}]}] =
        [F || F = {function, _, start_typed_wave, 4, _} <- Forms],
    ContextPositions = [I || {I, {match, _, {var, _, 'Context'}, Expr}} <- indexed(Body),
                            contains_atom(evidence_deadline, Expr)],
    WorkerPositions = [I || {I, {match, _, {var, _, 'Workers'}, _}} <- indexed(Body)],
    ?assertMatch([_], ContextPositions),
    ?assertMatch([_], WorkerPositions),
    ?assert(hd(ContextPositions) < hd(WorkerPositions)),
    [IO] = [F || F = {function, _, phase_evidence_io, 2, _} <- Forms],
    ?assert(contains_atom(evidence_deadline, IO)),
    ?assertNot(contains_atom(mono_ms, IO)),
    ?assertNot(contains_atom(endpoint_sources, IO)),
    ?assertEqual([], [Name || {function, _, Name, _, _} <- Forms,
                             lists:member(Name, [phase_evidence_sources,
                                                 verify_accepted_phase_sources,
                                                 endpoint_evidence_source])]).

indexed(List) -> lists:zip(lists:seq(1, length(List)), List).
contains_atom(Atom, {atom, _, Atom}) -> true;
contains_atom(Atom, Tuple) when is_tuple(Tuple) -> contains_atom(Atom, tuple_to_list(Tuple));
contains_atom(Atom, List) when is_list(List) -> lists:any(fun(X) -> contains_atom(Atom, X) end, List);
contains_atom(_, _) -> false.

wait_past(Deadline) -> receive after max(0, Deadline - quod_time:mono_ms()) + 1 -> ok end.

assert_resolver_admission(#{target := Target, ref := Ref}, Hint, Calls) ->
    Admissions = calls(quod_foreign_log, resolve_reference, Calls),
    ?assertMatch([[Target, Ref, finalize, none, Hint, _]], Admissions),
    [[_, _, _, _, _, Deadline]] = Admissions,
    ?assert(is_integer(Deadline)),
    ?assert(Deadline =< quod_time:mono_ms() + 2000),
    case calls(quod_simplex, history_view, Calls) of
        [[Target, committed, Deadline]] -> ok;
        %% The history API's public clause calls its exact-PID clause.
        [[Target, committed, Deadline], [{_, Target}, committed, Deadline]] -> ok;
        Other -> error({wrong_capture_budget, Other})
    end.

remote_source(#{ref := Ref, hint := Hint, winner := Peer}) ->
    {reply_source, remote, Peer, [{Ref, Hint}]}.

resolve_reply(Mode, F, Source, Timeout) ->
    quod_dtx_coordinator:test_phase_reply_evidence(
      Mode, maps:get(owner_ns, F), maps:get(target, F), maps:get(group_id, F),
      finalize, maps:get(ref, F), Source, Timeout).

with_fixture(Cohosted, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    F0 = quod_foreign_log_tests:foreign_fixture(quod_foreign_log_tests:unique_ns()),
    #{ns := Ns, anchor := Anchor, pub := Pub, chain := Chain, control := Control,
      ref := Ref} = F0,
    Target = {Ns, Anchor}, OwnerNs = <<"coordinator-source:", Ns/binary>>,
    Record = quod_dtx:control_body(Control), Hint = lists:last(Chain),
    Endpoint = {"127.0.0.1", 19000},
    Root = quod_foreign_log_tests:temp_dir("coordinator-evidence"),
    Foreign = quod_foreign_log_tests:start_owner(
                filename:join(Root, "foreign"), quod_foreign_log_tests:chain_fetch(Ns, Chain)),
    Local = case Cohosted of
        true -> start_local_owner(F0, filename:join(Root, "local"));
        false -> none
    end,
    OldNodeKey = application:get_env(quod, node_pubkey),
    ok = application:set_env(quod, node_pubkey, <<249:256>>),
    Parent = self(),
    Router = spawn(fun() ->
        true = quod_reg:reg({quod_simplex, OwnerNs}),
        Parent ! {router_ready, self()},
        router_loop(Parent, Ns, Pub, Ref, Record, Hint)
    end),
    receive {router_ready, Router} -> ok after 1000 -> error(router_not_ready) end,
    try
        Peers = [Pub, <<247:256>>, <<248:256>>],
        [ok = quod_foreign_log:observe_candidate(Target, {Peer, Endpoint}) || Peer <- Peers],
        {ok, Routes} = quod_foreign_log:route_hints(Target, []),
        ?assertEqual(3, length(Routes)),
        Fun(F0#{target => Target, owner_ns => OwnerNs, record => Record,
                group_id => quod_dtx:group_id(Record), hint => Hint,
                winner => Pub, endpoint => Endpoint, local => Local,
                router => Router, foreign => Foreign})
    after
        stop_process(Router), stop_process(Local),
        quod_foreign_log_tests:stop_owner(Foreign),
        case OldNodeKey of
            undefined -> application:unset_env(quod, node_pubkey);
            {ok, Key} -> application:set_env(quod, node_pubkey, Key)
        end,
        _ = file:del_dir_r(Root)
    end.

start_local_owner(F, Dir) ->
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Ns = maps:get(ns, F),
        {ok, Empty} = quod_ledger_store:open(Ns, Dir),
        {ok, Store} = quod_ledger_store:append(Empty, maps:get(chain, F)),
        try
            %% Reuse the signed history's existing owner-view constructor;
            %% it replays once during fixture setup, before tracing starts.
            View = quod_foreign_log_tests:local_fixture_view(Store, F),
            Table = ets:new(binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
                            [named_table, protected, set]),
            true = ets:insert(Table, {anchor, maps:get(anchor, F)}),
            Parent ! {local_owner_ready, self()},
            local_owner_loop(Parent, View)
        after quod_ledger_store:close(Store)
        end
    end),
    receive
        {local_owner_ready, Pid} -> erlang:demonitor(Monitor, [flush]), Pid;
        {'DOWN', Monitor, process, Pid, Reason} -> error({local_owner_failed, Reason})
    after 3000 -> error(local_owner_not_ready)
    end.

local_owner_loop(Parent, View) -> local_owner_loop(Parent, View, none).
local_owner_loop(Parent, #{identity := Identity} = View, Gate) ->
    receive
        {hold_capture, Test} ->
            Test ! {capture_gate_ready, self()}, local_owner_loop(Parent, View, Test);
        {'$gen_call', From, {history_view, Identity, committed, Deadline}} ->
            case Gate of
                none -> ok;
                Test -> Test ! {capture_held, self(), Deadline}, receive release_capture -> ok end
            end,
            Reply = case quod_time:mono_ms() < Deadline of
                true -> {ok, View}; false -> {error, timeout}
            end,
            gen:reply(From, Reply), local_owner_loop(Parent, View);
        {'$gen_call', From, {dtx_endpoint_local, {phase, RequestId, _, _}, _, _, _}} ->
            gen:reply(From, {ok, {error, RequestId, not_ready}, []}),
            Parent ! {local_phase_unavailable, self()},
            local_owner_loop(Parent, View, Gate);
        {'$gen_call', _From, {dtx_endpoint_local, _, _, _, _}} ->
            %% Hold only the endpoint request, not the history owner mailbox.
            Parent ! {local_submit_held, self()}, local_owner_loop(Parent, View, Gate);
        stop -> ok
    end.

router_loop(Parent, Ns, Winner, Ref, Record, Hint) ->
    router_loop(Parent, Ns, Winner, Ref, Record, Hint, none).
router_loop(Parent, Ns, Winner, Ref, Record, Hint, FailedPhasePeer) ->
    receive
        {phase_reference, NewRef, Test} ->
            Test ! {phase_reference_ready, self()},
            router_loop(Parent, Ns, Winner, NewRef, Record, Hint, FailedPhasePeer);
        {fail_phase_peer, Peer, Test} ->
            Test ! {phase_failure_ready, self()},
            router_loop(Parent, Ns, Winner, Ref, Record, Hint, Peer);
        {'$gen_call', From, {dtx_endpoint_request, Ns, Peer, _Endpoint,
                            {phase, RequestId, _, _}, _, _, _}} ->
            case Peer of
                FailedPhasePeer ->
                    gen:reply(From, {error, connection_lost}),
                    Parent ! {remote_phase_failed, Peer};
                _ ->
                    Response = {phase, RequestId, 0, {committed, Ref}},
                    {ok, Bytes} = quod_dtx_endpoint:encode_response(Ns, Response, [{Ref, Hint}]),
                    gen:reply(From, quod_dtx_endpoint:decode_response(Ns, Bytes)),
                    Parent ! {remote_phase_replied, Peer, Ref}
            end,
            router_loop(Parent, Ns, Winner, Ref, Record, Hint, FailedPhasePeer);
        {'$gen_call', From, {dtx_endpoint_request, Ns, Winner, _Endpoint,
                            {submit, RequestId, _}, _, _, _}} ->
            Response = {accepted, RequestId, quod_dtx:record_digest(Record), Ref},
            {ok, Bytes} = quod_dtx_endpoint:encode_response(Ns, Response, [{Ref, Hint}]),
            Reply = quod_dtx_endpoint:decode_response(Ns, Bytes),
            gen:reply(From, Reply), Parent ! {remote_submit_replied, Winner},
            router_loop(Parent, Ns, Winner, Ref, Record, Hint, FailedPhasePeer);
        {'$gen_call', _From, {dtx_endpoint_request, Ns, _Peer, _, _, _, _, _}} ->
            router_loop(Parent, Ns, Winner, Ref, Record, Hint, FailedPhasePeer);
        stop -> ok
    end.

stop_process(none) -> ok;
stop_process(Pid) ->
    MRef = monitor(process, Pid), Pid ! stop,
    receive {'DOWN', MRef, process, Pid, _} -> ok
    after 1000 -> exit(Pid, kill),
        receive {'DOWN', MRef, process, Pid, _} -> ok end
    end.

%% An independent tracer observes caller descendants and the real foreign
%% owner, including spawned jobs. Calls are drained with trace_delivered/1;
%% process death or mailbox ordering cannot turn missing work into zero work.
traced(Owners, Fun) -> traced(Owners, Fun, fun(_Runner) -> ok end).
traced(Owners, Fun, Drive) ->
    MFAs = [{quod_foreign_log, resolve_reference, 6},
            {quod_foreign_log, verify_reference_deadline, 5},
            {quod_foreign_log, spawn_verification_worker, 3},
            {quod_simplex, history_view, 3},
            {quod_catchup, verify_forward, 6},
            {quod_ledger_store, open, 2}, {quod_ledger_store, open, 3},
            {quod_ledger_store, open_ro, 2}, {quod_ledger_store, open_ro, 3},
            {quod_ledger_store, open_ro_snapshot, 1},
            {quod_ledger_store, read_at, 2}],
    [code:ensure_loaded(M) || {M, _, _} <- MFAs],
    Tracer = spawn(fun() -> trace_loop([]) end),
    Parent = self(),
    {Runner, Monitor} = spawn_monitor(fun() ->
        receive go -> ok end,
        Result = Fun(), Parent ! {traced_result, self(), Result},
        receive stop -> ok end
    end),
    [erlang:trace_pattern(MFA, true, [local]) || MFA <- MFAs],
    Pids = [Runner | Owners],
    [1 = erlang:trace(Pid, true, [call, set_on_spawn, {tracer, Tracer}]) || Pid <- Pids],
    try
        Runner ! go,
        Drive(Runner),
        Result = receive
            {traced_result, Runner, R} -> R;
            {'DOWN', Monitor, process, Runner, Why} -> error({evidence_runner_failed, Why})
        after 8000 -> error(evidence_runner_stalled)
        end,
        Delivered = erlang:trace_delivered(all),
        receive {trace_delivered, all, Delivered} -> ok after 2000 -> error(trace_stalled) end,
        Tracer ! {take, self()},
        receive {traced_calls, Tracer, Calls} -> {Result, Calls}
        after 2000 -> error(tracer_stalled)
        end
    after
        [catch erlang:trace(Pid, false, [all]) || Pid <- Pids],
        [erlang:trace_pattern(MFA, false, [local]) || MFA <- MFAs],
        stop_process(Runner), erlang:demonitor(Monitor, [flush]), stop_process(Tracer)
    end.

trace_loop(Calls) ->
    receive
        {trace, _Pid, call, Call} -> trace_loop([Call | Calls]);
        {take, Caller} -> Caller ! {traced_calls, self(), lists:reverse(Calls)}, trace_loop([]);
        stop -> ok
    end.

calls(Module, Function, Calls) -> [Args || {M, F, Args} <- Calls, M =:= Module, F =:= Function].
full_opens(Calls) -> calls(quod_ledger_store, open, Calls) ++ calls(quod_ledger_store, open_ro, Calls).
