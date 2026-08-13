-module(quod_effect_journal_tests).
-moduledoc false.

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(ROOT_NS, <<"quod:root">>).
-define(MAGIC, 16#51454A31).

unactivated_binding_is_rejected_on_restart_test() ->
    with_snapshot(
      bound,
      fun(Dir, Effect, _Admission, _Transaction, Ref) ->
          {ok, Pid} = quod_effect_journal:start_link(#{data_dir => Dir}),
          unlink(Pid),
          EffectId = quod_effect:effect_id(Effect),
          ?assertMatch(
             {ok, #{state := retired, result := not_activated,
                    ref := Ref}},
             quod_effect_journal:status(EffectId)),
          ?assertMatch(
             {ok, #{state := retired, result := not_activated}},
             quod_effect_journal:status_ref(Ref)),
          ?assertEqual({error, not_activated},
                       quod_effect_journal:handoff(EffectId)),
          stop(Pid),

          %% The rejection itself is durable and the private bytes were
          %% compacted, so another restart cannot resurrect the action.
          {ok, Pid2} = quod_effect_journal:start_link(#{data_dir => Dir}),
          unlink(Pid2),
          ?assertMatch(
             {ok, #{state := retired, result := not_activated}},
             quod_effect_journal:status(EffectId)),
          stop(Pid2)
      end).

activated_binding_redrives_the_exact_transaction_test() ->
    with_snapshot(
      prepared,
      fun(Dir, Effect, Admission, Transaction, _Ref) ->
          Parent = self(),
          Fake = spawn(fun() -> fake_simplex(Parent) end),
          receive {fake_simplex_ready, Fake} -> ok after 1000 -> error(timeout) end,
          try
              {ok, Pid} = quod_effect_journal:start_link(#{data_dir => Dir}),
              unlink(Pid),
              EffectId = quod_effect:effect_id(Effect),
              ?assertEqual(ok, quod_effect_journal:handoff(EffectId)),
              receive
                  {effect_handoff, Admission, Transaction} -> ok
              after 1000 ->
                  error(handoff_timeout)
              end,
              ?assertMatch(
                 {ok, #{state := handed_off}},
                 quod_effect_journal:status(EffectId)),
              stop(Pid)
          after
              exit(Fake, kill)
          end
      end).

duplicate_reference_returns_conflict_without_killing_journal_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Dir = filename:join(
            "/tmp",
            "quod_effect_journal_duplicate_" ++
                integer_to_list(erlang:unique_integer([positive]))),
    try
        {Effect1, _Admission1, _Transaction1, Ref, Row1} = fixture(bound),
        {Effect20, _Admission2, _Transaction2, _Ref2, Row20} = fixture(bound),
        Effect2 = setelement(6, Effect20, hash(3003)),
        Row21 = setelement(3, Row20, quod_effect:effect_id(Effect2)),
        Row22 = setelement(4, Row21, Effect2),
        Row2 = setelement(9, Row22, Ref),
        ?assertNotEqual(quod_effect:effect_id(Effect1),
                        quod_effect:effect_id(Effect2)),
        write_snapshot(Dir, [Row1, Row2]),
        {ok, Pid} = quod_effect_journal:start_link(#{data_dir => Dir}),
        unlink(Pid),
        ?assertEqual(
           {error, effect_journal_conflict},
           quod_effect_journal:status_ref(Ref)),
        ?assert(is_process_alive(Pid)),
        stop(Pid)
    after
        _ = file:del_dir_r(Dir)
    end.

committed_descriptor_conflict_retires_row_without_killing_journal_test() ->
    with_snapshot(
      prepared,
      fun(Dir, Effect, _Admission, _Transaction, Ref) ->
          {ok, Pid} = quod_effect_journal:start_link(#{data_dir => Dir}),
          unlink(Pid),
          EffectId = quod_effect:effect_id(Effect),
          <<First, Rest/binary>> = quod_effect:request_digest(Effect),
          Conflicting = setelement(10, Effect, <<(First bxor 1), Rest/binary>>),
          ?assert(quod_effect:validate(Conflicting)),
          quod_effect_journal:release_applied(2, [Conflicting]),
          ?assertMatch(
             {ok, #{state := retired,
                    result := effect_journal_conflict,
                    ref := Ref}},
             quod_effect_journal:status(EffectId)),
          ?assert(is_process_alive(Pid)),
          stop(Pid)
      end).

with_snapshot(State, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Dir = filename:join(
            "/tmp",
            "quod_effect_journal_" ++
                integer_to_list(erlang:unique_integer([positive]))),
    try
        ?assertEqual(undefined,
                     quod_reg:where({quod_effect_journal, node})),
        ?assertEqual(undefined,
                     quod_reg:where({quod_simplex, ?ROOT_NS})),
        {Effect, Admission, Transaction, Ref, Row} = fixture(State),
        write_snapshot(Dir, Row),
        Fun(Dir, Effect, Admission, Transaction, Ref)
    after
        _ = file:del_dir_r(Dir)
    end.

fixture(State) ->
    {Pub, _Seed} = quod_identity:generate(),
    Anchor = hash(1),
    Admission = hash(2),
    {ok, ActionBytes} = quod_durable_term:encode_goal(
                          {create_ontology, <<"effect:test">>, []}),
    {ok, DesiredBytes} = quod_durable_term:encode_goal(
                           {ontology_hosted, <<"effect:test">>}),
    PreparedBytes = term_to_binary({test_prepared, 1}, [deterministic]),
    Effect = {quod_direct_effect, 1, local_durable,
              ontology_lifecycle, create, hash(3), Pub,
              {node, Pub}, {<<"effect:test">>, hash(4)},
              crypto:hash(sha256, ActionBytes),
              crypto:hash(sha256, PreparedBytes)},
    {ok, Goal} = quod_durable_term:encode_goal(
                   {create_ontology, <<"effect:test">>, []}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Transaction = quod_transaction:bind_id(
                    {?ROOT_NS, Anchor},
                    #transaction{origin = {?ROOT_NS, Anchor},
                                 proof_id = hash(5),
                                 plan_digest = hash(6),
                                 goal = Goal, result = Result,
                                 diff = [], read_check = #{},
                                 effects = [Effect], author = Pub,
                                 author_seq = 0, submitted_at = 10,
                                 sig = none}),
    TxId = Transaction#transaction.tx_id,
    Ref = {transaction, ?ROOT_NS, Anchor, TxId},
    Row = {quod_effect_row, 1, quod_effect:effect_id(Effect), Effect,
           ActionBytes, DesiredBytes, PreparedBytes,
           term_to_binary(Transaction, [deterministic]), Ref, Admission,
           State, 0, none},
    {Effect, Admission, Transaction, Ref, Row}.

write_snapshot(Dir, Row) ->
    Rows = case Row of
               [_ | _] -> Row;
               _ -> [Row]
           end,
    Path = filename:join(
             quod_ledger_store:ns_dir(Dir, ?ROOT_NS),
             "direct_effects.qej"),
    ok = filelib:ensure_dir(Path),
    Payload = term_to_binary(
                {quod_effect_journal, 1, Rows}, [deterministic]),
    Digest = crypto:hash(sha256, Payload),
    Bytes = <<?MAGIC:32/unsigned-big,
              (byte_size(Payload)):32/unsigned-big,
              Digest/binary, Payload/binary>>,
    ok = file:write_file(Path, Bytes).

fake_simplex(Parent) ->
    true = quod_reg:reg({quod_simplex, ?ROOT_NS}),
    Parent ! {fake_simplex_ready, self()},
    fake_simplex_loop(Parent).

fake_simplex_loop(Parent) ->
    receive
        {'$gen_call', From, {handoff_effect, Admission, Transaction}} ->
            Parent ! {effect_handoff, Admission, Transaction},
            gen:reply(From, ok),
            fake_simplex_loop(Parent);
        _Other ->
            fake_simplex_loop(Parent)
    end.

stop(Pid) ->
    MRef = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 1000 -> error(timeout) end.

hash(N) -> crypto:hash(sha256, term_to_binary(N, [deterministic])).
