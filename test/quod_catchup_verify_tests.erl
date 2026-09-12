-module(quod_catchup_verify_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").

%% Counted suffix-only control: real signed entries and retained writer index,
%% NOT a live consensus-admitted multiwrite campaign. The unchanged-source
%% baseline and its original probe are frozen separately in the handoff.
-export([history_replay_baseline_probe/0]).

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
    Entry0 = genesis(Founding),
    #entry{data = {batch, [Tx0]}} = quod_ledger:entry_view(Entry0),
    ExtraAdmission =
        {assert, {{peer_admitted, Extra, undefined, undefined, Extra}, true}},
    Tx1 = Tx0#transaction{diff = Tx0#transaction.diff ++ [ExtraAdmission]},
    entry_with_data(Entry0, {batch, [Tx1]}).

entry_with_data(Entry, Data) ->
    #entry{index = Index, timestamp = Timestamp, cert = Cert} =
        quod_ledger:entry_view(Entry),
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
    {ok, Chain, Final} = verify_chain(C, [], 1, Chain),
    ?assertEqual(P, Final).

canonical_page_artifacts_survive_verify_and_forward_test() ->
    C = committee(4), P = pubs(C),
    Chain = [genesis(P), committed(2, tx(2, C), C, 3)],
    Blobs = [begin {ok, Bytes} = quod_ledger:encode_entry(E), Bytes end || E <- Chain],
    {ok, Chain, P} = verify_chain(C, [], 1, Chain),
    %% The verifier returns precisely its input artifacts. Sizing and feed
    %% forwarding consume those same objects, not rebuilt semantic records.
    ?assertEqual({ok, 2, lists:sum([byte_size(B) || B <- Blobs])},
                 quod_catchup:page_stats(Chain)),
    lists:foreach(fun({Entry, Bytes}) ->
        Frame = quod_feed:encode(?NS, {block, Entry}),
        {feed, ?NS, Inner} = binary_to_term(Frame, [safe]),
        ?assertEqual({block_bytes, Bytes}, binary_to_term(Inner, [safe])),
        ?assertEqual({block, Entry}, quod_feed:decode(Frame, ?NS))
    end, lists:zip(Chain, Blobs)),
    ?assertEqual({ok, Chain}, quod_catchup:decode_entries(Blobs, materialized)).

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
    [_, E2, _] = Good,
    View = quod_ledger:entry_view(E2),
    ?assertEqual({error, bad_entry},
                 quod_ledger:from_entry_view(
                   View#entry{timestamp = 1750000009999})).

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
    {ok, Block} = quod_ledger:block_from_entry(B2),
    ?assertEqual({error, {missing_cert, 2}},
                 verify_chain(
                   C, [], 1, [genesis(pubs(C)), quod_ledger:entry(Block, none)])).

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
    View = quod_ledger:entry_view(B2),
    Cert = View#entry.cert,
    [First | _] = Cert#cert.sigs,
    lists:foreach(fun(Sigs) ->
        Bad = View#entry{cert = Cert#cert{sigs = Sigs}},
        %% Canonical envelope construction grants no finality. A malformed
        %% certificate must still be refused by the existing forward verifier.
        {ok, Artifact} = quod_ledger:from_entry_view(Bad),
        ?assertEqual({error, {bad_cert, 2}},
                     verify_chain(C, [], 1, [genesis(pubs(C)), Artifact]))
    end, [not_a_list, [First | bad_tail]]).

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

%% A non-artifact element is refused; corrupted views fail at checked import.
malformed_entry_rejected_test() ->
    C = committee(4),
    ?assertMatch({error, {malformed_entry, 2}},
                 verify_chain(
                   C, [], 1, [genesis(pubs(C)), {not_an_entry, 2}])),
    B2 = committed(2, tx(2, C), C, 3),
    View = quod_ledger:entry_view(B2),
    ?assertEqual({error, bad_entry},
                 quod_ledger:from_entry_view(
                   View#entry{data = {batch, [tx(2, C) | bad_tail]}})),
    BadTx = (tx(2, C))#transaction{diff = [not_an_operation]},
    ?assertEqual({error, bad_entry},
                 quod_ledger:from_entry_view(
                   View#entry{data = {batch, [BadTx]}})),
    ?assertEqual({error, {malformed_entry, 2}},
                 verify_chain(C, [], 1, [genesis(pubs(C)) | bad_tail])).

%% Complaint skips have no block timestamp. Letting a certified `noop` carry an arbitrary
%% value would raise the restart timestamp floor and could freeze future proposals.
skip_timestamp_must_be_zero_test() ->
    C = committee(4),
    View = quod_ledger:entry_view(skipped(2, C, 3)),
    Bad = View#entry{timestamp = 9999999999999},
    ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view(Bad)).

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

%%%--- catch_up/7 driver (mocked transport, real writer snapshots) ---

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
        {ok, Store} = quod_ledger_store:append(Empty, Prefix),
        put(Key, Store),
        Identity = {?NS, GenesisHash},
        Projection0 = quod_simplex:history_projection(Identity),
        Projection = case Prefix of
            [] -> Projection0;
            _ ->
                {ok, Prefix, VerifiedProjection, Delta} = quod_catchup:verify_forward(
                    ?NS, GenesisHash, Projection0, 1, Prefix, Index),
                ok = quod_dtx_phase_index:commit_delta(Index, Delta),
                VerifiedProjection
        end,
        View = sink_view(Store, Identity, Projection, Index),
        DurableSink = fun(Entries, Projection1, Delta1) ->
            case Sink(Entries, Projection1) of
                ok ->
                    {ok, Next} = quod_ledger_store:append(get(Key), Entries),
                    put(Key, Next),
                    ok = quod_dtx_phase_index:commit_delta(Index, Delta1),
                    {ok, sink_view(Next, Identity, Projection1, Index)};
                {error, _} = Error -> Error
            end
        end,
        Fun(DurableSink, View, Options)
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
    C = committee(4), G = genesis(pubs(C)), GH = gen_hash(G),
    Prefix = [G | [skipped(I, C, 3) || I <- lists:seq(2, 257)]],
    Finalize = direct_abort_entry(258, C),
    Chain = Prefix ++ [Finalize],
    %% The first DTX control arrives after successful content-only sink turns;
    %% it uses the read-only index returned with the preceding sink.
    ?assertEqual({ok, 258}, run_catch_up(GH, mock_fetch(Chain, 128), sink())),
    ?assertEqual(Chain, sunk()).

resumed_phase_window_uses_initial_owner_capture_test() ->
    C = committee(4), G = genesis(pubs(C)), GH = gen_hash(G),
    Prefix = [G | [skipped(I, C, 3) || I <- lists:seq(2, 257)]],
    Finalize = direct_abort_entry(258, C),
    with_disk_sink(GH, Prefix, sink(),
      fun(Sink, View = #{projection := Projection}, Options) ->
          ?assertEqual({ok, 258}, quod_catchup:catch_up(
              ?NS, GH, mock_fetch(Prefix ++ [Finalize], 128), Sink,
              258, Projection, Options#{history_view => View})),
          ?assertEqual([Finalize], sunk()),
          ?assertEqual({error, bad_catchup_options}, quod_catchup:catch_up(
              ?NS, GH, fun(_) -> error(mismatched_view_fetched) end, Sink,
              258, Projection, Options#{history_view => View#{slot => 256}}))
      end).

history_suffix_only_work_is_counted_test() ->
    lists:foreach(fun(Counts) ->
        ?assertEqual(0, maps:get(prefix_entries_read, Counts)),
        ?assertEqual(0, maps:get(prefix_entries_reverified, Counts)),
        ?assertEqual(1, maps:get(suffix_entries_verified, Counts))
    end, history_replay_baseline_probe()).

history_replay_baseline_probe() ->
    [{module, M} = code:ensure_loaded(M)
     || M <- [quod_catchup, quod_ledger_store]],
    MFAs = [{{quod_catchup, verify_forward, 5}, [local]},
            {{quod_catchup, verify_forward, 6}, [local]},
            {{quod_ledger_store, read_range, 3}, []}],
    lists:foreach(fun({MFA, Flags}) ->
        1 = erlang:trace_pattern(MFA, true, Flags)
    end, MFAs),
    try
        [history_replay_baseline_case(Height, Kind)
         || Height <- [8, 64, 257], Kind <- [noop, dtx]]
    after
        lists:foreach(fun({MFA, Flags}) ->
            erlang:trace_pattern(MFA, false, Flags)
        end, MFAs)
    end.

history_replay_baseline_case(Height, Kind) ->
    Parent = self(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        try
            C = committee(4), G = genesis(pubs(C)), GH = gen_hash(G),
            Prefix = [G | [skipped(I, C, 3) || I <- lists:seq(2, Height)]],
            Last = case Kind of
                noop -> skipped(Height + 1, C, 3);
                dtx -> direct_abort_entry(Height + 1, C)
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
        {trace, Worker, call, {quod_ledger_store, read_range, [_Store, From, To]}} ->
            N = max(0, min(To, Height) - From + 1),
            history_probe_trace(Worker, Barrier, Height,
                maps:update_with(prefix_entries_read, fun(V) -> V + N end, Counts));
        {trace, Worker, call, {quod_catchup, verify_forward,
                              [_Ns, _GH, _Projection, From, Entries | _Rest]}} ->
            N = max(0, min(length(Entries), Height - From + 1)),
            C1 = maps:update_with(prefix_entries_reverified, fun(V) -> V + N end, Counts),
            C2 = maps:update_with(suffix_entries_verified,
                                 fun(V) -> V + length(Entries) - N end, C1),
            history_probe_trace(Worker, Barrier, Height, C2);
        {trace_delivered, Worker, Barrier} -> Counts
    after 10000 -> error(history_probe_trace_barrier_stalled)
    end.

direct_abort_entry(Slot, C) ->
    Target = {?NS, genesis_hash(C)},
    {Pub, _} = author(),
    {ok, {?NS, _, Admission}} = quod_simplex:history_binding(
                                  Target, Pub, projection_after_genesis(C)),
    {ok, DecisionRef} = quod_dtx:certified_ref(
        <<"foreign-origin">>, <<60:256>>, 7, <<61:256>>, <<62:256>>, <<"qc">>),
    {ok, Record} = quod_dtx:new_finalize(<<63:256>>, DecisionRef, abort, none, 0),
    {ok, Control} = quod_dtx:sign_control(Target, Record, Admission, 1, 1,
                                         signer(author())),
    {ok, Blob} = quod_dtx:encode_control(Control),
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, {batch, [{dtx, Blob}]}, 0),
    Hash = quod_simplex:block_hash(Block),
    Shares = [quod_simplex:make_share(domain(C), commit, Slot, Hash, signer(M))
              || M <- lists:sublist(C, 3)],
    {ok, Cert} = quod_simplex:form_cert(domain(C), commit, Slot, Hash, Shares, pubs(C)),
    quod_ledger:entry(Block, Cert).

%% the out-of-band-pinned genesis anchor = block_hash of the genesis block.
gen_hash(Entry) ->
    #entry{index = 1} = quod_ledger:entry_view(Entry),
    {ok, Block} = quod_ledger:block_from_entry(Entry),
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

catch_up_real_writer_current_era_view_preserves_verifier_history_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    C4 = committee(4), G = genesis(pubs(C4)), GH = gen_hash(G),
    {P5, _} = New = quod_identity:generate(), C5 = C4 ++ [New],
    B2 = committed(2, admit_tx(P5, C4), C4, 3),
    B3 = committed_in(domain(C4), 3, tx(3, C4), C5, 4),
    Options = #{ledger_root := Scratch} = catchup_options(),
    LedgerRoot = Scratch ++ "-writer",
    StateKey = make_ref(), ViewsKey = make_ref(),
    try
        {ok, Store} = quod_ledger_store:open(?NS, LedgerRoot),
        {ok, Index} = quod_dtx_phase_index:open(LedgerRoot, ?NS),
        try
            %% Use the actual sink callback and its actual same-turn capture,
            %% not the disk fixture's handwritten echo of the input projection.
            State0 = quod_simplex:test_state(
                       #{ns => ?NS, genesis_hash => GH,
                         consensus_domain => domain(C4), store => Store, phase_index => Index,
                         eng => quod_simplex:eng_with_certs(0, []),
                         sync => {pulling, self()}}),
            put(StateKey, State0),
            put(ViewsKey, []),
            Sink = fun(Entries, VerifiedProjection, Delta) ->
                From = {self(), make_ref()},
                {keep_state, State1, Actions} = quod_simplex:running(
                    {call, From},
                    {sink_catchup, {recovery, self()}, Entries, VerifiedProjection, Delta},
                    get(StateKey)),
                put(StateKey, State1),
                [{reply, From, {ok, View}}] =
                    [A || {reply, F, _} = A <- Actions, F =:= From],
                put(ViewsKey, [{VerifiedProjection, View} | get(ViewsKey)]),
                {ok, View}
            end,
            Fetch = fun(1) -> {ok, [G, B2], 3};
                       (3) -> {ok, [B3], 3}
                    end,
            InitialView = #{projection := InitialProjection} = sink_view(
                Store, {?NS, GH}, quod_simplex:history_projection({?NS, GH}), Index),
            ?assertEqual({ok, 3}, quod_catchup:catch_up(
                ?NS, GH, Fetch, Sink, 1, InitialProjection,
                Options#{history_view => InitialView})),
            [{Verified2, View2}, {Verified3, View3}] = lists:reverse(get(ViewsKey)),
            ?assertEqual(2, length(maps:get(committee_views, Verified2))),
            ?assertEqual(1, length(maps:get(committee_views, Verified3))),
            lists:foreach(
              fun({Verified, #{owner := Owner, projection := Published}}) ->
                  ?assertEqual(self(), Owner),
                  ?assertEqual(1, length(maps:get(committee_views, Published))),
                  ?assertNotEqual(Verified, Published),
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
                         quod_ledger_store:read_range(DurableStore, 1, 3)),
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
        [_, _, Finalize] = maps:get(chain, F),
        #{projection := #{history_index := Capture} = Projection} = View,
        {ok, [Finalize], NextProjection, Delta} = quod_catchup:verify_forward(
            Ns, Anchor, Projection, 3, [Finalize], Capture),
        %% Another owner-applied window overtakes the verified borrow. The
        %% actual sink advances; the earlier view still hides this same-group
        %% Finalize. This is the production applier seam, not consensus admission.
        {ok, _} = Sink([Finalize], NextProjection, Delta),
        {ok, OldHistory} = quod_dtx_phase_index:history(Capture, maps:get(group_id, F)),
        ?assertEqual(not_found, quod_dtx:history_phase(finalize, OldHistory)),
        {ok, NewHistory} = quod_dtx_phase_index:history(Index, maps:get(group_id, F)),
        ?assertEqual({ok, maps:get(finalize_ref, F)}, quod_dtx:history_phase(finalize, NewHistory)),
        Installed = get(StateKey),
        IndexStats = quod_dtx_phase_index:stats(Index),
        ?assertEqual({error, stale_window}, Sink([Finalize], NextProjection, Delta)),
        ?assertEqual(Installed, get(StateKey)),
        ?assertEqual(IndexStats, quod_dtx_phase_index:stats(Index)),
        {3, Store} = quod_simplex:test_committed_store(Installed),
        ?assertEqual({ok, maps:get(chain, F)}, quod_ledger_store:read_range(Store, 1, 3))
    end).

catch_up_failed_append_leaves_retained_index_unchanged_test() ->
    with_phase_writer(fun(F, Index, Sink, View, StateKey) ->
        [_, _, Finalize] = maps:get(chain, F),
        #{projection := #{history_index := Capture} = Projection} = View,
        {ok, _, NextProjection, Delta} = quod_catchup:verify_forward(
            maps:get(ns, F), maps:get(anchor, F), Projection, 3, [Finalize], Capture),
        Installed = get(StateKey),
        Before = quod_dtx_phase_index:stats(Index),
        {2, Store} = quod_simplex:test_committed_store(Installed),
        ok = quod_ledger_store:close(Store),
        ?assertMatch({error, _}, Sink([Finalize], NextProjection, Delta)),
        ?assertEqual(Installed, get(StateKey)),
        ?assertEqual(Before, quod_dtx_phase_index:stats(Index)),
        {ok, History} = quod_dtx_phase_index:history(Index, maps:get(group_id, F)),
        ?assertEqual(not_found, quod_dtx:history_phase(finalize, History))
    end).

catch_up_index_install_failure_is_loud_before_any_publication_test() ->
    with_phase_writer(fun(F, Index, Sink, View, StateKey) ->
        Ns = maps:get(ns, F),
        [_, _, Finalize] = maps:get(chain, F),
        #{projection := #{history_index := Capture} = Projection} = View,
        {ok, _, NextProjection, Delta} = quod_catchup:verify_forward(
            Ns, maps:get(anchor, F), Projection, 3, [Finalize], Capture),
        true = quod_reg:reg({quod_prolog, Ns}),
        true = quod_reg:subscribe({committed, Ns}),
        try
            %% The actual table disappears after verification but before
            %% installation. Appending may succeed; publishing the old index
            %% or converting the failure to a recoverable sink reply may not.
            ok = quod_dtx_phase_index:close(Index),
            ?assertException(error, {badmatch, {error, {phase_index_io, _}}},
                             Sink([Finalize], NextProjection, Delta)),
            ?assertEqual([], writer_publications([])),
            {2, OldStore} = quod_simplex:test_committed_store(get(StateKey)),
            ok = quod_ledger_store:close(OldStore),
            {ok, Reopened} = quod_ledger_store:open(Ns, maps:get(root, F)),
            try
                ?assertEqual(3, quod_ledger_store:last(Reopened)),
                ?assertEqual({ok, Finalize}, quod_ledger_store:read_at(Reopened, 3))
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
    Ns = maps:get(ns, F), Anchor = maps:get(anchor, F),
    Root = quod_foreign_log_tests:temp_dir("catchup-owner-phase"),
    {ok, Store} = quod_ledger_store:open(Ns, Root),
    {ok, Index} = quod_dtx_phase_index:open(Root, Ns),
    StateKey = make_ref(),
    put(StateKey, quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
        consensus_domain => quod_simplex:consensus_domain(Ns, Anchor),
        store => Store, phase_index => Index, eng => quod_simplex:eng_with_certs(0, []),
        sync => {pulling, self()}})),
    Sink = fun(Entries, P, Delta) ->
        From = {self(), make_ref()},
        {keep_state, State, Actions} = quod_simplex:running({call, From},
            {sink_catchup, {recovery, self()}, Entries, P, Delta}, get(StateKey)),
        put(StateKey, State),
        [Reply] = [R || {reply, Who, R} <- Actions, Who =:= From],
        Reply
    end,
    try
        Prefix = lists:sublist(maps:get(chain, F), 2),
        {ok, Prefix, P, Delta} = quod_catchup:verify_forward(
            Ns, Anchor, quod_simplex:history_projection({Ns, Anchor}), 1, Prefix, Index),
        {ok, View} = Sink(Prefix, P, Delta),
        Fun(F#{root => Root}, Index, Sink, View, StateKey)
    after
        erase(StateKey),
        quod_dtx_phase_index:close(Index), quod_ledger_store:close(Store),
        _ = file:del_dir_r(Root)
    end.

catch_up_owner_death_during_empty_fetch_is_not_completion_test() ->
    C = committee(4), G = genesis(pubs(C)),
    with_disk_sink(gen_hash(G), [G], fun(_, _) -> error(unexpected_sink) end,
      fun(Sink, View = #{projection := Projection}, Options) ->
          {Owner, Monitor} = spawn_monitor(fun() -> receive stop -> ok end end),
          Fetch = fun(2) ->
              Owner ! stop,
              receive {'DOWN', Monitor, process, Owner, normal} -> ok end,
              {ok, [], 1}
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
                             eng => quod_simplex:eng_with_certs(0, []),
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
                %% the worker's real pull/4 call, not a test-owned parked loop.
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
        {'$gen_call', {Worker, _}, {pull, From, _To, _Contact, _Started}} ->
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
