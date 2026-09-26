-module(quod_catchup_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").
-include("quod_transport_limits.hrl").

era_direct_and_ancestor_finality_use_the_same_verifier_test() ->
    F = finality_fixture(), Root = maps:get(root, F), Era = maps:get(era, F),
    {ok, B} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [maps:get(transaction, F)]}, 1),
    {ok, Head} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(B), 2, empty, 1),
    Direct = quod_ledger:entry(2, B, finality_cert(B, F)),
    Ancestor = quod_ledger:entry(2, B, finality_cert(Head, F)),
    ?assertEqual(ok, quod_ct:verify_finality(maps:get(identity, F), Direct, maps:get(projection, F))),
    ?assertEqual(ok, verify_witness(F, Ancestor, [Head, B])),
    ?assertEqual({error, {wrong_finality_link, 2}},
      quod_ct:verify_finality(maps:get(identity, F), Ancestor, maps:get(projection, F))),
    {ok, Wrapped} = quod_ledger:decode_entry(element(2, quod_ledger:encode_entry(Ancestor)), wrapped),
    ?assertEqual(ok, verify_witness(F, Wrapped, [Head, B])),
    BadCert = (finality_cert(B, F))#cert{sigs = [{maps:get(pubkey, maps:get(signer, F)), <<0:512>>}]},
    ?assertEqual({error, {bad_cert, 2}}, verify_witness(F, quod_ledger:entry(2, B, BadCert), [B])).

era_witness_must_restore_empty_protocol_parents_between_material_entries_test() ->
    F0 = finality_fixture(), Era = maps:get(era, F0), Tx = maps:get(transaction, F0),
    {ok, Previous} = quod_ledger:new_block({Era, 1}, maps:get(root, F0), 2, {batch, [Tx]}, 1),
    PrevRef = quod_ledger:block_ref(Previous),
    P = (maps:get(projection, F0))#{protocol_root := PrevRef,
                                    history_head := {2, element(3, PrevRef)}, timestamp := 1},
    F = F0#{projection := P},
    {ok, Carrier} = quod_ledger:new_block({Era, 2}, PrevRef, 2, empty, 1),
    {ok, B} = quod_ledger:new_block({Era, 4}, quod_ledger:block_ref(Carrier), 3, {batch, [Tx]}, 3),
    Entry = quod_ledger:entry(3, B, finality_cert(B, F)),
    ?assertEqual(ok, verify_witness(F, Entry, [B, Carrier])),
    ?assertEqual({error, {incomplete_finality, 3}}, verify_witness(F, Entry, [B])),
    {ok, Omitted} = quod_ledger:new_block({Era, 2}, PrevRef, 3, {batch, [Tx]}, 2),
    {ok, Skipping} = quod_ledger:new_block({Era, 4}, quod_ledger:block_ref(Omitted), 3, {batch, [Tx]}, 3),
    Bad = quod_ledger:entry(3, Skipping, finality_cert(Skipping, F)),
    ?assertEqual({error, {invalid_finality_path, 3}}, verify_witness(F, Bad, [Skipping, Omitted])).

era_finality_rejects_wrong_links_roots_and_backwards_time_test() ->
    F = finality_fixture(), Era = maps:get(era, F), Root = maps:get(root, F),
    {ok, B} = quod_ledger:new_block({Era, 2}, Root, 2, {batch, [maps:get(transaction, F)]}, 10),
    {ok, Head} = quod_ledger:new_block({Era, 3}, quod_ledger:block_ref(B), 2, empty, 10),
    Entry = quod_ledger:entry(2, B, finality_cert(Head, F)),
    ?assertEqual({error, {wrong_finality_link, 2}}, verify_witness(F, Entry, [B, Head])),
    {ok, Wrong} = quod_ledger:new_block({Era, 2}, Root, 2, {batch, [maps:get(transaction, F)]}, 9),
    ?assertEqual({error, {wrong_finality_link, 2}}, verify_witness(F, Entry, [Head, Wrong])),
    {ok, Backwards} = quod_ledger:new_block({Era, 3}, quod_ledger:block_ref(B), 2, empty, 9),
    ?assertEqual({error, {invalid_finality_path, 2}},
      verify_witness(F, quod_ledger:entry(2, B, finality_cert(Backwards, F)), [Backwards, B])),
    Projection = (maps:get(projection, F))#{protocol_root := {Era, 0, <<99:256>>}},
    ?assertEqual({error, {wrong_finality_root, 2}},
      verify_witness(F#{projection := Projection}, Entry, [Head, B])).

era_finality_carriers_cannot_choose_a_clock_test() ->
    F = finality_fixture(), Era = maps:get(era, F),
    {ok, Material} = quod_ledger:new_block({Era, 1}, maps:get(root, F), 2,
                                         {batch, [maps:get(transaction, F)]}, 7),
    lists:foreach(fun(Time) ->
        {ok, Carrier} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(Material), 2, empty, Time),
        Entry = quod_ledger:entry(2, Material, finality_cert(Carrier, F)),
        ?assertEqual(case Time of 7 -> ok; _ -> {error, {invalid_finality_path, 2}} end,
                     verify_witness(F, Entry, [Carrier, Material]))
    end, [6, 7, 8]),
    %% The last carrier can point straight to the captured material prefix;
    %% its inherited timestamp is checked even when the parent is not resent.
    PrevRef = quod_ledger:block_ref(Material),
    P = (maps:get(projection, F))#{protocol_root := PrevRef,
            history_head := {2, element(3, PrevRef)}, timestamp := 7},
    {ok, Wrong} = quod_ledger:new_block({Era, 2}, PrevRef, 2, empty, 8),
    {ok, Next} = quod_ledger:new_block({Era, 3}, quod_ledger:block_ref(Wrong), 3,
                                     {batch, [maps:get(transaction, F)]}, 9),
    ?assertEqual({error, {wrong_finality_root, 3}},
      verify_witness(F#{projection := P}, quod_ledger:entry(3, Next, finality_cert(Next, F)), [Next, Wrong])).

era_terminal_membership_only_allows_empty_witness_descendants_test() ->
    F = finality_fixture(), Era = maps:get(era, F), Tx = maps:get(transaction, F),
    Diff = [{assert, {{peer_admitted, <<9:256>>, <<"host">>, 1, <<9:256>>}, true}}],
    Unsigned = quod_transaction:bind_id(maps:get(identity, F),
      Tx#transaction{diff = Diff, sig = none, signed_bytes = none, authentication = none}),
    {Ns, Anchor} = maps:get(identity, F),
    {ok, Membership} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, Unsigned, maps:get(signer, F)),
    {ok, M} = quod_ledger:new_block({Era, 1}, maps:get(root, F), 2, {batch, [Membership]}, 1),
    {ok, Carrier} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(M), 2, empty, 1),
    ?assertEqual(ok, verify_witness(F, quod_ledger:entry(2, M, finality_cert(Carrier, F)), [Carrier, M])),
    {ok, Illegal} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(M), 3, {batch, [Tx]}, 1),
    ?assertEqual({error, {invalid_finality_path, 2}},
      verify_witness(F, quod_ledger:entry(2, M, finality_cert(Illegal, F)), [Illegal, M])).

era_finality_stream_continues_from_the_archived_cursor_test_() ->
    {timeout, 30, fun() ->
        F = finality_fixture(), Era = maps:get(era, F), {Ns, _} = maps:get(identity, F),
        {ok, B} = quod_ledger:new_block({Era, 1}, maps:get(root, F), 2, {batch, [maps:get(transaction, F)]}, 1),
        {Proof, _} = lists:foldl(fun(V, {Acc, Parent}) ->
            {ok, Carrier} = quod_ledger:new_block({Era, V}, Parent, 2, empty, 1),
            {[Carrier | Acc], quod_ledger:block_ref(Carrier)}
        end, {[B], quod_ledger:block_ref(B)}, lists:seq(2, 6500)),
        Entry = quod_ledger:entry(2, B, finality_cert(hd(Proof), F)),
        Bodies = [quod_ledger:block_bytes(Block) || Block <- Proof],
        Size = lists:sum([13 + byte_size(Bytes) || Bytes <- Bodies]),
        ?assert(Size > 900 * 1024),
        Source = {Size, fun([]) -> done; ([Bytes | Rest]) -> {Bytes, Rest} end, Bodies},
        Dir = filename:join("/tmp", "quod_stream_finality_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        try
            {ok, S0} = quod_ledger_store:open(Ns, Dir),
            Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
            {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
            {ok, S2} = quod_ledger_store:append(S1, {Source, [Entry]}),
            Snapshot = quod_ledger_store:snapshot(S2),
            ok = quod_ledger_store:close(S2),
            {ok, Reader} = quod_ledger_store:open_ro_snapshot(Snapshot),
            {ok, Cursor} = quod_ledger_store:proof_cursor(Reader, 2),
            ?assertEqual(ok, quod_ct:verify_finality(maps:get(identity, F), Entry, maps:get(projection, F),
                {fun(C) -> quod_ledger_store:proof_next(Reader, C) end, Cursor})),
            {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
            try
                {ok, _, _} = quod_ct:history_advance(maps:get(identity, F), Genesis,
                    quod_simplex:history_projection(maps:get(identity, F)), Index),
                {ok, View} = quod_dtx_phase_index:capture(Index, 2),
                {ok, Sender} = quod_catchup:evidence_open(Reader, View, genesis, tip),
                {Evidence, Sent} = consume_evidence_sender(Reader, Sender,
                    quod_catchup:evidence_begin(maps:get(identity, F), none, tip), []),
                ?assertEqual([1, 2], [H || {evidence, _, H} <- Sent]),
                ?assertEqual(length(Proof), length([ok || {proof, _} <- Sent])),
                ?assertEqual(2, quod_ledger:entry_index(maps:get(entry, Evidence)))
            after quod_dtx_phase_index:close(Index) end,
            ok = quod_ledger_store:close(Reader)
        after file:del_dir_r(Dir) end
    end}.

era_finality_genesis_is_pinned_before_any_committee_exists_test() ->
    F = finality_fixture(), Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
    ?assertEqual(ok, quod_ct:verify_finality(maps:get(identity, F), Genesis,
                                              quod_simplex:history_projection())),
    {Ns, _} = maps:get(identity, F),
    ?assertEqual({error, {cert_mismatch, 1}},
      quod_ct:verify_finality({Ns, <<99:256>>}, Genesis, quod_simplex:history_projection())).

era_shared_finality_verifies_a_material_group_in_one_pass_test() ->
    F = finality_fixture(), Era = maps:get(era, F), Tx = maps:get(transaction, F),
    {Reverse, _} = lists:foldl(fun(V, {Acc, Parent}) ->
        {ok, B} = quod_ledger:new_block({Era, V}, Parent, V + 1, {batch, [Tx]}, 1),
        {[B | Acc], quod_ledger:block_ref(B)}
    end, {[], maps:get(root, F)}, lists:seq(1, 256)),
    Cert = finality_cert(hd(Reverse), F),
    Entries = [quod_ledger:entry(I, B, Cert)
                 || {I, B} <- lists:zip(lists:seq(2, 257), lists:reverse(Reverse))],
    ?assertEqual(ok, verify_witness(F, Entries, Reverse)),
    %% A missing material entry cannot be hidden inside otherwise genuine
    %% ancestry. Signed heights prevent renumbering the later entries; the
    %% shared verifier still refuses a noncontiguous material group.
    [First, _Omitted | Others] = lists:reverse(Reverse),
    Missing = [quod_ledger:entry(B#block.height, B, Cert) || B <- [First | Others]],
    ?assertEqual({error, {invalid_finality_group, 2}}, verify_witness(F, Missing, Reverse)).

era_projection_rotates_only_at_the_material_membership_boundary_test() ->
    F = finality_fixture(), {Ns, Anchor} = Binding = maps:get(identity, F),
    Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
    P0 = quod_simplex:history_advance(Ns, Genesis, quod_simplex:history_projection(Binding)),
    ?assertEqual(maps:get(root, F), maps:get(protocol_root, P0)),
    Tx = maps:get(transaction, F), Era = maps:get(era, F),
    Diff = [{assert, {{peer_admitted, <<9:256>>, <<"host">>, 1, <<9:256>>}, true}}],
    Unsigned = quod_transaction:bind_id(Binding,
      Tx#transaction{diff = Diff, sig = none, signed_bytes = none, authentication = none}),
    {ok, Membership} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, Unsigned, maps:get(signer, F)),
    {ok, M} = quod_ledger:new_block({Era, 9}, maps:get(root, F), 2, {batch, [Membership]}, 1),
    {ok, Carrier} = quod_ledger:new_block({Era, 10}, quod_ledger:block_ref(M), 2, empty, 1),
    Direct = quod_ledger:entry(2, M, finality_cert(M, F)),
    ViaCarrier = quod_ledger:entry(2, M, finality_cert(Carrier, F)),
    P1 = quod_simplex:history_advance(Ns, Direct, P0),
    ?assertEqual(P1, quod_simplex:history_advance(Ns, ViaCarrier, P0)),
    Hash = element(3, quod_ledger:block_ref(M)),
    NextEra = quod_ledger:next_era(Binding, Era, Hash),
    ?assertEqual({NextEra, 0, Hash}, maps:get(protocol_root, P1)),
    ?assertEqual({2, Hash}, maps:get(history_head, P1)),
    {ok, B} = quod_ledger:new_block({NextEra, 1}, {NextEra, 0, Hash}, 3, {batch, [Tx]}, 2),
    Entry = quod_ledger:entry(3, B, finality_cert(B, F)),
    P2 = quod_simplex:history_advance(Ns, Entry, P1),
    ?assertEqual(quod_ledger:block_ref(B), maps:get(protocol_root, P2)),
    ?assertEqual(3, element(1, maps:get(history_head, P2))).

era_exact_claim_proof_does_not_grant_complete_group_custody_test() ->
    F = finality_fixture(), Era = maps:get(era, F), Tx = maps:get(transaction, F),
    {ok, First} = quod_ledger:new_block({Era, 1}, maps:get(root, F), 2, {batch, [Tx]}, 1),
    {ok, Second} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(First), 3, {batch, [Tx]}, 2),
    Cert = finality_cert(Second, F), E2 = quod_ledger:entry(2, First, Cert),
    E3 = quod_ledger:entry(3, Second, Cert),
    Begin = fun(Entries) -> quod_catchup:finality_begin(maps:get(identity, F), Entries, maps:get(projection, F)) end,
    {more, One} = Begin(E2),
    {more, AfterHead} = quod_catchup:finality_block(One, Second#block.block_bytes),
    ?assertMatch({done, #{head_timestamp := 2, complete_group := false}},
                  quod_catchup:finality_block(AfterHead, First#block.block_bytes)),
    {more, Both} = Begin([E2, E3]),
    {more, GroupHead} = quod_catchup:finality_block(Both, Second#block.block_bytes),
    ?assertMatch({done, #{head_timestamp := 2, complete_group := true}},
                  quod_catchup:finality_block(GroupHead, First#block.block_bytes)),
    Source = {fun([]) -> done; ([B | Rest]) -> {ok, quod_ledger:block_bytes(B), Rest} end,
              [Second, First]},
    ?assertMatch({ok, #{complete_group := false}},
      quod_catchup:verify_finality(maps:get(identity, F), [E2], maps:get(projection, F), Source)),
    ?assertMatch({ok, #{complete_group := true}},
      quod_catchup:verify_finality(maps:get(identity, F), [E2, E3], maps:get(projection, F), Source)).

era_forward_group_checks_semantics_and_reuses_foreign_recovery_test() ->
    F = finality_fixture(), {Ns, Anchor} = Binding = maps:get(identity, F),
    Era = maps:get(era, F), Signer = maps:get(signer, F), Pub = maps:get(pubkey, Signer),
    Tx = maps:get(transaction, F),
    Unsigned2 = quod_transaction:bind_id(Binding,
        Tx#transaction{author_seq = 2, proof_id = <<22:256>>, sig = none,
                       signed_bytes = none, authentication = none}),
    {ok, Tx2} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, Unsigned2, Signer),
    {ok, First} = quod_ledger:new_block({Era, 1}, maps:get(root, F), 2, {batch, [Tx]}, 1),
    {ok, Second} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(First), 3, {batch, [Tx2]}, 1),
    {ok, Carrier} = quod_ledger:new_block({Era, 3}, quod_ledger:block_ref(Second), 3, empty, 1),
    Cert = finality_cert(Carrier, F), Entries = [quod_ledger:entry(2, First, Cert), quod_ledger:entry(3, Second, Cert)],
    Bodies = [quod_ledger:block_bytes(B) || B <- [Carrier, Second, First]],
    ReadSource = {fun([]) -> done; ([B | R]) -> {ok, B, R} end, Bodies},
    WriteSource = {lists:sum([13 + byte_size(B) || B <- Bodies]),
                   fun([]) -> done; ([B | R]) -> {B, R} end, Bodies},
    Dir = filename:join("/tmp", "quod_group_forward_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    try
        {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
        try
            Empty = quod_simplex:history_projection(Binding),
            Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
            {ok, P0, GenesisDelta, genesis} = quod_catchup:verify_forward_group(
                Binding, [Genesis], Empty, Index, {fun(_) -> done end, none}),
            ?assertMatch({ok, #{rows := 0}}, quod_dtx_phase_index:stats(Index)),
            ok = quod_dtx_phase_index:commit_delta(Index, GenesisDelta),
            Before = quod_dtx_phase_index:stats(Index),
            {ok, P, _Delta, #{complete_group := true}} = quod_catchup:verify_forward_group(
                Binding, Entries, P0, Index, ReadSource),
            ?assertEqual(2, maps:get(Pub, maps:get(sequences, P))),
            ?assertEqual({3, element(3, quod_ledger:block_ref(Second))}, maps:get(history_head, P)),
            ?assertEqual(Before, quod_dtx_phase_index:stats(Index)),
            %% The actual page receiver shares authentication across material
            %% entries and their proof blocks. Finality still pays its own QC.
            Path = filename:join(Dir, "page-proof"),
            quod_ledger_store:with_proof_stage(Path, fun(Stage) ->
                Range = quod_catchup:range_begin(Binding, 3, wrapped, Stage, none, P0, Index),
                Parts = [{group, 2, 3}] ++
                    [{entry, element(2, quod_ledger:encode_entry(E))} || E <- Entries] ++
                    [{proof, B} || B <- Bodies] ++ [end_group],
                Install = fun(#{entries := Installed, projection := InstalledProjection}, none) ->
                    ?assertEqual(P, InstalledProjection),
                    {ok, Installed, InstalledProjection, Index}
                end,
                {{ok, Received}, {call_count, Calls}} = tprof:profile(fun() ->
                    quod_catchup:range_accept(Range, Parts, 3, done, Install)
                end, #{type => call_count, report => return, pattern => [{crypto, verify, 5}]}),
                ?assertEqual(Entries, quod_catchup:range_context(Received)),
                ?assertEqual(3, lists:sum([N || {crypto, verify, 5, Ps} <- Calls, {_, N, _} <- Ps]))
            end),
            %% Genuine finality alone is insufficient: a reused author sequence
            %% fails semantic replay and leaves the borrowed index untouched.
            {ok, Repeated} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(First), 3, {batch, [Tx]}, 1),
            BadCert = finality_cert(Repeated, F),
            BadEntries = [quod_ledger:entry(2, First, BadCert), quod_ledger:entry(3, Repeated, BadCert)],
            BadSource = {fun([]) -> done; ([B | R]) -> {ok, quod_ledger:block_bytes(B), R} end,
                         [Repeated, First]},
            ?assertEqual({error, {invalid_transaction, 3}},
              quod_catchup:verify_forward_group(Binding, BadEntries, P0, Index, BadSource)),
            ?assertEqual(Before, quod_dtx_phase_index:stats(Index)),
            {ok, S0} = quod_ledger_store:open(Ns, Dir),
            {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
            {ok, S2} = quod_ledger_store:append(S1, {WriteSource, Entries}),
            ok = quod_ledger_store:close(S2),
            {ok, Reader} = quod_ledger_store:open_ro(Ns, Dir, wrapped),
            {ok, RecoveredIndex} = quod_dtx_phase_index:open(Dir, <<"recovered">>),
            try
                ?assertEqual({ok, P}, quod_foreign_log:test_replay_cache(Reader, Binding, Empty, RecoveredIndex))
            after
                quod_dtx_phase_index:close(RecoveredIndex), quod_ledger_store:close(Reader)
            end
        after quod_dtx_phase_index:close(Index) end
    after file:del_dir_r(Dir) end.

finality_fixture() ->
    F = #{identity := {_, Anchor}, era := Era} =
        quod_ct:protocol_fixture(<<"quod:finality-cursor">>),
    F#{root => {Era, 0, Anchor}}.

range_batch_preserves_phase_delta_across_pages_test() ->
    Fixture = quod_foreign_log_tests:prepared_then_committed_fixture(<<"range:pending-phases">>),
    quod_ct:with_network_identity(maps:get(network, Fixture), fun() ->
        Binding = {Ns, _} = {maps:get(ns, Fixture), maps:get(anchor, Fixture)},
        Dir = quod_foreign_log_tests:temp_dir("range-pending-phases"),
        {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
        {ok, Store} = quod_ledger_store:open(Ns, Dir),
        try
            Before = quod_dtx_phase_index:stats(Index),
            Parts = quod_foreign_log_tests:fixture_page_parts(Fixture, 1, 3),
            {FirstPage, SecondPage} = lists:splitwith(fun(P) -> P =/= {group, 3, 3} end, Parts),
            ?assertMatch([_ | _], SecondPage),
            quod_ledger_store:with_proof_stage(filename:join(Dir, "proof-stage"), fun(Stage) ->
                Range = quod_catchup:range_begin(Binding, 3, wrapped, Stage,
                    quod_ledger_store:batch_begin(Store), quod_simplex:history_projection(Binding), Index),
                Install = fun(#{proof := Proof, entries := Entries,
                                projection := P, delta := Delta}, Batch) ->
                    {ok, Next} = quod_ledger_store:batch_append(Batch, {Proof, Entries}),
                    ?assertEqual(Before, quod_dtx_phase_index:stats(Index)),
                    {ok, Next, P, Index, Delta}
                end,
                {ok, Partial} = quod_catchup:range_accept(Range, FirstPage, 3, {<<"next">>, 1}, Install),
                {ok, Complete} = quod_catchup:range_accept(Partial, SecondPage, 3, done, Install),
                ?assertEqual(Before, quod_dtx_phase_index:stats(Index)),
                {ok, Durable} = quod_ledger_store:batch_sync(quod_catchup:range_context(Complete)),
                ok = quod_dtx_phase_index:commit_delta(Index, quod_catchup:range_delta(Complete)),
                {ok, History} = quod_dtx_phase_index:history(Index, maps:get(group_id, Fixture)),
                ?assertEqual({ok, maps:get(resolve_ref, Fixture)}, quod_atomic:history_phase(resolve, History)),
                ?assertEqual(3, quod_ledger_store:last(Durable)),
                %% Each group's proof survived reset/reuse of the one stage.
                ?assertMatch({ok, _}, quod_ledger_store:proof_cursor(Durable, 2)),
                ?assertMatch({ok, _}, quod_ledger_store:proof_cursor(Durable, 3))
            end)
        after
            quod_ledger_store:close(Store), quod_dtx_phase_index:close(Index), file:del_dir_r(Dir)
        end
    end).

sparse_evidence_reads_genesis_and_exact_claim_only_test_() ->
    [{integer_to_list(Height), {timeout, 30, fun() ->
        F = quod_foreign_log_tests:long_identity_fixture(<<"evidence:exact">>, Height),
        with_evidence_archive(F, fun(Store, Index, Identity, _P) ->
            Entry = lists:last(maps:get(chain, F)), {ok, Block} = quod_ledger:block_from_entry(Entry),
            Selection = {exact, Height, Block#block.era},
            {ok, Sender} = quod_catchup:evidence_open(Store, Index, genesis, Selection),
            {Result, Parts} = consume_evidence_sender(Store, Sender,
                quod_catchup:evidence_begin(Identity, none, Selection), []),
            ?assertEqual([1, Height], [H || {evidence, _, H} <- Parts]),
            ?assertEqual(1, length([ok || {proof, _} <- Parts])),
            ?assertEqual(element(2, quod_ledger:encode_entry(Entry)),
                         element(2, quod_ledger:encode_entry(maps:get(entry, Result)))),
            Authority = maps:get(authority, Result),
            {ok, WarmSender} = quod_catchup:evidence_open(Store, Index, Block#block.era, Selection),
            {_WarmResult, WarmParts} = consume_evidence_sender(Store, WarmSender,
                quod_catchup:evidence_begin(Identity, Authority, Selection), []),
            ?assertEqual([Height], [H || {evidence, _, H} <- WarmParts])
        end)
    end}} || Height <- [2, 64, 257]].

sparse_evidence_requires_membership_chain_and_checks_wrong_era_test() ->
    F0 = quod_ct:protocol_fixture(<<"evidence:membership">>),
    Identity = {Ns, Anchor} = maps:get(identity, F0), Era = maps:get(era, F0),
    Pub = maps:get(pubkey, maps:get(signer, F0)),
    {ok, First} = quod_ledger:new_block({Era, 1}, {Era, 0, Anchor}, 2,
                                      {batch, [maps:get(transaction, F0)]}, 1),
    Membership = evidence_transaction(F0, 2,
        [{assert, {{peer_admitted, Pub, <<"localhost">>, 1, Pub}, true}}]),
    {ok, M} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(First), 3, {batch, [Membership]}, 2),
    MHash = element(3, quod_ledger:block_ref(M)), NextEra = quod_ledger:next_era(Identity, Era, MHash),
    NextTx = evidence_transaction(F0, 3, []),
    {ok, Last} = quod_ledger:new_block({NextEra, 1}, {NextEra, 0, MHash}, 4, {batch, [NextTx]}, 3),
    Genesis = quod_ledger:entry(1, maps:get(genesis, F0), none),
    Chain = [Genesis | [quod_ledger:entry(B#block.height, B, finality_cert(B, F0)) || B <- [First, M, Last]]],
    F = F0#{ns => Ns, anchor => Anchor, chain => Chain},
    with_evidence_archive(F, fun(Store, Index, _, _) ->
        {ok, Sender} = quod_catchup:evidence_open(Store, Index, genesis, tip),
        {Result, Parts} = consume_evidence_sender(Store, Sender,
            quod_catchup:evidence_begin(Identity, none, tip), []),
        ?assertEqual([1, 3, 4], [H || {evidence, _, H} <- Parts]),
        ?assertMatch(#{authority := #{protocol_root := {NextEra, 0, MHash}},
                       authorities := #{Era := _, NextEra := _}}, Result),
        {ok, OldAuthority} = quod_simplex:history_authority_advance(Identity, Genesis, none),
        ClaimParts = lists:dropwhile(fun(P) -> P =/= {evidence, claim, 4} end, Parts),
        ?assertEqual({error, {cert_mismatch, 4}}, quod_catchup:evidence_accept(
            quod_catchup:evidence_begin(Identity, OldAuthority, tip), ClaimParts, 4, done)),
        ?assertEqual({error, wrong_requested_era}, quod_catchup:evidence_open(Store, Index, genesis, {exact, 4, Era})),
        {ok, GenesisSender} = quod_catchup:evidence_open(Store, Index, NextEra, {exact, 1, genesis}),
        {_GenesisResult, GenesisParts} = consume_evidence_sender(Store, GenesisSender,
            quod_catchup:evidence_begin(Identity, maps:get(authority, Result), {exact, 1, genesis}), []),
        ?assertEqual([1], [H || {evidence, _, H} <- GenesisParts])
    end),
    with_evidence_archive(F#{chain := lists:sublist(Chain, 3)}, fun(Store, Index, _, _) ->
        {ok, ColdSender} = quod_catchup:evidence_open(Store, Index, genesis, tip),
        {Cold, _} = consume_evidence_sender(Store, ColdSender,
            quod_catchup:evidence_begin(Identity, none, tip), []),
        Authority = maps:get(authority, Cold),
        lists:foreach(fun(Selection) ->
            {ok, RootSender} = quod_catchup:evidence_open(Store, Index, NextEra, Selection),
            {Warm, RootParts} = consume_evidence_sender(Store, RootSender,
                quod_catchup:evidence_begin(Identity, Authority, Selection), []),
            ?assertEqual(Authority, maps:get(authority, Warm)),
            ?assertEqual(MHash, quod_simplex:entry_history_hash(maps:get(entry, Warm))),
            ?assertMatch([{evidence, claim, 3}, {entry, _}, end_group], RootParts),
            %% The sender's era hint is only a selection optimization. The
            %% receiver must already own this exact identity/height/hash.
            lists:foreach(fun(Untrusted) ->
                ?assertMatch({error, _}, quod_catchup:evidence_accept(
                    quod_catchup:evidence_begin(Identity, Untrusted, Selection), RootParts, 3, done))
            end, [none, Authority#{identity := {<<"other">>, Anchor}},
                  Authority#{height := 2}, Authority#{protocol_root := {NextEra, 0, <<0:256>>}}])
        end, [tip, {exact, 3, Era}])
    end).

sparse_claim_checks_finality_and_signed_parent_heights_test() ->
    F = finality_fixture(), Identity = maps:get(identity, F), Era = maps:get(era, F),
    Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
    {ok, Authority} = quod_simplex:history_authority_advance(Identity, Genesis, none),
    {ok, Block} = quod_ledger:new_block({Era, 80}, {Era, 79, <<79:256>>}, 50,
        {batch, [maps:get(transaction, F)]}, 1),
    Entry = quod_ledger:entry(50, Block, finality_cert(Block, F)),
    Accept = fun(E, Proofs) ->
        Parts = [{evidence, claim, 50}, {entry, element(2, quod_ledger:encode_entry(E))}]
            ++ [{proof, quod_ledger:block_bytes(B)} || B <- Proofs] ++ [end_group],
        quod_catchup:evidence_accept(
            quod_catchup:evidence_begin(Identity, Authority, {exact, 50, Era}), Parts, 50, done)
    end,
    %% An authentic exact claim requires no earlier material entries.
    ?assertMatch({ok, _}, Accept(Entry, [Block])),
    BadCert = (finality_cert(Block, F))#cert{sigs = [{maps:get(pubkey, maps:get(signer, F)), <<0:512>>}]},
    ?assertEqual({error, {bad_cert, 50}}, Accept(quod_ledger:entry(50, Block, BadCert), [Block])),
    {ok, WrongHeight} = quod_ledger:new_block({Era, 81}, quod_ledger:block_ref(Block), 51, empty, 1),
    ?assertEqual({error, {invalid_finality_path, 50}},
        Accept(quod_ledger:entry(50, Block, finality_cert(WrongHeight, F)), [WrongHeight, Block])).

evidence_transaction(F = #{identity := Identity = {Ns, Anchor}}, Sequence, Diff) ->
    Base = maps:get(transaction, F),
    Unsigned = quod_transaction:bind_id(Identity, Base#transaction{author_seq = Sequence,
        proof_id = <<Sequence:256>>, submitted_at = Sequence, diff = Diff,
        sig = none, signed_bytes = none, authentication = none}),
    {ok, Tx} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, Unsigned, maps:get(signer, F)),
    Tx.

with_evidence_archive(F, Fun) ->
    Binding = {Ns, _} = {maps:get(ns, F), maps:get(anchor, F)},
    Dir = quod_foreign_log_tests:temp_dir("sparse-evidence"),
    {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
    {ok, Store} = quod_ledger_store:open(Ns, Dir),
    try
        {Batch, Projection} = lists:foldl(fun(Entry, {Pending, P}) ->
            {ok, P1, _} = quod_ct:history_advance(Binding, Entry, P, Index),
            {ok, Next} = quod_ledger_store:batch_append(Pending, {quod_ct:direct_proof(Entry), [Entry]}),
            {Next, P1}
        end, {quod_ledger_store:batch_begin(Store), quod_simplex:history_projection(Binding)}, maps:get(chain, F)),
        {ok, Durable} = quod_ledger_store:batch_sync(Batch),
        {ok, View} = quod_dtx_phase_index:capture(Index, quod_ledger_store:last(Durable)),
        Fun(Durable, View, Binding, Projection)
    after
        quod_ledger_store:close(Store), quod_dtx_phase_index:close(Index), file:del_dir_r(Dir)
    end.

consume_evidence_sender(Store, Sender, Receiver, Acc) ->
    {ok, Parts, Next} = quod_catchup:transfer_page(Store, Sender),
    Continuation = case Next of done -> done; _ -> {<<1:128>>, 1} end,
    {ok, Received} = quod_catchup:evidence_accept(Receiver, Parts,
                                                quod_ledger_store:last(Store), Continuation),
    case Next of
        done -> {ok, Result} = quod_catchup:evidence_result(Received),
                {Result, lists:append(lists:reverse([Parts | Acc]))};
        _ -> consume_evidence_sender(Store, Next, Received, [Parts | Acc])
    end.

era_paged_transfer_verifies_once_then_appends_the_complete_staged_group_test_() ->
    {timeout, 30, fun() ->
        F = finality_fixture(), {Ns, _} = Binding = maps:get(identity, F),
        Era = maps:get(era, F),
        {ok, B} = quod_ledger:new_block({Era, 1}, maps:get(root, F), 2,
                                       {batch, [maps:get(transaction, F)]}, 1),
        {Proof, _} = lists:foldl(fun(V, {Acc, Parent}) ->
            {ok, Carrier} = quod_ledger:new_block({Era, V}, Parent, 2, empty, 1),
            {[Carrier | Acc], quod_ledger:block_ref(Carrier)}
        end, {[B], quod_ledger:block_ref(B)}, lists:seq(2, 8001)),
        Entry = quod_ledger:entry(2, B, finality_cert(hd(Proof), F)),
        Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
        Bodies = [quod_ledger:block_bytes(Block) || Block <- Proof],
        Source = {lists:sum([quod_ledger_store:proof_frame_size(Bytes) || Bytes <- Bodies]),
                  fun([]) -> done; ([Bytes | Rest]) -> {Bytes, Rest} end, Bodies},
        Dir = filename:join("/tmp", "quod_paged_group_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        try
            {ok, I} = quod_dtx_phase_index:open(Dir, Ns),
            {ok, S0} = quod_ledger_store:open(Ns, filename:join(Dir, "source")),
            {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
            {ok, SourceStore} = quod_ledger_store:append(S1, {Source, [Entry]}),
            {ok, D0} = quod_ledger_store:open(Ns, filename:join(Dir, "target")),
            {ok, Target} = quod_ledger_store:append(D0, {none, [Genesis]}),
            {ok, P, GenesisDelta, genesis} = quod_catchup:verify_forward_group(
                Binding, [Genesis], quod_simplex:history_projection(Binding), I,
                {fun(_) -> done end, none}),
            ok = quod_dtx_phase_index:commit_delta(I, GenesisDelta),
            Before = quod_dtx_phase_index:stats(I),
            Send = quod_catchup:transfer_open(SourceStore, 2, 2),
            try
                quod_ledger_store:with_proof_stage(filename:join(Dir, "interrupted"), fun(Stage) ->
                    {ok, T} = quod_catchup:transfer_begin(Binding, 2, P, I, wrapped, Stage),
                    {ok, [{group, 2, 2} | Page], More} = quod_catchup:transfer_page(SourceStore, Send),
                    ?assertNotEqual(done, More),
                    ?assertEqual({error, incomplete_transfer}, quod_catchup:transfer_accept(T, Page, done)),
                    ?assertEqual(1, quod_ledger_store:last(Target)),
                    ?assertEqual(Before, quod_dtx_phase_index:stats(I))
                end),
                quod_ledger_store:with_proof_stage(filename:join(Dir, "complete"), fun(Stage) ->
                    {ok, T} = quod_catchup:transfer_begin(Binding, 2, P, I, wrapped, Stage),
                    {Group, Pages} = transfer_all_pages(SourceStore, Send, T, 0),
                    ?assert(Pages > 1),
                    ?assertMatch(#{finality := #{complete_group := true}}, Group),
                    ?assertEqual(Before, quod_dtx_phase_index:stats(I)),
                    {ok, Installed} = quod_ledger_store:append(Target,
                        {maps:get(proof, Group), maps:get(entries, Group)}),
                    ?assertEqual(2, quod_ledger_store:last(Installed)),
                    %% Restart validation consumes the exact persisted proof,
                    %% with no dependence on the temporary stage or sender.
                    {ok, C} = quod_ledger_store:proof_cursor(Installed, 2),
                    ?assertEqual(ok, quod_ct:verify_finality(Binding, Entry, P,
                        {fun(PC) -> quod_ledger_store:proof_next(Installed, PC) end, C})),
                    ?assertEqual({2, element(3, quod_ledger:block_ref(B))},
                                  maps:get(history_head, maps:get(projection, Group))),
                    ok = quod_ledger_store:close(Installed)
                end)
            after
                quod_ledger_store:close(SourceStore), quod_dtx_phase_index:close(I)
            end
        after file:del_dir_r(Dir) end
    end}.

transfer_all_pages(Store, Send, Receive, Count) ->
    {ok, Parts, Next} = quod_catchup:transfer_page(Store, Send),
    ?assert(length(Parts) =< ?QUOD_MAX_FOREIGN_PAGE_ENTRIES),
    {ok, Wire} = quod_safe_term:encode_canonical(Parts, ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
    {ok, Decoded} = quod_safe_term:decode_wrapped(Wire, ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
    Payload = case Decoded of [{group, 2, 2} | Rest] -> Rest; _ -> Decoded end,
    {Body, End} = case Next of
        done -> ?assertEqual(end_group, lists:last(Payload)),
                {lists:droplast(Payload), done};
        _ -> {Payload, more}
    end,
    case quod_catchup:transfer_accept(Receive, Body, End) of
        {more, T1} -> transfer_all_pages(Store, Next, T1, Count + 1);
        {done, Group} -> {Group, Count + 1}
    end.

era_transfer_batches_groups_in_one_page_instead_of_one_round_trip_per_entry_test() ->
    F = finality_fixture(), {Ns, _} = maps:get(identity, F), Era = maps:get(era, F),
    {ok, First} = quod_ledger:new_block({Era, 1}, maps:get(root, F), 2, {batch, [maps:get(transaction, F)]}, 1),
    {ok, Second} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(First), 3,
                                       {batch, [maps:get(transaction, F)]}, 1),
    Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
    Dir = filename:join("/tmp", "quod_transfer_batch_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    try
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        Store = lists:foldl(fun({Height, Block}, S) ->
            Bytes = quod_ledger:block_bytes(Block),
            Source = {quod_ledger_store:proof_frame_size(Bytes),
                      fun(done) -> done; (B) -> {B, done} end, Bytes},
            {ok, Next} = quod_ledger_store:append(S,
                {Source, [quod_ledger:entry(Height, Block, finality_cert(Block, F))]}),
            Next
        end, S1, [{2, First}, {3, Second}]),
        try
            ?assertMatch({ok, [{group, 2, 2}, {entry, _}, {proof, _}, end_group,
                               {group, 3, 3}, {entry, _}, {proof, _}, end_group], done},
                quod_catchup:transfer_page(Store, quod_catchup:transfer_open(Store, 2, 100))),
            ?assertMatch({ok, [{group, 2, 2}, {entry, _}, {proof, _}, end_group], done},
                quod_catchup:transfer_page(Store, quod_catchup:transfer_open(Store, 2, 2))),
            ?assertEqual({ok, [], done},
                quod_catchup:transfer_page(Store, quod_catchup:transfer_open(Store, 4, 4))),
            %% The second block deliberately repeats the first author sequence.
            %% Verification of a later group must preserve the context of the
            %% successfully appended prefix, including its current raw handle.
            {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
            {ok, Target} = quod_ledger_store:open(Ns, filename:join(Dir, "receiver")),
            try
                {ok, WholePage, done} = quod_catchup:transfer_page(Store,
                    quod_catchup:transfer_open(Store, 1, 3)),
                quod_ledger_store:with_proof_stage(filename:join(Dir, "range-stage"), fun(Stage) ->
                    Range = quod_catchup:range_begin(maps:get(identity, F), 3, wrapped, Stage,
                        Target, quod_simplex:history_projection(maps:get(identity, F)), Index),
                    Install = fun(Group, Current) ->
                        {ok, Installed} = quod_ledger_store:append(Current,
                            {maps:get(proof, Group), maps:get(entries, Group)}),
                        ok = quod_dtx_phase_index:commit_delta(Index, maps:get(delta, Group)),
                        {ok, Installed, maps:get(projection, Group), Index}
                    end,
                    {error, {invalid_transaction, 3}, FailedRange} =
                        quod_catchup:range_accept(Range, WholePage, 3, done, Install),
                    Retained = quod_catchup:range_context(FailedRange),
                    ?assertEqual(2, quod_ledger_store:last(Retained)),
                    ?assertMatch({ok, _}, quod_ledger_store:read_at(Retained, 2)),
                    ?assertEqual(not_found, quod_ledger_store:read_at(Retained, 3))
                end)
            after quod_ledger_store:close(Target), quod_dtx_phase_index:close(Index) end
        after quod_ledger_store:close(Store) end
    after file:del_dir_r(Dir) end.

finality_cert(B, F) -> quod_ct:protocol_certificate(B, F).

era_transfer_wire_binds_credit_request_and_opaque_continuation_test() ->
    Ns = <<"quod:transfer-wire">>, Grant = <<1:128>>, Req = <<2:128>>,
    Next = <<3:128>>, Token = <<4:128>>,
    Terms = [{history_credit3, Grant},
             {history_request3, Grant, Req, {range, 2, 257}},
             {history_request3, Grant, Req, {continue, Token, 9}},
             {history_page3, Grant, Req, [{group, 2, 3}, {entry, <<1>>}, {proof, <<2>>}],
              100, {Token, 10}, Next},
             {history_page3, Grant, Req, [end_group], 100, done, Next},
             {history_error3, Grant, Req, not_ready, Next}],
    lists:foreach(fun(Term) ->
        Wire = quod_catchup:encode_frame(Ns, Term),
        ?assertMatch({ok, Term, _}, quod_catchup:decode_frame(Ns, Wire)),
        ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(<<"other">>, Wire))
    end, Terms),
    Bad = [{history_request3, Grant, Req, {continue, Token, 0}},
           {history_request3, Grant, Req, {continue, {disk_offset, 100}, 1}},
           {history_page3, Grant, Req, [end_group], 100, done, Grant},
           {history_page3, Grant, Req, lists:duplicate(?QUOD_MAX_FOREIGN_PAGE_ENTRIES + 1, end_group),
            100, done, Next},
           {blocks_req, Grant, Req, 2, 3}],
    lists:foreach(fun(Term) ->
        {ok, Inner} = quod_safe_term:encode_canonical(Term, ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
        {ok, Wire} = quod_safe_term:encode_canonical({catchup, 3, Ns, Inner}, ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
        ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(Ns, Wire))
    end, Bad).

verify_witness(F, Entry, Blocks) ->
    quod_ct:verify_finality(maps:get(identity, F), Entry, maps:get(projection, F),
      {fun([]) -> done; ([B | Rest]) -> {ok, quod_ledger:block_bytes(B), Rest} end, Blocks}).

%%%===================================================================
%%% Streamed archive range and endpoint lifecycle fixtures.
%%%===================================================================

setup() ->
    Dir = filename:join("/tmp", "quod_catchup_test_" ++
                        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Ns = <<"catchup:test">>, F = quod_ct:protocol_fixture(Ns),
    Identity = {Ns, Anchor} = maps:get(identity, F), Era = maps:get(era, F),
    G = quod_ledger:entry(1, maps:get(genesis, F), none),
    {ok, S0} = quod_ledger_store:open(Ns, Dir),
    {ok, S1} = quod_ledger_store:append(S0, {none, [G]}),
    {Store, _, Cert} = lists:foldl(fun(I, {Acc, Parent, _}) ->
        Base = maps:get(transaction, F),
        Unsigned = quod_transaction:bind_id(Identity, Base#transaction{
            proof_id = <<I:256>>, author_seq = I - 1, sig = none,
            signed_bytes = none, authentication = none}),
        {ok, Tx} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)},
                                         Unsigned, maps:get(signer, F)),
        {ok, Block} = quod_ledger:new_block({Era, I - 1}, Parent, I, {batch, [Tx]}, I),
        C = quod_ct:protocol_certificate(Block, F),
        Bytes = quod_ledger:block_bytes(Block),
        Proof = {quod_ledger_store:proof_frame_size(Bytes),
            fun([]) -> done; ([B]) -> {B, []} end, [Bytes]},
        {ok, Next} = quod_ledger_store:append(Acc, {Proof, [quod_ledger:entry(I, Block, C)]}),
        {Next, quod_ledger:block_ref(Block), C}
    end, {S1, {Era, 0, Anchor}, none}, lists:seq(2, 5)),
    Snapshot = quod_ledger_store:snapshot(Store),
    ok = quod_ledger_store:close(Store),
    {Dir, Ns, Anchor, Cert, Snapshot}.

cleanup({Dir, _, _, _, _}) -> _ = file:del_dir_r(Dir), ok.

tx(I) -> #transaction{tx_id = integer_to_binary(I), origin = {<<"catchup:test">>, <<0:256>>},
                      diff = [{assert, {{fact, I}, true}}], read_check = #{},
                      author = <<1:256>>, sig = none}.

entry(Index, Data, Timestamp, Cert) ->
    {Position, Parent} = case Index of
        1 -> {{genesis, 0}, none};
        _ -> {{<<7:256>>, Index - 1}, {<<7:256>>, Index - 2, <<0:256>>}}
    end,
    {ok, Block} = quod_ledger:new_block(Position, Parent, Index, Data, Timestamp),
    Head = case {Index, Cert} of
        {1, none} -> none;
        {_, none} -> #cert{kind = commit, era = <<7:256>>, slot = Index - 1,
            block_hash = quod_simplex:block_hash(Block), sigs = [{<<1:256>>, <<0:512>>}]};
        _ -> Cert
    end,
    quod_ledger:entry(Index, Block, Head).

transfer_shares_authentication_only_within_one_page_test() ->
    F = finality_fixture(), Era = maps:get(era, F), Tx = maps:get(transaction, F),
    {Blocks, _} = lists:foldl(fun(V, {Acc, Parent}) ->
        {ok, B} = quod_ledger:new_block({Era, V}, Parent, V + 1, {batch, [Tx]}, 1),
        {[B | Acc], quod_ledger:block_ref(B)}
    end, {[], maps:get(root, F)}, lists:seq(1, 4)),
    Cert = finality_cert(hd(Blocks), F),
    Parts = [{entry, element(2, quod_ledger:encode_entry(quod_ledger:entry(I, B, Cert)))}
        || {I, B} <- lists:zip(lists:seq(2, 5), lists:reverse(Blocks))],
    Path = filename:join("/tmp", "quod-page-decode-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    quod_ledger_store:with_proof_stage(Path, fun(Stage) ->
        {ok, T} = quod_catchup:transfer_begin(maps:get(identity, F), 5,
            maps:get(projection, F), none, wrapped, Stage),
        [A, B, C, D] = Parts,
        {{more, Next}, {call_count, First}} = tprof:profile(fun() ->
            quod_catchup:transfer_accept(T, [A, B], more)
        end, #{type => call_count, report => return, pattern => [{crypto, verify, 5}]}),
        ?assertEqual(1, lists:sum([N || {crypto, verify, 5, Ps} <- First, {_, N, _} <- Ps])),
        {{more, _}, {call_count, Second}} = tprof:profile(fun() ->
            quod_catchup:transfer_accept(Next, [C, D], more)
        end, #{type => call_count, report => return, pattern => [{crypto, verify, 5}]}),
        %% The next page authenticates the transaction again and then the QC.
        %% No proof has arrived, so neither page authorizes an archive append.
        ?assertEqual(2, lists:sum([N || {crypto, verify, 5, Ps} <- Second, {_, N, _} <- Ps]))
    end).

transfer_does_not_reauthenticate_the_previous_material_test() ->
    Fixture = {_, _, _, _, Snapshot} = setup(),
    try
        {module, crypto} = code:ensure_loaded(crypto),
        {{ok, Parts, done}, {call_count, Rows}} = tprof:profile(fun() ->
            {ok, Store} = quod_ledger_store:open_ro_snapshot(Snapshot),
            try quod_catchup:transfer_page(Store, quod_catchup:transfer_open(Store, 3, 5))
            after quod_ledger_store:close(Store) end
        end, #{type => call_count, report => return,
               pattern => [{crypto, verify, 5}], timeout => 5000}),
        ?assertEqual([3, 4, 5], [quod_ledger:entry_index(B) || {entry, B} <- Parts]),
        ?assertEqual(0, lists:sum([N || {crypto, verify, 5, Ps} <- Rows,
                                      {_, N, _} <- Ps])),
        %% The receiver still authenticates every application.
        {{ok, _}, {call_count, Received}} = tprof:profile(fun() ->
            [Bytes | _] = [B || {entry, B} <- Parts],
            quod_ledger:decode_entry(Bytes, wrapped)
        end, #{type => call_count, report => return,
               pattern => [{crypto, verify, 5}], timeout => 5000}),
        ?assert(lists:sum([N || {crypto, verify, 5, Ps} <- Received,
                               {_, N, _} <- Ps]) > 0)
    after cleanup(Fixture) end.

transfer_ranges_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun({_Dir, _Ns, _Anchor, Cert, Snapshot}) ->
         [?_test(begin
            {ok, Store} = quod_ledger_store:open_ro_snapshot(Snapshot),
            try
                Read = fun(From, To) ->
                    {ok, Parts, done} = quod_catchup:transfer_page(Store,
                        quod_catchup:transfer_open(Store, From, To)),
                    [quod_ledger:entry_view(E) || {entry, B} <- Parts,
                         {ok, E} <- [quod_ledger:decode_entry(B)]]
                end,
                ?assertEqual([2,3,4], [E#entry.index || E <- Read(2,4)]),
                ?assertEqual([1,2,3,4,5], [E#entry.index || E <- Read(1,1000)]),
                ?assertEqual([], Read(10,20)),
                ?assertMatch([#entry{index = 5, cert = Cert}], Read(5,5)),
                %% Invalid ranges are refused at the wire boundary; the
                %% retained cursor is never silently rewound or clamped.
                ?assertException(error, function_clause,
                    quod_catchup:transfer_open(Store, 0, 3))
            after quod_ledger_store:close(Store) end
         end)]
     end}.

%% The byte budget caps the response so it fits one quod_link frame (1 MiB) — a window of large blocks is
%% returned as a shorter prefix (the joiner loops for the rest), never an oversized frame that kills the link.
byte_cap_test() ->
    Dir = filename:join("/tmp", "quod_catchup_big_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    Ns  = <<"catchup:big">>,
    Big = binary:copy(<<0>>, 200 * 1024),   %% ~200 KiB payload per entry
    _ = file:del_dir_r(Dir),
    try
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        Es = [entry(I,
                    {batch,
                     [#transaction{tx_id = integer_to_binary(I), origin = {Ns, <<0:256>>},
                                   diff = [{assert, {{blob, I}, Big}}], read_check = #{},
                                   author = <<1:256>>, sig = none}]},
                    0, none)
              || I <- lists:seq(1, 8)],      %% 8 × ~200 KiB = ~1.6 MiB total, over the ~900 KiB budget
        {ok, S1} = quod_ledger_store:append(S0, {none, Es}),
        {ok, Parts, More} = quod_catchup:transfer_page(S1,
            quod_catchup:transfer_open(S1, 1, 1000)),
        ?assertNotEqual(done, More),
        Served = [B || {entry, B} <- Parts],
        ok = quod_ledger_store:close(S1),
        ?assert(length(Served) >= 1),      %% always makes progress
        ?assert(length(Served) < 8),       %% but byte-capped below the full window
        Bytes = lists:sum([byte_size(Blob) || Blob <- Served]),
        ?assert(Bytes < 1024 * 1024)       %% the served entries fit under quod_link's 1 MiB frame cap
    after
        _ = file:del_dir_r(Dir)
    end.

count_cap_serves_a_contiguous_prefix_test() ->
    Dir = filename:join("/tmp", "quod_catchup_count_" ++
                        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Ns = <<"catchup:count">>,
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    try
        Height = ?QUOD_MAX_FOREIGN_PAGE_ENTRIES + 10,
        Entries = [entry(I, {batch, [tx(I)]}, 0, none) || I <- lists:seq(1, Height)],
        {ok, Store} = quod_ledger_store:append(Store0, {none, Entries}),
        {ok, Parts, More} = quod_catchup:transfer_page(Store,
            quod_catchup:transfer_open(Store, 1, Height)),
        ?assertNotEqual(done, More),
        ?assertEqual(?QUOD_MAX_FOREIGN_PAGE_ENTRIES, length(Parts)),
        ?assertEqual(lists:seq(1, ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1),
                     [quod_ledger:entry_index(E) || {entry, B} <- Parts,
                         {ok, E} <- [quod_ledger:decode_entry(B)]])
    after
        quod_ledger_store:close(Store0),
        _ = file:del_dir_r(Dir)
    end.

%% Link framing validates bounded canonical parts; only the receiving history
%% consumer decodes vocabulary and verifies the complete certified ancestry.
canonical_outer_and_inner_frames_are_exact_test() ->
    Ns = <<"catchup:canonical">>,
    Term = {history_page3, <<1:128>>, <<2:128>>,
            [{entry, binary:copy(<<0>>, 2048)}], 2, done, <<3:128>>},
    Inner = term_to_binary(Term, [deterministic]),
    Outer = raw_frame(Ns, Term),
    <<131, 104, 4, OuterFields/binary>> = Outer,
    Bad = [<<Outer/binary, 0>>,
           <<131, 105, 4:32, OuterFields/binary>>,
           term_to_binary({catchup, 3, Ns, <<Inner/binary, 0>>}, [deterministic]),
           term_to_binary({catchup, 3, Ns, Inner}, [compressed, deterministic]),
           term_to_binary({catchup, 3, Ns, term_to_binary(Term, [compressed, deterministic])},
                          [deterministic]),
           raw_frame(<<"another:namespace">>, Term)],
    lists:foreach(fun(Frame) ->
        ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(Ns, Frame))
    end, Bad),
    Canonical = term_to_binary({history_request3, <<1:128>>, <<2:128>>, {range, 1, 2}}, [deterministic]),
    N = byte_size(Canonical) - 4,
    <<Prefix:N/binary, 97, 1, 97, 2>> = Canonical,
    Noncanonical = <<Prefix/binary, 98, 1:32/signed-big, 97, 2>>,
    ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(
      Ns, term_to_binary({catchup, 3, Ns, Noncanonical}, [deterministic]))).

page_count_bytes_and_frame_headroom_test() ->
    Ns = <<"catchup:bounds">>, Grant = <<1:128>>, ReqId = <<2:128>>, Next = <<3:128>>,
    AtCount = lists:duplicate(?QUOD_MAX_FOREIGN_PAGE_ENTRIES, end_group),
    Page = fun(Parts) -> {history_page3, Grant, ReqId, Parts, 9, done, Next} end,
    ?assertMatch({ok, _, _}, quod_catchup:decode_frame(Ns, raw_frame(Ns, Page(AtCount)))),
    ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(
      Ns, raw_frame(Ns, Page([end_group | AtCount])))),
    {ok, EmptyPart} = quod_safe_term:encode_canonical({entry, <<>>}, 1024),
    Limit = ?QUOD_MAX_FOREIGN_PAGE_BYTES - byte_size(EmptyPart),
    AtBytes = [{entry, binary:copy(<<0>>, Limit)}],
    Frame = quod_catchup:encode_frame(Ns, Page(AtBytes)),
    ?assert(byte_size(Frame) < ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
    ?assertMatch({ok, _, _}, quod_catchup:decode_frame(Ns, Frame)),
    ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(
      Ns, raw_frame(Ns, Page([{entry, binary:copy(<<0>>, Limit + 1)}])))),
    ?assertEqual({error, frame_too_large}, quod_catchup:decode_frame(
      Ns, binary:copy(<<0>>, ?QUOD_TRANSPORT_MAX_FRAME_BYTES + 1))).

foreign_response_keeps_unknown_vocabulary_opaque_test() ->
    Ns = <<"catchup:opaque-response">>,
    Name = <<"quod_r3_catchup_", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    Symbol = {'$quod_symbol', Name},
    Transaction = #transaction{
      tx_id = <<12:256>>, origin = {Ns, <<0:256>>},
      diff = [{assert, {{Symbol, value}, {[], false}}}], read_check = #{},
      author = <<13:256>>, sig = none, signed_bytes = none},
    {ok, TransactionBytes} = quod_transaction:encode_ledger_transaction(Transaction),
    {ok, BlockBytes} = quod_safe_term:encode_canonical(
      {quod_block, 3, genesis, 0, none, 1, {batch, [{transaction, TransactionBytes}]}, 0}, 1024 * 1024),
    {ok, Entry} = quod_ledger:from_entry_view(
                   #entry{index = 1, data = {batch, [Transaction]}, timestamp = 0,
                          block_bytes = BlockBytes, cert = none}),
    {ok, Blob} = quod_ledger:encode_entry(Entry),
    Grant = <<1:128>>, ReqId = <<2:128>>, Next = <<3:128>>,
    Frame = quod_catchup:encode_frame(
      Ns, {history_page3, Grant, ReqId, [{entry, Blob}], 1, done, Next}),
    ?assertException(error, badarg, binary_to_existing_atom(Name, utf8)),
    {ok, {history_page3, Grant, ReqId, [{entry, Received}], 1, done, Next}, _} =
        quod_catchup:decode_frame(Ns, Frame),
    {ok, Decoded} = quod_ledger:decode_entry(Received, wrapped),
    ?assertMatch(#entry{data = {batch, [#transaction{
      diff = [{assert, {{Symbol, value}, {[], false}}}]}]}}, quod_ledger:entry_view(Decoded)),
    ?assertException(error, badarg, binary_to_existing_atom(Name, utf8)),
    ?assertEqual({error, bad_entry},
                 quod_ledger:decode_entry(<<Blob/binary, 0>>, wrapped)),
    <<131, EntryBody/binary>> = Blob,
    Compressed = <<131, 80, (byte_size(EntryBody)):32,
                   (zlib:compress(EntryBody))/binary>>,
    ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(Compressed, wrapped)).

%% These tests run the actual endpoint and its linked/monitored reader. The
%% link stub models only authenticated link callbacks, not grant validation.
era_server_continuation_retains_one_reader_and_rejects_stale_or_foreign_tokens_test() ->
    with_transfer_endpoint(fun(#{endpoint := Endpoint, source := Source}) ->
      with_link(fun(Link) -> with_link(fun(OtherLink) ->
        FirstOp = make_ref(), Started = quod_time:mono_ms(),
        Endpoint ! {catchup_request, Link, FirstOp, {range, 2, 2}, Started},
        {ok, [{group, 2, 2} | _], 2, {Token, 1}} = expect_complete(Link, Endpoint, FirstOp),
        #{worker := Worker, started_ms := Started} = maps:get(Token, readers(Endpoint)),
        ?assert(is_process_alive(Worker)),
        FirstAccepted = accept_reader_page(Link, Endpoint, FirstOp),
        ?assertMatch(#{operation := none, sequence := 1, worker := Worker},
                     maps:get(Token, maps:get(readers, FirstAccepted))),
        ForeignOp = make_ref(),
        Endpoint ! {catchup_request, OtherLink, ForeignOp, {continue, Token, 1}, quod_time:mono_ms()},
        ?assertEqual({error, not_ready}, expect_complete(OtherLink, Endpoint, ForeignOp)),
        _ = accept_reader_page(OtherLink, Endpoint, ForeignOp),
        StaleOp = make_ref(),
        Endpoint ! {catchup_request, Link, StaleOp, {continue, Token, 2}, quod_time:mono_ms()},
        ?assertEqual({error, not_ready}, expect_complete(Link, Endpoint, StaleOp)),
        _ = accept_reader_page(Link, Endpoint, StaleOp),
        ?assertMatch(#{worker := Worker, sequence := 1, started_ms := Started}, maps:get(Token, readers(Endpoint))),
        NextOp = make_ref(),
        Endpoint ! {catchup_request, Link, NextOp, {continue, Token, 1}, quod_time:mono_ms()},
        {ok, Parts, 2, done} = expect_complete(Link, Endpoint, NextOp),
        ?assertEqual(end_group, lists:last(Parts)),
        ?assertNot(is_process_alive(Worker)),
        ?assertMatch(#{worker := none, started_ms := Started}, maps:get(Token, readers(Endpoint))),
        Accepted = accept_reader_page(Link, Endpoint, NextOp),
        ?assertEqual(#{}, maps:get(readers, Accepted)),
        Ref = make_ref(), Source ! {capture_count, self(), Ref},
        receive {capture_count, Ref, Captures} -> ?assertEqual(1, Captures) end
      end) end)
    end).

era_server_idle_continuation_expires_at_its_original_deadline_test() ->
    with_transfer_endpoint(fun(#{endpoint := Endpoint}) ->
      with_link(fun(Link) ->
        Op = make_ref(),
        Endpoint ! {catchup_request, Link, Op, {range, 2, 2}, quod_time:mono_ms()},
        {ok, _, 2, {Token, 1}} = expect_complete(Link, Endpoint, Op),
        #{worker := Worker} = maps:get(Token, readers(Endpoint)),
        Monitor = monitor(process, Worker),
        _ = accept_reader_page(Link, Endpoint, Op),
        %% Deliver the real expiry event deterministically; no sleep or new
        %% per-page allowance is needed to discover an idle transfer's end.
        Endpoint ! {page_deadline, Token},
        receive {'DOWN', Monitor, process, Worker, killed} -> ok end,
        RetryOp = make_ref(),
        Endpoint ! {catchup_request, Link, RetryOp, {continue, Token, 1}, quod_time:mono_ms()},
        ?assertEqual({error, not_ready}, expect_complete(Link, Endpoint, RetryOp)),
        _ = accept_reader_page(Link, Endpoint, RetryOp),
        ?assertEqual(#{}, readers(Endpoint))
      end)
    end).

accept_reader_page(Link, Endpoint, Op) ->
    Link ! {accept_page_and_sync, Endpoint, Op, self()},
    receive {page_accepted, Op, Snapshot} -> Snapshot end.

era_client_keeps_page_custody_until_consumption_and_cancels_a_dead_consumer_test() ->
    with_transfer_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
      with_link(fun(Link) ->
        Parent = self(), Peer = <<99:256>>, Deadline = quod_time:mono_ms() + 8000,
        Client = spawn(fun() -> transfer_client(Parent, Ns, Peer, Deadline) end),
        try
            Client ! {consume, {range, 2, 2}},
            {OpenRef, Chan} = expect_open(Endpoint, Peer, ordinary),
            Endpoint ! {link_up, OpenRef, Peer, Chan, Link},
            Binding = expect_binding(Link, Endpoint),
            Grant = <<1:128>>, NextGrant = <<2:128>>, Token = <<3:128>>,
            Endpoint ! {catchup_credit, Link, Binding, Grant},
            Req = expect_transfer_request(Link, Endpoint, Binding, Grant, {range, 2, 2}),
            Endpoint ! {catchup_page, Link, Binding, Grant, Req,
                         {ok, [end_group], 2, {Token, 1}}, NextGrant},
            receive {consuming_page, Client, [end_group], 2, {Token, 1}} -> ok end,
            ?assertEqual(1, maps:get(client_pending, quod_catchup:stats(Ns))),
            ?assertMatch(#{active := Req}, maps:get(Binding, maps:get(bindings, recovery(Endpoint)))),
            %% A different caller cannot acknowledge someone else's decode.
            ?assertEqual({error, stale_page}, gen_server:call(Endpoint,
                {complete_pull_page, {Req, Link, Binding, Grant}, accepted})),
            Client ! finish_consume,
            ?assertEqual({ok, consumed, 2, {Token, 1}}, pull_result(Client)),
            ?assertEqual(0, maps:get(client_pending, quod_catchup:stats(Ns))),
            Client ! {consume, {continue, Token, 1}},
            Req2 = expect_transfer_request(Link, Endpoint, Binding, NextGrant, {continue, Token, 1}),
            Endpoint ! {catchup_page, Link, Binding, NextGrant, Req2,
                         {ok, [end_group], 2, done}, <<4:128>>},
            receive {consuming_page, Client, [end_group], 2, done} -> ok end,
            LinkMonitor = monitor(process, Link), ClientMonitor = monitor(process, Client),
            exit(Client, kill),
            receive {'DOWN', ClientMonitor, process, Client, killed} -> ok end,
            receive {'DOWN', LinkMonitor, process, Link, _} -> ok end,
            ?assertEqual(0, maps:get(client_pending, quod_catchup:stats(Ns))),
            ?assert(is_process_alive(Endpoint))
        after stop_process(Client) end
      end)
    end).

transfer_client(Parent, Ns, Peer, Deadline) ->
    receive
        {consume, Query} ->
            Result = quod_catchup:pull(Ns, Query, Peer, Deadline, fun(Parts, Height, More) ->
                Parent ! {consuming_page, self(), Parts, Height, More},
                receive finish_consume -> {ok, consumed} end
            end),
            Parent ! {pull_result, self(), Result},
            transfer_client(Parent, Ns, Peer, Deadline);
        stop -> ok
    end.

expect_transfer_request(Link, Endpoint, Binding, Grant, Query) ->
    receive {link_event, Link, {request_page, Endpoint, Binding, Grant, ReqId, Query}} -> ReqId
    after 2000 -> error(missing_transfer_request)
    end.

era_hosted_driver_transfers_pages_into_the_existing_recovery_sink_test() ->
    with_transfer_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        F = finality_fixture(), Parent = self(), Peer = <<91:256>>,
        Dir = filename:join("/tmp", "quod_transfer_target_" ++
                           binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        Target = spawn(fun() -> transfer_target_owner(F, Dir, Parent) end),
        receive {target_ready, Target, View} ->
            Path = quod_ledger_store:staging_path(maps:get(snapshot, View)),
            {Client, ClientMonitor} = spawn_monitor(fun() ->
                Fetch = fun(Query, Deadline, Consume) ->
                    quod_catchup:pull(Ns, Query, Peer, Deadline, Consume)
                end,
                Sink = fun(Group) -> gen_server:call(Target, {sink_transfer, Group}) end,
                Result = quod_catchup:catch_up(Ns, element(2, maps:get(identity, F)),
                    Fetch, Sink, 2, maps:get(projection, View),
                    #{history_view => View, stage_path => Path}),
                Parent ! {caught_up, self(), Result}
            end),
            Link = spawn(fun() -> transfer_link(Endpoint, Endpoint, Ns, none, <<1:128>>, none) end),
            try
                {OpenRef, Channel} = expect_open(Endpoint, Peer, ordinary),
                Endpoint ! {link_up, OpenRef, Peer, Channel, Link},
                receive {caught_up, Client, Result} -> ?assertEqual({ok, 2}, Result) end,
                receive {'DOWN', ClientMonitor, process, Client, normal} -> ok end,
                %% Two modeled nodes share this VM's registry; inspect the
                %% receiver fixture directly rather than pretending it owns
                %% the source's registered namespace capability.
                Installed = gen_server:call(Target, test_projection),
                ?assertMatch({2, _}, maps:get(history_head, Installed)),
                ?assertEqual({error, enoent}, file:read_file_info(Path)),
                ?assertMatch(#{client_pending := 0, server_inflight := 0}, quod_catchup:stats(Ns))
            after
                stop_process(Client), stop_process(Link), stop_process(Target),
                _ = file:delete(Path), file:del_dir_r(Dir)
            end
        end
    end).

era_foreign_owner_transfers_through_real_credit_and_server_test() ->
    with_transfer_endpoint(fun(#{endpoint := Server, ns := Ns, fixture := F, entry := Entry}) ->
        Identity = maps:get(identity, F), Tx = maps:get(transaction, F),
        Peer = maps:get(pubkey, maps:get(signer, F)), Addr = {"localhost", 1},
        {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Entry, Tx),
        Dir = filename:join("/tmp", "quod_foreign_wire_" ++
                           binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
        {ok, Owner} = quod_foreign_log:start_link(#{cache_dir => Dir, page_timeout_ms => 5000}),
        Link = spawn(fun() -> transfer_link(Server, Owner, Ns, none, <<1:128>>, none) end),
        Parent = self(),
        Client = spawn(fun() -> Parent ! {foreign_verified, self(),
            quod_foreign_log:verify(Peer, Addr, Ref, transaction, 5000)} end),
        try
            Chan = quod_catchup:channel(Ns),
            Lease = receive
                {transport_event, {open_link_pinned_lease, Peer, Addr, Chan, {Owner, L}}} -> L
            after 2000 -> error(foreign_did_not_open_pinned_link)
            end,
            Owner ! {link_up, Lease, Peer, Chan, Link},
            receive {foreign_verified, Client, Result} ->
                ?assertMatch({ok, #{transaction := Tx, slot := 2}}, Result)
            after 5000 -> error(foreign_did_not_verify_transfer)
            end,
            ?assertMatch(#{pulls := 0, pending := 0}, quod_foreign_log:stats()),
            ?assertMatch(#{server_inflight := 0}, quod_catchup:stats(Ns))
        after
            stop_process(Client), stop_process(Link),
            gen_server:stop(Owner), file:del_dir_r(Dir)
        end
    end).

%% Network delivery is held at the public pull endpoint. The actual feed
%% process, its acquisition worker, streamed verifier and Simplex state machine
%% run together; this is not a second implementation of their callbacks.
era_observer_worker_installs_shared_group_before_credit_ack_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = finality_fixture(),
    {Ns, Anchor} = Identity = maps:get(identity, F),
    Era = maps:get(era, F), Signer = maps:get(signer, F),
    Root = maps:get(root, F), Tx = maps:get(transaction, F),
    {ok, B1} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [Tx]}, 1),
    Unsigned = quod_transaction:bind_id(Identity, Tx#transaction{
        author_seq = 2, proof_id = <<31:256>>, submitted_at = 2,
        sig = none, signed_bytes = none, authentication = none}),
    {ok, Tx2} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, Unsigned, Signer),
    {ok, B2} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(B1), 3, {batch, [Tx2]}, 2),
    Cert = finality_cert(B2, F),
    [Live, Historical] = Entries = [quod_ledger:entry(2, B1, Cert), quod_ledger:entry(3, B2, Cert)],
    Parts = [{group, 2, 3}] ++
        [{entry, element(2, quod_ledger:encode_entry(E))} || E <- Entries] ++
        [{proof, quod_ledger:block_bytes(B)} || B <- [B2, B1]] ++ [end_group],
    Dir = filename:join("/tmp", "quod-observer-worker-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    Parent = self(),
    Table = ets:new(binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
                    [named_table, protected, set]),
    true = ets:insert(Table, {anchor, Anchor}),
    true = quod_reg:reg({quod_prolog, Ns}),
    Owner = proc_lib:spawn(fun() ->
        transfer_target_owner(F#{observer => true}, Dir, Parent, fun(State) ->
            true = quod_reg:reg({quod_simplex, Ns}),
            Parent ! {observer_started, self()},
            gen_statem:enter_loop(quod_simplex, [], running, State)
        end)
    end),
    Endpoint = spawn(fun() ->
        true = quod_reg:reg({quod_catchup, Ns}),
        Parent ! {page_endpoint_ready, self()},
        observer_page_endpoint(Parent, Parts)
    end),
    try
        View = receive {target_ready, Owner, Captured} -> Captured
               after 2000 -> error(observer_not_initialized) end,
        receive {observer_started, Owner} -> ok after 1000 -> error(observer_not_started) end,
        receive {page_endpoint_ready, Endpoint} -> ok after 1000 -> error(page_endpoint_not_started) end,
        {ok, Feed} = quod_feed:start_link(Ns, #{node_id => <<92:256>>}),
        unlink(Feed),
        1 = erlang:trace(Feed, true, ['receive', {tracer, self()}]),
        try
            _ = sys:replace_state(Feed, fun(State) ->
                quod_feed:test_set_snapshot({1, maps:get(projection, View), false}, State)
            end),
            Peer = maps:get(pubkey, Signer),
            Feed ! {quod_message, {{Peer, {"localhost", 1}}, self()},
                     quod_feed:channel(Ns), quod_feed:encode(Ns, {block, Live})},
            Worker = receive {observer_pull_waiting, Endpoint, W} -> W
                     after 2000 -> error(observer_did_not_pull) end,
            Monitor = erlang:monitor(process, Worker),
            ?assertEqual({{2, 2, Peer}, Worker}, quod_feed:test_received(sys:get_state(Feed))),
            {ok, #{slot := 1}} = quod_simplex:history_view(
                {Owner, Identity}, committed, quod_time:mono_ms() + 1000),
            Path = receive
                {trace, Feed, 'receive', {'$gen_call', {Worker, _}, {pull_stage, StagePath}}} -> StagePath
            after 1000 -> error(proof_stage_not_owned_by_feed) end,
            Endpoint ! release_page,
            receive {'$gen_cast', {apply_entry, _, replay}} -> ok
            after 1000 -> error(genesis_replay_missing) end,
            receive {'$gen_cast', {apply_entry, Live, live}} -> ok
            after 1000 -> error(live_origin_lost) end,
            receive {'$gen_cast', {apply_entry, Historical, replay}} -> ok
            after 1000 -> error(historical_origin_lost) end,
            receive {observer_credit_accepted, Endpoint} ->
                {ok, #{slot := 3}} = quod_simplex:history_view(
                    {Owner, Identity}, committed, quod_time:mono_ms() + 1000)
            after 1000 -> error(credit_not_completed) end,
            receive {'DOWN', Monitor, process, Worker, normal} -> ok
            after 1000 -> error(observer_worker_not_finished) end,
            %% The feed must process its own monitor notice before inspecting
            %% cleanup. Our separate monitor alone cannot establish that order.
            receive {trace, Feed, 'receive', {'DOWN', _, process, Worker, normal}} -> ok
            after 1000 -> error(feed_did_not_receive_worker_retirement) end,
            ?assertEqual({none, false}, quod_feed:test_received(sys:get_state(Feed))),
            ?assertMatch(#{ingested := 1, pulled := 1}, quod_feed:stats(Ns)),
            ?assertEqual({error, enoent}, file:read_file_info(Path))
        after
            _ = erlang:trace(Feed, false, ['receive']),
            gen_server:stop(Feed)
        end
    after
        stop_process(Endpoint), stop_process(Owner),
        gproc:unreg(quod_reg:name({quod_prolog, Ns})), ets:delete(Table), file:del_dir_r(Dir)
    end.

%% Start an actual empty joiner. Its ordinary recovery worker must install
%% genesis before a committee-key tip response can establish synchronization.
era_cold_join_installs_genesis_through_owned_recovery_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = finality_fixture(), {Ns, Anchor} = Identity = maps:get(identity, F),
    Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
    {ok, Bytes} = quod_ledger:encode_entry(Genesis),
    Parts = [{group, 1, 1}, {entry, Bytes}, end_group],
    Peer = maps:get(pubkey, maps:get(signer, F)), Parent = self(),
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Dir = filename:join("/tmp", "quod-join-download-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    Endpoint = spawn(fun() ->
        true = quod_reg:reg({quod_catchup, Ns}),
        Parent ! {bootstrap_endpoint_ready, self()},
        bootstrap_page_endpoint(Parent, Peer, Parts)
    end),
    Trap = process_flag(trap_exit, true),
    try
        receive {bootstrap_endpoint_ready, Endpoint} -> ok
        after 1000 -> error(bootstrap_endpoint_not_ready) end,
        {ok, Owner} = quod_simplex:start_link(Ns,
            #{mode => join, genesis_hash => Anchor, node_id => Pub,
              identity => Signer, data_dir => Dir}),
        unlink(Owner), OwnerMonitor = erlang:monitor(process, Owner),
        try
            Worker = receive {bootstrap_download_waiting, Endpoint, Pid} -> Pid
                     after 2000 -> error(cold_join_did_not_request_genesis) end,
            WorkerMonitor = erlang:monitor(process, Worker),
            {ok, #{slot := 0}} = quod_simplex:history_view(
                {Owner, Identity}, committed, quod_time:mono_ms() + 1000),
            1 = erlang:trace(Owner, true, ['receive', {tracer, self()}]),
            Endpoint ! release_genesis,
            receive
                {bootstrap_page_consumed, Endpoint, accepted} -> ok;
                {'DOWN', OwnerMonitor, process, Owner, Why} -> error({cold_genesis_install_failed, Why})
            after 2000 -> error(cold_genesis_not_installed) end,
            receive
                {trace, Owner, 'receive', {'$gen_cast', {sync_done, Worker, {ready, 1}}}} -> ok
            after 2000 -> error(cold_join_not_confirmed) end,
            ?assertMatch(#{committed := 1, pipeline_gap := 0, committee_size := 1,
                           prolog_ready := false}, quod_simplex:stats(Ns)),
            {ok, #{slot := 1, projection := Projection}} = quod_simplex:history_view(
                {Owner, Identity}, committed, quod_time:mono_ms() + 1000),
            ?assertEqual({1, Anchor}, maps:get(history_head, Projection)),
            ?assertMatch({error, _}, quod_simplex:await_proof_access(
                Ns, quod_time:mono_ms() + 1000, #{})),
            receive {'DOWN', WorkerMonitor, process, Worker, normal} -> ok
            after 1000 -> error(cold_recovery_worker_not_retired) end
        after
            erlang:demonitor(OwnerMonitor, [flush]),
            case is_process_alive(Owner) of true -> gen_statem:stop(Owner); false -> ok end,
            receive {'EXIT', Owner, _} -> ok after 0 -> ok end
        end
    after
        process_flag(trap_exit, Trap), stop_process(Endpoint), file:del_dir_r(Dir)
    end.

bootstrap_page_endpoint(Parent, Peer, Parts) ->
    receive
        {'$gen_call', From, contact} ->
            gen:reply(From, Peer), bootstrap_page_endpoint(Parent, Peer, Parts);
        {'$gen_call', From = {Worker, _}, {pull, {range, First, _}, Peer, _, _}} ->
            Page = case First of
                1 ->
                    Parent ! {bootstrap_download_waiting, self(), Worker},
                    receive release_genesis -> ok end,
                    Parts;
                2 -> []
            end,
            Key = make_ref(),
            gen:reply(From, {consume_page, Key, Page, 1, done}),
            receive {'$gen_call', Completed, {complete_pull_page, Key, Verdict}} ->
                case First of 1 -> Parent ! {bootstrap_page_consumed, self(), Verdict}; _ -> ok end,
                gen:reply(Completed, ok)
            end,
            bootstrap_page_endpoint(Parent, Peer, Parts);
        stop -> ok
    end.

observer_page_endpoint(Parent, Parts) ->
    receive
        {'$gen_call', From = {Worker, _}, {pull, {range, 2, _}, _, _, _}} ->
            Parent ! {observer_pull_waiting, self(), Worker},
            receive release_page -> ok end,
            Key = make_ref(),
            gen:reply(From, {consume_page, Key, Parts, 3, done}),
            receive
                {'$gen_call', Completed, {complete_pull_page, Key, accepted}} ->
                    Parent ! {observer_credit_accepted, self()},
                    gen:reply(Completed, ok)
            end,
            receive stop -> ok end
    end.

transfer_target_owner(F, Dir, Parent) ->
    transfer_target_owner(F, Dir, Parent, fun source_loop/1).

transfer_target_owner(F, Dir, Parent, Run) ->
    {Ns, Anchor} = Binding = maps:get(identity, F), Signer = maps:get(signer, F),
    {ok, I} = quod_dtx_phase_index:open(Dir, Ns),
    {ok, S0} = quod_ledger_store:open(Ns, Dir),
    Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
    {ok, Store} = quod_ledger_store:append(S0, {none, [Genesis]}),
    try
        {ok, Projection, Delta, genesis} = quod_catchup:verify_forward_group(Binding,
            [Genesis], quod_simplex:history_projection(Binding), I, {fun(_) -> done end, none}),
        ok = quod_dtx_phase_index:commit_delta(I, Delta),
        Domain = quod_simplex:consensus_domain(Ns, Anchor), Root = maps:get(root, F),
        Engine = quod_simplex:eng_new(Domain, [maps:get(pubkey, Signer)], {Root, 1, 0}),
        State = quod_simplex:test_install_projection(Projection,
            quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor, consensus_domain => Domain,
              self => case maps:get(observer, F, false) of true -> <<92:256>>;
                         false -> maps:get(pubkey, Signer) end,
              sync => ready, store => Store, slot => 1, eng => Engine,
              archive_tip => {Root, 0}, phase_index => I, signing_journal => memory})),
        {ok, View} = quod_simplex:test_local_history_view(Binding, committed, State),
        Parent ! {target_ready, self(), View},
        Run(State)
    after quod_dtx_phase_index:close(I), quod_ledger_store:close(Store) end.

%% This adapter replaces QUIC only. Both endpoint lifecycles, canonical wire
%% grammars, finality verification and the real recovery sink execute normally.
transfer_link(Endpoint, Client, Ns, Binding, Grant, Pending) ->
    receive
        {bind_catchup, Client, Ref} ->
            Client ! {catchup_credit, self(), Ref, Grant},
            transfer_link(Endpoint, Client, Ns, Ref, Grant, Pending);
        {request_page, Client, Binding, Grant, Request, Query} when Pending =:= none ->
            Frame = quod_catchup:encode_frame(Ns, {history_request3, Grant, Request, Query}),
            {ok, {history_request3, Grant, Request, Decoded}, _} = quod_catchup:decode_frame(Ns, Frame),
            Op = make_ref(),
            Endpoint ! {catchup_request, self(), Op, Decoded, quod_time:mono_ms()},
            transfer_link(Endpoint, Client, Ns, Binding, Grant, {Op, Request});
        {complete_page, Endpoint, Op, {ok, Parts, Height, More}} when element(1, Pending) =:= Op ->
            {Op, Request} = Pending, Next = crypto:strong_rand_bytes(16),
            Frame = quod_catchup:encode_frame(Ns, {history_page3, Grant, Request, Parts, Height, More, Next}),
            {ok, {history_page3, Grant, Request, Payload, Height, More, Next}, _} =
                quod_catchup:decode_frame(Ns, Frame),
            Endpoint ! {catchup_page_sent, self(), Op},
            Client ! {catchup_page, self(), Binding, Grant, Request,
                         {ok, Payload, Height, More}, Next},
            transfer_link(Endpoint, Client, Ns, Binding, Next, none);
        close -> ok;
        stop -> ok
    end.

same_link_response_waits_for_reader_down_and_send_acceptance_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        with_link(fun(Link) ->
            {Op, Token, Worker} = held_reader(Endpoint, Link, after_result),
            Rows = readers(Endpoint),
            ?assertMatch(#{worker := Worker, result := {ok, _, 5, done}}, maps:get(Token, Rows)),
            assert_no_complete(Link),
            ?assert(is_process_alive(Worker)),
            Worker ! {release_reader, Token},
            {ok, Parts, 5, done} = expect_complete(Link, Endpoint, Op),
            ?assertEqual([2,3], [quod_ledger:entry_index(E) || {entry, B} <- Parts,
                                   {ok, E} <- [quod_ledger:decode_entry(B)]]),
            ?assertNot(is_process_alive(Worker)),
            ?assertMatch(#{worker := none}, reader_for_operation(Endpoint, Op)),
            ?assertEqual(1, maps:get(server_inflight, quod_catchup:stats(Ns))),
            Link ! {accept_page, Endpoint, Op},
            await_readers(Endpoint, 0),
            ?assertEqual(1, maps:get(server_inflight_peak, quod_catchup:stats(Ns)))
        end)
    end).

expired_link_admission_does_not_start_a_reader_test() ->
    with_endpoint(fun(#{endpoint := Endpoint}) ->
        with_link(fun(Link) ->
            ok = quod_catchup:test_hold_next_reader(Endpoint, before_read, self()),
            Op = make_ref(),
            %% The timestamp belongs to link grant admission, not the later
            %% endpoint mailbox turn. An already-spent budget opens no view.
            Endpoint ! {catchup_request, Link, Op, {range, 2, 3}, quod_time:mono_ms() - 8001},
            ?assertEqual({error, not_ready}, expect_complete(Link, Endpoint, Op)),
            ?assertMatch(#{worker := none}, reader_for_operation(Endpoint, Op)),
            receive {reader_held, _, Op, _} -> error(expired_admission_started_reader)
            after 0 -> ok
            end,
            Link ! {accept_page, Endpoint, Op},
            await_readers(Endpoint, 0)
        end)
    end).

source_death_after_result_cannot_publish_captured_page_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, source := Source}) ->
        with_link(fun(Link) ->
            {Op, _Token, Worker} = held_reader(Endpoint, Link, after_result),
            ?assertMatch(#{result := {ok, _, _, _}}, reader_for_operation(Endpoint, Op)),
            Monitor = monitor(process, Worker),
            exit(Source, kill),
            await_down(Worker, Monitor),
            ?assertEqual({error, not_ready}, expect_complete(Link, Endpoint, Op)),
            Link ! {accept_page, Endpoint, Op},
            await_readers(Endpoint, 0)
        end)
    end).

link_death_releases_held_reader_test() ->
    with_endpoint(fun(#{endpoint := Endpoint}) ->
        with_link(fun(Link) ->
            {_Op, _Token, Worker} = held_reader(Endpoint, Link, before_read),
            Monitor = monitor(process, Worker),
            exit(Link, kill),
            await_down(Worker, Monitor),
            await_readers(Endpoint, 0),
            assert_no_complete(Link)
        end)
    end).

endpoint_kill_releases_held_reader_test() ->
    with_endpoint(fun(#{endpoint := Endpoint}) ->
        with_link(fun(Link) ->
            {_Op, _Token, Worker} = held_reader(Endpoint, Link, before_read),
            Monitor = monitor(process, Worker),
            exit(Endpoint, kill),
            await_down(Worker, Monitor),
            assert_no_complete(Link)
        end)
    end).

more_than_32_links_retain_and_retire_all_readers_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, source := Source, ns := Ns}) ->
        Links = [start_link_stub() || _ <- lists:seq(1, 40)],
        try
            Source ! {pause_captures, self()},
            receive {source_paused, Source} -> ok after 1000 -> error(source_not_paused) end,
            Pages = [{Link, make_ref()} || Link <- Links],
            lists:foreach(fun({Link, Op}) ->
                Endpoint ! {catchup_request, Link, Op, {range, 2, 3}, quod_time:mono_ms()}
            end, Pages),
            %% The source is genuinely busy: all forty readers have issued
            %% their owner capture, not merely been put behind a test gate.
            await(fun() ->
                {messages, Messages} = process_info(Source, messages),
                length([ok || {'$gen_call', _, {history_view, _, _, _}} <- Messages]) =:= 40
            end),
            ?assertEqual(40, map_size(readers(Endpoint))),
            ?assertEqual(40, maps:get(server_inflight_peak, quod_catchup:stats(Ns))),
            lists:foreach(fun({Link, _}) -> assert_no_complete(Link) end, Pages),
            Source ! resume_captures,
            lists:foreach(fun({Link, Op}) ->
                ?assertMatch({ok, [_ | _], 5, done}, expect_complete(Link, Endpoint, Op)),
                Link ! {accept_page, Endpoint, Op}
            end, Pages),
            await_readers(Endpoint, 0)
        after lists:foreach(fun stop_process/1, Links)
        end
    end).

queued_pulls_share_one_identified_link_and_grants_fifo_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        with_link(fun(Link) ->
            Contact = {"127.0.0.1", 14570}, Peer = <<10:256>>,
            quod_quic:ensure_cache(),
            _ = ets:delete(quod_addr_cache, Peer),
            try
                First = start_pull(Ns, 1, 1, Contact),
                {OpenRef, Chan} = expect_open(Endpoint, Contact, identified),
                Second = start_pull(Ns, 2, 2, Contact),
                await_pending(Ns, 2),
                ?assertEqual(1, map_size(maps:get(openings, recovery(Endpoint)))),
                assert_no_open(Endpoint),
                Endpoint ! {link_up, OpenRef, Peer, Chan, Link},
                Binding = expect_binding(Link, Endpoint),
                ?assertEqual({ok, Contact}, quod_quic:resolve(Peer)),
                assert_no_request(Link),
                Grant1 = <<1:128>>, Grant2 = <<2:128>>, Grant3 = <<3:128>>,
                Endpoint ! {catchup_credit, Link, Binding, Grant1},
                Req1 = expect_request(Link, Endpoint, Binding, Grant1, 1, 1),
                assert_no_request(Link),
                %% Wrong correlation cannot complete the first pull or dispatch the second.
                Endpoint ! {catchup_page, Link, Binding, <<99:128>>, Req1,
                            {error, server_error}, Grant2},
                ?assertEqual(2, maps:get(client_pending, quod_catchup:stats(Ns))),
                assert_no_request(Link),
                Endpoint ! {catchup_page, Link, Binding, Grant1, Req1,
                            {ok, [], 5, done}, Grant2},
                ?assertEqual({ok, [], 5, done}, pull_result(First)),
                Req2 = expect_request(Link, Endpoint, Binding, Grant2, 2, 2),
                ?assertNotEqual(Req1, Req2),
                assert_no_open(Endpoint),
                Endpoint ! {catchup_page, Link, Binding, Grant2, Req2,
                            {error, server_error}, Grant3},
                ?assertEqual({error, server_error}, pull_result(Second)),
                await_pending(Ns, 0)
            after _ = ets:delete(quod_addr_cache, Peer)
            end
        end)
    end).

expired_queued_pull_creates_no_borrower_or_open_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        Contact = <<17:256>>,
        Parent = self(),
        ok = sys:suspend(Endpoint),
        Caller = spawn(fun() ->
            Result = gen_server:call(
                       Endpoint, {pull, {range, 1, 2}, Contact, quod_time:mono_ms() - 8001, quod_time:mono_ms() - 1}, 2000),
            Parent ! {pull_result, self(), Result},
            receive stop -> ok end
        end),
        try
            await_queued_pull(Endpoint, Caller),
            ok = sys:resume(Endpoint),
            ?assertEqual({error, timeout}, pull_result(Caller)),
            ?assert(is_process_alive(Caller)),
            assert_no_pull_admission(Endpoint, Ns)
        after
            _ = catch sys:resume(Endpoint),
            stop_process(Caller)
        end
    end).

dead_queued_pull_caller_creates_no_borrower_or_open_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        ok = sys:suspend(Endpoint),
        Caller = start_pull(Ns, 1, 2, <<18:256>>),
        try
            %% Exercise public pull/5: its real call and absolute deadline
            %% is already queued before the original caller disappears.
            await_queued_pull(Endpoint, Caller),
            Monitor = monitor(process, Caller),
            exit(Caller, kill),
            await_down(Caller, Monitor),
            ok = sys:resume(Endpoint),
            assert_no_pull_admission(Endpoint, Ns)
        after
            _ = catch sys:resume(Endpoint),
            stop_process(Caller)
        end
    end).

retired_open_failure_does_not_strand_the_surviving_borrower_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        with_link(fun(Link) ->
            Contact = <<19:256>>,
            First = start_pull(Ns, 1, 1, Contact),
            {OldOpen, Chan} = expect_open(Endpoint, Contact, ordinary),
            Monitor = monitor(process, First),
            exit(First, kill),
            await_down(First, Monitor),
            await(fun() ->
                Bindings = maps:get(bindings, recovery(Endpoint)),
                lists:any(fun(#{retiring := Retiring, borrowers := Borrowers}) ->
                                  Retiring andalso Borrowers =:= 0
                          end, maps:values(Bindings))
            end),
            Parent = self(),
            Survivor = spawn(fun() -> recovery_client(Parent, Ns, Contact) end),
            try
                Survivor ! {pull, 2, 2},
                await_pending(Ns, 1),
                ?assert(maps:is_key(OldOpen, maps:get(openings, recovery(Endpoint)))),
                assert_no_open(Endpoint),
                Endpoint ! {link_error, OldOpen, Contact, Chan},
                %% Preserve the existing failed-open result. A subsequent
                %% explicit request, not an automatic retry, owns the next turn.
                ?assertEqual({error, link_down}, pull_result(Survivor)),
                ?assert(is_process_alive(Survivor)),
                Survivor ! {pull, 3, 3},
                {NewOpen, Chan} = expect_open(Endpoint, Contact, ordinary),
                ?assertNotEqual(OldOpen, NewOpen),
                Endpoint ! {link_up, NewOpen, Contact, Chan, Link},
                Binding = expect_binding(Link, Endpoint),
                Grant = <<21:128>>, Next = <<22:128>>,
                Endpoint ! {catchup_credit, Link, Binding, Grant},
                Req = expect_request(Link, Endpoint, Binding, Grant, 3, 3),
                Endpoint ! {catchup_page, Link, Binding, Grant, Req, {ok, [], 5, done}, Next},
                ?assertEqual({ok, [], 5, done}, pull_result(Survivor)),
                await_pending(Ns, 0)
            after stop_process(Survivor)
            end
        end)
    end).

recovery_caller_retains_one_link_between_pages_until_it_exits_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        with_link(fun(Link) ->
            Peer = <<14:256>>,
            Parent = self(),
            Client = spawn(fun() -> recovery_client(Parent, Ns, Peer) end),
            try
                Client ! {pull, 1, 1},
                {OpenRef, Chan} = expect_open(Endpoint, Peer, ordinary),
                Endpoint ! {link_up, OpenRef, Peer, Chan, Link},
                Binding = expect_binding(Link, Endpoint),
                Grant1 = <<1:128>>, Grant2 = <<2:128>>, Grant3 = <<3:128>>,
                Endpoint ! {catchup_credit, Link, Binding, Grant1},
                Req1 = expect_request(Link, Endpoint, Binding, Grant1, 1, 1),
                Endpoint ! {catchup_page, Link, Binding, Grant1, Req1, {ok, [], 5, done}, Grant2},
                ?assertEqual({ok, [], 5, done}, pull_result(Client)),
                await_pending(Ns, 0),
                ?assert(is_process_alive(Link)),
                Client ! {pull, 2, 2},
                Req2 = expect_request(Link, Endpoint, Binding, Grant2, 2, 2),
                assert_no_open(Endpoint),
                Endpoint ! {catchup_page, Link, Binding, Grant2, Req2, {ok, [], 5, done}, Grant3},
                ?assertEqual({ok, [], 5, done}, pull_result(Client)),
                LinkMonitor = monitor(process, Link),
                stop_process(Client),
                await_down(Link, LinkMonitor)
            after stop_process(Client)
            end
        end)
    end).

ordinary_keyed_pull_uses_the_ordinary_pool_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        Peer = <<15:256>>,
        Pull = start_pull(Ns, 1, 2, Peer),
        {OpenRef, Chan} = expect_open(Endpoint, Peer, ordinary),
        Endpoint ! {link_error, OpenRef, Peer, Chan},
        ?assertMatch({error, _}, pull_result(Pull)),
        await_pending(Ns, 0)
    end).

failed_identified_open_cannot_bind_a_late_link_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        with_link(fun(Link) ->
            Contact = {"127.0.0.1", 14571},
            Pull = start_pull(Ns, 1, 2, Contact),
            {OpenRef, Chan} = expect_open(Endpoint, Contact, identified),
            Endpoint ! {link_error, OpenRef, Contact, Chan},
            ?assertMatch({error, _}, pull_result(Pull)),
            Endpoint ! {link_up, OpenRef, <<11:256>>, Chan, Link},
            ?assertEqual(#{}, maps:get(openings, recovery(Endpoint))),
            receive {link_event, Link, {bind_catchup, _, _}} -> error(late_link_bound)
            after 30 -> ok
            end,
            assert_no_request(Link)
        end)
    end).

raw_frame(Ns, Term) ->
    term_to_binary({catchup, 3, Ns, term_to_binary(Term, [deterministic])}, [deterministic]).

with_endpoint(Fun) ->
    Fixture = {Dir, Ns, Anchor, _Cert, _Snapshot} = setup(),
    try with_endpoint_source(Dir, Ns, Anchor, 5, Fun)
    after cleanup(Fixture) end.

with_transfer_endpoint(Fun) ->
    F = finality_fixture(), {Ns, Anchor} = maps:get(identity, F), Era = maps:get(era, F),
    {ok, B} = quod_ledger:new_block({Era, 1}, maps:get(root, F), 2, {batch, [maps:get(transaction, F)]}, 1),
    {Proof, _} = lists:foldl(fun(V, {Acc, Parent}) ->
        {ok, C} = quod_ledger:new_block({Era, V}, Parent, 2, empty, 1),
        {[C | Acc], quod_ledger:block_ref(C)}
    end, {[B], quod_ledger:block_ref(B)}, lists:seq(2, 301)),
    Entry = quod_ledger:entry(2, B, finality_cert(hd(Proof), F)),
    Bodies = [quod_ledger:block_bytes(Block) || Block <- Proof],
    Source = {lists:sum([quod_ledger_store:proof_frame_size(Bytes) || Bytes <- Bodies]),
              fun([]) -> done; ([Bytes | Rest]) -> {Bytes, Rest} end, Bodies},
    Dir = filename:join("/tmp", "quod_transfer_endpoint_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    try
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0,
            {none, [quod_ledger:entry(1, maps:get(genesis, F), none)]}),
        {ok, S2} = quod_ledger_store:append(S1, {Source, [Entry]}),
        ok = quod_ledger_store:close(S2),
        with_endpoint_source(Dir, Ns, Anchor, 2,
          fun(C) -> Fun(C#{fixture => F, entry => Entry}) end)
    after file:del_dir_r(Dir) end.

with_endpoint_source(Dir, Ns, Anchor, Height, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Parent = self(),
    Source = spawn(fun() ->
        {ok, Store} = quod_ledger_store:open(Ns, Dir),
        {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
        try
            Binding = {Ns, Anchor},
            Projection = quod_ledger_store:fold_groups(Store, fun(Entries, Proof, P) ->
                Reader = {fun(C) -> quod_ledger_store:proof_next(Store, C) end, Proof},
                {ok, Next, Delta, _} = quod_catchup:verify_forward_group(Binding, Entries, P, Index, Reader),
                ok = quod_dtx_phase_index:commit_delta(Index, Delta),
                Next
            end, quod_simplex:history_projection(Binding)),
            true = quod_reg:reg({quod_simplex, Ns}),
            State = quod_simplex:test_install_projection(Projection, quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
              store => Store, slot => Height, last_applied => 0, sync => ready,
              phase_index => Index, prolog_ready => false})),
            Parent ! {source_ready, self()},
            source_loop(State)
        after quod_ledger_store:close(Store), quod_dtx_phase_index:close(Index)
        end
    end),
    try
        receive {source_ready, Source} -> ok after 2000 -> error(source_not_ready) end,
        Transport = spawn(fun() ->
            true = quod_reg:reg({transport, node}),
            Parent ! {transport_ready, self()},
            transport_loop(Parent)
        end),
        try
            receive {transport_ready, Transport} -> ok after 2000 -> error(transport_not_ready) end,
            {ok, Endpoint} = quod_catchup:start_link(
                               Ns, #{node_id => <<0:256>>, seed_peers => []}),
            unlink(Endpoint),
            try Fun(#{endpoint => Endpoint, source => Source, ns => Ns})
            after stop_endpoint(Endpoint)
            end
        after stop_process(Transport)
        end
    after
        stop_process(Source)
    end.

source_loop(State) -> source_loop(State, 0).
source_loop(State, Captures) ->
    receive
        {'$gen_call', From, test_projection} ->
            gen:reply(From, quod_simplex:test_state_projection(State)),
            source_loop(State, Captures);
        {pause_captures, Caller} ->
            Caller ! {source_paused, self()},
            receive resume_captures -> source_loop(State, Captures) end;
        {'$gen_call', From, {history_view, Identity, Requirement, Deadline}} ->
            gen:reply(From, quod_simplex:test_local_history_view(
                             Identity, Requirement, Deadline, State)),
            source_loop(State, Captures + 1);
        {'$gen_call', From, {sink_transfer, Group}} ->
            {Next, ok} = quod_simplex:test_apply_catchup_window({recovery, self()}, Group, State),
            Projection = quod_simplex:test_state_projection(Next),
            Identity = maps:get(identity, Projection),
            gen:reply(From, quod_simplex:test_local_history_view(Identity, committed, Next)),
            source_loop(Next, Captures);
        {capture_count, Caller, Ref} ->
            Caller ! {capture_count, Ref, Captures}, source_loop(State, Captures);
        stop -> ok
    end.

transport_loop(Parent) ->
    receive
        {'$gen_cast', Request} -> Parent ! {transport_event, Request}, transport_loop(Parent);
        stop -> ok
    end.

start_link_stub() ->
    Parent = self(),
    spawn(fun() -> link_loop(Parent) end).
with_link(Fun) ->
    Link = start_link_stub(),
    try Fun(Link) after stop_process(Link) end.
link_loop(Parent) ->
    receive
        {accept_page_and_sync, Endpoint, Op, Caller} ->
            Endpoint ! {catchup_page_sent, self(), Op},
            Snapshot = quod_catchup:test_recovery_state(Endpoint),
            Caller ! {page_accepted, Op, Snapshot},
            link_loop(Parent);
        {accept_page, Endpoint, Op} ->
            Endpoint ! {catchup_page_sent, self(), Op},
            link_loop(Parent);
        {sync, Caller, Ref} ->
            Caller ! {link_synced, self(), Ref},
            link_loop(Parent);
        stop -> ok;
        close -> ok;
        Message -> Parent ! {link_event, self(), Message}, link_loop(Parent)
    end.

held_reader(Endpoint, Link, Point) ->
    ok = quod_catchup:test_hold_next_reader(Endpoint, Point, self()),
    Op = make_ref(),
    Endpoint ! {catchup_request, Link, Op, {range, 2, 3}, quod_time:mono_ms()},
    receive {reader_held, Worker, Token, Point} ->
        await(fun() ->
            case maps:find(Token, readers(Endpoint)) of
                {ok, #{result := Result}} -> Point =:= before_read orelse Result =/= none;
                error -> false
            end
        end),
        {Op, Token, Worker}
    after 2000 -> error(reader_not_held)
    end.

expect_complete(Link, Endpoint, Op) ->
    receive {link_event, Link, {complete_page, Endpoint, Op, Result}} -> Result
    after 2000 -> error({missing_page_completion, Op})
    end.
assert_no_complete(Link) ->
    receive {link_event, Link, {complete_page, _, _, _}} -> error(response_before_reader_down)
    after 0 -> ok
    end.

recovery(Endpoint) -> quod_catchup:test_recovery_state(Endpoint).
readers(Endpoint) -> maps:get(readers, recovery(Endpoint)).
await_queued_pull(Endpoint, Caller) ->
    await(fun() ->
        {messages, Messages} = process_info(Endpoint, messages),
        lists:any(fun({'$gen_call', {Pid, _}, {pull, _, _, Started, _Deadline}}) ->
                          Pid =:= Caller andalso is_integer(Started);
                     (_) -> false
                  end, Messages)
    end).
assert_no_pull_admission(Endpoint, Ns) ->
    State = recovery(Endpoint),
    ?assertEqual(#{}, maps:get(contacts, State)),
    ?assertEqual(#{}, maps:get(openings, State)),
    ?assertEqual(#{}, maps:get(bindings, State)),
    ?assertEqual(0, maps:get(client_pending, quod_catchup:stats(Ns))),
    ?assertEqual(0, maps:get(client_pending_peak, quod_catchup:stats(Ns))),
    receive {transport_event, {_, _, _, {Endpoint, _}} = Event} ->
        error({unadmitted_pull_opened_transport, Event});
        {transport_event, {_, _, _, _, {Endpoint, _}} = Event} ->
        error({unadmitted_pull_opened_transport, Event})
    after 30 -> ok
    end.
await_readers(Endpoint, Count) ->
    await(fun() -> map_size(readers(Endpoint)) =:= Count end).
await_pending(Ns, Count) ->
    await(fun() -> maps:get(client_pending, quod_catchup:stats(Ns)) =:= Count end).
await(Check) -> await(Check, quod_time:mono_ms() + 2000).
await(Check, Deadline) ->
    case Check() of
        true -> ok;
        false ->
            case quod_time:mono_ms() < Deadline of
                true -> receive after 1 -> await(Check, Deadline) end;
                false -> error(state_did_not_converge)
            end
    end.

start_pull(Ns, From, To, Contact) ->
    Parent = self(),
    spawn(fun() -> Parent ! {pull_result, self(), quod_catchup:pull(Ns, {range, From, To}, Contact, quod_time:mono_ms() + 8000,
            fun(Parts, _Height, _More) -> {ok, Parts} end)} end).
recovery_client(Parent, Ns, Contact) ->
    receive
        {pull, From, To} ->
            Parent ! {pull_result, self(), quod_catchup:pull(Ns, {range, From, To}, Contact, quod_time:mono_ms() + 8000,
            fun(Parts, _Height, _More) -> {ok, Parts} end)},
            recovery_client(Parent, Ns, Contact);
        stop -> ok
    end.
pull_result(Pid) ->
    receive {pull_result, Pid, Result} -> Result
    after 2000 -> error(pull_did_not_complete)
    end.
expect_open(Endpoint, Contact, Pool) ->
    Kind = case Pool of identified -> open_link_identified; ordinary -> open_link end,
    receive {transport_event, {Kind, Contact, Chan, {Endpoint, OpenRef}}} ->
        {OpenRef, Chan}
    after 2000 -> error({missing_transport_open, Pool})
    end.
assert_no_open(Endpoint) ->
    receive {transport_event, {Kind, _, _, {Endpoint, _}} = Event}
      when Kind =:= open_link; Kind =:= open_link_identified ->
        error({extra_transport_request, Event})
    after 0 -> ok
    end.
expect_binding(Link, Endpoint) ->
    receive {link_event, Link, {bind_catchup, Endpoint, Binding}} -> Binding
    after 2000 -> error(link_not_bound)
    end.
expect_request(Link, Endpoint, Binding, Grant, From, To) ->
    receive {link_event, Link, {request_page, Endpoint, Binding, Grant, ReqId, {range, From, To}}} -> ReqId
    after 2000 -> error(missing_fifo_page_request)
    end.
assert_no_request(Link) ->
    receive {link_event, Link, {request_page, _, _, _, _, _}} -> error(uncredited_page)
    after 0 -> ok
    end.

stop_endpoint(Pid) ->
    case is_process_alive(Pid) of
        true -> _ = catch gen_server:stop(Pid, normal, 2000);
        false -> ok
    end.
stop_process(Pid) ->
    Monitor = monitor(process, Pid),
    Pid ! stop,
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> exit(Pid, kill), await_down(Pid, Monitor)
    end.
await_down(Pid, Monitor) ->
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 2000 -> error({process_did_not_stop, Pid})
    end.

%% Cold recovery begins with endpoint seeds, not pubkey resolver hints. Candidate discovery must keep the
%% endpoint form (so a direct authenticated pull can teach the hint), exclude self, deduplicate, and cap.
contact_candidates_test() ->
    Ns = <<"catchup:no-process">>,
    Self = {"127.0.0.1", 14567},
    A = {"10.0.0.1", 1001}, B = {"10.0.0.2", 1002},
    application:set_env(quod, node_addr, Self),
    try
        Candidates = quod_catchup:contact_candidates(Ns, [Self, A, A, B], 8),
        ?assertEqual(lists:sort([A, B]), lists:sort(Candidates)),
        ?assertEqual(1, length(quod_catchup:contact_candidates(Ns, [A, B], 1)))
    after
        application:unset_env(quod, node_addr)
    end.

reader_for_operation(Endpoint, Op) ->
    [Row] = [R || R = #{operation := Operation} <- maps:values(readers(Endpoint)), Operation =:= Op],
    Row.
