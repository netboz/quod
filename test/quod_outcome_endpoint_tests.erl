-module(quod_outcome_endpoint_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Real endpoint workers and owner transitions, with only the Prolog snapshot
%% reply held by a message-controlled fixture. No ledger timing is assumed.
replay_ready_at_unchanged_height_releases_the_same_request_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        assert_subscribed(F, Worker),
        gen_server:reply(From, {error, {ontology_rebuilding, maps:get(ns, F)}}),
        await_result(F, {error, not_ready}),
        ?assertEqual(1, worker_count(F)),
        update_owner(F, #{prolog_ready => true}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_outcome(F, outcome, 3),
        assert_worker_gone(F, Worker)
    end).

snapshot_result_racing_newer_head_is_resampled_test() ->
    with_endpoint(true, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        update_owner(F, #{slot => 4, last_applied => 4}),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(4)),
        assert_outcome(F, outcome, 4),
        assert_worker_gone(F, Worker)
    end).

unchanged_stale_snapshot_parks_without_a_resampling_loop_test() ->
    with_endpoint(true, fun(F) ->
        update_owner(F, #{slot => 4, last_applied => 4}),
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        assert_no_snapshot(F),
        ?assertEqual(1, worker_count(F)),
        Ns = maps:get(ns, F),
        quod_reg:publish({runtime, Ns}, {projection_advanced, self(), 3}),
        assert_no_snapshot(F),
        quod_reg:publish({runtime, Ns}, {projection_advanced, self(), 4}),
        {Worker, From3} = snapshot_call(F),
        gen_server:reply(From3, snapshot(4)),
        assert_outcome(F, outcome, 4),
        assert_worker_gone(F, Worker)
    end).

runtime_edge_queued_before_owner_decision_is_not_lost_test() ->
    with_endpoint(true, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        assert_subscribed(F, Worker),
        Ns = maps:get(ns, F),
        %% The subscription precedes the query. This ready edge arrives while
        %% the helper still awaits its first reply, before parent parking.
        quod_reg:publish({runtime, Ns}, {replay_ready, make_ref(), 3}),
        gen_server:reply(From, {error, {ontology_rebuilding, Ns}}),
        await_result(F, {error, not_ready}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_outcome(F, outcome, 3),
        assert_worker_gone(F, Worker)
    end).

outcome_barrier_uses_the_same_readiness_wait_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome_barrier, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        ?assertEqual(1, worker_count(F)),
        update_owner(F, #{prolog_ready => true}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_outcome(F, outcome_barrier, 3),
        assert_worker_gone(F, Worker)
    end).

wrong_anchor_or_era_is_refused_without_a_worker_test() ->
    with_endpoint(false, fun(F) ->
        Request = request(F, outcome),
        {transaction, Ns, _Anchor, TxId} = element(3, Request),
        BadAnchor = setelement(3, Request, {transaction, Ns, <<99:256>>, TxId}),
        BadEra = setelement(4, Request, <<98:256>>),
        ?assertEqual({error, not_ready}, admit(F, BadAnchor, 3000)),
        ?assertEqual({error, not_ready}, admit(F, BadEra, 3000)),
        ?assertEqual(0, worker_count(F)),
        ?assertEqual([], subscribers(F)),
        assert_no_snapshot(F)
    end).

parked_request_refuses_a_changed_committee_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        update_owner(F, #{committee_id => <<98:256>>}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_refused(F),
        assert_worker_gone(F, Worker)
    end).

parked_deadline_removes_worker_and_subscription_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 100),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        assert_refused(F),
        assert_worker_gone(F, Worker)
    end).

owner_death_releases_parked_worker_and_subscription_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        Monitor = monitor(process, Worker),
        exit(maps:get(owner, F), kill),
        receive {'DOWN', Monitor, process, Worker, normal} -> ok
        after 1000 -> error(worker_retained_after_owner_death)
        end,
        ?assertEqual([], subscribers(F))
    end).

operation_applied_pins_history_and_waits_for_durable_publication_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 3000),
        {Worker, From} = snapshot_call(F),
        assert_subscribed(F, Worker),
        assert_one_history_capture(F),
        %% Included bytes exist at slot 2, but the outcome owner has only
        %% published slot 1. Even a terminal-looking row is not signable yet.
        Pending = operation_snapshot(F, 1, committed),
        gen_server:reply(From, Pending),
        await_operation_snapshot(F, Pending),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, Pending),
        await_operation_snapshot(F, Pending),
        assert_no_reply(F),
        assert_no_snapshot(F),
        Ns = maps:get(ns, F),
        quod_reg:publish({runtime, Ns}, {projection_advanced, self(), 1}),
        assert_no_snapshot(F),
        quod_reg:publish({runtime, Ns}, {projection_advanced, self(), 2}),
        {Worker, From3} = snapshot_call(F),
        gen_server:reply(From3, operation_snapshot(F, 2, committed)),
        assert_operation_vote(F, applied),
        assert_worker_gone(F, Worker),
        assert_no_history_capture(F)
    end).

operation_applied_signs_historical_not_current_committee_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 3000),
        {Worker, From} = snapshot_call(F),
        %% Membership has advanced, but this signer belonged to the exact
        %% application's historical committee. A current committee cannot
        %% reinterpret the statement or substitute its identity.
        update_owner(F, #{committee_id => <<91:256>>, validators => [<<92:256>>]}),
        gen_server:reply(From, operation_snapshot(F, 2, {rejected, conflict_retry})),
        assert_operation_vote(F, {rejected, conflict_retry}),
        assert_worker_gone(F, Worker),
        assert_one_history_capture(F),
        assert_no_history_capture(F)
    end).

operation_applied_current_member_cannot_replace_historical_signer_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 3000),
        {Worker, From} = snapshot_call(F),
        {Pub, Seed} = quod_identity:generate(),
        update_owner(F, #{self => Pub, validators => [Pub],
                          id => #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}),
        gen_server:reply(From, operation_snapshot(F, 2, committed)),
        assert_refused(F),
        assert_worker_gone(F, Worker)
    end).

operation_applied_wrong_occurrence_is_not_signed_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 3000),
        {Worker, From} = snapshot_call(F),
        {ok, Snapshot = #{outcome := Row}} = operation_snapshot(F, 2, committed),
        gen_server:reply(From, {ok, Snapshot#{outcome := Row#{height := 1}}}),
        assert_refused(F),
        assert_worker_gone(F, Worker)
    end).

operation_applied_deadline_does_not_restart_while_parked_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 150),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, operation_snapshot(F, 1, committed)),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, operation_snapshot(F, 1, committed)),
        assert_refused(F),
        assert_worker_gone(F, Worker),
        assert_one_history_capture(F),
        assert_no_history_capture(F)
    end).

operation_applied_owner_death_releases_the_pinned_capture_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 3000),
        {Worker, From} = snapshot_call(F),
        Pending = operation_snapshot(F, 1, committed),
        gen_server:reply(From, Pending),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, Pending),
        await_operation_snapshot(F, Pending),
        M = monitor(process, Worker),
        exit(maps:get(owner, F), kill),
        receive {'DOWN', M, process, Worker, normal} -> ok
        after 1000 -> error(operation_worker_survived_owner)
        end,
        ?assertEqual([], subscribers(F)),
        assert_no_reply(F)
    end).

operation_collector_uses_the_real_endpoint_and_exact_result_test() ->
    with_operation_endpoint(fun(F = #{ns := Ns, target := Target,
      certified_target_ref := Ref, evidence := E0, network := Network}) ->
        E = E0#{routes => #{}}, Parent = self(),
        {Collector, M} = spawn_monitor(fun() ->
            Parent ! {collected, self(), quod_dtx_current_view:certify_operation_evidence(
              Ns, Target, Ref, E, none, quod_time:mono_ms() + 3000)}
        end),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, operation_snapshot(F, 2, {rejected, conflict_retry})),
        receive {collected, Collector, {ok, Ref, E, Cert}} ->
            ?assert(quod_applied_certificate:verify_operation_certificate(Cert, Network, E)),
            ?assertMatch({ok, #{result := {rejected, conflict_retry}}},
                         quod_applied_certificate:operation_certificate_binding(Cert))
        after 1000 -> error(collector_did_not_certify)
        end,
        receive {'DOWN', M, process, Collector, normal} -> ok after 1000 -> error(collector_retained) end,
        assert_worker_gone(F, Worker),
        assert_one_history_capture(F), assert_no_history_capture(F)
    end).

operation_collector_expiry_keeps_inclusion_but_invents_no_verdict_test() ->
    with_operation_endpoint(fun(F = #{ns := Ns, target := Target,
      certified_target_ref := Ref, evidence := E0}) ->
        E = E0#{routes => #{}}, Parent = self(),
        {Collector, M} = spawn_monitor(fun() ->
            Parent ! {collected, self(), quod_dtx_current_view:certify_operation_evidence(
              Ns, Target, Ref, E, none, quod_time:mono_ms() + 200)}
        end),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, operation_snapshot(F, 1, committed)),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, operation_snapshot(F, 1, committed)),
        receive {collected, Collector, {error, retry}} -> ok
        after 1000 -> error(expired_collector_invented_verdict)
        end,
        receive {'DOWN', M, process, Collector, normal} -> ok after 1000 -> error(collector_retained) end,
        %% The worker's existing deadline/owner protocol performs cleanup.
        assert_worker_gone(F, Worker)
    end).

target_endpoint_refuses_a_signed_vector_without_its_own_independent_seal_test() ->
    with_operation_endpoint(2, fun(F = #{target := Target, origin := {SourceNs, SourceAnchor} = Origin,
      claim := Claim, node_identity := Signer, admission := Admission, tag := Tag}) ->
        #transaction{role = {remote_claim, Manifest, Bundles, _}} = Claim,
        {ok, Plan} = quod_transaction:remote_claim_plan(Claim, Target),
        {ok, Ordinary} = quod_dtx:attest_plan(1, Target, Plan, Manifest, Signer),
        Own = lists:keyfind(Target, 1, Bundles),
        Refused0 = quod_transaction:remote_claim(Origin, Manifest,
          lists:keyreplace(Target, 1, Bundles, setelement(4, Own, Ordinary)),
          Claim#transaction.request_auth, []),
        {ok, Refused} = quod_transaction:sign({SourceNs, SourceAnchor, Admission},
          Refused0#transaction{author = maps:get(pubkey, Signer), author_seq = 1, submitted_at = 1}, Signer),
        Entry = quod_operation_fixture:entry(Origin, Signer, 2, Refused),
        {ok, ClaimRef} = quod_dtx:certified_entry_ref(Origin, Entry, Refused),
        {ok, Blob} = quod_transaction:encode_evidence(ClaimRef, Refused),
        Id = maps:get(request_id, F),
        ?assertEqual(ok, admit(F, {apply_claim, Id, Target, Blob}, 3000)),
        receive {Tag, Reply} -> ?assertEqual({ok, {error, Id, independent_scope_required}, []}, Reply)
        after 1000 -> error(ordinary_target_seal_admitted)
        end,
        ?assertEqual(0, worker_count(F)),
        assert_no_snapshot(F), assert_no_history_capture(F),
        ?assertEqual(2, quod_ledger_store:last(maps:get(store, F)))
    end).

with_operation_endpoint(Test) -> with_operation_endpoint(1, Test).
with_operation_endpoint(N, Test) ->
    quod_operation_fixture:with(N, fun(F = #{target := {Ns, Anchor},
      store := Store, projection := P, entry := Entry, node_identity := Signer}) ->
        View = quod_operation_fixture:view(Store, P, Entry),
        S0 = quod_simplex:test_state(#{ns => Ns, self => maps:get(pubkey, Signer),
          id => Signer, genesis_hash => Anchor, store => Store, slot => 2,
          last_applied => 2, sync => ready, prolog_ready => true}),
        S = quod_simplex:test_install_projection(maps:get(projection, View), S0),
        with_endpoint_state(Ns, Anchor, maps:get(committee_id, P), S, F, Test)
    end).

with_endpoint(Ready, Test) ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"outcome-wait-", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    Anchor = <<11:256>>,
    Committee = <<12:256>>,
    Key = <<13:256>>,
    S = quod_simplex:test_state(#{ns => Ns, self => Key, validators => [Key],
          genesis_hash => Anchor, committee_id => Committee, slot => 3,
          last_applied => 3, sync => ready, prolog_ready => Ready, store => memory}),
    with_endpoint_state(Ns, Anchor, Committee, S, #{}, Test).

with_endpoint_state(Ns, Anchor, Committee, S, Extra, Test) ->
    Parent = self(),
    Stub = spawn(fun() ->
        true = quod_reg:reg({quod_prolog, Ns}),
        Parent ! {stub_ready, self()},
        prolog_stub(Ns, Parent)
    end),
    receive {stub_ready, Stub} -> ok after 1000 -> error(stub_not_ready) end,
    Owner = spawn(fun() ->
        true = quod_reg:reg({quod_simplex, Ns}),
        Parent ! {owner_ready, self()}, owner_loop(Parent, S)
    end),
    receive {owner_ready, Owner} -> ok after 1000 -> error(owner_not_ready) end,
    F = Extra#{ns => Ns, anchor => Anchor, committee => Committee, owner => Owner,
          tag => make_ref(), request_id => crypto:strong_rand_bytes(16)},
    try Test(F)
    after
        stop_process(Owner),
        stop_process(Stub)
    end.

prolog_stub(Ns, Parent) ->
    receive
        {'$gen_call', {Worker, _} = From, {outcome_snapshot, _Ref}} ->
            Parent ! {snapshot_call, Ns, Worker, From},
            prolog_stub(Ns, Parent)
    end.

owner_loop(Parent, S) ->
    receive
        {'$gen_call', From, {dtx_endpoint_local, Request, [], Timeout, _TraceCtx}} ->
            case quod_simplex:test_start_local_dtx_endpoint_request(Request, [], Timeout, From, S) of
                {ok, S1} -> owner_loop(Parent, S1);
                Error -> gen_statem:reply(From, Error), owner_loop(Parent, S)
            end;
        {'$gen_call', From, {history_view, Identity, Requirement, Deadline}} ->
            Result = quod_simplex:test_local_history_view(Identity, Requirement, Deadline, S),
            Parent ! {history_capture, self(), Identity, Requirement, Result},
            gen_statem:reply(From, Result),
            owner_loop(Parent, S);
        {call, Ref, {start, Request, Timeout, From}} ->
            case quod_simplex:test_start_local_dtx_endpoint_request(
                   Request, [], Timeout, From, S) of
                {ok, S1} -> Parent ! {Ref, ok}, owner_loop(Parent, S1);
                Error -> Parent ! {Ref, Error}, owner_loop(Parent, S)
            end;
        {call, Ref, {update, Overrides}} ->
            S1 = maps:fold(fun quod_simplex:test_state_set/3, S, Overrides),
            ok = quod_simplex:test_wake_dtx_snapshot_workers(S, S1),
            Parent ! {Ref, ok}, owner_loop(Parent, S1);
        {call, Ref, count} ->
            Parent ! {Ref, maps:get(workers, quod_simplex:test_dtx_endpoint_counts(S))},
            owner_loop(Parent, S);
        {dtx_endpoint_worker_result, Worker, Result} ->
            {S1, Actions} = quod_simplex:test_finish_dtx_worker(Worker, Result, S),
            Parent ! {endpoint_result, self(), Result},
            lists:foreach(fun({reply, From, Reply}) -> gen_statem:reply(From, Reply) end,
                          Actions),
            owner_loop(Parent, S1);
        {'DOWN', _, process, _, _} -> owner_loop(Parent, S)
    end.

request(#{request_id := Id, certified_target_ref := Ref}, operation_applied) ->
    {operation_applied, Id, Ref};
request(F, Kind) ->
    #{ns := Ns, anchor := Anchor, committee := Cid, request_id := Id} = F,
    Ref = case Kind of
        outcome -> {transaction, Ns, Anchor, <<14:256>>};
        outcome_barrier ->
            {group, Ns, Anchor, <<13:256>>,
             quod_simplex:test_author_admission(<<13:256>>), <<16:256>>}
    end,
    {Kind, Id, Ref, Cid, 3}.

snapshot(Height) -> {ok, #{applied_floor => Height, outcome => not_found}}.

operation_snapshot(#{target_ref := Ref}, Floor, Verdict) ->
    Row = case Verdict of
        committed -> #{ref => Ref, height => 2, status => committed};
        {rejected, Reason} -> #{ref => Ref, height => 2, status => rejected, reason => Reason}
    end,
    {ok, #{applied_floor => Floor, outcome => Row}}.

await_operation_snapshot(#{owner := Owner}, {ok, Snapshot}) ->
    receive {endpoint_result, Owner, {operation_applied_state, _, Snapshot}} -> ok
    after 1000 -> error(operation_snapshot_not_processed)
    end.

assert_one_history_capture(#{owner := Owner, target := Target}) ->
    receive {history_capture, Owner, Target, any, {ok, #{slot := 2}}} -> ok;
            {history_capture, Owner, Identity, Requirement, Result} ->
                error({unexpected_history_capture, Identity, Requirement, Result})
    after 1000 -> error(no_exact_history_capture)
    end.
assert_no_history_capture(#{owner := Owner}) ->
    receive {history_capture, Owner, _, _, _} -> error(recaptured_pinned_history)
    after 0 -> ok
    end.
assert_no_reply(#{tag := Tag}) ->
    receive {Tag, Reply} -> error({signed_before_publication, Reply})
    after 0 -> ok
    end.
assert_operation_vote(F = #{tag := Tag, certified_target_ref := Ref, request_id := Id,
                            network := Network, evidence := Evidence}, Expected) ->
    receive {Tag, {ok, {operation_applied, Id, Ref, Statement, Key, Signature}, []}} ->
        ?assertEqual({ok, Statement}, quod_applied_certificate:operation_statement(Network, Evidence, Expected)),
        ?assertEqual(maps:get(pubkey, maps:get(node_identity, F)), Key),
        ?assert(quod_applied_certificate:verify_operation_vote(Statement, Key, Signature))
    after 1000 -> error(operation_vote_not_received)
    end.

start_request(F, Kind, Timeout) -> ?assertEqual(ok, admit(F, request(F, Kind), Timeout)).
admit(F, Request, Timeout) ->
    owner_call(F, {start, Request, Timeout, {self(), maps:get(tag, F)}}).
update_owner(F, Overrides) -> ?assertEqual(ok, owner_call(F, {update, Overrides})).
worker_count(F) -> owner_call(F, count).
owner_call(#{owner := Owner}, Message) ->
    Ref = make_ref(),
    Owner ! {call, Ref, Message},
    receive {Ref, Reply} -> Reply after 1000 -> error(owner_not_responding) end.

snapshot_call(#{ns := Ns}) ->
    receive {snapshot_call, Ns, Worker, From} -> {Worker, From}
    after 1000 -> error(snapshot_not_requested)
    end.
await_result(#{owner := Owner}, Result) ->
    receive {endpoint_result, Owner, Result} -> ok
    after 1000 -> error({result_not_processed, Result})
    end.
assert_no_snapshot(#{ns := Ns}) ->
    receive {snapshot_call, Ns, _, _} -> error(snapshot_spun_without_progress)
    after 30 -> ok
    end.
subscribers(#{ns := Ns}) -> gproc:lookup_pids({p, l, {runtime, Ns}}).
assert_subscribed(F, Worker) -> ?assertEqual([Worker], subscribers(F)).
assert_outcome(#{tag := Tag, request_id := Id, ns := Ns,
                 anchor := Anchor, committee := Cid}, Kind, Floor) ->
    receive {Tag, Reply} ->
        ?assertEqual({ok, {Kind, Id, {Ns, Anchor}, Cid, Floor, not_found}, []}, Reply)
    after 1000 -> error(endpoint_never_replied)
    end.
assert_refused(#{tag := Tag, request_id := Id}) ->
    receive {Tag, Reply} -> ?assertEqual({ok, {error, Id, not_ready}, []}, Reply)
    after 1000 -> error(endpoint_never_refused)
    end.
assert_worker_gone(F, Worker) ->
    Monitor = monitor(process, Worker),
    receive {'DOWN', Monitor, process, Worker, _} -> ok
    after 1000 -> error(worker_retained_after_reply)
    end,
    ?assertEqual(0, worker_count(F)),
    ?assertEqual([], subscribers(F)).
stop_process(Pid) ->
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(fixture_process_did_not_stop)
    end.
