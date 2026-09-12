-module(quod_foreign_log_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([identity_current_global_network_dependency_case/0]).

-ifdef(TEST).
%% The lifecycle/trace suites exercise the same signed fixture and registered
%% borrowed-source seams; do not build a second verifier or genesis fixture.
-export([foreign_fixture/1, prepared_then_committed_fixture/1,
         membership_after_finalize_fixture/1,
         chain_fetch/2, peer_chain_fetch/3, local_fixture_view/2, local_fixture_view/3,
         start_local_borrow_source/2, stop_local_borrow_source/2,
         hold_direct_local/4, receive_local_borrow_result/1,
         start_owner/2, stop_owner/1, unique_ns/0, temp_dir/1,
         with_page_decode_fixture/2, receive_page_open/3,
         install_page_test_link/5, receive_page_request/3,
         hold_next_page_decode/3, receive_page_decode_gate/2,
         page_gate_complete/4, fixture_entry_blobs/1,
         assert_page_owner_drained/0, await_history_ready/2]).
-endif.

-define(GENESIS_TX_VERSION, 1).
-define(GENESIS_TX_TAG, "quod/genesis").

page_credit_shares_pinned_binding_fifo_across_anchors_test() ->
    Ns = unique_ns(),
    A = foreign_fixture(Ns),
    B = foreign_fixture(Ns),
    Peer = maps:get(pub, A),
    Endpoint = {"127.0.0.1", 32121},
    Dir = temp_dir("page-credit-two-anchors"),
    Pid = start_owner_opts(Dir, undefined, #{page_timeout_ms => 5000}),
    Transport = start_page_test_transport(self()),
    Parent = self(),
    Link = spawn(fun() -> page_test_link(Parent) end),
    try
        First = gen_server:send_request(Pid, owner_request({verify, Peer, Endpoint, maps:get(ref, A), finalize, 5000})),
        {Lease, Producer} = receive_page_open(Peer, Endpoint, Ns),
        Second = gen_server:send_request(Pid, owner_request({verify, Peer, Endpoint, maps:get(ref, B), finalize, 5000})),
        wait_page_pull_count(2, 2000),
        ?assertEqual(1, maps:get(page_bindings, quod_foreign_log:stats())),
        receive {page_test_open, _, _, _, _, _} -> error(duplicate_pinned_open)
        after 0 -> ok
        end,
        Producer ! {link_up, Lease, Peer, quod_catchup:channel(Ns), Link},
        Binding = receive {page_test_bound, Link, Producer, Ref} -> Ref
                  after 1000 -> error(page_binding_not_installed)
                  end,
        Grant1 = crypto:strong_rand_bytes(16),
        Producer ! {catchup_credit, Link, Binding, Grant1},
        Req1 = receive_page_request(Link, Binding, Grant1),
        %% Both callers are admitted, but only the head may spend one credit.
        ?assertEqual(2, maps:get(pulls, quod_foreign_log:stats())),
        receive {page_test_request, Link, _, _, _, _, _, _} -> error(second_page_spent_same_credit)
        after 0 -> ok
        end,
        Grant2 = crypto:strong_rand_bytes(16),
        Producer ! {catchup_page, Link, Binding, Grant1, Req1,
                    {ok, fixture_entry_blobs(A), 2}, Grant2},
        ?assertMatch({reply, {ok, #{phase := finalize}}}, gen_server:wait_response(First, 3000)),
        Req2 = receive_page_request(Link, Binding, Grant2),
        Producer ! {catchup_page, Link, Binding, Grant2, Req2,
                    {ok, fixture_entry_blobs(B), 2}, crypto:strong_rand_bytes(16)},
        ?assertMatch({reply, {ok, #{phase := finalize}}}, gen_server:wait_response(Second, 3000)),
        ?assertMatch(#{pending := 0, pulls := 0, page_bindings := 0}, quod_foreign_log:stats()),
        receive {page_test_release, Peer, Endpoint, _, {Producer, Lease}} -> ok
        after 1000 -> error(final_page_lease_not_released)
        end
    after
        Link ! close,
        stop_owner(Pid),
        stop_page_test_transport(Transport),
        _ = file:del_dir_r(Dir)
    end.

page_error_returns_successor_credit_to_queued_pull_test_() ->
    [{atom_to_list(Reason), fun() -> page_error_returns_successor_credit(Reason) end}
     || Reason <- [not_ready, server_error]].

page_error_returns_successor_credit(Reason) ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link, second := B} = C,
          #{first_call := First, second_call := Second, binding := Binding,
            grant := Grant, first_id := Req1, second_id := Req2} =
              begin_queued_page_pair(C),
          NextGrant = crypto:strong_rand_bytes(16),
          Owner ! {catchup_page, Link, Binding, Grant, Req1,
                   {error, Reason}, NextGrant},
          %% A terminal server refusal is not a malformed page. It returns
          %% the successor credit without a decode or a replacement link.
          ?assertEqual(Req2, receive_page_request(Link, Binding, NextGrant)),
          ?assert(is_process_alive(Link)),
          receive {page_test_open, _, _, _, _, _} -> error(error_reopened_link)
          after 0 -> ok end,
          ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 2000)),
          Owner ! {catchup_page, Link, Binding, NextGrant, Req2,
                   {ok, fixture_entry_blobs(B), 2}, crypto:strong_rand_bytes(16)},
          ?assertMatch({reply, {ok, #{phase := finalize}}},
                       gen_server:wait_response(Second, 3000)),
          assert_page_owner_drained()
      end).

page_decode_does_not_block_another_identity_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link1, link2 := Link2,
            first := A, second := B, peer := Peer, ns := Ns} = C,
          Token = make_ref(),
          ok = hold_next_page_decode(Owner, Token, before_decode),
          #{call := First, binding := Binding1, grant := Grant1, req_id := Req1} =
              begin_single_page(C),
          NextGrant = crypto:strong_rand_bytes(16),
          Owner ! {catchup_page, Link1, Binding1, Grant1, Req1,
                   {ok, fixture_entry_blobs(A), 2}, NextGrant},
          {Worker, _Key} = receive_page_decode_gate(before_decode, Token),
          try
              Rows = gen_server:call(Owner, test_page_rows),
              ?assertMatch(#{caller := Worker,
                             turn := {decoding, Link1, Binding1, Grant1, NextGrant}},
                           maps:get(Req1, Rows)),
              OtherEndpoint = {"127.0.0.1", 32142},
              Second = page_verify_request(Owner, Peer, OtherEndpoint, B),
              {Lease2, Owner} = receive_page_open(Peer, OtherEndpoint, Ns),
              Binding2 = install_page_test_link(Owner, Lease2, Peer, Ns, Link2),
              Grant2 = crypto:strong_rand_bytes(16),
              Owner ! {catchup_credit, Link2, Binding2, Grant2},
              Req2 = receive_page_request(Link2, Binding2, Grant2),
              Owner ! {catchup_page, Link2, Binding2, Grant2, Req2,
                       {ok, fixture_entry_blobs(B), 2}, crypto:strong_rand_bytes(16)},
              ?assertMatch({reply, {ok, #{phase := finalize}}},
                           gen_server:wait_response(Second, 3000)),
              %% The first worker is still held: this cannot pass if the
              %% node-wide owner is the process doing the page decode.
              ?assert(maps:is_key(Req1, gen_server:call(Owner, test_page_rows))),
              ?assertEqual(timeout, gen_server:wait_response(First, 0)),
              Worker ! {continue_foreign_page_decode, Token},
              ?assertMatch({reply, {ok, #{phase := finalize}}},
                           gen_server:wait_response(First, 3000)),
              assert_page_owner_drained()
          after
              Worker ! {continue_foreign_page_decode, Token}
          end
      end).

page_decode_worker_death_closes_link_and_preserves_queued_deadline_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link1, link2 := Link2,
            first := A, second := B, peer := Peer, endpoint := Endpoint, ns := Ns} = C,
          Token = make_ref(),
          ok = hold_next_page_decode(Owner, Token, before_completion),
          #{first_call := First, second_call := Second, lease := Lease1,
            binding := Binding, grant := Grant1, first_id := Req1,
            second_id := Req2, queued := Queued} = begin_queued_page_pair(C),
          #{caller := Worker} = maps:get(Req1, gen_server:call(Owner, test_page_rows)),
          MonitorsBefore = page_owner_monitor_count(Owner, Worker),
          ?assert(MonitorsBefore >= 2),
          NextGrant = crypto:strong_rand_bytes(16),
          Owner ! {catchup_page, Link1, Binding, Grant1, Req1,
                   {ok, fixture_entry_blobs(A), 2}, NextGrant},
          {Worker, Key} = receive_page_decode_gate(before_completion, Token),
          try
              ?assertEqual(MonitorsBefore, page_owner_monitor_count(Owner, Worker)),
              ?assertMatch(#{from_pending := false,
                             turn := {decoding, Link1, Binding, Grant1, NextGrant}},
                           maps:get(Req1, gen_server:call(Owner, test_page_rows))),
              ?assertMatch(#{active := Req1, credit := none, retiring := false},
                           page_binding_state(Owner, Binding)),
              receive {page_test_request, Link1, _, _, _, _, _, _} ->
                          error(successor_spent_before_decode_acceptance)
              after 0 -> ok end,
              exit(Worker, kill),
              ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 2000)),
              {Lease2, Owner} = receive_page_open(Peer, Endpoint, Ns),
              ?assertNotEqual(Lease1, Lease2),
              ?assertNot(is_process_alive(Link1)),
              ?assertEqual(#{Req2 => Queued}, gen_server:call(Owner, test_page_rows)),
              ?assertEqual(0, page_owner_monitor_count(Owner, Worker)),
              ?assertEqual(Binding, install_page_test_link(Owner, Lease2, Peer, Ns, Link2)),
              Grant2 = crypto:strong_rand_bytes(16),
              Owner ! {catchup_credit, Link2, Binding, Grant2},
              ?assertEqual(Req2, receive_page_request(Link2, Binding, Grant2)),
              BeforeLate = page_binding_state(Owner, Binding),
              Owner ! {catchup_page, Link1, Binding, Grant1, Req1,
                       {ok, fixture_entry_blobs(A), 2}, NextGrant},
              ?assertEqual({error, retry},
                           gen_server:call(Owner, {complete_page_decode, Key, decoded})),
              ?assertEqual(BeforeLate, page_binding_state(Owner, Binding)),
              ?assertEqual(1, maps:get(pulls, quod_foreign_log:stats())),
              Owner ! {catchup_page, Link2, Binding, Grant2, Req2,
                       {ok, fixture_entry_blobs(B), 2}, crypto:strong_rand_bytes(16)},
              ?assertMatch({reply, {ok, #{phase := finalize}}},
                           gen_server:wait_response(Second, 3000)),
              assert_page_owner_drained()
          after
              exit(Worker, kill)
          end
      end).

page_decode_wrong_completion_keys_cannot_release_credit_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link, link2 := OtherLink, first := A} = C,
          Token = make_ref(),
          ok = hold_next_page_decode(Owner, Token, before_completion),
          #{call := First, binding := Binding, grant := Grant, req_id := ReqId} =
              begin_single_page(C),
          NextGrant = crypto:strong_rand_bytes(16),
          Owner ! {catchup_page, Link, Binding, Grant, ReqId,
                   {ok, fixture_entry_blobs(A), 2}, NextGrant},
          {Worker, Key} = receive_page_decode_gate(before_completion, Token),
          try
              Rows = gen_server:call(Owner, test_page_rows),
              State = page_binding_state(Owner, Binding),
              ?assertEqual({error, retry},
                           gen_server:call(Owner, {complete_page_decode, Key, decoded})),
              %% These calls originate in the real retained puller, so the
              %% key negatives cannot pass merely through the PID guard.
              WrongKeys = [{self(), ReqId, Binding, Link, Grant},
                           {Owner, crypto:strong_rand_bytes(16), Binding, Link, Grant},
                           {Owner, ReqId, make_ref(), Link, Grant},
                           {Owner, ReqId, Binding, OtherLink, Grant},
                           {Owner, ReqId, Binding, Link, crypto:strong_rand_bytes(16)}],
              lists:foreach(
                fun(WrongKey) ->
                    ?assertEqual({error, retry},
                                 page_gate_complete(Worker, Token, WrongKey, decoded)),
                    ?assertEqual(Rows, gen_server:call(Owner, test_page_rows)),
                    ?assertEqual(State, page_binding_state(Owner, Binding))
                end, WrongKeys),
              %% An identical wire response is equally inert while decoding.
              Owner ! {catchup_page, Link, Binding, Grant, ReqId,
                       {ok, fixture_entry_blobs(A), 2}, NextGrant},
              ?assertEqual(Rows, gen_server:call(Owner, test_page_rows)),
              ?assertEqual(timeout, gen_server:wait_response(First, 0)),
              Worker ! {continue_foreign_page_decode, Token},
              ?assertMatch({reply, {ok, #{phase := finalize}}},
                           gen_server:wait_response(First, 3000)),
              assert_page_owner_drained()
          after
              Worker ! {continue_foreign_page_decode, Token}
          end
      end).

page_decode_duplicate_completion_and_stale_timeout_are_inert_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link, first := A} = C,
          Token = make_ref(),
          ok = hold_next_page_decode(Owner, Token, after_accept),
          #{call := First, binding := Binding, grant := Grant, req_id := ReqId} =
              begin_single_page(C),
          #{caller := Worker} = maps:get(ReqId, gen_server:call(Owner, test_page_rows)),
          MonitorCount = page_owner_monitor_count(Owner, Worker),
          NextGrant = crypto:strong_rand_bytes(16),
          Owner ! {catchup_page, Link, Binding, Grant, ReqId,
                   {ok, fixture_entry_blobs(A), 2}, NextGrant},
          {Worker, Key} = receive_page_decode_gate(after_accept, Token),
          try
              ?assertEqual(#{}, gen_server:call(Owner, test_page_rows)),
              ?assertEqual(MonitorCount - 1, page_owner_monitor_count(Owner, Worker)),
              State = page_binding_state(Owner, Binding),
              ?assertMatch(#{active := none, credit := NextGrant, retiring := false}, State),
              ?assertEqual({error, retry}, page_gate_complete(Worker, Token, Key, decoded)),
              Owner ! {pull_timeout, ReqId},
              Owner ! {catchup_page, Link, Binding, Grant, ReqId,
                       {ok, fixture_entry_blobs(A), 2}, crypto:strong_rand_bytes(16)},
              ?assertEqual(State, page_binding_state(Owner, Binding)),
              ?assertEqual(timeout, gen_server:wait_response(First, 0)),
              Worker ! {continue_foreign_page_decode, Token},
              ?assertMatch({reply, {ok, #{phase := finalize}}},
                           gen_server:wait_response(First, 3000)),
              assert_page_owner_drained()
          after
              Worker ! {continue_foreign_page_decode, Token}
          end
      end).

page_decode_acceptance_allows_the_same_worker_next_page_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link, first := A} = C,
          [Genesis, Finalize] = fixture_entry_blobs(A),
          Token = make_ref(),
          ok = hold_next_page_decode(Owner, Token, before_completion),
          #{call := First, binding := Binding, grant := Grant1, req_id := Req1} =
              begin_single_page(C),
          Grant2 = crypto:strong_rand_bytes(16),
          Owner ! {catchup_page, Link, Binding, Grant1, Req1, {ok, [Genesis], 2}, Grant2},
          {Worker, _Key} = receive_page_decode_gate(before_completion, Token),
          try
              ?assertEqual(timeout, gen_server:wait_response(First, 0)),
              Worker ! {continue_foreign_page_decode, Token},
              Req2 = receive_page_request_range(Link, Binding, Grant2, 2, 2),
              ?assertMatch(#{caller := Worker},
                           maps:get(Req2, gen_server:call(Owner, test_page_rows))),
              ?assertEqual(timeout, gen_server:wait_response(First, 0)),
              Owner ! {catchup_page, Link, Binding, Grant2, Req2,
                       {ok, [Finalize], 2}, crypto:strong_rand_bytes(16)},
              ?assertMatch({reply, {ok, #{phase := finalize}}},
                           gen_server:wait_response(First, 3000)),
              assert_page_owner_drained()
          after
              Worker ! {continue_foreign_page_decode, Token}
          end
      end).

page_decode_malformed_page_closes_link_and_rebinds_queued_work_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link1, link2 := Link2, second := B,
            peer := Peer, endpoint := Endpoint, ns := Ns} = C,
          #{first_call := First, second_call := Second, lease := Lease1,
            binding := Binding, grant := Grant1, first_id := Req1,
            second_id := Req2, queued := Queued} = begin_queued_page_pair(C),
          %% Valid page framing, invalid entry bytes: exercise worker-side
          %% wrapped decoding, not a rejection by the link's frame grammar.
          Owner ! {catchup_page, Link1, Binding, Grant1, Req1,
                   {ok, [<<"not-an-entry">>], 2}, crypto:strong_rand_bytes(16)},
          ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 2000)),
          {Lease2, Owner} = receive_page_open(Peer, Endpoint, Ns),
          ?assertNotEqual(Lease1, Lease2),
          ?assertNot(is_process_alive(Link1)),
          ?assertEqual(#{Req2 => Queued}, gen_server:call(Owner, test_page_rows)),
          ?assertEqual(Binding, install_page_test_link(Owner, Lease2, Peer, Ns, Link2)),
          Grant2 = crypto:strong_rand_bytes(16),
          Owner ! {catchup_credit, Link2, Binding, Grant2},
          ?assertEqual(Req2, receive_page_request(Link2, Binding, Grant2)),
          Owner ! {catchup_page, Link2, Binding, Grant2, Req2,
                   {ok, fixture_entry_blobs(B), 2}, crypto:strong_rand_bytes(16)},
          ?assertMatch({reply, {ok, #{phase := finalize}}},
                       gen_server:wait_response(Second, 3000)),
          assert_page_owner_drained()
      end).

page_decode_queued_completion_cannot_renew_expired_deadline_test() ->
    with_page_decode_fixture(
      #{page_timeout_ms => 500},
      fun(C) ->
          #{owner := Owner, link1 := Link, first := A} = C,
          Token = make_ref(),
          ok = hold_next_page_decode(Owner, Token, before_completion),
          #{call := First, binding := Binding, grant := Grant, req_id := ReqId} =
              begin_single_page(C),
          Owner ! {catchup_page, Link, Binding, Grant, ReqId,
                   {ok, fixture_entry_blobs(A), 2}, crypto:strong_rand_bytes(16)},
          {Worker, Key} = receive_page_decode_gate(before_completion, Token),
          try
              #{deadline := Deadline} = maps:get(ReqId, gen_server:call(Owner, test_page_rows)),
              ok = sys:suspend(Owner),
              1 = erlang:trace(Worker, true, [send, {tracer, self()}]),
              Worker ! {test_complete_foreign_page, Token, Key, decoded},
              receive
                  {trace, Worker, send,
                   {'$gen_call', _, {complete_page_decode, Key, decoded}}, Owner} -> ok
              after 1000 -> error(decode_completion_not_queued)
              end,
              1 = erlang:trace(Worker, false, [send]),
              ?assert(Deadline > quod_time:mono_ms()),
              {messages, Queued} = process_info(Owner, messages),
              ?assert(lists:any(
                        fun({'$gen_call', _, {complete_page_decode, QueuedKey, decoded}}) ->
                                QueuedKey =:= Key;
                           (_) -> false
                        end, Queued)),
              ?assertNot(lists:member({pull_timeout, ReqId}, Queued)),
              %% The completion was sent before the timeout message, but
              %% admission occurs after the unchanged absolute deadline.
              receive after max(0, Deadline - quod_time:mono_ms()) + 20 -> ok end,
              ok = sys:resume(Owner),
              receive
                  {foreign_page_completion, Token, {error, retry}} -> ok
              after 1000 -> error(expired_decode_completion_was_accepted)
              end,
              Worker ! {continue_foreign_page_decode, Token},
              ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 2000)),
              ?assertNot(is_process_alive(Link)),
              assert_page_owner_drained()
          after
              _ = catch erlang:trace(Worker, false, [send]),
              _ = catch sys:resume(Owner),
              Worker ! {continue_foreign_page_decode, Token}
          end
      end).

page_decode_link_death_before_completion_refuses_late_verdict_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link, first := A} = C,
          Token = make_ref(),
          ok = hold_next_page_decode(Owner, Token, before_completion),
          #{call := First, binding := Binding, grant := Grant, req_id := ReqId} =
              begin_single_page(C),
          Owner ! {catchup_page, Link, Binding, Grant, ReqId,
                   {ok, fixture_entry_blobs(A), 2}, crypto:strong_rand_bytes(16)},
          {Worker, Key} = receive_page_decode_gate(before_completion, Token),
          try
              Link ! close,
              %% Lease release comes from the owner's exact link-DOWN
              %% transition, not merely from observing the link's death.
              receive {page_test_release, _, _, _, {Owner, _}} -> ok
              after 1000 -> error(dead_decode_link_not_retired)
              end,
              ?assertEqual(#{}, gen_server:call(Owner, test_page_rows)),
              ?assertEqual({error, retry}, page_gate_complete(Worker, Token, Key, decoded)),
              ?assertEqual(timeout, gen_server:wait_response(First, 0)),
              Worker ! {continue_foreign_page_decode, Token},
              ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 2000)),
              assert_page_owner_drained()
          after
              Worker ! {continue_foreign_page_decode, Token}
          end
      end).

page_decode_worker_death_after_acceptance_keeps_successor_work_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link, first := A, second := B} = C,
          Token = make_ref(),
          ok = hold_next_page_decode(Owner, Token, after_accept),
          #{first_call := First, second_call := Second, binding := Binding,
            grant := Grant1, first_id := Req1, second_id := Req2} =
              begin_queued_page_pair(C),
          Grant2 = crypto:strong_rand_bytes(16),
          Owner ! {catchup_page, Link, Binding, Grant1, Req1,
                   {ok, fixture_entry_blobs(A), 2}, Grant2},
          {Worker, _Key} = receive_page_decode_gate(after_accept, Token),
          try
              ?assertEqual(Req2, receive_page_request(Link, Binding, Grant2)),
              exit(Worker, kill),
              ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 2000)),
              ?assert(is_process_alive(Link)),
              ?assertMatch(#{active := Req2, retiring := false}, page_binding_state(Owner, Binding)),
              Owner ! {catchup_page, Link, Binding, Grant2, Req2,
                       {ok, fixture_entry_blobs(B), 2}, crypto:strong_rand_bytes(16)},
              ?assertMatch({reply, {ok, #{phase := finalize}}},
                           gen_server:wait_response(Second, 3000)),
              assert_page_owner_drained()
          after
              exit(Worker, kill)
          end
      end).

page_decode_runs_once_in_the_requesting_worker_never_in_owner_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link, first := A} = C,
          #{call := First, binding := Binding, grant := Grant, req_id := ReqId} =
              begin_single_page(C),
          #{caller := Worker} = maps:get(ReqId, gen_server:call(Owner, test_page_rows)),
          1 = erlang:trace_pattern({quod_catchup, decode_entries, 2}, true, [local]),
          1 = erlang:trace(Owner, true, [call, {tracer, self()}]),
          1 = erlang:trace(Worker, true, [call, {tracer, self()}]),
          try
              Owner ! {catchup_page, Link, Binding, Grant, ReqId,
                       {ok, fixture_entry_blobs(A), 2}, crypto:strong_rand_bytes(16)},
              ?assertMatch({reply, {ok, #{phase := finalize}}},
                           gen_server:wait_response(First, 3000)),
              Barrier = erlang:trace_delivered(all),
              Calls = collect_page_decode_calls(Barrier, #{}),
              %% The worker call is the positive control for the zero owner
              %% count; retaining an owner-side decode is a real failure.
              ?assertEqual(#{{Worker, wrapped} => 1}, Calls),
              assert_page_owner_drained()
          after
              _ = catch erlang:trace(Owner, false, [call]),
              _ = catch erlang:trace(Worker, false, [call]),
              1 = erlang:trace_pattern({quod_catchup, decode_entries, 2}, false, [local])
          end
      end).

page_decode_owner_replacement_cannot_accept_old_page_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link, first := A} = C,
          Token = make_ref(),
          ok = hold_next_page_decode(Owner, Token, before_completion),
          #{call := First, binding := Binding, grant := Grant, req_id := ReqId} =
              begin_single_page(C),
          Owner ! {catchup_page, Link, Binding, Grant, ReqId,
                   {ok, fixture_entry_blobs(A), 2}, crypto:strong_rand_bytes(16)},
          {Worker, _Key} = receive_page_decode_gate(before_completion, Token),
          WorkerMonitor = monitor(process, Worker),
          try
              stop_owner(Owner),
              ?assertMatch({error, {normal, Owner}}, gen_server:wait_response(First, 1000)),
              %% The directional owner-death watcher now retires even a
              %% decoder held before completion. A replacement never inherits
              %% that writer or relies on it finishing voluntarily.
              receive {'DOWN', WorkerMonitor, process, Worker, killed} -> ok
              after 2000 -> error(old_page_worker_survived_owner)
              end,
              ReplacementDir = temp_dir("page-decode-new-owner"),
              Replacement = start_owner_opts(ReplacementDir, undefined, #{page_timeout_ms => 5000}),
              try
                  ?assertEqual(Replacement, quod_reg:where({foreign_log, node})),
                  1 = erlang:trace(Replacement, true, ['receive', {tracer, self()}]),
                  Worker ! {continue_foreign_page_decode, Token},
                  Barrier = erlang:trace_delivered(all),
                  assert_no_page_completion_to_replacement(Replacement, Barrier),
                  ?assertEqual(#{}, gen_server:call(Replacement, test_page_rows)),
                  ?assertEqual(#{}, gen_server:call(Replacement, test_page_binding)),
                  ?assertMatch(#{pending := 0, histories := 0}, quod_foreign_log:stats())
              after
                  _ = catch erlang:trace(Replacement, false, ['receive']),
                  stop_owner(Replacement),
                  _ = file:del_dir_r(ReplacementDir)
              end
          after
              exit(Worker, kill),
              _ = demonitor(WorkerMonitor, [flush])
          end
      end).

page_trace_parent_selection_ignores_prior_real_fixture_test() ->
    %% This actual upstream fixture leaves correctly exported spans from its
    %% mocked byte transport. They have a tip-confirm/page-fetch ancestry but
    %% no real page-wait child. A name-only parent selector must fail here;
    %% the following assertions must follow only their own request's trace.
    quod_foreign_queue_observation_tests:current_queue_names_the_actual_exact_predecessor_test(),
    page_decode_trace_crosses_real_owner_and_confirmation_probe_test().

page_decode_trace_crosses_real_owner_and_confirmation_probe_test() ->
    with_page_decode_fixture(
      fun(C) ->
          #{owner := Owner, link1 := Link, first := Fixture,
            peer := Peer, ns := Ns} = C,
          %% Use the address committed by genesis: tip confirmation follows
          %% certified committee routes, not the initial bootstrap contact.
          Endpoint = {"127.0.0.1", 19000},
          Identity = {Ns, maps:get(anchor, Fixture)},
          Routes = route_candidates([{Peer, Endpoint}]),
          quod_trace_tests:with_tracer(fun() ->
              TestPid = self(),
              Tag = make_ref(),
              {RequestContext, RequestSpan} = quod_trace:start_span(
                otel_ctx:new(), <<"test.page.current.request">>, internal, #{}),
              TraceId = otel_span:trace_id(RequestSpan),
              {Caller, CallerMonitor} = spawn_monitor(fun() ->
                  Result = quod_trace:with_context(RequestContext,
                    fun() -> quod_foreign_log:current(Routes, Identity, 5000) end),
                  TestPid ! {page_trace_current_result, Tag, Result}
              end),
              try
                  {Lease, Owner} = receive_page_open(Peer, Endpoint, Ns),
                  [#{caller := VerificationWorker}] = maps:values(gen_server:call(Owner, test_page_rows)),
                  VerificationMonitor = monitor(process, VerificationWorker),
                  try
                      Binding = install_page_test_link(Owner, Lease, Peer, Ns, Link),
                      Owner ! {catchup_credit, Link, Binding, crypto:strong_rand_bytes(16)},
                      ?assertMatch({ok, #{identity := Identity}},
                                   serve_page_trace_current(Owner, Link, Binding, Fixture, Tag)),
                      Current = quod_trace_tests:take_span(<<"quod.foreign.current">>, TraceId),
                      Confirmation = quod_trace_tests:take_span(<<"quod.foreign.tip_confirm">>, TraceId),
                      %% Select the page belonging to the spawned confirmation
                      %% probe, not an earlier bootstrap page in its parent.
                      %% The collection/worker intervals now expose expected
                      %% fanout and each probe's own stage reconciliation.
                      Collection = take_page_child_span(
                                     <<"quod.foreign.probe_collection">>, Confirmation),
                      Probe = take_page_child_span(
                                <<"quod.foreign.probe_worker">>, Collection),
                      ?assertEqual(1, maps:get('quod.foreign.expected_probe_children',
                                               otel_attributes:map(Collection#span.attributes))),
                      ?assertEqual(1, maps:get('quod.foreign.probe_ordinal',
                                               otel_attributes:map(Probe#span.attributes))),
                      Page = take_page_child_span(<<"quod.foreign.page_fetch">>, Probe),
                      lists:foreach(
                        fun(Name) ->
                            Span = take_page_child_span(Name, Page),
                            ?assertEqual(Current#span.trace_id, Span#span.trace_id)
                        end,
                        [<<"quod.foreign.page_wait">>, <<"quod.foreign.page_decode">>,
                         <<"quod.foreign.page_completion">>, <<"quod.foreign.page_delivery">>,
                         <<"quod.foreign.page_completion_owner">>]),
                      ?assertEqual(Current#span.trace_id, Page#span.trace_id),
                      assert_page_owner_drained()
                  after
                      exit(VerificationWorker, kill),
                      receive {'DOWN', VerificationMonitor, process, VerificationWorker, _} -> ok
                      after 1000 -> error(trace_verification_worker_survived_cleanup)
                      end,
                      wait_foreign_work(0, 0, 1000)
                  end
              after
                  exit(Caller, kill),
                  receive {'DOWN', CallerMonitor, process, Caller, _} -> ok
                  after 1000 -> error(trace_caller_survived_cleanup)
                  end,
                  stop_owner(Owner),
                  quod_trace:finish_span(RequestSpan, ok),
                  flush_page_trace_spans()
              end
          end)
      end).

page_credit_worker_death_resets_sent_page_and_rebinds_unsent_deadline_test() ->
    Ns = unique_ns(),
    A = foreign_fixture(Ns),
    B = foreign_fixture(Ns),
    Peer = maps:get(pub, A),
    Endpoint = {"127.0.0.1", 32122},
    Dir = temp_dir("page-credit-cancel-sent"),
    Pid = start_owner_opts(Dir, undefined, #{page_timeout_ms => 5000}),
    Transport = start_page_test_transport(self()),
    Parent = self(),
    Link1 = spawn(fun() -> page_test_link(Parent) end),
    Link2 = spawn(fun() -> page_test_link(Parent) end),
    try
        First = gen_server:send_request(Pid, owner_request({verify, Peer, Endpoint, maps:get(ref, A), finalize, 5000})),
        {Lease1, Pid} = receive_page_open(Peer, Endpoint, Ns),
        Second = gen_server:send_request(Pid, owner_request({verify, Peer, Endpoint, maps:get(ref, B), finalize, 5000})),
        wait_page_pull_count(2, 2000),
        Pid ! {link_up, Lease1, Peer, quod_catchup:channel(Ns), Link1},
        Binding = receive {page_test_bound, Link1, Pid, Ref} -> Ref
                  after 1000 -> error(page_binding_not_installed)
                  end,
        Grant1 = crypto:strong_rand_bytes(16),
        Pid ! {catchup_credit, Link1, Binding, Grant1},
        Req1 = receive_page_request(Link1, Binding, Grant1),
        Rows = gen_server:call(Pid, test_page_rows),
        #{caller := PageOwner} = maps:get(Req1, Rows),
        [{Req2, Unsent}] = maps:to_list(maps:remove(Req1, Rows)),
        exit(PageOwner, kill),
        ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 2000)),
        {Lease2, Pid} = receive_page_open(Peer, Endpoint, Ns),
        ?assert(Lease1 =/= Lease2),
        ?assertNot(is_process_alive(Link1)),
        ?assertEqual(#{Req2 => Unsent}, gen_server:call(Pid, test_page_rows)),
        Pid ! {link_up, Lease2, Peer, quod_catchup:channel(Ns), Link2},
        receive {page_test_bound, Link2, Pid, Binding} -> ok
        after 1000 -> error(replacement_page_binding_not_installed)
        end,
        Grant2 = crypto:strong_rand_bytes(16),
        Pid ! {catchup_credit, Link2, Binding, Grant2},
        ?assertEqual(Req2, receive_page_request(Link2, Binding, Grant2)),
        Pid ! {catchup_page, Link1, Binding, Grant1, Req1,
               {ok, fixture_entry_blobs(A), 2}, crypto:strong_rand_bytes(16)},
        ?assertEqual(1, maps:get(pulls, quod_foreign_log:stats())),
        ?assert(is_process_alive(Link2)),
        Pid ! {catchup_page, Link2, Binding, Grant2, Req2,
               {ok, fixture_entry_blobs(B), 2}, crypto:strong_rand_bytes(16)},
        ?assertMatch({reply, {ok, #{phase := finalize}}}, gen_server:wait_response(Second, 3000)),
        ?assertMatch(#{pending := 0, pulls := 0, page_bindings := 0}, quod_foreign_log:stats())
    after
        Link1 ! close,
        Link2 ! close,
        stop_owner(Pid),
        stop_page_test_transport(Transport),
        _ = file:del_dir_r(Dir)
    end.

page_credit_caller_timeout_does_not_cancel_shared_page_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 32123},
    Ref = maps:get(ref, Fixture),
    Dir = temp_dir("page-credit-caller-detach"),
    Pid = start_owner_opts(Dir, undefined, #{page_timeout_ms => 5000}),
    Transport = start_page_test_transport(self()),
    Parent = self(),
    Link = spawn(fun() -> page_test_link(Parent) end),
    try
        Short = gen_server:send_request(Pid, owner_request({verify, Peer, Endpoint, Ref, finalize, 30})),
        {Lease, Pid} = receive_page_open(Peer, Endpoint, Ns),
        Long = gen_server:send_request(Pid, owner_request({verify, Peer, Endpoint, Ref, finalize, 5000})),
        ?assertMatch(#{pending := 1, queued := 0}, quod_foreign_log:stats()),
        Pid ! {link_up, Lease, Peer, quod_catchup:channel(Ns), Link},
        Binding = receive {page_test_bound, Link, Pid, BRef} -> BRef
                  after 1000 -> error(page_binding_not_installed)
                  end,
        Grant = crypto:strong_rand_bytes(16),
        Pid ! {catchup_credit, Link, Binding, Grant},
        ReqId = receive_page_request(Link, Binding, Grant),
        ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Short, 2000)),
        ?assertMatch(#{pending := 1, pulls := 1, page_bindings := 1}, quod_foreign_log:stats()),
        ?assert(is_process_alive(Link)),
        Pid ! {catchup_page, Link, Binding, Grant, ReqId,
               {ok, fixture_entry_blobs(Fixture), 2}, crypto:strong_rand_bytes(16)},
        ?assertMatch({reply, {ok, #{phase := finalize}}}, gen_server:wait_response(Long, 3000)),
        ?assertMatch(#{pending := 0, pulls := 0, page_bindings := 0}, quod_foreign_log:stats())
    after
        Link ! close,
        stop_owner(Pid),
        stop_page_test_transport(Transport),
        _ = file:del_dir_r(Dir)
    end.

page_credit_late_terminal_cannot_beat_queued_deadline_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 32124},
    Dir = temp_dir("page-credit-late-result"),
    Pid = start_owner_opts(Dir, undefined, #{page_timeout_ms => 300}),
    Transport = start_page_test_transport(self()),
    Parent = self(),
    Link = spawn(fun() -> page_test_link(Parent) end),
    try
        Request = gen_server:send_request(Pid, owner_request({verify, Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000})),
        {Lease, Pid} = receive_page_open(Peer, Endpoint, Ns),
        Pid ! {link_up, Lease, Peer, quod_catchup:channel(Ns), Link},
        Binding = receive {page_test_bound, Link, Pid, Ref} -> Ref
                  after 1000 -> error(page_binding_not_installed)
                  end,
        Grant = crypto:strong_rand_bytes(16),
        ReqId = begin Pid ! {catchup_credit, Link, Binding, Grant}, receive_page_request(Link, Binding, Grant) end,
        #{deadline := Deadline} = maps:get(ReqId, gen_server:call(Pid, test_page_rows)),
        ok = sys:suspend(Pid),
        %% Queue a valid terminal before the timer message, but process both
        %% only after expiry. Mailbox order cannot grant a new page budget.
        Pid ! {catchup_page, Link, Binding, Grant, ReqId,
               {ok, fixture_entry_blobs(Fixture), 2}, crypto:strong_rand_bytes(16)},
        receive after max(0, Deadline - quod_time:mono_ms()) + 20 -> ok end,
        ok = sys:resume(Pid),
        ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Request, 2000)),
        ?assertMatch(#{pending := 0, pulls := 0, page_bindings := 0}, quod_foreign_log:stats())
    after
        _ = catch sys:resume(Pid),
        Link ! close,
        stop_owner(Pid),
        stop_page_test_transport(Transport),
        _ = file:del_dir_r(Dir)
    end.

page_credit_cancelled_open_and_new_open_failure_leave_no_binding_test() ->
    Ns = unique_ns(),
    A = foreign_fixture(Ns),
    B = foreign_fixture(Ns),
    C = foreign_fixture(Ns),
    Peer = maps:get(pub, A),
    Endpoint = {"127.0.0.1", 32125},
    Dir = temp_dir("page-credit-opening-failure"),
    Pid = start_owner_opts(Dir, undefined, #{page_timeout_ms => 5000}),
    Transport = start_page_test_transport(self()),
    try
        First = gen_server:send_request(Pid, owner_request({verify, Peer, Endpoint, maps:get(ref, A), finalize, 5000})),
        {Lease1, Pid} = receive_page_open(Peer, Endpoint, Ns),
        [#{caller := PageOwner}] = maps:values(gen_server:call(Pid, test_page_rows)),
        exit(PageOwner, kill),
        ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 2000)),
        ?assertEqual(0, maps:get(page_bindings, quod_foreign_log:stats())),
        Second = gen_server:send_request(Pid, owner_request({verify, Peer, Endpoint, maps:get(ref, B), finalize, 5000})),
        {Lease2, Pid} = receive_page_open(Peer, Endpoint, Ns),
        Third = gen_server:send_request(Pid, owner_request({verify, Peer, Endpoint, maps:get(ref, C), finalize, 5000})),
        wait_page_pull_count(2, 1000),
        Pid ! {link_error, Lease1, Peer, quod_catchup:channel(Ns)},
        ?assertMatch(#{pulls := 2, page_bindings := 1}, quod_foreign_log:stats()),
        Pid ! {link_error, Lease2, Peer, quod_catchup:channel(Ns)},
        ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Second, 1000)),
        ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Third, 1000)),
        ?assertMatch(#{pending := 0, pulls := 0, page_bindings := 0}, quod_foreign_log:stats()),
        receive {page_test_open, _, _, _, _, _} -> error(open_failure_reopened_itself)
        after 0 -> ok
        end
    after
        stop_owner(Pid),
        stop_page_test_transport(Transport),
        _ = file:del_dir_r(Dir)
    end.

with_page_decode_fixture(Fun) ->
    with_page_decode_fixture(#{}, Fun).

with_page_decode_fixture(Options, Fun) ->
    Ns = unique_ns(),
    A = foreign_fixture(Ns),
    B = foreign_fixture(Ns),
    Dir = temp_dir("page-decode"),
    Owner = start_owner_opts(Dir, undefined, maps:merge(#{page_timeout_ms => 5000}, Options)),
    try
        Transport = start_page_test_transport(self()),
        Parent = self(),
        Link1 = spawn(fun() -> page_test_link(Parent) end),
        Link2 = spawn(fun() -> page_test_link(Parent) end),
        try
            Fun(#{owner => Owner, first => A, second => B, ns => Ns,
                  peer => maps:get(pub, A), endpoint => {"127.0.0.1", 32141},
                  link1 => Link1, link2 => Link2})
        after
            Link1 ! close,
            Link2 ! close,
            stop_page_test_transport(Transport)
        end
    after
        stop_owner(Owner),
        _ = file:del_dir_r(Dir)
    end.

page_verify_request(Owner, Peer, Endpoint, Fixture) ->
    gen_server:send_request(
      Owner, owner_request({verify, Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000})).

begin_single_page(#{owner := Owner, first := A, ns := Ns, peer := Peer,
                    endpoint := Endpoint, link1 := Link}) ->
    Call = page_verify_request(Owner, Peer, Endpoint, A),
    {Lease, Owner} = receive_page_open(Peer, Endpoint, Ns),
    Binding = install_page_test_link(Owner, Lease, Peer, Ns, Link),
    Grant = crypto:strong_rand_bytes(16),
    Owner ! {catchup_credit, Link, Binding, Grant},
    ReqId = receive_page_request(Link, Binding, Grant),
    #{call => Call, lease => Lease, binding => Binding, grant => Grant, req_id => ReqId}.

begin_queued_page_pair(C = #{owner := Owner, second := B, peer := Peer,
                             endpoint := Endpoint}) ->
    #{call := First, lease := Lease, binding := Binding,
      grant := Grant, req_id := Req1} = begin_single_page(C),
    Second = page_verify_request(Owner, Peer, Endpoint, B),
    wait_page_pull_count(2, 2000),
    Rows = gen_server:call(Owner, test_page_rows),
    [{Req2, Queued}] = maps:to_list(maps:remove(Req1, Rows)),
    #{first_call => First, second_call => Second, lease => Lease,
      binding => Binding, grant => Grant, first_id => Req1,
      second_id => Req2, queued => Queued}.

install_page_test_link(Owner, Lease, Peer, Ns, Link) ->
    Owner ! {link_up, Lease, Peer, quod_catchup:channel(Ns), Link},
    receive {page_test_bound, Link, Owner, Binding} -> Binding
    after 1000 -> error(page_binding_not_installed)
    end.

hold_next_page_decode(Owner, Token, Stage) ->
    gen_server:call(Owner, {test_hold_next_page_decode, self(), Token, Stage}).

receive_page_decode_gate(Stage, Token) ->
    receive
        {foreign_page_decode, Stage, Token, Worker, Key} -> {Worker, Key}
    after 2000 -> error({page_decode_gate_not_reached, Stage})
    end.

page_gate_complete(Worker, Token, Key, Verdict) ->
    Worker ! {test_complete_foreign_page, Token, Key, Verdict},
    receive
        {foreign_page_completion, Token, Result} -> Result
    after 2000 -> error(page_completion_gate_timeout)
    end.

page_binding_state(Owner, Binding) ->
    maps:get(Binding, gen_server:call(Owner, test_page_binding)).

page_owner_monitor_count(Owner, Worker) ->
    {monitors, Monitors} = process_info(Owner, monitors),
    length([Pid || {process, Pid} <- Monitors, Pid =:= Worker]).

assert_page_owner_drained() ->
    ?assertMatch(#{pending := 0, pulls := 0, page_bindings := 0},
                 quod_foreign_log:stats()).

serve_page_trace_current(Owner, Link, Binding, Fixture, Tag) ->
    receive
        {page_test_request, Link, Owner, Binding, Grant, ReqId, From, To} ->
            Chain = maps:get(chain, Fixture),
            Blobs = [begin {ok, Blob} = quod_ledger:encode_entry(Entry), Blob end
                     || Entry <- Chain, Height <- [entry_index(Entry)],
                        Height >= From, Height =< To],
            Owner ! {catchup_page, Link, Binding, Grant, ReqId,
                     {ok, Blobs, length(Chain)}, crypto:strong_rand_bytes(16)},
            serve_page_trace_current(Owner, Link, Binding, Fixture, Tag);
        {page_trace_current_result, Tag, Result} -> Result
    after 6000 -> error(page_trace_current_did_not_complete)
    end.

take_page_child_span(Name, #span{span_id = ParentId, trace_id = TraceId}) ->
    receive
        {quod_test_span, Span = #span{name = Name, parent_span_id = ParentId,
                                     trace_id = TraceId}} -> Span
    after 2000 -> error({missing_page_child_span, Name})
    end.

flush_page_trace_spans() ->
    %% All producers are stopped before this drain. Leave no unconsumed
    %% bootstrap/owner spans for the next fixture's name-based selector.
    receive
        {quod_test_span, _} -> flush_page_trace_spans()
    after 0 -> ok
    end.

collect_page_decode_calls(Barrier, Acc) ->
    receive
        {trace, Pid, call, {quod_catchup, decode_entries, [_Blobs, Mode]}} ->
            Key = {Pid, Mode},
            collect_page_decode_calls(Barrier, maps:update_with(Key, fun(N) -> N + 1 end, 1, Acc));
        {trace_delivered, all, Barrier} -> Acc
    after 2000 -> error(page_decode_trace_barrier_timeout)
    end.

assert_no_page_completion_to_replacement(Replacement, Barrier) ->
    receive
        {trace, Replacement, 'receive', {'$gen_call', _, {complete_page_decode, _, _}}} ->
            error(page_completion_re_resolved_the_owner);
        {trace, Replacement, 'receive', _} ->
            assert_no_page_completion_to_replacement(Replacement, Barrier);
        {trace_delivered, all, Barrier} -> ok
    after 2000 -> error(replacement_trace_barrier_timeout)
    end.

start_page_test_transport(Parent) ->
    ?assertEqual(undefined, quod_reg:where({transport, node})),
    {Pid, MRef} = spawn_monitor(fun() ->
        true = quod_reg:reg({transport, node}),
        Parent ! {page_test_transport_ready, self()},
        page_test_transport_loop(Parent)
    end),
    receive {page_test_transport_ready, Pid} -> {Pid, MRef}
    after 1000 -> error(page_test_transport_timeout)
    end.

page_test_transport_loop(Parent) ->
    receive
        {'$gen_cast', {open_link_pinned_lease, Peer, Endpoint, Chan, {Producer, Lease}}} ->
            Parent ! {page_test_open, Peer, Endpoint, Chan, Producer, Lease},
            page_test_transport_loop(Parent);
        {'$gen_cast', {release_link_pinned, Peer, Endpoint, Chan, Lease}} ->
            Parent ! {page_test_release, Peer, Endpoint, Chan, Lease},
            page_test_transport_loop(Parent);
        stop -> ok;
        _ -> page_test_transport_loop(Parent)
    end.

stop_page_test_transport({Pid, MRef}) ->
    Pid ! stop,
    receive {'DOWN', MRef, process, Pid, _} -> ok
    after 1000 -> exit(Pid, kill), error(page_test_transport_stop_timeout)
    end.

page_test_link(Observer) ->
    receive
        {observer, Parent} -> page_test_link(Parent);
        {bind_catchup, Producer, Binding} ->
            Observer ! {page_test_bound, self(), Producer, Binding},
            page_test_link(Observer);
        {request_page, Producer, Binding, Grant, ReqId, From, To} ->
            Observer ! {page_test_request, self(), Producer, Binding, Grant, ReqId, From, To},
            page_test_link(Observer);
        close -> ok
    end.

receive_page_open(Peer, Endpoint, Ns) ->
    Chan = quod_catchup:channel(Ns),
    receive {page_test_open, Peer, Endpoint, Chan, Producer, Lease} -> {Lease, Producer}
    after 2000 -> error(page_open_not_requested)
    end.

receive_page_request(Link, Binding, Grant) ->
    receive_page_request_range(Link, Binding, Grant, 1, 2).

receive_page_request_range(Link, Binding, Grant, From, To) ->
    receive {page_test_request, Link, _, Binding, Grant, ReqId, From, To} -> ReqId
    after 2000 -> error(page_request_not_sent)
    end.

fixture_entry_blobs(Fixture) ->
    [begin {ok, Blob} = quod_ledger:encode_entry(Entry), Blob end
     || Entry <- maps:get(chain, Fixture)].

wait_page_pull_count(Expected, Left) when Left > 0 ->
    case maps:get(pulls, quod_foreign_log:stats()) of
        Expected -> ok;
        _ -> receive after 5 -> ok end, wait_page_pull_count(Expected, Left - 5)
    end;
wait_page_pull_count(Expected, _Left) -> error({page_pull_count_timeout, Expected}).

final_confirmation_reaps_held_pull_before_worker_done_test_() ->
    [{atom_to_list(Stage), fun() -> final_confirmation_reaps_held_pull(Stage) end}
     || Stage <- [sent, decoding]].

final_confirmation_reaps_held_pull(Stage) ->
    with_confirmation_fixture(
      fun(C) ->
          #{owner := Owner, peers := [A, B, D, Held], links := Links} = C,
          {Call, Token, Pulls} = begin_confirmation_wave(C),
          #{id := HeldId, caller := Child} = maps:get(Held, Pulls),
          HeldLink = maps:get(Held, Links),
          ChildMonitor = erlang:monitor(process, Child),
          LinkMonitor = erlang:monitor(process, HeldLink),
          case Stage of
              sent -> ok;
              decoding ->
                  DecodeToken = make_ref(),
                  ok = hold_next_page_decode(Owner, DecodeToken, before_completion),
                  reply_confirmation_pull(C, maps:get(Held, Pulls), {ok, [], 2}),
                  {Child, _} = receive_page_decode_gate(before_completion, DecodeToken)
          end,
          HeldRow = maps:get(HeldId, gen_server:call(Owner, test_page_rows)),
          ?assert(maps:get(deadline, HeldRow) > quod_time:mono_ms()),
          ?assertEqual(1, page_owner_monitor_count(Owner, Child)),
          lists:foreach(
            fun(Peer) -> reply_confirmation_pull(C, maps:get(Peer, Pulls), {ok, [], 2}) end,
            [A, B, D]),
          %% No response/continue message is ever sent to the held peer.
          %% A collect-all implementation cannot reach this barrier while
          %% that peer and its original page budget remain unresolved.
          Worker = receive_confirmation_return(Token, true),
          assert_confirmation_pull_reaped(
            C, Call, Worker, HeldId, Child, ChildMonitor, HeldLink, LinkMonitor),
          ?assertMatch(#{pending := 1, pulls := 0}, quod_foreign_log:stats()),
          Worker ! {release_foreign_confirmation, Token},
          ?assertMatch({reply, {ok, #{slot := 2}}}, gen_server:wait_response(Call, 3000))
      end).

final_confirmation_impossible_reaps_two_held_pulls_before_worker_done_test() ->
    with_confirmation_fixture(
      fun(C) ->
          #{peers := [A, B, Held1, Held2], links := Links} = C,
          {Call, Token, Pulls} = begin_confirmation_wave(C),
          Held = [begin
                      #{id := Id, caller := Child} = maps:get(Peer, Pulls),
                      Link = maps:get(Peer, Links),
                      {Id, Child, erlang:monitor(process, Child),
                       Link, erlang:monitor(process, Link)}
                  end || Peer <- [Held1, Held2]],
          reply_confirmation_pull(C, maps:get(A, Pulls), {error, not_ready}),
          reply_confirmation_pull(C, maps:get(B, Pulls), {error, server_error}),
          Worker = receive_confirmation_return(Token, false),
          lists:foreach(
            fun({Id, Child, CM, Link, LM}) ->
                assert_confirmation_pull_reaped(C, Call, Worker, Id, Child, CM, Link, LM)
            end, Held),
          ?assertMatch(#{pending := 1, pulls := 0}, quod_foreign_log:stats()),
          cancel_held_confirmation(Worker, Call)
      end).

final_confirmation_exhausts_peer_endpoints_before_counting_failure_test() ->
    with_confirmation_fixture(
      fun(C0) ->
          #{owner := Owner, peers := [A, B, D, E], routes := Routes, ns := Ns} = C0,
          [{A, [Primary]} | Rest] = Routes,
          Alternative = {"127.0.0.1", 19114},
          %% A real authenticated current contact precedes the certified
          %% historical endpoint. Arbitrary extra supplied addresses cannot
          %% create this alternative for an already-certified validator.
          C = C0#{routes := [{A, [Alternative, Primary]} | Rest],
                   contact => {A, Alternative}},
          Parent = self(),
          AlternativeLink = spawn(fun() -> page_test_link(Parent) end),
          try
              {Call, Token, Pulls} = begin_confirmation_wave(C),
              reply_confirmation_pull(C, maps:get(B, Pulls), {ok, [], 2}),
              reply_confirmation_pull(C, maps:get(D, Pulls), {ok, [], 2}),
              reply_confirmation_pull(C, maps:get(E, Pulls), {error, not_ready}),
              reply_confirmation_pull(C, maps:get(A, Pulls), {error, server_error}),
              {Lease, Owner} = receive_page_open(A, Primary, Ns),
              Binding = install_page_test_link(Owner, Lease, A, Ns, AlternativeLink),
              Owner ! {catchup_credit, AlternativeLink, Binding, crypto:strong_rand_bytes(16)},
              AlternativePull = receive_confirmation_pull(Owner, AlternativeLink, 3, 3),
              ?assertEqual(maps:get(caller, maps:get(A, Pulls)), maps:get(caller, AlternativePull)),
              reply_confirmation_pull(C, AlternativePull, {ok, [], 2}),
              Worker = receive_confirmation_return(Token, true),
              Worker ! {release_foreign_confirmation, Token},
              ?assertMatch({reply, {ok, #{slot := 2}}}, gen_server:wait_response(Call, 3000))
          after
              AlternativeLink ! close
          end
      end).

final_confirmation_duplicate_owner_probe_reply_cannot_supply_third_peer_test() ->
    with_confirmation_fixture(
      fun(C) ->
          #{peers := [A, B, D, E]} = C,
          {Call, Token, Pulls} = begin_confirmation_wave(C),
          #{caller := ChildA} = maps:get(A, Pulls),
          #{caller := ChildB} = maps:get(B, Pulls),
          1 = erlang:trace(ChildA, true, [send, {tracer, self()}]),
          1 = erlang:trace(ChildB, true, [send, {tracer, self()}]),
          reply_confirmation_pull(C, maps:get(A, Pulls), {ok, [], 2}),
          {Worker, Message} = receive
                                  {trace, ChildA, send,
                                   {foreign_probe, _, ChildA, {A, _}, true} = Sent, Collector} ->
                                      {Collector, Sent}
                              after 2000 -> error(real_confirmation_result_not_observed)
                              end,
          Worker ! Message,
          Worker ! Message,
          reply_confirmation_pull(C, maps:get(B, Pulls), {ok, [], 2}),
          receive
              {trace, ChildB, send, {foreign_probe, _, ChildB, {B, _}, true}, Worker} -> ok
          after 2000 -> error(second_real_confirmation_result_not_observed)
          end,
          reply_confirmation_pull(C, maps:get(D, Pulls), {error, not_ready}),
          reply_confirmation_pull(C, maps:get(E, Pulls), {error, server_error}),
          %% These messages came from actual owner pulls and the actual tip
          %% verifier. Replaying A's authentic result still supplies only A.
          Worker = receive_confirmation_return(Token, false),
          ?assertEqual(timeout, gen_server:wait_response(Call, 0)),
          cancel_held_confirmation(Worker, Call)
      end).

initial_probe_waits_for_delayed_highest_before_final_confirmation_test() ->
    with_confirmation_fixture(
      fun(C) ->
          #{owner := Owner, peers := [A, B, D, Highest], links := Links,
            fixture := Fixture} = C,
          Token = make_ref(),
          ok = gen_server:call(Owner, {test_hold_next_confirmation, self(), Token}),
          Call = confirmation_current_request(C),
          Initial = receive_initial_confirmation_pulls(C),
          lists:foreach(
            fun(Peer) -> reply_confirmation_pull(C, maps:get(Peer, Initial), {ok, [], 2}) end,
            [A, B, D]),
          %% Completion of these real decodes is observable without sleeps.
          lists:foreach(
            fun(Peer) -> await_confirmation_child_result(maps:get(Peer, Initial)) end,
            [A, B, D]),
          ?assertEqual(timeout, gen_server:wait_response(Call, 0)),
          receive
              {foreign_confirmation_returned, Token, _, _} -> error(initial_probe_short_circuited);
              {page_test_request, _, Owner, _, _, _, _, _} -> error(initial_probe_advanced_early)
          after 0 -> ok end,
          [_, _, Entry3, _] = maps:get(chain, Fixture),
          {ok, Blob3} = quod_ledger:encode_entry(Entry3),
          reply_confirmation_pull(C, maps:get(Highest, Initial), {ok, [Blob3], 4}),
          await_confirmation_child_result(maps:get(Highest, Initial)),
          HighLink = maps:get(Highest, Links),
          Advance = receive_confirmation_pull(Owner, HighLink, 3, 4),
          reply_confirmation_pull(C, Advance, {ok, lists:nthtail(2, fixture_entry_blobs(Fixture)), 4}),
          Final = maps:from_list(
                    [{Peer, receive_confirmation_pull(Owner, maps:get(Peer, Links), 5, 5)}
                     || Peer <- [A, B, D, Highest]]),
          lists:foreach(
            fun(Peer) -> reply_confirmation_pull(C, maps:get(Peer, Final), {ok, [], 4}) end,
            [A, B, D]),
          Worker = receive_confirmation_return(Token, true),
          Worker ! {release_foreign_confirmation, Token},
          ?assertMatch({reply, {ok, #{slot := 4}}}, gen_server:wait_response(Call, 3000))
      end).

confirmation_candidates_group_distinct_members_in_endpoint_order_test() ->
    [A, B, C, D, Outsider] = [key({confirmation_peer, I}) || I <- lists:seq(1, 5)],
    E1 = {"127.0.0.1", 19111},
    E2 = {"127.0.0.1", 19112},
    E3 = {"127.0.0.1", 19113},
    Hints = [{A, [E1, E1]}, {Outsider, [E1]}, {B, [E3]},
             {A, [E2, E1]}, {B, [E3]}, {C, [E1]}, {D, [E1]}],
    Candidates = quod_foreign_log:test_confirmation_candidates(Hints, [A, B, C, D]),
    ?assertEqual([{A, [E1, E2]}, {B, [E3]}, {C, [E1]}, {D, [E1]}], Candidates),
    ?assertEqual([], quod_foreign_log:test_confirmation_candidates([{Outsider, [E1]}], [A, B, C, D])).

confirmation_duplicate_and_mismatched_results_do_not_inflate_quorum_test() ->
    Items = confirmation_collector_items(),
    with_controlled_confirmation_collector(
      Items, {threshold, 3},
      fun(Collector, Token, Children) ->
          [A, B, C, D] = Items,
          ChildA = maps:get(A, Children),
          1 = erlang:trace(ChildA, true, [send, {tracer, self()}]),
          ChildA ! {confirmation_probe_reply, Token, true},
          Message = receive
                        {trace, ChildA, send, {foreign_probe, _, ChildA, A, true} = Sent, Collector} -> Sent
                    after 2000 -> error(confirmation_probe_result_not_observed)
                    end,
          {foreign_probe, Tag, ChildA, A, true} = Message,
          %% Replay the real tag/PID/item after that exact peer has replied.
          Collector ! Message,
          Collector ! Message,
          ChildB = maps:get(B, Children),
          ChildC = maps:get(C, Children),
          1 = erlang:trace(Collector, true, ['receive', {tracer, self()}]),
          Collector ! {foreign_probe, Tag, self(), A, true},
          Collector ! {foreign_probe, make_ref(), ChildB, B, true},
          Mismatch = {foreign_probe, Tag, ChildC, {key(noncommittee), []}, true},
          Collector ! Mismatch,
          receive {trace, Collector, 'receive', Mismatch} -> ok
          after 2000 -> error(mismatched_confirmation_not_delivered)
          end,
          ChildB ! {confirmation_probe_reply, Token, true},
          ChildC ! {confirmation_probe_reply, Token, false},
          maps:get(D, Children) ! {confirmation_probe_reply, Token, false},
          %% All genuine replies are only two distinct successes. This final
          %% false assertion also detects a premature true, not just absence
          %% observed before the collector has had a chance to run.
          ?assertEqual(false, receive_controlled_confirmation_result(Collector, Token))
      end).

confirmation_wrong_down_monitor_does_not_consume_live_peer_test() ->
    Items = confirmation_collector_items(),
    with_controlled_confirmation_collector(
      Items, {threshold, 3},
      fun(Collector, Token, Children) ->
          [A, B, C, D] = Items,
          ChildC = maps:get(C, Children),
          1 = erlang:trace(Collector, true, ['receive', {tracer, self()}]),
          WrongDown = {'DOWN', make_ref(), process, ChildC, normal},
          Collector ! WrongDown,
          receive {trace, Collector, 'receive', WrongDown} -> ok
          after 2000 -> error(wrong_monitor_down_not_delivered)
          end,
          maps:get(A, Children) ! {confirmation_probe_reply, Token, true},
          maps:get(B, Children) ! {confirmation_probe_reply, Token, true},
          maps:get(D, Children) ! {confirmation_probe_reply, Token, false},
          ChildC ! {confirmation_probe_reply, Token, true},
          ?assertEqual(true, receive_controlled_confirmation_result(Collector, Token))
      end).

confirmation_normal_child_down_makes_quorum_impossible_test() ->
    Items = confirmation_collector_items(),
    with_controlled_confirmation_collector(
      Items, {threshold, 3},
      fun(Collector, Token, Children) ->
          [A, B, C, D] = Items,
          Held = [{Child, erlang:monitor(process, Child)}
                  || Item <- [C, D], Child <- [maps:get(Item, Children)]],
          maps:get(A, Children) ! {confirmation_probe_exit, Token},
          maps:get(B, Children) ! {confirmation_probe_exit, Token},
          ?assertEqual(false, receive_controlled_confirmation_result(Collector, Token)),
          lists:foreach(
            fun({Child, Monitor}) ->
                receive {'DOWN', Monitor, process, Child, killed} -> ok
                after 2000 -> error(impossible_confirmation_did_not_kill_child)
                end
            end, Held)
      end).

confirmation_responses_preserve_original_collector_deadline_test() ->
    Items = confirmation_collector_items(),
    with_controlled_confirmation_collector(
      Items, {threshold, 3},
      fun(Collector, Token, Children) ->
          1 = erlang:trace_pattern({quod_foreign_log, collect_probes, 4}, true, [local]),
          1 = erlang:trace(Collector, true, [call, {tracer, self()}]),
          try
              [A, B, C, D] = Items,
              maps:get(A, Children) ! {confirmation_probe_reply, Token, true},
              Deadline = receive_confirmation_collector_deadline(Collector, 3, 1),
              %% Deliver B in a later monotonic millisecond. Without this
              %% test-only scheduling, a reset-to-now bug could accidentally
              %% produce the same deadline for back-to-back responses.
              _ = erlang:send_after(5, maps:get(B, Children), {confirmation_probe_reply, Token, true}),
              ?assertEqual(Deadline, receive_confirmation_collector_deadline(Collector, 2, 2)),
              maps:get(C, Children) ! {confirmation_probe_reply, Token, false},
              ?assertEqual(Deadline, receive_confirmation_collector_deadline(Collector, 1, 2)),
              maps:get(D, Children) ! {confirmation_probe_reply, Token, false},
              ?assertEqual(false, receive_controlled_confirmation_result(Collector, Token))
          after
              _ = erlang:trace_pattern({quod_foreign_log, collect_probes, 4}, false, [local])
          end
      end).

receive_confirmation_collector_deadline(Collector, PendingCount, ConfirmedCount) ->
    receive
        {trace, Collector, call,
         {quod_foreign_log, collect_probes,
          [_, Pending, Deadline, {threshold, 3, Confirmed}]}}
          when map_size(Pending) =:= PendingCount,
               map_size(Confirmed) =:= ConfirmedCount -> Deadline
    after 2000 -> error(confirmation_collector_deadline_not_observed)
    end.

confirmation_collect_all_and_threshold_agree_across_response_orders_test_() ->
    {timeout, 30, fun() ->
        Orders = confirmation_permutations([1, 2, 3, 4]),
        lists:foreach(
          fun(Outcomes) ->
              Expected = length([ok || true <- Outcomes]) >= 3,
              lists:foreach(
                fun(Order) ->
                    ?assertEqual(Expected, ordered_confirmation_result(Outcomes, Order, all)),
                    ?assertEqual(Expected, ordered_confirmation_result(Outcomes, Order, {threshold, 3}))
                end, Orders)
          end, [[true, true, true, true], [true, true, true, false],
                [true, true, false, false], [true, false, false, false],
                [false, false, false, false]])
    end}.

ordered_confirmation_result(Outcomes, Order, Completion) ->
    Items = confirmation_collector_items(),
    OrderedItems = [lists:nth(I, Items) || I <- Order],
    Parent = self(),
    Token = make_ref(),
    %% Continue each child only after observing the collector receive the
    %% previous result: response order is not assumed from scheduling.
    Probe = fun(Item) ->
                Parent ! {confirmation_order_child, Token, Item, self()},
                receive {confirmation_order_reply, Token, Value} -> Value end
            end,
    {Collector, Monitor} = spawn_monitor(
                             fun() ->
                                 Result = quod_foreign_log:test_parallel_probes(Items, Probe, 10000, Completion),
                                 Parent ! {confirmation_order_result, Token, self(), Result}
                             end),
    Children = maps:from_list(
                 [receive {confirmation_order_child, Token, Item, Child} -> {Item, Child}
                  after 2000 -> error(confirmation_order_child_not_started)
                  end || Item <- Items]),
    try
        1 = erlang:trace(Collector, true, ['receive', {tracer, self()}]),
        lists:foreach(
          fun(Item) ->
              Child = maps:get(Item, Children),
              Position = proplists:get_value(Item, lists:zip(Items, lists:seq(1, 4))),
              Child ! {confirmation_order_reply, Token, lists:nth(Position, Outcomes)},
              receive
                  {trace, Collector, 'receive', {foreign_probe, _, Child, Item, _}} -> ok;
                  {confirmation_order_result, Token, Collector, Result} ->
                      throw({confirmation_order_done, Result})
              after 2000 -> error(confirmation_order_not_consumed)
              end
          end, OrderedItems),
        receive {confirmation_order_result, Token, Collector, Result} -> confirmation_boolean(Completion, Result)
        after 2000 -> error(confirmation_order_no_result)
        end
    catch
        throw:{confirmation_order_done, EarlyResult} -> confirmation_boolean(Completion, EarlyResult)
    after
        _ = erlang:demonitor(Monitor, [flush]),
        exit(Collector, kill),
        maps:foreach(fun(_, Child) -> exit(Child, kill) end, Children),
        flush_confirmation_traces(Collector)
    end.

confirmation_boolean(all, Results) -> length([ok || {_, true} <- Results]) >= 3;
confirmation_boolean({threshold, 3}, Result) -> Result.

confirmation_permutations([]) -> [[]];
confirmation_permutations(Items) ->
    [[Item | Rest] || Item <- Items, Rest <- confirmation_permutations(Items -- [Item])].

confirmation_collector_items() -> [{key({confirmation_collector, I}), [I]} || I <- lists:seq(1, 4)].

with_controlled_confirmation_collector(Items, Completion, Fun) ->
    Parent = self(),
    Token = make_ref(),
    Probe = fun(Item) ->
                Parent ! {confirmation_probe_started, Token, Item, self()},
                receive
                    {confirmation_probe_reply, Token, Result} -> Result;
                    {confirmation_probe_exit, Token} -> exit(normal)
                end
            end,
    {Collector, Monitor} = spawn_monitor(
                             fun() ->
                                 Result = quod_foreign_log:test_parallel_probes(Items, Probe, 10000, Completion),
                                 Parent ! {confirmation_probe_collected, Token, self(), Result}
                             end),
    Children = maps:from_list(
                 [receive {confirmation_probe_started, Token, Item, Child} -> {Item, Child}
                  after 2000 -> error(confirmation_probe_not_started)
                  end || Item <- Items]),
    try Fun(Collector, Token, Children)
    after
        _ = erlang:demonitor(Monitor, [flush]),
        exit(Collector, kill),
        maps:foreach(fun(_, Child) -> exit(Child, kill) end, Children),
        flush_confirmation_traces(Collector)
    end.

receive_controlled_confirmation_result(Collector, Token) ->
    receive {confirmation_probe_collected, Token, Collector, Result} -> Result
    after 2000 -> error(controlled_confirmation_did_not_finish)
    end.

flush_confirmation_traces(Collector) ->
    receive
        {trace, Collector, _, _} -> flush_confirmation_traces(Collector);
        {trace, _, send, _, Collector} -> flush_confirmation_traces(Collector)
    after 0 -> ok end.

with_confirmation_fixture(Fun) ->
    Fixture = four_member_confirmation_fixture(unique_ns()),
    Peers = maps:get(peers, Fixture),
    Routes = maps:get(routes, Fixture),
    Dir = temp_dir("threshold-confirmation"),
    Owner = start_owner_opts(Dir, undefined, #{page_timeout_ms => 30000}),
    Transport = start_page_test_transport(self()),
    Parent = self(),
    Links = maps:from_list([{Peer, spawn(fun() -> page_test_link(Parent) end)} || Peer <- Peers]),
    C = #{owner => Owner, fixture => Fixture, peers => Peers, routes => Routes,
          links => Links, ns => maps:get(ns, Fixture)},
    try
        [First | _] = Peers,
        [{First, [Endpoint]} | _] = Routes,
        Seed = gen_server:send_request(
                 Owner, owner_request({verify, First, Endpoint, maps:get(ref, Fixture), transaction, 10000})),
        Link = maps:get(First, Links),
        open_confirmation_link(C, First, Endpoint),
        SeedPull = receive_confirmation_pull(Owner, Link, 1, 2),
        reply_confirmation_pull(C, SeedPull, {ok, lists:sublist(fixture_entry_blobs(Fixture), 2), 2}),
        ?assertMatch({reply, {ok, #{slot := 2}}}, gen_server:wait_response(Seed, 3000)),
        assert_page_owner_drained(),
        Fun(C)
    after
        stop_owner(Owner),
        maps:foreach(fun(_, Link) -> Link ! close end, Links),
        stop_page_test_transport(Transport),
        _ = file:del_dir_r(Dir)
    end.

confirmation_current_request(C = #{owner := Owner, fixture := Fixture, routes := Routes, ns := Ns}) ->
    gen_server:send_request(
      Owner, current_request(Routes, {Ns, maps:get(anchor, Fixture)}, maps:get(contact, C, none), 10000)).

begin_confirmation_wave(C = #{owner := Owner, peers := Peers, links := Links}) ->
    Token = make_ref(),
    ok = gen_server:call(Owner, {test_hold_next_confirmation, self(), Token}),
    Call = confirmation_current_request(C),
    Initial = receive_initial_confirmation_pulls(C),
    lists:foreach(
      fun(Peer) -> reply_confirmation_pull(C, maps:get(Peer, Initial), {ok, [], 2}) end, Peers),
    lists:foreach(fun(Peer) -> await_confirmation_child_result(maps:get(Peer, Initial)) end, Peers),
    Pulls = maps:from_list(
              [{Peer, receive_confirmation_pull(Owner, maps:get(Peer, Links), 3, 3)}
               || Peer <- Peers]),
    {Call, Token, Pulls}.

receive_initial_confirmation_pulls(C = #{owner := Owner, routes := Routes, links := Links}) ->
    lists:foreach(fun({Peer, [Endpoint | _]}) -> open_confirmation_link(C, Peer, Endpoint) end, Routes),
    maps:from_list(
      [{Peer, monitor_confirmation_pull(receive_confirmation_pull(Owner, maps:get(Peer, Links), 3, 3))}
       || {Peer, _} <- Routes]).

open_confirmation_link(#{owner := Owner, ns := Ns, links := Links}, Peer, Endpoint) ->
    {Lease, Owner} = receive_page_open(Peer, Endpoint, Ns),
    Link = maps:get(Peer, Links),
    Binding = install_page_test_link(Owner, Lease, Peer, Ns, Link),
    Owner ! {catchup_credit, Link, Binding, crypto:strong_rand_bytes(16)}.

receive_confirmation_pull(Owner, Link, From, To) ->
    receive
        {page_test_request, Link, Owner, Binding, Grant, Id, From, To} ->
            #{caller := Caller, deadline := Deadline} =
                maps:get(Id, gen_server:call(Owner, test_page_rows)),
            #{id => Id, caller => Caller, link => Link, binding => Binding,
              grant => Grant, deadline => Deadline}
    after 3000 -> error({confirmation_pull_not_sent, From, To})
    end.

monitor_confirmation_pull(Pull = #{caller := Child}) ->
    Pull#{monitor => erlang:monitor(process, Child)}.

await_confirmation_child_result(#{caller := Child, monitor := Monitor}) ->
    receive {'DOWN', Monitor, process, Child, normal} -> ok
    after 2000 -> error(initial_confirmation_child_not_done)
    end.

reply_confirmation_pull(#{owner := Owner},
                        #{link := Link, binding := Binding, grant := Grant, id := Id}, Result) ->
    Owner ! {catchup_page, Link, Binding, Grant, Id, Result, crypto:strong_rand_bytes(16)}.

receive_confirmation_return(Token, Expected) ->
    receive
        {foreign_confirmation_returned, Token, Worker, Result} ->
            ?assertEqual(Expected, Result),
            Worker
    after 2000 -> error({confirmation_did_not_short_circuit, Expected})
    end.

cancel_held_confirmation(Worker, Call) ->
    %% The collector's false has already been observed. Routed current work
    %% normally parks for a later route/history event after it returns retry;
    %% terminate the still-held worker only for fixture cleanup, after every
    %% assertion that must precede whole-request cancellation.
    exit(Worker, kill),
    ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Call, 3000)),
    %% Pull cleanup is immediate even if losing writer custody starts the
    %% separate disk-only reconstruction. That job may not own a page lease.
    ?assertMatch(#{pulls := 0, page_bindings := 0}, quod_foreign_log:stats()),
    maps:foreach(fun(Identity, #{height := Height}) ->
        await_history_ready(Identity, Height)
    end, quod_foreign_log:test_lifecycle_state()),
    assert_page_owner_drained().

assert_confirmation_pull_reaped(#{owner := Owner}, Call, Worker,
                               Id, Child, ChildMonitor, Link, LinkMonitor) ->
    receive {'DOWN', ChildMonitor, process, Child, killed} -> ok
    after 2000 -> error(held_confirmation_child_survived)
    end,
    %% Link closure is caused by the owner's immediate-puller DOWN handler.
    %% Waiting on that local event orders the read after cancellation without
    %% requiring a transport acknowledgement or polling owner state.
    receive {'DOWN', LinkMonitor, process, Link, normal} -> ok
    after 2000 -> error(held_confirmation_link_not_closed)
    end,
    ?assert(is_process_alive(Worker)),
    ?assertEqual(timeout, gen_server:wait_response(Call, 0)),
    ?assertNot(maps:is_key(Id, gen_server:call(Owner, test_page_rows))),
    ?assertEqual(0, page_owner_monitor_count(Owner, Child)),
    ?assertMatch(#{pending := 1}, quod_foreign_log:stats()).

four_member_confirmation_fixture(Ns) ->
    Members = lists:sort(
                [begin
                     {Pub, Seed} = quod_identity:generate(),
                     {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}
                 end || _ <- lists:seq(1, 4)]),
    [{Author, Signer} | _] = Members,
    Peers = [Pub || {Pub, _} <- Members],
    Routes = [{Peer, [{"127.0.0.1", 19000 + I}]} || {Peer, I} <- lists:zip(Peers, lists:seq(0, 3))],
    GenesisTx = quod_simplex:test_genesis_tx(
                  #{committee => [{Peer, Host, Port} || {Peer, [{Host, Port}]} <- tl(Routes)],
                    node_addr => {"127.0.0.1", 19000}},
                  Ns, Author, key(confirmation_genesis_incarnation)),
    {ok, Genesis} = quod_ledger:new_entry(1, {batch, [GenesisTx]}, 0, none),
    Anchor = entry_hash(Genesis),
    Identity = {Ns, Anchor},
    {ok, [Genesis], Projection} = quod_catchup:verify_forward(
                                   Ns, Anchor, quod_simplex:history_projection(Identity), 1, [Genesis]),
    ?assertEqual(Peers, quod_simplex:history_committee(Projection)),
    {ok, Binding} = quod_simplex:history_binding(Identity, Author, Projection),
    Entries = [begin
                   Tx0 = #transaction{
                            origin = Identity, proof_id = key({confirmation_proof, Slot}),
                            plan_digest = key({confirmation_plan, Slot}),
                            goal = durable_goal({confirmation_content, Slot}), result = durable_result(),
                            diff = [{assert, {{confirmation_content, Slot}, true}}],
                            read_check = #{}, author = Author, author_seq = Slot - 1,
                            submitted_at = Slot - 1, sig = none},
                   {ok, Tx} = quod_transaction:sign(Binding, quod_transaction:bind_id(Identity, Tx0), Signer),
                   {committee_content_entry(Ns, Anchor, Members, Slot, [Tx]), Tx}
               end || Slot <- lists:seq(2, 4)],
    [{ReferencedEntry, Referenced} | _] = Entries,
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, ReferencedEntry, Referenced),
    #{ns => Ns, anchor => Anchor, ref => Ref, peers => Peers, routes => Routes,
      chain => [Genesis | [Entry || {Entry, _} <- Entries]]}.

required_references_is_exhaustive_test() ->
    A = {<<"a">>, key(1)},
    B = {<<"b">>, key(2)},
    BeginA = ref(A, 1, 11),
    PrepareA = ref(A, 2, 12),
    PrepareB = ref(B, 2, 13),
    Decision = ref(A, 3, 14),
    FinalizeA = ref(A, 4, 15),
    FinalizeB = ref(B, 4, 16),
    Target = A,
    ?assertEqual(
       {ok, []},
       quod_foreign_log:required_references(
         control('begin', Target,
                 {quod_dtx_begin, 3, ignored, none, ignored}))),
    ?assertEqual(
       {ok, [{'begin', BeginA}]},
       quod_foreign_log:required_references(
         control(prepare, Target,
                 {quod_dtx_prepare, 3, key(20), BeginA, ignored,
                  key(21), <<>>}))),
    ?assertEqual(
       {ok, [{'begin', BeginA}, {prepare, PrepareA}, {prepare, PrepareB}]},
       quod_foreign_log:required_references(
         control(decision, Target,
                 {quod_dtx_decision, 3, key(20), BeginA, commit,
                  [{A, PrepareA}, {B, PrepareB}], none}))),
    ?assertEqual(
       {ok, [{decision, Decision}, {prepare, PrepareA}]},
       quod_foreign_log:required_references(
         control(finalize, Target,
                 {quod_dtx_finalize, 3, key(20), Decision, commit,
                  PrepareA, 2}))),
    ?assertEqual(
       {ok, [{decision, Decision}]},
       quod_foreign_log:required_references(
         control(finalize, Target,
                 {quod_dtx_finalize, 3, key(20), Decision, abort, none, 1}))),
    ?assertEqual(
       {ok, [{decision, Decision},
             {finalize, FinalizeA}, {finalize, FinalizeB}]},
       quod_foreign_log:required_references(
         control(complete, Target,
                 {quod_dtx_complete, 3, key(20), Decision,
                  [{A, FinalizeA, 2}, {B, FinalizeB, 3}]}))),
    %% A row cannot smuggle a reference for a different anchored identity.
    ?assertEqual(
       {error, invalid_control},
       quod_foreign_log:required_references(
         control(decision, Target,
                 {quod_dtx_decision, 3, key(20), BeginA, commit,
                  [{B, PrepareA}], none}))),
    ?assertEqual(
       {error, invalid_control},
       quod_foreign_log:required_references(
         control(complete, Target,
                 {quod_dtx_complete, 3, key(20), Decision,
                  [{A, FinalizeA, 16#10000000000000000}]}))),
    %% Ingress sees the unsigned canonical record before consensus wraps it;
    %% it must use the same exhaustive reference extractor as validators.
    Fixture = quod_ct:dtx_prepare_fixture(),
    ?assertEqual(
       {ok, [{'begin', maps:get(begin_ref, Fixture)}]},
       quod_foreign_log:required_references(maps:get(prepare, Fixture))).

invalid_public_timeout_is_rejected_without_owner_test() ->
    ?assertEqual(
       {error, bad_foreign_reference},
       quod_foreign_log:verify_reference(
         ref({<<"timeout">>, key(9)}, 1, 10), finalize, invalid)).

restart_checkpoint_projection_mismatch_refetches_certified_prefix_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Ref = maps:get(ref, Fixture),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31979},
    Dir = temp_dir("checkpoint-projection-mismatch"),
    BaseFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Pid = start_owner(Dir, BaseFetch),
    try
        ?assertMatch({ok, #{identity := Identity, phase := finalize}},
                     quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000))
    after
        stop_owner(Pid)
    end,
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    Path = filename:join(quod_ledger_store:ns_dir(Dir, CacheNs), "checkpoint.term"),
    {ok, Blob} = file:read_file(Path),
    Checkpoint = binary_to_term(Blob, [safe]),
    Projection = element(7, Checkpoint),
    %% Keep a structurally valid checkpoint with the same identity and height.
    %% Only replaying its certified ledger reveals that its timestamp differs;
    %% disk presence must not manufacture a warm verified-session authority.
    ForgedProjection = Projection#{timestamp := maps:get(timestamp, Projection) + 1},
    ?assert(quod_foreign_log:valid_projection(ForgedProjection, Identity)),
    ok = file:write_file(Path, term_to_binary(setelement(7, Checkpoint, ForgedProjection))),
    Parent = self(),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                Parent ! {checkpoint_mismatch_refetch, From},
                BaseFetch(P, E, RequestedNs, From, To)
            end,
    Pid2 = start_owner(Dir, Fetch),
    try
        ?assertMatch({ok, #{identity := Identity, phase := finalize}},
                     quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        receive {checkpoint_mismatch_refetch, 1} -> ok
        after 1000 -> error(inconsistent_checkpoint_was_trusted)
        end,
        ?assertEqual({2, Projection}, cache_checkpoint(Dir, Identity))
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(Dir)
    end.

dtx_batch_projection_keeps_each_controls_changes_separate_test() ->
    FirstOps = [{assert, {{first_control, one}, true}}],
    SecondOps = [{retract, {{second_control, two}, false}}],
    FirstHeads = [{first_control, one}],
    SecondHeads = [{second_control, two}],
    Result =
        #{kind => dtx_batch,
          items =>
              [#{group_id => key(801), applied_ops => FirstOps,
                 changed_heads => FirstHeads},
               #{group_id => key(802), applied_ops => SecondOps,
                 changed_heads => SecondHeads}]},
    ?assertEqual(
       FirstHeads ++ SecondHeads,
       quod_foreign_projection:test_result_heads(Result)),
    %% A materialized follower emits two ordered occurrences at the shared
    %% block height.  Aggregating the slot's operations would lose which
    %% control produced which publication and permit cross-control leakage.
    ?assertEqual(
       [{9, FirstOps}, {9, SecondOps}],
       quod_foreign_projection:test_result_publications(9, Result)).

warm_exact_and_current_reuse_one_verified_phase_session_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31980},
    Ref = maps:get(ref, Fixture),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Mode = atomics:new(2, []),
    ok = atomics:put(Mode, 1, 1),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:get(Mode, 1) of
                1 ->
                    BaseFetch(P, E, RequestedNs, From, To);
                2 ->
                    error({warm_exact_used_network, From});
                3 when From =:= 3 ->
                    _ = atomics:add_get(Mode, 2, 1),
                    BaseFetch(P, E, RequestedNs, From, To);
                3 ->
                    error({warm_current_restarted_fetch, From})
            end
        end,
    Dir = temp_dir("resident-warm-exact-current"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        [SessionFile] = phase_session_files(Dir, Identity),

        %% The exact entry and its post-slot projection are already resident.
        %% A network read or a new phase-index file would prove that the warm
        %% path discarded and rebuilt work it had just verified.
        ok = atomics:put(Mode, 1, 2),
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity)),

        %% Current-view confirmation still asks the remote committee whether
        %% there is a newer slot, but it must resume the same verified phase
        %% session for both its exact-reference and current-prefix passes.
        ok = atomics:put(Mode, 1, 3),
        ?assertMatch(
           {ok, #{identity := Identity, slot := 2}},
           quod_foreign_log:current(
             route_candidates([{Peer, Endpoint}]), {Ns, maps:get(anchor, Fixture)}, 5000)),
        ?assert(atomics:get(Mode, 2) > 0),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

resident_current_view_uses_height_wake_and_verifies_real_delta_test() ->
    Fixture = prepared_then_committed_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31989},
    [Genesis, Prepare, _Finalize] = FullChain = maps:get(chain, Fixture),
    InitialChain = [Genesis, Prepare],
    Routes = route_candidates([{Peer, Endpoint}]),
    TestPid = self(),
    Mode = atomics:new(1, []),
    ok = atomics:put(Mode, 1, 1),
    InitialFetch = peer_chain_fetch(Ns, InitialChain, [Peer]),
    AdvancedFetch = peer_chain_fetch(Ns, FullChain, [Peer]),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            TestPid ! {resident_current_fetch, From},
            case atomics:get(Mode, 1) of
                1 -> InitialFetch(P, E, RequestedNs, From, To);
                2 -> error({unchanged_current_fetched, From});
                3 -> AdvancedFetch(P, E, RequestedNs, From, To)
            end
        end,
    Dir = temp_dir("resident-current-height-wake"),
    Pid = start_owner(Dir, Fetch),
    RegistrationId = binary:part(key(31990), 0, 16),
    Link = spawn(fun() -> fake_feed_link(TestPid) end),
    try
        ?assertMatch(
           {ok, #{identity := Identity, slot := 2}},
           quod_foreign_log:current(Routes, Identity, 5000)),
        [SessionFile] = phase_session_files(Dir, Identity),
        flush_resident_current_fetches(),

        %% Install the exact post-handshake link owned by the existing feed
        %% registration seam. Its registered height is a freshness witness,
        %% never history evidence.
        ok = quod_foreign_log:test_install_feed_registration(
               Pid, Identity, Peer, Link, RegistrationId),
        Registered = quod_feed:encode(
                       Ns,
                       {recipient_registered, 1,
                        RegistrationId, maps:get(anchor, Fixture), 2}),
        Pid ! {quod_message, {Peer, Link},
               quod_feed:channel(Ns), Registered},
        Ack2 = receive_fake_feed_send(Link, 1000),
        ?assertMatch(
           {ack, RegistrationId, _, 2},
           quod_feed:decode_recipient(Ack2, Ns)),

        %% The ordinary anti-entropy digest repeats the already-certified
        %% height. It is liveness, not new history, and must not discard the
        %% exact height witness or manufacture verifier work.
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns),
               quod_feed:encode(Ns, {digest, 2})},

        %% The unchanged request is answered from the one resident certified
        %% row. Any fetch would fail this call, and the suspended phase file
        %% proves that no second fold/session was created.
        ok = atomics:put(Mode, 1, 2),
        with_foreign_history_metrics(
          fun() ->
              Stages = [resident_current_hit, page_fetch, ledger_resume,
                        phase_resume, phase_suspend],
              Before = foreign_stage_samples(Stages),
              ?assertMatch(
                 {ok, #{identity := Identity, slot := 2}},
                 quod_foreign_log:current(Routes, Identity, 5000)),
              Deltas = foreign_stage_deltas(
                         Before, foreign_stage_samples(Stages)),
              ?assertMatch({1, _}, maps:get(resident_current_hit, Deltas)),
              ?assertEqual({0, 0.0}, maps:get(page_fetch, Deltas)),
              ?assertEqual({0, 0.0}, maps:get(ledger_resume, Deltas)),
              ?assertEqual({0, 0.0}, maps:get(phase_resume, Deltas)),
              ?assertEqual({0, 0.0}, maps:get(phase_suspend, Deltas))
          end),
        ?assertEqual([], collect_resident_current_fetches([])),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity)),
        ?assertEqual(
           1, maps:get(feed_registrations, quod_foreign_log:stats())),

        %% A later correlated height invalidates only freshness. The next
        %% request must return to the ordinary verifier, consume slot 3, and
        %% never restart from genesis.
        ok = atomics:put(Mode, 1, 3),
        WakesBefore = maps:get(follow_wakes, quod_foreign_log:stats()),
        Wake3 = quod_feed:encode(
                  Ns,
                  {recipient_wake, 1,
                   RegistrationId, maps:get(anchor, Fixture), 3}),
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Wake3},
        Ack3 = receive_fake_feed_send(Link, 1000),
        ?assertMatch(
           {ack, RegistrationId, _, 3},
           quod_feed:decode_recipient(Ack3, Ns)),
        %% A freshness watch is not a subscription. The wake invalidates the
        %% resident view but must not start background follow work; only the
        %% real request below advances the one certified verifier.
        ?assertEqual(
           WakesBefore,
           maps:get(follow_wakes, quod_foreign_log:stats())),
        ?assertEqual([], collect_resident_current_fetches([])),
        ?assertMatch(
           {ok, #{identity := Identity, slot := 3}},
           quod_foreign_log:current(Routes, Identity, 5000)),
        Fetches = collect_resident_current_fetches([]),
        ?assert(lists:member(3, Fetches)),
        ?assertNot(lists:member(1, Fetches)),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity))
    after
        Link ! close,
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

current_view_nonoverlapping_stages_explain_enclosing_request_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31988},
    Routes = route_candidates([{Peer, Endpoint}]),
    Parent = self(),
    Gate = atomics:new(1, []),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:compare_exchange(Gate, 1, 0, 1) of
                ok ->
                    Parent ! {accounted_current_blocked, self()},
                    receive release_accounted_current -> ok end;
                _ ->
                    ok
            end,
            BaseFetch(P, E, RequestedNs, From, To)
        end,
    Dir = temp_dir("current-stage-accounting"),
    Pid = start_owner(Dir, Fetch),
    try
        with_foreign_history_metrics(
          fun() ->
              Before = foreign_stage_samples(
                         [current_total, owner_mailbox, request_current,
                          result_install, caller_wake]),
              Caller = spawn(
                         fun() ->
                             Parent !
                                 {accounted_current_result,
                                  quod_foreign_log:current(
                                    Routes, Identity, 5000)}
                         end),
              Worker = receive
                           {accounted_current_blocked, FetchWorker} ->
                               FetchWorker
                       after 2000 ->
                           error(accounted_current_not_started)
                       end,
              %% A deliberate dependency hold makes the worker interval
              %% dominate scheduler noise; it is not a progress poll or a
              %% production deadline.
              receive after 25 -> ok end,
              1 = erlang:trace_pattern(
                    {quod_trace, set_attributes, 2}, true, []),
              1 = erlang:trace(Worker, true, [call, {tracer, self()}]),
              try
                  Worker ! release_accounted_current,
                  receive
                      {accounted_current_result, Result} ->
                          ?assertMatch(
                             {ok, #{identity := Identity}}, Result)
                  after 5000 ->
                      exit(Caller, kill),
                      error(accounted_current_no_result)
                  end,
                  receive
                      {trace, Worker, call,
                       {quod_trace, set_attributes,
                        [_SpanCtx,
                         #{'quod.foreign.resident_start_height' := 0,
                           'quod.foreign.final_verified_height' := Height}]}} ->
                          %% This metrics fixture does not install an SDK.
                          %% Real sampled parenting and replay-vs-network
                          %% counts are covered by the worker tracing suite.
                          ?assert(Height > 0)
                  after 2000 ->
                      error(accounted_current_trace_not_carried)
                  end
              after
                  _ = catch erlang:trace(Worker, false, [call]),
                  _ = erlang:trace_pattern(
                        {quod_trace, set_attributes, 2}, false, [])
              end,
              After = foreign_stage_samples(
                        [current_total, owner_mailbox, request_current,
                         result_install, caller_wake]),
              Deltas = foreign_stage_deltas(Before, After),
              {1, Total} = maps:get(current_total, Deltas),
              {1, MailboxTime} = maps:get(owner_mailbox, Deltas),
              {1, WorkerTime} = maps:get(request_current, Deltas),
              {1, InstallTime} = maps:get(result_install, Deltas),
              {1, WakeTime} = maps:get(caller_wake, Deltas),
              Explained = MailboxTime + WorkerTime + InstallTime + WakeTime,
              ?assert(Explained =< Total * 1.10),
              ?assert(Explained >= Total * 0.90)
          end)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

current_view_trace_crosses_owner_and_worker_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Routes = route_candidates([{Peer, {"127.0.0.1", 31989}}]),
    Dir = temp_dir("current-trace-parentage"),
    Pid = start_owner(Dir, peer_chain_fetch(
                             Ns, maps:get(chain, Fixture), [Peer])),
    try
        quod_trace_tests:with_tracer(fun() ->
            ?assertMatch({ok, #{identity := Identity}},
                         quod_foreign_log:current(
                           Routes, Identity, 5000)),
            Current = quod_trace_tests:take_span(
                        <<"quod.foreign.current">>),
            OwnerRequest = quod_trace_tests:take_span(
                             <<"quod.foreign.owner_request">>),
            Verification = quod_trace_tests:take_span(
                             <<"quod.foreign.verification_worker">>),
            ?assertEqual(Current#span.trace_id,
                         OwnerRequest#span.trace_id),
            ?assertEqual(Current#span.span_id,
                         OwnerRequest#span.parent_span_id),
            ?assertEqual(OwnerRequest#span.trace_id,
                         Verification#span.trace_id),
            ?assertEqual(OwnerRequest#span.span_id,
                         Verification#span.parent_span_id)
        end)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

resident_current_after_exact_uses_same_height_wake_without_fetch_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Ref = maps:get(ref, Fixture),
    Endpoint = {"127.0.0.1", 31991},
    Routes = route_candidates([{Peer, Endpoint}]),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Mode = atomics:new(1, []),
    ok = atomics:put(Mode, 1, 1),
    TestPid = self(),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            TestPid ! {resident_current_reference_fetch, From},
            case atomics:get(Mode, 1) of
                1 -> BaseFetch(P, E, RequestedNs, From, To);
                2 -> error({unchanged_current_reference_fetched, From})
            end
        end,
    Dir = temp_dir("resident-current-reference-height-wake"),
    Pid = start_owner(Dir, Fetch),
    RegistrationId = binary:part(key(31992), 0, 16),
    Link = spawn(fun() -> fake_feed_link(TestPid) end),
    try
        ?assertMatch(
           {ok, #{phase := finalize}},
           quod_foreign_log:verify_reference(Ref, finalize, {Peer, Endpoint}, 5000)),
        ?assertMatch(
           {ok, #{identity := Identity, slot := 2}},
           quod_foreign_log:current(Routes, {Ns, maps:get(anchor, Fixture)}, 5000)),
        [SessionFile] = phase_session_files(Dir, Identity),
        flush_resident_current_reference_fetches(),

        ok = quod_foreign_log:test_install_feed_registration(
               Pid, Identity, Peer, Link, RegistrationId),
        Registered = quod_feed:encode(
                       Ns,
                       {recipient_registered, 1, RegistrationId,
                        maps:get(anchor, Fixture), 2}),
        Pid ! {quod_message, {Peer, Link},
               quod_feed:channel(Ns), Registered},
        Ack = receive_fake_feed_send(Link, 1000),
        ?assertMatch(
           {ack, RegistrationId, _, 2},
           quod_feed:decode_recipient(Ack, Ns)),

        ok = atomics:put(Mode, 1, 2),
        ?assertMatch(
           {ok, #{identity := Identity, slot := 2}},
           quod_foreign_log:current(Routes, {Ns, maps:get(anchor, Fixture)}, 5000)),
        ?assertEqual([], collect_resident_current_reference_fetches([])),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity))
    after
        Link ! close,
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

resident_cache_session_height_mismatch_requires_explicit_reconstruction_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31993},
    TestPid = self(),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            TestPid ! {resident_mismatch_fetch, From},
            BaseFetch(P, E, RequestedNs, From, To)
        end,
    Dir = temp_dir("resident-session-height-mismatch"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000)),
        assert_history_integrity_counts(0, 0, 0),
        flush_resident_mismatch_fetches(),

        %% The immutable ledger session still resumes because its file is
        %% unchanged, but the deliberately inconsistent retained height must
        %% close that handle. The request refuses; an explicitly scheduled
        %% initialization restores retained disk, never refetching the prefix.
        ok = quod_foreign_log:test_corrupt_resident_height(Pid, Identity, 3),
        ?assertEqual({error, retry}, quod_foreign_log:verify(
             Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000)),
        await_history_ready(Identity, length(maps:get(chain, Fixture))),
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000)),
        ?assertEqual([], collect_resident_mismatch_fetches([])),
        assert_history_integrity_counts(0, 1, 0)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

live_corruption_reconstruction_is_not_counted_twice_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Ref = maps:get(ref, Fixture),
    Endpoint = {"127.0.0.1", 31994},
    Dir = temp_dir("live-corrupt-counter"),
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    try
        ?assertMatch({ok, _}, quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        CacheDir = quod_ledger_store:ns_dir(Dir, quod_foreign_log:cache_namespace(Identity)),
        %% The first read diagnoses an inconsistent resident cursor. Its
        %% separately queued initialization then finds a corrupt checkpoint.
        %% These are the same corruption-driven reconstruction, not two.
        ok = file:write_file(filename:join(CacheDir, "checkpoint.term"), <<"corrupt">>),
        ok = quod_foreign_log:test_corrupt_resident_height(Pid, Identity, 3),
        ?assertEqual({error, retry}, quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        ?assertMatch({ok, _}, quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        assert_history_integrity_counts(0, 1, 0)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

pending_prepare_to_finalize_resumes_phase_history_and_fetches_only_delta_test() ->
    Fixture = prepared_then_committed_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31981},
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Mode = atomics:new(2, []),
    ok = atomics:put(Mode, 1, 1),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:get(Mode, 1) of
                1 ->
                    BaseFetch(P, E, RequestedNs, From, To);
                2 when From =:= 3 ->
                    _ = atomics:add_get(Mode, 2, 1),
                    BaseFetch(P, E, RequestedNs, From, To);
                2 ->
                    error({finalize_restarted_fetch, From})
            end
        end,
    Dir = temp_dir("resident-pending-finalize"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, phase := prepare}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(prepare_ref, Fixture),
             prepare, 5000)),
        {2, PrepareProjection} = cache_checkpoint(Dir, Identity),
        %% A participant-side Prepare does not advertise a pending group in
        %% the public projection.  Its exact group history lives only in the
        %% phase index, so accepting the Finalize from slot 3 alone below is
        %% the non-vacuous proof that the suspended index was resumed.
        ?assertEqual(#{}, maps:get(dtx_pending, PrepareProjection)),
        [SessionFile] = phase_session_files(Dir, Identity),

        %% Finalize depends on the exact Prepare history kept in the suspended
        %% phase index.  The second request may fetch only slot 3; fetching
        %% from an earlier slot or replacing the session is a hidden replay.
        ok = atomics:put(Mode, 1, 2),
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(finalize_ref, Fixture),
             finalize, 5000)),
        ?assertEqual(1, atomics:get(Mode, 2)),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity)),
        ?assertMatch({3, _}, cache_checkpoint(Dir, Identity))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

worker_down_after_phase_session_transfer_does_not_leave_fake_resident_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31982},
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Crash = atomics:new(1, []),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:get(Crash, 1) of
                0 -> BaseFetch(P, E, RequestedNs, From, To);
                1 -> error({resident_fetch_crash, From})
            end
        end,
    Dir = temp_dir("resident-worker-down"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000)),
        ?assertMatch(
           #{histories := 1, resident_verified := 1},
           quod_foreign_log:stats()),
        assert_history_integrity_counts(0, 0, 0),

        %% Launch transfers the only suspended phase session to the worker.
        %% If that worker dies before returning it, the owner has a durable
        %% cache but no reusable in-memory verification state. Keeping
        %% `resident_verified=true` here would strand a
        %% history that resident_cache/2 can never actually resume.
        Gate = make_ref(),
        ok = gen_server:call(Pid, {test_hold_next_initialization, self(), Gate}),
        ok = atomics:put(Crash, 1, 1),
        ?assertEqual(
           {error, retry},
           quod_foreign_log:current(
             route_candidates([{Peer, Endpoint}]), Identity, 5000)),
        Initializer = receive
            {initialization_held, Gate, _, W} -> W
        after 2000 -> error(no_explicit_reconstruction)
        end,
        ?assertMatch(#{pending := 1, histories := 1, resident_verified := 0},
                     quod_foreign_log:stats()),
        ?assertMatch(#{active := #{work := {initialize, Identity, custody_lost}}},
                     maps:get(Identity, quod_foreign_log:test_lifecycle_state())),
        assert_history_integrity_counts(1, 0, 0),
        Initializer ! {release_initialization, Gate},
        %% Network fetch is still set to crash. The rebuild and next exact
        %% reference must both succeed from the retained certified prefix.
        await_history_ready(Identity, length(maps:get(chain, Fixture))),
        ?assertMatch({ok, #{identity := Identity}},
                     quod_foreign_log:verify_reference(maps:get(ref, Fixture), finalize, 5000)),
        ?assertMatch(#{pending := 0, resident_verified := 1}, quod_foreign_log:stats()),
        assert_history_integrity_counts(1, 0, 0)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

%% Counts live in the existing owner, so SDK/metrics availability cannot hide
%% a custody loss or classify it as diagnosed corruption. No new polling.
assert_history_integrity_counts(Custody, Corrupt, Index) ->
    ?assertEqual(
       #{history_custody_losses => Custody, history_corruptions => Corrupt,
         history_index_losses => Index},
       maps:with([history_custody_losses, history_corruptions,
                  history_index_losses], quod_foreign_log:stats())),
    {ok, _} = application:ensure_all_started(prometheus),
    ok = quod_metrics:declare(<<"kp_testnode">>),
    ok = quod_metrics:test_refresh_foreign_log(),
    ?assertEqual(Custody, prometheus_gauge:value(quod_foreign_history_custody_losses)),
    ?assertEqual(Corrupt, prometheus_gauge:value(quod_foreign_history_corruptions)),
    ?assertEqual(Index, prometheus_gauge:value(quod_foreign_history_index_losses)).

accepted_entry_hint_advances_through_the_one_verified_cache_path_test() ->
    Fixture = prepared_then_committed_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31983},
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    NetworkAllowed = atomics:new(1, []),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:get(NetworkAllowed, 1) of
                1 -> BaseFetch(P, E, RequestedNs, From, To);
                0 -> error({accepted_hint_refetched, From})
            end
        end,
    Dir = temp_dir("accepted-entry-hint"),
    Pid = start_owner(Dir, Fetch),
    try
        ok = atomics:put(NetworkAllowed, 1, 1),
        ?assertMatch(
           {ok, #{identity := Identity, phase := prepare}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(prepare_ref, Fixture),
             prepare, 5000)),
        [SessionFile] = phase_session_files(Dir, Identity),
        FinalizeEntry = lists:last(maps:get(chain, Fixture)),

        %% The response-carried entry is only acceleration material.  It is
        %% accepted here solely because the ordinary history fold validates
        %% it against the cached prefix and the ordinary exact checker binds
        %% it to this Ref and phase before the page is persisted.
        ok = atomics:put(NetworkAllowed, 1, 0),
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify_reference(
             maps:get(finalize_ref, Fixture), finalize,
             {Peer, Endpoint}, FinalizeEntry, 5000)),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity)),
        ?assertMatch({3, _}, cache_checkpoint(Dir, Identity))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

bad_accepted_entry_hint_is_inert_and_falls_back_to_certified_fetch_test() ->
    Fixture = prepared_then_committed_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31984},
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Mode = atomics:new(2, []),
    ok = atomics:put(Mode, 1, 1),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:get(Mode, 1) of
                1 ->
                    BaseFetch(P, E, RequestedNs, From, To);
                2 when From =:= 3 ->
                    _ = atomics:add_get(Mode, 2, 1),
                    BaseFetch(P, E, RequestedNs, From, To);
                2 ->
                    error({bad_hint_restarted_fetch, From})
            end
        end,
    Dir = temp_dir("bad-accepted-entry-hint"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, phase := prepare}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(prepare_ref, Fixture),
             prepare, 5000)),
        [SessionFile] = phase_session_files(Dir, Identity),
        FinalizeEntry = lists:last(maps:get(chain, Fixture)),
        BadHint = without_entry_cert(FinalizeEntry),

        %% Previewing a bad hint mutates neither the durable cache nor the
        %% phase index.  The same worker therefore continues from slot 2 and
        %% obtains the authoritative slot 3 through its normal source.
        ok = atomics:put(Mode, 1, 2),
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify_reference(
             maps:get(finalize_ref, Fixture), finalize,
             {Peer, Endpoint}, BadHint, 5000)),
        ?assertEqual(1, atomics:get(Mode, 2)),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity)),
        ?assertMatch({3, _}, cache_checkpoint(Dir, Identity))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

authenticated_bootstrap_candidates_are_bounded_and_peer_unique_test() ->
    Dir = temp_dir("bootstrap-bounds"),
    Pid = start_owner(
            Dir, fun(_, _, _, _, _) -> {error, unavailable} end),
    Identity = {unique_ns(), key(95)},
    Limit = 2 * ?MAX_VALIDATORS,
    try
        lists:foreach(
          fun(N) ->
              quod_foreign_log:observe_candidate(
                Identity, {key(1000 + N), {"127.0.0.1", 20000 + N}})
          end, lists:seq(1, Limit + 1)),
        Stats1 = quod_foreign_log:stats(),
        ?assertEqual(Limit, maps:get(bootstrap_candidates, Stats1)),
        ?assertEqual(Limit + 1, maps:get(bootstrap_accepted, Stats1)),
        ?assertEqual(1, maps:get(bootstrap_evicted, Stats1)),

        %% Re-observing one authenticated peer replaces its endpoint; it
        %% cannot consume another source slot for the same identity.
        Peer = key(1000 + Limit + 1),
        Replacement = {"127.0.0.1", 29999},
        quod_foreign_log:observe_candidate(Identity, {Peer, Replacement}),
        {ok, Selected} = quod_foreign_log:route_hints(Identity, []),
        ?assert(length(Selected) =< ?MAX_VALIDATORS),
        ?assertEqual(length(Selected),
                     length(lists:usort([K || {K, _} <- Selected]))),
        ?assertEqual([{Peer, [Replacement]}],
                     [Row || Row = {K, _} <- Selected, K =:= Peer]),
        ?assertEqual(Limit,
                     maps:get(bootstrap_candidates,
                              quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

bootstrap_candidates_do_not_impose_a_global_history_cap_test() ->
    Dir = temp_dir("bootstrap-history-unbounded"),
    Pid = start_owner(
            Dir, fun(_, _, _, _, _) -> {error, unavailable} end),
    Count = 96,
    try
        lists:foreach(
          fun(N) ->
              quod_foreign_log:observe_candidate(
                {<<"candidate:", (integer_to_binary(N))/binary>>, key(N)},
                {key(2000 + N), {"127.0.0.1", 30000 + N}})
          end, lists:seq(1, Count)),
        Stats = quod_foreign_log:stats(),
        ?assertEqual(0, maps:get(histories, Stats)),
        ?assertEqual(Count, maps:get(bootstrap_candidates, Stats)),
        ?assertEqual(0, maps:get(bootstrap_rejected, Stats))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

retained_history_is_initialized_at_startup_before_proof_requests_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31990},
    Ref = maps:get(ref, Fixture),
    Fetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Dir = temp_dir("lazy-history"),
    Pid1 = start_owner(Dir, Fetch),
    try
        %% Exact verification writes a certified cache and retains only its
        %% bounded owner-verified projection for later calls in this VM.
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        ?assertEqual(1, maps:get(histories, quod_foreign_log:stats())),
        ?assertEqual(1, maps:get(resident_verified,
                                quod_foreign_log:stats())),
        ?assertEqual(0, maps:get(page_bindings, quod_foreign_log:stats())),
        stop_owner(Pid1),

        %% Initialization precedes proof work and uses no network. A later
        %% ordinary verification uses the now-resident certified history.
        Pid2 = start_owner(Dir, fun(_, _, _, _, _) -> error(startup_used_network) end),
        try
            await_history_ready(Identity, length(maps:get(chain, Fixture))),
            ?assertEqual(1, maps:get(histories, quod_foreign_log:stats())),
            ?assertMatch(
               {ok, #{identity := Identity, phase := finalize}},
               quod_foreign_log:verify_reference(Ref, finalize, 5000)),
            ?assertEqual(1, maps:get(histories, quod_foreign_log:stats())),
            ?assertEqual(1, maps:get(resident_verified,
                                    quod_foreign_log:stats())),
            ?assertEqual(0, maps:get(page_bindings, quod_foreign_log:stats()))
        after
            stop_owner(Pid2)
        end
    after
        _ = file:del_dir_r(Dir)
    end.

byte_large_verified_cache_reopens_through_canonical_pages_test() ->
    Fixture = byte_large_foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31991},
    Ref = maps:get(ref, Fixture),
    SourceDir = temp_dir("byte-large-source"),
    CacheDir = temp_dir("byte-large-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(
                     Store0, maps:get(chain, Fixture)),
    Snapshot = quod_ledger_store:snapshot(Store1),
    ok = quod_ledger_store:close(Store1),
    Fetch =
        fun(_RoutePeer, _RouteEndpoint, RequestedNs, From, To)
              when RequestedNs =:= Ns ->
                quod_catchup:serve_blocks(Ns, Snapshot, From, To);
           (_RoutePeer, _RouteEndpoint, _RequestedNs, _From, _To) ->
                {error, wrong_namespace}
        end,
    Pid1 = start_owner(CacheDir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:current(
             [{Peer, [Endpoint]}], Identity, 5000)),
        %% One current-view job advances every certified page to the captured
        %% source height. A later call reuses that completed cache.
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:current(
             [{Peer, [Endpoint]}], Identity, 5000)),
        ?assertEqual(1, maps:get(histories, quod_foreign_log:stats()))
    after
        stop_owner(Pid1)
    end,
    %% The cache exceeds one certified page even though every source response
    %% and every individual block is valid. Reopening must replay the same
    %% byte-bounded page shape rather than treating a count-bounded read as one
    %% oversized network page.
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    CacheLog = filename:join(
                 quod_ledger_store:ns_dir(CacheDir, CacheNs), "log.0001"),
    ?assert(filelib:file_size(CacheLog) > ?QUOD_MAX_FOREIGN_PAGE_BYTES),
    NoFetch = fun(_, _, _, _, _) -> {error, network_used} end,
    Pid2 = start_owner(CacheDir, NoFetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify_reference(Ref, finalize, 5000))
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

one_peer_can_introduce_many_dormant_bootstrap_identities_test() ->
    Dir = temp_dir("bootstrap-peer-identities"),
    Pid = start_owner(
            Dir, fun(_, _, _, _, _) -> {error, unavailable} end),
    Peer = key(97),
    OtherPeer = key(98),
    try
        lists:foreach(
          fun(N) ->
              quod_foreign_log:observe_candidate(
                {<<"peer-cap:", (integer_to_binary(N))/binary>>, key(N)},
                {Peer, {"127.0.0.1", 31000 + N}})
          end, lists:seq(1, 1200)),
        OtherIdentity = {<<"peer-cap:other">>, key(999)},
        quod_foreign_log:observe_candidate(
          OtherIdentity, {OtherPeer, {"127.0.0.1", 31999}}),
        Stats = quod_foreign_log:stats(),
        ?assertEqual(0,
                     maps:get(histories, Stats)),
        ?assertEqual(1201,
                     maps:get(bootstrap_candidates, Stats)),
        ?assertEqual(0, maps:get(bootstrap_rejected, Stats)),
        ?assertMatch({ok, [{OtherPeer, [_]}]},
                     quod_foreign_log:route_hints(OtherIdentity, []))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

verify_reference_uses_authenticated_candidate_and_route_failover_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("candidate-verify"),
    Identity = {maps:get(ns, Fixture), maps:get(anchor, Fixture)},
    GoodPeer = maps:get(pub, Fixture),
    BadPeer = key(96),
    GoodEndpoint = {"127.0.0.1", 19096},
    BadEndpoint = {"127.0.0.1", 19097},
    Fetch = peer_chain_fetch(
              maps:get(ns, Fixture), maps:get(chain, Fixture), [GoodPeer]),
    Pid = start_owner(Dir, Fetch),
    try
        quod_foreign_log:observe_candidate(
          Identity, {GoodPeer, GoodEndpoint}),
        %% Newest candidate is tried first, so this unavailable route proves
        %% exact verification fails over within the one shared selector.
        quod_foreign_log:observe_candidate(
          Identity, {BadPeer, BadEndpoint}),
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify_reference(
             maps:get(ref, Fixture), finalize, 5000)),
        %% Once certified history is installed, its committee routes replace
        %% the temporary contacts instead of retaining stale guesses behind it.
        ?assertEqual(
           0, maps:get(bootstrap_candidates, quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

verify_reference_uses_request_contact_without_pre_observation_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("request-contact-verify"),
    Identity = {maps:get(ns, Fixture), maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19098},
    Fetch = peer_chain_fetch(
              maps:get(ns, Fixture), maps:get(chain, Fixture), [Peer]),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify_reference(
             maps:get(ref, Fixture), finalize,
             {Peer, Endpoint}, 5000)),
        %% The request contact enabled the exact verification without first
        %% becoming a bootstrap hint. Certified history is the only retained
        %% result.
        ?assertMatch(
           #{histories := 1, bootstrap_candidates := 0},
           quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

authenticated_live_endpoint_precedes_certified_history_with_fallback_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Ref = maps:get(ref, Fixture),
    Historical = {"127.0.0.1", 19000},
    Live = {"127.0.0.1", 19990},
    Supplied = {"127.0.0.1", 19991},
    TestPid = self(),
    BaseFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch = fun(P, Endpoint, RequestedNs, From, To) ->
                    TestPid ! {route_rotation_fetch, Endpoint, From},
                    case Endpoint of
                        Live -> {error, retry};
                        Historical ->
                            BaseFetch(P, Endpoint, RequestedNs, From, To);
                        _ -> {error, wrong_route}
                    end
            end,
    Dir = temp_dir("authenticated-live-fallback"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(
             Peer, Historical, Ref, finalize, 5000)),
        %% A caller-supplied address never displaces certified history.
        ?assertEqual(
           {ok, [{Peer, [Historical]}]},
           quod_foreign_log:route_hints(Identity, [{Peer, [Supplied]}])),
        %% Learning the already-certified address does not manufacture a
        %% second attempt for the same peer.
        quod_foreign_log:observe_candidate(Identity, {Peer, Historical}),
        ?assertEqual(
           {ok, [{Peer, [Historical]}]},
           quod_foreign_log:route_hints(Identity, [])),
        %% A contact learned from the peer itself is fresher reachability, but
        %% the certified address remains the same-key fallback.
        quod_foreign_log:observe_candidate(Identity, {Peer, Live}),
        ?assertEqual(
           {ok, [{Peer, [Live, Historical]}]},
           quod_foreign_log:route_hints(
             Identity, [{Peer, [Supplied]}])),
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:current(
             [{Peer, [Live, Historical]}], {Ns, maps:get(anchor, Fixture)}, 5000)),
        Calls = collect_route_rotation_fetches([]),
        ?assert(lists:member(Live, Calls)),
        ?assert(lists:member(Historical, Calls))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

cross_key_live_endpoint_cannot_displace_certified_fallback_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    OldEndpoint = {"127.0.0.1", 19000},
    NewEndpoint = {"127.0.0.1", 19101},
    Initial = route_candidates(
                [{Old, OldEndpoint}, {New, NewEndpoint}]),
    BaseFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    TestPid = self(),
    Fetch = fun(Peer, Endpoint, RequestedNs, From, To) ->
                    TestPid ! {cross_key_fetch, Peer, Endpoint},
                    case {Peer, Endpoint} of
                        {Old, OldEndpoint} ->
                            BaseFetch(Peer, Endpoint, RequestedNs, From, To);
                        {New, NewEndpoint} ->
                            BaseFetch(Peer, Endpoint, RequestedNs, From, To);
                        _ ->
                            {error, tls_identity_mismatch}
                    end
            end,
    Dir = temp_dir("cross-key-live-route"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{committee := [_, _]}},
           quod_foreign_log:current(Initial, {Ns, maps:get(anchor, Fixture)}, 5000)),
        %% A live hint may be stale or wrongly associated. It is tried only
        %% under Old's key and cannot remove Old's certified address.
        quod_foreign_log:observe_candidate(
          Identity, {Old, NewEndpoint}),
        {ok, Candidates} = quod_foreign_log:route_hints(Identity, []),
        ?assertEqual(
           [NewEndpoint, OldEndpoint],
           proplists:get_value(Old, Candidates)),
        ?assertEqual(
           [NewEndpoint],
           proplists:get_value(New, Candidates)),
        ?assertMatch(
           {ok, #{committee := [_, _]}},
           quod_foreign_log:current(Candidates, {Ns, maps:get(anchor, Fixture)}, 5000)),
        Calls = collect_cross_key_fetches([]),
        ?assert(lists:member({Old, NewEndpoint}, Calls)),
        ?assert(lists:member({Old, OldEndpoint}, Calls))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

collect_cross_key_fetches(Acc) ->
    receive
        {cross_key_fetch, Peer, Endpoint} ->
            collect_cross_key_fetches([{Peer, Endpoint} | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

collect_route_rotation_fetches(Acc) ->
    receive
        {route_rotation_fetch, Endpoint, _From} ->
            collect_route_rotation_fetches([Endpoint | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

bootstrap_hints_preserve_current_committee_contacts_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    OldHistorical = {"127.0.0.1", 19000},
    NewHistorical = {"127.0.0.1", 19101},
    OldLive = {"127.0.0.1", 19980},
    NewLive = {"127.0.0.1", 19981},
    Dir = temp_dir("bootstrap-protected-eviction"),
    Pid = start_owner(
            Dir, peer_chain_fetch(
                   Ns, maps:get(chain, Fixture), [Old, New])),
    try
        ?assertMatch(
           {ok, #{committee := [_, _]}},
           quod_foreign_log:current(
             route_candidates(
               [{Old, OldHistorical}, {New, NewHistorical}]), {Ns, maps:get(anchor, Fixture)}, 5000)),
        quod_foreign_log:observe_candidate(Identity, {Old, OldLive}),
        quod_foreign_log:observe_candidate(Identity, {New, NewLive}),
        lists:foreach(
          fun(N) ->
              quod_foreign_log:observe_candidate(
                Identity,
                {key(3000 + N), {"127.0.0.1", 22000 + N}})
          end, lists:seq(1, 2 * ?MAX_VALIDATORS)),
        {ok, Candidates} = quod_foreign_log:route_hints(Identity, []),
        ?assertEqual(
           [OldLive, OldHistorical],
           proplists:get_value(Old, Candidates)),
        ?assertEqual(
           [NewLive, NewHistorical],
           proplists:get_value(New, Candidates)),
        ?assertEqual(
           lists:sort([Old, New]),
           lists:sort([Key || {Key, _Endpoints} <- Candidates])),
        Stats = quod_foreign_log:stats(),
        ?assertEqual(2 * ?MAX_VALIDATORS,
                     maps:get(bootstrap_candidates, Stats)),
        ?assertEqual(2, maps:get(bootstrap_evicted, Stats))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

foreign_log_start_removes_only_disposable_projection_state_test() ->
    Dir = temp_dir("projection-start-cleanup"),
    ProjectionDir = filename:join([Dir, "projections", "stale-generation"]),
    Marker = filename:join(ProjectionDir, "outcome.dets"),
    ok = filelib:ensure_dir(Marker),
    ok = file:write_file(Marker, <<"derived">>),
    Pid = start_owner(Dir, fun(_, _, _, _, _) -> {error, unavailable} end),
    try
        ?assertNot(filelib:is_dir(filename:join(Dir, "projections")))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

opening_a_follow_signals_one_exact_directory_demand_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    stop_route_recovery_owners(),
    Dir = temp_dir("follow-route-demand"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    {ok, Directory} = quod_directory:start_link(
                        #{expire_tick_ms => 60000, ttl_ms => 10000}),
    unlink(Directory),
    {ok, Control} = quod_directory_control:start_link(#{}),
    unlink(Control),
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    Identity = {unique_ns(), key(100)},
    try
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        _ = receive_follow(FollowRef, Identity),
        ok = wait_route_demand(Identity, 100),
        ?assertEqual(
           [Identity],
           maps:get(route_demands,
                    quod_directory_control:test_control_state())),
        ok = quod_foreign_log:unfollow(FollowRef)
    after
        stop_owner(Pid),
        catch gen_server:stop(Control),
        catch gen_server:stop(Directory),
        stop_route_recovery_owners(),
        _ = file:del_dir_r(Dir)
    end.

slow_follow_consumer_coalesces_live_occurrences_to_state_only_test() ->
    Projection1 = key(103),
    Projection2 = key(104),
    Freshness = #{committee_id => key(105)},
    First = {advanced, 7, 8, Projection1, Freshness,
             [{changed, one}],
             [{8, [{assert, {{remote_ping, one}, {[], false}}}]}]},
    Second = {advanced, 8, 9, Projection2, Freshness,
              [{changed, two}],
              [{9, [{assert, {{remote_ping, two}, {[], false}}}]}]},
    %% Once a consumer has missed an acknowledgement boundary, the cache is
    %% still authoritative for current P but the occurrences are no longer a
    %% replay-safe E stream. The next notice therefore carries no history.
    ?assertEqual(
       {resnapshot, 9, Projection2, Freshness},
       quod_foreign_log:test_coalesce_notice(First, Second)),
    ?assertEqual(
       {resnapshot, 10, Projection2, Freshness},
       quod_foreign_log:test_coalesce_notice(
         {resnapshot, 9, Projection1, Freshness},
         {advanced, 9, 10, Projection2, Freshness, [],
          [{10, [{retract, {{remote_ping, one}, {[], false}}}]}]})).

follow_progress_is_message_driven_and_cleanup_is_exact_test() ->
    Dir = temp_dir("follow-lifecycle"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    Identity = {unique_ns(), key(101)},
    try
        {ok, Follow1} = quod_foreign_log:follow(Identity),
        Notice1 = receive_follow(Follow1, Identity),
        ?assertMatch({building, 0}, element(2, Notice1)),
        ok = quod_foreign_log:ack(Follow1, element(1, Notice1)),
        Unreachable1 = receive_follow(Follow1, Identity),
        ?assertMatch({unreachable, unavailable, 0}, element(2, Unreachable1)),
        ok = quod_foreign_log:ack(Follow1, element(1, Unreachable1)),
        FollowStats = quod_foreign_log:stats(),
        ?assertMatch(#{follow_unreachable := 1}, FollowStats),
        ?assertEqual(1, maps:get(follow_wakes, FollowStats)),

        %% An exact directory event wakes the parked verifier immediately.
        %% There is no retry timer between these two attempts.
        Pid ! {directory_route_available, Identity},
        Unreachable2 = receive_follow(Follow1, Identity),
        ?assertMatch({unreachable, unavailable, 0}, element(2, Unreachable2)),
        ok = quod_foreign_log:ack(Follow1, element(1, Unreachable2)),
        ?assertEqual(2, maps:get(follow_wakes, quod_foreign_log:stats())),

        %% A TLS-authenticated but uncertified peer cannot spend work merely
        %% by naming the same feed channel.  Generic block/digest freshness
        %% is accepted only from this exact identity's certified committee.
        Ns = element(1, Identity),
        FeedChan = quod_feed:channel(Ns),
        FeedWake = term_to_binary({feed, Ns, <<0, 1, 2>>}),
        Pid ! {quod_message, {key(77), self()}, FeedChan, FeedWake},
        ?assertEqual(2, maps:get(follow_wakes, quod_foreign_log:stats())),

        %% A co-hosted commit does not need to leave this Erlang node and come
        %% back through Brahms to wake the same certified follower.  The local
        %% commit is still only a freshness edge; the failed certified fetch
        %% below proves the entry was not consumed as trusted evidence.
        _ = quod_reg:publish(
              {committed, Ns},
              {committed, Ns, 1, quod_ledger:noop_entry(1, none)}),
        Unreachable4 = receive_follow(Follow1, Identity),
        ?assertMatch({unreachable, unavailable, 0}, element(2, Unreachable4)),
        ok = quod_foreign_log:ack(Follow1, element(1, Unreachable4)),
        ?assertEqual(3, maps:get(follow_wakes, quod_foreign_log:stats())),

        {ok, Follow2} = quod_foreign_log:follow(Identity),
        Notice2 = receive_follow(Follow2, Identity),
        ?assertMatch({building, 0}, element(2, Notice2)),
        ok = quod_foreign_log:ack(Follow2, element(1, Notice2)),
        ?assertMatch(
           #{histories := 1, followed_histories := 1,
             follow_consumers := 2}, quod_foreign_log:stats()),

        ok = quod_foreign_log:unfollow(Follow1),
        ?assertEqual(1, maps:get(follow_consumers, quod_foreign_log:stats())),
        ok = quod_foreign_log:unfollow(Follow2),
        ?assertMatch(
           #{histories := 0, followed_histories := 0,
             follow_consumers := 0, projection_workers := 0},
           quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

root_readiness_resumes_parked_projection_without_polling_test() ->
    Fixture = signed_content_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Network = maps:get(network, Fixture),
    Endpoint = {"127.0.0.1", 31980},
    SavedDesired = application:get_env(quod, namespace_desired),
    SavedStatic = application:get_env(quod, namespace_static_content),
    RootNs = quod_ontology:root_ns(),
    application:set_env(
      quod, namespace_desired,
      #{content => #{RootNs => #{genesis_hash => Network}}, brahms => #{}}),
    application:set_env(quod, namespace_static_content, #{}),
    Dir = temp_dir("root-ready-projection-wake"),
    Pid = start_owner(
            Dir, peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer])),
    try
        %% First verify and retain the certified history while Root is ready.
        %% The regression concerns only its separately rebuilt P projection.
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:current(
             route_candidates([{Peer, Endpoint}]), Identity, 5000)),
        application:set_env(
          quod, namespace_desired, #{content => #{}, brahms => #{}}),
        ok = quod_foreign_log:observe_candidate(Identity, {Peer, Endpoint}),
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        Initial = receive_follow(FollowRef, Identity),
        ?assertMatch({building, 0}, element(2, Initial)),
        ok = quod_foreign_log:ack(FollowRef, element(1, Initial)),

        %% The certified cache reaches the signed entry, but its projection
        %% cannot validate that entry until Root supplies the network anchor.
        Waiting = receive_follow(FollowRef, Identity),
        ?assertMatch({building, _}, element(2, Waiting)),
        ?assertMatch(
           #{follow_building := 1, follow_unreachable := 0},
           quod_foreign_log:stats()),

        Desired0 = application:get_env(quod, namespace_desired, #{}),
        Content0 = maps:get(content, Desired0, #{}),
        application:set_env(
          quod, namespace_desired,
          Desired0#{content =>
                        Content0#{RootNs => #{genesis_hash => Network}}}),
        _ = quod_reg:publish(
              {runtime, RootNs}, {replay_ready, boot, 1}),
        ok = quod_foreign_log:ack(FollowRef, element(1, Waiting)),
        Ready = receive_follow_resnapshot(FollowRef, Identity),
        ?assertMatch({resnapshot, 2, _, _}, element(2, Ready)),
        ok = quod_foreign_log:ack(FollowRef, element(1, Ready)),
        ?assertMatch(
           #{follow_building := 0, follow_unreachable := 0},
           quod_foreign_log:stats()),
        ok = quod_foreign_log:unfollow(FollowRef)
    after
        stop_owner(Pid),
        restore_application_env(namespace_desired, SavedDesired),
        restore_application_env(namespace_static_content, SavedStatic),
        _ = file:del_dir_r(Dir)
    end.

directory_renewal_does_not_probe_a_reachable_follow_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31979},
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    FetchCalls = atomics:new(1, []),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            _ = atomics:add_get(FetchCalls, 1, 1),
            BaseFetch(P, E, RequestedNs, From, To)
        end,
    Dir = temp_dir("reachable-follow-directory-renewal"),
    Pid = start_owner(Dir, Fetch),
    try
        ok = quod_foreign_log:observe_candidate(Identity, {Peer, Endpoint}),
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        Building = receive_follow(FollowRef, Identity),
        ok = quod_foreign_log:ack(FollowRef, element(1, Building)),
        Ready = receive_follow_resnapshot(FollowRef, Identity),
        ok = quod_foreign_log:ack(FollowRef, element(1, Ready)),
        Before = quod_foreign_log:stats(),
        ?assertEqual(0, maps:get(follow_unreachable, Before)),
        Wakes = maps:get(follow_wakes, Before),
        Calls = atomics:get(FetchCalls, 1),

        %% The signed lease is useful for route/link reconciliation, but an
        %% already-reachable certified follower waits for feed/commit progress.
        %% It must not turn the lease cadence into a periodic history pull.
        Pid ! {directory_route_available, Identity},
        After = quod_foreign_log:stats(),
        ?assertEqual(Wakes, maps:get(follow_wakes, After)),
        ?assertEqual(Calls, atomics:get(FetchCalls, 1)),
        ok = quod_foreign_log:unfollow(FollowRef),
        ok = wait_follow_count(0, 2000)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

feed_progress_is_correlated_to_each_anchored_committee_test() ->
    Dir = temp_dir("feed-progress-committee-correlation"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    Ns = unique_ns(),
    Fixture1 = fixture_base(Ns),
    Fixture2 = fixture_base(Ns),
    Peer1 = maps:get(pub, Fixture1),
    Peer2 = maps:get(pub, Fixture2),
    Identity1 = {Ns, maps:get(anchor, Fixture1)},
    Identity2 = {Ns, maps:get(anchor, Fixture2)},
    Projection1 = quod_simplex:history_advance(
                    Ns, maps:get(genesis, Fixture1),
                    quod_simplex:history_projection(Identity1)),
    Projection2 = quod_simplex:history_advance(
                    Ns, maps:get(genesis, Fixture2),
                    quod_simplex:history_projection(Identity2)),
    try
        {ok, Follow1} = quod_foreign_log:follow(Identity1),
        Building1 = receive_follow(Follow1, Identity1),
        ok = quod_foreign_log:ack(Follow1, element(1, Building1)),
        Unreachable1 = receive_follow(Follow1, Identity1),
        ok = quod_foreign_log:ack(Follow1, element(1, Unreachable1)),
        {ok, Follow2} = quod_foreign_log:follow(Identity2),
        Building2 = receive_follow(Follow2, Identity2),
        ok = quod_foreign_log:ack(Follow2, element(1, Building2)),
        Unreachable2 = receive_follow(Follow2, Identity2),
        ok = quod_foreign_log:ack(Follow2, element(1, Unreachable2)),
        ok = quod_foreign_log:test_install_feed_projection(
               Pid, Identity1, Projection1),
        ok = quod_foreign_log:test_install_feed_projection(
               Pid, Identity2, Projection2),
        Wakes0 = maps:get(follow_wakes, quod_foreign_log:stats()),
        FeedChan = quod_feed:channel(Ns),
        Digest = quod_feed:encode(Ns, {digest, 2}),

        %% Any authenticated outsider is inert, even with a valid feed shape.
        Pid ! {quod_message, {key(32030), self()}, FeedChan, Digest},
        ?assertEqual(Wakes0,
                     maps:get(follow_wakes, quod_foreign_log:stats())),

        %% The same namespace can identify distinct anchored histories. Peer1
        %% is certified only by Identity1, so its digest wakes exactly that
        %% follower and cannot spend work for Identity2.
        Pid ! {quod_message, {Peer1, self()}, FeedChan, Digest},
        Woken1 = receive_follow(Follow1, Identity1),
        ok = quod_foreign_log:ack(Follow1, element(1, Woken1)),
        ?assertEqual(Wakes0 + 1,
                     maps:get(follow_wakes, quod_foreign_log:stats())),
        receive
            {quod_foreign_follow, Follow2, _, Identity2, _} ->
                error(wrong_anchor_feed_woke_follower)
        after 0 ->
            ok
        end,

        %% Identity2's own certified peer independently wakes it.
        Pid ! {quod_message, {Peer2, self()}, FeedChan, Digest},
        Woken2 = receive_follow(Follow2, Identity2),
        ok = quod_foreign_log:ack(Follow2, element(1, Woken2)),
        ?assertEqual(Wakes0 + 2,
                     maps:get(follow_wakes, quod_foreign_log:stats())),
        ok = quod_foreign_log:unfollow(Follow1),
        ok = quod_foreign_log:unfollow(Follow2)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

feed_recipient_wake_is_exactly_correlated_and_interest_owned_test() ->
    Dir = temp_dir("feed-recipient-source"),
    TestPid = self(),
    Fetch =
        fun(_, _, _, _, _) ->
            TestPid ! {feed_recipient_fetch_waiting, self()},
            receive
                release_feed_recipient_fetch -> {error, unavailable}
            end
        end,
    Pid = start_owner_opts(Dir, Fetch, #{}),
    Ns = unique_ns(),
    Anchor = key(32010),
    Identity = {Ns, Anchor},
    Peer = key(32011),
    RegistrationId = binary:part(key(32012), 0, 16),
    WrongRegistrationId = binary:part(key(32013), 0, 16),
    Link = spawn(fun() -> fake_feed_link(TestPid) end),
    try
        ok = quod_foreign_log:observe_candidate(
               Identity, {Peer, {"127.0.0.1", 32010}}),
        {ok, Follow1} = quod_foreign_log:follow(Identity),
        Building1 = receive_follow(Follow1, Identity),
        ok = quod_foreign_log:ack(Follow1, element(1, Building1)),
        _BlockedWorker = receive
                             {feed_recipient_fetch_waiting, Worker} -> Worker
                         after 1000 ->
                             error(initial_follow_did_not_start)
                         end,
        Wakes0 = maps:get(follow_wakes, quod_foreign_log:stats()),

        %% Install the post-handshake state directly: transport opening is
        %% covered by QUIC tests, while this test owns the source correlation
        %% boundary.  A crossed generation must neither ACK nor wake work.
        ok = quod_foreign_log:test_install_feed_registration(
               Pid, Identity, Peer, Link, RegistrationId),
        Wrong = quod_feed:encode(
                  Ns,
                  {recipient_registered, 1,
                   WrongRegistrationId, Anchor, 7}),
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Wrong},
        ?assertEqual(Wakes0,
                     maps:get(follow_wakes, quod_foreign_log:stats())),
        ?assertNot(receive_fake_feed_send(Link, 0)),

        %% The exact registration response both closes the open/register race
        %% and wakes the one existing certified follower.  Its height is only
        %% acknowledged freshness; the still-blocked certified fetch proves
        %% it was not applied as history evidence.
        Registered = quod_feed:encode(
                       Ns,
                       {recipient_registered, 1,
                        RegistrationId, Anchor, 7}),
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Registered},
        Ack7 = receive_fake_feed_send(Link, 1000),
        ?assertMatch(
           {ack, RegistrationId, Anchor, 7},
           quod_feed:decode_recipient(Ack7, Ns)),

        Wake8 = quod_feed:encode(
                  Ns,
                  {recipient_wake, 1, RegistrationId, Anchor, 8}),
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Wake8},
        Ack8 = receive_fake_feed_send(Link, 1000),
        ?assertMatch(
           {ack, RegistrationId, Anchor, 8},
           quod_feed:decode_recipient(Ack8, Ns)),
        %% The second edge is coalesced into the already-running certified
        %% job; acknowledgements never create parallel history work.
        ?assertEqual(Wakes0,
                     maps:get(follow_wakes, quod_foreign_log:stats())),

        %% One registration belongs to the anchored identity, not to an
        %% individual consumer.  It survives the first detach and is removed
        %% exactly when the last interest disappears.
        {ok, Follow2} = quod_foreign_log:follow(Identity),
        Building2 = receive_follow(Follow2, Identity),
        ok = quod_foreign_log:ack(Follow2, element(1, Building2)),
        ok = quod_foreign_log:unfollow(Follow1),
        ?assertEqual(1,
                     maps:get(feed_registrations,
                              quod_foreign_log:stats())),
        ok = quod_foreign_log:unfollow(Follow2),
        Unregister = receive_fake_feed_send(Link, 1000),
        ?assertMatch(
           {unregister, RegistrationId, Anchor},
           quod_feed:decode_recipient(Unregister, Ns)),
        receive
            {fake_feed_link_closed, Link} -> ok
        after 1000 ->
            error(feed_registration_link_not_closed)
        end,
        ?assertEqual(0,
                     maps:get(feed_registrations,
                              quod_foreign_log:stats()))
    after
        Link ! close,
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

feed_registration_crossed_link_reply_preserves_opening_test() ->
    Dir = temp_dir("feed-registration-crossed-open"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    TestPid = self(),
    Ns = unique_ns(),
    Anchor = key(32020),
    Identity = {Ns, Anchor},
    Peer = key(32021),
    WrongPeer = key(32022),
    RegistrationId = binary:part(key(32023), 0, 16),
    OpenRef = make_ref(),
    Chan = quod_feed:channel(Ns),
    WrongPeerLink = spawn(fun() -> fake_feed_link(TestPid) end),
    WrongChannelLink = spawn(fun() -> fake_feed_link(TestPid) end),
    ExactLink = spawn(fun() -> fake_feed_link(TestPid) end),
    try
        ok = quod_foreign_log:test_install_feed_opening(
               Pid, Identity, Peer, RegistrationId, OpenRef),

        %% A crossed reply must close only the unrelated link.  In
        %% particular it must not consume the real opening: the exact reply
        %% below still has to install the link and send its registration.
        Pid ! {link_up, OpenRef, WrongPeer, Chan, WrongPeerLink},
        receive
            {fake_feed_link_closed, WrongPeerLink} -> ok
        after 1000 ->
            error(crossed_peer_link_not_closed)
        end,
        Pid ! {link_up, OpenRef, Peer, <<"wrong-channel">>,
               WrongChannelLink},
        receive
            {fake_feed_link_closed, WrongChannelLink} -> ok
        after 1000 ->
            error(crossed_channel_link_not_closed)
        end,

        Pid ! {link_up, OpenRef, Peer, Chan, ExactLink},
        Register = receive_fake_feed_send(ExactLink, 1000),
        ?assertMatch(
           {register, RegistrationId, Anchor},
           quod_feed:decode_recipient(Register, Ns))
    after
        WrongPeerLink ! close,
        WrongChannelLink ! close,
        ExactLink ! close,
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

local_commit_progress_subscription_is_namespace_refcounted_test() ->
    Dir = temp_dir("local-commit-refcount"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    Ns = unique_ns(),
    Identity1 = {Ns, key(121)},
    Identity2 = {Ns, key(122)},
    try
        {ok, Follow1} = quod_foreign_log:follow(Identity1),
        Building1 = receive_follow(Follow1, Identity1),
        ok = quod_foreign_log:ack(Follow1, element(1, Building1)),
        Unreachable1 = receive_follow(Follow1, Identity1),
        ok = quod_foreign_log:ack(Follow1, element(1, Unreachable1)),

        {ok, Follow2} = quod_foreign_log:follow(Identity2),
        Building2 = receive_follow(Follow2, Identity2),
        ok = quod_foreign_log:ack(Follow2, element(1, Building2)),
        Unreachable2 = receive_follow(Follow2, Identity2),
        ok = quod_foreign_log:ack(Follow2, element(1, Unreachable2)),

        %% Releasing one anchored identity must retain the one per-namespace
        %% subscription needed by the other identity.
        ok = quod_foreign_log:unfollow(Follow1),
        ok = wait_follow_count(1, 2000),
        _ = quod_reg:publish(
              {committed, Ns},
              {committed, Ns, 2, quod_ledger:noop_entry(2, none)}),
        Woken2 = receive_follow(Follow2, Identity2),
        ?assertMatch({unreachable, unavailable, 0}, element(2, Woken2)),
        ok = quod_foreign_log:ack(Follow2, element(1, Woken2)),

        %% Releasing the last identity removes both namespace progress
        %% subscriptions.  The stats call is a mailbox barrier for any event
        %% this process could still have delivered.
        ok = quod_foreign_log:unfollow(Follow2),
        ok = wait_follow_count(0, 2000),
        Wakes = maps:get(follow_wakes, quod_foreign_log:stats()),
        _ = quod_reg:publish(
              {committed, Ns},
              {committed, Ns, 3, quod_ledger:noop_entry(3, none)}),
        ?assertEqual(Wakes,
                     maps:get(follow_wakes, quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

follow_attempt_permission_is_consumed_without_erasing_known_lag_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 32131},
    Mode = atomics:new(1, []),
    BaseFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch = fun(P, E, N, F, T) ->
                case atomics:get(Mode, 1) of
                    0 -> BaseFetch(P, E, N, F, T);
                    1 -> {error, not_ready}
                end
            end,
    Dir = temp_dir("follow-consume-permission"),
    Pid = start_owner(Dir, Fetch),
    Parent = self(),
    Link = spawn(fun() -> fake_feed_link(Parent) end),
    Registration = crypto:strong_rand_bytes(16),
    try
        ?assertMatch({ok, _}, quod_foreign_log:verify(Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000)),
        atomics:put(Mode, 1, 1),
        Token1 = make_ref(),
        ok = gen_server:call(Pid, {test_hold_next_follow_worker, self(), Token1}),
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        Worker1 = receive_follow_worker(Token1),
        ok = quod_foreign_log:test_install_feed_registration(Pid, Identity, Peer, Link, Registration),
        Registered = quod_feed:encode(Ns, {recipient_registered, 1, Registration, element(2, Identity), 3}),
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Registered},
        ?assertMatch({ack, Registration, _, 3}, quod_feed:decode_recipient(receive_fake_feed_send(Link, 1000), Ns)),
        Token2 = make_ref(),
        ok = gen_server:call(Pid, {test_hold_next_follow_worker, self(), Token2}),
        Wake = quod_feed:encode(Ns, {recipient_wake, 1, Registration, element(2, Identity), 4}),
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Wake},
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Wake},
        ?assertMatch({ack, Registration, _, 4}, quod_feed:decode_recipient(receive_fake_feed_send(Link, 1000), Ns)),
        _ = receive_fake_feed_send(Link, 1000),
        Worker1 ! {release_follow_worker, Token1},
        Worker2 = receive_follow_worker(Token2),
        ?assertMatch(#{height := 2, hint := 4}, gen_server:call(Pid, {test_follow_attempt_state, Identity})),
        Token3 = make_ref(),
        ok = gen_server:call(Pid, {test_hold_next_follow_worker, self(), Token3}),
        Worker2 ! {release_follow_worker, Token2},
        wait_follow_attempt_idle(Pid, Identity, 2000),
        ?assertEqual(2, maps:get(follow_wakes, quod_foreign_log:stats())),
        ?assertMatch(#{height := 2, hint := 4, dirty := false, token := none},
                     gen_server:call(Pid, {test_follow_attempt_state, Identity})),
        %% Quiet same-PID recovery is not a new edge. An explicit caller
        %% refresh may spend one attempt, but unchanged success cannot loop.
        atomics:put(Mode, 1, 0),
        ?assertEqual(2, maps:get(follow_wakes, quod_foreign_log:stats())),
        ok = quod_foreign_log:refresh(FollowRef),
        Worker3 = receive_follow_worker(Token3),
        Worker3 ! {release_follow_worker, Token3},
        wait_follow_attempt_idle(Pid, Identity, 2000),
        ?assertEqual(3, maps:get(follow_wakes, quod_foreign_log:stats())),
        ?assertMatch(#{height := 2, hint := 4, dirty := false, token := none},
                     gen_server:call(Pid, {test_follow_attempt_state, Identity})),
        ok = quod_foreign_log:unfollow(FollowRef)
    after
        Link ! close,
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

receive_follow_worker(Token) ->
    receive {follow_worker_held, Token, _RequestRef, Worker} -> Worker
    after 2000 -> error(follow_worker_not_held)
    end.

wait_follow_attempt_idle(Pid, Identity, Left) when Left > 0 ->
    case gen_server:call(Pid, {test_follow_attempt_state, Identity}) of
        #{inflight := false, token := none} -> ok;
        _ -> receive after 5 -> ok end, wait_follow_attempt_idle(Pid, Identity, Left - 5)
    end;
wait_follow_attempt_idle(_Pid, _Identity, _Left) -> error(follow_attempt_did_not_park).

follow_wakes_coalesce_while_certified_work_is_inflight_test() ->
    Dir = temp_dir("follow-wake-coalesce"),
    Parent = self(),
    FetchCount = atomics:new(1, []),
    BlockingFetch =
        fun(_, _, _, _, _) ->
            _ = atomics:add_get(FetchCount, 1, 1),
            Parent ! {follow_fetch_started, self()},
            receive
                release_follow_fetch -> {error, unavailable}
            end
        end,
    Pid = start_owner_opts(Dir, BlockingFetch, #{}),
    Identity = {unique_ns(), key(111)},
    Peer = key(112),
    Endpoint = {"127.0.0.1", 31990},
    try
        ok = quod_foreign_log:observe_candidate(Identity, {Peer, Endpoint}),
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        Building = receive_follow(FollowRef, Identity),
        ok = quod_foreign_log:ack(FollowRef, element(1, Building)),
        Worker1 = receive
                      {follow_fetch_started, W1} -> W1
                  after 2000 -> error(first_follow_fetch_not_started)
                  end,

        Ns = element(1, Identity),
        Pid ! {directory_route_available, Identity},
        Pid ! {directory_route_available, Identity},
        Pid ! {quod_message, {Peer, self()}, quod_feed:channel(Ns),
               term_to_binary({feed, Ns, <<"wake">>})},
        ?assertEqual(1, maps:get(follow_wakes, quod_foreign_log:stats())),

        Worker1 ! release_follow_fetch,
        Unreachable1 = receive_follow(FollowRef, Identity),
        ok = quod_foreign_log:ack(FollowRef, element(1, Unreachable1)),
        %% Failed discovery has no certified projection. Its bootstrap hint
        %% therefore remains available to the one coalesced next attempt;
        %% that attempt must really fetch, not pass via an accidental no-route
        %% early return after an empty projection erased the hint.
        Worker2 = receive
                      {follow_fetch_started, W2} -> W2
                  after 2000 -> error(second_follow_fetch_not_started)
                  end,
        ?assertNotEqual(Worker1, Worker2),
        Worker2 ! release_follow_fetch,
        Unreachable2 = receive_follow(FollowRef, Identity),
        ok = quod_foreign_log:ack(FollowRef, element(1, Unreachable2)),
        %% Three signals created one dirty edge and therefore one second job.
        ?assertEqual(2, maps:get(follow_wakes, quod_foreign_log:stats())),
        ?assertEqual(2, atomics:get(FetchCount, 1)),
        ok = quod_foreign_log:unfollow(FollowRef),
        ok = wait_follow_count(0, 2000)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

exact_verification_parks_until_directory_progress_test() ->
    Ns = unique_ns(),
    Identity = {Ns, key(31990)},
    Peer = key(31991),
    Endpoint = {"127.0.0.1", 31991},
    Ref = ref(Identity, 2, 31992),
    TestPid = self(),
    Fetch = fun(P, E, _RequestedNs, _From, _To) ->
                    TestPid ! {parked_exact_fetch, P, E},
                    {error, unavailable}
            end,
    Dir = temp_dir("parked-exact-directory"),
    Pid = start_owner(Dir, Fetch),
    try
        Request = gen_server:send_request(
                    Pid,
                    owner_request({verify_reference, Ref, finalize, none, none, 300})),
        %% The stats call is a mailbox barrier: absence of a route has parked
        %% the owned call instead of returning retry or starting a worker.
        ?assertMatch(#{pending := 0, queued := 1},
                     quod_foreign_log:stats()),

        %% The contact remains an untrusted bootstrap hint.  Only the exact
        %% directory progress edge makes the parked verifier select it and
        %% run the ordinary anchored history fold.
        ok = quod_foreign_log:observe_candidate(
               Identity, {Peer, Endpoint}),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        Pid ! {directory_route_available, Identity},
        receive
            {parked_exact_fetch, Peer, Endpoint} -> ok
        after 1000 ->
            error(parked_verifier_not_woken)
        end,
        %% The failed fetch parks again.  Only the caller's original final
        %% deadline ends the request; there is no retry timer or ladder.
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Request, 2000)),
        ?assertMatch(#{pending := 0, queued := 0},
                     quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

parked_route_does_not_block_later_request_contact_test() ->
    Ns = unique_ns(),
    Identity = {Ns, key(31993)},
    Peer = key(31994),
    Endpoint = {"127.0.0.1", 31992},
    Ref = ref(Identity, 2, 31995),
    TestPid = self(),
    Fetch = fun(P, E, _RequestedNs, _From, _To) ->
                    TestPid ! {contact_exact_fetch, P, E},
                    {error, unavailable}
            end,
    Dir = temp_dir("parked-exact-contact"),
    Pid = start_owner(Dir, Fetch),
    try
        Parked = gen_server:send_request(
                   Pid,
                   owner_request({verify_reference, Ref, finalize, none, none, 350})),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        Contact = gen_server:send_request(
                    Pid,
                    owner_request({verify_reference, Ref, finalize,
                                   {Peer, Endpoint}, none, 250})),
        %% The second row has a usable request-scoped route, so it runs even
        %% though the older row remains parked at the front of the one queue.
        receive
            {contact_exact_fetch, Peer, Endpoint} -> ok
        after 1000 ->
            error(contact_request_blocked_behind_parked_row)
        end,
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Contact, 2000)),
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Parked, 2000)),
        ?assertMatch(#{pending := 0, queued := 0},
                     quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

authenticated_repeat_wakes_shared_parked_current_request_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31996},
    Routes = route_candidates([{Peer, Endpoint}]),
    Contact = {Peer, Endpoint},
    TestPid = self(),
    Attempts = atomics:new(1, []),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            Attempt = atomics:add_get(Attempts, 1, 1),
            case Attempt of
                1 ->
                    TestPid ! {authenticated_repeat_fetch, 1},
                    {error, unavailable};
                2 ->
                    TestPid ! {authenticated_repeat_fetch, 2, self()},
                    receive release_authenticated_repeat -> ok end,
                    BaseFetch(P, E, RequestedNs, From, To);
                _ -> BaseFetch(P, E, RequestedNs, From, To)
            end
        end,
    Dir = temp_dir("authenticated-repeat-wake"),
    Pid = start_owner(Dir, Fetch),
    try
        First = gen_server:send_request(
                  Pid,
                  current_request(Routes, Identity, Contact, 3000)),
        receive
            {authenticated_repeat_fetch, 1} -> ok
        after 1000 ->
            error(first_authenticated_fetch_not_started)
        end,
        ok = wait_foreign_work(0, 1, 1000),

        %% This is a new authenticated arrival from the same live endpoint,
        %% not a timer or a route-table change.  It must wake the one shared
        %% parked verification rather than merely add a caller to it asleep.
        Second = gen_server:send_request(
                   Pid,
                   current_request(Routes, Identity, Contact, 3000)),
        SecondFetch = receive
            {authenticated_repeat_fetch, 2, FetchWorker} -> FetchWorker
        after 1000 ->
            error(authenticated_repeat_did_not_wake_parked_work)
        end,
        ?assertMatch(#{pending := 1, queued := 0},
                     quod_foreign_log:stats()),
        SecondFetch ! release_authenticated_repeat,
        ?assertMatch(
           {reply, {ok, #{identity := Identity, slot := 2}}},
           gen_server:wait_response(First, 3000)),
        ?assertMatch(
           {reply, {ok, #{identity := Identity, slot := 2}}},
           gen_server:wait_response(Second, 3000)),
        ?assertMatch(#{pending := 0, queued := 0},
                     quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

uncertified_feed_progress_does_not_wake_parked_exact_verification_test() ->
    Ns = unique_ns(),
    Identity = {Ns, key(31998)},
    Peer = key(31999),
    Endpoint = {"127.0.0.1", 31993},
    Ref = ref(Identity, 2, 32000),
    TestPid = self(),
    Fetch = fun(P, E, _RequestedNs, _From, _To) ->
                    TestPid ! {feed_woken_exact_fetch, P, E},
                    {error, unavailable}
            end,
    Dir = temp_dir("parked-exact-feed"),
    Pid = start_owner(Dir, Fetch),
    try
        Request = gen_server:send_request(
                    Pid,
                    owner_request({verify_reference, Ref, finalize, none, none, 300})),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        ok = quod_foreign_log:observe_candidate(
               Identity, {Peer, Endpoint}),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        Pid ! {quod_message, {Peer, self()}, quod_feed:channel(Ns),
               term_to_binary({feed, Ns, <<"wake">>})},
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        receive
            {feed_woken_exact_fetch, Peer, Endpoint} ->
                error(uncertified_feed_woke_parked_verifier)
        after 0 ->
            ok
        end,

        %% The exact directory signal remains the ordinary discovery wake.
        Pid ! {directory_route_available, Identity},
        receive
            {feed_woken_exact_fetch, Peer, Endpoint} -> ok
        after 1000 ->
            error(directory_did_not_wake_parked_verifier)
        end,
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Request, 2000)),
        ?assertMatch(#{pending := 0, queued := 0, histories := 0},
                     quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

parked_exact_expires_only_at_its_caller_deadline_test() ->
    Identity = {unique_ns(), key(31996)},
    Ref = ref(Identity, 2, 31997),
    Dir = temp_dir("parked-exact-deadline"),
    Pid = start_owner(Dir, fun(_, _, _, _, _) -> {error, unavailable} end),
    try
        Request = gen_server:send_request(
                    Pid,
                    owner_request({verify_reference, Ref, finalize,
                                   none, none, 80})),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Request, 2000)),
        ?assertMatch(#{pending := 0, queued := 0, histories := 0},
                     quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

follow_owner_identity_and_consumer_down_are_fail_closed_test() ->
    Dir = temp_dir("follow-owner"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    Identity = {unique_ns(), key(102)},
    Parent = self(),
    Consumer = spawn(
                 fun() ->
                         Result = quod_foreign_log:follow(Identity),
                         Parent ! {child_follow, self(), Result},
                         receive stop -> ok end
                 end),
    try
        FollowRef = receive
                        {child_follow, Consumer, {ok, Ref}} -> Ref
                    after 2000 -> error(missing_child_follow)
                    end,
        %% A different process cannot remove the child's consumer reference.
        ok = quod_foreign_log:unfollow(FollowRef),
        ?assertEqual(1, maps:get(follow_consumers, quod_foreign_log:stats())),
        exit(Consumer, kill),
        ok = wait_follow_count(0, 2000),
        ?assertEqual(0, maps:get(followed_histories, quod_foreign_log:stats()))
    after
        catch exit(Consumer, kill),
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

verify_exact_reference_and_persisted_cache_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("verify"),
    Chain = maps:get(chain, Fixture),
    Ns = maps:get(ns, Fixture),
    Ref = maps:get(ref, Fixture),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19091},
    Fetch = chain_fetch(Ns, Chain),
    Pid = start_owner(Dir, Fetch),
    try
        {ok, Evidence} = quod_foreign_log:verify(
                           Peer, Endpoint, Ref, finalize, 5000),
        ?assertEqual({Ns, maps:get(anchor, Fixture)},
                     maps:get(identity, Evidence)),
        ?assertEqual(2, maps:get(slot, Evidence)),
        ?assertEqual(finalize, maps:get(phase, Evidence)),
        ?assertEqual(0, maps:get(generation, Evidence)),
        ?assertEqual([maps:get(pub, Fixture)],
                     maps:get(committee, Evidence)),
        ?assertEqual(
           #{maps:get(pub, Fixture) => {"127.0.0.1", 19000}},
           maps:get(routes, Evidence)),
        ?assert(is_binary(maps:get(committee_id, Evidence))),
        ?assertEqual(1, maps:get(histories, quod_foreign_log:stats())),
        ?assertMatch(
           {ok, #{slot := 2, phase := finalize, control := _}},
           quod_foreign_log:verify(Peer, Endpoint, Ref, entry, 5000)),
        %% The serving peer is transport, not authority. Re-reading the exact
        %% retained reference through an outsider still returns the committee
        %% certified at that slot; it does not add the outsider to evidence.
        ?assertMatch(
           {ok, #{committee := [Peer]}},
           quod_foreign_log:verify(
             key(91), Endpoint, Ref, finalize, 5000))
    after
        stop_owner(Pid)
    end,

    %% The second owner verifies the durable cache from slot 1.  A network
    %% fetch would fail, proving restart does not confuse availability with
    %% validity and does not trust checkpoint fields without replaying them.
    NoFetch = fun(_, _, _, _, _) -> {error, should_not_fetch} end,
    Pid2 = start_owner(Dir, NoFetch),
    try
        ?assertMatch(
           {ok, #{slot := 2, phase := finalize}},
           quod_foreign_log:verify(
             Peer, Endpoint, Ref, finalize, 5000))
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(Dir)
    end.

foreign_exact_reference_accepts_only_the_pinned_genesis_entry_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    [GenesisEntry | _] = maps:get(chain, Fixture),
    #entry{data = {batch, [Genesis]}} = quod_ledger:entry_view(GenesisEntry),
    {ok, GenesisRef} = quod_dtx:certified_entry_ref(
                         {Ns, Anchor}, GenesisEntry, Genesis),
    Dir = temp_dir("exact-pinned-genesis"),
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    try
        %% Slot 1 has no quorum certificate.  It is accepted only because the
        %% immutable genesis entry rebuilds to the identity's pinned anchor.
        ?assertMatch(
           {ok, #{slot := 1, phase := transaction, transaction := Genesis}},
           quod_foreign_log:verify(
             maps:get(pub, Fixture), {"127.0.0.1", 19094}, GenesisRef,
             transaction, 5000)),
        BadAnchorRef = setelement(4, GenesisRef, key(genesis_wrong_anchor)),
        ?assertEqual(
           {error, retry},
           quod_foreign_log:verify(
             maps:get(pub, Fixture), {"127.0.0.1", 19094}, BadAnchorRef,
             transaction, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

generic_entry_reference_accepts_certified_content_test() ->
    Fixture = long_identity_fixture(unique_ns(), 2),
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    [_, Entry] = maps:get(chain, Fixture),
    #entry{data = {batch, [Transaction]}} = quod_ledger:entry_view(Entry),
    {ok, Ref} = quod_dtx:certified_entry_ref(
                  {Ns, Anchor}, Entry, Transaction),
    Dir = temp_dir("generic-content-entry"),
    Pid = start_owner(
            Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    try
        ?assertMatch(
           {ok, #{phase := transaction, transaction := Transaction,
                  committee := [_]}},
           quod_foreign_log:verify(
             maps:get(pub, Fixture), {"127.0.0.1", 19093},
             Ref, entry, 5000)),
        ?assertMatch(
           {ok, #{phase := transaction, transaction := Transaction}},
           quod_foreign_log:verify(
             maps:get(pub, Fixture), {"127.0.0.1", 19093},
             Ref, transaction, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

verify_local_uses_exact_historical_projection_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Ref = maps:get(ref, Fixture),
    SourceDir = temp_dir("local-source"),
    CacheDir = temp_dir("local-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(
                     Store0, maps:get(chain, Fixture)),
    Source = local_fixture_view(Store1, Fixture),
    ok = quod_ledger_store:close(Store1),
    NoNetwork = fun(_, _, _, _, _) -> {error, network_used} end,
    Pid = start_owner(CacheDir, NoNetwork),
    try
        {ok, Evidence} = quod_foreign_log:verify_local(
                           Source, Ref, finalize, 5000),
        ?assertEqual(finalize, maps:get(phase, Evidence)),
        ?assertEqual(0, maps:get(generation, Evidence)),
        ?assertEqual(
           #{maps:get(pub, Fixture) => {"127.0.0.1", 19000}},
           maps:get(routes, Evidence))
    after
        true = gproc:unreg(quod_reg:name({quod_simplex, Ns})),
        stop_owner(Pid),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

verify_local_infinite_read_needs_no_foreign_owner_test() ->
    with_indexed_local_source(fun(F, _SourcePid, Source) ->
        ?assertEqual(undefined, quod_reg:where({foreign_log, node})),
        {Caller, Token} = hold_direct_local(Source, maps:get(ref, F), infinity, after_read),
        try
            Caller ! {release_local_read, Token},
            ?assertMatch({ok, #{phase := finalize}}, receive_local_borrow_result(Caller))
        after exit(Caller, kill)
        end
    end).

verify_local_source_death_cannot_publish_or_disrupt_foreign_work_test() ->
    with_indexed_local_source(fun(F, SourcePid, Source) ->
        CacheDir = temp_dir("local-death-foreign"), Gate = make_ref(),
        Pid = start_owner(CacheDir, gated_local_borrow_fetch(F, self(), Gate)),
        try
            Remote = gen_server:send_request(Pid, owner_request(
                {verify, maps:get(pub, F), {"127.0.0.1", 19000}, maps:get(ref, F), finalize, 5000})),
            RemoteWorker = receive {remote_borrow_worker_held, Gate, W} -> W
                           after 2000 -> error(remote_not_held)
                           end,
            {Caller, Token} = hold_direct_local(Source, maps:get(ref, F), infinity, after_read),
            try
                ?assertEqual(0, local_borrow_monitor_count(Pid, SourcePid)),
                ?assertMatch(#{pending := 1, queued := 0}, quod_foreign_log:stats()),
                SourceDown = monitor(process, SourcePid),
                exit(SourcePid, kill),
                receive {'DOWN', SourceDown, process, SourcePid, killed} -> ok
                after 1000 -> error(source_not_dead)
                end,
                Caller ! {release_local_read, Token},
                ?assertEqual({error, retry}, receive_local_borrow_result(Caller)),
                ?assert(is_process_alive(RemoteWorker)),
                ?assertMatch(#{pending := 1, queued := 0}, quod_foreign_log:stats()),
                RemoteWorker ! {release_remote_borrow_worker, Gate},
                ?assertMatch({reply, {ok, #{phase := finalize}}},
                             gen_server:wait_response(Remote, 3000))
            after exit(Caller, kill), exit(RemoteWorker, kill)
            end
        after stop_owner(Pid), _ = file:del_dir_r(CacheDir)
        end
    end).

local_follow_capture_uses_original_operation_budget_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Identity = {maps:get(ns, Fixture), maps:get(anchor, Fixture)},
    SourceDir = temp_dir("local-follow-capture-source"),
    CacheDir = temp_dir("local-follow-capture-cache"),
    Pid = start_owner_opts(CacheDir, fun(_, _, _, _, _) -> {error, network_used} end,
                           #{page_timeout_ms => 1000}),
    {SourcePid, SourceMRef, _Source} = start_local_borrow_source(SourceDir, Fixture),
    try
        hold_source_capture(SourcePid),
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        Deadline = receive {local_capture_held, SourcePid, D} -> D
                   after 1000 -> error(local_capture_not_started)
                   end,
        %% This same live source remains busy beyond the removed independent
        %% one-second cutoff, but within the existing three-second operation.
        receive after 1100 -> ok end,
        ?assert(Deadline > quod_time:mono_ms()),
        ?assertMatch(#{inflight := true}, gen_server:call(Pid, {test_follow_attempt_state, Identity})),
        SourcePid ! release_capture,
        {_NoticeRef, {resnapshot, 3, _, _}} = receive_follow_resnapshot(FollowRef, Identity),
        ?assertEqual(1, maps:get(follow_wakes, quod_foreign_log:stats())),
        ?assert(is_process_alive(SourcePid)),
        ok = quod_foreign_log:unfollow(FollowRef)
    after
        stop_local_borrow_source(SourcePid, SourceMRef),
        stop_owner(Pid),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

local_follow_terminal_borrow_admission_expiry_keeps_lag_until_fresh_request_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    SourceDir = temp_dir("local-follow-expired-source"),
    CacheDir = temp_dir("local-follow-expired-cache"),
    InitialChain = lists:sublist(maps:get(chain, Fixture), 2),
    Pid = start_owner_opts(CacheDir, chain_fetch(Ns, InitialChain),
                           #{page_timeout_ms => 100}),
    {SourcePid, SourceMRef, _Source} = start_local_borrow_source(SourceDir, Fixture),
    Parent = self(),
    Link = spawn(fun() -> fake_feed_link(Parent) end),
    Registration = crypto:strong_rand_bytes(16),
    try
        %% A real current-view interest opens the feed path before a follow
        %% exists, so ACKing H=3 records lag without creating a dirty attempt.
        ?assertMatch({ok, #{slot := 2}}, quod_foreign_log:current(
                       route_candidates([{Peer, {"127.0.0.1", 19000}}]), Identity, 5000)),
        ok = quod_foreign_log:test_install_feed_registration(Pid, Identity, Peer, Link, Registration),
        Registered = quod_feed:encode(Ns, {recipient_registered, 1, Registration, element(2, Identity), 3}),
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Registered},
        ?assertMatch({ack, Registration, _, 3}, quod_feed:decode_recipient(receive_fake_feed_send(Link, 1000), Ns)),
        hold_source_capture(SourcePid),
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        Deadline = receive {local_capture_held, SourcePid, D} -> D
                   after 1000 -> error(local_capture_not_started)
                   end,
        %% Capture completes inside budget, but borrower admission is delayed
        %% at its existing owner. That queued call must not authorize a cache
        %% read after the same operation's deadline has elapsed.
        ok = sys:suspend(Pid),
        SourcePid ! release_capture,
        wait_queued_local_borrow(Pid, 500),
        receive after max(0, Deadline - quod_time:mono_ms()) + 20 -> ok end,
        ok = sys:resume(Pid),
        wait_follow_attempt_idle(Pid, Identity, 2000),
        ?assertMatch(#{height := 2, hint := 3, token := none, dirty := false},
                     gen_server:call(Pid, {test_follow_attempt_state, Identity})),
        %% A barrier through the same source proves it has really recovered.
        ?assertMatch({ok, _}, quod_simplex:history_view(Identity, any, quod_time:mono_ms() + 1000)),
        ?assertEqual(1, maps:get(follow_wakes, quod_foreign_log:stats())),
        ?assertMatch(#{height := 2, hint := 3, token := none},
                     gen_server:call(Pid, {test_follow_attempt_state, Identity})),
        ok = quod_foreign_log:refresh(FollowRef),
        wait_follow_attempt_idle(Pid, Identity, 2000),
        ?assertMatch(#{height := 3}, gen_server:call(Pid, {test_follow_attempt_state, Identity})),
        ok = quod_foreign_log:unfollow(FollowRef)
    after
        Link ! close,
        _ = catch sys:resume(Pid),
        stop_local_borrow_source(SourcePid, SourceMRef),
        stop_owner(Pid),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

wait_queued_local_borrow(Pid, Left) when Left > 0 ->
    {messages, Messages} = process_info(Pid, messages),
    case lists:any(fun({'$gen_call', _, {borrow_local_view, _, _}}) -> true;
                      (_) -> false
                   end, Messages) of
        true -> ok;
        false -> receive after 5 -> ok end, wait_queued_local_borrow(Pid, Left - 5)
    end;
wait_queued_local_borrow(_Pid, _Left) -> error(local_borrow_was_not_queued).

hold_source_capture(SourcePid) ->
    SourcePid ! {hold_capture, self()},
    receive {local_capture_gate_ready, SourcePid} -> ok
    after 1000 -> error(local_capture_gate_timeout)
    end.

verify_local_does_not_queue_behind_same_identity_foreign_work_test() ->
    with_indexed_local_source(fun(F, SourcePid, Source) ->
        CacheDir = temp_dir("local-busy-foreign"), Gate = make_ref(),
        Pid = start_owner(CacheDir, gated_local_borrow_fetch(F, self(), Gate)),
        try
            Remote = gen_server:send_request(Pid, owner_request(
                {verify, maps:get(pub, F), {"127.0.0.1", 19000}, maps:get(ref, F), finalize, 5000})),
            Worker = receive {remote_borrow_worker_held, Gate, W} -> W
                     after 2000 -> error(remote_not_held)
                     end,
            try
                ?assertMatch({ok, #{phase := finalize}},
                             quod_foreign_log:verify_local(Source, maps:get(ref, F), finalize, infinity)),
                ?assertMatch(#{pending := 1, queued := 0}, quod_foreign_log:stats()),
                ?assertEqual(0, local_borrow_monitor_count(Pid, SourcePid)),
                Worker ! {release_remote_borrow_worker, Gate},
                ?assertMatch({reply, {ok, #{phase := finalize}}},
                             gen_server:wait_response(Remote, 3000))
            after exit(Worker, kill)
            end
        after stop_owner(Pid), _ = file:del_dir_r(CacheDir)
        end
    end).

verify_local_callers_keep_independent_deadlines_test() ->
    with_indexed_local_source(fun(F, _SourcePid, Source) ->
        Ref = maps:get(ref, F),
        {Long, LongToken} = hold_direct_local(Source, Ref, infinity, after_read),
        Deadline = quod_time:mono_ms() + 500,
        {Short, ShortToken} = hold_direct_local(Source, Ref, Deadline, after_read),
        try
            %% Waiting for the actual deadline is intentional; the read gates,
            %% not this elapsed time, establish which work has completed.
            receive after max(0, Deadline - quod_time:mono_ms()) + 1 -> ok end,
            ?assert(quod_time:mono_ms() >= Deadline),
            Short ! {release_local_read, ShortToken},
            ?assertEqual({error, retry}, receive_local_borrow_result(Short)),
            ?assert(is_process_alive(Long)),
            Long ! {release_local_read, LongToken},
            ?assertMatch({ok, #{phase := finalize}}, receive_local_borrow_result(Long))
        after exit(Short, kill), exit(Long, kill)
        end
    end).

with_indexed_local_source(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    F = membership_after_finalize_fixture(unique_ns()),
    Dir = temp_dir("indexed-local-source"),
    {Pid, Monitor, View} = start_local_borrow_source(Dir, F),
    try Fun(F, Pid, View)
    after stop_local_borrow_source(Pid, Monitor), _ = file:del_dir_r(Dir)
    end.

%% A separate registered source owns a real ledger and retained read-only
%% index. Its current-only projection resolves old eras without a foreign job.
start_local_borrow_source(Dir, Fixture) ->
    Parent = self(),
    {SourcePid, SourceMRef} = spawn_monitor(
      fun() ->
          {ok, Store0} = quod_ledger_store:open(maps:get(ns, Fixture), Dir),
          {ok, Store} = quod_ledger_store:append(Store0, maps:get(chain, Fixture)),
          {ok, Index} = quod_dtx_phase_index:open(Dir, maps:get(ns, Fixture)),
          View = local_fixture_view(Store, Fixture, Index),
          Parent ! {local_borrow_source, self(), View},
          local_borrow_source_loop(View, none),
          quod_dtx_phase_index:close(Index),
          quod_ledger_store:close(Store)
      end),
    receive
        {local_borrow_source, SourcePid, View} -> {SourcePid, SourceMRef, View};
        {'DOWN', SourceMRef, process, SourcePid, Reason} ->
            error({local_borrow_source_failed, Reason})
    after 2000 ->
        exit(SourcePid, kill),
        error(local_borrow_source_timeout)
    end.

local_borrow_source_loop(View = #{identity := Identity}, Gate) ->
    receive
        {hold_capture, Parent} ->
            Parent ! {local_capture_gate_ready, self()},
            local_borrow_source_loop(View, Parent);
        {'$gen_call', From, {history_view, Identity, any, Deadline}} ->
            case Gate of
                none -> ok;
                Parent ->
                    Parent ! {local_capture_held, self(), Deadline},
                    receive release_capture -> ok end
            end,
            Reply = case Deadline > quod_time:mono_ms() of
                        true -> {ok, View};
                        false -> {error, timeout}
                    end,
            gen_statem:reply(From, Reply),
            local_borrow_source_loop(View, none);
        stop -> ok
    end.

stop_local_borrow_source(SourcePid, SourceMRef) ->
    exit(SourcePid, kill),
    receive {'DOWN', SourceMRef, process, SourcePid, _} -> ok
    after 2000 -> error(local_borrow_source_stop_timeout)
    end.

hold_direct_local(Source, Ref, Deadline, Stage) ->
    Token = make_ref(), Parent = self(),
    Caller = spawn(fun() ->
        put({quod_foreign_log, local_read_gate}, {Stage, Parent, Token}),
        Parent ! {local_borrow_result, self(),
                  quod_foreign_log:verify_local_deadline(Source, Ref, finalize, Deadline)}
    end),
    receive {local_read_held, Token, Caller} -> {Caller, Token}
    after 2000 -> exit(Caller, kill), error(local_read_not_held)
    end.

receive_local_borrow_result(Caller) ->
    receive {local_borrow_result, Caller, Result} -> Result
    after 3000 -> error(local_borrow_result_timeout)
    end.

local_borrow_monitor_count(Pid, SourcePid) ->
    {monitors, Monitors} = process_info(Pid, monitors),
    length([ok || {process, Target} <- Monitors, Target =:= SourcePid]).

gated_local_borrow_fetch(Fixture, Parent, Token) ->
    BaseFetch = chain_fetch(maps:get(ns, Fixture), maps:get(chain, Fixture)),
    fun(Peer, Endpoint, Ns, From, To) ->
        case put(Token, held) of
            undefined ->
                Parent ! {remote_borrow_worker_held, Token, self()},
                receive {release_remote_borrow_worker, Token} -> ok end;
            held -> ok
        end,
        BaseFetch(Peer, Endpoint, Ns, From, To)
    end.

verify_local_reuses_current_committee_entry_without_history_owner_test() ->
    Fixture = long_identity_fixture(unique_ns(), 300),
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Binding = {Ns, Anchor},
    Chain = maps:get(chain, Fixture),
    Entry = lists:last(Chain),
    #entry{data = {batch, [Transaction]}} = quod_ledger:entry_view(Entry),
    {ok, Ref} = quod_dtx:certified_entry_ref(Binding, Entry, Transaction),
    {ok, Chain, Projection} = quod_catchup:verify_forward(
                                Ns, Anchor,
                                quod_simplex:history_projection(Binding),
                                1, Chain),
    SourceDir = temp_dir("resident-local-source"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(Store0, Chain),
    Source = local_test_view(Store1, Projection),
    try
        %% No quod_foreign_log owner is running. Success therefore proves the
        %% current certified entry was read directly instead of replayed. The
        %% verifier runs in another process so passing a writer-owned raw file
        %% handle instead of the immutable snapshot would fail.
        ?assertEqual(undefined, quod_reg:where({foreign_log, node})),
        ?assertMatch(
           {ok, #{phase := transaction, transaction := Transaction,
                  committee := [_]}},
           verify_local_in_worker(Source, Ref, transaction)),
        BadRef = setelement(7, Ref, key(resident_digest_mismatch)),
        ?assertEqual(
           {error, invalid_foreign_reference},
           verify_local_in_worker(Source, BadRef, transaction))
    after
        true = gproc:unreg(quod_reg:name({quod_simplex, Ns})),
        quod_ledger_store:close(Store1),
        _ = file:del_dir_r(SourceDir)
    end.

verify_local_newer_reference_remains_unavailable_test() ->
    Fixture = long_identity_fixture(unique_ns(), 3),
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Identity = {Ns, Anchor},
    [Genesis, Prior, Newer] = maps:get(chain, Fixture),
    #entry{data = {batch, [Transaction]}} = quod_ledger:entry_view(Newer),
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Newer, Transaction),
    {ok, [Genesis, Prior], Projection} = quod_catchup:verify_forward(
                                         Ns, Anchor,
                                         quod_simplex:history_projection(Identity),
                                         1, [Genesis, Prior]),
    SourceDir = temp_dir("local-newer-reference"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(Store0, [Genesis, Prior]),
    Source = local_test_view(Store1, Projection),
    try
        %% A valid future reference is unavailable, never invalid authority.
        ?assertEqual({error, retry},
                     quod_foreign_log:verify_local(Source, Ref, transaction, 5000)),
        {ok, Store2} = quod_ledger_store:append(Store1, [Newer]),
        %% An ordinary append leaves the original read capability bounded.
        ?assertEqual({error, retry},
                     quod_foreign_log:verify_local(Source, Ref, transaction, 5000)),
        {ok, [Newer], Projection2} = quod_catchup:verify_forward(
                                      Ns, Anchor, Projection, 3, [Newer]),
        Current = Source#{slot := 3, applied := 3,
                          snapshot := quod_ledger_store:snapshot(Store2),
                          projection := Projection2},
        ?assertMatch({ok, #{phase := transaction, transaction := Transaction}},
                     quod_foreign_log:verify_local(Current, Ref, transaction, 5000))
    after
        true = gproc:unreg(quod_reg:name({quod_simplex, Ns})),
        quod_ledger_store:close(Store1),
        _ = file:del_dir_r(SourceDir)
    end.

verify_local_reuses_current_committee_control_without_history_owner_test() ->
    Ns = unique_ns(),
    Base = fixture_base(Ns),
    Anchor = maps:get(anchor, Base),
    Binding = {Ns, Anchor},
    BeginFixture = quod_ct:signed_dtx_begin_fixture(
                     #{target => Binding,
                       participant_target =>
                           {<<"resident-local-control-target">>, key(903)},
                       node_identity => maps:get(signer, Base),
                       admission => maps:get(admission, Base),
                       proof_id => key(904)}),
    Control = maps:get(begin_control, BeginFixture),
    {ok, ControlBlob} = quod_dtx:encode_control(Control),
    Entry = control_entry(
              Ns, Anchor, maps:get(pub, Base), maps:get(signer, Base),
              2, ControlBlob),
    {ok, Ref} = quod_dtx:certified_entry_ref(Binding, Entry, Control),
    Genesis = maps:get(genesis, Base),
    Chain = [Genesis, Entry],
    {ok, [Genesis], Projection1} = quod_catchup:verify_forward(
                                      Ns, Anchor,
                                      quod_simplex:history_projection(Binding),
                                      1, [Genesis]),
    %% The live owner has already validated and applied slot 2. This test
    %% models that owned projection directly because the seam under test is
    %% exact-reference verification, not a second replay of DTX semantics.
    Projection = Projection1#{history_head => {2, entry_hash(Entry)},
                              timestamp => 2},
    SourceDir = temp_dir("resident-local-control-source"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(Store0, Chain),
    Source = local_test_view(Store1, Projection),
    try
        %% The owning consensus projection already certifies this committee
        %% era. No foreign-history owner may be needed to read its exact
        %% committed control from the immutable local snapshot.
        ?assertEqual(undefined, quod_reg:where({foreign_log, node})),
        ?assertMatch(
           {ok, #{phase := 'begin', control := Control, entry := _}},
           verify_local_in_worker(Source, Ref, 'begin'))
    after
        true = gproc:unreg(quod_reg:name({quod_simplex, Ns})),
        quod_ledger_store:close(Store1),
        _ = file:del_dir_r(SourceDir)
    end.

local_fixture_view(Store, Fixture, Index) ->
    Ns = maps:get(ns, Fixture), Anchor = maps:get(anchor, Fixture),
    {ok, _, Projection, Delta} = quod_catchup:verify_forward(
        Ns, Anchor, quod_simplex:history_projection({Ns, Anchor}),
        1, maps:get(chain, Fixture), Index),
    ok = quod_dtx_phase_index:commit_delta(Index, Delta),
    {ok, Borrow} = quod_dtx_phase_index:capture(Index, quod_ledger_store:last(Store)),
    local_test_view(Store, Projection#{history_index => Borrow,
        committee_views := lists:sublist(maps:get(committee_views, Projection), 1)}).

local_fixture_view(Store, Fixture) ->
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Chain = maps:get(chain, Fixture),
    PhaseDir = temp_dir("local-fixture-phase-index"),
    {ok, PhaseIndex} = quod_dtx_phase_index:open(PhaseDir, Ns),
    try
        {ok, Chain, Projection, _Delta} = quod_catchup:verify_forward(
                                           Ns, Anchor,
                                           quod_simplex:history_projection({Ns, Anchor}),
                                           1, Chain, PhaseIndex),
        local_test_view(Store, Projection)
    after
        ok = quod_dtx_phase_index:close(PhaseIndex),
        _ = file:del_dir_r(PhaseDir)
    end.

%% These verifier-boundary fixtures stand in for the registered live owner;
%% they do not run consensus or manufacture a second production view API.
local_test_view(Store, Projection) ->
    Ns = quod_ledger_store:namespace(Store),
    true = quod_reg:reg({quod_simplex, Ns}),
    Height = quod_ledger_store:last(Store),
    #{owner => self(), identity => maps:get(target, maps:get(dtx, Projection)),
      slot => Height, applied => Height,
      snapshot => quod_ledger_store:snapshot(Store), projection => Projection}.

verify_local_in_worker(Source, Ref, Phase) ->
    Caller = self(),
    Tag = make_ref(),
    _ = spawn(
          fun() ->
              Caller ! {Tag, quod_foreign_log:verify_local(
                               Source, Ref, Phase, 5000)}
          end),
    receive
        {Tag, Result} -> Result
    after 6000 ->
        error(verify_local_worker_timeout)
    end.

verify_local_current_entry_uses_exact_historical_committee_test() ->
    Fixture = long_identity_fixture(unique_ns(), 2),
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Binding = {Ns, Anchor},
    [Genesis, ReferencedEntry] = maps:get(chain, Fixture),
    #entry{data = {batch, [Referenced]}} = quod_ledger:entry_view(ReferencedEntry),
    {ok, Ref} = quod_dtx:certified_entry_ref(
                  Binding, ReferencedEntry, Referenced),
    OldPub = maps:get(pub, Fixture),
    OldSigner = maps:get(signer, Fixture),
    Admission = maps:get(admission, Fixture),
    NewPub = key(historical_committee_new_member),
    Membership0 = #transaction{
                    origin = Binding,
                    proof_id = key(historical_committee_proof),
                    plan_digest = key(historical_committee_plan),
                    goal = durable_goal({admit, NewPub}),
                    result = durable_result(),
                    diff = [{assert,
                             {{peer_admitted, NewPub,
                               "127.0.0.1", 19101, NewPub}, true}}],
                    read_check = #{}, author = OldPub, author_seq = 2,
                    submitted_at = 2, sig = none},
    Membership1 = quod_transaction:bind_id(Binding, Membership0),
    {ok, Membership} = quod_transaction:sign(
                         {Ns, Anchor, Admission}, Membership1, OldSigner),
    MembershipEntry = content_entry(
                        Ns, Anchor, OldPub, OldSigner, 3, [Membership]),
    Chain = [Genesis, ReferencedEntry, MembershipEntry],
    {ok, Chain, Projection} = quod_catchup:verify_forward(
                                Ns, Anchor,
                                quod_simplex:history_projection(Binding),
                                1, Chain),
    SourceDir = temp_dir("historical-local-source"),
    CacheDir = temp_dir("historical-local-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(Store0, Chain),
    Pid = start_owner(CacheDir, fun(_, _, _, _, _) -> {error, network_used} end),
    Source = local_test_view(Store1, Projection),
    try
        %% Ref was certified by the former committee. The current projection
        %% must not be substituted; the existing historical verifier supplies
        %% the exact committee era instead.
        ?assertMatch(
           {ok, #{phase := transaction, committee := [OldPub]}},
           quod_foreign_log:verify_local(
             Source, Ref, transaction, 5000))
    after
        true = gproc:unreg(quod_reg:name({quod_simplex, Ns})),
        stop_owner(Pid),
        quod_ledger_store:close(Store1),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

verify_local_committee_shrink_never_relabels_historical_entry_test() ->
    Ns = unique_ns(),
    Members = lists:sort(
                [begin
                     {Pub, Seed} = quod_identity:generate(),
                     {Pub, #{pubkey => Pub,
                             key => quod_identity:key_term({Pub, Seed})}}
                 end || _ <- lists:seq(1, 5)]),
    [{Author, AuthorSigner} | _] = Members,
    MemberKeys = [Pub || {Pub, _Signer} <- Members],
    GenesisTx = quod_simplex:test_genesis_tx(
                  #{committee => tl(MemberKeys),
                    node_addr => {"127.0.0.1", 19000}},
                  Ns, Author, key(shrink_genesis_incarnation)),
    {ok, Genesis} = quod_ledger:new_entry(
                      1, {batch, [GenesisTx]}, 0, none),
    Anchor = entry_hash(Genesis),
    Binding = {Ns, Anchor},
    {ok, [Genesis], GenesisProjection} = quod_catchup:verify_forward(
                                           Ns, Anchor,
                                           quod_simplex:history_projection(
                                             Binding),
                                           1, [Genesis]),
    {ok, AuthorBinding} = quod_simplex:history_binding(
                            Binding, Author, GenesisProjection),
    Referenced0 = #transaction{
                    origin = Binding,
                    proof_id = key(shrink_referenced_proof),
                    plan_digest = key(shrink_referenced_plan),
                    goal = durable_goal(shrink_referenced),
                    result = durable_result(),
                    diff = [{assert, {{shrink_referenced, true}, true}}],
                    read_check = #{}, author = Author, author_seq = 1,
                    submitted_at = 1, sig = none},
    Referenced1 = quod_transaction:bind_id(Binding, Referenced0),
    {ok, Referenced} = quod_transaction:sign(
                         AuthorBinding, Referenced1, AuthorSigner),
    OldQuorum = lists:sublist(Members, 4),
    ReferencedEntry = committee_content_entry(
                        Ns, Anchor, OldQuorum, 2, [Referenced]),
    Removed = lists:last(MemberKeys),
    Membership0 = #transaction{
                    origin = Binding,
                    proof_id = key(shrink_membership_proof),
                    plan_digest = key(shrink_membership_plan),
                    goal = durable_goal({remove, Removed}),
                    result = durable_result(),
                    diff = [{retract,
                             {{peer_admitted, Removed,
                               undefined, undefined, Removed}, true}}],
                    read_check = #{}, author = Author, author_seq = 2,
                    submitted_at = 2, sig = none},
    Membership1 = quod_transaction:bind_id(Binding, Membership0),
    {ok, Membership} = quod_transaction:sign(
                         AuthorBinding, Membership1, AuthorSigner),
    MembershipEntry = committee_content_entry(
                        Ns, Anchor, OldQuorum, 3, [Membership]),
    Chain = [Genesis, ReferencedEntry, MembershipEntry],
    {ok, Chain, FullProjection} = quod_catchup:verify_forward(
                                    Ns, Anchor,
                                    quod_simplex:history_projection(Binding),
                                    1, Chain),
    {ok, Ref} = quod_dtx:certified_entry_ref(
                  Binding, ReferencedEntry, Referenced),
    {ok, OldCommittee, OldCommitteeId, _} =
        quod_simplex:history_committee_view(2, FullProjection),
    [{3, CurrentCommittee, CurrentCommitteeId, CurrentRoutes} | _] =
        maps:get(committee_views, FullProjection),
    ?assertEqual(5, length(OldCommittee)),
    ?assertEqual(4, length(CurrentCommittee)),
    %% This is the live Simplex shape: one exact row for the current era plus
    %% its retained read-only index. Before the old-era fix, the old
    %% 4-of-5 certificate also satisfied the smaller current 3-of-4 quorum and
    %% the fast path returned CurrentCommitteeId for slot 2.
    SourceDir = temp_dir("shrink-local-source"),
    CacheDir = temp_dir("shrink-local-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(Store0, Chain),
    {ok, Index} = quod_dtx_phase_index:open(SourceDir, Ns),
    Pid = start_owner(CacheDir, fun(_, _, _, _, _) -> {error, network_used} end),
    Source = local_fixture_view(Store1, #{ns => Ns, anchor => Anchor, chain => Chain}, Index),
    ?assertEqual([{3, CurrentCommittee, CurrentCommitteeId, CurrentRoutes}],
                 maps:get(committee_views, maps:get(projection, Source))),
    try
        ?assertMatch(
           {ok, #{phase := transaction,
                  committee := OldCommittee,
                  committee_id := OldCommitteeId}},
           quod_foreign_log:verify_local(
             Source, Ref, transaction, 5000))
    after
        true = gproc:unreg(quod_reg:name({quod_simplex, Ns})),
        stop_owner(Pid),
        quod_dtx_phase_index:close(Index),
        quod_ledger_store:close(Store1),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

foreign_projection_loads_genesis_pinned_predicates_test() ->
    Ns = unique_ns(),
    Pub = key(210),
    Nonce = key(211),
    StaticBridgeHead =
        {directory_host, Ns, key(212), Pub, "127.0.0.1", 19000},
    AgentKey = {agent_key, {node, one}, Pub, active},
    Hosting = {hosts_ontology, {node, one}, Ns, key(213), discoverable},
    Genesis = quod_simplex:test_genesis_tx(
                #{node_id => Pub, mode => create, committee => [],
                  node_addr => {"127.0.0.1", 19000},
                  external_predicate_modules =>
                      [quod_directory_predicates],
                  genesis_diff =>
                      quod_prolog:terms_to_diff(
                        [StaticBridgeHead, AgentKey, Hosting])},
                Ns, Pub, Nonce),
    {ok, Entry} = quod_ledger:new_entry(
                    1, {batch, [Genesis]}, 1, none),
    Anchor = entry_hash(Entry),
    Root = temp_dir("projection-manifest"),
    CacheNs = <<"projection-cache:", Ns/binary>>,
    {ok, Store0} = quod_ledger_store:open(CacheNs, Root),
    {ok, Store1} = quod_ledger_store:append(Store0, [Entry]),
    View = projection_test_view(Store1, {Ns, Anchor}, Entry),
    ok = quod_ledger_store:close(Store1),
    {Pid, MRef, Generation} = quod_foreign_projection:start_monitor(
                                self(), {Ns, Anchor}, filename:join(Root, "scratch"), View),
    try
        ok = quod_foreign_projection:advance(
               Pid, Generation, View),
        Result = receive
                     {foreign_projection_ready, {Ns, Anchor}, Generation,
                      Ready} -> Ready
                 after 3000 ->
                     error(foreign_projection_timeout)
                 end,
        %% If the foreign worker ignored the genesis manifest, this ordinary
        %% assertion would materialize.  With the pinned bridge installed it
        %% is the same static procedure as on validators and is not changed.
        ?assertNot(
           lists:member(
             StaticBridgeHead, maps:get(changed_heads, Result))),
        {ok, Clauses} = quod_foreign_projection:clauses(
                          Pid, Generation,
                          [{agent_key, 3}, {hosts_ontology, 4}], 1000),
        ?assert(lists:any(
                  fun({Head, {[], false}}) -> Head =:= AgentKey;
                     (_) -> false
                  end, maps:get({agent_key, 3}, Clauses))),
        ?assert(lists:any(
                  fun({Head, {[], false}}) -> Head =:= Hosting;
                     (_) -> false
                  end, maps:get({hosts_ontology, 4}, Clauses)))
    after
        quod_foreign_projection:stop(Pid),
        receive {'DOWN', MRef, process, Pid, _} -> ok after 3000 -> ok end,
        _ = file:del_dir_r(Root)
    end.

foreign_projection_large_change_set_becomes_resnapshot_test() ->
    Ns = unique_ns(),
    Base = fixture_base(Ns),
    Pub = maps:get(pub, Base),
    Signer = maps:get(signer, Base),
    Anchor = maps:get(anchor, Base),
    Admission = maps:get(admission, Base),
    Binding = {Ns, Anchor},
    MakeTx =
        fun(Sequence, From, To) ->
            Tx0 = #transaction{
                     origin = Binding,
                     proof_id = key({projection_overflow_proof, Sequence}),
                     plan_digest = key({projection_overflow_plan, Sequence}),
                     goal = durable_goal({projection_overflow, Sequence}),
                     result = durable_result(),
                     diff = [{assert, {{projection_overflow, I}, true}}
                             || I <- lists:seq(From, To)],
                     read_check = #{}, author = Pub,
                     author_seq = Sequence, submitted_at = Sequence,
                     sig = none},
            Tx1 = quod_transaction:bind_id(Binding, Tx0),
            {ok, Tx} = quod_transaction:sign(
                         {Ns, Anchor, Admission}, Tx1, Signer),
            Tx
        end,
    Transactions =
        [MakeTx(1, 1, ?QUOD_MAX_PLAN_DIFF_OPS),
         MakeTx(2, ?QUOD_MAX_PLAN_DIFF_OPS + 1,
                ?QUOD_MAX_PLAN_DIFF_OPS + 1)],
    Entry = content_entry(Ns, Anchor, Pub, Signer, 2, Transactions),
    Root = temp_dir("projection-large-change-set"),
    CacheNs = <<"projection-cache:", Ns/binary>>,
    {ok, Store0} = quod_ledger_store:open(CacheNs, Root),
    {ok, Store1} = quod_ledger_store:append(
                     Store0, [maps:get(genesis, Base), Entry]),
    View = projection_test_view(Store1, {Ns, Anchor}, Entry),
    ok = quod_ledger_store:close(Store1),
    {Pid, MRef, Generation} = quod_foreign_projection:start_monitor(
                                self(), {Ns, Anchor}, filename:join(Root, "scratch"), View),
    try
        ok = quod_foreign_projection:advance(
               Pid, Generation, View),
        Ready = receive
                    {foreign_projection_ready, {Ns, Anchor}, Generation,
                     Result} -> Result;
                    {'DOWN', MRef, process, Pid, Reason} ->
                        error({foreign_projection_crashed, Reason})
                after 5000 ->
                    error(foreign_projection_timeout)
                end,
        ?assertEqual(true, maps:get(resnapshot, Ready)),
        ?assertEqual([], maps:get(changed_heads, Ready)),
        ?assertEqual([], maps:get(publications, Ready)),
        ?assert(is_process_alive(Pid))
    after
        quod_foreign_projection:stop(Pid),
        receive {'DOWN', MRef, process, Pid, _} -> ok after 3000 -> ok end,
        _ = file:del_dir_r(Root)
    end.

projection_test_view(Store, Identity, Entry) ->
    #{owner => self(), identity => Identity, slot => quod_ledger_store:last(Store),
      snapshot => quod_ledger_store:snapshot(Store),
      projection => #{history_head => {entry_index(Entry), entry_hash(Entry)}}}.

certified_current_view_advances_past_finalize_membership_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Dir = temp_dir("current-membership"),
    Ns = maps:get(ns, Fixture),
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    Routes = route_candidates(
               [{Old, {"127.0.0.1", 19000}},
                {New, {"127.0.0.1", 19101}}]),
    Pid = start_owner(
            Dir, peer_chain_fetch(Ns, maps:get(chain, Fixture), [Old, New])),
    try
        {ok, Historical} = quod_foreign_log:verify(
                             Old, {"127.0.0.1", 19000},
                             maps:get(ref, Fixture), finalize, 5000),
        {ok, Current} = quod_foreign_log:current(
                          Routes, {Ns, maps:get(anchor, Fixture)}, 5000),
        %% The current-view call advanced the resident cache past a committee
        %% rotation. Re-reading the older exact Finalize must still return the
        %% committee that was certified at its own slot, independently of the
        %% verifier's newer cache head and without a genesis replay.
        {ok, HistoricalAgain} = quod_foreign_log:verify_reference(
                                  maps:get(ref, Fixture), finalize, 5000),
        ?assertEqual(2, maps:get(slot, Historical)),
        ?assertEqual(3, maps:get(slot, Current)),
        ?assertEqual([Old], maps:get(committee, Historical)),
        ?assertEqual(maps:get(committee, Historical),
                     maps:get(committee, HistoricalAgain)),
        ?assertEqual(maps:get(committee_id, Historical),
                     maps:get(committee_id, HistoricalAgain)),
        ?assertEqual(lists:sort([Old, New]), maps:get(committee, Current)),
        ?assertNotEqual(maps:get(committee_id, Historical),
                        maps:get(committee_id, Current)),
        %% Applied evidence signed before the rotation remains valid against
        %% the exact Finalize evidence after the cache advances. Substituting
        %% the current head's committee view must fail.
        NetworkIdentity = key(179),
        GroupId = quod_dtx:group_id(maps:get(control, Fixture)),
        {ok, Vote} = quod_dtx_current_view:sign_applied_vote(
                       NetworkIdentity, {Ns, maps:get(anchor, Fixture)},
                       maps:get(committee_id, Historical), GroupId,
                       maps:get(ref, Fixture),
                       maps:get(generation, Historical), abort,
                       maps:get(signer, Fixture)),
        AppliedCertificate =
            {quod_dtx_applied_certificate, 1, NetworkIdentity,
             {Ns, maps:get(anchor, Fixture)},
             maps:get(committee_id, Historical), GroupId,
             maps:get(ref, Fixture), maps:get(generation, Historical),
             abort, [Vote]},
        ?assert(quod_dtx_current_view:verify_applied_certificate(
                  AppliedCertificate, NetworkIdentity, HistoricalAgain)),
        ?assertNot(quod_dtx_current_view:verify_applied_certificate(
                     AppliedCertificate, NetworkIdentity, Current)),
        ?assertEqual(
           lists:keysort(1, Routes), maps:get(route_candidates, Current))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

partial_cache_recovers_after_complete_committee_move_test() ->
    Fixture = complete_committee_move_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    OldEndpoint = {"127.0.0.1", 19000},
    NewEndpoint = {"127.0.0.1", 19101},
    Prefix = lists:sublist(maps:get(chain, Fixture), 2),
    FullChain = maps:get(chain, Fixture),
    Mode = atomics:new(1, []),
    ok = atomics:put(Mode, 1, 1),
    TestPid = self(),
    PrefixFetch = peer_chain_fetch(Ns, Prefix, [Old]),
    FullFetch = peer_chain_fetch(Ns, FullChain, [New]),
    Fetch =
        fun(Peer, Endpoint, RequestedNs, From, To) ->
            TestPid ! {committee_move_fetch, Peer, From},
            case {atomics:get(Mode, 1), Peer, Endpoint} of
                {1, Old, OldEndpoint} ->
                    PrefixFetch(Peer, Endpoint, RequestedNs, From, To);
                {2, New, NewEndpoint} ->
                    FullFetch(Peer, Endpoint, RequestedNs, From, To);
                _ ->
                    {error, unavailable}
            end
        end,
    Dir = temp_dir("complete-committee-move"),
    Pid = start_owner(Dir, Fetch),
    try
        %% Prime only the old certified prefix. The retained projection knows
        %% no current route except Old, exactly as after a node restarts before
        %% learning the later committee transition.
        ?assertMatch(
           {ok, #{slot := 2, committee := [Old]}},
           quod_foreign_log:verify(
             Old, OldEndpoint, maps:get(prefix_ref, Fixture), finalize, 5000)),
        ok = atomics:put(Mode, 1, 2),

        %% Old is now gone. New is merely the authenticated source which
        %% carried the request; its bytes gain no authority. The one history
        %% verifier must nevertheless be able to certify the transition and
        %% the later exact reference from those bytes.
        ?assertMatch(
           {ok, #{slot := 5, committee := [New]}},
           quod_foreign_log:verify_reference(
             maps:get(final_ref, Fixture), transaction,
             {New, NewEndpoint}, 5000)),
        ?assertMatch(
           {ok, #{slot := 5, committee := [New],
                  route_candidates := [{New, _}]}},
           quod_foreign_log:current(
             route_candidates([{New, NewEndpoint}]), Identity, 5000)),
        ?assertEqual(
           {ok, [{New, [NewEndpoint]}]},
           quod_foreign_log:route_hints(Identity, [])),
        Calls = collect_committee_move_fetches([]),
        ?assert(lists:member({New, 3}, Calls))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

current_view_recovers_partial_cache_after_complete_committee_move_test() ->
    Fixture = complete_committee_move_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    OldEndpoint = {"127.0.0.1", 19000},
    NewEndpoint = {"127.0.0.1", 19101},
    Prefix = lists:sublist(maps:get(chain, Fixture), 2),
    FullChain = maps:get(chain, Fixture),
    Mode = atomics:new(1, []),
    ok = atomics:put(Mode, 1, 1),
    PrefixFetch = peer_chain_fetch(Ns, Prefix, [Old]),
    FullFetch = peer_chain_fetch(Ns, FullChain, [New]),
    Fetch =
        fun(Peer, Endpoint, RequestedNs, From, To) ->
            case {atomics:get(Mode, 1), Peer, Endpoint} of
                {1, Old, OldEndpoint} ->
                    PrefixFetch(Peer, Endpoint, RequestedNs, From, To);
                {2, New, NewEndpoint} ->
                    FullFetch(Peer, Endpoint, RequestedNs, From, To);
                _ ->
                    {error, unavailable}
            end
        end,
    Dir = temp_dir("current-complete-committee-move"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{slot := 2, committee := [Old]}},
           quod_foreign_log:verify(
             Old, OldEndpoint, maps:get(prefix_ref, Fixture), finalize, 5000)),
        ok = atomics:put(Mode, 1, 2),
        ?assertMatch(
           {ok, #{slot := 5, committee := [New],
                  route_candidates := [{New, [NewEndpoint]}]}},
           quod_foreign_log:current(
             route_candidates([{New, NewEndpoint}]), Identity, 5000)),
        %% The fallback supplied history bytes only. It becomes an outward
        %% route precisely because those bytes certified New as the current
        %% committee, never merely because New answered the fetch.
        ?assertEqual(
           {ok, [{New, [NewEndpoint]}]},
           quod_foreign_log:route_hints(Identity, []))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

restart_rebuilds_committee_eras_for_old_exact_references_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Routes = route_candidates(
               [{Old, {"127.0.0.1", 19000}},
                {New, {"127.0.0.1", 19101}}]),
    Fetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Old, New]),
    Dir = temp_dir("restart-committee-eras"),
    Pid1 = start_owner(Dir, Fetch),
    {Historical, Current} =
        try
            {ok, Historical0} = quod_foreign_log:verify(
                                  Old, {"127.0.0.1", 19000},
                                  maps:get(ref, Fixture), finalize, 5000),
            {ok, Current0} = quod_foreign_log:current(
                               Routes, {Ns, maps:get(anchor, Fixture)}, 5000),
            {_Height, Checkpoint} = cache_checkpoint(Dir, Identity),
            ?assertEqual(false, maps:is_key(committee_views, Checkpoint)),
            {Historical0, Current0}
        after
            stop_owner(Pid1)
        end,
    Pid2 = start_owner(Dir, Fetch),
    try
        {ok, HistoricalAgain} = quod_foreign_log:verify_reference(
                                  maps:get(ref, Fixture), finalize, 5000),
        {ok, CurrentAgain} = quod_foreign_log:current(
                               Routes, {Ns, maps:get(anchor, Fixture)}, 5000),
        ?assertEqual(maps:get(committee, Historical),
                     maps:get(committee, HistoricalAgain)),
        ?assertEqual(maps:get(committee_id, Historical),
                     maps:get(committee_id, HistoricalAgain)),
        ?assertEqual(maps:get(committee, Current),
                     maps:get(committee, CurrentAgain)),
        ?assertEqual(maps:get(committee_id, Current),
                     maps:get(committee_id, CurrentAgain))
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(Dir)
    end.

identity_current_view_starts_at_genesis_and_tracks_rotation_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    Routes = route_candidates(
               [{Old, {"127.0.0.1", 19000}},
                {New, {"127.0.0.1", 19101}}]),
    TestPid = self(),
    Fetch0 = peer_chain_fetch(
               Ns, maps:get(chain, Fixture), [Old, New]),
    Fetch = fun(Peer, Endpoint, RequestedNs, From, To) ->
                    TestPid ! {identity_current_fetch, From},
                    Fetch0(Peer, Endpoint, RequestedNs, From, To)
            end,
    Dir = temp_dir("identity-current"),
    Pid = start_owner(Dir, Fetch),
    try
        {ok, Current} = quod_foreign_log:current(
                          Routes, {Ns, Anchor}, 5000),
        ?assertEqual(3, maps:get(slot, Current)),
        ?assertEqual(lists:sort([Old, New]), maps:get(committee, Current)),
        ?assertEqual(
           lists:keysort(1, Routes), maps:get(route_candidates, Current)),
        Fetches = collect_identity_current_fetches([]),
        ?assert(lists:member(1, Fetches))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

identity_current_bootstrap_fails_over_before_certified_routes_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Right = maps:get(pub, Fixture),
    Wrong = <<0:256>>,
    Endpoint = {"127.0.0.1", 19000},
    TestPid = self(),
    FetchTag = make_ref(),
    RightFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch =
        fun(Peer, GivenEndpoint, RequestedNs, From, To) ->
            TestPid ! {bootstrap_route_fetch, FetchTag, Peer, From},
            case {Peer, GivenEndpoint} of
                {Wrong, Endpoint} -> {error, retry};
                {Right, Endpoint} ->
                    RightFetch(Peer, GivenEndpoint, RequestedNs, From, To);
                _ -> {error, wrong_route}
            end
        end,
    Dir = temp_dir("identity-current-route-failover"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, committee := [Right]}},
           quod_foreign_log:current(
             route_candidates([{Wrong, Endpoint}, {Right, Endpoint}]),
             Identity, 5000)),
        Calls = collect_bootstrap_route_fetches(FetchTag, []),
        ?assertMatch([{Wrong, 1}, {Right, 1} | _], Calls),
        %% After the genesis page certifies Right for Endpoint, the conflicting
        %% discovery hint is never consulted again.
        ?assertEqual(
           1, length([ok || {Peer, _} <- Calls, Peer =:= Wrong]))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

identity_current_bootstrap_continues_after_selected_source_retry_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Right = maps:get(pub, Fixture),
    Wrong = <<0:256>>,
    Endpoint = {"127.0.0.1", 19000},
    TestPid = self(),
    FetchTag = make_ref(),
    ChainFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch =
        fun(Peer, GivenEndpoint, RequestedNs, From, To) ->
            TestPid ! {bootstrap_route_fetch, FetchTag, Peer, From},
            case {Peer, GivenEndpoint, To} of
                {Wrong, Endpoint, 1} ->
                    %% The discovery page is valid, but this source becomes
                    %% unavailable while the verified history is downloaded.
                    ChainFetch(Peer, GivenEndpoint, RequestedNs, From, To);
                {Wrong, Endpoint, _Later} ->
                    {error, retry};
                {Right, Endpoint, _} ->
                    ChainFetch(Peer, GivenEndpoint, RequestedNs, From, To);
                _ ->
                    {error, wrong_route}
            end
        end,
    Dir = temp_dir("identity-current-selected-route-retry"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, committee := [Right]}},
           quod_foreign_log:current(
             route_candidates([{Wrong, Endpoint}, {Right, Endpoint}]),
             Identity, 5000)),
        Calls = collect_bootstrap_route_fetches(FetchTag, []),
        ?assertEqual(
           2, length([ok || {Peer, _} <- Calls, Peer =:= Wrong])),
        ?assert(lists:any(fun({Peer, _}) -> Peer =:= Right end, Calls))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

identity_current_global_network_dependency_stops_route_failover_test() ->
    Name = list_to_atom(
             "foreign_identity_"
             ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | code:get_path()]}),
    try
        ?assertEqual(
           ok,
           peer:call(
             Peer, ?MODULE,
             identity_current_global_network_dependency_case, [], 15000))
    after
        _ = peer:stop(Peer)
    end.

%% Run in a fresh VM so no namespace started by another EUnit module can
%% satisfy the deliberately unavailable root-network dependency. This keeps
%% the route-policy test local without changing production identity precedence.
identity_current_global_network_dependency_case() ->
    Fixture = signed_content_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    %% Bootstrap routes are untrusted fetch hints, so they need not be the
    %% ledger signer.  Fix their canonical order explicitly: the assertion
    %% must exercise dependency failure at the selected first source rather
    %% than depend on a random signing key's sort position.
    [First, Second] = lists:sort([key(252), key(253)]),
    FirstEndpoint = {"127.0.0.1", 19000},
    SecondEndpoint = {"127.0.0.1", 19001},
    TestPid = self(),
    FetchTag = make_ref(),
    ChainFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch =
        fun(Peer, Endpoint, RequestedNs, From, To) ->
            TestPid ! {bootstrap_route_fetch, FetchTag, Peer, From},
            case {Peer, Endpoint} of
                {First, FirstEndpoint} ->
                    ChainFetch(Peer, Endpoint, RequestedNs, From, To);
                {Second, SecondEndpoint} ->
                    ChainFetch(Peer, Endpoint, RequestedNs, From, To);
                _ ->
                    {error, wrong_route}
            end
        end,
    Dir = temp_dir("identity-current-global-dependency"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:current(
             route_candidates(
               [{First, FirstEndpoint}, {Second, SecondEndpoint}]),
             Identity, 200)),
        Calls = collect_bootstrap_route_fetches(FetchTag, []),
        ?assertEqual([], [ok || {PeerKey, _} <- Calls, PeerKey =:= Second]),
        ok
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

identity_current_view_rejects_stale_malformed_and_uncertified_history_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Routes = route_candidates([{Peer, {"127.0.0.1", 19000}}]),
    [Genesis, Finalize, Membership] = maps:get(chain, Fixture),
    Cases =
        [{identity_stale,
          fun(_P, _E, RequestedNs, From, To) ->
                  case From =< 2 of
                      true -> page_reply(
                                RequestedNs, Ns,
                                [Genesis, Finalize], From, To, 2);
                      false -> {ok, [], 1}
                  end
          end},
         {identity_malformed,
          fun(_P, _E, RequestedNs, From, To) ->
                  page_reply(
                    RequestedNs, Ns,
                    [Genesis, Finalize, entry_at(Membership, 4)],
                    From, To, 4)
          end},
         {identity_uncertified,
          fun(_P, _E, RequestedNs, From, To) ->
                  page_reply(
                    RequestedNs, Ns,
                    [Genesis, Finalize, without_entry_cert(Membership)],
                    From, To, 3)
          end}],
    lists:foreach(
      fun({Name, Fetch}) ->
          Dir = temp_dir(atom_to_list(Name)),
          Pid = start_owner(Dir, Fetch),
          try
              ?assertEqual(
                 {error, retry},
                 quod_foreign_log:current(Routes, Identity, 100))
          after
              stop_owner(Pid),
              _ = file:del_dir_r(Dir)
          end
      end, Cases).

outsider_cannot_establish_identity_current_view_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Outsider = key(196),
    Fetch = peer_chain_fetch(
              Ns, maps:get(chain, Fixture), [Outsider]),
    Dir = temp_dir("identity-current-outsider"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:current(
             route_candidates([{Outsider, {"127.0.0.1", 19196}}]),
             Identity, 100))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

malformed_remote_identity_current_request_is_rejected_before_owner_test() ->
    ?assertEqual(
       {error, bad_foreign_reference},
       quod_foreign_log:current(
         route_candidates([{key(197), {"127.0.0.1", 19197}}]),
         {<<>>, key(198)}, 1000)).

current_view_rejects_stale_malformed_and_uncertified_pages_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Peer = maps:get(pub, Fixture),
    Routes = route_candidates([{Peer, {"127.0.0.1", 19000}}]),
    [Genesis, Finalize, Membership] = maps:get(chain, Fixture),
    Cases =
        [{stale, fun(_P, _E, RequestedNs, From, To) ->
                     case From =< 2 of
                         true -> page_reply(
                                   RequestedNs, Ns,
                                   [Genesis, Finalize], From, To, 2);
                         false -> {ok, [], 1}
                     end
                 end},
         {malformed, fun(_P, _E, RequestedNs, From, To) ->
                         case From =< 2 of
                             true -> page_reply(
                                       RequestedNs, Ns,
                                       [Genesis, Finalize], From, To, 2);
                             false ->
                                 {ok, [entry_at(Membership, 4)], 4}
                         end
                     end},
         {uncertified, fun(_P, _E, RequestedNs, From, To) ->
                           case From =< 2 of
                               true -> page_reply(
                                         RequestedNs, Ns,
                                         [Genesis, Finalize], From, To, 2);
                               false ->
                                   {ok, [without_entry_cert(Membership)], 3}
                           end
                       end}],
    lists:foreach(
      fun({Name, Fetch}) ->
          Dir = temp_dir(atom_to_list(Name)),
          Pid = start_owner(Dir, Fetch),
          try
              ?assertEqual(
                 {error, retry},
                 quod_foreign_log:current(Routes, {Ns, maps:get(anchor, Fixture)}, 100))
          after
              stop_owner(Pid),
              _ = file:del_dir_r(Dir)
          end
      end, Cases).

nonmember_route_cannot_corroborate_current_view_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Outsider = key(95),
    Fetch = peer_chain_fetch(
              Ns, maps:get(chain, Fixture), [Outsider]),
    Dir = temp_dir("current-nonmember"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:current(
             route_candidates([{Outsider, {"127.0.0.1", 19102}}]), {Ns, maps:get(anchor, Fixture)}, 100))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

current_view_caller_timeout_detaches_without_killing_shared_work_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Peer = maps:get(pub, Fixture),
    Ref = maps:get(ref, Fixture),
    Routes = route_candidates([{Peer, {"127.0.0.1", 19000}}]),
    TestPid = self(),
    Gate = atomics:new(1, []),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    TestPid ! {current_fetch_from, From},
                    case atomics:compare_exchange(Gate, 1, 1, 2) of
                        ok ->
                            TestPid ! {current_fetch_blocked, self()},
                            receive release_current_fetch -> ok end;
                        _ ->
                            ok
                    end,
                    BaseFetch(P, E, RequestedNs, From, To)
            end,
    Dir = temp_dir("current-timeout"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(
             Peer, {"127.0.0.1", 19000}, Ref, finalize, 2000)),
        flush_fetches(),
        ok = atomics:put(Gate, 1, 1),
        First = gen_server:send_request(
                  Pid, current_request(Routes, {Ns, maps:get(anchor, Fixture)}, none, 100)),
        Worker = receive
                     {current_fetch_blocked, FetchWorker} -> FetchWorker
                 after 2000 ->
                     error(current_fetch_not_started)
                 end,
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(First, 2000)),
        %% The caller is gone, but the one cache writer remains active.
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        ?assertEqual(1, maps:get(histories, quod_foreign_log:stats())),
        Second = gen_server:send_request(
                   Pid, current_request(Routes, {Ns, maps:get(anchor, Fixture)}, none, 2000)),
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        Worker ! release_current_fetch,
        ?assertMatch(
           {reply, {ok, #{slot := 2}}},
           gen_server:wait_response(Second, 3000)),
        ?assertEqual(0, maps:get(pending, quod_foreign_log:stats())),
        Fetches = collect_fetches([]),
        ?assert(Fetches =/= []),
        ?assert(lists:all(fun(From) -> From =:= 3 end, Fetches))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

request_scoped_contact_is_preferred_and_not_retained_on_failure_test() ->
    Identity = {unique_ns(), key(301)},
    Peer = key(302),
    Stale = {"127.0.0.1", 19301},
    Live = {"127.0.0.1", 19302},
    TestPid = self(),
    Fetch = fun(P, Endpoint, _Ns, _From, _To) ->
                    TestPid ! {request_contact_fetch, P, Endpoint},
                    {error, unavailable}
            end,
    Dir = temp_dir("request-contact"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:current(
             route_candidates([{Peer, Stale}]), Identity,
             {Peer, Live}, 1000)),
        receive
            {request_contact_fetch, Peer, Live} -> ok
        after 2000 ->
            error(request_contact_not_preferred)
        end,
        %% An unverifiable claim leaves neither a decoded history row nor a
        %% persistent bootstrap address. No population cap is needed.
        ?assertMatch(
           #{histories := 0, bootstrap_candidates := 0},
           quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

request_scoped_contact_precedes_stale_bootstrap_at_tip_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Stale = {"127.0.0.1", 19303},
    Live = {"127.0.0.1", 19304},
    TestPid = self(),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch = fun(P, Endpoint, RequestedNs, From, To) ->
                    TestPid ! {request_tip_fetch, Endpoint},
                    case Endpoint of
                        Live -> BaseFetch(P, Endpoint, RequestedNs, From, To);
                        _ -> {error, unavailable}
                    end
            end,
    Dir = temp_dir("request-contact-tip"),
    Pid = start_owner(Dir, Fetch),
    try
        %% A retained contact can name the peer's previous allocation.  The
        %% authenticated endpoint carrying this request must win both while
        %% fetching genesis and while corroborating the resulting current tip.
        quod_foreign_log:observe_candidate(Identity, {Peer, Stale}),
        ?assertMatch(
           {ok, #{identity := Identity, slot := 2}},
           quod_foreign_log:current(
             route_candidates([{Peer, Stale}]), Identity,
             {Peer, Live}, 5000)),
        Calls = collect_request_tip_fetches([]),
        ?assert(length(Calls) >= 2),
        ?assert(lists:all(fun(Endpoint) -> Endpoint =:= Live end, Calls))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

collect_request_tip_fetches(Acc) ->
    receive
        {request_tip_fetch, Endpoint} ->
            collect_request_tip_fetches([Endpoint | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

long_identity_convergence_survives_caller_timeout_test_() ->
    {timeout, 30,
     fun long_identity_convergence_survives_caller_timeout/0}.

long_identity_convergence_survives_caller_timeout() ->
    Fixture = long_identity_fixture(unique_ns(), 1025),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19205},
    Routes = route_candidates([{Peer, Endpoint}]),
    TestPid = self(),
    Gate = atomics:new(1, []),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    TestPid ! {long_current_fetch, From},
                    case From =:= 257 andalso
                         atomics:compare_exchange(Gate, 1, 0, 1) =:= ok of
                        true ->
                            TestPid ! {long_current_blocked, self()},
                            receive release_long_current -> ok end;
                        false ->
                            ok
                    end,
                    BaseFetch(P, E, RequestedNs, From, To)
            end,
    Dir = temp_dir("long-current-timeout"),
    Pid = start_owner_opts(
            Dir, Fetch, #{page_timeout_ms => 5000}),
    try
        First = gen_server:send_request(
                  Pid, current_request(Routes, Identity, none, 100)),
        Worker = receive
                     {long_current_blocked, FetchWorker} -> FetchWorker
                 after 5000 ->
                     error(long_current_second_page_not_reached)
                 end,
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(First, 2000)),
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        Second = gen_server:send_request(
                   Pid, current_request(Routes, Identity, none, 15000)),
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        Worker ! release_long_current,
        ?assertMatch(
           {reply, {ok, #{slot := 1025}}},
           gen_server:wait_response(Second, 15000)),
        Fetches = collect_long_current_fetches([]),
        %% Genesis is fetched once for discovery and once as the first page.
        %% A restarted job would add another From=1 fetch.
        ?assertEqual(2, length([ok || 1 <- Fetches])),
        ?assert(lists:member(257, Fetches)),
        ?assert(lists:member(513, Fetches)),
        ?assert(lists:member(769, Fetches)),
        ?assert(lists:member(1025, Fetches)),
        ?assertEqual(0, maps:get(pending, quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

identical_current_identity_requests_share_one_verification_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19098},
    Routes = route_candidates([{Peer, Endpoint}]),
    RoutesWithAnotherHint = route_candidates(
                             [{Peer, Endpoint},
                              {key(199), {"127.0.0.1", 19199}}]),
    TestPid = self(),
    First = atomics:new(1, []),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    case atomics:add_get(First, 1, 1) of
                        1 ->
                            TestPid ! {shared_current_fetch, self()},
                            receive release_shared_current -> ok end;
                        _ ->
                            ok
                    end,
                    BaseFetch(P, E, RequestedNs, From, To)
            end,
    Dir = temp_dir("shared-current-identity"),
    Pid = start_owner(Dir, Fetch),
    try
        FirstRequest = gen_server:send_request(
                         Pid, current_request(
                                Routes, Identity, none, 2000)),
        Worker = receive
                     {shared_current_fetch, FetchWorker} -> FetchWorker
                 after 2000 ->
                     error(shared_current_fetch_not_started)
                 end,
        SecondRequest = gen_server:send_request(
                          Pid, current_request(
                                 RoutesWithAnotherHint,
                                 Identity, none, 100)),
        %% This stats call is sent after the second request by the same
        %% process, so it is a deterministic mailbox barrier, not a sleep.
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        Worker ! release_shared_current,
        {reply, {ok, FirstView}} =
            gen_server:wait_response(FirstRequest, 3000),
        {reply, {ok, SecondView}} =
            gen_server:wait_response(SecondRequest, 3000),
        ?assertEqual(FirstView, SecondView),
        ?assertEqual(0, maps:get(pending, quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

queued_identical_callers_expire_without_cancelling_the_job_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19310},
    Routes = route_candidates([{Peer, Endpoint}]),
    TestPid = self(),
    Gate = atomics:new(1, []),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    case atomics:compare_exchange(Gate, 1, 0, 1) of
                        ok ->
                            TestPid ! {distinct_work_blocked, self()},
                            receive release_distinct_work -> ok end;
                        _ ->
                            case From =:= 3 andalso
                                 atomics:compare_exchange(
                                   Gate, 1, 1, 2) =:= ok of
                                true ->
                                    TestPid ! {callerless_job_blocked, self()},
                                    receive release_callerless_job -> ok end;
                                false ->
                                    ok
                            end
                    end,
                    BaseFetch(P, E, RequestedNs, From, To)
            end,
    Dir = temp_dir("queued-shared-current"),
    Pid = start_owner(Dir, Fetch),
    try
        Active = gen_server:send_request(
                   Pid, owner_request({verify, Peer, Endpoint, maps:get(ref, Fixture),
                                       finalize, 5000})),
        ActiveWorker = receive
                           {distinct_work_blocked, Worker} -> Worker
                       after 2000 ->
                           error(distinct_work_not_started)
                       end,
        First = gen_server:send_request(
                  Pid, current_request(Routes, Identity, none, 100)),
        Second = gen_server:send_request(
                   Pid, current_request(Routes, Identity, none, 150)),
        %% Both callers own one queued work item, not duplicate catch-up jobs.
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(First, 2000)),
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Second, 2000)),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        ActiveWorker ! release_distinct_work,
        ?assertMatch(
           {reply, {ok, _}}, gen_server:wait_response(Active, 3000)),
        %% The now-callerless queued job still starts from the certified prefix
        %% and finishes; caller expiry did not cancel shared history progress.
        CallerlessWorker = receive
            {callerless_job_blocked, Worker2} -> Worker2
        after 3000 ->
            error(callerless_queued_job_not_started)
        end,
        Third = gen_server:send_request(
                  Pid, current_request(Routes, Identity, none, 2000)),
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        CallerlessWorker ! release_callerless_job,
        ?assertMatch(
           {reply, {ok, #{slot := 2}}},
           gen_server:wait_response(Third, 3000)),
        ?assertEqual(0, maps:get(queued, quod_foreign_log:stats())),
        ?assertEqual(0, maps:get(pending, quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

corrupt_cache_is_discarded_and_refetched_from_genesis_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("corrupt-restart"),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Ref = maps:get(ref, Fixture),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19096},
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000))
    after
        stop_owner(Pid)
    end,
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    CacheDir = quod_ledger_store:ns_dir(Dir, CacheNs),
    ok = file:write_file(
           filename:join(CacheDir, "checkpoint.term"), <<"corrupt">>),
    TestPid = self(),
    Fetch0 = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    TestPid ! {corrupt_cache_fetch_from, From},
                    Fetch0(P, E, RequestedNs, From, To)
            end,
    Pid2 = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        receive
            {corrupt_cache_fetch_from, 1} -> ok
        after 1000 ->
            error(cache_was_not_refetched_from_genesis)
        end,
        assert_history_integrity_counts(0, 1, 0)
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(Dir)
    end.

tampered_reference_and_phase_are_rejected_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("tamper"),
    Ns = maps:get(ns, Fixture),
    Fetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Pid = start_owner(Dir, Fetch),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19092},
    Ref = maps:get(ref, Fixture),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        {quod_dtx_ref, 2, RNs, Anchor, Slot, BlockHash, Digest, Proof} = Ref,
        BadHash = {quod_dtx_ref, 2, RNs, Anchor, Slot, key(201),
                   Digest, Proof},
        BadDigest = {quod_dtx_ref, 2, RNs, Anchor, Slot, BlockHash,
                     key(202), Proof},
        BadProof = {quod_dtx_ref, 2, RNs, Anchor, Slot, BlockHash,
                    Digest, <<"different-qc">>},
        ?assertMatch(
           {error, _},
           quod_foreign_log:verify(
             Peer, Endpoint, BadHash, finalize, 5000)),
        ?assertMatch(
           {error, _},
           quod_foreign_log:verify(
             Peer, Endpoint, BadDigest, finalize, 5000)),
        ?assertMatch(
           {error, _},
           quod_foreign_log:verify(
             Peer, Endpoint, BadProof, finalize, 5000)),
        ?assertEqual(
           {error, phase_mismatch},
           quod_foreign_log:verify(
             Peer, Endpoint, Ref, decision, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

equivalent_claim_does_not_authorize_invalid_signature_or_wrong_era_test() ->
    Fixture = complete_committee_move_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Ref = maps:get(prefix_ref, Fixture),
    {quod_dtx_ref, 2, Ns, Anchor, Slot, Hash, _, Proof} = Ref,
    Cert = binary_to_term(Proof, [safe]),
    [{OldPub, _}] = Cert#cert.sigs,
    BadSig = setelement(8, Ref, term_to_binary(
        Cert#cert{sigs = [{OldPub, <<0:512>>}]}, [deterministic])),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    NewPub = maps:get(new_pub, Fixture),
    NewShare = quod_simplex:make_share(
        Domain, commit, Slot, Hash, maps:get(new_signer, Fixture)),
    {ok, NewCert} = quod_simplex:form_cert(
        Domain, commit, Slot, Hash, [NewShare], [NewPub]),
    ?assert(quod_simplex:verify_cert(Domain, NewCert, [NewPub])),
    WrongEra = setelement(8, Ref, term_to_binary(NewCert, [deterministic])),
    Dir = temp_dir("exact-reference-era"),
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    Endpoint = {"127.0.0.1", 19092},
    try
        %% Advance through the real certified committee replacement first.
        %% The old entry must still be judged by its old era, not the head's.
        ?assertMatch({ok, #{committee := [NewPub]}},
            quod_foreign_log:verify(NewPub, Endpoint,
                                   maps:get(final_ref, Fixture), transaction, 5000)),
        ?assertMatch({ok, #{committee := [OldPub]}},
            quod_foreign_log:verify(NewPub, Endpoint, Ref, finalize, 5000)),
        lists:foreach(fun(BadRef) ->
            %% Claim equality deliberately confers no authentication. The
            %% existing exact-history verifier refuses before returning any
            %% usable evidence to consensus validation / the outcome reducer.
            ?assert(quod_dtx:same_certified_ref(Ref, BadRef)),
            ?assertEqual({error, invalid_foreign_reference},
                quod_foreign_log:verify(NewPub, Endpoint, BadRef, finalize, 5000))
        end, [BadSig, WrongEra])
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

prepared_reference_reports_post_slot_generation_test() ->
    Fixture = prepared_fixture(unique_ns()),
    Dir = temp_dir("prepare-generation"),
    Ns = maps:get(ns, Fixture),
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    try
        ?assertMatch(
           {ok, #{phase := prepare, generation := 0}},
           quod_foreign_log:verify(
             maps:get(pub, Fixture), {"127.0.0.1", 19095},
             maps:get(ref, Fixture),
             prepare, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

local_prepared_reference_uses_the_same_exact_verifier_test() ->
    Fixture = prepared_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    SourceDir = temp_dir("local-prepare-source"),
    CacheDir = temp_dir("local-prepare-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(
                     Store0, maps:get(chain, Fixture)),
    Source = local_fixture_view(Store1, Fixture),
    ok = quod_ledger_store:close(Store1),
    Pid = start_owner(
            CacheDir, fun(_, _, _, _, _) -> {error, network_used} end),
    try
        ?assertMatch(
           {ok, #{phase := prepare, generation := 0}},
           quod_foreign_log:verify_local(
             Source, maps:get(ref, Fixture), prepare, 5000))
    after
        true = gproc:unreg(quod_reg:name({quod_simplex, Ns})),
        stop_owner(Pid),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

cached_earlier_reference_reuses_certified_current_projection_test() ->
    Fixture = prepared_then_committed_fixture(unique_ns()),
    Dir = temp_dir("historical-generation"),
    Ns = maps:get(ns, Fixture),
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19097},
    try
        ?assertMatch(
           {ok, #{phase := finalize, generation := 1}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(finalize_ref, Fixture),
             finalize, 5000)),
        [SessionFile] = phase_session_files(Dir, {Ns, maps:get(anchor, Fixture)}),
        %% The cache is now certified through slot 3.  The immutable slot-2
        %% Prepare is checked against its retained entry while committee-era
        %% routing metadata comes from the resident projection. Prepare recovery reads the
        %% exact base generation from its signed plan, not this current-view
        %% field.  Replacing the phase session would prove a hidden replay.
        ?assertMatch(
           {ok, #{phase := prepare, generation := 1}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(prepare_ref, Fixture), prepare, 5000)),
        ?assertEqual(
           [SessionFile],
           phase_session_files(Dir, {Ns, maps:get(anchor, Fixture)})),
        %% Reusing the certified resident prefix never turns membership in the
        %% local store into authority.  The requested digest must still rebuild
        %% the exact certified reference from that slot's retained entry.
        BadDigestRef = setelement(
                         7, maps:get(prepare_ref, Fixture),
                         key(retained_wrong_record_digest)),
        ?assertEqual(
           {error, invalid_foreign_reference},
           quod_foreign_log:verify(
             Peer, Endpoint, BadDigestRef, prepare, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

wrong_anchor_and_unavailable_history_only_retry_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("anchor"),
    Ns = maps:get(ns, Fixture),
    Fetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Pid = start_owner(Dir, Fetch),
    Peer = key(93),
    Endpoint = {"127.0.0.1", 19093},
    {quod_dtx_ref, 2, RNs, _Anchor, Slot, BlockHash, Digest, Proof} =
        maps:get(ref, Fixture),
    WrongAnchorRef = {quod_dtx_ref, 2, RNs, key(203), Slot,
                      BlockHash, Digest, Proof},
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:verify(
             Peer, Endpoint, WrongAnchorRef, finalize, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end,

    EmptyDir = temp_dir("unavailable"),
    Missing = fun(_, _, _, _, _) -> {ok, [], 0} end,
    Pid2 = start_owner(EmptyDir, Missing),
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000))
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(EmptyDir)
    end.

fetch_dependency_exit_is_retry_but_programmer_fault_is_visible_test() ->
    fetch_dependency_failure_case(noproc, normal),
    fetch_dependency_failure_case(
      programmer_fault, {foreign_fetch_dependency_fault, stacktrace}).

fetch_dependency_failure_case(Failure, ExpectedReason) ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19093},
    TestPid = self(),
    Fetch =
        fun(_Peer, _Endpoint, _RequestedNs, _From, _To) ->
            TestPid ! {foreign_fetch_dependency, Failure, self()},
            receive
                {continue_foreign_fetch, Failure} -> ok
            end,
            case Failure of
                noproc -> exit(noproc);
                programmer_fault -> error(foreign_fetch_dependency_fault)
            end
        end,
    Dir = temp_dir("fetch-dependency"),
    Owner = start_owner(Dir, Fetch),
    Caller = spawn(
               fun() ->
                   TestPid !
                       {foreign_fetch_result, Failure,
                        quod_foreign_log:current(
                          route_candidates([{Peer, Endpoint}]),
                          Identity, 2000)}
               end),
    try
        Probe = receive
                    {foreign_fetch_dependency, Failure, Pid} -> Pid
                after 2000 ->
                    error({fetch_dependency_not_called, Failure})
                end,
        ProbeMonitor = erlang:monitor(process, Probe),
        Probe ! {continue_foreign_fetch, Failure},
        receive
            {'DOWN', ProbeMonitor, process, Probe, Reason} ->
                assert_fetch_failure_reason(ExpectedReason, Reason)
        after 2000 ->
            error({fetch_probe_survived, Failure})
        end,
        receive
            {foreign_fetch_result, Failure, {error, retry}} -> ok
        after 3000 ->
            error({missing_fetch_failure_result, Failure, Caller})
        end,
        ?assert(is_process_alive(Owner))
    after
        stop_owner(Owner),
        _ = file:del_dir_r(Dir)
    end.

assert_fetch_failure_reason(normal, normal) ->
    ok;
assert_fetch_failure_reason(
  {foreign_fetch_dependency_fault, stacktrace},
  {foreign_fetch_dependency_fault, [_ | _]}) ->
    ok;
assert_fetch_failure_reason(Expected, Actual) ->
    error({unexpected_fetch_failure_reason, Expected, Actual}).

decoded_page_bounds_test() ->
    Tiny = quod_ledger:noop_entry(1, none),
    ?assertEqual(
       {error, too_many_entries},
       quod_catchup:page_stats(
         lists:duplicate(?QUOD_MAX_FOREIGN_PAGE_ENTRIES + 1, Tiny))),
    LargePayload = largest_payload(<<"foreign:page-bound">>),
    Huge = [begin
                {ok, Entry} = quod_ledger:new_entry(
                                I, LargePayload, 0, none),
                Entry
            end || I <- lists:seq(1, 4)],
    ?assertEqual({error, page_too_large},
                 quod_catchup:page_stats(Huge)).

worst_case_implicit_entry_frame_stays_below_budget_test() ->
    Ns = <<"foreign:frame-bound">>,
    Payload = largest_payload(Ns),
    {ok, PayloadBytes} = quod_ledger:encoded_payload_size(Payload),
    ?assert(PayloadBytes =< ?MAX_BLOCK_BYTES),
    Signatures = [{key(I), <<I:512>>} || I <- lists:seq(1, ?MAX_VALIDATORS)],
    {ok, Parent} = quod_ledger:new_block(2, 1, Payload, 0),
    {ok, Child} = quod_ledger:new_block(3, 2, Payload, 0),
    Support = #cert{kind = support, slot = 2,
                    block_hash = quod_simplex:block_hash(Parent),
                    sigs = Signatures},
    Commit = #cert{kind = commit, slot = 3,
                   block_hash = quod_simplex:block_hash(Child),
                   sigs = Signatures},
    Entry = quod_ledger:entry(
              Parent, #implicit_cert{support = Support,
                                     child = Child, commit = Commit}),
    {ok, Blob} = quod_ledger:encode_entry(Entry),
    Frame = quod_catchup:encode_frame(
              Ns, {blocks_resp_bytes, crypto:strong_rand_bytes(16),
                   crypto:strong_rand_bytes(16), [Blob], 3,
                   crypto:strong_rand_bytes(16)}),
    ?assert(byte_size(Frame) < ?QUOD_MAX_FOREIGN_PAGE_BYTES),
    ?assertMatch({ok, 1, _}, quod_catchup:page_stats([Entry])).

%%%===================================================================
%%% Fixtures
%%%===================================================================

foreign_fixture(Ns) ->
    Base = fixture_base(Ns),
    Pub = maps:get(pub, Base),
    Signer = maps:get(signer, Base),
    Genesis = maps:get(genesis, Base),
    Anchor = maps:get(anchor, Base),
    Binding = {Ns, Anchor},
    Admission = maps:get(admission, Base),
    GroupId = key(70),
    DecisionIdentity = {<<"origin:", Ns/binary>>, key(71)},
    DecisionRef = ref(DecisionIdentity, 7, 72),
    {ok, FinalizeRecord} =
        quod_dtx:new_finalize(GroupId, DecisionRef, abort, none, 0),
    {ok, Control} =
        quod_dtx:sign_control(
          Binding, FinalizeRecord, Admission, 1, 1, Signer),
    {ok, ControlBlob} = quod_dtx:encode_control(Control),
    Entry = control_entry(Ns, Anchor, Pub, Signer, 2, ControlBlob),
    {ok, Ref} = quod_dtx:certified_entry_ref(Binding, Entry, Control),
    #{ns => Ns, pub => Pub, signer => Signer, anchor => Anchor,
      admission => Admission,
      chain => [Genesis, Entry], ref => Ref, control => Control}.

byte_large_foreign_fixture(Ns) ->
    Fixture = foreign_fixture(Ns),
    Pub = maps:get(pub, Fixture),
    Signer = maps:get(signer, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Admission = maps:get(admission, Fixture),
    Binding = {Ns, Anchor},
    Blob = binary:copy(<<16#aa>>, 48 * 1024),
    Entries =
        [begin
             Tx0 = #transaction{
                     origin = Binding,
                     proof_id = key(300 + Sequence),
                     plan_digest = key(400 + Sequence),
                     goal = durable_goal({large_history, Sequence}),
                     result = durable_result(),
                     diff = [{assert,
                              {{large_history, Sequence, Blob}, true}}],
                     read_check = #{}, author = Pub,
                     author_seq = Sequence,
                     submitted_at = Sequence, sig = none},
             Tx1 = quod_transaction:bind_id(Binding, Tx0),
             {ok, Tx} = quod_transaction:sign(
                          {Ns, Anchor, Admission}, Tx1, Signer),
             content_entry(
               Ns, Anchor, Pub, Signer, Sequence + 1, [Tx])
         end || Sequence <- lists:seq(2, 22)],
    Fixture#{chain := maps:get(chain, Fixture) ++ Entries}.

long_identity_fixture(Ns, Height) when Height > 1 ->
    Base = fixture_base(Ns),
    Pub = maps:get(pub, Base),
    Signer = maps:get(signer, Base),
    Anchor = maps:get(anchor, Base),
    Admission = maps:get(admission, Base),
    Binding = {Ns, Anchor},
    Entries =
        [begin
             Sequence = Slot - 1,
             Tx0 = #transaction{
                     origin = Binding,
                     proof_id = key({long_proof, Slot}),
                     plan_digest = key({long_plan, Slot}),
                     goal = durable_goal({long_history, Slot}),
                     result = durable_result(),
                     diff = [{assert, {{long_history, Slot}, true}}],
                     read_check = #{}, author = Pub,
                     author_seq = Sequence,
                     submitted_at = Sequence, sig = none},
             Tx1 = quod_transaction:bind_id(Binding, Tx0),
             {ok, Tx} = quod_transaction:sign(
                          {Ns, Anchor, Admission}, Tx1, Signer),
             content_entry(Ns, Anchor, Pub, Signer, Slot, [Tx])
         end || Slot <- lists:seq(2, Height)],
    Base#{ns => Ns,
          chain => [maps:get(genesis, Base) | Entries]}.

signed_content_fixture(Ns) ->
    ClientKeyPair = quod_identity:generate(),
    {ClientPub, _ClientSeed} = ClientKeyPair,
    AgentInstance = {human_user, test_agent},
    Base = fixture_base(
             Ns, [{agent_key, AgentInstance, ClientPub, active}]),
    Pub = maps:get(pub, Base),
    Signer = maps:get(signer, Base),
    Anchor = maps:get(anchor, Base),
    Admission = maps:get(admission, Base),
    Network = key(254),
    RequestFixture = quod_ct:signed_dtx_begin_fixture(
                       #{target => {Ns, Anchor}, network => Network,
                         key_pair => ClientKeyPair}),
    Unsigned = (maps:get(transaction, RequestFixture))#transaction{
                 author = Pub, author_seq = 1, sig = none,
                 signed_bytes = none},
    {ok, Signed} = quod_transaction:sign(
                     {Ns, Anchor, Admission}, Unsigned, Signer),
    Entry = content_entry(Ns, Anchor, Pub, Signer, 2, [Signed]),
    Base#{ns => Ns, network => Network,
          chain => [maps:get(genesis, Base), Entry]}.

membership_after_finalize_fixture(Ns) ->
    Fixture = foreign_fixture(Ns),
    OldPub = maps:get(pub, Fixture),
    OldSigner = maps:get(signer, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Binding = {Ns, Anchor},
    {NewPub, _NewSeed} = quod_identity:generate(),
    Projection1 = quod_simplex:history_advance(
                    Ns, hd(maps:get(chain, Fixture)),
                    quod_simplex:history_projection()),
    Goal = durable_goal({admit, NewPub}),
    Result = durable_result(),
    Tx0 = #transaction{
             origin = Binding,
             proof_id = key(180), plan_digest = key(181),
             goal = Goal, result = Result,
             diff = [{assert,
                      {{peer_admitted, NewPub,
                        "127.0.0.1", 19101, NewPub}, true}}],
             read_check = #{}, author = OldPub,
             author_seq = 1, submitted_at = 1, sig = none},
    Tx1 = quod_transaction:bind_id(Binding, Tx0),
    {ok, AuthorBinding} = quod_simplex:history_binding(
                            Binding, OldPub, Projection1),
    {ok, Tx} = quod_transaction:sign(
                 AuthorBinding, Tx1, OldSigner),
    Entry = content_entry(
              Ns, Anchor, OldPub, OldSigner, 3, [Tx]),
    Fixture#{chain := maps:get(chain, Fixture) ++ [Entry],
             new_pub => NewPub}.

complete_committee_move_fixture(Ns) ->
    Fixture = foreign_fixture(Ns),
    OldPub = maps:get(pub, Fixture),
    OldSigner = maps:get(signer, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Binding = {Ns, Anchor},
    {NewPub, NewSeed} = quod_identity:generate(),
    NewSigner = #{pubkey => NewPub,
                  key => quod_identity:key_term({NewPub, NewSeed})},
    Prefix = maps:get(chain, Fixture),
    Projection1 = quod_simplex:history_advance(
                    Ns, hd(Prefix), quod_simplex:history_projection()),
    {ok, OldBinding2} = quod_simplex:history_binding(
                          Binding, OldPub, Projection1),
    Add0 = #transaction{
             origin = Binding,
             proof_id = key(committee_move_add_proof),
             plan_digest = key(committee_move_add_plan),
             goal = durable_goal({admit, NewPub}), result = durable_result(),
             diff = [{assert,
                      {{peer_admitted, NewPub,
                        "127.0.0.1", 19101, NewPub}, true}}],
             read_check = #{}, author = OldPub, author_seq = 1,
             submitted_at = 1, sig = none},
    Add1 = quod_transaction:bind_id(Binding, Add0),
    {ok, Add} = quod_transaction:sign(OldBinding2, Add1, OldSigner),
    AddEntry = content_entry(Ns, Anchor, OldPub, OldSigner, 3, [Add]),
    Projection3 = quod_simplex:history_advance(Ns, AddEntry, Projection1),
    {ok, OldBinding3} = quod_simplex:history_binding(
                          Binding, OldPub, Projection3),
    Remove0 = #transaction{
                origin = Binding,
                proof_id = key(committee_move_remove_proof),
                plan_digest = key(committee_move_remove_plan),
                goal = durable_goal({remove, OldPub}),
                result = durable_result(),
                diff = [{retract,
                         {{peer_admitted, OldPub,
                           undefined, undefined, OldPub}, true}}],
                read_check = #{}, author = OldPub, author_seq = 2,
                submitted_at = 2, sig = none},
    Remove1 = quod_transaction:bind_id(Binding, Remove0),
    {ok, Remove} = quod_transaction:sign(
                     OldBinding3, Remove1, OldSigner),
    RemoveEntry = committee_content_entry(
                    Ns, Anchor,
                    [{OldPub, OldSigner}, {NewPub, NewSigner}],
                    4, [Remove]),
    Projection4 = quod_simplex:history_advance(
                    Ns, RemoveEntry, Projection3),
    ?assertEqual([NewPub], quod_simplex:history_committee(Projection4)),
    {ok, NewBinding4} = quod_simplex:history_binding(
                          Binding, NewPub, Projection4),
    Final0 = #transaction{
               origin = Binding,
               proof_id = key(committee_move_final_proof),
               plan_digest = key(committee_move_final_plan),
               goal = durable_goal(committee_move_final),
               result = durable_result(),
               diff = [{assert, {{committee_move_final, true}, true}}],
               read_check = #{}, author = NewPub, author_seq = 1,
               submitted_at = 3, sig = none},
    Final1 = quod_transaction:bind_id(Binding, Final0),
    {ok, Final} = quod_transaction:sign(NewBinding4, Final1, NewSigner),
    FinalEntry = content_entry(
                   Ns, Anchor, NewPub, NewSigner, 5, [Final]),
    {ok, FinalRef} = quod_dtx:certified_entry_ref(
                       Binding, FinalEntry, Final),
    Fixture#{chain := Prefix ++ [AddEntry, RemoveEntry, FinalEntry],
             prefix_ref => maps:get(ref, Fixture),
             final_ref => FinalRef,
             new_pub => NewPub, new_signer => NewSigner}.

prepared_fixture(Ns) ->
    Base = fixture_base(Ns),
    Pub = maps:get(pub, Base),
    Signer = maps:get(signer, Base),
    Genesis = maps:get(genesis, Base),
    Anchor = maps:get(anchor, Base),
    Binding = {Ns, Anchor},
    Admission = maps:get(admission, Base),
    Origin = {<<"prepare-origin:", Ns/binary>>, key(80)},
    %% Reuse the shared public constructor so this foreign-history fixture
    %% cannot retain an old plan/signature preimage when that protocol evolves.
    BeginFixture = quod_ct:signed_dtx_begin_fixture(
                     #{target => Origin,
                       participant_target => Binding,
                       node_identity => Signer,
                       admission => Admission,
                       proof_id => key(83),
                       operation_id => key(82)}),
    Begin = maps:get('begin', BeginFixture),
    GroupId = quod_dtx:group_id(Begin),
    BeginRef = ref_with_digest(Origin, 7, key(84), GroupId),
    {ok, PrepareRecord} = quod_dtx:new_prepare(
                            Begin, BeginRef, Binding),
    {ok, Control} = quod_dtx:sign_control(
                      Binding, PrepareRecord, Admission, 1, 1, Signer),
    {ok, ControlBlob} = quod_dtx:encode_control(Control),
    Entry = control_entry(Ns, Anchor, Pub, Signer, 2, ControlBlob),
    {ok, Ref} = quod_dtx:certified_entry_ref(Binding, Entry, Control),
    #{ns => Ns, pub => Pub, anchor => Anchor, signer => Signer,
      admission => Admission, origin => Origin, group_id => GroupId,
      chain => [Genesis, Entry], ref => Ref, prepare_ref => Ref,
      control => Control}.

prepared_then_committed_fixture(Ns) ->
    Prepared = prepared_fixture(Ns),
    Binding = {Ns, maps:get(anchor, Prepared)},
    DecisionRef = ref(maps:get(origin, Prepared), 8, 84),
    {ok, FinalizeRecord} =
        quod_dtx:new_finalize(
          maps:get(group_id, Prepared), DecisionRef, commit,
          maps:get(prepare_ref, Prepared), 2),
    {ok, FinalizeControl} =
        quod_dtx:sign_control(
          Binding, FinalizeRecord, maps:get(admission, Prepared),
          2, 2, maps:get(signer, Prepared)),
    {ok, FinalizeBlob} = quod_dtx:encode_control(FinalizeControl),
    Entry = control_entry(
              Ns, maps:get(anchor, Prepared), maps:get(pub, Prepared),
              maps:get(signer, Prepared), 3, FinalizeBlob),
    {ok, FinalizeRef} =
        quod_dtx:certified_entry_ref(Binding, Entry, FinalizeControl),
    Prepared#{chain := maps:get(chain, Prepared) ++ [Entry],
              finalize_ref => FinalizeRef}.

fixture_base(Ns) ->
    fixture_base(Ns, []).

fixture_base(Ns, InitialTerms) ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub,
               key => quod_identity:key_term({Pub, Seed})},
    Genesis = genesis(Ns, Pub, InitialTerms),
    Anchor = entry_hash(Genesis),
    Binding = {Ns, Anchor},
    {ok, [_], Projection1} =
        quod_catchup:verify_forward(
          Ns, Anchor, quod_simplex:history_projection(Binding),
          1, [Genesis]),
    ?assertEqual([Pub], quod_simplex:history_committee(Projection1)),
    Admission = crypto:hash(
                  sha256,
                  term_to_binary(
                    {quod_validator_admission, 1, Ns, 1, Anchor, Pub},
                    [deterministic])),
    #{pub => Pub, signer => Signer, genesis => Genesis,
      anchor => Anchor, admission => Admission}.

control_entry(Ns, Anchor, Pub, Signer, Slot, ControlBlob) ->
    Data = {batch, [{dtx, ControlBlob}]},
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, Data, 0),
    BlockHash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    #share{sig = Signature} = quod_simplex:make_share(
                                Domain, commit, Slot, BlockHash, Signer),
    Cert = #cert{kind = commit, slot = Slot, block_hash = BlockHash,
                 sigs = [{Pub, Signature}]},
    quod_ledger:entry(Block, Cert).

content_entry(Ns, Anchor, Pub, Signer, Slot, Transactions) ->
    Data = {batch, Transactions},
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, Data, 0),
    BlockHash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    #share{sig = Signature} = quod_simplex:make_share(
                                Domain, commit, Slot, BlockHash, Signer),
    Cert = #cert{kind = commit, slot = Slot, block_hash = BlockHash,
                 sigs = [{Pub, Signature}]},
    quod_ledger:entry(Block, Cert).

committee_content_entry(Ns, Anchor, Signers, Slot, Transactions) ->
    Data = {batch, Transactions},
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, Data, 0),
    BlockHash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Signatures =
        [begin
             #share{sig = Signature} = quod_simplex:make_share(
                                         Domain, commit, Slot,
                                         BlockHash, Signer),
             {Pub, Signature}
         end || {Pub, Signer} <- Signers],
    Cert = #cert{kind = commit, slot = Slot, block_hash = BlockHash,
                 sigs = Signatures},
    quod_ledger:entry(Block, Cert).

genesis(Ns, Pub, InitialTerms) ->
    Nonce = key(44),
    Tx = quod_simplex:test_genesis_tx(
           #{node_id => Pub, mode => create, committee => [],
             node_addr => {"127.0.0.1", 19000},
             genesis_diff => quod_prolog:terms_to_diff(InitialTerms)},
           Ns, Pub, Nonce),
    {ok, Entry} = quod_ledger:new_entry(1, {batch, [Tx]}, 0, none),
    Entry.

entry_hash(Entry) ->
    {ok, Block} = quod_ledger:block_from_entry(Entry),
    quod_simplex:block_hash(Block).

entry_index(Entry) -> (quod_ledger:entry_view(Entry))#entry.index.

without_entry_cert(Entry) ->
    {ok, Block} = quod_ledger:block_from_entry(Entry),
    quod_ledger:entry(Block, none).

entry_at(Entry, Index) ->
    #entry{data = Data, timestamp = Timestamp, cert = Cert} = quod_ledger:entry_view(Entry),
    {ok, Changed} = quod_ledger:new_entry(Index, Data, Timestamp, Cert),
    Changed.

chain_fetch(Ns, Chain) ->
    Height = length(Chain),
    fun(_Peer, _Endpoint, RequestedNs, From, To) when RequestedNs =:= Ns ->
            Page = [Entry || Entry <- Chain, I <- [entry_index(Entry)],
                             I >= From, I =< To],
            {ok, Page, Height};
       (_Peer, _Endpoint, _RequestedNs, _From, _To) ->
            {error, wrong_namespace}
    end.

peer_chain_fetch(Ns, Chain, Peers) ->
    Base = chain_fetch(Ns, Chain),
    fun(Peer, Endpoint, RequestedNs, From, To) ->
            case lists:member(Peer, Peers) of
                true -> Base(Peer, Endpoint, RequestedNs, From, To);
                false -> {error, wrong_peer}
            end
    end.

page_reply(RequestedNs, Ns, Chain, From, To, Height)
  when RequestedNs =:= Ns ->
    {ok, [Entry || Entry <- Chain, Index <- [entry_index(Entry)],
                   Index >= From, Index =< To], Height};
page_reply(_RequestedNs, _Ns, _Chain, _From, _To, _Height) ->
    {error, wrong_namespace}.

durable_goal(Goal) ->
    {ok, Blob} = quod_durable_term:encode_goal(Goal),
    Blob.

durable_result() ->
    {ok, Blob} = quod_durable_term:encode_result(#{}),
    Blob.

flush_fetches() ->
    receive
        {current_fetch_from, _From} -> flush_fetches()
    after 0 ->
        ok
    end.

collect_fetches(Acc) ->
    receive
        {current_fetch_from, From} -> collect_fetches([From | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

collect_identity_current_fetches(Acc) ->
    receive
        {identity_current_fetch, From} ->
            collect_identity_current_fetches([From | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

collect_committee_move_fetches(Acc) ->
    receive
        {committee_move_fetch, Peer, From} ->
            collect_committee_move_fetches([{Peer, From} | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

flush_resident_current_fetches() ->
    receive
        {resident_current_fetch, _From} -> flush_resident_current_fetches()
    after 0 ->
        ok
    end.

collect_resident_current_fetches(Acc) ->
    receive
        {resident_current_fetch, From} ->
            collect_resident_current_fetches([From | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

flush_resident_current_reference_fetches() ->
    receive
        {resident_current_reference_fetch, _From} ->
            flush_resident_current_reference_fetches()
    after 0 ->
        ok
    end.

collect_resident_current_reference_fetches(Acc) ->
    receive
        {resident_current_reference_fetch, From} ->
            collect_resident_current_reference_fetches([From | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

flush_resident_mismatch_fetches() ->
    receive
        {resident_mismatch_fetch, _From} -> flush_resident_mismatch_fetches()
    after 0 ->
        ok
    end.

collect_resident_mismatch_fetches(Acc) ->
    receive
        {resident_mismatch_fetch, From} ->
            collect_resident_mismatch_fetches([From | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

collect_bootstrap_route_fetches(Tag, Acc) ->
    receive
        {bootstrap_route_fetch, Tag, Peer, From} ->
            collect_bootstrap_route_fetches(Tag, [{Peer, From} | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

collect_long_current_fetches(Acc) ->
    receive
        {long_current_fetch, From} ->
            collect_long_current_fetches([From | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

phase_session_files(Dir, Identity) ->
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    CacheDir = quod_ledger_store:ns_dir(Dir, CacheNs),
    {ok, Names} = file:list_dir(CacheDir),
    lists:sort(
      [Name || Name <- Names,
               lists:prefix("dtx-phases.", Name),
               lists:suffix(".dets", Name)]).

cache_checkpoint(Dir, Identity = {Ns, Anchor}) ->
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    Path = filename:join(
             quod_ledger_store:ns_dir(Dir, CacheNs), "checkpoint.term"),
    {ok, Blob} = file:read_file(Path),
    {quod_foreign_log_checkpoint, _Version, Ns, Anchor,
     Height, _Bytes, Projection} = binary_to_term(Blob, [safe]),
    {Height, Projection}.

with_foreign_history_metrics(Fun) ->
    {ok, _} = application:ensure_all_started(prometheus),
    case whereis(quod_metrics) of
        undefined ->
            Placeholder = spawn(fun metrics_placeholder/0),
            true = register(quod_metrics, Placeholder),
            try
                ok = quod_metrics:declare(<<"kp_foreign_log_test">>),
                Fun()
            after
                case whereis(quod_metrics) of
                    Placeholder -> true = unregister(quod_metrics);
                    _ -> ok
                end,
                Placeholder ! stop
            end;
        _Existing ->
            Fun()
    end.

metrics_placeholder() ->
    receive stop -> ok end.

foreign_stage_samples(Stages) ->
    maps:from_list(
      [{Stage, foreign_stage_sample(Stage)} || Stage <- Stages]).

foreign_stage_deltas(Before, After) ->
    maps:map(
      fun(Stage, {CountAfter, SumAfter}) ->
          {CountBefore, SumBefore} = maps:get(Stage, Before),
          {CountAfter - CountBefore, SumAfter - SumBefore}
      end, After).

foreign_stage_sample(Stage) ->
    Labels = [atom_to_binary(Stage, utf8), <<"ok">>],
    case prometheus_histogram:value(
           quod_foreign_history_stage_seconds, Labels) of
        undefined -> {0, 0.0};
        {Buckets, Sum} -> {lists:sum(Buckets), Sum}
    end.

current_request(Routes, Identity, Contact, TimeoutMs) ->
    owner_request({current, Routes, Identity, Contact, TimeoutMs}).

owner_request(Request) ->
    Timeout = element(tuple_size(Request), Request),
    Deadline = case Timeout of infinity -> infinity;
                              _ -> quod_time:mono_ms() + Timeout end,
    {verification, Deadline, undefined, erlang:monotonic_time(), Request}.

start_owner(Dir, Fetch) ->
    start_owner_opts(Dir, Fetch, #{}).

await_history_ready(Identity, Height) ->
    await_history_ready(Identity, Height, quod_time:mono_ms() + 3000).

await_history_ready(Identity, Height, Deadline) ->
    Row = maps:get(Identity, quod_foreign_log:test_lifecycle_state()),
    case Row of
        #{active := none, waiting := [], resident_verified := true, height := Height} -> ok;
        _ ->
            %% Bounded test-only observation of installed owner state, not a
            %% sleep or an assumption about cross-recipient message delivery.
            ?assert(quod_time:mono_ms() < Deadline),
            await_history_ready(Identity, Height, Deadline)
    end.

start_owner_opts(Dir, Fetch, Extra) ->
    {ok, _} = application:ensure_all_started(gproc),
    case quod_reg:where({foreign_log, node}) of
        Existing when is_pid(Existing) -> stop_owner(Existing);
        undefined -> ok
    end,
    {ok, Pid} = quod_foreign_log:start_link(
                  maps:merge(
                    #{cache_dir => Dir, fetch_fun => Fetch,
                      page_timeout_ms => 1000}, Extra)),
    Pid.

receive_follow(FollowRef, Identity) ->
    receive
        {quod_foreign_follow, FollowRef, NoticeRef, Identity, Notice} ->
            {NoticeRef, Notice}
    after 3000 ->
        error({missing_follow_notice, FollowRef, Identity})
    end.

receive_follow_resnapshot(FollowRef, Identity) ->
    Notice = receive_follow(FollowRef, Identity),
    case element(2, Notice) of
        {resnapshot, _, _, _} ->
            Notice;
        {building, _} ->
            ok = quod_foreign_log:ack(
                   FollowRef, element(1, Notice)),
            receive_follow_resnapshot(FollowRef, Identity);
        Unexpected ->
            error({unexpected_follow_notice, Unexpected})
    end.

fake_feed_link(Owner) ->
    receive
        {send_ordered, Payload} ->
            Owner ! {fake_feed_link_send, self(), Payload},
            fake_feed_link(Owner);
        close ->
            Owner ! {fake_feed_link_closed, self()}
    end.

receive_fake_feed_send(Link, Timeout) ->
    receive
        {fake_feed_link_send, Link, Payload} -> Payload
    after Timeout ->
        false
    end.

wait_follow_count(Expected, Left) when Left =< 0 ->
    case maps:get(follow_consumers, quod_foreign_log:stats()) of
        Expected -> ok;
        Actual -> error({follow_count_timeout, Expected, Actual})
    end;
wait_follow_count(Expected, Left) ->
    case maps:get(follow_consumers, quod_foreign_log:stats()) of
        Expected -> ok;
        _ -> receive after 10 -> ok end,
             wait_follow_count(Expected, Left - 10)
    end.

wait_foreign_work(ExpectedPending, ExpectedQueued, Left) when Left =< 0 ->
    Stats = quod_foreign_log:stats(),
    error({foreign_work_timeout, ExpectedPending, ExpectedQueued, Stats});
wait_foreign_work(ExpectedPending, ExpectedQueued, Left) ->
    Stats = quod_foreign_log:stats(),
    case {maps:get(pending, Stats), maps:get(queued, Stats)} of
        {ExpectedPending, ExpectedQueued} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_foreign_work(ExpectedPending, ExpectedQueued, Left - 10)
    end.

stop_owner(Pid) when is_pid(Pid) ->
    unlink(Pid),
    try gen_server:stop(Pid) catch exit:_ -> ok end.

stop_route_recovery_owners() ->
    _ = [catch gen_server:stop(Pid)
         || Key <- [{directory, control}, {directory, node}],
            Pid <- [quod_reg:where(Key)], is_pid(Pid)],
    ok.

wait_route_demand(Identity, 0) ->
    error({route_demand_timeout, Identity,
           quod_directory_control:test_control_state()});
wait_route_demand(Identity, Left) ->
    State = quod_directory_control:test_control_state(),
    case lists:member(Identity, maps:get(route_demands, State)) of
        true -> ok;
        false ->
            receive after 5 -> ok end,
            wait_route_demand(Identity, Left - 1)
    end.

restore_application_env(Key, {ok, Value}) ->
    application:set_env(quod, Key, Value);
restore_application_env(Key, undefined) ->
    application:unset_env(quod, Key).

control(Kind, Target, Record) ->
    {quod_dtx_control, 2, Kind, Target, Record,
     key(240), key(241), 1, 0, <<0:512>>}.

ref({Ns, Anchor}, Slot, Seed) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, key(Seed), key(Seed + 1),
                  <<"foreign-finality">>),
    Ref.

ref_with_digest({Ns, Anchor}, Slot, Seed, Digest) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, key(Seed), Digest,
                  <<"foreign-finality">>),
    Ref.

largest_payload(Ns) ->
    largest_payload(Ns, 0, ?MAX_BLOCK_BYTES).

largest_payload(Ns, Low, High) when Low + 1 >= High ->
    payload(Ns, Low);
largest_payload(Ns, Low, High) ->
    Mid = (Low + High) div 2,
    Candidate = payload(Ns, Mid),
    case quod_ledger:encoded_payload_size(Candidate) of
        {ok, Size} when Size =< ?MAX_BLOCK_BYTES ->
            largest_payload(Ns, Mid, High);
        _ ->
            largest_payload(Ns, Low, Mid)
    end.

payload(Ns, Bytes) ->
    Target = {Ns, key(251)},
    Seed = key(254),
    {Author, Seed} = crypto:generate_key(eddsa, ed25519, Seed),
    Signer = #{pubkey => Author,
               key => quod_identity:key_term({Author, Seed})},
    Transaction0 = #transaction{
                     tx_id = <<>>, origin = Target,
                     proof_id = key(252), plan_digest = key(253),
                     goal = <<>>, result = <<>>,
                     diff = [{assert,
                              {{large_foreign_value,
                                binary:copy(<<0>>, Bytes)}, true}}],
                     read_check = #{}, author = Author,
                     author_seq = 1, submitted_at = 1,
                     sig = none},
    Transaction = quod_transaction:bind_id(Target, Transaction0),
    {ok, Signed} = quod_transaction:sign(
                     {Ns, element(2, Target), Author}, Transaction, Signer),
    {batch, [Signed]}.

unique_ns() ->
    <<"foreign:test:",
      (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.

temp_dir(Suffix) ->
    filename:join(
      "/tmp",
      "quod_foreign_log_" ++ Suffix ++ "_" ++
          os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive, monotonic]))).

key(N) -> crypto:hash(sha256, term_to_binary({foreign_key, N})).

route_candidates(Routes) ->
    [{Peer, [Endpoint]} || {Peer, Endpoint} <- Routes].
