-module(quod_ask_router_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

-define(TIMEOUT, 1000).

pending_precedes_send_and_scope_is_reused_test() ->
    with_router(
      fun(Router, TestPid, OriginKey, TargetKey) ->
          Binding = binding(OriginKey, TargetKey, 1, <<"quod:target">>, 11),
          OpenRef = pending_ref(
                      quod_ask_router:ensure_scope(
                        Router, endpoint(), Binding, 30000), Router),
          ?assertEqual(1, maps:get(scopes, quod_ask_router:test_stats(Router))),
          {OpenRef, Channel} = receive_open(TargetKey),
          ?assertEqual(quod_scope_wire:request_channel(<<"quod:target">>), Channel),
          RequestLink = fake_link(TestPid, request),
          Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
          OpenCommand = receive_command(request),
          {scope_command, Binding, 1, RequestId, 30000, scope_open} = OpenCommand,
          ReturnLink = fake_link(TestPid, return),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     1, RequestId, 1, 0, false, {scope_opened, 42}),
          Handle = receive
                       {quod_scope_open, OpenRef,
                        {ok, H, 42, 0, false}} -> H
                   after ?TIMEOUT -> error(open_timeout)
                   end,
          ReuseBinding = setelement(
                           3, setelement(5, Binding, id(99)), key(99)),
          ?assertEqual({ok, Handle},
                       quod_ask_router:ensure_scope(
                         Router, {"different.invalid", 9999},
                         ReuseBinding, 1)),
          receive {open_requested, _, _, _, _} -> ?assert(false)
          after 20 -> ok
          end,
          ok = quod_ask_router:unregister(Handle),
          await_scope_count(Router, 0),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

command_correlation_generation_and_no_reply_commands_test() ->
    with_open_scope(
      fun(Router, TestPid, TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          InvocationId = id(31),
          Selection = {tx_selection, none, []},
          {ok, RequestId} = quod_ask_router:command(
                              Handle, 20000,
                              {invoke_open, InvocationId, Selection,
                               [target_identity(Binding)], <<>>}),
          {scope_command, Binding, 2, RequestId, 20000,
           {invoke_open, InvocationId, Selection, _, <<>>}} =
              receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     2, RequestId, 2, 0, false,
                     {invocation_opened, InvocationId}),
          receive
              {quod_scope_event, Handle, RequestId, 0, false,
               {invocation_opened, InvocationId}} -> ok
          after ?TIMEOUT -> error(invocation_timeout)
          end,

          %% Controller replies have no acknowledgement in the fixed codec.
          %% More than the pending-reply bound must therefore remain sendable.
          lists:foreach(
            fun(N) ->
                {sent, _} = quod_ask_router:command(
                              Handle, 19000,
                              {nested_error, id(N + 100),
                               {protocol_error, request_binding}}),
                _ = receive_command(request)
            end,
            lists:seq(1, ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE + 4)),

          BatchIds = [id(77)],
          {ok, BatchRequest} = quod_ask_router:command(
                                 Handle, 18000, {batch_restore, BatchIds}),
          {scope_command, Binding, BatchCommandSeq, BatchRequest, 18000,
           {batch_restore, BatchIds}} = receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     3, BatchRequest, BatchCommandSeq, 1, true,
                     {batch_restored, BatchIds}),
          receive
              {quod_scope_event, Handle, BatchRequest, 1, true,
               {batch_restored, BatchIds}} -> ok
          after ?TIMEOUT -> error(batch_timeout)
          end,

          %% Same generation with a different dirty value is inconsistent and
          %% poisons every scope owned by this proof worker.
          {ok, BadRequest} = quod_ask_router:command(
                               Handle, 17000, {batch_release, BatchIds}),
          {scope_command, Binding, BadCommandSeq, BadRequest, 17000,
           {batch_release, BatchIds}} = receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     4, BadRequest, BadCommandSeq, 1, false,
                     {batch_released, BatchIds}),
          receive
              {quod_scope_down, Handle, {protocol_error, generation}} -> ok
          after ?TIMEOUT -> error(protocol_error_timeout)
          end,
          await_scope_count(Router, 0),
          stop_link(RequestLink),
          stop_link(ReturnLink),
          flush_link_frames(TestPid)
      end).

seal_attest_and_submit_are_reply_correlated_test() ->
    with_open_scope(
      fun(Router, _TestPid, TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          {ok, SealRequest} = quod_ask_router:command(
                                Handle, 30000, scope_seal),
          {scope_command, Binding, SealSeq, SealRequest, 30000, scope_seal} =
              receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     2, SealRequest, SealSeq, 0, false, plan_not_material),
          receive
              {quod_scope_event, Handle, SealRequest, 0, false,
               plan_not_material} -> ok
          after ?TIMEOUT -> error(seal_event_timeout)
          end,

          ManifestBlob = <<"bounded manifest">>,
          {ok, AttestRequest} = quod_ask_router:command(
                                  Handle, 30000,
                                  {scope_attest, ManifestBlob}),
          {scope_command, Binding, AttestSeq, AttestRequest, 30000,
           {scope_attest, ManifestBlob}} = receive_command(request),
          AttestationBlob = <<"bounded attestation">>,
          send_event(Router, TargetKey, ReturnLink, Binding,
                     3, AttestRequest, AttestSeq, 0, false,
                     {plan_attested, AttestationBlob}),
          receive
              {quod_scope_event, Handle, AttestRequest, 0, false,
               {plan_attested, AttestationBlob}} -> ok
          after ?TIMEOUT -> error(attest_event_timeout)
          end,

          Submit = {submit_plan, <<"plan">>, <<"goal">>, <<"result">>, []},
          {ok, SubmitRequest} = quod_ask_router:command(
                                  Handle, 30000, Submit),
          {scope_command, Binding, SubmitSeq, SubmitRequest, 30000, Submit} =
              receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     4, SubmitRequest, SubmitSeq, 0, false,
                     {plan_submitted, {rejected, bad_plan}}),
          receive
              {quod_scope_event, Handle, SubmitRequest, 0, false,
               {plan_submitted, {rejected, bad_plan}}} -> ok
          after ?TIMEOUT -> error(submit_event_timeout)
          end,

          ok = quod_ask_router:unregister(Handle),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

cancelled_command_discards_late_event_test() ->
    with_open_scope(
      fun(Router, _TestPid, TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          BatchIds = [id(76)],
          {ok, RequestId} = quod_ask_router:command(
                              Handle, 1, {batch_restore, BatchIds}),
          {scope_command, Binding, CommandSeq, RequestId, 1,
           {batch_restore, BatchIds}} = receive_command(request),
          ok = quod_ask_router:cancel(Handle, RequestId),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     2, RequestId, CommandSeq, 0, false,
                     {batch_restored, BatchIds}),
          receive
              {quod_scope_event, Handle, RequestId, _, _, _} ->
                  error(cancelled_event_delivered);
              {quod_scope_down, Handle, Reason} ->
                  error({cancelled_event_poisoned_scope, Reason})
          after 20 ->
              ok
          end,

          {ok, NextRequestId} = quod_ask_router:command(
                                  Handle, 1000,
                                  {batch_release, BatchIds}),
          {scope_command, Binding, NextCommandSeq, NextRequestId, 1000,
           {batch_release, BatchIds}} = receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     3, NextRequestId, NextCommandSeq, 0, false,
                     {batch_released, BatchIds}),
          receive
              {quod_scope_event, Handle, NextRequestId, 0, false,
               {batch_released, BatchIds}} -> ok
          after ?TIMEOUT -> error(next_command_timeout)
          end,
          ok = quod_ask_router:unregister(Handle),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

scope_close_bypasses_full_pending_limit_test() ->
    with_open_scope(
      fun(Router, _TestPid, _TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          lists:foreach(
            fun(N) ->
                {ok, RequestId} = quod_ask_router:command(
                                    Handle, 1000,
                                    {invoke_next, id(N), 1}),
                {scope_command, Binding, _CommandSeq, RequestId, 1000,
                 {invoke_next, _, 1}} = receive_command(request)
            end,
            lists:seq(1, ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE)),
          ?assertEqual(
             {error, pending_request_limit},
             quod_ask_router:command(
               Handle, 1000, {invoke_next, id(100), 1})),

          ok = quod_ask_router:close(Handle, 0),
          {scope_command, Binding, _CloseSeq, _CloseRequestId, 0,
           scope_close} = receive_command(request),
          await_scope_count(Router, 0),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

scope_close_terminal_event_is_optional_and_silent_test() ->
    with_open_scope(
      fun(Router, _TestPid, TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          {sent, RequestId} = quod_ask_router:command(
                                Handle, 0, scope_close),
          {scope_command, Binding, CommandSeq, RequestId, 0, scope_close} =
              receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     2, RequestId, CommandSeq, 0, false, scope_closed),
          await_scope_count(Router, 0),
          receive
              {quod_scope_event, Handle, RequestId, _, _, scope_closed} ->
                  error(unexpected_close_reply);
              {quod_scope_down, Handle, Reason} ->
                  error({close_poisoned_scope, Reason})
          after 20 ->
              ok
          end,
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

intermediary_nested_event_retains_invocation_correlation_test() ->
    with_open_scope(
      fun(Router, _TestPid, TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          InvocationId = id(40),
          {ok, RequestId} = quod_ask_router:command(
                              Handle, 20000,
                              {invoke_next, InvocationId, 1}),
          {scope_command, Binding, CommandSeq, RequestId, 20000,
           {invoke_next, InvocationId, 1}} = receive_command(request),
          ControllerId = id(41),
          {ok, GoalBlob} = quod_scope_wire:encode_payload(
                             goal, {child_goal, ok}),
          Nested = {nested_open, ControllerId, <<"quod:child">>,
                    [target_identity(Binding)], GoalBlob},
          send_event(Router, TargetKey, ReturnLink, Binding,
                     2, RequestId, CommandSeq, 0, false, Nested),
          receive
              {quod_scope_event, Handle, RequestId, 0, false, Nested} -> ok
          after ?TIMEOUT -> error(nested_event_timeout)
          end,
          {ok, AnswerBlob} = quod_scope_wire:encode_payload(
                               answer, {child_goal, ok}),
          Final = {solution, InvocationId, 1, AnswerBlob},
          send_event(Router, TargetKey, ReturnLink, Binding,
                     3, RequestId, CommandSeq, 0, false, Final),
          receive
              {quod_scope_event, Handle, RequestId, 0, false, Final} -> ok
          after ?TIMEOUT -> error(final_event_timeout)
          end,

          %% A late second terminal with a fresh event sequence still lacks a
          %% pending request and therefore poisons rather than redelivering.
          send_event(Router, TargetKey, ReturnLink, Binding,
                     4, RequestId, CommandSeq, 0, false, Final),
          receive
              {quod_scope_down, Handle,
               {protocol_error, request_binding}} -> ok
          after ?TIMEOUT -> error(late_terminal_timeout)
          end,
          await_scope_count(Router, 0),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

scope_error_namespace_is_bound_but_descendant_invocation_error_is_not_test() ->
    with_open_scope(
      fun(Router, _TestPid, TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          InvocationId = id(45),
          {ok, InvocationRequest} = quod_ask_router:command(
                                      Handle, 1000,
                                      {invoke_next, InvocationId, 1}),
          {scope_command, Binding, InvocationCommandSeq, InvocationRequest,
           1000, {invoke_next, InvocationId, 1}} = receive_command(request),
          DescendantError =
              {invocation_error, InvocationId, 1,
               {proof_limit_exceeded, <<"quod:descendant">>}},
          send_event(Router, TargetKey, ReturnLink, Binding,
                     2, InvocationRequest, InvocationCommandSeq,
                     0, false, DescendantError),
          receive
              {quod_scope_event, Handle, InvocationRequest,
               0, false, DescendantError} -> ok
          after ?TIMEOUT -> error(descendant_error_timeout)
          end,

          BatchId = id(46),
          {ok, ScopeRequest} = quod_ask_router:command(
                                 Handle, 1000,
                                 {batch_restore, [BatchId]}),
          {scope_command, Binding, ScopeCommandSeq, ScopeRequest,
           1000, {batch_restore, [BatchId]}} = receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     3, ScopeRequest, ScopeCommandSeq, 0, false,
                     {scope_error,
                      {proof_limit_exceeded, <<"quod:not-the-target">>}}),
          receive
              {quod_scope_down, Handle,
               {protocol_error, session_binding}} -> ok
          after ?TIMEOUT -> error(scope_error_binding_timeout)
          end,
          Stats = quod_ask_router:test_stats(Router),
          ?assertEqual(0, maps:get(scopes, Stats)),
          ?assertEqual(1, maps:get(retained_owners, Stats)),
          ?assertEqual(1, maps:get(entries, Stats)),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

exact_peer_return_link_and_router_generation_test() ->
    with_open_scope(
      fun(Router, _TestPid, TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          FakeHandle = setelement(3, Handle, id(240)),
          ?assertEqual({error, stale_router},
                       quod_ask_router:command(
                         FakeHandle, 1000, {batch_restore, []})),
          {ok, RequestId} = quod_ask_router:command(
                              Handle, 1000, {batch_restore, [id(50)]}),
          {scope_command, Binding, CommandSeq, RequestId, 1000,
           {batch_restore, [BatchId]}} = receive_command(request),
          WrongReturn = fake_link(self(), wrong_return),
          send_event(Router, TargetKey, WrongReturn, Binding,
                     2, RequestId, CommandSeq, 0, false,
                     {batch_restored, [BatchId]}),
          receive
              {quod_scope_down, Handle, {protocol_error, return_link}} -> ok
          after ?TIMEOUT -> error(return_link_timeout)
          end,
          await_scope_count(Router, 0),
          stop_link(RequestLink),
          stop_link(ReturnLink),
          stop_link(WrongReturn)
      end).

legacy_frame_is_rejected_without_touching_scope_test() ->
    with_open_scope(
      fun(Router, _TestPid, TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          Legacy = term_to_binary(
                     {quod_ask_answer, id(1), 1, complete}, [deterministic]),
          Router ! {quod_message, {TargetKey, ReturnLink},
                    quod_scope_wire:return_channel(origin_key(Binding)), Legacy},
          timer:sleep(10),
          ?assertEqual(1, maps:get(scopes, quod_ask_router:test_stats(Router))),
          {ok, RequestId} = quod_ask_router:command(
                              Handle, 1000, {batch_restore, [id(60)]}),
          {scope_command, Binding, CommandSeq, RequestId, 1000,
           {batch_restore, [BatchId]}} = receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     2, RequestId, CommandSeq, 0, false,
                     {batch_restored, [BatchId]}),
          receive
              {quod_scope_event, Handle, RequestId, 0, false,
               {batch_restored, [BatchId]}} -> ok
          after ?TIMEOUT -> error(post_legacy_timeout)
          end,
          ok = quod_ask_router:unregister(Handle),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

identity_probe_success_is_one_shot_and_creates_no_scope_test() ->
    with_identity_router(
      fun(Router, TestPid, OriginKey, TargetKey) ->
          Ns = <<"quod:seeded">>,
          OpenRef = pending_ref(
                      quod_ask_router:identify(
                        Router, endpoint(), Ns, 1000), Router),
          Stats0 = quod_ask_router:test_stats(Router),
          ?assertEqual(0, maps:get(scopes, Stats0)),
          ?assertEqual(1, maps:get(probes, Stats0)),
          {OpenRef, Channel} = receive_identity_open(),
          RequestLink = fake_link(TestPid, identity_request),
          Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
          {scope_identity_probe, RequestId, OriginKey, Ns} =
              receive_identity_probe(identity_request),
          ReturnLink = fake_link(TestPid, identity_return),
          TargetIdentity = {Ns, key(88)},
          send_identity_response(
            Router, TargetKey, ReturnLink, RequestId,
            TargetKey, TargetIdentity, validator),
          receive
              {quod_scope_identity, OpenRef,
               {ok, TargetKey, TargetIdentity, validator}} -> ok
          after ?TIMEOUT -> error(identity_response_timeout)
          end,
          ?assertEqual(0, maps:get(probes, quod_ask_router:test_stats(Router))),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

identity_probe_rejects_declared_key_mismatch_test() ->
    with_identity_router(
      fun(Router, TestPid, _OriginKey, TargetKey) ->
          Ns = <<"quod:seeded">>,
          OpenRef = pending_ref(
                      quod_ask_router:identify(
                        Router, endpoint(), Ns, 1000), Router),
          {OpenRef, Channel} = receive_identity_open(),
          RequestLink = fake_link(TestPid, identity_request),
          Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
          {scope_identity_probe, RequestId, _, Ns} =
              receive_identity_probe(identity_request),
          ReturnLink = fake_link(TestPid, identity_return),
          send_identity_response(
            Router, TargetKey, ReturnLink, RequestId,
            key(99), {Ns, key(88)}, observer),
          receive
              {quod_scope_identity, OpenRef,
               {error, identity_binding}} -> ok
          after ?TIMEOUT -> error(identity_mismatch_timeout)
          end,
          ?assertEqual(0, maps:get(probes, quod_ask_router:test_stats(Router))),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

identity_probe_owner_and_request_link_cleanup_test() ->
    with_identity_router(
      fun(Router, TestPid, _OriginKey, TargetKey) ->
          Owner = owner_process(Router, TestPid),
          Ns = <<"quod:seeded">>,
          Owner ! {identify, endpoint(), Ns, 1000},
          {OpenRef, Channel} = receive_identity_open(),
          receive
              {owner_result, Owner, Pending} ->
                  OpenRef = pending_ref(Pending, Router)
          after ?TIMEOUT -> error(identity_owner_open_timeout)
          end,
          RequestLink = fake_link(TestPid, identity_request),
          Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
          _ = receive_identity_probe(identity_request),
          exit(RequestLink, kill),
          receive
              {owner_notice, Owner,
               {quod_scope_identity, OpenRef,
                {error, {request_link_down, killed}}}} -> ok
          after ?TIMEOUT -> error(identity_link_cleanup_timeout)
          end,
          await_probe_count(Router, 0),

          Owner ! {identify, endpoint(), <<"quod:second">>, 1000},
          {OpenRef2, _} = receive_identity_open(),
          receive
              {owner_result, Owner, Pending2} ->
                  OpenRef2 = pending_ref(Pending2, Router)
          after ?TIMEOUT -> error(identity_second_open_timeout)
          end,
          exit(Owner, kill),
          await_probe_count(Router, 0)
      end).

identity_probes_share_owner_admission_bound_test() ->
    with_identity_router(
      fun(Router, _TestPid, _OriginKey, _TargetKey) ->
          Results = [quod_ask_router:identify(
                       Router, endpoint(), namespace(N), 30000)
                     || N <- lists:seq(
                                  1, ?QUOD_MAX_ROUTER_SCOPES_PER_OWNER)],
          ?assert(lists:all(fun(Result) -> is_pending(Result, Router) end,
                           Results)),
          ?assertEqual(
             {error, owner_scope_limit},
             quod_ask_router:identify(
               Router, endpoint(), <<"quod:probe-overflow">>, 30000)),
          Stats = quod_ask_router:test_stats(Router),
          ?assertEqual(?QUOD_MAX_ROUTER_SCOPES_PER_OWNER,
                       maps:get(probes, Stats)),
          ?assertEqual(0, maps:get(scopes, Stats))
      end).

identity_probe_budget_is_a_cleanup_deadline_test() ->
    with_identity_router(
      fun(Router, _TestPid, _OriginKey, _TargetKey) ->
          OpenRef = pending_ref(
                      quod_ask_router:identify(
                        Router, endpoint(), <<"quod:timeout">>, 5), Router),
          receive
              {quod_scope_identity, OpenRef, {error, timeout}} -> ok
          after ?TIMEOUT -> error(identity_timeout_missing)
          end,
          ?assertEqual(0, maps:get(probes, quod_ask_router:test_stats(Router)))
      end).

owner_and_peer_bounds_reject_before_open_test() ->
    with_router(
      fun(Router, _TestPid, OriginKey, TargetKey) ->
          Results = [quod_ask_router:ensure_scope(
                       Router, endpoint(),
                       setelement(
                         4,
                         binding(OriginKey, TargetKey, N,
                                 namespace(N), N),
                         proof_id(1)), 1000)
                     || N <- lists:seq(1, ?QUOD_MAX_ROUTER_SCOPES_PER_OWNER)],
          ?assert(lists:all(fun(Result) -> is_pending(Result, Router) end,
                           Results)),
          ?assertEqual(
             {error, owner_scope_limit},
             quod_ask_router:ensure_scope(
               Router, endpoint(),
               setelement(
                 4,
                 binding(OriginKey, key(2), 100,
                         <<"quod:overflow">>, 100),
                 proof_id(1)),
               1000)),
          ?assertEqual(?QUOD_MAX_ROUTER_SCOPES_PER_OWNER,
                       maps:get(scopes, quod_ask_router:test_stats(Router)))
      end),

    with_router(
      fun(Router, _TestPid, OriginKey, TargetKey) ->
          Owners = [owner_process(Router, self()) || _ <- lists:seq(1, 3)],
          [O1, O2, O3] = Owners,
          lists:foreach(
            fun({Owner, Offset}) ->
                lists:foreach(
                  fun(N) ->
                      Owner ! {ensure, endpoint(),
                               setelement(
                                 4,
                                 binding(OriginKey, TargetKey, Offset + N,
                                         namespace(Offset + N), Offset + N),
                                 proof_id(Offset))},
                      receive
                          {owner_result, Owner, Pending} ->
                              ?assert(is_pending(Pending, Router))
                      after ?TIMEOUT -> error(peer_fill_timeout)
                      end
                  end,
                  lists:seq(1, 8))
            end, [{O1, 100}, {O2, 200}]),
          O3 ! {ensure, endpoint(),
                binding(OriginKey, TargetKey, 301,
                        <<"quod:peer-overflow">>, 301)},
          receive
              {owner_result, O3, {error, peer_scope_limit}} -> ok
          after ?TIMEOUT -> error(peer_limit_timeout)
          end,
          ?assertEqual(?QUOD_MAX_ROUTER_SCOPES_PER_PEER,
                       maps:get(TargetKey,
                                maps:get(peers,
                                         quod_ask_router:test_stats(Router)))),
          lists:foreach(fun(Pid) -> Pid ! stop end, Owners)
      end).

global_router_bound_rejects_before_extra_open_test_() ->
    {timeout, 10, fun global_router_bound_rejects_before_extra_open/0}.

global_router_bound_rejects_before_extra_open() ->
    drain_test_messages(),
    OriginKey = key(1),
    SilentOpen = fun(_NodeKey, _Endpoint, _Channel) -> make_ref() end,
    {ok, Router} = quod_ask_router:test_start_link(OriginKey, SilentOpen),
    unlink(Router),
    OwnerCount = ?QUOD_MAX_ROUTER_SCOPES div
                 ?QUOD_MAX_ROUTER_SCOPES_PER_OWNER,
    Owners =
        [begin
             PeerKey = key(1000 + ((OwnerN - 1) div 2)),
             Bindings =
                 [begin
                      N = OwnerN * 1000 + Slot,
                      setelement(
                        4,
                        binding(OriginKey, PeerKey, N, namespace(N), N),
                        proof_id(OwnerN))
                  end || Slot <- lists:seq(
                                   1, ?QUOD_MAX_ROUTER_SCOPES_PER_OWNER)],
             batch_owner(Router, self(), Bindings)
         end || OwnerN <- lists:seq(1, OwnerCount)],
    try
        lists:foreach(
          fun(Owner) ->
              receive
                  {batch_owner_result, Owner, Results} ->
                      ?assert(lists:all(
                                fun(Result) -> is_pending(Result, Router) end,
                                Results))
              after 5000 -> error(global_fill_timeout)
              end
          end, Owners),
        ?assertEqual(?QUOD_MAX_ROUTER_SCOPES,
                     maps:get(scopes, quod_ask_router:test_stats(Router))),
        FilledStats = quod_ask_router:test_stats(Router),
        ?assertEqual(0, maps:get(retained_owners, FilledStats)),
        ?assertEqual(?QUOD_MAX_ROUTER_SCOPES,
                     maps:get(entries, FilledStats)),

        %% Replace one owner's eight live scopes by its one sealed owner
        %% tombstone, then refill the seven released entries. The mixed state
        %% must hit the same global ceiling without scanning the owner map.
        TombstoneOwner = hd(Owners),
        TombstoneOwner ! {finalize, proof_id(1)},
        receive
            {batch_owner_finalized, TombstoneOwner,
             {error, {protocol_error, unfinished_scope}}} -> ok
        after ?TIMEOUT -> error(tombstone_finalize_timeout)
        end,
        TombstoneStats = quod_ask_router:test_stats(Router),
        ?assertEqual(?QUOD_MAX_ROUTER_SCOPES - 8,
                     maps:get(scopes, TombstoneStats)),
        ?assertEqual(1, maps:get(retained_owners, TombstoneStats)),
        ?assertEqual(?QUOD_MAX_ROUTER_SCOPES - 7,
                     maps:get(entries, TombstoneStats)),

        Overflow = owner_process(Router, self()),
        lists:foreach(
          fun(N) ->
              Overflow !
                  {ensure, endpoint(),
                   setelement(
                     4,
                     binding(OriginKey, key(8888), 800000 + N,
                             namespace(800000 + N), 800000 + N),
                     proof_id(8000))},
              receive
                  {owner_result, Overflow, Pending} ->
                      ?assert(is_pending(Pending, Router))
              after ?TIMEOUT -> error(tombstone_refill_timeout)
              end
          end, lists:seq(1, 7)),
        RefilledStats = quod_ask_router:test_stats(Router),
        ?assertEqual(1, maps:get(retained_owners, RefilledStats)),
        ?assertEqual(?QUOD_MAX_ROUTER_SCOPES,
                     maps:get(entries, RefilledStats)),

        Overflow ! {ensure, endpoint(),
                    setelement(
                      4,
                      binding(OriginKey, key(8888), 999999,
                              <<"quod:global-overflow">>, 999999),
                      proof_id(8000))},
        receive
            {owner_result, Overflow, {error, router_full}} -> ok
        after ?TIMEOUT -> error(global_limit_timeout)
        end,

        %% Reaping the exact sealed owner frees one entry, which a new live
        %% scope can reuse immediately without disturbing the other 511.
        TombstoneOwner ! stop,
        await_retained_owner_count(Router, 0),
        Overflow ! {ensure, endpoint(),
                    setelement(
                      4,
                      binding(OriginKey, key(8888), 999999,
                              <<"quod:global-overflow">>, 999999),
                      proof_id(8000))},
        receive
            {owner_result, Overflow, Pending} ->
                ?assert(is_pending(Pending, Router))
        after ?TIMEOUT -> error(reaped_tombstone_not_reused)
        end,
        ReusedStats = quod_ask_router:test_stats(Router),
        ?assertEqual(?QUOD_MAX_ROUTER_SCOPES,
                     maps:get(entries, ReusedStats)),
        Overflow ! stop
    after
        lists:foreach(fun(Pid) -> Pid ! stop end, Owners),
        exit(Router, kill),
        flush_test_messages()
    end.

owner_death_queues_close_and_reaps_exact_entry_test() ->
    with_router(
      fun(Router, TestPid, OriginKey, TargetKey) ->
          Owner = owner_process(Router, TestPid),
          Binding = binding(OriginKey, TargetKey, 1, <<"quod:owned">>, 44),
          Owner ! {ensure, endpoint(), Binding},
          {OpenRef, Channel} = receive_open(TargetKey),
          receive
              {owner_result, Owner, Pending} ->
                  OpenRef = pending_ref(Pending, Router)
          after ?TIMEOUT -> error(owner_open_timeout)
          end,
          RequestLink = fake_link(TestPid, request),
          Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
          {scope_command, Binding, 1, RequestId, _, scope_open} =
              receive_command(request),
          ReturnLink = fake_link(TestPid, return),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     1, RequestId, 1, 0, false, {scope_opened, 1}),
          receive {owner_notice, Owner, {quod_scope_open, OpenRef, {ok, _, 1, 0, false}}} -> ok
          after ?TIMEOUT -> error(owner_notice_timeout)
          end,
          exit(Owner, kill),
          {scope_command, Binding, 2, _CloseId, 0, scope_close} =
              receive_command(request),
          await_scope_count(Router, 0),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

owner_death_after_open_send_closes_still_pending_scope_test() ->
    with_router(
      fun(Router, TestPid, OriginKey, TargetKey) ->
          Owner = owner_process(Router, TestPid),
          Binding = binding(OriginKey, TargetKey, 1, <<"quod:pending">>, 45),
          Owner ! {ensure, endpoint(), Binding},
          {OpenRef, Channel} = receive_open(TargetKey),
          receive
              {owner_result, Owner, Pending} ->
                  OpenRef = pending_ref(Pending, Router)
          after ?TIMEOUT -> error(pending_owner_open_timeout)
          end,
          RequestLink = fake_link(TestPid, request),
          Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
          {scope_command, Binding, 1, _OpenRequestId, _, scope_open} =
              receive_command(request),
          exit(Owner, kill),
          {scope_command, Binding, 2, _CloseId, 0, scope_close} =
              receive_command(request),
          await_scope_count(Router, 0),
          stop_link(RequestLink)
      end).

finalize_retains_poison_without_owner_mailbox_polling_test() ->
    with_open_scope(
      fun(Router, _TestPid, TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          {ok, RequestId} = quod_ask_router:command(
                              Handle, 1000, {batch_restore, [id(70)]}),
          {scope_command, Binding, CommandSeq, RequestId, 1000,
           {batch_restore, [_]}} = receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     2, RequestId, CommandSeq, 0, true,
                     {batch_restored, [id(70)]}),
          %% The generation/dirty pair conflicts with the opened scope.  The
          %% synchronous fence must retain this poison even though its async
          %% notification remains unread in the proof owner's mailbox.
          Expected = {error, {protocol_error, generation}},
          ?assertEqual(Expected,
                       quod_ask_router:finalize(Router, proof_id(1))),
          ?assertEqual(Expected,
                       quod_ask_router:finalize(Router, proof_id(1))),
          receive
              {quod_scope_down, Handle, {protocol_error, generation}} -> ok
          after ?TIMEOUT -> error(missing_poison_notification)
          end,
          ?assertEqual(0, maps:get(scopes, quod_ask_router:test_stats(Router))),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

finalize_cleanly_detaches_scope_at_one_router_boundary_test() ->
    with_open_scope(
      fun(Router, _TestPid, _TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          ?assertEqual(ok, quod_ask_router:finalize(Router, proof_id(1))),
          {scope_command, Binding, 2, _CloseId, 0, scope_close} =
              receive_command(request),
          ?assertEqual(ok, quod_ask_router:finalize(Router, proof_id(1))),
          ?assertEqual({error, invalid_handle},
                       quod_ask_router:command(
                         Handle, 1000, {batch_restore, []})),
          exit(ReturnLink, kill),
          receive {quod_scope_down, _, _} -> ?assert(false)
          after 20 -> ok
          end,
          stop_link(RequestLink)
      end).

finalize_detects_dead_link_before_queued_down_is_consumed_test() ->
    with_open_scope(
      fun(Router, _TestPid, _TargetKey, _Binding, _Handle,
          RequestLink, ReturnLink) ->
          LinkMRef = monitor(process, ReturnLink),
          exit(ReturnLink, kill),
          receive {'DOWN', LinkMRef, process, ReturnLink, killed} -> ok
          after ?TIMEOUT -> error(return_link_still_alive)
          end,
          ?assertMatch(
             {error, {ontology_unreachable, <<"quod:target">>}},
             quod_ask_router:finalize(Router, proof_id(1))),
          ?assertEqual(0, maps:get(scopes, quod_ask_router:test_stats(Router))),
          stop_link(RequestLink)
      end).

authenticated_idle_expiry_uses_exact_last_command_test() ->
    with_open_scope(
      fun(Router, _TestPid, TargetKey, Binding, Handle,
          RequestLink, ReturnLink) ->
          BatchIds = [id(72)],
          {ok, RequestId} = quod_ask_router:command(
                              Handle, 1000, {batch_restore, BatchIds}),
          {scope_command, Binding, CommandSeq, RequestId, 1000,
           {batch_restore, BatchIds}} = receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     2, RequestId, CommandSeq, 1, false,
                     {batch_restored, BatchIds}),
          receive
              {quod_scope_event, Handle, RequestId, 1, false,
               {batch_restored, BatchIds}} -> ok
          after ?TIMEOUT -> error(batch_restore_timeout)
          end,
          Expired = {scope_error,
                     {scope_expired, <<"quod:target">>}},
          send_event(Router, TargetKey, ReturnLink, Binding,
                     3, RequestId, CommandSeq, 1, false, Expired),
          receive
              {quod_scope_event, Handle, RequestId, 1, false, Expired} -> ok
          after ?TIMEOUT -> error(scope_expiry_timeout)
          end,
          ?assertEqual(
             {error, {scope_error,
                      {scope_expired, <<"quod:target">>}}},
             quod_ask_router:finalize(Router, proof_id(1))),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

%% ------------------------------------------------------------------
%% Fixtures
%% ------------------------------------------------------------------

with_router(Fun) ->
    drain_test_messages(),
    TestPid = self(),
    OriginKey = key(1),
    TargetKey = key(2),
    OpenFun = fun(NodeKey, Endpoint, Channel) ->
                      Ref = make_ref(),
                      TestPid ! {open_requested, Ref, NodeKey, Endpoint, Channel},
                      Ref
              end,
    {ok, Router} = quod_ask_router:test_start_link(OriginKey, OpenFun),
    unlink(Router),
    try Fun(Router, TestPid, OriginKey, TargetKey)
    after
        exit(Router, kill),
        flush_test_messages()
    end.

with_open_scope(Fun) ->
    with_router(
      fun(Router, TestPid, OriginKey, TargetKey) ->
          Binding = binding(OriginKey, TargetKey, 1, <<"quod:target">>, 11),
          OpenRef = pending_ref(
                      quod_ask_router:ensure_scope(
                        Router, endpoint(), Binding, 30000), Router),
          {OpenRef, Channel} = receive_open(TargetKey),
          RequestLink = fake_link(TestPid, request),
          Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
          {scope_command, Binding, 1, RequestId, 30000, scope_open} =
              receive_command(request),
          ReturnLink = fake_link(TestPid, return),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     1, RequestId, 1, 0, false, {scope_opened, 42}),
          Handle = receive
                       {quod_scope_open, OpenRef, {ok, H, 42, 0, false}} -> H
                   after ?TIMEOUT -> error(open_timeout)
                   end,
          Fun(Router, TestPid, TargetKey, Binding, Handle,
              RequestLink, ReturnLink)
      end).

with_identity_router(Fun) ->
    drain_test_messages(),
    TestPid = self(),
    OriginKey = key(1),
    TargetKey = key(2),
    OpenFun = fun(_NodeKey, _Endpoint, _Channel) -> make_ref() end,
    IdentifyFun = fun(Endpoint, Channel) ->
                          Ref = make_ref(),
                          TestPid ! {identify_requested, Ref, Endpoint, Channel},
                          Ref
                  end,
    {ok, Router} = quod_ask_router:test_start_link(
                     OriginKey, OpenFun, IdentifyFun),
    unlink(Router),
    try Fun(Router, TestPid, OriginKey, TargetKey)
    after
        exit(Router, kill),
        flush_test_messages()
    end.

send_event(Router, TargetKey, ReturnLink, Binding, EventSeq, RequestId,
           CommandSeq, Generation, Dirty, Operation) ->
    Event = {scope_event, Binding, EventSeq, RequestId, CommandSeq,
             Generation, Dirty, Operation},
    {ok, Frame} = quod_scope_wire:encode_event(Event),
    Router ! {quod_message, {{TargetKey, endpoint()}, ReturnLink},
              quod_scope_wire:return_channel(origin_key(Binding)), Frame}.

send_identity_response(Router, AuthenticatedKey, ReturnLink, RequestId,
                       ResponseKey, TargetIdentity, Role) ->
    Response = {scope_identity_response, RequestId, ResponseKey,
                TargetIdentity, Role},
    {ok, Frame} = quod_scope_wire:encode_identity_response(Response),
    Router ! {quod_message, {AuthenticatedKey, ReturnLink},
              quod_scope_wire:return_channel(key(1)), Frame}.

receive_open(TargetKey) ->
    ExpectedEndpoint = endpoint(),
    receive
        {open_requested, Ref, TargetKey, ExpectedEndpoint, Channel} ->
            {Ref, Channel}
    after ?TIMEOUT -> error(no_open_request)
    end.

receive_command(Tag) ->
    receive
        {link_frame, Tag, Frame} ->
            {ok, Command} = quod_scope_wire:decode_request(Frame),
            Command
    after ?TIMEOUT -> error({no_command, Tag})
    end.

receive_identity_open() ->
    ExpectedEndpoint = endpoint(),
    receive
        {identify_requested, Ref, ExpectedEndpoint, Channel} -> {Ref, Channel}
    after ?TIMEOUT -> error(no_identity_open_request)
    end.

receive_identity_probe(Tag) ->
    receive
        {link_frame, Tag, Frame} ->
            {ok, Probe} = quod_scope_wire:decode_request(Frame),
            Probe
    after ?TIMEOUT -> error({no_identity_probe, Tag})
    end.

fake_link(TestPid, Tag) ->
    spawn(fun() -> fake_link_loop(TestPid, Tag) end).

fake_link_loop(TestPid, Tag) ->
    receive
        {send_ordered, Frame} ->
            TestPid ! {link_frame, Tag, Frame},
            fake_link_loop(TestPid, Tag);
        stop -> ok
    end.

stop_link(Pid) when is_pid(Pid) -> Pid ! stop, ok.

owner_process(Router, TestPid) ->
    spawn(fun() -> owner_loop(Router, TestPid) end).

batch_owner(Router, TestPid, Bindings) ->
    spawn(
      fun() ->
          Results = [quod_ask_router:ensure_scope(
                       Router, endpoint(), Binding, 30000)
                     || Binding <- Bindings],
          TestPid ! {batch_owner_result, self(), Results},
          batch_owner_loop(Router, TestPid)
      end).

batch_owner_loop(Router, TestPid) ->
    receive
        {finalize, ProofId} ->
            Result = quod_ask_router:finalize(Router, ProofId),
            TestPid ! {batch_owner_finalized, self(), Result},
            batch_owner_loop(Router, TestPid);
        stop -> ok
    end.

owner_loop(Router, TestPid) ->
    receive
        {ensure, Endpoint, Binding} ->
            Result = quod_ask_router:ensure_scope(
                       Router, Endpoint, Binding, 1000),
            TestPid ! {owner_result, self(), Result},
            owner_loop(Router, TestPid);
        {identify, Endpoint, Namespace, RemainingMs} ->
            Result = quod_ask_router:identify(
                       Router, Endpoint, Namespace, RemainingMs),
            TestPid ! {owner_result, self(), Result},
            owner_loop(Router, TestPid);
        stop -> ok;
        Notice ->
            TestPid ! {owner_notice, self(), Notice},
            owner_loop(Router, TestPid)
    end.

await_scope_count(Router, Expected) ->
    await_scope_count(Router, Expected, 50).

await_scope_count(_Router, _Expected, 0) -> error(scope_count_timeout);
await_scope_count(Router, Expected, Left) ->
    case maps:get(scopes, quod_ask_router:test_stats(Router)) of
        Expected -> ok;
        _ -> timer:sleep(5), await_scope_count(Router, Expected, Left - 1)
    end.

await_probe_count(Router, Expected) ->
    await_probe_count(Router, Expected, 50).

await_probe_count(_Router, _Expected, 0) -> error(probe_count_timeout);
await_probe_count(Router, Expected, Left) ->
    case maps:get(probes, quod_ask_router:test_stats(Router)) of
        Expected -> ok;
        _ -> timer:sleep(5), await_probe_count(Router, Expected, Left - 1)
    end.

await_retained_owner_count(Router, Expected) ->
    await_retained_owner_count(Router, Expected, 50).

await_retained_owner_count(_Router, _Expected, 0) ->
    error(retained_owner_count_timeout);
await_retained_owner_count(Router, Expected, Left) ->
    case maps:get(retained_owners, quod_ask_router:test_stats(Router)) of
        Expected -> ok;
        _ -> timer:sleep(5),
             await_retained_owner_count(Router, Expected, Left - 1)
    end.

flush_link_frames(TestPid) ->
    receive {link_frame, _, _} -> flush_link_frames(TestPid)
    after 0 -> ok
    end.

flush_test_messages() ->
    receive
        {open_requested, _, _, _, _} -> flush_test_messages();
        {identify_requested, _, _, _} -> flush_test_messages();
        {link_frame, _, _} -> flush_test_messages();
        {owner_result, _, _} -> flush_test_messages();
        {batch_owner_result, _, _} -> flush_test_messages();
        {owner_notice, _, _} -> flush_test_messages();
        {quod_scope_open, _, _} -> flush_test_messages();
        {quod_scope_event, _, _, _, _, _} -> flush_test_messages();
        {quod_scope_down, _, _} -> flush_test_messages()
    after 0 -> ok
    end.

drain_test_messages() ->
    timer:sleep(5),
    flush_test_messages().

pending_ref({pending, Router, Generation, OpenRef}, Router)
  when is_binary(Generation), byte_size(Generation) =:= 16,
       is_reference(OpenRef) ->
    OpenRef.

is_pending({pending, Router, Generation, OpenRef}, Router)
  when is_binary(Generation), byte_size(Generation) =:= 16,
       is_reference(OpenRef) -> true;
is_pending(_Result, _Router) -> false.

binding(OriginKey, TargetKey, N, TargetNs, AnchorN) ->
    {scope_binding, OriginKey, TargetKey, proof_id(N), id(N),
     {<<"quod:origin">>, key(10)}, {TargetNs, key(AnchorN)}, read_write}.

origin_key({scope_binding, OriginKey, _, _, _, _, _, _}) -> OriginKey.
target_identity({scope_binding, _, _, _, _, _, TargetIdentity, _}) ->
    TargetIdentity.

endpoint() -> {"127.0.0.1", 14567}.
namespace(N) -> iolist_to_binary([<<"quod:n">>, integer_to_binary(N)]).
key(N) -> <<N:256>>.
proof_id(N) -> <<N:256>>.
id(N) -> <<N:128>>.
