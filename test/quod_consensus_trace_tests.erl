-module(quod_consensus_trace_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include("quod_ledger.hrl").

owner_turns_cover_real_statem_calls_casts_and_info_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Ns = <<"trace:owner:", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
        Domain = quod_simplex:consensus_domain(Ns, <<0:256>>),
        Root = {quod_ledger:initial_era({Ns, <<0:256>>}), 0, <<0:256>>},
        State = quod_simplex:test_state(#{ns => Ns, trace_owner_turns => true,
                    eng => quod_simplex:eng_new(Domain, [], {Root, 0})}),
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
                    history_head => {0, <<0:256>>}, slot => 0,
                    eng => quod_simplex:eng_new(Domain, [],
                      {{quod_ledger:initial_era({Ns, <<0:256>>}), 0, <<0:256>>}, 0})}),
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

relayed_block_uses_only_opt_in_owner_ancestry_test() ->
    with_request_spans(fun(Unsampled, Sampled, _Parent) ->
        Ns = <<"trace:relay-owner">>, Slot = 23, OwnHash = <<1:256>>, OtherHash = <<2:256>>,
        S = quod_simplex:test_state(#{ns => Ns,
              local_proposal => {Slot, OwnHash, [Sampled]}}),
        Before = quod_trace:context(), Once = make_ref(),
        %% An unrelated ambient request must not become the relayed block's parent.
        quod_trace:with_context(Sampled, fun() ->
            quod_trace:with_owner_turn(#{'quod.namespace' => Ns}, fun() ->
                ?assertEqual(unchanged, quod_simplex:test_trace_block(
                    Slot, OtherHash, <<"relay.owner.work">>, S,
                    fun() -> self() ! {called, Once}, unchanged end)),
                ok = quod_simplex:test_trace_block_event(
                    Slot, OtherHash, <<"relay.owner.boundary">>, #{}, S),
                ?assertError(original_work_error, quod_simplex:test_trace_block(
                    Slot, OtherHash, <<"relay.owner.failure">>, S,
                    fun() -> error(original_work_error) end)),
                %% A valid unsampled caller still controls its own block's sampling.
                Unrecorded = quod_simplex:test_state_set(
                    local_proposal, {Slot, OwnHash, [Unsampled]}, S),
                ok = quod_simplex:test_trace_block_event(
                    Slot, OwnHash, <<"relay.owner.unsampled">>, #{}, Unrecorded)
            end)
        end),
        assert_called_once(Once),
        Turn = take_owner_turn(Ns),
        lists:foreach(fun(Name) ->
            Span = quod_trace_tests:take_span(Name, Turn#span.trace_id),
            ?assertEqual(Turn#span.span_id, Span#span.parent_span_id),
            ?assertEqual(binary:encode_hex(OtherHash, lowercase),
                         owner_attribute('quod.consensus.block_hash', Span)),
            ?assertEqual([], otel_links:list(Span#span.links))
        end, [<<"relay.owner.work">>, <<"relay.owner.boundary">>, <<"relay.owner.failure">>]),
        ?assertEqual(Before, quod_trace:context()),
        receive {quod_test_span, #span{name = <<"relay.owner.unsampled">>}} -> error(sampling_overridden)
        after 0 -> ok end
    end).

consensus_boundary_survives_ended_proof_parent_test() ->
    quod_trace_tests:with_tracer(fun() ->
        {Ctx, Parent} = quod_trace:start_span(otel_ctx:new(), <<"ended.proof">>, internal, #{}),
        quod_trace:finish_span(Parent, ok),
        Proof = quod_trace_tests:take_span(<<"ended.proof">>),
        %% Dedicated pinned SDK control: ended spans cannot accept events.
        ?assertNot(quod_trace:add_event(Ctx, <<"too.late">>, #{})),
        Ns = <<"trace:ended-proof">>, Slot = 11, Hash = crypto:hash(sha256, <<"begin">>),
        S = quod_simplex:test_state(#{ns => Ns, local_proposal => {Slot, Hash, [Ctx]}}),
        Name = <<"consensus.parent_verdict_received">>,
        ok = quod_simplex:test_trace_block_event(Slot, Hash, Name, #{}, S),
        Boundary = quod_trace_tests:take_span(Name, otel_span:trace_id(Parent)),
        assert_parent_and_block(Boundary, Parent, Ns, Slot, Hash),
        ?assert(Boundary#span.start_time >= Proof#span.end_time),
        ?assert(Boundary#span.end_time >= Boundary#span.start_time),
        ?assertEqual(<<"boundary">>, owner_attribute('quod.consensus.observation', Boundary)),
        %% No mutation of the ended proof and no long-lived synthetic round.
        ?assertEqual([], otel_events:list(Proof#span.events)),
        Other = crypto:hash(sha256, <<"other">>),
        ok = quod_simplex:test_trace_block_event(Slot, Other, <<"wrong.boundary">>, #{}, S),
        receive {quod_test_span, #span{name = <<"wrong.boundary">>}} -> error(wrong_block_parent)
        after 0 -> ok end
    end).

consensus_boundary_keeps_all_participating_links_test() ->
    with_request_spans(fun(Unsampled, Sampled, Parent) ->
        Ns = <<"trace:boundary-links">>, Slot = 12, Hash = crypto:hash(sha256, <<"shared">>),
        S = quod_simplex:test_state(#{ns => Ns, local_proposal => {Slot, Hash, [Unsampled, Sampled]}}),
        ok = quod_simplex:test_trace_block_event(Slot, Hash, <<"boundary.links">>, #{}, S),
        Span = quod_trace_tests:take_span(<<"boundary.links">>),
        assert_parent_and_block(Span, Parent, Ns, Slot, Hash),
        [Link] = otel_links:list(Span#span.links),
        ?assertEqual(otel_span:span_id(otel_tracer:current_span_ctx(Unsampled)), Link#link.span_id),
        OnlyUnsampled = quod_simplex:test_state(#{ns => Ns, local_proposal => {Slot, Hash, [Unsampled]}}),
        ok = quod_simplex:test_trace_block_event(Slot, Hash, <<"boundary.unsampled">>, #{}, OnlyUnsampled),
        receive {quod_test_span, #span{name = <<"boundary.unsampled">>}} -> error(sampling_overridden)
        after 0 -> ok end
    end).

foreign_validation_worker_inherits_trace_and_records_terminal_verdict_test_() ->
    [{atom_to_list(Case), fun() ->
        with_certified_history(fun(State0, Transaction, Ref, Receipt) ->
            with_request_spans(fun(Unsampled, Sampled, Parent) ->
                exercise_foreign_validation(
                  Case, State0, Transaction, Ref, Receipt, Unsampled, Sampled, Parent)
            end)
        end)
      end} || Case <- [valid, invalid, owner]].

exercise_foreign_validation(Case, State0, Transaction, Ref0, Receipt0,
                            Unsampled, Sampled, Parent) ->
    %% Co-hosted history still goes through the real spawned foreign-reference
    %% worker and certified-history verifier. Only transport is unnecessary;
    %% no verifier result is stubbed and a changed exact block hash is refused.
    Ref = case Case of
              Case when Case =:= valid; Case =:= owner -> Ref0;
              invalid -> setelement(6, Ref0, crypto:hash(sha256, <<"wrong-block">>))
          end,
    {ok, {Ns, _}, _, _} = quod_dtx:certified_ref_binding(Ref),
    Receipt = Receipt0#transaction{evidence = {applications, [{Ref, Transaction}]}},
    ?assertEqual([{transaction, Ref}], quod_transaction:required_references(Receipt)),
    Slot = 3,
    Hash = crypto:hash(sha256, <<"receipt-validation-proposal">>),
    {Started, ExpectedParent} = case Case of
        owner ->
            OwnerStarted = quod_trace:with_owner_turn(#{'quod.namespace' => Ns}, fun() ->
                quod_simplex:test_start_content_validation([Receipt], 0, Slot, Hash, State0)
            end),
            Turn = take_owner_turn(Ns),
            {OwnerStarted, #span_ctx{trace_id = Turn#span.trace_id, span_id = Turn#span.span_id}};
        _ ->
            State = quod_simplex:test_state_set(
                      local_proposal, {Slot, Hash, [Unsampled, Sampled]}, State0),
            {quod_simplex:test_start_content_validation([Receipt], 0, Slot, Hash, State), Parent}
    end,
    {Hash, {content_foreign, Worker, Monitor}, _, _, _} =
        quod_simplex:test_dtx_round(Slot, Started),
    try
        Expected = case Case of
                       Case when Case =:= valid; Case =:= owner -> valid;
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
        Span = quod_trace_tests:take_span(<<"quod.consensus.foreign_validation">>,
                                        otel_span:trace_id(ExpectedParent)),
        assert_parent_and_block(Span, ExpectedParent, Ns, Slot, Hash),
        [Finished] = [Event || Event = #event{name = Name} <- otel_events:list(Span#span.events),
                               Name =:= <<"consensus.foreign_validation_finished">>],
        ?assertEqual(case Case of invalid -> <<"invalid">>; _ -> <<"valid">> end, maps:get(
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
        with_certified_history(fun(State0, _Transaction, Ref, Receipt) ->
            {ok, {Ns, Anchor}, _, _} = quod_dtx:certified_ref_binding(Ref),
            %% This is a callback-state fixture, not candidate wire admission:
            %% the worker authenticates the actual signed entry and its AM3
            %% result in the real store. No verifier answer is supplied.
            Projection = quod_simplex:test_state_projection(State0),
            {Era, 1, _} = Root = maps:get(protocol_root, Projection),
            {ok, Block} = quod_ledger:new_block({Era, 2}, Root, {batch, [Receipt]}, 2),
            Hash = quod_simplex:block_hash(Block),
            Eng0 = quod_simplex:eng_new(quod_simplex:consensus_domain(Ns, Anchor), [], {Root, 2}),
            {Eng, _} = quod_simplex:eng_offer({block, Block}, Eng0),
            State = quod_simplex:test_state_set(eng, Eng, State0),
            true = quod_reg:reg({quod_prolog, Ns}),
            StartedAt = quod_time:mono_ms(),
            Started = quod_simplex:test_start_content_validation([Receipt], 2, 2, Hash, State),
            {Hash, {content_foreign, Worker, Monitor}, _, _, _} =
                quod_simplex:test_dtx_round(2, Started),
            try
                receive
                    {content_foreign_verdict, {2, Hash}, Worker, Deadline, valid} ->
                        ?assert(Deadline >= StartedAt + 6000),
                        ?assert(Deadline =< quod_time:mono_ms() + 6000),
                        ?assert(Deadline > quod_time:mono_ms()),
                        case When of
                            timely -> ok;
                            expired -> receive after max(0, Deadline - quod_time:mono_ms()) -> ok end
                        end,
                        Done = quod_simplex:on_content_foreign_verdict(
                          2, Hash, Worker, Deadline, valid, Started),
                        case When of
                            timely ->
                                ?assertMatch({Hash, content, _, _, _},
                                             quod_simplex:test_dtx_round(2, Done)),
                                receive
                                    {'$gen_cast', {content_verdict_req, [Receipt], 2,
                                                  3, _, {2, Hash}, _}} -> ok
                                after 1000 -> error(valid_result_not_applied)
                                end;
                            expired ->
                                ?assertMatch({none, none, _, _, _},
                                             quod_simplex:test_dtx_round(2, Done)),
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
    %% Reuse real claim/application/AM3 bytes. As in the shared fixture, the
    %% committee view is an owner input, not consensus-admission evidence.
    quod_operation_fixture:with(1, fun(F) ->
        #{target := {Ns, Anchor}, store := Store, projection := Projection0,
          application := Transaction, certified_target_ref := Ref,
          node_identity := Signer = #{pubkey := Pub}} = F,
        IndexDir = filename:join("/tmp", "quod-trace-index-" ++
            binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
        {ok, Index} = quod_dtx_phase_index:open(IndexDir, Ns),
        {ok, Projection, _} = quod_ct:history_advance(
            {Ns, Anchor}, maps:get(entry, F), Projection0, Index),
        Root = maps:get(protocol_root, Projection),
        Domain = quod_simplex:consensus_domain(Ns, Anchor),
        true = quod_reg:reg({quod_simplex, Ns}),
        try
            Base = quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
                     self => Pub, id => Signer, store => Store, slot => 2,
                     last_applied => 2, sync => ready, prolog_ready => true,
                     validators => [Pub], consensus_domain => Domain,
                     phase_index => Index,
                     eng => quod_simplex:eng_new(Domain, [Pub], {Root, 2})}),
            State = quod_simplex:test_install_projection(Projection, Base),
            Fun(State, Transaction, Ref, maps:get(completion, F))
        after
            true = gproc:unreg(quod_reg:name({quod_simplex, Ns})),
            ok = quod_dtx_phase_index:close(Index),
            ok = file:del_dir_r(IndexDir)
        end
    end).
