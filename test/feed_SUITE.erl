-module(feed_SUITE).
-moduledoc """
Dissemination feed (F1) integration: **a follower follows live commits over the feed**, on genuine
loopback QUIC. A founder (`mode=create`, N=1) founds `feed:f1` and commits a fact; a second node
(`mode=join`) catches up to that height and goes `join=done` (a read-only observer). Both then join the
namespace **Brahms overlay**, and the founder commits a NEW fact. Because the follower is already `done`
and never re-enters catch-up — and its digest rounds are pinned far out, so the digest→pull path can't
recover the block instead — the only way its height can advance is the **eager push**: the founder's
`m:quod_feed` pushes the fresh block to its overlay view, the follower verifies the block's quorum cert
against the committee it holds, hands it to `m:quod_simplex`, and advances — proving the committee→crowd
push path end to end. The second case proves the complementary **digest → verified pull** recovery,
overlay-less.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-import(quod_ct, [eventually/2, match_ok/1]).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([follower_follows_live/1, follower_recovers_gap_via_anti_entropy/1]).

-define(NS, <<"feed:f1">>).
-define(FOUNDER_PORT, 15610).
-define(FOLLOWER_PORT, 15611).
-define(AE_FOUNDER_PORT, 15612).
-define(AE_FOLLOWER_PORT, 15613).

all() -> [follower_follows_live, follower_recovers_gap_via_anti_entropy].

%%%===================================================================
%%% setup: found N=1 + a fact, a mode=join follower catches up, then both join the overlay
%%%===================================================================

init_per_suite(Config) ->
    [{FPub, _} = FKey, {JPub, _} = JKey] = [quod_identity:generate() || _ <- [f, j]],
    FAddr = {"127.0.0.1", ?FOUNDER_PORT},
    JAddr = {"127.0.0.1", ?FOLLOWER_PORT},

    %% 1. founder: N=1, commit one fact (slot 2).
    Founder = start_node(?FOUNDER_PORT, FKey, Config, #{mode => create, committee => []}),
    ?assert(eventually(fun() -> slot(Founder) =:= 1 end, 10000)),
    ?assert(eventually(fun() -> match_ok(prove(Founder, {assertz, {capital, france, paris}})) end, 20000)),
    ?assert(eventually(fun() -> slot(Founder) =:= 2 end, 10000)),

    %% 2. follower: mode=join, catches up to the founder's height (2), then goes quiescent (join=done).
    %% Pin this pair's digest rounds far out FIRST: `follower_follows_live` proves the eager-PUSH path,
    %% and a digest round racing the push would recover the block by pull instead — stealing the ingest
    %% the case asserts (the digest→pull path has its own case below, on its own nodes).
    GH = peer:call(Founder, quod_simplex, genesis_hash, [?NS]),
    ?assert(is_binary(GH)),
    ok = peer:call(Founder, application, set_env, [quod, feed_anti_entropy_ms, 600000]),
    Follower = start_node(?FOLLOWER_PORT, JKey, Config,
                          #{mode => join, genesis_hash => GH, seed_peers => [FAddr]}),
    ok = peer:call(Follower, application, set_env, [quod, feed_anti_entropy_ms, 600000]),
    ok = peer:call(Founder,  quod_quic, learn, [JPub, JAddr]),
    ok = peer:call(Follower, quod_quic, learn, [FPub, FAddr]),
    ?assert(eventually(fun() -> slot(Follower) =:= 2 end, 30000)),
    ?assert(eventually(fun() -> maps:get(join, status(Follower), undefined) =:= done end, 30000)),

    %% 3. both join the namespace Brahms overlay (address-based), seeded to each other. The seed IS the
    %% initial view, so the founder's eager-push reaches the follower without waiting for a gossip round.
    {ok, _} = peer:call(Founder,  quod_brahms, start_namespace, [?NS, #{node_id => FAddr, seed_peers => [JAddr]}]),
    {ok, _} = peer:call(Follower, quod_brahms, start_namespace, [?NS, #{node_id => JAddr, seed_peers => [FAddr]}]),
    ?assert(eventually(fun() -> lists:member(JAddr, peer:call(Founder, quod_brahms, view, [?NS])) end, 15000)),

    [{founder, Founder}, {follower, Follower}, {jpub, JPub} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(P) || P <- [?config(founder, Config), ?config(follower, Config)]],
    ok.

%%%===================================================================
%%% test
%%%===================================================================

follower_follows_live(Config) ->
    Founder  = ?config(founder, Config),
    Follower = ?config(follower, Config),

    %% sanity: the follower is a caught-up NON-member read observer, sitting at the snapshot height.
    ?assertEqual(2, slot(Follower)),
    ?assertEqual(done, maps:get(join, status(Follower), undefined)),
    ?assertNot(lists:member(?config(jpub, Config), peer:call(Follower, quod_simplex, committee, [?NS]))),

    %% the founder commits a NEW fact (slot 3) — the feed eager-pushes it to the overlay.
    ?assert(eventually(fun() -> match_ok(prove(Founder, {assertz, {capital, spain, madrid}})) end, 20000)),
    ?assert(eventually(fun() -> slot(Founder) =:= 3 end, 10000)),

    %% the follower advances to 3 via the FEED (it is join=done and never re-runs catch-up), and the fact
    %% is readable from its OWN kb — the block was applied, not merely stored.
    ?assert(eventually(fun() -> slot(Follower) =:= 3 end, 30000)),
    ?assertEqual(done, maps:get(join, status(Follower), undefined)),   %% never dropped back into catch-up
    ?assert(eventually(fun() -> match_ok(prove(Follower, {capital, spain, {'X'}})) end, 15000)),

    %% and it stayed a non-voter — dissemination is read-tier, never promotion.
    ?assertNot(lists:member(?config(jpub, Config), peer:call(Follower, quod_simplex, committee, [?NS]))),

    %% the feed recorded the ingest (relayed a verified block into consensus).
    FS = peer:call(Follower, quod_feed, stats, [?NS]),
    ?assertMatch(#{ingested := N} when N >= 1, FS).

%% A follower recovers a block it MISSED on the push, purely via anti-entropy — with NO overlay at all.
%% The founder commits the extra block while the follower has an empty Brahms view (no eager-push can
%% reach it); the follower is join=done and never re-runs cold-start catch-up, so the only path to the
%% missed block is its periodic digest to the COMMITTEE → the founder's ahead-reply → verified pull.
%% (These are the same digests admission's `peer_ready` gate reads.) Self-contained nodes.
follower_recovers_gap_via_anti_entropy(Config) ->
    {FPub, _} = FKey = quod_identity:generate(),
    {JPub, _} = JKey = quod_identity:generate(),
    FAddr = {"127.0.0.1", ?AE_FOUNDER_PORT},
    JAddr = {"127.0.0.1", ?AE_FOLLOWER_PORT},
    Founder  = start_node(?AE_FOUNDER_PORT, FKey, Config, #{mode => create, committee => []}),
    try
        ?assert(eventually(fun() -> slot(Founder) =:= 1 end, 10000)),
        ?assert(eventually(fun() -> match_ok(prove(Founder, {assertz, {capital, italy, rome}})) end, 20000)),
        ?assert(eventually(fun() -> slot(Founder) =:= 2 end, 10000)),
        GH = peer:call(Founder, quod_simplex, genesis_hash, [?NS]),
        F2 = start_node(?AE_FOLLOWER_PORT, JKey, Config, #{mode => join, genesis_hash => GH, seed_peers => [FAddr]}),
        try
            ok = peer:call(F2, application, set_env, [quod, feed_anti_entropy_ms, 500]),
            ok = peer:call(Founder, quod_quic, learn, [JPub, JAddr]),
            ok = peer:call(F2,      quod_quic, learn, [FPub, FAddr]),
            ?assert(eventually(fun() -> slot(F2) =:= 2 end, 30000)),
            ?assert(eventually(fun() -> maps:get(join, status(F2), undefined) =:= done end, 30000)),

            %% commit the delta — the eager-push has an empty view and reaches nobody; recovery must come
            %% from the digest exchange alone.
            ?assert(eventually(fun() -> match_ok(prove(Founder, {assertz, {capital, japan, tokyo}})) end, 20000)),
            ?assert(eventually(fun() -> slot(Founder) =:= 3 end, 10000)),
            ?assert(eventually(fun() -> slot(F2) =:= 3 end, 30000)),          %% recovered via digest → pull
            ?assert(eventually(fun() -> match_ok(prove(F2, {capital, japan, {'X'}})) end, 15000)),
            ?assertNot(lists:member(JPub, peer:call(F2, quod_simplex, committee, [?NS]))),
            FS = peer:call(F2, quod_feed, stats, [?NS]),
            ?assertMatch(#{pulled := N} when N >= 1, FS)
        after
            _ = catch peer:stop(F2)
        end
    after
        _ = catch peer:stop(Founder)
    end.

%%%===================================================================
%%% node harness (one OS node each; own identity + QUIC listener)
%%%===================================================================

start_node(Port, {Pub, Seed}, Config, Extra) ->
    Name = list_to_atom("feed_" ++ integer_to_list(Port)),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io, args => ["-pa" | code:get_path()]}),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    KeyTerm = quod_identity:key_term({Pub, Seed}),
    Set = fun(K, V) -> ok = peer:call(Peer, application, set_env, [quod, K, V]) end,
    Set(listen_port,   Port),
    Set(node_addr,     {"127.0.0.1", Port}),
    Set(node_pubkey,   Pub),
    Set(identity_key,  KeyTerm),
    Set(identity_cert, quod_identity:mint_cert({Pub, Seed})),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    DataDir = filename:join(?config(priv_dir, Config), "data_" ++ integer_to_list(Port)),
    Cfg = maps:merge(#{node_id => Pub, identity => #{pubkey => Pub, key => KeyTerm}, data_dir => DataDir},
                     Extra),
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    Peer.

%%%===================================================================
%%% helpers
%%%===================================================================

status(Peer)      -> peer:call(Peer, quod_simplex, status, [?NS]).
slot(Peer)        -> maps:get(slot, status(Peer), -1).
prove(Peer, Goal) -> peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]).
