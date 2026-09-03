-module(quod_catchup_verify_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").

-define(NS, <<"ns">>).
-define(GENESIS_NONCE, <<16#5c:256>>).

%%%===================================================================
%%% quod_catchup:verify_forward/5 — the trustless catch-up trust core. A joiner replays a pulled chain by
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
                    1, 0, {batch, [Transaction]}, 0),
    quod_ledger:entry(Block, none).

%% Build an over-cap record without teaching the canonical founding helper how
%% to create invalid state.  The verifier must reject this wire/history input.
oversized_genesis(Pubs) ->
    Founding = lists:sublist(Pubs, ?MAX_VALIDATORS),
    Extra = lists:nth(?MAX_VALIDATORS + 1, Pubs),
    #entry{data = {batch, [Tx0]}} = Entry0 = genesis(Founding),
    ExtraAdmission =
        {assert, {{peer_admitted, Extra, undefined, undefined, Extra}, true}},
    Tx1 = Tx0#transaction{diff = Tx0#transaction.diff ++ [ExtraAdmission]},
    entry_with_data(Entry0, {batch, [Tx1]}).

entry_with_data(#entry{index = Index, timestamp = Timestamp,
                       cert = Cert}, Data) ->
    {ok, Block} = quod_ledger:new_block(
                    Index, Index - 1, Data, Timestamp),
    quod_ledger:entry(Block, Cert).

genesis_hash(C) ->
    gen_hash(genesis(pubs(C))).

domain(C) ->
    quod_simplex:consensus_domain(?NS, genesis_hash(C)).

verify_chain(GenesisCommittee, Committee0, From, Entries) ->
    Projection0 =
        case Committee0 of
            [] -> quod_simplex:history_projection();
            _  -> projection_after_genesis(GenesisCommittee)
        end,
    case quod_catchup:verify_forward(
           ?NS, genesis_hash(GenesisCommittee), Projection0, From, Entries) of
        {ok, Verified, Projection1} ->
            {ok, Verified, quod_simplex:history_committee(Projection1)};
        Error ->
            Error
    end.

projection_after_genesis(GenesisCommittee) ->
    quod_simplex:history_advance(
      ?NS, genesis(pubs(GenesisCommittee)), quod_simplex:history_projection()).

%% a committed block at slot I with data D, its COMMIT cert (bound to the block) signed by the first K of C.
committed(I, D, C, K) ->
    committed_in(domain(C), I, D, C, K).

committed_in(Domain, I, D, C, K) ->
    committed_batch_in(Domain, I, [D], C, K).

committed_batch(I, Transactions, C, K) ->
    committed_batch_in(domain(C), I, Transactions, C, K).

committed_batch_in(Domain, I, Transactions, C, K) ->
    Data = {batch, Transactions},
    {ok, Block} = quod_ledger:new_block(I, I - 1, Data, 0),
    BH = quod_simplex:block_hash(Block),
    Shares = [quod_simplex:make_share(Domain, commit, I, BH, signer(M))
              || M <- lists:sublist(C, K)],
    {ok, Cert} = quod_simplex:form_cert(Domain, commit, I, BH, Shares, pubs(C)),
    quod_ledger:entry(Block, Cert).

%% like committed/4 but with an explicit (nonzero) block time on BOTH the hashed block and the entry —
%% exercises the timestamp threading that committed/4 leaves at the 0 default.
committed_at(I, D, Ts, C, K) ->
    Domain = domain(C),
    {ok, Block} = quod_ledger:new_block(
                    I, I - 1, {batch, [D]}, Ts),
    BH = quod_simplex:block_hash(Block),
    Shares = [quod_simplex:make_share(Domain, commit, I, BH, signer(M))
              || M <- lists:sublist(C, K)],
    {ok, Cert} = quod_simplex:form_cert(Domain, commit, I, BH, Shares, pubs(C)),
    quod_ledger:entry(Block, Cert).

%% a complaint-SKIPPED slot I with a COMPLAINT cert (block_hash=none) signed by the first K of C.
skipped(I, C, K) ->
    Domain = domain(C),
    Shares = [quod_simplex:make_share(Domain, complaint, I, none, signer(M))
              || M <- lists:sublist(C, K)],
    {ok, Cert} = quod_simplex:form_cert(Domain, complaint, I, none, Shares, pubs(C)),
    quod_ledger:noop_entry(I, Cert).

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

%%%--- tests ---

%% A valid genesis + committed blocks verifies, and the folded committee is the founding set.
happy_test() ->
    C = committee(4), P = pubs(C),
    Chain = [genesis(P), committed(2, tx(2, C), C, 3), committed(3, tx(3, C), C, 4)],
    {ok, [_, _, _], Final} = verify_chain(C, [], 1, Chain),
    ?assertEqual(P, Final).

%% The same checked history fold serves catch-up and restart. A committee at
%% the shared limit verifies; an oversized founding set and an otherwise-valid,
%% old-committee-certified 64 -> 65 admission are both refused.
validator_cap_history_boundary_test() ->
    N = ?MAX_VALIDATORS,
    Capped = committee(N),
    CappedPubs = pubs(Capped),
    ?assertMatch(
       {ok, [_], CappedPubs},
       verify_chain(Capped, [], 1, [genesis(CappedPubs)])),
    Oversized = committee(N + 1),
    OversizedGenesis = oversized_genesis(pubs(Oversized)),
    ?assertEqual(
       {error, {invalid_transaction, 1}},
       quod_catchup:verify_forward(
         ?NS, gen_hash(OversizedGenesis), quod_simplex:history_projection(),
         1, [OversizedGenesis])),
    {ExtraPub, _} = quod_identity:generate(),
    CertifiedAdmission = committed(
                           2, admit_tx(ExtraPub, Capped), Capped,
                           quod_simplex:quorum(N)),
    ?assertEqual(
       {error, {invalid_transaction, 2}},
       verify_chain(
         Capped, [], 1, [genesis(CappedPubs), CertifiedAdmission])).

batch_hash_is_verified_test() ->
    C = committee(4), P = pubs(C),
    Batch = committed_batch(2, [tx(20, C), tx(21, C)], C, 3),
    ?assertMatch({ok, [_, _], _},
                 verify_chain(C, [], 1, [genesis(P), Batch])),
    %% Reordering transactions changes the certified block hash.
    ?assertEqual({error, {cert_mismatch, 2}},
                 verify_chain(
                   C, [], 1,
                   [genesis(P),
                    entry_with_data(
                      Batch, {batch, [tx(21, C), tx(20, C)]})])).

implicit_parent_commit_test() ->
    C = committee(4), P = pubs(C),
    Domain = domain(C),
    ParentData = {batch, [tx(2, C)]},
    {ok, ParentBlock} = quod_ledger:new_block(2, 1, ParentData, 0),
    ParentBH = quod_simplex:block_hash(ParentBlock),
    SupportShares = [quod_simplex:make_share(Domain, support, 2, ParentBH, signer(M))
                     || M <- lists:sublist(C, 3)],
    {ok, Support} =
        quod_simplex:form_cert(Domain, support, 2, ParentBH, SupportShares, P),
    ChildData = {batch, [tx(3, C)]},
    {ok, Child} = quod_ledger:new_block(3, 2, ChildData, 0),
    ChildBH = quod_simplex:block_hash(Child),
    CommitShares = [quod_simplex:make_share(Domain, commit, 3, ChildBH, signer(M))
                    || M <- lists:sublist(C, 3)],
    {ok, Commit} =
        quod_simplex:form_cert(Domain, commit, 3, ChildBH, CommitShares, P),
    E2 = quod_ledger:entry(
           ParentBlock,
           #implicit_cert{support = Support, child = Child, commit = Commit}),
    E3 = quod_ledger:entry(Child, Commit),
    ?assertMatch({ok, [_, _, _], _},
                 verify_chain(C, [], 1, [genesis(P), E2, E3])),
    ?assertEqual({error, {bad_implicit_cert, 2}},
                 verify_chain(
                   C, [], 1,
                   [genesis(P),
                    entry_with_data(E2, {batch, [tx(99, C)]}), E3])).

%% A DTX control is an explicit-finality barrier even though it carries no
%% committee diff. It cannot be smuggled in as the child proof that implicitly
%% finalizes an ordinary parent.
implicit_dtx_child_is_rejected_test() ->
    C = committee(4),
    P = pubs(C),
    Domain = domain(C),
    ParentData = {batch, [tx(2, C)]},
    {ok, Parent} = quod_ledger:new_block(2, 1, ParentData, 0),
    ParentBH = quod_simplex:block_hash(Parent),
    SupportShares =
        [quod_simplex:make_share(Domain, support, 2, ParentBH, signer(M))
         || M <- lists:sublist(C, 3)],
    {ok, Support} = quod_simplex:form_cert(
                      Domain, support, 2, ParentBH, SupportShares, P),
    DtxData = quod_ct:dtx_decision_payload(),
    {ok, Child} = quod_ledger:new_block(3, 2, DtxData, 0),
    ChildBH = quod_simplex:block_hash(Child),
    CommitShares =
        [quod_simplex:make_share(Domain, commit, 3, ChildBH, signer(M))
         || M <- lists:sublist(C, 3)],
    {ok, Commit} = quod_simplex:form_cert(
                     Domain, commit, 3, ChildBH, CommitShares, P),
    E2 = quod_ledger:entry(
           Parent,
           #implicit_cert{support = Support, child = Child,
                          commit = Commit}),
    ?assertEqual(
       {error, {cert_mismatch, 2}},
       verify_chain(C, [], 1, [genesis(P), E2])).

%% A complaint-skipped slot (noop + complaint cert) is accepted between committed blocks.
skip_test() ->
    C = committee(4), P = pubs(C),
    ?assertMatch({ok, [_, _, _], _},
                 verify_chain(
                   C, [], 1,
                   [genesis(P), skipped(2, C, 3),
                    committed(3, tx(3, C), C, 3)])).

%% Nonzero block timestamps ride inside the cert-bound hash: a chain with real timestamps verifies, and an
%% entry whose stored timestamp differs from the one its cert signed is rejected on block_hash reconstruction.
timestamped_test() ->
    C = committee(4), P = pubs(C),
    Good = [genesis(P), committed_at(2, tx(2, C), 1750000000000, C, 3),
                        committed_at(3, tx(3, C), 1750000000500, C, 4)],
    ?assertMatch({ok, [_, _, _], _}, verify_chain(C, [], 1, Good)),
    %% tamper the stored timestamp while keeping the cert (signed over the original Ts) ⇒ block_hash mismatch
    [G, E2, E3] = Good,
    ?assertMatch({error, _},
                 verify_chain(
                   C, [], 1,
                   [G, E2#entry{timestamp = 1750000009999}, E3])).

%% A complaint cert (proves "skip slot I") attached to a #transaction is REJECTED — it authorizes no payload.
complaint_over_tx_rejected_test() ->
    C = committee(4), {X, _} = quod_identity:generate(),
    Skipped = skipped(2, C, 3),
    Forged = entry_with_data(Skipped, {batch, [admit_tx(X, C)]}),
    ?assertEqual({error, {cert_mismatch, 2}},
                 verify_chain(C, [], 1, [genesis(pubs(C)), Forged])).

%% A cert signed by NON-committee members fails the ⅔ check.
bad_cert_test() ->
    C = committee(4), Outsiders = committee(4),
    Bad = committed_in(domain(C), 2, tx(2, C), Outsiders, 3),
    ?assertEqual({error, {bad_cert, 2}},
                 verify_chain(C, [], 1, [genesis(pubs(C)), Bad])).

%% A non-genesis entry with no cert is rejected (a committed slot MUST carry its proof).
missing_cert_test() ->
    C = committee(4), B2 = committed(2, tx(2, C), C, 3),
    ?assertEqual({error, {missing_cert, 2}},
                 verify_chain(
                   C, [], 1, [genesis(pubs(C)), B2#entry{cert = none}])).

%% A cert that does not BIND the block (the entry's data was swapped) is rejected on block_hash.
cert_mismatch_test() ->
    C = committee(4), B2 = committed(2, tx(2, C), C, 3),
    ?assertEqual({error, {cert_mismatch, 2}},
                 verify_chain(
                   C, [], 1,
                   [genesis(pubs(C)),
                    entry_with_data(B2, {batch, [tx(99, C)]})])).

%% A MALFORMED cert (non-list sigs from a hostile server) is rejected, never crashes the joiner.
malformed_cert_rejected_test() ->
    C = committee(4), B2 = committed(2, tx(2, C), C, 3),
    Bad = B2#entry{cert = (B2#entry.cert)#cert{sigs = not_a_list}},
    ?assertEqual({error, {bad_cert, 2}},
                 verify_chain(C, [], 1, [genesis(pubs(C)), Bad])),
    [First | _] = (B2#entry.cert)#cert.sigs,
    Improper = B2#entry{cert = (B2#entry.cert)#cert{sigs = [First | bad_tail]}},
    ?assertEqual({error, {bad_cert, 2}},
                 verify_chain(C, [], 1, [genesis(pubs(C)), Improper])).

%% A GAP (a dropped intermediate entry) is rejected — the fold must be complete + contiguous, so a server
%% cannot omit a committee-changing block to shift verification onto a stale committee.
noncontiguous_rejected_test() ->
    C = committee(4), P = pubs(C),
    ?assertMatch({error, {noncontiguous, 2, 3}},
                 verify_chain(
                   C, [], 1, [genesis(P), committed(3, tx(3, C), C, 3)])),   %% dropped 2
    %% a window that doesn't start at the requested From is likewise rejected
    ?assertMatch({error, {noncontiguous, 5, 2}},
                 verify_chain(C, P, 5, [committed(2, tx(2, C), C, 3)])).

%% A non-#entry element from a hostile server is rejected, not crashed.
malformed_entry_rejected_test() ->
    C = committee(4),
    ?assertMatch({error, {malformed_entry, 2}},
                 verify_chain(
                   C, [], 1, [genesis(pubs(C)), {not_an_entry, 2}])),
    B2 = committed(2, tx(2, C), C, 3),
    ?assertEqual({error, {malformed_entry, 2}},
                 verify_chain(
                   C, [], 1,
                   [genesis(pubs(C)),
                    B2#entry{data = {batch, [tx(2, C) | bad_tail]}}])),
    BadTx = (tx(2, C))#transaction{diff = [not_an_operation]},
    ?assertEqual({error, {malformed_entry, 2}},
                 verify_chain(
                   C, [], 1,
                   [genesis(pubs(C)),
                    B2#entry{data = {batch, [BadTx]}}])),
    ?assertEqual({error, {malformed_entry, 2}},
                 verify_chain(C, [], 1, [genesis(pubs(C)) | bad_tail])).

%% Complaint skips have no block timestamp. Letting a certified `noop` carry an arbitrary
%% value would raise the restart timestamp floor and could freeze future proposals.
skip_timestamp_must_be_zero_test() ->
    C = committee(4),
    Bad = (skipped(2, C, 3))#entry{timestamp = 9999999999999},
    ?assertEqual({error, {cert_mismatch, 2}},
                 verify_chain(C, [], 1, [genesis(pubs(C)), Bad])).

%% A mid-chain window: the caller threads Committee0 (as of From>1); no genesis in the window.
midchain_window_test() ->
    C = committee(4), P = pubs(C),
    ?assertMatch({ok, [_, _], P},
                 verify_chain(
                   C, P, 5,
                   [committed(5, tx(5, C), C, 3),
                    committed(6, tx(6, C), C, 4)])).

%% A committee-changing block is verified under the OLD set; the NEXT block must meet the GROWN set's quorum.
committee_grows_test() ->
    C4 = committee(4), P4 = pubs(C4),
    {P5, _} = New = quod_identity:generate(),
    C5 = C4 ++ [New],
    Domain = domain(C4),
    Chain = [genesis(P4),
             committed(2, admit_tx(P5, C4), C4, 3),
             committed_in(Domain, 3, tx(3, C4), C5, 4)],
    {ok, _, Final} = verify_chain(C4, [], 1, Chain),
    ?assertEqual(lists:usort([P5 | P4]), Final).

%% The SAME chain but the post-change block is signed only by the OLD set (3 sigs) is REJECTED — it must meet
%% the GROWN committee's quorum (5-set, quorum 4). This is exactly the stale-committee cert a lagging node
%% might persist (S1 finding #2): a trustless joiner refuses it.
committee_grows_rejects_stale_test() ->
    C4 = committee(4), P4 = pubs(C4),
    {P5, _} = quod_identity:generate(),
    Chain = [genesis(P4), committed(2, admit_tx(P5, C4), C4, 3), committed(3, tx(3, C4), C4, 3)],
    ?assertEqual({error, {bad_cert, 3}}, verify_chain(C4, [], 1, Chain)).

%% A committee SHRINK (retract peer_admitted): the removed member is dropped, and the next block is verified
%% against the smaller set.
committee_shrinks_test() ->
    C5 = committee(5), P5 = pubs(C5),
    {Author, _} = author(),
    Gone = hd(P5 -- [Author]),
    C4 = [M || {Pk, _} = M <- C5, Pk =/= Gone],
    Domain = domain(C5),
    Chain = [genesis(P5),
             committed(2, remove_tx(Gone, C5), C5, 4),
             committed_in(Domain, 3, tx(3, C5), C4, 3)],
    {ok, _, Final} = verify_chain(C5, [], 1, Chain),
    ?assertEqual(lists:usort(P5 -- [Gone]), Final).

%% A cert is valid only in the exact namespace/genesis domain that produced it.
%% Keeping committee, kind, slot and block hash identical proves this is domain
%% rejection rather than a quorum or content mismatch.
explicit_cross_domain_rejected_test() ->
    C = committee(4),
    P = pubs(C),
    G = genesis(P),
    GH = genesis_hash(C),
    OtherNsDomain =
        quod_simplex:consensus_domain(<<"other:ontology">>, GH),
    OtherGenesisDomain =
        quod_simplex:consensus_domain(?NS, crypto:hash(sha256, <<"other genesis">>)),
    [begin
         Entry = committed_in(WrongDomain, 2, tx(2, C), C, 3),
         ?assertEqual(
            {error, {bad_cert, 2}},
            quod_catchup:verify_forward(
              ?NS, GH, quod_simplex:history_projection(), 1, [G, Entry]))
     end
     || WrongDomain <- [OtherNsDomain, OtherGenesisDomain]],
    ok.

empty_namespace_is_rejected_test() ->
    C = committee(4),
    ?assertEqual(
       {error, bad_anchor},
       quod_catchup:verify_forward(
         <<>>, genesis_hash(C), quod_simplex:history_projection(),
         1, [genesis(pubs(C))])).

%% The same domain rule applies to both certificates inside an implicit proof:
%% the parent's support cert and its child's commit cert.
implicit_cross_domain_rejected_test() ->
    C = committee(4),
    P = pubs(C),
    G = genesis(P),
    GH = genesis_hash(C),
    OtherNsDomain =
        quod_simplex:consensus_domain(<<"other:ontology">>, GH),
    OtherGenesisDomain =
        quod_simplex:consensus_domain(?NS, crypto:hash(sha256, <<"other genesis">>)),
    [begin
         {E2, E3} = implicit_entries(WrongDomain, C),
         ?assertEqual(
            {error, {bad_implicit_cert, 2}},
            quod_catchup:verify_forward(
              ?NS, GH, quod_simplex:history_projection(), 1, [G, E2, E3]))
     end
     || WrongDomain <- [OtherNsDomain, OtherGenesisDomain]],
    ok.

implicit_entries(Domain, C) ->
    P = pubs(C),
    ParentTx = tx(2, C),
    {ok, Parent} = quod_ledger:new_block(
                     2, 1, {batch, [ParentTx]}, 0),
    ParentBH = quod_simplex:block_hash(Parent),
    SupportShares =
        [quod_simplex:make_share(Domain, support, 2, ParentBH, signer(M))
         || M <- lists:sublist(C, 3)],
    {ok, Support} =
        quod_simplex:form_cert(
          Domain, support, 2, ParentBH, SupportShares, P),
    ChildTx = tx(3, C),
    {ok, Child} = quod_ledger:new_block(
                    3, 2, {batch, [ChildTx]}, 0),
    ChildBH = quod_simplex:block_hash(Child),
    CommitShares =
        [quod_simplex:make_share(Domain, commit, 3, ChildBH, signer(M))
         || M <- lists:sublist(C, 3)],
    {ok, Commit} =
        quod_simplex:form_cert(
          Domain, commit, 3, ChildBH, CommitShares, P),
    {quod_ledger:entry(
       Parent,
       #implicit_cert{support = Support, child = Child, commit = Commit}),
     quod_ledger:entry(Child, Commit)}.

%%%--- catch_up/4 driver (mocked Fetch/Sink — no transport/store) ---

%% a Fetch serving a pre-built Chain (entries 1..H) in windows of W; From > H ⇒ empty.
mock_fetch(Chain, W) ->
    H = length(Chain),
    fun(From) when From > H -> {ok, [], H};
       (From)               -> {ok, lists:sublist(Chain, From, W), H}
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
    Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
    #{ledger_root => filename:join(
                        "/tmp", "quod_catchup_verify_" ++ Unique)}.

run_catch_up(GenesisHash, Fetch, Sink) ->
    quod_catchup:catch_up(
      ?NS, GenesisHash, Fetch, Sink, catchup_options()).

%% the out-of-band-pinned genesis anchor = block_hash of the genesis block.
gen_hash(#entry{index = 1, data = D}) ->
    {ok, Transactions} = quod_ledger:payload(D),
    {ok, Block} = quod_ledger:new_block(
                    1, 0, {batch, Transactions}, 0),
    quod_simplex:block_hash(Block).

%% The driver loops windowed fetches, verifies each, sinks the verified entries in order, and reports the
%% caught-up height.
catch_up_happy_test() ->
    C = committee(4), P = pubs(C), G = genesis(P),
    Chain = [G, committed(2, tx(2, C), C, 3), committed(3, tx(3, C), C, 4)],
    Sink = sink(),
    ?assertEqual({ok, 3}, run_catch_up(gen_hash(G), mock_fetch(Chain, 2), Sink)),   %% windows of 2
    ?assertEqual(Chain, sunk()).                                                             %% all, in order

%% A genesis whose CONTENT (here, committee) differs from the pinned genesis hash is rejected (forged anchor).
catch_up_bad_anchor_test() ->
    C = committee(4), Fake = committee(4),
    Chain = [genesis(pubs(Fake))],
    ?assertEqual({error, bad_anchor},
                 run_catch_up(
                   gen_hash(genesis(pubs(C))), mock_fetch(Chain, 10),
                   fun(_, _) -> ok end)).

%% A window that fails verification aborts catch-up, and NOTHING is persisted (the whole window is atomic).
catch_up_forged_test() ->
    C = committee(4), Outsiders = committee(4), G = genesis(pubs(C)),
    Chain = [G, committed_in(domain(C), 2, tx(2, C), Outsiders, 3)],
    Sink = sink(),
    ?assertMatch({error, {verify, {bad_cert, 2}}},
                 run_catch_up(gen_hash(G), mock_fetch(Chain, 10), Sink)),
    ?assertEqual([], sunk()).   %% the bad window is never sunk

%% A committee change in window 1 is threaded so window 2 verifies against the GROWN set.
catch_up_committee_change_across_windows_test() ->
    C4 = committee(4), P4 = pubs(C4), G = genesis(P4),
    {P5, _} = New = quod_identity:generate(), C5 = C4 ++ [New],
    Domain = domain(C4),
    B2 = committed(2, admit_tx(P5, C4), C4, 3),   %% grows the committee, in window 1
    B3 = committed_in(Domain, 3, tx(3, C4), C5, 4), %% window 2, needs the 5-set quorum
    Sink  = sink(),
    Fetch = fun(1) -> {ok, [G, B2], 3}; (3) -> {ok, [B3], 3}; (_) -> {ok, [], 3} end,
    ?assertEqual({ok, 3}, run_catch_up(gen_hash(G), Fetch, Sink)),
    ?assertEqual([G, B2, B3], sunk()).

%% A contact that REGRESSES its claimed height below what it already served is treated as stalled (the target
%% is the MAX height seen), not falsely "caught up" — so the joiner fails over instead of truncating.
catch_up_height_regression_test() ->
    C = committee(4), P = pubs(C), G = genesis(P), B2 = committed(2, tx(2, C), C, 3),
    Fetch = fun(1) -> {ok, [G, B2], 100};   %% claims height 100
               (_) -> {ok, [], 5}           %% then regresses to 5, mid-catch-up
            end,
    ?assertEqual({error, no_progress}, run_catch_up(gen_hash(G), Fetch, sink())).

%% A fetch failure surfaces so the caller can try another contact.
catch_up_fetch_error_test() ->
    ?assertEqual({error, {fetch, timeout}},
                 run_catch_up(
                   <<0:256>>, fun(_) -> {error, timeout} end,
                   fun(_, _) -> ok end)).

catch_up_malformed_height_test() ->
    ?assertEqual({error, {fetch, bad_response}},
                 run_catch_up(
                   <<0:256>>, fun(_) -> {ok, [], not_a_height} end,
                   fun(_, _) -> ok end)).

%% A sink failure aborts catch-up cleanly (recoverable), not a badmatch crash.
catch_up_sink_error_test() ->
    C = committee(4), P = pubs(C), G = genesis(P),
    Chain = [G, committed(2, tx(2, C), C, 3)],
    ?assertEqual({error, {sink, disk_full}},
                 run_catch_up(
                   gen_hash(G), mock_fetch(Chain, 10),
                   fun(_, _) -> {error, disk_full} end)).

%% A server that returns empty while claiming more height is stuck — reported, not looped forever.
catch_up_no_progress_test() ->
    ?assertEqual({error, no_progress},
                 run_catch_up(
                   <<0:256>>, fun(_) -> {ok, [], 5} end,
                   fun(_, _) -> ok end)).
