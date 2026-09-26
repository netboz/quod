-module(quod_catchup_verify_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").

%% Counted suffix-only control: real signed entries and retained writer index,
%% NOT a live consensus-admitted multiwrite campaign. The unchanged-source
%% baseline and its original probe are frozen separately in the handoff.
-export([history_suffix_work_probe/0]).

-define(NS, <<"ns">>).
-define(GENESIS_NONCE, <<16#5c:256>>).

%%%===================================================================
%%% The shared proof-group verifier checks a pulled material chain by
%%% INDUCTION from the pinned genesis committee, verifying each entry's finalizing cert against the
%%% namespace/genesis domain and committee AS-OF-that-slot (folded forward from peer_admitted facts).
%%%===================================================================

%%%--- helpers: build a real signed chain ---
%% Every content transaction is authored by a deterministic first committee
%% member, while the remaining members stay fresh per test.
author() -> crypto:generate_key(eddsa, ed25519, <<16#5a:256>>).
committee(N) -> [author() | [quod_identity:generate() || _ <- lists:seq(2, N)]].
pubs(C)      -> lists:usort([P || {P, _} <- C]).
signer({P, Seed}) -> #{pubkey => P, key => quod_identity:key_term({P, Seed})}.

sign_tx(Transaction, GenesisCommittee) ->
    Target = {?NS, genesis_hash(GenesisCommittee)},
    Bound = quod_transaction:bind_id(Target, Transaction),
    Projection = projection_after_genesis(GenesisCommittee),
    {ok, Binding} = quod_simplex:history_binding(
                      Target, Bound#transaction.author, Projection),
    {ok, Signed} = quod_transaction:sign(
                      Binding, Bound, signer(author())),
    Signed.

%% Slot 1 uses the same canonical genesis constructor as production.  Keeping
%% a second hand-written genesis here would let catch-up tests silently drift
%% from founding/restart validation when a reserved genesis fact is added.
genesis(Pubs) ->
    [Self | OtherFounders] = Pubs,
    Transaction =
        quod_simplex:test_genesis_tx(
          #{committee => OtherFounders,
            external_predicate_modules => []},
          ?NS, Self, ?GENESIS_NONCE),
    {ok, Block} = quod_ledger:new_block(
                    {genesis, 0}, none, {batch, [Transaction]}, 0),
    quod_ledger:entry(1, Block, none).

%% Build an over-cap record without teaching the canonical founding helper how
%% to create invalid state.  The verifier must reject this wire/history input.
oversized_genesis(Pubs) ->
    Founding = lists:sublist(Pubs, ?MAX_VALIDATORS),
    Extra = lists:nth(?MAX_VALIDATORS + 1, Pubs),
    Entry0 = genesis(Founding),
    #entry{data = {batch, [Tx0]}} = quod_ledger:entry_view(Entry0),
    ExtraAdmission =
        {assert, {{peer_admitted, Extra, undefined, undefined, Extra}, true}},
    Tx1 = Tx0#transaction{diff = Tx0#transaction.diff ++ [ExtraAdmission]},
    entry_with_data(Entry0, {batch, [Tx1]}).

entry_with_data(Entry, Data) ->
    {ok, Changed} = quod_ledger:decode_entry(entry_bytes_with_data(Entry, Data)),
    Changed.

entry_bytes_with_data(Entry, Data) ->
    {ok, #block{era = Era, slot = View, parent = Parent, timestamp = Ts}} =
        quod_ledger:block_from_entry(Entry),
    {ok, Block} = quod_ledger:new_block({Era, View}, Parent, Data, Ts),
    {ok, Bytes} = quod_ledger:encode_entry(Entry),
    Wire = binary_to_term(Bytes, [safe]),
    term_to_binary(setelement(4, Wire, quod_ledger:block_bytes(Block)), [deterministic]).

genesis_hash(C) -> gen_hash(genesis(pubs(C))).
domain(C) -> quod_simplex:consensus_domain(?NS, genesis_hash(C)).

verify_chain(C, Entries) -> verify_entries({?NS, genesis_hash(C)}, Entries).

verify_entries(Identity, Entries) ->
    #{ledger_root := Root} = catchup_options(),
    {ok, Index} = quod_dtx_phase_index:open(Root, ?NS),
    try verify_groups(Identity, Entries, quod_simplex:history_projection(Identity), Index)
    after quod_dtx_phase_index:close(Index), file:del_dir_r(Root) end.

verify_groups(_Identity, [], Projection, _Index) -> {ok, Projection};
verify_groups(Identity, [Entry | Rest], Projection, Index) ->
    case quod_ct:history_advance(Identity, Entry, Projection, Index) of
        {ok, Next, _} -> verify_groups(Identity, Rest, Next, Index);
        {error, _} = Error -> Error
    end.

projection_after_genesis(C) ->
    quod_simplex:history_advance(?NS, genesis(pubs(C)),
                                quod_simplex:history_projection({?NS, genesis_hash(C)})).

%% The explicit parent projection fixes the protocol era/view independently
%% of material height. Signers may deliberately differ in negative controls.
committed(I, Tx, Projection, C, K) ->
    committed_in(domain(C), I, Tx, Projection, C, K).

committed_in(Domain, I, Tx, Projection, C, K) ->
    committed_batch(Domain, I, [Tx], Projection, 0, C, K).

committed_batch(Domain, I, Transactions, Projection, Ts, C, K) ->
    Parent = {Era, View, _} = maps:get(protocol_root, Projection),
    Position = {Era, View + 1},
    {ok, Block} = quod_ledger:new_block(Position, Parent, {batch, Transactions}, Ts),
    Hash = quod_simplex:block_hash(Block),
    Shares = [quod_simplex:make_share(Domain, commit, Position, Hash, signer(M))
              || M <- lists:sublist(C, K)],
    {ok, Cert} = quod_simplex:form_cert(Domain, commit, Position, Hash, Shares, pubs(C)),
    quod_ledger:entry(I, Block, Cert).

tx(I, GC)    ->
    {Author, _} = author(),
    sign_tx(#transaction{tx_id = integer_to_binary(I), origin = {?NS, <<0:256>>},
                         proof_id = <<I:256>>, plan_digest = <<I:256>>,
                         goal = durable_goal({fact, I}),
                         result = durable_result(),
                         diff = [{assert, {{fact, I}, true}}],
                         read_check = #{}, author = Author, author_seq = I,
                         sig = none}, GC).
admit_tx(Pk, GC) -> peer_tx(assert, Pk, GC).
remove_tx(Pk, GC) -> peer_tx(retract, Pk, GC).
peer_tx(Op, Pk, GC) ->
    {Author, _} = author(),
    sign_tx(#transaction{tx_id = <<"m">>, origin = {?NS, <<0:256>>},
                         proof_id = <<77:256>>, plan_digest = <<78:256>>,
                         goal = durable_goal({membership, Op, Pk}),
                         result = durable_result(),
                         diff = [{Op, {{peer_admitted, Pk, undefined, undefined, Pk}, true}}],
                         read_check = #{}, author = Author,
                         author_seq = 2,
                         sig = none}, GC).

durable_goal(Goal) ->
    {ok, Blob} = quod_durable_term:encode_goal(Goal),
    Blob.

durable_result() ->
    {ok, Blob} = quod_durable_term:encode_result(#{}),
    Blob.

%%%--- proof and historical membership controls ---

happy_test() ->
    C = committee(4), G = genesis(pubs(C)), P = projection_after_genesis(C),
    B2 = committed(2, tx(2, C), P, C, 3),
    P2 = quod_simplex:history_advance(?NS, B2, P),
    B3 = committed(3, tx(3, C), P2, C, 4),
    {ok, Final} = verify_chain(C, [G, B2, B3]),
    ?assertEqual(pubs(C), quod_simplex:history_committee(Final)).

canonical_page_artifacts_survive_verify_and_forward_test() ->
    C = committee(4), G = genesis(pubs(C)),
    B = committed(2, tx(2, C), projection_after_genesis(C), C, 3),
    {ok, _} = verify_chain(C, [G, B]),
    lists:foreach(fun(Entry) ->
        {ok, Bytes} = quod_ledger:encode_entry(Entry),
        Frame = quod_feed:encode(?NS, {block, Entry}),
        {feed, ?NS, Inner} = binary_to_term(Frame, [safe]),
        ?assertEqual({block_bytes, Bytes}, binary_to_term(Inner, [safe])),
        ?assertEqual({block, Entry}, quod_feed:decode(Frame, ?NS)),
        ?assertEqual({ok, Entry}, quod_ledger:decode_entry(Bytes))
    end, [G, B]).

validator_cap_history_boundary_test() ->
    N = ?MAX_VALIDATORS, C = committee(N), G = genesis(pubs(C)),
    {ok, P} = verify_chain(C, [G]),
    ?assertEqual(pubs(C), quod_simplex:history_committee(P)),
    Oversized = oversized_genesis(pubs(committee(N + 1))),
    ?assertEqual({error, {invalid_transaction, 1}},
        verify_entries({?NS, gen_hash(Oversized)}, [Oversized])),
    {Extra, _} = quod_identity:generate(),
    Admission = committed(2, admit_tx(Extra, C), P, C, quod_simplex:quorum(N)),
    ?assertEqual({error, {invalid_transaction, 2}}, verify_chain(C, [G, Admission])).

batch_hash_is_verified_test() ->
    C = committee(4), G = genesis(pubs(C)),
    Batch = committed_batch(domain(C), 2, [tx(20, C), tx(21, C)],
                            projection_after_genesis(C), 0, C, 3),
    ?assertMatch({ok, _}, verify_chain(C, [G, Batch])),
    Changed = entry_bytes_with_data(Batch, {batch, [tx(21, C), tx(20, C)]}),
    ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(Changed)).

timestamped_test() ->
    C = committee(4), G = genesis(pubs(C)), P = projection_after_genesis(C),
    B2 = committed_batch(domain(C), 2, [tx(2, C)], P, 1750000000000, C, 3),
    P2 = quod_simplex:history_advance(?NS, B2, P),
    B3 = committed_batch(domain(C), 3, [tx(3, C)], P2, 1750000000500, C, 4),
    ?assertMatch({ok, _}, verify_chain(C, [G, B2, B3])),
    View = quod_ledger:entry_view(B2),
    ?assertEqual({error, bad_entry},
        quod_ledger:from_entry_view(View#entry{timestamp = 1750000009999})).

bad_cert_test() ->
    C = committee(4), Outsiders = committee(4),
    Bad = committed_in(domain(C), 2, tx(2, C), projection_after_genesis(C), Outsiders, 3),
    ?assertEqual({error, {bad_cert, 2}}, verify_chain(C, [genesis(pubs(C)), Bad])).

missing_and_malformed_certificates_are_not_artifacts_test() ->
    C = committee(4),
    B = committed(2, tx(2, C), projection_after_genesis(C), C, 3),
    View = #entry{cert = Cert} = quod_ledger:entry_view(B),
    [First | _] = Cert#cert.sigs,
    lists:foreach(fun(Bad) ->
        ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view(View#entry{cert = Bad}))
    end, [none, Cert#cert{kind = complaint}, Cert#cert{sigs = not_a_list},
          Cert#cert{sigs = [First | bad_tail]}]).

cert_mismatch_test() ->
    C = committee(4), B = committed(2, tx(2, C), projection_after_genesis(C), C, 3),
    ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(
        entry_bytes_with_data(B, {batch, [tx(99, C)]}))).

noncontiguous_rejected_test() ->
    C = committee(4), P = projection_after_genesis(C),
    B2 = committed(2, tx(2, C), P, C, 3),
    B3 = committed(3, tx(3, C), quod_simplex:history_advance(?NS, B2, P), C, 3),
    ?assertEqual({error, {cert_mismatch, 3}}, verify_chain(C, [genesis(pubs(C)), B3])).

malformed_entry_rejected_test() ->
    C = committee(4), B = committed(2, tx(2, C), projection_after_genesis(C), C, 3),
    View = quod_ledger:entry_view(B),
    ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view({not_an_entry, 2})),
    ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view(
        View#entry{data = {batch, [tx(2, C) | bad_tail]}})),
    BadTx = (tx(2, C))#transaction{diff = [not_an_operation]},
    ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view(View#entry{data = {batch, [BadTx]}})).

membership_chain(C, NextC, Membership) ->
    G = genesis(pubs(C)), P = projection_after_genesis(C),
    B2 = committed(2, Membership, P, C, quod_simplex:quorum(length(C))),
    P2 = quod_simplex:history_advance(?NS, B2, P),
    B3 = committed_in(domain(C), 3, tx(3, C), P2, NextC, quod_simplex:quorum(length(NextC))),
    [G, B2, B3].

committee_grows_test() ->
    C = committee(4), {Pub, _} = New = quod_identity:generate(),
    {ok, P} = verify_chain(C, membership_chain(C, C ++ [New], admit_tx(Pub, C))),
    ?assertEqual(lists:usort([Pub | pubs(C)]), quod_simplex:history_committee(P)).

committee_grows_rejects_stale_test() ->
    C = committee(4), {Pub, _} = quod_identity:generate(),
    ?assertEqual({error, {bad_cert, 3}},
        verify_chain(C, membership_chain(C, C, admit_tx(Pub, C)))).

committee_shrinks_test() ->
    C = committee(5), {Author, _} = author(), Gone = hd(pubs(C) -- [Author]),
    Next = [M || {Pub, _} = M <- C, Pub =/= Gone],
    {ok, P} = verify_chain(C, membership_chain(C, Next, remove_tx(Gone, C))),
    ?assertEqual(pubs(Next), quod_simplex:history_committee(P)).

explicit_cross_domain_rejected_test() ->
    C = committee(4), G = genesis(pubs(C)), GH = genesis_hash(C), P = projection_after_genesis(C),
    Domains = [quod_simplex:consensus_domain(<<"other:ontology">>, GH),
               quod_simplex:consensus_domain(?NS, crypto:hash(sha256, <<"other genesis">>))],
    lists:foreach(fun(Domain) ->
        Entry = committed_in(Domain, 2, tx(2, C), P, C, 3),
        ?assertEqual({error, {bad_cert, 2}}, verify_chain(C, [G, Entry]))
    end, Domains).

empty_namespace_is_rejected_test() ->
    ?assertEqual({error, bad_catchup_options}, quod_catchup:catch_up(
        <<>>, <<1:256>>, fun(_, _, _) -> error(unreachable) end,
        fun(_) -> error(unreachable) end, 1, #{}, #{})).

%%%--- catch_up/7 driver (mocked transport, real writer snapshots) ---

%% a Fetch serving a pre-built Chain (entries 1..H) in windows of W; From > H ⇒ empty.
mock_fetch(Chain, W) ->
    Base = quod_foreign_log_tests:chain_fetch(?NS, Chain),
    fun(Query, Deadline, Consume) ->
        Bounded = case Query of
            {range, From, To} -> {range, From, min(To, From + W - 1)};
            _ -> Query
        end,
        case Base(none, none, ?NS, Bounded, Deadline, Consume) of
            {ok, {ok, Next}, Height, Continuation} -> {ok, Next, Height, Continuation};
            {ok, {error, _} = Error, _, _} -> Error;
            {error, _} = Error -> Error
        end
    end.

sink() ->
    put(sink, []),
    fun(Es, Projection) ->
            put(sink, lists:reverse(Es, get(sink))),
            put(sink_projection, Projection),
            ok
    end.

sunk() ->
    lists:reverse(get(sink)).

catchup_options() ->
    Unique = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    #{ledger_root => filename:join(
                        "/tmp", "quod_catchup_verify_" ++ Unique)}.

run_catch_up(GenesisHash, Fetch, Sink) ->
    with_disk_sink(GenesisHash, [], Sink,
      fun(DurableSink, View = #{projection := Projection}, Options) ->
          quod_catchup:catch_up(
            ?NS, GenesisHash, Fetch, DurableSink, 1, Projection,
            Options#{history_view => View})
      end).

with_disk_sink(GenesisHash, Prefix, Sink, Fun) ->
    Options = #{ledger_root := Scratch} = catchup_options(),
    %% The driver has no path authority. Only this fixture writer opens the
    %% real ledger and retained index; every borrowed view is read-only.
    LedgerRoot = Scratch ++ "-ledger",
    Key = make_ref(),
    {ok, Empty} = quod_ledger_store:open(?NS, LedgerRoot),
    {ok, Index} = quod_dtx_phase_index:open(LedgerRoot, ?NS),
    put(Key, Empty),
    try
        {ok, Store} = quod_ct:append_direct_history(Empty, Prefix),
        put(Key, Store),
        Identity = {?NS, GenesisHash},
        Projection0 = quod_simplex:history_projection(Identity),
        Projection = lists:foldl(fun(Entry, P) ->
            {ok, Next, _} = quod_ct:history_advance(Identity, Entry, P, Index), Next
        end, Projection0, Prefix),
        View = sink_view(Store, Identity, Projection, Index),
        DurableSink = fun(#{entries := Entries, projection := Projection1,
                            delta := Delta1, proof := Proof}) ->
            case Sink(Entries, Projection1) of
                ok ->
                    {ok, Next} = quod_ledger_store:append(get(Key), {Proof, Entries}),
                    put(Key, Next),
                    ok = quod_dtx_phase_index:commit_delta(Index, Delta1),
                    {ok, sink_view(Next, Identity, Projection1, Index)};
                {error, _} = Error -> Error
            end
        end,
        Fun(DurableSink, View, Options#{stage_path => quod_ledger_store:staging_path(Store)})
    after
        quod_dtx_phase_index:close(Index),
        quod_ledger_store:close(erase(Key)),
        _ = file:del_dir_r(Scratch),
        _ = file:del_dir_r(LedgerRoot)
    end.

sink_view(Store, Identity, Projection, Index) ->
    Height = quod_ledger_store:last(Store),
    {ok, IndexView} = quod_dtx_phase_index:capture(Index, Height),
    Bounded = Projection#{history_index => IndexView,
                         committee_views := lists:sublist(maps:get(committee_views, Projection), 1)},
    #{owner => self(), identity => Identity, slot => Height, applied => Height,
      snapshot => quod_ledger_store:snapshot(Store), projection => Bounded}.

phase_window_uses_retained_owner_index_test() ->
    F = quod_foreign_log_tests:long_identity_fixture(?NS, 257),
    Prefix = maps:get(chain, F), GH = maps:get(anchor, F),
    Resolve = direct_abort_entry(258, F),
    Chain = Prefix ++ [Resolve],
    %% The first DTX control arrives after successful content-only sink turns;
    %% it uses the read-only index returned with the preceding sink.
    ?assertEqual({ok, 258}, run_catch_up(GH, mock_fetch(Chain, 128), sink())),
    ?assertEqual(Chain, sunk()).

resumed_phase_window_uses_initial_owner_capture_test() ->
    F = quod_foreign_log_tests:long_identity_fixture(?NS, 257),
    Prefix = maps:get(chain, F), GH = maps:get(anchor, F),
    Resolve = direct_abort_entry(258, F),
    with_disk_sink(GH, Prefix, sink(),
      fun(Sink, View = #{projection := Projection}, Options) ->
          ?assertEqual({ok, 258}, quod_catchup:catch_up(
              ?NS, GH, mock_fetch(Prefix ++ [Resolve], 128), Sink,
              258, Projection, Options#{history_view => View})),
          ?assertEqual([Resolve], sunk()),
          ?assertEqual({error, bad_catchup_options}, quod_catchup:catch_up(
              ?NS, GH, fun(_, _, _) -> error(mismatched_view_fetched) end, Sink,
              258, Projection, Options#{history_view => View#{slot => 256}}))
      end).

history_suffix_only_work_is_counted_test() ->
    lists:foreach(fun(Counts) ->
        ?assertEqual(0, maps:get(prefix_entries_read, Counts)),
        ?assertEqual(0, maps:get(prefix_entries_reverified, Counts)),
        ?assertEqual(1, maps:get(suffix_entries_verified, Counts))
    end, history_suffix_work_probe()).

history_suffix_work_probe() ->
    [{module, M} = code:ensure_loaded(M)
     || M <- [quod_catchup, quod_ledger_store]],
    MFAs = [{{quod_catchup, preview_group, 5}, [local]},
            {{quod_ledger_store, read_at, 3}, []},
            {{quod_ledger_store, fold_groups, 3}, []},
            {{quod_ledger_store, read_range, 4}, []}],
    lists:foreach(fun({MFA, Flags}) ->
        1 = erlang:trace_pattern(MFA, true, Flags)
    end, MFAs),
    try
        [history_replay_baseline_case(Height, Kind)
         || Height <- [8, 64, 257], Kind <- [content, dtx]]
    after
        lists:foreach(fun({MFA, Flags}) ->
            erlang:trace_pattern(MFA, false, Flags)
        end, MFAs)
    end.

history_replay_baseline_case(Height, Kind) ->
    Parent = self(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        try
            F = quod_foreign_log_tests:long_identity_fixture(?NS, Height + 1),
            GH = maps:get(anchor, F),
            Prefix = lists:sublist(maps:get(chain, F), Height),
            Last = case Kind of
                content -> lists:last(maps:get(chain, F));
                dtx -> direct_abort_entry(Height + 1, F#{chain := Prefix})
            end,
            with_disk_sink(GH, Prefix, sink(),
              fun(Sink, View = #{projection := Projection}, Options) ->
                  %% Startup/setup verification has completed BEFORE tracing.
                  Parent ! {history_probe_ready, self()},
                  receive history_probe_go -> ok end,
                  Result = quod_catchup:catch_up(
                    ?NS, GH, mock_fetch(Prefix ++ [Last], 128), Sink,
                    Height + 1, Projection, Options#{history_view => View}),
                  Parent ! {history_probe_result, self(), Result, sunk()},
                  receive history_probe_finish -> ok end
              end)
        catch Class:Reason:Stack ->
            Parent ! {history_probe_failed, self(), Class, Reason, Stack}
        end
    end),
    try
        receive
            {history_probe_ready, Worker} -> ok;
            {history_probe_failed, Worker, C0, R0, S0} -> erlang:raise(C0, R0, S0)
        after 10000 -> error(history_probe_setup_stalled)
        end,
        1 = erlang:trace(Worker, true, [call, {tracer, self()}]),
        Worker ! history_probe_go,
        receive
            {history_probe_result, Worker, Result, Sunk} ->
                ?assertEqual({ok, Height + 1}, Result),
                ?assertEqual(1, length(Sunk));
            {history_probe_failed, Worker, C1, R1, S1} -> erlang:raise(C1, R1, S1)
        after 10000 -> error(history_probe_catchup_stalled)
        end,
        Barrier = erlang:trace_delivered(Worker),
        Counts = history_probe_trace(Worker, Barrier, Height,
                    #{prefix_entries_read => 0, prefix_entries_reverified => 0,
                      prefix_backfills => 0, suffix_entries_verified => 0}),
        _ = erlang:trace(Worker, false, [call]),
        Counts#{prefix_height => Height, missing_blocks => 1,
                suffix_kind => atom_to_binary(Kind),
                target_invariant_passed =>
                    maps:get(prefix_entries_read, Counts) =:= 0 andalso
                    maps:get(prefix_entries_reverified, Counts) =:= 0}
    after
        Worker ! history_probe_finish,
        receive {'DOWN', Monitor, process, Worker, normal} -> ok
        after 10000 ->
            exit(Worker, kill),
            receive {'DOWN', Monitor, process, Worker, _} -> ok end,
            error(history_probe_cleanup_stalled)
        end
    end.

history_probe_trace(Worker, Barrier, Height, Counts) ->
    receive
        {trace, Worker, call, {quod_ledger_store, read_range, [_Store, From, To, _Form]}} ->
            N = max(0, min(To, Height) - From + 1),
            history_probe_trace(Worker, Barrier, Height,
                maps:update_with(prefix_entries_read, fun(V) -> V + N end, Counts));
        {trace, Worker, call, {quod_ledger_store, read_at, [_Store, At, _]}} ->
            N = case At =< Height of true -> 1; false -> 0 end,
            history_probe_trace(Worker, Barrier, Height,
                maps:update_with(prefix_entries_read, fun(V) -> V + N end, Counts));
        {trace, Worker, call, {quod_ledger_store, fold_groups, _}} ->
            history_probe_trace(Worker, Barrier, Height,
                maps:update_with(prefix_entries_read, fun(V) -> V + Height end, Counts));
        {trace, Worker, call, {quod_catchup, preview_group,
                              [_Identity, [Entry | _], _P, _Index, _Delta]}} ->
            N = case quod_ledger:entry_index(Entry) =< Height of true -> 1; false -> 0 end,
            C1 = maps:update_with(prefix_entries_reverified, fun(V) -> V + N end, Counts),
            C2 = maps:update_with(suffix_entries_verified,
                                 fun(V) -> V + 1 - N end, C1),
            history_probe_trace(Worker, Barrier, Height, C2);
        {trace_delivered, Worker, Barrier} -> Counts
    after 10000 -> error(history_probe_trace_barrier_stalled)
    end.

direct_abort_entry(Slot, F = #{anchor := Anchor, signer := Signer, admission := Admission}) ->
    Target = {?NS, Anchor},
    {ok, VoteRef} = quod_dtx:certified_ref(
        <<"foreign-origin">>, <<60:256>>, 7, <<61:256>>, <<62:256>>,
        quod_ct:fixture_finality(6, <<61:256>>)),
    Record = quod_ct:atomic_abort_record(Target, <<63:256>>, VoteRef),
    {ok, Material} = quod_atomic:admission_material(Record),
    {ok, Control} = quod_atomic:sign_control(Target, Material, Admission, 1, 1,
                                         Signer),
    {ok, ParentBlock} = quod_ledger:block_from_entry(lists:last(maps:get(chain, F))),
    Parent = {Era, View, _} = quod_ledger:block_ref(ParentBlock),
    {ok, Block} = quod_ledger:new_block({Era, View + 1}, Parent, {batch, [{dtx, Control}]}, 0),
    Cert = quod_ct:protocol_certificate(Block, F#{identity => Target}),
    quod_ledger:entry(Slot, Block, Cert).

%% the out-of-band-pinned genesis anchor = block_hash of the genesis block.
gen_hash(Entry) ->
    #entry{index = 1} = quod_ledger:entry_view(Entry),
    {ok, Block} = quod_ledger:block_from_entry(Entry),
    quod_simplex:block_hash(Block).

%% The driver loops windowed fetches, verifies each, sinks the verified entries in order, and reports the
%% caught-up height.
catch_up_happy_test() ->
    C = committee(4), P = pubs(C), G = genesis(P),
    P0 = projection_after_genesis(C),
    B2 = committed(2, tx(2, C), P0, C, 3),
    B3 = committed(3, tx(3, C), quod_simplex:history_advance(?NS, B2, P0), C, 4),
    Chain = [G, B2, B3],
    Sink = sink(),
    ?assertEqual({ok, 3}, run_catch_up(gen_hash(G), mock_fetch(Chain, 2), Sink)),   %% windows of 2
    ?assertEqual(Chain, sunk()).                                                             %% all, in order

%% A genesis whose CONTENT (here, committee) differs from the pinned genesis hash is rejected (forged anchor).
catch_up_bad_anchor_test() ->
    C = committee(4), Fake = committee(4),
    Chain = [genesis(pubs(Fake))],
    ?assertEqual({error, {cert_mismatch, 1}},
                 run_catch_up(
                   gen_hash(genesis(pubs(C))), mock_fetch(Chain, 10),
                   fun(_, _) -> ok end)).

%% Each complete proof group commits independently of transport page boundaries.
%% A later invalid group cannot remove an already-committed earlier group.
catch_up_forged_test() ->
    C = committee(4), Outsiders = committee(4), G = genesis(pubs(C)),
    Chain = [G, committed_in(domain(C), 2, tx(2, C), projection_after_genesis(C), Outsiders, 3)],
    Sink = sink(),
    ?assertMatch({error, {bad_cert, 2}},
                 run_catch_up(gen_hash(G), mock_fetch(Chain, 10), Sink)),
    ?assertEqual([G], sunk()).

%% A committee change in window 1 is threaded so window 2 verifies against the GROWN set.
catch_up_committee_change_across_windows_test() ->
    C4 = committee(4), P4 = pubs(C4), G = genesis(P4),
    {P5, _} = New = quod_identity:generate(), C5 = C4 ++ [New],
    Domain = domain(C4),
    B2 = committed(2, admit_tx(P5, C4), projection_after_genesis(C4), C4, 3),   %% grows the committee, in window 1
    B3 = committed_in(Domain, 3, tx(3, C4), quod_simplex:history_advance(?NS, B2, projection_after_genesis(C4)), C5, 4), %% window 2, needs the 5-set quorum
    Sink  = sink(),
    Fetch = mock_fetch([G, B2, B3], 2),
    ?assertEqual({ok, 3}, run_catch_up(gen_hash(G), Fetch, Sink)),
    ?assertEqual([G, B2, B3], sunk()).

catch_up_real_writer_current_era_view_preserves_verifier_history_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    C4 = committee(4), G = genesis(pubs(C4)), GH = gen_hash(G),
    {P5, _} = New = quod_identity:generate(), C5 = C4 ++ [New],
    B2 = committed(2, admit_tx(P5, C4), projection_after_genesis(C4), C4, 3),
    B3 = committed_in(domain(C4), 3, tx(3, C4), quod_simplex:history_advance(?NS, B2, projection_after_genesis(C4)), C5, 4),
    Options = #{ledger_root := Scratch} = catchup_options(),
    LedgerRoot = Scratch ++ "-writer",
    StateKey = make_ref(), ViewsKey = make_ref(),
    try
        {ok, Store} = quod_ledger_store:open(?NS, LedgerRoot),
        {ok, Index} = quod_dtx_phase_index:open(LedgerRoot, ?NS),
        try
            %% Use the actual sink callback and its actual same-turn capture,
            %% not the disk fixture's handwritten echo of the input projection.
            Root = {quod_ledger:initial_era({?NS, GH}), 0, GH},
            State0 = quod_simplex:test_state(
                       #{ns => ?NS, genesis_hash => GH,
                         consensus_domain => domain(C4), store => Store, phase_index => Index,
                         eng => quod_simplex:eng_new(domain(C4), [], {Root, 0}),
                         archive_tip => {Root, 0},
                         sync => {pulling, self()}}),
            put(StateKey, State0),
            put(ViewsKey, []),
            Sink = fun(Group = #{projection := VerifiedProjection}) ->
                From = {self(), make_ref()},
                {keep_state, State1, Actions} = quod_simplex:running(
                    {call, From},
                    {sink_catchup, {recovery, self()}, Group},
                    get(StateKey)),
                put(StateKey, State1),
                [{reply, From, {ok, View}}] =
                    [A || {reply, F, _} = A <- Actions, F =:= From],
                put(ViewsKey, [{VerifiedProjection, View} | get(ViewsKey)]),
                {ok, View}
            end,
            Fetch = mock_fetch([G, B2, B3], 2),
            InitialView = #{projection := InitialProjection} = sink_view(
                Store, {?NS, GH}, quod_simplex:history_projection({?NS, GH}), Index),
            ?assertEqual({ok, 3}, quod_catchup:catch_up(
                ?NS, GH, Fetch, Sink, 1, InitialProjection,
                Options#{history_view => InitialView, stage_path => quod_ledger_store:staging_path(Store)})),
            [{_, #{slot := 1}}, {Verified2, View2}, {Verified3, View3}] = lists:reverse(get(ViewsKey)),
            ?assertEqual(2, length(maps:get(committee_views, Verified2))),
            ?assertEqual(1, length(maps:get(committee_views, Verified3))),
            lists:foreach(
              fun({Verified, #{owner := Owner, projection := Published}}) ->
                  ?assertEqual(self(), Owner),
                  ?assertEqual(1, length(maps:get(committee_views, Published))),
                  ?assert(maps:is_key(history_index, Published)),
                  ?assertEqual(maps:get(history_head, Verified),
                               maps:get(history_head, Published)),
                  ?assertEqual(pubs(C5), quod_simplex:history_committee(Published)),
                  %% Every intermediate era is installed before this reply;
                  %% the current-only projection resolves old slots by index.
                  ?assertMatch({ok, _, _, _},
                               quod_simplex:history_committee_view(1, Published)),
                  {ok, OldCommittee, _, _} = quod_simplex:history_committee_view(1, Published),
                  ?assertEqual(pubs(C4), OldCommittee)
              end, [{Verified2, View2}, {Verified3, View3}]),
            ?assertEqual(2, maps:get(slot, View2)),
            ?assertEqual(3, maps:get(slot, View3)),
            {3, DurableStore} = quod_simplex:test_committed_store(get(StateKey)),
            ?assertEqual({ok, [G, B2, B3]},
                         quod_ledger_store:read_range(DurableStore, 1, 3, all)),
            %% The earlier writer acknowledgement remains a bounded prefix.
            {ok, Reader} = quod_ledger_store:open_ro_snapshot(maps:get(snapshot, View2)),
            try ?assertEqual(not_found, quod_ledger_store:read_at(Reader, 3))
            after quod_ledger_store:close(Reader)
            end
        after
            erase(StateKey), erase(ViewsKey),
            quod_dtx_phase_index:close(Index),
            quod_ledger_store:close(Store)
        end
    after
        _ = file:del_dir_r(Scratch),
        _ = file:del_dir_r(LedgerRoot)
    end.

catch_up_overtaken_same_group_window_cannot_reinstall_old_state_test() ->
    with_phase_writer(fun(F, Index, Sink, View, StateKey) ->
        Ns = maps:get(ns, F), Anchor = maps:get(anchor, F),
        [_, _, Resolve] = maps:get(chain, F),
        #{projection := #{history_index := Capture} = Projection} = View,
        {ok, Group} = quod_ct:history_group({Ns, Anchor}, Resolve, Projection, Capture),
        %% Another owner-applied window overtakes the verified borrow. The
        %% actual sink advances; the earlier view still hides this same-group
        %% Resolve. This is the production applier seam, not consensus admission.
        {ok, _} = Sink(Group),
        {ok, OldHistory} = quod_dtx_phase_index:history(Capture, maps:get(group_id, F)),
        ?assertEqual(not_found, quod_atomic:history_phase(resolve, OldHistory)),
        {ok, NewHistory} = quod_dtx_phase_index:history(Index, maps:get(group_id, F)),
        ?assertEqual({ok, maps:get(resolve_ref, F)}, quod_atomic:history_phase(resolve, NewHistory)),
        Installed = get(StateKey),
        IndexStats = quod_dtx_phase_index:stats(Index),
        ?assertEqual({error, stale_window}, Sink(Group)),
        ?assertEqual(Installed, get(StateKey)),
        ?assertEqual(IndexStats, quod_dtx_phase_index:stats(Index)),
        {3, Store} = quod_simplex:test_committed_store(Installed),
        ?assertEqual({ok, maps:get(chain, F)}, quod_ledger_store:read_range(Store, 1, 3, all))
    end).

catch_up_failed_append_leaves_retained_index_unchanged_test() ->
    with_phase_writer(fun(F, Index, Sink, View, StateKey) ->
        [_, _, Resolve] = maps:get(chain, F),
        #{projection := #{history_index := Capture} = Projection} = View,
        {ok, Group} = quod_ct:history_group(
            {maps:get(ns, F), maps:get(anchor, F)}, Resolve, Projection, Capture),
        Installed = get(StateKey),
        Before = quod_dtx_phase_index:stats(Index),
        {2, Store} = quod_simplex:test_committed_store(Installed),
        ok = quod_ledger_store:close(Store),
        ?assertMatch({error, _}, Sink(Group)),
        ?assertEqual(Installed, get(StateKey)),
        ?assertEqual(Before, quod_dtx_phase_index:stats(Index)),
        {ok, History} = quod_dtx_phase_index:history(Index, maps:get(group_id, F)),
        ?assertEqual(not_found, quod_atomic:history_phase(resolve, History))
    end).

catch_up_index_install_failure_is_loud_before_any_publication_test() ->
    with_phase_writer(fun(F, Index, Sink, View, StateKey) ->
        Ns = maps:get(ns, F),
        [_, _, Resolve] = maps:get(chain, F),
        #{projection := #{history_index := Capture} = Projection} = View,
        {ok, Group} = quod_ct:history_group(
            {Ns, maps:get(anchor, F)}, Resolve, Projection, Capture),
        true = quod_reg:reg({quod_prolog, Ns}),
        true = quod_reg:subscribe({committed, Ns}),
        try
            %% The actual table disappears after verification but before
            %% installation. Appending may succeed; publishing the old index
            %% or converting the failure to a recoverable sink reply may not.
            ok = quod_dtx_phase_index:close(Index),
            ?assertException(error, {badmatch, {error, {phase_index_io, _}}},
                             Sink(Group)),
            ?assertEqual([], writer_publications([])),
            {2, OldStore} = quod_simplex:test_committed_store(get(StateKey)),
            ok = quod_ledger_store:close(OldStore),
            {ok, Reopened} = quod_ledger_store:open(Ns, maps:get(root, F)),
            try
                ?assertEqual(3, quod_ledger_store:last(Reopened)),
                ?assertEqual({ok, Resolve}, quod_ledger_store:read_at(Reopened, 3))
            after quod_ledger_store:close(Reopened)
            end
        after
            true = quod_reg:unsubscribe({committed, Ns}),
            true = gproc:unreg(quod_reg:name({quod_prolog, Ns}))
        end
    end).

writer_publications(Acc) ->
    receive
        {'$gen_cast', _} = Cast -> writer_publications([Cast | Acc]);
        {certified_head, _, _} = Head -> writer_publications([Head | Acc]);
        {committed, _, _} = Commit -> writer_publications([Commit | Acc])
    after 0 -> lists:reverse(Acc)
    end.

with_phase_writer(Fun) ->
    %% The owner publications belong to this fixture's mailbox, not EUnit's
    %% shared executor, which may contain another fixture's production casts.
    Parent = self(), Tag = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Outcome = try with_phase_writer_owned(Fun) of
            Result -> {ok, Result}
        catch Class:Reason:Stack -> {exception, Class, Reason, Stack}
        end,
        Parent ! {Tag, Outcome}
    end),
    receive
        {Tag, Outcome} ->
            receive {'DOWN', Monitor, process, Pid, normal} -> ok end,
            case Outcome of
                {ok, Result} -> Result;
                {exception, Class, Reason, Stack} -> erlang:raise(Class, Reason, Stack)
            end;
        {'DOWN', Monitor, process, Pid, Reason} -> error({phase_writer_died, Reason})
    end.

phase_writer_mailbox_isolation_test() ->
    %% Reproduce the combined-suite contaminator without consuming or filtering
    %% away any publication: only the fixture owner may supply the assertion.
    Cast = {'$gen_cast', {unrelated_fixture, make_ref()}},
    self() ! Cast,
    try
        with_phase_writer(fun(_, _, _, _, _) ->
            ?assertEqual([], writer_publications([]))
        end),
        receive Cast -> ok after 0 -> error(parent_publication_consumed) end
    after receive Cast -> ok after 0 -> ok end
    end.

with_phase_writer_owned(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_foreign_log_tests:prepared_then_committed_fixture(
          quod_foreign_log_tests:unique_ns()),
    quod_ct:with_network_identity(maps:get(network, F), fun() ->
    Ns = maps:get(ns, F), Anchor = maps:get(anchor, F),
    Root = quod_foreign_log_tests:temp_dir("catchup-owner-phase"),
    {ok, Store} = quod_ledger_store:open(Ns, Root),
    {ok, Index} = quod_dtx_phase_index:open(Root, Ns),
    StateKey = make_ref(),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    ProtocolRoot = {quod_ledger:initial_era({Ns, Anchor}), 0, Anchor},
    put(StateKey, quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
        consensus_domain => Domain, archive_tip => {ProtocolRoot, 0},
        store => Store, phase_index => Index,
        eng => quod_simplex:eng_new(Domain, [], {ProtocolRoot, 0}),
        sync => {pulling, self()}})),
    Sink = fun(Group) ->
        From = {self(), make_ref()},
        {keep_state, State, Actions} = quod_simplex:running({call, From},
            {sink_catchup, {recovery, self()}, Group}, get(StateKey)),
        put(StateKey, State),
        [Reply] = [R || {reply, Who, R} <- Actions, Who =:= From],
        Reply
    end,
    try
        Prefix = lists:sublist(maps:get(chain, F), 2),
        View = lists:foldl(fun(Entry, #{projection := P}) ->
            {ok, Group} = quod_ct:history_group({Ns, Anchor}, Entry, P, Index),
            {ok, Next} = Sink(Group), Next
        end, #{projection => quod_simplex:history_projection({Ns, Anchor})}, Prefix),
        Fun(F#{root => Root}, Index, Sink, View, StateKey)
    after
        erase(StateKey),
        quod_dtx_phase_index:close(Index), quod_ledger_store:close(Store),
        _ = file:del_dir_r(Root)
    end
    end).

catch_up_owner_death_during_empty_fetch_is_not_completion_test() ->
    C = committee(4), G = genesis(pubs(C)),
    with_disk_sink(gen_hash(G), [G], fun(_, _) -> error(unexpected_sink) end,
      fun(Sink, View = #{projection := Projection}, Options) ->
          {Owner, Monitor} = spawn_monitor(fun() -> receive stop -> ok end end),
          Fetch = fun({range, 2, _}, _Deadline, Consume) ->
              Owner ! stop,
              receive {'DOWN', Monitor, process, Owner, normal} -> ok end,
              Consume([], 1, done)
          end,
          %% Only the identity/lifetime subject is replaced for this control;
          %% the retained index and prefix are the ordinary real disk fixture.
          ?assertEqual({error, owner_down}, quod_catchup:catch_up(
              ?NS, gen_hash(G), Fetch, Sink, 2, Projection,
              Options#{history_view => View#{owner := Owner}}))
      end).

recovery_owner_death_cancels_worker_blocked_in_real_pull_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    #{ledger_root := Root} = catchup_options(),
    Ns = iolist_to_binary([<<"recovery:owner-death:">>,
                          binary:encode_hex(crypto:strong_rand_bytes(8))]),
    Anchor = crypto:hash(sha256, Ns),
    Parent = self(),
    {Endpoint, EndpointRef} = spawn_monitor(fun() ->
        true = quod_reg:reg({quod_catchup, Ns}),
        Parent ! {blocked_recovery_endpoint, self()},
        blocked_recovery_endpoint(Parent)
    end),
    try
        receive {blocked_recovery_endpoint, Endpoint} -> ok
        after 1000 -> error(recovery_endpoint_not_started)
        end,
        {Owner, OwnerRef} = spawn_monitor(fun() ->
            {ok, Store} = quod_ledger_store:open(Ns, Root),
            {ok, Index} = quod_dtx_phase_index:open(Root, Ns),
            try
                true = quod_reg:reg({quod_simplex, Ns}),
                State0 = quod_simplex:test_state(
                           #{ns => Ns, genesis_hash => Anchor, store => Store, phase_index => Index,
                             eng => quod_simplex:eng_new(quod_simplex:consensus_domain(Ns, Anchor), [],
                                      {{quod_ledger:initial_era({Ns, Anchor}), 0, Anchor}, 0}),
                             sync => unconfirmed}),
                %% The production tick arms the real monitored recovery worker.
                {keep_state, State1, _Actions} =
                    quod_simplex:running({timeout, tick}, tick, State0),
                {pulling, Worker} = quod_simplex:test_sync(State1),
                Parent ! {recovery_worker_started, self(), Worker},
                recovery_capture_owner(State1)
            after quod_dtx_phase_index:close(Index), quod_ledger_store:close(Store)
            end
        end),
        try
            Worker = receive {recovery_worker_started, Owner, Pid} -> Pid
                     after 1000 -> error(recovery_worker_not_started)
                     end,
            WorkerRef = monitor(process, Worker),
            try
                %% The fake transport boundary withholds the reply. This is
                %% the worker's real pull/5 call, not a test-owned parked loop.
                receive {recovery_pull_blocked, Worker, 1} -> ok
                after 1000 -> error(recovery_worker_not_in_pull)
                end,
                ?assert(is_process_alive(Worker)),
                exit(Owner, kill),
                receive {'DOWN', WorkerRef, process, Worker, killed} -> ok
                after 1000 -> error(recovery_worker_outlived_owner)
                end
            after
                demonitor(WorkerRef, [flush]),
                exit(Worker, kill)
            end
        after
            exit(Owner, kill),
            receive {'DOWN', OwnerRef, process, Owner, _} -> ok after 1000 -> ok end
        end
    after
        exit(Endpoint, kill),
        receive {'DOWN', EndpointRef, process, Endpoint, _} -> ok after 1000 -> ok end,
        _ = file:del_dir_r(Root)
    end.

blocked_recovery_endpoint(Parent) ->
    receive
        {'$gen_call', From, contact} ->
            gen:reply(From, {"127.0.0.1", 19000}),
            blocked_recovery_endpoint(Parent);
        {'$gen_call', {Worker, _}, {pull, {range, From, _}, _Contact, _Started, _Deadline}} ->
            Parent ! {recovery_pull_blocked, Worker, From},
            blocked_recovery_endpoint(Parent)
    end.

recovery_capture_owner(State) ->
    receive
        {'$gen_call', From, {history_view, _, _, _} = Request} ->
            {keep_state, State1, Actions} = quod_simplex:running({call, From}, Request, State),
            lists:foreach(fun({reply, To, Reply}) -> gen:reply(To, Reply) end, Actions),
            recovery_capture_owner(State1)
    end.

%% A contact that REGRESSES its claimed height below what it already served is treated as stalled (the target
%% is the MAX height seen), not falsely "caught up" — so the joiner fails over instead of truncating.
catch_up_height_regression_test() ->
    C = committee(4), P = pubs(C), G = genesis(P), B2 = committed(2, tx(2, C), projection_after_genesis(C), C, 3),
    Base = mock_fetch([G, B2], 2),
    Fetch = fun(Query = {range, From, _}, Deadline, Consume) ->
        case From of
            1 ->
                {ok, Next, _, More} = Base(Query, Deadline,
                    fun(Parts, _, Continuation) -> Consume(Parts, 100, Continuation) end),
                {ok, Next, 100, More};
            _ -> {ok, Next} = Consume([], 5, done), {ok, Next, 5, done}
        end
    end,
    ?assertEqual({error, no_progress}, run_catch_up(gen_hash(G), Fetch, sink())).

%% A fetch failure surfaces so the caller can try another contact.
catch_up_fetch_error_test() ->
    ?assertEqual({error, timeout},
                 run_catch_up(
                   <<0:256>>, fun(_, _, _) -> {error, timeout} end,
                   fun(_, _) -> ok end)).

catch_up_malformed_height_test() ->
    ?assertEqual({error, changed_transfer_height},
                 run_catch_up(
                   <<0:256>>, fun(_, _, Consume) -> Consume([], not_a_height, done) end,
                   fun(_, _) -> ok end)).

%% A sink failure aborts catch-up cleanly (recoverable), not a badmatch crash.
catch_up_sink_error_test() ->
    C = committee(4), P = pubs(C), G = genesis(P),
    Chain = [G, committed(2, tx(2, C), projection_after_genesis(C), C, 3)],
    ?assertEqual({error, disk_full},
                 run_catch_up(
                   gen_hash(G), mock_fetch(Chain, 10),
                   fun(_, _) -> {error, disk_full} end)).

%% A server that returns empty while claiming more height is stuck — reported, not looped forever.
catch_up_no_progress_test() ->
    ?assertEqual({error, no_progress},
                 run_catch_up(
                   <<0:256>>, fun(_, _, Consume) ->
                       {ok, Range} = Consume([], 5, done), {ok, Range, 5, done}
                   end,
                   fun(_, _) -> ok end)).
