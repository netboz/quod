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
%%% helpers
%%%===================================================================

take(N, L) -> lists:sublist(L, N).

flip1(<<B, Rest/binary>>) -> <<(B bxor 1), Rest/binary>>.
