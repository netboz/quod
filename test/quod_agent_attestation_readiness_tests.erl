-module(quod_agent_attestation_readiness_tests).
-include_lib("eunit/include/eunit.hrl").

%% Real gate transitions, router, Prolog, signatures and MVCC. The pending
%% projection is injected at the existing Simplex TEST seam: these fixtures
%% do not claim consensus admission or emulate a four-node network.

membership_survives_apply_lag_test() ->
    with_fixture(fun(C = #{ns := Ns}) ->
        {ok, Before} = quod_simplex:identity_view(Ns),
        Access = open_access(C),
        _ = close_gate(C),
        ?assertEqual({ok, Before}, quod_simplex:identity_view(Ns)),
        ?assertMatch({error, {transaction_pending, _}},
                     quod_simplex:check_proof_access(Access))
    end).

exact_clear_wakes_once_after_install_test() ->
    with_fixture(fun(C = #{key := Key}) ->
        S0 = close_gate(C),
        true = quod_reg:subscribe(Key),
        MFA = {quod_simplex, acquire_attestation_gate, 4},
        erlang:trace_pattern(MFA, true, [call_count]),
        try
            W = waiter(C, quod_time:mono_ms() + 2000),
            _ = waiting(C),
            ?assertEqual({call_count, 1}, erlang:trace_info(MFA, call_count)),
            %% Neither unrelated progress nor a stale ACK changes the gate.
            S1 = ack(S0, 7),
            P = quod_simplex:test_state_projection(S1),
            Hinted = quod_simplex:test_install_projection(
                P#{validator_routes := #{<<88:256>> => []}}, S1),
            quod_reg:publish({proof_gate, {<<"another">>, self()}},
                             {proof_fence_cleared, self(), fence()}),
            ?assertEqual([], gate_events()),
            S2 = ack(Hinted, 8),
            ?assertEqual([{proof_fence_cleared, self(), fence()}], gate_events()),
            {ok, Access} = result(W),
            ?assertEqual(ok, quod_simplex:check_proof_access(Access)),
            ?assertEqual({call_count, 2}, erlang:trace_info(MFA, call_count)),
            ?assertEqual({ok, Access}, result(waiter(C, quod_time:mono_ms() + 1000))),
            _ = ack(S2, 8),
            ?assertEqual([], gate_events())
        after
            erlang:trace_pattern(MFA, false, [call_count]),
            quod_reg:unsubscribe(Key)
        end
    end).

cleared_before_subscription_needs_no_notice_test() ->
    with_fixture(fun(C) ->
        _ = ack(close_gate(C), 8),
        ?assertMatch({ok, _}, result(waiter(C, quod_time:mono_ms() + 1000)))
    end).

wait_has_one_absolute_deadline_test() ->
    with_fixture(fun(C = #{key := Key}) ->
        _ = close_gate(C),
        Deadline = quod_time:mono_ms() + 100,
        W = waiter(C, Deadline),
        ?assertEqual({error, timeout}, result(W)),
        ?assert(quod_time:mono_ms() >= Deadline),
        ?assertEqual([], gproc:lookup_pids({p, l, Key})),
        ?assertEqual({error, timeout}, result(waiter(C, Deadline)))
    end).

cancelled_wait_unsubscribes_test() ->
    with_fixture(fun(C = #{ns := Ns, key := Key}) ->
        _ = close_gate(C),
        Caller = spawn(fun() -> receive finish -> ok end end),
        W = launch(fun() ->
            Ref = monitor(process, Caller),
            quod_simplex:await_proof_access(Ns, quod_time:mono_ms() + 10000, #{Ref => true})
        end),
        _ = waiting(C),
        Caller ! finish,
        ?assertEqual({error, unavailable}, result(W)),
        ?assertEqual([], gproc:lookup_pids({p, l, Key}))
    end).

owner_loss_never_borrows_replacement_generation_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = namespace(),
    Parent = self(),
    {Owner, Ref} = spawn_monitor(fun() ->
        Tab = gate_table(Ns, <<51:256>>, <<250:256>>, 7, []),
        Parent ! {gate_owner, self(), Tab},
        receive finish -> ok end
    end),
    receive {gate_owner, Owner, _} -> ok after 1000 -> error(no_gate) end,
    Access = open_access(#{ns => Ns}),
    Owner ! finish,
    receive {'DOWN', Ref, process, Owner, normal} -> ok after 1000 -> error(no_down) end,
    Tab = gate_table(Ns, <<51:256>>, <<250:256>>, 7, []),
    try ?assertMatch({error, _}, quod_simplex:check_proof_access(Access))
    after ets:delete(Tab) end.

committee_change_invalidates_acquired_access_test() ->
    with_fixture(fun(C = #{tab := Tab}) ->
        Access = open_access(C),
        true = ets:update_element(Tab, proof_gate, {7, <<99:256>>}),
        ?assertMatch({error, _}, quod_simplex:check_proof_access(Access))
    end).

committee_replacement_cancels_pending_acquisition_test() ->
    with_fixture(fun(C = #{ns := Ns}) ->
        Closed = close_gate(C),
        W = waiter(C, quod_time:mono_ms() + 2000),
        _ = waiting(C),
        P = quod_simplex:test_state_projection(Closed),
        _ = quod_simplex:test_install_projection(
              P#{committee_id := <<99:256>>, committee_views := []}, Closed),
        ?assertEqual({error, unavailable}, result(W)),
        ?assertMatch({ok, #{committee_id := <<99:256>>}}, quod_simplex:identity_view(Ns))
    end).

owner_loss_cancels_pending_acquisition_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = namespace(), Parent = self(),
    {Owner, Ref} = spawn_monitor(fun() ->
        _ = gate_table(Ns, <<51:256>>, <<250:256>>, 8, [fence()]),
        Parent ! {gate_owner, self()},
        receive finish -> ok end
    end),
    receive {gate_owner, Owner} -> ok after 1000 -> error(no_gate) end,
    C = #{ns => Ns, key => {proof_gate, {Ns, Owner}}},
    W = waiter(C, quod_time:mono_ms() + 2000),
    _ = waiting(C),
    Owner ! finish,
    receive {'DOWN', Ref, process, Owner, normal} -> ok after 1000 -> error(no_down) end,
    ?assertEqual({error, unavailable}, result(W)).

real_absence_and_nonmembership_do_not_wait_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    ?assertEqual({error, unavailable}, quod_simplex:await_proof_access(
        namespace(), quod_time:mono_ms() + 2000, #{})),
    with_fixture(fun(#{ns := Ns, tab := Tab}) ->
        true = ets:update_element(Tab, proof_gate, {6, [<<99:256>>]}),
        ?assertEqual({error, not_validator}, quod_simplex:await_proof_access(
            Ns, quod_time:mono_ms() + 2000, #{}))
    end).

identity_collection_waits_through_apply_and_stale_ack_test() ->
    with_fixture(fun(C = #{ns := Ns}) ->
        Closed = close_gate(C),
        W = collection(C),
        _ = waiting_collection(C, W),
        apply_facts(Ns, 2, quod_ct:diff_for({unrelated, applied})),
        Stale = ack(Closed, 7),
        _ = waiting_collection(C, W),
        _ = ack(Stale, 8),
        ?assertMatch({ok, _}, result(W))
    end).

revocation_applied_while_waiting_is_not_signed_test() ->
    with_fixture(fun(C = #{ns := Ns, fact := Fact}) ->
        Closed = close_gate(C),
        W = collection(C),
        _ = waiting_collection(C, W),
        [{assert, Clause}] = quod_ct:diff_for(Fact),
        apply_facts(Ns, 2, [{retract, Clause}]),
        _ = ack(Closed, 8),
        ?assertEqual({error, unavailable}, result(W))
    end).

revocation_after_key_proof_invalidates_signing_test() ->
    with_fixture(fun(C = #{ns := Ns, fact := Fact}) ->
        {Access, Reads} = key_proof(C),
        [{assert, Clause}] = quod_ct:diff_for(Fact),
        apply_facts(Ns, 2, [{retract, Clause}]),
        ?assertEqual({error, retry}, sign(C, Access, Reads))
    end).

new_unapplied_fence_invalidates_signing_test() ->
    with_fixture(fun(C) ->
        {Access, Reads} = key_proof(C),
        _ = close_gate(C),
        ?assertEqual({error, retry}, sign(C, Access, Reads))
    end).

cleared_successor_generation_does_not_refresh_old_proof_test() ->
    with_fixture(fun(C) ->
        {Access, Reads} = key_proof(C),
        _ = ack(close_gate(C), 8),
        ?assertEqual({error, retry}, sign(C, Access, Reads))
    end).

expired_caller_cannot_sign_even_with_current_access_test() ->
    with_fixture(fun(C = #{engine := Engine, evidence := Evidence}) ->
        {Access, Reads} = key_proof(C),
        ?assertEqual({error, retry}, gen_server:call(Engine,
            {sign_agent_identity, Access, Reads, Evidence, <<94:256>>,
             quod_time:now_ms() + 1000, quod_time:mono_ms() - 1}))
    end).

four_member_quorum_waits_for_fenced_third_signature_test() ->
    %% One real attester plus two fixture signatures and one absent member.
    %% The signed quorum and gate are real; this is not a network/consensus
    %% fixture. Two signatures cannot authorize; clearing the fence permits
    %% the third, while the fourth member remains absent.
    with_fixture(fun(C = #{ns := Ns, tab := Tab, evidence := Evidence}) ->
        {ok, #{self := Self}} = quod_simplex:identity_view(Ns),
        Keys = [quod_identity:generate() || _ <- lists:seq(1, 3)],
        Committee = lists:sort([Self | [K || {K, _} <- Keys]]),
        Closed = close_gate(C),
        true = ets:update_element(Tab, proof_gate, {6, Committee}),
        Proof = <<93:256>>, NotAfter = quod_time:now_ms() + 2000,
        {ok, Statement} = quod_agent_identity:statement(Evidence, Proof, <<52:256>>, NotAfter),
        Rows = [begin
            {ok, Row} = quod_agent_identity:sign(Statement,
                #{pubkey => K, key => quod_identity:key_term(KP)}), Row
        end || KP = {K, _} <- lists:sublist(Keys, 2)],
        {ok, View} = quod_simplex:identity_view(Ns),
        {ok, Incomplete} = quod_agent_identity:certificate(Statement, Rows, []),
        ?assertMatch({error, _}, quod_agent_identity:verify(Incomplete, Evidence, Proof, View, quod_time:now_ms())),
        Request = {agent_identity_request, <<93:128>>, Proof,
                   maps:get(request_bytes, Evidence), maps:get(signature, Evidence), NotAfter},
        ok = quod_prolog:request_agent_attestation(Ns, Request, self(), third_signature),
        _ = waiting(C),
        %% Keep the same installed committee when publishing the exact ACK.
        P = quod_simplex:test_state_projection(Closed),
        S = quod_simplex:test_install_projection(P#{committee := Committee}, Closed),
        _ = ack(S, 8),
        receive
            {quod_agent_attestation, third_signature, {ok, Self, Statement, Signature}} ->
                {ok, Certificate} = quod_agent_identity:certificate(Statement, [{Self, Signature} | Rows], []),
                ?assertEqual(ok, quod_agent_identity:verify(Certificate, Evidence, Proof, View, quod_time:now_ms()))
        after 2500 -> error(no_third_signature) end
    end).

cohosted_routing_uses_installed_membership_during_fence_test() ->
    with_fixture(fun(C = #{ns := Ns}) ->
        _ = close_gate(C),
        ?assertEqual(local, quod_ask:test_cohosted_scope_route(
            {Ns, <<51:256>>}, quod_simplex:identity_view(Ns)))
    end).

reply_owner_loss_cancels_real_attester_test() ->
    with_fixture(fun(C = #{key := Key}) ->
        _ = close_gate(C),
        {Caller, Ref} = collection(C, 10000),
        Attester = waiting(C),
        ARef = monitor(process, Attester),
        exit(Caller, kill),
        receive {'DOWN', Ref, process, Caller, killed} -> ok after 2000 -> error(no_caller_down) end,
        receive {'DOWN', ARef, process, Attester, _} -> ok after 2000 -> error(no_attester_down) end,
        ?assertEqual([], gproc:lookup_pids({p, l, Key}))
    end).

public_deadline_includes_router_mailbox_residence_test() ->
    with_fixture(fun(C = #{router := Router, evidence := Evidence}) ->
        ok = sys:suspend(Router),
        Started = quod_time:mono_ms(),
        W = launch(fun() -> quod_ask_router:identity(Evidence, <<91:256>>, 20) end),
        try
            Deadline = until(fun() ->
                case process_info(Router, messages) of
                    {messages, Messages} ->
                        case [D || {'$gen_call', _, {identity, _, _, _, D, _}} <- Messages] of
                            [D] -> {ok, D};
                            _ -> false
                        end
                end
            end),
            ?assert(Deadline >= Started andalso Deadline =< quod_time:mono_ms() + 20),
            %% Advance to the actual deadline, not a guessed sleep. No work
            %% or readiness is polled in production; this controls queue age.
            _ = until(fun() -> case quod_time:mono_ms() >= Deadline of
                                  true -> {ok, expired}; false -> false end end),
            ok = sys:resume(Router),
            ?assertEqual({error, timeout}, result(W)),
            ?assertEqual([], gproc:lookup_pids({p, l, maps:get(key, C)}))
        after catch sys:resume(Router) end
    end).

with_fixture(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(crypto),
    Ns = namespace(), Anchor = <<51:256>>,
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    F = quod_ct:signed_goal_fixture(#{target => {Ns, Anchor}}),
    Tab = gate_table(Ns, Anchor, Pub, 7, []),
    PreviousKey = application:get_env(quod, node_pubkey),
    application:set_env(quod, node_pubkey, Pub),
    {ok, Router} = quod_ask_router:start_link(),
    try quod_ct:with_network_identity(maps:get(network, F), fun() ->
        {ok, Engine} = quod_prolog:start_link(Ns,
            #{node_id => Pub, identity => Signer, outcome_backend => memory}),
        try
            ok = quod_prolog:mark_ready(Ns),
            [Fact] = quod_ct:signed_agent_facts(F),
            apply_facts(Ns, 1, quod_ct:diff_for(Fact)),
            P0 = quod_atomic:initial_projection({Ns, Anchor}, 7),
            S0 = quod_simplex:test_state(#{ns => Ns, self => Pub, genesis_hash => Anchor,
                validators => [Pub], committee_id => <<52:256>>, prolog_ready => true,
                sync => ready, dtx_projection => P0, eng => quod_simplex:eng_new(
                    quod_simplex:consensus_domain(Ns, Anchor), [Pub],
                    {{quod_ledger:initial_era({Ns, Anchor}), 0, Anchor}, 1, 0})}),
            Fun(#{ns => Ns, tab => Tab, router => Router, engine => Engine,
                  evidence => maps:get(evidence, F), fixture => F, fact => Fact, state => S0,
                  key => {proof_gate, {Ns, self()}}})
        after gen_server:stop(Engine) end
    end)
    after
        gen_server:stop(Router), ets:delete(Tab),
        case PreviousKey of
            {ok, Value} -> application:set_env(quod, node_pubkey, Value);
            undefined -> application:unset_env(quod, node_pubkey)
        end
    end.

namespace() -> <<"quod:attestation-wait:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

gate_table(Ns, Anchor, Pub, Generation, Fences) ->
    Tab = binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
    Tab = ets:new(Tab, [named_table, protected, set]),
    true = ets:insert(Tab, [{anchor, Anchor},
        {proof_gate, true, Generation, Fences, Pub, [Pub], <<52:256>>, #{}}]),
    Tab.

fence() -> {<<53:256>>, 2, 8}.

close_gate(#{state := S0}) ->
    P = quod_simplex:test_state_projection(S0),
    D = maps:get(dtx, P),
    quod_simplex:test_install_projection(P#{dtx := D#{generation := 8,
        apply_fences := #{<<53:256>> => #{slot => 2, generation => 8, blocking => true}}}}, S0).

ack(S, Generation) ->
    element(2, quod_simplex:running(cast, {resolve_applied, <<53:256>>, 2, Generation}, S)).

apply_facts(Ns, Slot, Ops) ->
    Entry = quod_ct:committed_entry(Ns, Slot, quod_ct:batch(quod_ct:change(Ns, Ops, #{}))),
    ok = quod_prolog:apply_entry(Ns, Entry, live),
    Slot = quod_prolog:applied(Ns), ok.

key_proof(C = #{ns := Ns, fixture := F}) ->
    Access = open_access(C),
    {ok, Est, Height} = quod_prolog:attach_runtime(Ns),
    Session = quod_proof_session:start(Est, #{read_set => false, read_only => true,
        scope_id => <<92:128>>, access_guard => Access}),
    try
        {true, Reads} = quod_ask:authenticate_agent(maps:get(principal, F),
            maps:get(signing_key, F), {Ns, <<51:256>>}, Height, Session),
        {Access, Reads}
    after quod_proof_session:stop(Session) end.

sign(#{engine := Engine, evidence := Evidence}, Access, Reads) ->
    gen_server:call(Engine, {sign_agent_identity, Access, Reads, Evidence,
        <<92:256>>, quod_time:now_ms() + 1000, quod_time:mono_ms() + 1000}).

waiter(#{ns := Ns}, Deadline) ->
    launch(fun() -> quod_simplex:await_proof_access(Ns, Deadline, #{}) end).

open_access(#{ns := Ns}) ->
    {ok, Access} = quod_simplex:await_proof_access(Ns, quod_time:mono_ms() + 1000, #{}),
    Access.

collection(C) -> collection(C, 2000).

collection(#{evidence := Evidence}, RemainingMs) ->
    launch(fun() ->
        Proof = crypto:strong_rand_bytes(32),
        case quod_ask_router:identity(Evidence, Proof, RemainingMs) of
            {pending, Router, _, Ref} ->
                R = receive {quod_agent_identity, Ref, Reply} -> Reply
                    after 3000 -> error(no_identity_reply) end,
                ok = quod_ask_router:finalize(Router, Proof), R;
            Error -> Error
        end
    end).

launch(Fun) ->
    Parent = self(),
    spawn_monitor(fun() -> Parent ! {worker_result, self(), Fun()} end).

result({Pid, Ref}) ->
    receive
        {worker_result, Pid, Result} ->
            receive {'DOWN', Ref, process, Pid, normal} -> Result
            after 3000 -> error(worker_did_not_exit) end;
        {'DOWN', Ref, process, Pid, Reason} -> error({worker_exit, Reason})
    after 3000 -> error(no_worker_result) end.

waiting(#{key := Key}) ->
    until(fun() -> waiting_pid(Key) end).

waiting_collection(#{key := Key}, {Pid, _}) ->
    until(fun() ->
        receive {worker_result, Pid, Error} -> error({refused_instead_of_waiting, Error})
        after 0 -> waiting_pid(Key) end
    end).

waiting_pid(Key) ->
    case gproc:lookup_pids({p, l, Key}) -- [self()] of
        [Pid] ->
            case process_info(Pid, [status, current_function]) of
                [{status, waiting}, {current_function, {quod_simplex, acquire_attestation_gate, 4}}] -> {ok, Pid};
                _ -> false
            end;
        _ -> false
    end.

until(Check) -> until(Check, quod_time:mono_ms() + 2500).
until(Check, Deadline) ->
    case Check() of
        {ok, Value} -> Value;
        false ->
            case quod_time:mono_ms() < Deadline of
                true -> erlang:yield(), until(Check, Deadline);
                false -> error(fixture_barrier_timeout)
            end
    end.

gate_events() ->
    receive
        {proof_fence_cleared, _, _} = E -> [E | gate_events()];
        {proof_gate_invalidated, _} = E -> [E | gate_events()]
    after 0 -> [] end.
