-module(quod_catchup_verify_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%%%===================================================================
%%% quod_catchup:verify_forward/3 — the trustless catch-up trust core. A joiner replays a pulled chain by
%%% INDUCTION from the pinned genesis committee, verifying each entry's finalizing cert against the
%%% committee AS-OF-that-slot (folded forward from the peer_admitted facts). Trusts nothing but the certs.
%%%===================================================================

%%%--- helpers: build a real signed chain ---
committee(N) -> [quod_identity:generate() || _ <- lists:seq(1, N)].   %% [{Pubkey, Seed}]
pubs(C)      -> lists:usort([P || {P, _} <- C]).
signer({P, Seed}) -> #{pubkey => P, key => quod_identity:key_term({P, Seed})}.

%% slot 1: the self-signed genesis (no cert) asserting each founder's peer_admitted — establishes C1.
genesis(Pubs) ->
    Diff = [{assert, {{peer_admitted, Pk, undefined, undefined, Pk}, true}} || Pk <- Pubs],
    #entry{index = 1, term = 0, kind = block, cert = none,
           data = #transaction{tx_id = <<"genesis">>, caller_ns = <<"ns">>, diff = Diff,
                               read_check = #{}, author = hd(Pubs), sig = none}}.

%% a committed block at slot I with data D, its COMMIT cert (bound to the block) signed by the first K of C.
committed(I, D, C, K) ->
    BH     = quod_simplex:block_hash(#block{slot = I, parent = I - 1, payload = [D]}),
    Shares = [quod_simplex:make_share(commit, I, BH, signer(M)) || M <- lists:sublist(C, K)],
    {ok, Cert} = quod_simplex:form_cert(commit, I, BH, Shares, pubs(C)),
    #entry{index = I, term = 0, kind = block, data = D, cert = Cert}.

%% a leader committed an empty (noop) BLOCK — a COMMIT cert bound to the noop block, NOT a complaint.
committed_noop(I, C, K) -> committed(I, noop, C, K).

%% a complaint-SKIPPED slot I with a COMPLAINT cert (block_hash=none) signed by the first K of C.
skipped(I, C, K) ->
    Shares = [quod_simplex:make_share(complaint, I, none, signer(M)) || M <- lists:sublist(C, K)],
    {ok, Cert} = quod_simplex:form_cert(complaint, I, none, Shares, pubs(C)),
    #entry{index = I, term = 0, kind = block, data = noop, cert = Cert}.

tx(I)        -> #transaction{tx_id = integer_to_binary(I), caller_ns = <<"ns">>,
                             diff = [{assert, {{fact, I}, true}}], read_check = #{}, author = <<"a">>, sig = none}.
admit_tx(Pk) -> peer_tx(assert, Pk).
remove_tx(Pk) -> peer_tx(retract, Pk).
peer_tx(Op, Pk) -> #transaction{tx_id = <<"m">>, caller_ns = <<"ns">>,
                                diff = [{Op, {{peer_admitted, Pk, undefined, undefined, Pk}, true}}],
                                read_check = #{}, author = <<"a">>, sig = none}.

%%%--- tests ---

%% A valid genesis + committed blocks verifies, and the folded committee is the founding set.
happy_test() ->
    C = committee(4), P = pubs(C),
    Chain = [genesis(P), committed(2, tx(2), C, 3), committed(3, tx(3), C, 4)],
    {ok, [_, _, _], Final} = quod_catchup:verify_forward([], 1, Chain),
    ?assertEqual(P, Final).

%% A complaint-skipped slot (noop + complaint cert) is accepted between committed blocks.
skip_test() ->
    C = committee(4), P = pubs(C),
    ?assertMatch({ok, [_, _, _], _},
                 quod_catchup:verify_forward([], 1, [genesis(P), skipped(2, C, 3), committed(3, tx(3), C, 3)])).

%% A committed noop BLOCK (a COMMIT cert, not a complaint) is accepted — a leader may propose an empty block.
committed_noop_block_test() ->
    C = committee(4), P = pubs(C),
    ?assertMatch({ok, [_, _, _], _},
                 quod_catchup:verify_forward([], 1, [genesis(P), committed_noop(2, C, 3), committed(3, tx(3), C, 3)])).

%% A complaint cert (proves "skip slot I") attached to a #transaction is REJECTED — it authorizes no payload.
complaint_over_tx_rejected_test() ->
    C = committee(4), {X, _} = quod_identity:generate(),
    Forged = (skipped(2, C, 3))#entry{data = admit_tx(X)},   %% real complaint cert, but a committee-changing tx
    ?assertEqual({error, {cert_mismatch, 2}}, quod_catchup:verify_forward([], 1, [genesis(pubs(C)), Forged])).

%% A cert signed by NON-committee members fails the ⅔ check.
bad_cert_test() ->
    C = committee(4), Outsiders = committee(4),
    Bad = committed(2, tx(2), Outsiders, 3),
    ?assertEqual({error, {bad_cert, 2}}, quod_catchup:verify_forward([], 1, [genesis(pubs(C)), Bad])).

%% A non-genesis entry with no cert is rejected (a committed slot MUST carry its proof).
missing_cert_test() ->
    C = committee(4), B2 = committed(2, tx(2), C, 3),
    ?assertEqual({error, {missing_cert, 2}},
                 quod_catchup:verify_forward([], 1, [genesis(pubs(C)), B2#entry{cert = none}])).

%% A cert that does not BIND the block (the entry's data was swapped) is rejected on block_hash.
cert_mismatch_test() ->
    C = committee(4), B2 = committed(2, tx(2), C, 3),
    ?assertEqual({error, {cert_mismatch, 2}},
                 quod_catchup:verify_forward([], 1, [genesis(pubs(C)), B2#entry{data = tx(99)}])).

%% A MALFORMED cert (non-list sigs from a hostile server) is rejected, never crashes the joiner.
malformed_cert_rejected_test() ->
    C = committee(4), B2 = committed(2, tx(2), C, 3),
    Bad = B2#entry{cert = (B2#entry.cert)#cert{sigs = not_a_list}},
    ?assertEqual({error, {bad_cert, 2}}, quod_catchup:verify_forward([], 1, [genesis(pubs(C)), Bad])).

%% A GAP (a dropped intermediate entry) is rejected — the fold must be complete + contiguous, so a server
%% cannot omit a committee-changing block to shift verification onto a stale committee.
noncontiguous_rejected_test() ->
    C = committee(4), P = pubs(C),
    ?assertMatch({error, {noncontiguous, 2, 3}},
                 quod_catchup:verify_forward([], 1, [genesis(P), committed(3, tx(3), C, 3)])),   %% dropped 2
    %% a window that doesn't start at the requested From is likewise rejected
    ?assertMatch({error, {noncontiguous, 5, 2}}, quod_catchup:verify_forward(P, 5, [committed(2, tx(2), C, 3)])).

%% A non-#entry element from a hostile server is rejected, not crashed.
malformed_entry_rejected_test() ->
    C = committee(4),
    ?assertMatch({error, {malformed_entry, 2}},
                 quod_catchup:verify_forward([], 1, [genesis(pubs(C)), {not_an_entry, 2}])).

%% A mid-chain window: the caller threads Committee0 (as of From>1); no genesis in the window.
midchain_window_test() ->
    C = committee(4), P = pubs(C),
    ?assertMatch({ok, [_, _], P},
                 quod_catchup:verify_forward(P, 5, [committed(5, tx(5), C, 3), committed(6, tx(6), C, 4)])).

%% A committee-changing block is verified under the OLD set; the NEXT block must meet the GROWN set's quorum.
committee_grows_test() ->
    C4 = committee(4), P4 = pubs(C4),
    {P5, _} = New = quod_identity:generate(),
    C5 = C4 ++ [New],
    Chain = [genesis(P4), committed(2, admit_tx(P5), C4, 3), committed(3, tx(3), C5, 4)],
    {ok, _, Final} = quod_catchup:verify_forward([], 1, Chain),
    ?assertEqual(lists:usort([P5 | P4]), Final).

%% The SAME chain but the post-change block is signed only by the OLD set (3 sigs) is REJECTED — it must meet
%% the GROWN committee's quorum (5-set, quorum 4). This is exactly the stale-committee cert a lagging node
%% might persist (S1 finding #2): a trustless joiner refuses it.
committee_grows_rejects_stale_test() ->
    C4 = committee(4), P4 = pubs(C4),
    {P5, _} = quod_identity:generate(),
    Chain = [genesis(P4), committed(2, admit_tx(P5), C4, 3), committed(3, tx(3), C4, 3)],
    ?assertEqual({error, {bad_cert, 3}}, quod_catchup:verify_forward([], 1, Chain)).

%% A committee SHRINK (retract peer_admitted): the removed member is dropped, and the next block is verified
%% against the smaller set.
committee_shrinks_test() ->
    C5 = committee(5), P5 = pubs(C5),
    Gone = lists:last(P5),
    C4 = [M || {Pk, _} = M <- C5, Pk =/= Gone],
    Chain = [genesis(P5), committed(2, remove_tx(Gone), C5, 4), committed(3, tx(3), C4, 3)],
    {ok, _, Final} = quod_catchup:verify_forward([], 1, Chain),
    ?assertEqual(lists:usort(P5 -- [Gone]), Final).

%%%--- catch_up/3 driver (mocked Fetch/Sink — no transport/store) ---

%% a Fetch serving a pre-built Chain (entries 1..H) in windows of W; From > H ⇒ empty.
mock_fetch(Chain, W) ->
    H = length(Chain),
    fun(From) when From > H -> {ok, [], H};
       (From)               -> {ok, lists:sublist(Chain, From, W), H}
    end.

sink() -> put(sink, []), fun(Es) -> put(sink, get(sink) ++ Es), ok end.

%% the out-of-band-pinned genesis anchor = block_hash of the genesis block.
gen_hash(#entry{index = 1, data = D}) -> quod_simplex:block_hash(#block{slot = 1, parent = 0, payload = [D]}).

%% The driver loops windowed fetches, verifies each, sinks the verified entries in order, and reports the
%% caught-up height.
catch_up_happy_test() ->
    C = committee(4), P = pubs(C), G = genesis(P),
    Chain = [G, committed(2, tx(2), C, 3), committed(3, tx(3), C, 4)],
    Sink = sink(),
    ?assertEqual({ok, 3}, quod_catchup:catch_up(gen_hash(G), mock_fetch(Chain, 2), Sink)),   %% windows of 2
    ?assertEqual(Chain, get(sink)).                                                          %% all, in order

%% A genesis whose CONTENT (here, committee) differs from the pinned genesis hash is rejected (forged anchor).
catch_up_bad_anchor_test() ->
    C = committee(4), Fake = committee(4),
    Chain = [genesis(pubs(Fake)), committed(2, tx(2), Fake, 3)],
    ?assertEqual({error, bad_anchor},
                 quod_catchup:catch_up(gen_hash(genesis(pubs(C))), mock_fetch(Chain, 10), fun(_) -> ok end)).

%% A window that fails verification aborts catch-up, and NOTHING is persisted (the whole window is atomic).
catch_up_forged_test() ->
    C = committee(4), Outsiders = committee(4), G = genesis(pubs(C)),
    Chain = [G, committed(2, tx(2), Outsiders, 3)],
    Sink = sink(),
    ?assertMatch({error, {verify, {bad_cert, 2}}},
                 quod_catchup:catch_up(gen_hash(G), mock_fetch(Chain, 10), Sink)),
    ?assertEqual([], get(sink)).   %% the bad window is never sunk

%% A committee change in window 1 is threaded so window 2 verifies against the GROWN set.
catch_up_committee_change_across_windows_test() ->
    C4 = committee(4), P4 = pubs(C4), G = genesis(P4),
    {P5, _} = New = quod_identity:generate(), C5 = C4 ++ [New],
    B2 = committed(2, admit_tx(P5), C4, 3),   %% grows the committee, in window 1
    B3 = committed(3, tx(3), C5, 4),           %% window 2, needs the 5-set quorum
    Sink  = sink(),
    Fetch = fun(1) -> {ok, [G, B2], 3}; (3) -> {ok, [B3], 3}; (_) -> {ok, [], 3} end,
    ?assertEqual({ok, 3}, quod_catchup:catch_up(gen_hash(G), Fetch, Sink)),
    ?assertEqual([G, B2, B3], get(sink)).

%% A contact that REGRESSES its claimed height below what it already served is treated as stalled (the target
%% is the MAX height seen), not falsely "caught up" — so the joiner fails over instead of truncating.
catch_up_height_regression_test() ->
    C = committee(4), P = pubs(C), G = genesis(P), B2 = committed(2, tx(2), C, 3),
    Fetch = fun(1) -> {ok, [G, B2], 100};   %% claims height 100
               (_) -> {ok, [], 5}           %% then regresses to 5, mid-catch-up
            end,
    ?assertEqual({error, no_progress}, quod_catchup:catch_up(gen_hash(G), Fetch, sink())).

%% A fetch failure surfaces so the caller can try another contact.
catch_up_fetch_error_test() ->
    ?assertEqual({error, {fetch, timeout}},
                 quod_catchup:catch_up(<<0>>, fun(_) -> {error, timeout} end, fun(_) -> ok end)).

%% A sink failure aborts catch-up cleanly (recoverable), not a badmatch crash.
catch_up_sink_error_test() ->
    C = committee(4), P = pubs(C), G = genesis(P),
    Chain = [G, committed(2, tx(2), C, 3)],
    ?assertEqual({error, {sink, disk_full}},
                 quod_catchup:catch_up(gen_hash(G), mock_fetch(Chain, 10), fun(_) -> {error, disk_full} end)).

%% A server that returns empty while claiming more height is stuck — reported, not looped forever.
catch_up_no_progress_test() ->
    ?assertEqual({error, no_progress},
                 quod_catchup:catch_up(<<0>>, fun(_) -> {ok, [], 5} end, fun(_) -> ok end)).
