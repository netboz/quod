-module(quod_simplex_tests).
-moduledoc """
Pure-logic unit tests for `quod_simplex`'s DispersedSimplex consensus core — the parts that must be
correct independently of the network: quorum math, share signing, certificate formation + trustless
verification (incl. the Byzantine rejections), and the commit-vs-complaint guard. Uses real Ed25519
keypairs, so the crypto path is exercised end-to-end. Real multi-node QUIC behavior and restart recovery
are covered by `simplex_SUITE`.
""".
-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").

-export([canonical_block_fixture/1]).

%% Every ordinary consensus fixture belongs to one explicit chain domain. Tests
%% that exercise cross-namespace/genesis replay derive their foreign domains
%% separately and must never rely on an implicit/default signature context.
-define(FIXTURE_ERA, <<7:256>>).
-define(DOMAIN, <<16#51:256>>).

era_vote_bytes_bind_kind_chain_era_view_and_value_test() ->
    Era = <<7:256>>, Hash = <<8:256>>,
    ?assertEqual(<<"quod/simplex/share", 0, 3, ?DOMAIN/binary, Era/binary,
                   $S, 19:64, Hash/binary>>,
                 quod_simplex:share_bytes(?DOMAIN, support, {Era, 19}, Hash)),
    ?assertEqual(<<"quod/simplex/share", 0, 3, ?DOMAIN/binary, Era/binary,
                   $X, 19:64>>,
                 quod_simplex:share_bytes(?DOMAIN, complaint, {Era, 19}, none)).

era_vote_cannot_be_reused_at_the_same_view_in_another_era_test() ->
    {_Pub, Id} = id(), Era = <<7:256>>, Hash = <<8:256>>,
    Share = quod_simplex:make_share(?DOMAIN, commit, {Era, 19}, Hash, Id),
    ?assert(quod_simplex:verify_share(?DOMAIN, Share)),
    lists:foreach(fun(Other) ->
        ?assertNot(quod_simplex:verify_share(?DOMAIN, Other))
    end, [Share#share{era = <<9:256>>}, Share#share{slot = 20},
          Share#share{block_hash = <<10:256>>}, Share#share{kind = support},
          Share#share{era = undefined}, Share#share{slot = 0}]),
    ?assertNot(quod_simplex:verify_share(<<10:256>>, Share)).

era_certificate_cannot_mix_eras_or_duplicate_signers_test() ->
    Committee = committee(4), Era = <<7:256>>, Hash = <<8:256>>,
    Shares = [quod_simplex:make_share(?DOMAIN, commit, {Era, 19}, Hash, Id)
              || {_, Id} <- Committee],
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN, commit, {Era, 19}, Hash,
                                       take(3, Shares), pubs(Committee)),
    ?assert(quod_simplex:verify_cert(?DOMAIN, Cert, pubs(Committee))),
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, Cert#cert{era = <<9:256>>}, pubs(Committee))),
    [First, Second, Third | _] = Shares,
    lists:foreach(fun(Insufficient) ->
        ?assertEqual({error, insufficient},
          quod_simplex:form_cert(?DOMAIN, commit, {Era, 19}, Hash,
                                Insufficient, pubs(Committee)))
    end, [[First, First, Second], [First, Second, Third#share{era = <<9:256>>}]]).

era_complaint_has_no_value_and_never_becomes_a_commit_test() ->
    Committee = committee(4), Era = <<7:256>>,
    Shares = [quod_simplex:make_share(?DOMAIN, complaint, {Era, 19}, none, Id)
              || {_, Id} <- Committee],
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN, complaint, {Era, 19}, none,
                                       Shares, pubs(Committee)),
    ?assert(quod_simplex:verify_cert(?DOMAIN, Cert, pubs(Committee))),
    ?assertNot(quod_simplex:verify_cert(?DOMAIN,
                 Cert#cert{kind = commit, block_hash = <<8:256>>}, pubs(Committee))),
    ?assertNot(quod_simplex:verify_cert(?DOMAIN,
                 Cert#cert{block_hash = <<8:256>>}, pubs(Committee))).

era_eight_voter_split_recovers_without_changing_parent_votes_test() ->
    Committee = committee(8), Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    Dir = filename:join("/tmp", "quod_era_split_" ++
                         integer_to_list(erlang:unique_integer([positive]))),
    {ok, Parent} = quod_ledger:new_block({Era, 1}, Root, 2,
                                         {batch, [tx([{assert, {{kept, value}, true}}])]}, 1),
    {ok, Child} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(Parent), (Parent)#block.height, empty, 1),
    try
        Journals = [begin
            Path = filename:join(Dir, integer_to_list(I)),
            {ok, J} = quod_signing_journal:initialize(<<"t">>, ?DOMAIN, Path),
            {Member, Path, J}
        end || {I, Member} <- lists:zip(lists:seq(1, 8), Committee)],
        {Supported, SupportShares} = era_journal_support(Parent, Journals),
        {E1, _} = quod_simplex:eng_offer({block, Parent},
                    quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 1, 0})),
        {E2, _} = feed_shares(SupportShares, E1),
        Choices = lists:duplicate(3, commit) ++ lists:duplicate(5, complaint),
        {Voted, FinalShares} = era_journal_finals(Parent, Choices, Supported),
        {Stalled, ParentEvents} = feed_shares(FinalShares, E2),
        ?assertEqual([], [B || {committed, _, B} <- ParentEvents]),
        Before = [maps:get({Era, 1}, quod_signing_journal:rounds(J)) || {_, _, J} <- Voted],
        Restarted = [begin
            ok = quod_signing_journal:close(J),
            {ok, Recovered} = quod_signing_journal:recover(<<"t">>, ?DOMAIN, Path),
            {Member, Path, Recovered}
        end || {Member, Path, J} <- Voted],
        {ChildSupported, ChildShares} = era_journal_support(Child, Restarted),
        {E3, _} = quod_simplex:eng_offer({block, Child}, Stalled),
        {E4, _} = feed_shares(ChildShares, E3),
        {Finished, Commits} = era_journal_finals(Child, lists:duplicate(8, commit), ChildSupported),
        {Final, Events} = feed_shares(Commits, E4),
        ?assertEqual([Parent, Child], [B || {committed, _, B} <- Events]),
        ?assertEqual([Parent], [B || {committed, _, B = #block{payload = {batch, _}}} <- Events]),
        ?assertEqual(Before,
          [maps:get({Era, 1}, quod_signing_journal:rounds(J)) || {_, _, J} <- Finished]),
        {_Same, Duplicates} = feed_shares(FinalShares ++ Commits, Final),
        ?assertEqual([], [B || {committed, _, B} <- Duplicates]),
        lists:foreach(fun({_, _, J}) -> quod_signing_journal:close(J) end, Finished)
    after
        file:del_dir_r(Dir)
    end.

era_stacked_splits_allow_a_third_view_with_a_silent_voter_test() ->
    Committee = committee(4), Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    {ok, First} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [tx([])]}, 1),
    {ok, Second} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(First), (First)#block.height, empty, 1),
    {ok, Third} = quod_ledger:new_block({Era, 3}, quod_ledger:block_ref(Second), (Second)#block.height, empty, 1),
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 1, 0}),
    Split = fun(Block, E) ->
        {Added, _} = quod_simplex:eng_offer({block, Block}, E),
        {Notarized, _} = feed_shares(era_shares(support, Block, Committee), Added),
        {Next, Events} = feed_shares(
          era_shares(commit, Block, take(2, Committee)) ++
          era_shares(complaint, Block, lists:nthtail(2, Committee)), Notarized),
        ?assertEqual([], [B || {committed, _, B} <- Events]), Next
    end,
    E2 = Split(Second, Split(First, E0)),
    {E3, _} = quod_simplex:eng_offer({block, Third}, E2),
    {E4, _} = feed_shares(era_shares(support, Third, take(3, Committee)), E3),
    {_Final, Events} = feed_shares(era_shares(commit, Third, take(3, Committee)), E4),
    ?assertEqual([First, Second, Third], [B || {committed, _, B} <- Events]).

era_complaint_certificate_advances_without_a_ledger_result_test() ->
    Committee = committee(4), Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    {ok, Failed} = quod_ledger:new_block({Era, 1}, Root, 1, empty, 1),
    {E1, Events} = feed_shares(era_shares(complaint, Failed, Committee),
                               quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 1, 0})),
    ?assert(lists:member({view_advanced, 1, complaint}, Events)),
    ?assertEqual([], [B || {committed, _, B} <- Events]),
    ?assertEqual([], [V || {skipped, V} <- Events]),
    {ok, Next} = quod_ledger:new_block({Era, 2}, Root, 2, {batch, [tx([])]}, 1),
    {E2, _} = quod_simplex:eng_offer({block, Next}, E1),
    {E3, _} = feed_shares(era_shares(support, Next, Committee), E2),
    {_E4, Committed} = feed_shares(era_shares(commit, Next, Committee), E3),
    ?assertEqual([Next], [B || {committed, _, B} <- Committed]).

era_terminal_membership_refuses_material_descendants_test() ->
    Committee = committee(4), Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    {ok, Membership} = quod_ledger:new_block({Era, 1}, Root, 2,
                                            {batch, [tx([pa(<<9:256>>)])]}, 1),
    {E1, _} = quod_simplex:eng_offer({block, Membership},
                                  quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 1, 0})),
    {E2, _} = feed_shares(era_shares(support, Membership, Committee), E1),
    {ok, Illegal} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(Membership), (Membership)#block.height + 1,
                                         {batch, [tx([])]}, 1),
    {E3, _} = quod_simplex:eng_offer({block, Illegal}, E2),
    {E4, Events} = feed_shares(era_shares(support, Illegal, Committee), E3),
    ?assertEqual([], [B || {notarized, B} <- Events]),
    ?assertNot(maps:is_key(2, quod_simplex:eng_tree(E4))),
    %% A peer's impossible commit QC does not bypass the same complete-tree
    %% semantic check. This is a rejection control, not an honest schedule.
    {_E5, FinalEvents} = feed_shares(era_shares(commit, Illegal, Committee), E4),
    ?assertEqual([], [B || {committed, _, B} <- FinalEvents]).

signed_material_height_is_checked_before_support_and_tree_installation_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = [{Self, Signer} | _] = committee(4),
    Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 900, 0}),
    Links = maps:from_list([{Pub, {self(), make_ref()}} || {Pub, _} <- Committee, Pub =/= Self]),
    Owner = st(#{self => Self, id => Signer, validators => pubs(Committee),
                 eng => E0, sync => ready, slot => 900, history_head => {900, element(3, Root)},
                 conns => Links}),
    lists:foreach(fun({Payload, Heights}) ->
        lists:foreach(fun(Height) ->
            {ok, Wrong} = quod_ledger:new_block({Era, 1}, Root, Height, Payload, 0),
            Refused = quod_simplex:dispatch(quod_simplex:leader(1, pubs(Committee)),
                                           {propose, Wrong, []}, Owner),
            ?assertEqual({none, false, false}, quod_simplex:test_round(1, Refused)),
            {Added, _} = quod_simplex:eng_offer({block, Wrong}, E0),
            {Rejected, Events} = feed_shares(era_shares(support, Wrong, Committee), Added),
            ?assertEqual(#{}, quod_simplex:eng_tree(Rejected)),
            ?assertEqual([], [B || {notarized, B} <- Events])
        end, Heights)
    end, [{empty, [899, 901]}, {{batch, [tx([])]}, [900, 902]}]),
    {ok, Correct} = quod_ledger:new_block({Era, 1}, Root, 900, empty, 0),
    Accepted = quod_simplex:dispatch(quod_simplex:leader(1, pubs(Committee)),
                                    {propose, Correct, []}, Owner),
    ?assertMatch({<<_:256>>, false, false}, quod_simplex:test_round(1, Accepted)),
    flush_consensus_fixture_frames().

era_delayed_parent_wakes_its_certified_child_once_test() ->
    Committee = committee(4), Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    {ok, Parent} = quod_ledger:new_block({Era, 1}, Root, 1, empty, 0),
    {ok, Child} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(Parent), (Parent)#block.height, empty, 0),
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 1, 0}),
    {E1, _} = quod_simplex:eng_offer({block, Child}, E0),
    {E2, _} = feed_shares(era_shares(support, Child, Committee), E1),
    {E3, Waiting} = feed_shares(era_shares(commit, Child, Committee), E2),
    ?assertEqual([], [B || {committed, _, B} <- Waiting]),
    {E4, _} = quod_simplex:eng_offer({block, Parent}, E3),
    {E5, Ready} = feed_shares(era_shares(support, Parent, Committee), E4),
    ?assertEqual([Parent, Child], [B || {notarized, B} <- Ready]),
    ?assertEqual([Parent, Child], [B || {committed, _, B} <- Ready]),
    {_E6, Duplicate} = feed_shares(era_shares(support, Parent, Committee), E5),
    ?assertEqual([], Duplicate).

era_gapped_parent_waits_for_every_complaint_test() ->
    Committee = committee(4), Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    {Past, E1, _} = lists:foldl(fun(V, {Bs, Eng, Ref}) ->
        {ok, B} = quod_ledger:new_block({Era, V}, Ref, 1, empty, 0),
        {Added, _} = quod_simplex:eng_offer({block, B}, Eng),
        {Notarized, _} = feed_shares(era_shares(support, B, Committee), Added),
        {[B | Bs], Notarized, quod_ledger:block_ref(B)}
    end, {[], quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 1, 0}), Root}, lists:seq(1, 32)),
    {ok, Skipping} = quod_ledger:new_block({Era, 33}, Root, 1, empty, 0),
    {E2, _} = quod_simplex:eng_offer({block, Skipping}, E1),
    {E3, Waiting} = feed_shares(era_shares(support, Skipping, Committee), E2),
    ?assertEqual([], [B || {notarized, B} <- Waiting]),
    [First | Rest] = lists:reverse(Past),
    %% Out-of-order complaint certificates do not grant a partial gap. The
    %% missing first certificate is delivered last, then one exact waiter wakes.
    E4 = lists:foldl(fun(B, Eng) ->
        {Next, Events} = feed_shares(era_shares(complaint, B, Committee), Eng),
        ?assertEqual([], [X || {notarized, X} <- Events]), Next
    end, E3, lists:reverse(Rest)),
    {E5, Ready} = feed_shares(era_shares(complaint, First, Committee), E4),
    ?assertEqual([Skipping], [B || {notarized, B} <- Ready]),
    {_E6, Final} = feed_shares(era_shares(commit, Skipping, Committee), E5),
    ?assertEqual([Skipping], [B || {committed, _, B} <- Final]).

era_settlement_work_does_not_rescan_the_unfinished_prefix_test_() ->
    {timeout, 30, fun() ->
        Small = era_settlement_work(128), Large = era_settlement_work(512),
        %% Four times the work should remain near four times the reductions.
        %% The previous whole-pool scan needed >14 times on these same inputs.
        ?assert(Large < Small * 6)
    end}.

era_settlement_work(Count) ->
    Committee = committee(4), Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    {Rev, _} = lists:foldl(fun(V, {Acc, Ref}) ->
        {ok, B} = quod_ledger:new_block({Era, V}, Ref, 1, empty, 0),
        {ok, Cert} = quod_simplex:form_cert(?DOMAIN, support, {Era, V},
          element(3, quod_ledger:block_ref(B)), era_shares(support, B, Committee), pubs(Committee)),
        {[{B, Cert} | Acc], quod_ledger:block_ref(B)}
    end, {[], Root}, lists:seq(1, Count)),
    Inputs = lists:reverse(Rev), E0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 1, 0}),
    erlang:garbage_collect(),
    {reductions, Before} = process_info(self(), reductions),
    _ = lists:foldl(fun({B, Cert}, Eng) ->
        {E1, _} = quod_simplex:eng_offer({block, B}, Eng),
        {E2, _} = quod_simplex:eng_offer({cert, Cert}, E1), E2
    end, E0, Inputs),
    {reductions, After} = process_info(self(), reductions),
    After - Before.

era_cold_recovery_resumes_after_archived_carriers_test() ->
    era_cold_recovery_case(false).

era_cold_recovery_seals_only_the_certified_old_era_test() ->
    era_cold_recovery_case(true).

era_cold_recovery_refuses_bad_history_before_retiring_any_vote_test() ->
    era_cold_recovery_case(bad_certificate).

era_cold_recovery_refuses_a_witness_with_unarchived_material_test() ->
    era_cold_recovery_case(incomplete_material).

era_cold_recovery_case(Mode) ->
    Membership = Mode =:= true,
    Ns = <<"quod:cold-protocol-custody">>, F = quod_ct:protocol_fixture(Ns),
    {Ns, Anchor} = Binding = maps:get(identity, F), Era = maps:get(era, F),
    Signer = maps:get(signer, F), Pub = maps:get(pubkey, Signer),
    Tx0 = maps:get(transaction, F),
    Tx = case Membership of
        false -> Tx0;
        true ->
            Diff = [{assert, {{peer_admitted, Pub, <<"localhost">>, 1, Pub}, true}}],
            Unsigned = quod_transaction:bind_id(Binding,
                Tx0#transaction{diff = Diff, sig = none, signed_bytes = none, authentication = none}),
            {ok, Signed} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, Unsigned, Signer),
            Signed
    end,
    Root = {Era, 0, Anchor},
    {ok, Material} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [Tx]}, 1),
    {Proof, _} = lists:foldl(fun(V, {Bs, Parent}) ->
        {ok, B} = quod_ledger:new_block({Era, V}, Parent, 2, empty, 1),
        {[B | Bs], quod_ledger:block_ref(B)}
    end, {[Material], quod_ledger:block_ref(Material)}, lists:seq(2, 19)),
    RecoveryProof = case Mode of
        incomplete_material ->
            UnsignedNext = quod_transaction:bind_id(Binding,
                Tx0#transaction{author_seq = 2, proof_id = <<22:256>>, sig = none,
                                signed_bytes = none, authentication = none}),
            {ok, NextTx} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, UnsignedNext, Signer),
            {ok, Unarchived} = quod_ledger:new_block({Era, 20}, quod_ledger:block_ref(hd(Proof)), (hd(Proof))#block.height + 1,
                                                    {batch, [NextTx]}, 2),
            [Unarchived | Proof];
        _ -> Proof
    end,
    Head = hd(RecoveryProof), Cert = quod_ct:protocol_certificate(Head, F),
    Entry = quod_ledger:entry(2, Material, Cert),
    NextEra = quod_ledger:next_era(Binding, Era, element(3, quod_ledger:block_ref(Material))),
    Future = <<91:256>>, Positions = [{Era, 1}, {Era, 19}, {Era, 20}, {NextEra, 1}, {Future, 1}],
    Dir = filename:join("/tmp", "quod_cold_protocol_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    try
        {ok, J0} = quod_signing_journal:initialize(Ns, Domain, Dir),
        J1 = lists:foldl(fun(Pos, J) ->
            {ok, Next} = quod_signing_journal:record_vote(J, complaint, Pos, none), Next
        end, J0, Positions),
        ok = quod_signing_journal:close(J1),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [quod_ledger:entry(1, maps:get(genesis, F), none)]}),
        Bytes = [quod_ledger:block_bytes(B) || B <- RecoveryProof],
        Source = {lists:sum([13 + byte_size(B) || B <- Bytes]),
                  fun([]) -> done; ([B | Rest]) -> {B, Rest} end, Bytes},
        {ok, S2} = quod_ledger_store:append(S1, {Source, [Entry]}),
        SFinal = case Mode of
            bad_certificate ->
                Unsigned2 = quod_transaction:bind_id(Binding,
                    Tx0#transaction{author_seq = 2, sig = none, signed_bytes = none, authentication = none}),
                {ok, Tx2} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, Unsigned2, Signer),
                {ok, B20} = quod_ledger:new_block({Era, 20}, quod_ledger:block_ref(Head), (Head)#block.height + 1, {batch, [Tx2]}, 2),
                BadCert = (quod_ct:protocol_certificate(B20, F))#cert{sigs = [{Pub, <<0:512>>}]},
                Bytes20 = quod_ledger:block_bytes(B20),
                NewSource = {13 + byte_size(Bytes20), fun([]) -> done; ([B | R]) -> {B, R} end, [Bytes20]},
                {ok, Appended} = quod_ledger_store:append(S2,
                     {{extend, NewSource, 2}, [quod_ledger:entry(3, B20, BadCert)]}),
                Appended;
            _ -> S2
        end,
        ok = quod_ledger_store:close(SFinal),
        Cfg = #{mode => join, genesis_hash => Anchor, data_dir => Dir},
        case Mode of
            Invalid when Invalid =:= bad_certificate; Invalid =:= incomplete_material ->
                ExpectedError = case Invalid of
                    bad_certificate -> {bad_cert, 3};
                    incomplete_material -> {incomplete_material_group, 2}
                end,
                ?assertException(error, ExpectedError,
                                  quod_simplex:test_restore_storage(Ns, Cfg, Pub)),
                {ok, Untouched} = quod_signing_journal:recover(Ns, Domain, Dir),
                ?assertEqual(lists:sort(Positions),
                             lists:sort(maps:keys(quod_signing_journal:rounds(Untouched)))),
                ok = quod_signing_journal:close(Untouched);
            _ ->
        #{height := 2, archive_tip := Tip, rounds := Rounds, projection := Projection} =
            quod_simplex:test_restore_storage(Ns, Cfg, Pub),
        ExpectedTip = case Membership of
            false -> {quod_ledger:block_ref(Head), 1};
            true -> {{NextEra, 0, element(3, quod_ledger:block_ref(Material))}, 1}
        end,
        ?assertEqual(ExpectedTip, Tip),
        ExpectedRounds = case Membership of
            false -> [{Era, 20}, {NextEra, 1}, {Future, 1}];
            true -> [{NextEra, 1}, {Future, 1}]
        end,
        ?assertEqual(lists:sort(ExpectedRounds), lists:sort(maps:keys(Rounds))),
        ?assertEqual({2, element(3, quod_ledger:block_ref(Material))}, maps:get(history_head, Projection)),
        %% Repeat the actual startup fold after any journal compaction. Its
        %% retirement authority must be identical, not inferred from height 2.
        Again = quod_simplex:test_restore_storage(Ns, Cfg, Pub),
        ?assertEqual(Tip, maps:get(archive_tip, Again)),
        ?assertEqual(Cert, maps:get(archive_certificate, Again)),
        ?assertEqual(Rounds, maps:get(rounds, Again)),
        E0 = quod_simplex:eng_new(Domain, [Pub], {element(1, Tip), 2, element(2, Tip)}),
        {Same, OldEvents} = quod_simplex:eng_offer({block, Head}, E0),
        ?assertEqual(E0, Same), ?assertEqual([], OldEvents)
        end
    after file:del_dir_r(Dir) end.

era_carriers_inherit_time_in_live_and_pruned_engines_test() ->
    Committee = committee(4), Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    {ok, Material} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [tx([])]}, 7),
    {E1, _} = quod_simplex:eng_offer({block, Material},
                              quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 1, 0})),
    {E2, _} = feed_shares(era_shares(support, Material, Committee), E1),
    Pruned = quod_simplex:eng_prune(quod_ledger:block_ref(Material), E2),
    lists:foreach(fun(Engine) ->
        lists:foreach(fun(Time) ->
            {ok, Carrier} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(Material), (Material)#block.height, empty, Time),
            {Added, _} = quod_simplex:eng_offer({block, Carrier}, Engine),
            {_, Events} = feed_shares(era_shares(support, Carrier, Committee), Added),
            ?assertEqual(case Time of 7 -> [Carrier]; _ -> [] end,
                         [B || {notarized, B} <- Events])
        end, [6, 7, 8])
    end, [E2, Pruned]).

era_material_parent_is_cached_across_carriers_and_pruning_test() ->
    Committee = committee(4), Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 1, 0}),
    {ok, Material} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [tx([])]}, 7),
    {E1, _} = quod_simplex:eng_offer({block, Material}, E0),
    {E2, _} = feed_shares(era_shares(support, Material, Committee), E1),
    {Engine, Head} = lists:foldl(fun(View, {Previous, Parent}) ->
        {ok, Carrier} = quod_ledger:new_block({Era, View}, quod_ledger:block_ref(Parent), (Parent)#block.height, empty, 7),
        {Added, _} = quod_simplex:eng_offer({block, Carrier}, Previous),
        {Notarized, _} = feed_shares(era_shares(support, Carrier, Committee), Added),
        {Notarized, Carrier}
    end, {E2, Material}, lists:seq(2, 128)),
    Installed = {1, element(3, Root)},
    Expected = {2, element(3, quod_ledger:block_ref(Material))},
    S0 = quod_simplex:test_state(#{eng => Engine, slot => 1, history_head => Installed}),
    ?assertEqual(Expected, quod_simplex:protocol_parent_material(S0)),
    #transaction{author = Author, author_seq = Seq} = tx([]),
    ?assertEqual({ok, #{Author => Seq}}, quod_simplex:approved_author_seqs(S0)),
    ?assert(is_integer(quod_simplex:vote_timestamp(S0))),
    Pruned = quod_simplex:eng_prune(quod_ledger:block_ref(Head), Engine),
    S1 = quod_simplex:test_state(#{eng => Pruned, slot => 2, history_head => Expected,
                                  author_seqs => #{Author => Seq}}),
    ?assertEqual(Expected, quod_simplex:protocol_parent_material(S1)),
    ?assertEqual({ok, #{Author => Seq}}, quod_simplex:approved_author_seqs(S1)),
    {ok, Next} = quod_ledger:new_block({Era, 129}, quod_ledger:block_ref(Head), (Head)#block.height + 1,
                                     {batch, [tx([])]}, 8),
    {E3, _} = quod_simplex:eng_offer({block, Next}, Pruned),
    {E4, _} = feed_shares(era_shares(support, Next, Committee), E3),
    S2 = quod_simplex:test_state_set(eng, E4, S1),
    ?assertEqual({3, element(3, quod_ledger:block_ref(Next))},
                 quod_simplex:protocol_parent_material(S2)).

era_delayed_dtx_verdict_can_install_history_without_voting_in_an_old_view_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_ct:atomic_role_fixture(), {Ns, Anchor} = maps:get(origin, F),
    Signer = maps:get(signer, F), Self = maps:get(pubkey, Signer),
    Committee = [{Self, Signer} | committee(3)],
    Era = <<7:256>>, Root = {Era, 63, Anchor}, Token = {900, Anchor},
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Control = maps:get(source_control, F), Payload = {batch, [{dtx, Control}]},
    {ok, Block} = quod_ledger:new_block({Era, 64}, Root, 901, Payload, 1),
    Hash = element(3, quod_ledger:block_ref(Block)),
    Links = maps:from_list([{Pub, {self(), make_ref()}} || {Pub, _} <- Committee, Pub =/= Self]),
    Owner = quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
        self => Self, id => Signer, validators => pubs(Committee), consensus_domain => Domain,
        eng => quod_simplex:eng_new(Domain, pubs(Committee), {Root, 900, 0}),
        sync => ready, slot => 900, history_head => Token, conns => Links}),
    {_Monitor, Pending} = quod_simplex:test_latch_dtx_validation(64, Hash, Token, self(), Block, Owner),
    Shares = [quod_simplex:make_share(Domain, complaint, {Era, 64}, none, Id)
              || {Pub, Id} <- Committee, Pub =/= Self],
    Advanced = quod_simplex:engine_step([{share, Sh} || Sh <- Shares], Pending),
    ?assertEqual(65, maps:get(view, quod_simplex:test_protocol_position(Advanced))),
    Validated = quod_simplex:test_on_dtx_verdict(64, Hash, Token, self(), 900, {valid, #{}}, Advanced),
    ?assertMatch({none, none, {Hash, Block}, {Hash, Token, #{}, _}, Block},
                 quod_simplex:test_dtx_round(64, Validated)),
    ?assertEqual({none, false, false}, quod_simplex:test_round(64, Validated)),
    flush_consensus_fixture_frames().

era_complaint_replaces_placement_without_resolving_or_resigning_request_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = committee(4), Self = quod_simplex:leader(1, pubs(Committee)),
    Signer = proplists:get_value(Self, Committee),
    Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    Links = maps:from_list([{Pub, {self(), make_ref()}} || {Pub, _} <- Committee, Pub =/= Self]),
    Owner = st(#{self => Self, id => Signer, validators => pubs(Committee),
        eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 900, 0}),
        sync => ready, slot => 900, history_head => {900, element(3, Root)},
        conns => Links, relay_conns => Links}),
    From = {self(), make_ref()},
    {Collected, _} = quod_simplex:test_append(From, lt($s, Self), Owner),
    [{SubmissionId, 1, Submission, {local, 1}, Deadline, 1}] = quod_simplex:test_custody(Collected),
    ?assertEqual(quod_simplex:test_custody(Collected),
                 quod_simplex:test_custody(quod_simplex:reconcile_custody_lane(Collected))),
    Shares = [quod_simplex:make_share(?DOMAIN, complaint, {Era, 1}, none, Id)
              || {Pub, Id} <- Committee, Pub =/= Self],
    Advanced = quod_simplex:engine_step([{share, Sh} || Sh <- Shares], Collected),
    ?assertEqual(2, maps:get(view, quod_simplex:test_protocol_position(Advanced))),
    Ready = quod_simplex:reconcile_custody_lane(Advanced),
    ?assertEqual([{SubmissionId, 1, Submission, ready, Deadline, 1}], quod_simplex:test_custody(Ready)),
    ?assertEqual(900, element(1, quod_simplex:test_committed_store(Ready))),
    assert_no_reply(From),
    {Replaced, []} = quod_simplex:test_drain_custody(Ready),
    Target = quod_simplex:leader(2, pubs(Committee)),
    [{SubmissionId, 1, Submission, {relay, _AttemptId, Target, 2, Era}, Deadline, 2}] =
        quod_simplex:test_custody(Replaced),
    ?assertEqual(quod_simplex:test_custody(Replaced),
                 quod_simplex:test_custody(quod_simplex:reconcile_custody_lane(Replaced))),
    assert_no_reply(From),
    flush_consensus_fixture_frames().

healthy_notarization_waits_for_direct_finality_without_carrier_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = committee(4), Self = quod_simplex:leader(3, pubs(Committee)),
    Signer = proplists:get_value(Self, Committee),
    Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 900, 0}),
    Links = maps:from_list([{Pub, {self(), make_ref()}} || {Pub, _} <- Committee, Pub =/= Self]),
    Before = st(#{self => Self, id => Signer, validators => pubs(Committee),
        eng => E0, sync => ready, slot => 900, history_head => {900, element(3, Root)}, conns => Links}),
    {ok, Material} = quod_ledger:new_block({Era, 1}, Root, 901, {batch, [tx([])]}, 7),
    Entered = quod_simplex:engine_step([{block, Material} |
        [{share, Sh} || Sh <- era_shares(support, Material, Committee)]], Before),
    ?assertEqual(Entered, quod_simplex:drive_empty_proposal(Before, Entered)),
    Watching = quod_simplex:reconcile_head_progress(Entered),
    ?assertEqual({Era, 2, awaiting_proposal}, quod_simplex:test_progress(Watching)),
    %% The unchanged ordinary watchdog complains in view 2. A quorum of that
    %% complaint opens fresh view 3; it never commits in the timed-out view.
    TimedOut = quod_simplex:on_progress_timeout({Era, 2}, Watching),
    ?assertEqual({none, false, true}, quod_simplex:test_round(2, TimedOut)),
    Complaints = [quod_simplex:make_share(?DOMAIN, complaint, {Era, 2}, none, Id)
                  || {Pub, Id} <- Committee, Pub =/= Self],
    Advanced = quod_simplex:engine_step([{share, Sh} || Sh <- Complaints], TimedOut),
    Proposed = quod_simplex:drive_empty_proposal(TimedOut, Advanced),
    {Hash, false, false} = quod_simplex:test_round(3, Proposed),
    {ok, Expected} = quod_ledger:new_block({Era, 3}, quod_ledger:block_ref(Material), 901, empty, 7),
    ?assertEqual(element(3, quod_ledger:block_ref(Expected)), Hash),
    ?assertEqual(Proposed, quod_simplex:drive_empty_proposal(TimedOut, Proposed)),
    ?assertEqual(Proposed, quod_simplex:drive_empty_proposal(Proposed, Proposed)),
    ?assertEqual(900, element(1, quod_simplex:test_committed_store(Proposed))),
    %% Direct finality arriving before recovery selection removes the need.
    {E1, _} = quod_simplex:eng_offer({block, Material}, E0),
    {E2, _} = feed_shares(era_shares(support, Material, Committee), E1),
    Final = st(#{self => Self, id => Signer, validators => pubs(Committee),
        eng => quod_simplex:eng_prune(quod_ledger:block_ref(Material), E2), sync => ready,
        slot => 901, history_head => {901, element(3, quod_ledger:block_ref(Material))}, conns => Links}),
    ?assertEqual(Final, quod_simplex:drive_empty_proposal(Before, Final)),
    flush_consensus_fixture_frames().

era_owner_admits_carriers_without_consuming_material_window_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = committee(4), [{Self, Signer} | _] = Committee,
    Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 900, 0}),
    {Engine, Head} = lists:foldl(fun(View, {Previous, Parent}) ->
        Payload = case View =< 2 of true -> {batch, [tx([])]}; false -> empty end,
        {ok, B} = quod_ledger:new_block({Era, View}, Parent, 900 + min(View, 2), Payload, 0),
        {Added, _} = quod_simplex:eng_offer({block, B}, Previous),
        {Notarized, _} = feed_shares(era_shares(support, B, Committee), Added),
        {Notarized, quod_ledger:block_ref(B)}
    end, {E0, Root}, lists:seq(1, 64)),
    Links = maps:from_list([{Pub, {self(), make_ref()}} || {Pub, _} <- Committee, Pub =/= Self]),
    Owner = quod_simplex:test_state(#{self => Self, id => Signer, validators => pubs(Committee),
        eng => Engine, sync => ready, slot => 900, history_head => {900, element(3, Root)}, conns => Links}),
    ?assertEqual(blocked, quod_simplex:proposal_slot(Owner)),
    Leader = quod_simplex:leader(65, pubs(Committee)),
    {ok, Good} = quod_ledger:new_block({Era, 65}, Head, 902, empty, 0),
    Accepted = quod_simplex:dispatch(Leader, {propose, Good, []}, Owner),
    ?assertEqual({element(3, quod_ledger:block_ref(Good)), false, false},
                 quod_simplex:test_round(65, Accepted)),
    ?assertEqual(900, element(1, quod_simplex:test_committed_store(Accepted))),
    lists:foreach(fun({Position, Parent, Time}) ->
        {ok, Bad} = quod_ledger:new_block(Position, Parent, 902, empty, Time),
        Rejected = quod_simplex:dispatch(Leader, {propose, Bad, []}, Owner),
        ?assertEqual({none, false, false}, quod_simplex:test_round(65, Rejected))
    end, [{{Era, 65}, {Era, 64, <<99:256>>}, 0},
          {{Era, 65}, Head, 1},
          {{Era, 65}, Root, 0},
          {{<<8:256>>, 65}, {<<8:256>>, 64, element(3, Head)}, 0}]),
    flush_consensus_fixture_frames().

%% Empty finality closes proposer work without inventing a material entry.
%% Keeping its local proposal alive makes an idle ontology complain forever.
finalized_empty_proposal_retires_watchdog_and_periodic_shares_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = [{Self, Signer} | _] = committee(4),
    Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    {ok, Empty} = quod_ledger:new_block({Era, 1}, Root, 500, empty, 0),
    Links = maps:from_list([{Pub, {self(), make_ref()}} || {Pub, _} <- Committee, Pub =/= Self]),
    Owner = st(#{self => Self, id => Signer, validators => pubs(Committee),
        eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 500, 0}),
        sync => ready, slot => 500, history_head => {500, element(3, Root)},
        protocol_root => Root, conns => Links}),
    Proposed = quod_simplex:dispatch(quod_simplex:leader(1, pubs(Committee)),
                                    {propose, Empty, []}, Owner),
    Notarized = quod_simplex:engine_step(
        [{share, Sh} || Sh <- era_shares(support, Empty, Committee)], Proposed),
    Hash = element(3, quod_ledger:block_ref(Empty)),
    ?assertEqual({Hash, true, false}, quod_simplex:test_round(1, Notarized)),
    flush_consensus_fixture_frames(),
    _ = quod_simplex:redrive_inflight(Notarized),
    ?assertMatch([_ | _], captured_consensus_messages()),
    Settled = quod_simplex:engine_step(
        [{share, Sh} || Sh <- era_shares(commit, Empty, Committee)], Notarized),
    ?assertEqual(idle, quod_simplex:test_progress(quod_simplex:reconcile_head_progress(Settled))),
    ?assertEqual(500, element(1, quod_simplex:test_committed_store(Settled))),
    ?assertEqual({Hash, true, false}, quod_simplex:test_round(1, Settled)),
    Pool = quod_simplex:test_engine_pool_sizes(Settled),
    Journal = quod_simplex:test_signing_journal(Settled),
    flush_consensus_fixture_frames(),
    lists:foreach(fun(_) ->
        Same = quod_simplex:redrive_inflight(Settled),
        ?assertEqual(Pool, quod_simplex:test_engine_pool_sizes(Same)),
        ?assertEqual(Journal, quod_simplex:test_signing_journal(Same)),
        ?assertEqual([], captured_consensus_messages())
    end, lists:seq(1, 3)),
    Later = quod_simplex:reconcile_head_progress(quod_simplex:watch_requested(2, Settled)),
    ?assertEqual({Era, 2, awaiting_proposal}, quod_simplex:test_progress(Later)).

same_height_reconnect_recovers_empty_finality_without_periodic_shares_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = [{Self, SelfId}, {Peer, PeerId} | _] = lists:sort(committee(4)),
    Era = <<7:256>>, Root = {Era, 0, <<1:256>>}, Height = 500,
    {ok, Empty} = quod_ledger:new_block({Era, 1}, Root, Height, empty, 0),
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, Height, 0}),
    {E1, _} = quod_simplex:eng_offer({block, Empty}, E0),
    {E2, _} = feed_shares(era_shares(support, Empty, Committee), E1),
    {E3, _} = feed_shares(era_shares(commit, Empty, Committee), E2),
    Base = #{sync => ready, slot => Height, history_head => {Height, element(3, Root)},
             protocol_root => Root, validators => pubs(Committee)},
    Settled = st(Base#{self => Self, id => SelfId, eng => E3,
        inbound_conns => #{Peer => {self(), make_ref()}}}),
    Learner = st(Base#{self => Peer, id => PeerId, eng => E0,
        conns => #{Self => {self(), make_ref()}},
        inbound_conns => #{Self => {self(), make_ref()}}}),
    %% No material-height gap exists. The authenticated replacement stream's
    %% current protocol position alone requests the missing certificates.
    Notice = {readiness, Height, {Era, 1, 0}, true},
    Informed = quod_simplex:dispatch(Peer, Notice, Settled),
    ?assertEqual([], captured_consensus_messages()),
    Reconnected = running_state(quod_simplex:running(
        info, {link_up, Peer, term_to_binary({log, <<"t">>}, [deterministic]), self()}, Informed)),
    Certificates = [C || {cert, C} <- captured_consensus_messages()],
    ?assertEqual([commit, support], lists:sort([C#cert.kind || C <- Certificates])),
    Waiting = lists:foldl(fun(C, S) -> quod_simplex:dispatch(Self, {cert, C}, S) end,
                         Learner, Certificates),
    flush_consensus_fixture_frames(),
    Requested = quod_simplex:reconcile_block_requests(Waiting),
    [Request] = [M || M = {block_request, _, _} <- captured_consensus_messages()],
    _ = quod_simplex:dispatch(Peer, Request, Reconnected),
    [Reply] = [M || M = {certified_block, _, _} <- captured_consensus_messages()],
    Recovered = quod_simplex:dispatch(Self, Reply, Requested),
    ?assertEqual(2, maps:get(view, quod_simplex:test_protocol_position(Recovered))),
    ?assertEqual(Height, element(1, quod_simplex:test_committed_store(Recovered))),
    flush_consensus_fixture_frames(),
    _ = quod_simplex:redrive_inflight(Recovered),
    ?assertEqual([], captured_consensus_messages()),
    %% Duplicate positions and stale current-stream notices cannot restart the
    %% acquisition. A newly installed position is the only next wakeup.
    Advanced = quod_simplex:dispatch(Peer, {readiness, Height, {Era, 2, 1}, true}, Reconnected),
    ?assertEqual([], captured_consensus_messages()),
    _ = quod_simplex:dispatch(Peer, Notice, Advanced),
    _ = quod_simplex:dispatch(Peer, {readiness, Height, {Era, 2, 1}, true}, Advanced),
    ?assertEqual([], captured_consensus_messages()).

captured_consensus_messages() ->
    receive
        {send, Frame} ->
            {consensus, Message} = quod_relay:decode_consensus_frame(Frame, <<"t">>),
            [Message | captured_consensus_messages()];
        {send_ordered, Frame} ->
            {consensus, Message} = quod_relay:decode_consensus_frame(Frame, <<"t">>),
            [Message | captured_consensus_messages()]
    after 0 -> []
    end.

era_watchdog_tracks_view_without_quorum_grace_or_deadline_renewal_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = committee(4), [{Self, Signer} | _] = Committee,
    Era = <<7:256>>, Root = {Era, 63, <<1:256>>},
    Engine = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 900, 7}),
    Links = maps:from_list([{Pub, {self(), make_ref()}} || {Pub, _} <- Committee, Pub =/= Self]),
    Idle = quod_simplex:test_state(#{self => Self, id => Signer, validators => pubs(Committee),
        eng => Engine, sync => ready, slot => 900, history_head => {900, element(3, Root)}, conns => Links}),
    ?assertEqual(idle, quod_simplex:test_progress(quod_simplex:reconcile_head_progress(Idle))),
    Watching = quod_simplex:reconcile_head_progress(quod_simplex:watch_requested(64, Idle)),
    ?assertEqual({Era, 64, awaiting_proposal}, quod_simplex:test_progress(Watching)),
    ?assertMatch([{{timeout, progress}, _, {progress_timeout, {Era, 64}}}],
                 quod_simplex:progress_timer_actions(Idle, Watching)),
    Repeated = quod_simplex:reconcile_head_progress(quod_simplex:watch_requested(64, Watching)),
    ?assertEqual([], quod_simplex:progress_timer_actions(Watching, Repeated)),
    ProposalPhase = quod_simplex:test_state_set(head_progress, {Era, 64, awaiting_notarization}, Watching),
    ?assertEqual([], quod_simplex:progress_timer_actions(Watching, ProposalPhase)),
    ?assertEqual(Watching, quod_simplex:on_progress_timeout({<<8:256>>, 64}, Watching)),
    ?assertEqual(Watching, quod_simplex:on_progress_timeout({Era, 63}, Watching)),
    %% No remote readiness reports are present. The protocol timeout still
    %% chooses a complaint, durably before transport, and only in this view.
    Complained = quod_simplex:on_progress_timeout({Era, 64}, Watching),
    ?assertEqual({none, false, true}, quod_simplex:test_round(64, Complained)),
    ?assertEqual(1, quod_simplex:test_progress_counts(Complained)),
    ?assertEqual({none, false, false}, quod_simplex:test_round(900, Complained)),
    ?assertEqual([], quod_simplex:progress_timer_actions(Watching,
                        quod_simplex:reconcile_head_progress(Complained))),
    Recovering = quod_simplex:test_state_set(sync, unconfirmed, Watching),
    ?assertEqual({none, false, false}, quod_simplex:test_round(64,
                        quod_simplex:on_progress_timeout({Era, 64}, Recovering))),
    %% A delayed timeout from the previous committee cannot renew this timer.
    ?assertEqual({keep_state, Watching}, quod_simplex:running(
        {timeout, progress}, {progress_timeout, {<<8:256>>, 64}}, Watching)),
    flush_consensus_fixture_frames().

era_parent_validation_uses_material_height_after_carriers_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = committee(4), Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    Ns = <<"validation-after-carriers">>,
    {ok, Material} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [tx([])]}, 7),
    {E1, _} = quod_simplex:eng_offer({block, Material},
                              quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 1, 0})),
    {E2, _} = feed_shares(era_shares(support, Material, Committee), E1),
    {Engine, Head} = lists:foldl(fun(View, {Previous, Parent}) ->
        {ok, B} = quod_ledger:new_block({Era, View}, quod_ledger:block_ref(Parent), (Parent)#block.height, empty, 7),
        {Added, _} = quod_simplex:eng_offer({block, B}, Previous),
        {Notarized, _} = feed_shares(era_shares(support, B, Committee), Added),
        {Notarized, B}
    end, {E2, Material}, lists:seq(2, 64)),
    {ok, Content} = quod_ledger:new_block({Era, 65}, quod_ledger:block_ref(Head), (Head)#block.height + 1, {batch, [tx([])]}, 8),
    {WithContent, _} = quod_simplex:eng_offer({block, Content}, Engine),
    Hash = element(3, quod_ledger:block_ref(Content)),
    Owner = quod_simplex:test_state(#{ns => Ns, eng => WithContent, slot => 1,
                                      history_head => {1, element(3, Root)}}),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        _ = quod_simplex:test_start_content_validation([tx([])], 8, 65, Hash, Owner),
        receive
            {'$gen_cast', {content_verdict_req, _, 8, Height, _, {65, Hash}, _}} ->
                ?assertEqual(3, Height)
        after 1000 -> error(missing_content_request) end,
        Payload = quod_ct:atomic_resolve_payload(),
        {batch, [{dtx, Control}]} = Payload,
        {ok, Dtx} = quod_ledger:new_block({Era, 65}, quod_ledger:block_ref(Head), (Head)#block.height + 1, Payload, 8),
        DtxHash = element(3, quod_ledger:block_ref(Dtx)),
        ?assertEqual(Owner, quod_simplex:request_dtx_validation([Control], Dtx, 65, DtxHash, Owner)),
        receive {'$gen_cast', {dtx_verdict_req, _, _, _, _, _, _}} -> error(uncommitted_dtx_parent)
        after 0 -> ok end,
        Token = {2, element(3, quod_ledger:block_ref(Material))},
        Installed = quod_simplex:test_state(#{ns => Ns, slot => 2, history_head => Token,
            eng => quod_simplex:eng_prune(quod_ledger:block_ref(Head), Engine)}),
        Pending = quod_simplex:request_dtx_validation([Control], Dtx, 65, DtxHash, Installed),
        receive
            {'$gen_cast', {dtx_verdict_req, {wave, [Control]}, 8, DtxHeight, _, {65, DtxHash, Token}, _}} ->
                ?assertEqual(3, DtxHeight)
        after 1000 -> error(missing_dtx_request) end,
        {DtxHash, {dtx, Token, _, Monitor, _}, _, _, _} = quod_simplex:test_dtx_round(65, Pending),
        erlang:demonitor(Monitor, [flush])
    after gproc:unreg(quod_reg:name({quod_prolog, Ns})) end.

%% A pinned anchor is not yet installed history. Exercise normal startup,
%% internal reconciliation and public reads before any download is available.
era_cold_join_without_material_keeps_owner_alive_and_admission_closed_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"cold-join:", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    {Pub, Signer} = id(), Anchor = <<86:256>>,
    Dir = filename:join("/tmp", binary_to_list(Ns)),
    Trap = process_flag(trap_exit, true),
    try
        {ok, Owner} = quod_simplex:start_link(Ns,
            #{mode => join, genesis_hash => Anchor, node_id => Pub,
              identity => Signer, data_dir => Dir}),
        unlink(Owner),
        try
            ?assertMatch(#{committed := 0, pipeline_gap := 0, committee_size := 0,
                           prolog_ready := false}, quod_simplex:stats(Ns)),
            {ok, View} = quod_simplex:history_view(
                {Owner, {Ns, Anchor}}, committed, quod_time:mono_ms() + 1000),
            ?assertMatch(#{slot := 0, projection := #{history_head := none}}, View),
            ?assertMatch({error, _}, quod_simplex:await_proof_access(
                Ns, quod_time:mono_ms() + 1000, #{})),
            ?assert(is_process_alive(Owner))
        after
            case is_process_alive(Owner) of true -> gen_statem:stop(Owner); false -> ok end,
            receive {'EXIT', Owner, _} -> ok after 0 -> ok end
        end
    after
        process_flag(trap_exit, Trap),
        file:del_dir_r(Dir)
    end.

era_live_archive_group_preserves_material_heights_and_reuses_proofs_test() ->
    era_live_archive_case(ordinary, live).

era_live_membership_group_retires_old_votes_and_starts_at_material_root_test() ->
    era_live_archive_case(membership, live).

era_recovery_group_restores_protocol_head_without_replaying_live_events_test() ->
    era_live_archive_case(ordinary, replay).

era_recovery_membership_group_seals_old_votes_before_reseating_test() ->
    era_live_archive_case(membership, replay).

era_observer_proof_group_preserves_live_and_replay_apply_origins_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = #{identity := {Ns, Anchor} = Identity, era := Era, transaction := Tx,
          signer := Signer, projection := P0} = quod_ct:protocol_fixture(<<"feed:group-origins">>),
    Root = maps:get(protocol_root, P0),
    {ok, B1} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [Tx]}, 1),
    Unsigned = quod_transaction:bind_id(Identity, Tx#transaction{author_seq = 2,
      proof_id = <<24:256>>, sig = none, signed_bytes = none, authentication = none}),
    {ok, Tx2} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, Unsigned, Signer),
    {ok, B2} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(B1), (B1)#block.height + 1, {batch, [Tx2]}, 2),
    Cert = quod_ct:protocol_certificate(B2, F),
    Entries = [quod_ledger:entry(2, B1, Cert), quod_ledger:entry(3, B2, Cert)],
    Bytes = [quod_ledger:block_bytes(B2), quod_ledger:block_bytes(B1)],
    Source = {lists:sum([quod_ledger_store:proof_frame_size(B) || B <- Bytes]),
              fun([]) -> done; ([B | Rest]) -> {B, Rest} end, Bytes},
    Dir = filename:join("/tmp", "quod_feed_origins_" ++
                       binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
        {ok, Store} = quod_ledger_store:append(S0, {none, [Genesis]}),
        {ok, P, GD, genesis} = quod_catchup:verify_forward_group(Identity, [Genesis],
          quod_simplex:history_projection(Identity), Index, {fun(_) -> done end, none}),
        ok = quod_dtx_phase_index:commit_delta(Index, GD),
        {ok, P1, Delta, Summary} = quod_catchup:verify_forward_group(Identity, Entries, P, Index,
          {fun([]) -> done; ([B | Rest]) -> {ok, B, Rest} end, Bytes}),
        Domain = quod_simplex:consensus_domain(Ns, Anchor),
        Engine = quod_simplex:eng_new(Domain, [maps:get(pubkey, Signer)],{Root, 1, 0}),
        State = quod_simplex:test_install_projection(P,
          quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor, self => <<92:256>>,
            consensus_domain => Domain, eng => Engine, store => Store, phase_index => Index,
            slot => 1, last_applied => 0, archive_tip => {Root, 0}, signing_journal => memory})),
        Group = #{entries => Entries, proof => Source, projection => P1, delta => Delta, finality => Summary},
        {Next, ok} = quod_simplex:test_apply_catchup_window({feed, {live, 2, 2}}, Group, State),
        [Live, Missed] = Entries,
        receive {'$gen_cast', {apply_entry, Genesis, replay}} -> ok after 1000 -> error(genesis_replayed_live) end,
        receive {'$gen_cast', {apply_entry, Live, live}} -> ok after 1000 -> error(live_notification_lost) end,
        receive {'$gen_cast', {apply_entry, Missed, replay}} -> ok after 1000 -> error(history_replayed_live) end,
        {3, FinalStore} = quod_simplex:test_committed_store(Next),
        ?assertEqual({Next, {error, stale_window}},
          quod_simplex:test_apply_catchup_window({feed, {live, 2, 3}}, Group, Next)),
        receive {'$gen_cast', {apply_entry, _, _}} -> error(duplicate_apply) after 0 -> ok end,
        ok = quod_dtx_phase_index:close(Index), quod_ledger_store:close(FinalStore)
    after gproc:unreg(quod_reg:name({quod_prolog, Ns})), file:del_dir_r(Dir) end.

era_live_archive_case(Mode, Origin) ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_ct:protocol_fixture(<<"live-archive">>),
    {Ns, Anchor} = Binding = maps:get(identity, F),
    Era = maps:get(era, F), Root = {Era, 0, Anchor}, Signer = maps:get(signer, F),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Tx0 = maps:get(transaction, F),
    Tx = case Mode of
        ordinary -> Tx0;
        membership ->
            Pub = maps:get(pubkey, Signer),
            MemberUnsigned = quod_transaction:bind_id(Binding,
                Tx0#transaction{diff = [{assert, {{peer_admitted, Pub, <<"localhost">>, 1, Pub}, true}}],
                                sig = none, signed_bytes = none, authentication = none}),
            {ok, MemberTx} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, MemberUnsigned, Signer),
            MemberTx
    end,
    Support = fun(Block, Engine) ->
        {_, View, Hash} = quod_ledger:block_ref(Block),
        {Added, _} = quod_simplex:eng_offer({block, Block}, Engine),
        Share = quod_simplex:make_share(Domain, support, {Block#block.era, View}, Hash, Signer),
        element(1, quod_simplex:eng_offer({share, Share}, Added))
    end,
    {ok, Material} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [Tx]}, 1),
    E1 = Support(Material, quod_simplex:eng_new(Domain, [maps:get(pubkey, Signer)],{Root, 1, 0})),
    {E2, Head} = lists:foldl(fun(View, {Engine, Parent}) ->
        {ok, B} = quod_ledger:new_block({Era, View}, quod_ledger:block_ref(Parent), (Parent)#block.height, empty, 1),
        {Support(B, Engine), B}
    end, {E1, Material}, lists:seq(2, 64)),
    Cert = quod_ct:protocol_certificate(Head, F),
    {E3, _} = quod_simplex:eng_offer({cert, Cert}, E2),
    {Source, [Entry], Summary} = quod_simplex:eng_archive_group(Cert, 1, Root, E3),
    ?assertEqual(2, quod_ledger:entry_index(Entry)),
    ?assertEqual(quod_ledger:block_ref(Material), maps:get(material_tip, Summary)),
    Dir = filename:join("/tmp", "quod_live_archive_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    try
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [quod_ledger:entry(1, maps:get(genesis, F), none)]}),
        {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
        Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
        {ok, _, GenesisDelta, genesis} = quod_catchup:verify_forward_group(
            Binding, [Genesis], quod_simplex:history_projection(Binding), Index,
            {fun(_) -> done end, none}),
        ok = quod_dtx_phase_index:commit_delta(Index, GenesisDelta),
        {_, NextProof, ProofState} = Source,
        ReadProof = {fun(C) -> case NextProof(C) of done -> done; {Bytes, NextC} -> {ok, Bytes, NextC} end end,
                     ProofState},
        {ok, GroupProjection, GroupDelta, Summary} = quod_catchup:verify_forward_group(
            Binding, [Entry], maps:get(projection, F), Index, ReadProof),
        Group = #{entries => [Entry], proof => Source, finality => Summary,
                   projection => GroupProjection, delta => GroupDelta},
        {ok, J0} = quod_signing_journal:initialize(Ns, Domain, Dir),
        {ok, J1} = quod_signing_journal:record_support(J0, Material),
        {ok, J2} = quod_signing_journal:record_support(J1, Head),
        {ok, Journal} = quod_signing_journal:record_vote(J2, commit, {Era, 64}, Cert#cert.block_hash),
        true = quod_reg:reg({quod_prolog, Ns}),
        true = quod_reg:subscribe({committed, Ns}),
        Owner0 = quod_simplex:test_install_projection(maps:get(projection, F),
            quod_simplex:test_state(#{ns => Ns, self => maps:get(pubkey, Signer),
              genesis_hash => Anchor, consensus_domain => Domain, eng => E2,
              slot => 1, last_applied => 1, archive_tip => {Root, 0},
              store => S1, phase_index => Index, signing_journal => Journal})),
        %% A failed archive write cannot publish or retire any vote. Use an
        %% actual read-only descriptor, not a test-only storage implementation.
        {ok, ReadOnly} = quod_ledger_store:open_ro(Ns, Dir),
        FailedOwner = quod_simplex:test_state_set(store, ReadOnly,
                        quod_simplex:test_state_set(eng, E3, Owner0)),
        case Origin of
            live -> ?assertException(error, {badmatch, {error, ebadf}},
                                      quod_simplex:commit_finality(Cert, FailedOwner));
            replay -> ?assertEqual({FailedOwner, {error, {badmatch, {error, ebadf}}}},
                quod_simplex:test_apply_catchup_window({recovery, self()}, Group, FailedOwner))
        end,
        {ok, PreservedJournal} = quod_signing_journal:recover(Ns, Domain, Dir),
        ?assertEqual(quod_signing_journal:rounds(Journal), quod_signing_journal:rounds(PreservedJournal)),
        ok = quod_signing_journal:close(PreservedJournal),
        receive {committed, Ns, _, _} -> error(published_failed_archive);
                {'$gen_cast', {apply_entry, _, _}} -> error(applied_failed_archive)
        after 0 -> ok end,
        ok = quod_ledger_store:close(ReadOnly),
        Owner1 = case Origin of
            live -> quod_simplex:engine_step([{cert, Cert}], Owner0);
            replay ->
                {Recovered, ok} = quod_simplex:test_apply_catchup_window({recovery, self()}, Group, Owner0),
                Recovered
        end,
        {2, S2} = quod_simplex:test_committed_store(Owner1),
        %% A late supported-body request crosses protocol view 1 / material
        %% height 2. The already-pruned owner sends its archived CommitQC;
        %% it cannot reinterpret view 1 as a ledger offset or reread a prefix.
        Peer = maps:get(pubkey, Signer),
        Caller = self(), ReplyTag = make_ref(),
        Link = spawn_link(fun() ->
            receive {send, Bytes} -> Caller ! {ReplyTag, Bytes}
            after 5000 -> exit(missing_archive_reply) end
        end),
        Serving = quod_simplex:test_state_set(conns, #{Peer => {Link, make_ref()}}, Owner1),
        {_, {call_count, Reads}} = tprof:profile(fun() ->
            quod_simplex:dispatch(Peer, {block_request, 1, quod_simplex:block_hash(Material)}, Serving)
        end, #{type => call_count, report => return,
               pattern => [{quod_ledger_store, read_at, 3}], timeout => 5000}),
        ?assertEqual(0, lists:sum([N || {quod_ledger_store, read_at, 3, Ps} <- Reads, {_, N, _} <- Ps])),
        receive {ReplyTag, Frame} ->
            ?assertEqual({consensus, {cert, Cert}}, quod_relay:decode_consensus_frame(Frame, Ns))
        after 1000 -> error(missing_archived_finality_handoff) end,
        {LaggingEngine, _} = quod_simplex:eng_offer({cert, Cert},
            quod_simplex:eng_new(Domain, [Peer],{Root, 1, 0})),
        ?assert(quod_simplex:should_sync(quod_simplex:test_state_set(sync, ready,
            quod_simplex:test_state_set(eng, LaggingEngine, Owner0)))),

        ?assertEqual(#{}, quod_signing_journal:rounds(quod_simplex:test_signing_journal(Owner1))),
        case Origin of
            live -> receive {committed, Ns, 2, Entry} -> ok after 1000 -> error(missing_material_publication) end;
            replay -> receive {certified_head, Ns, 2} -> ok after 1000 -> error(missing_certified_head) end
        end,
        receive {'$gen_cast', {project_pending_votes, []}} -> ok after 1000 -> error(missing_custody_projection) end,
        receive {'$gen_cast', {apply_entry, Entry, Origin}} -> ok after 1000 -> error(missing_material_apply) end,
        receive {committed, Ns, _, _} -> error(carrier_published);
                {'$gen_cast', {apply_entry, _, live}} -> error(carrier_applied)
        after 0 -> ok end,
        {ok, Proof} = quod_ledger_store:proof_cursor(S2, 2),
        ?assertEqual({ok, Summary}, quod_catchup:verify_finality(Binding, [Entry], maps:get(projection, F),
                      {fun(C) -> quod_ledger_store:proof_next(S2, C) end, Proof})),
        P = quod_simplex:history_advance(Ns, Entry, maps:get(projection, F)),
        {NextEra, NextView, NextParent, Pruned} = case Mode of
            ordinary ->
                {Era, 65, quod_ledger:block_ref(Head), quod_simplex:eng_prune(quod_ledger:block_ref(Head), E3)};
            membership ->
                NewRoot = maps:get(protocol_root, P), NewEra = element(1, NewRoot),
                ?assertEqual({NewEra, 0, element(3, quod_ledger:block_ref(Material))}, NewRoot),
                {NewEra, 1, NewRoot, quod_simplex:eng_new(Domain, [maps:get(pubkey, Signer)],{NewRoot, 2, 1})}
        end,
        ?assertEqual(#{era => NextEra, view => NextView, root => NextParent, parent => NextParent, material_height => 2},
                     quod_simplex:test_protocol_position(Owner1)),
        Unsigned = quod_transaction:bind_id(Binding,
          Tx0#transaction{author_seq = 2, proof_id = <<23:256>>, sig = none,
                         signed_bytes = none, authentication = none}),
        {ok, Tx2} = quod_transaction:sign({Ns, Anchor, maps:get(maps:get(pubkey, Signer), maps:get(admissions, P))}, Unsigned, Signer),
        {ok, Next} = quod_ledger:new_block({NextEra, NextView}, NextParent, 3, {batch, [Tx2]}, 2),
        E4 = Support(Next, Pruned), Cert2 = quod_ct:protocol_certificate(Next, F),
        {E5, _} = quod_simplex:eng_offer({cert, Cert2}, E4),
        {Source2, [Entry2], Summary2} =
            quod_simplex:eng_archive_group(Cert2, 2, maps:get(protocol_root, P), E5),
        {NewBytes, _, _} = case Mode of ordinary -> element(2, Source2); membership -> Source2 end,
        ?assertEqual(quod_ledger_store:proof_frame_size(quod_ledger:block_bytes(Next)), NewBytes),
        Owner2 = quod_simplex:engine_step([{cert, Cert2}], quod_simplex:test_state_set(eng, E4, Owner1)),
        {3, S3} = quod_simplex:test_committed_store(Owner2),
        case Mode of ordinary -> ?assertMatch({extend, _, 2}, Source2); membership -> ok end,
        receive {committed, Ns, 3, Entry2} -> ok after 1000 -> error(missing_next_publication) end,
        receive {'$gen_cast', {project_pending_votes, []}} -> ok after 1000 -> error(missing_next_custody_projection) end,
        receive {'$gen_cast', {apply_entry, Entry2, live}} -> ok after 1000 -> error(missing_next_apply) end,
        {ok, Proof2} = quod_ledger_store:proof_cursor(S3, 3),
        ?assertEqual({ok, Summary2}, quod_catchup:verify_finality(Binding, [Entry2], P,
                      {fun(C) -> quod_ledger_store:proof_next(S3, C) end, Proof2})),
        ?assertEqual(3, quod_ledger_store:last(S3)),
        ok = quod_signing_journal:close(quod_simplex:test_signing_journal(Owner2)),
        ok = quod_dtx_phase_index:close(Index),
        ok = quod_ledger_store:close(S3)
    after
        quod_reg:unsubscribe({committed, Ns}),
        gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        file:del_dir_r(Dir)
    end.

era_owner_commits_only_on_its_notarization_view_edge_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = committee(4), [{Self, Signer} | _] = Committee,
    Era = <<7:256>>, Root = {Era, 0, <<1:256>>},
    Eng = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 500, 0}),
    Conns = maps:from_list([{Pub, {self(), make_ref()}} || {Pub, _} <- Committee, Pub =/= Self]),
    Owner = quod_simplex:test_state(#{self => Self, id => Signer, validators => pubs(Committee),
        eng => Eng, sync => ready, slot => 500, history_head => {500, element(3, Root)},
        conns => Conns}),
    {ok, B1} = quod_ledger:new_block({Era, 1}, Root, 500, empty, 0),
    Complaints = era_shares(complaint, B1, Committee),
    Moved = quod_simplex:engine_step([{share, Sh} || Sh <- Complaints], Owner),
    ?assertEqual(2, maps:get(view, quod_simplex:test_protocol_position(Moved))),
    ?assert(quod_simplex:may_vote(Moved)),
    %% No peer complaint amplified a local decision. A late complete tree row
    %% must not manufacture the view edge that this owner already passed.
    ?assertEqual({none, false, false}, quod_simplex:test_round(1, Moved)),
    Late = quod_simplex:engine_step([{block, B1} | [{share, Sh} || Sh <- era_shares(support, B1, Committee)]], Moved),
    ?assertEqual({none, false, false}, quod_simplex:test_round(1, Late)),
    {ok, B2} = quod_ledger:new_block({Era, 2}, Root, 500, empty, 0),
    Advanced = quod_simplex:engine_step([{block, B2} | [{share, Sh} || Sh <- era_shares(support, B2, Committee)]], Late),
    ?assertEqual(3, maps:get(view, quod_simplex:test_protocol_position(Advanced))),
    ?assertEqual({none, true, false}, quod_simplex:test_round(2, Advanced)),
    ?assertEqual({none, false, false}, quod_simplex:test_round(1, Advanced)),
    flush_consensus_fixture_frames().

era_relay_material_result_is_only_a_hint_for_the_original_placement_test() ->
    Era = <<7:256>>, Root = {Era, 0, <<1:256>>}, Peer = <<2:256>>,
    Engine = quod_simplex:eng_new(?DOMAIN, [Peer],{Root, 2, 0}),
    Owner = quod_simplex:test_state(#{eng => Engine, slot => 2}),
    {ok, Pending} = quod_simplex:test_put_pending_relay(Peer, 64, Owner),
    [{Attempt, Peer, 64, Deadline, false}] = quod_simplex:test_relay_pending_detail(Pending),
    %% View 64 can commit at material height 2. It is still not proof: the
    %% source retains its exact placement and original deadline until its own
    %% material history establishes inclusion or exclusion.
    Hinted = quod_simplex:test_relay_result(Peer, Attempt, {ok, 2}, Pending),
    ?assertEqual([{Attempt, Peer, 64, Deadline, true}], quod_simplex:test_relay_pending_detail(Hinted)),
    Refused = quod_simplex:test_relay_result(Peer, Attempt, {error, skipped}, Hinted),
    ?assertEqual(quod_simplex:test_relay_pending_detail(Hinted),
                 quod_simplex:test_relay_pending_detail(Refused)),
    ?assertEqual(quod_simplex:test_relay_pending_detail(Pending),
                 quod_simplex:test_relay_pending_detail(
                   quod_simplex:test_relay_result(<<3:256>>, Attempt, {ok, 2}, Pending))).

%% The callback fixtures above own their fake outbound transport mailbox.
%% Consume their ignored traffic before the next EUnit case reuses this PID.
flush_consensus_fixture_frames() ->
    receive
        {send, _} -> flush_consensus_fixture_frames();
        {send_ordered, _} -> flush_consensus_fixture_frames()
    after 0 -> ok
    end.

era_shares(Kind, #block{era = Era, slot = View} = Block, Committee) ->
    Hash = case Kind of complaint -> none; _ -> element(3, quod_ledger:block_ref(Block)) end,
    [quod_simplex:make_share(?DOMAIN, Kind, {Era, View}, Hash, Id) || {_, Id} <- Committee].

era_journal_support(Block, Journals) ->
    {Pairs, Shares} = lists:unzip([begin
        {ok, J1} = quod_signing_journal:record_support(J, Block),
        [Share] = era_shares(support, Block, [Member]),
        {{Member, Path, J1}, Share}
    end || {Member, Path, J} <- Journals]),
    {Pairs, Shares}.

era_journal_finals(#block{era = Era, slot = View} = Block, Choices, Journals) ->
    {Pairs, Shares} = lists:unzip([begin
        Hash = case Kind of complaint -> none; commit -> element(3, quod_ledger:block_ref(Block)) end,
        {ok, J1} = quod_signing_journal:record_vote(J, Kind, {Era, View}, Hash),
        [Share] = era_shares(Kind, Block, [Member]),
        {{Member, Path, J1}, Share}
    end || {Kind, {Member, Path, J}} <- lists:zip(Choices, Journals)]),
    {Pairs, Shares}.

%% a fresh validator identity {Pubkey, IdentityMap}
id() ->
    {Pub, Seed} = quod_identity:generate(),
    {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}.

block(Slot, Parent, Height, Payload) -> block(Slot, Parent, Height, Payload, 0).

block(Slot, Parent, Height, Payload, Timestamp) ->
    {ok, Block} = quod_ledger:new_block(
                    Slot, Parent, Height, Payload, Timestamp),
    Block.

%% Projection/endpoint fixtures carry canonical material artifacts. Their
%% certificates are shape-only; verified-history tests use real signatures.
material_entry(Height, Position, Parent, Payload, Timestamp) ->
    {ok, Block} = quod_ledger:new_block(Position, Parent, Height, Payload, Timestamp),
    Cert = case Position of
        {genesis, 0} -> none;
        {Era, View} -> #cert{kind = commit, era = Era, slot = View,
                            block_hash = quod_simplex:block_hash(Block),
                            sigs = [{<<1:256>>, <<0:512>>}]}
    end,
    quod_ledger:entry(Height, Block, Cert).

stored_entry_view(Store, Slot) ->
    {ok, Entry} = quod_ledger_store:read_at(Store, Slot),
    quod_ledger:entry_view(Entry).

blk(View) -> blk(View, max(2, View)).

blk(View, Height) ->
    Parent = case {View, Height} of
        {1, _} -> {?FIXTURE_ERA, 0, <<1:256>>};
        {_, 2} -> {?FIXTURE_ERA, View - 1, <<1:256>>};
        _ -> quod_ledger:block_ref(blk(View - 1, Height - 1))
    end,
    {ok, Block} = quod_ledger:new_block({?FIXTURE_ERA, View}, Parent, Height,
        {batch, [tx([{assert, {{fact, View}, true}}])]}, 0),
    Block.

%%%===================================================================
%%% quorum
%%%===================================================================

quorum_test() ->
    ?assertEqual(1, quod_simplex:quorum(1)),   %% sole validator
    ?assertEqual(3, quod_simplex:quorum(3)),   %% f=0
    ?assertEqual(3, quod_simplex:quorum(4)),   %% f=1
    ?assertEqual(5, quod_simplex:quorum(7)),   %% f=2
    ?assertEqual(7, quod_simplex:quorum(10)).  %% f=3

%%%===================================================================
%%% block hashing
%%%===================================================================

block_hash_deterministic_test() ->
    ?assertEqual(quod_simplex:block_hash(blk(5)), quod_simplex:block_hash(blk(5))),
    ?assertNotEqual(quod_simplex:block_hash(blk(5)), quod_simplex:block_hash(blk(6))).

block_bytes_and_hash_match_across_fresh_vms_test() ->
    %% Escript archive paths belong to the launcher, not a fresh Erlang VM.
    Path = [filename:absname(P) || P <- code:get_path(), filelib:is_dir(P)],
    PeerName1 = list_to_atom(
                  "canonical_block_a_"
                  ++ integer_to_list(erlang:unique_integer([positive]))),
    PeerName2 = list_to_atom(
                  "canonical_block_b_"
                  ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Peer1, _} = peer:start(
                       #{name => PeerName1, connection => standard_io,
                         args => ["+S", "2:2"]}),
    {ok, Peer2, _} = peer:start(
                       #{name => PeerName2, connection => standard_io,
                         args => ["+S", "2:2"]}),
    try
        %% set_path preserves the caller's exact precedence. Repeating -pa in
        %% a child command can load stale baseline beams ahead of this tree.
        true = peer:call(Peer1, code, set_path, [Path]),
        true = peer:call(Peer2, code, set_path, [Path]),
        lists:foreach(fun(Peer) ->
            ?assertEqual(filename:absname(code:which(?MODULE)),
                         filename:absname(peer:call(Peer, code, which, [?MODULE]))),
            ?assertEqual(filename:absname(code:which(quod_ledger)),
                         filename:absname(peer:call(Peer, code, which, [quod_ledger])))
        end, [Peer1, Peer2]),
        First = peer:call(Peer1, ?MODULE, canonical_block_fixture, [47]),
        ?assertMatch({<<_/binary>>, <<_:256>>}, First),
        %% Loading unrelated vocabulary in only one VM must not influence the
        %% producer's canonical bytes or their consensus hash.
        _ = peer:call(Peer2, erlang, binary_to_atom,
                      [<<"canonical_block_unrelated_atom">>, utf8]),
        Second = peer:call(Peer2, ?MODULE, canonical_block_fixture, [47]),
        ?assertEqual(First, Second)
    after
        _ = peer:stop(Peer1),
        _ = peer:stop(Peer2)
    end.

canonical_block_fixture(Salt) ->
    Block = block(
              {?FIXTURE_ERA, 8}, {?FIXTURE_ERA, 7, <<1:256>>}, 47,
              {batch,
               [tx(<<"canonical:vm">>,
                   [{assert,
                     {{canonical_fact, Salt, {{pair, a, 1}, [x, y]}},
                      true}}])]},
              1234),
    Bytes = quod_ledger:block_bytes(Block),
    {Bytes, quod_simplex:block_hash(Block)}.

block_producer_rejects_map_inside_map_key_test() ->
    Ns = <<"canonical:unstable-key">>,
    BadMap = #{#{a => 1} => rejected},
    Genesis = #transaction{
                 tx_id = <<1:256>>, origin = {Ns, <<0:256>>},
                 diff = [{assert, {{bad_map_key, BadMap}, true}}],
                 read_check = #{}, author = <<2:256>>, sig = none},
    ?assertEqual(
       {error, bad_block},
       quod_ledger:new_block({genesis, 0}, none, 1, {batch, [Genesis]}, 0)).

%% The committee view is the membership set plus its adopting material block.
%% Content entries retain that view; empty carriers never enter the projection.
committee_view_projection_test() ->
    Ns = <<"committee:view">>,
    [A, B, C] = lists:sort(pubs(committee(3))),
    Genesis = material_entry(1, {genesis, 0}, none,
                             {batch, [tx(Ns, [pa(B), pa(A)])]}, 0),
    {ok, GB} = quod_ledger:block_from_entry(Genesis),
    Era = quod_ledger:initial_era({Ns, quod_simplex:block_hash(GB)}),
    Root = {Era, 0, quod_simplex:block_hash(GB)},
    Content = material_entry(2, {Era, 1}, Root,
                    {batch, [tx(Ns, [{assert, {{content, kept}, true}}])]},
                    123),
    {ok, CB} = quod_ledger:block_from_entry(Content),
    AdmitC = material_entry(3, {Era, 2}, quod_ledger:block_ref(CB),
                            {batch, [tx(Ns, [pa(C)])]}, 456),
    {ok, GenesisBlock} = quod_simplex:block_from_entry(Genesis),
    GenesisHash = quod_simplex:block_hash(GenesisBlock),
    ExpectedGenesisId =
        crypto:hash(
          sha256,
          term_to_binary(
            {quod_committee_view, 2, Ns, 1, GenesisHash,
             lists:sort([A, B])},
            [deterministic])),
    Seed = quod_simplex:history_projection(),
    Projection1 = quod_simplex:test_log_projection(Ns, [Genesis], Seed),
    ?assertEqual([A, B], quod_simplex:history_committee(Projection1)),
    GenesisId = maps:get(committee_id, Projection1),
    ?assertEqual(32, byte_size(GenesisId)),
    ?assertEqual(ExpectedGenesisId, GenesisId),
    ?assertEqual(
       GenesisId,
       quod_simplex:committee_view_id(Ns, 1, GenesisHash, [B, A])),

    %% Folding a window in one call and streaming it entry-by-entry are identical.
    AfterStable =
        quod_simplex:test_log_projection(
          Ns, [Content], Projection1),
    ?assertEqual([A, B], quod_simplex:history_committee(AfterStable)),
    ?assertEqual(GenesisId, maps:get(committee_id, AfterStable)),
    ?assertEqual(123, maps:get(timestamp, AfterStable)),
    Full = quod_simplex:test_log_projection(
             Ns, [Genesis, Content, AdmitC], Seed),
    Streamed = quod_simplex:test_log_projection(
                 Ns, [AdmitC], AfterStable),
    ?assertEqual(Full, Streamed),
    ?assertEqual([A, B, C], quod_simplex:history_committee(Full)),
    AdmitCId = maps:get(committee_id, Full),
    ?assertEqual(456, maps:get(timestamp, Full)),
    {ok, AdmitCBlock} = quod_simplex:block_from_entry(AdmitC),
    ?assertEqual(
       quod_simplex:committee_view_id(
       Ns, 3, quod_simplex:block_hash(AdmitCBlock), [A, B, C]),
       AdmitCId),
    ?assertNotEqual(GenesisId, AdmitCId),
    %% Exact-reference consumers select by slot, not by the projection's
    %% current head. Stable material remains in the prior era; carriers add no rows.
    lists:foreach(
      fun(Slot) ->
          ?assertMatch(
             {ok, [A, B], GenesisId, _},
             quod_simplex:history_committee_view(Slot, Full))
      end,
      [1, 2]),
    ?assertMatch(
       {ok, [A, B, C], AdmitCId, _},
       quod_simplex:history_committee_view(3, Full)),
    ?assertMatch(
       {ok, [A, B], GenesisId, _},
       quod_simplex:history_certifying_committee_view(3, Full)),
    ?assertMatch(
       {ok, [A, B], GenesisId, _},
       quod_simplex:history_certifying_committee_view(1, Full)),
    ?assertEqual(error, quod_simplex:history_committee_view(4, Full)).

committee_view_is_not_invented_before_membership_test() ->
    Ns = <<"committee:unfounded">>,
    Entry = material_entry(1, {genesis, 0}, none,
                  {batch, [tx([{assert, {{ordinary, fact}, true}}])]}, 0),
    Projection = quod_simplex:test_log_projection(
                   Ns, [Entry], quod_simplex:history_projection()),
    ?assertEqual(undefined, maps:get(committee_id, Projection)),
    ?assertEqual([], maps:get(committee_views, Projection)),
    ?assertEqual(error, quod_simplex:history_committee_view(1, Projection)).

live_state_projection_retains_current_committee_era_start_test() ->
    Ns = <<"committee:live-era-start">>,
    Anchor = <<21:256>>,
    Member = <<22:256>>,
    CommitteeId = <<23:256>>,
    Admission = <<24:256>>,
    Routes = #{Member => {"127.0.0.1", 19000}},
    Projection = (quod_simplex:history_projection({Ns, Anchor}))#{
                   committee := [Member],
                   validator_routes := Routes,
                   committee_id := CommitteeId,
                   committee_views :=
                       [{40, [Member], CommitteeId, Routes}],
                   admissions := #{Member => Admission},
                   sequences := #{Member => 0},
                   history_head := {100, <<25:256>>}},
    S0 = quod_simplex:test_state(
           #{ns => Ns, self => Member, slot => 100,
             author_admissions => #{Member => Admission}}),
    S1 = quod_simplex:test_install_projection(Projection, S0),
    LiveProjection = quod_simplex:test_state_projection(S1),
    ?assertMatch(
       {ok, [Member], CommitteeId, Routes},
       quod_simplex:history_committee_view(40, LiveProjection)),
    ?assertMatch(
       {ok, [Member], CommitteeId, Routes},
       quod_simplex:history_committee_view(100, LiveProjection)),
    ?assertEqual(
       error, quod_simplex:history_committee_view(39, LiveProjection)).

%% Returning to the same validator set after a leave/rejoin is a new view.
%% Reasserting a current member (for example to refresh its endpoint) retains
%% the current view and admission generation.
committee_view_recurring_set_revision_test() ->
    Ns = <<"committee:recurring">>,
    [{A, _AIdentity}, {B, BIdentity}] = lists:sort(committee(2)),
    Genesis = material_entry(1, {genesis, 0}, none,
                             {batch, [tx(Ns, [pa(A), pa(B)])]}, 0),
    {ok, GB} = quod_ledger:block_from_entry(Genesis),
    Era = quod_ledger:initial_era({Ns, quod_simplex:block_hash(GB)}),
    BWrite = material_entry(2, {Era, 1}, {Era, 0, quod_simplex:block_hash(GB)},
               {batch, [signed_tx_seq(Ns, <<"b-write">>, 9,
                          [{assert, {{b_wrote, true}, true}}],
                          {B, BIdentity})]}, 9),
    {ok, WB} = quod_ledger:block_from_entry(BWrite),
    Removed = material_entry(3, {Era, 2}, quod_ledger:block_ref(WB),
                             {batch, [tx(Ns, [rm(B)])]}, 10),
    {ok, RB} = quod_ledger:block_from_entry(Removed),
    Era2 = quod_ledger:next_era({Ns, quod_simplex:block_hash(GB)}, Era, quod_simplex:block_hash(RB)),
    Readded = material_entry(4, {Era2, 1}, {Era2, 0, quod_simplex:block_hash(RB)},
                             {batch, [tx(Ns, [pa(B)])]}, 11),
    Projection1 =
        quod_simplex:test_log_projection(
          Ns, [Genesis], quod_simplex:history_projection()),
    ProjectionWritten =
        quod_simplex:test_log_projection(Ns, [BWrite], Projection1),
    ?assertEqual(9, maps:get(B, maps:get(sequences, ProjectionWritten))),
    Projection2 =
        quod_simplex:test_log_projection(Ns, [Removed], ProjectionWritten),
    Projection3 =
        quod_simplex:test_log_projection(Ns, [Readded], Projection2),
    Set1 = quod_simplex:history_committee(Projection1),
    Set2 = quod_simplex:history_committee(Projection2),
    Set3 = quod_simplex:history_committee(Projection3),
    Id1 = maps:get(committee_id, Projection1),
    Id2 = maps:get(committee_id, Projection2),
    Id3 = maps:get(committee_id, Projection3),
    ?assertEqual([A, B], Set1),
    ?assertEqual([A], Set2),
    ?assertEqual([A, B], Set3),
    ?assertNotEqual(Id1, Id2),
    ?assertNotEqual(Id1, Id3),
    ?assertNotEqual(Id2, Id3),
    Admissions1 = maps:get(admissions, Projection1),
    Admissions2 = maps:get(admissions, Projection2),
    Admissions3 = maps:get(admissions, Projection3),
    ?assertEqual(maps:get(A, Admissions1), maps:get(A, Admissions2)),
    ?assertEqual(maps:get(A, Admissions1), maps:get(A, Admissions3)),
    ?assertNot(maps:is_key(B, Admissions2)),
    ?assertNotEqual(maps:get(B, Admissions1), maps:get(B, Admissions3)),
    ?assertNot(maps:is_key(B, maps:get(sequences, Projection2))),
    ?assertEqual(2, map_size(Admissions3)),
    {ok, AB} = quod_ledger:block_from_entry(Readded),
    Era3 = quod_ledger:next_era({Ns, quod_simplex:block_hash(GB)}, Era2, quod_simplex:block_hash(AB)),
    Reassert = material_entry(5, {Era3, 1}, {Era3, 0, quod_simplex:block_hash(AB)},
                              {batch, [tx(Ns, [pa(B)])]}, 12),
    Reasserted = quod_simplex:test_log_projection(
                   Ns, [Reassert], Projection3),
    ?assertEqual([A, B], quod_simplex:history_committee(Reasserted)),
    ?assertEqual(Id3, maps:get(committee_id, Reasserted)),
    ?assertEqual(
       maps:get(B, Admissions3),
       maps:get(B, maps:get(admissions, Reasserted))),
    ?assertNot(maps:is_key(B, maps:get(sequences, Reasserted))),
    ?assertEqual(12, maps:get(timestamp, Reasserted)).

canonical_ledger_payload_test() ->
    Transaction = tx([{assert, {{fact, canonical}, true}}]),
    Data = {batch, [Transaction]},
    ?assertEqual({ok, [Transaction]}, quod_ledger:payload(Data)),
    ?assertEqual(error, quod_ledger:payload(Transaction)),
    ?assertEqual(error, quod_ledger:payload(noop)),
    ?assertEqual(error,
                 quod_simplex:block_from_entry(
                   #entry{index = 1, data = Transaction})),
    Fixture = quod_ct:atomic_role_fixture(),
    ControlData = {batch, [{dtx, maps:get(vote_control, Fixture)}]},
    Parent = {?FIXTURE_ERA, 0, <<1:256>>},
    ControlEntry = material_entry(2, {?FIXTURE_ERA, 1}, Parent, ControlData, 42),
    ?assertMatch(
       {ok, #block{era = ?FIXTURE_ERA, slot = 1, parent = Parent, payload = ControlData,
                   timestamp = 42, block_bytes = <<_/binary>>}},
       quod_simplex:block_from_entry(ControlEntry)).

%%%===================================================================
%%% gap detector — ahead_cert_ceiling/1 (Slice 1)
%%%===================================================================

%% Only verified commit evidence can demand material recovery. Complaints
%% advance protocol views without claiming any missing ledger entries.
ahead_cert_ceiling_test() ->
    Committee = [{_, Signer}] = committee(1),
    C = fun(Base, Kinds) ->
        Engine = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {{?FIXTURE_ERA, Base, <<1:256>>}, max(1, Base), 0}),
        Folded = lists:foldl(fun({Kind, View}, E) ->
            Hash = case Kind of complaint -> none; _ -> <<2:256>> end,
            Position = {?FIXTURE_ERA, View},
            Share = quod_simplex:make_share(?DOMAIN, Kind, Position, Hash, Signer),
            {ok, Cert} = quod_simplex:form_cert(?DOMAIN, Kind, Position, Hash,
                                               [Share], pubs(Committee)),
            {Next, _} = quod_simplex:eng_offer({cert, Cert}, E),
            Next
        end, Engine, Kinds),
        quod_simplex:ahead_cert_ceiling(Folded)
    end,
    ?assertEqual(0, C(0, [])),                                        %% empty pool -> base (no lists:max([]) crash)
    ?assertEqual(0, C(0, [{complaint, 5}, {support, 9}, {support, 42}])),             %% support certs excluded (only notarize)
    ?assertEqual(7, C(0, [{commit, 7}, {complaint, 5}, {support, 9}])), %% max over finalizers, ignoring support
    ?assertEqual(5, C(5, [{commit, 3}, {commit, 5}, {complaint, 4}])), %% certs <= base excluded -> base
    ?assertEqual(12, C(10, [{commit, 12}, {commit, 8}])).            %% only the above-base finalizer counts

%%%===================================================================
%%% Slice 4 — boot-mode / sync / participation gate truth table
%%%===================================================================

%% Only a sole validator starts ready. Every other facts shape has one unambiguous recovery state.
initial_sync_test() ->
    Init = fun(Vs) -> quod_simplex:initial_sync(st(#{self => <<"me">>, validators => Vs})) end,
    ?assertEqual(ready, Init([<<"me">>])),
    ?assertEqual(unconfirmed, Init([])),
    ?assertEqual(unconfirmed, Init([<<"me">>, <<"b">>])),
    ?assertEqual(unconfirmed, Init([<<"b">>])).

proof_gate_requires_exact_ready_ack_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = unique_gate_namespace(<<"ready">>),
    Anchor = <<0:256>>,
    Projection = quod_atomic:initial_projection({Ns, Anchor}, 7),
    with_simplex_gate(
      Ns, quod_ct:proof_gate_row(false, 7, []),
      fun(_Tab) ->
          Owner = registered_prolog_owner(Ns),
          true = quod_reg:subscribe({runtime, Ns}),
          Access = {quod_proof_access, Ns, self(), 7, <<251:256>>},
          try
              S0 = st(#{ns => Ns, committee_id => <<251:256>>,
                        consensus_domain =>
                            quod_simplex:consensus_domain(Ns, Anchor),
                        dtx_projection => Projection,
                        slot => 0, last_applied => 0,
                        sync => ready, prolog_ready => false,
                        eng => quod_simplex:eng_new(
                            quod_simplex:consensus_domain(Ns, Anchor), [ ], {{quod_ledger:initial_era({Ns, Anchor}), 0, Anchor}, 1, 0})}),
              ?assertMatch(
                 {error, {ontology_rebuilding, Ns}},
                 quod_simplex:check_proof_access(Access)),

              %% A forged owner PID and a stale height are both inert.
              WrongOwner = result_state(
                             quod_simplex:running(
                               cast, {prolog_ready, self(), 0, []}, S0)),
              ?assertEqual(false,
                           maps:get(prolog_ready,
                                    quod_simplex:stats_map(WrongOwner))),
              WrongHeight = result_state(
                              quod_simplex:running(
                                cast, {prolog_ready, Owner, 1, []}, S0)),
              ?assertEqual(false,
                           maps:get(prolog_ready,
                                    quod_simplex:stats_map(WrongHeight))),

              receive {proof_ready, {Ns, Anchor}, _, _, _} -> error(premature_ready_edge) after 0 -> ok end,
              Ready = result_state(
                        quod_simplex:running(
                          cast, {prolog_ready, Owner, 0, []}, S0)),
              ?assertEqual(true,
                           maps:get(prolog_ready,
                                    quod_simplex:stats_map(Ready))),
              ?assertEqual(
                 ok, quod_simplex:check_proof_access(Access)),

              FirstGeneration = receive
                  {proof_ready, {Ns, Anchor}, Sender, Owner, Generation}
                    when Sender =:= self(), is_integer(Generation), Generation > 0 ->
                      ?assertEqual(ok, quod_simplex:check_proof_access(Access)),
                      Generation
              after 0 -> error(missing_installed_ready_edge)
              end,
              _ = quod_simplex:running(cast, {prolog_ready, Owner, 0, []}, Ready),
              receive {proof_ready, {Ns, Anchor}, _, _, _} -> error(duplicate_ready_edge) after 0 -> ok end,

              %% Rebuild closes the row synchronously; a queued mark_ready
              %% cannot reopen it without the later owner acknowledgement.
              Rebuilding = result_state(
                             quod_simplex:running(cast, rebuild, Ready)),
              ?assertEqual(false,
                           maps:get(prolog_ready,
                                    quod_simplex:stats_map(Rebuilding))),
              ?assertMatch(
                 {error, {ontology_rebuilding, Ns}},
                 quod_simplex:check_proof_access(Access)),
              _ = quod_simplex:running(cast, {prolog_ready, Owner, 0, []}, Rebuilding),
              receive
                  {proof_ready, {Ns, Anchor}, SenderAgain, Owner, NextGeneration}
                    when SenderAgain =:= self() ->
                      ?assert(NextGeneration > FirstGeneration),
                      ?assertEqual(ok, quod_simplex:check_proof_access(Access))
              after 0 -> error(missing_rebuilt_ready_edge)
              end
          after
              quod_reg:unsubscribe({runtime, Ns}),
              stop_registered_owner(Owner)
          end
      end).

resolve_applied_opens_only_the_exact_pending_fence_test() ->
    Ns = unique_gate_namespace(<<"finalize">>),
    Anchor = <<0:256>>,
    GroupId = <<73:256>>,
    Slot = 4,
    Generation = 2,
    Open = quod_atomic:initial_projection({Ns, Anchor}, 0),
    Pending = Open#{apply_fences :=
                        #{GroupId =>
                            #{slot => Slot, generation => Generation,
                              blocking => true}},
                    generation := Generation},
    with_simplex_gate(
      Ns,
      quod_ct:proof_gate_row(
        true, Generation, [{GroupId, Slot, Generation}]),
      fun(_Tab) ->
          Access = {quod_proof_access, Ns, self(), Generation, <<251:256>>},
          S0 = st(#{ns => Ns, committee_id => <<251:256>>,
                    consensus_domain =>
                        quod_simplex:consensus_domain(Ns, Anchor),
                    dtx_projection => Pending,
                    prolog_ready => true, sync => ready,
                    eng => quod_simplex:eng_new(
                            quod_simplex:consensus_domain(Ns, Anchor), [ ], {{quod_ledger:initial_era({Ns, Anchor}), 0, Anchor}, 1, 0})}),
          ?assertEqual(
             {error, {transaction_pending, GroupId}},
             quod_simplex:check_proof_access(Access)),

          Stale = result_state(
                    quod_simplex:running(
                      cast,
                      {resolve_applied, GroupId, Slot, Generation - 1},
                      S0)),
          ?assertEqual(
             {error, {transaction_pending, GroupId}},
             quod_simplex:check_proof_access(Access)),
          Applied = result_state(
                      quod_simplex:running(
                        cast,
                        {resolve_applied, GroupId, Slot, Generation},
                        Stale)),
          ?assertEqual(
             ok, quod_simplex:check_proof_access(Access)),

          %% A duplicate is a no-op, while installing a committed closed
          %% projection republishes the protected row from the same seam used
          %% by live history and catch-up.
          Duplicate = result_state(
                        quod_simplex:running(
                          cast,
                          {resolve_applied, GroupId, Slot, Generation},
                          Applied)),
          ClosedHistory =
              (quod_simplex:test_state_projection(Duplicate))#{
                dtx := Pending},
          _Closed = quod_simplex:test_install_projection(
                      ClosedHistory, Duplicate),
          ?assertEqual(
             {error, {transaction_pending, GroupId}},
             quod_simplex:check_proof_access(Access))
      end).

%% DTX payloads remain outside the consensus engine until the exact parent
%% history and own-role Vote policy have been validated. A commit
%% certificate by itself is only retained evidence: without the block it can
%% neither notarize nor commit the slot.
dtx_certificate_cannot_bypass_parent_validation_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    {Author, AuthorId} = id(),
    Ns = unique_gate_namespace(<<"dtx-cert-only">>),
    Anchor = <<0:256>>,
    Target = {Ns, Anchor},
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Admission = quod_simplex:test_author_admission(Author),
    GroupId = crypto:hash(sha256, <<"dtx-cert-only">>),
    {ok, SourceVoteRef} =
        quod_dtx:certified_ref(
          <<"origin">>, <<1:256>>, 2, <<2:256>>, <<3:256>>,
          quod_ct:fixture_finality(1, <<2:256>>)),
    Resolve = quod_ct:atomic_abort_record(Target, GroupId, SourceVoteRef),
    {ok, Material} = quod_atomic:admission_material(Resolve),
    {ok, Control} =
        quod_atomic:sign_control(
          Target, Material, Admission, 1, 1, AuthorId),
    Era = quod_ledger:initial_era(Target),
    Root = {Era, 0, Anchor},
    Block = block({Era, 1}, Root, 2, {batch, [{dtx, Control}]}, 0),
    BH = quod_simplex:block_hash(Block),
    Eng0 = quod_simplex:eng_new(Domain, [Author], {Root, 1, 0}),
    S0 = st(#{ns => Ns, self => Author, id => AuthorId,
              consensus_domain => Domain, validators => [Author],
              slot => 1, sync => ready, eng => Eng0,
              archive_tip => {Root, 0}, history_head => {1, Anchor},
              dtx_projection => quod_atomic:initial_projection(Target, 0)}),

    SupportShare =
        quod_simplex:make_share(Domain, support, {Era, 1}, BH, AuthorId),
    CommitShare =
        quod_simplex:make_share(Domain, commit, {Era, 1}, BH, AuthorId),
    {ok, SupportCert} =
        quod_simplex:form_cert(
          Domain, support, {Era, 1}, BH, [SupportShare], [Author]),
    {ok, CommitCert} =
        quod_simplex:form_cert(
          Domain, commit, {Era, 1}, BH, [CommitShare], [Author]),
    WithCerts =
        quod_simplex:dispatch(
          Author, {cert, CommitCert},
          quod_simplex:dispatch(Author, {cert, SupportCert}, S0)),

    %% This structural fixture has an installed parent token but no Prolog
    %% owner. Certificates cannot promote its receipt to an admitted candidate;
    %% the real-founded parent-progress suite covers the subsequent verdict.
    S1 = quod_simplex:dispatch(Author, {propose, Block, []}, WithCerts),
    ?assertEqual(
       {none, none, {BH, Block}, none, undefined},
       quod_simplex:test_dtx_round(1, S1)),
    ?assertEqual(1, maps:get(slot, quod_simplex:stats_map(S1))).

%% Both an origin-retained control and a relayed control consult this one
%% slot-first leader seam.  Reversing leader/2's arguments either crashes or
%% sends the two ingress paths away from the deterministic slot owner.
dtx_local_and_relayed_controls_share_slot_leader_test() ->
    [A, B, C] = Validators = lists:sort(pubs(committee(3))),
    LocalSlot = hd([Slot || Slot <- lists:seq(1, 32),
                            quod_simplex:leader(Slot, Validators) =:= B]),
    RelaySlot = hd([Slot || Slot <- lists:seq(1, 32),
                            quod_simplex:leader(Slot, Validators) =/= B]),
    ExpectedPeer = quod_simplex:leader(RelaySlot, Validators),
    InLink = spawn(fun() -> receive stop -> ok end end),
    S = st(#{self => B, validators => Validators,
             inbound_conns => #{ExpectedPeer => {InLink, make_ref()}},
             peer_readiness =>
                 voting_readiness([ExpectedPeer], InLink, RelaySlot - 1)}),
    ?assertEqual(local,
                 quod_simplex:test_dtx_slot_route(LocalSlot, S)),
    ?assertEqual({relay, ExpectedPeer},
                 quod_simplex:test_dtx_slot_route(RelaySlot, S)),
    ?assert(lists:member(ExpectedPeer, [A, C])),
    InLink ! stop.

%% A retired holder still serves historical phase/applied evidence, but cannot
%% accept signed work or answer a current-committee outcome query. The latter
%% already fails at current_outcome_snapshot; refuse it before parking a worker.
dtx_endpoint_reads_survive_validator_retirement_test() ->
    {Self, _SelfId} = id(),
    {Other, _OtherId} = id(),
    Ns = <<"quod:dtx-retired-holder">>,
    S = st(#{ns => Ns, self => Self, validators => [Other],
             committee_id => <<24:256>>,
             sync => ready, prolog_ready => true, store => memory}),
    Ref = dtx_test_ref({Ns, <<0:256>>}, 2, <<21:256>>),
    GroupId = <<22:256>>,
    GroupRef = {group, Ns, <<0:256>>, Other, <<23:256>>, GroupId},
    ?assertNot(
       quod_simplex:test_dtx_endpoint_ready(
         {submit, <<1:128>>, maps:get(vote_blob, quod_ct:atomic_role_fixture())}, S)),
    ?assert(
       quod_simplex:test_dtx_endpoint_ready(
         {phase, <<2:128>>, GroupId, resolve}, S)),
    ?assertNot(
       quod_simplex:test_dtx_endpoint_ready(
         {outcome, <<3:128>>, GroupRef, <<24:256>>, 1}, S)),
    Active = quod_simplex:test_state_set(validators, [Self], S),
    ?assert(
       quod_simplex:test_dtx_endpoint_ready(
         {outcome, <<3:128>>, GroupRef, <<24:256>>, 1}, Active)),
    ?assert(
       quod_simplex:test_dtx_endpoint_ready(
         {applied, <<4:128>>, GroupId, Ref, 3, commit}, S)).

dtx_outcome_facade_preserves_only_authoritative_results_test() ->
    TxRef = {transaction, <<"quod:remote">>, <<51:256>>, <<52:256>>},
    GroupRef = {group, <<"quod:remote">>, <<51:256>>, <<53:256>>,
                <<54:256>>, <<55:256>>},
    Status = #{status => committed, height => 7, ref => TxRef},
    ?assertEqual(
       {ok, Status},
       quod_simplex:test_dtx_outcome_result(TxRef, {ok, Status})),
    ?assertEqual(
       {error, {outcome_unknown, TxRef}},
       quod_simplex:test_dtx_outcome_result(TxRef, {error, retry})),
    ?assertEqual(
       {error, {outcome_unknown, TxRef}},
       quod_simplex:test_dtx_outcome_result(TxRef, {error, not_found})),
    ?assertEqual(
       {error, {outcome_unknown, GroupRef}},
       quod_simplex:test_dtx_outcome_result(GroupRef, {error, not_found})).

owner_terminal_results_follow_the_retired_row_not_the_wrapper_test() ->
    RequestId = <<4:128>>,
    ?assertEqual(
       busy,
       quod_simplex:test_endpoint_terminal_result(
         {ok, {error, RequestId, busy}, []})),
    ?assertEqual(
       timeout,
       quod_simplex:test_dtx_worker_terminal_result(
         {submit_result, <<5:256>>, {error, timeout}},
         {error, RequestId, not_ready})),
    %% Metrics classification must never turn a real re-envelope failure into
    %% a Simplex crash while the original caller error is being returned.
    ?assertEqual(
       error,
       quod_simplex:test_dtx_retirement_result(unexpected_signing_failure)).

operation_recovery_owner_replies_once_and_retains_exact_result_test() ->
    TargetRef = {transaction, <<"quod:target">>, <<1:256>>, <<2:256>>},
    ?assertMatch(
       #{reply := {operation_results, [{_, {committed, TargetRef}}]},
         stored := {operation_results, [{_, {committed, TargetRef}}]},
         waiters := 0,
         duplicate := {true, _}},
       quod_simplex:test_operation_target_result(committed, TargetRef)),
    ?assertMatch(
       #{reply := {operation_results, [{_, {{rejected, not_authorized}, TargetRef}}]},
         stored := {operation_results, [{_, {{rejected, not_authorized}, TargetRef}}]},
         waiters := 0,
         duplicate := {true, _}},
       quod_simplex:test_operation_target_result(
         {rejected, not_authorized}, TargetRef)).

%% A relay can acknowledge a committed source claim before a non-leading
%% gateway applies that same block. The waiter must park in the existing
%% recovery owner and survive projection installation; the old code returned
%% outcome_unknown immediately, so this test could not reach the assertions.
%% If its caller dies first, the pre-projection placeholder leaves no residue.
operation_waiter_survives_relay_reply_before_claim_projection_test() ->
    Claim = maps:get(
              claim, quod_ct:remote_operation_fixture(#{})),
    ?assertEqual(
       #{waiting_status => pending,
         waiting_count => 1,
         abandoned_present => false,
         projected_status => pending,
         projected_slot => 7,
         projected_waiters => 1},
       quod_simplex:test_operation_wait_before_projection(7, Claim)).

%% Response ownership is the exact authenticated peer plus the exact request;
%% a valid response on the right namespace from any other peer is inert.
dtx_endpoint_response_correlation_is_exact_and_released_test() ->
    Ns = <<"quod:dtx-correlation">>,
    {ExpectedPeer, _} = id(),
    {WrongPeer, _} = id(),
    RequestId = <<5:128>>,
    Request = {phase, RequestId, <<24:256>>, vote},
    Response = {phase, RequestId, 7, pending},
    {ok, Frame} = quod_dtx_endpoint:encode_response(Ns, Response, []),
    From = {self(), make_ref()},
    S0 = quod_simplex:test_seed_dtx_correlation(
           Ns, ExpectedPeer, Request, From, st(#{ns => Ns})),
    SeededStats = quod_simplex:test_owner_stats(S0),
    ?assertMatch(
       #{dtx_endpoint := #{outbound := 1, inbound := 0}},
       maps:get(owner_current, SeededStats)),
    ?assertMatch(
       #{dtx_endpoint := #{outbound := 1, inbound := 0}},
       maps:get(owner_peak, SeededStats)),
    {Wrong, []} = quod_simplex:test_dtx_endpoint_frame(
                    Ns, serve, WrongPeer, self(), Frame, S0),
    ?assertEqual(1, maps:get(correlations,
                            quod_simplex:test_dtx_endpoint_counts(Wrong))),
    {Done, Actions} = quod_simplex:test_dtx_endpoint_frame(
                        Ns, serve, ExpectedPeer, self(), Frame, Wrong),
    ?assertEqual([{reply, From, {ok, Response, []}}], Actions),
    ?assertEqual(0, maps:get(correlations,
                            quod_simplex:test_dtx_endpoint_counts(Done))),
    DoneStats = quod_simplex:test_owner_stats(Done),
    ?assertMatch(
       #{dtx_endpoint := #{outbound := 0, inbound := 0}},
       maps:get(owner_current, DoneStats)),
    ?assertMatch(
       #{dtx_endpoint := #{outbound := 1, inbound := 0}},
       maps:get(owner_peak, DoneStats)).

dtx_endpoint_accepted_response_carries_exact_committed_entry_test() ->
    Fixture = quod_ct:atomic_role_fixture(),
    Target = {Ns, Anchor} = maps:get(target, Fixture),
    Record = maps:get(vote, Fixture),
    Control = maps:get(vote_control, Fixture),
    {ok, RecordBlob} = quod_atomic:encode_record(Record),
    Digest = quod_atomic:record_digest(Record),
    {Entry, _Payload, Ref} =
        certified_dtx_test_entry(Target, Control, 7),
    RequestId = <<177:128>>,
    Request = {submit, RequestId, RecordBlob},
    ?assertEqual(
       {{accepted, RequestId, Digest, Ref}, [{Ref, Entry}]},
       quod_simplex:test_dtx_endpoint_result_with_hints(
         Request, {submit_result, Digest, {ok, Ref, [{Ref, Entry}]}},
         st(#{ns => Ns, genesis_hash => Anchor}))).

%% Replies travel back on the request's bidirectional stream.  An outbound
%% pinned link publishes its peer as the bare TLS-pinned key, whereas an
%% inbound link publishes the authenticated `{Key, Endpoint}` header.  Both
%% transport identities must reach the same exact correlation check; malformed
%% identities must neither reply nor release someone else's request.
dtx_outbound_response_normalizes_transport_identity_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    OwnerNs = <<"quod:dtx-response-owner">>,
    TargetNs = <<"quod:dtx-response-target">>,
    {ExpectedPeer, _} = id(),
    RequestId = <<6:128>>,
    Request = {phase, RequestId, <<25:256>>, vote},
    Response = {phase, RequestId, 3, pending},
    {ok, Frame} = quod_dtx_endpoint:encode_response(TargetNs, Response, []),
    From = {self(), make_ref()},
    Seeded = quod_simplex:test_seed_dtx_correlation(
               TargetNs, ExpectedPeer, Request, From,
               st(#{ns => OwnerNs})),
    Channel = quod_dtx_endpoint:channel(TargetNs),
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_outbound_message(
         malformed_identity, self(), Channel, Frame, Seeded)),
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_outbound_message(
         ExpectedPeer, self(), <<"unrelated-channel">>, Frame, Seeded)),
    ?assertEqual(
       #{correlations => 1, channels => 1},
       maps:with([correlations, channels],
                 quod_simplex:test_dtx_endpoint_counts(Seeded))),
    WrongLink = spawn(fun test_blocked_process/0),
    {handled, StillCorrelated, []} =
        quod_simplex:test_dtx_outbound_message(
          ExpectedPeer, WrongLink, Channel, Frame, Seeded),
    ?assertEqual(
       1, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(StillCorrelated))),
    WrongLink ! stop,
    {handled, Done, Actions} = quod_simplex:test_dtx_outbound_message(
                                 ExpectedPeer, self(), Channel, Frame, Seeded),
    ?assertEqual([{reply, From, {ok, Response, []}}], Actions),
    ?assertEqual(
       #{correlations => 0, channels => 0},
       maps:with([correlations, channels],
                 quod_simplex:test_dtx_endpoint_counts(Done))),

    %% A same-namespace remote fallback uses the namespace's permanent DTX
    %% subscription rather than a dynamically retained target channel.
    SameNs = <<"quod:dtx-response-same-ns">>,
    SameChannel = quod_dtx_endpoint:channel(SameNs),
    SameId = <<7:128>>,
    SameRequest = {phase, SameId, <<26:256>>, resolve},
    SameResponse = {phase, SameId, 0, not_found},
    {ok, SameFrame} = quod_dtx_endpoint:encode_response(
                        SameNs, SameResponse, []),
    SameFrom = {self(), make_ref()},
    SameSeeded = quod_simplex:test_seed_dtx_correlation(
                   SameNs, ExpectedPeer, SameRequest, SameFrom,
                   st(#{ns => SameNs, dtx_chan => SameChannel})),
    {handled, SameDone, SameActions} =
        quod_simplex:test_dtx_outbound_message(
          {ExpectedPeer, {"127.0.0.1", 15970}},
          self(), SameChannel, SameFrame, SameSeeded),
    ?assertEqual([{reply, SameFrom, {ok, SameResponse, []}}], SameActions),
    ?assertEqual(
       0, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(SameDone))).

%% A request is inert until its exact pinned open authenticates. The callback
%% then queues the frame asynchronously on the ordered link FIFO; crossed open
%% results cannot send or take ownership of the correlation.
dtx_endpoint_request_sends_only_after_exact_pinned_link_up_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    OwnerNs = <<"quod:dtx-link-owner">>,
    TargetNs = <<"quod:dtx-link-target">>,
    {Peer, _} = id(),
    RequestId = <<71:128>>,
    Request = {phase, RequestId, <<72:256>>, vote},
    From = {self(), make_ref()},
    {OpenRef, Opening} =
        quod_simplex:test_seed_opening_dtx_correlation(
          TargetNs, Peer, Request, From, st(#{ns => OwnerNs})),
    Channel = quod_dtx_endpoint:channel(TargetNs),
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_correlation_link_up(
         make_ref(), Peer, Channel, self(), Opening)),
    receive
        {send_ordered, Unexpected0} -> error({crossed_open_sent, Unexpected0})
    after 0 -> ok
    end,
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_correlation_link_up(
         OpenRef, <<73:256>>, Channel, self(), Opening)),
    receive
        {send_ordered, Unexpected1} -> error({wrong_peer_sent, Unexpected1})
    after 0 -> ok
    end,
    {handled, Sent, []} =
        quod_simplex:test_dtx_correlation_link_up(
          OpenRef, Peer, Channel, self(), Opening),
    SentFrame = receive_ordered_frame(),
    {ok, Request, [], _Carrier} = quod_dtx_endpoint:decode_request(TargetNs, SentFrame),
    Response = {phase, RequestId, 9, pending},
    {ok, ResponseFrame} =
        quod_dtx_endpoint:encode_response(TargetNs, Response, []),
    {handled, Done, Actions} = quod_simplex:test_dtx_outbound_message(
                                 Peer, self(), Channel, ResponseFrame, Sent),
    ?assertEqual([{reply, From, {ok, Response, []}}], Actions),
    ?assertEqual(
       0, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(Done))),
    Parent = self(),
    Orphan = spawn(
               fun() ->
                       receive close -> Parent ! {orphan_closed, self()} end
               end),
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_correlation_link_up(
         OpenRef, Peer, Channel, Orphan, Done)),
    receive {orphan_closed, Orphan} ->
        error(simplex_closed_transport_owned_stale_link)
    after 0 -> ok
    end,
    Orphan ! close,
    receive {orphan_closed, Orphan} -> ok
    after 1000 -> error(orphan_cleanup_failed)
    end.

%% Once authenticated, the exact link monitor is the terminal loss edge. It
%% releases the caller immediately and never waits for or manufactures a retry
%% timer; a replacement request belongs to the higher-level route wake.
dtx_endpoint_exact_link_down_releases_only_its_correlation_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    OwnerNs = <<"quod:dtx-link-down-owner">>,
    TargetNs = <<"quod:dtx-link-down-target">>,
    {Peer, _} = id(),
    Request = {phase, <<74:128>>, <<75:256>>, resolve},
    From = {self(), make_ref()},
    {OpenRef, Opening} =
        quod_simplex:test_seed_opening_dtx_correlation(
          TargetNs, Peer, Request, From, st(#{ns => OwnerNs})),
    Parent = self(),
    Link = spawn(
             fun() ->
                     receive
                         {send_ordered, Frame} ->
                             Parent ! {dtx_link_sent, self(), Frame},
                             test_blocked_process()
                     end
             end),
    Channel = quod_dtx_endpoint:channel(TargetNs),
    {handled, Sent, []} =
        quod_simplex:test_dtx_correlation_link_up(
          OpenRef, Peer, Channel, Link, Opening),
    receive {dtx_link_sent, Link, _Frame} -> ok
    after 1000 -> error(dtx_request_not_sent)
    end,
    exit(Link, kill),
    LinkMRef = receive
                   {'DOWN', Ref, process, Link, killed} -> Ref
               after 1000 -> error(dtx_link_down_not_monitored)
               end,
    {true, Done, Actions} =
        quod_simplex:test_drop_dtx_endpoint_owner(LinkMRef, Link, Sent),
    ?assertEqual([{reply, From, {error, connection_lost}}], Actions),
    ?assertEqual(
       0, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(Done))).

%% A timed-out request releases its exact endpoint/ref lease. A link_up already
%% queued for that old ref is inert in Simplex: it neither sends nor closes a
%% transport-owned link, and a different endpoint lease still progresses.
dtx_endpoint_timeout_then_late_link_up_preserves_other_lease_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    OwnerNs = <<"quod:dtx-lease-owner">>,
    TargetNs = <<"quod:dtx-lease-target">>,
    {Peer, _} = id(),
    Channel = quod_dtx_endpoint:channel(TargetNs),
    Endpoint1 = {"127.0.0.1", 15972},
    Endpoint2 = {"127.0.0.1", 15973},
    Request1 = {phase, <<76:128>>, <<77:256>>, vote},
    Request2 = {phase, <<78:128>>, <<79:256>>, vote},
    From1 = {self(), make_ref()},
    From2 = {self(), make_ref()},
    {OpenRef1, Opening1} =
        quod_simplex:test_seed_opening_dtx_correlation(
          TargetNs, Peer, Endpoint1, Request1, From1,
          st(#{ns => OwnerNs})),
    {OpenRef2, Opening2} =
        quod_simplex:test_seed_opening_dtx_correlation(
          TargetNs, Peer, Endpoint2, Request2, From2, Opening1),
    {OneLeft, [{reply, From1, {error, timeout}}]} =
        quod_simplex:test_timeout_dtx_correlation(<<76:128>>, Opening2),
    Parent = self(),
    Link1 = spawn(fun() -> test_link_probe(Parent) end),
    Link2 = spawn(fun() -> test_link_probe(Parent) end),
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_correlation_link_up(
         OpenRef1, Peer, Channel, Link1, OneLeft)),
    receive
        {dtx_link_sent, Link1, _} -> error(timed_out_request_was_sent);
        {dtx_link_closed, Link1} -> error(simplex_closed_stale_leased_link)
    after 0 -> ok
    end,
    {handled, Sent, []} = quod_simplex:test_dtx_correlation_link_up(
                            OpenRef2, Peer, Channel, Link2, OneLeft),
    receive {dtx_link_sent, Link2, _} -> ok
    after 1000 -> error(second_dtx_link_did_not_send)
    end,
    ?assertEqual(
       1, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(OneLeft))),
    Response2 = {phase, <<78:128>>, 11, pending},
    {ok, Frame2} = quod_dtx_endpoint:encode_response(
                     TargetNs, Response2, []),
    {handled, Done, [{reply, From2, {ok, Response2, []}}]} =
        quod_simplex:test_dtx_outbound_message(
          Peer, Link2, Channel, Frame2, Sent),
    receive {dtx_link_closed, Link2} ->
        error(simplex_closed_completed_leased_link)
    after 0 -> ok
    end,
    ?assertEqual(
       0, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(Done))),
    Link1 ! stop,
    Link2 ! stop.

%% Every terminal owner edge releases the immutable endpoint/OpenRef lease.
%% Wrong correlation data is inert, and termination releases both refs even
%% when their eventual transport stream would have been shared.
dtx_endpoint_terminal_paths_release_exact_request_leases_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    with_transport_stub(
      fun() ->
          OwnerNs = <<"quod:dtx-release-owner">>,
          TargetNs = <<"quod:dtx-release-target">>,
          {Peer, _} = id(),
          Endpoint = {"127.0.0.1", 15974},
          Channel = quod_dtx_endpoint:channel(TargetNs),
          From = {self(), make_ref()},

          TimeoutRequest = {phase, <<80:128>>, <<81:256>>, vote},
          {TimeoutRef, TimeoutOpening} =
              quod_simplex:test_seed_opening_dtx_correlation(
                TargetNs, Peer, Endpoint, TimeoutRequest, From,
                st(#{ns => OwnerNs})),
          ?assertEqual(
             ignore,
             quod_simplex:test_dtx_correlation_link_error(
               make_ref(), Peer, Channel, TimeoutOpening)),
          ?assertEqual(
             ignore,
             quod_simplex:test_dtx_correlation_link_error(
               TimeoutRef, <<82:256>>, Channel, TimeoutOpening)),
          assert_no_transport_cast(),
          {_AfterTimeout, [{reply, From, {error, timeout}}]} =
              quod_simplex:test_timeout_dtx_correlation(
                <<80:128>>, TimeoutOpening),
          receive_exact_lease_release(
            Peer, Endpoint, Channel, TimeoutRef),

          CallerRequest = {phase, <<83:128>>, <<84:256>>, resolve},
          {CallerRef, CallerOpening} =
              quod_simplex:test_seed_opening_dtx_correlation(
                TargetNs, Peer, Endpoint, CallerRequest, From,
                st(#{ns => OwnerNs})),
          {true, _AfterCallerDown, []} =
              quod_simplex:test_drop_dtx_correlation_caller(
                <<83:128>>, CallerOpening),
          receive_exact_lease_release(
            Peer, Endpoint, Channel, CallerRef),

          ResponseRequest = {phase, <<85:128>>, <<86:256>>, resolve},
          {ResponseRef, ResponseOpening} =
              quod_simplex:test_seed_opening_dtx_correlation(
                TargetNs, Peer, Endpoint, ResponseRequest, From,
                st(#{ns => OwnerNs})),
          Parent = self(),
          ResponseLink = spawn(fun() -> test_link_probe(Parent) end),
          {handled, ResponseSent, []} =
              quod_simplex:test_dtx_correlation_link_up(
                ResponseRef, Peer, Channel, ResponseLink,
                ResponseOpening),
          receive {dtx_link_sent, ResponseLink, _} -> ok
          after 1000 -> error(response_request_not_sent)
          end,
          Response = {phase, <<85:128>>, 12, pending},
          {ok, ResponseFrame} = quod_dtx_endpoint:encode_response(
                                  TargetNs, Response, []),
          {handled, _ResponseDone,
           [{reply, From, {ok, Response, []}}]} =
              quod_simplex:test_dtx_outbound_message(
                Peer, ResponseLink, Channel, ResponseFrame, ResponseSent),
          receive_exact_lease_release(
            Peer, Endpoint, Channel, ResponseRef),
          ResponseLink ! stop,

          Request1 = {phase, <<87:128>>, <<88:256>>, vote},
          Request2 = {phase, <<89:128>>, <<90:256>>, vote},
          {Ref1, Opening1} =
              quod_simplex:test_seed_opening_dtx_correlation(
                TargetNs, Peer, Endpoint, Request1,
                {self(), make_ref()}, st(#{ns => OwnerNs})),
          {Ref2, Opening2} =
              quod_simplex:test_seed_opening_dtx_correlation(
                TargetNs, Peer, Endpoint, Request2,
                {self(), make_ref()}, Opening1),
          ok = quod_simplex:test_close_dtx_endpoint(Opening2),
          Releases =
              [receive_any_lease_release(), receive_any_lease_release()],
          ?assertEqual(
             lists:sort([{Peer, Endpoint, Channel, Ref1},
                         {Peer, Endpoint, Channel, Ref2}]),
             lists:sort(Releases)),
          receive {_Tag1, {error, not_ready}} -> ok
          after 1000 -> error(first_terminate_reply_missing)
          end,
          receive {_Tag2, {error, not_ready}} -> ok
          after 1000 -> error(second_terminate_reply_missing)
          end
      end).

%% Repeated authenticated requests remain on the one readiness path; no hidden
%% rate counter changes their result or allocates a worker.
dtx_endpoint_requests_have_no_rate_gate_test() ->
    Ns = <<"quod:dtx-rate">>,
    {Peer, _} = id(),
    PeerIdentity = {Peer, {"127.0.0.1", 15971}},
    S0 = st(#{ns => Ns}),
    {S1, Replies} =
        lists:foldl(
          fun(N, {SAcc, Acc}) ->
                  Request = {phase, <<N:128>>, <<25:256>>, vote},
                  {ok, Frame} = quod_dtx_endpoint:encode_request(
                                  Ns, Request, []),
                  {SNext, []} = quod_simplex:test_dtx_endpoint_frame(
                                  Ns, serve, PeerIdentity, self(), Frame, SAcc),
                  Reply = receive
                              {send_ordered, ReplyFrame} ->
                                  {ok, Decoded, []} =
                                      quod_dtx_endpoint:decode_response(
                                        Ns, ReplyFrame),
                                  Decoded
                          after 1000 ->
                              error(missing_dtx_endpoint_reply)
                          end,
                  {SNext, [Reply | Acc]}
          end, {S0, []}, lists:seq(1, 33)),
    [Last | Earlier] = Replies,
    ?assertMatch({error, <<33:128>>, not_ready}, Last),
    ?assert(lists:all(
              fun({error, _Id, not_ready}) -> true;
                 (_) -> false
              end, Earlier)),
    Counts = quod_simplex:test_dtx_endpoint_counts(S1),
    ?assertEqual(0, maps:get(workers, Counts)).


dtx_contact_is_bound_to_the_resolves_certified_source_test() ->
    Fixture = quod_ct:atomic_role_fixture(),
    Target = maps:get(target, Fixture),
    Resolve = quod_ct:atomic_abort_record(Target, quod_atomic:group_id(maps:get(group, Fixture)),
                                          maps:get(source_ref, Fixture)),
    ?assertEqual(
       {ok, maps:get(origin, Fixture)},
       quod_simplex:test_dtx_source_identity(
         Resolve, Target)),
    %% A co-hosted origin needs no foreign bootstrap association, and record
    %% kinds without an authenticated source reference create none.
    ?assertEqual(
       none,
       quod_simplex:test_dtx_source_identity(
         Resolve, maps:get(origin, Fixture))),
    ?assertEqual(
       none,
       quod_simplex:test_dtx_source_identity(
         maps:get(vote, Fixture), Target)).

%% A keyed peer may claim any origin inside decode-only DTX material. The
%% authenticated endpoint is useful to the exact verification attempt, but it
%% must not become a reusable route before that attempt succeeds. A transient
%% history row is not the security boundary: an exact verifier or an unrelated
%% legitimate follower may own one while this asynchronous request is active.
dtx_unverified_endpoint_contacts_are_never_retained_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Dir = relay_store_dir("unverified_dtx_contact"),
    case quod_reg:where({foreign_log, node}) of
        Existing when is_pid(Existing) -> gen_server:stop(Existing);
        undefined -> ok
    end,
    Fetch = fun(_Peer, _Endpoint, _Ns, _Query, _Deadline, _Consume) ->
                    {error, unavailable}
            end,
    {ok, ForeignLog} = quod_foreign_log:start_link(
                         #{cache_dir => Dir, fetch_fun => Fetch,
                           page_timeout_ms => 100}),
    EndpointSink = spawn(fun registered_prolog_sink_loop/0),
    {Peer, _PeerIdentity} = id(),
    Endpoint = {"127.0.0.1", 15972},
    PeerContact = {Peer, Endpoint},
    try
        Operation = quod_ct:remote_operation_fixture(#{}),
        {ok, ClaimEvidence} = quod_transaction:encode_evidence(
                                maps:get(certified_claim_ref, Operation),
                                maps:get(claim, Operation)),
        {TargetNs, _} = Target = maps:get(participant_target, Operation),
        ApplyRequest = {apply_claim, <<72:128>>, Target, ClaimEvidence},
        ApplyState0 = ready_dtx_endpoint_state(
                        Target, maps:get(node_identity, Operation),
                        maps:get(admission, Operation)),
        {ok, ApplyFrame} = quod_dtx_endpoint:encode_request(
                             TargetNs, ApplyRequest, []),
        {ApplyState, []} = quod_simplex:test_dtx_endpoint_frame(
                             TargetNs, serve, PeerContact, EndpointSink,
                             ApplyFrame, ApplyState0),
        ?assertEqual(
           false,
           foreign_contact_is_routable(Target, PeerContact)),
        ?assertEqual(
           0,
           maps:get(bootstrap_candidates, quod_foreign_log:stats())),
        ok = quod_simplex:test_close_dtx_endpoint(ApplyState),

        VoteFixture = quod_ct:atomic_role_fixture(),
        {VoteNs, _} = VoteTarget = maps:get(target, VoteFixture),
        SubmitRequest = {submit, <<73:128>>,
                         maps:get(vote_blob, VoteFixture)},
        SubmitState0 = ready_dtx_endpoint_state(
                         VoteTarget, maps:get(signer, VoteFixture),
                         maps:get(admission, VoteFixture),
                         %% Reject after decoding but before signing or
                         %% retaining. The old path had already persisted the
                         %% claimed source contact at this exact point.
                         #{dtx_projection => undefined}),
        {ok, SubmitFrame} = quod_dtx_endpoint:encode_request(
                              VoteNs, SubmitRequest, []),
        {SubmitState, []} = quod_simplex:test_dtx_endpoint_frame(
                              VoteNs, serve, PeerContact, EndpointSink,
                              SubmitFrame, SubmitState0),
        ?assertEqual(
           false,
           foreign_contact_is_routable(VoteTarget, PeerContact)),
        ?assertEqual(
           0,
           maps:get(bootstrap_candidates, quod_foreign_log:stats())),
        ok = quod_simplex:test_close_dtx_endpoint(SubmitState)
    after
        stop_registered_prolog_sink(EndpointSink),
        gen_server:stop(ForeignLog),
        _ = file:del_dir_r(Dir)
    end.

%% Seen is shared across the candidate's requirements, but the reference kind
%% remains part of the proof obligation.  Identical bytes already verified as
%% a control entry cannot later satisfy a transaction requirement (or the
%% reverse) merely because both requirements use the same map key.
content_reference_seen_reuse_is_type_safe_test() ->
    Ref = {certified, <<74:256>>, 2, <<75:256>>, <<76:256>>},
    EntryEvidence = #{entry => material_entry(2, {?FIXTURE_ERA, 1},
        {?FIXTURE_ERA, 0, <<1:256>>}, {batch, [tx([])]}, 0)},
    TransactionEvidence = #{transaction => #transaction{}},
    ?assertMatch(
       {valid, _},
       quod_simplex:test_verify_content_requirements(
         [{entry, Ref}, {entry, Ref}], #{Ref => EntryEvidence})),
    ?assertEqual(
       {invalid, foreign_reference},
       quod_simplex:test_verify_content_requirements(
         [{entry, Ref}, {transaction, Ref}], #{Ref => EntryEvidence})),
    ?assertEqual(
       {invalid, foreign_reference},
       quod_simplex:test_verify_content_requirements(
         [{transaction, Ref}, {entry, Ref}],
         #{Ref => TransactionEvidence})).

%% The authenticated endpoint is a request-scoped route hint for the claim
%% transaction only.  Read-certificate anchors in the same application must
%% be resolved and verified independently, never through that contact.
content_reference_contact_is_claim_only_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    ClaimRef = maps:get(certified_claim_ref, Fixture),
    Application = maps:get(application, Fixture),
    Target = maps:get(participant_target, Fixture),
    {ok, EvidenceBlob} = quod_transaction:encode_evidence(
                           ClaimRef, maps:get(claim, Fixture)),
    Request = {apply_claim, <<77:128>>, Target, EvidenceBlob},
    Worker = spawn(fun validation_owner/0),
    Peer = <<78:256>>,
    Endpoint = {"127.0.0.1", 15973},
    {_Monitor, State} = quod_simplex:test_seed_dtx_worker(
                          Worker, {Peer, Endpoint}, Request,
                          {link, self()}, st(#{})),
    EntryRef = {certified, <<79:256>>, 3, <<80:256>>, <<81:256>>},
    try
        Contacts = quod_simplex:test_content_reference_contacts(
                     [{Application,
                       [{transaction, ClaimRef}, {entry, EntryRef}]}],
                     Target, State),
        ?assertEqual(
           #{ClaimRef => {maps:get(origin, Fixture), {Peer, Endpoint}}},
           Contacts),
        ?assertEqual(false, maps:is_key(EntryRef, Contacts)),
        %% A worker for another target cannot lend this owner its contact,
        %% even when a caller supplies the same candidate transaction plan.
        ?assertEqual(#{}, quod_simplex:test_content_reference_contacts(
          [{Application, [{transaction, ClaimRef}]}],
          {element(1, Target), <<82:256>>}, State))
    after
        exit(Worker, kill)
    end.

foreign_contact_is_routable(Identity, {Peer, Endpoint}) ->
    case quod_foreign_log:route_hints(Identity, []) of
        {ok, Routes} ->
            lists:member(Endpoint, proplists:get_value(Peer, Routes, []));
        {error, unavailable} ->
            false
    end.

ready_dtx_endpoint_state(
  {Ns, Anchor}, #{pubkey := _} = Identity, Admission) ->
    ready_dtx_endpoint_state(
      {Ns, Anchor}, Identity, Admission, #{}).

ready_dtx_endpoint_state(
  {Ns, Anchor}, #{pubkey := Self} = Identity, Admission, Extra) ->
    st(maps:merge(
         #{ns => Ns, genesis_hash => Anchor,
           self => Self, id => Identity,
           validators => [Self],
           author_admissions => #{Self => Admission},
           sync => ready, prolog_ready => true},
         Extra)).

%% The endpoint deadline owns only its waiter, not the durable semantic
%% submission.  Once the owner dies, a later recovery request can attach one
%% fresh waiter instead of seeing `busy` forever or accumulating dead PIDs.
dtx_endpoint_owner_down_detaches_waiter_but_retains_submission_test() ->
    Fixture = quod_ct:atomic_role_fixture(),
    Control = maps:get(vote_control, Fixture),
    Record = maps:get(vote, Fixture),
    {ok, RecordBlob} = quod_atomic:encode_record(Record),
    Request = {submit, <<211:128>>, RecordBlob},
    Worker = spawn(fun validation_owner/0),
    From = {self(), make_ref()},
    {Ns, Anchor} = maps:get(target, Fixture),
    {Monitor, WithWorker} = quod_simplex:test_seed_dtx_worker(
                              Worker, local, Request, {caller, From},
                              st(#{ns => Ns, genesis_hash => Anchor})),
    Retained = quod_simplex:test_seed_dtx_submission(
                 Control, [{dtx_endpoint, Worker}], WithWorker),
    RetainedState = quod_simplex:test_retained_dtx_state(Retained),
    exit(Worker, kill),
    receive
        {'DOWN', Monitor, process, Worker, killed} -> ok
    after 1000 ->
        error(missing_endpoint_owner_down)
    end,
    {true, Detached, _Actions} = quod_simplex:test_drop_dtx_endpoint_owner(
                                   Monitor, Worker, Retained),
    ?assertEqual(0, quod_simplex:test_dtx_submission_waiters(Detached)),
    DetachedState = quod_simplex:test_retained_dtx_state(Detached),
    ?assertEqual(maps:get(bytes, RetainedState),
                 maps:get(bytes, DetachedState)),
    ?assertEqual(#{}, maps:get(waiter_index, DetachedState)),
    ?assertEqual(
       maps:get(retained, DetachedState),
       maps:get(ready, DetachedState) + maps:get(blocked, DetachedState)),
    ?assertEqual(
       1, maps:get(submissions,
                   quod_simplex:test_dtx_endpoint_counts(Detached))),
    RetryOwner = spawn(fun validation_owner/0),
    try
        {ok, Retried} = quod_simplex:test_retain_dtx_record(
                          Record, {dtx_endpoint, RetryOwner}, Detached),
        ?assertEqual(1, quod_simplex:test_dtx_submission_waiters(Retried)),
        ?assertEqual(
           #{RetryOwner => quod_atomic:record_digest(Record)},
           maps:get(waiter_index,
                    quod_simplex:test_retained_dtx_state(Retried)))
    after
        RetryOwner ! stop
    end.

%% A co-hosted endpoint submit enters custody in its call turn, then one
%% self-message drives every control already waiting in the mailbox. This is
%% immediate and event-driven, but gives concurrent submissions one natural
%% Erlang scheduling edge in which to form a byte-bounded consensus wave.
dtx_endpoint_local_submit_drives_on_mailbox_edge_test() ->
    Fixture = quod_ct:atomic_role_fixture(),
    {Ns, Anchor} = maps:get(target, Fixture),
    #{pubkey := Self} = Signer = maps:get(signer, Fixture),
    Admission = maps:get(admission, Fixture),
    Record = quod_ct:atomic_abort_record(maps:get(target, Fixture),
                  quod_atomic:group_id(maps:get(group, Fixture)), maps:get(source_ref, Fixture)),
    {ok, RecordBlob} = quod_atomic:encode_record(Record),
    Request = {submit, <<212:128>>, RecordBlob},
    [{_Phase, RequiredRef} | _] = quod_atomic:reference_requirements(Record),
    {ok, _Identity, RequiredSlot, _Digest} =
        quod_dtx:certified_ref_binding(RequiredRef),
    ValidationSidecar =
        [{RequiredRef, element(1, committed_dtx_test_entry(
            maps:get(source_control, Fixture), RequiredSlot))}],
    From = {self(), make_ref()},
    Dir = relay_store_dir("dtx_local_immediate"),
    {ok, Journal} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Self, id => Signer,
                  validators => [Self],
                  author_admissions => #{Self => Admission},
                  sync => ready, prolog_ready => true,
                  slot => 1, last_applied => 1,
                  history_head => {1, Anchor},
                  store => memory, signing_journal => Journal}),
        {keep_state, Retained, _Actions0} =
            quod_simplex:running(
              {call, From},
              {dtx_endpoint_local, Request, ValidationSidecar, 1000, otel_ctx:new()}, S0),
        try
            ?assertEqual(
               0, maps:get(proposals, quod_simplex:stats_map(Retained))),
            receive dtx_drive -> ok
            after 0 -> error(missing_dtx_mailbox_wake)
            end,
            {keep_state, Proposed, _Actions1} =
                quod_simplex:running(info, dtx_drive, Retained),
            ?assertEqual(
               1, maps:get(proposals, quod_simplex:stats_map(Proposed))),
            {_, _, {_, #block{slot = 1}}, _, _} =
                quod_simplex:test_dtx_round(1, Proposed),
            ?assertEqual(ValidationSidecar,
                         quod_simplex:test_dtx_round_hints(1, Proposed))
        after
            ok = quod_simplex:terminate(test, running, Retained)
        end
    after
        _ = catch quod_signing_journal:close(Journal),
        _ = file:del_dir_r(Dir)
    end.

%% Once a retained control is queued on a live ordered link, unrelated
%% progress turns must not enqueue it again.  The placement is tied to the
%% link pid, so replacing that link makes the same durable row eligible for
%% exactly one reconstruction send without a retry clock or relay queue.
dtx_reliable_relay_is_placed_once_per_link_test() ->
    Fixture = quod_ct:atomic_role_fixture(),
    {Ns, Anchor} = maps:get(target, Fixture),
    #{pubkey := Self} = Signer = maps:get(signer, Fixture),
    Admission = maps:get(admission, Fixture),
    Record = quod_ct:atomic_abort_record(maps:get(target, Fixture),
                  quod_atomic:group_id(maps:get(group, Fixture)), maps:get(source_ref, Fixture)),
    {ok, RecordBlob} = quod_atomic:encode_record(Record),
    Request = {submit, <<213:128>>, RecordBlob},
    Peer = <<0:256>>,
    ?assertNotEqual(Peer, Self),
    Validators = lists:sort([Peer, Self]),
    Parent = self(),
    FirstLink = spawn(fun() -> receive_ordered_relay(Parent, first_link) end),
    InboundLink = spawn(fun() -> receive stop -> ok end end),
    From = {self(), make_ref()},
    Dir = relay_store_dir("dtx_reliable_placement"),
    {ok, Journal} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Self, id => Signer,
                  validators => Validators,
                  author_admissions => #{Self => Admission},
                  sync => ready, prolog_ready => true,
                  slot => 1, last_applied => 1,
                  history_head => {1, Anchor},
                  store => memory, signing_journal => Journal,
                  conns => #{Peer => {FirstLink, make_ref()}},
                  inbound_conns =>
                      #{Peer => {InboundLink, make_ref()}},
                  peer_readiness =>
                      voting_readiness([Peer], InboundLink, 1)}),
        {keep_state, Retained, _Actions0} =
            quod_simplex:running(
              {call, From},
              {dtx_endpoint_local, Request, [], 1000, otel_ctx:new()}, S0),
        receive dtx_drive -> ok
        after 0 -> error(missing_dtx_mailbox_wake)
        end,
        {keep_state, Placed, _Actions1} =
            quod_simplex:running(info, dtx_drive, Retained),
        FirstFrame =
            receive {first_link, Frame} -> Frame
            after 1000 -> error(missing_ordered_dtx_relay)
            end,
        [#{relay_placement := {Peer, LinkPid}}] =
            maps:values(
              maps:get(rows,
                       quod_simplex:test_retained_dtx_state(Placed))),
        ?assertEqual(FirstLink, LinkPid),
        {keep_state, Unchanged, _Actions2} =
            quod_simplex:test_keep_progress_transition(Placed, Placed),
        receive
            {send_ordered, _DuplicateFrame} ->
                error(duplicate_ordered_dtx_relay)
        after 0 ->
            ok
        end,
        NewLink = spawn(fun() -> receive_ordered_relay(Parent, new_link) end),
        Reconnected = quod_simplex:test_state_set(
                        conns, #{Peer => {NewLink, make_ref()}}, Unchanged),
        {keep_state, Replaced, _Actions3} =
            quod_simplex:test_keep_progress_transition(
              Reconnected, Reconnected),
        receive
            {new_link, FirstFrame} -> ok
        after 1000 ->
            error(missing_reconnected_dtx_relay)
        end,
        [#{relay_placement := {Peer, NewLink}}] =
            maps:values(
              maps:get(rows,
                       quod_simplex:test_retained_dtx_state(Replaced)))
    after
        InboundLink ! stop,
        _ = catch quod_signing_journal:close(Journal),
        _ = file:del_dir_r(Dir)
    end.

%% A live node-level QUIC link is not proof that the target ontology process
%% exists.  Retained custody therefore stays unplaced until the elected leader
%% announces readiness on its exact authenticated consensus generation.  That
%% incoming message is the wake: the same keep_progress turn sends once, with
%% no timer, poll, acknowledgement protocol, or duplicate relay owner.
dtx_relay_waits_for_elected_ontology_readiness_test() ->
    Fixture = quod_ct:atomic_role_fixture(),
    {Ns, Anchor} = maps:get(target, Fixture),
    #{pubkey := Self} = Signer = maps:get(signer, Fixture),
    Admission = maps:get(admission, Fixture),
    Record = quod_ct:atomic_abort_record(maps:get(target, Fixture),
                  quod_atomic:group_id(maps:get(group, Fixture)), maps:get(source_ref, Fixture)),
    {ok, RecordBlob} = quod_atomic:encode_record(Record),
    Request = {submit, <<214:128>>, RecordBlob},
    Peer = <<0:256>>,
    ?assertNotEqual(Peer, Self),
    Validators = lists:sort([Peer, Self]),
    Parent = self(),
    OutLink = spawn(fun() -> receive_ordered_relay(Parent, ready_link) end),
    InLink = spawn(fun() -> receive stop -> ok end end),
    From = {self(), make_ref()},
    Dir = relay_store_dir("dtx_readiness_placement"),
    {ok, Journal} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Self, id => Signer,
                  validators => Validators,
                  author_admissions => #{Self => Admission},
                  sync => ready, prolog_ready => true,
                  slot => 1, last_applied => 1,
                  history_head => {1, Anchor},
                  store => memory, signing_journal => Journal,
                  conns => #{Peer => {OutLink, make_ref()}},
                  inbound_conns => #{Peer => {InLink, make_ref()}}}),
        {keep_state, Retained, _} =
            quod_simplex:running(
              {call, From},
              {dtx_endpoint_local, Request, [], 1000, otel_ctx:new()}, S0),
        receive dtx_drive -> ok
        after 0 -> error(missing_dtx_mailbox_wake)
        end,
        {keep_state, Parked, _} =
            quod_simplex:running(info, dtx_drive, Retained),
        [#{relay_placement := none}] =
            maps:values(
              maps:get(rows,
                       quod_simplex:test_retained_dtx_state(Parked))),
        receive
            {ready_link, _Premature} -> error(relay_sent_before_readiness)
        after 0 -> ok
        end,

        NotReady =
            quod_simplex:test_state_set(
              peer_readiness,
              #{Peer => {InLink, 1, {?FIXTURE_ERA, 1, 0}, false, quod_time:mono_ms()}},
              Parked),
        {keep_state, StillParked, _} =
            quod_simplex:test_keep_progress_transition(
              Parked, NotReady),
        [#{relay_placement := none}] =
            maps:values(
              maps:get(rows,
                       quod_simplex:test_retained_dtx_state(
                         StillParked))),
        receive
            {ready_link, _NotReadyFrame} ->
                error(relay_sent_for_negative_readiness)
        after 0 -> ok
        end,

        Ready =
            quod_simplex:test_state_set(
              peer_readiness,
              voting_readiness([Peer], InLink, 1),
              StillParked),
        {keep_state, Placed, _} =
            quod_simplex:test_keep_progress_transition(
              StillParked, Ready),
        ?assertEqual(
           {relay, Peer},
           quod_simplex:test_dtx_slot_route(1, Placed)),
        receive {ready_link, _Frame} -> ok
        after 1000 -> error(readiness_did_not_wake_relay)
        end,
        [#{relay_placement := {Peer, OutLink}}] =
            maps:values(
              maps:get(rows,
                       quod_simplex:test_retained_dtx_state(Placed)))
    after
        InLink ! stop,
        _ = catch quod_signing_journal:close(Journal),
        _ = file:del_dir_r(Dir)
    end.

receive_ordered_relay(Parent, Tag) ->
    receive
        {send_ordered, Frame} ->
            {sx3, Ns, _} = binary_to_term(Frame),
            case quod_relay:decode_consensus_frame(Frame, Ns) of
                {consensus, {dtx_submit, _, _}} -> Parent ! {Tag, Frame};
                _ -> receive_ordered_relay(Parent, Tag)
            end;
        _OtherLinkTraffic -> receive_ordered_relay(Parent, Tag)
    end.

%% A relayed control that reaches the current leader while an ordinary batch
%% is open used to be discarded by handle_dtx_submit/4. It now enters the one
%% retained DTX owner and shares the same mailbox wake as a local endpoint
%% submit; no retry tick or second relay queue is needed.
dtx_relay_received_while_leader_busy_is_retained_test() ->
    Fixture = quod_ct:atomic_role_fixture(),
    {Ns, Anchor} = maps:get(target, Fixture),
    #{pubkey := Author} = maps:get(signer, Fixture),
    {Self, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Self, key => quod_identity:key_term({Self, Seed})},
    Admission = maps:get(admission, Fixture),
    Control = maps:get(vote_control, Fixture),
    {ok, Envelope} = quod_atomic:encode_control(Control),
    Dir = relay_store_dir("dtx_relay_retention"),
    {ok, Journal} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        Busy = quod_simplex:test_state_set(
                 collecting, {1, []},
                 st(#{ns => Ns, genesis_hash => Anchor,
                      self => Self, id => Signer,
                      validators => lists:sort([Self, Author]),
                      author_admissions => #{Self => Admission, Author => Admission},
                      signing_journal => Journal,
                      sync => ready, prolog_ready => true})),
        Retained = quod_simplex:dispatch(
                     Author, {dtx_submit, [Envelope], []}, Busy),
        ?assertMatch(
           #{retained := 1, ready := 1, waiters := 0},
           quod_simplex:test_retained_dtx_state(Retained)),
        ?assert(quod_simplex:test_dtx_drive_scheduled(Retained)),
        receive dtx_drive -> ok
        after 0 -> error(missing_relay_dtx_mailbox_wake)
        end
    after
        ok = quod_signing_journal:close(Journal),
        _ = file:del_dir_r(Dir)
    end.

%% A Vote can be authored by a source voter other than the next slot's
%% leader. The leader must propose
%% the exact authenticated control it received: re-signing the semantic record
%% as the leader is invalid and used to discard every such relay silently.
dtx_origin_vote_relay_keeps_its_original_author_test() ->
    Fixture = quod_ct:signed_atomic_fixture(#{}),
    {Ns, Anchor} = maps:get(origin, Fixture),
    #{pubkey := Source} = maps:get(node_identity, Fixture),
    SourceAdmission = maps:get(admission, Fixture),
    Control = maps:get(vote_control, Fixture),
    {ok, Envelope} = quod_atomic:encode_control(Control),
    {Leader, LeaderSeed} = quod_identity:generate(),
    LeaderIdentity =
        #{pubkey => Leader,
          key => quod_identity:key_term({Leader, LeaderSeed})},
    LeaderAdmission = <<206:256>>,
    Busy = quod_simplex:test_state_set(
             collecting, {1, []},
             st(#{ns => Ns, genesis_hash => Anchor,
                  self => Leader, id => LeaderIdentity,
                  validators => [Source, Leader],
                  author_admissions =>
                      #{Source => SourceAdmission,
                        Leader => LeaderAdmission},
                  sync => ready, prolog_ready => true})),
    Retained = quod_simplex:dispatch(
                 Source, {dtx_submit, [Envelope], []}, Busy),
    #{retained := 1, ready := 1, rows := Rows} =
        quod_simplex:test_retained_dtx_state(Retained),
    [#{envelope := Envelope}] = maps:values(Rows),
    %% Reconciliation keeps a still-current foreign-authored control rather
    %% than either re-signing or retiring it.
    Refreshed = quod_simplex:test_refresh_retained_dtx_signatures(Retained),
    #{retained := 1, rows := RefreshedRows} =
        quod_simplex:test_retained_dtx_state(Refreshed),
    [#{envelope := Envelope}] = maps:values(RefreshedRows),
    %% Removing the original author's admission retires that transient row;
    %% exact-byte retention is never a way around the current committee view.
    Revoked = quod_simplex:test_set_author_admissions(
                #{Leader => LeaderAdmission}, Refreshed),
    ?assertMatch(
       #{retained := 0},
       quod_simplex:test_retained_dtx_state(
         quod_simplex:test_refresh_retained_dtx_signatures(Revoked))),
    receive dtx_drive -> ok
    after 0 -> error(missing_origin_vote_relay_wake)
    end.

dtx_semantic_commit_retires_an_equivalent_retained_envelope_test() ->
    Fixture = quod_ct:atomic_role_fixture(),
    Original = maps:get(source_control, Fixture),
    Origin = {Ns, Anchor} = maps:get(origin, Fixture),
    {ok, Committed} =
        quod_atomic:sign_control(
          Origin, quod_atomic:control_material(Original), maps:get(admission, Fixture), 2, 2,
          maps:get(signer, Fixture)),
    {Entry, Payload} = committed_dtx_test_entry(Committed, 2),
    Seeded = quod_simplex:test_seed_dtx_submission(
               Original, [], st(#{ns => Ns, genesis_hash => Anchor})),
    Resolved = quod_simplex:test_resolve_committed_dtx(
                 Entry, Payload, Seeded),
    ?assertEqual(
       0, maps:get(submissions,
                   quod_simplex:test_dtx_endpoint_counts(Resolved))).

%% The retained-control gauges expose the exact consensus owner rather than a
%% second accounting store.  A normal keep_progress pass remembers the peak;
%% the canonical committed-control reducer then removes the row while that
%% owner-lifetime peak and its byte high-water mark remain observable.
dtx_owner_stats_keep_peak_after_committed_cleanup_test() ->
    Fixture = quod_ct:atomic_role_fixture(),
    Control = maps:get(vote_control, Fixture),
    {Ns, Anchor} = maps:get(target, Fixture),
    Seeded = quod_simplex:test_seed_dtx_submission(
               Control, [],
               st(#{ns => Ns, genesis_hash => Anchor})),
    SeededStats = quod_simplex:stats_map(Seeded),
    ?assertEqual(
       #{retained => 1, ready => 1, blocked => 0, waiters => 0},
       maps:get(dtx_control, maps:get(owner_current, SeededStats))),
    RetainedBytes = maps:get(
                      dtx_control,
                      maps:get(owner_bytes_current, SeededStats)),
    ?assert(RetainedBytes > 0),

    {keep_state, Tracked, _Actions} =
        quod_simplex:test_keep_progress_transition(Seeded, Seeded),
    TrackedStats = quod_simplex:stats_map(Tracked),
    ?assertEqual(
       #{retained => 1, ready => 1, blocked => 0, waiters => 0},
       maps:get(dtx_control, maps:get(owner_peak, TrackedStats))),
    ?assertEqual(
       RetainedBytes,
       maps:get(dtx_control, maps:get(owner_bytes_peak, TrackedStats))),

    {Entry, Payload} = committed_dtx_test_entry(Control, 2),
    Cleared = quod_simplex:test_resolve_committed_dtx(
                Entry, Payload, Tracked),
    ClearedStats = quod_simplex:stats_map(Cleared),
    ?assertEqual(
       #{retained => 0, ready => 0, blocked => 0, waiters => 0},
       maps:get(dtx_control, maps:get(owner_current, ClearedStats))),
    ?assertEqual(
       #{retained => 1, ready => 1, blocked => 0, waiters => 0},
       maps:get(dtx_control, maps:get(owner_peak, ClearedStats))),
    ?assertEqual(
       0, maps:get(dtx_control,
                   maps:get(owner_bytes_current, ClearedStats))),
    ?assertEqual(
       RetainedBytes,
       maps:get(dtx_control,
                maps:get(owner_bytes_peak, ClearedStats))).

dtx_catchup_retires_retained_submission_and_replies_exact_ref_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = unique_gate_namespace(<<"catchup-dtx-submission">>),
    F = #{identity := Origin = {Ns, Anchor}, signer := Signer,
          admission := Admission, era := Era} = quod_ct:protocol_fixture(Ns),
    Fixture = quod_ct:signed_atomic_fixture(
        #{target => Origin, node_identity => Signer, admission => Admission}),
    Vote = maps:get(vote, Fixture),
    Original = maps:get(vote_control, Fixture),
    {ok, Committed} = quod_atomic:sign_control(
        Origin, quod_atomic:control_material(Original), Admission, 1, 2, Signer),
    {ok, OriginalEnvelope} = quod_atomic:encode_control(Original),
    {ok, Envelope} = quod_atomic:encode_control(Committed),
    ?assertNotEqual(OriginalEnvelope, Envelope),
    Root = {Era, 0, Anchor},
    Block = block({Era, 1}, Root, 2, {batch, [{dtx, Committed}]}, 2),
    BlockHash = quod_simplex:block_hash(Block),
    Entry = quod_ledger:entry(2, Block, quod_ct:protocol_certificate(Block, F)),
    Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
    Dir = relay_store_dir("catchup_dtx_submission"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store1} = quod_ct:append_direct_history(Store0, [Genesis]),
    {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
    try
        {ok, Projection, _} = quod_ct:history_advance(
            Origin, Genesis, quod_simplex:history_projection(Origin), Index),
        quod_ct:with_network_identity(maps:get(network, Fixture), fun() ->
            {ok, Group} = quod_ct:history_group(Origin, Entry, Projection, Index),
            Owner = quod_simplex:test_install_projection(Projection,
                st(#{ns => Ns, genesis_hash => Anchor, store => Store1,
                     consensus_domain => quod_simplex:consensus_domain(Ns, Anchor),
                     slot => 1, last_applied => 1, archive_tip => {Root, 0},
                     phase_index => Index, sync => {pulling, self()}})),
            Seeded = quod_simplex:test_seed_dtx_submission(
                       Original, [{dtx_endpoint, self()}], Owner),
            {Recovered, ok} = quod_simplex:test_apply_catchup_window(
                                {recovery, self()}, Group, Seeded),
            receive
                {dtx_submit_result, {ok, Ref, [{Ref, Entry}]}} ->
                    ?assert(quod_dtx:validate_certified_ref(Ref)),
                    {quod_dtx_ref, 3, Ns, Anchor, 2, BlockHash, Digest, _} = Ref,
                    ?assertEqual(quod_atomic:record_digest(Vote), Digest)
            after 0 -> error(missing_committed_dtx_reply)
            end,
            ?assertEqual(0, maps:get(submissions,
                           quod_simplex:test_dtx_endpoint_counts(Recovered))),
            {2, DurableStore} = quod_simplex:test_committed_store(Recovered),
            ?assertEqual({ok, Entry}, quod_ledger_store:read_at(DurableStore, 2))
        end)
    after
        quod_dtx_phase_index:close(Index),
        quod_ledger_store:close(Store0),
        file:del_dir_r(Dir)
    end.


unsigned_vote_history_replay_does_not_require_root_identity_test() ->
    SavedDesired = application:get_env(quod, namespace_desired),
    application:unset_env(quod, namespace_desired),
    Fixture = quod_ct:atomic_role_fixture(),
    Origin = {Ns, Anchor} = maps:get(origin, Fixture),
    Signer = maps:get(signer, Fixture),
    Pub = maps:get(pubkey, Signer),
    Admission = maps:get(admission, Fixture),
    Control = maps:get(source_control, Fixture),
    Data = {batch, [{dtx, Control}]},
    Era = quod_ledger:initial_era(Origin),
    Root = {Era, 0, Anchor},
    Block = block({Era, 1}, Root, 2, Data, 0),
    Cert = quod_ct:protocol_certificate(Block, #{identity => Origin, signer => Signer}),
    Entry = quod_ledger:entry(2, Block, Cert),
    Projection0 =
        (quod_simplex:history_projection(
           [Pub], <<1:256>>, #{Pub => Admission}, #{}, 0))#{
          identity := Origin, history_head := {1, Anchor}, protocol_root := Root,
          dtx := quod_atomic:initial_projection(Origin, 0)},
    Dir = relay_store_dir("unsigned_vote_history"),
    {ok, PhaseIndex} = quod_dtx_phase_index:open(Dir, Ns),
    try
        ?assertMatch({error, _}, quod_ontology:network_identity()),
        ?assertMatch(
           {ok, _Projection1, _Effects},
           quod_ct:history_advance(
             Origin, Entry, Projection0, PhaseIndex))
    after
        ok = quod_dtx_phase_index:close(PhaseIndex),
        _ = file:del_dir_r(Dir),
        case SavedDesired of
            {ok, Desired} ->
                application:set_env(quod, namespace_desired, Desired);
            undefined ->
                application:unset_env(quod, namespace_desired)
        end
    end.

signed_content_history_replay_waits_for_root_identity_test() ->
    Fixture = quod_ct:signed_atomic_fixture(#{}),
    Target = {_Ns, Anchor} = maps:get(target, Fixture),
    Era = quod_ledger:initial_era(Target),
    Root = {Era, 0, Anchor},
    Network = maps:get(network, Fixture),
    Transaction = maps:get(transaction, Fixture),
    #{pubkey := Author} = maps:get(node_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    Deadline = maps:get(deadline, Fixture),
    Projection0 = (quod_simplex:history_projection(
                    [Author], undefined, #{Author => Admission}, #{}, 0))#{
                      identity := Target, history_head := {1, Anchor}, protocol_root := Root,
                      dtx := quod_atomic:initial_projection(Target, 0)},
    Entry = material_entry(2, {Era, 1}, Root, {batch, [Transaction]}, Deadline),
    without_network_identity(
      fun() ->
          ?assertEqual(
             {error, {unavailable, network_identity, not_hosted}},
             quod_simplex:history_validate_advance(
               Target, Entry, Projection0))
      end),
    quod_ct:with_network_identity(
      Network,
      fun() ->
          ?assertMatch(
             {ok, _Projection1},
             quod_simplex:history_validate_advance(
               Target, Entry, Projection0))
      end).

signed_vote_history_replay_waits_for_root_identity_test() ->
    Fixture = quod_ct:signed_atomic_fixture(#{}),
    Target = {Ns, Anchor} = maps:get(target, Fixture),
    Network = maps:get(network, Fixture),
    Control = maps:get(vote_control, Fixture),
    #{pubkey := Author} = Identity = maps:get(node_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    Data = {batch, [{dtx, Control}]},
    Era = quod_ledger:initial_era(Target),
    Root = {Era, 0, Anchor},
    Block = block({Era, 1}, Root, 2, Data, 1),
    Cert = quod_ct:protocol_certificate(Block, #{identity => Target, signer => Identity}),
    Entry = quod_ledger:entry(2, Block, Cert),
    Projection0 =
        (quod_simplex:history_projection(
           [Author], <<1:256>>, #{Author => Admission}, #{}, 0))#{
          identity := Target, history_head := {1, Anchor}, protocol_root := Root,
          dtx := quod_atomic:initial_projection(Target, 0)},
    Dir = relay_store_dir("signed_vote_history_identity"),
    {ok, PhaseIndex} = quod_dtx_phase_index:open(Dir, Ns),
    try
        without_network_identity(
          fun() ->
              ?assertEqual(
                 {error, {unavailable, network_identity, not_hosted}},
                 quod_ct:history_advance(
                   Target, Entry, Projection0, PhaseIndex))
          end),
        quod_ct:with_network_identity(
          Network,
          fun() ->
              ?assertMatch(
                 {ok, _Projection1, _Effects},
                 quod_ct:history_advance(
                   Target, Entry, Projection0, PhaseIndex))
          end)
    after
        ok = quod_dtx_phase_index:close(PhaseIndex),
        _ = file:del_dir_r(Dir)
    end.

dtx_retained_selection_skips_an_older_ineligible_group_test() ->
    [Older, Active] = lists:sort(fun(A, B) ->
        quod_atomic:group_id(maps:get(group, A)) < quod_atomic:group_id(maps:get(group, B))
    end, [quod_ct:atomic_role_fixture(), quod_ct:atomic_role_fixture()]),
    Origin = {Ns, Anchor} = maps:get(origin, Active),
    Vote = maps:get(source_control, Active), Ref = maps:get(source_ref, Active),
    {ok, _, Locked, _} = quod_atomic:reduce(Vote, Ref,
        quod_atomic:initial_group_history(), quod_atomic:initial_projection(Origin, 0)),
    Resolve = source_resolve(Active, Ref),
    {ok, M} = quod_atomic:admission_material(Resolve),
    {ok, C} = quod_atomic:sign_control(Origin, M, maps:get(admission, Active), 2, 0,
                                      maps:get(signer, Active)),
    S0 = st(#{ns => Ns, genesis_hash => Anchor, slot => 1, history_head => {1, Anchor}, dtx_projection => Locked}),
    WithOlder = quod_simplex:test_seed_dtx_submission_at(maps:get(source_control, Older), [], 10, S0),
    ?assertMatch(#{retained := 1, ready := 0, blocked := 1},
                 quod_simplex:test_retained_dtx_state(WithOlder)),
    WithBoth = quod_simplex:test_seed_dtx_submission_at(C, [], 20, WithOlder),
    ?assertEqual([{quod_atomic:record_digest(Resolve), Resolve}],
                 quod_simplex:test_eligible_dtx_wave(WithBoth)),
    ?assertEqual(2, maps:get(submissions, quod_simplex:test_dtx_endpoint_counts(WithBoth))).

%% Alternate quorum proof bytes are one transition, not two batch entries.
%% References are structural fixtures; evidence verification is tested separately.
dtx_retained_wave_selects_one_reference_variant_per_group_test() ->
    F = quod_ct:atomic_role_fixture(), Origin = {Ns, Anchor} = maps:get(origin, F),
    Ref = maps:get(source_ref, F),
    {ok, _, P, _} = quod_atomic:reduce(maps:get(source_control, F), Ref,
        quod_atomic:initial_group_history(), quod_atomic:initial_projection(Origin, 0)),
    [R1, R2] = [source_resolve(F, R) || R <- [Ref, setelement(8, Ref, quod_ct:fixture_finality(3, <<222:256>>))]],
    Controls = [begin
        {ok, M} = quod_atomic:admission_material(R),
        {ok, C} = quod_atomic:sign_control(Origin, M, maps:get(admission, F), N, 0, maps:get(signer, F)), C
    end || {R, N} <- [{R1, 2}, {R2, 3}]],
    S = lists:foldl(fun(C, Acc) -> quod_simplex:test_seed_dtx_submission(C, [], Acc) end,
                    st(#{ns => Ns, genesis_hash => Anchor, slot => 1, history_head => {1, Anchor}, dtx_projection => P}), Controls),
    ?assertNotEqual(quod_atomic:record_digest(R1), quod_atomic:record_digest(R2)),
    ?assertEqual([{quod_atomic:record_digest(R1), R1}], quod_simplex:test_eligible_dtx_wave(S)).

source_resolve(F, OriginRef) ->
    Origin = maps:get(origin, F), Target = maps:get(target, F),
    TargetRef = dtx_test_ref(Target, 2, quod_atomic:record_digest(maps:get(vote, F))),
    {ok, R} = quod_atomic:new_resolve(maps:get(group, F), OriginRef, Origin, commit,
        {all_prepared, lists:sort([{Origin, OriginRef}, {Target, TargetRef}])}, OriginRef, 2), R.

%% Retention is governed by phase readiness, not by a compiled row count. The
%% old nine-row guard would reject this exact tenth insertion with `busy`.
dtx_retained_registry_has_no_population_cap_test() ->
    {Self, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Self,
               key => quod_identity:key_term({Self, Seed})},
    Origin = {Ns, Anchor} = {<<"quod:dtx-unlimited">>, <<151:256>>},
    Admission = <<152:256>>,
    Fixtures =
        [quod_ct:signed_atomic_fixture(
           #{target => Origin, node_identity => Signer,
             admission => Admission, proof_id => <<(153 + I):256>>})
         || I <- lists:seq(0, 12)],
    [Active | FutureFixtures] =
        lists:reverse(
          lists:sort(
            fun(A, B) ->
                    quod_atomic:group_id(maps:get(vote, A)) <
                        quod_atomic:group_id(maps:get(vote, B))
            end, Fixtures)),
    Vote = maps:get(vote, Active),
    VoteRef = dtx_test_ref(Origin, 2, quod_atomic:record_digest(Vote)),
    H0 = quod_atomic:initial_group_history(),
    P0 = quod_atomic:initial_projection(Origin, 0),
    {ok, _H1, P1, _} = quod_atomic:reduce(
                         maps:get(vote_control, Active), VoteRef, H0, P0),
    Locked = P1,
    FutureRows =
        [begin
             FutureVote = maps:get(vote, Future),
             FutureVoteRef = dtx_test_ref(
                                Origin, I + 10,
                                quod_atomic:record_digest(FutureVote)),
             {I, maps:get(vote_control, Future), FutureVote,
              FutureVoteRef}
         end || {I, Future} <- lists:zip(
                                  lists:seq(1, 12), FutureFixtures)],
    Dir = relay_store_dir("dtx_unlimited_retention"),
    {ok, Journal0} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Self, id => Signer, validators => [Self],
                  sync => ready, slot => 1, history_head => {1, Anchor},
                  author_admissions => #{Self => Admission},
                  signing_journal => Journal0,
                  dtx_projection => Locked}),
        Retained = lists:foldl(
                     fun({I, _VoteControl, FutureVote, _VoteRef}, S) ->
                             case quod_simplex:test_retain_dtx_record(
                                    FutureVote, none, S) of
                                 {ok, S1} -> S1;
                                 {error, Reason} -> error({retain_failed, I, Reason})
                             end
                     end, S0, FutureRows),
        ?assertMatch(
           #{retained := 12, ready := 0, blocked := 12,
             waiters := 0, bytes := Bytes} when Bytes > 0,
           quod_simplex:test_retained_dtx_state(Retained)),
        %% Retained selection uses the signed control's canonical lane,
        %% sequence, group and target order. Local arrival time cannot make
        %% validators choose different controls. Once one Vote applies, the
        %% others block behind it; clearing it restores the canonical order.
        SeededVotes = lists:foldl(
                         fun({I, VoteControl, _Vote, _VoteRef}, S) ->
                                 quod_simplex:test_seed_dtx_submission_at(
                                   VoteControl, [], I, S)
                         end,
                         quod_simplex:test_state_set(
                           retained_dtx, empty, S0),
                         FutureRows),
        OrderedFutureRows =
            [Row || {_Order, Row} <-
                        lists:sort(
                          [{quod_atomic:control_order_key(VoteControl), Row}
                           || Row = {_I, VoteControl, _Vote, _VoteRef}
                                  <- FutureRows])],
        Open = quod_simplex:test_refresh_retained_readiness(
                 quod_simplex:test_state_set(
                   dtx_projection, P0, SeededVotes)),
        [{_I, FirstControl, FirstVote, FirstRef} | _] = OrderedFutureRows,
        FirstDigest = quod_atomic:record_digest(FirstVote),
        ?assertEqual(
           [{FirstDigest, FirstVote}],
           quod_simplex:test_eligible_dtx_wave(Open)),
        {ok, _History, ActiveProjection, _Effects} =
            quod_atomic:reduce(
              FirstControl, FirstRef, quod_atomic:initial_group_history(), P0),
        %% These are competing plans of the same signed request. The winning
        %% Vote removes its own retained row; other plans must wait, never
        %% manufacture refusals that could abort that request on both forks.
        AfterFirst = quod_simplex:test_refresh_retained_readiness(
                       quod_simplex:test_state_set(
                         dtx_projection, ActiveProjection, Open)),
        ?assertMatch(
           #{retained := 11, ready := 0, blocked := 11},
           quod_simplex:test_retained_dtx_state(AfterFirst))
    after
        _ = catch quod_signing_journal:close(Journal0),
        _ = file:del_dir_r(Dir)
    end.

%% Re-signing replaces one row through the same registry mutation path: its
%% scheduling age and exact envelope bytes change, while its observation age
%% and semantic digest remain stable.
dtx_retained_resign_updates_exact_bytes_and_preserves_observation_test() ->
    Fixture = quod_ct:atomic_role_fixture(),
    Target = {Ns, Anchor} = maps:get(target, Fixture),
    Signer = #{pubkey := Self} = maps:get(signer, Fixture),
    Admission = maps:get(admission, Fixture),
    Record = maps:get(vote, Fixture),
    Control = maps:get(vote_control, Fixture),
    Digest = quod_atomic:record_digest(Record),
    Meta = quod_atomic:control_metadata(Control),
    Lane = {maps:get(author_admission, Meta), maps:get(author, Meta)},
    Dir = relay_store_dir("dtx_resign_accounting"),
    {ok, Journal0} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Self, id => Signer, validators => [Self],
                  sync => ready, prolog_ready => true,
                  author_admissions => #{Self => Admission},
                  signing_journal => Journal0,
                  dtx_projection => quod_atomic:initial_projection(Target, 0),
                  dtx_lanes => #{Lane => maps:get(sequence, Meta)}}),
        Seeded = quod_simplex:test_seed_dtx_submission_at(
                   Control, [], 10, S0),
        Before = quod_simplex:test_retained_dtx_state(Seeded),
        BeforeRow = maps:get(Digest, maps:get(rows, Before)),
        Renewed = quod_simplex:test_refresh_retained_dtx_signatures(Seeded),
        After = quod_simplex:test_retained_dtx_state(Renewed),
        AfterRow = maps:get(Digest, maps:get(rows, After)),
        ?assertEqual(10, maps:get(observation_started_at, AfterRow)),
        ?assertNotEqual(10, maps:get(inserted_at, AfterRow)),
        ?assertNotEqual(maps:get(envelope, BeforeRow),
                        maps:get(envelope, AfterRow)),
        ?assertEqual(
           maps:get(bytes, Before) - maps:get(bytes, BeforeRow)
             + maps:get(bytes, AfterRow),
           maps:get(bytes, After)),
        ?assertEqual(1, maps:get(ready, After)),
        ?assertEqual(0, maps:get(blocked, After))
    after
        _ = catch quod_signing_journal:close(Journal0),
        _ = file:del_dir_r(Dir)
    end.

%% Journal and committed projection carry authenticated own material directly.
%% There is no bootstrap reader. Two groups own separate workers; publishing a
%% Vote preserves the worker, and only its exact DOWN starts a new incarnation.
source_coordinators_adopt_votes_and_restart_from_durable_own_material_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    [F, Other] = [quod_ct:atomic_role_fixture() || _ <- [1, 2]],
    Origin = {Ns, Anchor} = maps:get(origin, F),
    C = maps:get(source_control, F), C2 = maps:get(source_control, Other),
    Id = quod_atomic:group_id(C), Id2 = quod_atomic:group_id(C2),
    #{pubkey := Pub} = maps:get(signer, F), Admission = maps:get(admission, F),
    Dir = relay_store_dir("own_vote_coordinators"),
    {ok, J0} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    {ok, J1, _} = quod_signing_journal:record_dtx(J0, C),
    {ok, J, _} = quod_signing_journal:record_dtx(J1, C2),
    S = st(#{ns => Ns, genesis_hash => Anchor, self => Pub,
             validators => [Pub], author_admissions => #{Pub => Admission},
             signing_journal => J, sync => ready, prolog_ready => true}),
    Running = quod_simplex:test_reconcile_dtx_coordinator(S),
    try
        Owners = quod_simplex:test_dtx_coordinator_state(Running),
        ?assertEqual(lists:sort([Id, Id2]), lists:sort(maps:keys(Owners))),
        #{pid := Pid, monitor := Monitor} = maps:get(Id, Owners),
        #{pid := OtherPid} = maps:get(Id2, Owners),
        ?assertNotEqual(Pid, OtherPid),
        ?assertEqual(Owners, quod_simplex:test_dtx_coordinator_state(
                               quod_simplex:test_reconcile_dtx_coordinator(Running))),
        {Entry, Payload, Ref} = certified_dtx_test_entry(Origin, C, 2),
        Seeded = quod_simplex:test_seed_dtx_submission(C, [], Running),
        Resolved = quod_simplex:test_resolve_committed_dtx(Entry, Payload, Seeded),
        {ok, _, P, _} = quod_atomic:reduce(C, Ref,
            quod_atomic:initial_group_history(), quod_atomic:initial_projection(Origin, 0)),
        Adopted = quod_simplex:test_reconcile_dtx_coordinator(
                    quod_simplex:test_state_set(dtx_projection, P, Resolved)),
        ?assertEqual(Owners, quod_simplex:test_dtx_coordinator_state(Adopted)),
        ?assertEqual(0, maps:get(submissions, quod_simplex:test_dtx_endpoint_counts(Adopted))),
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, killed} -> ok
        after 1000 -> error(missing_coordinator_down) end,
        {true, Restarted} = quod_simplex:test_drop_dtx_coordinator(Monitor, Pid, killed, Adopted),
        try
            #{pid := NewPid} = maps:get(Id, quod_simplex:test_dtx_coordinator_state(Restarted)),
            ?assertNotEqual(Pid, NewPid),
            ?assert(is_process_alive(NewPid)),
            ?assertEqual(OtherPid, maps:get(pid, maps:get(Id2,
                                   quod_simplex:test_dtx_coordinator_state(Restarted))))
        after _ = quod_simplex:test_stop_dtx_coordinator(Restarted) end
    after
        _ = quod_simplex:test_stop_dtx_coordinator(Running),
        ok = quod_signing_journal:close(J),
        ok = file:del_dir_r(Dir)
    end.

%% A coordinator waiting on its own ontology must be woken by that owning
%% Simplex, not by replaying the same ledger through foreign_log. The wake is
%% only a scheduling edge; the coordinator verifies the local snapshot again.
dtx_source_commit_wakes_owned_coordinator_directly_test() ->
    Ns = <<"quod:dtx-local-progress">>,
    Anchor = crypto:hash(sha256, <<226>>),
    GroupId = crypto:hash(sha256, <<227>>),
    S0 = st(#{ns => Ns, genesis_hash => Anchor, slot => 5}),
    Owned = quod_simplex:test_seed_running_dtx_coordinator(
              GroupId, self(), S0),
    %% Installing a coordinator establishes the stream with the owner's
    %% current view, closing the race where its initial drive parks before the
    %% parent has recorded the child and no later commit edge occurs.
    ok = quod_simplex:test_activate_dtx_coordinator(self(), Owned),
    Owner = self(),
    receive
        {local_dtx_progress, Owner, {Ns, Anchor}, 5, false} -> ok
    after 1000 ->
        error(local_dtx_progress_not_established)
    end,
    ok = quod_simplex:test_notify_dtx_coordinator_progress(Owned, Owned),
    receive
        {local_dtx_progress, _, _, _, _} = Unexpected ->
            error({unexpected_local_progress, Unexpected})
    after 0 ->
        ok
    end,
    Advanced = quod_simplex:test_state_set(slot, 6, Owned),
    ok = quod_simplex:test_notify_dtx_coordinator_progress(Owned, Advanced),
    receive
        {local_dtx_progress, Owner, {Ns, Anchor}, 6, false} -> ok
    after 1000 ->
        error(local_dtx_progress_not_delivered)
    end.


%% The generic state builder has one dependency: `validators` supplies default
%% admission ids, but a test's explicit admission view is authoritative.  This
%% must not depend on maps:fold/3 traversal order (which differs as the VM atom
%% table and map representation change across the full suite).
test_state_explicit_admissions_override_validator_defaults_test() ->
    {Validator, _Identity} = id(),
    ExplicitAdmission = <<16#A5:256>>,
    ?assertNotEqual(
       quod_simplex:test_author_admission(Validator), ExplicitAdmission),
    State = st(#{validators => [Validator],
                 author_admissions => #{Validator => ExplicitAdmission}}),
    ?assertEqual(
       #{Validator => ExplicitAdmission},
       quod_simplex:test_author_admissions(State)).


%% A committed high-water under the same admission only invalidates the old
%% outer envelope. Reconciliation retains the semantic Vote and its waiter
%% while allocating one fresh sequence under that exact same lane.
pending_vote_same_admission_stale_sequence_reenvelopes_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Fixture = quod_ct:atomic_role_fixture(),
    Vote = maps:get(source_vote, Fixture),
    Control = maps:get(source_control, Fixture),
    Signer = maps:get(signer, Fixture),
    {Ns, Anchor} = maps:get(origin, Fixture),
    {ok, GroupRef = {group, Ns, Anchor, Coordinator, Admission, GroupId}} =
        quod_atomic:source_group_ref(quod_atomic:control_material(Control)),
    Meta = quod_atomic:control_metadata(Control),
    Sequence = maps:get(sequence, Meta),
    Lane = {Admission, Coordinator},
    Dir = relay_store_dir("pending_vote_reenvelope"),
    {ok, PhaseIndex} = quod_dtx_phase_index:open(Dir, Ns),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           Ns, ?DOMAIN, Dir),
        {ok, Journal1, OldEnvelope} =
            quod_signing_journal:record_dtx(Journal0, Control),
        Base = st(#{ns => Ns, genesis_hash => Anchor,
                    self => Coordinator, id => Signer,
                    validators => [Coordinator],
                    author_admissions => #{Coordinator => Admission},
                    sync => ready, prolog_ready => true, slot => 1,
                    signing_journal => Journal1, phase_index => PhaseIndex,
                    dtx_lanes => #{Lane => Sequence}}),
        Pending = quod_simplex:test_seed_dtx_submission(
                    Control, [{dtx_endpoint, self()}], Base),
        {Reconciled, Transition} =
            quod_simplex:test_reconcile_signing_state(Pending),
        ?assertEqual(none, Transition),
        #{lane := Lane, sequence := NewSequence,
          envelope := NewEnvelope} =
            maps:get(
              GroupId,
              quod_signing_journal:pending_dtx(
                quod_simplex:test_signing_journal(Reconciled))),
        ?assertEqual(Sequence + 1, NewSequence),
        ?assertNotEqual(OldEnvelope, NewEnvelope),
        {ok, NewControl} = quod_atomic:decode_control(NewEnvelope),
        ?assertEqual(Vote, quod_atomic:control_body(NewControl)),
        ?assertEqual(
           1, maps:get(submissions,
                       quod_simplex:test_dtx_endpoint_counts(Reconciled))),
        ?assertEqual(1, quod_simplex:test_dtx_submission_waiters(Reconciled)),
        receive
            {'$gen_cast',
             {project_pending_votes, [GroupRef]}} -> ok
        after 1000 ->
            error(reenveloped_vote_was_not_projected)
        end,
        receive
            {dtx_submit_result, _Unexpected} ->
                error(still_valid_waiter_was_replied)
        after 0 ->
            ok
        end,
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Reconciled))
    after
        ok = quod_dtx_phase_index:close(PhaseIndex),
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        file:del_dir_r(Dir)
    end.

%% Applied corroboration is bound to the exact committee that certified the
%% Resolve. A later committee change must not rewrite that historical claim.
dtx_endpoint_applied_uses_resolve_committee_test() ->
    Generation = 4,
    #{target := {Ns, Anchor} = Target, control := Control, entry := Entry,
      signer := #{pubkey := Author} = AuthorId, ref := ResolveRef,
      group_id := GroupId} = applied_role_fixture(Generation, 4),
    HistoricalCommitteeId = <<40:256>>,
    CurrentCommitteeId = <<41:256>>,
    Evidence = #{identity => Target, phase => resolve, control => Control, entry => Entry,
                 committee => [Author],
                 committee_id => HistoricalCommitteeId},
    Snapshot =
        #{applied_floor => 8, generation => 11, history => none,
          applied => #{resolve_ref => ResolveRef,
                       generation => Generation, verdict => commit}},
    S = st(#{ns => Ns, genesis_hash => Anchor, self => Author, id => AuthorId,
             validators => [Author], committee_id => CurrentCommitteeId,
             slot => 8, sync => ready, prolog_ready => true, store => memory,
             dtx_projection => quod_atomic:initial_projection(Target, 11)}),
    RequestId = <<42:128>>,
    Request = {applied, RequestId, GroupId, ResolveRef,
               Generation, commit},
    NetworkIdentity = <<43:256>>,
    with_network_identity(
      NetworkIdentity,
      fun() ->
          {ok, {Author, Signature}} =
              quod_applied_certificate:sign_applied_vote(
                NetworkIdentity, Target, HistoricalCommitteeId, GroupId,
                ResolveRef, Generation, commit, AuthorId),
          ?assertEqual(
             {applied, RequestId, Target, HistoricalCommitteeId, GroupId,
              ResolveRef, Generation, commit, Author, Signature},
             quod_simplex:test_dtx_endpoint_result(
               Request, {applied_state, Evidence, Snapshot}, S))
      end).

read_attest_observer_returns_typed_unavailable_without_signing_test() ->
    Fixture = quod_ct:signed_atomic_fixture(
                #{goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    {Ns, Anchor} = quod_dtx:target(Plan),
    {Self, Identity} = id(),
    {Validator, _ValidatorIdentity} = id(),
    Applied = 8,
    State = st(#{ns => Ns, genesis_hash => Anchor,
                 self => Self, id => Identity,
                 validators => [Validator], slot => Applied,
                 last_applied => Applied, sync => ready,
                 prolog_ready => true, store => memory}),
    RequestId = <<58:128>>,
    ?assertEqual(
       {error, RequestId, read_certificate_unavailable},
       quod_simplex:test_dtx_endpoint_result(
         {read_attest, RequestId, PlanBlob},
         {read_plan_valid, Plan, Applied}, State)).

history_view_role_and_readiness_are_checked_by_the_consensus_owner_test() ->
    Ns = <<"quod:history-role">>,
    #{anchor := Anchor, chain := Chain} =
        quod_foreign_log_tests:long_identity_fixture(Ns, 9),
    Self = crypto:hash(sha256, <<1502:64>>),
    Dir = relay_store_dir("history_role"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store} = quod_ct:append_direct_history(Store0, lists:sublist(Chain, 8)),
    try
        Identity = {Ns, Anchor},
        Base = st(#{ns => Ns, self => Self, genesis_hash => Anchor,
                    store => Store, slot => 8, last_applied => 7,
                    sync => ready, prolog_ready => true, validators => []}),
        ?assertMatch(
           {ok, #{identity := Identity, slot := 8, applied := 7}},
           quod_simplex:test_local_history_view(Identity, any, Base)),
        ?assertEqual(
           {error, read_certificate_unavailable},
           quod_simplex:test_local_history_view(Identity, validator, Base)),
        CommitteeId = crypto:hash(sha256, <<1503:64>>),
        Current = quod_simplex:test_state_set(
                    committee_id, CommitteeId,
                    quod_simplex:test_state_set(validators, [Self], Base)),
        {ok, View} = quod_simplex:test_local_history_view(
                       Identity, validator, Current),
        ?assertEqual(
           [applied, identity, owner, projection, slot, snapshot],
           lists:sort(maps:keys(View))),
        ?assertMatch(
           #{identity := Identity, slot := 8, applied := 7,
             projection := #{committee := [Self], committee_id := CommitteeId}},
           View),
        ?assertEqual(self(), maps:get(owner, View)),
        ?assertEqual(
           {error, invalid_identity},
           quod_simplex:test_local_history_view(
             {Ns, crypto:hash(sha256, <<1504:64>>)}, validator, Current)),
        Replaying = quod_simplex:test_state_set(prolog_ready, false, Current),
        ?assertEqual({error, not_ready},
                     quod_simplex:test_local_history_view(Identity, any, Replaying)),
        ?assertMatch({ok, #{slot := 8}},
                     quod_simplex:test_local_history_view(
                       Identity, committed, Replaying)),
        ?assertEqual({error, not_ready},
                     quod_simplex:test_local_history_view(
                       Identity, committed,
                       quod_simplex:test_state_set(slot, 9, Current))),
        %% The borrowed prefix remains bounded when the owner advances. Its
        %% apply frontier and committee projection do not silently change.
        {ok, _Store9} = quod_ct:append_direct_history(Store, [lists:last(Chain)]),
        {ok, Reader} = quod_ledger_store:open_ro_snapshot(maps:get(snapshot, View)),
        try
            ?assertEqual(8, quod_ledger_store:last(Reader)),
            ?assertEqual(not_found, quod_ledger_store:read_at(Reader, 9)),
            ?assertEqual(7, maps:get(applied, View))
        after quod_ledger_store:close(Reader)
        end
    after
        quod_ledger_store:close(Store),
        _ = file:del_dir_r(Dir)
    end.

read_attest_stale_token_refusal_remains_typed_test() ->
    Fixture = quod_ct:signed_atomic_fixture(
                #{goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    RequestId = <<59:128>>,
    ?assertEqual(
       {error, RequestId, conflict_retry},
       quod_simplex:test_dtx_endpoint_result(
         {read_attest, RequestId, PlanBlob},
         {error, conflict_retry}, st(#{}))).

read_attest_requires_one_exact_applied_height_test() ->
    Fixture = quod_ct:signed_atomic_fixture(
                #{goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    RequestId = <<60:128>>,
    Request = {read_attest, RequestId, PlanBlob},
    Refusal = {error, RequestId, read_certificate_unavailable},
    ?assertEqual(
       Refusal,
       quod_simplex:test_dtx_endpoint_result(
         Request, {read_plan_valid, Plan, 8},
         st(#{slot => 9, last_applied => 8}))),
    ?assertEqual(
       Refusal,
       quod_simplex:test_dtx_endpoint_result(
         Request, {read_plan_valid, Plan, 8},
         st(#{slot => 8, last_applied => 9}))),
    ?assertEqual(
       Refusal,
       quod_simplex:test_dtx_endpoint_result(
         Request, {read_plan_valid, Plan, 9},
         st(#{slot => 8, last_applied => 8}))).

read_attest_validator_signs_the_exact_current_ledger_anchor_test() ->
    Ns = <<"quod:read-attest-validator">>,
    #{anchor := Anchor, pub := Self, signer := Identity, chain := Chain} =
        quod_foreign_log_tests:long_identity_fixture(Ns, 3),
    Target = {Ns, Anchor},
    Fixture = quod_ct:signed_atomic_fixture(
                #{target => Target, node_identity => Identity,
                  goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    Dir = relay_store_dir("read_attest_validator"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store3} = quod_ct:append_direct_history(Store0, Chain),
    try
        State = st(#{ns => Ns, genesis_hash => Anchor,
                     self => Self, id => Identity,
                     validators => [Self], slot => 3, last_applied => 3,
                     sync => ready, prolog_ready => true, store => Store3}),
        RequestId = <<61:128>>,
        {read_attest, RequestId, Target, ProofId, PlanDigest, AnchorRef,
         CommitteeId, Self, Signature} =
            quod_simplex:test_dtx_endpoint_result(
              {read_attest, RequestId, PlanBlob},
              {read_plan_valid, Plan, 3}, State),
        ?assertEqual(quod_dtx:proof_id(Plan), ProofId),
        ?assertEqual(quod_dtx:digest(Plan), PlanDigest),
        ?assertMatch({ok, Target, 3, _},
                     quod_dtx:certified_ref_binding(AnchorRef)),
        ?assert(quod_read_certificate:verify_vote(
                  Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
                  Self, Signature))
    after
        quod_ledger_store:close(Store3),
        file:del_dir_r(Dir)
    end.

read_attest_keeps_the_admitted_snapshot_when_consensus_advances_test() ->
    Ns = <<"quod:read-attest-advance">>,
    #{anchor := Anchor, pub := Self, signer := Identity, chain := Chain} =
        quod_foreign_log_tests:long_identity_fixture(Ns, 4),
    Target = {Ns, Anchor},
    Fixture = quod_ct:signed_atomic_fixture(
                #{target => Target, node_identity => Identity,
                  goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    Dir = relay_store_dir("read_attest_advance"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store4} = quod_ct:append_direct_history(Store0, Chain),
    try
        Common = #{ns => Ns, genesis_hash => Anchor,
                   self => Self, id => Identity,
                   validators => [Self], sync => ready,
                   prolog_ready => true, store => Store4},
        AdmissionState = st(Common#{slot => 3, last_applied => 3}),
        ResponseState = st(Common#{slot => 4, last_applied => 4}),
        RequestId = <<65:128>>,
        {read_attest, RequestId, Target, ProofId, PlanDigest, AnchorRef,
         CommitteeId, Self, Signature} =
            quod_simplex:test_dtx_endpoint_result_at(
              {read_attest, RequestId, PlanBlob},
              {read_plan_valid, Plan, 3},
              AdmissionState, ResponseState),
        ?assertMatch({ok, Target, 3, _},
                     quod_dtx:certified_ref_binding(AnchorRef)),
        ?assert(quod_read_certificate:verify_vote(
                  Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
                  Self, Signature))
    after
        quod_ledger_store:close(Store4),
        file:del_dir_r(Dir)
    end.

read_attest_validator_signs_the_pinned_genesis_anchor_test() ->
    {Self, Identity} = id(),
    Ns = <<"quod:read-attest-genesis">>,
    Genesis = quod_simplex:test_genesis_tx(
                #{external_predicate_modules => []}, Ns, Self, <<62:256>>),
    Entry = material_entry(1, {genesis, 0}, none, {batch, [Genesis]}, 0),
    {ok, Block} = quod_simplex:block_from_entry(Entry),
    Anchor = quod_simplex:block_hash(Block),
    Target = {Ns, Anchor},
    Fixture = quod_ct:signed_atomic_fixture(
                #{target => Target, node_identity => Identity,
                  goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    Dir = relay_store_dir("read_attest_genesis"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store1} = quod_ledger_store:append(Store0, {none, [Entry]}),
    try
        ?assertMatch({ok, _},
                     quod_dtx:certified_entry_ref(Target, Entry, Genesis)),
        State = st(#{ns => Ns, genesis_hash => Anchor,
                     self => Self, id => Identity,
                     validators => [Self], slot => 1, last_applied => 1,
                     sync => ready, prolog_ready => true, store => Store1}),
        RequestId = <<63:128>>,
        {read_attest, RequestId, Target, ProofId, PlanDigest, AnchorRef,
         CommitteeId, Self, Signature} =
            quod_simplex:test_dtx_endpoint_result(
              {read_attest, RequestId, PlanBlob},
              {read_plan_valid, Plan, 1}, State),
        ?assertMatch({ok, Target, 1, _},
                     quod_dtx:certified_ref_binding(AnchorRef)),
        ?assert(quod_read_certificate:verify_vote(
                  Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
                  Self, Signature))
    after
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

dtx_endpoint_applied_waits_for_exact_projection_message_test() ->
    Generation = 5,
    Slot = 4,
    #{target := {Ns, Anchor} = Target, control := Control, entry := Entry,
      signer := #{pubkey := Author} = AuthorId, ref := ResolveRef,
      group_id := GroupId} = applied_role_fixture(Generation, Slot),
    ResolveCommitteeId = <<55:256>>,
    Evidence = #{identity => Target, phase => resolve, control => Control, entry => Entry,
                 committee => [Author], committee_id => ResolveCommitteeId},
    RequestId = <<52:128>>,
    Request = {applied, RequestId, GroupId, ResolveRef,
               Generation, commit},
    WaitingSnapshot =
        #{applied => none, applied_floor => Slot - 1,
          generation => Generation - 1},
    Key = {GroupId, ResolveRef, Generation, commit},
    ?assertEqual(
       {wait, Key},
       quod_simplex:test_waiting_applied_key(
         Request, {applied_state, Evidence, WaitingSnapshot})),
    AppliedSnapshot =
        #{applied => #{resolve_ref => ResolveRef,
                       generation => Generation, verdict => commit},
          applied_floor => Slot, generation => Generation},
    ?assertEqual(
       ready,
       quod_simplex:test_waiting_applied_key(
         Request, {applied_state, Evidence, AppliedSnapshot})),

    %% Applied confirmation is a durable level, not a transient edge.  Once
    %% the atomic projection floor covers the exact certified Resolve,
    %% releasing the group row cannot make the operation look pending again.
    %% The group-scoped AppliedGeneration and global proof epoch are distinct.
    ReleasedSnapshot =
        #{applied => none, applied_floor => Slot,
          generation => 1},
    ?assertEqual(
       ready,
       quod_simplex:test_waiting_applied_key(
         Request, {applied_state, Evidence, ReleasedSnapshot})),
    CurrentCommitteeId = <<56:256>>,
    ReleasedState = st(
                      #{ns => Ns, genesis_hash => Anchor, self => Author,
                        id => AuthorId,
                        validators => [Author], committee_id => CurrentCommitteeId,
                        slot => Slot, sync => ready, prolog_ready => true,
                        store => memory,
                        dtx_projection =>
                          quod_atomic:initial_projection(Target, 1)}),
    NetworkIdentity = <<57:256>>,
    with_network_identity(
      NetworkIdentity,
      fun() ->
          {ok, {Author, Signature}} =
              quod_applied_certificate:sign_applied_vote(
                NetworkIdentity, Target, ResolveCommitteeId, GroupId,
                ResolveRef, Generation, commit, AuthorId),
          ?assertEqual(
             {applied, RequestId, Target, ResolveCommitteeId, GroupId,
              ResolveRef, Generation, commit, Author, Signature},
             quod_simplex:test_dtx_endpoint_result(
               Request, {applied_state, Evidence, ReleasedSnapshot},
               ReleasedState))
      end),

    Parent = self(),
    Matching = spawn(fun() -> Parent ! {matching, receive M -> M end} end),
    Other = spawn(fun() -> Parent ! {other, receive M -> M end} end),
    S0 = st(#{ns => Ns, genesis_hash => Anchor, self => Author,
              validators => [Author], slot => Slot, sync => ready,
              prolog_ready => true, store => memory}),
    {_MatchingMonitor, S1} =
        quod_simplex:test_seed_dtx_worker(
          Matching, local, Request, {link, self()}, S0),
    OtherRequest =
        {applied, <<53:128>>, <<54:256>>, ResolveRef,
         Generation, commit},
    {_OtherMonitor, S2} =
        quod_simplex:test_seed_dtx_worker(
          Other, local, OtherRequest, {link, self()}, S1),
    %% The apply notification also wakes an exact waiter when this Resolve
    %% had no proof fence.  That is the ordinary no-write/abort path.
    _ = result_state(
          quod_simplex:running(
            cast, {resolve_applied, GroupId, Slot, Generation}, S2)),
    receive
        {matching, {dtx_resolve_applied, Key}} -> ok
    after 1000 ->
        error(exact_applied_worker_was_not_woken)
    end,
    receive
        {other, _Unexpected} ->
            error(unrelated_applied_worker_was_woken)
    after 0 ->
        ok
    end,
    exit(Other, kill).

%% Public outcomes are authoritative only when the responder is a member of
%% the requested frozen committee and its Prolog publication floor exactly
%% matches its current Simplex slot. A stale view, lagging projection, or
%% retired holder returns no status.
dtx_endpoint_outcome_is_current_view_and_floor_bound_test() ->
    {Self, _SelfId} = id(),
    {Other, _OtherId} = id(),
    Ns = <<"quod:dtx-outcome-view">>,
    Anchor = <<43:256>>,
    Target = {Ns, Anchor},
    CommitteeId = <<44:256>>,
    Ref = {transaction, Ns, Anchor, <<45:256>>},
    Status = #{status => pending, ref => Ref},
    Snapshot = #{applied_floor => 8, outcome => Status},
    S = st(#{ns => Ns, genesis_hash => Anchor, self => Self,
             validators => [Self], committee_id => CommitteeId,
             slot => 8, sync => ready, prolog_ready => true,
             store => memory}),
    RequestId = <<46:128>>,
    Request = {outcome, RequestId, Ref, CommitteeId, 7},
    ?assertEqual(
       {outcome, RequestId, Target, CommitteeId, 8, Status},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, Snapshot}, S)),
    ?assertEqual(
       {error, RequestId, not_ready},
       quod_simplex:test_dtx_endpoint_result(
         setelement(4, Request, <<47:256>>),
         {outcome_state, Snapshot}, S)),
    ?assertEqual(
       {error, RequestId, not_ready},
       quod_simplex:test_dtx_endpoint_result(
         setelement(5, Request, 9), {outcome_state, Snapshot}, S)),
    ?assertEqual(
       {error, RequestId, not_ready},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, Snapshot#{applied_floor => 7}}, S)),
    Ahead = quod_simplex:test_state_set(slot, 9, S),
    ?assertEqual(
       {error, RequestId, not_ready},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, Snapshot}, Ahead)),
    Retired = st(#{ns => Ns, genesis_hash => Anchor, self => Self,
                   validators => [Other], committee_id => CommitteeId,
                   slot => 8, sync => ready, prolog_ready => true,
                   store => memory}),
    ?assertEqual(
       {error, RequestId, not_ready},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, Snapshot}, Retired)).

%% An abort tombstone can lose its slot to a concurrently certified Vote.
%% Retire that exact stale Resolve and wake recovery to include the own Vote
%% reference; rejection of stale evidence is not a target-policy refusal.
dtx_invalid_resolve_is_released_for_phase_replan_test() ->
    {Author, AuthorId} = id(),
    Target = {Ns, Anchor} =
        {<<"quod:dtx-finalize-race">>, <<43:256>>},
    SourceIdentity = {<<"quod:dtx-finalize-race-origin">>, <<42:256>>},
    GroupId = <<44:256>>,
    SourceVoteRef = dtx_test_ref(SourceIdentity, 2, <<45:256>>),
    DirectAbort = quod_ct:atomic_abort_record(Target, GroupId, SourceVoteRef),
    {ok, Material} = quod_atomic:admission_material(DirectAbort),
    {ok, Control} = quod_atomic:sign_control(
                      Target, Material, <<46:256>>, 1, 1, AuthorId),
    S0 = st(#{ns => Ns, genesis_hash => Anchor, self => Author,
              validators => [Author], sync => ready,
              dtx_projection => quod_atomic:initial_projection(Target, 1)}),
    Retained = quod_simplex:test_seed_dtx_submission(
                 Control, [{dtx_endpoint, self()}], S0),
    Done = quod_simplex:test_retire_invalid_dtx(
             {batch, [{dtx, Control}]},
             [generation_changed], Retained),
    receive
        {dtx_submit_result, {error, retry}} -> ok
    after 1000 ->
        error(missing_resolve_replan_reply)
    end,
    ?assertEqual(0, maps:get(submissions,
                            quod_simplex:test_dtx_endpoint_counts(Done))).


%% A stale response must not tear down a newer validation for the same slot.
%% Conversely, an exact response that is unusable because the head/floor moved
%% discards that obsolete request and candidate together. It is never parked
%% for a timer-driven retry.
dtx_verdict_cleanup_discards_only_the_exact_stale_request_test() ->
    Ns = unique_gate_namespace(<<"dtx-verdict-cleanup">>),
    Target = {Ns, <<0:256>>},
    Slot = 1,
    Era = quod_ledger:initial_era(Target),
    Root = {Era, 0, <<23:256>>},
    CurrentBH = <<22:256>>,
    CurrentToken = {1, <<23:256>>},
    OldToken = {1, <<24:256>>},
    Candidate = #block{era = Era, slot = Slot, parent = Root,
                       payload = {batch, [{dtx, <<>>}]}, timestamp = 0},
    CurrentOwner = spawn(fun validation_owner/0),
    OldOwner = spawn(fun validation_owner/0),
    try
        S0 = st(#{ns => Ns, slot => 1,
                  history_head => CurrentToken,
                  dtx_projection => quod_atomic:initial_projection(Target, 0),
                  eng => quod_simplex:eng_new(?DOMAIN, [],{Root, 1, 0})}),
        {Monitor, Latched} =
            quod_simplex:test_latch_dtx_validation(
              Slot, CurrentBH, CurrentToken, CurrentOwner, Candidate, S0),
        ?assert(quod_simplex:test_consensus_barrier(Latched)),
        Expected =
            {CurrentBH,
             {dtx, CurrentToken, CurrentOwner, Monitor, DeadlineMs},
             {CurrentBH, Candidate}, none, undefined} = quod_simplex:test_dtx_round(Slot, Latched),
        ?assert(is_integer(DeadlineMs)),

        %% This belongs to an older request and is therefore an exact no-op.
        AfterStale =
            quod_simplex:test_on_dtx_verdict(
              Slot, <<21:256>>, OldToken, OldOwner, 1, abstain, Latched),
        ?assertEqual(Expected, quod_simplex:test_dtx_round(Slot, AfterStale)),

        %% The exact active request is now below the required applied floor.
        %% It cannot be used, but it must not wedge all ordinary ingress.
        Released =
            quod_simplex:test_on_dtx_verdict(
              Slot, CurrentBH, CurrentToken, CurrentOwner, 0,
              abstain, AfterStale),
        ?assertEqual(
           {none, none, none, none, undefined},
           quod_simplex:test_dtx_round(Slot, Released)),
        ?assertNot(quod_simplex:test_consensus_barrier(Released)),
        ?assertNot(erlang:demonitor(Monitor, [info]))
    after
        CurrentOwner ! stop,
        OldOwner ! stop
    end.

%% is_participant is FACTS-ONLY now — Self ∈ active_validators, with no sync/boot coupling.
is_participant_test() ->
    P = fun(Self, Vs) -> quod_simplex:is_participant(st(#{self => Self, validators => Vs})) end,
    ?assert(P(<<"me">>, [<<"a">>, <<"me">>])),
    ?assertNot(P(<<"me">>, [<<"a">>, <<"b">>])),   %% observer
    ?assertNot(P(<<"me">>, [])).                    %% unfounded

%% Only `ready` is caught up; voting and leading share the same participant + recovery capability.
gate_truth_table_test() ->
    EngIdle = root_engine(0),                 %% empty pool ⇒ not behind
    EngBehind = engine_with_commit(0, 20),   %% a finalizer cert well past slot+1 ⇒ behind
    Base = #{self => <<"me">>, validators => [<<"me">>], slot => 2, eng => EngIdle},

    S1 = st(Base#{sync => ready}),
    ?assert(quod_simplex:caught_up(S1)),
    ?assert(quod_simplex:may_vote(S1)),

    %% A resuming member remains a participant for ingress, but has no voting capability.
    S2 = st(Base#{sync => unconfirmed}),
    ?assert(quod_simplex:is_participant(S2)),
    ?assertNot(quod_simplex:caught_up(S2)),
    ?assertNot(quod_simplex:may_vote(S2)),

    ?assertNot(quod_simplex:caught_up(st(Base#{sync => {pulling, self()}}))),
    ?assertNot(quod_simplex:caught_up(st(Base#{sync => ready, eng => EngBehind}))),

    %% A ready observer may serve/follow, but cannot vote or lead.
    Obs = st(Base#{validators => [<<"a">>], sync => ready}),
    ?assert(quod_simplex:caught_up(Obs)),
    ?assertNot(quod_simplex:may_vote(Obs)).

%% Load-robust self-corroboration: applying a live certified finality group
%% flips an `unconfirmed` member to `ready` — so a member that keeps up with a busy head via the live
%% stream resumes voting without needing the tip probe to catch a quiet instant. Only `unconfirmed` flips;
%% an in-flight pull (`{pulling,_}`) and an already-`ready` node are left untouched (no double-latch, and a
%% still-behind head is re-gated by `caught_up = ready AND not behind`).
confirm_live_test() ->
    ?assertEqual(ready, quod_simplex:test_sync(
                          quod_simplex:confirm_live(st(#{sync => unconfirmed})))),
    ?assertMatch({pulling, _}, quod_simplex:test_sync(
                                 quod_simplex:confirm_live(st(#{sync => {pulling, self()}})))),
    ?assertEqual(ready, quod_simplex:test_sync(
                          quod_simplex:confirm_live(st(#{sync => ready})))),
    %% a CAUGHT-UP unconfirmed member self-corroborates on a live finality and RESUMES voting (the stall fix)
    CaughtUp = st(#{self => <<"me">>, validators => [<<"me">>], slot => 3, sync => unconfirmed,
                    eng => root_engine(0)}),
    ?assertNot(quod_simplex:may_vote(CaughtUp)),                          %% unconfirmed ⇒ cannot vote (the stall)
    ?assert(quod_simplex:may_vote(quod_simplex:confirm_live(CaughtUp))),  %% live finality ⇒ ready ⇒ votes
    %% a member confirmed-live over a head still behind the tip is NOT caught up (behind re-gates voting)
    Behind = st(#{self => <<"me">>, validators => [<<"me">>], slot => 2, sync => unconfirmed,
                  eng => engine_with_commit(0, 20)}),
    Confirmed = quod_simplex:confirm_live(Behind),
    ?assertEqual(ready, quod_simplex:test_sync(Confirmed)),
    ?assertNot(quod_simplex:caught_up(Confirmed)),
    ?assertNot(quod_simplex:may_vote(Confirmed)).

%% Recovery intent and the externally visible syncing flag derive from the same enum.
should_sync_and_syncing_test() ->
    EngIdle = root_engine(0),
    EngBehind = engine_with_commit(0, 20),
    Settled = st(#{sync => ready, slot => 2, eng => EngIdle}),
    ?assertNot(quod_simplex:should_sync(Settled)),
    ?assertNot(quod_simplex:syncing(Settled)),
    Fresh = st(#{sync => unconfirmed, slot => 0, eng => EngIdle}),
    ?assert(quod_simplex:should_sync(Fresh)),
    ?assert(quod_simplex:syncing(Fresh)),
    ?assert(quod_simplex:should_sync(st(#{sync => ready, slot => 2, eng => EngBehind}))),
    ?assert(quod_simplex:syncing(st(#{sync => {pulling, self()}, slot => 2, eng => EngIdle}))).

%% A final certificate for the immediate next slot is already authoritative gap evidence when this node
%% never received the block. It must lose voting capability and enter normal durable-log recovery instead
%% of waiting for the network to advance a second slot.
next_slot_finalizer_revokes_stale_voting_test() ->
    Me = <<"me">>,
    FinalizedNext = engine_with_commit(5, 6),
    Stale = st(#{self => Me, validators => [Me], slot => 500,
                 eng => FinalizedNext, sync => ready}),
    ?assert(quod_simplex:should_sync(Stale)),
    ?assertNot(quod_simplex:caught_up(Stale)),
    ?assertNot(quod_simplex:may_vote(Stale)).

%% Success grants readiness when the durable head is AT OR PAST the corroborated height. A head that
%% advanced while the completion was in flight only moves via cert-verified commits (`persisted_finality`),
%% so it is itself corroborated — accepting it is what keeps a member that stays caught up under load from
%% being bounced back to `unconfirmed` forever. A result from an OBSOLETE worker (pid mismatch) is ignored.
sync_completion_is_height_bound_test() ->
    Eng = root_engine(0),
    Base = #{self => <<"me">>, validators => [<<"me">>],
             sync => {pulling, self()}, eng => Eng, last_applied => 3, prolog_ready => true},
    %% exact corroborated height ⇒ ready
    Pulling = st(Base#{slot => 2}),
    {keep_state, Ready, _} = quod_simplex:running(cast, {sync_done, self(), {ready, 2}}, Pulling),
    ?assertEqual(ready, quod_simplex:test_sync(Ready)),
    %% head advanced past the corroborated height (live cert-verified commits) ⇒ STILL ready (no bounce)
    Advanced = st(Base#{slot => 3}),
    ?assertNot(quod_simplex:may_vote(Advanced)),   %% mid-pull ⇒ the stall: cannot vote yet
    {keep_state, Accepted, _} =
        quod_simplex:running(cast, {sync_done, self(), {ready, 2}}, Advanced),
    ?assertEqual(ready, quod_simplex:test_sync(Accepted)),
    ?assert(quod_simplex:may_vote(Accepted)),      %% accepted advanced-during-probe ⇒ RESUMES voting (the fix)
    %% a result whose pid does not own the in-flight pull is stale ⇒ state unchanged (still pulling)
    Other = spawn(fun() -> ok end),
    {keep_state, Stale} = quod_simplex:running(cast, {sync_done, Other, {ready, 2}}, Pulling),
    ?assertMatch({pulling, _}, quod_simplex:test_sync(Stale)).

tip_quorum_test() ->
    A = <<"a">>, B = <<"b">>, C = <<"c">>, D = <<"d">>, Committee = [A, B, C, D],
    ?assertNot(quod_simplex:tip_quorum(Committee, A, [B])),
    ?assert(quod_simplex:tip_quorum(Committee, A, [B, C])),
    ?assert(quod_simplex:tip_quorum(Committee, A, [B, B, C, <<"outsider">>])),
    ?assertNot(quod_simplex:tip_quorum(Committee, <<"outsider">>, [A, B])).

%% A sole validator settles locally; it must not perform endpoint warming just because there are no peer
%% resolver hints. A cold joiner with no committee has no possible identity confirmation and does need its
%% bootstrap endpoint path.
hint_warm_threshold_test() ->
    ?assertNot(quod_simplex:needs_hint_warm([<<"me">>], <<"me">>)),
    ?assert(quod_simplex:needs_hint_warm([], <<"me">>)).

recovery_failure_revokes_capability_test() ->
    Eng = root_engine(0),
    Pulling = st(#{self => <<"me">>, validators => [<<"me">>], slot => 2,
                   eng => Eng, sync => {pulling, self()}}),
    Failed = quod_simplex:recovery_failed(Pulling),
    ?assertEqual(unconfirmed, quod_simplex:test_sync(Failed)),
    ?assertNot(quod_simplex:may_vote(Failed)).

sink_ownership_test() ->
    Other = spawn(fun() -> receive stop -> ok end end),
    Pulling = st(#{sync => {pulling, self()}}),
    ?assert(quod_simplex:may_sink({recovery, self()}, Pulling)),
    ?assertNot(quod_simplex:may_sink({recovery, Other}, Pulling)),
    ?assertNot(quod_simplex:may_sink({feed, replay}, Pulling)),
    ?assert(quod_simplex:may_sink({feed, {live, 2, 3}},
                                  st(#{self => <<"me">>, validators => [<<"other">>], sync => ready}))),
    ?assertNot(quod_simplex:may_sink({feed, replay},
                                     st(#{self => <<"me">>, validators => [<<"me">>], sync => ready}))),
    Other ! stop.

%% A settled observer's contiguous push is a real live event. Recovery and anti-entropy
%% windows rebuild D silently and reconcile P once at their explicit ready edge.
feed_apply_origin_test() ->
    ?assertEqual({live, 2, 3}, quod_simplex:catchup_origin({feed, {live, 2, 3}})),
    ?assertEqual(replay, quod_simplex:catchup_origin({feed, replay})),
    ?assertEqual(replay, quod_simplex:catchup_origin({recovery, self()})).

catchup_window_publishes_one_wake_only_certified_head_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = iolist_to_binary(
           [<<"catchup:certified-head:">>,
            integer_to_binary(erlang:unique_integer([positive]))]),
    #{identity := Identity = {Ns, Anchor}, genesis := Genesis} = quod_ct:protocol_fixture(Ns),
    Entry = quod_ledger:entry(1, Genesis, none),
    Dir = relay_store_dir("catchup_certified_head"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
    quod_reg:subscribe({committed, Ns}),
    try
        {ok, Group} = quod_ct:history_group(
            Identity, Entry, quod_simplex:history_projection(Identity), Index),
        Initial = st(#{ns => Ns, genesis_hash => Anchor, phase_index => Index,
                       store => Store0, slot => 0, sync => {pulling, self()}}),
        {_Recovered, ok} = quod_simplex:test_apply_catchup_window(
                             {recovery, self()}, Group, Initial),
        receive
            {certified_head, Ns, 1} -> ok
        after 1000 ->
            error(catchup_head_wake_missing)
        end,
        %% Catch-up exposes only the newest durable height. It must never
        %% replay the historical entry as a live commit/event.
        receive
            {committed, Ns, 1, _HistoricalEntry} ->
                error(catchup_rebroadcast_historical_entry)
        after 0 ->
            ok
        end
    after
        _ = try quod_reg:unsubscribe({committed, Ns}) catch _:_ -> ok end,
        quod_dtx_phase_index:close(Index),
        quod_ledger_store:close(Store0),
        file:del_dir_r(Dir)
    end.

%% Finality needs no hysteresis. Only failed acquisitions retain pacing.
sync_arm_pacing_test() ->
    Arm = fun(S) -> quod_simplex:test_arm(quod_simplex:pace_tick(S)) end,
    ?assertEqual({0, 0}, Arm(st(#{sync_arm => {0, 0}}))),
    ?assertEqual({2, 8}, Arm(st(#{sync_arm => {3, 8}}))),
    ?assert(quod_simplex:arm_ready(st(#{sync => unconfirmed, sync_arm => {0, 0}}))),
    ?assertNot(quod_simplex:arm_ready(st(#{sync => unconfirmed, sync_arm => {1, 4}}))),
    ?assert(quod_simplex:arm_ready(st(#{sync => ready, sync_arm => {0, 0}}))),
    ?assertNot(quod_simplex:arm_ready(st(#{sync => ready, sync_arm => {1, 4}}))),
    {BC, BI} = quod_simplex:backoff({0, 0}),
    ?assert(BI >= 3),                              %% floored at ?SYNC_BACKOFF_MIN
    ?assert(BC >= 1),                              %% a positive jittered cooldown
    {_, BI2} = quod_simplex:backoff({0, BI}),
    ?assert(BI2 >= BI andalso BI2 =< 20),          %% grows, capped at ?SYNC_BACKOFF_MAX
    ?assertEqual({0, 0}, quod_simplex:reset_pace()).

root_engine(View) ->
    quod_simplex:eng_new(?DOMAIN, [ ], {{?FIXTURE_ERA, View, <<1:256>>}, max(1, View), 0}).

notarized_prefix(Committee, RootView, LastView) ->
    Root = quod_ledger:block_ref(blk(RootView)),
    lists:foldl(fun(View, Engine) ->
        Block = blk(View),
        {Offered, _} = quod_simplex:eng_offer({block, Block}, Engine),
        {Notarized, _} = feed_shares(supports(Block, Committee, length(Committee)), Offered),
        Notarized
    end, quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, RootView, 0}),
    lists:seq(RootView + 1, LastView)).

%% Recovery gates ingest a genuine certificate without its block. Certificate
%% presence cannot be simulated by planting keys in a different engine field.
engine_with_commit(RootView, CommitView) ->
    [{Pub, Signer}] = committee(1),
    Engine = quod_simplex:eng_new(?DOMAIN, [Pub ], {{?FIXTURE_ERA, RootView, <<1:256>>}, max(1, RootView), 0}),
    Position = {?FIXTURE_ERA, CommitView}, Hash = <<2:256>>,
    Share = quod_simplex:make_share(?DOMAIN, commit, Position, Hash, Signer),
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN, commit, Position, Hash, [Share], [Pub]),
    {Next, _} = quod_simplex:eng_offer({cert, Cert}, Engine),
    Next.

%% minimal-state builder for the pure gate predicates (the #s record is private to quod_simplex)
st(Overrides) ->
    DomainOverrides =
        case maps:is_key(consensus_domain, Overrides) of
            true  -> Overrides;
            false -> Overrides#{consensus_domain => ?DOMAIN}
        end,
    %% Every founded test committee has the same kind of authoritative view
    %% identity as a live/replayed node. Tests that intentionally model an
    %% unfounded state leave `validators` empty; explicit committee ids win.
    WithCommitteeId =
        case {maps:is_key(committee_id, DomainOverrides),
              maps:get(validators, DomainOverrides, [])} of
            {false, [_ | _]} ->
                DomainOverrides#{
                  committee_id =>
                      crypto:hash(sha256, <<"simplex-test-committee-view">>)};
            _ ->
                DomainOverrides
        end,
    %% A state owner always has a protocol root, including before its material
    %% history is installed. Height/readiness remain explicit per test.
    WithEngine = case maps:is_key(eng, WithCommitteeId) of
        true -> WithCommitteeId;
        false ->
            Ns = maps:get(ns, WithCommitteeId, <<"t">>),
            Anchor = maps:get(genesis_hash, WithCommitteeId, <<0:256>>),
            Root = {quod_ledger:initial_era({Ns, Anchor}), 0, Anchor},
            WithCommitteeId#{eng => quod_simplex:eng_new(
                maps:get(consensus_domain, WithCommitteeId),
                maps:get(validators, WithCommitteeId, []), {Root, max(1, maps:get(slot, WithCommitteeId, 1)), 0})}
    end,
    quod_simplex:test_state(WithEngine).

voting_readiness(Peers, LinkPid, Height) ->
    Now = quod_time:mono_ms(),
    maps:from_list([{Peer, {LinkPid, Height, {?FIXTURE_ERA, 1, 0}, true, Now}} || Peer <- Peers]).

%%%===================================================================
%%% block-timestamp acceptance (the valid_proposal monotonic + future + type gate)
%%%===================================================================

%% Ts must be a non-negative integer, ≥ the parent block time, and ≤ Now + skew. This is the whole
%% Byzantine-timestamp defence, so pin every branch directly (valid_proposal wires it to the live clock).
ts_acceptable_test() ->
    Now  = quod_time:now_ms(),
    Last = Now - 1000,
    ?assert(quod_simplex:ts_acceptable(Now, Last, Now)),          %% normal: monotonic + within skew
    ?assert(quod_simplex:ts_acceptable(Last, Last, Now)),         %% equal to parent is allowed
    ?assertNot(quod_simplex:ts_acceptable(Last - 1, Last, Now)),  %% backwards ⇒ rejected
    ?assertNot(quod_simplex:ts_acceptable(Now + 3 * 60 * 60 * 1000, Last, Now)),  %% >2h future ⇒ rejected
    %% non-integer terms must NOT slip through. A FLOAT is the load-bearing case: numbers compare by
    %% VALUE, so the range check alone would accept Now+0.5 — ONLY the is_integer guard rejects it. The
    %% others (binary/atom/tuple) sort above every integer in term order, so the upper bound also stops them.
    ?assertNot(quod_simplex:ts_acceptable(Now + 0.5, Last, Now)),
    ?assertNot(quod_simplex:ts_acceptable(<<"x">>, Last, Now)),
    ?assertNot(quod_simplex:ts_acceptable(future, Last, Now)),
    ?assertNot(quod_simplex:ts_acceptable({0}, Last, Now)).

%% Material admission allows two overlapping writes. Protocol views advance
%% through real notarization; neither a view number nor a carrier is a row.
pipeline_frontier_test() ->
    Committee = [{Self, _} | _] = committee(4),
    Root = quod_ledger:block_ref(blk(5, 495 + 5)),
    Eng = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 500, 0}),
    Base = #{self => Self, validators => pubs(Committee), slot => 500,
             history_head => {500, element(3, Root)}, sync => ready},
    ?assertEqual({ok, 6}, quod_simplex:proposal_slot(st(Base#{eng => Eng}))),
    B6 = blk(6, 495 + 6),
    {E1, _} = quod_simplex:eng_offer({block, B6}, Eng),
    {E2, _} = feed_shares(supports(B6, Committee, 3), E1),
    ?assertEqual({ok, 7}, quod_simplex:proposal_slot(st(Base#{eng => E2}))),
    B7 = blk(7, 495 + 7),
    {E3, _} = quod_simplex:eng_offer({block, B7}, E2),
    {E4, _} = feed_shares(supports(B7, Committee, 3), E3),
    ?assertEqual(blocked, quod_simplex:proposal_slot(st(Base#{eng => E4}))).

%% Parent installation preserves an already requested successor, without
%% resetting the unchanged view's deadline or requiring another caller.
pipelined_demand_survives_parent_finality_test() ->
    Committee = [{Self, _} | _] = committee(4),
    Root = quod_ledger:block_ref(blk(5, 495 + 5)), B6 = blk(6, 495 + 6),
    {E1, _} = quod_simplex:eng_offer({block, B6},
        quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 500, 0})),
    {E2, _} = feed_shares(supports(B6, Committee, 3), E1),
    Base = #{self => Self, validators => pubs(Committee), slot => 500,
             history_head => {500, element(3, Root)}, sync => ready},
    Requested = quod_simplex:reconcile_head_progress(
        quod_simplex:watch_requested(7, st(Base#{eng => E2}))),
    ?assertEqual(7, quod_simplex:test_requested(Requested)),
    ?assertEqual({?FIXTURE_ERA, 7, awaiting_proposal},
                 quod_simplex:test_progress(Requested)),
    Ref = quod_ledger:block_ref(B6),
    ParentFinal = quod_simplex:reconcile_head_progress(st(Base#{
        slot => 501, history_head => {501, element(3, Ref)},
        requested_slot => quod_simplex:test_requested(Requested),
        eng => quod_simplex:eng_prune(Ref, E2)})),
    ?assertEqual({?FIXTURE_ERA, 7, awaiting_proposal},
                 quod_simplex:test_progress(ParentFinal)),
    ?assertEqual([], quod_simplex:progress_timer_actions(Requested, ParentFinal)).

%% A delayed request below the archived protocol root cannot reopen demand.
%% A genuinely later request survives the same delayed call.
finalized_request_is_not_resurrected_test() ->
    Base = #{slot => 500, eng => root_engine(6), sync => ready},
    Cleared = quod_simplex:watch_requested(6, st(Base#{requested_slot => 6})),
    ?assertEqual(none, quod_simplex:test_requested(Cleared)),
    Later = quod_simplex:watch_requested(6, st(Base#{requested_slot => 7})),
    ?assertEqual(7, quod_simplex:test_requested(Later)).

%% One authenticated complaint is demand to watch, not an instruction to
%% join a complaint camp. Duplicate delivery cannot renew that deadline.
single_peer_complaint_wakes_existing_watchdog_test() ->
    [{A, IdA}, {B, _} = PeerB | _] = Committee = committee(4),
    Links = maps:from_list([{P, {self(), make_ref()}} || P <- pubs(Committee), P =/= A]),
    Idle = st(#{self => A, id => IdA, validators => pubs(Committee), slot => 500,
        eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), {{?FIXTURE_ERA, 5, <<1:256>>}, 500, 0}),
        sync => ready, conns => Links}),
    try
        Share = complaint_share(6, PeerB),
        Receive = fun(S) -> quod_simplex:reconcile_head_progress(
            quod_simplex:dispatch(B, {share, Share}, S)) end,
        Watched = Receive(Idle),
        ?assertEqual({?FIXTURE_ERA, 6, awaiting_notarization},
                     quod_simplex:test_progress(Watched)),
        ?assertEqual({none, false, false}, quod_simplex:test_round(6, Watched)),
        ?assertMatch([{{timeout, progress}, _, {progress_timeout, {?FIXTURE_ERA, 6}}}],
                     quod_simplex:progress_timer_actions(Idle, Watched)),
        Repeated = Receive(Watched),
        ?assertEqual([], quod_simplex:progress_timer_actions(Watched, Repeated)),
        TimedOut = quod_simplex:on_progress_timeout({?FIXTURE_ERA, 6}, Repeated),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, TimedOut)),
        ?assertEqual(1, quod_simplex:test_progress_counts(TimedOut)),
        ?assertEqual(500, element(1, quod_simplex:test_committed_store(TimedOut)))
    after flush_consensus_fixture_frames() end.

%% A wire shape is not accepted evidence. Rejected signatures/domains/eras,
%% stale or far views, self shares and removed members cannot create demand.
unaccepted_complaints_do_not_wake_watchdog_test() ->
    [{A, IdA} = Self, {B, _} = PeerB, {C, _}, {D, _}] = Committee = committee(4),
    {Outsider, _} = Other = id(),
    Base = #{self => A, id => IdA, validators => pubs(Committee), slot => 500,
        eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), {{?FIXTURE_ERA, 5, <<1:256>>}, 500, 0}), sync => ready},
    Valid = complaint_share(6, PeerB),
    WrongDomain = quod_simplex:make_share(crypto:hash(sha256, <<"another-chain">>),
        complaint, {?FIXTURE_ERA, 6}, none, element(2, PeerB)),
    WrongEra = quod_simplex:make_share(?DOMAIN, complaint, {<<8:256>>, 6}, none,
                                     element(2, PeerB)),
    Cases = [{B, Valid#share{sig = <<0:512>>}}, {B, WrongDomain}, {B, WrongEra},
             {Outsider, complaint_share(6, Other)}, {A, complaint_share(6, Self)},
             {B, complaint_share(5, PeerB)}, {B, complaint_share(8, PeerB)}],
    lists:foreach(fun({Sender, Share}) ->
        S = quod_simplex:reconcile_head_progress(
              quod_simplex:dispatch(Sender, {share, Share}, st(Base))),
        ?assertEqual(idle, quod_simplex:test_progress(S)),
        ?assertEqual({none, false, false}, quod_simplex:test_round(6, S))
    end, Cases),
    {Retained, []} = quod_simplex:eng_offer({share, Valid}, maps:get(eng, Base)),
    Removed = st(Base#{validators => [A, C, D], eng => Retained}),
    ?assertEqual(idle, quod_simplex:test_progress(
        quod_simplex:reconcile_head_progress(Removed))).

%% Recovery retains demand while refusing fresh signatures. A future view's
%% complaint becomes watchable only when a certificate advances to that view.
passive_and_future_complaints_track_the_current_view_test() ->
    [{A, IdA}, {B, _} = PeerB | _] = Committee = committee(4),
    Base = #{self => A, id => IdA, validators => pubs(Committee), slot => 500,
        eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), {{?FIXTURE_ERA, 5, <<1:256>>}, 500, 0}), sync => ready},
    {HeadEvidence, []} = quod_simplex:eng_offer(
        {share, complaint_share(6, PeerB)}, maps:get(eng, Base)),
    Passive = quod_simplex:reconcile_head_progress(
        st(Base#{eng => HeadEvidence, sync => unconfirmed})),
    ?assertEqual({?FIXTURE_ERA, 6, awaiting_notarization},
                 quod_simplex:test_progress(Passive)),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6,
        quod_simplex:on_progress_timeout({?FIXTURE_ERA, 6}, Passive))),
    Child = quod_simplex:reconcile_head_progress(quod_simplex:dispatch(
        B, {share, complaint_share(7, PeerB)}, st(Base))),
    ?assertEqual(idle, quod_simplex:test_progress(Child)),
    {ChildEvidence, []} = quod_simplex:eng_offer(
        {share, complaint_share(7, PeerB)}, maps:get(eng, Base)),
    {Advanced, _} = feed_shares([complaint_share(6, P) || P <- take(3, Committee)],
                               ChildEvidence),
    NextHead = quod_simplex:reconcile_head_progress(st(Base#{eng => Advanced})),
    ?assertEqual({?FIXTURE_ERA, 7, awaiting_notarization},
                 quod_simplex:test_progress(NextHead)),
    ?assertEqual(500, element(1, quod_simplex:test_committed_store(NextHead))).

%% Placement requires readiness on the exact authenticated inbound generation.
%% Socket existence, old material height, stale reports and replaced links
%% cannot transfer custody. An outbound connection is not required.
relay_readiness_requires_current_inbound_generation_test() ->
    Committee = [{Self, _} | _] = committee(4), Validators = pubs(Committee),
    View = hd([V || V <- lists:seq(1, 4), quod_simplex:leader(V, Validators) =/= Self]),
    Peer = quod_simplex:leader(View, Validators),
    Base = #{self => Self, validators => Validators, slot => 500,
             inbound_conns => #{Peer => {self(), make_ref()}}},
    OtherLink = spawn(fun() -> receive stop -> ok end end),
    try
        Now = quod_time:mono_ms(),
        lists:foreach(fun(Readiness) ->
            ?assertEqual(blocked, quod_simplex:test_dtx_slot_route(
                View, st(Base#{peer_readiness => Readiness})))
        end, [#{}, voting_readiness([Peer], self(), 499),
              #{Peer => {self(), 500, {?FIXTURE_ERA, 1, 0}, true, Now - 3001}},
              #{Peer => {self(), 500, {?FIXTURE_ERA, 1, 0}, false, Now}},
              voting_readiness([Peer], OtherLink, 500)]),
        ?assertEqual({relay, Peer}, quod_simplex:test_dtx_slot_route(
            View, st(Base#{peer_readiness => voting_readiness([Peer], self(), 500)})))
    after OtherLink ! stop end.

%% Consensus links are committee-scoped. A committed removal drops both directions plus any queued frames
%% and outstanding dial for the departed peer, while preserving the remaining member's transport state.
committee_change_prunes_stale_links_test() ->
    [{A, _}, {B, _}, {C, _}] = committee(3),
    Keep = spawn(fun Loop() -> receive _ -> Loop() end end),
    DropOut = spawn(fun Loop() -> receive _ -> Loop() end end),
    DropIn = spawn(fun Loop() -> receive _ -> Loop() end end),
    try
        S = st(#{self => A, validators => [A, B],
                 conns => #{B => {Keep, erlang:monitor(process, Keep)},
                            C => {DropOut, erlang:monitor(process, DropOut)}},
                 inbound_conns => #{B => {Keep, erlang:monitor(process, Keep)},
                                    C => {DropIn, erlang:monitor(process, DropIn)}},
                 outbox => #{B => [<<"keep">>], C => [<<"drop">>]},
                 dialing => #{B => 1, C => 1}}),
        Pruned = quod_simplex:prune_consensus_links(S),
        ?assertEqual({[B], [B], [B], [B]},
                     quod_simplex:test_link_peers(Pruned))
    after
        exit(Keep, kill),
        exit(DropOut, kill),
        exit(DropIn, kill)
    end.

%% Membership pruning uses the same monitored retirement barrier as live
%% generation replacement. Keep the removed process alive after `close` to
%% prove the prune itself does not wait, then re-admit its peer before
%% delivering a queued frame: the tombstone, rather than committee exclusion or
%% process death, is what prevents the retired pid from reclaiming the stream.
committee_prune_retirement_is_nonblocking_and_monotonic_test() ->
    [{Self, _SelfId}, {Peer, _PeerId}] = committee(2),
    Slot = 3,
    {OldPid, OldToken} = spawn_stubborn_link(),
    OldRef = erlang:monitor(process, OldPid),
    try
        Removed =
            st(#{self => Self, validators => [Self],
                 slot => Slot, sync => ready,
                 eng => root_engine(Slot),
                 inbound_conns => #{Peer => {OldPid, OldRef}},
                 peer_readiness =>
                     #{Peer =>
                           {OldPid, Slot, {?FIXTURE_ERA, 1, 0}, true,
                            quod_time:mono_ms()}}}),
        {PruneUs, Pruned} =
            timer:tc(
              fun() ->
                      quod_simplex:prune_consensus_links(Removed)
              end),
        ?assert(PruneUs < 250000),
        await_stubborn_close_requested(OldPid, OldToken),
        ?assert(is_process_alive(OldPid)),
        ?assertEqual(
           {[], [], [], []},
           quod_simplex:test_link_peers(Pruned)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(Pruned)),

        %% Make the peer eligible again before its queued old-generation
        %% readiness arrives. Without the retained tombstone, this live pid
        %% would be adopted and counted as the new generation.
        Readmitted =
            quod_simplex:test_state_set(
              validators, [Self, Peer], Pruned),
        LogChan =
            term_to_binary({log, <<"t">>}, [deterministic]),
        ReadyPayload =
            quod_simplex:encode(
              <<"t">>, {readiness, Slot, {?FIXTURE_ERA, 1, 0}, true}),
        AfterStale =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Peer, ignored}, OldPid},
                 LogChan, ReadyPayload},
                Readmitted)),
        {_OutboundAfterStale, InboundAfterStale,
         _OutboxAfterStale, _DialingAfterStale} =
            quod_simplex:test_link_peers(AfterStale),
        ?assertEqual([], InboundAfterStale),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AfterStale)),

        OldDown =
            release_stubborn_link(OldPid, OldToken, OldRef),
        AfterOldDown =
            running_state(
              quod_simplex:running(
                info, OldDown, AfterStale)),
        ?assertEqual(
           [],
           quod_simplex:test_retired_inbound(AfterOldDown))
    after
        ensure_stubborn_link_closed(OldPid, OldToken)
    end.

%% A proposal admitted while recovering can be redriven after readiness.
%% Timeout still chooses its ordinary complaint immediately, with no grace.
ready_proposal_redrive_supports_without_timeout_grace_test() ->
    Committee = [{Self, Signer} | _] = committee(4),
    Root = quod_ledger:block_ref(blk(5, 495 + 5)),
    Tx = signed_tx(<<"t">>, <<"passive-recovery">>,
                   [{assert, {{recovered, proposal}, true}}], {Self, Signer}),
    Block = block({?FIXTURE_ERA, 6}, Root, 501, {batch, [Tx]}),
    Hash = quod_simplex:block_hash(Block),
    Links = maps:from_list([{P, {self(), make_ref()}} || P <- pubs(Committee), P =/= Self]),
    Recovering = st(#{self => Self, id => Signer, validators => pubs(Committee),
        slot => 500, history_head => {500, element(3, Root)}, sync => unconfirmed,
        eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 500, 0}), conns => Links}),
    Leader = quod_simplex:leader(6, pubs(Committee)),
    try
        Retained = quod_simplex:dispatch(Leader, {propose, Block, []}, Recovering),
        ?assertEqual({none, false, false}, quod_simplex:test_round(6, Retained)),
        Ready = quod_simplex:test_state_set(sync, ready, Retained),
        Supported = quod_simplex:reconcile_head_progress(
            quod_simplex:dispatch(Leader, {propose, Block, []}, Ready)),
        ?assertEqual({Hash, false, false}, quod_simplex:test_round(6, Supported)),
        Complained = quod_simplex:on_progress_timeout({?FIXTURE_ERA, 6}, Supported),
        ?assertEqual({Hash, false, true}, quod_simplex:test_round(6, Complained)),
        ?assertEqual(1, quod_simplex:test_progress_counts(Complained))
    after flush_consensus_fixture_frames() end.

%% A retained leader proposal must be queued for validators that are not connected yet. The old live-link
%% filter omitted them entirely, so a recovered validator could advertise readiness but never receive the
%% proposal whose support was needed to complete notarization.
redrive_queues_proposal_for_disconnected_validators_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Tx = signed_tx(<<"t">>, <<"redrive-disconnected">>,
                   [{assert, {{recovered, redrive}, true}}], {A, IdA}),
    Block = block({?FIXTURE_ERA, 6}, quod_ledger:block_ref(blk(5, 495 + 5)), 501, {batch, [Tx]}),
    BH = quod_simplex:block_hash(Block),
    {Eng, []} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0})),
    S = st(#{self => A, id => IdA, validators => pubs(Committee),
             slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))}, eng => Eng, sync => ready}),
    Redriven = quod_simplex:test_redrive_head(6, BH, S),
    ?assertEqual({[], [], lists:sort([B, C, D]), lists:sort([B, C, D])},
                 quod_simplex:test_link_peers(Redriven)).

%% A validator that has a support certificate but lost the corresponding block asks one holder at a
%% time. The request itself is tiny; it must not fan a complete block out from every validator.
certified_block_request_targets_one_holder_test() ->
    Committee = [{A, IdA} | _] = committee(4),
    Tx = signed_tx(<<"t">>, <<"missing-block">>,
                   [{assert, {{recovered, block}, true}}], {A, IdA}),
    Block = block({?FIXTURE_ERA, 6}, quod_ledger:block_ref(blk(5, 495 + 5)), 501, {batch, [Tx]}),
    {Eng, _} = feed_shares(supports(Block, Committee, 3),
                           quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0})),
    Missing = st(#{self => A, id => IdA, validators => pubs(Committee),
                   slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))}, eng => Eng, sync => ready}),

    Requested = quod_simplex:reconcile_block_requests(Missing),
    {[], [], OutboxPeers, DialPeers} = quod_simplex:test_link_peers(Requested),
    ?assertEqual(1, length(OutboxPeers)),
    ?assertEqual(OutboxPeers, DialPeers),
    ?assertEqual(1, map_size(quod_simplex:test_block_requests(Requested))).

%% An empty finalizer can be newer than the selected proof in the material
%% archive. Its commit certificate must not suppress the existing exact-body
%% request: a history pull at the unchanged height cannot supply that body.
finalized_empty_body_recovery_at_unchanged_material_height_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = [{A, IdA}, {B, _} | _] = committee(4),
    Root = quod_ledger:block_ref(blk(5, 495 + 5)),
    Block = block({?FIXTURE_ERA, 6}, Root, 500, empty, 0),
    Hash = quod_simplex:block_hash(Block),
    {Eng, _} = feed_shares(supports(Block, Committee, 3) ++
                            commits(Block, Committee, 3),
                          quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 500, 0})),
    Missing = st(#{self => A, id => IdA, validators => pubs(Committee),
                   slot => 500, history_head => {500, element(3, Root)},
                   protocol_root => Root, eng => Eng, sync => ready}),
    ?assertNot(quod_simplex:may_vote(Missing)),
    Requested = quod_simplex:reconcile_block_requests(Missing),
    ?assertEqual(1, map_size(quod_simplex:test_block_requests(Requested))),
    Restored = quod_simplex:dispatch(B, {certified_block, Block, Hash}, Requested),
    ?assertEqual(0, map_size(quod_simplex:test_block_requests(Restored))),
    ?assert(quod_simplex:may_vote(Restored)),
    ?assertEqual({500, undefined}, quod_simplex:test_committed_store(Restored)).

%% Any active validator holding the exact block may answer the certified request, but an
%% authenticated non-member cannot use block recovery as an oracle or make the node queue large frames.
certified_block_request_is_committee_scoped_test() ->
    Committee = [{A, IdA}, {B, _} | _] = committee(4),
    Tx = signed_tx(<<"t">>, <<"serve-certified-block">>,
                   [{assert, {{recovered, served}, true}}], {A, IdA}),
    Block = block({?FIXTURE_ERA, 6}, quod_ledger:block_ref(blk(5, 495 + 5)), 501, {batch, [Tx]}),
    BH = quod_simplex:block_hash(Block),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0})),
    {Eng2, _} = feed_shares(supports(Block, Committee, 3), Eng1),
    Holder = st(#{self => B, validators => pubs(Committee), slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))},
                  eng => Eng2, sync => ready}),

    Answered = quod_simplex:dispatch(A, {block_request, 6, BH}, Holder),
    ?assertEqual({[], [], [A], [A]}, quod_simplex:test_link_peers(Answered)),
    Outsider = <<"not-a-validator">>,
    Ignored = quod_simplex:dispatch(Outsider, {block_request, 6, BH}, Holder),
    ?assertEqual({[], [], [], []}, quod_simplex:test_link_peers(Ignored)).

%% The responder need not be the original proposer. A quorum support certificate authenticates the exact
%% block hash; the receiver rechecks the bounded block and its transactions before putting it in the tree.
certified_block_from_non_leader_restores_finality_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Tx = signed_tx(<<"t">>, <<"non-leader-recovery">>,
                   [{assert, {{recovered, any_holder}, true}}], {A, IdA}),
    Block = block({?FIXTURE_ERA, 6}, quod_ledger:block_ref(blk(5, 495 + 5)), 501, {batch, [Tx]}),
    BH = quod_simplex:block_hash(Block),
    SupportShares = supports(Block, Committee, 3),
    {CertOnly, _} = feed_shares(SupportShares, quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0})),
    Requester = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))}, eng => CertOnly, sync => ready,
                     block_requests => #{{6, BH} => {1, 0}}}),
    Leader = quod_simplex:leader(6, pubs(Committee)),
    Sender = hd([Peer || {Peer, _} <- Peers, Peer =/= Leader]),

    Restored = quod_simplex:dispatch(Sender, {certified_block, Block, BH}, Requester),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Restored)),
    ?assertEqual(0, map_size(quod_simplex:test_block_requests(Restored))).

%% Certified recovery must retain DTX input without granting engine authority.
%% This pre-genesis structural fixture has no durable parent token: receipt
%% must stay unadmitted. Real-founded validation is covered in parent-progress.
certified_dtx_block_uses_phase_aware_recovery_test() ->
    Fixture = quod_ct:signed_atomic_fixture(#{}),
    Control = maps:get(vote_control, Fixture),
    {Ns, Anchor} = maps:get(target, Fixture),
    #{pubkey := Self} = Identity = maps:get(node_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    Era = quod_ledger:initial_era({Ns, Anchor}), Root = {Era, 0, Anchor},
    Block = block({Era, 1}, Root, 2, {batch, [{dtx, Control}]}, 0),
    BH = quod_simplex:block_hash(Block),
    {CertOnly, _} = feed_shares(
                      supports(Block, [{Self, Identity}], 1),
                      quod_simplex:eng_new(?DOMAIN, [Self],{Root, 1, 0})),
    S = st(#{ns => Ns, genesis_hash => Anchor,
             self => Self, id => Identity, validators => [Self],
             author_admissions => #{Self => Admission},
             dtx_projection => quod_atomic:initial_projection({Ns, Anchor}, 0),
             slot => 0, eng => CertOnly, sync => ready,
             block_requests => #{{1, BH} => {1, 0}}}),

    Recovered = quod_simplex:dispatch(
                  Self, {certified_block, Block, BH}, S),
    ?assertMatch({none, none, {offered, _, #block{payload = {batch, [{dtx, _}]}}},
                  none, undefined},
                 quod_simplex:test_dtx_round(1, Recovered)),
    ?assertEqual(0, map_size(quod_simplex:test_block_requests(Recovered))).

certified_block_response_requires_outstanding_request_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Tx = signed_tx(<<"t">>, <<"unsolicited-certified-block">>,
                   [{assert, {{recovered, requested_only}, true}}], {A, IdA}),
    Block = block({?FIXTURE_ERA, 6}, quod_ledger:block_ref(blk(5, 495 + 5)), 501, {batch, [Tx]}),
    BH = quod_simplex:block_hash(Block),
    SupportShares = supports(Block, Committee, 3),
    {CertOnly, _} = feed_shares(SupportShares,
                                quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0})),
    S = st(#{self => A, id => IdA, validators => pubs(Committee),
             slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))}, eng => CertOnly, sync => ready}),
    Sender = element(1, hd(Peers)),

    Ignored = quod_simplex:dispatch(Sender, {certified_block, Block, BH}, S),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6, Ignored)),
    ?assertEqual(1, maps:get(missing_certified_blocks,
                            quod_simplex:stats_map(Ignored))).

%% Supporting one proposal does not bind the later final vote to that losing hash. Once a different block
%% has the unique support quorum, this validator must recover it and join finality; otherwise one leader
%% equivocation can remove an honest validator from the only completable commit camp.
certified_block_recovery_accepts_losing_local_support_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader = quod_simplex:leader(6, Validators),
    {Leader, LeaderId} = lists:keyfind(Leader, 1, Committee),
    [{Self, SelfId} | _] = [Pair || {Pub, _} = Pair <- Committee, Pub =/= Leader],
    OtherValidators = [Pair || {Pub, _} = Pair <- Committee, Pub =/= Self],
    Losing = block(
               {?FIXTURE_ERA, 6}, quod_ledger:block_ref(blk(5, 495 + 5)), 501,
               {batch,
                [signed_tx(<<"t">>, <<"losing-support">>,
                           [{assert, {{proposal, losing}, true}}],
                           {Leader, LeaderId})]}),
    Winning = block(
                {?FIXTURE_ERA, 6}, quod_ledger:block_ref(blk(5, 495 + 5)), 501,
                {batch,
                 [signed_tx(<<"t">>, <<"winning-support">>,
                            [{assert, {{proposal, winning}, true}}],
                            hd(OtherValidators))]}),
    WinningHash = quod_simplex:block_hash(Winning),
    {ok, WinningCert} = quod_simplex:form_cert(?DOMAIN,
                          support, {?FIXTURE_ERA, 6}, WinningHash,
                          supports(Winning, OtherValidators, 3), Validators),
    Initial = st(#{self => Self, id => SelfId, validators => Validators,
                   slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))}, eng => quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(5, 500)), 500, 0}), sync => ready}),
    SupportedLosing = quod_simplex:dispatch(
                        Leader, {propose, Losing, []}, Initial),
    LosingHash = quod_simplex:block_hash(Losing),
    ?assertEqual({LosingHash, false, false},
                 quod_simplex:test_round(6, SupportedLosing)),
    HasCertificate = quod_simplex:dispatch(Leader, {cert, WinningCert}, SupportedLosing),
    Requested = quod_simplex:reconcile_block_requests(HasCertificate),
    Sender = element(1, hd(OtherValidators)),

    Restored = quod_simplex:dispatch(
                 Sender, {certified_block, Winning, WinningHash}, Requested),
    ?assertEqual({LosingHash, true, false}, quod_simplex:test_round(6, Restored)),
    ?assertEqual(0, map_size(quod_simplex:test_block_requests(Restored))).

certified_block_hash_mismatch_is_rejected_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Tx = signed_tx(<<"t">>, <<"certified-good">>,
                   [{assert, {{recovered, correct}, true}}], {A, IdA}),
    Block = block({?FIXTURE_ERA, 6}, quod_ledger:block_ref(blk(5, 495 + 5)), 501, {batch, [Tx]}),
    BH = quod_simplex:block_hash(Block),
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN,
                   support, {?FIXTURE_ERA, 6}, BH, supports(Block, Committee, 3), pubs(Committee)),
    Different = block({?FIXTURE_ERA, 6}, quod_ledger:block_ref(blk(5, 495 + 5)), 501, {batch, [Tx]}, 1),
    {WithCert, _} = quod_simplex:eng_offer(
                     {cert, Cert}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0})),
    S = st(#{self => A, id => IdA, validators => pubs(Committee),
             slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))}, eng => WithCert, sync => ready,
             block_requests => #{{6, BH} => {1, 0}}}),
    Rejected = quod_simplex:dispatch(element(1, hd(Peers)),
                                     {certified_block, Different, BH}, S),
    ?assertEqual(S, Rejected),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6, Rejected)).

%% Recovery metrics count signatures carried by a verified certificate even when individual share frames
%% were not received, and expose the exact "certificate present, block absent" condition.
recovery_stats_include_certificate_evidence_test() ->
    Committee = [{A, _} | _] = committee(4),
    Block = blk(6, 495 + 6),
    BH = quod_simplex:block_hash(Block),
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN,
                   support, {?FIXTURE_ERA, 6}, BH, supports(Block, Committee, 3), pubs(Committee)),
    {CertOnly, _} = quod_simplex:eng_offer(
                      {cert, Cert}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0})),
    Stats = quod_simplex:stats_map(
              st(#{self => A, validators => pubs(Committee), slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))},
                   eng => CertOnly, sync => ready})),
    ?assertEqual(3, maps:get(head_support_votes, Stats)),
    ?assertEqual(0, maps:get(head_commit_votes, Stats)),
    ?assertEqual(0, maps:get(head_complaint_votes, Stats)),
    ?assertEqual(1, maps:get(missing_certified_blocks, Stats)).

%% Recovery resumes this owner's observed notarization edge, never infers a
%% new decision from an installed tree. Peer complaints do not choose its vote.
resume_observed_notarization_after_readiness_test_() ->
    [{atom_to_list(Kind) ++ "-complaints-" ++ integer_to_list(Count),
      {spawn, fun() -> resume_observed_notarization(Kind, Count) end}}
     || Kind <- [content, membership], Count <- [0, 3, 4]].

resume_observed_notarization(Kind, ComplaintCount) ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = [{Self, Signer} | Peers] = committee(10),
    Root = quod_ledger:block_ref(blk(5, 495 + 5)),
    Payload = case Kind of
        content -> {batch, [tx([])]};
        membership -> {Added, _} = id(), {batch, [tx([pa(Added)])]}
    end,
    Block = block({?FIXTURE_ERA, 6}, Root, 501, Payload),
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 500, 0}),
    Base = st(#{self => Self, id => Signer, validators => pubs(Committee),
                slot => 500, history_head => {500, element(3, Root)},
                eng => E0, sync => unconfirmed}),
    Items = [{block, Block} | [{share, Sh} || Sh <- supports(Block, Peers, 7)]],
    Complaints = [{share, Sh} || Sh <- era_shares(complaint, Block, take(ComplaintCount, Peers))],
    Paused = quod_simplex:engine_step(Items ++ Complaints, Base),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6, Paused)),
    ?assertEqual(Paused, quod_simplex:resume_ready_rounds(Paused)),
    %% A passive archive/tree capture contains no owner decision edge.
    TreeOnly = lists:foldl(fun(Item, E) -> element(1, quod_simplex:eng_offer(Item, E)) end,
                          E0, Items ++ Complaints),
    Unobserved = quod_simplex:test_state_set(sync, ready,
                   quod_simplex:test_state_set(eng, TreeOnly, Base)),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6,
                        quod_simplex:resume_ready_rounds(Unobserved))),
    Ready = quod_simplex:test_state_set(sync, ready, Paused),
    Resumed = quod_simplex:settle_readiness(Paused, Ready),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Resumed)),
    ?assertEqual(Resumed, quod_simplex:resume_ready_rounds(Resumed)),
    ?assertEqual(500, element(1, quod_simplex:test_committed_store(Resumed))),
    flush_consensus_fixture_frames().

resume_multiple_observed_notarization_edges_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = [{Self, Signer} | Peers] = committee(4),
    Root = quod_ledger:block_ref(blk(5, 495 + 5)),
    Base = st(#{self => Self, id => Signer, validators => pubs(Committee),
                slot => 500, history_head => {500, element(3, Root)},
                eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 500, 0}),
                sync => unconfirmed}),
    Paused = lists:foldl(fun(View, Owner) ->
        B = blk(View, 495 + View),
        quod_simplex:engine_step([{block, B} | [{share, Sh} || Sh <- supports(B, Peers, 3)]], Owner)
    end, Base, [6, 7]),
    Resumed = quod_simplex:settle_readiness(Paused, quod_simplex:test_state_set(sync, ready, Paused)),
    lists:foreach(fun(V) ->
        ?assertEqual({none, false, false}, quod_simplex:test_round(V, Paused)),
        ?assertEqual({none, true, false}, quod_simplex:test_round(V, Resumed))
    end, [6, 7]),
    flush_consensus_fixture_frames().

%% A restart reloads the validator's own final-vote decision before recovery sees network evidence. A
%% notarized block therefore cannot recruit a validator that complaint-signed this slot before crashing.
restart_preserves_complaint_latch_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    Dir = filename:join("/tmp", "quod_simplex_vote_restart_" ++
                                integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           <<"t">>, ?DOMAIN, Dir),
        Inbound = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
                    D => {Sink, make_ref()}},
        Readiness = voting_readiness([B, C, D], Sink, 5),
        EmptyEng = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0}),
        BeforeCrash = st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))}, eng => EmptyEng, sync => ready,
                           signing_journal => Journal0,
                           inbound_conns => Inbound, peer_readiness => Readiness,
                           head_progress => {?FIXTURE_ERA, 6, awaiting_proposal}}),
        Complained = quod_simplex:on_progress_timeout({?FIXTURE_ERA, 6}, BeforeCrash),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, Complained)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Complained)),

        Block = blk(6, 495 + 6),
        {E1, _} = quod_simplex:eng_offer(
                    {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0})),
        {Notarized, _} = feed_shares(supports(Block, Committee, 3), E1),
        {ok, Journal1} = quod_signing_journal:recover(
                           <<"t">>, ?DOMAIN, Dir),
        Restarted = quod_simplex:restore_signing_state(
                      st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))}, eng => Notarized, sync => ready,
                           signing_journal => Journal1})),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, Restarted)),
        AfterRestart = quod_simplex:resume_ready_rounds(Restarted),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, AfterRestart)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(AfterRestart))
    after
        exit(Sink, kill),
        file:del_dir_r(Dir)
    end.

%% Supporting a block transfers custody of its exact canonical bytes to the
%% existing anti-equivocation journal. A restart restores both the body and
%% this validator's share through the ordinary engine, and the durable latch
%% keeps a restarted leader from proposing a different body for that slot.
restart_restores_supported_block_and_prevents_competing_proposal_test() ->
    Committee = [{A, IdA} | _] = committee(4),
    Block = blk(6, 495 + 6),
    BH = quod_simplex:block_hash(Block),
    Dir = filename:join(
            "/tmp", "quod_simplex_support_restart_" ++
                    binary_to_list(
                      binary:encode_hex(crypto:strong_rand_bytes(8)))),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           <<"t">>, ?DOMAIN, Dir),
        {ok, Journal1} = quod_signing_journal:record_support(
                           Journal0, Block),
        ok = quod_signing_journal:close(Journal1),
        {ok, Journal2} = quod_signing_journal:recover(
                           <<"t">>, ?DOMAIN, Dir),
        EmptyEng = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0}),
        Loaded = quod_simplex:restore_signing_state(
                   st(#{self => A, id => IdA,
                        consensus_domain => ?DOMAIN,
                        validators => pubs(Committee), slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))},
                        eng => EmptyEng,
                        sync => unconfirmed,
                        signing_journal => Journal2})),
        ?assertEqual({BH, false, false},
                     quod_simplex:test_round(6, Loaded)),
        ?assertEqual(blocked, quod_simplex:proposal_slot(Loaded)),
        {_, _, _, _, undefined} = quod_simplex:test_dtx_round(6, Loaded),

        Restored = quod_simplex:restore_signing_engine(Loaded),
        {_, _, _, _, Block} = quod_simplex:test_dtx_round(6, Restored),
        ?assertMatch(#{share_buckets := 1, seen_votes := 1},
                     quod_simplex:test_engine_pool_sizes(Restored)),
        ?assertEqual(blocked, quod_simplex:proposal_slot(Restored)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Restored))
    after
        file:del_dir_r(Dir)
    end.

%% A commit signed on the owner's notarization edge survives restart.
%% Later complaints cannot replace its same-view durable final decision.
restart_preserves_commit_latch_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Block = blk(6, 495 + 6),
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), {quod_ledger:block_ref(blk(5, 500)), 500, 0}),
    {E1, _} = quod_simplex:eng_offer({block, Block}, E0),
    SupportShares = supports(Block, Peers, 3),
    {Notarized, _} = feed_shares(SupportShares, E1),
    Dir = filename:join("/tmp", "quod_simplex_commit_restart_" ++
                                integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           <<"t">>, ?DOMAIN, Dir),
        BeforeCrash = st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))}, eng => E0, sync => ready,
                           signing_journal => Journal0}),
        Committed = quod_simplex:engine_step(
            [{block, Block} | [{share, Sh} || Sh <- SupportShares]], BeforeCrash),
        ?assertEqual({none, true, false}, quod_simplex:test_round(6, Committed)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Committed)),

        Complaints = [quod_simplex:make_share(?DOMAIN, complaint, {?FIXTURE_ERA, 6}, none, Id)
                      || {_Pub, Id} <- take(2, Peers)],
        {WithComplaints, _} = feed_shares(Complaints, Notarized),
        {ok, Journal1} = quod_signing_journal:recover(
                           <<"t">>, ?DOMAIN, Dir),
        Restarted = quod_simplex:restore_signing_state(
                      st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 500, history_head => {500, element(3, quod_ledger:block_ref(blk(5, 495 + 5)))}, eng => WithComplaints, sync => ready,
                           signing_journal => Journal1})),
        ?assertEqual({none, true, false}, quod_simplex:test_round(6, Restarted)),
        StillCommitted = quod_simplex:resume_ready_rounds(Restarted),
        ?assertEqual({none, true, false}, quod_simplex:test_round(6, StillCommitted)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(StillCommitted))
    after
        file:del_dir_r(Dir)
    end.

%% An effect transaction crosses a second hard crash boundary after the
%% effect journal has handed it to Simplex: the exact signed submission must
%% be datasync'd in the signing journal before custody is acknowledged.  A
%% restart restores those bytes, rather than rebuilding or re-signing the
%% transaction, so the original OutcomeRef remains the only public identity.
restart_restores_exact_effect_custody_test() ->
    Ns = <<"t">>,
    Anchor = <<0:256>>,
    {Author, Identity} = id(),
    Admission = quod_simplex:test_author_admission(Author),
    EffectId = crypto:hash(sha256, <<"effect-restart-id">>),
    TargetAnchor = crypto:hash(sha256, <<"effect-restart-target">>),
    RequestDigest = crypto:hash(sha256, <<"effect-restart-request">>),
    PreparedDigest = crypto:hash(sha256, <<"effect-restart-prepared">>),
    {ok, Goal} = quod_durable_term:encode_goal(
                   {create_ontology, <<"restart:created">>, []}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Effect = {quod_direct_effect, 2, local_durable,
              ontology_lifecycle, create, EffectId, Author,
              {node, Author}, {<<"restart:created">>, TargetAnchor},
              RequestDigest, PreparedDigest},
    Unsigned = quod_transaction:bind_id(
                 {Ns, Anchor},
                 #transaction{origin = {Ns, Anchor},
                              proof_id = crypto:hash(
                                           sha256, <<"effect-proof">>),
                              plan_digest = crypto:hash(
                                              sha256, <<"effect-plan">>),
                              goal = Goal, result = Result,
                              diff = [], read_check = #{},
                              effects = [Effect], author = Author,
                              author_seq = 1, submitted_at = 1234,
                              sig = none}),
    {ok, Signed, Submission} = quod_transaction:sign_submission(
                                 {Ns, Anchor, Admission},
                                 Unsigned, Identity),
    TxId = Signed#transaction.tx_id,
    SubmissionId = quod_transaction:submission_id(Submission),
    Dir = filename:join(
            "/tmp", "quod_effect_custody_restart_" ++
                        integer_to_list(
                          erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           Ns, ?DOMAIN, Dir),
        {ok, Journal1} = quod_signing_journal:record_transaction(
                           Journal0, Signed, Submission, ready),
        ok = quod_signing_journal:close(Journal1),

        {ok, Journal2} = quod_signing_journal:recover(
                           Ns, ?DOMAIN, Dir),
        Restarted = quod_simplex:restore_signing_state(
                      st(#{ns => Ns, self => Author, id => Identity,
                           validators => [Author],
                           author_admissions => #{Author => Admission},
                           signing_journal => Journal2,
                           sync => ready})),
        [{SubmissionId, 1, RestoredSubmission, ready,
          _NoExpiry, 0}] = quod_simplex:test_custody(Restarted),
        ?assertEqual(Submission, RestoredSubmission),
        ?assertMatch(
           #{TxId := #{admission := Admission, sequence := 1}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Restarted))),

        %% Live commit retirement is keyed by semantic TxId, not by the
        %% shorter transport submission id.  It must clear custody in the
        %% same turn even when no ordinary custody/relay waiter exists.
        Committed = quod_simplex:test_resolve_committed_submissions(
                      {batch, [Signed]}, 2, Restarted),
        ?assertEqual(
           #{},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Committed))),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Committed))
    after
        file:del_dir_r(Dir)
    end.

%% Dormant source custody is process-owned until the proof either activates it
%% or explicitly asks the same custody owner to cancel it. If that proof dies,
%% its exact monitor starts one cancellation coordinator from the retained
%% signed Submission; no timeout or second cleanup registry is involved.
dormant_operation_owner_down_starts_exact_cancellation_test() ->
    {Dir, Fixture, Owner, TxId, S1} =
        registered_dormant_operation("owner_down"),
    Parent = self(),
    Start = cancellation_test_starter(Parent),
    #{dormant_owner := {Owner, OwnerMonitor},
      placement := dormant} = quod_simplex:test_custody_owner(TxId, S1),
    try
        exit(Owner, kill),
        receive
            {'DOWN', OwnerMonitor, process, Owner, _} -> ok
        after 1000 -> error(missing_dormant_owner_down)
        end,
        {true, Cancelling} =
            quod_simplex:test_restart_dormant_custody_owner(
              OwnerMonitor, Owner, S1, Start),
        CancelPid = receive
            {cancellation_started, Submission, Pid, _CancelMonitor} ->
                ?assertEqual(maps:get(submission, Fixture), Submission),
                ?assert(is_process_alive(Pid)),
                Pid
        after 1000 -> error(cancellation_not_started)
        end,
        ?assertMatch(
           #{placement := cancelling, dormant_owner := none},
           quod_simplex:test_custody_owner(TxId, Cancelling)),
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid, Cancelling),
        ?assertEqual(not_found,
                     quod_simplex:test_custody_owner(TxId, Settled)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        file:del_dir_r(Dir)
    end.

%% The stored proof-worker PID owns the dormant transition, and the spawned
%% cancellation PID alone may retire it. Knowing the semantic TxId is not a
%% capability to bind, activate, or erase the durable signing row.
dormant_operation_transitions_require_exact_process_owner_test() ->
    {Dir, _Fixture, Owner, TxId, Dormant} =
        registered_dormant_operation("wrong_owner"),
    Intruder = spawn(fun validation_owner/0),
    Parent = self(),
    Start = cancellation_test_starter(Parent),
    try
        ?assertMatch(
           {error, not_in_charge, _},
           quod_simplex:test_activate_dormant_transaction(
             TxId, {Intruder, make_ref()}, Dormant)),
        ?assertMatch(
           {error, not_in_charge, _},
           quod_simplex:test_start_dormant_transaction_cancellation(
             TxId, Intruder, Dormant, Start)),
        ?assertMatch(
           {error, not_in_charge, _},
           quod_simplex:test_cancel_dormant_transaction(
             TxId, Owner, Dormant)),
        ?assertMatch(
           #{TxId := #{state := dormant}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Dormant))),
        ?assertMatch(
           #{placement := dormant, dormant_owner := {Owner, _}},
           quod_simplex:test_custody_owner(TxId, Dormant)),

        {ok, Cancelling} =
            quod_simplex:test_start_dormant_transaction_cancellation(
              TxId, Owner, Dormant, Start),
        CancelPid = receive
            {cancellation_started, _Submission, Pid, _Monitor} -> Pid
        after 1000 -> error(exact_owner_cancellation_not_started)
        end,
        ?assertMatch(
           {error, not_in_charge, _},
           quod_simplex:test_cancel_dormant_transaction(
             TxId, Intruder, Cancelling)),
        ?assertMatch(
           #{TxId := #{state := dormant}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Cancelling))),
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid, Cancelling),
        ?assertEqual(not_found,
                     quod_simplex:test_custody_owner(TxId, Settled)),
        ?assertEqual(
           #{}, quod_signing_journal:pending_transactions(
                  quod_simplex:test_signing_journal(Settled))),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        ensure_process_stopped(Intruder),
        file:del_dir_r(Dir)
    end.

%% An admission generation change makes every old source signature unusable,
%% but it does not prove that the remote target forgot its private operation
%% row. Every volatile source placement therefore converges on the same sole
%% cancellation owner; the durable signing row survives until that owner
%% receives a correlated terminal target reply.
admission_change_cancels_remote_operation_from_every_placement_test() ->
    lists:foreach(
      fun(PlacementKind) ->
          {Dir, Fixture, Owner, TxId, Dormant} =
              registered_dormant_operation(
                "admission_" ++ atom_to_list(PlacementKind)),
          #{pubkey := Author} = maps:get(source_identity, Fixture),
          OldAdmission = maps:get(admission, Fixture),
          NewAdmission = crypto:hash(
                           sha256,
                           term_to_binary(
                             {new_admission, PlacementKind},
                             [deterministic])),
          try
              Placed = operation_custody_placement(
                         PlacementKind, Owner, TxId, Dormant),
              BeforeState = case PlacementKind of
                                dormant -> dormant;
                                _ -> ready
                            end,
              ?assertMatch(
                 #{TxId := #{state := BeforeState}},
                 quod_signing_journal:pending_transactions(
                   quod_simplex:test_signing_journal(Placed))),
              Cancelling = quod_simplex:test_retire_changed_admissions(
                             #{Author => OldAdmission},
                             #{Author => NewAdmission}, Placed),
              {Reconciled, _PendingTransition} =
                  quod_simplex:test_reconcile_signing_state(
                    quod_simplex:test_set_author_admissions(
                      #{Author => NewAdmission}, Cancelling)),
              #{placement := cancelling,
                cancellation_owner := CancelPid} =
                  quod_simplex:test_custody_owner(TxId, Reconciled),
              ?assert(is_process_alive(CancelPid)),
              ?assertEqual(
                 0, maps:get(custody_ready,
                             quod_simplex:stats_map(Reconciled))),
              ?assertMatch(
                 #{TxId := #{state := BeforeState}},
                 quod_signing_journal:pending_transactions(
                   quod_simplex:test_signing_journal(Reconciled))),
              {ok, Settled} =
                  quod_simplex:test_cancel_dormant_transaction(
                    TxId, CancelPid, Reconciled),
              ?assertEqual(
                 #{}, quod_signing_journal:pending_transactions(
                        quod_simplex:test_signing_journal(Settled))),
              ok = quod_signing_journal:close(
                     quod_simplex:test_signing_journal(Settled))
          after
              ensure_process_stopped(Owner),
              file:del_dir_r(Dir)
          end
      end, [dormant, ready, local, relay]).

operation_custody_placement(dormant, _Owner, _TxId, S) ->
    S;
operation_custody_placement(Kind, Owner, TxId, Dormant) ->
    {ok, Ready} = quod_simplex:test_activate_dormant_transaction(
                    TxId, {Owner, make_ref()}, Dormant),
    case Kind of
        ready -> Ready;
        local ->
            {ok, Local} = quod_simplex:test_place_transaction_custody(
                            TxId, {local, 2, <<241:256>>}, Ready),
            Local;
        relay ->
            {ok, Relay} = quod_simplex:test_place_transaction_custody(
                            TxId,
                            {relay, <<242:128>>, <<243:256>>, 2, <<244:256>>},
                            Ready),
            Relay
    end.

%% Activation and owner death are serialized by Simplex. Whichever message is
%% handled first decides the only legal next state: activation removes the
%% monitor, while a consumed DOWN moves custody to cancelling and makes later
%% activation fail closed.
dormant_operation_activation_vs_owner_down_is_serialized_test() ->
    {Dir1, _Fixture1, Owner1, TxId1, Dormant1} =
        registered_dormant_operation("activate_first"),
    #{dormant_owner := {Owner1, OwnerMonitor1}} =
        quod_simplex:test_custody_owner(TxId1, Dormant1),
    NeverStart =
        fun(_Ns, _Submission) -> error(unexpected_cancellation_start) end,
    try
        {ok, Ready} = quod_simplex:test_activate_dormant_transaction(
                        TxId1, {Owner1, make_ref()}, Dormant1),
        ?assertMatch(#{placement := ready, dormant_owner := none},
                     quod_simplex:test_custody_owner(TxId1, Ready)),
        exit(Owner1, kill),
        ?assertEqual(
           false,
           quod_simplex:test_restart_dormant_custody_owner(
             OwnerMonitor1, Owner1, Ready, NeverStart)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Ready))
    after
        ensure_process_stopped(Owner1),
        file:del_dir_r(Dir1)
    end,

    {Dir2, _Fixture2, Owner2, TxId2, Dormant2} =
        registered_dormant_operation("down_first"),
    Parent = self(),
    Start = cancellation_test_starter(Parent),
    #{dormant_owner := {Owner2, OwnerMonitor2}} =
        quod_simplex:test_custody_owner(TxId2, Dormant2),
    try
        exit(Owner2, kill),
        receive
            {'DOWN', OwnerMonitor2, process, Owner2, _} -> ok
        after 1000 -> error(missing_down_first_owner_down)
        end,
        {true, Cancelling} =
            quod_simplex:test_restart_dormant_custody_owner(
              OwnerMonitor2, Owner2, Dormant2, Start),
        CancelPid2 = receive
            {cancellation_started, _Submission, Pid, _Monitor} -> Pid
        after 1000 -> error(down_first_cancellation_not_started)
        end,
        ?assertMatch(
           {error, already_active, _},
           quod_simplex:test_activate_dormant_transaction(
              TxId2, {self(), make_ref()}, Cancelling)),
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId2, CancelPid2, Cancelling),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner2),
        file:del_dir_r(Dir2)
    end.

%% A cancellation worker owns no durable truth. If it crashes, its exact
%% monitor recreates that one worker from the same retained Submission, and an
%% explicit concurrent cancellation request observes the existing owner
%% instead of spawning another one.
dormant_operation_cancellation_worker_crash_restarts_once_test() ->
    {Dir, Fixture, Owner, TxId, Dormant} =
        registered_dormant_operation("cancel_restart"),
    Parent = self(),
    Start = cancellation_test_starter(Parent),
    #{dormant_owner := {Owner, OwnerMonitor}} =
        quod_simplex:test_custody_owner(TxId, Dormant),
    try
        exit(Owner, kill),
        receive
            {'DOWN', OwnerMonitor, process, Owner, _} -> ok
        after 1000 -> error(missing_restart_owner_down)
        end,
        {true, Cancelling1} =
            quod_simplex:test_restart_dormant_custody_owner(
              OwnerMonitor, Owner, Dormant, Start),
        {CancelPid1, CancelMonitor1} =
            receive
                {cancellation_started, Submission1, Pid1, Monitor1} ->
                    ?assertEqual(maps:get(submission, Fixture), Submission1),
                    {Pid1, Monitor1}
            after 1000 -> error(first_cancellation_not_started)
            end,
        exit(CancelPid1, kill),
        receive
            {'DOWN', CancelMonitor1, process, CancelPid1, _} -> ok
        after 1000 -> error(missing_cancellation_worker_down)
        end,
        {true, Cancelling2} =
            quod_simplex:test_restart_dormant_custody_owner(
              CancelMonitor1, CancelPid1, Cancelling1, Start),
        CancelPid2 = receive
            {cancellation_started, Submission2, Pid2, _Monitor2} ->
                ?assertEqual(maps:get(submission, Fixture), Submission2),
                ?assert(CancelPid1 =/= Pid2),
                Pid2
        after 1000 -> error(replacement_cancellation_not_started)
        end,
        {ok, Same} = quod_simplex:test_start_dormant_transaction_cancellation(
                       TxId, CancelPid2, Cancelling2, Start),
        ?assertEqual(quod_simplex:test_custody(Cancelling2),
                     quod_simplex:test_custody(Same)),
        receive
            {cancellation_started, _, _, _} ->
                error(duplicate_cancellation_owner)
        after 0 -> ok
        end,
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid2, Same),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        file:del_dir_r(Dir)
    end.

%% A hard restart has no proof-worker PID to monitor. A persisted dormant row
%% therefore reconstructs directly as cancelling, never as an inert tombstone.
restart_reconstructs_dormant_operation_cancellation_owner_test() ->
    {Dir, Fixture, Owner, TxId, Dormant} =
        registered_dormant_operation("restart_cancel"),
    {Ns, Anchor} = maps:get(origin, Fixture),
    Identity = #{pubkey := Author} = maps:get(source_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    #{dormant_owner := {Owner, OwnerMonitor}, placement := dormant} =
        quod_simplex:test_custody_owner(TxId, Dormant),
    try
        ?assertMatch(
           #{TxId := #{state := dormant}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Dormant))),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Dormant)),
        exit(Owner, kill),
        receive
            {'DOWN', OwnerMonitor, process, Owner, _} -> ok
        after 1000 -> error(missing_restart_registration_owner_down)
        end,
        {ok, Journal} = quod_signing_journal:recover(Ns, ?DOMAIN, Dir),
        NewAdmission = crypto:hash(
                         sha256,
                         term_to_binary(
                           {restart_new_admission, Admission},
                           [deterministic])),
        BeforeRestore = st(#{ns => Ns, genesis_hash => Anchor,
                             self => Author, id => Identity,
                             validators => [Author],
                             author_admissions => #{Author => NewAdmission},
                             signing_journal => Journal, sync => ready,
                             eng => root_engine(0)}),
        {Reconciled, _PendingTransition} =
            quod_simplex:test_reconcile_signing_state(BeforeRestore),
        ?assertMatch(
           #{TxId := #{admission := Admission, state := dormant}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Reconciled))),
        Restored = quod_simplex:restore_signing_state(Reconciled),
        #{placement := cancelling, dormant_owner := none,
          cancellation_owner := CancelPid} =
            quod_simplex:test_custody_owner(TxId, Restored),
        ?assertMatch(
           #{TxId := #{admission := Admission, state := dormant}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Restored))),
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid, Restored),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        file:del_dir_r(Dir)
    end.

%% A target-bound operation that was ready under an earlier admission cannot
%% re-enter consensus after re-admission. Recovery still verifies its exact old
%% signature, but restores it under cancellation rather than the ready queue.
restart_with_changed_admission_cancels_ready_operation_test() ->
    {Dir, Fixture, Owner, TxId, Dormant} =
        registered_dormant_operation("restart_ready_new_admission"),
    {Ns, Anchor} = maps:get(origin, Fixture),
    Identity = #{pubkey := Author} = maps:get(source_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    try
        {ok, Ready} = quod_simplex:test_activate_dormant_transaction(
                        TxId, {Owner, make_ref()}, Dormant),
        ?assertMatch(
           #{TxId := #{state := ready}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Ready))),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Ready)),
        exit(Owner, kill),
        {ok, Journal} = quod_signing_journal:recover(Ns, ?DOMAIN, Dir),
        NewAdmission = crypto:hash(
                         sha256,
                         term_to_binary(
                           {restart_ready_new_admission, Admission},
                           [deterministic])),
        BeforeRestore = st(#{ns => Ns, genesis_hash => Anchor,
                             self => Author, id => Identity,
                             validators => [Author],
                             author_admissions => #{Author => NewAdmission},
                             signing_journal => Journal, sync => ready,
                             eng => root_engine(0)}),
        {Reconciled, _PendingTransition} =
            quod_simplex:test_reconcile_signing_state(BeforeRestore),
        Restored = quod_simplex:restore_signing_state(Reconciled),
        #{placement := cancelling,
          cancellation_owner := CancelPid} =
            quod_simplex:test_custody_owner(TxId, Restored),
        ?assertEqual(
           0, maps:get(custody_ready, quod_simplex:stats_map(Restored))),
        ?assertMatch(
           #{TxId := #{admission := Admission, state := ready}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Restored))),
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid, Restored),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        file:del_dir_r(Dir)
    end.

%% Dormant/cancelling custody is a prerequisite lifecycle, not consensus-lane
%% work. Lane retirement and catch-up exclusion must preserve it rather than
%% silently enqueueing the source claim before its target prerequisite exists.
dormant_operation_is_not_released_by_lane_or_catchup_reconciliation_test() ->
    {Dir, _Fixture, Owner, TxId, Dormant} =
        registered_dormant_operation("lane_reconcile"),
    try
        LaneRetired = quod_simplex:test_mark_custody_lane_ready(Dormant),
        ?assertMatch(#{placement := dormant},
                     quod_simplex:test_custody_owner(TxId, LaneRetired)),
        Recovered = quod_simplex:test_settle_recovery_submissions([], LaneRetired),
        ?assertMatch(#{placement := dormant},
                     quod_simplex:test_custody_owner(TxId, Recovered)),
        Parent = self(),
        Start = cancellation_test_starter(Parent),
        {ok, Cancelling} =
            quod_simplex:test_start_dormant_transaction_cancellation(
              TxId, Owner, Recovered, Start),
        CancelPid = receive
            {cancellation_started, _Submission, Pid, _Monitor} -> Pid
        after 1000 -> error(lane_reconcile_cancellation_not_started)
        end,
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid, Cancelling),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        file:del_dir_r(Dir)
    end.

%% Catch-up must retire the same durable signing row as a live commit. Merely
%% removing the volatile custody record would let the next restart restore and
%% re-drive an effect transaction that is already in certified history.
catchup_commit_retires_effect_signing_custody_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = #{identity := {Ns, Anchor} = Binding, signer := Signer,
          admission := Admission, era := Era, projection := P0} =
        quod_ct:protocol_fixture(<<"effect:catchup-retirement">>),
    Author = maps:get(pubkey, Signer),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Root = maps:get(protocol_root, P0),
    {Signed, Submission} = effect_submission_fixture(Ns, Anchor, Admission, 1, Author, Signer),
    TxId = Signed#transaction.tx_id,
    Block = block({Era, 1}, Root, 2, {batch, [Signed]}, 1),
    Entry = quod_ledger:entry(2, Block, quod_ct:protocol_certificate(Block, F)),
    Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
    Dir = relay_store_dir("effect_catchup_retirement"),
    try
        {ok, Journal0} = quod_signing_journal:initialize(Ns, Domain, Dir),
        {ok, Journal1} = quod_signing_journal:record_transaction(
                           Journal0, Signed, Submission, ready),
        {ok, Store0} = quod_ledger_store:open(Ns, Dir),
        {ok, Store1} = quod_ledger_store:append(Store0, {none, [Genesis]}),
        {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
        {ok, Projection, genesis} = quod_ct:history_advance(Binding, Genesis,
            quod_simplex:history_projection(Binding), Index),
        {ok, Group} = quod_ct:history_group(Binding, Entry, Projection, Index),
        Restored = quod_simplex:restore_signing_state(
            quod_simplex:test_install_projection(Projection,
                st(#{ns => Ns, genesis_hash => Anchor, consensus_domain => Domain,
                     self => Author, id => Signer, validators => [Author],
                     signing_journal => Journal1, store => Store1, phase_index => Index,
                     eng => quod_simplex:eng_new(Domain, [Author], {Root, 1, 0}),
                     archive_tip => {Root, 0}, slot => 1, last_applied => 1,
                     sync => {pulling, self()}}))),
        ?assertMatch(#{TxId := #{}}, quod_signing_journal:pending_transactions(
            quod_simplex:test_signing_journal(Restored))),
        {Recovered, ok} = quod_simplex:test_apply_catchup_window(
            {recovery, self()}, Group, Restored),
        ?assertEqual([], quod_simplex:test_custody(Recovered)),
        Journal2 = quod_simplex:test_signing_journal(Recovered),
        ?assertEqual(#{}, quod_signing_journal:pending_transactions(Journal2)),
        ok = quod_signing_journal:close(Journal2),
        {ok, Reopened} = quod_signing_journal:recover(Ns, Domain, Dir),
        ?assertEqual(#{}, quod_signing_journal:pending_transactions(Reopened)),
        ok = quod_signing_journal:close(Reopened),
        {2, Store2} = quod_simplex:test_committed_store(Recovered),
        ?assertEqual({ok, Entry}, quod_ledger_store:read_at(Store2, 2)),
        ok = quod_ledger_store:close(Store2),
        ok = quod_dtx_phase_index:close(Index)
    after file:del_dir_r(Dir) end.

%% More than one full journal capacity of sequential effect commits must not
%% accumulate signing custody.  Each committed semantic TxId retires before
%% the next lifecycle transaction is signed.
effect_custody_does_not_saturate_after_live_commits_test() ->
    Ns = <<"t">>,
    Anchor = <<0:256>>,
    {Author, Identity} = id(),
    Admission = quod_simplex:test_author_admission(Author),
    Dir = filename:join(
            "/tmp", "quod_effect_custody_capacity_" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           Ns, ?DOMAIN, Dir),
        S0 = st(#{ns => Ns, self => Author, id => Identity,
                  validators => [Author],
                  author_admissions => #{Author => Admission},
                  signing_journal => Journal0, sync => ready}),
        Final =
            lists:foldl(
              fun(Sequence, S) ->
                  {Signed, Submission} = effect_submission_fixture(
                                           Ns, Anchor, Admission,
                                           Sequence, Author, Identity),
                  {ok, Journal1} = quod_signing_journal:record_transaction(
                                     quod_simplex:test_signing_journal(S),
                                     Signed, Submission, ready),
                  S1 = quod_simplex:test_state_set(
                         signing_journal, Journal1, S),
                  S2 = quod_simplex:test_resolve_committed_submissions(
                         {batch, [Signed]}, Sequence + 1, S1),
                  ?assertEqual(
                     #{},
                     quod_signing_journal:pending_transactions(
                       quod_simplex:test_signing_journal(S2))),
                  S2
              end,
              S0, lists:seq(1, 65)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Final))
    after
        file:del_dir_r(Dir)
    end.

effect_submission_fixture(Ns, Anchor, Admission, Sequence,
                          Author, Identity) ->
    Effect = {quod_direct_effect, 2, local_durable,
              ontology_lifecycle, create,
              crypto:hash(sha256, <<"effect-id", Sequence:64>>), Author,
              {node, Author},
              {<<"capacity:test">>,
               crypto:hash(sha256, <<"effect-target", Sequence:64>>)},
              crypto:hash(sha256, <<"effect-request", Sequence:64>>),
              crypto:hash(sha256, <<"effect-prepared", Sequence:64>>)},
    Unsigned = quod_transaction:bind_id(
                 {Ns, Anchor},
                 #transaction{origin = {Ns, Anchor},
                              proof_id = crypto:hash(
                                           sha256,
                                           <<"effect-proof", Sequence:64>>),
                              plan_digest = crypto:hash(
                                              sha256,
                                              <<"effect-plan", Sequence:64>>),
                              goal = durable_goal(
                                       {create_ontology,
                                        <<"capacity:test">>, []}),
                              result = durable_result(),
                              diff = [], read_check = #{}, effects = [Effect],
                              author = Author, author_seq = Sequence,
                              submitted_at = Sequence, sig = none}),
    {ok, Signed, Submission} = quod_transaction:sign_submission(
                                 {Ns, Anchor, Admission},
                                 Unsigned, Identity),
    {Signed, Submission}.

%% Content transactions may batch. A committee transaction is legal only as a
%% singleton at the committed frontier, making it a pipeline barrier by construction.
batch_consensus_barrier_test() ->
    Committee = [{A, IdA}, {B, _IdB}] = committee(2),
    Root = quod_ledger:block_ref(blk(5, 495 + 5)),
    Eng = quod_simplex:eng_new(?DOMAIN, [A, B],{Root, 500, 0}),
    S0 = st(#{self => A, validators => [A, B], slot => 500, history_head => {500, element(3, Root)},
              eng => Eng, sync => ready}),
    C1 = signed_tx(<<"t">>, <<"one">>, [{assert, {{fact, one}, true}}], {A, IdA}),
    C2 = signed_tx(<<"t">>, <<"two">>, [{assert, {{fact, two}, true}}], {A, IdA}),
    Membership = signed_tx(<<"t">>, <<"membership">>, [pa(B)], {A, IdA}),
    ?assert(quod_simplex:acceptable_payload({batch, [C1, C2]}, S0)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [C1, C1]}, S0)),
    ?assertNot(quod_simplex:acceptable_payload(
                 {batch, [C1 | malformed_tail]}, S0)),
    ?assert(quod_simplex:acceptable_payload({batch, [Membership]}, S0)),
    ?assertNot(quod_simplex:acceptable_payload(
                 {batch, [C1, Membership]}, S0)),
    Proposed = block({?FIXTURE_ERA, 6}, Root, 501, {batch, [C1]}),
    {E1, _} = quod_simplex:eng_offer({block, Proposed}, Eng),
    {E2, _} = feed_shares(supports(Proposed, Committee, 2), E1),
    S1 = quod_simplex:test_state_set(eng, E2, S0),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Membership]}, S1)).

transaction_signature_acceptance_test() ->
    [{Author, AuthorId}, {Outsider, OutsiderId}] = committee(2),
    State = st(#{self => Author, validators => [Author], slot => 500,
                 history_head => {500, <<1:256>>},
                 eng => quod_simplex:eng_new(?DOMAIN, [Author ], {{?FIXTURE_ERA, 5, <<1:256>>}, 500, 0}),
                 sync => ready}),
    Good = signed_tx(<<"t">>, <<"good">>,
                     [{assert, {{fact, signed}, true}}], {Author, AuthorId}),
    Forged = Good#transaction{sig = flip1(Good#transaction.sig)},
    Unsigned = Good#transaction{sig = none, signed_bytes = none},
    {ok, NondeterministicId} = quod_transaction:sign(
                                 test_binding(<<"t">>, Author),
                                 Good#transaction{tx_id = <<99:256>>,
                                                  sig = none,
                                                  signed_bytes = none},
                                 AuthorId),
    WrongNamespace = signed_tx(
                       <<"other">>, <<"wrong-ns">>,
                       [{assert, {{fact, other}, true}}], {Author, AuthorId}),
    Unauthorized = signed_tx(
                     <<"t">>, <<"outsider">>,
                     [{assert, {{fact, outsider}, true}}], {Outsider, OutsiderId}),
    ?assert(quod_simplex:acceptable_payload({batch, [Good]}, State)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Unsigned]}, State)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Forged]}, State)),
    ?assertNot(quod_simplex:acceptable_payload(
                 {batch, [NondeterministicId]}, State)),
    ?assertNot(quod_simplex:acceptable_payload(
                 {batch, [WrongNamespace]}, State)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Unauthorized]}, State)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Good, Forged]}, State)).

committed_author_sequence_replay_test() ->
    [{Author, AuthorId}] = committee(1),
    State = st(#{self => Author, validators => [Author], slot => 500,
                 history_head => {500, <<1:256>>},
                 eng => quod_simplex:eng_new(?DOMAIN, [Author ], {{?FIXTURE_ERA, 5, <<1:256>>}, 500, 0}),
                 author_seqs => #{Author => 5}, sync => ready}),
    Fresh = signed_tx_seq(<<"t">>, <<"fresh">>, 6,
                          [{assert, {{fact, fresh}, true}}],
                          {Author, AuthorId}),
    Replay = signed_tx_seq(<<"t">>, <<"old">>, 5,
                           [{assert, {{fact, old}, true}}],
                           {Author, AuthorId}),
    SameSeq = signed_tx_seq(<<"t">>, <<"same-seq">>, 6,
                            [{assert, {{fact, duplicate}, true}}],
                            {Author, AuthorId}),
    ?assert(quod_simplex:acceptable_payload({batch, [Fresh]}, State)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Replay]}, State)),
    ?assertNot(quod_simplex:acceptable_payload(
                 {batch, [Fresh, SameSeq]}, State)).

%% The dialing timeout: a dial marker whose deadline has passed is swept (so the tick re-dials it),
%% while one still in the future is kept. This is the whole self-heal for a dial that resolves to neither
%% link_up nor link_error — without it a lost dial pins the peer out of redial_pending forever.
prune_dials_test() ->
    Now = 1000,
    %% keep future deadlines (Now < Deadline); drop expired ones, INCLUDING exactly at the deadline (Now >= Deadline)
    ?assertEqual(#{a => 1500},
                 quod_simplex:prune_dials(#{a => 1500, b => 900, c => 1000}, Now)),
    ?assertEqual(#{}, quod_simplex:prune_dials(#{}, Now)),
    ?assertEqual(#{}, quod_simplex:prune_dials(#{stuck => 1}, Now)),            %% long-expired ⇒ swept
    ?assertEqual(#{x => 2000, y => 3000},                                       %% all future ⇒ all kept
                 quod_simplex:prune_dials(#{x => 2000, y => 3000}, Now)).

%%%===================================================================
%%% share sign / verify
%%%===================================================================

share_roundtrip_test() ->
    {_Pub, Id} = id(),
    H = quod_simplex:block_hash(blk(3)),
    S = quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 3}, H, Id),
    ?assert(quod_simplex:verify_share(?DOMAIN, S)),
    %% a tampered signature is rejected
    Bad = S#share{sig = flip1(S#share.sig)},
    ?assertNot(quod_simplex:verify_share(?DOMAIN, Bad)).

%% a support sig does not verify as a commit sig (domain separation)
domain_separation_test() ->
    {Pub, Id} = id(),
    H = quod_simplex:block_hash(blk(3)),
    S = quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 3}, H, Id),
    %% same signer/slot/hash, but the COMMIT bytes -> the support sig must not verify
    ?assertNot(quod_identity:verify(S#share.sig, quod_simplex:share_bytes(?DOMAIN, commit, {?FIXTURE_ERA, 3}, H), Pub)).

%% There is deliberately no dual-stack verifier. A genuine Ed25519 signature
%% over the former unversioned `{kind,slot,hash}` bytes is cryptographically
%% valid for those bytes but invalid consensus evidence after the format break.
legacy_unversioned_share_is_rejected_test() ->
    {Pub, #{key := Key}} = id(),
    H = quod_simplex:block_hash(blk(3)),
    LegacyBytes = <<$S, 3:64, H/binary>>,
    LegacySig = quod_identity:sign(LegacyBytes, Key),
    ?assert(quod_identity:verify(LegacySig, LegacyBytes, Pub)),
    Legacy =
        #share{kind = support, slot = 3, block_hash = H,
               signer = Pub, sig = LegacySig},
    ?assertNot(quod_simplex:verify_share(?DOMAIN, Legacy)).

%% A node identity is intentionally reused across hosted ontologies. The
%% namespace and pinned genesis must therefore both participate in the
%% consensus signature domain: even a genuine quorum complaint from one chain
%% is inert in either a sibling namespace or a re-founded chain.
namespace_and_genesis_bound_consensus_replay_rejected_test() ->
    NsA = <<"ontology:a">>,
    NsB = <<"ontology:b">>,
    GenesisA = <<1:256>>,
    GenesisB = <<2:256>>,
    DomainA = quod_simplex:consensus_domain(NsA, GenesisA),
    NamespaceDomain = quod_simplex:consensus_domain(NsB, GenesisA),
    GenesisDomain = quod_simplex:consensus_domain(NsA, GenesisB),
    ?assertNotEqual(DomainA, NamespaceDomain),
    ?assertNotEqual(DomainA, GenesisDomain),
    Committee = committee(4),
    Validators = pubs(Committee),
    Shares =
        [quod_simplex:make_share(DomainA, complaint, {?FIXTURE_ERA, 6}, none, Id)
         || {_, Id} <- take(3, Committee)],
    [FirstShare | _] = Shares,
    {ok, Cert} =
        quod_simplex:form_cert(
          DomainA, complaint, {?FIXTURE_ERA, 6}, none, Shares, Validators),
    ?assert(quod_simplex:verify_share(DomainA, FirstShare)),
    ?assertNot(quod_simplex:verify_share(NamespaceDomain, FirstShare)),
    ?assertNot(quod_simplex:verify_share(GenesisDomain, FirstShare)),
    ?assert(quod_simplex:verify_cert(DomainA, Cert, Validators)),
    ?assertNot(quod_simplex:verify_cert(
                 NamespaceDomain, Cert, Validators)),
    ?assertNot(quod_simplex:verify_cert(
                 GenesisDomain, Cert, Validators)),
    NamespaceEngine =
        quod_simplex:eng_new(NamespaceDomain, Validators, {{?FIXTURE_ERA, 5, <<1:256>>}, 1, 0}),
    {NamespaceRejected, []} =
        quod_simplex:eng_offer({cert, Cert}, NamespaceEngine),
    ?assertEqual(NamespaceEngine, NamespaceRejected),
    GenesisEngine =
        quod_simplex:eng_new(GenesisDomain, Validators, {{?FIXTURE_ERA, 5, <<1:256>>}, 1, 0}),
    {GenesisRejected, []} =
        quod_simplex:eng_offer({cert, Cert}, GenesisEngine),
    ?assertEqual(GenesisEngine, GenesisRejected).

%%%===================================================================
%%% certificate formation + trustless verification
%%%===================================================================

form_and_verify_cert_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],           %% N=4, quorum=3
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    Shares = [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Id) || {_, Id} <- take(3, Ids)],
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Shares, Vals),
    ?assert(quod_simplex:verify_cert(?DOMAIN, Cert, Vals)).

cert_insufficient_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    Shares = [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Id) || {_, Id} <- take(2, Ids)],   %% < quorum 3
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Shares, Vals)).

%% a share from a non-validator does not count toward quorum
cert_rejects_outsider_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    {_, Outsider} = id(),                            %% not in Vals
    H = quod_simplex:block_hash(blk(1)),
    Shares =
        [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Outsider) |
         [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Id)
          || {_, Id} <- take(2, Ids)]],
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Shares, Vals)).

%% a corrupted signature does not count
cert_rejects_bad_sig_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    [S1, S2, S3] = [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Id) || {_, Id} <- take(3, Ids)],
    Shares = [S1, S2, S3#share{sig = flip1(S3#share.sig)}],   %% one bad -> only 2 valid
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Shares, Vals)).

%% duplicate shares from the same signer count once
cert_dedup_signer_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    [{_, A}, {_, B} | _] = Ids,
    %% 3 shares but only 2 distinct signers (A twice) -> below quorum 3
    Shares = [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, A),
              quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, A),
              quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, B)],
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Shares, Vals)).

%% a forged cert (sigs over a different block) fails trustless verification
verify_cert_rejects_wrong_block_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H1 = quod_simplex:block_hash(blk(1)),
    Shares = [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H1, Id) || {_, Id} <- take(3, Ids)],
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H1, Shares, Vals),
    %% claim the cert is for a different block hash -> sigs no longer verify
    Forged = Cert#cert{block_hash = quod_simplex:block_hash(blk(2))},
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, Forged, Vals)).

%% Competing protocol progress retires a raw collection once. Ordinary
%% signed writes keep their durable custody and are retargeted separately.
protocol_progress_nacks_raw_collection_test_() ->
    [?_test(protocol_progress_nacks_raw_collection(Kind)) || Kind <- [complaint, notarized]].

protocol_progress_nacks_raw_collection(Kind) ->
    Committee = [{Self, Signer} | _] = committee(4),
    Ref = make_ref(), From = {self(), Ref}, Block = blk(5, 496 + 5),
    Root = quod_ledger:block_ref(blk(4, 496 + 4)),
    S = st(#{self => Self, id => Signer, validators => pubs(Committee),
        slot => 500, sync => unconfirmed, history_head => {500, element(3, Root)},
        eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), {Root, 500, 0}),
        collecting => {5, [From]}}),
    Inputs = case Kind of
        complaint -> [{share, complaint_share(5, M)} || M <- take(3, Committee)];
        notarized -> [{block, Block} | [{share, Sh} || Sh <- supports(Block, Committee, 3)]]
    end,
    Advanced = quod_simplex:engine_step(Inputs, S),
    ?assertEqual(6, maps:get(view, quod_simplex:test_protocol_position(Advanced))),
    ?assertEqual(500, element(1, quod_simplex:test_committed_store(Advanced))),
    receive {Ref, Reply} -> ?assertEqual({error, skipped}, Reply)
    after 0 -> error(missing_collection_retirement) end,
    _ = quod_simplex:engine_step(Inputs, Advanced),
    receive {Ref, _} -> error(duplicate_collection_reply) after 0 -> ok end.

%% Batch capacity limits, driven through the real append entry (running/3). An oversized single change is
%% rejected fast ({error, too_large}) so a block can never blow past the wire frame; a leader whose
%% depth-one pipeline is already full now PARKS the append in the bounded ingress queue instead of
%% rejecting {error, busy} — the caller waits for the pipeline's own events, not a retry timer.
batch_caps_reject_oversized_and_park_test() ->
    {Me, Id} = id(),
    Base = #{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             history_head => {3, quod_simplex:block_hash(blk(3))},
             eng => notarized_prefix([{Me, Id}], 3, 3)},   %% a caught-up sole leader
    From = {self(), make_ref()},
    %% The transaction itself remains within its canonical envelope, while
    %% the enclosing signed-transaction and block bytes cross MAX_BLOCK_BYTES.
    %% That keeps this test on the Simplex block-cap seam now that R2 refuses
    %% an intrinsically oversized transaction before it can be signed.
    Big = bind_test_id(
            #transaction{tx_id = <<>>, origin = {<<"t">>, <<0:256>>},
                         proof_id = <<0:256>>, plan_digest = <<0:256>>,
                         goal = durable_goal({test, big}),
                         result = durable_result(),
                         author = Me, sig = none, read_check = #{},
                         diff = [{assert,
                                  {{blob,
                                    binary:copy(<<0>>, 255 * 1024 + 512)},
                                   true}}]}),
    {keep_state, _, A1} =
        quod_simplex:running(
          {call, From}, {append, Big, otel_ctx:new()}, st(Base)),
    ?assert(lists:member({reply, From, {error, too_large}}, A1)),
    %% material pipeline full (height 3, two notarized writes pending): the append PARKS —
    %% no reply action, no busy, one queued item under this author.
    Small = bind_test_id(
              #transaction{tx_id = <<>>, origin = {<<"t">>, <<0:256>>},
                           proof_id = <<0:256>>, plan_digest = <<0:256>>,
                           goal = durable_goal({test, small}),
                           result = durable_result(),
                           author = Me, sig = none, read_check = #{},
                           diff = [{assert, {{k, v}, true}}]}),
    {keep_state, SParked, A2} =
        quod_simplex:running(
          {call, From}, {append, Small, otel_ctx:new()},
          st(Base#{eng => notarized_prefix([{Me, Id}], 3, 5)})),
    ?assertEqual([], [R || {reply, _, _} = R <- A2]),
    SmallId = Small#transaction.tx_id,
    {1, _, Authors, [{local, SmallId, _}]} = quod_simplex:test_ingress(SParked),
    ?assertEqual(#{Me => 1}, Authors),
    ?assertEqual(0, maps:get(r_busy, quod_simplex:stats_map(SParked))),
    %% Two locally authored envelopes for the same semantic transaction
    %% coalesce. The second custody record is not replied to early; both are
    %% released by the one committed tx_id.
    FirstRef = make_ref(),
    SecondRef = make_ref(),
    FirstFrom = {self(), FirstRef},
    SecondFrom = {self(), SecondRef},
    {keep_state, S1, _} =
        quod_simplex:running(
          {call, FirstFrom}, {append, Small, otel_ctx:new()}, st(Base)),
    {keep_state, S2, A3} =
        quod_simplex:running(
          {call, SecondFrom}, {append, Small, otel_ctx:new()}, S1),
    ?assertEqual([], [R || {reply, _, _} = R <- A3]),
    ?assertEqual(2, length(quod_simplex:test_custody(S2))),
    [{_FirstSubmissionId, 1, FirstSubmission,
      _FirstPlacement, _FirstDeadline, _FirstAttempts}] =
        quod_simplex:test_custody(S1),
    {ok, SignedFirst} = decode_submission(<<"t">>, FirstSubmission),
    Settled = quod_simplex:test_resolve_committed_submissions(
                {batch, [SignedFirst]}, 4, S2),
    receive {FirstRef, {ok, 4}} -> ok after 0 -> ?assert(false) end,
    receive {SecondRef, {ok, 4}} -> ok after 0 -> ?assert(false) end,
    ?assertEqual([], quod_simplex:test_custody(Settled)).

different_validator_envelopes_for_same_transaction_converge_test() ->
    Ns = <<"t">>,
    {FirstAuthor, FirstIdentity} = id(),
    {SecondAuthor, SecondIdentity} = id(),
    Base = bind_test_id(
             #transaction{tx_id = <<>>, origin = {Ns, <<0:256>>},
                          proof_id = <<91:256>>, plan_digest = <<92:256>>,
                          goal = durable_goal({same, semantic, transaction}),
                          result = durable_result(), read_check = #{},
                          diff = [{assert, {{same_semantic, value}, true}}],
                          author = SecondAuthor, author_seq = 0, sig = none}),
    FirstUnsigned = Base#transaction{author = FirstAuthor, author_seq = 1},
    {ok, First} = quod_transaction:sign(
                    test_binding(Ns, FirstAuthor),
                    FirstUnsigned, FirstIdentity),
    Ref = make_ref(),
    From = {self(), Ref},
    S0 = st(#{self => SecondAuthor, id => SecondIdentity,
              validators => [SecondAuthor], sync => ready,
              slot => 3, history_head => {3, <<1:256>>},
              eng => root_engine(3)}),
    {S1, _Actions} = quod_simplex:test_append(From, Base, S0),
    [{_SubmissionId, 1, SecondSubmission, _Placement, _Deadline, _Attempts}] =
        quod_simplex:test_custody(S1),
    {ok, Second} = decode_submission(Ns, SecondSubmission),
    ?assertNotEqual(First#transaction.author, Second#transaction.author),
    ?assertEqual(First#transaction.tx_id, Second#transaction.tx_id),
    Settled = quod_simplex:test_resolve_committed_submissions(
                {batch, [First]}, 4, S1),
    receive {Ref, {ok, 4}} -> ok after 0 -> ?assert(false) end,
    ?assertEqual([], quod_simplex:test_custody(Settled)).

batch_rejects_duplicate_author_sequence_without_mutation_test() ->
    Ns = <<"t">>,
    [{Author, AuthorId}] = Committee = committee(1),
    First =
        signed_tx_seq(
          Ns, <<"same-sequence-a">>, 7,
          [{assert, {{same_sequence, a}, true}}],
          {Author, AuthorId}),
    Second =
        signed_tx_seq(
          Ns, <<"same-sequence-b">>, 7,
          [{assert, {{same_sequence, b}, true}}],
          {Author, AuthorId}),
    S0 =
        st(#{self => Author, id => AuthorId,
             validators => pubs(Committee), sync => ready,
             slot => 3, history_head => {3, <<1:256>>}, author_seqs => #{Author => 6},
             eng => root_engine(3),
             relay_conns => #{Author => {self(), make_ref()}}}),
    {S1, _} = quod_simplex:test_relayed_append(Author, First, S0),
    BatchBefore = quod_simplex:test_batch(S1),
    StatsBefore = quod_simplex:stats_map(S1),
    {S2, []} = quod_simplex:test_relayed_append(Author, Second, S1),
    ?assertEqual(BatchBefore, quod_simplex:test_batch(S2)),
    ?assertEqual(maps:get(appends, StatsBefore),
                 maps:get(appends, quod_simplex:stats_map(S2))),
    ?assertEqual(maps:get(r_stale, StatsBefore) + 1,
                 maps:get(r_stale, quod_simplex:stats_map(S2))),
    ?assertMatch(
       {relay_result, _SubmissionId, _AttemptId, _CommitteeId, 4,
        {error, stale_seq}},
       receive_relay_control(Ns)).

batch_operation_claims_coalesce_aliases_and_reject_conflicts_test() ->
    Ns = <<"t">>,
    Anchor = <<0:256>>,
    OperationId = <<77:256>>,
    AgentKey = quod_identity:generate(),
    Base = quod_ct:signed_atomic_fixture(
             #{target => {Ns, Anchor}, operation_id => OperationId,
               key_pair => AgentKey}),
    First0 = maps:get(transaction, Base),
    #{pubkey := Author} = NodeIdentity = maps:get(node_identity, Base),
    Admission = maps:get(admission, Base),
    First = First0#transaction{author = Author, author_seq = 0,
                               sig = none, signed_bytes = none},
    AliasFixture = quod_ct:signed_atomic_fixture(
                     #{target => {Ns, Anchor},
                       operation_id => OperationId, key_pair => AgentKey,
                       proof_id => <<210:256>>}),
    Alias = (maps:get(transaction, AliasFixture))#transaction{
              author = Author, author_seq = 0,
              sig = none, signed_bytes = none},
    ConflictFixture = quod_ct:signed_atomic_fixture(
                        #{target => {Ns, Anchor},
                          operation_id => OperationId, key_pair => AgentKey,
                          proof_id => <<211:256>>,
                          goal_text => <<"assertz(saved(conflict)).">>}),
    Conflict = (maps:get(transaction, ConflictFixture))#transaction{
                 author = Author, author_seq = 0,
                 sig = none, signed_bytes = none},
    ?assertNotEqual(First#transaction.tx_id, Alias#transaction.tx_id),
    {ok, FirstClaim} = quod_transaction:request_claim(First),
    {ok, AliasClaim} = quod_transaction:request_claim(Alias),
    {ok, ConflictClaim} = quod_transaction:request_claim(Conflict),
    ?assertEqual(maps:get(key, FirstClaim), maps:get(key, AliasClaim)),
    ?assertEqual(maps:get(digest, FirstClaim), maps:get(digest, AliasClaim)),
    ?assertEqual(maps:get(key, FirstClaim), maps:get(key, ConflictClaim)),
    ?assertNotEqual(maps:get(digest, FirstClaim),
                    maps:get(digest, ConflictClaim)),
    quod_ct:with_network_identity(
      maps:get(network, Base),
      fun() ->
          S0 = st(#{ns => Ns, self => Author,
                    id => NodeIdentity,
                    genesis_hash => Anchor,
                    consensus_domain => quod_simplex:consensus_domain(
                                            Ns, Anchor),
                    validators => [Author],
                    author_admissions => #{Author => Admission},
                    author_seqs => #{Author => 0}, sync => ready,
                    slot => 3, history_head => {3, <<1:256>>},
                    eng => root_engine(3)}),
          FirstRef = make_ref(),
          AliasRef = make_ref(),
          {S1, _BatchTimer} = quod_simplex:test_append(
                                {self(), FirstRef}, First, S0),
          {S2, []} = quod_simplex:test_append(
                       {self(), AliasRef}, Alias, S1),
          #{count := 1, operation_claims := Claims} =
              quod_simplex:test_batch(S2),
          ?assertEqual(1, map_size(Claims)),
          ?assertEqual(2, length(quod_simplex:test_custody(S2))),
          [{_FirstSubmissionId, 1, FirstSubmission,
            _FirstPlacement, _FirstDeadline, _FirstAttempts}] =
              quod_simplex:test_custody(S1),
          {ok, SignedFirst} = quod_transaction:decode_verified_submission(
                                {Ns, Anchor, Admission}, FirstSubmission),
          Settled = quod_simplex:test_resolve_committed_submissions(
                      {batch, [SignedFirst]}, 4, S2),
          receive {FirstRef, {ok, 4}} -> ok
          after 0 -> ?assert(false)
          end,
          OperationRef = maps:get(operation_ref, FirstClaim),
          receive
              {AliasRef, {error, {outcome_unknown, OperationRef}}} -> ok
          after 0 -> ?assert(false)
          end,
          ?assertEqual([], quod_simplex:test_custody(Settled)),

          ConflictRef = make_ref(),
          ConflictFrom = {self(), ConflictRef},
          {C1, _ConflictBatchTimer} = quod_simplex:test_append(
                                        {self(), make_ref()}, First, S0),
          {C2, ConflictActions} = quod_simplex:test_append(
                                    ConflictFrom, Conflict, C1),
          ?assert(lists:member(
                    {reply, ConflictFrom, {error, bad_change}},
                    ConflictActions)),
          #{count := 1} = quod_simplex:test_batch(C2),
          ?assertEqual(1, length(quod_simplex:test_custody(C2)))
      end).

batch_population_does_not_flush_before_byte_limit_test() ->
    Ns = <<"t">>,
    [{Author, AuthorId}] = Committee = committee(1),
    S0 =
        st(#{self => Author, id => AuthorId,
             validators => pubs(Committee), sync => ready,
             slot => 3, history_head => {3, <<1:256>>},
             eng => root_engine(3)}),
    Transactions =
        [signed_tx_seq(
           Ns, <<"batch-", (integer_to_binary(N))/binary>>, N,
           [{assert, {{batch_item, N}, true}}],
           {Author, AuthorId})
         || N <- lists:seq(1, 256)],
    {First255, _} =
        lists:foldl(
          fun(Change, {Acc, _Actions}) ->
                  quod_simplex:test_relayed_append(
                    Author, Change, Acc)
          end, {S0, []}, lists:sublist(Transactions, 255)),
    #{count := 255, tx_ids := TxIds, sequences := Sequences} =
        quod_simplex:test_batch(First255),
    ?assertEqual(255, map_size(TxIds)),
    ?assertEqual(255, map_size(Sequences)),
    Last = lists:nth(256, Transactions),
    {Collected, Actions} =
        quod_simplex:test_relayed_append(
          Author, Last, First255),
    #{count := 256, tx_ids := FinalTxIds,
      sequences := FinalSequences} = quod_simplex:test_batch(Collected),
    ?assertEqual(256, map_size(FinalTxIds)),
    ?assertEqual(256, map_size(FinalSequences)),
    ?assertNot(lists:member({{timeout, batch}, cancel}, Actions)),
    Stats = quod_simplex:stats_map(Collected),
    ?assertEqual(256, maps:get(appends, Stats)),
    ?assertEqual(0, maps:get(batched_txs, Stats)),
    ?assertEqual(0, maps:get(proposals, Stats)).

%%%===================================================================
%%% ingress park queue — park, drain, forward, expire (event-driven ingress)
%%%===================================================================

lt(N) -> bind_test_id(
           #transaction{tx_id = <<>>, origin = {<<"t">>, <<0:256>>},
                        proof_id = <<0:256>>, plan_digest = <<0:256>>,
                        goal = durable_goal({load, N}),
                        result = durable_result(),
                        author = undefined,
                        sig = none, read_check = #{},
                        diff = [{assert, {{loadfact, N}, true}}]}).
lt(N, Author) -> (lt(N))#transaction{author = Author}.

keep_progress_retains_unchanged_ingress_view_test() ->
    {Me, Id} = id(),
    S0 =
        st(#{self => Me, id => Id, validators => [Me],
             sync => ready, slot => 3, history_head => {3, <<1:256>>},
             eng => root_engine(3)}),
    ?assertEqual(undefined,
                 quod_simplex:test_ingress_view_source(S0)),
    {keep_state, Cached, _} =
        quod_simplex:test_keep_progress_transition(S0, S0),
    Source = quod_simplex:test_ingress_view_source(Cached),
    ?assertNotEqual(undefined, Source),
    {keep_state, CachedAgain, _} =
        quod_simplex:test_keep_progress_transition(Cached, Cached),
    ?assertEqual(
       Source,
       quod_simplex:test_ingress_view_source(CachedAgain)).

%% A verified finalizer beyond the live engine window is represented only by
%% `ahead_finalizer`. That scalar revokes voting and ingress immediately, so it
%% must also invalidate the cached route view even though no cert map changed.
far_finalizer_invalidates_cached_ingress_view_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = committee(4),
    Validators = pubs(Committee),
    Me = quod_simplex:leader(6, Validators),
    {Me, MyId} = lists:keyfind(Me, 1, Committee),
    E0 = quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(5)), 5, 0}),
    S0 =
        st(#{self => Me, id => MyId, validators => Validators,
             sync => ready, slot => 5, history_head => {5, <<1:256>>}, eng => E0}),
    {keep_state, Cached, _} =
        quod_simplex:test_keep_progress_transition(S0, S0),
    CachedSource = quod_simplex:test_ingress_view_source(Cached),
    ?assertEqual(
       {collect, 6},
       quod_simplex:test_route(entry, local, lt($h, Me), Cached)),

    FarBlock = blk(8),
    FarHash = quod_simplex:block_hash(FarBlock),
    {ok, FarCert} =
        quod_simplex:form_cert(
          ?DOMAIN, commit, {?FIXTURE_ERA, 8}, FarHash,
          commits(FarBlock, Committee, 3), Validators),
    {HintedEngine, [{ahead, FarCert}]} =
        quod_simplex:eng_offer({cert, FarCert}, E0),
    Hinted =
        quod_simplex:test_state_set(eng, HintedEngine, Cached),
    {keep_state, Refreshed, _} =
        quod_simplex:test_keep_progress_transition(Cached, Hinted),
    ?assertNotEqual(
       CachedSource,
       quod_simplex:test_ingress_view_source(Refreshed)),
    ?assertEqual(
       {park, awaiting_turn},
       quod_simplex:test_route(entry, local, lt($i, Me), Refreshed)),
    ?assertNot(quod_simplex:may_vote(Refreshed)).

%% Two parked items drain into ONE immediately-sealed block the moment the pipeline
%% opens — no micro-batch window for backlog that already waited a full flight.
%% Planting the blocked queue directly keeps this test about drain/seal,
%% independently of source-side target selection.
multi_item_drain_seals_one_block_test() ->
    Committee = committee(3),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(6, Validators), 1, Committee),
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, history_head => {3, quod_simplex:block_hash(blk(3))},
                   eng => notarized_prefix(Committee, 3, 5)}),
    F1 = {self(), make_ref()}, F2 = {self(), make_ref()},
    A = lt($a, Me), B = lt($b, Me),
    P2 = quod_simplex:test_state_set(
           ingress,
           [{local, F1, A, quod_time:mono_ms()},
            {local, F2, B, quod_time:mono_ms() + 1}],
           Blocked),
    {2, _, _, [{local, AId, _}, {local, BId, _}]} =
        quod_simplex:test_ingress(P2),
    ?assertEqual(A#transaction.tx_id, AId),
    ?assertEqual(B#transaction.tx_id, BId),
    %% parent is installed; the same protocol view can now admit material => drain pours + seals NOW
    Opened = quod_simplex:test_state_set(history_head, {5, quod_simplex:block_hash(blk(5))},
        quod_simplex:test_state_set(slot, 5,
          quod_simplex:test_state_set(eng, notarized_prefix(Committee, 5, 5), P2))),
    ?assert(quod_simplex:test_ingress_needs_drain(P2, Opened)),
    {Drained, Actions} = quod_simplex:test_drain(Opened),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    %% sealed immediately: no open batch survives, both waiters sit on the in-flight
    %% proposal (pending counts local_proposal waiters), the head watchdog is armed.
    ?assert(lists:member({{timeout, batch}, cancel}, Actions)),
    ?assertMatch({?FIXTURE_ERA, 6, _}, quod_simplex:test_progress(Drained)),
    ?assertEqual(2, maps:get(pending, quod_simplex:stats_map(Drained))),
    ?assertEqual(2, maps:get(batched_txs, quod_simplex:stats_map(Drained))).

%% A singleton drain keeps the normal micro-batch window (its arm action threads out),
%% so the post-rotation re-send wave can still join the same block.
singleton_drain_keeps_batch_window_test() ->
    Committee = committee(3),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(6, Validators), 1, Committee),
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, history_head => {3, quod_simplex:block_hash(blk(3))},
                   batch_window_ms => 37,
                   eng => notarized_prefix(Committee, 3, 5)}),
    F = {self(), make_ref()},
    P1 = quod_simplex:test_state_set(
           ingress, [{local, F, lt($c, Me), quod_time:mono_ms()}], Blocked),
    {Drained, Actions} = quod_simplex:test_drain(
                           quod_simplex:test_state_set(history_head, {5, quod_simplex:block_hash(blk(5))},
                               quod_simplex:test_state_set(slot, 5,
                                 quod_simplex:test_state_set(eng, notarized_prefix(Committee, 5, 5), P1)))),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual([{{timeout, batch}, 37, {flush_batch, 6}}],
                 [A || {{timeout, batch}, _, _} = A <- Actions]).

%% Membership must enter only after the approved pipeline becomes final. It is a
%% global drain barrier, not ordinary author-local backpressure: allowing later
%% writes to keep filling the child slot could starve the committee transition.
queued_membership_stops_the_drain_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(5, Validators), 1, Committee),
    [{AuthorA, IdA}, {AuthorB, IdB} | _] =
        [P || {Pub, _} = P <- Committee, Pub =/= Me],
    NewMember = <<99:256>>,
    Membership = signed_tx(<<"t">>, <<"membership-head">>, [pa(NewMember)],
                           {AuthorA, IdA}),
    Ordinary = signed_tx(<<"t">>, <<"ordinary-ready">>,
                         [{assert, {{ordinary, ready}, true}}], {AuthorB, IdB}),
    Approved = blk(4),
    {E1, _} = quod_simplex:eng_offer(
                {block, Approved}, quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(3)), 3, 0})),
    {Eng, _} = feed_shares(supports(Approved, Committee, 3), E1),
    Now = quod_time:mono_ms(),
    Queued = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                  slot => 3, history_head => {3, quod_simplex:block_hash(blk(3))},
                  eng => Eng,
                  ingress =>
                      [{relayed, AuthorA, 5, Membership, Now},
                       {relayed, AuthorB, 5, Ordinary, Now}]}),
    %% The ordinary write could enter slot 5 in isolation; queue ordering is what
    %% deliberately holds it behind the membership boundary.
    OrdinaryOrigin =
        quod_simplex:test_relay_origin(AuthorB, 5, Ordinary, Queued),
    ?assertEqual({collect, 5},
                 quod_simplex:test_route(
                   drain, OrdinaryOrigin, Ordinary, Queued)),
    {Drained, _Actions} = quod_simplex:test_drain(Queued),
    {2, _, #{AuthorA := 1, AuthorB := 1},
     [{relayed, MembershipId, _}, {relayed, OrdinaryId, _}]} =
        quod_simplex:test_ingress(Drained),
    ?assertEqual(Membership#transaction.tx_id, MembershipId),
    ?assertEqual(Ordinary#transaction.tx_id, OrdinaryId),
    ?assertEqual(0, maps:get(appends, quod_simplex:stats_map(Drained))).

%% Capacity backpressure is author-local. A large A1 that cannot join the open
%% batch holds A2 behind it, preserving signed author sequence, while a small B
%% may fill the otherwise usable block. The held pair is restored in order.
blocked_author_does_not_block_other_authors_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    [{FillerAuthor, FillerId}, {AuthorA, IdA}, {AuthorB, IdB}] =
        [P || {Pub, _} = P <- Committee, Pub =/= Me],
    Filler = signed_tx(
               <<"t">>, <<"batch-filler">>,
               [{assert, {{blob, binary:copy(<<1>>, 220000)}, true}}],
               {FillerAuthor, FillerId}),
    A1 = signed_tx_seq(
           <<"t">>, <<"a-large">>, 10,
           [{assert, {{blob, binary:copy(<<2>>, 120000)}, true}}],
           {AuthorA, IdA}),
    A2 = signed_tx_seq(
           <<"t">>, <<"a-small">>, 11,
           [{assert, {{ordinary, a2}, true}}], {AuthorA, IdA}),
    B = signed_tx(
          <<"t">>, <<"b-small">>,
          [{assert, {{ordinary, b}, true}}], {AuthorB, IdB}),
    Base = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                slot => 3, history_head => {3, <<1:256>>},
                eng => root_engine(3)}),
    {WithBatch, _BatchActions} =
        quod_simplex:test_relayed_append(
          FillerAuthor, Filler, Base),
    Now = quod_time:mono_ms(),
    Queued = quod_simplex:test_state_set(
               ingress,
               [{relayed, AuthorA, 4, A1, Now},
                {relayed, AuthorA, 4, A2, Now + 1},
                {relayed, AuthorB, 4, B, Now + 2}],
               WithBatch),
    ?assert(quod_simplex:test_ingress_needs_drain(WithBatch, Queued)),
    A1Origin = quod_simplex:test_relay_origin(AuthorA, 4, A1, Queued),
    A2Origin = quod_simplex:test_relay_origin(AuthorA, 4, A2, Queued),
    BOrigin = quod_simplex:test_relay_origin(AuthorB, 4, B, Queued),
    ?assertMatch({park, _},
                 quod_simplex:test_route(drain, A1Origin, A1, Queued)),
    ?assertEqual({collect, 4},
                 quod_simplex:test_route(drain, A2Origin, A2, Queued)),
    ?assertEqual({collect, 4},
                 quod_simplex:test_route(drain, BOrigin, B, Queued)),
    {Drained, _Actions} = quod_simplex:test_drain(Queued),
    {2, _, #{AuthorA := 2},
     [{relayed, A1Id, _}, {relayed, A2Id, _}]} =
        quod_simplex:test_ingress(Drained),
    ?assertEqual(A1#transaction.tx_id, A1Id),
    ?assertEqual(A2#transaction.tx_id, A2Id),
    ?assertEqual(2, maps:get(appends, quod_simplex:stats_map(Drained))),
    ?assertNot(quod_simplex:test_ingress_needs_drain(Drained, Drained)).

%% The first pass can itself change routing: B and C fill and seal slot 4 while
%% A1/A2 are held behind A1's capacity block. The second pass must then revisit A
%% and reject its now-closed exact target. A one-pass drain leaves both A requests
%% stranded even though the route changed during the same statem event.
drain_rechecks_held_authors_after_route_change_test() ->
    Committee = committee(5),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    [{FillerAuthor, FillerId}, {AuthorA, IdA},
     {AuthorB, IdB}, {AuthorC, IdC}] =
        [P || {Pub, _} = P <- Committee, Pub =/= Me],
    Filler = signed_tx(
               <<"t">>, <<"multipass-filler">>,
               [{assert, {{blob, binary:copy(<<1>>, 220000)}, true}}],
               {FillerAuthor, FillerId}),
    A1 = signed_tx_seq(
           <<"t">>, <<"multipass-a-large">>, 10,
           [{assert, {{blob, binary:copy(<<2>>, 120000)}, true}}],
           {AuthorA, IdA}),
    A2 = signed_tx_seq(
           <<"t">>, <<"multipass-a-small">>, 11,
           [{assert, {{ordinary, multipass_a2}, true}}], {AuthorA, IdA}),
    B = signed_tx(
          <<"t">>, <<"multipass-b">>,
          [{assert, {{ordinary, multipass_b}, true}}], {AuthorB, IdB}),
    C = signed_tx(
          <<"t">>, <<"multipass-c">>,
          [{assert, {{ordinary, multipass_c}, true}}], {AuthorC, IdC}),
    Base = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                slot => 3, history_head => {3, <<1:256>>},
                eng => root_engine(3)}),
    {WithBatch, _} =
        quod_simplex:test_relayed_append(
          FillerAuthor, Filler, Base),
    Now = quod_time:mono_ms(),
    Queued = quod_simplex:test_state_set(
               ingress,
               [{relayed, AuthorA, 4, A1, Now},
                {relayed, AuthorA, 4, A2, Now + 1},
                {relayed, AuthorB, 4, B, Now + 2},
                {relayed, AuthorC, 4, C, Now + 3}],
               WithBatch),
    {Drained, _Actions} = quod_simplex:test_drain(Queued),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    Stats = quod_simplex:stats_map(Drained),
    ?assertEqual(3, maps:get(appends, Stats)),
    ?assertEqual(2, maps:get(r_redirect, Stats)).

%% A participant can temporarily lose voting capability while recovering or while a
%% finality cert arrives before its block. Unsigned local work and authenticated
%% relay attempts are held until readiness returns. If recovery
%% replaces that volatile destination window, the source reconnects and replays
%% its retained ordered prefix; no public retry is synthesized.
queued_work_survives_temporary_unready_state_test() ->
    Committee = committee(2),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    [{Author, AuthorId}] = [P || {Pub, _} = P <- Committee, Pub =/= Me],
    Tx = signed_tx(<<"t">>, <<"recovering-queue">>,
                   [{assert, {{recovering, queued}, true}}], {Author, AuthorId}),
    Now = quod_time:mono_ms(),
    Recovering = st(
                   #{self => Me, id => MyId, validators => Validators,
                     sync => unconfirmed, slot => 3, history_head => {3, <<1:256>>},
                     eng => root_engine(3),
                     ingress =>
                         [{relayed, Author, 4, Tx, Now}]}),
    Origin4 =
        quod_simplex:test_relay_origin(Author, 4, Tx, Recovering),
    Origin5 =
        quod_simplex:test_relay_origin(Author, 5, Tx, Recovering),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:test_route(entry, Origin4, Tx, Recovering)),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:test_route(drain, Origin4, Tx, Recovering)),
    ?assertEqual(redirect,
                 quod_simplex:test_route(entry, Origin5, Tx, Recovering)),
    {Held, []} = quod_simplex:test_drain(Recovering),
    {1, _, _, [{relayed, RecoveringId, _}]} =
        quod_simplex:test_ingress(Held),
    ?assertEqual(Tx#transaction.tx_id, RecoveringId),
    Ready = quod_simplex:test_state_set(sync, ready, Held),
    ?assert(quod_simplex:test_ingress_needs_drain(Held, Ready)),
    {Drained, _} = quod_simplex:test_drain(Ready),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual(1, maps:get(appends, quod_simplex:stats_map(Drained))).

%% Shared and per-author bounds: overflow is the only remaining live source of busy.
%% A foreign author reaches this node only over the signed relay, so its park rides
%% the relayed entry; the flooding author's overflow never blocks anyone else's seat.
ingress_overflow_and_author_cap_test() ->
    Committee = committee(2),
    Validators = pubs(Committee),
    %% the node that leads the blocked-time floor (slot 6) — local items park HERE
    {Me, Id} = lists:keyfind(quod_simplex:leader(6, Validators), 1, Committee),
    [{Other, OtherId}] = [P || {Pub, _} = P <- Committee, Pub =/= Me],
    Blocked = st(#{self => Me, id => Id, validators => Validators, sync => ready,
                   slot => 3, history_head => {3, quod_simplex:block_hash(blk(3))},
                   eng => notarized_prefix(Committee, 3, 5)}),
    %% Fill one author to its fair-share cap (64). Planting the queue directly
    %% isolates the queue bounds from source-side target selection.
    S64 = quod_simplex:test_state_set(
            ingress,
            [{local, {self(), make_ref()}, lt(N, Me),
              quod_time:mono_ms() + N} || N <- lists:seq(1, 64)],
            Blocked),
    {64, _, #{Me := 64}, _} = quod_simplex:test_ingress(S64),
    %% the 65th from the SAME author overflows busy; another author still parks
    FromB = {self(), make_ref()},
    {S65, A65} = quod_simplex:test_append(FromB, lt(65, Me), S64),
    ?assert(lists:member({reply, FromB, {error, busy}}, A65)),
    ?assertEqual(1, maps:get(ingress_overflow, quod_simplex:stats_map(S65))),
    OtherTx = signed_tx(<<"t">>, <<"other-park">>,
                        [{assert, {{other, fact}, true}}], {Other, OtherId}),
    {S66, []} = quod_simplex:test_relayed_append(
                  Other, OtherTx, S65),
    {65, _, #{Other := 1}, _} = quod_simplex:test_ingress(S66).

%% TTL expiry fails VISIBLY (busy) and walks only the queue head — a stalled cluster
%% must never silently hold callers hostage.
ingress_ttl_expires_visibly_test() ->
    {Me, Id} = id(),
    Old = quod_time:mono_ms() - 60000,
    From = {self(), make_ref()},
    S = st(#{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             history_head => {3, quod_simplex:block_hash(blk(3))},
             eng => notarized_prefix([{Me, Id}], 3, 5)}),
    {Parked, []} = quod_simplex:test_append(From, lt($e, Me), S),
    %% age the single parked item by rebuilding it with an old enqueue stamp
    Aged = st(#{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
                history_head => {3, quod_simplex:block_hash(blk(3))},
             eng => notarized_prefix([{Me, Id}], 3, 5),
                ingress => [{local, From, lt($e, Me), Old}]}),
    {1, _, _, _} = quod_simplex:test_ingress(Aged),
    Expired = quod_simplex:test_expire_ingress(Aged),
    {0, 0, _, []} = quod_simplex:test_ingress(Expired),
    {_, ExpectRef} = From,
    receive {ExpectRef, Reply} -> ?assertEqual({error, busy}, Reply)
    after 0 -> ?assert(false) end,
    ?assertEqual(1, maps:get(ingress_expired, quod_simplex:stats_map(Expired))),
    ?assertEqual(1, maps:get(r_busy, quod_simplex:stats_map(Expired))),
    %% the fresh twin above must NOT have expired anything
    Fresh = quod_simplex:test_expire_ingress(Parked),
    {1, _, _, _} = quod_simplex:test_ingress(Fresh).

%% Forward-on-rotation: at drain, a local item whose next slot belongs to another
%% leader is signed once and relayed — with the relay deadline anchored at the ORIGINAL
%% enqueue time, so queue time counts against the caller's end-to-end budget.
drain_forwards_to_next_leader_with_anchored_deadline_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    NotLeader4 = hd([P || {P, _} = P4 <- Committee,
                          element(1, P4) =/= quod_simplex:leader(4, Validators)]),
    {Me, MyId} = lists:keyfind(NotLeader4, 1, Committee),
    TargetLeader = quod_simplex:leader(4, Validators),
    Anchor = quod_time:mono_ms() - 3000,   %% parked 3s ago
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, history_head => {3, <<1:256>>}, eng => root_engine(3),
             ingress => [{local, From, lt($f, Me), Anchor}]}),
    {Drained, []} = quod_simplex:test_drain(S),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual(1, maps:get(ingress_forwarded, quod_simplex:stats_map(Drained))),
    %% the relay is pending toward leader(4) with its deadline anchored at the ORIGINAL
    %% enqueue time — park time counts against the caller's budget, not on top of it
    ?assertEqual(
       {[], [], [], []},
       quod_simplex:test_link_peers(Drained)),
    ?assertEqual(
       {[], [], [TargetLeader]},
       quod_simplex:test_relay_link_peers(Drained)),
    [{_AttemptId, Target, 4, Deadline}] =
        quod_simplex:test_relay_pending(Drained),
    ?assertEqual(TargetLeader, Target),
    ?assert(Deadline =< Anchor + 32000),                  %% anchored: ~Anchor + 31s
    ?assert(Deadline < quod_time:mono_ms() + 30000).      %% NOT re-anchored at drain time

%% A fresh author lane targets the earliest slot that can still accept it. The
%% target slot is explicit and therefore cannot be reinterpreted by the receiver.
origin_routes_to_earliest_seat_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    ExpectedTarget = quod_simplex:leader(4, Validators),
    {Me, MyId} = hd([P || {Pub, _} = P <- Committee,
                          Pub =/= ExpectedTarget]),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, history_head => {3, <<1:256>>},
             eng => root_engine(3)}),
    {Sent, []} = quod_simplex:test_append(From, lt($g, Me), S),
    {0, 0, _, []} = quod_simplex:test_ingress(Sent),
    [{_AttemptId, Target, 4, _Deadline}] =
        quod_simplex:test_relay_pending(Sent),
    ?assertEqual(ExpectedTarget, Target),
    %% A live entry is not a drain forward.
    ?assertEqual(0, maps:get(ingress_forwarded, quod_simplex:stats_map(Sent))).

%% Placement is about filling the earliest block, independent of author identity.
%% Aggregation can be moved out of the consensus process later; routing must not
%% manufacture empty slots merely to distribute mailbox work.
all_authors_target_earliest_seat_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Targets =
        [begin
             S = st(#{self => Author, id => AuthorId,
                      validators => Validators, sync => ready,
                      slot => 3, history_head => {3, <<1:256>>},
                      eng => root_engine(3)}),
             case quod_simplex:test_route(entry, local, lt($d, Author), S) of
                 {collect, 4} -> quod_simplex:leader(4, Validators);
                 {relay, Target, 4} -> Target
             end
         end || {Author, AuthorId} <- Committee],
    ?assertEqual(
       lists:duplicate(length(Committee), quod_simplex:leader(4, Validators)),
       Targets).

%% Notarization opens the next proposal view before the parent is durable.
%% Its elected leader may collect the second material write immediately.
origin_collects_at_the_notarized_frontier_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(5, Validators), 1, Committee),
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(3)), 3, 0})),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, history_head => {3, <<1:256>>}, eng => E2}),
    {Collected, Actions} = quod_simplex:test_append(From, lt($g, Me), S),
    ?assertMatch([{{timeout, batch}, _, {flush_batch, 5}}], Actions),
    ?assertMatch(#{count := 1}, quod_simplex:test_batch(Collected)),
    ?assertEqual({0, 0, #{}, []}, quod_simplex:test_ingress(Collected)),
    ?assertEqual([], quod_simplex:test_relay_pending(Collected)),
    assert_no_reply(From).

%% Every parked item sits under an armed head watchdog: for each blocked cause the
%% reconciled head_progress is non-idle (the liveness invariant behind park-not-poll).
parked_ingress_implies_armed_watchdog_test() ->
    {Me, Id} = id(), Committee = [{Me, Id}],
    Root = quod_ledger:block_ref(blk(3)),
    Empty = quod_simplex:eng_new(?DOMAIN, [Me],{Root, 3, 0}),
    Base = #{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             history_head => {3, element(3, Root)}, eng => Empty},
    MTx = signed_tx(<<"t">>, <<"barrier">>, [pa(Me)], {Me, Id}),
    MBlock = block({?FIXTURE_ERA, 4}, Root, 4, {batch, [MTx]}),
    {Offered, _} = quod_simplex:eng_offer({block, MBlock}, Empty),
    {Barrier, _} = feed_shares(supports(MBlock, Committee, 1), Offered),
    lists:foreach(fun(Override) ->
        {Parked, []} = quod_simplex:test_append({self(), make_ref()}, lt($h, Me),
            st(maps:merge(Base, Override))),
        ?assertMatch({1, _, _, _}, quod_simplex:test_ingress(Parked)),
        ?assertNotEqual(idle, quod_simplex:test_progress(
            quod_simplex:reconcile_head_progress(Parked)))
    end, [#{eng => notarized_prefix(Committee, 3, 5)},
          #{local_proposal => {4, quod_simplex:block_hash(blk(4))}},
          #{eng => Barrier}]).

%% A pre-signed relayed change whose sequence fell below the floor is STALE_SEQ —
%% retryable by contract — never terminal bad_change.
stale_seq_is_retryable_test() ->
    [{A, IdA}] = Committee = committee(1),
    Signed = signed_tx_seq(<<"t">>, <<"stale">>, 2,
                           [{assert, {{stale, fact}, true}}], {A, IdA}),
    S = st(#{self => A, id => IdA, validators => pubs(Committee), sync => ready,
             slot => 5, history_head => {5, <<1:256>>}, eng => root_engine(0),
             relay_conns => #{A => {self(), make_ref()}},
             author_seqs => #{A => 9}}),   %% committed floor already past seq 2
    {S1, []} = quod_simplex:test_relayed_append(A, Signed, S),
    %% The relay result stays on the dedicated ingress stream. Consensus
    %% transport state remains completely untouched.
    ?assertMatch(
       {relay_result, _SubmissionId, _AttemptId, _CommitteeId,
        _TargetSlot, {error, stale_seq}},
       receive_relay_control(<<"t">>)),
    ?assertEqual({[], [], [], []}, quod_simplex:test_link_peers(S1)),
    ?assertEqual({[A], [], []},
                 quod_simplex:test_relay_link_peers(S1)),
    %% counted as a ROUTING RACE, never as malformed input — r_bad is the loadtest's
    %% "malformed workload" alarm and must stay quiet for retryable races
    ?assertEqual(1, maps:get(r_stale, quod_simplex:stats_map(S1))),
    ?assertEqual(0, maps:get(r_bad, quod_simplex:stats_map(S1))).

%% A protocol-readiness dip can occur after the ordinary Prolog proof. Keep
%% that unsigned request under its original queue deadline through recovery.
local_append_survives_recovery_before_signing_test() ->
    {Me, Id} = id(),
    From = {self(), make_ref()},
    Tx = lt($i, Me),
    S = st(#{self => Me, id => Id, validators => [Me], sync => unconfirmed,
             slot => 3, history_head => {3, <<1:256>>},
             archive_tip => {{?FIXTURE_ERA, 3, <<1:256>>}, 0},
             eng => root_engine(3)}),
    {Parked, []} = quod_simplex:test_append(From, Tx, S),
    {1, _, _, [{local, TxId, Arrival}]} = quod_simplex:test_ingress(Parked),
    ?assertEqual(Tx#transaction.tx_id, TxId),
    ?assertEqual([], quod_simplex:test_custody(Parked)),
    ?assertEqual(0, maps:get(appends, quod_simplex:stats_map(Parked))),
    assert_no_reply(From),
    Reseated = quod_simplex:reseat_engine(Parked),
    ?assertEqual(quod_simplex:test_ingress(Parked), quod_simplex:test_ingress(Reseated)),
    {Held, []} = quod_simplex:test_drain(Reseated),
    ?assertEqual([], quod_simplex:test_custody(Held)),
    Ready = quod_simplex:test_state_set(sync, ready, Held),
    ?assert(quod_simplex:test_ingress_needs_drain(Held, Ready)),
    {Drained, _} = quod_simplex:test_drain(Ready),
    ?assertMatch({0, 0, _, []}, quod_simplex:test_ingress(Drained)),
    ?assertEqual(1, maps:get(appends, quod_simplex:stats_map(Drained))),
    ?assertEqual(1, length(quod_simplex:test_custody(Drained))),
    ?assert(is_integer(Arrival)),
    assert_no_reply(From).

%% Delivery can race the selected slot closing. The destination rejects that
%% attempt; the origin treats the response as a hint and retargets its retained
%% submission after observing local exclusion.
closed_target_slot_is_rejected_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    L4 = quod_simplex:leader(4, Validators),
    {Me, MyId} = lists:keyfind(L4, 1, Committee),
    [{Author, AuthorId} | _] =
        [P || {Pub, _} = P <- Committee,
              Pub =/= Me],
    Tx = signed_tx(<<"t">>, <<"closed">>, [{assert, {{closed, fact}, true}}],
                   {Author, AuthorId}),
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(3)), 3, 0})),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    Closed = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                  slot => 3, history_head => {3, <<1:256>>}, eng => E2}),
    ?assert(quod_simplex:proposal_visible(4, Closed)),
    ClosedOrigin =
        quod_simplex:test_relay_origin(Author, 4, Tx, Closed),
    ?assertEqual(redirect,
                 quod_simplex:test_route(entry, ClosedOrigin, Tx, Closed)),
    {Rejected, []} = quod_simplex:test_relayed_append(
                       Author, 4, Tx, Closed),
    {0, 0, #{}, []} = quod_simplex:test_ingress(Rejected),
    ?assertEqual(1, maps:get(r_redirect, quod_simplex:stats_map(Rejected))).

%% The pure decision function, cell by cell: exact target-slot ownership, the
%% barrier override, and FIFO egress.
route_decision_cells_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    L = fun(Slot) -> quod_simplex:leader(Slot, Validators) end,
    Outside = L(7),
    {Me, MyId} = lists:keyfind(Outside, 1, Committee),
    [{Author, AuthorId} | _] = [P || {Pub, _} = P <- Committee, Pub =/= Me],
    Tx = signed_tx(<<"t">>, <<"cell">>, [{assert, {{cell, fact}, true}}],
                   {Author, AuthorId}),
    Open = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                slot => 3, history_head => {3, <<1:256>>}, eng => root_engine(3)}),
    Origin4 = quod_simplex:test_relay_origin(Author, 4, Tx, Open),
    Origin7 = quod_simplex:test_relay_origin(Author, 7, Tx, Open),
    %% This node does not own target slot 4, so it refuses that placement.
    ?assertEqual(redirect,
                 quod_simplex:test_route(entry, Origin4, Tx, Open)),
    %% It does own target slot 7 and may safely hold it until that slot opens.
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:test_route(entry, Origin7, Tx, Open)),
    %% The same exact-slot rule holds while the pipeline is full.
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, history_head => {3, quod_simplex:block_hash(blk(3))},
                   eng => notarized_prefix(Committee, 3, 5)}),
    BlockedOrigin7 =
        quod_simplex:test_relay_origin(Author, 7, Tx, Blocked),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:test_route(entry, BlockedOrigin7, Tx, Blocked)),
    %% Another participant accepts only the slot it actually owns.
    {Far, FarId} = lists:keyfind(L(9), 1, Committee),
    BlockedFar = st(#{self => Far, id => FarId, validators => Validators,
                      sync => ready, slot => 3, history_head => {3, quod_simplex:block_hash(blk(3))},
                      eng => notarized_prefix(Committee, 3, 5)}),
    FarTx = signed_tx(<<"t">>, <<"cellf">>, [{assert, {{cellf, fact}, true}}],
                      {Author, AuthorId}),
    FarOrigin =
        quod_simplex:test_relay_origin(Author, 9, FarTx, BlockedFar),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:test_route(entry, FarOrigin, FarTx, BlockedFar)),
    %% consensus barrier: park UNCONDITIONALLY, both origins — the
    %% post-adoption schedule is unknowable until the committee block commits
    {MPub, MId} = id(),
    MTx = signed_tx(<<"t">>, <<"mb">>, [pa(MPub)], {MPub, MId}),
    MBlock = block({?FIXTURE_ERA, 4}, quod_ledger:block_ref(blk(3)), (blk(3))#block.height + 1, {batch, [MTx]}),
    {EngB0, _} = quod_simplex:eng_offer({block, MBlock},
                                        quod_simplex:eng_new(?DOMAIN, [MPub],{quod_ledger:block_ref(blk(3)), 3, 0})),
    {BarrierEng, _} = feed_shares(
                        [quod_simplex:make_share(?DOMAIN,
                           support, {?FIXTURE_ERA, 4}, quod_simplex:block_hash(MBlock), MId)],
                        EngB0),
    Barrier = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, history_head => {3, <<1:256>>}, eng => BarrierEng}),
    BarrierOrigin =
        quod_simplex:test_relay_origin(Author, 7, Tx, Barrier),
    ?assertEqual({park, barrier},
                 quod_simplex:test_route(entry, BarrierOrigin, Tx, Barrier)),
    ?assertEqual({park, barrier},
                 quod_simplex:test_route(entry, local, lt($m, Me), Barrier)),
    %% FIFO egress: with a live queue a local ENTRY joins the tail (ordered dispatch),
    %% while the DRAIN pass relays that same item to the first seat's leader
    Queued = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                  slot => 3, history_head => {3, <<1:256>>}, eng => root_engine(3),
                  ingress => [{local, {self(), make_ref()}, lt($q, Me),
                               quod_time:mono_ms()}]}),
    ?assertEqual({park, fifo},
                 quod_simplex:test_route(entry, local, lt($n, Me), Queued)),
    ?assertEqual({relay, L(4), 4},
                 quod_simplex:test_route(drain, local, lt($q, Me), Queued)).

%% The round-phase probe follows an own proposal: stamped when the proposal seals
%% (mono-ms, notarization mark initially none), then removed when the archive
%% owns that protocol prefix. Material height never serves as the probe key.
round_probe_lifecycle_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = committee(3), Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    Base = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                slot => 500, history_head => {500, <<1:256>>},
                eng => quod_simplex:eng_new(?DOMAIN, Validators, {{?FIXTURE_ERA, 3, <<1:256>>}, 500, 0})}),
    ?assertEqual(#{}, quod_simplex:test_round_probe(Base)),
    F1 = {self(), make_ref()}, F2 = {self(), make_ref()},
    Pending = quod_simplex:test_state_set(ingress,
        [{local, F1, lt($p, Me), quod_time:mono_ms()},
         {local, F2, lt($q, Me), quod_time:mono_ms()}], Base),
    {Proposed, _} = quod_simplex:test_drain(Pending),
    ?assertMatch(#{4 := {At, none}} when is_integer(At), quod_simplex:test_round_probe(Proposed)),
    {_, _, _, _, Block} = quod_simplex:test_dtx_round(4, Proposed),
    Notarized = quod_simplex:engine_step(
        [{share, Share} || Share <- supports(Block, Committee, 3)], Proposed),
    ?assertMatch(#{4 := {At, Mark}} when is_integer(At) andalso is_integer(Mark),
                 quod_simplex:test_round_probe(Notarized)),
    Head = quod_ledger:block_ref(Block),
    Archived = quod_simplex:test_state_set(archive_tip, {Head, Block#block.timestamp}, Notarized),
    Finalized = quod_simplex:finalize_protocol(Head, Archived),
    ?assertEqual(#{}, quod_simplex:test_round_probe(Finalized)),
    assert_no_reply(F1), assert_no_reply(F2).

%% Creation owns the one-lane invariant: a future call site cannot silently add
%% a different target or slot to the map projected into the ingress view.
relay_lane_creation_rejects_divergent_target_test() ->
    Target4 = <<1:256>>,
    Target5 = <<2:256>>,
    S0 = st(#{}),
    Era = maps:get(era, quod_simplex:test_protocol_position(S0)),
    {ok, S1} = quod_simplex:test_put_pending_relay(Target4, 4, S0),
    {ok, S2} = quod_simplex:test_put_pending_relay(Target4, 4, S1),
    ?assertEqual(
       [{Target4, 4}, {Target4, 4}],
       lists:sort([{Target, Slot}
                   || {_AttemptId, Target, Slot, _Deadline} <-
                          quod_simplex:test_relay_pending(S2)])),
    ?assertEqual(
       {error, {relay_lane_conflict,
                {Target4, 4, Era},
                {Target5, 5, Era}}},
       quod_simplex:test_put_pending_relay(Target5, 5, S2)),
    NewEra = crypto:hash(sha256, <<"new-relay-lane-view">>),
    NewView =
        quod_simplex:test_state_set(eng,
            quod_simplex:eng_new(?DOMAIN, [ ], {{NewEra, 0, <<1:256>>}, 3, 0}), S2),
    ?assertEqual(
       {error, {relay_lane_conflict,
                {Target4, 4, Era},
                {Target4, 4, NewEra}}},
       quod_simplex:test_put_pending_relay(Target4, 4, NewView)).

%% A defensive relay-lane conflict cannot classify retained content as skipped.
%% Keep the exact signed submission ready; once routed onto the extant lane it
%% must proceed internally without a public reply or a new signature.
retained_custody_relay_lane_conflict_defers_without_reply_test() ->
    {Leader5, From, SubmissionId, Submission, Deadline, Ready} = ready_custody_fixture($c),
    Validators = maps:get(committee, quod_simplex:test_state_projection(Ready)),
    Leader6 = quod_simplex:leader(6, Validators),
    {ok, WithExistingLane} =
        quod_simplex:test_put_pending_relay(Leader5, 5, Ready),
    ExistingPending =
        quod_simplex:test_relay_pending(WithExistingLane),

    {Deferred, []} =
        quod_simplex:test_relay_custody(
          SubmissionId, Leader6, 6, WithExistingLane),
    ?assertEqual(
       ExistingPending, quod_simplex:test_relay_pending(Deferred)),
    ?assertEqual(
       [{SubmissionId, 1, Submission, ready, Deadline, 1}],
       quod_simplex:test_custody(Deferred)),
    ?assertEqual(0, maps:get(r_bad, quod_simplex:stats_map(Deferred))),
    assert_no_reply(From),

    %% The restored ready key is live, not merely retained in the custody map.
    {Retried, []} = quod_simplex:test_drain_custody(Deferred),
    [{SubmissionId, 1, Submission,
      {relay, _AttemptId, Leader5, 5, _CommitteeId}, Deadline, 2}] =
        quod_simplex:test_custody(Retried),
    ?assertEqual(2, length(quod_simplex:test_relay_pending(Retried))),
    assert_no_reply(From).

%% Readiness loss pauses retained custody. A no-progress drain must return
%% without releasing the caller, then wake on the existing capability edge.
retained_custody_unready_route_defers_without_reply_test() ->
    {Target, From, SubmissionId, Submission, Deadline, Ready} = ready_custody_fixture($d),
    Era = maps:get(era, quod_simplex:test_protocol_position(Ready)),
    Unready = quod_simplex:test_state_set(sync, unconfirmed, Ready),
    {Deferred, []} = drain_custody_within(Unready),
    ?assertEqual([], quod_simplex:test_relay_pending(Deferred)),
    ?assertEqual([{SubmissionId, 1, Submission, ready, Deadline, 1}],
                 quod_simplex:test_custody(Deferred)),
    Stats = quod_simplex:stats_map(Deferred),
    ?assertEqual(1, maps:get(custody_ready, Stats)),
    ?assertEqual(0, maps:get(r_bad, Stats)),
    ?assertEqual(0, maps:get(r_busy, Stats)),
    assert_no_reply(From),
    Restored = quod_simplex:test_state_set(sync, ready, Deferred),
    Retried = running_state(quod_simplex:test_keep_progress_transition(Deferred, Restored)),
    ?assertMatch([{SubmissionId, 1, Submission,
                  {relay, _, Target, 5, Era}, Deadline, 2}],
                 quod_simplex:test_custody(Retried)),
    ?assertEqual(1, length(quod_simplex:test_relay_pending(Retried))),
    assert_no_reply(From).

%% Relay ownership has no compiled population threshold. More rows than the
%% retired 2048-entry cap cannot refuse an already-owned signed submission.
retained_custody_relay_has_no_population_cap_test() ->
    {Target, From, SubmissionId, Submission, Deadline, Ready} =
        ready_custody_fixture($e),
    Full =
        lists:foldl(
          fun(_, Acc) ->
                  {ok, Next} =
                      quod_simplex:test_put_pending_relay(
                        Target, 5, Acc),
                  Next
          end, Ready, lists:seq(1, 2048)),
    ExistingPending = quod_simplex:test_relay_pending(Full),
    ?assertEqual(2048, length(ExistingPending)),
    CommitteeId = maps:get(era, quod_simplex:test_protocol_position(Full)),
    CustodyAttemptId =
        quod_transaction:relay_attempt_id(
          <<"t">>, SubmissionId, CommitteeId, 5, Target),
    ?assertNot(lists:keymember(CustodyAttemptId, 1, ExistingPending)),

    {Retried, []} = drain_custody_within(Full),
    [{SubmissionId, 1, Submission,
      {relay, _AttemptId, Target, 5, _CommitteeId}, Deadline, 2}] =
        quod_simplex:test_custody(Retried),
    ?assertEqual(2049, length(quod_simplex:test_relay_pending(Retried))),
    RetriedStats = quod_simplex:stats_map(Retried),
    ?assertEqual(0, maps:get(custody_ready, RetriedStats)),
    ?assertEqual(0, maps:get(r_bad, RetriedStats)),
    ?assertEqual(0, maps:get(r_busy, RetriedStats)),
    assert_no_reply(From).

%% A stale exact attempt collision is distinct from lane divergence: the
%% retained submission must neither overwrite the pending owner nor release its
%% caller. Removing that exact entry while another same-lane relay remains must
%% wake the real keep_progress drain even though lane and capacity stay stable.
retained_custody_duplicate_attempt_defers_and_wakes_test() ->
    {Target, From, SubmissionId, Submission, Deadline, Ready} =
        ready_custody_fixture($f),
    CommitteeId = maps:get(era, quod_simplex:test_protocol_position(Ready)),

    %% Derive the collision through the real relay-placement path, then copy
    %% only its opaque pending map onto the original ready state. This avoids a
    %% test-side reconstruction drifting from the production AttemptId recipe.
    {Placed, []} =
        quod_simplex:test_relay_custody(
          SubmissionId, Target, 5, Ready),
    [{AttemptId, Target, 5, Deadline}] =
        quod_simplex:test_relay_pending(Placed),
    ?assertEqual(
       quod_transaction:relay_attempt_id(
         <<"t">>, SubmissionId, CommitteeId, 5, Target),
       AttemptId),
    {ok, WithOther} =
        quod_simplex:test_put_pending_relay(Target, 5, Placed),
    PendingBefore =
        quod_simplex:test_relay_pending(WithOther),
    ?assertEqual(2, length(PendingBefore)),
    [OtherAttemptId] =
        [Id || {Id, _, 5, _} <- PendingBefore,
               Id =/= AttemptId],
    Collision =
        quod_simplex:test_copy_relay_pending(WithOther, Ready),

    {Deferred, []} = drain_custody_within(Collision),
    DeferredPending =
        quod_simplex:test_relay_pending(Deferred),
    ?assertEqual(2, length(DeferredPending)),
    ?assert(lists:keymember(AttemptId, 1, DeferredPending)),
    ?assert(lists:keymember(OtherAttemptId, 1, DeferredPending)),
    ?assertEqual(
       [{SubmissionId, 1, Submission, ready, Deadline, 1}],
       quod_simplex:test_custody(Deferred)),
    DeferredStats = quod_simplex:stats_map(Deferred),
    ?assertEqual(1, maps:get(custody_ready, DeferredStats)),
    ?assertEqual(0, maps:get(r_bad, DeferredStats)),
    ?assertEqual(0, maps:get(r_busy, DeferredStats)),
    assert_no_reply(From),

    Relieved =
        quod_simplex:test_remove_pending_relay(
          AttemptId, Deferred),
    [{OtherAttemptId, Target, 5, _OtherDeadline}] =
        quod_simplex:test_relay_pending(Relieved),
    Retried =
        running_state(
          quod_simplex:test_keep_progress_transition(
            Deferred, Relieved)),
    [{SubmissionId, 1, Submission,
      {relay, RetriedAttemptId, Target, 5, CommitteeId}, Deadline, 2}] =
        quod_simplex:test_custody(Retried),
    ?assertEqual(AttemptId, RetriedAttemptId),
    RetriedPending =
        quod_simplex:test_relay_pending(Retried),
    ?assertEqual(2, length(RetriedPending)),
    ?assert(lists:keymember(AttemptId, 1, RetriedPending)),
    ?assert(lists:keymember(OtherAttemptId, 1, RetriedPending)),
    assert_no_reply(From).

%% Demotion is not authoritative exclusion: the old exact relay attempt may
%% already commit under the adopted committee. Retain its immutable submission
%% to the original deadline, with no redirect, malformed alarm, or public retry.
retained_custody_demotion_remains_ambiguous_until_deadline_test() ->
    {Ns, OldCommitteeId, Slot, From, Target, Validators,
     SubmissionId, AttemptId, _Frame, Sent} =
        outbound_fixture(<<"custody-demotion">>),
    [{SubmissionId, 1, Submission,
      {relay, AttemptId, Target, Slot, OldCommitteeId}, Deadline, 1}] =
        quod_simplex:test_custody(Sent),
    {ok, Change = #transaction{author = Author}} =
        decode_submission(Ns, Submission),

    %% Also pin the defensive sibling: after custody, a changed local validity
    %% view is ambiguity, never retroactive bad input.
    Capable =
        quod_simplex:test_state_set(validators, [Author], Sent),
    ?assert(quod_simplex:may_vote(Capable)),
    ?assertEqual(
       {park, awaiting_turn},
       quod_simplex:test_route(
         drain, {custody, SubmissionId},
         Change#transaction{origin = {<<"other">>, <<0:256>>}}, Capable)),

    Remaining = lists:delete(Author, Validators),
    NewCommitteeId =
        crypto:hash(sha256, <<"custody-demotion-new-view">>),
    ?assertNotEqual(OldCommitteeId, NewCommitteeId),
    Demoted =
        quod_simplex:test_state_set(
          eng, quod_simplex:eng_new(?DOMAIN, Remaining,{{NewCommitteeId, 0, <<1:256>>}, 3, 0}),
          quod_simplex:test_state_set(
            validators, Remaining, Sent)),
    {keep_state, Parked, Actions} =
        quod_simplex:test_keep_progress_transition(Sent, Demoted),
    ?assertNot(lists:keymember(reply, 1, Actions)),
    ?assertEqual([], quod_simplex:test_relay_pending(Parked)),
    ?assertEqual(
       [{SubmissionId, 1, Submission, ready, Deadline, 1}],
       quod_simplex:test_custody(Parked)),
    ParkedStats = quod_simplex:stats_map(Parked),
    ?assertEqual(1, maps:get(custody_ready, ParkedStats)),
    ?assertEqual(0, maps:get(r_bad, ParkedStats)),
    ?assertEqual(0, maps:get(r_redirect, ParkedStats)),
    ?assertEqual(0, maps:get(r_stale, ParkedStats)),
    ?assertEqual({Parked, []}, quod_simplex:test_drain_custody(Parked)),
    assert_no_reply(From),

    Expired = quod_simplex:test_expire_custody(Parked),
    ?assertEqual([], quod_simplex:test_custody(Expired)),
    ?assertEqual([], quod_simplex:test_relay_pending(Expired)),
    {_, ExpectRef} = From,
    receive
        {ExpectRef, Reply} ->
            ?assertEqual({error, not_in_charge, unavailable}, Reply)
    after 0 ->
        ?assert(false)
    end,
    assert_no_reply(From).

ready_custody_fixture(TxSuffix) ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader4 = quod_simplex:leader(4, Validators),
    Target = quod_simplex:leader(5, Validators),
    {Leader4, Leader4Id} = lists:keyfind(Leader4, 1, Committee),
    From = {self(), make_ref()},
    S = st(#{self => Leader4, id => Leader4Id,
             validators => Validators, sync => ready,
             slot => 3, history_head => {3, <<1:256>>},
             eng => quod_simplex:eng_new(?DOMAIN, Validators, {{?FIXTURE_ERA, 3, <<1:256>>}, 3, 0})}),
    {Collected, _BatchActions} =
        quod_simplex:test_append(From, lt(TxSuffix, Leader4), S),
    [{SubmissionId, 1, Submission, {local, 4}, Deadline, 1}] =
        quod_simplex:test_custody(Collected),
    Advanced = quod_simplex:engine_step(
        [{share, complaint_share(4, Member)} || {Pub, _} = Member <- Committee,
                                               Pub =/= Leader4], Collected),
    Ready = quod_simplex:reconcile_custody_lane(Advanced),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(Ready),
    {Target, From, SubmissionId, Submission, Deadline, Ready}.

admission_change_retires_exact_signed_custody_test() ->
    {_Ns, _CommitteeId, _Slot, From, _Target, Validators,
     _SubmissionId, _AttemptId, _Frame, Sent} =
        outbound_fixture(<<"admission-retired">>),
    [Author] = quod_simplex:test_custody_authors(Sent),
    ?assert(lists:member(Author, Validators)),
    [Other | _] = Validators -- [Author],
    OtherOld = quod_simplex:test_author_admission(Other),
    Unrelated = quod_simplex:test_retire_changed_admissions(
                  #{Other => OtherOld}, #{Other => <<98:256>>}, Sent),
    ?assertEqual(quod_simplex:test_custody(Sent),
                 quod_simplex:test_custody(Unrelated)),
    ?assertEqual(quod_simplex:test_relay_pending(Sent),
                 quod_simplex:test_relay_pending(Unrelated)),
    Old = quod_simplex:test_author_admission(Author),
    Retired = quod_simplex:test_retire_changed_admissions(
                #{Author => Old}, #{Author => <<99:256>>}, Sent),
    ?assertEqual([], quod_simplex:test_custody(Retired)),
    ?assertEqual([], quod_simplex:test_relay_pending(Retired)),
    {_, ReplyRef} = From,
    receive
        {ReplyRef, Reply} ->
            ?assertEqual({error, not_in_charge, unavailable}, Reply)
    after 0 ->
        ?assert(false)
    end.

%% A committee-view change can race a locally collected custody lane before
%% the normal reconciliation hook retires it. The next ordinary write must wait
%% unsigned for that transition; a lane mismatch is placement state, not a
%% malformed transaction and therefore must not increment r_bad or reply.
committee_view_lane_conflict_parks_without_bad_change_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Me = quod_simplex:leader(4, Validators),
    {Me, MyId} = lists:keyfind(Me, 1, Committee),
    OldCommitteeId =
        crypto:hash(sha256, <<"placement-conflict-old-view">>),
    NewCommitteeId =
        crypto:hash(sha256, <<"placement-conflict-new-view">>),
    From1 = {self(), make_ref()},
    From2 = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators,
             committee_id => OldCommitteeId,
             sync => ready, slot => 3, history_head => {3, <<1:256>>},
             eng => root_engine(3)}),
    {Collected, _BatchActions} =
        quod_simplex:test_append(From1, lt($v, Me), S),
    [{_SubmissionId, 1, _Submission, {local, 4},
      _Deadline, 1}] =
        quod_simplex:test_custody(Collected),
    NewView =
        quod_simplex:test_state_set(
          eng, quod_simplex:eng_new(?DOMAIN, Validators, {{NewCommitteeId, 0, <<1:256>>}, 3, 0}), Collected),
    Next = lt($w, Me),
    ?assertEqual(
       {park, awaiting_turn},
       quod_simplex:test_route(entry, local, Next, NewView)),

    {Parked, []} =
        quod_simplex:test_append(From2, Next, NewView),
    [{_SameSubmissionId, 1, _SameSubmission, {local, 4},
      _SameDeadline, 1}] =
        quod_simplex:test_custody(Parked),
    {1, _, #{Me := 1}, [{local, NextId, _}]} =
        quod_simplex:test_ingress(Parked),
    ?assertEqual(Next#transaction.tx_id, NextId),
    ?assertEqual(0, maps:get(r_bad, quod_simplex:stats_map(Parked))),
    {StillParked, _} = quod_simplex:test_drain(Parked),
    {1, _, #{Me := 1}, [{local, NextId, _}]} =
        quod_simplex:test_ingress(StillParked),
    ?assertEqual(0, maps:get(r_bad, quod_simplex:stats_map(StillParked))),
    assert_no_reply(From1),
    assert_no_reply(From2).

%% A burst stays on one exact-slot lane while that slot is open. Once the local
%% frontier sees it close, later sequences queue until the old lane resolves.
stable_relay_lane_preserves_author_order_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Target4 = quod_simplex:leader(4, Validators),
    Target5 = quod_simplex:leader(5, Validators),
    Me = hd(Validators -- [Target4, Target5]),
    {Me, MyId} = lists:keyfind(Me, 1, Committee),
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, history_head => {3, <<1:256>>}, eng => root_engine(3)}),
    From1 = {self(), make_ref()},
    From2 = {self(), make_ref()},
    {Sent1, []} = quod_simplex:test_append(From1, lt($r, Me), S),
    [{Attempt1, LaneTarget, 4, Deadline}] =
        quod_simplex:test_relay_pending(Sent1),
    [{Submission1, 1, Signed1,
      {relay, Attempt1, LaneTarget, 4, _CommitteeId}, Deadline, 1}] =
        quod_simplex:test_custody(Sent1),
    %% Locally, slot 4 closes and a fresh route would now choose leader(5).
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(3)), 3, 0})),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    Advanced = quod_simplex:test_state_set(eng, E2, Sent1),
    ?assert(quod_simplex:proposal_visible(4, Advanced)),
    ?assertEqual(
       {relay, Target5, 5},
       quod_simplex:test_route(entry, local, lt($x, Me),
                          quod_simplex:test_state_set(eng, E2, S))),
    Later = lt($s, Me),
    {Sent2, []} =
        quod_simplex:test_append(From2, Later, Advanced),
    [{Attempt1, LaneTarget, 4, Deadline}] =
        quod_simplex:test_relay_pending(Sent2),
    {1, _, _, [{local, LaterId, _}]} = quod_simplex:test_ingress(Sent2),
    ?assertEqual(Later#transaction.tx_id, LaterId),
    Finalized = quod_simplex:reconcile_custody_lane(Sent2),
    ?assertEqual([], quod_simplex:test_relay_pending(Finalized)),
    [{Submission1, 1, Signed1, ready, Deadline, 1}] =
        quod_simplex:test_custody(Finalized),
    assert_no_reply(From1),
    assert_no_reply(From2),

    %% Retained signed work drains before the later unsigned queue entry. The
    %% first placement gets a new attempt id but keeps the exact signed envelope
    %% and original deadline.
    Open = quod_simplex:test_state_set(
             outbox, #{},
             Finalized),
    {Retargeted, []} = quod_simplex:test_drain_custody(Open),
    [{Attempt2, Target5, 5, Deadline}] =
        quod_simplex:test_relay_pending(Retargeted),
    ?assertNotEqual(Attempt1, Attempt2),
    [{Submission1, 1, Signed1,
      {relay, Attempt2, Target5, 5, _CommitteeId2}, Deadline, 2}] =
        quod_simplex:test_custody(Retargeted),
    {1, _, _, [{local, LaterId, _}]} =
        quod_simplex:test_ingress(Retargeted),

    %% Only after sequence 1 is placed again may sequence 2 leave the unsigned
    %% queue; both then share the same exact lane in author order.
    {SentBoth, []} = quod_simplex:test_drain(Retargeted),
    {0, 0, _, []} = quod_simplex:test_ingress(SentBoth),
    ?assertEqual(
       [1, 2],
       lists:sort([Seq || {_Id, Seq, _Submission, _Placement,
                           _Deadline, _Attempts} <-
                              quod_simplex:test_custody(SentBoth)])),
    ?assertEqual(
       [{Target5, 5}, {Target5, 5}],
       lists:sort([{Target, Slot}
                   || {_Id, _Seq, _Submission,
                       {relay, _Attempt, Target, Slot, _View},
                       _Deadline, _Attempts} <-
                          quod_simplex:test_custody(SentBoth)])),
    ?assertEqual(
       1, maps:get(ingress_retargets,
                   quod_simplex:stats_map(SentBoth))),

    %% Source submissions never enter the bounded consensus outbox. When the
    %% link opens, the complete retained prefix is reconstructed from custody
    %% and emitted in author-sequence order, with the exact signed envelopes.
    ?assertEqual(#{}, quod_simplex:test_outbox(SentBoth)),
    RelayChan = quod_simplex:test_relay_chan(SentBoth),
    {keep_state, Linked, _Actions} =
        quod_simplex:running(
          info, {link_up, Target5, RelayChan, self()}, SentBoth),
    Frames = [receive_ordered_frame(), receive_ordered_frame()],
    BySeq =
        maps:from_list(
          [{Seq, Signed}
           || {_Id, Seq, Signed, _Placement, _Deadline, _Attempts} <-
                  quod_simplex:test_custody(SentBoth)]),
    DecodedPrefix =
        [begin
             {relay,
              {relay_submit, _SubmissionId, _AttemptId, _View,
               5, Signed, _Carrier}} =
                 quod_relay:decode_relay_frame(Frame, <<"t">>),
             {ok, Tx} =
                 decode_submission(<<"t">>, Signed),
             {Tx#transaction.author_seq, Signed}
         end || Frame <- Frames],
    ?assertEqual(
       [{1, maps:get(1, BySeq)}, {2, maps:get(2, BySeq)}],
       DecodedPrefix),
    ?assertEqual(#{}, quod_simplex:test_outbox(Linked)),
    flush_unordered_link_frames(),
    assert_no_reply(From1),
    assert_no_reply(From2).

%% A lane may hold several exact signed placements. Expiring one member must
%% retain the lane while others remain; advancing its view must derive the
%% complete remaining cohort from custody, make every member ready, and clear
%% the old lane so the cohort can retarget together.
same_lane_partial_completion_and_view_change_retargets_cohort_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Target4 = quod_simplex:leader(4, Validators),
    Target5 = quod_simplex:leader(5, Validators),
    Me = hd(Validators -- [Target4, Target5]),
    {Me, MyId} = lists:keyfind(Me, 1, Committee),
    Base = st(#{self => Me, id => MyId, validators => Validators,
                sync => ready, slot => 3, history_head => {3, <<1:256>>},
                eng => root_engine(3)}),
    ExpiredFrom = {self(), make_ref()},
    ExpiredAt = quod_time:mono_ms() - 60000,
    Parked = quod_simplex:test_state_set(
               ingress,
               [{local, ExpiredFrom, lt($1, Me), ExpiredAt}],
               Base),
    {Sent1, []} = quod_simplex:test_drain(Parked),
    From2 = {self(), make_ref()},
    From3 = {self(), make_ref()},
    From4 = {self(), make_ref()},
    {Sent2, []} = quod_simplex:test_append(From2, lt($2, Me), Sent1),
    {Sent3, []} = quod_simplex:test_append(From3, lt($3, Me), Sent2),
    {Sent4, []} = quod_simplex:test_append(From4, lt($4, Me), Sent3),
    ?assertEqual(
       [1, 2, 3, 4],
       lists:sort(
         [Seq || {_Id, Seq, _Submission, _Placement,
                  _Deadline, _Attempts} <-
                     quod_simplex:test_custody(Sent4)])),

    %% Make slot 4 visibly closed. With a surviving lane, a fresh local write
    %% must remain behind it instead of independently choosing slot 5.
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer(
                {block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(3)), 3, 0})),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    {keep_state, OneExpired, _TickActions} =
        quod_simplex:running({timeout, tick}, tick, Sent4),
    receive
        {Tag, Reply} when Tag =:= element(2, ExpiredFrom) ->
            ?assertEqual({error, not_in_charge, unavailable}, Reply)
    after 0 ->
        ?assert(false)
    end,
    Remaining = quod_simplex:test_custody(OneExpired),
    ?assertEqual([2, 3, 4],
                 lists:sort([Seq || {_Id, Seq, _Submission, _Placement,
                                      _Deadline, _Attempts} <- Remaining])),
    ?assert(
       lists:all(
         fun({_Id, _Seq, _Submission,
              {relay, _Attempt, ActualTarget, 4, _View},
              _Deadline, 1}) -> ActualTarget =:= Target4;
            (_) -> false
         end, Remaining)),
    ?assertEqual(
       {park, fifo},
       quod_simplex:test_route(
         entry, local, lt($5, Me), quod_simplex:test_state_set(eng, E2, OneExpired))),

    Finalized = quod_simplex:reconcile_custody_lane(quod_simplex:test_state_set(eng, E2, OneExpired)),
    Ready = quod_simplex:test_custody(Finalized),
    ?assertEqual([2, 3, 4],
                 lists:sort([Seq || {_Id, Seq, _Submission, ready,
                                      _Deadline, 1} <- Ready])),
    ?assertEqual([], quod_simplex:test_relay_pending(Finalized)),

    {Retargeted, []} =
        quod_simplex:test_drain_custody(
          Finalized),
    RetargetedCustody = quod_simplex:test_custody(Retargeted),
    ?assertEqual([2, 3, 4],
                 lists:sort([Seq || {_Id, Seq, _Submission, _Placement,
                                      _Deadline, _Attempts} <-
                                         RetargetedCustody])),
    ?assert(
       lists:all(
         fun({_Id, _Seq, _Submission,
              {relay, _Attempt, ActualTarget, 5, _View},
              _Deadline, 2}) -> ActualTarget =:= Target5;
            (_) -> false
         end, RetargetedCustody)),
    ?assertEqual(3, length(quod_simplex:test_relay_pending(Retargeted))),
    assert_no_reply(From2),
    assert_no_reply(From3),
    assert_no_reply(From4).

%% Ready custody always precedes this author's later unsigned ingress. In
%% particular, a large lower sequence that cannot fit the remaining active
%% batch must stop a later small write that otherwise could join and commit.
ready_lower_sequence_capacity_block_prevents_local_overtake_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Target4 = quod_simplex:leader(4, Validators),
    Me = quod_simplex:leader(5, Validators),
    ?assertNotEqual(Target4, Me),
    {Me, MyId} = lists:keyfind(Me, 1, Committee),
    [{FillerAuthor, FillerId} | _] =
        [Member || {Pub, _} = Member <- Committee, Pub =/= Me],
    Lower = bind_test_id(
        #transaction{
           tx_id = <<>>, origin = {<<"t">>, <<0:256>>},
           proof_id = <<0:256>>, plan_digest = <<0:256>>,
           goal = durable_goal(ready_lower), result = durable_result(),
           author = Me, sig = none, read_check = #{},
           diff =
               [{assert,
                 {{blob, binary:copy(<<1>>, 120000)}, true}}]}),
    Filler =
        signed_tx(
          <<"t">>, <<"ready-order-filler">>,
          [{assert, {{blob, binary:copy(<<2>>, 220000)}, true}}],
          {FillerAuthor, FillerId}),
    Small = bind_test_id(
        #transaction{
           tx_id = <<>>, origin = {<<"t">>, <<0:256>>},
           proof_id = <<0:256>>, plan_digest = <<0:256>>,
           goal = durable_goal(later_small), result = durable_result(),
           author = Me, sig = none, read_check = #{},
           diff = [{assert, {{later, small}, true}}]}),
    Current =
        st(#{self => Me, id => MyId, validators => Validators,
             sync => ready, slot => 4, history_head => {4, <<1:256>>},
             eng => root_engine(4)}),

    %% The small write genuinely fits beside the filler when no retained lower
    %% sequence owns priority.
    {ControlBatch, _} =
        quod_simplex:test_relayed_append(
          FillerAuthor, Filler, Current),
    ?assertEqual(
       {collect, 5},
       quod_simplex:test_route(entry, local, Small, ControlBatch)),

    LowerFrom = {self(), make_ref()},
    Before =
        st(#{self => Me, id => MyId, validators => Validators,
             sync => ready, slot => 3, history_head => {3, <<1:256>>},
             eng => root_engine(3)}),
    {Placed, []} =
        quod_simplex:test_append(LowerFrom, Lower, Before),
    [{SubmissionId, 1, Submission, _Placement, Deadline, 1}] =
        quod_simplex:test_custody(Placed),
    Ready =
        quod_simplex:reconcile_custody_lane(
          quod_simplex:test_state_set(eng, notarized_prefix(Committee, 3, 4), Placed)),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(Ready),
    {ok, SignedLower} =
        decode_submission(<<"t">>, Submission),
    {WithBatch, _} =
        quod_simplex:test_relayed_append(
          FillerAuthor, Filler, Ready),
    ?assertEqual(
       {park, awaiting_turn},
       quod_simplex:test_route(
         drain, {custody, SubmissionId}, SignedLower, WithBatch)),

    SmallFrom = {self(), make_ref()},
    {ParkedSmall, []} =
        quod_simplex:test_append(SmallFrom, Small, WithBatch),
    {1, _, #{Me := 1}, [{local, SmallId, _}]} =
        quod_simplex:test_ingress(ParkedSmall),
    ?assertEqual(Small#transaction.tx_id, SmallId),
    {CustodyHeld, []} =
        quod_simplex:test_drain_custody(ParkedSmall),
    {StillHeld, []} = quod_simplex:test_drain(CustodyHeld),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(StillHeld),
    {1, _, #{Me := 1}, [{local, SmallId, _}]} =
        quod_simplex:test_ingress(StillHeld),
    ?assertEqual(1, maps:get(appends, quod_simplex:stats_map(StillHeld))),
    assert_no_reply(LowerFrom),
    assert_no_reply(SmallFrom).

%% Membership shares exact-byte custody with other transactions. Both admit
%% and remove survive complaint-driven placement changes without a new request,
%% signature, sequence or deadline. These are owner callback tests; the QUIC
%% membership-leader-loss case supplies live consensus/application acceptance.
membership_view_change_preserves_signed_custody_test() ->
    Ns = <<"t">>, Committee = committee(4), Validators = pubs(Committee),
    View = 4, Target = quod_simplex:leader(View, Validators),
    NextTarget = quod_simplex:leader(View + 1, Validators),
    {Me, MyId} = hd([M || {Pub, _} = M <- Committee,
                         Pub =/= Target, Pub =/= NextTarget]),
    {NewMember, _} = id(), RemovedMember = hd(Validators -- [Me]),
    Cases = [{admit, [pa(NewMember)]}, {remove, [rm(RemovedMember)]}],
    lists:foreach(fun({Kind, Diff}) ->
        lists:foreach(fun(Completion) ->
            From = {self(), make_ref()},
            Change = bind_test_id(#transaction{
                tx_id = <<>>, origin = {Ns, <<0:256>>},
                proof_id = <<0:256>>, plan_digest = <<0:256>>,
                goal = durable_goal({membership, Kind}), result = durable_result(),
                author = Me, sig = none, read_check = #{}, diff = Diff}),
            Engine = quod_simplex:eng_new(?DOMAIN, Validators, {{?FIXTURE_ERA, View - 1, <<1:256>>}, 3, 0}),
            S = st(#{self => Me, id => MyId, validators => Validators,
                relay_conns => #{Target => {self(), make_ref()},
                                 NextTarget => {self(), make_ref()}},
                sync => ready, slot => 3, history_head => {3, <<1:256>>}, eng => Engine}),
            {Sent, []} = quod_simplex:test_append(From, Change, S),
            {relay, {relay_submit, Id, Attempt, ?FIXTURE_ERA, View, Submission, _}} =
                quod_relay:decode_relay_frame(receive_ordered_frame(), Ns),
            ?assert(quod_transaction:verify_submission(Submission)),
            {ok, Signed} = decode_submission(Ns, Submission),
            ?assert(quod_transaction:verify(test_binding(Ns, Me), Signed)),
            ?assertEqual({Me, 1, Diff},
                         {Signed#transaction.author, Signed#transaction.author_seq, Signed#transaction.diff}),
            [{Id, 1, Submission, {relay, Attempt, Target, View, ?FIXTURE_ERA}, Deadline, 1}] =
                quod_simplex:test_custody(Sent),
            {Advanced, _} = feed_shares(
                [complaint_share(View, M) || M <- take(3, Committee)], Engine),
            Ready = quod_simplex:reconcile_custody_lane(
                quod_simplex:test_state_set(eng, Advanced, Sent)),
            assert_no_reply(From),
            {Placed, []} = quod_simplex:test_drain_custody(Ready),
            NextView = View + 1,
            {relay, {relay_submit, Id, NextAttempt, ?FIXTURE_ERA, NextView, Submission, _}} =
                quod_relay:decode_relay_frame(receive_ordered_frame(), Ns),
            ?assertNotEqual(Attempt, NextAttempt),
            [{Id, 1, Submission, {relay, NextAttempt, NextTarget, NextView, ?FIXTURE_ERA}, Deadline, 2}] =
                quod_simplex:test_custody(Placed),
            assert_no_reply(From),
            {Done, Expected} = case Completion of
                committed ->
                    Committed = quod_simplex:test_resolve_committed_submissions({batch, [Signed]}, 4, Placed),
                    {quod_simplex:test_resolve_committed_submissions({batch, [Signed]}, 4, Committed), {ok, 4}};
                expired ->
                    %% Prolog maps this existing internal deadline result to
                    %% the exact caller's outcome_unknown reference.
                    {quod_simplex:test_expire_custody(Placed), {error, not_in_charge, unavailable}}
            end,
            ?assertEqual([], quod_simplex:test_custody(Done)),
            receive {Tag, Reply} when Tag =:= element(2, From) -> ?assertEqual(Expected, Reply)
            after 0 -> error(membership_custody_not_resolved) end,
            assert_no_reply(From)
        end, [committed, expired])
    end, Cases).

%% A local collection overtaken by complaint progress retains the exact signed
%% submission and caller deadline for its next protocol placement.
local_view_change_retains_exact_submission_test() ->
    {Target, From, SubmissionId, Submission, Deadline, Ready} = ready_custody_fixture($l),
    assert_no_reply(From),
    {Placed, []} = quod_simplex:test_drain_custody(Ready),
    [{AttemptId, Target, 5, Deadline}] = quod_simplex:test_relay_pending(Placed),
    [{SubmissionId, 1, Submission,
      {relay, AttemptId, Target, 5, ?FIXTURE_ERA}, Deadline, 2}] = quod_simplex:test_custody(Placed),
    assert_no_reply(From).

%% A request for the next slot may arrive early and wait at that exact proposer;
%% when the parent approves it enters the intended block without another hop.
future_target_drains_at_declared_slot_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Holder = quod_simplex:leader(5, Validators),
    {Holder, HolderId} = lists:keyfind(Holder, 1, Committee),
    [{Author, AuthorId} | _] = [P || {Pub, _} = P <- Committee, Pub =/= Holder],
    Tx = signed_tx(<<"t">>, <<"custody">>,
                   [{assert, {{custody, stable}, true}}], {Author, AuthorId}),
    Before = st(#{self => Holder, id => HolderId, validators => Validators,
                  sync => ready, slot => 3, history_head => {3, <<1:256>>},
                  eng => root_engine(3)}),
    {Held, []} = quod_simplex:test_relayed_append(
                   Author, 5, Tx, Before),
    {1, _, _, _} = quod_simplex:test_ingress(Held),
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer(
                {block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(3)), 3, 0})),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    AtTurn = quod_simplex:test_state_set(eng, E2, Held),
    {Drained, _} = quod_simplex:test_drain(AtTurn),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual(1, maps:get(appends, quod_simplex:stats_map(Drained))).

%% A target refusal is only a recovery hint: a Byzantine destination cannot
%% decide an operation's result or advance protocol placement. Locally verified
%% protocol progress can place the exact signed submission at the next seat;
%% only committed material can resolve its outcome.
stale_target_hint_cannot_decide_placement_or_outcome_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader4 = quod_simplex:leader(4, Validators),
    Leader5 = quod_simplex:leader(5, Validators),
    {Me, MyId} =
        hd([P || {Pub, _} = P <- Committee,
                 Pub =/= Leader4, Pub =/= Leader5]),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, history_head => {3, <<1:256>>}, eng => root_engine(3),
             ingress => [{local, From, lt($u, Me), quod_time:mono_ms()}]}),
    {Sent, []} = quod_simplex:test_drain(S),
    [{AttemptId, Target, 4, Deadline}] =
        quod_simplex:test_relay_pending(Sent),
    [{SubmissionId, 1, Submission, _Placement, Deadline, 1}] =
        quod_simplex:test_custody(Sent),
    Hinted = quod_simplex:test_relay_result(
               Target, AttemptId, {error, not_in_charge, none}, Sent),
    [{AttemptId, Target, 4, _Deadline, true}] =
        quod_simplex:test_relay_pending_detail(Hinted),
    Tag = element(2, From),
    receive
        {Tag, _ForgedOutcome} -> ?assert(false)
    after 0 ->
        ok
    end,
    Finalized = quod_simplex:reconcile_custody_lane(
        quod_simplex:test_state_set(eng, notarized_prefix(Committee, 3, 4), Hinted)),
    ?assertEqual([], quod_simplex:test_relay_pending(Finalized)),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(Finalized),
    assert_no_reply(From),
    {Retargeted, []} =
        quod_simplex:test_drain_custody(
          Finalized),
    [{Attempt2, _Target2, 5, Deadline}] =
        quod_simplex:test_relay_pending(Retargeted),
    ?assertNotEqual(AttemptId, Attempt2),
    [{SubmissionId, 1, Submission, _Placement2, Deadline, 2}] =
        quod_simplex:test_custody(Retargeted),
    assert_no_reply(From).

%% Receipt acknowledgement marks the exact retained attempt without creating a
%% retry clock. A spoofed acknowledgement from another peer cannot alter it.
relay_accepted_is_exact_and_timer_free_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    ImmediateLeader = quod_simplex:leader(4, Validators),
    {Me, MyId} = hd([P || {Pub, _} = P <- Committee,
                          Pub =/= ImmediateLeader]),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, history_head => {3, <<1:256>>}, eng => root_engine(3),
             ingress => [{local, From, lt($t, Me), quod_time:mono_ms()}]}),
    {Sent, []} = quod_simplex:test_drain(S),
    [{AttemptId, Target, 4, _Deadline, false}] =
        quod_simplex:test_relay_pending_detail(Sent),
    [Other | _] = Validators -- [Target],
    ?assertEqual(quod_simplex:test_relay_pending_detail(Sent),
                 quod_simplex:test_relay_pending_detail(
                   quod_simplex:test_relay_accepted(
                     Other, AttemptId, Sent))),
    Accepted =
        quod_simplex:test_relay_accepted(Target, AttemptId, Sent),
    [{AttemptId, Target, 4, _Deadline2, true}] =
        quod_simplex:test_relay_pending_detail(Accepted),
    ?assertEqual(1, maps:get(relay_accepted, quod_simplex:stats_map(Accepted))).

%% Duplicate requests are acknowledged again so a sender that missed the first
%% acknowledgement can observe receipt. Authentication precedes cache lookup.
duplicate_inflight_relay_is_acknowledged_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, _Validators,
     SubmissionId, AttemptId, Submit, S} =
        relay_receiver_fixture(<<"duplicate-inflight">>),
    {Accepted, _Actions} = quod_simplex:test_dispatch_relay(
                             Author, Submit, S),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId, CommitteeId, Slot},
       receive_relay_control(Ns)),
    {Acked, []} = quod_simplex:test_dispatch_relay(
                    Author, Submit, Accepted),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId, CommitteeId, Slot},
       receive_relay_control(Ns)),
    ?assertEqual(#{}, quod_simplex:test_outbox(Acked)),
    ?assertEqual(1, maps:get(relay_duplicates, quod_simplex:stats_map(Acked))).

%% An exact inflight attempt remains answerable after the current committee
%% view advances. Current-view equality gates first admission, not recovery.
inflight_attempt_is_answerable_after_view_change_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, Validators,
     SubmissionId, AttemptId, Submit, S} =
        relay_receiver_fixture(<<"serve-inflight">>),
    {Accepted, _Actions} =
        quod_simplex:test_dispatch_relay(Author, Submit, S),
    ?assertEqual(
       {[], [AttemptId], []},
       quod_simplex:test_relay_state_keys(Accepted)),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId,
        CommitteeId, Slot},
       receive_relay_control(Ns)),

    NewCommitteeId = crypto:hash(sha256, <<"later-view">>),
    Advanced =
        quod_simplex:test_state_set(
          eng, quod_simplex:eng_new(?DOMAIN, Validators, {{NewCommitteeId, 0, <<1:256>>}, 3, 0}), Accepted),
    {Duplicate, []} =
        quod_simplex:test_dispatch_relay(Author, Submit, Advanced),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId,
        CommitteeId, Slot},
       receive_relay_control(Ns)),
    ?assertEqual(#{}, quod_simplex:test_outbox(Duplicate)),
    ?assertEqual(
       1, maps:get(relay_duplicates, quod_simplex:stats_map(Duplicate))).

%% Completed attempts are cached by their immutable full relay reference. A
%% duplicate old-view submit is served from that stored context even after both
%% the local frontier and committee view have advanced.
cached_result_is_served_after_view_change_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, Validators,
     SubmissionId, AttemptId, Submit, S} =
        relay_receiver_fixture(<<"serve-cache">>),
    {Accepted, _} = quod_simplex:test_dispatch_relay(Author, Submit, S),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId, CommitteeId, Slot},
       receive_relay_control(Ns)),
    Completed = quod_simplex:test_reply_relay(Author, SubmissionId, AttemptId,
        CommitteeId, Slot, {error, skipped}, Accepted),
    ?assertEqual(
       {[], [], [AttemptId]},
       quod_simplex:test_relay_state_keys(Completed)),
    ?assertEqual(
       {relay_result, SubmissionId, AttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),

    Advanced =
        quod_simplex:test_state_set(
          eng, quod_simplex:eng_new(?DOMAIN, Validators, {{crypto:hash(sha256, <<"post-cache-view">>), 0, <<1:256>>}, 3, 0}),
          Completed),
    {Replayed, []} =
        quod_simplex:test_dispatch_relay(Author, Submit, Advanced),
    ?assertEqual(
       {relay_result, SubmissionId, AttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),
    ?assertEqual(#{}, quod_simplex:test_outbox(Replayed)).

%% After restart the destination has no cached attempt outcome. A closed
%% protocol position produces only a routing hint, regardless of material
%% height. The source must resolve its request from its own certified history.
destination_restart_refuses_closed_placement_without_history_reads_test_() ->
    [?_test(destination_restart_refuses_closed_placement(Height, Observer))
     || Height <- [2, 900], Observer <- [false, true]].

destination_restart_refuses_closed_placement(Height, Observer) ->
    {Ns, Era, View, Author, _Signer, Target, Validators,
     SubmissionId, AttemptId, Submit, Initial} = relay_receiver_fixture(<<"restart-placement">>),
    Root = {Era, View, <<92:256>>},
    Members = case Observer of true -> Validators -- [Target]; false -> Validators end,
    Restarted = quod_simplex:test_state_set(validators, Members,
        quod_simplex:test_state_set(eng, quod_simplex:eng_new(?DOMAIN, Members,{Root, Height, 0}),
            quod_simplex:test_state_set(archive_tip, {Root, 0},
                quod_simplex:test_state_set(history_head, {Height, <<93:256>>},
                    quod_simplex:test_state_set(slot, Height, Initial))))),
    ?assertEqual(not Observer, quod_simplex:is_participant(Restarted)),
    Payload = quod_relay:encode(Ns, Submit),
    {{keep_state, Rejected, _}, {call_count, Calls}} = tprof:profile(fun() ->
        quod_simplex:running(info,
            {quod_message, {{Author, ignored}, self()},
             quod_simplex:test_relay_chan(Restarted), Payload}, Restarted)
    end, #{type => call_count, report => return,
           pattern => [{quod_ledger_store, read_at, 2}, {quod_ledger_store, read_at, 3}], timeout => 5000}),
    ?assertEqual(0, lists:sum([N || {quod_ledger_store, read_at, _, Ps} <- Calls,
                                  {_, N, _} <- Ps])),
    ?assertEqual({relay_result, SubmissionId, AttemptId, Era, View,
                  {error, not_in_charge, none}}, receive_relay_control(Ns)),
    ?assertEqual({[], [], [AttemptId]}, quod_simplex:test_relay_state_keys(Rejected)),
    ?assertEqual(Height, element(1, quod_simplex:test_committed_store(Rejected))).

%% The transport peer must be the signed author before touching the attempt
%% cache. Neither pre-playing a valid envelope nor replaying its cached hint
%% permits another peer to receive or replace that result.
non_author_replay_cannot_poison_or_read_result_cache_test() ->
    {Ns, Era, View, Author, _Signer, Target, _Validators,
     SubmissionId, AttemptId, Submit, Initial} = relay_receiver_fixture(<<"non-author-replay">>),
    {Rejected, []} = quod_simplex:test_dispatch_relay(Target, Submit, Initial),
    ?assertEqual(Initial, Rejected),
    assert_no_relay_control(),
    {Accepted, _} = quod_simplex:test_dispatch_relay(Author, Submit, Rejected),
    ?assertEqual({relay_accepted, SubmissionId, AttemptId, Era, View},
                 receive_relay_control(Ns)),
    Cached = quod_simplex:test_reply_relay(Author, SubmissionId, AttemptId,
                                          Era, View, {ok, 501}, Accepted),
    Reply = {relay_result, SubmissionId, AttemptId, Era, View, {ok, 501}},
    ?assertEqual(Reply, receive_relay_control(Ns)),
    {RejectedCached, []} = quod_simplex:test_dispatch_relay(Target, Submit, Cached),
    ?assertEqual(Cached, RejectedCached),
    assert_no_relay_control(),
    {Repeated, []} = quod_simplex:test_dispatch_relay(Author, Submit, RejectedCached),
    ?assertEqual(Reply, receive_relay_control(Ns)),
    ?assertEqual(quod_simplex:test_relay_result_entries(Cached),
                 quod_simplex:test_relay_result_entries(Repeated)).

%% Even an authenticated transport peer claiming the envelope's author cannot
%% use a bad signature to prune/read/populate recovery state. Even a fully
%% archived protocol prefix grants no access before signature verification.
invalid_signature_precedes_cache_and_durable_recovery_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, Target, Validators,
     _SubmissionId, _AttemptId,
     {relay_submit, _, _, _, _, {submit, Author, Signature, Canonical}, Carrier},
     Initial} =
    relay_receiver_fixture(<<"invalid-before-recovery">>),
    InvalidSubmission = {submit, Author, flip1(Signature), Canonical},
    InvalidSubmissionId =
    quod_transaction:submission_id(InvalidSubmission),
    InvalidAttemptId =
    quod_transaction:relay_attempt_id(
      Ns, InvalidSubmissionId, CommitteeId, Slot, Target),
    InvalidSubmit =
    {relay_submit, InvalidSubmissionId, InvalidAttemptId, CommitteeId,
     Slot, InvalidSubmission, Carrier},
    Root = {CommitteeId, Slot, <<92:256>>},
    Durable = quod_simplex:test_state_set(archive_tip, {Root, 0},
    quod_simplex:test_state_set(eng, quod_simplex:eng_new(?DOMAIN, Validators, {Root, 900, 0}),
        quod_simplex:test_state_set(slot, 900, Initial))),
    SeedSubmissionId = <<16#A5:128>>,
    SeedAttemptId = <<16#5A:128>>,
    WithExpiredResult =
        quod_simplex:test_state_set(
          outbox, #{},
          quod_simplex:test_expire_relay_results(
            quod_simplex:test_reply_relay(
              Author, SeedSubmissionId, SeedAttemptId, CommitteeId,
              Slot, {error, skipped}, Durable))),
    ?assertEqual(
       {relay_result, SeedSubmissionId, SeedAttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),
    [{SeedAttemptId, {error, skipped}, ExpiredAt}] =
        quod_simplex:test_relay_result_entries(WithExpiredResult),
    ?assert(ExpiredAt =< quod_time:mono_ms()),

    {Rejected, []} =
        quod_simplex:test_dispatch_relay(
          Author, InvalidSubmit, WithExpiredResult),
    ?assertEqual(WithExpiredResult, Rejected),
    ?assertEqual(#{}, quod_simplex:test_outbox(Rejected)),
    ?assertEqual(
       {[], [], [SeedAttemptId]},
       quod_simplex:test_relay_state_keys(Rejected)),
    assert_no_relay_control(),

    %% The observer mailbox uses the same guarded recovery path after a
    %% proposer is demoted; it must not reintroduce the pre-verify lookup.
    Observer =
        quod_simplex:test_state_set(
          validators, Validators -- [Target], WithExpiredResult),
    ?assertEqual(false, quod_simplex:is_participant(Observer)),
    Payload = quod_relay:encode(Ns, InvalidSubmit),
    {keep_state, ObserverRejected, _Actions} =
        quod_simplex:running(
          info,
          {quod_message, {{Author, ignored}, self()},
           quod_simplex:test_relay_chan(Observer), Payload},
          Observer),
    ?assertEqual(
       quod_simplex:test_relay_result_entries(Observer),
       quod_simplex:test_relay_result_entries(ObserverRejected)),
    ?assertEqual(
       {[], [], [SeedAttemptId]},
       quod_simplex:test_relay_state_keys(ObserverRejected)),
    ?assertEqual(#{}, quod_simplex:test_outbox(ObserverRejected)),
    assert_no_relay_control().

%% One verified archive group settles both relay directions from exact signed
%% submissions. Protocol placement is separate from the resulting material
%% heights; recovery then drops volatile delivery hints, not durable outcomes.
catchup_window_settles_inbound_and_outbound_relays_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = committee(4), Validators = pubs(Committee),
    Self = quod_simplex:leader(1, Validators),
    Author = quod_simplex:leader(2, Validators),
    {Self, Signer} = lists:keyfind(Self, 1, Committee),
    {Author, AuthorSigner} = lists:keyfind(Author, 1, Committee),
    Ns = <<"relay:catchup-both">>,
    GenesisTx = quod_simplex:test_genesis_tx(
        #{committee => [{Pub, "localhost", 9001} || Pub <- Validators],
          external_predicate_modules => []}, Ns, Self, <<1:256>>),
    GenesisBlock = block({genesis, 0}, none, 1, {batch, [GenesisTx]}, 0),
    Genesis = quod_ledger:entry(1, GenesisBlock, none),
    Anchor = quod_simplex:block_hash(GenesisBlock), Identity = {Ns, Anchor},
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Dir = relay_store_dir("catchup_both_directions"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store1} = quod_ledger_store:append(Store0, {none, [Genesis]}),
    {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
    try
        {ok, P, _} = quod_ct:history_advance(
            Identity, Genesis, quod_simplex:history_projection(Identity), Index),
        Root = {Era, 0, Anchor} = maps:get(protocol_root, P),
        Binding = {Ns, Anchor, maps:get(Author, maps:get(admissions, P))},
        InboundUnsigned = quod_transaction:bind_id(Identity,
            (lt($v, Author))#transaction{origin = Identity, author_seq = 1, submitted_at = 1}),
        {ok, InboundTx} = quod_transaction:sign(Binding, InboundUnsigned, AuthorSigner),
        {ok, InboundSubmission} = quod_transaction:submission(Binding, InboundTx),
        InboundId = quod_transaction:submission_id(InboundSubmission),
        InboundAttempt = quod_transaction:relay_attempt_id(Ns, InboundId, Era, 1, Self),
        Submit = {relay_submit, InboundId, InboundAttempt, Era, 1, InboundSubmission, []},
        Initial = quod_simplex:test_install_projection(P,
            st(#{ns => Ns, self => Self, id => Signer, validators => Validators,
                 genesis_hash => Anchor, consensus_domain => Domain,
                 eng => quod_simplex:eng_new(Domain, Validators, {Root, 1, 0}),
                 archive_tip => {Root, 0}, store => Store1, phase_index => Index,
                 slot => 1, sync => ready, batch_window_ms => 0,
                 relay_conns => #{Author => {self(), make_ref()}}})),
        {WithInbound, _} = quod_simplex:test_dispatch_relay(Author, Submit, Initial),
        ?assertEqual({relay_accepted, InboundId, InboundAttempt, Era, 1}, receive_relay_control(Ns)),
        ?assert(quod_simplex:proposal_visible(1, WithInbound)),
        {_, _, _, _, B1} = quod_simplex:test_dtx_round(1, WithInbound),
        H1 = quod_simplex:block_hash(B1),
        Support = [quod_simplex:make_share(Domain, support, {Era, 1}, H1, Id)
                   || {_, Id} <- Committee],
        Notarized = quod_simplex:engine_step([{share, Sh} || Sh <- Support], WithInbound),
        ?assertMatch(#{view := 2}, quod_simplex:test_protocol_position(Notarized)),
        SourceFrom = {self(), make_ref()},
        SourceChange = quod_transaction:bind_id(Identity,
            (lt($w, Self))#transaction{origin = Identity}),
        {WithSource, []} = quod_simplex:test_append(SourceFrom, SourceChange, Notarized),
        [{SourceAttempt, Author, 2, Deadline}] = quod_simplex:test_relay_pending(WithSource),
        {relay, {relay_submit, SourceId, SourceAttempt, Era, 2, SourceSubmission, _}} =
            quod_relay:decode_relay_frame(receive_ordered_frame(), Ns),
        [{SourceId, 1, SourceSubmission, {relay, SourceAttempt, Author, 2, Era}, Deadline, 1}] =
            quod_simplex:test_custody(WithSource),
        SourceBinding = {Ns, Anchor, maps:get(Self, maps:get(admissions, P))},
        {ok, SourceTx} = quod_transaction:decode_verified_submission(SourceBinding, SourceSubmission),
        B2 = block({Era, 2}, quod_ledger:block_ref(B1), (B1)#block.height + 1, {batch, [SourceTx]}, B1#block.timestamp),
        H2 = quod_simplex:block_hash(B2),
        Commit = [quod_simplex:make_share(Domain, commit, {Era, 2}, H2, Id)
                  || {_, Id} <- Committee],
        {ok, Cert} = quod_simplex:form_cert(Domain, commit, {Era, 2}, H2, Commit, Validators),
        Entries = [quod_ledger:entry(2, B1, Cert), quod_ledger:entry(3, B2, Cert)],
        Bytes = [quod_ledger:block_bytes(B2), quod_ledger:block_bytes(B1)],
        {ok, P1, Delta, Summary} = quod_catchup:verify_forward_group(Identity, Entries, P, Index,
            {fun([]) -> done; ([B | Rest]) -> {ok, B, Rest} end, Bytes}),
        Source = {lists:sum([quod_ledger_store:proof_frame_size(B) || B <- Bytes]),
                  fun([]) -> done; ([B | Rest]) -> {B, Rest} end, Bytes},
        Group = #{entries => Entries, proof => Source, projection => P1,
                  delta => Delta, finality => Summary},
        {Recovered, ok} = quod_simplex:test_apply_catchup_window({recovery, self()}, Group, WithSource),
        {_, SourceTag} = SourceFrom,
        receive {SourceTag, Reply} -> ?assertEqual({ok, 3}, Reply) after 0 -> ?assert(false) end,
        ?assertEqual({relay_result, InboundId, InboundAttempt, Era, 1, {ok, 2}},
                     receive_relay_control(Ns)),
        ?assertEqual({[], [], []}, quod_simplex:test_relay_state_keys(Recovered)),
        ?assertEqual([], quod_simplex:test_custody(Recovered)),
        ?assertEqual({0, 0, #{}, []}, quod_simplex:test_ingress(Recovered)),
        {3, DurableStore} = quod_simplex:test_committed_store(Recovered),
        ?assertMatch(#entry{index = 3}, stored_entry_view(DurableStore, 3)),
        ?assertNotEqual(InboundId, SourceId),
        assert_no_reply(SourceFrom)
    after
        quod_dtx_phase_index:close(Index),
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

%% The protocol cutover is definitive: `{log,Ns}` accepts consensus only and
%% `{ingress,Ns}` accepts relay only. Neither wrong-channel frame may even
%% replace the other channel's authenticated generation.
relay_channel_cutover_is_strict_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, _Validators,
     SubmissionId, AttemptId, Submit, Initial} =
        relay_receiver_fixture(<<"strict-relay-channel">>),
    LogChan = term_to_binary({log, Ns}, [deterministic]),
    RelayChan = quod_simplex:test_relay_chan(Initial),
    RelayPayload = quod_relay:encode(Ns, Submit),
    ConsensusPayload =
        quod_simplex:encode(
          Ns, {readiness, Slot - 1, {?FIXTURE_ERA, 1, 0}, true}),

    RelayOnLog =
        running_state(
          quod_simplex:running(
            info,
            {quod_message, {{Author, ignored}, self()},
             LogChan, RelayPayload},
            Initial)),
    ?assertEqual(Initial, RelayOnLog),
    ConsensusOnRelay =
        running_state(
          quod_simplex:running(
            info,
            {quod_message, {{Author, ignored}, self()},
             RelayChan, ConsensusPayload},
            RelayOnLog)),
    ?assertEqual(Initial, ConsensusOnRelay),
    assert_no_relay_control(),

    Accepted =
        running_state(
          quod_simplex:running(
            info,
            {quod_message, {{Author, ignored}, self()},
             RelayChan, RelayPayload},
            ConsensusOnRelay)),
    ?assertEqual(
       {[], [AttemptId], []},
       quod_simplex:test_relay_state_keys(Accepted)),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId,
        CommitteeId, Slot},
       receive_relay_control(Ns)),
    ?assertEqual(#{}, quod_simplex:test_outbox(Accepted)).

%% A former committee member that owns neither a current destination attempt
%% nor an origin-side pending attempt has no relay capability. Reject it at the
%% authenticated ingress mailbox boundary, close that stream, and do not even
%% prune an expired cache entry (which would prove dispatch was reached).
removed_relay_source_is_rejected_before_dispatch_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, Validators,
     _SubmissionId, _AttemptId, Submit, Initial} =
        relay_receiver_fixture(<<"removed-relay-source">>),
    SeedSubmissionId = <<16#C1:128>>,
    SeedAttemptId = <<16#C2:128>>,
    Seeded =
        quod_simplex:test_expire_relay_results(
          quod_simplex:test_reply_relay(
            Author, SeedSubmissionId, SeedAttemptId, CommitteeId,
            Slot, {error, skipped}, Initial)),
    ?assertEqual(
       {relay_result, SeedSubmissionId, SeedAttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),
    Removed =
        quod_simplex:test_state_set(
          validators, Validators -- [Author], Seeded),
    ?assert(quod_simplex:is_participant(Removed)),
    {InLink, Token} = spawn_close_aware_link(),
    Payload = quod_relay:encode(Ns, Submit),
    {keep_state, Rejected} =
        quod_simplex:running(
          info,
          {quod_message, {{Author, ignored}, InLink},
           quod_simplex:test_relay_chan(Removed), Payload},
          Removed),
    await_link_closed(InLink, Token),
    ?assertEqual(Removed, Rejected),
    [{SeedAttemptId, {error, skipped}, ExpiredAt}] =
        quod_simplex:test_relay_result_entries(Rejected),
    ?assert(ExpiredAt =< quod_time:mono_ms()),
    assert_no_relay_control().

%% A destination can race local finality: by the time its valid result reaches
%% us, the exact pending attempt may already be gone. A still-current committee
%% member continues to own the shared ingress stream; dispatch safely ignores
%% the unmatched hint instead of resetting that stream.
late_current_member_result_does_not_close_ingress_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, _Validators,
     SubmissionId, AttemptId, _Submit, Initial} =
        relay_receiver_fixture(<<"late-current-result">>),
    {InLink, Token} = spawn_close_aware_link(),
    Monitor = erlang:monitor(process, InLink),
    Tracked =
        quod_simplex:test_state_set(
          relay_inbound_conns,
          #{Author => {InLink, Monitor}},
          Initial),
    Payload =
        quod_relay:encode(
          Ns,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot, {ok, Slot}}),
    {keep_state, Ignored, []} =
        quod_simplex:running(
          info,
          {quod_message, {{Author, ignored}, InLink},
           quod_simplex:test_relay_chan(Tracked), Payload},
          Tracked),
    {_, [Author], _} =
        quod_simplex:test_relay_link_peers(Ignored),
    assert_link_not_closed(InLink, Token),
    ensure_close_aware_link_closed(InLink, Token).

%% quod_conn may resolve several open_link waiters with the same stream pid.
%% Repeating that exact link_up is idempotent on both channels: it neither
%% replaces the maps nor closes the already-adopted live stream.
duplicate_same_pid_link_up_is_idempotent_test() ->
    [{Self, _SelfId}, {Peer, _PeerId}] = committee(2),
    {Consensus, ConsensusToken} = spawn_close_aware_link(),
    {Relay, RelayToken} = spawn_close_aware_link(),
    try
        S =
            st(#{self => Self, validators => [Self, Peer],
                 sync => ready, slot => 3, history_head => {3, <<1:256>>},
                 eng => root_engine(3),
                 conns =>
                     #{Peer =>
                           {Consensus,
                            erlang:monitor(process, Consensus)}},
                 relay_conns =>
                     #{Peer =>
                           {Relay,
                            erlang:monitor(process, Relay)}}}),
        LogChan = term_to_binary({log, <<"t">>}, [deterministic]),
        RelayChan = quod_simplex:test_relay_chan(S),
        AfterConsensus =
            running_state(
              quod_simplex:running(
                info, {link_up, Peer, LogChan, Consensus}, S)),
        AfterRelay =
            running_state(
              quod_simplex:running(
                info, {link_up, Peer, RelayChan, Relay},
                AfterConsensus)),
        ?assertEqual(
           quod_simplex:test_link_peers(S),
           quod_simplex:test_link_peers(AfterRelay)),
        ?assertEqual(
           quod_simplex:test_relay_link_peers(S),
           quod_simplex:test_relay_link_peers(AfterRelay)),
        assert_link_not_closed(Consensus, ConsensusToken),
        assert_link_not_closed(Relay, RelayToken)
    after
        ensure_close_aware_link_closed(Consensus, ConsensusToken),
        ensure_close_aware_link_closed(Relay, RelayToken)
    end.

%% Relay pruning keeps the union of committee, outbound-attempt, and inbound-
%% attempt owners. In particular, subtracting Self must not bind over the later
%% unions: that precedence bug removed an active peer when the same peer also
%% appeared in relay_pending, and discarded inflight-only peers entirely.
relay_pruning_retains_pending_and_inflight_owners_test() ->
    [{Self, SelfId}, {ActivePeer, _ActiveId},
     {InflightPeer, InflightId}] = committee(3),
    {ActivePid, ActiveToken} = spawn_stubborn_link(),
    {InflightPid, InflightToken} = spawn_stubborn_link(),
    try
        Base =
            st(#{self => Self, id => SelfId,
                 validators => [Self, ActivePeer, InflightPeer],
                 sync => ready, slot => 3, history_head => {3, <<1:256>>},
                 eng => root_engine(3),
                 relay_conns =>
                     #{ActivePeer =>
                           {ActivePid,
                            erlang:monitor(process, ActivePid)},
                       InflightPeer =>
                           {InflightPid,
                            erlang:monitor(process, InflightPid)}},
                 relay_dialing =>
                     #{ActivePeer => 101, InflightPeer => 202}}),
        {ok, WithPending} =
            quod_simplex:test_put_pending_relay(
              ActivePeer, 4, Base),
        InflightTx =
            signed_tx(
              <<"t">>, <<"prune-inflight-owner">>,
              [{assert, {{prune, inflight_owner}, true}}],
              {InflightPeer, InflightId}),
        {relayed, InflightRef} =
            quod_simplex:test_relay_origin(
              InflightPeer, 4, InflightTx, WithPending),
        InflightKey = make_ref(),
        MembershipAdvanced =
            quod_simplex:test_state_set(
              validators, [Self, ActivePeer], WithPending),
        Owned =
            quod_simplex:test_state_set(
              relay_inflight,
              #{InflightKey => InflightRef},
              MembershipAdvanced),
        [{_PendingAttemptId, ActivePeer, 4, _Deadline}] =
            quod_simplex:test_relay_pending(Owned),
        {[_PendingKey], [InflightKey], []} =
            quod_simplex:test_relay_state_keys(Owned),

        Pruned = quod_simplex:test_prune_relay_links(Owned),
        ExpectedPeers = lists:sort([ActivePeer, InflightPeer]),
        ?assertEqual(
           {ExpectedPeers, [], ExpectedPeers},
           quod_simplex:test_relay_link_peers(Pruned)),
        assert_stubborn_link_not_closed(ActivePid, ActiveToken),
        assert_stubborn_link_not_closed(InflightPid, InflightToken)
    after
        ensure_stubborn_link_closed(ActivePid, ActiveToken),
        ensure_stubborn_link_closed(InflightPid, InflightToken)
    end.

%% An ordered-send failure kills only the dedicated ingress stream. Its DOWN
%% and link_error events cannot remove consensus links, readiness, queued
%% evidence, or consensus dial state.
relay_transport_failure_isolated_from_consensus_test() ->
    [{Self, _SelfId}, {Peer, _PeerId}] = committee(2),
    {ConsensusOut, ConsensusOutToken} = spawn_close_aware_link(),
    {ConsensusIn, ConsensusInToken} = spawn_close_aware_link(),
    {RelayOut, RelayOutToken} = spawn_close_aware_link(),
    {RelayIn, RelayInToken} = spawn_close_aware_link(),
    try
        S =
            st(#{self => Self, validators => [Self, Peer],
                 sync => ready, slot => 3, history_head => {3, <<1:256>>},
                 eng => root_engine(3),
                 conns =>
                     #{Peer =>
                           {ConsensusOut,
                            erlang:monitor(process, ConsensusOut)}},
                 inbound_conns =>
                     #{Peer =>
                           {ConsensusIn,
                            erlang:monitor(process, ConsensusIn)}},
                 peer_readiness =>
                     #{Peer =>
                           {ConsensusIn, 3, {?FIXTURE_ERA, 1, 0}, true,
                            quod_time:mono_ms()}},
                 outbox => #{Peer => [<<"consensus-evidence">>]},
                 dialing => #{Peer => 101},
                 relay_conns =>
                     #{Peer =>
                           {RelayOut,
                            erlang:monitor(process, RelayOut)}},
                 relay_inbound_conns =>
                     #{Peer =>
                           {RelayIn,
                            erlang:monitor(process, RelayIn)}},
                 relay_dialing => #{Peer => 202}}),
        AfterDown =
            running_state(
              quod_simplex:running(
                info,
                {'DOWN', make_ref(), process, RelayOut,
                 {ordered_send_failed, send_queue_full}},
                S)),
        ?assertEqual(
           {[Peer], [Peer], [Peer], [Peer]},
           quod_simplex:test_link_peers(AfterDown)),
        ?assertEqual(
           {[], [Peer], [Peer]},
           quod_simplex:test_relay_link_peers(AfterDown)),
        RelayView = hd([V || V <- [4, 5],
                              quod_simplex:leader(V, [Self, Peer]) =:= Peer]),
        ?assertEqual({relay, Peer},
                     quod_simplex:test_dtx_slot_route(RelayView, AfterDown)),

        RelayChan = quod_simplex:test_relay_chan(S),
        AfterRelayError =
            running_state(
              quod_simplex:running(
                info, {link_error, Peer, RelayChan}, S)),
        ?assertEqual(
           {[Peer], [Peer], [Peer], [Peer]},
           quod_simplex:test_link_peers(AfterRelayError)),
        ?assertEqual(
           {[Peer], [Peer], []},
           quod_simplex:test_relay_link_peers(AfterRelayError)),

        LogChan = term_to_binary({log, <<"t">>}, [deterministic]),
        AfterLogError =
            running_state(
              quod_simplex:running(
                info, {link_error, Peer, LogChan}, S)),
        ?assertEqual(
           {[Peer], [Peer], [Peer], []},
           quod_simplex:test_link_peers(AfterLogError)),
        ?assertEqual(
           {[Peer], [Peer], [Peer]},
           quod_simplex:test_relay_link_peers(AfterLogError))
    after
        ensure_close_aware_link_closed(
          ConsensusOut, ConsensusOutToken),
        ensure_close_aware_link_closed(
          ConsensusIn, ConsensusInToken),
        ensure_close_aware_link_closed(
          RelayOut, RelayOutToken),
        ensure_close_aware_link_closed(
          RelayIn, RelayInToken)
    end.

%% Recovery invalidation must also retire, rather than synchronously close and
%% forget, an affected ingress generation. The old link deliberately ignores
%% `close`; while it remains alive, its already-queued relay frame must not
%% recreate the discarded inflight attempt. The real monitor DOWN is the only
%% event that removes the tombstone.
relay_recovery_invalidation_is_nonblocking_and_monotonic_test() ->
    {Ns, _CommitteeId, _Slot, Author, _AuthorId, _Target, _Validators,
     _SubmissionId, AttemptId, Submit, Initial} =
        relay_receiver_fixture(
          <<"recovery-retirement-barrier">>),
    {OldPid, OldToken} = spawn_stubborn_link(),
    OldRef = erlang:monitor(process, OldPid),
    try
        Linked =
            quod_simplex:test_state_set(
              relay_inbound_conns,
              #{Author => {OldPid, OldRef}},
              Initial),
        {WithInflight, _Actions} =
            quod_simplex:test_dispatch_relay(
              Author, Submit, Linked),
        ?assertEqual(
           {[], [AttemptId], []},
           quod_simplex:test_relay_state_keys(WithInflight)),
        _Accepted = receive_relay_control(Ns),

        {InvalidateUs, Invalidated} =
            timer:tc(
              fun() ->
                      quod_simplex:
                          test_invalidate_relay_generation(WithInflight)
              end),
        ?assert(InvalidateUs < 250000),
        await_stubborn_close_requested(OldPid, OldToken),
        ?assert(is_process_alive(OldPid)),
        ?assertEqual(
           {[Author], [], []},
           quod_simplex:test_relay_link_peers(Invalidated)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(Invalidated)),

        %% The peer is still a committee member and the exact attempt remains
        %% inflight in this focused helper state. Without the tombstone, this
        %% frame would re-adopt OldPid and emit another relay_accepted.
        RelayPayload = quod_relay:encode(Ns, Submit),
        AfterStale =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Author, ignored}, OldPid},
                 quod_simplex:test_relay_chan(Invalidated),
                 RelayPayload},
                Invalidated)),
        ?assertEqual(
           {[], [AttemptId], []},
           quod_simplex:test_relay_state_keys(AfterStale)),
        ?assertEqual(
           {[Author], [], []},
           quod_simplex:test_relay_link_peers(AfterStale)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AfterStale)),
        assert_no_relay_control(),

        OldDown =
            release_stubborn_link(OldPid, OldToken, OldRef),
        AfterOldDown =
            running_state(
              quod_simplex:running(
                info, OldDown, AfterStale)),
        ?assertEqual(
           [],
           quod_simplex:test_retired_inbound(AfterOldDown))
    after
        ensure_stubborn_link_closed(OldPid, OldToken)
    end.

%% Recovery invalidates only sources whose volatile relay ownership was
%% discarded. Their exact inbound generation is closed and forgotten; other
%% authenticated links and their readiness claims remain usable. A relay frame
%% already queued with the closed pid cannot resurrect the discarded attempt.
reseat_invalidates_only_relay_affected_inbound_generation_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, Target, Validators,
     SubmissionId, AttemptId, Submit, Initial} =
        relay_receiver_fixture(<<"reseat-generation">>),
    [KeepPeer1, KeepPeer2] = Validators -- [Target, Author],
    {AffectedPid, AffectedToken} = spawn_close_aware_link(),
    {AuthorConsensusPid, AuthorConsensusToken} =
        spawn_close_aware_link(),
    {KeepPid1, KeepToken1} = spawn_close_aware_link(),
    {KeepPid2, KeepToken2} = spawn_close_aware_link(),
    ConsensusLinks =
        #{Author => {AuthorConsensusPid, make_ref()},
          KeepPeer1 => {KeepPid1, make_ref()},
          KeepPeer2 => {KeepPid2, make_ref()}},
    RelayLinks =
        #{Author => {AffectedPid, make_ref()}},
    Readiness =
        #{Author =>
              {AuthorConsensusPid, Slot - 1, {?FIXTURE_ERA, 1, 0}, true,
               quod_time:mono_ms()},
          KeepPeer1 =>
              {KeepPid1, Slot - 1, true, quod_time:mono_ms()},
          KeepPeer2 =>
              {KeepPid2, Slot - 1, true, quod_time:mono_ms()}},
    try
        Linked =
            quod_simplex:test_state_set(
              peer_readiness, Readiness,
              quod_simplex:test_state_set(
                relay_inbound_conns, RelayLinks,
                quod_simplex:test_state_set(
                  inbound_conns, ConsensusLinks, Initial))),
        {WithInflight, _Actions} =
            quod_simplex:test_dispatch_relay(
              Author, Submit, Linked),
        ?assertEqual(
           {[], [AttemptId], []},
           quod_simplex:test_relay_state_keys(WithInflight)),
        ?assertEqual(
           {relay_accepted, SubmissionId, AttemptId,
            CommitteeId, Slot},
           receive_relay_control(Ns)),

        FutureSubmissionId = <<16#F1:128>>,
        FutureAttemptId = <<16#F2:128>>,
        HistoricalSubmissionId = <<16#A1:128>>,
        HistoricalAttemptId = <<16#A2:128>>,
        WithFutureResult =
            quod_simplex:test_reply_relay(
              Author, FutureSubmissionId, FutureAttemptId,
              CommitteeId, Slot + 1, {error, skipped}, WithInflight),
        ?assertEqual(
           {relay_result, FutureSubmissionId, FutureAttemptId,
            CommitteeId, Slot + 1, {error, skipped}},
           receive_relay_control(Ns)),
        WithResults =
            quod_simplex:test_state_set(
              outbox, #{},
              quod_simplex:test_reply_relay(
                KeepPeer1, HistoricalSubmissionId, HistoricalAttemptId,
                CommitteeId, Slot - 1, {error, skipped},
                WithFutureResult)),
        ?assertEqual(
           lists:sort([FutureAttemptId, HistoricalAttemptId]),
           [Key || {Key, _Reply, _Expires} <-
                       quod_simplex:test_relay_result_entries(WithResults)]),

        Reseated = quod_simplex:reseat_engine(WithResults),
        ?assertEqual({relay_result, SubmissionId, AttemptId, CommitteeId,
                      Slot, {error, not_in_charge, unavailable}},
                     receive_relay_control(Ns)),
        await_link_closed(AffectedPid, AffectedToken),
        ?assertNot(is_process_alive(AffectedPid)),
        ?assert(is_process_alive(AuthorConsensusPid)),
        ?assert(is_process_alive(KeepPid1)),
        ?assert(is_process_alive(KeepPid2)),
        {_, InboundPeers, _, _} =
            quod_simplex:test_link_peers(Reseated),
        ?assertEqual(
           lists:sort([Author, KeepPeer1, KeepPeer2]), InboundPeers),
        ?assertEqual(
           {[Author], [], []},
           quod_simplex:test_relay_link_peers(Reseated)),
        ?assertEqual(
           {[], [], []},
           quod_simplex:test_relay_state_keys(Reseated)),

        %% Every consensus/readiness generation survives the relay-only reset.
        RelayView = hd([V || V <- lists:seq(1, 4),
                              quod_simplex:leader(V, Validators) =:= Author]),
        ?assertEqual({relay, Author},
                     quod_simplex:test_dtx_slot_route(RelayView, Reseated)),

        QueuedPayload = quod_relay:encode(Ns, Submit),
        BeforeOldFrame =
            quod_simplex:test_relay_state_keys(Reseated),
        {keep_state, AfterOldFrame, _OldActions} =
            quod_simplex:running(
              info,
              {quod_message,
               {{Author, ignored}, AffectedPid},
               quod_simplex:test_relay_chan(Reseated), QueuedPayload},
              Reseated),
        ?assertEqual(
           BeforeOldFrame,
           quod_simplex:test_relay_state_keys(AfterOldFrame)),
        {_, AfterOldInboundPeers, _, _} =
            quod_simplex:test_link_peers(AfterOldFrame),
        ?assertEqual(InboundPeers, AfterOldInboundPeers)
    after
        ensure_close_aware_link_closed(AffectedPid, AffectedToken),
        ensure_close_aware_link_closed(
          AuthorConsensusPid, AuthorConsensusToken),
        ensure_close_aware_link_closed(KeepPid1, KeepToken1),
        ensure_close_aware_link_closed(KeepPid2, KeepToken2)
    end.

%% Replacing a live inbound generation is non-blocking and monotonic. The old
%% process deliberately ignores `close` and stays alive, so this pins both
%% halves of the contract: replacement cannot wait for DOWN, and a queued frame
%% from that still-live retired pid cannot reverse the generation.
queued_old_inbound_frame_cannot_reverse_link_replacement_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, Target, _Validators,
     SubmissionId, AttemptId,
     {relay_submit, SubmissionId, AttemptId, CommitteeId, Slot,
      {submit, Author, Signature, Canonical}, Carrier} = Submit,
    Initial} =
        relay_receiver_fixture(<<"replace-generation">>),
    {ConsensusPid, ConsensusToken} = spawn_close_aware_link(),
    {OldPid, OldToken} = spawn_stubborn_link(),
    OldRef = erlang:monitor(process, OldPid),
    {NewPid, NewToken} = spawn_close_aware_link(),
    try
        OldGeneration =
            quod_simplex:test_state_set(
              peer_readiness,
              #{Author =>
                    {ConsensusPid, Slot - 1, {?FIXTURE_ERA, 1, 0}, true,
                     quod_time:mono_ms()}},
              quod_simplex:test_state_set(
                relay_inbound_conns,
                #{Author => {OldPid, OldRef}},
                quod_simplex:test_state_set(
                  inbound_conns,
                  #{Author => {ConsensusPid, make_ref()}},
                  Initial))),
        InvalidSubmission =
            {submit, Author, flip1(Signature), Canonical},
        InvalidSubmissionId =
            quod_transaction:submission_id(InvalidSubmission),
        InvalidAttemptId =
            quod_transaction:relay_attempt_id(
              Ns, InvalidSubmissionId, CommitteeId, Slot, Target),
        ReplacementPayload =
            quod_relay:encode(
              Ns,
              {relay_submit, InvalidSubmissionId, InvalidAttemptId,
               CommitteeId, Slot, InvalidSubmission, Carrier}),
        RelayChan = quod_simplex:test_relay_chan(OldGeneration),
        {ReplaceUs, ReplaceResult} =
            timer:tc(
              fun() ->
                      quod_simplex:running(
                        info,
                        {quod_message,
                         {{Author, ignored}, NewPid},
                         RelayChan, ReplacementPayload},
                        OldGeneration)
              end),
        %% The removed implementation waited at least 500ms for DOWN. Leave a
        %% generous scheduler margin while still proving this callback cannot
        %% contain that synchronous wait.
        ?assert(ReplaceUs < 250000),
        Replaced = running_state(ReplaceResult),
        await_stubborn_close_requested(OldPid, OldToken),
        ?assert(is_process_alive(OldPid)),
        ?assert(is_process_alive(NewPid)),
        ?assert(is_process_alive(ConsensusPid)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(Replaced)),
        ?assertEqual(
           {[], [], []},
           quod_simplex:test_relay_state_keys(Replaced)),
        {[], [Author], [], _ConsensusDialsAfterReplace} =
            quod_simplex:test_link_peers(Replaced),
        ?assertEqual(
           {[Author], [Author], []},
           quod_simplex:test_relay_link_peers(Replaced)),

        RelayPayload = quod_relay:encode(Ns, Submit),
        AfterQueuedOld =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Author, ignored}, OldPid},
                 RelayChan, RelayPayload},
                Replaced)),
        ?assertEqual(
           {[], [], []},
           quod_simplex:test_relay_state_keys(AfterQueuedOld)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AfterQueuedOld)),
        ?assert(is_process_alive(NewPid)),
        assert_no_relay_control(),

        AcceptedOnNew =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Author, ignored}, NewPid},
                 RelayChan, RelayPayload},
                AfterQueuedOld)),
        ?assertEqual(
           {[], [AttemptId], []},
           quod_simplex:test_relay_state_keys(AcceptedOnNew)),
        ?assertMatch(
           {relay_accepted, _, AttemptId, _, Slot},
           receive_relay_control(Ns)),
        {[], [Author], [], _ConsensusDialsAfterAccept} =
            quod_simplex:test_link_peers(AcceptedOnNew),
        ?assertEqual(
           {[Author], [Author], []},
           quod_simplex:test_relay_link_peers(AcceptedOnNew)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AcceptedOnNew)),

        OldDown = release_stubborn_link(OldPid, OldToken, OldRef),
        AfterOldDown =
            running_state(
              quod_simplex:running(info, OldDown, AcceptedOnNew)),
        ?assertEqual(
           [],
           quod_simplex:test_retired_inbound(AfterOldDown)),
        ?assert(is_process_alive(NewPid))
    after
        ensure_close_aware_link_closed(ConsensusPid, ConsensusToken),
        ensure_stubborn_link_closed(OldPid, OldToken),
        ensure_close_aware_link_closed(NewPid, NewToken)
    end.

%% Consensus/readiness uses the same retirement machinery but a distinct
%% generation map. A stale live log-stream pid must neither block replacement
%% nor overwrite the readiness reported on the new authenticated generation.
stale_live_consensus_generation_cannot_block_or_reverse_test() ->
    [{Self, _SelfId}, {Peer, _PeerId}] = Committee = committee(2),
    Validators = pubs(Committee),
    Slot = 3,
    RelayView = hd([V || V <- [4, 5], quod_simplex:leader(V, Validators) =:= Peer]),
    {OldPid, OldToken} = spawn_stubborn_link(),
    OldRef = erlang:monitor(process, OldPid),
    {NewPid, NewToken} = spawn_close_aware_link(),
    try
        OldGeneration =
            st(#{self => Self, validators => Validators,
                 slot => Slot, sync => ready,
                 eng => root_engine(Slot),
                 inbound_conns =>
                     #{Peer => {OldPid, OldRef}},
                 peer_readiness =>
                     #{Peer =>
                           {OldPid, Slot, {?FIXTURE_ERA, 1, 0}, true,
                            quod_time:mono_ms()}}}),
        LogChan = term_to_binary({log, <<"t">>}, [deterministic]),
        ReadyPayload =
            quod_simplex:encode(
              <<"t">>, {readiness, Slot, {?FIXTURE_ERA, 1, 0}, true}),
        {ReplaceUs, ReplaceResult} =
            timer:tc(
              fun() ->
                      quod_simplex:running(
                        info,
                        {quod_message,
                         {{Peer, ignored}, NewPid},
                         LogChan, ReadyPayload},
                        OldGeneration)
              end),
        ?assert(ReplaceUs < 250000),
        Replaced = running_state(ReplaceResult),
        await_stubborn_close_requested(OldPid, OldToken),
        ?assert(is_process_alive(OldPid)),
        ?assert(is_process_alive(NewPid)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(Replaced)),
        ?assertEqual(
           {relay, Peer},
           quod_simplex:test_dtx_slot_route(RelayView, Replaced)),

        %% If the old live pid were allowed to re-adopt itself, this false
        %% readiness would bind to it and remove the current placement readiness.
        StalePayload =
            quod_simplex:encode(
              <<"t">>, {readiness, Slot, {?FIXTURE_ERA, 1, 0}, false}),
        AfterStale =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Peer, ignored}, OldPid},
                 LogChan, StalePayload},
                Replaced)),
        ?assertEqual(
           {relay, Peer},
           quod_simplex:test_dtx_slot_route(RelayView, AfterStale)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AfterStale)),
        assert_link_not_closed(NewPid, NewToken),

        %% The same false readiness is accepted on the actual current pid,
        %% proving stale rejection did not wedge or discard the replacement.
        AfterNew =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Peer, ignored}, NewPid},
                 LogChan, StalePayload},
                AfterStale)),
        ?assertEqual(
           blocked,
           quod_simplex:test_dtx_slot_route(RelayView, AfterNew)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AfterNew)),

        OldDown = release_stubborn_link(OldPid, OldToken, OldRef),
        AfterOldDown =
            running_state(
              quod_simplex:running(info, OldDown, AfterNew)),
        ?assertEqual(
           [],
           quod_simplex:test_retired_inbound(AfterOldDown)),
        ?assertEqual(
           blocked,
           quod_simplex:test_dtx_slot_route(RelayView, AfterOldDown)),
        ?assert(is_process_alive(NewPid))
    after
        ensure_stubborn_link_closed(OldPid, OldToken),
        ensure_close_aware_link_closed(NewPid, NewToken)
    end.

%% Terminal result state is write-once. Repeating the identical completion may
%% re-send it but cannot extend expiry; a same-key divergent context emits
%% nothing and cannot replace the cached answer.
terminal_cache_is_write_once_test() ->
    Ns = <<"t">>,
    Peer = <<1:256>>,
    SubmissionId = <<2:128>>,
    AttemptId = <<3:128>>,
    CommitteeId = <<4:256>>,
    Slot = 7,
    S = st(#{self => <<5:256>>, validators => [<<5:256>>],
             relay_conns => #{Peer => {self(), make_ref()}}}),
    First =
        quod_simplex:test_reply_relay(
          Peer, SubmissionId, AttemptId, CommitteeId, Slot,
          {error, skipped}, S),
    ?assertEqual(
       {relay_result, SubmissionId, AttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),
    [{Key = AttemptId, {error, skipped}, Expires}] =
        quod_simplex:test_relay_result_entries(First),
    Exact =
        quod_simplex:test_reply_relay(
          Peer, SubmissionId, AttemptId, CommitteeId, Slot,
          {error, skipped}, First),
    ?assertEqual(
       {relay_result, SubmissionId, AttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),
    ?assertEqual(
       [{Key, {error, skipped}, Expires}],
       quod_simplex:test_relay_result_entries(Exact)),

    DivergentBase = quod_simplex:test_state_set(outbox, #{}, Exact),
    Divergent =
        quod_simplex:test_reply_relay(
          Peer, flip1(SubmissionId), AttemptId, CommitteeId, Slot,
          {error, bad_change}, DivergentBase),
    ?assertEqual(
       [{Key, {error, skipped}, Expires}],
       quod_simplex:test_relay_result_entries(Divergent)),
    ?assertEqual(#{}, quod_simplex:test_outbox(Divergent)),
    assert_no_relay_control().

%% Only a brand-new attempt is gated on the current committee revision and this
%% node's exact ownership of the declared slot.
first_admission_requires_current_view_and_exact_owner_test() ->
    {Ns, CommitteeId, Slot, Author, AuthorId, Target, Validators,
     _SubmissionId, _AttemptId, _Submit, S} =
        relay_receiver_fixture(<<"first-admission">>),
    Tx = signed_tx(
           Ns, <<"first-admission">>,
           [{assert, {{relay, first_admission}, true}}],
           {Author, AuthorId}),
    {ok, Submission} = quod_transaction:submission(
                         test_binding(Ns, Author), Tx),
    SubmissionId = quod_transaction:submission_id(Submission),

    StaleCommitteeId = crypto:hash(sha256, <<"stale-view">>),
    StaleAttemptId =
        quod_transaction:relay_attempt_id(
          Ns, SubmissionId, StaleCommitteeId, Slot, Target),
    StaleSubmit =
        {relay_submit, SubmissionId, StaleAttemptId,
         StaleCommitteeId, Slot, Submission, []},
    {Stale, []} =
        quod_simplex:test_dispatch_relay(Author, StaleSubmit, S),
    ?assertEqual(
       {relay_result, SubmissionId, StaleAttemptId, StaleCommitteeId,
        Slot, {error, not_in_charge, none}},
       receive_relay_control(Ns)),
    ?assertEqual(
       {[], [], [StaleAttemptId]},
       quod_simplex:test_relay_state_keys(Stale)),

    WrongSlot =
        hd([Candidate
            || Candidate <- lists:seq(Slot + 1, Slot + length(Validators)),
               quod_simplex:leader(Candidate, Validators) =/= Target]),
    WrongAttemptId =
        quod_transaction:relay_attempt_id(
          Ns, SubmissionId, CommitteeId, WrongSlot, Target),
    WrongSubmit =
        {relay_submit, SubmissionId, WrongAttemptId,
         CommitteeId, WrongSlot, Submission, []},
    {WrongOwner, []} =
        quod_simplex:test_dispatch_relay(Author, WrongSubmit, S),
    ?assertEqual(
       {relay_result, SubmissionId, WrongAttemptId, CommitteeId,
        WrongSlot, {error, not_in_charge, none}},
       receive_relay_control(Ns)),
    ?assertEqual(#{}, quod_simplex:test_outbox(WrongOwner)).

%% Source hints bind to the stored peer, submission, attempt, era, and
%% slot—not the source's later current view. Even a perfectly matching success
%% or error remains only a hint: the origin's durable log decides the outcome.
source_ignores_foreign_metadata_and_waits_for_local_finality_test() ->
    {_Ns, CommitteeId, Slot, From, Target, Validators,
     SubmissionId, AttemptId, _InitialFrame, Sent} =
        outbound_fixture(<<"source-match">>),
    [{SubmissionId, 1, Submission, _OriginalPlacement,
      Deadline, 1}] =
        quod_simplex:test_custody(Sent),
    [Other | _] = Validators -- [Target],
    NewCommitteeId =
        crypto:hash(sha256, <<"source-new-view">>),
    Advanced =
        quod_simplex:test_state_set(
          eng, quod_simplex:eng_new(?DOMAIN, Validators, {{NewCommitteeId, 0, <<1:256>>}, 3, 0}), Sent),
    BadAccepted =
        [{Other,
          {relay_accepted, SubmissionId, AttemptId,
           CommitteeId, Slot}},
         {Target,
          {relay_accepted, flip1(SubmissionId), AttemptId,
           CommitteeId, Slot}},
         {Target,
          {relay_accepted, SubmissionId, AttemptId,
           crypto:hash(sha256, <<"foreign-view">>), Slot}},
         {Target,
          {relay_accepted, SubmissionId, AttemptId,
           CommitteeId, Slot + 1}}],
    _ =
        [begin
             {Ignored, []} =
                 quod_simplex:test_dispatch_relay(Peer, Frame, Advanced),
             ?assertEqual(
                quod_simplex:test_relay_pending_detail(Advanced),
                quod_simplex:test_relay_pending_detail(Ignored))
         end || {Peer, Frame} <- BadAccepted],

    {Accepted, []} =
        quod_simplex:test_dispatch_relay(
          Target,
          {relay_accepted, SubmissionId, AttemptId,
           CommitteeId, Slot},
          Advanced),
    [{AttemptId, Target, Slot, Deadline, true}] =
        quod_simplex:test_relay_pending_detail(Accepted),

    BadResults =
        [{Other,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot, {ok, Slot}}},
         {Target,
          {relay_result, flip1(SubmissionId), AttemptId,
           CommitteeId, Slot, {ok, Slot}}},
         {Target,
          {relay_result, SubmissionId, AttemptId,
           crypto:hash(sha256, <<"wrong-result-view">>),
           Slot, {ok, Slot}}},
         {Target,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot + 1, {ok, Slot + 1}}},
         {Target,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot, {ok, Slot + 1}}}],
    _ =
        [begin
             {Ignored, []} =
                 quod_simplex:test_dispatch_relay(Peer, Frame, Accepted),
             ?assertEqual(
                quod_simplex:test_relay_pending_detail(Accepted),
                quod_simplex:test_relay_pending_detail(Ignored))
         end || {Peer, Frame} <- BadResults],

    {SuccessHint, []} =
        quod_simplex:test_dispatch_relay(
          Target,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot, {ok, Slot}},
          Accepted),
    [{AttemptId, Target, Slot, Deadline, true}] =
        quod_simplex:test_relay_pending_detail(SuccessHint),
    Tag = element(2, From),
    receive
        {Tag, _ForgedSuccess} ->
            ?assert(false)
    after 0 ->
        ok
    end,

    {ErrorHint, []} =
        quod_simplex:test_dispatch_relay(
          Target,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot, {error, not_in_charge, none}},
          SuccessHint),
    [{AttemptId, Target, Slot, Deadline, true}] =
        quod_simplex:test_relay_pending_detail(ErrorHint),
    receive
        {Tag, _ForgedError} ->
            ?assert(false)
    after 0 ->
        ok
    end,

    %% A changed current era does not let a remote reply resolve, replace, or
    %% renew the old request. The exact attempt context still owns these hints.
    ?assertEqual([{SubmissionId, 1, Submission,
                   {relay, AttemptId, Target, Slot, CommitteeId}, Deadline, 1}],
                 quod_simplex:test_custody(ErrorHint)),
    assert_no_reply(From).

%% The custody deadline is anchored once at original arrival. Retargeting keeps
%% that exact deadline, and expiry removes both custody and its active placement
%% while sending one ambiguous `unavailable` signal upstream. `quod_prolog`
%% deliberately keeps the public caller parked and eventually reports
%% `outcome_unknown`.
custody_deadline_survives_retarget_and_expires_once_test() ->
    {{Ns, _CommitteeId, Slot, From, _Target, _Validators,
     SubmissionId, Attempt1, _InitialFrame, Sent}, Committee} =
        outbound_committee_fixture(<<"custody-deadline">>),
    [{SubmissionId, 1, Submission, _Placement1, Deadline, 1}] =
        quod_simplex:test_custody(Sent),
    Advanced = quod_simplex:engine_step(
        [{share, complaint_share(Slot, Member)} || Member <- Committee], Sent),
    Ready = quod_simplex:reconcile_custody_lane(Advanced),
    {Retargeted, []} =
        quod_simplex:test_drain_custody(
          Ready),
    [{SubmissionId, 1, Submission, Placement2, Deadline, 2}] =
        quod_simplex:test_custody(Retargeted),
    case Placement2 of
        {local, Slot2} ->
            ?assertEqual(Slot + 1, Slot2);
        {relay, Attempt2, _Target2, Slot2, _View2} ->
            ?assertEqual(Slot + 1, Slot2),
            ?assertNotEqual(Attempt1, Attempt2),
            RetargetFrame = receive_ordered_frame(),
            {relay,
             {relay_submit, SubmissionId, Attempt2, _CommitteeId2,
              Slot2, Submission, _Carrier}} =
                quod_relay:decode_relay_frame(RetargetFrame, Ns)
    end,

    Expired = quod_simplex:test_expire_custody(Retargeted),
    ?assertEqual([], quod_simplex:test_custody(Expired)),
    ?assertEqual([], quod_simplex:test_relay_pending(Expired)),
    {_, ExpectRef} = From,
    receive
        {ExpectRef, Reply} ->
            ?assertEqual({error, not_in_charge, unavailable}, Reply)
    after 0 ->
        ?assert(false)
    end,
    assert_no_reply(From).

%% The emitted frame binds the signed envelope to one era/view/target
%% attempt. A timer reconciliation never duplicates it on a live reliable
%% stream; a replacement link reconstructs the exact retained bytes once.
relay_emission_is_attempt_scoped_and_link_recovery_is_immutable_test() ->
    {Ns, CommitteeId, Slot, _From, Target, _Validators,
     SubmissionId, AttemptId, Frame, Sent} =
        outbound_fixture(<<"wire-attempt">>),
    ?assertEqual(#{}, quod_simplex:test_outbox(Sent)),
    {relay,
     {relay_submit, SubmissionId, AttemptId, CommitteeId, Slot,
      Submission, _TraceCarrier}} =
        quod_relay:decode_relay_frame(Frame, Ns),
    ?assertEqual(
       AttemptId,
       quod_transaction:relay_attempt_id(
         Ns, quod_transaction:submission_id(Submission),
         CommitteeId, Slot, Target)),
    [{AttemptId, Target, Slot, Deadline, false}] =
        quod_simplex:test_relay_pending_detail(Sent),
    Reconciled = quod_simplex:test_reconcile_relays(Sent),
    assert_no_ordered_frame(),
    ?assertEqual(#{}, quod_simplex:test_outbox(Reconciled)),
    [{AttemptId, Target, Slot, Deadline, false}] =
        quod_simplex:test_relay_pending_detail(Reconciled),

    Disconnected = quod_simplex:test_state_set(
                     relay_conns, #{}, Reconciled),
    RelayChan = quod_simplex:test_relay_chan(Disconnected),
    Reconnected = running_state(
                    quod_simplex:running(
                      info, {link_up, Target, RelayChan, self()},
                      Disconnected)),
    ?assertEqual(Frame, receive_ordered_frame()),
    assert_no_ordered_frame(),
    [{AttemptId, Target, Slot, Deadline, false}] =
        quod_simplex:test_relay_pending_detail(Reconnected).

%% Signature verification consumes the opaque canonical bytes as bytes. An
%% invalid signature must prevent the later unsafe canonical ETF decode from
%% even interning an atom embedded in those bytes.
signature_is_checked_before_canonical_decode_test() ->
    {Ns, CommitteeId, Slot, Author, AuthorId, Target, _Validators,
     _SubmissionId, _AttemptId, _Submit, S} =
        relay_receiver_fixture(<<"verify-before-decode">>),
    Tx = signed_tx(
           Ns, <<"verify-before-decode">>,
           [{assert, {{relay, opaque}, true}}],
           {Author, AuthorId}),
    {ok, {submit, Author, _GoodSignature, Canonical}} =
        quod_transaction:submission(test_binding(Ns, Author), Tx),
    AtomName =
        iolist_to_binary(
          io_lib:format(
            "qars_~11..0B",
            [erlang:unique_integer([positive]) rem 100000000000])),
    ?assertEqual(16, byte_size(AtomName)),
    ?assertException(
       error, badarg, binary_to_existing_atom(AtomName, utf8)),
    Poisoned =
        binary:replace(
          Canonical, <<"quod_transaction">>, AtomName, [global]),
    Submission = {submit, Author, <<0:512>>, Poisoned},
    SubmissionId = quod_transaction:submission_id(Submission),
    AttemptId =
        quod_transaction:relay_attempt_id(
          Ns, SubmissionId, CommitteeId, Slot, Target),
    Wire =
        quod_relay:encode(
          Ns, {relay_submit, SubmissionId, AttemptId, CommitteeId,
               Slot, Submission, []}),
    {relay, Decoded} = quod_relay:decode_relay_frame(Wire, Ns),
    {Rejected, []} =
        quod_simplex:test_dispatch_relay(Author, Decoded, S),
    ?assertException(
       error, badarg, binary_to_existing_atom(AtomName, utf8)),
    %% A failed opaque-signature check is silent and leaves even volatile
    %% recovery state untouched.
    ?assertEqual(S, Rejected),
    ?assertEqual(#{}, quod_simplex:test_outbox(Rejected)),
    ?assertEqual({[], [], []},
                 quod_simplex:test_relay_state_keys(Rejected)).

%% A decoded but unsupported or malformed relay term cannot crash or mutate the
%% state owner. The wire codec normally rejects the malformed shape first; this
%% keeps the state-machine boundary fail-closed as well.
unsupported_and_malformed_relay_terms_are_safely_dropped_test() ->
    S = st(#{self => <<0:256>>, validators => [<<0:256>>],
             slot => 6, history_head => {6, <<1:256>>},
             eng => root_engine(6)}),
    Messages =
        [{relay_unsupported, <<"opaque">>},
         {relay_submit, <<1:120>>, <<2:128>>, <<3:256>>, 7,
          malformed_submission, []}],
    _ =
        [begin
             {S1, Actions} =
                 quod_simplex:test_dispatch_relay(<<1:256>>, Message, S),
             ?assertEqual(S, S1),
             ?assertEqual([], Actions)
         end || Message <- Messages],
    ok.

%% A leader latched into a final-vote camp for its OWN in-flight slot must STILL redrive
%% the proposal on every Δ: the link send is fire-and-forget, so the Δ re-fire is the
%% only retransmit of a lost proposal frame. (Live regression: a leader that
%% complaint-signed its slot before proposing stopped redriving, no follower ever saw
%% the proposal, and the burst wedged with zero support votes.)
latched_leader_still_redrives_proposal_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Committee = committee(4),
        Validators = pubs(Committee),
        {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
        B4 = blk(4),
        BH = quod_simplex:block_hash(B4),
        {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(3)), 3, 0})),
        %% latch the complaint exactly as the pre-proposal timeout path does
        Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
        {TraceCtx, TraceSpan} = quod_trace:start_span(
                                 otel_ctx:new(), <<"consensus.redrive.test">>, internal, #{}),
        try
            Inbound = maps:from_list([{P, {Sink, make_ref()}} || P <- Validators, P =/= Me]),
            Readiness = voting_readiness([P || P <- Validators, P =/= Me], Sink, 3),
            SReady = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                          slot => 3, history_head => {3, <<1:256>>}, eng => E1,
                          inbound_conns => Inbound, peer_readiness => Readiness,
                          head_progress => {?FIXTURE_ERA, 4, awaiting_proposal}}),
            Complained = quod_simplex:on_progress_timeout({?FIXTURE_ERA, 4}, SReady),
            ?assertEqual({none, false, true}, quod_simplex:test_round(4, Complained)),
            %% now it proposes (the drain would do this); then the next Δ must RE-SEND it
            Redriven = quod_simplex:on_progress_timeout(
                         {?FIXTURE_ERA, 4}, quod_simplex:test_state_set(
                              local_proposal, {4, BH, [TraceCtx]}, Complained)),
            ?assertEqual(1, maps:get(redrives, quod_simplex:stats_map(Redriven)))
        after
            exit(Sink, kill),
            quod_trace:finish_span(TraceSpan, ok)
        end,
        Span = quod_trace_tests:take_span(<<"consensus.redrive.test">>),
        Watchdog = quod_trace_tests:take_span(<<"consensus.watchdog_fired">>, Span#span.trace_id),
        Redrive = quod_trace_tests:take_span(<<"consensus.proposal_redriven">>, Span#span.trace_id),
        WatchdogAttrs = otel_attributes:map(Watchdog#span.attributes),
        ?assertEqual(4, maps:get('quod.consensus.slot', WatchdogAttrs)),
        ?assertEqual(<<"awaiting_proposal">>, maps:get('quod.consensus.phase', WatchdogAttrs)),
        %% A watchdog is a slot event; only the actual resend identifies a
        %% block. This prevents a timeout from claiming another proposal's hash.
        ?assertNot(maps:is_key('quod.consensus.block_hash', WatchdogAttrs)),
        ?assertEqual(binary:encode_hex(BH, lowercase), maps:get(
          'quod.consensus.block_hash', otel_attributes:map(Redrive#span.attributes))),
        ?assert(Watchdog#span.start_time =< Redrive#span.start_time)
    end).

%% The quod_metrics matcher and stats_map can never drift: every key the Prometheus
%% refresh pattern requires must exist in the stats map (a miss silently zeroes ALL
%% consensus gauges).
metrics_matcher_lockstep_test() ->
    {Me, Id} = id(),
    Root = {<<7:256>>, 63, <<1:256>>},
    Stats = quod_simplex:stats_map(
              st(#{self => Me, id => Id, validators => [Me], sync => ready,
                   slot => 900, history_head => {900, element(3, Root)},
                   eng => quod_simplex:eng_new(?DOMAIN, [Me],{Root, 900, 0})})),
    ?assertEqual(64, maps:get(protocol_view, Stats)),
    ?assertEqual(900, maps:get(committed, Stats)),
    ?assertEqual(0, maps:get(pipeline_gap, Stats)),
    ?assertEqual(0, maps:get(ahead_gap, Stats)),
    Missing = quod_metrics:consensus_stat_keys() -- maps:keys(Stats),
    ?assertEqual([], Missing).

%%%===================================================================
%%% boundary / edge / Byzantine (fixes from the review)
%%%===================================================================

%% Positive control for the rejection tests: a cert forms at EXACTLY quorum and not one below.
cert_boundary_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],           %% N=4, quorum=3
    Vals = [P || {P, _} <- Ids],
    H    = quod_simplex:block_hash(blk(1)),
    Sh   = fun(N) -> [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Id) || {_, Id} <- take(N, Ids)] end,
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Sh(2), Vals)),
    ?assertMatch({ok, _},               quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Sh(3), Vals)).

%% The live sole-founder path: N=1, quorum=1, a self-signed cert forms and verifies.
sole_validator_cert_test() ->
    {P, Id} = id(),
    H = quod_simplex:block_hash(blk(1)),
    {ok, C} = quod_simplex:form_cert(?DOMAIN, commit, {?FIXTURE_ERA, 1}, H, [quod_simplex:make_share(?DOMAIN, commit, {?FIXTURE_ERA, 1}, H, Id)], [P]),
    ?assert(quod_simplex:verify_cert(?DOMAIN, C, [P])).

%% An empty validator set must NOT crash (quorum(0)) — clean insufficient / false.
empty_validators_test() ->
    {_, Id} = id(),
    H = quod_simplex:block_hash(blk(1)),
    ?assertEqual({error, insufficient},
                 quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Id)], [])),
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, #cert{kind = support, era = ?FIXTURE_ERA, slot = 1, block_hash = H, sigs = []}, [])).

%% A complaint (slot-only, block_hash=none) cert forms and verifies.
complaint_cert_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    Sh   = [quod_simplex:make_share(?DOMAIN, complaint, {?FIXTURE_ERA, 2}, none, Id) || {_, Id} <- take(3, Ids)],
    {ok, C} = quod_simplex:form_cert(?DOMAIN, complaint, {?FIXTURE_ERA, 2}, none, Sh, Vals),
    ?assert(quod_simplex:verify_cert(?DOMAIN, C, Vals)).

%% Different authentic quorum subsets for one complaint lead to the same
%% protocol position, without changing material history or producing a row.
complaint_quorum_subsets_have_one_protocol_position_test() ->
    Members = committee(4), Validators = pubs(Members),
    [M1, M2, _M3, M4] = Members,
    Position = {?FIXTURE_ERA, 2}, Root = {?FIXTURE_ERA, 1, <<92:256>>},
    {ok, CertA} = quod_simplex:form_cert(?DOMAIN, complaint, Position, none,
        [complaint_share(2, M) || M <- take(3, Members)], Validators),
    {ok, CertB} = quod_simplex:form_cert(?DOMAIN, complaint, Position, none,
        [complaint_share(2, M) || M <- [M1, M2, M4]], Validators),
    ?assertNotEqual(CertA, CertB),
    Engine = quod_simplex:eng_new(?DOMAIN, Validators, {Root, 500, 0}),
    {EA, EventsA} = quod_simplex:eng_offer({cert, CertA}, Engine),
    {EB, EventsB} = quod_simplex:eng_offer({cert, CertB}, Engine),
    ?assertEqual([{broadcast, CertA}, {view_advanced, 2, complaint}], EventsA),
    ?assertEqual([{broadcast, CertB}, {view_advanced, 2, complaint}], EventsB),
    Base = #{slot => 500, history_head => {500, element(3, Root)}},
    SA = st(Base#{eng => EA}), SB = st(Base#{eng => EB}),
    ?assertEqual(#{era => ?FIXTURE_ERA, view => 3, root => Root, parent => Root, material_height => 500},
                 quod_simplex:test_protocol_position(SA)),
    ?assertEqual(quod_simplex:test_protocol_position(SA),
                 quod_simplex:test_protocol_position(SB)),
    ?assertEqual({500, undefined}, quod_simplex:test_committed_store(SA)),
    ?assertEqual({500, undefined}, quod_simplex:test_committed_store(SB)),
    ?assert(quod_simplex:verify_cert(?DOMAIN, CertA, Validators)),
    ?assert(quod_simplex:verify_cert(?DOMAIN, CertB, Validators)).

%% Malformed shapes are rejected even with a valid signature over their (malformed) bytes.
share_shape_test() ->
    {_, Id} = id(),
    H = quod_simplex:block_hash(blk(1)),
    ?assert(quod_simplex:verify_share(?DOMAIN, quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Id))),
    ?assertNot(quod_simplex:verify_share(?DOMAIN, quod_simplex:make_share(?DOMAIN, complaint, {?FIXTURE_ERA, 1}, H, Id))),   %% complaint w/ hash
    ?assertNot(quod_simplex:verify_share(?DOMAIN, quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, <<1, 2, 3>>, Id))),  %% short hash
    Wrapped = (quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Id))#share{slot = (1 bsl 64) + 1},
    ?assertNot(quod_simplex:verify_share(?DOMAIN, Wrapped)).   %% slot encoding must never wrap modulo 2^64

%% A share whose FIELDS claim block H but whose signature is over a DIFFERENT block: form_cert
%% re-verifies over the cert's canonical bytes, so the liar does not count (proves fields aren't trusted).
fields_lie_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H      = quod_simplex:block_hash(blk(1)),
    HOther = quod_simplex:block_hash(blk(9)),
    [{_, A}, {_, B}, {_, C} | _] = Ids,
    Liar = (quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, HOther, C))#share{block_hash = H},  %% sig over HOther, claims H
    Shares = [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, A),
              quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, B), Liar],
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Shares, Vals)).

%% A cert carrying MORE signatures than validators is rejected before any verify work (amplification cap).
verify_cert_caps_sigs_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    Bloat = [{P, <<0:512>>} || P <- Vals] ++ [{<<X:256>>, <<0:512>>} || X <- lists:seq(1, 20)],
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, #cert{kind = support, era = ?FIXTURE_ERA, slot = 1, block_hash = H, sigs = Bloat}, Vals)),
    {ok, Good} = quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, supports(blk(1), Ids, 3), Vals),
    [First | _] = Good#cert.sigs,
    Improper = Good#cert{sigs = [First | bad_tail]},
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, Improper, Vals)),
    Wrapped = Good#cert{slot = (1 bsl 64) + 1},
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, Wrapped, Vals)).

validator_cap_certificate_boundary_test() ->
    N = ?MAX_VALIDATORS,
    Ids = committee(N + 1),
    AtLimitIds = take(N, Ids),
    AtLimitVals = pubs(AtLimitIds),
    H = quod_simplex:block_hash(blk(1)),
    AtLimitShares =
        [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Id)
         || {_, Id} <- take(quod_simplex:quorum(N), AtLimitIds)],
    {ok, AtLimitCert} = quod_simplex:form_cert(
                          ?DOMAIN, support, {?FIXTURE_ERA, 1}, H,
                          AtLimitShares, AtLimitVals),
    ?assert(quod_simplex:verify_cert(?DOMAIN, AtLimitCert, AtLimitVals)),
    Vals = pubs(Ids),
    Shares = [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Id)
              || {_, Id} <- take(quod_simplex:quorum(N + 1), Ids)],
    Cert = #cert{kind = support, era = ?FIXTURE_ERA, slot = 1, block_hash = H,
                 sigs = [{Share#share.signer, Share#share.sig}
                         || Share <- Shares]},
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, Cert, Vals)),
    ?assertEqual(
       {error, insufficient},
       quod_simplex:form_cert(
         ?DOMAIN, support, {?FIXTURE_ERA, 1}, H, Shares, Vals)).

%%%===================================================================
%%% consensus engine — certificate pool + block tree (§2.3)
%%%===================================================================

%% The volatile window follows the current protocol view. A parent arrival
%% advances it even when no material entry has yet been archived.
eng_live_window_follows_protocol_view_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    H2Block = blk(7),
    H3Block = blk(8),
    H2Hash = quod_simplex:block_hash(H2Block),
    E0 = quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(5)), 5, 0}),
    {E1, []} = quod_simplex:eng_offer({block, H2Block}, E0),
    ?assertEqual(H2Block, quod_simplex:eng_retained_block(7, E1)),
    ?assertEqual(
       #{blocks => 1, share_buckets => 0, seen_votes => 0, certs => 0},
       quod_simplex:eng_pool_sizes(E1)),
    {BlockDropped, []} = quod_simplex:eng_offer({block, H3Block}, E1),
    ?assertEqual(E1, BlockDropped),

    [{_, FirstSigner} | _] = Committee,
    H2Share =
        quod_simplex:make_share(
          ?DOMAIN, support, {?FIXTURE_ERA, 7}, H2Hash, FirstSigner),
    {E2, []} = quod_simplex:eng_offer({share, H2Share}, E1),
    ?assertEqual(
       #{blocks => 1, share_buckets => 1, seen_votes => 1, certs => 0},
       quod_simplex:eng_pool_sizes(E2)),
    H3Share =
        quod_simplex:make_share(
          ?DOMAIN, support, {?FIXTURE_ERA, 8}, quod_simplex:block_hash(H3Block),
          FirstSigner),
    {ShareDropped, []} = quod_simplex:eng_offer({share, H3Share}, E2),
    ?assertEqual(E2, ShareDropped),

    {ok, H2Cert} =
        quod_simplex:form_cert(
          ?DOMAIN, support, {?FIXTURE_ERA, 7}, H2Hash,
          supports(H2Block, Committee, 3), Validators),
    {E3, _} = quod_simplex:eng_offer({cert, H2Cert}, E2),
    ?assertMatch(
       #cert{},
       quod_simplex:persisted_cert(support, 7, H2Hash, E3)),
    {ok, H3Cert} =
        quod_simplex:form_cert(
          ?DOMAIN, support, {?FIXTURE_ERA, 8}, quod_simplex:block_hash(H3Block),
          supports(H3Block, Committee, 3), Validators),
    {CertDropped, []} = quod_simplex:eng_offer({cert, H3Cert}, E3),
    ?assertEqual(E3, CertDropped),
    {WithParent, _} = quod_simplex:eng_offer({block, blk(6)}, E3),
    {Advanced, _} = feed_shares(supports(blk(6), Committee, 3), WithParent),
    {NextHeld, []} = quod_simplex:eng_offer({block, H3Block}, Advanced),
    ?assertEqual(H3Block, quod_simplex:eng_retained_block(8, NextHeld)).

%% A far finalizer is verified once and represented by one scalar recovery
%% hint. It must neither populate the certificate pool nor remain authoritative
%% after the validator set changes. Once base advances enough, retransmission
%% takes the ordinary retained-certificate path.
eng_far_finalizer_is_bounded_recovery_hint_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    FarBlock = blk(8),
    FarHash = quod_simplex:block_hash(FarBlock),
    {ok, FarCert} =
        quod_simplex:form_cert(
          ?DOMAIN, commit, {?FIXTURE_ERA, 8}, FarHash,
          commits(FarBlock, Committee, 3), Validators),
    E0 = quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(5)), 5, 0}),
    {Hinted, [{ahead, FarCert}]} = quod_simplex:eng_offer({cert, FarCert}, E0),
    ?assertEqual(8, quod_simplex:ahead_cert_ceiling(Hinted)),
    ?assertEqual(
       #{blocks => 0, share_buckets => 0, seen_votes => 0, certs => 0},
       quod_simplex:eng_pool_sizes(Hinted)),
    ?assertEqual(
       none, quod_simplex:persisted_cert(commit, 8, FarHash, Hinted)),
    [{Self, _} | _] = Committee,
    Ready =
        st(#{self => Self, validators => Validators, slot => 5,
             eng => Hinted, sync => ready}),
    ?assertNot(quod_simplex:caught_up(Ready)),
    ?assertNot(quod_simplex:may_vote(Ready)),
    ?assert(quod_simplex:should_sync(Ready)),

    {WithNext, _} = quod_simplex:eng_offer({block, blk(6)}, Hinted),
    {Supported, _} = feed_shares(supports(blk(6), Committee, 3), WithNext),
    {Committed, _} = feed_shares(commits(blk(6), Committee, 3), Supported),
    Advanced = quod_simplex:eng_prune(quod_ledger:block_ref(blk(6)), Committed),
    ?assertEqual(8, quod_simplex:ahead_cert_ceiling(Advanced)),
    {InsideWindow, _} =
        quod_simplex:eng_offer({cert, FarCert}, Advanced),
    ?assertMatch(
       #cert{},
       quod_simplex:persisted_cert(
         commit, 8, FarHash, InsideWindow)),

    NewCommittee = committee(4),
    NewValidators = pubs(NewCommittee),
    NewEra = <<8:256>>,
    Changed = quod_simplex:eng_new(?DOMAIN, NewValidators, {{NewEra, 0, <<3:256>>}, 1, 0}),
    ?assertEqual(0, quod_simplex:ahead_cert_ceiling(Changed)),
    {OldSetRejected, []} =
        quod_simplex:eng_offer({cert, FarCert}, Changed),
    ?assertEqual(Changed, OldSetRejected),
    {ok, NewFar} = quod_ledger:new_block({NewEra, 8}, {NewEra, 7, <<4:256>>}, 1, empty, 0),
    {ok, NewSetCert} = quod_simplex:form_cert(?DOMAIN, commit, {NewEra, 8},
        quod_simplex:block_hash(NewFar), commits(NewFar, NewCommittee, 3), NewValidators),
    {Rehinted, [{ahead, NewSetCert}]} =
        quod_simplex:eng_offer({cert, NewSetCert}, Changed),
    ?assertEqual(8, quod_simplex:ahead_cert_ceiling(Rehinted)),
    ?assertEqual(
       #{blocks => 0, share_buckets => 0, seen_votes => 0, certs => 0},
       quod_simplex:eng_pool_sizes(Rehinted)).

%% A Byzantine validator can sign arbitrarily many hashes for one live slot.
%% Only its first verified vote is retained, so both the signer index and the
%% hash-bucket map remain constant while later valid conflicts are discarded.
eng_conflicting_share_spam_is_bounded_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    [{_, Signer} | _] = Committee,
    Hashes =
        [crypto:hash(sha256, <<"conflicting-share", N:64>>)
         || N <- lists:seq(1, 64)],
    Shares =
        [quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 6}, Hash, Signer)
         || Hash <- Hashes],
    ?assert(lists:all(
              fun(Share) ->
                      quod_simplex:verify_share(?DOMAIN, Share)
              end, Shares)),
    E0 = quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(5)), 5, 0}),
    Bounded =
        lists:foldl(
          fun(Share, Eng) ->
                  {Eng1, _} = quod_simplex:eng_offer({share, Share}, Eng),
                  Eng1
          end, E0, Shares),
    ?assertEqual(
       #{blocks => 0, share_buckets => 1, seen_votes => 1, certs => 0},
       quod_simplex:eng_pool_sizes(Bounded)).

%% A Byzantine leader's second ordinary proposal reaches the real driver seam:
%% it is structurally valid and from the correct authenticated leader, but the
%% engine's first-block latch rejects it. The driver must not dereference the
%% rejected hash or mutate any state.
ordinary_block_equivocation_is_bounded_and_does_not_crash_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Root = quod_ledger:block_ref(blk(5, 495 + 5)),
    Leader = quod_simplex:leader(6, Validators),
    {Leader, LeaderId} = lists:keyfind(Leader, 1, Committee),
    First = block(
              {?FIXTURE_ERA, 6}, Root, 501,
              {batch,
               [signed_tx(
                  <<"t">>, <<"equivocation-first">>,
                  [{assert, {{equivocation, first}, true}}],
                  {Leader, LeaderId})]}),
    Second = block(
               {?FIXTURE_ERA, 6}, Root, 501,
               {batch,
                [signed_tx(
                   <<"t">>, <<"equivocation-second">>,
                   [{assert, {{equivocation, second}, true}}],
                   {Leader, LeaderId})]}),
    Initial =
        st(#{self => Leader, id => LeaderId, validators => Validators,
             slot => 500, last_applied => 500, history_head => {500, element(3, Root)},
             eng => quod_simplex:eng_new(?DOMAIN, Validators, {Root, 500, 0}),
             sync => ready}),
    Supported =
        quod_simplex:dispatch(Leader, {propose, First, []}, Initial),
    FirstHash = quod_simplex:block_hash(First),
    ?assertEqual(
       {FirstHash, false, false},
       quod_simplex:test_round(6, Supported)),
    Rejected =
        quod_simplex:dispatch(Leader, {propose, Second, []}, Supported),
    ?assertEqual(Supported, Rejected),
    %% After quorum, a redrive must still heal lost delivery of our existing
    %% support and commit shares. This is not permission to mint fresh support
    %% for a certified body we never supported (the recovery control above).
    {ok, Cert} = quod_simplex:form_cert(
                   ?DOMAIN, support, {?FIXTURE_ERA, 6}, FirstHash,
                   supports(First, Committee, 3), Validators),
    Approved = quod_simplex:dispatch(Leader, {cert, Cert}, Rejected),
    ?assertEqual({FirstHash, true, false}, quod_simplex:test_round(6, Approved)),
    Clean = quod_simplex:test_state_set(outbox, #{}, Approved),
    Echoed = quod_simplex:dispatch(Leader, {propose, First, []}, Clean),
    ?assertEqual(quod_simplex:test_dtx_round(6, Clean),
                 quod_simplex:test_dtx_round(6, Echoed)),
    ?assertEqual(quod_simplex:test_round(6, Clean), quod_simplex:test_round(6, Echoed)),
    Expected = lists:sort([
        {consensus, {share, quod_simplex:make_share(?DOMAIN, Kind, {?FIXTURE_ERA, 6}, FirstHash, LeaderId)}}
        || Kind <- [support, commit]]),
    Outbox = quod_simplex:test_outbox(Echoed),
    ?assertEqual(3, map_size(Outbox)),
    maps:foreach(fun(_Peer, Frames) ->
        ?assertEqual(Expected, lists:sort([
            quod_relay:decode_consensus_frame(Frame, <<"t">>) || Frame <- Frames]))
    end, Outbox).

%% Record field types are not runtime checks: an authenticated Byzantine
%% leader can still put an arbitrary term in a wire-decoded block payload.
%% Proposal admission must classify that term and reject it, never narrow the
%% function head to canonical batches and crash the ontology process.
malformed_leader_payload_is_rejected_without_crash_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Root = quod_ledger:block_ref(blk(5, 495 + 5)),
    Leader = quod_simplex:leader(6, Validators),
    {Leader, LeaderId} = lists:keyfind(Leader, 1, Committee),
    Malformed = #block{era = ?FIXTURE_ERA, slot = 6, parent = Root,
                       payload = malformed_payload, timestamp = 0},
    Initial =
        st(#{self => Leader, id => LeaderId, validators => Validators,
             slot => 500, last_applied => 500, history_head => {500, element(3, Root)},
             eng => quod_simplex:eng_new(?DOMAIN, Validators, {Root, 500, 0}),
             sync => ready}),
    ?assertEqual(
       Initial,
       quod_simplex:dispatch(Leader, {propose, Malformed, []}, Initial)).

%% First-block-wins bounds ordinary equivocation, but certified-block recovery
%% must still replace an unnotarized losing copy. The replacement removes the
%% old payload, whereas an already-notarized slot is immutable even if a
%% synthetic second quorum certificate is presented.
eng_certified_alternate_replaces_only_unnotarized_block_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Losing = blk(6),
    Winning = block({?FIXTURE_ERA, 6}, Losing#block.parent, Losing#block.height, Losing#block.payload, 1),
    WinningHash = quod_simplex:block_hash(Winning),
    {ok, WinningCert} =
        quod_simplex:form_cert(
          ?DOMAIN, support, {?FIXTURE_ERA, 6}, WinningHash,
          supports(Winning, Committee, 3), Validators),
    E0 = quod_simplex:eng_new(?DOMAIN, Validators, {quod_ledger:block_ref(blk(5)), 5, 0}),
    {LosingHeld, []} = quod_simplex:eng_offer({block, Losing}, E0),
    {Certified, _} =
        quod_simplex:eng_offer({cert, WinningCert}, LosingHeld),
    {Replaced, ReplacedEvents} =
        quod_simplex:eng_offer({block, Winning}, Certified),
    ?assertEqual(Winning, quod_simplex:eng_retained_block(6, Replaced)),
    ?assertEqual(
       #{blocks => 1, share_buckets => 0, seen_votes => 0, certs => 1},
       quod_simplex:eng_pool_sizes(Replaced)),
    ?assert(lists:member({notarized, Winning}, ReplacedEvents)),

    LosingHash = quod_simplex:block_hash(Losing),
    {ok, LosingCert} =
        quod_simplex:form_cert(
          ?DOMAIN, support, {?FIXTURE_ERA, 6}, LosingHash,
          supports(Losing, Committee, 3), Validators),
    {LosingAgain, []} = quod_simplex:eng_offer({block, Losing}, E0),
    {Notarized, _} =
        quod_simplex:eng_offer({cert, LosingCert}, LosingAgain),
    ?assertEqual(Losing, maps:get(6, quod_simplex:eng_tree(Notarized))),
    {TwoCerts, _} =
        quod_simplex:eng_offer({cert, WinningCert}, Notarized),
    {StillNotarized, []} =
        quod_simplex:eng_offer({block, Winning}, TwoCerts),
    ?assertEqual(TwoCerts, StillNotarized),
    ?assertEqual(
       Losing, quod_simplex:eng_retained_block(6, StillNotarized)),
    ?assertEqual(
       Losing, maps:get(6, quod_simplex:eng_tree(StillNotarized))),
    ?assertEqual(1, maps:get(
                      blocks,
                      quod_simplex:eng_pool_sizes(StillNotarized))).

%% N=4 (quorum 3): a block notarizes at the 3rd support share, commits at the 3rd commit share.
eng_notarize_then_commit_test() ->
    C = committee(4),
    B = blk(1, 1 + 1),
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(C),{{?FIXTURE_ERA, 0, <<1:256>>}, 1, 0}),
    {E1, _} = quod_simplex:eng_offer({block, B}, E0),
    {E2, Ev2} = feed_shares(supports(B, C, 2), E1),        %% 2 < quorum 3
    ?assertNot(lists:member({notarized, B}, Ev2)),
    ?assertNot(maps:is_key(1, quod_simplex:eng_tree(E2))),
    {E3, Ev3} = feed_shares(supports(B, C, 3) -- supports(B, C, 2), E2),   %% the 3rd share
    ?assert(lists:member({notarized, B}, Ev3)),
    ?assertEqual(B, maps:get(1, quod_simplex:eng_tree(E3))),
    {E4, Ev4} = feed_shares(commits(B, C, 3), E3),
    ?assert(lists:member({committed, 1, B}, Ev4)),
    ?assertEqual(B, maps:get(1, quod_simplex:eng_committed(E4))).

%% A committee transition creates a new era; it never retroactively raises
%% quorum on an already-certified old-era material block.
old_era_certificate_survives_new_committee_quorum_test() ->
    C5 = committee(5), C4 = take(4, C5),
    [{Added, _}] = C5 -- C4,
    OldRoot = {?FIXTURE_ERA, 0, <<1:256>>},
    Membership = block({?FIXTURE_ERA, 1}, OldRoot, 2, {batch, [tx([pa(Added)])]}),
    {E1, _} = quod_simplex:eng_offer({block, Membership},
        quod_simplex:eng_new(?DOMAIN, pubs(C4),{OldRoot, 1, 0})),
    {E2, _} = feed_shares(supports(Membership, C4, 3), E1),
    {Old, _} = feed_shares(commits(Membership, C4, 3), E2),
    Hash = quod_simplex:block_hash(Membership),
    OldCert = quod_simplex:persisted_cert(commit, 1, Hash, Old),
    ?assertMatch(#cert{}, OldCert),
    Era = quod_ledger:next_era({<<"t">>, <<0:256>>}, ?FIXTURE_ERA, Hash),
    Root = {Era, 0, Hash},
    NewBlock = block({Era, 1}, Root, 3, {batch, [tx([])]}),
    Fresh = quod_simplex:eng_new(?DOMAIN, pubs(C5), {Root, 2, 0}),
    ?assertEqual({Fresh, []}, quod_simplex:eng_offer({cert, OldCert}, Fresh)),
    {N1, _} = quod_simplex:eng_offer({block, NewBlock}, Fresh),
    {N2, TooFew} = feed_shares(supports(NewBlock, C5, 3), N1),
    ?assertEqual([], [B || {notarized, B} <- TooFew]),
    {N3, Quorum} = feed_shares(supports(NewBlock, C5, 4), N2),
    ?assertEqual([NewBlock], [B || {notarized, B} <- Quorum]),
    ?assertEqual(OldCert, quod_simplex:persisted_cert(commit, 1, Hash, Old)),
    ?assertEqual(#{}, quod_simplex:eng_committed(N3)).

%% Even retained members must sign the new era. An old cached share is not a
%% contribution to its quorum, and a removed signer cannot contribute at all.
old_era_and_removed_signer_shares_do_not_count_in_new_era_test() ->
    C4 = committee(4), [Member, Removed | Rest] = C4,
    Current = [Member | Rest], Era = <<8:256>>, Root = {Era, 0, <<2:256>>},
    NewBlock = block({Era, 1}, Root, 3, {batch, [tx([])]}),
    [OldMemberShare] = supports(blk(1), [Member], 1),
    [RemovedShare] = supports(NewBlock, [Removed], 1),
    {E1, _} = quod_simplex:eng_offer({block, NewBlock},
        quod_simplex:eng_new(?DOMAIN, pubs(Current), {Root, 2, 0})),
    ?assertEqual({E1, []}, quod_simplex:eng_offer({share, OldMemberShare}, E1)),
    ?assertEqual({E1, []}, quod_simplex:eng_offer({share, RemovedShare}, E1)),
    {E2, TooFew} = feed_shares(supports(NewBlock, Current, 2), E1),
    ?assertEqual([], [B || {notarized, B} <- TooFew]),
    {_, Quorum} = feed_shares(supports(NewBlock, Current, 3), E2),
    ?assertEqual([NewBlock], [B || {notarized, B} <- Quorum]).

%% N=1 (quorum 1): the sole validator's own shares notarize + commit instantly (the degenerate case).
eng_sole_validator_test() ->
    C = committee(1),
    B = blk(1, 1 + 1),
    {E1, _}   = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(?DOMAIN, pubs(C),{{?FIXTURE_ERA, 0, <<1:256>>}, 1, 0})),
    {E2, Ev2} = feed_shares(supports(B, C, 1), E1),
    ?assert(lists:member({notarized, B}, Ev2)),
    {_E3, Ev3} = feed_shares(commits(B, C, 1), E2),
    ?assert(lists:member({committed, 1, B}, Ev3)).

%% A block whose parent is not yet notarized WAITS, then rides in on the parent's settle (fixpoint).
eng_parent_ordering_test() ->
    C = committee(4),
    B1 = blk(1, 1 + 1), B2 = blk(2, 2 + 1),                              %% B2's parent is slot 1
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(C),{{?FIXTURE_ERA, 0, <<1:256>>}, 1, 0}),
    {E1, _}   = quod_simplex:eng_offer({block, B2}, E0),
    {E2, Ev2} = feed_shares(supports(B2, C, 3), E1),       %% B2 fully supported BEFORE B1
    ?assertNot(lists:member({notarized, B2}, Ev2)),
    ?assertNot(maps:is_key(2, quod_simplex:eng_tree(E2))),
    {E3, _}   = quod_simplex:eng_offer({block, B1}, E2),
    {E4, Ev4} = feed_shares(supports(B1, C, 3), E3),
    ?assert(lists:member({notarized, B1}, Ev4)),
    ?assert(lists:member({notarized, B2}, Ev4)),           %% B2 notarizes on the SAME settle as B1
    ?assert(maps:is_key(2, quod_simplex:eng_tree(E4))).

%% Consensus ordering is pipelined independently of state execution: a child can
%% notarize and even obtain its own commit certificate while its parent has no commit
%% certificate yet. The driver buffers finalization and applies slots in order.
eng_child_finalizes_before_parent_test() ->
    C = committee(4),
    B1 = blk(1, 1 + 1), B2 = blk(2, 2 + 1),
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(C),{{?FIXTURE_ERA, 0, <<1:256>>}, 1, 0}),
    {E1, _} = quod_simplex:eng_offer({block, B1}, E0),
    {E2, _} = quod_simplex:eng_offer({block, B2}, E1),
    {E3, _} = feed_shares(supports(B1, C, 3), E2),
    {E4, _} = feed_shares(supports(B2, C, 3), E3),
    ?assert(maps:is_key(1, quod_simplex:eng_tree(E4))),
    ?assert(maps:is_key(2, quod_simplex:eng_tree(E4))),
    ?assertEqual(#{}, quod_simplex:eng_committed(E4)),
    {E5, Events} = feed_shares(commits(B2, C, 3), E4),
    ?assert(lists:member({committed, 1, B1}, Events)),
    ?assert(lists:member({committed, 2, B2}, Events)),
    ?assert(maps:is_key(1, quod_simplex:eng_committed(E5))),
    ?assert(maps:is_key(2, quod_simplex:eng_committed(E5))).

%% A support share from a non-validator does not count toward the quorum.
eng_rejects_outsider_test() ->
    C = committee(4),
    {_, Outsider} = id(),
    B = blk(1, 1 + 1),
    {E1, _}    = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(?DOMAIN, pubs(C),{{?FIXTURE_ERA, 0, <<1:256>>}, 1, 0})),
    Bad = quod_simplex:make_share(?DOMAIN, support, {?FIXTURE_ERA, 1}, quod_simplex:block_hash(B), Outsider),
    {E2, Ev2}  = feed_shares(supports(B, C, 2) ++ [Bad], E1),   %% 2 valid + 1 outsider
    ?assertNot(lists:member({notarized, B}, Ev2)),
    ?assertNot(maps:is_key(1, quod_simplex:eng_tree(E2))).

%% A cert learned from a peer is added + re-disseminated ONCE (never twice), and notarizes the block.
eng_relays_cert_once_test() ->
    C = committee(4),
    B = blk(1, 1 + 1),
    {ok, SC} = quod_simplex:form_cert(?DOMAIN, support, {?FIXTURE_ERA, 1}, quod_simplex:block_hash(B), supports(B, C, 3), pubs(C)),
    {E1, _}   = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(?DOMAIN, pubs(C),{{?FIXTURE_ERA, 0, <<1:256>>}, 1, 0})),
    {E2, Ev2} = quod_simplex:eng_offer({cert, SC}, E1),
    ?assert(lists:member({broadcast, SC}, Ev2)),
    ?assert(lists:member({notarized, B}, Ev2)),
    {_E3, Ev3} = quod_simplex:eng_offer({cert, SC}, E2),
    ?assertEqual([], [X || {broadcast, _} = X <- Ev3]).     %% not re-broadcast

%% The Stage-2c leader ROTATES round-robin over the sorted set, order-independently across nodes.
eng_leader_rotates_test() ->
    Ps     = pubs(committee(4)),
    Sorted = lists:sort(Ps),
    ?assertEqual(lists:min(Ps), quod_simplex:leader(1, Ps)),        %% slot 1 → lowest pubkey
    ?assertEqual(hd(tl(Sorted)), quod_simplex:leader(2, Ps)),      %% slot 2 → next (rotation)
    ?assertEqual(quod_simplex:leader(1, Ps), quod_simplex:leader(5, Ps)),   %% wraps at N=4 (1 ≡ 5)
    ?assertNotEqual(quod_simplex:leader(1, Ps), quod_simplex:leader(2, Ps)),
    ?assertEqual(quod_simplex:leader(3, Ps),                        %% order-independent (sorts internally)
                 quod_simplex:leader(3, lists:reverse(Ps))).

%% Complaint progress and dissemination each happen once; neither produces
%% material history, including when the same quorum is delivered again.
eng_complaint_advances_once_without_material_test() ->
    C = committee(4), Position = {?FIXTURE_ERA, 1},
    Shares = [quod_simplex:make_share(?DOMAIN, complaint, Position, none, Id)
              || {_, Id} <- take(3, C)],
    Engine = quod_simplex:eng_new(?DOMAIN, pubs(C),{{?FIXTURE_ERA, 0, <<1:256>>}, 1, 0}),
    {Advanced, Events} = feed_shares(Shares, Engine),
    ?assertEqual([1], [View || {view_advanced, View, complaint} <- Events]),
    ?assertMatch([#cert{kind = complaint}], [Cert || {broadcast, Cert} <- Events]),
    ?assertEqual(#{}, quod_simplex:eng_committed(Advanced)),
    ?assertEqual(#{}, quod_simplex:eng_tree(Advanced)),
    {Repeated, []} = feed_shares(Shares, Advanced),
    ?assertEqual(Advanced, Repeated).

%% An empty committee has no leader — `leader/2` returns `none` (never `rem 0`-crashes) so a committee that
%% somehow emptied leaves the statem gracefully wedged instead of crash-looping.
leader_empty_committee_test() ->
    ?assertEqual(none, quod_simplex:leader(1, [])),
    ?assertEqual(none, quod_simplex:leader(7, [])).

%% The committee projection: a transaction's diff folds into {added, removed} `peer_admitted` pubkeys —
%% a re-asserted member is idempotent, a non-peer_admitted op is ignored. `apply_committee_delta/2` applies
%% the delta onto a set, sorted + deduped — the ONE function used by BOTH the boot re-fold AND the live swap
%% on commit, so the running set can never drift from a fresh re-fold. (The end-to-end fold over a committed
%% log is exercised by the gen_statem CT `t_restart_replays`.)
committee_delta_test() ->
    [A, B, C] = [P || {P, _} <- committee(3)],
    Tx = tx([pa(A), pa(B), pa(A), rm(B), {assert, {{other, foo}, true}}]),   %% +A +B +A(dup) -B, noise
    ?assertEqual({[A], [B]}, quod_simplex:committee_delta(Tx)),
    ?assertEqual({[A], [B]}, quod_simplex:committee_delta({batch, [Tx]})),
    ?assertEqual([A], quod_simplex:apply_committee_delta(Tx, [])),
    ?assertEqual(lists:usort([A, C]), quod_simplex:apply_committee_delta(Tx, [A, C, B])),  %% A dup, C kept, B dropped
    ?assertEqual({[], []}, quod_simplex:committee_delta({batch, [Tx | bad_tail]})),
    ?assertEqual({[], []}, quod_simplex:committee_delta(noop)),                 %% invalid input carries no change
    ?assertEqual(lists:usort([A, C]), quod_simplex:apply_committee_delta(noop, [C, A])).

%% Route extraction shares the committed membership source. Retractions and
%% invalid payloads add no endpoints; the owning map fold keeps the last value.
admitted_endpoints_test() ->
    [A, B, _] = [P || {P, _} <- committee(3)],
    Full = tx([{assert,  {{peer_admitted, A, "10.0.0.1", 9001, A}, true}},
               {retract, {{peer_admitted, B, "10.0.0.2", 9002, B}, true}},   %% retract → not a hint
               {assert,  {{other, foo}, true}}]),                            %% noise → ignored
    ?assertEqual([{A, {"10.0.0.1", 9001}}], quod_simplex:admitted_endpoints({batch, [Full]})),
    ?assertEqual([], quod_simplex:admitted_endpoints(noop)),                  %% invalid payload: no hint, no crash
    ?assertEqual([], quod_simplex:admitted_endpoints({batch, [tx([rm(A)])]})), %% retract-only
    %% undefined host/port (bare-pubkey genesis members) is EXTRACTED here; is_endpoint drops it at learn.
    ?assertEqual([{A, {undefined, undefined}}],
                 quod_simplex:admitted_endpoints({batch, [tx([pa(A)])]})),
    ?assertEqual([], quod_simplex:admitted_endpoints({batch, [Full | bad_tail]})),
    %% a repeated pubkey yields BOTH assert pairs in order — the maps:from_list at the hook takes last-wins.
    Dup = tx([{assert, {{peer_admitted, A, "10.0.0.1", 9001, A}, true}},
              {assert, {{peer_admitted, A, "10.0.0.9", 9009, A}, true}}]),
    ?assertEqual([{A, {"10.0.0.1", 9001}}, {A, {"10.0.0.9", 9009}}],
                 quod_simplex:admitted_endpoints({batch, [Dup]})),
    ?assertEqual({"10.0.0.9", 9009},
                 maps:get(A, maps:from_list(quod_simplex:admitted_endpoints({batch, [Dup]})))).

validator_routes_follow_the_committee_history_test() ->
    [A, B, _] = [P || {P, _} <- committee(3)],
    Ns = <<"routes:history">>,
    P0 = quod_simplex:history_projection(),
    E1 = material_entry(1, {genesis, 0}, none,
               {batch, [tx(Ns, [
                    {assert, {{peer_admitted, A, "10.0.0.1", 9001, A}, true}},
                    {assert, {{peer_admitted, B, "10.0.0.2", 9002, B}, true}}
                ])]}, 0),
    P1 = quod_simplex:history_advance(Ns, E1, P0),
    ?assertEqual(
       #{A => {"10.0.0.1", 9001}, B => {"10.0.0.2", 9002}},
       quod_simplex:history_validator_routes(P1)),
    Root1 = {Era1, 0, _} = maps:get(protocol_root, P1),
    E2 = material_entry(2, {Era1, 1}, Root1,
               {batch, [tx(Ns, [
                    {assert, {{peer_admitted, A, "10.0.0.9", 9009, A}, true}}
                ])]}, 0),
    P2 = quod_simplex:history_advance(Ns, E2, P1),
    ?assertEqual(
       #{A => {"10.0.0.9", 9009}, B => {"10.0.0.2", 9002}},
       quod_simplex:history_validator_routes(P2)),
    [{2, Committee, CommitteeId, RefreshedRoutes},
     {1, Committee, CommitteeId, OriginalRoutes}] =
        maps:get(committee_views, P2),
    ?assertEqual(lists:sort([A, B]), Committee),
    ?assertEqual(maps:get(committee_id, P1), CommitteeId),
    ?assertEqual(quod_simplex:history_validator_routes(P2), RefreshedRoutes),
    ?assertEqual(quod_simplex:history_validator_routes(P1), OriginalRoutes),
    ?assertEqual({ok, Committee, CommitteeId, OriginalRoutes},
                 quod_simplex:history_committee_view(1, P2)),
    ?assertEqual({ok, Committee, CommitteeId, RefreshedRoutes},
                 quod_simplex:history_committee_view(2, P2)),
    Root2 = {Era2, 0, _} = maps:get(protocol_root, P2),
    E3 = material_entry(3, {Era2, 1}, Root2,
               {batch, [tx(Ns, [
                    {retract,
                     {{peer_admitted, A, "10.0.0.9", 9009, A}, true}}
                ])]}, 0),
    P3 = quod_simplex:history_advance(Ns, E3, P2),
    ?assertEqual(#{B => {"10.0.0.2", 9002}},
                 quod_simplex:history_validator_routes(P3)),
    ?assertEqual(3, length(maps:get(committee_views, P3))).

content_only_catchup_repopulates_verified_validator_routes_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = [{Self, Signer}, {Peer, _}] = lists:sort(committee(2)),
    Ns = <<"routes:content-only-catchup">>, PeerEndpoint = {"10.0.0.2", 9002},
    GenesisTx = quod_simplex:test_genesis_tx(
        #{committee => [{Self, "10.0.0.1", 9001}, {Peer, "10.0.0.2", 9002}],
          external_predicate_modules => []}, Ns, Self, <<1:256>>),
    Admission = material_entry(1, {genesis, 0}, none, {batch, [GenesisTx]}, 0),
    {ok, Genesis} = quod_ledger:block_from_entry(Admission),
    Anchor = quod_simplex:block_hash(Genesis), Identity = {Ns, Anchor},
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    P1 = quod_simplex:history_advance(Ns, Admission, quod_simplex:history_projection(Identity)),
    Root = {Era, 0, _} = maps:get(protocol_root, P1),
    SelfAdmission = maps:get(Self, maps:get(admissions, P1)),
    Unsigned = quod_transaction:bind_id(Identity,
        #transaction{origin = Identity, proof_id = <<2:256>>, plan_digest = <<3:256>>,
                     goal = durable_goal(true), result = durable_result(),
                     diff = [{assert, {{ordinary_fact, recovered}, true}}], read_check = #{},
                     author = Self, author_seq = 1, submitted_at = 1}),
    {ok, Tx} = quod_transaction:sign({Ns, Anchor, SelfAdmission}, Unsigned, Signer),
    Block = block({Era, 1}, Root, 2, {batch, [Tx]}, 1),
    Hash = quod_simplex:block_hash(Block),
    Shares = [quod_simplex:make_share(Domain, commit, {Era, 1}, Hash, Id) || {_, Id} <- Committee],
    {ok, Cert} = quod_simplex:form_cert(Domain, commit, {Era, 1}, Hash, Shares, pubs(Committee)),
    Content = quod_ledger:entry(2, Block, Cert),
    Dir = relay_store_dir("content_only_catchup_routes"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store1} = quod_ct:append_direct_history(Store0, [Admission]),
    {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
    quod_quic:ensure_cache(),
    true = ets:delete(quod_addr_cache, Peer),
    ?assertEqual(error, quod_quic:resolve(Peer)),
    try
        {ok, P1, _} = quod_ct:history_advance(
            Identity, Admission, quod_simplex:history_projection(Identity), Index),
        {ok, Group} = quod_ct:history_group(Identity, Content, P1, Index),
        ?assertEqual(quod_simplex:history_committee(P1),
                     quod_simplex:history_committee(maps:get(projection, Group))),
        Initial = quod_simplex:test_install_projection(P1,
            st(#{ns => Ns, self => Self, genesis_hash => Anchor, consensus_domain => Domain,
                 store => Store1, phase_index => Index, archive_tip => {Root, 0},
                 slot => 1, sync => {pulling, self()}})),
        {Recovered, ok} = quod_simplex:test_apply_catchup_window({recovery, self()}, Group, Initial),
        ?assertEqual({ok, PeerEndpoint}, quod_quic:resolve(Peer)),
        {2, DurableStore} = quod_simplex:test_committed_store(Recovered),
        ok = quod_ledger_store:close(DurableStore)
    after
        _ = ets:delete(quod_addr_cache, Peer),
        quod_dtx_phase_index:close(Index),
        quod_ledger_store:close(Store0),
        _ = file:del_dir_r(Dir)
    end.

%% Slice A membership gate (deferred.md §3 a+c): a committee-touching transaction must be EXACTLY ONE
%% well-formed `peer_admitted` op that neither empties the committee nor exceeds the validator cap — the
%% pure shape + bounded floor,
%% enforced before a node proposes or supports (the KB-side `can_join` verdict is the next slice).
membership_gate_test() ->
    [A, B] = pubs(committee(2)),
    %% legal single ops
    ?assert(quod_simplex:membership_change_ok(tx([pa(B)]), [A])),        %% admit one member
    ?assert(quod_simplex:membership_change_ok(tx([rm(B)]), [A, B])),     %% stepwise shrink: N=2 → 1
    ?assert(quod_simplex:membership_change_ok(tx([rm(B)]), [A])),        %% non-member retract: shape-legal
                                                                         %% (the KB verdict rejects it later)
    %% the wedge: a change that would EMPTY the committee is never acceptable
    ?assertNot(quod_simplex:membership_change_ok(tx([rm(A)]), [A])),               %% N=1 → 0
    ?assertNot(quod_simplex:membership_change_ok(tx([rm(A), rm(B)]), [A, B])),     %% mass retract
    %% shape violations: exactly one op, nothing else, well-formed head, Id =:= Pk, binary pubkey
    ?assertNot(quod_simplex:membership_change_ok(tx([pa(A), pa(B)]), [])),
    ?assertNot(quod_simplex:membership_change_ok(
                 tx([pa(A), {assert, {{other, x}, true}}]), [])),                  %% mixed content+membership
    ?assertNot(quod_simplex:membership_change_ok(
                 tx([{assert, {{peer_admitted, <<"not-the-pk">>, undefined, undefined, A}, true}}]), [])),
    ?assertNot(quod_simplex:membership_change_ok(
                 tx([{assert, {{peer_admitted, na, undefined, undefined, na}, true}}]), [A])),
    ?assertNot(quod_simplex:membership_change_ok(tx([{retract, garbage}]), [A])).  %% catch-all is total

membership_gate_enforces_validator_cap_test() ->
    Current = [<<I:256>> || I <- lists:seq(1, ?MAX_VALIDATORS)],
    Candidate = <<(?MAX_VALIDATORS + 1):256>>,
    ?assert(quod_simplex:membership_change_ok(
              tx([pa(lists:last(Current))]),
              lists:sublist(Current, ?MAX_VALIDATORS - 1))),
    ?assertNot(quod_simplex:membership_change_ok(
                 tx([pa(Candidate)]), Current)),
    %% Reasserting an existing member does not grow the set and remains a
    %% shape-valid no-op for the later KB verdict to classify.
    ?assert(quod_simplex:membership_change_ok(
              tx([pa(hd(Current))]), Current)).

%% A non-PROPER-list diff (an improper list `[Op|junk]`, or a non-list) must be rejected, never crash.
%% `binary_to_term` on the untrusted consensus wire can decode either shape, and a shallow `[Op | _]`
%% match would let it through to crash `committee_delta`'s fold during commit/restart.
membership_gate_improper_list_test() ->
    [A] = pubs(committee(1)),
    Improper = raw_tx([{assert, {{other, x}, true}} | 2]),
    NonList  = raw_tx(not_a_list),
    ?assertNot(quod_simplex:change_acceptable(Improper, [A])),
    ?assertNot(quod_simplex:change_acceptable(NonList, [A])),
    ?assert(quod_simplex:change_acceptable(tx([{assert, {{ok, x}, true}}]), [A])),   %% proper: fine
    ?assertNot(quod_simplex:change_acceptable(noop, [A])).

%% Every field consumed after consensus has a structural gate before an honest node signs.
%% In particular, a proper list containing an invalid op used to pass and crash apply_op/3.
transaction_shape_gate_test() ->
    [A] = pubs(committee(1)),
    Good = tx([{assert, {{ok, x}, true}}]),
    ?assert(quod_simplex:change_acceptable(Good, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{diff = [garbage]}, [A])),
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{diff = [{assert, {42, true}}]}, [A])),
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{diff = [{assert, {{ok, x}, 42}}]}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{read_check = []}, [A])),
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{read_check = #{{fact, -1} => {present, 0}}}, [A])),
    %% the pre-token integer-hash value space is rejected outright
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{read_check = #{{fact, 1} => 12345}}, [A])),
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{read_check = #{{fact, 1} => {present, -1}}}, [A])),
    %% the transient same-block `staged` marker is never a wire token: admitting
    %% it would let a crafted read set MATCH a same-block staged write
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{read_check = #{{fact, 1} => staged}}, [A])),
    ?assert(quod_simplex:change_acceptable(
              Good#transaction{read_check = #{{fact, 1} => {absent, 4},
                                              {other, 2} => never_present,
                                              {sys, 3} => static}}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{tx_id = <<>>}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{submitted_at = 1.5}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{sig = unsigned}, [A])).

%% Every `peer_admitted` fact is a voter (no non-voting tier): asserting one grows the set and the quorum.
committee_grows_test() ->
    [A, B] = [P || {P, _} <- committee(2)],
    Members1 = quod_simplex:apply_committee_delta(tx([pa(A)]), []),
    Members2 = quod_simplex:apply_committee_delta(tx([pa(B)]), Members1),
    ?assertEqual([A], Members1),
    ?assertEqual(lists:usort([A, B]), Members2),
    ?assertEqual(1, quod_simplex:quorum(length(Members1))),
    ?assertEqual(2, quod_simplex:quorum(length(Members2))).

%% Pruning a committed slot advances `base` and drops it from every map (the memory-leak fix), and a
%% stale share/cert/block for an already-final slot (`=< base`) is then ignored.
eng_prune_test() ->
    C = committee(4),
    B1 = blk(1, 1 + 1), B2 = blk(2, 2 + 1),
    {E1, _} = quod_simplex:eng_offer({block, B1}, quod_simplex:eng_new(?DOMAIN, pubs(C),{{?FIXTURE_ERA, 0, <<1:256>>}, 1, 0})),
    {E2, _} = quod_simplex:eng_offer({block, B2}, E1),
    {E3, _} = feed_shares(supports(B1, C, 3) ++ supports(B2, C, 3), E2),
    {E4, _} = feed_shares(commits(B1, C, 3) ++ commits(B2, C, 3), E3),
    ?assert(maps:is_key(1, quod_simplex:eng_committed(E4))),
    ?assert(maps:is_key(2, quod_simplex:eng_committed(E4))),
    %% prune past slot 1: slot 1 is dropped from tree + committed; slot 2 is retained
    E5 = quod_simplex:eng_prune(quod_ledger:block_ref(B1), E4),
    ?assertNot(maps:is_key(1, quod_simplex:eng_tree(E5))),
    ?assertNot(maps:is_key(1, quod_simplex:eng_committed(E5))),
    ?assert(maps:is_key(2, quod_simplex:eng_tree(E5))),
    %% a stale support share for the pruned slot 1 (=< base) is ignored — no event, no state change
    {E6, Ev6} = quod_simplex:eng_offer({share, hd(supports(B1, C, 1))}, E5),
    ?assertEqual([], Ev6),
    ?assertEqual(quod_simplex:eng_committed(E5), quod_simplex:eng_committed(E6)).

%%%===================================================================
%%% helpers
%%%===================================================================

relay_receiver_fixture(TxId) ->
    Ns = <<"t">>,
    Committee = committee(4),
    Validators = pubs(Committee),
    Slot = 4,
    Target = quod_simplex:leader(Slot, Validators),
    {Target, TargetId} = lists:keyfind(Target, 1, Committee),
    {Author, AuthorId} =
        hd([Member || {Pub, _} = Member <- Committee, Pub =/= Target]),
    Tx = signed_tx(
           Ns, TxId, [{assert, {{relay_fixture, TxId}, true}}],
           {Author, AuthorId}),
    {ok, Submission} = quod_transaction:submission(
                         test_binding(Ns, Author), Tx),
    SubmissionId = quod_transaction:submission_id(Submission),
    CommitteeId =
        crypto:hash(sha256, <<"fixture-view:", TxId/binary>>),
    Era = ?FIXTURE_ERA,
    AttemptId =
        quod_transaction:relay_attempt_id(
          Ns, SubmissionId, Era, Slot, Target),
    Submit =
        {relay_submit, SubmissionId, AttemptId, Era,
         Slot, Submission, []},
    S = st(#{self => Target, id => TargetId,
             validators => Validators, committee_id => CommitteeId,
             relay_conns => #{Author => {self(), make_ref()}},
             sync => ready, slot => 3, history_head => {3, <<1:256>>},
             archive_tip => {{Era, 3, <<1:256>>}, 0},
             eng => quod_simplex:eng_new(?DOMAIN, Validators, {{Era, 3, <<1:256>>}, 3, 0})}),
    {Ns, Era, Slot, Author, AuthorId, Target, Validators,
     SubmissionId, AttemptId, Submit, S}.

outbound_fixture(TxId) ->
    {Fixture, _Committee} = outbound_committee_fixture(TxId),
    Fixture.

outbound_committee_fixture(TxId) ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"t">>,
    Committee = committee(4),
    Validators = pubs(Committee),
    Slot = 4,
    Target = quod_simplex:leader(Slot, Validators),
    NextTarget = quod_simplex:leader(Slot + 1, Validators),
    {Me, MyId} =
        hd([Member || {Pub, _} = Member <- Committee,
                      Pub =/= Target, Pub =/= NextTarget]),
    CommitteeId =
        crypto:hash(sha256, <<"outbound-view:", TxId/binary>>),
    Era = ?FIXTURE_ERA,
    Change = bind_test_id(
               #transaction{tx_id = <<>>, origin = {Ns, <<0:256>>},
                            proof_id = <<0:256>>, plan_digest = <<0:256>>,
                            goal = durable_goal({relay, TxId}),
                            result = durable_result(),
                            author = Me,
                            sig = none, read_check = #{},
                            diff = [{assert,
                                     {{relay_outbound, TxId}, true}}]}),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators,
             committee_id => CommitteeId,
             relay_conns => #{Target => {self(), make_ref()},
                              NextTarget => {self(), make_ref()}},
             sync => ready, slot => 3, history_head => {3, <<1:256>>},
             archive_tip => {{Era, 3, <<1:256>>}, 0},
             eng => quod_simplex:eng_new(?DOMAIN, Validators, {{Era, 3, <<1:256>>}, 3, 0})}),
    {Sent, []} = quod_simplex:test_append(From, Change, S),
    Frame = receive_ordered_frame(),
    {relay,
     {relay_submit, SubmissionId, AttemptId, Era, Slot,
      _Submission, _Carrier}} =
        quod_relay:decode_relay_frame(Frame, Ns),
    {{Ns, Era, Slot, From, Target, Validators,
      SubmissionId, AttemptId, Frame, Sent}, Committee}.

relay_store_dir(Suffix) ->
    filename:join(
      "/tmp",
      "quod_relay_restart_" ++ Suffix ++ "_"
      ++ binary_to_list(
           binary:encode_hex(crypto:strong_rand_bytes(8)))).


%% Endpoint callback fixture: real authenticated plans and controls, shape-only
%% foreign refs. Committee/floor checks run here; remote crypto has its own suite.
applied_role_fixture(Generation, Slot) ->
    F = quod_ct:atomic_role_fixture(), Target = maps:get(target, F),
    Origin = maps:get(origin, F), OriginRef = maps:get(source_ref, F),
    OwnRef = dtx_test_ref(Target, 2, quod_atomic:record_digest(maps:get(vote, F))),
    {ok, R} = quod_atomic:new_resolve(maps:get(group, F), OriginRef, Target, commit,
                 {all_prepared, lists:sort([{Origin, OriginRef}, {Target, OwnRef}])},
                 OwnRef, Generation),
    {ok, M} = quod_atomic:admission_material(R),
    {ok, C} = quod_atomic:sign_control(Target, M, maps:get(admission, F), 2, 1, maps:get(signer, F)),
    {Entry, _, Ref} = certified_dtx_test_entry(Target, C, Slot),
    F#{control => C, group_id => quod_atomic:group_id(C), entry => Entry, ref => Ref}.

committed_dtx_test_entry(Control, Height) ->
    Payload = {batch, [{dtx, Control}]},
    Entry = material_entry(Height, {?FIXTURE_ERA, 1}, {?FIXTURE_ERA, 0, <<1:256>>},
                           Payload, 0),
    {Entry, Payload}.

certified_dtx_test_entry(Identity, Control, Slot) ->
    {Entry, Payload} = committed_dtx_test_entry(Control, Slot),
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Entry, Control),
    {Entry, Payload, Ref}.

registered_prolog_sink_loop() ->
    receive
        stop -> ok;
        _Message -> registered_prolog_sink_loop()
    end.

stop_registered_prolog_sink(Pid) ->
    MRef = monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', MRef, process, Pid, _Reason} -> ok
    after 1000 ->
        error(prolog_sink_stop_timeout)
    end.

assert_no_reply({_Pid, Tag}) ->
    receive
        {Tag, _Reply} -> ?assert(false)
    after 0 ->
        ok
    end.

drain_custody_within(S) ->
    Parent = self(),
    ReplyRef = make_ref(),
    {Pid, MonitorRef} =
        spawn_monitor(
          fun() ->
                  Parent !
                      {ReplyRef,
                       quod_simplex:test_drain_custody(S)}
          end),
    receive
        {ReplyRef, Result} ->
            receive
                {'DOWN', MonitorRef, process, Pid, normal} ->
                    Result;
                {'DOWN', MonitorRef, process, Pid, Reason} ->
                    error({custody_drain_failed, Reason})
            after 1000 ->
                exit(Pid, kill),
                error(custody_drain_did_not_exit)
            end;
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            error({custody_drain_failed, Reason})
    after 1000 ->
        exit(Pid, kill),
        receive
            {'DOWN', MonitorRef, process, Pid, _Reason} -> ok
        after 1000 ->
            ok
        end,
        error(custody_drain_timed_out)
    end.

receive_ordered_frame() ->
    receive
        {send_ordered, Frame} -> Frame
    after 0 ->
        error(missing_ordered_relay_frame)
    end.

assert_no_ordered_frame() ->
    receive
        {send_ordered, Frame} ->
            error({unexpected_ordered_relay_frame, Frame})
    after 0 ->
        ok
    end.

receive_relay_control(Ns) ->
    receive
        {send, Frame} ->
            case quod_relay:decode_relay_frame(Frame, Ns) of
                {relay, Relay} -> Relay;
                error -> error({malformed_relay_control, Frame})
            end
    after 0 ->
        error(missing_relay_control_frame)
    end.

assert_no_relay_control() ->
    receive
        {send, Frame} ->
            error({unexpected_relay_control_frame, Frame})
    after 0 ->
        ok
    end.

running_state({keep_state, S}) -> S;
running_state({keep_state, S, _Actions}) -> S.

flush_unordered_link_frames() ->
    receive
        {send, _Frame} -> flush_unordered_link_frames()
    after 0 ->
        ok
    end.

spawn_close_aware_link() ->
    Owner = self(),
    Token = make_ref(),
    Pid =
        spawn(
          fun Loop() ->
                  receive
                      close ->
                          Owner ! {close_aware_link_closed,
                                   Token, self()};
                      _Other ->
                          Loop()
                  end
          end),
    {Pid, Token}.

%% A superseded link can be slow to observe `close` (for example while its
%% mailbox is occupied). Keep it alive until an explicit release so generation
%% tests cannot pass merely because is_process_alive/1 rejects a dead pid.
spawn_stubborn_link() ->
    Owner = self(),
    Token = make_ref(),
    Pid =
        spawn(
          fun Loop() ->
                  receive
                      close ->
                          Owner !
                              {stubborn_link_close_requested,
                               Token, self()},
                          Loop();
                      {release_stubborn_link, Token} ->
                          ok;
                      _Other ->
                          Loop()
                  end
          end),
    {Pid, Token}.

await_stubborn_close_requested(Pid, Token) ->
    receive
        {stubborn_link_close_requested, Token, Pid} -> ok
    after 1000 ->
        error({stubborn_link_was_not_closed, Pid})
    end.

assert_stubborn_link_not_closed(Pid, Token) ->
    receive
        {stubborn_link_close_requested, Token, Pid} ->
            error({live_stubborn_link_was_closed, Pid})
    after 20 ->
        ?assert(is_process_alive(Pid))
    end.

release_stubborn_link(Pid, Token, Ref) ->
    Pid ! {release_stubborn_link, Token},
    receive
        {'DOWN', Ref, process, Pid, _Reason} = Down -> Down
    after 1000 ->
        error({stubborn_link_did_not_exit, Pid})
    end.

ensure_stubborn_link_closed(Pid, Token) ->
    case is_process_alive(Pid) of
        true ->
            Ref = erlang:monitor(process, Pid),
            Pid ! {release_stubborn_link, Token},
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            after 1000 ->
                _ = erlang:demonitor(Ref, [flush]),
                exit(Pid, kill)
            end;
        false ->
            ok
    end,
    flush_stubborn_close_requested(Pid, Token),
    flush_down_for(Pid).

flush_stubborn_close_requested(Pid, Token) ->
    receive
        {stubborn_link_close_requested, Token, Pid} ->
            flush_stubborn_close_requested(Pid, Token)
    after 0 ->
        ok
    end.

await_link_closed(Pid, Token) ->
    receive
        {close_aware_link_closed, Token, Pid} -> ok
    after 1000 ->
        error({link_was_not_closed, Pid})
    end.

assert_link_not_closed(Pid, Token) ->
    receive
        {close_aware_link_closed, Token, Pid} ->
            error({live_link_was_closed, Pid})
    after 20 ->
        ?assert(is_process_alive(Pid))
    end.

ensure_close_aware_link_closed(Pid, Token) ->
    case is_process_alive(Pid) of
        true ->
            Pid ! close,
            await_link_closed(Pid, Token);
        false ->
            receive
                {close_aware_link_closed, Token, Pid} -> ok
            after 0 ->
                ok
            end
    end,
    flush_down_for(Pid).

flush_down_for(Pid) ->
    receive
        {'DOWN', _Ref, process, Pid, _Reason} ->
            flush_down_for(Pid)
    after 0 ->
        ok
    end.

take(N, L) -> lists:sublist(L, N).

flip1(<<B, Rest/binary>>) -> <<(B bxor 1), Rest/binary>>.

%% a committee of N validators as [{Pubkey, IdentityMap}]; pubs/1 = just the node_ids
committee(N) -> [id() || _ <- lists:seq(1, N)].
pubs(C)      -> [P || {P, _} <- C].

%% committee-projection fixtures: a transaction whose diff is a list of peer_admitted asserts/retracts
pa(Pk)  -> {assert,  {{peer_admitted, Pk, undefined, undefined, Pk}, true}}.
rm(Pk)  -> {retract, {{peer_admitted, Pk, undefined, undefined, Pk}, true}}.
tx(Ops) -> tx(<<"t">>, Ops).

tx(Ns, Ops) ->
    Seed = <<16#42:256>>,
    {Author, Seed} = crypto:generate_key(eddsa, ed25519, Seed),
    Identity = #{pubkey => Author,
                 key => quod_identity:key_term({Author, Seed})},
    Anchor = <<0:256>>,
    Admission = <<7:256>>,
    Unsigned = quod_transaction:bind_id(
                 {Ns, Anchor},
                 #transaction{tx_id = <<>>, origin = {Ns, Anchor},
                              proof_id = <<0:256>>,
                              plan_digest = <<0:256>>,
                              goal = durable_goal(test),
                              result = durable_result(),
                              diff = Ops, read_check = #{},
                              author = Author,
                              author_seq = erlang:phash2(Ops) + 1,
                              sig = none}),
    {ok, Signed} = quod_transaction:sign(
                     {Ns, Anchor, Admission}, Unsigned, Identity),
    Signed.

raw_tx(Ops) ->
    #transaction{tx_id = <<"invalid-fixture">>,
                 origin = {<<"t">>, <<0:256>>},
                 proof_id = <<0:256>>, plan_digest = <<0:256>>,
                 goal = durable_goal(test), result = durable_result(),
                 diff = Ops, read_check = #{},
                 author = <<1:256>>, sig = none}.

signed_tx(Ns, TxId, Ops, {Pub, Identity}) ->
    signed_tx_seq(Ns, TxId, erlang:phash2(TxId) + 1, Ops,
                  {Pub, Identity}).

signed_tx_seq(Ns, Label, Seq, Ops, {Pub, Identity}) ->
    PlanDigest = <<Seq:256>>,
    Unsigned = quod_transaction:bind_id(
                 {Ns, <<0:256>>},
                 #transaction{tx_id = <<>>, origin = {Ns, <<0:256>>},
                              proof_id = <<Seq:256>>,
                              plan_digest = PlanDigest,
                              goal = durable_goal({signed, Label}),
                              result = durable_result(),
                              diff = Ops,
                              read_check = #{}, author = Pub,
                              author_seq = Seq, sig = none}),
    %% The engine fixtures run with the test default genesis anchor <<0:256>>
    %% (`#s.genesis_hash`), so signatures bind the same identity the engine
    %% verifies against.
    {ok, Signed} = quod_transaction:sign(
                     test_binding(Ns, Pub), Unsigned, Identity),
    Signed.

test_binding(Ns, Pub) ->
    {Ns, <<0:256>>, quod_simplex:test_author_admission(Pub)}.

durable_goal(Goal) ->
    {ok, Blob} = quod_durable_term:encode_goal(Goal),
    Blob.

durable_result() ->
    {ok, Blob} = quod_durable_term:encode_result(#{}),
    Blob.

dtx_test_ref({Ns, Anchor}, Slot, Digest) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, <<(200 + Slot):256>>, Digest,
                  quod_ct:fixture_finality(1, <<(200 + Slot):256>>)),
    Ref.

bind_test_id(Transaction) ->
    quod_transaction:bind_id({<<"t">>, <<0:256>>}, Transaction).

decode_submission(Ns, {submit, Author, _Signature, _Canonical} = Submission) ->
    quod_transaction:decode_verified_submission(
      test_binding(Ns, Author), Submission).

%% support/commit shares for block B from the first K committee members
supports(B, C, K) -> [quod_simplex:make_share(?DOMAIN, support, {B#block.era, B#block.slot}, quod_simplex:block_hash(B), Id)
                      || {_, Id} <- take(K, C)].
commits(B, C, K)  -> [quod_simplex:make_share(?DOMAIN, commit, {B#block.era, B#block.slot}, quod_simplex:block_hash(B), Id)
                      || {_, Id} <- take(K, C)].
complaint_share(Slot, {_Pub, Id}) ->
    quod_simplex:make_share(?DOMAIN, complaint, {?FIXTURE_ERA, Slot}, none, Id).

%% offer each share to the engine in turn, accumulating all emitted events
feed_shares(Shares, Eng) ->
    lists:foldl(fun(S, {E, Evs}) ->
                    {E1, Es} = quod_simplex:eng_offer({share, S}, E),
                    {E1, Evs ++ Es}
                end, {Eng, []}, Shares).

unique_gate_namespace(Label) ->
    <<"gate:", Label/binary, ":",
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

with_simplex_gate(Ns, Row, Fun) ->
    Name = binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
    Tab = ets:new(Name, [named_table, protected, set]),
    true = ets:insert(Tab, [{anchor, <<0:256>>}, Row]),
    try Fun(Tab)
    after
        ets:delete(Tab)
    end.

registered_prolog_owner(Ns) ->
    Parent = self(),
    Pid = spawn_link(
            fun() ->
                true = quod_reg:reg({quod_prolog, Ns}),
                Parent ! {registered_prolog_owner, self()},
                receive stop -> ok end
            end),
    receive
        {registered_prolog_owner, Pid} -> Pid
    after 1000 ->
        error(prolog_owner_registration_timeout)
    end.

stop_registered_owner(Pid) ->
    Ref = monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        error(prolog_owner_stop_timeout)
    end.

without_network_identity(Fun) when is_function(Fun, 0) ->
    SavedDesired = application:get_env(quod, namespace_desired),
    application:unset_env(quod, namespace_desired),
    try Fun()
    after
        case SavedDesired of
            {ok, Desired} ->
                application:set_env(quod, namespace_desired, Desired);
            undefined ->
                application:unset_env(quod, namespace_desired)
        end
    end.

with_network_identity(<<_:256>> = NetworkIdentity, Fun)
  when is_function(Fun, 0) ->
    SavedDesired = application:get_env(quod, namespace_desired),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    Content0 = maps:get(content, Desired0, #{}),
    RootNs = quod_ontology:root_ns(),
    Root0 = maps:get(RootNs, Content0, #{}),
    application:set_env(
      quod, namespace_desired,
      Desired0#{content =>
                    Content0#{RootNs =>
                                  Root0#{genesis_hash => NetworkIdentity}}}),
    try Fun()
    after
        case SavedDesired of
            {ok, Desired} ->
                application:set_env(quod, namespace_desired, Desired);
            undefined ->
                application:unset_env(quod, namespace_desired)
        end
    end.

validation_owner() ->
    receive stop -> ok end.

registered_dormant_operation(Suffix) ->
    Fixture = quod_ct:signed_effect_operation_submission(),
    {Ns, Anchor} = maps:get(origin, Fixture),
    Identity = #{pubkey := Author} = maps:get(source_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    SignedClaim = maps:get(claim, Fixture),
    UnsignedClaim = SignedClaim#transaction{author_seq = 0, sig = none,
                                             signed_bytes = none},
    TxId = SignedClaim#transaction.tx_id,
    Owner = spawn(fun validation_owner/0),
    Dir = relay_store_dir("dormant_operation_" ++ Suffix),
    {ok, Journal} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    S0 = st(#{ns => Ns, genesis_hash => Anchor,
              self => Author, id => Identity, validators => [Author],
              author_admissions => #{Author => Admission},
              signing_journal => Journal, sync => ready,
              eng => root_engine(0)}),
    {ok, Submission, S1} =
        quod_simplex:test_register_dormant_transaction(
          Admission, UnsignedClaim, Owner, S0),
    ?assertEqual(maps:get(submission, Fixture), Submission),
    {Dir, Fixture, Owner, TxId, S1}.

cancellation_test_starter(Parent) ->
    fun(_Ns, Submission) ->
            Pid = spawn(
                    fun() ->
                            ParentMonitor = erlang:monitor(process, Parent),
                            receive
                                stop -> ok;
                                {'DOWN', ParentMonitor, process, Parent, _} -> ok
                            end
                    end),
            Monitor = erlang:monitor(process, Pid),
            Parent ! {cancellation_started, Submission, Pid, Monitor},
            {ok, Pid, Monitor}
    end.

ensure_process_stopped(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> exit(Pid, kill);
        false -> ok
    end.

test_blocked_process() ->
    receive stop -> ok end.

test_link_probe(Parent) ->
    receive
        {send_ordered, Frame} ->
            Parent ! {dtx_link_sent, self(), Frame},
            test_link_probe(Parent);
        close ->
            Parent ! {dtx_link_closed, self()};
        stop ->
            ok
    end.

with_transport_stub(Fun) when is_function(Fun, 0) ->
    ?assertEqual(undefined, quod_reg:where({transport, node})),
    Parent = self(),
    Stub = spawn(
             fun() ->
                 true = quod_reg:reg({transport, node}),
                 Parent ! {transport_stub_ready, self()},
                 transport_stub_loop(Parent)
             end),
    receive {transport_stub_ready, Stub} -> ok
    after 1000 -> error(transport_stub_registration_timeout)
    end,
    try Fun()
    after
        Ref = monitor(process, Stub),
        Stub ! stop,
        receive {'DOWN', Ref, process, Stub, normal} -> ok
        after 1000 -> error(transport_stub_stop_timeout)
        end
    end.

transport_stub_loop(Parent) ->
    receive
        {'$gen_cast', Message} ->
            Parent ! {transport_cast, Message},
            transport_stub_loop(Parent);
        stop ->
            ok;
        _Other ->
            transport_stub_loop(Parent)
    end.

receive_exact_lease_release(Peer, Endpoint, Channel, Ref) ->
    ?assertEqual(
       {Peer, Endpoint, Channel, Ref},
       receive_any_lease_release()).

receive_any_lease_release() ->
    receive
        {transport_cast,
         {release_link_pinned, Peer, Endpoint, Channel,
          {Caller, Ref}}} when Caller =:= self() ->
            {Peer, Endpoint, Channel, Ref}
    after 1000 ->
        error(missing_exact_lease_release)
    end.

assert_no_transport_cast() ->
    receive
        {transport_cast, Unexpected} ->
            error({unexpected_transport_cast, Unexpected})
    after 0 ->
        ok
    end.

result_state(Result) -> element(2, Result).
