-module(quod_client_result_tests).
-include("retired_presentation_sizes.hrl").

-include_lib("eunit/include/eunit.hrl").
-include("quod_client_goal_limits.hrl").
-include("quod_proof_limits.hrl").

signed_read_dependencies_survive_answers_failure_and_errors_test() ->
    Evidence = maps:get(evidence,fixture()),
    Deps = [{<<"a">>,<<1:256>>,7,[{{policy,1},{present,3}}]},{<<"b">>,<<2:256>>,9,[]}],
    lists:foreach(fun(Raw) ->
        Outcome = quod_client_result:normalize(Evidence,Raw),
        Read = {read,Deps,Outcome},
        ?assertEqual(Read,quod_client_result:normalize(Evidence,{read,Deps,Raw})),
        {ok,Blob} = quod_client_result:encode(Read),
        ?assertEqual({ok,Read},quod_client_result:decode(Blob)),
        {_,Json} = quod_client_result:http_normalized(Evidence,Read),
        ?assertEqual([#{ns => N,genesis_anchor => b64url(A),height => integer_to_binary(H)}
                      || {N,A,H,_} <- Deps],maps:get(dependencies,Json))
    end,[{ok,[#{0 => bob}],7},fail,{fail,[denied]},{error,read_only}]),
    ?assertMatch({ok, _}, quod_client_result:encode({read, [{binary:copy(<<"n">>,1025),<<1:256>>,0,[]}], fail})),
    BadDeps = [[{<<"a">>,<<1:256>>,7,[{{policy,1},bad_token}]}],lists:reverse(Deps),Deps++Deps,[{<<"a">>,<<1:256>>,-1,[]}],
               [{<<"a">>,<<1:256>>,1 bsl 64,[]}],[{<<"a">>,<<1>>,1,[]}],
               [{<<>>,<<1:256>>,0,[]}],
               [{<<"a">>,<<1:256>>,0,[]},{<<"a">>,<<2:256>>,0,[]}]],
    [?assertEqual({error,invalid_result},quod_client_result:encode({read,D,fail})) || D <- BadDeps],
    [?assertEqual({error,invalid_result},quod_client_result:encode({read,Deps,R})) || R <-
        [{read,Deps,fail},stopped,{pending,{transaction,<<"a">>,<<1:256>>,<<2:256>>}}]].

read_dependency_heights_are_lossless_json_test() ->
    Evidence = maps:get(evidence,fixture()),
    %% A browser Number cannot distinguish these last two uint64 values.
    lists:foreach(fun(Height) ->
        Read = {read,[{<<"a">>,<<1:256>>,Height,[]}],fail},
        {200,Body} = quod_client_result:http_normalized(Evidence,Read),
        #{<<"dependencies">> := [#{<<"height">> := Decimal}]} =
            json:decode(iolist_to_binary(json:encode(Body))),
        ?assertEqual(integer_to_binary(Height),Decimal),
        ?assertEqual(Height,binary_to_integer(Decimal))
    end,[0,9007199254740991,9007199254740993,
          18446744073709551614,18446744073709551615]).

many_dependencies_and_answers_keep_their_exact_values_test() ->
    Evidence = maps:get(evidence, fixture()),
    Deps = [{<<I:32>>, <<I:256>>, I, []} || I <- lists:seq(1, 32)],
    Raw = {read, Deps, {ok, lists:duplicate(10001, #{}), 7}},
    Read = quod_client_result:normalize(Evidence, Raw),
    ?assertMatch({read, Deps, {answers, 7, _}}, Read),
    {read, _, {answers, _, Answers}} = Read,
    ?assertEqual(10001, length(Answers)),
    {ok, Bytes} = quod_client_result:encode(Read),
    ?assertEqual({ok, Read}, quod_client_result:decode(Bytes)).

material_budget_errors_report_the_actual_resource_test() ->
    lists:foreach(fun({Kind, Resource}) ->
        Error = {error, {material_limit, Kind, Resource, 9007199254740993, 1024}},
        ?assertEqual(Error, quod_client_result:normalize(#{}, Error)),
        {ok, Bytes} = quod_client_result:encode(Error),
        ?assertEqual({ok, Error}, quod_client_result:decode(Bytes)),
        ?assertEqual({413, #{error => material_limit, kind => Kind,
            resource => Resource, actual => <<"9007199254740993">>, limit => <<"1024">>}},
            quod_client_result:http_normalized(#{}, Error))
    end, [{proof, heap_bytes}, {plan, operations}, {plan, reads},
          {founding, symbols}, {founding, canonical_bytes}]),
    lists:foreach(fun(Reason) ->
        ?assertEqual({error, proof_unavailable},
                     quod_client_result:normalize(#{}, {error, Reason})),
        ?assertEqual({error, invalid_result}, quod_client_result:encode({error, Reason}))
    end, [{material_limit, private_kind, heap_bytes, 2, 1},
          {material_limit, proof, private_resource, 2, 1},
          {material_limit, proof, heap_bytes, 1, 2}]).

invalid_material_policy_survives_the_client_boundary_test() ->
    lists:foreach(fun(Kind) ->
        Error = {error, {invalid_material_policy, Kind}},
        ?assertEqual(Error, quod_client_result:normalize(#{}, Error)),
        {ok, Bytes} = quod_client_result:encode(Error),
        ?assertEqual({ok, Error}, quod_client_result:decode(Bytes)),
        ?assertEqual({500, #{error => invalid_material_policy, kind => Kind}},
                     quod_client_result:http_normalized(#{}, Error))
    end, [founding, plan, proof]),
    Private = {error, {invalid_material_policy, private_kind}},
    ?assertEqual({error, proof_unavailable}, quod_client_result:normalize(#{}, Private)),
    ?assertEqual({error, invalid_result}, quod_client_result:encode(Private)).

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

signed_binding_preserves_binary_identity_and_numeric_values_test() ->
    Evidence = maps:get(evidence, fixture()),
    Anchor = <<0:248, 255>>,
    Value = {depicts, <<"lobby">>, Anchor, {user, binary:copy(<<"x">>, 32)}},
    Result = quod_client_result:normalize(Evidence, {ok, [#{0 => Value}], 7}),
    {200, #{bindings := [#{<<"X">> := Text}]}} =
        quod_client_result:http_normalized(Evidence, Result),
    ?assertEqual(nomatch, binary:match(Text, <<"kp_">>)),
    {ok, #{goal := Parsed}} = quod_client_goal_parser:parse(<<Text/binary, ".">>, 2),
    ?assertEqual(quod_wire_term:encode_canonical(Value),
                 quod_wire_term:encode_canonical(Parsed)),
    ?assertEqual(<<"transform(-150,0,0,0,0,0)">>,
                 quod_client_goal_parser:value_text({transform, -150, 0, 0, 0, 0, 0})),
    ?assertEqual(<<"[65,66,67]">>, quod_client_goal_parser:value_text("ABC")).

complete_results_and_dependencies_have_no_second_allocation_test() ->
    Evidence=maps:get(evidence,fixture()),
    Value=binary:copy(<<$x>>,600000),
    Deps=[{<<"a">>,<<1:256>>,7,[]}],
    lists:foreach(fun(Raw) ->
        Result=quod_client_result:normalize(Evidence,{read,Deps,Raw}),
        ?assertMatch({read,Deps,{answers,7,_}},Result),
        {ok,Bytes}=quod_client_result:encode(Result),
        ?assertEqual({ok,Result},quod_client_result:decode(Bytes))
    end,[{ok,[#{0=>Value}],7},{ok,lists:duplicate(50,#{0=>binary:part(Value,0,12000)}),7}]),
    ?assertEqual({read,Deps,{error,proof_unavailable}},
        quod_client_result:normalize(Evidence,{read,Deps,{ok,[#{0=>self()}],7}})),
    LargeDependency = {read,[{Value,<<1:256>>,7,[]}],fail},
    ?assertEqual(LargeDependency, quod_client_result:normalize(Evidence,LargeDependency)),
    {ok, LargeBytes} = quod_client_result:encode(LargeDependency),
    ?assertEqual({ok,LargeDependency}, quod_client_result:decode(LargeBytes)),
    ?assertEqual({read,[],{error,proof_unavailable}},
        quod_client_result:normalize(Evidence,{read,[{<<"a">>,bad_anchor,7,[]}],fail})).

transient_bindings_use_the_complete_reply_contract_test() ->
    Evidence = maps:get(evidence, fixture()),
    Value = binary:copy(<<"x">>, ?LEGACY_MAX_DURABLE_RESULT_BYTES + 1),
    Answers = quod_client_result:normalize(Evidence, {ok, [#{0 => Value}], 7}),
    ?assertMatch({answers, 7, [_]}, Answers),
    {answers, _, [Binding]} = Answers,
    ?assertEqual({ok, [{<<"X">>, Value}]}, quod_durable_term:decode_result(Binding)),
    ?assertEqual({ok, [{<<"X">>, Value}]}, quod_client_result:decode_binding(Binding)),
    Preview = quod_client_result:normalize(Evidence,
        {solution, <<7:256>>, #{0 => Value}, 7}),
    ?assertEqual({solution, <<7:256>>, 7, Binding}, Preview),
    lists:foreach(fun(Result) ->
        {ok, ResultBlob} = quod_client_result:encode(Result),
        {ok, Frame} = quod_client_goal_endpoint:encode_response(
            {result, <<8:128>>, ResultBlob}),
        ?assertEqual({ok, {result, <<8:128>>, ResultBlob}},
                     quod_client_goal_endpoint:decode_response(Frame)),
        ?assertEqual({ok, Result}, quod_client_result:decode(ResultBlob)),
        {200, #{bindings := [#{<<"X">> := Text}]}} =
            quod_client_result:http_normalized(Evidence, Result),
        ?assertEqual(quod_client_goal_parser:value_text(Value), Text)
    end, [Answers, Preview]).

large_cursor_answers_preserve_invalid_result_refusal_test() ->
    Evidence=maps:get(evidence,fixture()),Value=binary:copy(<<$x>>,600000),
    ?assertMatch({solution,_,7,_},quod_client_result:normalize(Evidence,{solution,<<7:256>>,#{0=>Value},7})),
    ?assertEqual({error,result_too_large},quod_client_result:normalize(Evidence,{error,{too_large,result}})),
    ?assertEqual({error,invalid_result},quod_client_result:encode({answers,7,[Value]})),
    ?assertEqual({error,proof_unavailable},quod_client_result:normalize(Evidence,{ok,[#{0=>self()}],7})).

client_binding_validation_retains_canonical_name_rules_test() ->
    lists:foreach(fun(Pairs) ->
        {ok, Blob} = quod_wire_term:encode_canonical(Pairs),
        ?assertEqual({error, invalid_result}, quod_client_result:decode_binding(Blob)),
        ?assertEqual({error, invalid_result}, quod_durable_term:decode_result(Blob)),
        ?assertEqual({error, invalid_result}, quod_client_result:encode({answers, 7, [Blob]}))
    end, [[{<<"same">>, 1}, {<<"same">>, 2}], [{<<>>, value}],
          [{<<"z">>, 1}, {<<"a">>, 2}]]).

prepared_budget_error_survives_signed_normalization_and_http_test() ->
    Evidence = maps:get(evidence, fixture()),
    lists:foreach(fun({Actual, Limit}) ->
        Error = {error, {effect_custody_limit, prepared_bytes, Actual, Limit}},
        ?assertEqual(Error, quod_client_result:normalize(Evidence, Error)),
        {ok, Bytes} = quod_client_result:encode(Error),
        ?assertEqual({ok, Error}, quod_client_result:decode(Bytes)),
        ?assertEqual({413, #{error => effect_custody_limit, resource => prepared_bytes,
                            actual => integer_to_binary(Actual), limit => integer_to_binary(Limit)}},
                     quod_client_result:http_normalized(Evidence, Error))
    end, [{304774, 262144}, {(1 bsl 64) - 1, (1 bsl 53) + 1}]),
    Bad = {error, {effect_custody_limit, prepared_bytes, 1, -1}},
    ?assertEqual({error, proof_unavailable}, quod_client_result:normalize(Evidence, Bad)),
    ?assertEqual({error, invalid_result}, quod_client_result:encode(Bad)).

conflict_retry_is_a_specific_public_conflict_test() ->
    ?assertEqual(
       {409, #{error => conflict_retry}},
       quod_client_result:http_error({error, conflict_retry})).

malformed_and_noncanonical_results_are_rejected_test() ->
    ?assertEqual({error, invalid_result},
                 quod_client_result:decode(term_to_binary(arbitrary))),
    Oversized = <<0:600000/unit:8>>,
    ?assertEqual({error, invalid_result},
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

result_delivery_failure_preserves_recovery_http_contract_test() ->
    ?assertEqual({503, #{error => result_too_large}},
                 quod_client_result:http_error({error, result_too_large})),
    ?assertMatch({413, #{error := material_limit}},
                 quod_client_result:http_error({error, {material_limit, proof, answer_bytes, 10, 9}})).
