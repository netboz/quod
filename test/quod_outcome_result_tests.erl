-module(quod_outcome_result_tests).
-include_lib("eunit/include/eunit.hrl").
-export([assert_unchanged_reads/3, assert_no_generation/1, restart_outcome_owner/1]).

lost_reply_recovers_selected_bindings_test_() ->
    [{atom_to_list(Lane), {timeout, 60, fun() -> recover_bindings(Lane) end}}
     || Lane <- [ordinary, foreign, atomic]].

recover_bindings(Lane) ->
    {Key, _} = Pair = quod_identity:generate(),
    Ns = <<"host-test-agent">>, Other = <<"outcome-result-target">>,
    Creation = creation_terms(),
    Facts = [{agent_key, {human_user, test_agent}, Key, active},
             {can_invoke, {'_'}, {agent_instance_ref, Ns, {'_'}, {human_user, test_agent}}, {'_'}, Ns}
             | Creation],
    quod_agent_hosting_tests:with_host(fun(#{directory := Dir, identity := Node}) ->
        Target = {Ns, Anchor} = {Ns, quod_simplex:genesis_hash(Ns)},
        Sup = case Lane of
            ordinary -> none;
            _ -> quod_agent_hosting_tests:start_ontology(Other, Dir, Node, [],
                         [{can_invoke, {'_'}, {'_'}, {'_'}, {'_'}} | Creation])
        end,
        try
            Text = case Lane of
                ordinary -> <<"create_result(Ref), _ = hidden.">>;
                foreign -> <<"'outcome-result-target'::create_result(Ref), _ = hidden.">>;
                atomic -> <<"create_result(Ref), _ = hidden, 'outcome-result-target'::assertz(touched).">>
            end,
            F = quod_ct:signed_goal_fixture(#{network => <<42:256>>, target => Target,
                key_pair => Pair, goal_text => Text, operation_id => crypto:strong_rand_bytes(32),
                deadline => quod_time:now_ms() + 30000}),
            Bytes = maps:get(request_bytes, F), Signature = maps:get(signature, F),
            {{ok, Evidence, {normalized, {committed, [Binding], LiveRef}}}, Generated} =
                observe_generation(fun() -> quod_client_goal_ingress:submit(Bytes, Signature) end),
            ?assertEqual(#{{quod_common_primitives, instance_id_1, 3} => 1,
                           {quod_common_primitives, draw_3, 3} => 1,
                           {quod_common_primitives, assert_instance, 4} => 2}, Generated),
            {ok, Expected} = quod_client_result:decode_binding(Binding),
            ?assertEqual([<<"Ref">>], [Name || {Name, _} <- Expected]),
            [{<<"Ref">>, Reference = {entity_ref, Writer, WriterAnchor, Id}}] = Expected,
            ?assertEqual(26, byte_size(Id)),
            ?assertEqual(quod_simplex:genesis_hash(Writer), WriterAnchor),
            case Lane of
                ordinary -> ?assertMatch({transaction, Ns, Anchor, _}, LiveRef);
                foreign -> ?assertMatch({transaction, Other, _, _}, LiveRef);
                atomic -> ?assertMatch({group_outcome, {group, Ns, Anchor, _, _, _}, _, _}, LiveRef)
            end,
            %% The reply is discarded by the consumer. Only original signed
            %% bytes enter resolution; no ID, current membership or live proof.
            {ok, Evidence, {operation_outcome, Claim, Outcome}} = published_result(F),
            Status = case Lane of foreign -> completed; _ -> committed end,
            ?assertMatch(#{status := Status, bindings := Expected}, Outcome),
            {200, Json} = quod_client_http:signed_goal_result(
                {ok, Evidence, {operation_outcome, Claim, Outcome}}),
            {200, LiveJson} = quod_client_result:http_normalized(
                Evidence, {committed, [Binding], LiveRef}),
            ?assertEqual(maps:get(bindings, LiveJson), maps:get(bindings, Json)),
            authenticated_lookup(F, Pair, Outcome),
            case Lane of
                foreign ->
                    {ok, #{outcome := Compact}} = quod_prolog:outcome_snapshot(Other, LiveRef, 1000),
                    endpoint_result(Other, Compact#{bindings => Expected});
                _ -> endpoint_result(Ns, Outcome)
            end,
            %% Completion is published before its async source receipt. Finish
            %% that original write before measuring unchanged observations.
            case Lane of foreign -> await_receipt(F); _ -> ok end,
            assert_unchanged_reads(F, Outcome, Lane),
            Saved = {',', {instance_of, artifact, Id},
                     {',', {attribute, Id, name, <<"Harbor">>}, {initialized, Id}}},
            ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Writer, Saved)),
            assert_no_generation(fun() -> restart_outcome_owner(Writer) end),
            ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Writer, Saved)),
            commit(Writer, {',', {retract, {created, Reference}},
                           {retract, {instance_of, artifact, Id}}}),
            ?assertMatch(fail, quod_prolog:prove_ro(Writer, {created, Reference})),
            assert_no_generation(fun() ->
                restart_outcome_owner(Ns),
                case Lane of foreign -> restart_outcome_owner(Other); _ -> ok end
            end),
            ?assertMatch({ok, _, {operation_outcome, _, Outcome}}, resolve(F)),
            assert_unchanged_reads(F, Outcome, Lane),
            %% A new committed result remains visible after unchanged reads.
            Next = quod_ct:signed_goal_fixture(#{network => <<42:256>>, target => Target,
                key_pair => Pair, goal_text => <<"N = 2, assertz(later_result(N)).">>,
                operation_id => crypto:strong_rand_bytes(32)}),
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, submit(Next)),
            ?assertMatch({ok, _, {operation_outcome, _,
                         #{status := committed, bindings := [{<<"N">>, 2}]}}}, resolve(Next)),
            missing_evidence_stays_uncertain(Ns, F, Outcome, Lane)
        after
            case Sup of none -> ok; _ -> quod_agent_hosting_tests:stop_ontology(Sup) end
        end
    end, Facts).

creation_terms() ->
    {ok, Terms} = erlog_io:read_string_terms(
      "class_permission(artifact,create,allow). "
      "have_attribute(artifact,name,binary,default_from(artifact_name)). "
      "artifact_name(I,Name) :- draw(<<\"fixture\">>,<<\"place\">>,<<\"neutral\">>,I,Name). "
      "isa(<<\"fixture\">>,<<\"thing\">>). "
      "pool(<<\"fixture\">>,<<\"place\">>,<<\"neutral\">>,listed). "
      "listed(<<\"fixture\">>,<<\"place\">>,<<\"neutral\">>,[<<\"Harbor\">>]). "
      "create_result(R) :- assert(instance_of(artifact,I)), "
      "assertz(initialized(I)), trigger_event(built(I)), "
      "current_ontology_identity(N,A), R = entity_ref(N,A,I), assertz(created(R))."),
    quod_prolog:read_terms(filename:join(code:priv_dir(quod), "ontologies/quod_names.pl")) ++ Terms.

assert_no_generation(Fun) ->
    {_, Counts} = observe_generation(Fun),
    ?assertEqual(#{}, Counts).

observe_generation(Fun) ->
    Parent = self(), Tag = make_ref(),
    Collector = spawn(fun() -> count_reads(Parent, Tag, #{}) end),
    Trace = trace:session_create(construction_recovery, Collector, []),
    try
        [trace:function(Trace, MFA, true, [local]) || MFA <-
            [{quod_common_primitives, instance_id_1, 3},
             {quod_common_primitives, draw_3, 3},
             {quod_common_primitives, assert_instance, 4}]],
        trace:process(Trace, all, true, [call, arity]),
        Result = Fun(),
        Barrier = trace:delivered(Trace, all),
        receive {trace_delivered, all, Barrier} -> ok after 1000 -> error(trace_not_delivered) end,
        Collector ! {finish, self()},
        Counts = receive {Tag, C} -> C after 1000 -> error(no_work_counts) end,
        {Result, Counts}
    after trace:session_destroy(Trace), Collector ! stop end.

commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_prolog:execute(Ns, Goal)).
submit(F) -> quod_client_goal_ingress:submit(maps:get(request_bytes, F), maps:get(signature, F)).
resolve(F) -> quod_client_goal_ingress:resolve_operation(maps:get(request_bytes, F), maps:get(signature, F)).

await_receipt(F) ->
    {Ns, _} = maps:get(target, F),
    true = quod_reg:subscribe({runtime, Ns}),
    try await_receipt(F, quod_time:mono_ms() + 5000)
    after quod_reg:unsubscribe({runtime, Ns}) end.

await_receipt(F, Deadline) ->
    case resolve(F) of
        {ok, _, {operation_outcome, #{operation_state := terminal}, _}} -> ok;
        _ ->
            receive {projection_advanced, _, _} -> await_receipt(F, Deadline)
            after max(0, Deadline - quod_time:mono_ms()) -> error(receipt_not_published) end
    end.

published_result(F) ->
    {Ns, _} = maps:get(target, F),
    true = quod_reg:subscribe({runtime, Ns}),
    try await_result(F, quod_time:mono_ms() + 5000)
    after quod_reg:unsubscribe({runtime, Ns}) end.

await_result(F, Deadline) ->
    case resolve(F) of
        {ok, _, {operation_outcome, _, #{status := Status}}} = Result
          when Status =:= committed; Status =:= completed -> Result;
        {ok, _, {operation_outcome, _, #{status := pending}}} ->
            receive {projection_advanced, _, _} -> await_result(F, Deadline)
            after max(0, Deadline - quod_time:mono_ms()) -> error(result_not_published) end
    end.

authenticated_lookup(F, Pair, Outcome) ->
    Peer = {127, 0, 0, 1},
    Session = session(Pair, Peer),
    ?assertMatch({ok, _, {operation_outcome, _, Outcome}},
        quod_client_goal_ingress:resolve_operation(Session, maps:get(request_bytes, F),
                                                   maps:get(signature, F), Peer)),
    {Ns, Anchor} = maps:get(target, F),
    DuplicateRef = {group, Ns, Anchor, <<1:256>>, <<2:256>>, <<3:256>>},
    ?assertMatch({ok, _, {operation_outcome, _, Outcome}},
        quod_client_goal_ingress:resolve_operation(Session, maps:get(request_bytes, F),
                                                   maps:get(signature, F), Peer, DuplicateRef)),
    OtherSession = session(quod_identity:generate(), Peer),
    ?assertEqual({error, session_principal_mismatch},
        quod_client_goal_ingress:resolve_operation(OtherSession, maps:get(request_bytes, F),
                                                   maps:get(signature, F), Peer)),
    ?assertEqual({error, invalid_signature},
        quod_client_goal_ingress:resolve_operation(maps:get(request_bytes, F), <<0:512>>)),
    Changed = quod_ct:signed_goal_fixture(#{network => <<42:256>>, target => maps:get(target, F),
        key_pair => Pair, operation_id => maps:get(operation_id, F), goal_text => <<"true.">>}),
    ?assertEqual({error, operation_conflict}, resolve(Changed)),
    Ref = maps:get(ref, Outcome),
    ?assertMatch({error, wrong_genesis_anchor},
                 quod_prolog:outcome_snapshot(Ns, setelement(3, Ref, <<0:256>>), 1000)),
    ?assertMatch({ok, #{outcome := not_found}},
                 quod_prolog:outcome_snapshot(Ns, setelement(2, Ref, <<"other-scope">>), 1000)),
    ?assertMatch({error, _}, quod_outcome:result(
        #{status => committed, height => maps:get(height, Outcome, 1),
          ref => {transaction, Ns, <<0:256>>, <<1:256>>}}, quod_time:mono_ms() + 1000)),
    ?assertNotEqual(<<0:256>>, Anchor).

session({Key, _} = Pair, Peer) ->
    Nonce = crypto:strong_rand_bytes(32),
    {ok, Challenge} = quod_client_auth:issue_challenge(Key, Nonce, Peer),
    Id = maps:get(challenge_id, Challenge),
    {ok, Bytes} = quod_client_auth:challenge_bytes(<<42:256>>,
        application:get_env(quod, node_pubkey, undefined), Id, Key, Nonce,
        maps:get(server_nonce, Challenge), maps:get(expires_ms, Challenge)),
    {ok, Session} = quod_client_auth:complete_challenge(Id,
        quod_identity:sign(Bytes, quod_identity:key_term(Pair))),
    maps:get(session_id, Session).

endpoint_result(Ns, Outcome) ->
    {ok, #{identity := Target, projection := Projection, slot := Height}} =
        quod_simplex:history_view(Ns, any, quod_time:mono_ms() + 1000),
    Committee = maps:get(committee_id, Projection), Id = crypto:strong_rand_bytes(16),
    Request = {outcome, Id, maps:get(ref, Outcome), Committee, Height},
    ?assertMatch({ok, {outcome, Id, Target, Committee, _, Outcome}, []},
                 quod_simplex:dtx_endpoint_local(Ns, Request, [], 2000)).

restart_outcome_owner(Ns) ->
    true = quod_reg:subscribe({runtime, Ns}),
    Old = quod_reg:where({quod_prolog, Ns}),
    try
        Monitor = monitor(process, Old),
        exit(Old, kill),
        receive {'DOWN', Monitor, process, Old, _} -> ok after 5000 -> error(owner_survived) end,
        receive {replay_ready, {Next, _}, _} when Next =/= Old -> ok
        after 10000 -> error(replay_not_ready) end
    after quod_reg:unsubscribe({runtime, Ns}) end,
    ?assertNotEqual(Old, quod_reg:where({quod_prolog, Ns})).

assert_unchanged_reads(F, Outcome, Lane) when is_map(F) ->
    {Ns, _} = maps:get(target, F),
    Owners = case Lane of ordinary -> [Ns]; _ -> [Ns, <<"outcome-result-target">>] end,
    %% Trace descendants too: foreign result verification reads its source
    %% claim and target evidence in workers (three exact reads per lookup).
    Reads = case Lane of atomic -> 0; foreign -> 9; ordinary -> 3 end,
    assert_unchanged_reads(Owners, fun() ->
        ?assertMatch({ok, _, {operation_outcome, _, Outcome}}, resolve(F))
    end, Reads);

assert_unchanged_reads(Owners, Resolve, Reads) when is_list(Owners), is_function(Resolve, 0) ->
    Parent = self(), Tag = make_ref(),
    Collector = spawn(fun() -> count_reads(Parent, Tag, #{}) end),
    Trace = trace:session_create(outcome_result_reads, Collector, []),
    Patterns = [{quod_ledger_store, read_at, 3}, {quod_ledger_store, open_ro_snapshot, 1},
        {quod_ledger_store, open, 3},
        {quod_ledger_store, open_ro, 3}, {quod_ledger_store, fold, 5},
        {quod_ledger_store, fold_groups, 3}, {quod_prolog, apply_entry, 3},
        {dets, insert, 2}, {dets, sync, 1}, {file, write, 2}, {file, pwrite, 3},
        {file, sync, 1}, {file, datasync, 1},
        {quod_common_primitives, instance_id_1, 3}, {quod_common_primitives, draw_3, 3}],
    Pids = [self() | [quod_reg:where({Kind, Owner}) || Owner <- Owners,
                     Kind <- [quod_prolog, quod_simplex]]],
    try
        [trace:function(Trace, MFA, true, [local]) || MFA <- Patterns],
        [trace:process(Trace, P, true, [call, arity, set_on_spawn]) || P <- Pids],
        [Resolve() || _ <- lists:seq(1, 3)],
        Barrier = trace:delivered(Trace, all),
        receive {trace_delivered, all, Barrier} -> ok after 1000 -> error(trace_not_delivered) end,
        Collector ! {finish, self()},
        Counts = receive {Tag, C} -> C after 1000 -> error(no_work_counts) end,
        Expected = case Reads of
            0 -> #{};
            _ -> #{{quod_ledger_store, read_at, 3} => Reads,
                   {quod_ledger_store, open_ro_snapshot, 1} => Reads}
        end,
        ?assertEqual(Expected, Counts)
    after trace:session_destroy(Trace), Collector ! stop end.

count_reads(Parent, Tag, Counts) ->
    receive
        {trace, _, call, MFA} -> count_reads(Parent, Tag, maps:update_with(MFA, fun(N) -> N + 1 end, 1, Counts));
        {finish, Parent} -> Parent ! {Tag, Counts}, count_reads(Parent, Tag, Counts);
        stop -> ok
    end.

missing_evidence_stays_uncertain(Ns, F, Outcome, Lane) when Lane =/= atomic ->
    case Lane of
        ordinary ->
            ?assertMatch({error, _}, quod_outcome:result(
                Outcome#{height := 1}, quod_time:mono_ms() + 1000));
        foreign ->
            {ok, View} = quod_simplex:history_view(Ns, any, quod_time:mono_ms() + 1000),
            Op = maps:get(ref, Outcome),
            ?assertMatch({error, _}, quod_simplex:operation_claim_evidence(
                View, 1, Op, quod_time:mono_ms() + 1000)),
            ?assertMatch({error, _}, quod_simplex:operation_claim_evidence(
                View, 1, Op, quod_time:mono_ms() - 1))
    end,
    Simplex = quod_reg:where({quod_simplex, Ns}),
    sys:replace_state(Simplex, fun(S) ->
        true = gproc:unreg(quod_reg:name({quod_simplex, Ns})), S
    end),
    try ?assertMatch({ok, _, {operation_pending, _}}, resolve(F))
    after sys:replace_state(Simplex, fun(S) -> true = quod_reg:reg({quod_simplex, Ns}), S end) end;
missing_evidence_stays_uncertain(_Ns, _F, _Outcome, atomic) -> ok.
