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

membership_child_waits_for_durable_parent_test_() ->
    [{atom_to_list(Delivery), isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Parent, _, ValidParent} = receipt_content_parent(F, S0, Keys),
        Approved = receipt_certificates(Parent, [support], F, Keys, ValidParent),
        Removed = leader(2, Keys),
        {Membership, _} = receipt_membership_parent(F, S0, Removed),
        #block{payload = {batch, [Transaction]}} = Membership,
        Child = signed_receipt_child(F, Parent, Transaction, 2),
        {batch, ChildPayload} = Child#block.payload,
        ?assertNot(quod_simplex:test_collected_payload(ChildPayload, Approved)),
        Hash = quod_simplex:block_hash(Child),
        Before = case Delivery of
            early ->
                Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Approved),
                assert_receipt_offer(3, Hash, Child, Offered),
                ?assertEqual({none, none}, quod_simplex:test_proposal_rejection(3, Offered)),
                assert_no_content_request(3),
                Offered;
            _ -> Approved
        end,
        Committed = receipt_certificates(Parent, [commit], F, Keys, Before),
        ?assertEqual(2, element(1, quod_simplex:test_committed_store(Committed))),
        Settled = quod_simplex:settle_readiness(Before, Committed),
        ?assert(quod_simplex:test_collected_payload(ChildPayload, Settled)),
        Admitted = case Delivery of
            %% No resend: the ordinary parent progress edge releases this offer.
            early -> Settled;
            _ -> quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Settled)
        end,
        take_content_request(3, Hash),
        Repeated = case Delivery of
            repeated_late -> receipt_repeat(Child, Keys, Settled, Admitted);
            _ -> Admitted
        end,
        assert_no_content_request(3),
        Judged = callback_state(quod_simplex:running(
                    info, {content_verdict, {3, Hash}, valid}, Repeated)),
        Done = receipt_certificates(Child, [support, commit], F, Keys, Judged),
        {3, Store} = quod_simplex:test_committed_store(Done),
        {ok, Entry} = quod_ledger_store:read_at(Store, 3),
        ?assertEqual({ok, Child}, quod_ledger:block_from_entry(Entry)),
        ?assertEqual(lists:sort(maps:keys(maps:remove(Removed, Keys))),
                     quod_simplex:history_committee(quod_simplex:test_state_projection(Done)))
    end) end)} || Delivery <- [early, late, repeated_late]].

content_admission_parent_durability_siblings_test_() ->
    [{atom_to_list(Mode) ++ "_" ++ atom_to_list(Delivery), isolated(fun() ->
      with_fixture(fun(F, S0, Keys) ->
        {Parent, _, ValidParent} = receipt_content_parent(F, S0, Keys),
        Approved = receipt_certificates(Parent, [support], F, Keys, ValidParent),
        Base = maps:get(transaction, receipt_fixture(F, 3)),
        Sequence = case Mode of replay -> 1; _ -> 2 end,
        ValidChild = signed_receipt_child(F, Parent, Base, Sequence),
        Child = case Mode of
            bad_id ->
                #block{payload = {batch, [Signed]}} = ValidChild,
                BadChild = signed_receipt_child(F, Parent, Signed#transaction{tx_id = <<91:256>>}, Sequence),
                {batch, [BadSigned]} = BadChild#block.payload,
                ?assertEqual(<<91:256>>, BadSigned#transaction.tx_id),
                BadChild;
            _ -> ValidChild
        end,
        Start = case Delivery of
            early -> Approved;
            late -> receipt_certificates(Parent, [commit], F, Keys, Approved)
        end,
        Hash = quod_simplex:block_hash(Child),
        Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Start),
        case Mode of
            valid ->
                take_content_request(3, Hash),
                Again = receipt_repeat(Child, Keys, Start, Offered),
                assert_no_content_request(3),
                ?assertEqual({none, false, false}, quod_simplex:test_round(3, Again)),
                ?assertEqual({none, none}, quod_simplex:test_proposal_rejection(3, Again)),
                DurableParent = case Delivery of
                    early -> receipt_certificates(Parent, [commit], F, Keys, Again);
                    late -> Again
                end,
                Judged = callback_state(quod_simplex:running(
                    info, {content_verdict, {3, Hash}, valid}, DurableParent)),
                Done = receipt_certificates(Child, [support, commit], F, Keys, Judged),
                {3, Store} = quod_simplex:test_committed_store(Done),
                {ok, Entry} = quod_ledger_store:read_at(Store, 3),
                ?assertEqual({ok, Child}, quod_ledger:block_from_entry(Entry)),
                ?assertEqual(lists:sort(maps:keys(Keys)),
                             quod_simplex:history_committee(quod_simplex:test_state_projection(Done)));
            _ ->
                ?assertEqual({Hash, proposal_admission},
                             quod_simplex:test_proposal_rejection(3, Offered)),
                Later = case Delivery of
                    early -> receipt_certificates(Parent, [commit], F, Keys, Offered);
                    late -> Offered
                end,
                Again = receipt_repeat(Child, Keys, Start, Later),
                ?assertEqual(quod_simplex:test_dtx_round(3, Offered),
                             quod_simplex:test_dtx_round(3, Again)),
                ?assertEqual({Hash, proposal_admission},
                             quod_simplex:test_proposal_rejection(3, Again)),
                assert_no_content_request(3),
                ?assertEqual(2, element(1, quod_simplex:test_committed_store(Again)))
        end
      end)
    end)} || Mode <- [valid, replay, bad_id], Delivery <- [early, late]].

mixed_membership_child_is_rejected_not_parked_test_() ->
    [{atom_to_list(Delivery), isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Parent, _, ValidParent} = receipt_content_parent(F, S0, Keys),
        Approved = receipt_certificates(Parent, [support], F, Keys, ValidParent),
        {Membership, _} = receipt_membership_parent(F, S0, leader(2, Keys)),
        {batch, [MembershipTx]} = Membership#block.payload,
        M = signed_receipt_child(F, Parent, MembershipTx, 2),
        C = signed_receipt_child(F, Parent, maps:get(transaction, receipt_fixture(F, 3)), 3),
        {batch, [MT]} = M#block.payload,
        {batch, [CT]} = C#block.payload,
        ?assertNotEqual(MT#transaction.tx_id, CT#transaction.tx_id),
        {ok, Child} = quod_ledger:new_block(3, 2, {batch, [MT, CT]}, Parent#block.timestamp),
        Hash = quod_simplex:block_hash(Child),
        Start = case Delivery of
            early -> Approved;
            late -> receipt_certificates(Parent, [commit], F, Keys, Approved)
        end,
        ?assertNot(quod_simplex:test_collected_payload([MT, CT], Start)),
        Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Start),
        ?assertEqual({Hash, proposal_admission}, quod_simplex:test_proposal_rejection(3, Offered)),
        Later = case Delivery of
            early -> receipt_certificates(Parent, [commit], F, Keys, Offered);
            late -> Offered
        end,
        Again = receipt_repeat(Child, Keys, Start, Later),
        ?assertEqual({Hash, proposal_admission}, quod_simplex:test_proposal_rejection(3, Again)),
        ?assertEqual({none, false, false}, quod_simplex:test_round(3, Again)),
        assert_no_content_request(3),
        {2, Store} = quod_simplex:test_committed_store(Again),
        ?assertMatch({ok, _}, quod_ledger_store:read_at(Store, 2)),
        ?assertEqual(lists:sort(maps:keys(Keys)),
                     quod_simplex:history_committee(quod_simplex:test_state_projection(Again)))
    end) end)} || Delivery <- [early, late]].

signed_receipt_child(F, Parent, Transaction, Sequence) ->
    {Ns, Anchor} = maps:get(origin, F),
    {ok, Signed} = quod_transaction:sign(
        {Ns, Anchor, maps:get(admission, F)},
        Transaction#transaction{author_seq = Sequence, sig = none, signed_bytes = none},
        maps:get(node_identity, F)),
    {ok, Child} = quod_ledger:new_block(3, 2, {batch, [Signed]}, Parent#block.timestamp),
    Child.

take_content_request(Slot, Hash) ->
    Owner = self(),
    receive {'$gen_cast', {content_verdict_req, [_], _, Slot, Owner, {Slot, Hash}, _}} -> ok
    after 0 -> error({content_request_missing, Slot}) end.

assert_no_content_request(Slot) ->
    receive {'$gen_cast', {content_verdict_req, _, _, Slot, _, _, _}} ->
        error({unexpected_content_request, Slot})
    after 0 -> ok end.

%% Receipt is not admission. These controls enter through the same inbound
%% dispatcher as a peer; the tagged offer must never inherit the authority of
%% the existing admitted {Hash, Block} candidate. The original owner/deadline
%% controls below continue to pin the subsequent monitored validation lifetime.
early_child_receipt_survives_until_durable_parent_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Parent, ParentHash, Token, Owner, Child, ChildHash, Pending} =
            receipt_pair(F, S0, Keys, [support, commit]),
        Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Pending),
        %% Fail-before oracle: the old preflight drops this real early child.
        assert_receipt_offer(3, ChildHash, Child, Offered),
        assert_no_request(),
        ?assertEqual(quod_simplex:test_dtx_round(2, Pending),
                     quod_simplex:test_dtx_round(2, Offered)),
        Committed = quod_simplex:test_on_dtx_verdict(
                      2, ParentHash, Token, Owner, 1, {valid, #{}}, Offered),
        ?assertEqual(2, element(1, quod_simplex:test_committed_store(Committed))),
        Resumed = quod_simplex:settle_readiness(Offered, Committed),
        ChildToken = {2, quod_simplex:block_hash(Parent)},
        ?assertEqual({ChildHash, ChildToken, self()}, take_request(3)),
        {ChildHash, {dtx, ChildToken, ChildOwner, _, Deadline},
         {ChildHash, Child}, none, undefined} = quod_simplex:test_dtx_round(3, Resumed),
        ?assertEqual({none, false, false}, quod_simplex:test_round(3, Resumed)),
        Finality = receipt_certificates(Child, [support, commit], F, Keys, Resumed),
        Reconciled = quod_simplex:reconcile_block_requests(Finality),
        try
            ?assertEqual(ready, quod_simplex:test_sync(Reconciled)),
            ?assertNot(quod_simplex:should_sync(Reconciled)),
            ?assertNot(quod_simplex:may_vote(Reconciled)),
            ?assertNot(quod_simplex:caught_up(Reconciled)),
            Repeated = receipt_repeat(Child, Keys, Offered, Reconciled),
            ?assertMatch({ChildHash, {dtx, ChildToken, ChildOwner, _, Deadline},
                          {ChildHash, Child}, none, undefined},
                         quod_simplex:test_dtx_round(3, Repeated)),
            assert_no_request(),
            Done = quod_simplex:test_on_dtx_verdict(
                     3, ChildHash, ChildToken, ChildOwner, 2, {valid, #{}}, Repeated),
            {3, Store} = quod_simplex:test_committed_store(Done),
            {ok, Entry} = quod_ledger_store:read_at(Store, 3),
            ?assertEqual({ok, Child}, quod_ledger:block_from_entry(Entry)),
            ?assertEqual({none, none, none, none, undefined},
                         quod_simplex:test_dtx_round(3, Done))
        after stop_test_recovery(Reconciled) end
    end) end).

early_child_parent_progress_prevents_missing_body_recovery_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        with_receipt_recovery(F, fun() ->
            {_, ParentHash, Token, Owner, Child, Hash, Pending} =
                receipt_pair(F, S0, Keys, [support, commit]),
            Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Pending),
            assert_no_request(),
            Committed = quod_simplex:test_on_dtx_verdict(
                          2, ParentHash, Token, Owner, 1, {valid, #{}}, Offered),
            ?assertEqual(2, element(1, quod_simplex:test_committed_store(Committed))),
            Resumed = quod_simplex:settle_readiness(Offered, Committed),
            Finality = receipt_certificates(Child, [support, commit], F, Keys, Resumed),
            Reconciled = quod_simplex:reconcile_block_requests(Finality),
            try
                %% Intentionally before inspecting a candidate or consuming
                %% its request: old source reaches a real missing-body arm.
                ?assertEqual(ready, quod_simplex:test_sync(Reconciled)),
                ?assertNot(quod_simplex:should_sync(Reconciled)),
                ?assertNot(quod_simplex:may_vote(Reconciled)),
                ?assertNot(quod_simplex:caught_up(Reconciled)),
                ChildToken = {2, ParentHash},
                ?assertEqual({Hash, ChildToken, self()}, take_request(3)),
                ?assertEqual({none, false, false}, quod_simplex:test_round(3, Reconciled)),
                Done = quod_simplex:test_on_dtx_verdict(
                         3, Hash, ChildToken, self(), 2, {valid, #{}}, Reconciled),
                ?assertEqual(3, element(1, quod_simplex:test_committed_store(Done))),
                assert_no_request()
            after stop_test_recovery(Reconciled) end
        end)
    end) end).

early_child_finality_keeps_higher_gap_recovery_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        with_receipt_recovery(F, fun() ->
            {_, _, _, _, Child, Hash, Pending} = receipt_pair(F, S0, Keys, [support, commit]),
            Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Pending),
            assert_receipt_offer(3, Hash, Child, Offered),
            Finality = receipt_certificates(Child, [support, commit], F, Keys, Offered),
            ?assert(quod_simplex:should_sync(Finality)),
            Started = quod_simplex:reconcile_block_requests(Finality),
            try
                ?assertMatch({pulling, _}, quod_simplex:test_sync(Started)),
                ?assertNot(quod_simplex:may_vote(Started)),
                ?assertNot(quod_simplex:caught_up(Started)),
                ?assertEqual(1, element(1, quod_simplex:test_committed_store(Started))),
                assert_receipt_offer(3, Hash, Child, Started),
                assert_no_request()
            after stop_test_recovery(Started) end
        end)
    end) end).

early_child_approval_without_durability_does_not_admit_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Parent, ParentHash, Token, Owner, Child, Hash, Pending} =
            receipt_pair(F, S0, Keys, [support]),
        Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Pending),
        Approved0 = quod_simplex:test_on_dtx_verdict(
                      2, ParentHash, Token, Owner, 1, {valid, #{}}, Offered),
        Approved = quod_simplex:settle_readiness(Offered, Approved0),
        ?assertEqual(2, maps:get(approved, quod_simplex:stats_map(Approved))),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Approved))),
        assert_receipt_offer(3, Hash, Child, Approved),
        Repeated = receipt_repeat(Child, Keys, Offered, Approved),
        assert_receipt_offer(3, Hash, Child, Repeated),
        assert_no_request(),
        Committed = receipt_certificates(Parent, [commit], F, Keys, Repeated),
        Resumed = quod_simplex:settle_readiness(Repeated, Committed),
        ChildToken = {2, ParentHash},
        ?assertEqual({Hash, ChildToken, self()}, take_request(3)),
        ?assertMatch({Hash, {dtx, ChildToken, _, _, _}, {Hash, Child}, none, undefined},
                     quod_simplex:test_dtx_round(3, Resumed))
    end) end).

early_child_failed_or_changed_parent_grants_no_authority_test_() ->
    [{atom_to_list(Mode), isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {_, ParentHash, Token, Owner, Child, Hash, Pending} = receipt_pair(F, S0, Keys, []),
        Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Pending),
        {BeforeVerdict, Verdict} = case Mode of
            abstain -> {Offered, abstain};
            invalid -> {Offered, {invalid, refused}};
            stale_parent ->
                %% Structural parent-token change, as in the existing stale
                %% lifetime control; the old verdict has no authority here.
                {quod_simplex:test_state_set(history_head, {1, <<99:256>>}, Offered),
                 {valid, #{}}}
        end,
        Released = quod_simplex:test_on_dtx_verdict(
                     2, ParentHash, Token, Owner, 1, Verdict, BeforeVerdict),
        Settled = quod_simplex:settle_readiness(Offered, Released),
        assert_receipt_offer(3, Hash, Child, Settled),
        ?assertEqual(1, element(1, quod_simplex:test_committed_store(Settled))),
        assert_no_request()
    end) end)} || Mode <- [abstain, invalid, stale_parent]].

early_child_duplicates_do_not_repeat_full_admission_test_() ->
    [{atom_to_list(Mode), isolated(fun() ->
        {{ok, Caller}, {call_time, Counts}} = tprof:profile(fun() ->
            with_fixture(fun(F, S0, Keys) ->
                {_, ParentHash, Token, Owner, ValidChild, _, Pending} =
                    receipt_pair(F, S0, Keys, [support, commit]),
                Child = case Mode of valid -> ValidChild; invalid -> receipt_junk(ValidChild) end,
                Hash = quod_simplex:block_hash(Child),
                Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Pending),
                Repeated = receipt_repeat(Child, Keys, S0, Offered),
                assert_receipt_offer(3, Hash, Child, Repeated),
                assert_no_request(),
                Committed = quod_simplex:test_on_dtx_verdict(
                              2, ParentHash, Token, Owner, 1, {valid, #{}}, Repeated),
                Resumed = quod_simplex:settle_readiness(Repeated, Committed),
                case Mode of
                    valid -> {Hash, _, _} = take_request(3);
                    invalid ->
                        assert_receipt_offer(3, Hash, Child, Resumed),
                        assert_no_request()
                end,
                Latched = quod_simplex:test_dtx_round(3, Resumed),
                Again = receipt_repeat(Child, Keys, Repeated, Resumed),
                ?assertEqual(Latched, quod_simplex:test_dtx_round(3, Again)),
                case Mode of
                    valid -> ok;
                    invalid ->
                        OtherJunk = receipt_junk(ValidChild, <<1:512>>),
                        ?assertNotEqual(Hash, quod_simplex:block_hash(OtherJunk)),
                        Alternated = lists:foldl(fun(_, Acc) ->
                            Other = quod_simplex:dispatch(
                                      leader(3, Keys), {propose, OtherJunk, []}, Acc),
                            Original = quod_simplex:dispatch(
                                         leader(3, Keys), {propose, Child, []}, Other),
                            quod_simplex:settle_readiness(Repeated, Original)
                        end, Again, lists:seq(1, 20)),
                        assert_receipt_offer(3, Hash, Child, Alternated)
                end,
                assert_no_request()
            end),
            {ok, self()}
        end, #{type => call_time, report => return, set_on_spawn => false,
               pattern => [{quod_simplex, dtx_control_acceptable, 4}]}),
        %% One ordinary envelope-authentication boundary for the parent and
        %% one for the child; neither receipt nor twenty redrives pays again.
        ?assertEqual(2, lists:sum([N || {quod_simplex, dtx_control_acceptable, 4, Ps} <- Counts,
                                      {Pid, N, _} <- Ps, Pid =:= Caller]))
    end)} || Mode <- [valid, invalid]].

early_child_bad_input_is_not_retained_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Child, _} = receipt_child(F, 3, 2),
        {ok, Beyond} = quod_ledger:new_block(4, 3, Child#block.payload, Child#block.timestamp),
        {ok, WrongParent} = quod_ledger:new_block(3, 1, Child#block.payload, Child#block.timestamp),
        NonLeader = hd([P || P <- maps:keys(Keys), P =/= leader(3, Keys)]),
        Huge = binary:copy(<<0>>, 256 * 1024 + 129),
        Cases = [{NonLeader, Child}, {leader(3, Keys), WrongParent},
                 {leader(4, Keys), Beyond},
                 {leader(3, Keys), Child#block{timestamp = -1}},
                 {leader(3, Keys), Child#block{block_bytes = <<>>}},
                 {leader(3, Keys), Child#block{payload = {batch, [{dtx, Huge}]}, block_bytes = Huge}}],
        lists:foreach(fun({Peer, Block}) ->
            ?assertEqual(S0, quod_simplex:dispatch(Peer, {propose, Block, []}, S0))
        end, Cases),
        ?assertEqual({none, none, none, none, undefined}, quod_simplex:test_dtx_round(3, S0)),
        ?assertEqual({none, none, none, none, undefined}, quod_simplex:test_dtx_round(4, S0)),
        assert_no_request()
    end) end).

early_junk_offer_cannot_veto_certified_alternate_test_() ->
    [isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {_, ParentHash, Token, Owner, Child, Hash, Pending} =
            receipt_pair(F, S0, Keys, [support, commit]),
        %% Canonical bounded bytes, deliberately not an authenticated control.
        Junk = receipt_junk(Child),
        JunkHash = quod_simplex:block_hash(Junk),
        Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Junk, []}, Pending),
        assert_receipt_offer(3, JunkHash, Junk, Offered),
        %% Neither another ordinary body nor unauthenticated request bookkeeping
        %% can replace the first input. Certified recovery owns that authority.
        ?assertEqual(Offered, quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Offered)),
        Committed = quod_simplex:test_on_dtx_verdict(
                      2, ParentHash, Token, Owner, 1, {valid, #{}}, Offered),
        ?assertEqual(2, element(1, quod_simplex:test_committed_store(Committed))),
        Requested = quod_simplex:test_state_set(block_requests, #{{3, Hash} => {1, 0}}, Committed),
        ?assertEqual(Requested, quod_simplex:dispatch(peer(Keys), {certified_block, Child, Hash}, Requested)),
        Supported = receipt_certificates(Child, [support], F, Keys, Requested),
        Alternate = quod_simplex:dispatch(peer(Keys), {certified_block, Child, Hash}, Supported),
        ChildToken = {2, ParentHash},
        ?assertEqual({Hash, ChildToken, self()}, take_request(3)),
        ?assertMatch({Hash, {dtx, ChildToken, _, _, _}, {Hash, Child}, none, undefined},
                     quod_simplex:test_dtx_round(3, Alternate)),
        ?assertEqual({none, false, false}, quod_simplex:test_round(3, Alternate)),
        Finality = receipt_certificates(Child, [commit], F, Keys, Alternate),
        Done = quod_simplex:test_on_dtx_verdict(3, Hash, ChildToken, self(), 2, Verdict, Finality),
        Expected = case Verdict of {valid, _} -> 3; abstain -> 2 end,
        ?assertEqual(Expected, element(1, quod_simplex:test_committed_store(Done))),
        ?assertEqual({none, none, none, none, undefined}, quod_simplex:test_dtx_round(3, Done)),
        assert_no_request()
    end) end) || Verdict <- [{valid, #{}}, abstain]].

certified_dtx_offer_waits_for_ordinary_parent_durability_test_() ->
    isolated(fun() ->
        {{ok, Caller}, {call_time, Counts}} = tprof:profile(fun() ->
            with_fixture(fun(F, S0, Keys) ->
                {Parent, ParentHash, ValidParent} = receipt_content_parent(F, S0, Keys),
                {Child, Hash} = receipt_child(F, 3, 2),
                Junk = receipt_junk(Child),
                JunkHash = quod_simplex:block_hash(Junk),
                Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Junk, []}, ValidParent),
                Approved0 = receipt_certificates(Parent, [support], F, Keys, Offered),
                Approved = quod_simplex:settle_readiness(Offered, Approved0),
                %% Real content verdict and quorum approval, not a planted
                %% approved field or synthetic engine-tree parent.
                ?assertEqual(2, maps:get(approved, quod_simplex:stats_map(Approved))),
                ?assertEqual(1, element(1, quod_simplex:test_committed_store(Approved))),
                assert_receipt_offer(3, JunkHash, Junk, Approved),
                Supported = receipt_certificates(Child, [support], F, Keys, Approved),
                Requested = quod_simplex:test_state_set(
                              block_requests, #{{3, Hash} => {1, 0}}, Supported),
                Replaced = quod_simplex:dispatch(
                             peer(Keys), {certified_block, Child, Hash}, Requested),
                ?assertNot(maps:is_key({3, Hash}, quod_simplex:test_block_requests(Replaced))),
                assert_receipt_offer(3, Hash, Child, Replaced),
                Repeated = receipt_repeat(Child, Keys, Offered, Replaced),
                assert_receipt_offer(3, Hash, Child, Repeated),
                assert_no_request(),
                Committed = receipt_certificates(Parent, [commit], F, Keys, Repeated),
                ?assertEqual(2, element(1, quod_simplex:test_committed_store(Committed))),
                Resumed = quod_simplex:settle_readiness(Repeated, Committed),
                Token = {2, ParentHash},
                ?assertEqual({Hash, Token, self()}, take_request(3)),
                ?assertMatch({Hash, {dtx, Token, _, _, _}, {Hash, Child}, none, undefined},
                             quod_simplex:test_dtx_round(3, Resumed)),
                ?assertEqual({none, false, false}, quod_simplex:test_round(3, Resumed)),
                Finality = receipt_certificates(Child, [commit], F, Keys, Resumed),
                Done = quod_simplex:test_on_dtx_verdict(
                         3, Hash, Token, self(), 2, {valid, #{}}, Finality),
                ?assertEqual(3, element(1, quod_simplex:test_committed_store(Done))),
                assert_no_request()
            end),
            {ok, self()}
        end, #{type => call_time, report => return, set_on_spawn => false,
               pattern => [{quod_simplex, dtx_control_acceptable, 4}]}),
        %% Neither the early junk nor the certified waiting child is fully
        %% authenticated before the durable edge; the admitted child pays once.
        ?assertEqual(1, lists:sum([N || {quod_simplex, dtx_control_acceptable, 4, Ps} <- Counts,
                                      {Pid, N, _} <- Ps, Pid =:= Caller]))
    end).

certified_ordinary_replacement_has_only_engine_residence_test_() ->
    [{atom_to_list(Kind), isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {Parent, _, ValidParent} = receipt_content_parent(F, S0, Keys),
        {Child, Hash} = receipt_content(F, 3, 2),
        Junk = case Kind of
            dtx -> {Dtx, _} = receipt_child(F, 3, 2), receipt_junk(Dtx);
            ordinary ->
                %% Ordinary wire encoding already verifies its signature.
                %% Use genuine signed bytes whose sequence becomes stale
                %% when this parent's author sequence 1 commits.
                {Stale, _} = receipt_content(F, 3, 1), Stale
        end,
        JunkHash = quod_simplex:block_hash(Junk),
        Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Junk, []}, ValidParent),
        assert_receipt_offer(3, JunkHash, Junk, Offered),
        Committed = receipt_certificates(Parent, [support, commit], F, Keys, Offered),
        ?assertEqual(2, element(1, quod_simplex:test_committed_store(Committed))),
        Rejected = quod_simplex:settle_readiness(Offered, Committed),
        assert_receipt_offer(3, JunkHash, Junk, Rejected),
        Supported = receipt_certificates(Child, [support], F, Keys, Rejected),
        Requested = quod_simplex:test_state_set(
                      block_requests, #{{3, Hash} => {1, 0}}, Supported),
        Admitted = quod_simplex:dispatch(peer(Keys), {certified_block, Child, Hash}, Requested),
        ?assertNot(maps:is_key({3, Hash}, quod_simplex:test_block_requests(Admitted))),
        %% Ordinary admission must remove the old offered body, regardless
        %% of its content family, while retaining the certified engine bytes.
        ?assertMatch({_, _, none, none, Child}, quod_simplex:test_dtx_round(3, Admitted)),
        ?assertEqual([], quod_simplex:test_dtx_round_hints(3, Admitted)),
        Again = quod_simplex:dispatch(leader(3, Keys), {propose, Junk, []}, Admitted),
        ?assertEqual(Admitted, Again),
        assert_no_request()
    end) end)} || Kind <- [dtx, ordinary]].

early_child_binds_actual_replacement_parent_not_old_offer_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        {_, OldHash, Token, Owner, Child, Hash, Pending} = receipt_pair(F, S0, Keys, []),
        Offered = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Pending),
        Released = quod_simplex:test_on_dtx_verdict(2, OldHash, Token, Owner, 1, abstain, Offered),
        %% The wire carries parent SLOT only. An unadmitted child must pass
        %% full admission against the parent actually committed afterwards.
        {NewParent0, _} = receipt_child(F, 2, 1),
        {ok, NewParent} = quod_ledger:new_block(2, 1, NewParent0#block.payload, Child#block.timestamp),
        NewHash = quod_simplex:block_hash(NewParent),
        ?assertNotEqual(OldHash, NewHash),
        Certified = receipt_certificates(NewParent, [support, commit], F, Keys, Released),
        NewPending = quod_simplex:dispatch(leader(2, Keys), {propose, NewParent, []}, Certified),
        ?assertEqual({NewHash, Token, self()}, take_request(2)),
        Committed = quod_simplex:test_on_dtx_verdict(2, NewHash, Token, self(), 1, {valid, #{}}, NewPending),
        Resumed = quod_simplex:settle_readiness(NewPending, Committed),
        NewToken = {2, NewHash},
        ?assertEqual({Hash, NewToken, self()}, take_request(3)),
        Latched = quod_simplex:test_dtx_round(3, Resumed),
        ?assertMatch({Hash, {dtx, NewToken, _, _, _}, {Hash, Child}, none, undefined}, Latched),
        Stale = quod_simplex:test_on_dtx_verdict(3, Hash, {2, OldHash}, self(), 2, {valid, #{}}, Resumed),
        ?assertEqual(Latched, quod_simplex:test_dtx_round(3, Stale)),
        ?assertEqual({none, false, false}, quod_simplex:test_round(3, Stale)),
        assert_no_request()
    end) end).

early_child_receipt_does_not_cross_parent_committee_change_test_() ->
    [{Name, isolated(fun() -> with_fixture(#{node_addr => NodeAddr}, fun(F, S0, Keys) ->
        %% Removing the second sorted member changes slot 3's leader from
        %% the old third member to the old fourth; the author remains first.
        Removed = leader(2, Keys), OldLeader = leader(3, Keys),
        NewKeys = maps:remove(Removed, Keys), NewLeader = leader(3, NewKeys),
        ?assertNotEqual(OldLeader, NewLeader),
        {Parent, ParentHash} = receipt_membership_parent(F, S0, Removed),
        Proposed = quod_simplex:dispatch(Removed, {propose, Parent, []}, S0),
        Owner = self(),
        receive
            {'$gen_cast', {content_verdict_req, [_], _, 2, Owner, {2, ParentHash}, _}} -> ok
        after 0 -> error(membership_parent_validation_not_delivered)
        end,
        {Child, Hash} = receipt_child(F, 3, 2),
        Offered = quod_simplex:dispatch(OldLeader, {propose, Child, []}, Proposed),
        assert_receipt_offer(3, Hash, Child, Offered),
        assert_no_request(),
        %% As elsewhere in this suite, only the local policy receiver verdict
        %% is explicit. Transaction/plan/request signatures, proposal admission,
        %% old-committee certificates and durable history are the real paths.
        ValidParent = callback_state(quod_simplex:running(
                        info, {content_verdict, {2, ParentHash}, valid}, Offered)),
        Committed = receipt_certificates(Parent, [support, commit], F, Keys, ValidParent),
        {2, Store} = quod_simplex:test_committed_store(Committed),
        {ok, Entry} = quod_ledger_store:read_at(Store, 2),
        ?assertEqual({ok, Parent}, quod_ledger:block_from_entry(Entry)),
        ?assertEqual(lists:sort(maps:keys(NewKeys)),
                     quod_simplex:history_committee(quod_simplex:test_state_projection(Committed))),
        %% Fail-before: the checkpoint retains an offer authorized only by
        %% the old leader here and later admits it on parent progress.
        ?assertEqual({none, none, none, none, undefined}, quod_simplex:test_dtx_round(3, Committed)),
        ?assertEqual([], quod_simplex:test_dtx_round_hints(3, Committed)),
        Settled = quod_simplex:settle_readiness(Offered, Committed),
        ?assertEqual({none, false, false}, quod_simplex:test_round(3, Settled)),
        ?assertNot(maps:is_key(3, quod_signing_journal:rounds(quod_simplex:test_signing_journal(Settled)))),
        assert_no_request(),
        ?assertEqual(Settled, quod_simplex:dispatch(OldLeader, {propose, Child, []}, Settled)),
        Admitted = quod_simplex:dispatch(NewLeader, {propose, Child, []}, Settled),
        Token = {2, ParentHash},
        ?assertEqual({Hash, Token, self()}, take_request(3)),
        ?assertMatch({Hash, {dtx, Token, _, _, _}, {Hash, Child}, none, undefined},
                     quod_simplex:test_dtx_round(3, Admitted)),
        ?assertEqual({none, false, false}, quod_simplex:test_round(3, Admitted)),
        Finality = receipt_certificates(Child, [support, commit], F, NewKeys, Admitted),
        Done = quod_simplex:test_on_dtx_verdict(3, Hash, Token, self(), 2, {valid, #{}}, Finality),
        ?assertEqual(3, element(1, quod_simplex:test_committed_store(Done))),
        assert_no_request()
    end) end)} || {Name, NodeAddr} <-
        [{"no_self_address", undefined},
         {"self_address", {<<"127.0.0.1">>, 19001}}]].

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

%% The receiver is the genuine registered request owner, but its verdict is
%% supplied at the existing Prolog boundary (not a second evaluator). A second
%% monitor proves exit without dispatching the queued verdict or installed DOWN.
queued_parent_verdict_owns_validation_until_consumed_test_() ->
    [{atom_to_list(Kind), isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        with_pending_parent_owner(F, fun(Owner, ExitMonitor) ->
            {Block, Hash, Certified} = certified_first(F, S0, Keys),
            Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Certified),
            {Hash, Token, Caller} = await_parent_request(2),
            ?assertEqual(self(), Caller),
            Latched = {Hash, {dtx, Token, Owner, Monitor, Deadline}, _, _, _} =
                quod_simplex:test_dtx_round(2, Proposed),
            {Verdict, Reason} = case Kind of
                valid -> {{valid, #{}}, normal};
                invalid -> {{invalid, refused}, normal};
                abstain -> {abstain, normal};
                abnormal_after_send -> {{valid, #{}}, validation_crashed_after_send}
            end,
            Owner ! {finish, Verdict, Reason},
            receive {'DOWN', ExitMonitor, process, Owner, Reason} -> ok
            after 1000 -> error(validation_owner_did_not_exit) end,
            ?assertNot(is_process_alive(Owner)),
            Message = {dtx_verdict, {2, Hash, Token}, Owner, 1, Verdict},
            Down = {'DOWN', Monitor, process, Owner, Reason},
            {messages, Messages} = process_info(self(), messages),
            %% Verdict-before-exit is from one sender; delivery order between
            %% different monitors is deliberately not assumed.
            ?assertEqual([Message], [M || M <- Messages, M =:= Message]),
            ?assert(Deadline > quod_time:mono_ms()),
            Reconciled = quod_simplex:reconcile_block_requests(Proposed),
            try
                ?assertEqual(ready, quod_simplex:test_sync(Reconciled)),
                ?assertNot(quod_simplex:should_sync(Reconciled)),
                ?assertNot(quod_simplex:caught_up(Reconciled)),
                ?assertNot(quod_simplex:may_vote(Reconciled)),
                ?assertEqual(Latched, quod_simplex:test_dtx_round(2, Reconciled)),
                ?assertEqual(1, element(1, quod_simplex:test_committed_store(Reconciled))),
                ?assertEqual(#{}, quod_signing_journal:rounds(quod_simplex:test_signing_journal(Reconciled))),
                %% An actual second-monitor DOWN is stale for the installed
                %% request, even though the PID matches and really is dead.
                Stale = callback_state(quod_simplex:running(info,
                    {'DOWN', ExitMonitor, process, Owner, Reason}, Reconciled)),
                ?assertEqual(Latched, quod_simplex:test_dtx_round(2, Stale)),
                ?assertEqual(ready, quod_simplex:test_sync(Stale)),
                receive Message -> ok after 0 -> error(queued_verdict_lost) end,
                Done = callback_state(quod_simplex:running(info, Message, Stale)),
                try
                    Expected = case Verdict of {valid, _} -> 2; _ -> 1 end,
                    ?assertEqual(Expected, element(1, quod_simplex:test_committed_store(Done))),
                    ?assertEqual({none, none, none, none, undefined}, quod_simplex:test_dtx_round(2, Done)),
                    case Expected of
                        2 -> ?assertEqual(ready, quod_simplex:test_sync(Done));
                        1 -> ?assertMatch({pulling, _}, quod_simplex:test_sync(Done))
                    end,
                    %% Any delivered DOWN is flushed on verdict consumption;
                    %% we do not assume it arrived before the verdict callback.
                    receive Down -> error(consumed_verdict_left_monitor_down) after 0 -> ok end
                after stop_test_recovery(Done) end
            after stop_test_recovery(Reconciled) end
        end)
    end) end)} || Kind <- [valid, invalid, abstain, abnormal_after_send]].

crashed_parent_owner_releases_only_on_matching_down_test_() ->
    isolated(fun() -> with_fixture(fun(F, S0, Keys) ->
        with_pending_parent_owner(F, fun(Owner, ExitMonitor) ->
            {Block, Hash, Certified} = certified_first(F, S0, Keys),
            Proposed0 = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Certified),
            {Hash, Token, _} = await_parent_request(2),
            {Child, ChildHash} = receipt_child(F, 3, 2),
            Proposed = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Proposed0),
            assert_receipt_offer(3, ChildHash, Child, Proposed),
            Latched = {Hash, {dtx, Token, Owner, Monitor, Deadline}, _, _, _} =
                quod_simplex:test_dtx_round(2, Proposed),
            Owner ! crash,
            receive {'DOWN', ExitMonitor, process, Owner, validation_crashed} -> ok
            after 1000 -> error(validation_owner_did_not_crash) end,
            ?assert(Deadline > quod_time:mono_ms()),
            ?assertNot(quod_simplex:should_sync(Proposed)),
            Stale = callback_state(quod_simplex:running(info,
                {'DOWN', ExitMonitor, process, Owner, validation_crashed}, Proposed)),
            try
                ?assertEqual(Latched, quod_simplex:test_dtx_round(2, Stale)),
                ?assertEqual(ready, quod_simplex:test_sync(Stale)),
                ?assertNot(quod_simplex:may_vote(Stale)),
                Down = receive {'DOWN', Monitor, process, Owner, validation_crashed} = D -> D
                       after 1000 -> error(installed_monitor_down_missing) end,
                Released = callback_state(quod_simplex:running(info, Down, Stale)),
                try
                    ?assertMatch({none, none, {Hash, Block}, none, undefined}, quod_simplex:test_dtx_round(2, Released)),
                    ?assertMatch({pulling, _}, quod_simplex:test_sync(Released)),
                    ?assertNot(quod_simplex:caught_up(Released)),
                    ?assertNot(quod_simplex:may_vote(Released)),
                    ?assertEqual(1, element(1, quod_simplex:test_committed_store(Released))),
                    ?assertEqual(#{}, quod_signing_journal:rounds(quod_simplex:test_signing_journal(Released))),
                    assert_receipt_offer(3, ChildHash, Child, Released),
                    assert_no_request()
                after stop_test_recovery(Released) end
            after stop_test_recovery(Stale) end
        end)
    end) end).

with_pending_parent_owner(F, Fun) ->
    {Ns, _} = maps:get(origin, F),
    true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
    true = quod_reg:reg({quod_simplex, Ns}),
    true = quod_reg:reg({quod_catchup, Ns}),
    Caller = self(),
    {Owner, ExitMonitor} = spawn_monitor(fun() ->
        true = quod_reg:reg({quod_prolog, Ns}),
        Caller ! {self(), ready},
        receive {'$gen_cast', {dtx_verdict_req, [_], _, 2, ReplyTo, Tag, _}} = Request ->
            Caller ! Request,
            receive
                {finish, Verdict, Reason} ->
                    ReplyTo ! {dtx_verdict, Tag, self(), 1, Verdict},
                    exit(Reason);
                crash -> exit(validation_crashed)
            end
        end
    end),
    try
        receive {Owner, ready} -> ok after 1000 -> error(validation_owner_missing) end,
        Fun(Owner, ExitMonitor)
    after
        exit(Owner, kill),
        erlang:demonitor(ExitMonitor, [flush]),
        gproc:unreg(quod_reg:name({quod_simplex, Ns})),
        gproc:unreg(quod_reg:name({quod_catchup, Ns}))
    end.

await_parent_request(Slot) ->
    receive {'$gen_cast', {dtx_verdict_req, [_], _, Slot, Caller, {Slot, Hash, Token}, _}} ->
        {Hash, Token, Caller}
    after 1000 -> error(parent_progress_not_delivered) end.

callback_state({keep_state, S}) -> S;
callback_state({keep_state, S, _Actions}) -> S.

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
            Proposed0 = quod_simplex:dispatch(leader(2, Keys), {propose, Block, []}, Certified),
            {Hash, Token, Caller} = receive
                {'$gen_cast', {dtx_verdict_req, [_], _, 2, Caller, {2, H, T}, _}} -> {H, T, Caller}
            after 1000 -> error(parent_progress_not_delivered) end,
            {Child, ChildHash} = receipt_child(F, 3, 2),
            Proposed = quod_simplex:dispatch(leader(3, Keys), {propose, Child, []}, Proposed0),
            assert_receipt_offer(3, ChildHash, Child, Proposed),
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
                ?assertEqual({none, none, none, none, undefined}, quod_simplex:test_dtx_round(3, Recovered)),
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

foreign_validation_worker_is_atomically_monitored_test_() ->
    isolated(fun() ->
        {{ok, Caller}, {call_time, Counts}} = tprof:profile(fun() ->
            with_fixture(fun(F, S0, _Keys) ->
                Target = {Ns, Anchor} = maps:get(origin, F),
                Begin = maps:get('begin', F),
                %% A local reference beyond this snapshot is unavailable.
                %% Exercise the real foreign-stage worker without any remote
                %% resolver, and do not pretend this reference was admitted.
                {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, 2, <<90:256>>,
                    quod_dtx:group_id(Begin), <<"structural-unavailable-reference">>),
                {ok, Decision} = quod_dtx:new_decision(
                    quod_dtx:group_id(Begin), Ref, {abort, [expired]}, []),
                {ok, Control} = quod_dtx:sign_control(Target, Decision,
                    maps:get(admission, F), 1, 1, maps:get(node_identity, F)),
                {ok, Blob} = quod_dtx:encode_control(Control),
                Proposed = quod_simplex:test_propose_dtx_wave(2, [Blob], [], S0),
                {Hash, Token, Owner} = take_request(2),
                {_, {dtx, _, _, _, Deadline}, _, _, _} = quod_simplex:test_dtx_round(2, Proposed),
                Pending = callback_state(quod_simplex:running(info,
                    {dtx_verdict, {2, Hash, Token}, Owner, 1, {valid, #{}}}, Proposed)),
                {Hash, {dtx_foreign, Token, Worker, Monitor, #{}, Deadline}, _, _, _} =
                    quod_simplex:test_dtx_round(2, Pending),
                ?assert(Worker =/= self()),
                %% Selective receive leaves the earlier worker verdict queued.
                receive {'DOWN', Monitor, process, Worker, normal} -> ok
                after 1000 -> error(foreign_validation_worker_did_not_exit) end,
                Message = receive
                    {dtx_foreign_verdict, {2, Hash, Token}, Worker, _, abstain} = M -> M
                after 0 -> error(foreign_verdict_missing_before_down) end,
                Done = callback_state(quod_simplex:running(info, Message, Pending)),
                ?assertEqual({none, none, none, none, undefined}, quod_simplex:test_dtx_round(2, Done)),
                ?assertEqual(1, element(1, quod_simplex:test_committed_store(Done)))
            end),
            {ok, self()}
        end, #{type => call_time, report => return, set_on_spawn => false,
               pattern => [{erlang, spawn_monitor, 1}]}),
        %% Atomic construction is an observable call, not a probabilistic
        %% attempt to win the old spawn-then-monitor race.
        ?assertEqual(1, lists:sum([N || {erlang, spawn_monitor, 1, Ps} <- Counts,
                                      {Pid, N, _} <- Ps, Pid =:= Caller]))
    end).

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
                    %% Physical exit alone is not request completion. Consume
                    %% the real installed monitor's DOWN through the callback.
                    Dead = spawn(fun() -> receive crash -> exit(validation_crashed) end end),
                    {M, Altered} = quod_simplex:test_latch_dtx_validation(2, Hash, Token, Dead, Block, Proposed),
                    Dead ! crash,
                    Down = receive {'DOWN', M, process, Dead, validation_crashed} = D -> D
                           after 1000 -> error(owner_did_not_exit) end,
                    callback_state(quod_simplex:running(info, Down, Altered));
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

receipt_pair(F, S0, Keys, ParentCertKinds) ->
    {Parent, ParentHash, Certified} = certified_first(F, S0, Keys, ParentCertKinds),
    Pending = quod_simplex:dispatch(leader(2, Keys), {propose, Parent, []}, Certified),
    {ParentHash, Token, Owner} = take_request(2),
    {Child, ChildHash} = receipt_child(F, 3, 2),
    {Parent, ParentHash, Token, Owner, Child, ChildHash, Pending}.

receipt_child(F, Slot, Sequence) ->
    Target = maps:get(origin, F),
    ChildFixture = receipt_fixture(F, Slot),
    {ok, Control} = quod_dtx:sign_control(Target, maps:get('begin', ChildFixture),
                       maps:get(admission, F), Sequence, 1, maps:get(node_identity, F)),
    {ok, Blob} = quod_dtx:encode_control(Control),
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, {batch, [{dtx, Blob}]}, quod_time:now_ms()),
    {Block, quod_simplex:block_hash(Block)}.

receipt_fixture(F, Slot) ->
    %% The parent Begin still owns its prepared writes. A different proof ID
    %% alone leaves the default saved/1 write conflict unchanged; sign genuinely
    %% disjoint request/plan material so this fixture can validly commit both.
    Goal = iolist_to_binary(["assertz(receipt_slot_", integer_to_list(Slot), "(ok))."]),
    quod_ct:signed_dtx_begin_fixture(
                     #{target => maps:get(origin, F), network => maps:get(network, F),
                       node_identity => maps:get(node_identity, F),
                       admission => maps:get(admission, F), proof_id => <<Slot:256>>,
                       operation_id => <<Slot:256>>, goal_text => Goal}).

receipt_content(F, Slot, Sequence) ->
    {Ns, Anchor} = maps:get(origin, F),
    Transaction = maps:get(transaction, receipt_fixture(F, Slot)),
    {ok, Signed} = quod_transaction:sign(
                     {Ns, Anchor, maps:get(admission, F)},
                     Transaction#transaction{author_seq = Sequence, sig = none, signed_bytes = none},
                     maps:get(node_identity, F)),
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, {batch, [Signed]}, quod_time:now_ms()),
    {Block, quod_simplex:block_hash(Block)}.

receipt_content_parent(F, S0, Keys) ->
    {ok, Parent} = quod_ledger:new_block(2, 1, {batch, [maps:get(transaction, F)]}, quod_time:now_ms()),
    Hash = quod_simplex:block_hash(Parent),
    Proposed = quod_simplex:dispatch(leader(2, Keys), {propose, Parent, []}, S0),
    Owner = self(),
    receive
        {'$gen_cast', {content_verdict_req, [_], _, 2, Owner, {2, Hash}, _}} -> ok
    after 0 -> error(ordinary_parent_validation_not_delivered)
    end,
    Valid = callback_state(quod_simplex:running(info, {content_verdict, {2, Hash}, valid}, Proposed)),
    ?assertEqual({Hash, false, false}, quod_simplex:test_round(2, Valid)),
    ?assertEqual(1, maps:get(approved, quod_simplex:stats_map(Valid))),
    {Parent, Hash, Valid}.

receipt_membership_parent(F, S, Removed) ->
    {Ns, Anchor} = Target = maps:get(origin, F),
    {1, Store} = quod_simplex:test_committed_store(S),
    {ok, GenesisEntry} = quod_ledger_store:read_at(Store, 1),
    #entry{data = {batch, [Genesis]}} = quod_ledger:entry_view(GenesisEntry),
    %% Reconstruct the committed peer facts, not an empty signed-plan fixture.
    %% The sealed proof itself computes the retraction and its actual read set.
    Peers = [Head || {assert, {Head = {peer_admitted, _, _, _, _}, _}} <- Genesis#transaction.diff],
    Request = quod_ct:signed_goal_fixture(
                #{target => Target, network => maps:get(network, F),
                  operation_id => <<88:256>>,
                  goal_text => <<"findall(P,peer_admitted(P,_,_,P),Peers), "
                                 "sort(Peers,[_,Removed|_]), "
                                 "retract(peer_admitted(Removed,undefined,undefined,Removed)).">>}),
    Evidence = maps:get(evidence, Request),
    {ok, Goal} = quod_wire_term:materialize_symbols(maps:get(goal, Evidence)),
    Signer = maps:get(node_identity, F),
    Session = quod_proof_session:start(quod_ct:committed_kb(Peers),
                #{read_set => true, proof_context => {origin, membership_receipt}, signer => Signer}),
    try
        Invocation = <<88:128>>,
        Context = quod_predicates:proof_context(Ns, 1, undefined, [Target]),
        ok = quod_proof_session:open(Session, Invocation, Goal, allowed, Context,
                                    quod_transaction_scope:empty_selection()),
        {solution, _} = quod_proof_session:next(Session, Invocation),
        {ok, Bindings} = quod_proof_session:bindings(Session, Invocation),
        {ok, Named} = quod_client_goal:durable_bindings(Evidence, Bindings),
        %% The self member can carry an advertised endpoint. Identity selection
        %% must include it before sorting, just as Simplex leader/2 does.
        ?assertEqual(lists:sort([Pk || {peer_admitted, Pk, _, _, Pk} <- Peers]),
                     lists:sort(maps:get(<<"Peers">>, Named))),
        ?assertEqual(Removed, maps:get(<<"Removed">>, Named)),
        {ok, ResultBlob} = quod_durable_term:encode_result(Named),
        {ok, Plan} = quod_dtx:seal_session(Session,
                      #{target => Target, origin => Target, base_height => 1,
                        proof_id => <<88:256>>, principal => maps:get(principal, Request),
                        request_binding => maps:get(binding, Request)}),
        ?assert(quod_dtx:verify(Plan)),
        {ok, Material} = quod_dtx:material(Plan),
        ?assertMatch([{retract, {{peer_admitted, Removed, undefined, undefined, Removed}, _}}],
                     maps:get(diff, Material)),
        Unsigned = quod_transaction:from_plan(Plan, Material, maps:get(goal_blob, Request),
                                              ResultBlob, maps:get(auth, Request)),
        {ok, Transaction} = quod_transaction:sign(
                              {Ns, Anchor, maps:get(admission, F)},
                              Unsigned#transaction{author = maps:get(pubkey, Signer),
                                                   author_seq = 1, submitted_at = 1}, Signer),
        {ok, Block} = quod_ledger:new_block(2, 1, {batch, [Transaction]}, quod_time:now_ms()),
        {Block, quod_simplex:block_hash(Block)}
    after quod_proof_session:stop(Session) end.

receipt_junk(Block) -> receipt_junk(Block, <<0:512>>).

receipt_junk(Block = #block{slot = Slot, parent = Parent, payload = {batch, [{dtx, Blob}]}}, Sig) ->
    {ok, Control} = quod_dtx:decode_control(Blob),
    {ok, JunkBlob} = quod_dtx:encode_control(setelement(10, Control, Sig)),
    {ok, Junk} = quod_ledger:new_block(Slot, Parent, {batch, [{dtx, JunkBlob}]}, Block#block.timestamp),
    Junk.

assert_receipt_offer(Slot, Hash, Block, S) ->
    ?assertEqual({none, none, {offered, Hash, Block}, none, undefined},
                 quod_simplex:test_dtx_round(Slot, S)),
    ?assertEqual({none, false, false}, quod_simplex:test_round(Slot, S)),
    ?assertEqual([], quod_simplex:test_dtx_round_hints(Slot, S)),
    ?assertNot(maps:is_key(Slot, quod_signing_journal:rounds(quod_simplex:test_signing_journal(S)))).

receipt_repeat(Block = #block{slot = Slot}, Keys, Before, S) ->
    lists:foldl(fun(_, Acc) ->
        Proposed = quod_simplex:dispatch(leader(Slot, Keys), {propose, Block, []}, Acc),
        %% Repeated observation of the same durable/capability edge must not
        %% create fresh authentication or a new request/deadline.
        quod_simplex:settle_readiness(Before, Proposed)
    end, S, lists:seq(1, 20)).

with_receipt_recovery(F, Fun) ->
    {Ns, _} = maps:get(origin, F),
    true = quod_reg:reg({quod_simplex, Ns}),
    true = quod_reg:reg({quod_catchup, Ns}),
    try Fun()
    after
        gproc:unreg(quod_reg:name({quod_simplex, Ns})),
        gproc:unreg(quod_reg:name({quod_catchup, Ns}))
    end.

receipt_certificates(Block = #block{slot = Slot}, Kinds, F, Keys, S) ->
    {Ns, Anchor} = maps:get(origin, F),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Hash = quod_simplex:block_hash(Block),
    Committee = lists:sort(maps:keys(Keys)),
    lists:foldl(fun(Kind, Acc) ->
        Shares = [quod_simplex:make_share(Domain, Kind, Slot, Hash, maps:get(P, Keys))
                  || P <- lists:sublist(Committee, 3)],
        {ok, Cert} = quod_simplex:form_cert(Domain, Kind, Slot, Hash, Shares, Committee),
        quod_simplex:dispatch(hd(Committee), {cert, Cert}, Acc)
    end, S, Kinds).

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
    with_fixture(#{}, Fun).

with_fixture(GenesisOptions, Fun) ->
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
        maps:merge(#{mode => create, committee => Committee, genesis_diff => []}, GenesisOptions),
        Ns, Author),
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
