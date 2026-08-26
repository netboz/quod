-module(quod_client_goal_router_tests).
-moduledoc false.

-include_lib("eunit/include/eunit.hrl").

-define(PEER, <<16#41:256>>).
-define(ENDPOINT, {{127, 0, 0, 1}, 4567}).
-define(OWNER, {session, <<16#42:256>>, <<16#43:256>>}).

cursor_target_states_are_named_before_the_shared_renderer_test() ->
    ?assertEqual(
       {error, cursor_not_found},
       quod_client_goal_router:test_cursor_target_result({error, not_found})),
    ?assertEqual(
       {error, cursor_not_ready},
       quod_client_goal_router:test_cursor_target_result({error, not_ready})),
    ?assertEqual(
       {error, cursor_busy},
       quod_client_goal_router:test_cursor_target_result({error, busy})),
    ?assertEqual(
       {error, proof_unavailable},
       quod_client_goal_router:test_cursor_target_result({error, bad_state})).

submit_target_documented_outcomes_select_one_reply_test() ->
    Request = {submit, <<0:128>>, <<>>, <<0:512>>, none, []},
    ?assertEqual(
       {response, {refused, <<0:128>>, busy}},
       quod_client_goal_router:test_submit_target_result(
         Request, {error, busy})),
    ?assertEqual(
       {response, {error, <<0:128>>, operation_conflict}},
       quod_client_goal_router:test_submit_target_result(
         Request, {error, operation_conflict})).

result_is_correlated_and_fully_cleaned_test() ->
    with_router(
      fun(Router, Link, Fixture) ->
          Caller = submit_async(Router, Fixture, none, 1000),
          {Request, _Frame} = sent_request(Link),
          RequestId = quod_client_goal_endpoint:request_id(Request),
          {ok, ResultBlob} = quod_client_result:encode({answers, 7, []}),
          respond(Router, Link, {result, RequestId, ResultBlob}),
          receive
              {Caller, {ok, Evidence,
                        {normalized, {answers, 7, []}}}} ->
                  ?assertEqual(maps:get(evidence, Fixture), Evidence)
          after 1000 -> error(router_result_missing)
          end,
          await_stats(Router, #{correlations => 0, routes => 0})
      end).

wrong_peer_never_satisfies_an_exact_correlation_test() ->
    with_router(
      fun(Router, Link, Fixture) ->
          Caller = submit_async(Router, Fixture, none, 1000),
          {Request, _Frame} = sent_request(Link),
          RequestId = quod_client_goal_endpoint:request_id(Request),
          {ok, ResultBlob} = quod_client_result:encode(fail),
          {ok, WrongPeerResult} = quod_client_goal_endpoint:encode_response(
                                    {result, RequestId, ResultBlob}),
          Router ! {quod_message, {<<0:256>>, Link},
                    quod_client_goal_endpoint:channel(), WrongPeerResult},
          respond(Router, Link, {result, RequestId, ResultBlob}),
          receive {Caller, {ok, _, {normalized, fail}}} -> ok
          after 1000 -> error(exact_peer_result_missing)
          end,
          await_stats(Router, #{correlations => 0})
      end).

preexecution_refusals_remain_route_eligible_test_() ->
    [?_test(refusal_is_returned_before_any_result(Reason))
     || Reason <- [not_ready, busy, rate_limited]].

refusal_is_returned_before_any_result(Reason) ->
    with_router(
      fun(Router, Link, Fixture) ->
          Caller = submit_async(Router, Fixture, none, 1000),
          {Request, _Frame} = sent_request(Link),
          RequestId = quod_client_goal_endpoint:request_id(Request),
          respond(Router, Link, {refused, RequestId, Reason}),
          receive {Caller, {error, {refused, Reason}}} -> ok
          after 1000 -> error(preexecution_refusal_missing)
          end,
          await_stats(Router, #{correlations => 0, routes => 0})
      end).

link_failure_before_send_is_the_only_pre_send_result_test() ->
    Parent = self(),
    OpenFun = fun(Peer, _Endpoint, Channel) ->
                      Ref = make_ref(),
                      self() ! {link_error, Ref, Peer, Channel},
                      Parent ! open_attempted,
                      Ref
              end,
    {ok, Router} = quod_client_goal_router:test_start_link(OpenFun),
    Fixture = fixture(),
    try
        ?assertEqual(
           {error, pre_send},
           submit(Router, Fixture, none, 1000)),
        receive open_attempted -> ok after 1000 -> error(no_open_attempt) end,
        await_stats(Router, #{correlations => 0, routes => 0})
    after stop_router(Router) end.

missing_router_is_provably_pre_send_test() ->
    ?assertEqual(undefined, whereis(quod_client_goal_router)),
    Fixture = fixture(),
    ?assertEqual(
       {error, pre_send},
       quod_client_goal_router:submit(
         route(), ?OWNER, maps:get(evidence, Fixture),
         maps:get(request_bytes, Fixture), maps:get(signature, Fixture),
         none, [], quod_time:now_ms() + 5000, 1000)).

post_send_timeout_is_uncertain_and_leaves_nothing_test() ->
    with_router(
      fun(Router, Link, Fixture) ->
          Evidence = maps:get(evidence, Fixture),
          Caller = submit_async(Router, Fixture, none, 30),
          _ = sent_request(Link),
          receive {Caller, {error, {uncertain, Evidence}}} -> ok
          after 1000 -> error(router_uncertainty_missing)
          end,
          await_stats(Router, #{correlations => 0, routes => 0})
      end).

caller_death_cleans_the_exact_outbound_correlation_test() ->
    with_router(
      fun(Router, Link, Fixture) ->
          Parent = self(),
          Caller = spawn(
                     fun() ->
                         Parent ! {caller_ready, self()},
                         _ = submit(Router, Fixture, none, 1000),
                         Parent ! unexpected_caller_reply
                     end),
          receive {caller_ready, Caller} -> ok
          after 1000 -> error(caller_not_ready) end,
          _ = sent_request(Link),
          MRef = monitor(process, Caller),
          exit(Caller, kill),
          receive {'DOWN', MRef, process, Caller, killed} -> ok
          after 1000 -> error(caller_down_missing) end,
          await_stats(Router, #{correlations => 0, routes => 0}),
          receive unexpected_caller_reply -> error(caller_was_replied)
          after 0 -> ok end
      end).

cursor_route_reuses_one_link_and_drops_after_stop_test() ->
    with_router(
      fun(Router, Link, Fixture) ->
          CursorId = <<16#44:256>>,
          Caller = submit_async(Router, Fixture, CursorId, 1000),
          {OpenRequest, _} = sent_request(Link),
          OpenId = quod_client_goal_endpoint:request_id(OpenRequest),
          {ok, BindingBlob} = quod_durable_term:encode_result(#{}),
          {ok, SolutionBlob} = quod_client_result:encode(
                                 {solution, CursorId, 7, BindingBlob}),
          respond(Router, Link,
                  {cursor_result, OpenId, CursorId, SolutionBlob}),
          receive
              {Caller, {ok, _,
                        {normalized, {solution, CursorId, 7, _}}}} -> ok
          after 1000 -> error(cursor_open_result_missing)
          end,
          await_stats(Router, #{correlations => 0, routes => 1}),
          StopCaller = cursor_async(Router, CursorId, stop, 1000),
          {{cursor, StopId, CursorId, stop}, _} = sent_request(Link),
          {ok, StoppedBlob} = quod_client_result:encode(stopped),
          respond(Router, Link,
                  {cursor_result, StopId, CursorId, StoppedBlob}),
          receive
              {StopCaller, {ok, _, {normalized, stopped}}} -> ok
          after 1000 -> error(cursor_stop_result_missing)
          end,
          await_stats(Router, #{correlations => 0, routes => 0})
      end).

cursor_target_link_death_drops_the_exact_route_test() ->
    with_router(
      fun(Router, Link, Fixture) ->
          CursorId = <<16#47:256>>,
          Caller = submit_async(Router, Fixture, CursorId, 1000),
          {OpenRequest, _} = sent_request(Link),
          OpenId = quod_client_goal_endpoint:request_id(OpenRequest),
          {ok, BindingBlob} = quod_durable_term:encode_result(#{}),
          {ok, SolutionBlob} = quod_client_result:encode(
                                 {solution, CursorId, 7, BindingBlob}),
          respond(Router, Link,
                  {cursor_result, OpenId, CursorId, SolutionBlob}),
          receive {Caller, {ok, _, {normalized, {solution, CursorId, 7, _}}}} -> ok
          after 1000 -> error(cursor_open_result_missing) end,
          await_stats(Router, #{correlations => 0, routes => 1}),
          exit(Link, kill),
          await_stats(Router, #{correlations => 0, routes => 0})
      end).

%% Current rows must follow the live router maps, while the owner-lifetime
%% peaks survive exact cleanup.  Opening and stopping one real cursor exercises
%% both the outbound correlation owner and the retained cursor-route owner.
owner_stats_keep_peaks_after_cursor_cleanup_test() ->
    with_router(
      fun(Router, Link, Fixture) ->
          CursorId = <<16#48:256>>,
          Caller = submit_async(Router, Fixture, CursorId, 1000),
          {OpenRequest, _} = sent_request(Link),
          assert_owner_stats(
            Router,
            #{outbound => 1, inbound => 0, cursor_routes => 1},
            #{outbound => 1, inbound => 0, cursor_routes => 1}),

          OpenId = quod_client_goal_endpoint:request_id(OpenRequest),
          {ok, BindingBlob} = quod_durable_term:encode_result(#{}),
          {ok, SolutionBlob} = quod_client_result:encode(
                                 {solution, CursorId, 7, BindingBlob}),
          respond(Router, Link,
                  {cursor_result, OpenId, CursorId, SolutionBlob}),
          receive
              {Caller, {ok, _,
                        {normalized, {solution, CursorId, 7, _}}}} -> ok
          after 1000 -> error(cursor_owner_open_result_missing)
          end,
          assert_owner_stats(
            Router,
            #{outbound => 0, inbound => 0, cursor_routes => 1},
            #{outbound => 1, inbound => 0, cursor_routes => 1}),

          StopCaller = cursor_async(Router, CursorId, stop, 1000),
          {{cursor, StopId, CursorId, stop}, _} = sent_request(Link),
          {ok, StoppedBlob} = quod_client_result:encode(stopped),
          respond(Router, Link,
                  {cursor_result, StopId, CursorId, StoppedBlob}),
          receive
              {StopCaller, {ok, _, {normalized, stopped}}} -> ok
          after 1000 -> error(cursor_owner_stop_result_missing)
          end,
          assert_owner_stats(
            Router,
            #{outbound => 0, inbound => 0, cursor_routes => 0},
            #{outbound => 1, inbound => 0, cursor_routes => 1})
      end).

router_death_after_send_preserves_request_uncertainty_test() ->
    Parent = self(),
    Link = spawn(fun() -> link_loop(Parent) end),
    OpenFun = open_fun(Link),
    {ok, Router} = quod_client_goal_router:test_start_link(OpenFun),
    unlink(Router),
    Fixture = fixture(),
    Evidence = maps:get(evidence, Fixture),
    Caller = submit_async(Router, Fixture, none, 1000),
    _ = sent_request(Link),
    MRef = monitor(process, Router),
    exit(Router, kill),
    receive {'DOWN', MRef, process, Router, killed} -> ok
    after 1000 -> error(router_down_missing)
    end,
    receive {Caller, {error, {uncertain, Evidence}}} -> ok
    after 1500 -> error(router_restart_erased_uncertainty)
    end,
    Link ! stop.

with_router(Fun) ->
    Parent = self(),
    Link = spawn(fun() -> link_loop(Parent) end),
    {ok, Router} = quod_client_goal_router:test_start_link(open_fun(Link)),
    try Fun(Router, Link, fixture())
    after stop_router(Router), Link ! stop end.

open_fun(Link) ->
    fun(Peer, _Endpoint, Channel) ->
            Ref = make_ref(),
            self() ! {link_up, Ref, Peer, Channel, Link},
            Ref
    end.

fixture() ->
    quod_ct:signed_goal_fixture(
      #{network => <<16#45:256>>, target => {<<"quod:test">>, <<16#46:256>>},
        key_pair => quod_identity:generate(), mode => read,
        deadline => quod_time:now_ms() + 5000,
        goal_text => <<"true.">>}).

submit(Router, Fixture, CursorBinding, TimeoutMs) ->
    quod_client_goal_router:test_submit(
      Router, route(), ?OWNER, maps:get(evidence, Fixture),
      maps:get(request_bytes, Fixture), maps:get(signature, Fixture),
      CursorBinding, [], quod_time:now_ms() + 5000, TimeoutMs).

submit_async(Router, Fixture, CursorBinding, TimeoutMs) ->
    Parent = self(),
    spawn(fun() ->
                  Parent ! {self(),
                            submit(Router, Fixture, CursorBinding, TimeoutMs)}
          end).

cursor_async(Router, CursorId, Command, TimeoutMs) ->
    Parent = self(),
    spawn(fun() ->
                  Parent ! {self(), quod_client_goal_router:test_cursor(
                                           Router, ?OWNER, CursorId,
                                           Command, TimeoutMs)}
          end).

route() -> #{node_key => ?PEER, endpoint => ?ENDPOINT}.

link_loop(Parent) ->
    receive
        {send_ordered, Frame} ->
            Parent ! {link_frame, self(), Frame},
            link_loop(Parent);
        stop -> ok
    end.

sent_request(Link) ->
    receive
        {link_frame, Link, Frame} ->
            {ok, Request} = quod_client_goal_endpoint:route_request(Frame),
            {Request, Frame}
    after 1000 -> error(request_frame_missing)
    end.

respond(Router, Link, Response) ->
    {ok, Frame} = quod_client_goal_endpoint:encode_response(Response),
    Router ! {quod_message, {?PEER, Link},
              quod_client_goal_endpoint:channel(), Frame},
    ok.

await_stats(_Router, _Expected, 0) -> error(router_cleanup_timeout);
await_stats(Router, Expected, Remaining) ->
    Stats = quod_client_goal_router:test_stats(Router),
    case maps:with(maps:keys(Expected), Stats) =:= Expected of
        true -> ok;
        false ->
            receive after 1 -> ok end,
            await_stats(Router, Expected, Remaining - 1)
    end.

await_stats(Router, Expected) -> await_stats(Router, Expected, 1000).

assert_owner_stats(Router, Current, Peak) ->
    Stats = quod_client_goal_router:test_stats(Router),
    ?assertEqual(Current, maps:get(owner_current, Stats)),
    ?assertEqual(Peak, maps:get(owner_peak, Stats)).

stop_router(Router) ->
    case is_process_alive(Router) of
        true -> gen_server:stop(Router);
        false -> ok
    end.
