-module(quod_personal_agent_tests).
-include_lib("eunit/include/eunit.hrl").
-export([with_personal/2, instruction/2, instruct/3, lookup/2, session/1,
         request/3, session/2, await_result/3, await_runtime_ready/1]).

immediate_instruction_uses_distinct_actor_test_() ->
    {timeout, 60, fun() -> with_personal(fun exercise/1) end}.

foreign_and_atomic_instruction_results_test_() ->
    [{atom_to_list(Lane), {timeout, 60, fun() ->
        with_personal(fun(Ctx) -> foreign_instruction(Ctx, Lane) end)
    end}} || Lane <- [foreign, atomic]].

interrupted_instruction_never_dispatches_test_() ->
    [{atom_to_list(Stop), {timeout, 60, fun() ->
        with_personal(fun(Ctx) -> interrupted_instruction(Ctx, Stop) end)
    end}} || Stop <- [cancel, deadline, host_restart]].

cancellation_during_target_proof_preserves_the_original_identity_test_() ->
    {timeout, 60, fun() -> with_personal(fun(Ctx = #{namespace := Ns, agent := Agent}) ->
        true = quod_reg:reg({host_test, barrier}),
        {Instruction, Bytes} = instruction(Ctx, {',', test_fipa_completion, {assertz, forbidden_later}}),
        Parent = self(),
        {Caller, Monitor} = spawn_monitor(fun() -> Parent ! {reply, instruct(Ctx, submit, Instruction)} end),
        try
            {Proof, Op} = receive {fipa_completion_prepared, P, Operation} -> {P, Operation}
                          after 5000 -> error(target_not_started) end,
            {ok, #{operation_ref := Op}} = quod_client_goal:request_identity(Bytes),
            ProofMon = monitor(process, Proof), exit(Caller, kill),
            receive {'DOWN', Monitor, process, Caller, killed} -> ok after 5000 -> error(caller_survived) end,
            receive {'DOWN', ProofMon, process, Proof, _} -> ok after 5000 -> error(proof_not_cancelled) end,
            restart_runtime(Ns, Agent), await_runtime_ready(Ns),
            ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns,
                {personal_instruction, maps:get(human, Ctx), {'_'}, {'_'}, {'_'}, {'_'}, Bytes, {'_'}})),
            ?assertMatch({ok, _, {operation_pending, Op}}, lookup(Ctx, Bytes)),
            ?assertMatch({ok, _, {operation_pending, Op}}, instruct(Ctx, submit, Instruction)),
            ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, forbidden_later)),
            receive {fipa_completion_prepared, _, _} -> error(target_was_resubmitted) after 0 -> ok end
        after exit(Caller, kill), demonitor(Monitor, [flush]), gproc:unreg(quod_reg:name({host_test, barrier})) end
    end) end}.

retained_but_unsubmitted_instruction_is_not_replayed_test_() ->
    {timeout, 60, fun() -> with_personal(fun(Ctx = #{namespace := Ns, agent := Agent}) ->
        {Instruction = {UBytes, USig}, Bytes} = instruction(Ctx, {assertz, forbidden_later}),
        {_, Signature} = admitted(Instruction),
        %% Interrupt at the custody/dispatch handoff: commit the exact same
        %% association as the actor, without submitting its target request.
        {StoreInstruction, StoreBytes} = instruction(Ctx,
            {retain_personal_instruction, UBytes, USig, Signature}),
        {_, StoreSig} = admitted(StoreInstruction),
        ?assertMatch({ok, _, {normalized, {committed, _, _}}}, submit({StoreBytes, StoreSig})),
        %% Verified authority fields do not freeze U's grant. A later revocation
        %% must still deny the exact signed target through normal ingress.
        {UKey, _} = maps:get(human_pair, Ctx),
        {ok, _, _} = quod_prolog:execute(Ns, {retract, {agent_key, me, UKey, active}}),
        ?assertMatch({ok, _, {normalized, {failed, _}}}, submit({Bytes, Signature})),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, forbidden_later)),
        {ok, _, _} = quod_prolog:execute(Ns, {assertz, {agent_key, me, UKey, active}}),
        restart_runtime(Ns, Agent),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns,
            {personal_instruction, maps:get(human, Ctx), {'_'}, {'_'}, UBytes, USig, Bytes, Signature})),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, forbidden_later)),
        ?assertMatch({ok, _, {operation_pending, _}}, lookup(Ctx, Bytes))
    end) end}.

interrupted_instruction(Ctx = #{namespace := Ns, agent := Agent, actor_pid := Actor}, Stop) ->
    RequestContext = case Stop of
        deadline -> Ctx#{target_expiry => quod_time:now_ms() + 1000};
        _ -> Ctx
    end,
    {Instruction, Bytes} = instruction(RequestContext, {assertz, forbidden_later}),
    {Evidence, Signature} = admitted(Instruction),
    Vault = quod_reg:where({agent_vault, node}),
    ok = sys:suspend(Vault),
    Trace = trace:session_create(instruction_interruption, self(), []),
    trace:process(Trace, Actor, true, [procs]),
    true = quod_reg:subscribe({agent, Agent}),
    Parent = self(),
    Deadline = quod_time:mono_ms() + 10000,
    {Caller, CallerMon} = spawn_monitor(fun() ->
        Result = quod_runtime:agent_request_now(Ns, Evidence, {Bytes, Signature}, Deadline),
        Parent ! {admitted, self(), Result},
        receive {agent_instruction_result, _, Reply} -> Parent ! {reply, self(), Reply} end
    end),
    try
        receive {admitted, Caller, {ok, _, Actor}} -> ok
        after 5000 -> error(instruction_not_admitted) end,
        Worker = receive {trace, Actor, spawn, Pid, _} -> Pid
                 after 5000 -> error(worker_not_started) end,
        true = erlang:suspend_process(Worker),
        WorkerMon = monitor(process, Worker),
        ?assertEqual({error, agent_unavailable},
            quod_runtime:agent_request_now(Ns, Evidence, {Bytes, Signature}, Deadline)),
        case Stop of
            cancel -> exit(Caller, kill);
            deadline ->
                receive {reply, Caller, {error, {outcome_unknown, _}}} -> ok
                after 5000 -> error(deadline_was_extended) end;
            host_restart ->
                ok = supervisor:terminate_child(quod_reg:where({quod_ns, Ns}), quod_runtime)
        end,
        receive {'DOWN', WorkerMon, process, Worker, killed} -> ok
        after 5000 -> error(worker_not_cancelled) end,
        ok = sys:resume(Vault),
        case Stop of
            host_restart ->
                {ok, _} = supervisor:restart_child(quod_reg:where({quod_ns, Ns}), quod_runtime),
                _ = installed(Agent);
            _ ->
                receive {agent_request_finished, _, Actor, _, _, _} -> ok
                after 5000 -> error(completion_not_processed) end,
                restart_runtime(Ns, Agent)
        end,
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, forbidden_later)),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns,
            {personal_instruction, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}))
    after
        trace:session_destroy(Trace), quod_reg:unsubscribe({agent, Agent}),
        catch sys:resume(Vault), exit(Caller, kill), demonitor(CallerMon, [flush])
    end.

restart_runtime(Ns, Agent) ->
    Sup = quod_reg:where({quod_ns, Ns}),
    ok = supervisor:terminate_child(Sup, quod_runtime),
    {ok, _} = supervisor:restart_child(Sup, quod_runtime),
    installed(Agent).

admitted(Instruction) ->
    {ok, Evidence, {normalized, {read, _, {answers, _, [Answer]}}}} = submit(Instruction),
    {ok, [{_, Signature}]} = quod_client_result:decode_binding(Answer),
    {Evidence, Signature}.

lookup(Ctx, Bytes) ->
    {ok, #{request := #{operation_id := Id}}} = quod_client_goal:request_identity(Bytes),
    instruct(Ctx, resolve, request(Ctx, read,
        {personal_instruction_lookup, Id, {'Bytes'}, {'Signature'}})).

unavailable_actor_does_not_dispatch_on_restart_test_() ->
    {timeout, 60, fun() -> with_personal(fun(Ctx = #{namespace := Ns, agent := Agent}) ->
        {Instruction, _} = instruction(Ctx, {assertz, forbidden_later}),
        Sup = quod_reg:where({quod_ns, Ns}),
        ok = supervisor:terminate_child(Sup, quod_runtime),
        ?assertEqual({error, {request_not_submitted, agent_unavailable}},
                     instruct(Ctx, submit, Instruction)),
        {ok, _} = supervisor:restart_child(Sup, quod_runtime),
        {Runtime, _} = installed(Agent),
        _ = quod_runtime:stats(Ns),
        ?assert(is_process_alive(Runtime)),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, forbidden_later)),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns,
                     {personal_instruction, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}))
    end) end}.

unauthorized_and_staged_signing_are_denied_test_() ->
    {timeout, 60, fun() -> with_personal(fun(Ctx = #{namespace := Ns}) ->
        {Instruction = {UBytes, USig}, TargetBytes} = instruction(Ctx, {assertz, forbidden}),
        Other = session(quod_identity:generate()),
        ?assertEqual({error, session_principal_mismatch},
                     instruct(Ctx#{session => Other}, submit, Instruction)),
        ?assertEqual({error, invalid_signature},
                     instruct(Ctx, submit, {UBytes, <<0:512>>})),
        {ok, Typed} = quod_client_goal:decode_typed(TargetBytes),
        Staged = {',', {assertz, {can_sign_agent_request, {'_'}, {'_'}, Typed}},
                      {sign_agent_request, Typed, {'Signature'}}},
        ?assertNotMatch({ok, _, {normalized, {committed, _, _}}}, submit(request(Ctx, execute, Staged))),
        {ok, _, _} = quod_prolog:execute(Ns, {assertz, {agent_hosting_suspended, personal}}),
        ?assertEqual({error, instruction_not_authorized}, instruct(Ctx, submit, {UBytes, USig})),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, forbidden))
    end) end}.

revocation_preserves_authorized_result_recovery_test_() ->
    {timeout, 60, fun() -> with_personal(fun(Ctx = #{namespace := Ns, key := Key}) ->
        {Instruction, Bytes} = instruction(Ctx, {',', {'=', {'Value'}, original}, {assertz, created}}),
        ?assertMatch({ok, _, {normalized, {committed, _, _}}}, instruct(Ctx, submit, Instruction)),
        {NextInstruction, NextBytes} = instruction(Ctx, {assertz, forbidden}),
        {_, NextSig} = admitted(NextInstruction),
        {ok, _, _} = quod_prolog:execute(Ns, {',', {retract, {agent_key, personal, Key, active}},
                                                {assertz, {agent_key, personal, Key, revoked}}}),
        ?assertNotMatch({ok, _, {normalized, {committed, _, _}}}, submit({NextBytes, NextSig})),
        ?assertEqual({error, instruction_not_authorized}, instruct(Ctx, submit, NextInstruction)),
        ?assertMatch({ok, _, {operation_outcome, _, #{bindings := [{<<"V0">>, original}]}}}, lookup(Ctx, Bytes)),
        {OldKey, _} = maps:get(human_pair, Ctx),
        {NewKey, _} = NewPair = quod_identity:generate(),
        {ok, _, _} = quod_prolog:execute(Ns, {',', {retract, {agent_key, me, OldKey, active}},
            {',', {assertz, {agent_key, me, OldKey, revoked}}, {assertz, {agent_key, me, NewKey, active}}}}),
        ?assertNotMatch({ok, _, {operation_outcome, _, _}}, lookup(Ctx, Bytes)),
        NewDevice = Ctx#{human_pair => NewPair, session => session(NewPair)},
        ?assertMatch({ok, _, {operation_outcome, _, #{bindings := [{<<"V0">>, original}]}}}, lookup(NewDevice, Bytes)),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, forbidden))
    end) end}.

another_human_cannot_read_or_sign_the_instruction_test_() ->
    {timeout, 60, fun() -> with_personal(fun(Ctx = #{namespace := Ns, directory := Dir, identity := Node}) ->
        {Instruction, Bytes} = instruction(Ctx, {assertz, private_work}),
        ?assertMatch({ok, _, {normalized, {committed, _, _}}}, instruct(Ctx, submit, Instruction)),
        {Key, _} = Pair = quod_identity:generate(), OtherNs = <<"other-human">>,
        Sources = quod_prolog:read_terms(filename:join([code:priv_dir(quod), "ontologies", "user_instance.pl"])),
        Sup = quod_agent_hosting_tests:start_ontology(OtherNs, Dir, Node, [],
            Sources ++ [{instance_of, human_user, me}, {agent_key, me, Key, active}]),
        Other = Ctx#{human => {agent_instance_ref, OtherNs, quod_simplex:genesis_hash(OtherNs), me},
                     human_pair => Pair, session => session(Pair)},
        try
            {ok, #{request := #{operation_id := Id}}} = quod_client_goal:request_identity(Bytes),
            [{ok, _, {normalized, {read, _, {failed, _}}}} = submit(request(Other, read, {'::', Ns, Goal}))
             || Goal <- [{personal_instruction_lookup, Id, {'Bytes'}, {'Signature'}},
                         {personal_instruction_retained, Bytes, {'Retained'}},
                         {personal_instruction_accept, Bytes, {'Signature'}},
                         {personal_instruction, {'_'}, Id, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}]]
        after quod_agent_hosting_tests:stop_ontology(Sup) end
    end) end}.

human_revocation_between_signing_and_custody_refuses_dispatch_test_() ->
    {timeout, 60, fun() -> with_personal(fun(Ctx = #{namespace := Ns, human_pair := {Key, _}}) ->
        {Instruction, Bytes} = instruction(Ctx, {assertz, forbidden}),
        {Evidence, Signature} = admitted(Instruction),
        {ok, _, _} = quod_prolog:execute(Ns, {retract, {agent_key, me, Key, active}}),
        await_runtime_ready(Ns),
        {ok, Ref, _} = quod_runtime:agent_request_now(Ns, Evidence,
            {Bytes, Signature}, quod_time:mono_ms() + 5000),
        receive {agent_instruction_result, Ref, Result} ->
            ?assertMatch({error, {instruction_not_submitted, instruction_refused}}, Result)
        after 5000 -> error(revocation_not_observed) end,
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, forbidden)),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns,
            {personal_instruction, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}))
    end) end}.

endpoint_refusal_preserves_prior_operations_test_() ->
    [{atom_to_list(State), {timeout, 60, fun() -> with_personal(fun(Ctx = #{namespace := Ns,
          human_pair := {Key, _}}) ->
        {Instruction, Bytes} = instruction(Ctx, {assertz, original_work}),
        case State of
            fresh -> ?assertEqual({error, instruction_not_found}, lookup(Ctx, Bytes));
            retained -> ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                                    instruct(Ctx, submit, Instruction))
        end,
        %% Hold the real acceptance read after signing, then revoke U in a
        %% committed update before the endpoint reaches actor custody.
        Head = {personal_instruction_accept, {'B'}, {'S'}},
        {ok, _, _} = quod_prolog:execute(Ns, {',',
            {retract, {':-', Head, {'Body'}}},
            {assertz, {':-', Head, {',', {'Body'}, test_local_wait}}}}),
        true = quod_reg:reg({host_test, local_proof}), Parent = self(),
        {Caller, Monitor} = spawn_monitor(fun() ->
            Parent ! {endpoint_reply, self(), instruct(Ctx, submit, Instruction)} end),
        try
            Proof = receive {local_proof_waiting, P} -> P after 5000 -> error(accept_not_paused) end,
            {ok, _, _} = quod_prolog:execute(Ns, {retract, {agent_key, me, Key, active}}),
            await_runtime_ready(Ns), Proof ! release,
            Reply = receive {endpoint_reply, Caller, R} -> R after 5000 -> error(no_endpoint_reply) end,
            case State of
                fresh ->
                    ?assertEqual({error, {request_not_submitted, instruction_refused}}, Reply),
                    ?assertEqual({409, #{error => instruction_refused, submitted => false}},
                                 quod_client_http:signed_goal_result(Reply)),
                    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, original_work));
                retained ->
                    ?assertMatch({ok, _, {operation_pending, _}}, Reply),
                    ?assertMatch({202, #{terminal := false}}, quod_client_http:signed_goal_result(Reply)),
                    ?assertMatch({ok, [#{'Rows' := [ok]}], _}, quod_prolog:prove_ro(Ns,
                        {findall, ok, original_work, {'Rows'}}))
            end
        after exit(Caller, kill), demonitor(Monitor, [flush]),
              gproc:unreg(quod_reg:name({host_test, local_proof})) end
    end) end}} || State <- [fresh, retained]].

authorization_does_not_reparse_retained_history_test_() ->
    {timeout, 60, fun() -> with_personal(fun(Ctx = #{namespace := Ns, agent := Agent,
                                                   human_pair := {UKey, _}}) ->
        Work = {assertz, current_work},
        {Instruction, Bytes} = instruction(Ctx, Work),
        ?assertMatch({ok, _, {normalized, {committed, _, _}}}, instruct(Ctx, submit, Instruction)),
        Check = fun() -> ?assertMatch({ok, [_], _},
            quod_prolog:prove_ro(Ns, {can_invoke, Work, Agent, [Ns], Ns})) end,
        %% Other trace sessions can leave messages in EUnit's reused mailbox.
        Noise = {trace, self(), call, {quod_reg, subscribe, [stale_directory_route]}},
        self() ! Noise,
        assert_no_authority_decoding(Ns, Check),
        receive Noise -> ok after 0 -> error(unrelated_trace_consumed) end,
        %% The measurement must still detect real decoding through the owner.
        ?assertError({history_decoded, {quod_common_primitives, agent_request_bytes_2, 3}},
            assert_no_authority_decoding(Ns, fun() ->
                ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns,
                    {agent_request_bytes, {'Typed'}, Bytes}))
            end)),
        [begin
            {Next, _} = instruction(Ctx, {assertz, {historical_work, I}}),
            await_runtime_ready(Ns),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, instruct(Ctx, submit, Next))
         end || I <- lists:seq(1, 12)],
        assert_no_authority_decoding(Ns, Check),
        {ok, _, _} = quod_prolog:execute(Ns, {retract, {agent_key, me, UKey, active}}),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {can_invoke, Work, Agent, [Ns], Ns})),
        {ok, _, _} = quod_prolog:execute(Ns, {assertz, {agent_key, me, UKey, active}}),
        Check()
    end) end}.

assert_no_authority_decoding(Ns, Check) ->
    Parent = self(), Tag = make_ref(),
    Collector = spawn_link(fun() -> authority_calls(Parent, Tag, none) end),
    Trace = trace:session_create(personal_authority, Collector, []),
    Patterns = [{quod_common_primitives, signed_agent_request_3, 3},
                {quod_common_primitives, agent_request_bytes_2, 3},
                {quod_common_primitives, program_source_2, 3}],
    try
        [trace:function(Trace, MFA, true, [local]) || MFA <- Patterns],
        [trace:process(Trace, Pid, true, [call, arity, set_on_spawn]) ||
            Pid <- [self(), quod_reg:where({quod_prolog, Ns})]],
        [Check() || _ <- lists:seq(1, 3)],
        Barrier = trace:delivered(Trace, all),
        receive {trace_delivered, all, Barrier} -> ok after 1000 -> error(trace_not_delivered) end,
        Collector ! finish,
        receive
            {Tag, none} -> ok;
            {Tag, MFA} -> error({history_decoded, MFA})
        after 1000 -> error(authority_trace_not_collected) end
    after trace:session_destroy(Trace), Collector ! stop end.

authority_calls(Parent, Tag, First) ->
    receive
        {trace, _, call, MFA} when First =:= none -> authority_calls(Parent, Tag, MFA);
        {trace, _, call, _} -> authority_calls(Parent, Tag, First);
        finish -> Parent ! {Tag, First}, authority_calls(Parent, Tag, First);
        stop -> ok
    end.

await_runtime_ready(Ns) ->
    Runtime = quod_reg:where({quod_runtime, Ns}), Parent = self(), Tag = make_ref(),
    Observe = fun(State, {in, {'$gen_cast', {runner_done, _, _}}}, _) ->
                      Parent ! {runtime_processed, Tag}, State;
                 (State, {in, {agent_completed, _, _, _}}, _) ->
                      Parent ! {runtime_processed, Tag}, State;
                 (State, _, _) -> State end,
    ok = sys:install(Runtime, {Observe, none}),
    try await_runtime_ready(Ns, quod_prolog:applied(Ns), Tag, quod_time:mono_ms()+5000)
    after sys:remove(Runtime, Observe) end.

await_runtime_ready(Ns, Height, Tag, Deadline) ->
    case quod_runtime:stats(Ns) of
        #{mode := live, runner_active := false, agent_pending_bytes := 0,
          height := Current, e_frontier := H} when H >= Height, H >= Current -> ok;
        State -> receive {runtime_processed, Tag} -> await_runtime_ready(Ns, Height, Tag, Deadline)
             after max(0,Deadline-quod_time:mono_ms()) -> error({runtime_not_ready,State}) end
    end.

with_personal(Fun) -> with_personal(Fun, []).

with_personal(Fun, Additional) ->
    Pair = {HumanKey, _} = quod_identity:generate(),
    Sources = lists:append([quod_prolog:read_terms(filename:join(
        [code:priv_dir(quod), "ontologies", File]))
        || File <- ["user_instance.pl"]]),
    quod_agent_hosting_tests:with_host(fun(Ctx = #{namespace := Ns, node := Node}) ->
        Anchor = quod_simplex:genesis_hash(Ns),
        Human = {agent_instance_ref, Ns, Anchor, me},
        Agent = {agent_instance_ref, Ns, Anchor, personal},
        {ok, _, _} = quod_prolog:execute(Ns, {',',{assertz, {hosting_node, Node}},{assertz,{user_namespace,Ns}}}),
        Base = Ctx#{human => Human, human_pair => Pair, agent => Agent},
        Prep = request(Base, read, {personal_agent_preparation, {'Preparation'}}),
        {ok, _, {normalized, {read, _, {answers, _, [Answer]}}}} = submit(Prep),
        {ok, [{<<"V0">>, {prepared, Node, Key}}]} = quod_client_result:decode_binding(Answer),
        begin
            ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                submit(request(Base, execute, {goal,{agent_hosted,personal,Node,1,Key}}))),
            {_, ActorPid} = installed(Agent),
            {ok, _, {normalized, {read, _, {answers, _, [Ready]}}}} = submit(Prep),
            ?assertEqual({ok, [{<<"V0">>, ready}]}, quod_client_result:decode_binding(Ready)),
            Fun(Base#{key => Key, actor_pid => ActorPid, session => session(Pair)})
        end
    end, personal_fixture_sources(Sources,Additional) ++ Additional ++
        [{instance_of, human_user, me}, {agent_key, me, HumanKey, active}]).

personal_fixture_sources(Sources, Additional) ->
    %% A fixture's explicit class/operation policy replaces that same key in
    %% the reusable account source. Predicate names inside grants may evolve.
    Overrides = [{Class, Operation} || {class_permission, Class, Operation, _} <- Additional],
    [Clause || Clause <- Sources,
        case Clause of
            {class_permission, Class, Operation, _} ->
                not lists:member({Class, Operation}, Overrides);
            _ -> true
        end].

exercise(Ctx = #{namespace := Ns, human := Human, agent := Agent}) ->
    %% A source-side target action admits only A, never a U request routed
    %% through the same namespace. The named result is retained by S1.1.
    Goal = {',', {current_principal, {'Actor'}},
            {',', {'=', {'Actor'}, Agent}, {assertz, {acted, {'Actor'}}}}},
    {Instruction, TargetBytes} = instruction(Ctx, Goal),
    ?assertMatch({ok, _, {normalized, {failed, _}}}, submit(request(Ctx, execute, Goal))),
    Reply = instruct(Ctx, submit, Instruction),
    ?assertMatch({ok, _, {normalized, {committed, _, _}}}, Reply),
    {ok, #{agent_ref_blob := ActorBlob}, {normalized, {committed, [Binding], _}}} = Reply,
    ?assertEqual({ok, ActorBlob}, quod_wire_term:encode_canonical(Agent)),
    ?assertEqual({ok, [{<<"V0">>, Agent}]}, quod_client_result:decode_binding(Binding)),
    {ok, #{request := #{operation_id := Id}}} = quod_client_goal:request_identity(TargetBytes),
    {ok, [#{'Rows' := [{instruction, Id, TargetBytes, Signature}]}], _} =
        quod_prolog:prove_ro(Ns, {findall, {instruction, {'I'}, {'B'}, {'S'}},
            {personal_instruction, Human, {'I'}, {'_'}, {'_'}, {'_'}, {'B'}, {'S'}}, {'Rows'}}),
    ?assertMatch({ok, _}, quod_client_goal:verify(TargetBytes, Signature)),
    %% A fresh authenticated device needs only its account and committed list.
    OtherDevice = Ctx#{session => session(maps:get(human_pair, Ctx))},
    {ok, LookupText} = quod_client_goal_parser:format({personal_instruction_lookup, Id, {0}, {1}}),
    NamedLookup = binary:replace(binary:replace(LookupText, <<"V0">>, <<"ZBytes">>),
                                <<"V1">>, <<"ASignature">>),
    Lookup = request_text(OtherDevice, read, NamedLookup),
    ?assertMatch({ok, _, {operation_outcome, _,
        #{status := committed, bindings := [{<<"V0">>, Agent}]}}},
        instruct(OtherDevice, resolve, Lookup)),
    Unchanged = fun() -> ?assertMatch({ok, _, {operation_outcome, _,
        #{status := committed, bindings := [{<<"V0">>, Agent}]}}}, lookup(OtherDevice, TargetBytes)) end,
    quod_outcome_result_tests:assert_unchanged_reads([Ns], Unchanged, 3),
    %% Re-presenting the same instruction can only encounter its existing
    %% association. The store guard prevents a second target dispatch.
    ?assertMatch({ok, _, {operation_pending, _}}, instruct(Ctx, submit, Instruction)),
    ?assertMatch({ok, [#{'Rows' := [Agent]}], _}, quod_prolog:prove_ro(Ns,
        {findall, {'A'}, {acted, {'A'}}, {'Rows'}})),
    %% Recovery restores the ontology and index, never dispatches the record.
    Old = quod_reg:where({quod_prolog, Ns}),
    true = quod_reg:subscribe({runtime, Ns}),
    try
        Monitor = monitor(process, Old), exit(Old, kill),
        receive {'DOWN', Monitor, process, Old, _} -> ok after 5000 -> error(owner_survived) end,
        receive {replay_ready, {Next, _}, _} when Next =/= Old -> ok
        after 5000 -> error(owner_not_recovered) end
    after quod_reg:unsubscribe({runtime, Ns}) end,
    Unchanged(),
    quod_outcome_result_tests:assert_unchanged_reads([Ns], Unchanged, 3),
    {NextInstruction, NextBytes} = instruction(Ctx, {assertz, next_work}),
    _ = installed(Agent),
    ?assertMatch({ok, _, {normalized, {committed, _, _}}}, instruct(Ctx, submit, NextInstruction)),
    ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}}, lookup(Ctx, NextBytes)).

foreign_instruction(Ctx = #{namespace := Ns, agent := Agent, directory := Dir, identity := Node}, Lane) ->
    {ok, Foreign} = quod_foreign_log:start_link(#{cache_dir => filename:join(Dir, "foreign")}),
    Target = <<"personal-target">>,
    Sup = quod_agent_hosting_tests:start_ontology(Target, Dir, Node, [],
        [{':-', {can_invoke, {'_'}, Agent, {'_'}, Target}, allow_personal}, allow_personal]),
    Anchor = quod_simplex:genesis_hash(Target),
    Work = {'::', Target, {',', {current_ontology_identity, Target, Anchor},
            {',', {current_principal, {'Actor'}}, {assertz, {created, {'Actor'}}}}}},
    Goal = case Lane of foreign -> Work; atomic -> {',', {assertz, origin_changed}, Work} end,
    try
        ?assertNotMatch({ok, _, {normalized, {committed, _, _}}}, submit(request(Ctx, execute, Goal))),
        {Instruction, Bytes} = instruction(Ctx, Goal),
        Live = instruct(Ctx, submit, Instruction),
        ?assertMatch({ok, _, {normalized, {committed, _, _}}}, Live),
        {ok, #{request := #{operation_id := Id}}} = quod_client_goal:request_identity(Bytes),
        Lookup = request(Ctx, read, {personal_instruction_lookup, Id, {'Bytes'}, {'Signature'}}),
        Status = case Lane of foreign -> completed; atomic -> committed end,
        true = quod_reg:subscribe({runtime, Ns}),
        try
            Result = await_result(Ctx, Lookup, quod_time:mono_ms() + 5000),
            ?assertMatch({ok, _, {operation_outcome, _,
                #{status := Status, bindings := [{<<"V0">>, Agent}]}}}, Result)
        after quod_reg:unsubscribe({runtime, Ns}) end,
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Target, {created, Agent})),
        %% U's instruction and A's signature do not replace target admission.
        {ok, _, _} = quod_prolog:execute(Target, {retract, allow_personal}),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Target, {can_invoke, element(3, Work), Agent, [Ns], Target})),
        {Denied, _} = instruction(Ctx, Goal),
        ?assertMatch({ok, _, {normalized, {failed, _}}}, instruct(Ctx, submit, Denied)),
        ?assertMatch({ok, [#{'Rows' := [Agent]}], _}, quod_prolog:prove_ro(Target,
            {findall, {'A'}, {created, {'A'}}, {'Rows'}})),
        case Lane of
            atomic -> ?assertMatch({ok, [#{'Rows' := [ok]}], _}, quod_prolog:prove_ro(Ns,
                {findall, ok, origin_changed, {'Rows'}}));
            foreign -> ok
        end
    after quod_agent_hosting_tests:stop_ontology(Sup), gen_server:stop(Foreign) end.

await_result(Ctx, Lookup, Deadline) ->
    case instruct(Ctx, resolve, Lookup) of
        {ok, _, {operation_outcome, _, #{status := Status}}} = Result
          when Status =:= committed; Status =:= completed -> Result;
        _ -> receive {projection_advanced, _, _} -> await_result(Ctx, Lookup, Deadline)
             after max(0, Deadline - quod_time:mono_ms()) -> error(result_not_published) end
    end.

instruction(Ctx = #{agent := {agent_instance_ref, Ns, Anchor, Instance}, key := Key}, Goal) ->
    {Canonical, _, _} = erlog_int:term_instance(Goal, 0),
    {ok, Text} = quod_client_goal_parser:format(Canonical),
    {ok, InstanceText} = quod_client_goal_parser:format_clause(Instance),
    {ok, Bytes} = quod_client_goal:encode(#{network_identity => maps:get(network, Ctx, <<42:256>>),
        agent_namespace => Ns, agent_genesis_anchor => Anchor,
        agent_instance_text => InstanceText, signing_public_key => Key,
        operation_id => crypto:strong_rand_bytes(32),
        not_after_ms => maps:get(target_expiry, Ctx, quod_time:now_ms() + 20000),
        mode => execute, parser_version => 3, goal_text => Text}),
    {request(Ctx, read, {personal_instruction_accept, Bytes, {'Signature'}}), Bytes}.

request(Ctx, Mode, Goal) ->
    {Canonical, _, _} = erlog_int:term_instance(Goal, 0),
    {ok, Text} = quod_client_goal_parser:format(Canonical),
    request_text(Ctx, Mode, Text).

request_text(Ctx = #{human := {agent_instance_ref, Ns, Anchor, Instance}, human_pair := {Key, _} = Pair}, Mode, Text) ->
    {ok, InstanceText} = quod_client_goal_parser:format(Instance),
    {ok, Bytes} = quod_client_goal:encode(#{network_identity => maps:get(network, Ctx, <<42:256>>),
        agent_namespace => Ns, agent_genesis_anchor => Anchor,
        agent_instance_text => InstanceText, signing_public_key => Key,
        operation_id => crypto:strong_rand_bytes(32), not_after_ms => quod_time:now_ms() + 25000,
        mode => Mode, parser_version => 3, goal_text => Text}),
    {Bytes, quod_identity:sign(Bytes, quod_identity:key_term(Pair))}.

submit({Bytes, Signature}) -> quod_client_goal_ingress:submit(Bytes, Signature).
instruct(#{session := Session}, Action, {Bytes, Signature}) ->
    quod_client_goal_ingress:instruction(Action, Session, Bytes, Signature, {127,0,0,1}).

session(Pair) -> session(Pair, <<42:256>>).

session({Key, _} = Pair, Network) ->
    Nonce = crypto:strong_rand_bytes(32),
    {ok, C} = quod_client_auth:issue_challenge(Key, Nonce, {127,0,0,1}),
    Id = maps:get(challenge_id, C),
    {ok, Bytes} = quod_client_auth:challenge_bytes(Network,
        application:get_env(quod, node_pubkey, undefined), Id, Key, Nonce,
        maps:get(server_nonce, C), maps:get(expires_ms, C)),
    {ok, Session} = quod_client_auth:complete_challenge(Id,
        quod_identity:sign(Bytes, quod_identity:key_term(Pair))),
    maps:get(session_id, Session).

installed(Agent) ->
    receive {agent_installed, Runtime, Pid, #{reference := Agent, epoch := 1}, _} -> {Runtime, Pid}
    after 5000 -> error(agent_not_installed) end.
