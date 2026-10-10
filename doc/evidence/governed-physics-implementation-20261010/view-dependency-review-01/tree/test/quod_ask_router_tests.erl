-module(quod_ask_router_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

-define(TIMEOUT, 1000).

identity_collection_stops_as_soon_as_quorum_is_decided_test() ->
    %% A singleton starts with its asynchronous local signer outstanding.
    ?assertEqual(
       waiting,
       quod_ask_router:test_identity_collection_progress(1, 1, 0)),
    %% Once that signer refuses, quorum is impossible immediately.  The proof
    %% deadline is not an ordinary progress-discovery mechanism.
    ?assertEqual(
       impossible,
       quod_ask_router:test_identity_collection_progress(1, 0, 0)),
    %% A 9-member committee needs 7.  Six signatures plus one outstanding
    %% signer can still succeed; removing that signer decides failure.
    ?assertEqual(
       waiting,
       quod_ask_router:test_identity_collection_progress(9, 1, 6)),
    ?assertEqual(
       impossible,
       quod_ask_router:test_identity_collection_progress(9, 0, 6)),
    ?assertEqual(
       complete,
       quod_ask_router:test_identity_collection_progress(9, 2, 7)).

identity_collection_link_loss_decides_without_proof_deadline_test() ->
    Parent = self(),
    Peer = key(1),
    OpenRef = make_ref(),
    Collector = spawn(
                  fun() ->
                      Parent !
                          {identity_collection_result,
                           quod_ask_router:test_collect_identity_loop(
                             OpenRef, Peer, identity_committee(),
                             two_identity_signatures(), 3000)}
                  end),
    Link = spawn(
             fun() ->
                 receive
                     {send_ordered, <<"test-frame">>} ->
                         Parent ! {identity_frame_sent, self()},
                         receive stop -> ok end
                 end
             end),
    Collector ! {link_up, OpenRef, Peer,
                 quod_agent_identity:channel(), Link},
    receive {identity_frame_sent, Link} -> ok
    after ?TIMEOUT -> error(identity_frame_not_sent)
    end,
    exit(Link, kill),
    receive
        {identity_collection_result, Result} ->
            ?assertEqual({error, unavailable}, Result)
    after 500 ->
        exit(Collector, kill),
        error(identity_link_loss_waited_for_proof_deadline)
    end.

identity_collection_correlated_refusal_decides_immediately_test() ->
    assert_identity_response_decides(
      {agent_identity_refusal, <<1:128>>}).

identity_collection_correlated_stale_response_is_terminal_test() ->
    assert_identity_response_decides(
      {agent_identity_response, <<1:128>>, key(1), key(99), 0, <<0:512>>}).

assert_identity_response_decides(Response) ->
    Parent = self(),
    Peer = key(1),
    Collector = spawn(
                  fun() ->
                      Parent !
                          {identity_collection_result,
                           quod_ask_router:test_collect_identity_loop(
                             none, Peer, identity_committee(),
                             two_identity_signatures(), 3000)}
                  end),
    {ok, Payload} = quod_agent_identity:encode_response(Response),
    Collector ! {quod_message, {Peer, self()},
                 quod_agent_identity:channel(), Payload},
    receive
        {identity_collection_result, Result} ->
            ?assertEqual({error, unavailable}, Result)
    after 500 ->
        exit(Collector, kill),
        error(identity_response_waited_for_proof_deadline)
    end.

identity_committee() -> [key(N) || N <- lists:seq(1, 4)].

two_identity_signatures() ->
    #{key(2) => <<2:512>>, key(3) => <<3:512>>}.

inbound_identity_request_without_host_returns_correlated_refusal_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    with_router(
      fun(Router, TestPid, _OriginKey, Peer) ->
          Fixture = quod_ct:signed_goal_fixture(#{}),
          RequestId = <<7:128>>,
          Request =
              {agent_identity_request, RequestId, proof_id(7),
               maps:get(request_bytes, Fixture),
               maps:get(signature, Fixture), maps:get(deadline, Fixture)},
          {ok, Payload} = quod_agent_identity:encode_request(Request),
          Link = fake_link(TestPid, identity_refusal),
          Router ! {quod_message, {Peer, Link},
                    quod_agent_identity:channel(), Payload},
          receive
              {link_frame, identity_refusal, ResponsePayload} ->
                  ?assertEqual(
                     {ok, {agent_identity_refusal, RequestId}},
                     quod_agent_identity:decode_response(ResponsePayload))
          after ?TIMEOUT ->
              error(missing_identity_refusal)
          end,
          stop_link(Link)
      end).

inbound_identity_duplicate_moves_reply_to_replacement_link_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    with_router(
      fun(Router, TestPid, _OriginKey, Peer) ->
          Ns = <<"quod:identity-replacement-test">>,
          Fixture = quod_ct:signed_goal_fixture(
                      #{target => {Ns, <<201:256>>}}),
          RequestId = <<8:128>>,
          Request =
              {agent_identity_request, RequestId, proof_id(8),
               maps:get(request_bytes, Fixture),
               maps:get(signature, Fixture), maps:get(deadline, Fixture)},
          {ok, Payload} = quod_agent_identity:encode_request(Request),
          Attester = fake_identity_attester(TestPid, Ns),
          receive {identity_attester_ready, Attester} -> ok
          after ?TIMEOUT -> error(identity_attester_not_registered)
          end,
          Link1 = fake_link(TestPid, identity_original),
          Link2 = fake_link(TestPid, identity_replacement),
          Router ! {quod_message, {Peer, Link1},
                    quod_agent_identity:channel(), Payload},
          {Attester, Router, Tag} = receive
              {identity_attestation_requested, Attester, Router, Tag0} ->
                  {Attester, Router, Tag0}
          after ?TIMEOUT -> error(identity_attestation_not_requested)
          end,
          Router ! {quod_message, {Peer, Link2},
                    quod_agent_identity:channel(), Payload},
          _ = quod_ask_router:test_stats(Router),
          Attester ! {finish_identity_attestation, Router, Tag,
                      {error, unavailable}},
          receive
              {link_frame, identity_replacement, ResponsePayload} ->
                  ?assertEqual(
                     {ok, {agent_identity_refusal, RequestId}},
                     quod_agent_identity:decode_response(ResponsePayload))
          after ?TIMEOUT ->
              error(identity_replacement_link_not_used)
          end,
          receive
              {link_frame, identity_original, _} ->
                  error(identity_reply_used_dead_route)
          after 25 -> ok
          end,
          stop_link(Link1),
          stop_link(Link2),
          exit(Attester, kill)
      end).

fake_identity_attester(TestPid, Ns) ->
    spawn(
      fun() ->
          true = gproc:reg({n, l, {quod_prolog, Ns}}),
          TestPid ! {identity_attester_ready, self()},
          receive
              {'$gen_cast', {agent_attestation, _Request, ReplyTo, Tag}} ->
                  TestPid ! {identity_attestation_requested,
                             self(), ReplyTo, Tag},
                  receive
                      {finish_identity_attestation, ReplyTo, Tag, Result} ->
                          ReplyTo ! {quod_agent_attestation, Tag, Result}
                  end
          end
      end).

pending_precedes_send_and_scope_is_reused_test() ->
    with_router(
      fun(Router, TestPid, OriginKey, TargetKey) ->
          Binding = binding(OriginKey, TargetKey, 1, <<"quod:target">>, 11),
          OpenRef = pending_ref(
                      quod_ask_router:ensure_scope(
                        Router, endpoint(), Binding, node, 30000), Router),
          OpenStats = quod_ask_router:test_stats(Router),
          ?assertEqual(1, maps:get(scopes, OpenStats)),
          ?assertMatch(#{scopes := 1, owners := 1, openings := 1},
                       maps:get(owner_current, OpenStats)),
          ?assertMatch(#{scopes := 1, owners := 1, openings := 1},
                       maps:get(owner_peak, OpenStats)),
          {OpenRef, Channel} = receive_open(TargetKey),
          ?assertEqual(quod_scope_wire:request_channel(<<"quod:target">>), Channel),
          RequestLink = fake_link(TestPid, request),
          Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
          OpenCommand = receive_command(request),
          {scope_command, Binding, 1, RequestId, 30000,
           {scope_open, node, []}} = OpenCommand,
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
                         ReuseBinding, node, 1)),
          receive {open_requested, _, _, _, _} -> ?assert(false)
          after 20 -> ok
          end,
          ok = quod_ask_router:unregister(Handle),
          await_scope_count(Router, 0),
          ClosedStats = quod_ask_router:test_stats(Router),
          ?assertMatch(#{scopes := 0, owners := 0, openings := 0},
                       maps:get(owner_current, ClosedStats)),
          ?assertMatch(#{scopes := 1, owners := 1, openings := 1},
                       maps:get(owner_peak, ClosedStats)),
          stop_link(RequestLink),
          stop_link(ReturnLink)
      end).

scope_open_carries_caller_context_across_router_mailbox_test() ->
    with_router(fun(Router, TestPid, OriginKey, TargetKey) ->
        Carrier = [{<<"traceparent">>,
                    <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>}],
        Binding = binding(OriginKey, TargetKey, 1, <<"quod:target">>, 11),
        OpenRef = quod_trace:with_context(quod_trace:extract(Carrier), fun() ->
            pending_ref(quod_ask_router:ensure_scope(
                          Router, endpoint(), Binding, node, 30000), Router)
        end),
        %% Link establishment runs after the caller has detached its context.
        {OpenRef, Channel} = receive_open(TargetKey),
        RequestLink = fake_link(TestPid, request),
        try
            Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
            ?assertMatch(
               {scope_command, Binding, 1, _, 30000, {scope_open, node, Carrier}},
               receive_command(request))
        after stop_link(RequestLink)
        end
    end).

signed_authentication_is_carried_unchanged_on_remote_open_test() ->
    with_router(
      fun(Router, TestPid, OriginKey, TargetKey) ->
          Fixture = quod_ct:signed_goal_fixture(#{}),
          Authentication = signed_auth(Fixture),
          Binding = signed_binding(OriginKey, TargetKey, Fixture),
          OpenRef = pending_ref(
                      quod_ask_router:ensure_scope(
                        Router, endpoint(), Binding, Authentication, 30000),
                      Router),
          {OpenRef, Channel} = receive_open(TargetKey),
          RequestLink = fake_link(TestPid, request),
          Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
          {scope_command, Binding, 1, RequestId, 30000,
           {scope_open, Authentication, []}} = receive_command(request),

          %% The router binds the exact opaque authentication bytes.  Their
          %% signature and principal are verified independently by the target.
          {signed_goal, RequestBytes, Signature, Certificate} = Authentication,
          <<First, Rest/binary>> = RequestBytes,
          Altered = {signed_goal, <<(First bxor 1), Rest/binary>>,
                     Signature, Certificate},
          ?assertEqual(
             {error, invalid_binding},
             quod_ask_router:ensure_scope(
               Router, endpoint(), Binding, Altered, 30000)),
          ?assertEqual(
             {error, invalid_binding},
             quod_ask_router:ensure_scope(
               Router, endpoint(), Binding, node, 30000)),

          ReturnLink = fake_link(TestPid, return),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     1, RequestId, 1, 0, false, {scope_opened, 42}),
          Handle = receive
                       {quod_scope_open, OpenRef,
                        {ok, H, 42, 0, false}} -> H
                   after ?TIMEOUT -> error(open_timeout)
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
          Selection = {tx_selection, none, [], ordinary},
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

          {ok, CertifyRequest} = quod_ask_router:command(
                                   Handle, 30000, certify_reads),
          {scope_command, Binding, CertifySeq, CertifyRequest, 30000,
           certify_reads} = receive_command(request),
          CertificateBlob = <<"bounded read certificate">>,
          send_event(Router, TargetKey, ReturnLink, Binding,
                     4, CertifyRequest, CertifySeq, 0, false,
                     {reads_certified, CertificateBlob}),
          receive
              {quod_scope_event, Handle, CertifyRequest, 0, false,
               {reads_certified, CertificateBlob}} -> ok
          after ?TIMEOUT -> error(read_certificate_event_timeout)
          end,

          Submit = {submit_plan, <<"plan">>, <<"goal">>, <<"result">>,
                    foreign_reads_blob(), []},
          {ok, SubmitRequest} = quod_ask_router:command(
                                  Handle, 30000, Submit),
          {scope_command, Binding, SubmitSeq, SubmitRequest, 30000, Submit} =
              receive_command(request),
          send_event(Router, TargetKey, ReturnLink, Binding,
                     5, SubmitRequest, SubmitSeq, 0, false,
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
                    [target_identity(Binding)], GoalBlob,
                    quod_transaction_scope:empty_selection()},
          send_event(Router, TargetKey, ReturnLink, Binding,
                     2, RequestId, CommandSeq, 0, false, Nested),
          receive
              {quod_scope_event, Handle, RequestId, 0, false, Nested} -> ok
          after ?TIMEOUT -> error(nested_event_timeout)
          end,
          {ok, AnswerBlob} = quod_scope_wire:encode_payload(
                               answer, {child_goal, ok}),
          Final = {solution, InvocationId, 1, AnswerBlob, false},
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
          ?assertEqual(
             1,
             maps:get(retained_owners, maps:get(owner_peak, Stats))),
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

owner_proof_shape_bound_rejects_before_open_test() ->
    with_router(
      fun(Router, _TestPid, OriginKey, TargetKey) ->
          Results = [quod_ask_router:ensure_scope(
                       Router, endpoint(),
                       setelement(
                         4,
                         binding(OriginKey, TargetKey, N,
                                 namespace(N), N),
                         proof_id(1)), node, 1000)
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
               node, 1000)),
          ?assertEqual(?QUOD_MAX_ROUTER_SCOPES_PER_OWNER,
                       maps:get(scopes, quod_ask_router:test_stats(Router)))
      end).

router_population_has_no_peer_or_node_quota_test_() ->
    {timeout, 10, fun router_population_has_no_peer_or_node_quota/0}.

router_population_has_no_peer_or_node_quota() ->
    drain_test_messages(),
    OriginKey = key(1),
    TargetKey = key(2),
    SilentOpen = fun(_NodeKey, _Endpoint, _Channel) -> make_ref() end,
    {ok, Router} = quod_ask_router:test_start_link(OriginKey, SilentOpen),
    unlink(Router),
    %% Sixty-five owners with eight scopes each exceed both deleted defaults:
    %% sixteen scopes per peer and 512 scopes per router. Every scope still
    %% belongs to an exact monitored proof owner and obeys that proof's shape.
    OwnerCount = 65,
    Owners =
        [begin
             Bindings =
                 [begin
                      N = OwnerN * 1000 + Slot,
                      setelement(
                        4,
                        binding(OriginKey, TargetKey, N, namespace(N), N),
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
        Expected = OwnerCount * ?QUOD_MAX_ROUTER_SCOPES_PER_OWNER,
        ?assertEqual(Expected,
                     maps:get(scopes, quod_ask_router:test_stats(Router))),
        FilledStats = quod_ask_router:test_stats(Router),
        ?assertEqual(0, maps:get(retained_owners, FilledStats)),
        ?assertEqual(Expected, maps:get(entries, FilledStats))
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
          {scope_command, Binding, 1, RequestId, _, {scope_open, node, []}} =
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
          {scope_command, Binding, 1, _OpenRequestId, _, {scope_open, node, []}} =
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
                        Router, endpoint(), Binding, node, 30000), Router),
          {OpenRef, Channel} = receive_open(TargetKey),
          RequestLink = fake_link(TestPid, request),
          Router ! {link_up, OpenRef, TargetKey, Channel, RequestLink},
          {scope_command, Binding, 1, RequestId, 30000,
           {scope_open, node, []}} =
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
                       Router, endpoint(), Binding, node, 30000)
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
                       Router, Endpoint, Binding, node, 1000),
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
    {ok, AuthenticationDigest} =
        quod_scope_wire:authentication_digest(node),
    {scope_binding, OriginKey, TargetKey, proof_id(N), id(N),
     {<<"quod:origin">>, key(10)}, {TargetNs, key(AnchorN)}, read_write,
     {node, OriginKey}, AuthenticationDigest}.

signed_binding(OriginKey, TargetKey, Fixture) ->
    Authentication = signed_auth(Fixture),
    {ok, AuthenticationDigest} =
        quod_scope_wire:authentication_digest(Authentication),
    {scope_binding, OriginKey, TargetKey, proof_id(1), id(1),
     maps:get(target, Fixture), {<<"quod:signed-target">>, key(77)},
     read_write, maps:get(principal, Fixture), AuthenticationDigest}.

signed_auth(Fixture) ->
    {ok, Statement} = quod_agent_identity:statement(
                        maps:get(evidence, Fixture), proof_id(1), key(78),
                        maps:get(deadline, Fixture)),
    {ok, Certificate} = quod_agent_identity:certificate(
                          Statement, [], []),
    {signed_goal, maps:get(request_bytes, Fixture),
     maps:get(signature, Fixture), Certificate}.

origin_key({scope_binding, OriginKey, _, _, _, _, _, _, _, _}) -> OriginKey.
target_identity({scope_binding, _, _, _, _, _, TargetIdentity, _, _, _}) ->
    TargetIdentity.

endpoint() -> {"127.0.0.1", 14567}.
foreign_reads_blob() ->
    {ok, Blob} = quod_scope_wire:encode_payload(foreign_reads, []),
    Blob.
namespace(N) -> iolist_to_binary([<<"quod:n">>, integer_to_binary(N)]).
key(N) -> <<N:256>>.
proof_id(N) -> <<N:256>>.
id(N) -> <<N:128>>.
