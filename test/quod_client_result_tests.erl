-module(quod_client_result_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_client_goal_limits.hrl").

independent_refusals_remain_typed_through_the_client_boundary_test() ->
    lists:foreach(fun({Reason, Status}) ->
        Error = {error, Reason},
        ?assertEqual(Error, quod_client_result:normalize(#{}, Error)),
        {ok, Bytes} = quod_client_result:encode(Error),
        ?assertEqual({ok, Error}, quod_client_result:decode(Bytes)),
        ?assertEqual({Status, #{error => Reason}},
                     quod_client_result:http_normalized(#{}, Error))
    end, [{independent_requires_signed_request, 400},
          {independent_nesting, 400}, {independent_mixed_writes, 400},
          {independent_scope_required, 400}]).

all_normalized_results_roundtrip_test() ->
    Fixture = fixture(),
    Evidence = maps:get(evidence, Fixture),
    {ok, BindingBlob} = quod_durable_term:encode_result(#{<<"X">> => bob}),
    {ok, ReasonsBlob} = quod_wire_term:encode_failure_reasons(
                          [{not_allowed, <<"private">>}]),
    TxRef = {transaction, <<"quod:a">>, <<1:256>>, <<2:256>>},
    GroupRef = {group, <<"quod:a">>, <<1:256>>, <<3:256>>, <<4:256>>,
                <<5:256>>},
    OperationRef = {operation, <<"quod:a">>, <<1:256>>,
                    agent_ref(<<"quod:agent">>, <<8:256>>, 8),
                    <<9:256>>},
    Slots = [{{<<"quod:a">>, <<1:256>>}, 7, 1},
             {{<<"quod:b">>, <<6:256>>}, 8, 2}],
    Results =
        [{answers, 7, [BindingBlob]},
         {solution, <<7:256>>, 7, BindingBlob},
         stopped, fail, {failed, ReasonsBlob},
         {committed, [BindingBlob], TxRef},
         {committed, [BindingBlob],
          {group_outcome, GroupRef, 9, Slots}},
         {pending, TxRef}, {pending, GroupRef}, {pending, OperationRef},
         {error, read_only}, {error, target_unavailable},
         {error, ontology_rebuilding}, {error, ontology_busy},
         {error, cursor_not_found}, {error, cursor_not_ready},
         {error, cursor_busy},
         {error, invalid_action}, {error, non_backtrackable_action},
         {error, conflict_retry}, {error, proof_unavailable},
         {error, result_too_large}],
    lists:foreach(
      fun(Result) ->
          {ok, Blob} = quod_client_result:encode(Result),
          ?assertEqual({ok, Result}, quod_client_result:decode(Blob)),
          ?assert(is_tuple(quod_client_result:http_normalized(
                            Evidence, Result)))
      end, Results).

bare_engine_states_and_tagged_cursor_states_have_distinct_names_test() ->
    ?assertEqual({error, ontology_busy},
                 quod_client_result:normalize(#{}, {error, busy})),
    ?assertEqual({error, proof_unavailable},
                 quod_client_result:normalize(#{}, {error, not_ready})),
    ?assertEqual({error, proof_unavailable},
                 quod_client_result:normalize(#{}, {error, not_found})),
    ?assertEqual({error, cursor_busy},
                 quod_client_result:normalize(#{}, {error, cursor_busy})),
    ?assertEqual({error, cursor_not_ready},
                 quod_client_result:normalize(#{},
                                              {error, cursor_not_ready})).

independent_complete_vectors_keep_every_target_in_success_shaped_replies_test() ->
    Evidence = maps:get(evidence, fixture()),
    Op = {operation, <<"quod:a">>, <<1:256>>,
          agent_ref(<<"quod:agent">>, <<8:256>>, 8), <<9:256>>},
    A = {transaction, <<"quod:a">>, <<1:256>>, <<2:256>>},
    B = {transaction, <<"quod:b">>, <<3:256>>, <<4:256>>},
    lists:foreach(fun({Labels, Aggregate}) ->
        Rows = [{quod_operation_vector:target(Ref), {Label, Ref}}
                || {Label, Ref} <- lists:zip(Labels, [A, B])],
        Result = {committed, [], {operation_outcome, Op, Rows}},
        {ok, Bytes} = quod_client_result:encode(Result),
        ?assertEqual({ok, Result}, quod_client_result:decode(Bytes)),
        {200, Json} = quod_client_result:http_normalized(Evidence, Result),
        ?assertEqual(Aggregate, maps:get(aggregate, Json)),
        [JA, JB] = maps:get(targets, Json),
        ?assertEqual([<<"quod:a">>, <<"quod:b">>],
                     [maps:get(ns, JA), maps:get(ns, JB)]),
        ?assertEqual([case L of committed -> committed; _ -> rejected end || L <- Labels],
                     [maps:get(status, JA), maps:get(status, JB)])
    end, [{[committed, committed], all_applied},
          {[committed, {rejected, conflict_retry}], mixed},
          {[{rejected, not_authorized}, {rejected, conflict_retry}], all_rejected}]),
    ?assertEqual({error, invalid_result}, quod_client_result:encode(
      {committed, [], {operation_outcome, Op, [{quod_operation_vector:target(A), pending}]}})).

local_http_uses_the_normalized_binary_name_result_test() ->
    Evidence = maps:get(evidence, fixture()),
    Result = quod_client_result:normalize(Evidence, {ok, [#{0 => bob}], 7}),
    ?assertEqual(
       {200, #{result => ok, height => 7,
               request_digest => b64url(maps:get(request_digest, Evidence)),
               operation_id =>
                   b64url(maps:get(operation_id,
                                   maps:get(request, Evidence))),
               bindings => [#{<<"X">> => <<"bob">>}]}},
       quod_client_result:http_normalized(Evidence, Result)).

aggregate_result_bound_is_identical_before_transport_test() ->
    Evidence = maps:get(evidence, fixture()),
    Value = binary:copy(<<"x">>, 12000),
    Raw = {ok, lists:duplicate(50, #{0 => Value}), 7},
    Result = quod_client_result:normalize(Evidence, Raw),
    ?assertEqual({error, result_too_large}, Result),
    ?assertEqual({413, #{error => result_too_large}},
                 quod_client_result:http_normalized(Evidence, Result)).

conflict_retry_is_a_specific_public_conflict_test() ->
    ?assertEqual(
       {409, #{error => conflict_retry}},
       quod_client_result:http_error({error, conflict_retry})).

malformed_and_noncanonical_results_are_rejected_test() ->
    ?assertEqual({error, invalid_result},
                 quod_client_result:decode(term_to_binary(arbitrary))),
    Oversized = <<0:(?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES + 1)/unit:8>>,
    ?assertEqual({error, result_too_large},
                 quod_client_result:decode(Oversized)),
    ?assertEqual({error, invalid_result},
                 quod_client_result:encode({answers, -1, []})),
    GroupRef = {group, <<"quod:a">>, <<1:256>>, <<2:256>>, <<3:256>>,
                <<4:256>>},
    ?assertEqual(
       {error, invalid_result},
       quod_client_result:encode(
         {committed, [], {group_outcome, GroupRef, 1, []}})).

fixture() ->
    quod_ct:signed_goal_fixture(
      #{mode => read, goal_text => <<"lookup(X).">>}).

b64url(Bytes) -> base64:encode(Bytes, #{mode => urlsafe, padding => false}).

agent_ref(Ns, Anchor, N) ->
    {ok, #{blob := Blob}} = quod_agent_ref:from_text(
                              Ns, Anchor,
                              <<"human_user(", (integer_to_binary(N))/binary,
                                ").">>,
                              2),
    Blob.
