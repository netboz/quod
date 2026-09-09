-module(quod_foreign_job_tracing_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

%% These fixtures use the real SDK and foreign owner/verifier. Only the page
%% byte source and span exporter are the existing local test substitutes.
%% Worker completion is the export barrier, never a sleep or inferred zero.

exact_cold_and_warm_cache_trace_test() ->
    with_fixture(
      fun(_Fixture, Base) -> Base end,
      fun(Fixture, Dir, Owner, Fetch) ->
          ?assertMatch({ok, #{phase := finalize}}, explicit(Fixture)),
          quod_foreign_log_tests:stop_owner(Owner),
          Restarted = quod_foreign_log_tests:start_owner(Dir, Fetch),
          try
              {ColdResult, Cold, ColdSpans} = traced_request(
                <<"test.foreign.exact.cold">>, fun() -> explicit(Fixture) end),
              ?assertMatch({ok, #{phase := finalize}}, ColdResult),
              ColdAttrs = attrs(Cold),
              ?assertEqual(0, maps:get('quod.foreign.resident_start_height', ColdAttrs)),
              ?assertEqual(2, maps:get('quod.foreign.disk_start_height', ColdAttrs)),
              ?assertEqual(2, maps:get('quod.foreign.disk_replayed_entries', ColdAttrs)),
              ?assertEqual(0, maps:get('quod.foreign.network_advance_verified_entries', ColdAttrs)),
              ?assertEqual(2, maps:get('quod.foreign.final_verified_height', ColdAttrs)),
              ?assertNot(maps:is_key('quod.foreign.verified_suffix', ColdAttrs)),
              ?assertEqual(maps:get(ns, Fixture), maps:get('quod.namespace', ColdAttrs)),
              assert_stages(Cold, ColdSpans,
                [cache_open, cache_reconstruction, cache_replay,
                 checkpoint_compare, phase_suspend, ledger_suspend,
                 exact_lookup, exact_validate, worker_handoff]),
              {WarmResult, Warm, WarmSpans} = traced_request(
                <<"test.foreign.exact.warm">>, fun() -> explicit(Fixture) end),
              ?assertMatch({ok, #{phase := finalize}}, WarmResult),
              WarmAttrs = attrs(Warm),
              ?assertEqual(2, maps:get('quod.foreign.resident_start_height', WarmAttrs)),
              ?assertEqual(0, maps:get('quod.foreign.cold_opens', WarmAttrs)),
              ?assertEqual(0, maps:get('quod.foreign.disk_replayed_entries', WarmAttrs)),
              assert_stages(Warm, WarmSpans,
                [cache_open, ledger_resume, phase_resume, phase_suspend,
                 ledger_suspend, exact_lookup, exact_validate, worker_handoff]),
              assert_no_stage(cache_reconstruction, WarmSpans),
              assert_no_stage(cache_replay, WarmSpans)
          after
              quod_foreign_log_tests:stop_owner(Restarted)
          end
      end).

routed_exact_has_the_same_worker_children_test() ->
    with_fixture(
      fun(_Fixture, Base) -> Base end,
      fun(Fixture, _Dir, _Owner, _Fetch) ->
          {Result, Worker, Spans} = traced_request(
            <<"test.foreign.routed">>,
            fun() -> quod_foreign_log:verify_reference(
                       maps:get(ref, Fixture), finalize, contact(Fixture), none, 5000)
            end),
          ?assertMatch({ok, #{phase := finalize}}, Result),
          ?assertEqual(2, maps:get('quod.foreign.network_advance_verified_entries', attrs(Worker))),
          assert_stages(Worker, Spans,
            [exact_route, cache_open, page_fetch, page_verify,
             exact_lookup, exact_validate, phase_suspend, ledger_suspend, worker_handoff])
      end).

changed_checkpoint_trace_rejects_reconstruction_before_recovery_test() ->
    with_fixture(
      fun(_Fixture, Base) -> Base end,
      fun(Fixture, Dir, Owner, Fetch) ->
          ?assertMatch({ok, #{phase := finalize}}, explicit(Fixture)),
          quod_foreign_log_tests:stop_owner(Owner),
          Identity = {maps:get(ns, Fixture), maps:get(anchor, Fixture)},
          CacheNs = quod_foreign_log:cache_namespace(Identity),
          Path = filename:join(quod_ledger_store:ns_dir(Dir, CacheNs), "checkpoint.term"),
          {ok, Blob} = file:read_file(Path),
          Checkpoint = binary_to_term(Blob, [safe]),
          Projection = element(7, Checkpoint),
          Changed = Projection#{timestamp := maps:get(timestamp, Projection) + 1},
          ?assert(quod_foreign_log:valid_projection(Changed, Identity)),
          ok = file:write_file(Path, term_to_binary(setelement(7, Checkpoint, Changed), [deterministic])),
          Restarted = quod_foreign_log_tests:start_owner(Dir, Fetch),
          try
              {Result, Worker, Spans} = traced_request(
                <<"test.foreign.checkpoint.changed">>, fun() -> explicit(Fixture) end),
              %% The false checkpoint is rejected, but the existing certified
              %% recovery path may still authenticate the public reference.
              ?assertMatch({ok, #{phase := finalize}}, Result),
              Compare = one(<<"quod.foreign.checkpoint_compare">>, Spans),
              ?assertEqual(<<"rejected">>, maps:get('quod.foreign.reason', attrs(Compare))),
              Reconstruction = one(<<"quod.foreign.cache_reconstruction">>, Spans),
              ?assertEqual(<<"cache_corrupt">>,
                           maps:get('quod.foreign.reason', attrs(Reconstruction))),
              ?assertEqual(2, maps:get('quod.foreign.cold_opens', attrs(Worker))),
              ?assertEqual(2, maps:get('quod.foreign.disk_replayed_entries', attrs(Worker))),
              ?assertEqual(2, maps:get('quod.foreign.network_advance_verified_entries', attrs(Worker))),
              assert_stages(Worker, Spans,
                [cache_prepare, cache_open, cache_reconstruction, cache_replay,
                 checkpoint_compare, cache_cleanup, page_verify,
                 exact_validate, worker_handoff])
          after
              quod_foreign_log_tests:stop_owner(Restarted)
          end
      end).

queued_callers_share_one_parented_worker_without_ambient_context_test() ->
    Parent = self(),
    Gate = atomics:new(1, []),
    Token = make_ref(),
    with_fixture(
      fun(_Fixture, Base) ->
          fun(Peer, Endpoint, Ns, From, To) ->
              Parent ! {shared_fetch, Token, From,
                        otel_ctx:get_value(private_foreign_trace_sentinel)},
              case atomics:compare_exchange(Gate, 1, 0, 1) of
                  ok ->
                      Parent ! {shared_blocker, Token, self()},
                      receive {release_shared_blocker, Token} -> ok end;
                  _ -> ok
              end,
              Base(Peer, Endpoint, Ns, From, To)
          end
      end,
      fun(Fixture, _Dir, Owner, _Fetch) ->
          GenesisEntry = hd(maps:get(chain, Fixture)),
          {batch, [Genesis]} = element(3, quod_ledger:entry_view(GenesisEntry)),
          {ok, GenesisRef} = quod_dtx:certified_entry_ref(
                              {maps:get(ns, Fixture), maps:get(anchor, Fixture)},
                              GenesisEntry, Genesis),
          {Peer, Endpoint} = contact(Fixture),
          Blocker = owner_request(Owner, undefined,
                      {verify, Peer, Endpoint, GenesisRef, transaction, 5000}),
          Held = receive {shared_blocker, Token, Pid} -> Pid
                 after 2000 -> error(shared_blocker_not_started)
                 end,
          {FirstCtx, FirstSpan} = quod_trace:start_span(
                                   otel_ctx:new(), <<"test.foreign.shared.first">>, internal, #{}),
          {SecondCtx, SecondSpan} = quod_trace:start_span(
                                     otel_ctx:new(), <<"test.foreign.shared.second">>, internal, #{}),
          Sentinel = <<"foreign-private-shared-context-sentinel">>,
          Request = {verify_reference, maps:get(ref, Fixture), finalize,
                      contact(Fixture), none, 5000},
          First = owner_request(Owner,
                    otel_ctx:set_value(FirstCtx, private_foreign_trace_sentinel, Sentinel), Request),
          ?assertMatch(#{pending := 1, queued := 1}, quod_foreign_log:stats()),
          Second = owner_request(Owner,
                     otel_ctx:set_value(SecondCtx, private_foreign_trace_sentinel, Sentinel), Request),
          ?assertMatch(#{pending := 1, queued := 1}, quod_foreign_log:stats()),
          %% An ended participant remains a valid launch-time link, not a
          %% reason to split the semantic job or reparent its worker later.
          quod_trace:finish_span(SecondSpan, ok),
          Held ! {release_shared_blocker, Token},
          ?assertMatch({reply, {ok, #{slot := 1}}}, gen_server:wait_response(Blocker, 5000)),
          ?assertMatch({reply, {ok, #{phase := finalize}}}, gen_server:wait_response(First, 5000)),
          ?assertMatch({reply, {ok, #{phase := finalize}}}, gen_server:wait_response(Second, 5000)),
          quod_trace:finish_span(FirstSpan, ok),
          Worker = quod_trace_tests:take_span(
                     <<"quod.foreign.verification_worker">>, otel_span:trace_id(FirstSpan)),
          ?assertEqual(otel_span:span_id(FirstSpan), Worker#span.parent_span_id),
          [Link] = otel_links:list(Worker#span.links),
          ?assertEqual(otel_span:trace_id(SecondSpan), Link#link.trace_id),
          ?assertEqual(otel_span:span_id(SecondSpan), Link#link.span_id),
          Spans = exported_spans(otel_span:trace_id(FirstSpan)),
          ?assertEqual([], named(<<"quod.foreign.verification_worker">>, Spans)),
          ?assertEqual(nomatch, binary:match(term_to_binary([Worker | Spans]), Sentinel)),
          ?assertEqual([{1, undefined}, {2, undefined}], shared_fetches(Token)),
          assert_stages(Worker, Spans, [cache_open, exact_route, page_fetch,
                                       exact_validate, worker_handoff])
      end).

current_cold_replay_is_not_network_advance_test() ->
    with_fixture(
      fun(_Fixture, Base) -> Base end,
      fun(Fixture, Dir, Owner, Fetch) ->
          ?assertMatch({ok, #{phase := finalize}}, explicit(Fixture)),
          quod_foreign_log_tests:stop_owner(Owner),
          Restarted = quod_foreign_log_tests:start_owner(Dir, Fetch),
          try
              Identity = {maps:get(ns, Fixture), maps:get(anchor, Fixture)},
              {Peer, Endpoint} = contact(Fixture),
              {Result, Worker, Spans} = traced_request(
                <<"test.foreign.current.cold">>,
                fun() -> quod_foreign_log:current(
                           [{Peer, [Endpoint]}], Identity, contact(Fixture), 5000)
                end),
              ?assertMatch({ok, #{slot := 2}}, Result),
              Attributes = attrs(Worker),
              ?assertEqual(2, maps:get('quod.foreign.disk_replayed_entries', Attributes)),
              ?assertEqual(0, maps:get('quod.foreign.network_advance_verified_entries', Attributes)),
              ?assert(maps:get('quod.foreign.probe_children_started', Attributes) > 0),
              assert_stages(Worker, Spans,
                [cache_open, cache_reconstruction, cache_replay,
                 checkpoint_compare, tip_confirm, phase_suspend,
                 ledger_suspend, worker_handoff]),
              Probes = named(<<"quod.foreign.probe_worker">>, Spans),
              ?assertEqual(maps:get('quod.foreign.probe_children_started', Attributes),
                           length(Probes)),
              lists:foreach(fun(Probe) ->
                  A = attrs(Probe),
                  ?assertEqual(maps:get('quod.foreign.stages_started', A),
                               maps:get('quod.foreign.stages_completed', A))
              end, Probes)
          after
              quod_foreign_log_tests:stop_owner(Restarted)
          end
      end).

historical_local_trace_keeps_local_reads_distinct_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Fixture = quod_foreign_log_tests:membership_after_finalize_fixture(
                    quod_foreign_log_tests:unique_ns()),
        CacheDir = quod_foreign_log_tests:temp_dir("trace-local-cache"),
        SourceDir = quod_foreign_log_tests:temp_dir("trace-local-source"),
        Owner = quod_foreign_log_tests:start_owner(
                  CacheDir, fun(_, _, _, _, _) -> error(local_trace_used_network) end),
        {SourcePid, SourceMRef, Source} =
            quod_foreign_log_tests:start_local_borrow_source(SourceDir, Fixture),
        try
            {Result, Worker, Spans} = traced_request(
              <<"test.foreign.local">>,
              fun() -> quod_foreign_log:verify_local(
                         Source, maps:get(ref, Fixture), finalize, 5000)
              end),
            ?assertMatch({ok, #{phase := finalize}}, Result),
            Attributes = attrs(Worker),
            ?assertEqual(0, maps:get('quod.foreign.network_advance_verified_entries', Attributes)),
            ?assert(maps:get('quod.foreign.local_advance_verified_entries', Attributes) > 0),
            assert_stages(Worker, Spans,
              [cache_open, page_fetch, page_verify, exact_lookup,
               exact_validate, phase_suspend, ledger_suspend, worker_handoff])
        after
            quod_foreign_log_tests:stop_local_borrow_source(SourcePid, SourceMRef),
            quod_foreign_log_tests:stop_owner(Owner),
            _ = file:del_dir_r(SourceDir),
            _ = file:del_dir_r(CacheDir)
        end
    end).

unsampled_context_does_not_manufacture_worker_root_test() ->
    Parent = self(),
    with_fixture(
      fun(Fixture, Base) ->
          fun(Peer, Endpoint, Ns, From, To) ->
              Parent ! {unsampled_worker, maps:get(ns, Fixture), self()},
              Base(Peer, Endpoint, Ns, From, To)
          end
      end,
      fun(Fixture, _Dir, _Owner, _Fetch) ->
          Context = quod_trace:extract([
            {<<"traceparent">>,
             <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00">>}]),
          ?assertMatch({ok, #{phase := finalize}},
                       quod_trace:with_context(Context, fun() -> explicit(Fixture) end)),
          Ns = maps:get(ns, Fixture),
          Worker = receive {unsampled_worker, Ns, Pid} -> Pid
                   after 2000 -> error(unsampled_verifier_did_not_run)
                   end,
          Monitor = monitor(process, Worker),
          receive {'DOWN', Monitor, process, Worker, _} -> ok
          after 2000 -> error(unsampled_worker_did_not_finish)
          end,
          %% Exact worker DOWN is the export barrier. Other tests/seed calls
          %% may leave unrelated recording spans in this EUnit mailbox.
          ?assertEqual(1, maps:get(resident_verified, quod_foreign_log:stats())),
          ?assertEqual([], [Span || Span <- named(
                              <<"quod.foreign.verification_worker">>, exported_spans(any)),
                            maps:get('quod.namespace', attrs(Span), none) =:= Ns])
      end).

worker_exception_preserves_reason_without_exporting_payload_test() ->
    Parent = self(),
    Sentinel = <<"foreign-worker-private-exception-sentinel">>,
    with_fixture(
      fun(_Fixture, _Base) ->
          fun(_, _, _, _, _) ->
              Parent ! {throwing_worker, self()},
              receive throw_now -> error(Sentinel) end
          end
      end,
      fun(Fixture, _Dir, _Owner, _Fetch) ->
          {Context, Span} = quod_trace:start_span(
                              otel_ctx:new(), <<"test.foreign.exception">>, internal, #{}),
          TraceId = otel_span:trace_id(Span),
          Caller = spawn(fun() ->
              Reply = quod_trace:with_context(Context, fun() -> explicit(Fixture) end),
              Parent ! {exception_caller_reply, self(), Reply}
          end),
          Worker = receive {throwing_worker, Pid} -> Pid
                   after 2000 -> error(exception_worker_not_started)
                   end,
          Monitor = monitor(process, Worker),
          Worker ! throw_now,
          receive
              {'DOWN', Monitor, process, Worker, {Sentinel, Stack}} ->
                  ?assertMatch([{?MODULE, _, _, _} | _], Stack)
          after 2000 -> error(worker_exception_changed)
          end,
          receive {exception_caller_reply, Caller, Reply} ->
              ?assertEqual({error, retry}, Reply)
          after 2000 -> error(exception_caller_not_released)
          end,
          _ = quod_trace:finish_span(Span, ok),
          WorkerSpan = quod_trace_tests:take_span(
                         <<"quod.foreign.verification_worker">>, TraceId),
          Spans = exported_spans(TraceId),
          ?assertEqual(nomatch, binary:match(term_to_binary([WorkerSpan | Spans]), Sentinel)),
          Page = one(<<"quod.foreign.page_fetch">>, Spans),
          ?assertEqual(<<"error">>, maps:get('quod.foreign.exception_class', attrs(Page))),
          ?assertEqual(<<"unclassified_exception">>, maps:get('quod.foreign.reason', attrs(Page))),
          assert_stages(WorkerSpan, Spans, [cache_prepare, cache_open, page_fetch])
      end).

page_success_has_one_owner_terminal_despite_stale_messages_test() ->
    with_page_trace(#{}, fun(C, Context, TraceId) ->
        #{owner := Owner, first := Fixture, link1 := Link} = C,
        Token = make_ref(),
        ok = quod_foreign_log_tests:hold_next_page_decode(Owner, Token, after_accept),
        #{call := Call, binding := Binding, grant := Grant, req_id := ReqId} =
            begin_traced_page(C, Context),
        deliver_traced_page(Owner, Link, Binding, Grant, ReqId, Fixture),
        {Worker, Key} = quod_foreign_log_tests:receive_page_decode_gate(after_accept, Token),
        try
            ?assertEqual(#{}, gen_server:call(Owner, test_page_rows)),
            ?assertEqual({error, retry},
                         quod_foreign_log_tests:page_gate_complete(Worker, Token, Key, decoded)),
            Owner ! {pull_timeout, ReqId},
            deliver_traced_page(Owner, Link, Binding, Grant, ReqId, Fixture),
            %% Owner mailbox barrier: both stale terminal messages were consumed.
            ?assertEqual(#{}, gen_server:call(Owner, test_page_rows)),
            Worker ! {continue_foreign_page_decode, Token},
            ?assertMatch({reply, {ok, #{phase := finalize}}}, gen_server:wait_response(Call, 3000)),
            WorkerSpan = quod_trace_tests:take_span(<<"quod.foreign.verification_worker">>, TraceId),
            Spans = exported_spans(TraceId),
            {Page, Terminal} = assert_page_terminal(ReqId, completed, decoding, false, Spans),
            ?assert(Terminal#span.end_time =< Page#span.end_time),
            assert_stages(WorkerSpan, Spans, [page_fetch, page_wait, page_decode, page_completion]),
            quod_foreign_log_tests:assert_page_owner_drained()
        after
            Worker ! {continue_foreign_page_decode, Token}
        end
    end).

page_link_death_during_decode_exports_its_actual_terminal_cause_test() ->
    with_page_trace(#{}, fun(C, Context, TraceId) ->
        #{owner := Owner, first := Fixture, link1 := Link} = C,
        Token = make_ref(),
        ok = quod_foreign_log_tests:hold_next_page_decode(Owner, Token, before_completion),
        #{call := Call, binding := Binding, grant := Grant, req_id := ReqId} =
            begin_traced_page(C, Context),
        deliver_traced_page(Owner, Link, Binding, Grant, ReqId, Fixture),
        {Worker, Key} = quod_foreign_log_tests:receive_page_decode_gate(before_completion, Token),
        try
            ?assertMatch(#{from_pending := false, turn := {decoding, _, _, _, _}},
                         maps:get(ReqId, gen_server:call(Owner, test_page_rows))),
            exit(Link, kill),
            %% The owner terminal export, not just Link DOWN, is the barrier.
            Terminal = quod_trace_tests:take_span(<<"quod.foreign.page_completion_owner">>, TraceId),
            ?assertEqual(#{}, gen_server:call(Owner, test_page_rows)),
            ?assertEqual({error, retry},
                         quod_foreign_log_tests:page_gate_complete(Worker, Token, Key, decoded)),
            Worker ! {continue_foreign_page_decode, Token},
            ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Call, 3000)),
            _ = quod_trace_tests:take_span(<<"quod.foreign.verification_worker">>, TraceId),
            Spans = [Terminal | exported_spans(TraceId)],
            {_Page, Terminal} = assert_page_terminal(ReqId, link_down, decoding, false, Spans),
            %% The decoder succeeded; only the owner can explain the lost link
            %% after raw delivery. Its unchanged late completion result is retry.
            Decode = one(<<"quod.foreign.page_decode">>, Spans),
            ?assertEqual(<<"ok">>, maps:get('quod.foreign.reason', attrs(Decode))),
            Completion = one(<<"quod.foreign.page_completion">>, Spans),
            ?assertEqual(<<"retry">>, maps:get('quod.foreign.reason', attrs(Completion))),
            quod_foreign_log_tests:assert_page_owner_drained()
        after
            Worker ! {continue_foreign_page_decode, Token}
        end
    end).

page_expiry_terminal_survives_an_already_exported_page_parent_test() ->
    with_page_trace(#{page_timeout_ms => 250}, fun(C, Context, TraceId) ->
        #{owner := Owner, first := Fixture, link1 := Link} = C,
        Token = make_ref(),
        ok = quod_foreign_log_tests:hold_next_page_decode(Owner, Token, before_completion),
        #{call := Call, binding := Binding, grant := Grant, req_id := ReqId} =
            begin_traced_page(C, Context),
        deliver_traced_page(Owner, Link, Binding, Grant, ReqId, Fixture),
        {Worker, _Key} = quod_foreign_log_tests:receive_page_decode_gate(before_completion, Token),
        try
            #{deadline := Deadline} = maps:get(ReqId, gen_server:call(Owner, test_page_rows)),
            ok = sys:suspend(Owner),
            try
                %% Deliberately expire the original page budget while its real
                %% owner is suspended. This clock is the tested failure, never
                %% a progress driver or a replacement production timeout.
                receive after max(0, Deadline - quod_time:mono_ms()) + 20 -> ok end,
                {messages, Messages} = process_info(Owner, messages),
                ?assert(lists:member({pull_timeout, ReqId}, Messages)),
                Worker ! {continue_foreign_page_decode, Token},
                Page = quod_trace_tests:take_span(<<"quod.foreign.page_fetch">>, TraceId),
                ?assertEqual(<<"retry">>, maps:get('quod.foreign.reason', attrs(Page))),
                Completion = quod_trace_tests:take_span(<<"quod.foreign.page_completion">>, TraceId),
                ?assertEqual(<<"page_expired">>,
                             maps:get('quod.foreign.page_wait_cause', attrs(Completion))),
                %% page_fetch has ended and left SDK storage before the owner
                %% can remove its admitted pull. Mutating that parent here
                %% would lose the only terminal cause.
                ?assertEqual([], named(<<"quod.foreign.page_completion_owner">>,
                                       exported_page_terminals(TraceId))),
                ok = sys:resume(Owner),
                ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Call, 3000)),
                _ = quod_trace_tests:take_span(<<"quod.foreign.verification_worker">>, TraceId),
                Spans = [Page, Completion | exported_spans(TraceId)],
                {Page, Terminal} = assert_page_terminal(ReqId, page_expired, decoding, true, Spans),
                ?assert(Terminal#span.start_time > Page#span.end_time),
                quod_foreign_log_tests:assert_page_owner_drained()
            after
                _ = catch sys:resume(Owner)
            end
        after
            Worker ! {continue_foreign_page_decode, Token}
        end
    end).

with_page_trace(Options, Fun) ->
    quod_trace_tests:with_tracer(fun() ->
        quod_foreign_log_tests:with_page_decode_fixture(Options, fun(C) ->
            {Context, Parent} = quod_trace:start_span(
                                  otel_ctx:new(), <<"test.foreign.page.owner">>, internal, #{}),
            try Fun(C, Context, otel_span:trace_id(Parent))
            after quod_trace:finish_span(Parent, ok)
            end
        end)
    end).

begin_traced_page(#{owner := Owner, first := Fixture, peer := Peer,
                    endpoint := Endpoint, ns := Ns, link1 := Link}, Context) ->
    Call = owner_request(Owner, Context,
             {verify, Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000}),
    {Lease, Owner} = quod_foreign_log_tests:receive_page_open(Peer, Endpoint, Ns),
    Binding = quod_foreign_log_tests:install_page_test_link(Owner, Lease, Peer, Ns, Link),
    Grant = crypto:strong_rand_bytes(16),
    Owner ! {catchup_credit, Link, Binding, Grant},
    ReqId = quod_foreign_log_tests:receive_page_request(Link, Binding, Grant),
    #{call => Call, binding => Binding, grant => Grant, req_id => ReqId}.

deliver_traced_page(Owner, Link, Binding, Grant, ReqId, Fixture) ->
    Owner ! {catchup_page, Link, Binding, Grant, ReqId,
             {ok, quod_foreign_log_tests:fixture_entry_blobs(Fixture), 2},
             crypto:strong_rand_bytes(16)}.

assert_page_terminal(ReqId, Cause, Turn, Expired, Spans) ->
    Page = one(<<"quod.foreign.page_fetch">>, Spans),
    Admission = one(<<"quod.foreign.page_admission">>, Spans),
    Terminal = one(<<"quod.foreign.page_completion_owner">>, Spans),
    PageId = binary:encode_hex(ReqId, lowercase),
    ?assertEqual(1, maps:get('quod.foreign.page_expected_terminal', attrs(Admission))),
    ?assertEqual(1, maps:get('quod.foreign.page_terminal_count', attrs(Terminal))),
    lists:foreach(fun(Child) ->
        ?assertEqual(PageId, maps:get('quod.foreign.page_id', attrs(Child))),
        ?assertEqual(Page#span.trace_id, Child#span.trace_id),
        ?assertEqual(Page#span.span_id, Child#span.parent_span_id)
    end, [Admission, Terminal]),
    ?assertEqual(atom_to_binary(Cause), maps:get('quod.foreign.page_terminal', attrs(Terminal))),
    ?assertEqual(atom_to_binary(Turn), maps:get('quod.foreign.page_turn', attrs(Terminal))),
    ?assertEqual(Expired, maps:get('quod.foreign.page_deadline_expired', attrs(Terminal))),
    ?assert(Admission#span.end_time =< Terminal#span.start_time),
    {Page, Terminal}.

exported_page_terminals(TraceId) ->
    receive
        {quod_test_span, Span = #span{trace_id = TraceId,
                                     name = <<"quod.foreign.page_completion_owner">>}} ->
            [Span | exported_page_terminals(TraceId)]
    after 0 -> []
    end.

with_fixture(FetchFactory, Fun) ->
    quod_trace_tests:with_tracer(fun() ->
        Fixture = quod_foreign_log_tests:foreign_fixture(quod_foreign_log_tests:unique_ns()),
        Dir = quod_foreign_log_tests:temp_dir("job-tracing"),
        Base = quod_foreign_log_tests:chain_fetch(maps:get(ns, Fixture), maps:get(chain, Fixture)),
        Fetch = FetchFactory(Fixture, Base),
        Owner = quod_foreign_log_tests:start_owner(Dir, Fetch),
        try Fun(Fixture, Dir, Owner, Fetch)
        after
            quod_foreign_log_tests:stop_owner(Owner),
            _ = file:del_dir_r(Dir)
        end
    end).

contact(Fixture) -> {maps:get(pub, Fixture), {"127.0.0.1", 31988}}.

explicit(Fixture) ->
    {Peer, Endpoint} = contact(Fixture),
    quod_foreign_log:verify(Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000).

owner_request(Owner, Context, Request) ->
    gen_server:send_request(Owner,
      {verification, quod_time:mono_ms() + 5000, Context,
       erlang:monotonic_time(), Request}).

shared_fetches(Token) ->
    receive {shared_fetch, Token, From, Value} -> [{From, Value} | shared_fetches(Token)]
    after 0 -> []
    end.

traced_request(Name, Fun) ->
    {Context, Parent} = quod_trace:start_span(otel_ctx:new(), Name, internal, #{}),
    TraceId = otel_span:trace_id(Parent),
    Result = try quod_trace:with_context(Context, Fun)
             after quod_trace:finish_span(Parent, ok)
             end,
    Worker = quod_trace_tests:take_span(<<"quod.foreign.verification_worker">>, TraceId),
    {Result, Worker, exported_spans(TraceId)}.

exported_spans(any) ->
    receive {quod_test_span, Span} -> [Span | exported_spans(any)]
    after 0 -> []
    end;
exported_spans(TraceId) ->
    receive {quod_test_span, Span = #span{trace_id = TraceId}} ->
        [Span | exported_spans(TraceId)]
    after 0 -> []
    end.

attrs(Span) -> otel_attributes:map(Span#span.attributes).

named(Name, Spans) -> [Span || Span = #span{name = N} <- Spans, N =:= Name].

one(Name, Spans) ->
    [Span] = named(Name, Spans),
    Span.

assert_stages(Worker, Spans, Required) ->
    lists:foreach(fun(Stage) ->
        Name = <<"quod.foreign.", (atom_to_binary(Stage))/binary>>,
        ?assertNotEqual([], named(Name, Spans))
    end, Required),
    WorkerAttrs = attrs(Worker),
    WorkerPid = maps:get('quod.foreign.worker_pid', WorkerAttrs),
    Stages = [Span || Span <- Spans,
                      maps:get('quod.foreign.stage_process', attrs(Span), none) =:= WorkerPid],
    Started = maps:get('quod.foreign.stages_started', WorkerAttrs),
    ?assert(Started > 0),
    ?assertEqual(Started, maps:get('quod.foreign.stages_completed', WorkerAttrs)),
    ?assertEqual(Started, length(Stages)),
    ?assertEqual(lists:seq(1, Started),
                 lists:sort([maps:get('quod.foreign.stage_ordinal', attrs(Span)) || Span <- Stages])),
    lists:foreach(fun(Span) ->
        ?assert(Span#span.start_time >= Worker#span.start_time),
        ?assert(Span#span.end_time =< Worker#span.end_time)
    end, Stages).

assert_no_stage(Stage, Spans) ->
    ?assertEqual([], named(<<"quod.foreign.", (atom_to_binary(Stage))/binary>>, Spans)).
