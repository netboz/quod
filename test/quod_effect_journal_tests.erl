-module(quod_effect_journal_tests).
-moduledoc false.

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(ROOT_NS, <<"quod:root">>).
-define(MAGIC, 16#51454A31).

capacity_is_projected_and_restart_durable_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Dir = filename:join(
            "/tmp",
            "quod_effect_capacity_" ++
                integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, Pid} = quod_effect_journal:start_link(#{data_dir => Dir}),
        unlink(Pid),
        ?assertEqual(unconfigured, quod_effect_journal:capacity()),
        ?assertEqual({error, unavailable},
                     quod_effect_journal:reserve(self())),
        ?assertEqual({error, invalid_capacity},
                     quod_effect_journal:configure_capacity(-1)),
        ok = quod_effect_journal:configure_capacity(1),
        {ok, Token1} = quod_effect_journal:reserve(self()),
        ?assertMatch(
           #{capacity := 1, active := 0, reservations := 1,
             terminal := 0},
           quod_effect_journal:stats()),
        ?assertEqual({error, busy}, quod_effect_journal:reserve(self())),
        ok = quod_effect_journal:release_reservation(Token1),
        ok = quod_effect_journal:configure_capacity(unlimited),
        {ok, Token2} = quod_effect_journal:reserve(self()),
        {ok, Token3} = quod_effect_journal:reserve(self()),
        ok = quod_effect_journal:release_reservation(Token2),
        ok = quod_effect_journal:release_reservation(Token3),
        stop(Pid),
        {ok, Pid2} = quod_effect_journal:start_link(#{data_dir => Dir}),
        unlink(Pid2),
        ?assertEqual(unlimited, quod_effect_journal:capacity()),
        stop(Pid2)
    after
        _ = file:del_dir_r(Dir)
    end.

lowering_capacity_keeps_active_custody_test() ->
    with_snapshot(
      prepared,
      fun(Dir, Effect, _Admission, _Transaction, _Ref) ->
          {ok, Pid} = quod_effect_journal:start_link(#{data_dir => Dir}),
          unlink(Pid),
          EffectId = quod_effect:effect_id(Effect),
          ?assertMatch({ok, #{state := prepared}},
                       quod_effect_journal:status(EffectId)),
          ok = quod_effect_journal:configure_capacity(0),
          ?assertMatch(
             #{capacity := 0, active := 1, reservations := 0},
             quod_effect_journal:stats()),
          ?assertMatch({ok, #{state := prepared}},
                       quod_effect_journal:status(EffectId)),
          ?assertEqual({error, busy}, quod_effect_journal:reserve(self())),
          stop(Pid)
      end).

superseded_snapshot_version_is_identified_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Dir = filename:join(
            "/tmp",
            "quod_effect_old_format_" ++
                integer_to_list(erlang:unique_integer([positive]))),
    Path = filename:join(Dir, "direct_effects.qej"),
    try
        ok = filelib:ensure_dir(Path),
        Payload = term_to_binary(
                    {quod_effect_journal, 1, []}, [deterministic]),
        Digest = crypto:hash(sha256, Payload),
        Bytes = <<?MAGIC:32/unsigned-big,
                  (byte_size(Payload)):32/unsigned-big,
                  Digest/binary, Payload/binary>>,
        ok = file:write_file(Path, Bytes),
        PreviousTrapExit = process_flag(trap_exit, true),
        try
            ?assertMatch(
               {error, {{effect_journal_format_unsupported, 1}, _}},
               quod_effect_journal:start_link(#{data_dir => Dir}))
        after
            process_flag(trap_exit, PreviousTrapExit)
        end
    after
        _ = file:del_dir_r(Dir)
    end.

prepared_recovery_may_restore_genesis_atoms_test() ->
    %% A prepared genesis can contain an atom which existed in the authoring
    %% VM but not after a full restart. Build such an external term without
    %% interning its replacement name first, then prove recovery accepts it.
    Placeholder = <<"qej_placeholderx">>,
    FreshName = <<"qej_", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>,
    ?assertException(error, badarg,
                     binary_to_existing_atom(FreshName, utf8)),
    Prepared =
        {prepared_lifecycle, create, <<"effect:atom-recovery">>, hash(9001),
         #{qej_placeholderx => true}, created},
    {ok, Encoded0} = quod_ontology:prepared_bytes(Prepared),
    Encoded = binary:replace(Encoded0, Placeholder, FreshName, [global]),
    ?assertNotEqual(Encoded0, Encoded),
    ?assertMatch({ok, {prepared_lifecycle, create,
                      <<"effect:atom-recovery">>, _, _, created}},
                 quod_ontology:decode_prepared(Encoded)).

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

permanent_handoff_error_retires_instead_of_retrying_test() ->
    with_snapshot(
      prepared,
      fun(Dir, Effect, _Admission, _Transaction, Ref) ->
          Parent = self(),
          Fake = spawn(fun() -> fake_simplex(Parent, {error, bad_change}) end),
          receive {fake_simplex_ready, Fake} -> ok
          after 1000 -> error(fake_simplex_timeout)
          end,
          try
              {ok, Pid} = quod_effect_journal:start_link(#{data_dir => Dir}),
              unlink(Pid),
              EffectId = quod_effect:effect_id(Effect),
              quod_effect_journal:reconcile(),
              ok = wait_effect_state(EffectId, retired, 1000),
              ?assertMatch(
                 {ok, #{state := retired, result := bad_change, ref := Ref}},
                 quod_effect_journal:status(EffectId)),
              stop(Pid),
              {ok, Pid2} = quod_effect_journal:start_link(#{data_dir => Dir}),
              unlink(Pid2),
              ?assertMatch(
                 {ok, #{state := retired, result := bad_change}},
                 quod_effect_journal:status(EffectId)),
              stop(Pid2)
          after
              exit(Fake, kill)
          end
      end).

prepared_binding_survives_namespace_restart_gap_test() ->
    with_snapshot(
      prepared,
      fun(Dir, Effect, _Admission, _Transaction, Ref) ->
          %% The node-wide journal starts before dynamically hosted ontologies
          %% are restored. A missing Simplex is temporary unavailability, not
          %% proof that the durable author admission was retired.
          {ok, Pid} = quod_effect_journal:start_link(#{data_dir => Dir}),
          unlink(Pid),
          try
              1 = erlang:trace(Pid, true, [procs]),
              quod_effect_journal:reconcile(),
              Worker =
                  receive
                      {trace, Pid, spawn, Spawned, _Mfa} -> Spawned
                  after 1000 -> error(reconcile_not_started)
                  end,
              MRef = monitor(process, Worker),
              receive
                  {'DOWN', MRef, process, Worker, _} -> ok
              after 1000 -> error(reconcile_not_finished)
              end,
              ok = wait_reconcile_idle(Pid, 100),
              EffectId = quod_effect:effect_id(Effect),
              ?assertEqual({error, unavailable},
                           quod_effect_journal:handoff(EffectId)),
              ?assertMatch(
                 {ok, #{state := prepared, result := none, ref := Ref}},
                 quod_effect_journal:status(EffectId))
          after
              _ = erlang:trace(Pid, false, [procs]),
              stop(Pid)
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

committed_outcome_waits_for_ordered_projection_test() ->
    with_snapshot(
      handed_off,
      fun(Dir, Effect, _Admission, _Transaction, Ref) ->
          Parent = self(),
          Prolog = spawn(fun() -> fake_prolog(Parent, Ref, 2) end),
          Runtime = spawn(fun() -> fake_runtime(Parent, 1) end),
          receive {fake_prolog_ready, Prolog} -> ok
          after 1000 -> error(fake_prolog_timeout)
          end,
          receive {fake_runtime_ready, Runtime} -> ok
          after 1000 -> error(fake_runtime_timeout)
          end,
          try
              {ok, Pid} = quod_effect_journal:start_link(#{data_dir => Dir}),
              unlink(Pid),
              try
                  EffectId = quod_effect:effect_id(Effect),
                  quod_effect_journal:reconcile(),
                  receive {outcome_queried, Ref} -> ok
                  after 1000 -> error(outcome_query_timeout)
                  end,
                  receive {frontier_queried, Runtime, 1} -> ok
                  after 1000 -> error(frontier_query_timeout)
                  end,
                  ok = wait_reconcile_idle(Pid, 1000),
                  ?assertMatch({ok, #{state := handed_off, height := 0}},
                               quod_effect_journal:status(EffectId)),

                  Runtime ! {set_frontier, self(), 2},
                  receive {frontier_set, Runtime, 2} -> ok
                  after 1000 -> error(frontier_update_timeout)
                  end,
                  quod_effect_journal:reconcile(),
                  receive {outcome_queried, Ref} -> ok
                  after 1000 -> error(second_outcome_query_timeout)
                  end,
                  receive {frontier_queried, Runtime, 2} -> ok
                  after 1000 -> error(second_frontier_query_timeout)
                  end,
                  ok = wait_reconcile_idle(Pid, 1000),
                  %% The fixture's prepared bytes are deliberately synthetic.
                  %% Once the ordered projection reaches height 2, execution
                  %% is released and therefore ends in this stable terminal
                  %% state; observing the brief `committed` state was a race.
                  ok = wait_effect_state(EffectId, operator_error, 1000),
                  ?assertMatch({ok, #{state := operator_error, height := 2,
                                      result := corrupt_prepared_effect}},
                               quod_effect_journal:status(EffectId))
              after
                  stop(Pid)
              end
          after
              exit(Prolog, kill),
              exit(Runtime, kill)
          end
      end).

stale_reconcile_cannot_demote_terminal_row_test() ->
    with_snapshot(
      handed_off,
      fun(Dir, Effect, _Admission, _Transaction, Ref) ->
          Parent = self(),
          Prolog = spawn(fun() -> fake_paused_prolog(Parent, Ref, 2) end),
          Runtime = spawn(fun() -> fake_runtime(Parent, 2) end),
          receive {fake_prolog_ready, Prolog} -> ok
          after 1000 -> error(fake_prolog_timeout)
          end,
          receive {fake_runtime_ready, Runtime} -> ok
          after 1000 -> error(fake_runtime_timeout)
          end,
          try
              {ok, Pid} = quod_effect_journal:start_link(#{data_dir => Dir}),
              unlink(Pid),
              EffectId = quod_effect:effect_id(Effect),
              try
                  quod_effect_journal:reconcile(),
                  receive {outcome_waiting, Prolog, Ref} -> ok
                  after 1000 -> error(outcome_query_timeout)
                  end,

                  %% Model the live executor winning while the worker still
                  %% holds its older handed-off snapshot. Terminal compaction
                  %% has already discarded the private payload at this point.
                  _ = sys:replace_state(
                        Pid,
                        fun(S0) ->
                            Rows0 = element(4, S0),
                            Row0 = maps:get(EffectId, Rows0),
                            Row1 = setelement(3, Row0, <<>>),
                            Row2 = setelement(4, Row1, <<>>),
                            Row3 = setelement(5, Row2, <<>>),
                            Row4 = setelement(6, Row3, <<>>),
                            Row5 = setelement(9, Row4, applied),
                            Row6 = setelement(10, Row5, 2),
                            Row7 = setelement(11, Row6, ok),
                            setelement(4, S0, Rows0#{EffectId => Row7})
                        end),
                  %% Persist that exact terminal row before releasing the
                  %% stale reconciliation result.
                  ok = quod_effect_journal:configure_capacity(unlimited),
                  ok = quod_effect_journal:configure_capacity(64),
                  Prolog ! continue_outcome,
                  receive {frontier_queried, Runtime, 2} -> ok
                  after 1000 -> error(frontier_query_timeout)
                  end,
                  ok = wait_reconcile_idle(Pid, 1000),
                  ?assertMatch({ok, #{state := applied, height := 2,
                                      result := ok}},
                               quod_effect_journal:status(EffectId)),
                  stop(Pid),
                  {ok, Pid2} = quod_effect_journal:start_link(
                                 #{data_dir => Dir}),
                  unlink(Pid2),
                  ?assertMatch({ok, #{state := applied, height := 2,
                                      result := ok}},
                               quod_effect_journal:status(EffectId)),
                  stop(Pid2)
              after
                  case is_process_alive(Pid) of
                      true -> stop(Pid);
                      false -> ok
                  end
              end
          after
              exit(Prolog, kill),
              exit(Runtime, kill)
          end
      end).

bound_owner_death_retires_live_unactivated_row_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Dir = filename:join(
            "/tmp",
            "quod_effect_bound_owner_" ++
                integer_to_list(erlang:unique_integer([positive]))),
    SavedDesired = application:get_env(quod, namespace_desired),
    SavedKey = application:get_env(quod, node_pubkey),
    {Pub, _Seed} = quod_identity:generate(),
    RootConfig = #{data_dir => Dir,
                   ledger_dir => filename:join(Dir, "ledger")},
    application:set_env(
      quod, namespace_desired,
      #{content => #{?ROOT_NS => RootConfig}, brahms => #{}}),
    application:set_env(quod, node_pubkey, Pub),
    Ns = <<"effect:owner-down">>,
    Action = {create_ontology, Ns, []},
    Desired = {ontology_hosted, Ns},
    Anchor = hash(8101),
    Admission = hash(8102),
    try
        {ok, Structural} = quod_ontology:validate_action(Action),
        {ok, Prepared} = quod_ontology:prepare_action(Structural),
        {ok, Effect} = quod_ontology:prepared_effect(
                         Action, Prepared, Pub, {node, Pub}),
        {ok, Goal} = quod_durable_term:encode_goal(Action),
        {ok, Result} = quod_durable_term:encode_result(#{}),
        Transaction = quod_transaction:bind_id(
                        {?ROOT_NS, Anchor},
                        #transaction{origin = {?ROOT_NS, Anchor},
                                     proof_id = hash(8103),
                                     plan_digest = hash(8104),
                                     goal = Goal, result = Result,
                                     diff = [], read_check = #{},
                                     effects = [Effect], author = Pub,
                                     author_seq = 0, submitted_at = 10,
                                     sig = none}),
        Ref = {transaction, ?ROOT_NS, Anchor,
               Transaction#transaction.tx_id},
        Parent = self(),
        Fake = spawn(
                 fun() ->
                     fake_binding_simplex(
                       Parent,
                       {?ROOT_NS, Anchor, Pub, Admission})
                 end),
        receive {fake_simplex_ready, Fake} -> ok
        after 1000 -> error(fake_simplex_timeout)
        end,
        {ok, Journal} = quod_effect_journal:start_link(#{data_dir => Dir}),
        unlink(Journal),
        try
            ok = quod_effect_journal:configure_capacity(64),
            {ok, Token} = quod_effect_journal:reserve(self()),
            ok = quod_effect_journal:stage(
                   Token, Action, Desired, Effect, Prepared),
            Owner = spawn(
                      fun() ->
                          Parent !
                              {bound_result, self(),
                               quod_effect_journal:bind_transaction(
                                 Effect, Transaction, Ref)},
                          receive stop -> ok end
                      end),
            receive {bound_result, Owner, ok} -> ok
            after 1000 -> error(bind_timeout)
            end,
            EffectId = quod_effect:effect_id(Effect),
            ?assertMatch({ok, #{state := bound}},
                         quod_effect_journal:status(EffectId)),
            exit(Owner, kill),
            ok = wait_effect_state(EffectId, retired, 100),
            ?assertMatch(
               {ok, #{state := retired, result := not_activated,
                      ref := Ref}},
               quod_effect_journal:status(EffectId))
        after
            stop(Journal),
            exit(Fake, kill)
        end
    after
        restore_env(namespace_desired, SavedDesired),
        restore_env(node_pubkey, SavedKey),
        _ = file:del_dir_r(Dir)
    end.

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
    Row = {quod_effect_row, 2, quod_effect:effect_id(Effect), Effect,
           ActionBytes, DesiredBytes, PreparedBytes,
           term_to_binary(Transaction, [deterministic]), Ref, Admission,
           State, 0, none},
    {Effect, Admission, Transaction, Ref, Row}.

write_snapshot(Dir, Row) ->
    Rows = case Row of
               [_ | _] -> Row;
               _ -> [Row]
           end,
    Path = filename:join(Dir, "direct_effects.qej"),
    ok = filelib:ensure_dir(Path),
    Payload = term_to_binary(
                {quod_effect_journal, 3, 64, Rows}, [deterministic]),
    Digest = crypto:hash(sha256, Payload),
    Bytes = <<?MAGIC:32/unsigned-big,
              (byte_size(Payload)):32/unsigned-big,
              Digest/binary, Payload/binary>>,
    ok = file:write_file(Path, Bytes).

fake_simplex(Parent) ->
    fake_simplex(Parent, ok).

fake_simplex(Parent, Reply) ->
    true = quod_reg:reg({quod_simplex, ?ROOT_NS}),
    Parent ! {fake_simplex_ready, self()},
    fake_simplex_loop(Parent, Reply).

fake_simplex_loop(Parent, Reply) ->
    receive
        {'$gen_call', From, {handoff_effect, Admission, Transaction}} ->
            Parent ! {effect_handoff, Admission, Transaction},
            gen:reply(From, Reply),
            fake_simplex_loop(Parent, Reply);
        _Other ->
            fake_simplex_loop(Parent, Reply)
    end.

fake_binding_simplex(Parent, Binding) ->
    true = quod_reg:reg({quod_simplex, ?ROOT_NS}),
    Parent ! {fake_simplex_ready, self()},
    fake_binding_simplex_loop(Binding).

fake_binding_simplex_loop(Binding) ->
    receive
        {'$gen_call', From, get_dtx_binding} ->
            gen:reply(From, {ok, Binding}),
            fake_binding_simplex_loop(Binding)
    end.

fake_prolog(Parent, Ref, Height) ->
    true = quod_reg:reg({quod_prolog, ?ROOT_NS}),
    Parent ! {fake_prolog_ready, self()},
    fake_prolog_loop(Parent, Ref, Height).

fake_paused_prolog(Parent, Ref, Height) ->
    true = quod_reg:reg({quod_prolog, ?ROOT_NS}),
    Parent ! {fake_prolog_ready, self()},
    receive
        {'$gen_call', From, {outcome, Ref}} ->
            Parent ! {outcome_waiting, self(), Ref},
            receive continue_outcome -> ok end,
            gen:reply(From, {ok, #{status => committed, height => Height,
                                  ref => Ref}})
    end,
    fake_prolog_loop(Parent, Ref, Height).

fake_prolog_loop(Parent, Ref, Height) ->
    receive
        {'$gen_call', From, {outcome, Ref}} ->
            Parent ! {outcome_queried, Ref},
            gen:reply(From, {ok, #{status => committed, height => Height,
                                  ref => Ref}}),
            fake_prolog_loop(Parent, Ref, Height);
        {'$gen_cast', {public_proof, Caller, CallRef, prove_ro, _Goal, _Request}} ->
            Caller ! {quod_proof_reply, self(), CallRef,
                      {error, no_such_namespace}},
            fake_prolog_loop(Parent, Ref, Height);
        _Other ->
            fake_prolog_loop(Parent, Ref, Height)
    end.

fake_runtime(Parent, Frontier) ->
    true = quod_reg:reg({quod_runtime, ?ROOT_NS}),
    Parent ! {fake_runtime_ready, self()},
    fake_runtime_loop(Parent, Frontier).

fake_runtime_loop(Parent, Frontier) ->
    receive
        {'$gen_call', From, effect_frontier} ->
            gen:reply(From, {ok, Frontier}),
            Parent ! {frontier_queried, self(), Frontier},
            fake_runtime_loop(Parent, Frontier);
        {set_frontier, Caller, NewFrontier} ->
            Caller ! {frontier_set, self(), NewFrontier},
            fake_runtime_loop(Parent, NewFrontier);
        _Other ->
            fake_runtime_loop(Parent, Frontier)
    end.

stop(Pid) ->
    MRef = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 1000 -> error(timeout) end.

wait_reconcile_idle(_Pid, 0) ->
    error(reconcile_state_timeout);
wait_reconcile_idle(Pid, Attempts) ->
    %% #s.reconciling is element 8; this is a TEST-only synchronization
    %% barrier, not a production-state dependency.
    case element(8, sys:get_state(Pid)) of
        none -> ok;
        _ ->
            receive after 1 -> ok end,
            wait_reconcile_idle(Pid, Attempts - 1)
    end.

wait_effect_state(_EffectId, _State, 0) ->
    error(effect_state_timeout);
wait_effect_state(EffectId, State, Attempts) ->
    case quod_effect_journal:status(EffectId) of
        {ok, #{state := State}} -> ok;
        _ ->
            receive after 1 -> ok end,
            wait_effect_state(EffectId, State, Attempts - 1)
    end.

hash(N) -> crypto:hash(sha256, term_to_binary(N, [deterministic])).

restore_env(Key, {ok, Value}) -> application:set_env(quod, Key, Value);
restore_env(Key, undefined) -> application:unset_env(quod, Key).
