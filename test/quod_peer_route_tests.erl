-module(quod_peer_route_tests).
-include_lib("eunit/include/eunit.hrl").

empty_and_expired_walks_do_not_dispatch_test() ->
    Never = fun(_, _) -> error(dispatched_after_exhaustion) end,
    Select = fun(_, _) -> error(selected_without_dispatch) end,
    ?assertEqual(exhausted, quod_peer_route:walk(
      [], quod_time:mono_ms() + 1000, Never, Select, exhausted)),
    ?assertEqual(expired, quod_peer_route:walk(
      [address], quod_time:mono_ms(), Never, Select, expired)).

walk_is_ordered_in_caller_and_uses_one_deadline_test() ->
    Caller = self(), Deadline = quod_time:mono_ms() + 1000,
    Counter = atomics:new(1, []),
    Attempt = fun(Address, Timeout) ->
        ?assertEqual(Caller, self()),
        Ordinal = atomics:add_get(Counter, 1, 1),
        ?assertEqual(Ordinal, Address),
        ?assert(Timeout > 0),
        ?assert(Timeout =< 1000 div (4 - Ordinal)),
        Address
    end,
    ?assertEqual([3, 2, 1], quod_peer_route:walk([1, 2, 3], Deadline,
      Attempt, fun(Reply, Last) -> {next, [Reply | Last]} end, [])),
    ?assertEqual(3, atomics:get(Counter, 1)).

terminal_reply_stops_and_preserves_the_selected_value_test() ->
    ?assertEqual({reply, first}, quod_peer_route:walk(
      [first, forbidden], quod_time:mono_ms() + 1000,
      fun(first, _) -> first; (_, _) -> error(redial_after_reply) end,
      fun(Reply, _) -> {done, {reply, Reply}} end, none)).

callback_exceptions_are_not_transport_fallback_test() ->
    ?assertError(original_failure, quod_peer_route:walk(
      [first, second], quod_time:mono_ms() + 1000,
      fun(_, _) -> error(original_failure) end,
      fun(_, _) -> error(must_not_select) end, none)).

expired_between_addresses_keeps_the_last_result_test() ->
    Deadline = quod_time:mono_ms() + 1000,
    %% Expiry is the event being tested. Wait for the actual deadline inside
    %% the first attempt, rather than sleeping to guess a process ordering.
    Attempt = fun(first, _) ->
                      receive impossible -> error(unexpected_message)
                      after max(0, Deadline - quod_time:mono_ms()) -> first
                      end;
                 (_, _) -> error(dispatched_after_deadline)
              end,
    ?assertEqual(first, quod_peer_route:walk(
      [first, second], Deadline, Attempt,
      fun(Reply, _) -> {next, Reply} end, initial)).
