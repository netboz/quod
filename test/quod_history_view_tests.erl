-module(quod_history_view_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

future_view_waits_for_sufficient_progress_without_capturing_prefix_test() ->
    with_owner(fun(Owner, Ns, Identity, Entry, _Claim, _OperationRef) ->
        H = (quod_ledger:entry_view(Entry))#entry.index,
        observe_history(Owner),
        D = quod_time:mono_ms() + 3000,
        Reader = future_reader(Identity, H + 2, D),
        ?assertEqual({pending, H}, observed_history(Owner, H + 2, D)),
        %% Duplicate and below-target progress cannot initiate another query.
        quod_reg:publish({committed, Ns}, {certified_head, Ns, H}),
        append_owner(Owner, H + 1),
        append_owner(Owner, H + 2),
        {ok, View} = future_result(Reader),
        Expected = H + 2,
        ?assertMatch(#{owner := Owner, identity := Identity, slot := Expected}, View),
        ?assertEqual({ok, View}, observed_history(Owner, H + 2, D)),
        receive {history_observed, Owner, _, _, _} -> error(extra_capture)
        after 0 -> ok end
    end).

future_view_owner_loss_returns_unavailable_without_replacement_test() ->
    with_owner(fun(Owner, _Ns, Identity, Entry, _Claim, _OperationRef) ->
        H = (quod_ledger:entry_view(Entry))#entry.index,
        observe_history(Owner),
        D = quod_time:mono_ms() + 3000,
        Reader = future_reader(Identity, H + 1, D),
        ?assertEqual({pending, H}, observed_history(Owner, H + 1, D)),
        stop_owner(Owner),
        ?assertEqual({error, not_ready}, future_result(Reader))
    end).

future_view_uses_the_original_deadline_test() ->
    with_owner(fun(Owner, Ns, Identity, Entry, _Claim, _OperationRef) ->
        H = (quod_ledger:entry_view(Entry))#entry.index,
        observe_history(Owner),
        D = quod_time:mono_ms() + 100,
        Reader = future_reader(Identity, H + 1, D),
        ?assertEqual({pending, H}, observed_history(Owner, H + 1, D)),
        quod_reg:publish({committed, Ns}, {certified_head, Ns, H}),
        ?assertEqual({error, timeout}, future_result(Reader)),
        ?assert(quod_time:mono_ms() >= D),
        receive {history_observed, Owner, _, _, _} -> error(deadline_renewed)
        after 0 -> ok end
    end).

future_view_keeps_an_existing_progress_subscription_test() ->
    with_owner(fun(_Owner, Ns, Identity, Entry, _Claim, _OperationRef) ->
        H = (quod_ledger:entry_view(Entry))#entry.index,
        Key = {committed, Ns},
        true = quod_reg:subscribe(Key),
        try
            Before = gproc:get_value(quod_reg:prop(Key)),
            ?assertMatch({ok, _}, quod_simplex:history_view_at(
                                   Identity, H, quod_time:mono_ms() + 1000)),
            ?assertEqual(Before, gproc:get_value(quod_reg:prop(Key)))
        after quod_reg:unsubscribe(Key) end
    end).

future_view_does_not_keep_a_temporary_subscription_test() ->
    with_owner(fun(_Owner, Ns, Identity, Entry, _Claim, _OperationRef) ->
        H = (quod_ledger:entry_view(Entry))#entry.index,
        ?assertMatch({ok, _}, quod_simplex:history_view_at(
                               Identity, H, quod_time:mono_ms() + 1000)),
        ?assertError(badarg, gproc:get_value(quod_reg:prop({committed, Ns})))
    end).

future_view_different_anchor_is_not_local_evidence_test() ->
    with_owner(fun(_Owner, Ns, _Identity, _Entry, _Claim, _OperationRef) ->
        ?assertEqual({error, invalid_identity},
                     quod_simplex:history_view_at(
                       {Ns, <<19:256>>}, 1, quod_time:mono_ms() + 1000))
    end).

absent_desired_exact_owner_is_not_foreign_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"history-view:absent-desired">>,
    Anchor = <<97:256>>,
    Saved = application:get_env(quod, namespace_desired),
    application:set_env(quod, namespace_desired,
                        #{content => #{Ns => #{genesis_hash => Anchor}}}),
    try
        D = quod_time:mono_ms() + 1000,
        ?assertEqual({error, not_ready},
                     quod_simplex:history_view_at({Ns, Anchor}, 1, D)),
        ?assertEqual({error, not_hosted},
                     quod_simplex:history_view_at({Ns, <<98:256>>}, 1, D))
    after
        case Saved of
            {ok, Value} -> application:set_env(quod, namespace_desired, Value);
            undefined -> application:unset_env(quod, namespace_desired)
        end
    end.

observe_history(Owner) ->
    Owner ! {observe_history, self()},
    receive {observing_history, Owner} -> ok
    after 1000 -> error(history_observer_not_installed) end.

observed_history(Owner, Slot, D) ->
    receive {history_observed, Owner, {committed, Slot}, D, Reply} -> Reply
    after 1000 -> error(history_query_not_observed) end.

future_reader(Identity, Slot, D) ->
    Parent = self(),
    spawn(fun() ->
        Parent ! {future_view_result, self(),
                  quod_simplex:history_view_at(Identity, Slot, D)}
    end).

future_result(Reader) ->
    receive {future_view_result, Reader, Result} -> Result
    after 1500 -> error(future_view_stalled) end.

append_owner(Owner, Expected) ->
    Owner ! {append_noop, self()},
    receive {appended, Owner, Expected} -> ok
    after 1000 -> error(owner_did_not_append) end.

%% These tests exercise the public evidence reader and the real owner-view
%% constructor over a durable sparse index. The owner fixture is deliberately
%% not a consensus simulation; certificates use real keys, while append and
%% apply ordering itself remains covered by the live scope/consensus suites.
evidence_reads_borrow_one_view_without_scanning_test() ->
    with_owner(
      fun(Owner, Ns, Identity, Entry, Claim, OperationRef) ->
          {ok, ExpectedRef} = quod_dtx:certified_entry_ref(Identity, Entry, Claim),
          Slot = (quod_ledger:entry_view(Entry))#entry.index,
          Parent = self(),
          Reader = spawn(fun() ->
              receive go -> ok end,
              Deadline = quod_time:mono_ms() + 3000,
              Results = [quod_simplex:operation_claim_evidence(Ns, Slot, OperationRef, Deadline),
                         quod_simplex:transaction_evidence(Ns, Slot, Claim#transaction.tx_id, Deadline),
                         quod_simplex:transaction_evidence(Ns, Slot, <<0:256>>, Deadline)],
              Parent ! {evidence_results, self(), Results},
              receive stop -> ok end
          end),
          MFAs = [{quod_ledger_store, open_ro, 2},
                  {quod_ledger_store, open_ro, 3},
                  {quod_ledger_store, open_ro_snapshot, 1}],
          lists:foreach(fun(MFA) -> 1 = erlang:trace_pattern(MFA, true, []) end, MFAs),
          1 = erlang:trace(Reader, true, [call, {tracer, self()}]),
          try
              Reader ! go,
              receive
                  {evidence_results, Reader, Results} ->
                      ?assertEqual([{ok, ExpectedRef, Claim}, {ok, ExpectedRef, Claim},
                                    {error, not_found}], Results)
              after 3000 -> error(evidence_reader_stalled)
              end,
              TraceRef = erlang:trace_delivered(Reader),
              Counts = evidence_trace_counts(Reader, TraceRef, #{scans => 0, snapshots => 0}),
              ?assertEqual(#{scans => 0, snapshots => 3}, Counts),
              ?assertEqual(true, is_process_alive(Owner))
          after
              _ = erlang:trace(Reader, false, [call]),
              lists:foreach(fun(MFA) -> erlang:trace_pattern(MFA, false, []) end, MFAs),
              Reader ! stop
          end
      end).

captured_view_is_bounded_and_cannot_recapture_from_replacement_test() ->
    with_owner(
      fun(Owner, Ns, Identity, Entry, _Claim, _OperationRef) ->
          Deadline = quod_time:mono_ms() + 3000,
          {ok, View = #{snapshot := Snapshot, slot := Height}} =
              quod_simplex:history_view(Identity, committed, Deadline),
          ?assertEqual((quod_ledger:entry_view(Entry))#entry.index, Height),
          ?assert(quod_simplex:history_view_live(View)),
          Owner ! {append_noop, self()},
          receive {appended, Owner, Next} -> ?assertEqual(Height + 1, Next)
          after 1000 -> error(owner_did_not_append)
          end,
          {ok, #{slot := NewHeight}} = quod_simplex:history_view({Owner, Identity}, committed, Deadline),
          ?assertEqual(Height + 1, NewHeight),
          {ok, Reader} = quod_ledger_store:open_ro_snapshot(Snapshot),
          try
              ?assertEqual(Height, quod_ledger_store:last(Reader)),
              ?assertEqual(not_found, quod_ledger_store:read_at(Reader, Height + 1))
          after quod_ledger_store:close(Reader)
          end,
          stop_owner(Owner),
          ?assertNot(quod_simplex:history_view_live(View)),
          ?assertEqual({error, not_ready}, quod_simplex:history_view(Identity, committed, Deadline)),
          Parent = self(),
          Replacement = spawn(fun() ->
              true = quod_reg:reg({quod_simplex, Ns}),
              Parent ! {replacement_ready, self()},
              receive
                  {'$gen_call', _, _} -> Parent ! wrong_owner_called;
                  stop -> ok
              end
          end),
          receive {replacement_ready, Replacement} -> ok
          after 1000 -> error(replacement_not_ready)
          end,
          try
              ?assertEqual({error, not_ready},
                           quod_simplex:history_view({Owner, Identity}, committed, Deadline)),
              ?assertNot(quod_simplex:history_view_live(View)),
              receive wrong_owner_called -> error(recapture_switched_owner)
              after 0 -> ok
              end
          after stop_owner(Replacement)
          end
      end).

busy_same_owner_capture_uses_the_original_budget_test() ->
    with_owner(
      fun(Owner, _Ns, Identity, _Entry, _Claim, _OperationRef) ->
          Deadline = quod_time:mono_ms() + 3000,
          {Reader, Monitor} = paused_capture(Owner, Identity, Deadline),
          try
              %% Exceed the removed independent one-second cutoff while the
              %% real request budget and the exact registered owner survive.
              receive {capture_result, Reader, Early} -> error({early_capture, Early})
              after 1200 -> ok
              end,
              Owner ! resume_capture,
              receive {capture_result, Reader, Result} ->
                  ?assertMatch({ok, #{owner := Owner, identity := Identity}}, Result)
              after 1000 -> error(capture_did_not_recover)
              end
          after stop_reader(Reader, Monitor)
          end
      end).

expired_original_budget_neither_recaptures_nor_renews_test() ->
    with_owner(
      fun(Owner, _Ns, Identity, _Entry, _Claim, _OperationRef) ->
          Deadline = quod_time:mono_ms() + 100,
          {Reader, Monitor} = paused_capture(Owner, Identity, Deadline),
          try
              receive {capture_result, Reader, Result} ->
                  ?assertEqual({error, timeout}, Result)
              after 1000 -> error(expired_capture_stalled)
              end,
              %% Expiration is checked in the owner too: the queued capture
              %% must not open a fresh snapshot when this same PID resumes.
              Owner ! resume_capture,
              receive {owner_capture_result, Owner, OwnerResult} ->
                  ?assertEqual({error, timeout}, OwnerResult)
              after 1000 -> error(owner_did_not_reject_expired_capture)
              end,
              ?assertEqual({error, timeout},
                           quod_simplex:history_view(Identity, committed, Deadline)),
              ?assertEqual({error, invalid_identity},
                           quod_simplex:history_view(Identity, committed, infinity))
          after stop_reader(Reader, Monitor)
          end
      end).

source_death_wakes_an_inflight_capture_test() ->
    with_owner(
      fun(Owner, _Ns, Identity, _Entry, _Claim, _OperationRef) ->
          {Reader, Monitor} = paused_capture(
                                Owner, Identity, quod_time:mono_ms() + 5000),
          try
              exit(Owner, kill),
              receive {capture_result, Reader, Result} ->
                  ?assertEqual({error, not_ready}, Result)
              after 1000 -> error(source_death_did_not_wake_capture)
              end
          after stop_reader(Reader, Monitor)
          end
      end).

empty_committed_prefix_is_not_execution_readiness_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8)),
    Ns = <<"empty-history-view:", Suffix/binary>>,
    Identity = {Ns, crypto:strong_rand_bytes(32)},
    Dir = filename:join("/tmp", binary_to_list(Ns)),
    {ok, Store} = quod_ledger_store:open(Ns, Dir),
    true = quod_reg:reg({quod_simplex, Ns}),
    try
        Pub = crypto:strong_rand_bytes(32),
        State = quod_simplex:test_state(
            #{ns => Ns, genesis_hash => element(2, Identity),
              store => Store, slot => 0, last_applied => 0,
              self => Pub, validators => [Pub], sync => ready, prolog_ready => true}),
        Deadline = quod_time:mono_ms() + 1000,
        {ok, #{slot := 0, snapshot := Snapshot}} =
            quod_simplex:test_local_history_view(Identity, committed, Deadline, State),
        {ok, Reader} = quod_ledger_store:open_ro_snapshot(Snapshot),
        try
            ?assertEqual(0, quod_ledger_store:last(Reader)),
            ?assertEqual(not_found, quod_ledger_store:read_at(Reader, 1))
        after quod_ledger_store:close(Reader)
        end,
        %% Even a ready-marked state cannot lend execution/certification
        %% readiness before a real genesis has been installed.
        ?assertEqual({error, not_ready},
                     quod_simplex:test_local_history_view(Identity, any, Deadline, State)),
        ?assertEqual({error, not_ready},
                     quod_simplex:test_local_history_view(Identity, validator, Deadline, State))
    after
        gproc:unreg(quod_reg:name({quod_simplex, Ns})),
        quod_ledger_store:close(Store),
        _ = file:del_dir_r(Dir)
    end.

paused_capture(Owner, Identity, Deadline) ->
    Parent = self(),
    Owner ! {pause_capture, Parent},
    {Reader, Monitor} = spawn_monitor(fun() ->
        Result = quod_simplex:history_view({Owner, Identity}, committed, Deadline),
        Parent ! {capture_result, self(), Result}
    end),
    receive {capture_waiting, Owner, Deadline} -> {Reader, Monitor}
    after 1000 -> error(capture_was_not_submitted)
    end.

stop_reader(Reader, Monitor) ->
    exit(Reader, kill),
    receive {'DOWN', Monitor, process, Reader, _} -> ok
    after 1000 -> error(reader_did_not_stop)
    end.

evidence_trace_counts(Reader, TraceRef, Counts) ->
    receive
        {trace, Reader, call, {quod_ledger_store, open_ro, _}} ->
            evidence_trace_counts(Reader, TraceRef, Counts#{scans := maps:get(scans, Counts) + 1});
        {trace, Reader, call, {quod_ledger_store, open_ro_snapshot, _}} ->
            evidence_trace_counts(Reader, TraceRef,
                                  Counts#{snapshots := maps:get(snapshots, Counts) + 1});
        {trace_delivered, Reader, TraceRef} -> Counts
    after 3000 -> error(trace_delivery_stalled)
    end.

with_owner(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8)),
    Ns = <<"history-view:", Suffix/binary>>,
    Dir = filename:join("/tmp", "quod-history-view-" ++ binary_to_list(Suffix)),
    Identity = {Ns, crypto:strong_rand_bytes(32)},
    Fixture = quod_ct:remote_operation_fixture(#{target => Identity}),
    Claim = maps:get(claim, Fixture),
    {ok, #{operation_ref := OperationRef}} = quod_transaction:request_claim(Claim),
    Signer = maps:get(node_identity, Fixture),
    Height = 513, %% crosses two sparse-index checkpoints; not a production bound
    {ok, Block} = quod_ledger:new_block(Height, Height - 1, {batch, [Claim]}, 0),
    Hash = quod_simplex:block_hash(Block),
    #share{sig = Sig} = quod_simplex:make_share(
                         quod_simplex:consensus_domain(Ns, element(2, Identity)),
                         commit, Height, Hash, Signer),
    Pub = maps:get(pubkey, Signer),
    Entry = quod_ledger:entry(Block, #cert{kind = commit, slot = Height,
                                         block_hash = Hash, sigs = [{Pub, Sig}]}),
    Parent = self(),
    {Owner, Monitor} = spawn_monitor(fun() ->
        {ok, Empty} = quod_ledger_store:open(Ns, Dir),
        Prefix = [begin {ok, E} = quod_ledger:new_entry(I, noop, 0, none), E end
                  || I <- lists:seq(1, Height - 1)],
        {ok, Store} = quod_ledger_store:append(Empty, Prefix ++ [Entry]),
        try
            true = quod_reg:reg({quod_simplex, Ns}),
            State = quod_simplex:test_state(
                      #{ns => Ns, genesis_hash => element(2, Identity),
                        store => Store, slot => Height, last_applied => Height - 1,
                        self => Pub, validators => [Pub], sync => ready,
                        prolog_ready => true}),
            Parent ! {owner_ready, self()},
            owner_loop(State, Store)
        after quod_ledger_store:close(Store)
        end
    end),
    try
        receive {owner_ready, Owner} -> ok;
                {'DOWN', Monitor, process, Owner, Reason} -> error({owner_setup_failed, Reason})
        after 3000 -> error(owner_setup_stalled)
        end,
        Fun(Owner, Ns, Identity, Entry, Claim, OperationRef)
    after
        stop_owner(Owner),
        erlang:demonitor(Monitor, [flush]),
        _ = file:del_dir_r(Dir)
    end.

owner_loop(State, Store) -> owner_loop(State, Store, none).

owner_loop(State, Store, Observer) ->
    receive
        {'$gen_call', From, {history_view, Identity, Requirement, Deadline}} ->
            Reply = quod_simplex:test_local_history_view(
                      Identity, Requirement, Deadline, State),
            gen:reply(From, Reply),
            case Observer of
                none -> ok;
                _ -> Observer ! {history_observed, self(), Requirement, Deadline, Reply}
            end,
            owner_loop(State, Store, Observer);
        {observe_history, Caller} ->
            Caller ! {observing_history, self()},
            owner_loop(State, Store, Caller);
        {pause_capture, Caller} ->
            receive
                {'$gen_call', From, {history_view, Identity, Requirement, Deadline}} ->
                    Caller ! {capture_waiting, self(), Deadline},
                    receive resume_capture -> ok end,
                    Result = quod_simplex:test_local_history_view(
                               Identity, Requirement, Deadline, State),
                    Caller ! {owner_capture_result, self(), Result},
                    gen:reply(From, Result),
                    owner_loop(State, Store, Observer)
            end;
        {append_noop, Caller} ->
            Next = quod_ledger_store:last(Store) + 1,
            {ok, Entry} = quod_ledger:new_entry(Next, noop, 0, none),
            {ok, Store1} = quod_ledger_store:append(Store, [Entry]),
            State1 = quod_simplex:test_state_set(
                       slot, Next, quod_simplex:test_state_set(store, Store1, State)),
            Ns = quod_ledger_store:namespace(Store1),
            quod_reg:publish({committed, Ns}, {certified_head, Ns, Next}),
            Caller ! {appended, self(), Next},
            owner_loop(State1, Store1, Observer);
        stop -> ok
    end.

stop_owner(Pid) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! stop,
    receive {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 -> exit(Pid, kill),
        receive {'DOWN', Ref, process, Pid, _} -> ok end
    end.
