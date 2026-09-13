-module(quod_read_set_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-export([golden_consumer/1, golden_producer/1, produce/1, consume/1, mixed_consume/1]).

representation_and_size_test_() ->
    [?_test(begin
        Names = [iolist_to_binary(io_lib:format("s8_readset_size_~2..0B", [I]))
                 || I <- lists:seq(1, N)],
        Atoms = maps:from_list([{{binary_to_atom(Name, utf8), 1}, static} || Name <- Names]),
        Opaque = maps:from_list([{{{'$quod_symbol', Name}, 1}, static} || Name <- lists:reverse(Names)]),
        Mixed = maps:from_list([{{case I rem 2 of
                                  0 -> binary_to_atom(Name, utf8);
                                  1 -> {'$quod_symbol', Name}
                                 end, 1}, static}
                               || {I, Name} <- lists:enumerate(Names)]),
        {ok, Bytes} = quod_read_set:encode(Atoms),
        ?assertEqual({ok, Bytes}, quod_read_set:encode(Opaque)),
        ?assertEqual({ok, Bytes}, quod_read_set:encode(Mixed)),
        {ok, Pairs} = quod_wire_term:decode_canonical(Bytes, 100000),
        ?assertEqual(N, length(Pairs)),
        ?assert(quod_read_set:valid_pairs(Pairs))
    end) || N <- [2, 32, 33, 64]].

aliases_never_merge_or_drop_reads_test() ->
    Alias = {'$quod_symbol', <<"read_alias">>},
    Reads = #{{read_alias, 1} => static, {Alias, 1} => static},
    ?assertEqual({error, bad_term}, quod_read_set:encode(Reads)),
    ?assertNot(quod_diff:valid_read_check(Reads)),
    ?assertNot(quod_read_set:valid_pairs([{{read_alias, 1}, static}, {{Alias, 1}, static}])),
    ?assertNot(quod_read_set:valid_pairs([{{Alias, 1}, static}, {{read_alias, 1}, never_present}])).

same_name_distinct_arities_are_distinct_dependencies_test() ->
    Reads = #{{arity_key, 2} => {absent, 2},
              {{'$quod_symbol', <<"arity_key">>}, 1} => {present, 1}},
    ?assertMatch({ok, [{{_, 1}, {present, 1}}, {{_, 2}, {absent, 2}}]}, quod_read_set:pairs(Reads)),
    {ok, Pairs} = quod_read_set:pairs(Reads),
    ?assert(quod_read_set:valid_pairs(Pairs)).

wire_order_and_shape_are_checked_before_a_map_test() ->
    Good = [{{a, 1}, never_present}, {{b, 2}, static}],
    ?assert(quod_read_set:valid_pairs(Good)),
    lists:foreach(fun(Pairs) -> ?assertNot(quod_read_set:valid_pairs(Pairs)) end,
      [lists:reverse(Good), Good ++ Good, [hd(Good) | bad_tail],
       [{{a, -1}, static}], [{{a, 1}, staged}], [{{a, 1}, {present, -1}}],
       [{{{'$quod_symbol', <<255>>}, 1}, static}], not_pairs]),
    ?assertEqual(error, quod_read_set:pairs(not_a_map)).

utf8_order_preserves_atom_codepoint_order_test() ->
    Names = [<<>>, <<"z">>, <<"é"/utf8>>, <<"中"/utf8>>, <<"😀"/utf8>>],
    Atoms = maps:from_list([{{binary_to_atom(N, utf8), 1}, static} || N <- Names]),
    Opaque = maps:from_list([{{{'$quod_symbol', N}, 1}, static} || N <- Names]),
    Old = quod_wire_term:encode_canonical(maps:to_list(Atoms)),
    ?assertEqual(Old, quod_read_set:encode(Atoms)),
    ?assertEqual(Old, quod_read_set:encode(Opaque)).

signed_bad_order_is_refused_before_vocabulary_materializes_test() ->
    {ok, FixtureBytes} = file:read_file("test/fixtures/read-set174/golden-2.etf"),
    #{public_key := Pub} = F = binary_to_term(FixtureBytes, [safe]),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(12)),
    Names = [<<"readset_refusal_a_", Suffix/binary>>, <<"readset_refusal_z_", Suffix/binary>>],
    BadPairs = [{{{'$quod_symbol', Name}, 1}, static} || Name <- lists:reverse(Names)],
    {ok, ReadBytes} = quod_wire_term:encode_canonical(BadPairs),
    {ok, Plan} = quod_dtx:decode(maps:get(plan_bytes, F)),
    Core = (element(2, Plan))#{read_check := ReadBytes,
      conflict_descriptor := #{reads => [{Name, 1} || Name <- Names], writes => [], custody => []}},
    {ok, Signer} = test_signer(),
    Signature = quod_identity:sign(term_to_binary({<<"quod.dtx.plan">>, 8, Core}, [deterministic]), Signer),
    BadPlan = {quod_plan, Core, Pub, Signature},
    ?assert(quod_dtx:verify(BadPlan)),
    assert_unknown(Names),
    ?assertEqual({error, {protocol_error, bad_payload}}, quod_dtx:material(BadPlan)),
    assert_unknown(Names),
    {ok, Canonical} = quod_safe_term:decode_wrapped(maps:get(signed_bytes, F), 100000),
    {ok, Material} = quod_wire_term:encode_canonical({[], BadPairs}),
    {ok, BadBody} = quod_safe_term:encode_canonical(setelement(12, Canonical, Material), 100000),
    {ok, BadEnvelope} = quod_safe_term:encode_canonical(
      {submit, Pub, quod_identity:sign(BadBody, Signer), BadBody}, 100000),
    ?assertEqual({error, malformed_material},
      quod_transaction:decode_ledger_transaction(BadEnvelope, materialized)),
    assert_unknown(Names).

golden_and_two_vm_roundtrip_test_() ->
    {timeout, 90, fun() ->
        with_peer(fun(Producer) -> with_peer(fun(Consumer) ->
            lists:foreach(fun(N) ->
                {ok, Fixture} = file:read_file(filename:join(
                  ["test", "fixtures", "read-set174", "golden-" ++ integer_to_list(N) ++ ".etf"])),
                ?assertEqual(ok, peer:call(Producer, ?MODULE, golden_producer, [Fixture])),
                ?assertEqual(ok, peer:call(Consumer, ?MODULE, golden_consumer, [Fixture]))
            end, [2, 32]),
            lists:foreach(fun(N) ->
                Names = [<<"s8_two_vm_", (integer_to_binary(N))/binary, "_",
                           (integer_to_binary(I))/binary>> || I <- lists:seq(1, N)],
                Artifact = peer:call(Producer, ?MODULE, produce, [Names]),
                ?assertEqual(ok, peer:call(Consumer, ?MODULE, consume, [Artifact])),
                ?assertEqual(ok, peer:call(Consumer, ?MODULE, mixed_consume, [Artifact]))
            end, [2, 32, 33, 64])
        end) end)
    end}.

with_peer(Fun) ->
    {ok, Peer, _} = peer:start_link(#{connection => standard_io,
      args => ["+S", "2:2", "-pa" | code:get_path()]}),
    try Fun(Peer) after peer:stop(Peer) end.

golden_producer(FixtureBytes) ->
    #{public_key := _FixturePublicKey} = F = binary_to_term(FixtureBytes, [safe]),
    _ = [binary_to_atom(Name, utf8) || Name <- maps:get(names, F)],
    {ok, Plan} = quod_dtx:decode(maps:get(plan_bytes, F)),
    {ok, Material} = quod_dtx:material(Plan),
    ?assertEqual({ok, maps:get(read_bytes, F)}, quod_read_set:encode(maps:get(read_check, Material))),
    {ok, Tx} = quod_transaction:decode_ledger_transaction(maps:get(transaction_bytes, F), materialized),
    {ok, PubSeed} = test_signer(),
    Session = quod_proof_session:start(quod_ct:committed_kb([]),
      #{read_set => true, signer => PubSeed, proof_context => {origin, golden174}}),
    try
        ok = quod_proof_session:absorb_read_set(Session, maps:get(read_check, Material)),
        Core = element(2, Plan),
        ?assertEqual({ok, Plan}, quod_dtx:seal_session(Session,
          maps:with([target, base_height, proof_id, origin, principal, request_binding], Core)))
    after quod_proof_session:stop(Session)
    end,
    ?assertEqual({ok, Tx}, quod_transaction:sign(maps:get(binding, F),
      Tx#transaction{sig = none, signed_bytes = none}, PubSeed)),
    check_transaction(F, Tx),
    ?assertEqual(maps:get(plan_digest, F), quod_dtx:digest(Plan)),
    ?assertEqual({ok, maps:get(plan_bytes, F)}, quod_dtx:encode(Plan)),
    ok.

golden_consumer(FixtureBytes) ->
    warm(),
    F = binary_to_term(FixtureBytes, [safe]),
    Names = maps:get(names, F),
    assert_unknown(Names),
    %% Warm the exact decoding path, including lazy crypto/runtime modules,
    %% without ever materializing any fixture vocabulary.
    golden_consume(F),
    Before = erlang:system_info(atom_count),
    golden_consume(F),
    ?assertEqual(Before, erlang:system_info(atom_count)),
    assert_unknown(Names),
    ok.

golden_consume(F) ->
    {ok, Tx} = quod_transaction:decode_ledger_transaction(maps:get(transaction_bytes, F), wrapped),
    check_transaction(F, Tx),
    {ok, Plan} = quod_dtx:decode(maps:get(plan_bytes, F)),
    ?assertEqual({ok, maps:get(plan_bytes, F)}, quod_dtx:encode(Plan)),
    {ok, Pairs} = quod_wire_term:decode_canonical(quod_dtx:read_check_bytes(Plan), 100000),
    ?assert(quod_read_set:valid_pairs(Pairs)),
    ?assertEqual({ok, maps:get(read_bytes, F)}, quod_read_set:encode(maps:from_list(Pairs))).

check_transaction(F, Tx) ->
    ?assertEqual(maps:get(semantic_id, F), Tx#transaction.tx_id),
    {Ns, Anchor, _} = Binding = maps:get(binding, F),
    ?assert(quod_transaction:valid_id({Ns, Anchor}, Tx)),
    ?assertEqual(maps:get(signature, F), Tx#transaction.sig),
    ?assertEqual(maps:get(signed_bytes, F), Tx#transaction.signed_bytes),
    ?assertEqual({ok, maps:get(signed_bytes, F)}, quod_transaction:bytes(Binding, Tx)),
    ?assertEqual({ok, maps:get(transaction_bytes, F)}, quod_transaction:encode_ledger_transaction(Tx)).

produce(Names) ->
    warm(),
    Reads = maps:from_list([{{binary_to_atom(Name, utf8), 1}, static} || Name <- Names]),
    {ok, Signer = #{pubkey := Pub}} = test_signer(),
    Target = {<<"quod:read-set-cross-vm">>, <<11:256>>},
    Binding = {element(1, Target), element(2, Target), <<13:256>>},
    {ok, Goal} = quod_durable_term:encode_goal(true),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Tx = quod_transaction:bind_id(Target, #transaction{
      tx_id = <<>>, origin = Target, proof_id = <<21:256>>, plan_digest = <<22:256>>,
      goal = Goal, result = Result, diff = [], read_check = Reads,
      author = Pub, author_seq = 1, submitted_at = 1750000000000}),
    {ok, Signed} = quod_transaction:sign(Binding, Tx, Signer),
    {ok, Bytes} = quod_transaction:encode_ledger_transaction(Signed),
    #{names => Names, binding => Binding, semantic_id => Signed#transaction.tx_id,
      signature => Signed#transaction.sig, signed_bytes => Signed#transaction.signed_bytes,
      transaction_bytes => Bytes}.

consume(F) ->
    consume(F, maps:get(names, F)).

mixed_consume(F) ->
    Names = maps:get(names, F),
    %% A known *later* name moves ahead of unknown tuple symbols under the
    %% rejected native term/map order. All-opaque keys alone miss this bug.
    Known = lists:last(lists:sort(Names)),
    _ = binary_to_atom(Known, utf8),
    consume(F, lists:delete(Known, Names)).

consume(F, Unknown) ->
    warm(),
    Names = maps:get(names, F), assert_unknown(Unknown),
    {ok, WarmTx} = quod_transaction:decode_ledger_transaction(maps:get(transaction_bytes, F), wrapped),
    check_transaction(F, WarmTx),
    Before = erlang:system_info(atom_count),
    {ok, Tx} = quod_transaction:decode_ledger_transaction(maps:get(transaction_bytes, F), wrapped),
    check_transaction(F, Tx),
    ?assertEqual(length(Names), map_size(Tx#transaction.read_check)),
    ?assertEqual(Before, erlang:system_info(atom_count)),
    assert_unknown(Unknown),
    ok.

warm() ->
    {ok, _} = application:ensure_all_started(crypto),
    _ = [code:ensure_loaded(M) || M <- [quod_transaction, quod_dtx, quod_read_set,
                                        quod_diff, quod_wire_term, quod_safe_term]],
    ok.

assert_unknown(Names) ->
    [?assertError(badarg, binary_to_existing_atom(Name, utf8)) || Name <- Names], ok.

test_signer() ->
    {Pub, Seed} = crypto:generate_key(eddsa, ed25519, <<177:256>>),
    {ok, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}.
