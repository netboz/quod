-module(quod_simplex_tests).
-moduledoc """
Pure-logic unit tests for `quod_simplex`'s DispersedSimplex consensus core — the parts that must be
correct independently of the network: quorum math, share signing, certificate formation + trustless
verification (incl. the Byzantine rejections), and the commit-vs-complaint guard. Uses real Ed25519
keypairs, so the crypto path is exercised end-to-end. Multi-node behaviour is (will be) in
`simplex_SUITE`.
""".
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% a fresh validator identity {Pubkey, IdentityMap}
id() ->
    {Pub, Seed} = quod_identity:generate(),
    {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}.

blk(Slot) -> #block{slot = Slot, parent = Slot - 1, payload = [noop]}.

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
    S = quod_simplex:make_share(support, 3, H, Id),
    ?assert(quod_simplex:verify_share(S)),
    %% a tampered signature is rejected
    Bad = S#share{sig = flip1(S#share.sig)},
    ?assertNot(quod_simplex:verify_share(Bad)).

%% a support sig does not verify as a commit sig (domain separation)
domain_separation_test() ->
    {Pub, Id} = id(),
    H = quod_simplex:block_hash(blk(3)),
    S = quod_simplex:make_share(support, 3, H, Id),
    %% same signer/slot/hash, but the COMMIT bytes -> the support sig must not verify
    ?assertNot(quod_identity:verify(S#share.sig, quod_simplex:share_bytes(commit, 3, H), Pub)).

%%%===================================================================
%%% certificate formation + trustless verification
%%%===================================================================

form_and_verify_cert_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],           %% N=4, quorum=3
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    Shares = [quod_simplex:make_share(support, 1, H, Id) || {_, Id} <- take(3, Ids)],
    {ok, Cert} = quod_simplex:form_cert(support, 1, H, Shares, Vals),
    ?assert(quod_simplex:verify_cert(Cert, Vals)).

cert_insufficient_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    Shares = [quod_simplex:make_share(support, 1, H, Id) || {_, Id} <- take(2, Ids)],   %% < quorum 3
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(support, 1, H, Shares, Vals)).

%% a share from a non-validator does not count toward quorum
cert_rejects_outsider_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    {_, Outsider} = id(),                            %% not in Vals
    H = quod_simplex:block_hash(blk(1)),
    Shares = [quod_simplex:make_share(support, 1, H, Id) || {_, Id} <- take(2, Ids)]
             ++ [quod_simplex:make_share(support, 1, H, Outsider)],
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(support, 1, H, Shares, Vals)).

%% a corrupted signature does not count
cert_rejects_bad_sig_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    [S1, S2, S3] = [quod_simplex:make_share(support, 1, H, Id) || {_, Id} <- take(3, Ids)],
    Shares = [S1, S2, S3#share{sig = flip1(S3#share.sig)}],   %% one bad -> only 2 valid
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(support, 1, H, Shares, Vals)).

%% duplicate shares from the same signer count once
cert_dedup_signer_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    [{_, A}, {_, B} | _] = Ids,
    %% 3 shares but only 2 distinct signers (A twice) -> below quorum 3
    Shares = [quod_simplex:make_share(support, 1, H, A),
              quod_simplex:make_share(support, 1, H, A),
              quod_simplex:make_share(support, 1, H, B)],
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(support, 1, H, Shares, Vals)).

%% a forged cert (sigs over a different block) fails trustless verification
verify_cert_rejects_wrong_block_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H1 = quod_simplex:block_hash(blk(1)),
    Shares = [quod_simplex:make_share(support, 1, H1, Id) || {_, Id} <- take(3, Ids)],
    {ok, Cert} = quod_simplex:form_cert(support, 1, H1, Shares, Vals),
    %% claim the cert is for a different block hash -> sigs no longer verify
    Forged = Cert#cert{block_hash = quod_simplex:block_hash(blk(2))},
    ?assertNot(quod_simplex:verify_cert(Forged, Vals)).

%%%===================================================================
%%% the commit guard
%%%===================================================================

%% Both halves of the mutual-exclusion guard, and robustness to an UNSORTED list (the old ordset
%% contract was a silent-wrong-answer footgun — this pins the fix).
mutual_exclusion_guard_test() ->
    ?assert(quod_simplex:may_commit(5, [])),
    ?assertNot(quod_simplex:may_commit(5, [5])),        %% complained slot 5 -> cannot commit it
    ?assert(quod_simplex:may_complain(5, [])),
    ?assertNot(quod_simplex:may_complain(5, [5])),      %% committed slot 5 -> cannot complain it
    ?assertNot(quod_simplex:may_commit(5, [9, 5, 1])),  %% UNSORTED list must still find 5
    ?assertNot(quod_simplex:may_complain(5, [9, 5, 1])).

%%%===================================================================
%%% boundary / edge / Byzantine (fixes from the review)
%%%===================================================================

%% Positive control for the rejection tests: a cert forms at EXACTLY quorum and not one below.
cert_boundary_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],           %% N=4, quorum=3
    Vals = [P || {P, _} <- Ids],
    H    = quod_simplex:block_hash(blk(1)),
    Sh   = fun(N) -> [quod_simplex:make_share(support, 1, H, Id) || {_, Id} <- take(N, Ids)] end,
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(support, 1, H, Sh(2), Vals)),
    ?assertMatch({ok, _},               quod_simplex:form_cert(support, 1, H, Sh(3), Vals)).

%% The live sole-founder path: N=1, quorum=1, a self-signed cert forms and verifies.
sole_validator_cert_test() ->
    {P, Id} = id(),
    H = quod_simplex:block_hash(blk(1)),
    {ok, C} = quod_simplex:form_cert(commit, 1, H, [quod_simplex:make_share(commit, 1, H, Id)], [P]),
    ?assert(quod_simplex:verify_cert(C, [P])).

%% An empty validator set must NOT crash (quorum(0)) — clean insufficient / false.
empty_validators_test() ->
    {_, Id} = id(),
    H = quod_simplex:block_hash(blk(1)),
    ?assertEqual({error, insufficient},
                 quod_simplex:form_cert(support, 1, H, [quod_simplex:make_share(support, 1, H, Id)], [])),
    ?assertNot(quod_simplex:verify_cert(#cert{kind = support, slot = 1, block_hash = H, sigs = []}, [])).

%% A complaint (slot-only, block_hash=none) cert forms and verifies.
complaint_cert_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    Sh   = [quod_simplex:make_share(complaint, 2, none, Id) || {_, Id} <- take(3, Ids)],
    {ok, C} = quod_simplex:form_cert(complaint, 2, none, Sh, Vals),
    ?assert(quod_simplex:verify_cert(C, Vals)).

%%%===================================================================
%%% f+1 complaint amplification threshold (Slice B: growth liveness)
%%%===================================================================

%% The leader of an in-flight slot (and any node ingesting a complaint share) joins a complaint only on
%% `f+1` distinct PEER complaint shares — enough to guarantee ≥1 HONEST complainer, so a lone Byzantine
%% can't force a skip, yet a genuine stall still gets amplified. The threshold is DERIVED from quorum/1
%% (`f = N − quorum(N)`), so it must track the cert arithmetic exactly at every committee size.
complaint_amplified_threshold_test() ->
    Bucket = fun(Signers) -> maps:from_list([{S, dummy} || S <- Signers]) end,
    %% peers are just distinct signer keys; `self` (the atom `me`) is excluded from the count.
    Vs = fun(N) -> [me | [{peer, I} || I <- lists:seq(1, N - 1)]] end,
    Peers = fun(K) -> Bucket([{peer, I} || I <- lists:seq(1, K)]) end,
    Amp = fun(N, K) -> quod_simplex:complaint_amplified(me, Vs(N), Peers(K)) end,
    %% f+1 by committee size: N=2,3 ⇒ 1 (f=0); N=4,5,6 ⇒ 2 (f=1); N=7 ⇒ 3 (f=2).
    ?assertNot(Amp(2, 0)), ?assert(Amp(2, 1)),                 %% N=2: one peer suffices
    ?assertNot(Amp(3, 0)), ?assert(Amp(3, 1)),                 %% N=3: still one (f=0)
    ?assertNot(Amp(4, 1)), ?assert(Amp(4, 2)),                 %% N=4: needs two (f=1)
    ?assertNot(Amp(7, 2)), ?assert(Amp(7, 3)),                 %% N=7: needs three (f=2)
    %% our OWN complaint share is not independent evidence — self is excluded from the count.
    ?assertNot(quod_simplex:complaint_amplified(me, Vs(2), Bucket([me]))),
    ?assert(quod_simplex:complaint_amplified(me, Vs(2), Bucket([me, {peer, 1}]))).

%% Malformed shapes are rejected even with a valid signature over their (malformed) bytes.
share_shape_test() ->
    {_, Id} = id(),
    H = quod_simplex:block_hash(blk(1)),
    ?assert(quod_simplex:verify_share(quod_simplex:make_share(support, 1, H, Id))),
    ?assertNot(quod_simplex:verify_share(quod_simplex:make_share(complaint, 1, H, Id))),   %% complaint w/ hash
    ?assertNot(quod_simplex:verify_share(quod_simplex:make_share(support, 1, <<1, 2, 3>>, Id))).  %% short hash

%% A share whose FIELDS claim block H but whose signature is over a DIFFERENT block: form_cert
%% re-verifies over the cert's canonical bytes, so the liar does not count (proves fields aren't trusted).
fields_lie_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H      = quod_simplex:block_hash(blk(1)),
    HOther = quod_simplex:block_hash(blk(9)),
    [{_, A}, {_, B}, {_, C} | _] = Ids,
    Liar = (quod_simplex:make_share(support, 1, HOther, C))#share{block_hash = H},  %% sig over HOther, claims H
    Shares = [quod_simplex:make_share(support, 1, H, A),
              quod_simplex:make_share(support, 1, H, B), Liar],
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(support, 1, H, Shares, Vals)).

%% A cert carrying MORE signatures than validators is rejected before any verify work (amplification cap).
verify_cert_caps_sigs_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    Bloat = [{P, <<0:512>>} || P <- Vals] ++ [{<<X:256>>, <<0:512>>} || X <- lists:seq(1, 20)],
    ?assertNot(quod_simplex:verify_cert(#cert{kind = support, slot = 1, block_hash = H, sigs = Bloat}, Vals)).

%%%===================================================================
%%% consensus engine — certificate pool + block tree (§2.3)
%%%===================================================================

%% N=4 (quorum 3): a block notarizes at the 3rd support share, commits at the 3rd commit share.
eng_notarize_then_commit_test() ->
    C = committee(4),
    B = blk(1),
    E0 = quod_simplex:eng_new(pubs(C), 0),
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

%% N=1 (quorum 1): the sole validator's own shares notarize + commit instantly (the degenerate case).
eng_sole_validator_test() ->
    C = committee(1),
    B = blk(1),
    {E1, _}   = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(pubs(C), 0)),
    {E2, Ev2} = feed_shares(supports(B, C, 1), E1),
    ?assert(lists:member({notarized, B}, Ev2)),
    {_E3, Ev3} = feed_shares(commits(B, C, 1), E2),
    ?assert(lists:member({committed, 1, B}, Ev3)).

%% A block whose parent is not yet notarized WAITS, then rides in on the parent's settle (fixpoint).
eng_parent_ordering_test() ->
    C = committee(4),
    B1 = blk(1), B2 = blk(2),                              %% B2's parent is slot 1
    E0 = quod_simplex:eng_new(pubs(C), 0),
    {E1, _}   = quod_simplex:eng_offer({block, B2}, E0),
    {E2, Ev2} = feed_shares(supports(B2, C, 3), E1),       %% B2 fully supported BEFORE B1
    ?assertNot(lists:member({notarized, B2}, Ev2)),
    ?assertNot(maps:is_key(2, quod_simplex:eng_tree(E2))),
    {E3, _}   = quod_simplex:eng_offer({block, B1}, E2),
    {E4, Ev4} = feed_shares(supports(B1, C, 3), E3),
    ?assert(lists:member({notarized, B1}, Ev4)),
    ?assert(lists:member({notarized, B2}, Ev4)),           %% B2 notarizes on the SAME settle as B1
    ?assert(maps:is_key(2, quod_simplex:eng_tree(E4))).

%% A support share from a non-validator does not count toward the quorum.
eng_rejects_outsider_test() ->
    C = committee(4),
    {_, Outsider} = id(),
    B = blk(1),
    {E1, _}    = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(pubs(C), 0)),
    Bad = quod_simplex:make_share(support, 1, quod_simplex:block_hash(B), Outsider),
    {E2, Ev2}  = feed_shares(supports(B, C, 2) ++ [Bad], E1),   %% 2 valid + 1 outsider
    ?assertNot(lists:member({notarized, B}, Ev2)),
    ?assertNot(maps:is_key(1, quod_simplex:eng_tree(E2))).

%% A cert learned from a peer is added + re-disseminated ONCE (never twice), and notarizes the block.
eng_relays_cert_once_test() ->
    C = committee(4),
    B = blk(1),
    {ok, SC} = quod_simplex:form_cert(support, 1, quod_simplex:block_hash(B), supports(B, C, 3), pubs(C)),
    {E1, _}   = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(pubs(C), 0)),
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

%% A ⅔ complaint cert skips the slot: the engine emits {skipped, V} once and re-disseminates the cert.
eng_complaint_skips_test() ->
    C   = committee(4),
    Sh  = [quod_simplex:make_share(complaint, 2, none, Id) || {_, Id} <- take(3, C)],   %% quorum(4)=3
    E0  = quod_simplex:eng_new(pubs(C), 0),
    {E1, Ev1} = feed_shares(Sh, E0),
    ?assert(lists:member({skipped, 2}, Ev1)),
    ?assert(lists:any(fun({broadcast, #cert{kind = complaint, slot = 2}}) -> true; (_) -> false end, Ev1)),
    {_E2, Ev2} = feed_shares(Sh, E1),                              %% re-offering does NOT re-skip (deduped)
    ?assertEqual([], [X || {skipped, _} = X <- Ev2]).

%% An empty committee has no leader — `leader/2` returns `none` (never `rem 0`-crashes) so a committee that
%% somehow emptied leaves the statem gracefully wedged instead of crash-looping.
leader_empty_committee_test() ->
    ?assertEqual(none, quod_simplex:leader(1, [])),
    ?assertEqual(none, quod_simplex:leader(7, [])).

%% The commit/complaint guards are mutually exclusive per slot — the whole safety argument.
guards_mutual_exclusion_test() ->
    ?assert(quod_simplex:may_commit(5, [])),
    ?assertNot(quod_simplex:may_commit(5, [5])),        %% complained 5 ⇒ must not commit it
    ?assert(quod_simplex:may_complain(5, [])),
    ?assertNot(quod_simplex:may_complain(5, [5])).      %% commit-signed 5 ⇒ must not complain it

%% The committee projection: a transaction's diff folds into {added, removed} `peer_admitted` pubkeys —
%% a re-asserted member is idempotent, a non-peer_admitted op is ignored. `apply_committee_delta/2` applies
%% the delta onto a set, sorted + deduped — the ONE function used by BOTH the boot re-fold AND the live swap
%% on commit, so the running set can never drift from a fresh re-fold. (The end-to-end fold over a committed
%% log is exercised by the gen_statem CT `t_restart_replays`.)
committee_delta_test() ->
    [A, B, C] = [P || {P, _} <- committee(3)],
    Tx = tx([pa(A), pa(B), pa(A), rm(B), {assert, {{other, foo}, true}}]),   %% +A +B +A(dup) -B, noise
    ?assertEqual({[A], [B]}, quod_simplex:committee_delta(Tx)),
    ?assertEqual([A], quod_simplex:apply_committee_delta(Tx, [])),
    ?assertEqual(lists:usort([A, C]), quod_simplex:apply_committee_delta(Tx, [A, C, B])),  %% A dup, C kept, B dropped
    ?assertEqual({[], []}, quod_simplex:committee_delta(noop)),                 %% a noop carries no change
    ?assertEqual(lists:usort([A, C]), quod_simplex:apply_committee_delta(noop, [C, A])).

%% Slice A membership gate (deferred.md §3 a+c): a committee-touching transaction must be EXACTLY ONE
%% well-formed `peer_admitted` op that does not empty the committee — the pure shape + wedge floor,
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

%% A non-PROPER-list diff (an improper list `[Op|junk]`, or a non-list) must be rejected, never crash:
%% `binary_to_term` on the untrusted consensus wire can decode an improper list, and `is_list/1` alone
%% would let it through (it inspects only the first cons cell) to crash `committee_delta`'s fold. The gate
%% runs inside the unguarded statem callback, so a crash here is a network-wide DoS.
membership_gate_improper_list_test() ->
    [A] = pubs(committee(1)),
    Improper = tx([{assert, {{other, x}, true}} | 2]),   %% is_list/1 is TRUE for this
    NonList  = tx(not_a_list),
    ?assertNot(quod_simplex:change_acceptable(Improper, [A])),
    ?assertNot(quod_simplex:change_acceptable(NonList, [A])),
    ?assert(quod_simplex:change_acceptable(tx([{assert, {{ok, x}, true}}]), [A])),   %% proper: fine
    ?assert(quod_simplex:change_acceptable(noop, [A])).

%% Every `peer_admitted` fact is a voter (no non-voting tier): asserting one grows the set and the quorum.
committee_grows_test() ->
    [A, B] = [P || {P, _} <- committee(2)],
    V1 = quod_simplex:apply_committee_delta(tx([pa(A)]), []),
    V2 = quod_simplex:apply_committee_delta(tx([pa(B)]), V1),
    ?assertEqual([A], V1),
    ?assertEqual(lists:usort([A, B]), V2),
    ?assertEqual(1, quod_simplex:quorum(length(V1))),
    ?assertEqual(2, quod_simplex:quorum(length(V2))).

%% Pruning a committed slot advances `base` and drops it from every map (the memory-leak fix), and a
%% stale share/cert/block for an already-final slot (`=< base`) is then ignored.
eng_prune_test() ->
    C = committee(4),
    B1 = blk(1), B2 = blk(2),
    {E1, _} = quod_simplex:eng_offer({block, B1}, quod_simplex:eng_new(pubs(C), 0)),
    {E2, _} = quod_simplex:eng_offer({block, B2}, E1),
    {E3, _} = feed_shares(supports(B1, C, 3) ++ supports(B2, C, 3), E2),
    {E4, _} = feed_shares(commits(B1, C, 3) ++ commits(B2, C, 3), E3),
    ?assert(maps:is_key(1, quod_simplex:eng_committed(E4))),
    ?assert(maps:is_key(2, quod_simplex:eng_committed(E4))),
    %% prune past slot 1: slot 1 is dropped from tree + committed; slot 2 is retained
    E5 = quod_simplex:eng_prune(1, E4),
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

take(N, L) -> lists:sublist(L, N).

flip1(<<B, Rest/binary>>) -> <<(B bxor 1), Rest/binary>>.

%% a committee of N validators as [{Pubkey, IdentityMap}]; pubs/1 = just the node_ids
committee(N) -> [id() || _ <- lists:seq(1, N)].
pubs(C)      -> [P || {P, _} <- C].

%% committee-projection fixtures: a transaction whose diff is a list of peer_admitted asserts/retracts
pa(Pk)  -> {assert,  {{peer_admitted, Pk, undefined, undefined, Pk}, true}}.
rm(Pk)  -> {retract, {{peer_admitted, Pk, undefined, undefined, Pk}, true}}.
tx(Ops) -> #transaction{tx_id = <<"t">>, caller_ns = <<"ns">>, diff = Ops,
                        read_check = #{}, author = <<"a">>, sig = none}.

%% support/commit shares for block B from the first K committee members
supports(B, C, K) -> [quod_simplex:make_share(support, B#block.slot, quod_simplex:block_hash(B), Id)
                      || {_, Id} <- take(K, C)].
commits(B, C, K)  -> [quod_simplex:make_share(commit, B#block.slot, quod_simplex:block_hash(B), Id)
                      || {_, Id} <- take(K, C)].

%% offer each share to the engine in turn, accumulating all emitted events
feed_shares(Shares, Eng) ->
    lists:foldl(fun(S, {E, Evs}) ->
                    {E1, Es} = quod_simplex:eng_offer({share, S}, E),
                    {E1, Evs ++ Es}
                end, {Eng, []}, Shares).
