-module(quod_dtx_parent_progress_tests).
-moduledoc """
Consensus validation follows the exact durable parent, not signing permission.

Real signed Begin controls and certified N=4 history. A registered Prolog
receiver captures actual casts; the tests supply explicit verdicts at that
boundary, not a second evaluator. Parent progress releases validation; only the
bounded recovery-preference tests use the existing tick. No sleep releases work.
""".
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

parent_progress_wakes_waiting_child_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, _Keys) ->
        %% Approved content can precede its durable commit in the pipeline.
        %% The approved-parent fixture is structural, not consensus-admitted.
        {ok, Parent} = quod_ledger:new_block(2, 1,
                         {batch, [maps:get(transaction, F)]}, quod_time:now_ms()),
        Approved = quod_simplex:test_blocked_dtx_owner(Parent, S0),
        {ok, Blob} = quod_dtx:encode_control(maps:get(begin_control, F)),
        Waiting = quod_simplex:test_propose_dtx_wave(3, [Blob], [], Approved),
        ?assertMatch({none, none, {_, _}, none, undefined},
                     quod_simplex:test_dtx_round(3, Waiting)),
        assert_no_request(),
        Token = {2, quod_simplex:block_hash(Parent)},
        Installed = quod_simplex:test_state_set(history_head, Token,
                      quod_simplex:test_state_set(slot, 2, Waiting)),
        Resumed = quod_simplex:settle_readiness(Waiting, Installed),
        {Hash, Token, Owner} = take_request(3),
        ?assertEqual(self(), Owner),
        ?assertMatch({Hash, {dtx, Token, Owner, _, _}, _, none, undefined},
                     quod_simplex:test_dtx_round(3, Resumed)),
        %% Neither duplicate progress nor ordinary mailbox turns re-issue it.
        ?assertEqual(Resumed, quod_simplex:settle_readiness(Resumed, Resumed)),
        assert_no_request(),
        _ = quod_simplex:test_on_dtx_verdict(3, Hash, Token, Owner, 2, abstain, Resumed),
        ok
    end) end).

certified_candidate_validates_before_voting_readiness_test_() ->
    isolated(fun() -> without_signing(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, WithCerts} = certified_first(F, S0, Keys),
        Mode = {pulling, self()},
        Paused = quod_simplex:test_state_set(sync, Mode, WithCerts),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Paused),
        Token = maps:get(history_head, quod_simplex:test_state_projection(S0)),
        ?assertEqual({Hash, Token, self()}, take_request(2)),
        Repeated = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Proposed),
        ?assertEqual(quod_simplex:test_dtx_round(2, Proposed),
                     quod_simplex:test_dtx_round(2, Repeated)),
        assert_no_request(),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Proposed))),
        ?assertEqual({none, false, false}, quod_simplex:test_round(2, Proposed)),
        %% The real exact-parent preview and certificate-driven applier run.
        %% The pending recovery mode forbids fresh votes throughout application.
        Done = quod_simplex:test_on_dtx_verdict(
                 2, Hash, Token, self(), 1, {valid, #{}}, Proposed),
        {2, Store} = quod_simplex:test_committed_store(Done),
        {ok, Entry} = quod_ledger_store:read_at(Store, 2),
        ?assertEqual(Hash, quod_simplex:block_hash(element(2, quod_ledger:block_from_entry(Entry)))),
        ?assertEqual(2, maps:get(last_applied, quod_simplex:stats_map(Done))),
        ?assertEqual(Mode, quod_simplex:test_sync(Done)),
        ?assertEqual({none, false, false}, quod_simplex:test_round(2, Done)),
        ?assertEqual(#{}, quod_signing_journal:rounds(quod_simplex:test_signing_journal(Done))),
        ok
    end) end) end).

paused_validation_does_not_authorize_fresh_votes_test_() ->
    [isolated(fun() -> without_signing(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, WithCerts} = certified_first(F, S0, Keys, Kinds),
        Paused = quod_simplex:test_state_set(sync, {pulling, self()}, WithCerts),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Paused),
        {Hash, Token, Owner} = take_request(2),
        Done = quod_simplex:test_on_dtx_verdict(2, Hash, Token, Owner, 1,
                                              {valid, #{}}, Proposed),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Done))),
        ?assertMatch({none, false, _}, quod_simplex:test_round(2, Done)),
        ?assertEqual(#{}, quod_signing_journal:rounds(quod_simplex:test_signing_journal(Done))),
        ok
    end) end) end) || Kinds <- [[], [support]]].

nonparticipant_does_not_request_local_consensus_validation_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Outsider, _} = quod_identity:generate(),
        Observer = quod_simplex:test_state_set(self, Outsider, S0),
        {Block, _, WithCerts} = certified_first(F, Observer, Keys),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, WithCerts),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Proposed))),
        assert_no_request()
    end) end).

certificates_never_substitute_for_a_valid_parent_verdict_test_() ->
    [isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, WithCerts} = certified_first(F, S0, Keys),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, WithCerts),
        {Hash, Token, Owner} = take_request(2),
        Done = quod_simplex:test_on_dtx_verdict(2, Hash, Token, Owner, 1, Verdict, Proposed),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Done))),
        ?assertMatch({none, none, none, none, undefined}, quod_simplex:test_dtx_round(2, Done)),
        ?assertEqual({none, false, false}, quod_simplex:test_round(2, Done)),
        ok
    end) end) || Verdict <- [abstain, {invalid, refused}]].

missing_prolog_owner_never_uses_the_certificate_as_a_verdict_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Ns, _} = maps:get(origin, F),
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        {Block, Hash, WithCerts} = certified_first(F, S0, Keys),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, WithCerts),
        ?assertMatch({none, none, {Hash, Block}, none, undefined}, quod_simplex:test_dtx_round(2, Proposed)),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Proposed))),
        assert_no_request()
    end) end).

durable_block_remains_retrievable_after_engine_prune_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, Done} = committed_block(F, S0, Keys),
        ?assertEqual({none, false, false}, quod_simplex:test_round(2, Done)),
        ?assertEqual({certified_block, Block, Hash}, reply(F, Keys, Hash, Done)),
        Clean = quod_simplex:test_state_set(outbox, #{}, Done),
        ?assertEqual(Clean, quod_simplex:dispatch(peer(Keys), {block_request, 2, <<0:256>>}, Clean)),
        {Outsider, _} = quod_identity:generate(),
        ?assertEqual(Clean, quod_simplex:dispatch(Outsider, {block_request, 2, Hash}, Clean)),
        {2, Store} = quod_simplex:test_committed_store(Done),
        {ok, Entry} = quod_ledger_store:read_at(Store, 2),
        ?assertEqual({ok, Block}, quod_ledger:block_from_entry(Entry)),
        %% An explicit storage-reopen oracle, not a runtime recovery path.
        ok = quod_ledger_store:close(Store),
        {Ns, _} = maps:get(origin, F),
        {ok, Reopened} = quod_ledger_store:open(Ns, maps:get(dir, F)),
        try
            Restored = quod_simplex:test_state_set(store, Reopened, Done),
            ?assertEqual({certified_block, Block, Hash}, reply(F, Keys, Hash, Restored))
        after quod_ledger_store:close(Reopened) end
    end) end).

live_block_serving_needs_no_second_support_certificate_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, NoCerts} = certified_first(F, S0, Keys, []),
        Paused = quod_simplex:test_state_set(sync, {pulling, self()}, NoCerts),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Paused),
        {Hash, Token, Owner} = take_request(2),
        Live = quod_simplex:test_on_dtx_verdict(2, Hash, Token, Owner, 1, {valid, #{}}, Proposed),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Live))),
        ?assertEqual({certified_block, Block, Hash}, reply(F, Keys, Hash, Live))
    end) end).

durable_reply_is_data_not_a_validation_verdict_test_() ->
    [isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, WithCerts} = certified_first(F, S0, Keys),
        Requested = quod_simplex:test_state_set(block_requests, #{{2, Hash} => {1, 0}}, WithCerts),
        Received = quod_simplex:dispatch(peer(Keys), {certified_block, Block, Hash}, Requested),
        ?assertEqual({none, false, false}, quod_simplex:test_round(2, Received)),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Received))),
        {Hash, Token, Owner} = take_request(2),
        Done = quod_simplex:test_on_dtx_verdict(2, Hash, Token, Owner, 1, Verdict, Received),
        Expected = case Verdict of {valid, _} -> 2; _ -> 1 end,
        ?assertEqual(Expected, element(1, quod_simplex:test_committed_store(Done))),
        ?assertEqual(Done, quod_simplex:dispatch(peer(Keys), {certified_block, Block, Hash}, Done)),
        assert_no_request()
    end) end) || Verdict <- [{valid, #{}}, abstain, {invalid, refused}]].

request_bookkeeping_cannot_substitute_for_authenticated_support_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, NoCerts} = certified_first(F, S0, Keys, []),
        Requested = quod_simplex:test_state_set(block_requests, #{{2, Hash} => {1, 0}}, NoCerts),
        ?assertEqual(Requested, quod_simplex:dispatch(peer(Keys), {certified_block, Block, Hash}, Requested)),
        assert_no_request()
    end) end).

certified_reply_rejects_nonmember_and_unavailable_parent_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Block, Hash, WithCerts} = certified_first(F, S0, Keys),
        Requested = quod_simplex:test_state_set(block_requests, #{{2, Hash} => {1, 0}}, WithCerts),
        {Outsider, _} = quod_identity:generate(),
        ?assertEqual(Requested, quod_simplex:dispatch(Outsider, {certified_block, Block, Hash}, Requested)),
        %% The actual certificate remains valid, but this structural receiver
        %% has not installed its parent. It must not consume the reply.
        MissingParent = quod_simplex:test_state_set(slot, 0, Requested),
        ?assertEqual(MissingParent, quod_simplex:dispatch(peer(Keys), {certified_block, Block, Hash}, MissingParent)),
        assert_no_request()
    end) end).

durable_lookup_is_one_bounded_read_not_history_replay_test_() ->
    isolated(fun() ->
        {{ok, Owner}, {call_time, Counts}} = tprof:profile(fun() ->
            with_fixture(fun(F, S0, Keys) ->
                {Block, Hash, Done} = committed_block(F, S0, Keys),
                ?assertEqual({certified_block, Block, Hash}, reply(F, Keys, Hash, Done))
            end),
            {ok, self()}
        end, #{type => call_time, report => return, set_on_spawn => false,
               pattern => [{quod_ledger_store, open, 2}, {quod_ledger_store, read_at, 2},
                           {quod_simplex, history_validate_advance, 3}]}),
        Count = fun(M, F) -> lists:sum([N || {M0, F0, _, Ps} <- Counts, M0 =:= M, F0 =:= F,
                                            {Pid, N, _} <- Ps, Pid =:= Owner]) end,
        ?assertEqual(1, Count(quod_ledger_store, open)),
        ?assertEqual(1, Count(quod_ledger_store, read_at)),
        %% Founding validation only; neither lookup nor the live commit replays.
        ?assertEqual(1, Count(quod_simplex, history_validate_advance))
    end).

finality_does_not_duplicate_owned_parent_validation_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Ns, _} = maps:get(origin, F),
        true = quod_reg:reg({quod_catchup, Ns}),
        true = quod_reg:reg({quod_simplex, Ns}),
        try
            {Block, Hash, Certified} = certified_first(F, S0, Keys),
            Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Certified),
            {Hash, Token, Owner} = take_request(2),
            Reconciled = quod_simplex:reconcile_block_requests(Proposed),
            try
                ?assertEqual(ready, quod_simplex:test_sync(Reconciled)),
                ?assertNot(quod_simplex:caught_up(Reconciled)),
                From = {self(), make_ref()},
                ?assertMatch({keep_state, _, [{reply, From, {ok, _}}]},
                             quod_simplex:running({call, From}, get_dtx_binding, Reconciled)),
                Repeated = lists:foldl(fun(_, S) -> quod_simplex:reconcile_block_requests(S) end,
                                       Reconciled, lists:seq(1, 20)),
                ?assertEqual(ready, quod_simplex:test_sync(Repeated)),
                assert_no_request(),
                Done = quod_simplex:test_on_dtx_verdict(
                         2, Hash, Token, Owner, 1, {valid, #{}}, Repeated),
                ?assertEqual(2, element(1, quod_simplex:test_committed_store(Done))),
                ?assertEqual(ready, quod_simplex:test_sync(
                                     quod_simplex:reconcile_block_requests(Done)))
            after stop_test_recovery(Reconciled) end
        after
            gproc:unreg(quod_reg:name({quod_simplex, Ns})),
            gproc:unreg(quod_reg:name({quod_catchup, Ns}))
        end
    end) end).

validation_allowance_is_captured_at_request_not_owner_lifetime_test_() ->
    [isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        S = quod_simplex:test_state_set(validation_ttl_ms, Ttl, S0),
        {Block, Hash, Certified} = certified_first(F, S, Keys),
        Before = quod_time:mono_ms(),
        Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Certified),
        After = quod_time:mono_ms(),
        {Hash, Token, Owner} = take_request(2),
        {Hash, {dtx, Token, Owner, Monitor, Deadline}, _, _, _} = quod_simplex:test_dtx_round(2, Proposed),
        ?assert(Deadline >= Before + Ttl andalso Deadline =< After + Ttl),
        ?assertNot(quod_simplex:caught_up(Proposed)),
        erlang:demonitor(Monitor, [flush])
    end) end) || Ttl <- [500, 2000]].

expired_validation_keeps_latch_until_recovery_reseats_test_() ->
    isolated(fun() -> without_signing(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Ns, Anchor} = Identity = maps:get(origin, F),
        true = quod_reg:reg({quod_catchup, Ns}),
        true = quod_reg:reg({quod_simplex, Ns}),
        %% A distinct, live protocol owner is essential: monitoring self()
        %% creates no monitor and cannot witness recovery's resource cleanup.
        gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        Caller = self(),
        {Owner, OwnerMonitor} = spawn_monitor(fun() ->
            true = quod_reg:reg({quod_prolog, Ns}),
            Caller ! {self(), ready},
            receive Request -> Caller ! Request end,
            receive stop -> ok end
        end),
        receive {Owner, ready} -> ok after 1000 -> error(validation_owner_missing) end,
        try
            %% Zero is an already-exhausted instance of the same namespace
            %% allowance; expiry is deterministic, never a timing assertion.
            S = quod_simplex:test_state_set(validation_ttl_ms, 0, S0),
            {Block, Hash, Certified} = certified_first(F, S, Keys),
            Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Certified),
            {Hash, Token, Caller} = receive
                {'$gen_cast', {dtx_verdict_req, [_], _, 2, Caller, {2, H, T}, _}} -> {H, T, Caller}
            after 1000 -> error(parent_progress_not_delivered) end,
            Latched = quod_simplex:test_dtx_round(2, Proposed),
            {Hash, {dtx, Token, Owner, Monitor, _}, _, _, _} = Latched,
            ?assert(quod_simplex:should_sync(Proposed)),
            {keep_state, Started, _} = quod_simplex:running({timeout, tick}, tick, Proposed),
            try
                {pulling, Worker} = quod_simplex:test_sync(Started),
                ?assertEqual(Latched, quod_simplex:test_dtx_round(2, Started)),
                assert_no_request(),
                ?assertEqual(1, element(1, quod_simplex:test_committed_store(Started))),
                %% The actual recovery worker is held at its real capture call.
                %% This fixture supplies a quorum-certified window through the
                %% production verifier and sink, not a synthetic verdict.
                receive {'$gen_call', _, {history_view, Identity, committed, _}} -> ok
                after 1000 -> error(recovery_capture_missing) end,
                From = {self(), make_ref()},
                {keep_state, Started, [{reply, From, {ok, View}}]} = quod_simplex:running(
                    {call, From}, {history_view, Identity, committed, quod_time:mono_ms() + 5000}, Started),
                Projection0 = maps:get(projection, View),
                Domain = quod_simplex:consensus_domain(Ns, Anchor), Committee = lists:sort(maps:keys(Keys)),
                Shares = [quod_simplex:make_share(Domain, commit, 2, Hash, maps:get(P, Keys))
                          || P <- lists:sublist(Committee, 3)],
                {ok, Cert} = quod_simplex:form_cert(Domain, commit, 2, Hash, Shares, Committee),
                Entry = quod_ledger:entry(Block, Cert),
                {ok, Entries, Projection, Delta} = quod_ct:with_network_identity(maps:get(network, F), fun() ->
                    quod_catchup:verify_forward(Ns, Anchor, Projection0, 2, [Entry], maps:get(history_index, Projection0))
                end),
                {keep_state, Recovered, _} = quod_simplex:running({call, From},
                    {sink_catchup, {recovery, Worker}, Entries, Projection, Delta}, Started),
                ?assertEqual(2, element(1, quod_simplex:test_committed_store(Recovered))),
                ?assertEqual({none, none, none, none, undefined}, quod_simplex:test_dtx_round(2, Recovered)),
                ?assertNot(erlang:demonitor(Monitor, [flush, info])),
                ?assertEqual(Recovered, quod_simplex:test_on_dtx_verdict(
                    2, Hash, Token, Owner, 1, {valid, #{}}, Recovered)),
                assert_no_request()
            after stop_test_recovery(Started) end
        after
            Owner ! stop,
            receive {'DOWN', OwnerMonitor, process, Owner, normal} -> ok
            after 1000 -> error(validation_owner_survived) end,
            gproc:unreg(quod_reg:name({quod_simplex, Ns})),
            gproc:unreg(quod_reg:name({quod_catchup, Ns}))
        end
    end) end) end).

foreign_validation_inherits_expired_parent_allowance_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, _Keys) ->
        Target = maps:get(origin, F), Signer = maps:get(node_identity, F),
        Foreign = {<<"quod:deadline-foreign">>, <<89:256>>},
        RF = quod_ct:signed_dtx_begin_fixture(#{target => Foreign, participant_target => Target}),
        Begin = maps:get('begin', RF),
        {ok, Ref} = quod_dtx:certified_ref(element(1, Foreign), element(2, Foreign), 2,
            <<90:256>>, quod_dtx:group_id(Begin), <<"structural-reference-not-consensus-admitted">>),
        {ok, Prepare} = quod_dtx:new_prepare(Begin, Ref, Target),
        {ok, Control} = quod_dtx:sign_control(Target, Prepare, maps:get(admission, F), 1, 1, Signer),
        {ok, Blob} = quod_dtx:encode_control(Control),
        S = quod_simplex:test_state_set(validation_ttl_ms, 0, S0),
        Proposed = quod_simplex:test_propose_dtx_wave(2, [Blob], [], S),
        {Hash, Token, Owner} = take_request(2),
        {_, {dtx, _, _, _, Deadline}, _, _, _} = quod_simplex:test_dtx_round(2, Proposed),
        %% The supplied parent verdict is a callback fixture; this tests the
        %% actual handoff, not acceptance of the structural foreign reference.
        ForeignPending = quod_simplex:test_on_dtx_verdict(2, Hash, Token, Owner, 1, {valid, #{}}, Proposed),
        {_, {dtx_foreign, Token, Worker, Monitor, #{}, Deadline}, _, _, _} =
            quod_simplex:test_dtx_round(2, ForeignPending),
        ?assert(Deadline =< quod_time:mono_ms()),
        case is_process_alive(Worker) of true -> exit(Worker, kill); false -> ok end,
        erlang:demonitor(Monitor, [flush])
    end) end).

stop_test_recovery(S) ->
    case quod_simplex:test_sync(S) of
        {pulling, Worker} ->
            Monitor = erlang:monitor(process, Worker),
            exit(Worker, kill),
            receive {'DOWN', Monitor, process, Worker, _} -> ok
            after 1000 -> error(recovery_worker_survived) end;
        _ -> ok
    end.

failed_or_stale_parent_work_immediately_releases_recovery_test_() ->
    [{atom_to_list(Mode), isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Ns, Anchor} = maps:get(origin, F),
        true = quod_reg:reg({quod_catchup, Ns}),
        true = quod_reg:reg({quod_simplex, Ns}),
        try
            {Block, Hash, Certified} = certified_first(F, S0, Keys),
            Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Certified),
            {Hash, Token, Owner} = take_request(2),
            Changed = case Mode of
                abstain -> quod_simplex:test_on_dtx_verdict(2, Hash, Token, Owner, 1, abstain, Proposed);
                invalid -> quod_simplex:test_on_dtx_verdict(2, Hash, Token, Owner, 1, {invalid, refused}, Proposed);
                stale_parent -> quod_simplex:test_state_set(history_head, {1, <<99:256>>}, Proposed);
                wrong_hash ->
                    {_, Altered} = quod_simplex:test_latch_dtx_validation(2, <<98:256>>, Token, Owner, Block, Proposed),
                    Altered;
                dead_owner ->
                    Dead = spawn(fun() -> ok end), M = monitor(process, Dead),
                    receive {'DOWN', M, process, Dead, _} -> ok after 1000 -> error(owner_did_not_exit) end,
                    {_, Altered} = quod_simplex:test_latch_dtx_validation(2, Hash, Token, Dead, Block, Proposed),
                    Altered;
                higher_finalizer ->
                    Domain = quod_simplex:consensus_domain(Ns, Anchor),
                    Committee = lists:sort(maps:keys(Keys)),
                    Shares = [quod_simplex:make_share(Domain, commit, 3, <<97:256>>, maps:get(P, Keys))
                              || P <- lists:sublist(Committee, 3)],
                    {ok, Cert} = quod_simplex:form_cert(Domain, commit, 3, <<97:256>>, Shares, Committee),
                    quod_simplex:dispatch(peer(Keys), {cert, Cert}, Proposed)
            end,
            Started = quod_simplex:reconcile_block_requests(Changed),
            try
                ?assertMatch({pulling, _}, quod_simplex:test_sync(Started)),
                ?assertNot(quod_simplex:caught_up(Started)),
                ?assertEqual(1, element(1, quod_simplex:test_committed_store(Started)))
            after stop_test_recovery(Started) end
        after
            gproc:unreg(quod_reg:name({quod_simplex, Ns})),
            gproc:unreg(quod_reg:name({quod_catchup, Ns}))
        end
    end) end)} || Mode <- [abstain, invalid, stale_parent, wrong_hash, dead_owner, higher_finalizer]].

authenticated_finality_wakes_one_existing_recovery_worker_without_a_tick_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Ns, _} = Identity = maps:get(origin, F),
        true = quod_reg:reg({quod_catchup, Ns}),
        true = quod_reg:reg({quod_simplex, Ns}),
        try
            {_Block, Hash, Certified} = certified_first(F, S0, Keys),
            Waiting = quod_simplex:test_state_set(block_requests,
                        #{{2, Hash} => {1, 0}}, Certified),
            Started = quod_simplex:reconcile_block_requests(Waiting),
            ?assertMatch({pulling, _}, quod_simplex:test_sync(Started)),
            {pulling, Worker} = quod_simplex:test_sync(Started),
            Monitor = erlang:monitor(process, Worker),
            try
                ?assertEqual(#{}, quod_simplex:test_block_requests(Started)),
                %% A real worker asks the actual sole writer for its pinned
                %% history view. No tick, direct start call or invented reply.
                receive {'$gen_call', _, {history_view, Identity, committed, Deadline}} ->
                    ?assert(Deadline > quod_time:mono_ms())
                after 1000 -> error(recovery_capture_not_requested) end,
                Repeated = lists:foldl(fun(_, S) -> quod_simplex:reconcile_block_requests(S) end,
                                       Started, lists:seq(1, 20)),
                ?assertEqual({pulling, Worker}, quod_simplex:test_sync(Repeated)),
                ?assertEqual(#{}, quod_simplex:test_block_requests(Repeated)),
                ?assertEqual(1, element(1, quod_simplex:test_committed_store(Repeated))),
                ?assertNot(quod_simplex:caught_up(Repeated))
            after
                exit(Worker, kill),
                receive {'DOWN', Monitor, process, Worker, _} -> ok
                after 1000 -> error(recovery_worker_survived) end
            end
        after
            gproc:unreg(quod_reg:name({quod_simplex, Ns})),
            gproc:unreg(quod_reg:name({quod_catchup, Ns}))
        end
    end) end).

support_only_and_forged_finality_do_not_start_history_recovery_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Ns, _} = maps:get(origin, F),
        true = quod_reg:reg({quod_catchup, Ns}),
        try
            {_Block, Hash, Supported} = certified_first(F, S0, Keys, [support]),
            Forged = #cert{kind = commit, slot = 2, block_hash = Hash, sigs = []},
            Ignored = quod_simplex:dispatch(peer(Keys), {cert, Forged}, Supported),
            Reconciled = quod_simplex:reconcile_block_requests(Ignored),
            ?assertEqual(ready, quod_simplex:test_sync(Reconciled)),
            ?assertMatch(#{{2, Hash} := _}, quod_simplex:test_block_requests(Reconciled))
        after gproc:unreg(quod_reg:name({quod_catchup, Ns})) end
    end) end).

peer_progress_cannot_spend_failed_recovery_backoff_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Ns, _} = maps:get(origin, F),
        true = quod_reg:reg({quod_catchup, Ns}),
        try
            {_Block, _Hash, Certified} = certified_first(F, S0, Keys),
            Cooling = quod_simplex:test_state_set(sync_arm, {3, 4}, Certified),
            Reconciled = lists:foldl(fun(_, S) -> quod_simplex:reconcile_block_requests(S) end,
                                     Cooling, lists:seq(1, 20)),
            ?assertEqual(ready, quod_simplex:test_sync(Reconciled)),
            ?assertEqual({3, 4}, quod_simplex:test_arm(Reconciled))
        after gproc:unreg(quod_reg:name({quod_catchup, Ns})) end
    end) end).

committed_block(F, S0, Keys) ->
    {Block, Hash, WithCerts} = certified_first(F, S0, Keys),
    Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, WithCerts),
    {Hash, Token, Owner} = take_request(2),
    Done = quod_simplex:test_on_dtx_verdict(2, Hash, Token, Owner, 1, {valid, #{}}, Proposed),
    ?assertEqual(2, element(1, quod_simplex:test_committed_store(Done))),
    {Block, Hash, Done}.

peer(Keys) -> lists:nth(2, lists:sort(maps:keys(Keys))).

reply(F, Keys, Hash, S) ->
    {Ns, _} = maps:get(origin, F),
    Peer = peer(Keys),
    Clean = quod_simplex:test_state_set(outbox, #{}, S),
    Answered = quod_simplex:dispatch(Peer, {block_request, 2, Hash}, Clean),
    ?assertMatch(#{Peer := [_]}, quod_simplex:test_outbox(Answered)),
    [Frame] = maps:get(Peer, quod_simplex:test_outbox(Answered)),
    {consensus, Message} = quod_relay:decode_consensus_frame(Frame, Ns),
    Message.

certified_first(F, S, Keys) ->
    certified_first(F, S, Keys, [support, commit]).

certified_first(F, S, Keys, Kinds) ->
    {Ns, Anchor} = maps:get(origin, F),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    {ok, Blob} = quod_dtx:encode_control(maps:get(begin_control, F)),
    {ok, Block} = quod_ledger:new_block(2, 1, {batch, [{dtx, Blob}]}, quod_time:now_ms()),
    Hash = quod_simplex:block_hash(Block),
    Committee = lists:sort(maps:keys(Keys)),
    Certs = [begin
        Shares = [quod_simplex:make_share(Domain, Kind, 2, Hash, maps:get(P, Keys))
                  || P <- lists:sublist(Committee, 3)],
        {ok, Cert} = quod_simplex:form_cert(Domain, Kind, 2, Hash, Shares, Committee), Cert
    end || Kind <- Kinds],
    WithCerts = lists:foldl(fun(C, Acc) -> quod_simplex:dispatch(hd(Committee), {cert, C}, Acc) end, S, Certs),
    {Block, Hash, WithCerts}.

leader(Slot, Keys) -> quod_simplex:leader(Slot, lists:sort(maps:keys(Keys))).

take_request(Slot) ->
    receive {'$gen_cast', {dtx_verdict_req, [_], _, Slot, Owner,
                          {Slot, Hash, Token}, _}} -> {Hash, Token, Owner}
    after 0 -> error({parent_progress_not_delivered, Slot}) end.
assert_no_request() ->
    receive {'$gen_cast', {dtx_verdict_req, _, _, _, _, _, _}} -> error(duplicate_or_early_validation)
    after 0 -> ok end.

with_fixture(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Ns = <<"quod:parent-progress-", Suffix/binary>>,
    Dir = filename:join("/tmp", "quod_parent_progress_" ++ binary_to_list(Suffix)),
    Keys = maps:from_list([begin
        {Pub, Seed} = quod_identity:generate(),
        {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}
    end || _ <- lists:seq(1, 4)]),
    Committee = [Author | _] = lists:sort(maps:keys(Keys)),
    {ok, Genesis, Anchor} = quod_simplex:prepare_genesis(
        #{mode => create, committee => Committee, genesis_diff => []}, Ns, Author),
    Target = {Ns, Anchor}, Domain = quod_simplex:consensus_domain(Ns, Anchor),
    {ok, Projection} = quod_simplex:history_validate_advance(Target, Genesis, quod_simplex:history_projection(Target)),
    F = quod_ct:signed_dtx_begin_fixture(#{target => Target, node_identity => maps:get(Author, Keys),
            admission => maps:get(Author, maps:get(admissions, Projection))}),
    {ok, Journal} = quod_signing_journal:initialize(Ns, Domain, Dir),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store} = quod_ledger_store:append(Store0, [Genesis]),
    {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        S = quod_simplex:test_install_projection(Projection,
            quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor, self => Author,
                id => maps:get(Author, Keys), consensus_domain => Domain,
                store => Store, signing_journal => Journal, phase_index => Index,
                slot => 1, last_applied => 1, sync => ready, prolog_ready => true,
                eng => quod_simplex:eng_new(Domain, Committee, 1)})),
        Fun(F#{dir => Dir}, S, Keys)
    after
        catch gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        quod_dtx_phase_index:close(Index),
        quod_ledger_store:close(Store),
        catch quod_signing_journal:close(Journal),
        file:del_dir_r(Dir)
    end.

isolated(Fun) -> {timeout, 30, {spawn, Fun}}.

without_signing(Fun) ->
    %% tprof owns a fresh worker: construct its file handles and correlated
    %% verdict request inside that same worker, never move a live owner state.
    {{ok, Owner}, {call_time, Counts}} = tprof:profile(fun() -> {Fun(), self()} end,
        #{type => call_time, report => return, set_on_spawn => false,
          pattern => [{quod_signing_journal, record_vote, 4},
                      {quod_signing_journal, record_support, 2}]}),
    ?assertEqual(0, lists:sum([N || {_, _, _, Ps} <- Counts,
                                  {Pid, N, _} <- Ps, Pid =:= Owner])).
