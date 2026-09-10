-module(quod_consensus_trace_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include("quod_ledger.hrl").

owner_turns_cover_real_statem_calls_casts_and_info_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Ns = <<"trace:owner:", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
        State = quod_simplex:test_state(#{ns => Ns, trace_owner_turns => true}),
        %% Enter the production callback module, not a synthetic tracing callback.
        %% The three events below have ordinary inert/read-only production arms.
        Owner = proc_lib:spawn(fun() ->
            gen_statem:enter_loop(quod_simplex, [], running, State)
        end),
        Monitor = monitor(process, Owner),
        try
            ?assertEqual([], gen_statem:call(Owner, get_committee)),
            Call = take_owner_turn(Ns),
            gen_statem:cast(Owner, {sync_done, self(), unused}),
            Cast = take_owner_turn(Ns),
            Owner ! dtx_drive,
            Info = take_owner_turn(Ns),
            ?assertEqual([<<"call">>, <<"cast">>, <<"other">>],
                         [owner_attribute('quod.owner.event', S) || S <- [Call, Cast, Info]]),
            ?assertEqual([1, 2, 3],
                         [owner_attribute('quod.owner.sequence', S) || S <- [Call, Cast, Info]]),
            ?assertEqual(1, length(lists:usort(
                         [owner_attribute('quod.owner.incarnation', S) || S <- [Call, Cast, Info]]))),
            ?assert(Call#span.end_time =< Cast#span.start_time),
            ?assert(Cast#span.end_time =< Info#span.start_time),
            %% The SDK diagnostic context never leaks into the protocol state.
            ?assertEqual({running, State}, sys:get_state(Owner))
        after
            exit(Owner, kill),
            receive {'DOWN', Monitor, process, Owner, _} -> ok
            after 2000 -> error(owner_did_not_stop)
            end
        end
    end).

owner_turn_disabled_preserves_callback_and_emits_nothing_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Ns = <<"trace:owner-off:", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
        State = quod_simplex:test_state(#{ns => Ns}),
        From = {self(), make_ref()},
        ?assertEqual({keep_state, State, [{reply, From, []}]},
                     quod_simplex:running({call, From}, get_committee, State)),
        ?assertEqual({keep_state, State},
                     quod_simplex:running(info, dtx_drive, State)),
        receive
            {quod_test_span, #span{name = <<"quod.consensus.owner_turn">>}} ->
                error(disabled_owner_trace_emitted)
        after 0 -> ok
        end
    end).

owner_turn_covers_keep_progress_steps_and_timeout_actions_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    quod_trace_tests:with_tracer(fun() ->
        Ns = <<"trace:owner-timeout:", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
        Domain = quod_simplex:consensus_domain(Ns, <<0:256>>),
        State = quod_simplex:test_state(#{ns => Ns, consensus_domain => Domain,
                    eng => quod_simplex:eng_new(Domain, [], 0)}),
        %% A stale batch event still takes the real keep_progress path. Compare
        %% complete results/actions with diagnostics disabled, not a shape oracle.
        Expected = quod_simplex:running({timeout, batch}, {flush_batch, 1}, State),
        TracedState = quod_simplex:test_state_set(trace_owner_turns, true, State),
        {keep_state, TracedResult, Actions} =
            quod_simplex:running({timeout, batch}, {flush_batch, 1}, TracedState),
        ?assertEqual(Expected, {keep_state,
            quod_simplex:test_state_set(trace_owner_turns, false, TracedResult), Actions}),
        Turn = take_owner_turn(Ns),
        ?assertEqual(<<"timeout_batch">>, owner_attribute('quod.owner.event', Turn)),
        Steps = take_owner_steps(Turn#span.trace_id, []),
        Names = [owner_attribute('quod.owner.step', S) || S <- Steps],
        lists:foreach(fun(Name) -> ?assert(lists:member(Name, Names)) end,
                      [<<"readiness">>, <<"operation_recovery">>, <<"drain">>, <<"head_reconcile">>]),
        lists:foreach(fun(S) ->
            ?assertEqual(Turn#span.span_id, S#span.parent_span_id),
            ?assert(S#span.start_time >= Turn#span.start_time),
            ?assert(S#span.end_time =< Turn#span.end_time)
        end, Steps)
    end).

take_owner_turn(Ns) ->
    receive
        {quod_test_span, S = #span{name = <<"quod.consensus.owner_turn">>}} ->
            case owner_attribute('quod.namespace', S) of
                Ns -> S;
                _ -> take_owner_turn(Ns)
            end
    after 2000 -> error({missing_owner_turn, Ns})
    end.

take_owner_steps(TraceId, Acc) ->
    receive
        {quod_test_span, S = #span{name = <<"quod.consensus.owner_step">>, trace_id = TraceId}} ->
            take_owner_steps(TraceId, [S | Acc])
    after 0 -> lists:reverse(Acc)
    end.

owner_attribute(Key, Span) -> maps:get(Key, otel_attributes:map(Span#span.attributes)).

mixed_receipt_claim_block_uses_recording_parent_once_test() ->
    with_request_spans(fun(Unsampled, Sampled, Parent) ->
        Slot = 23,
        Hash = crypto:hash(sha256, <<"mixed-receipt-claim">>),
        Ns = <<"trace:mixed-block">>,
        State = quod_simplex:test_state(
                  #{ns => Ns, local_proposal => {Slot, Hash, [Unsampled, Sampled]}}),
        Once = make_ref(),
        ?assertEqual(unchanged,
          quod_simplex:test_trace_block(
            Slot, Hash, <<"consensus.shared.test">>, State,
            fun() -> self() ! {called, Once}, unchanged end)),
        assert_called_once(Once),
        Span = quod_trace_tests:take_span(<<"consensus.shared.test">>),
        assert_parent_and_block(Span, Parent, Ns, Slot, Hash),
        [Link] = otel_links:list(Span#span.links),
        Receipt = otel_tracer:current_span_ctx(Unsampled),
        ?assertEqual(otel_span:trace_id(Receipt), Link#link.trace_id),
        ?assertEqual(otel_span:span_id(Receipt), Link#link.span_id)
    end).

same_slot_other_hash_does_not_claim_request_trace_test() ->
    with_request_spans(fun(Unsampled, Sampled, _Parent) ->
        Slot = 23,
        OwnHash = crypto:hash(sha256, <<"own-proposal">>),
        OtherHash = crypto:hash(sha256, <<"other-proposal">>),
        State = quod_simplex:test_state(
                  #{local_proposal => {Slot, OwnHash, [Unsampled, Sampled]}}),
        Once = make_ref(),
        ?assertEqual(unchanged,
          quod_simplex:test_trace_block(
            Slot, OtherHash, <<"consensus.wrong-hash.test">>, State,
            fun() -> self() ! {called, Once}, unchanged end)),
        assert_called_once(Once),
        receive
            {quod_test_span, #span{name = <<"consensus.wrong-hash.test">>}} ->
                error(other_block_attributed_to_request)
        after 0 -> ok
        end
    end).

foreign_validation_worker_inherits_trace_and_records_terminal_verdict_test_() ->
    [{atom_to_list(Case), fun() ->
        with_certified_history(fun(State0, Transaction, Ref) ->
            with_request_spans(fun(Unsampled, Sampled, Parent) ->
                exercise_foreign_validation(
                  Case, State0, Transaction, Ref, Unsampled, Sampled, Parent)
            end)
        end)
      end} || Case <- [valid, invalid]].

exercise_foreign_validation(Case, State0, Transaction, Ref0,
                            Unsampled, Sampled, Parent) ->
    %% Co-hosted history still goes through the real spawned foreign-reference
    %% worker and certified-history verifier. Only transport is unnecessary;
    %% no verifier result is stubbed and a changed exact block hash is refused.
    Ref = case Case of
              valid -> Ref0;
              invalid -> setelement(6, Ref0, crypto:hash(sha256, <<"wrong-block">>))
          end,
    {ok, {Ns, _}, _, _} = quod_dtx:certified_ref_binding(Ref),
    TargetRef = quod_transaction:stable_ref(Ref),
    Receipt = #transaction{
                 role = {remote_complete, unused_operation, unused_request, TargetRef},
                 evidence = {Ref, Transaction}, foreign_reads = []},
    ?assertEqual([{transaction, Ref}], quod_transaction:required_references(Receipt)),
    Slot = 3,
    Hash = crypto:hash(sha256, <<"receipt-validation-proposal">>),
    State = quod_simplex:test_state_set(
              local_proposal, {Slot, Hash, [Unsampled, Sampled]}, State0),
    Started = quod_simplex:test_start_content_validation([Receipt], 0, Slot, Hash, State),
    {Hash, {content_foreign, Worker, Monitor}, _, _, _} =
        quod_simplex:test_dtx_round(Slot, Started),
    try
        Expected = case Case of
                       valid -> valid;
                       invalid -> {invalid, foreign_reference}
                   end,
        receive
            {content_foreign_verdict, {Slot, Hash}, Worker, Deadline, Verdict} ->
                ?assert(Deadline > quod_time:mono_ms()),
                ?assertEqual(Expected, Verdict)
        after 3000 -> error(foreign_verdict_not_delivered)
        end,
        receive {'DOWN', Monitor, process, Worker, Reason} -> ?assertEqual(normal, Reason)
        after 3000 -> error(foreign_validation_worker_not_retired)
        end,
        Span = quod_trace_tests:take_span(<<"quod.consensus.foreign_validation">>),
        assert_parent_and_block(Span, Parent, Ns, Slot, Hash),
        [Finished] = [Event || Event = #event{name = Name} <- otel_events:list(Span#span.events),
                               Name =:= <<"consensus.foreign_validation_finished">>],
        ?assertEqual(atom_to_binary(Case), maps:get(
          'quod.validation.verdict', otel_attributes:map(Finished#event.attributes))),
        ?assertEqual(1, maps:get('quod.validation.transactions',
                                otel_attributes:map(Span#span.attributes)))
    after
        _ = erlang:demonitor(Monitor, [flush]),
        case is_process_alive(Worker) of
            true ->
                CleanupMonitor = erlang:monitor(process, Worker),
                exit(Worker, kill),
                receive {'DOWN', CleanupMonitor, process, Worker, _} -> ok end;
            false -> ok
        end
    end.

assert_parent_and_block(Span, Parent, Ns, Slot, Hash) ->
    ?assertEqual(otel_span:trace_id(Parent), Span#span.trace_id),
    ?assertEqual(otel_span:span_id(Parent), Span#span.parent_span_id),
    Attributes = otel_attributes:map(Span#span.attributes),
    ?assertEqual(Ns, maps:get('quod.namespace', Attributes)),
    ?assertEqual(Slot, maps:get('quod.consensus.slot', Attributes)),
    ?assertEqual(binary:encode_hex(Hash, lowercase),
                 maps:get('quod.consensus.block_hash', Attributes)).

%% The real worker borrows the already captured local view: calling back into
%% this registered owner while it waits here would fail the positive control.
%% Hold an actual successful packet until its original deadline, not a forged
%% success or a newly granted short test allowance.
foreign_validation_queued_success_respects_original_deadline_test_() ->
    [{atom_to_list(When), {timeout, 12, fun() ->
        with_certified_history(fun(State0, Transaction, Ref) ->
            {ok, {Ns, Anchor}, _, _} = quod_dtx:certified_ref_binding(Ref),
            Receipt = #transaction{
              role = {remote_complete, unused_operation, unused_request,
                      quod_transaction:stable_ref(Ref)},
              evidence = {Ref, Transaction}, foreign_reads = []},
            %% This is a callback-state fixture, not candidate wire admission:
            %% only the receipt's reference binding is under test. The worker
            %% still authenticates the actual signed entry in the real store.
            Block = #block{slot = 3, parent = 2, payload = {batch, [Receipt]},
                           timestamp = 0, block_bytes = <<"queue-deadline-fixture">>},
            Hash = quod_simplex:block_hash(Block),
            Eng0 = quod_simplex:eng_new(quod_simplex:consensus_domain(Ns, Anchor), [], 2),
            {Eng, _} = quod_simplex:eng_offer({block, Block}, Eng0),
            State = quod_simplex:test_state_set(eng, Eng, State0),
            true = quod_reg:reg({quod_prolog, Ns}),
            StartedAt = quod_time:mono_ms(),
            Started = quod_simplex:test_start_content_validation([Receipt], 0, 3, Hash, State),
            {Hash, {content_foreign, Worker, Monitor}, _, _, _} =
                quod_simplex:test_dtx_round(3, Started),
            try
                receive
                    {content_foreign_verdict, {3, Hash}, Worker, Deadline, valid} ->
                        ?assert(Deadline >= StartedAt + 6000),
                        ?assert(Deadline =< quod_time:mono_ms() + 6000),
                        ?assert(Deadline > quod_time:mono_ms()),
                        case When of
                            timely -> ok;
                            expired -> receive after max(0, Deadline - quod_time:mono_ms()) -> ok end
                        end,
                        Done = quod_simplex:on_content_foreign_verdict(
                          3, Hash, Worker, Deadline, valid, Started),
                        case When of
                            timely ->
                                ?assertMatch({Hash, content, _, _, _},
                                             quod_simplex:test_dtx_round(3, Done)),
                                receive
                                    {'$gen_cast', {content_verdict_req, [Receipt], 0,
                                                  3, _, {3, Hash}, _}} -> ok
                                after 1000 -> error(valid_result_not_applied)
                                end;
                            expired ->
                                ?assertMatch({none, none, _, _, _},
                                             quod_simplex:test_dtx_round(3, Done)),
                                receive
                                    {'$gen_cast', {content_verdict_req, _, _, _, _, _, _}} ->
                                        error(expired_success_published)
                                after 0 -> ok
                                end
                        end
                after 3000 -> error(real_worker_did_not_return_valid)
                end
            after
                _ = erlang:demonitor(Monitor, [flush]),
                true = gproc:unreg(quod_reg:name({quod_prolog, Ns}))
            end
        end)
    end}} || When <- [timely, expired]].

assert_called_once(Ref) ->
    receive {called, Ref} -> ok after 0 -> error(work_not_called) end,
    receive {called, Ref} -> error(work_called_twice) after 0 -> ok end.

with_request_spans(Fun) ->
    quod_trace_tests:with_tracer(fun() ->
        Unsampled = quod_trace:extract([{<<"traceparent">>,
          <<"00-123456789abcdef0123456789abcdef0-123456789abcdef0-00">>}]),
        {Sampled, Parent} = quod_trace:start_span(
                              otel_ctx:new(), <<"consensus.claim.parent">>, internal, #{}),
        try Fun(Unsampled, Sampled, Parent)
        after
            quod_trace:finish_span(Parent, ok),
            _ = quod_trace_tests:take_span(<<"consensus.claim.parent">>)
        end
    end).

with_certified_history(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Ns = <<"trace:certified:", Suffix/binary>>,
    Dir = filename:join("/tmp", "quod-consensus-trace-" ++ binary_to_list(Suffix)),
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    GenesisTx = quod_simplex:test_genesis_tx(
                  #{node_id => Pub, mode => create, committee => [],
                    node_addr => {"127.0.0.1", 19000}, genesis_diff => []},
                  Ns, Pub, crypto:strong_rand_bytes(32)),
    {ok, Genesis} = quod_ledger:new_entry(1, {batch, [GenesisTx]}, 0, none),
    {ok, GenesisBlock} = quod_ledger:block_from_entry(Genesis),
    Anchor = quod_simplex:block_hash(GenesisBlock),
    Identity = {Ns, Anchor},
    {ok, [_], Projection1} = quod_catchup:verify_forward(
                               Ns, Anchor, quod_simplex:history_projection(Identity),
                               1, [Genesis]),
    {ok, AuthorBinding} = quod_simplex:history_binding(Identity, Pub, Projection1),
    {ok, Goal} = quod_durable_term:encode_goal(trace_fact),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Unsigned = quod_transaction:bind_id(Identity, #transaction{
                 origin = Identity, proof_id = <<1:256>>, plan_digest = <<2:256>>,
                 goal = Goal, result = Result,
                 diff = [{assert, {{trace_fact, committed}, true}}], read_check = #{},
                 author = Pub, author_seq = 1, submitted_at = 1, sig = none}),
    {ok, Transaction} = quod_transaction:sign(AuthorBinding, Unsigned, Signer),
    {ok, Block} = quod_ledger:new_block(2, 1, {batch, [Transaction]}, 0),
    BlockHash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    #share{sig = Signature} = quod_simplex:make_share(Domain, commit, 2, BlockHash, Signer),
    Entry = quod_ledger:entry(Block, #cert{kind = commit, slot = 2,
                 block_hash = BlockHash, sigs = [{Pub, Signature}]}),
    {ok, [_], Projection} = quod_catchup:verify_forward(Ns, Anchor, Projection1, 2, [Entry]),
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Entry, Transaction),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    try
        {ok, Store} = quod_ledger_store:append(Store0, [Genesis, Entry]),
        true = quod_reg:reg({quod_simplex, Ns}),
        try
            Base = quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
                     self => Pub, id => Signer, store => Store, slot => 2,
                     last_applied => 2, sync => ready, prolog_ready => true,
                     validators => [Pub], consensus_domain => Domain,
                     eng => quod_simplex:eng_new(Domain, [Pub], 2)}),
            State = quod_simplex:test_install_projection(Projection, Base),
            Fun(State, Transaction, Ref)
        after
            true = gproc:unreg(quod_reg:name({quod_simplex, Ns}))
        end
    after
        quod_ledger_store:close(Store0),
        _ = file:del_dir_r(Dir)
    end.
