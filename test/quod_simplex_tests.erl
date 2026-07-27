-module(quod_simplex_tests).
-moduledoc """
Pure-logic unit tests for `quod_simplex`'s DispersedSimplex consensus core — the parts that must be
correct independently of the network: quorum math, share signing, certificate formation + trustless
verification (incl. the Byzantine rejections), and the commit-vs-complaint guard. Uses real Ed25519
keypairs, so the crypto path is exercised end-to-end. Real multi-node QUIC behavior and restart recovery
are covered by `simplex_SUITE`.
""".
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% a fresh validator identity {Pubkey, IdentityMap}
id() ->
    {Pub, Seed} = quod_identity:generate(),
    {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}.

blk(Slot) -> #block{slot = Slot, parent = Slot - 1,
                    payload = [tx([{assert, {{fact, Slot}, true}}])]}.

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

%% The committee view is the membership set PLUS the exact committed block that adopted it. Boot replay
%% and catch-up both fold the same per-entry projector, and the live path feeds the same formula with the
%% engine-captured block hash. Content/noop slots do not invent revisions.
committee_view_projection_test() ->
    Ns = <<"committee:view">>,
    [A, B, C] = lists:sort(pubs(committee(3))),
    Genesis = #entry{index = 1,
                     data = quod_ledger:data([tx([pa(B), pa(A)])])},
    Content = #entry{index = 2,
                     data = quod_ledger:data(
                              [tx([{assert, {{content, kept}, true}}])]),
                     timestamp = 123},
    Skipped = #entry{index = 3, data = noop},
    AdmitC = #entry{index = 4,
                    data = quod_ledger:data([tx([pa(C)])]),
                    timestamp = 456},
    {ok, GenesisBlock} = quod_simplex:block_from_entry(Genesis),
    GenesisHash = quod_simplex:block_hash(GenesisBlock),
    ExpectedGenesisId =
        crypto:hash(
          sha256,
          term_to_binary(
            {quod_committee_view, 1, Ns, 1, GenesisHash,
             lists:sort([A, B])},
            [deterministic])),
    Seed = {[], undefined, 0, #{}},
    {[A, B], GenesisId, 0, Seqs1} =
        quod_simplex:test_log_projection(Ns, [Genesis], Seed),
    ?assertEqual(32, byte_size(GenesisId)),
    ?assertEqual(ExpectedGenesisId, GenesisId),
    ?assertEqual(
       GenesisId,
       quod_simplex:committee_view_id(Ns, 1, GenesisHash, [B, A])),

    %% Folding a window in one call and streaming it entry-by-entry are identical.
    AfterStable =
        quod_simplex:test_log_projection(
          Ns, [Content, Skipped], {[A, B], GenesisId, 0, Seqs1}),
    {[A, B], GenesisId, 123, Seqs3} = AfterStable,
    Full = quod_simplex:test_log_projection(
             Ns, [Genesis, Content, Skipped, AdmitC], Seed),
    Streamed = quod_simplex:test_log_projection(
                 Ns, [AdmitC], {[A, B], GenesisId, 123, Seqs3}),
    ?assertEqual(Full, Streamed),
    {[A, B, C], AdmitCId, 456, _} = Full,
    {ok, AdmitCBlock} = quod_simplex:block_from_entry(AdmitC),
    ?assertEqual(
       quod_simplex:committee_view_id(
         Ns, 4, quod_simplex:block_hash(AdmitCBlock), [A, B, C]),
       AdmitCId),
    ?assertNotEqual(GenesisId, AdmitCId).

%% Returning to the same validator set in a later membership block is a new view, while an idempotent
%% re-assert that does not change the facts retains the current identity.
committee_view_recurring_set_revision_test() ->
    Ns = <<"committee:recurring">>,
    [A, B] = lists:sort(pubs(committee(2))),
    Entries =
        [#entry{index = 1,
                data = quod_ledger:data([tx([pa(A), pa(B)])])},
         #entry{index = 2,
                data = quod_ledger:data([tx([rm(B)])]),
                timestamp = 10},
         #entry{index = 3,
                data = quod_ledger:data([tx([pa(B)])]),
                timestamp = 11}],
    [Genesis, Removed, Readded] = Entries,
    {Set1, Id1, Ts1, Seqs1} =
        quod_simplex:test_log_projection(
          Ns, [Genesis], {[], undefined, 0, #{}}),
    {Set2, Id2, Ts2, Seqs2} =
        quod_simplex:test_log_projection(
          Ns, [Removed], {Set1, Id1, Ts1, Seqs1}),
    {Set3, Id3, Ts3, Seqs3} =
        quod_simplex:test_log_projection(
          Ns, [Readded], {Set2, Id2, Ts2, Seqs2}),
    ?assertEqual([A, B], Set1),
    ?assertEqual([A], Set2),
    ?assertEqual([A, B], Set3),
    ?assertNotEqual(Id1, Id2),
    ?assertNotEqual(Id1, Id3),
    ?assertNotEqual(Id2, Id3),
    Reassert = #entry{index = 4,
                      data = quod_ledger:data([tx([pa(B)])]),
                      timestamp = 12},
    {[A, B], Id3, 12, _} =
        quod_simplex:test_log_projection(
          Ns, [Reassert], {Set3, Id3, Ts3, Seqs3}).

canonical_ledger_payload_test() ->
    Transaction = tx([{assert, {{fact, canonical}, true}}]),
    Data = quod_ledger:data([Transaction]),
    ?assertEqual({ok, [Transaction]}, quod_ledger:payload(Data)),
    ?assertEqual(error, quod_ledger:payload(Transaction)),
    ?assertEqual(error, quod_ledger:payload(noop)),
    ?assertEqual(error, quod_simplex:block_from_entry(#entry{index = 1, data = Transaction})).

%%%===================================================================
%%% gap detector — ahead_cert_ceiling/1 (Slice 1)
%%%===================================================================

%% The ceiling is the max FINALIZER (commit|complaint) cert slot above `base`, seeded with `base`.
ahead_cert_ceiling_test() ->
    C = fun(Base, KS) -> quod_simplex:ahead_cert_ceiling(quod_simplex:eng_with_certs(Base, KS)) end,
    ?assertEqual(0, C(0, [])),                                        %% empty pool -> base (no lists:max([]) crash)
    ?assertEqual(0, C(0, [{support, 9}, {support, 42}])),             %% support certs excluded (only notarize)
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

relay_activation_gate_validation_test() ->
    Base = #{node_id => <<0:256>>},
    ?assertEqual(ok, quod_simplex:test_valid_cfg(Base)),
    ?assertEqual(
       {error, ingress_retarget_requires_relay_v2},
       quod_simplex:test_valid_cfg(
         Base#{relay_protocol => v1, ingress_retarget => true})),
    ?assertEqual(
       ok,
       quod_simplex:test_valid_cfg(
         Base#{relay_protocol => v2, ingress_retarget => true})),
    ?assertEqual(
       {error, {bad_relay_protocol, v3}},
       quod_simplex:test_valid_cfg(Base#{relay_protocol => v3})),
    ?assertEqual(
       {error, {bad_ingress_retarget, enabled}},
       quod_simplex:test_valid_cfg(
         Base#{relay_protocol => v2, ingress_retarget => enabled})),
    Empty = st(#{}),
    ?assertEqual({v1, false}, quod_simplex:test_ingress_gates(Empty)),
    ?assertEqual(undefined, quod_simplex:test_committee_id(Empty)),
    ?assertEqual(
       {v2, true},
       quod_simplex:test_ingress_gates(
         st(#{relay_protocol => v2, ingress_retarget => true}))).

%% is_participant is FACTS-ONLY now — Self ∈ active_validators, with no sync/boot coupling.
is_participant_test() ->
    P = fun(Self, Vs) -> quod_simplex:is_participant(st(#{self => Self, validators => Vs})) end,
    ?assert(P(<<"me">>, [<<"a">>, <<"me">>])),
    ?assertNot(P(<<"me">>, [<<"a">>, <<"b">>])),   %% observer
    ?assertNot(P(<<"me">>, [])).                    %% unfounded

%% Only `ready` is caught up; voting and leading share the same participant + recovery capability.
gate_truth_table_test() ->
    EngIdle = quod_simplex:eng_with_certs(0, []),                 %% empty pool ⇒ not behind
    EngBehind = quod_simplex:eng_with_certs(0, [{commit, 20}]),   %% a finalizer cert well past slot+1 ⇒ behind
    Base = #{self => <<"me">>, validators => [<<"me">>], slot => 2, eng => EngIdle},

    S1 = st(Base#{sync => ready}),
    ?assert(quod_simplex:caught_up(S1)),
    ?assert(quod_simplex:may_vote(S1)),
    ?assert(quod_simplex:may_lead(S1)),

    %% A resuming member remains a participant for ingress, but has no voting capability.
    S2 = st(Base#{sync => unconfirmed}),
    ?assert(quod_simplex:is_participant(S2)),
    ?assertNot(quod_simplex:caught_up(S2)),
    ?assertNot(quod_simplex:may_vote(S2)),
    ?assertNot(quod_simplex:may_lead(S2)),

    ?assertNot(quod_simplex:caught_up(st(Base#{sync => {pulling, self()}}))),
    ?assertNot(quod_simplex:caught_up(st(Base#{sync => ready, eng => EngBehind}))),

    %% A ready observer may serve/follow, but cannot vote or lead.
    Obs = st(Base#{validators => [<<"a">>], sync => ready}),
    ?assert(quod_simplex:caught_up(Obs)),
    ?assertNot(quod_simplex:may_vote(Obs)),
    ?assertNot(quod_simplex:may_lead(Obs)).

%% Load-robust self-corroboration: applying a LIVE quorum-cert finalization (commit_block/skip_block)
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
                    eng => quod_simplex:eng_with_certs(0, [])}),
    ?assertNot(quod_simplex:may_vote(CaughtUp)),                          %% unconfirmed ⇒ cannot vote (the stall)
    ?assert(quod_simplex:may_vote(quod_simplex:confirm_live(CaughtUp))),  %% live finality ⇒ ready ⇒ votes
    %% a member confirmed-live over a head still behind the tip is NOT caught up (behind re-gates voting)
    Behind = st(#{self => <<"me">>, validators => [<<"me">>], slot => 2, sync => unconfirmed,
                  eng => quod_simplex:eng_with_certs(0, [{commit, 20}])}),
    Confirmed = quod_simplex:confirm_live(Behind),
    ?assertEqual(ready, quod_simplex:test_sync(Confirmed)),
    ?assertNot(quod_simplex:caught_up(Confirmed)),
    ?assertNot(quod_simplex:may_vote(Confirmed)).

%% Recovery intent and the externally visible syncing flag derive from the same enum.
should_sync_and_syncing_test() ->
    EngIdle = quod_simplex:eng_with_certs(0, []),
    EngBehind = quod_simplex:eng_with_certs(0, [{commit, 20}]),
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
    FinalizedNext = quod_simplex:eng_with_certs(5, [{commit, 6}]),
    Stale = st(#{self => Me, validators => [Me], slot => 5, approved => 5,
                 eng => FinalizedNext, sync => ready}),
    ?assert(quod_simplex:should_sync(Stale)),
    ?assertNot(quod_simplex:caught_up(Stale)),
    ?assertNot(quod_simplex:may_vote(Stale)).

%% Success grants readiness when the durable head is AT OR PAST the corroborated height. A head that
%% advanced while the completion was in flight only moves via cert-verified commits (`persisted_finality`),
%% so it is itself corroborated — accepting it is what keeps a member that stays caught up under load from
%% being bounced back to `unconfirmed` forever. A result from an OBSOLETE worker (pid mismatch) is ignored.
sync_completion_is_height_bound_test() ->
    Eng = quod_simplex:eng_with_certs(0, []),
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
    Eng = quod_simplex:eng_with_certs(0, []),
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
    ?assert(quod_simplex:may_sink({feed, live},
                                  st(#{self => <<"me">>, validators => [<<"other">>], sync => ready}))),
    ?assertNot(quod_simplex:may_sink({feed, replay},
                                     st(#{self => <<"me">>, validators => [<<"me">>], sync => ready}))),
    Other ! stop.

%% A settled observer's contiguous push is a real live event. Recovery and anti-entropy
%% windows rebuild D silently and reconcile P once at their explicit ready edge.
feed_apply_origin_test() ->
    ?assertEqual(live, quod_simplex:catchup_origin({feed, live})),
    ?assertEqual(replay, quod_simplex:catchup_origin({feed, replay})),
    ?assertEqual(replay, quod_simplex:catchup_origin({recovery, self()})).

%% Arm pacing (#s.sync_arm): the behind-hysteresis counter, the backoff cooldown countdown, and the
%% arm_ready gate / backoff growth.
sync_arm_pacing_test() ->
    EngIdle = quod_simplex:eng_with_certs(0, []),
    EngBehind = quod_simplex:eng_with_certs(0, [{commit, 20}]),
    Arm = fun(S) -> quod_simplex:test_arm(quod_simplex:pace_tick(S)) end,

    %% pace_tick grows the hysteresis while behind, resets it when not behind, and counts the cooldown down
    ?assertMatch({1, _, _}, Arm(st(#{slot => 2, eng => EngBehind, sync_arm => {0, 0, 0}}))),
    ?assertMatch({0, _, _}, Arm(st(#{slot => 2, eng => EngIdle,   sync_arm => {5, 0, 0}}))),
    ?assertMatch({_, 2, _}, Arm(st(#{slot => 2, eng => EngIdle,   sync_arm => {0, 3, 8}}))),

    %% unconfirmed arms immediately (unless cooling down); ready requires persistent gap evidence
    ?assert(quod_simplex:arm_ready(st(#{sync => unconfirmed, sync_arm => {0, 0, 0}}))),
    ?assertNot(quod_simplex:arm_ready(st(#{sync => unconfirmed, sync_arm => {0, 1, 4}}))),
    ?assertNot(quod_simplex:arm_ready(st(#{sync => ready, sync_arm => {1, 0, 0}}))),
    ?assert(quod_simplex:arm_ready(st(#{sync => ready, sync_arm => {2, 0, 0}}))),

    %% backoff floors then doubles the interval, resets the hysteresis, and sets a positive jittered cooldown
    {BH, BC, BI} = quod_simplex:backoff({7, 0, 0}),
    ?assertEqual(0, BH),
    ?assert(BI >= 3),                              %% floored at ?SYNC_BACKOFF_MIN
    ?assert(BC >= 1),                              %% a positive jittered cooldown
    {_, _, BI2} = quod_simplex:backoff({0, 0, BI}),
    ?assert(BI2 >= BI andalso BI2 =< 20),          %% grows, capped at ?SYNC_BACKOFF_MAX
    ?assertEqual({0, 0, 0}, quod_simplex:reset_pace()).

%% minimal-state builder for the pure gate predicates (the #s record is private to quod_simplex)
st(Overrides) -> quod_simplex:test_state(Overrides).

voting_readiness(Peers, LinkPid, Height) ->
    Now = quod_time:mono_ms(),
    maps:from_list([{Peer, {LinkPid, Height, true, Now}} || Peer <- Peers]).

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

%% The proposal frontier follows notarization, while the durable frontier follows
%% commit. Depth one allows H+2 to open over approved H+1, then applies backpressure.
pipeline_frontier_test() ->
    Eng = quod_simplex:eng_new([<<"self">>], 5),
    Open = st(#{self => <<"self">>, validators => [<<"self">>], slot => 5,
                approved => 5, eng => Eng, sync => ready}),
    ?assertEqual({ok, 6}, quod_simplex:proposal_slot(Open)),
    OneAhead = st(#{self => <<"self">>, validators => [<<"self">>], slot => 5,
                    approved => 6, eng => Eng, sync => ready}),
    ?assertEqual({ok, 7}, quod_simplex:proposal_slot(OneAhead)),
    Full = st(#{self => <<"self">>, validators => [<<"self">>], slot => 5,
                approved => 7, eng => Eng, sync => ready}),
    ?assertEqual(blocked, quod_simplex:proposal_slot(Full)).

%% The watchdog follows the durable head, not the proposal frontier. Notarizing H+1 changes the phase to
%% awaiting_commit and keeps slot H+1 watched while the pipeline may already propose H+2. Connectivity is
%% part of the state so a returning quorum receives a fresh full timeout.
head_progress_state_test() ->
    [{A, _}, {B, _}, {C, _}, {_D, _}] = Committee = committee(4),
    Eng0 = quod_simplex:eng_new(pubs(Committee), 5),
    Idle = st(#{self => A, validators => pubs(Committee), slot => 5,
                approved => 5, eng => Eng0, sync => ready}),
    ?assertEqual(idle, quod_simplex:test_progress(
                         quod_simplex:reconcile_head_progress(Idle))),

    Requested = st(#{self => A, validators => pubs(Committee), slot => 5,
                     approved => 5, eng => Eng0, sync => ready,
                     head_progress => {6, awaiting_proposal, false}}),
    ?assertEqual({6, awaiting_proposal, false},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(Requested))),

    Inbound = #{B => {self(), make_ref()}, C => {self(), make_ref()}},
    Readiness = voting_readiness([B, C], self(), 6),
    Notarized = st(#{self => A, validators => pubs(Committee), slot => 5,
                     approved => 6, eng => Eng0, sync => ready,
                     inbound_conns => Inbound, peer_readiness => Readiness,
                     head_progress => {6, awaiting_notarization, false}}),
    ?assertEqual({6, awaiting_commit, true},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(Notarized))),

    %% Once slot 6 is durable, the same approved frontier now means slot 7 is the watched finality head.
    Advanced = st(#{self => A, validators => pubs(Committee), slot => 6,
                    approved => 7, eng => quod_simplex:eng_new(pubs(Committee), 6),
                    sync => ready, inbound_conns => Inbound,
                    peer_readiness => Readiness}),
    ?assertEqual({7, awaiting_commit, true},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(Advanced))).

%% Demand for the depth-one successor arrives while the durable head is still awaiting commit. Preserve
%% that demand separately; once the parent commits, the successor immediately becomes the watched
%% awaiting-proposal head even if no second client request arrives.
pipelined_demand_survives_parent_finality_test() ->
    Eng = quod_simplex:eng_new([<<"self">>], 5),
    Pipelined = st(#{self => <<"self">>, validators => [<<"self">>],
                     slot => 5, approved => 6, eng => Eng, sync => ready}),
    Requested = quod_simplex:watch_requested(7, Pipelined),
    ?assertEqual(7, quod_simplex:test_requested(Requested)),
    ?assertEqual({6, awaiting_commit, true},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(Requested))),
    ParentFinal = st(#{self => <<"self">>, validators => [<<"self">>],
                       slot => 6, approved => 6,
                       requested_slot => quod_simplex:test_requested(Requested),
                       eng => quod_simplex:eng_new([<<"self">>], 6), sync => ready}),
    ?assertEqual({7, awaiting_proposal, true},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(ParentFinal))).

%% A complaint may finalize its slot synchronously before the amplification caller retains the demand.
%% Finalized demand must stay cleared; a genuinely later pipelined request is preserved.
finalized_request_is_not_resurrected_test() ->
    Eng = quod_simplex:eng_new([<<"self">>], 6),
    Final = st(#{self => <<"self">>, validators => [<<"self">>],
                 slot => 6, approved => 6, eng => Eng, sync => ready,
                 requested_slot => 6}),
    Cleared = quod_simplex:watch_requested(6, Final),
    ?assertEqual(none, quod_simplex:test_requested(Cleared)),
    Later = quod_simplex:watch_requested(
              6, st(#{self => <<"self">>, validators => [<<"self">>],
                      slot => 6, approved => 6, eng => Eng, sync => ready,
                      requested_slot => 7})),
    ?assertEqual(7, quod_simplex:test_requested(Later)).

%% A peer counts only after reporting readiness on the authenticated inbound stream that carries its
%% votes. Our own outbound stream may still be opening; that does not hide a peer that can already vote.
inbound_link_counts_toward_quorum_test() ->
    [{A, _}, {B, _}, {C, _}, {_D, _}] = Committee = committee(4),
    Inbound = #{B => {self(), make_ref()}, C => {self(), make_ref()}},
    S = st(#{self => A, validators => pubs(Committee), slot => 5, approved => 5,
             eng => quod_simplex:eng_new(pubs(Committee), 5), sync => ready,
             inbound_conns => Inbound,
             peer_readiness => voting_readiness([B, C], self(), 5),
             head_progress => {6, awaiting_proposal, false}}),
    ?assertEqual({6, awaiting_proposal, true},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(S))).

%% Open authenticated streams alone are not evidence that a restarted peer has recovered enough state to
%% vote. A current-height heartbeat turns the same links into a ready quorum; a behind heartbeat does not.
socket_only_quorum_is_not_ready_test() ->
    [{A, _}, {B, _}, {C, _}, {_D, _}] = Committee = committee(4),
    Links = #{B => {self(), make_ref()}, C => {self(), make_ref()}},
    Common = #{self => A, validators => pubs(Committee), slot => 5, approved => 5,
               eng => quod_simplex:eng_new(pubs(Committee), 5), sync => ready,
               inbound_conns => Links, head_progress => {6, awaiting_proposal, false}},
    SocketOnly = quod_simplex:reconcile_head_progress(st(Common)),
    ?assertEqual({6, awaiting_proposal, false},
                 quod_simplex:test_progress(SocketOnly)),
    Behind = quod_simplex:reconcile_head_progress(
               st(Common#{peer_readiness => voting_readiness([B, C], self(), 4)})),
    ?assertEqual({6, awaiting_proposal, false},
                 quod_simplex:test_progress(Behind)),
    Now = quod_time:mono_ms(),
    Stale = maps:from_list([{Peer, {self(), 5, true, Now - 3001}} ||
                               Peer <- [B, C]]),
    StaleState = quod_simplex:reconcile_head_progress(
                   st(Common#{peer_readiness => Stale})),
    ?assertEqual({6, awaiting_proposal, false},
                 quod_simplex:test_progress(StaleState)),
    OtherLink = spawn(fun() -> receive stop -> ok end end),
    WrongGeneration = voting_readiness([B, C], OtherLink, 5),
    WrongState = quod_simplex:reconcile_head_progress(
                   st(Common#{peer_readiness => WrongGeneration})),
    ?assertEqual({6, awaiting_proposal, false},
                 quod_simplex:test_progress(WrongState)),
    OtherLink ! stop,
    Ready = quod_simplex:reconcile_head_progress(
              st(Common#{peer_readiness => voting_readiness([B, C], self(), 5)})),
    ?assertEqual({6, awaiting_proposal, true},
                 quod_simplex:test_progress(Ready)).

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

%% Exercise every watchdog decision boundary directly: a ready node with quorum complains, a ready node
%% without quorum pauses, and a recovering node merely probes. Readiness restoration replaces the timer
%% with a fresh full Delta; losing quorum leaves the existing timer untouched.
progress_timeout_branches_test() ->
    [{A, IdA}, {B, _}, {C, _}, {D, _}] = Committee = committee(4),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    try
        Eng = quod_simplex:eng_new(pubs(Committee), 5),
        Full = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
                 D => {Sink, make_ref()}},
        Readiness = voting_readiness([B, C, D], Sink, 5),
        Common = #{self => A, id => IdA, validators => pubs(Committee),
                   slot => 5, approved => 5, eng => Eng,
                   head_progress => {6, awaiting_proposal, true}},
        Complained = quod_simplex:on_progress_timeout(
                       6, st(Common#{sync => ready, inbound_conns => Full,
                                     peer_readiness => Readiness})),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, Complained)),
        ?assertEqual({1, 0}, quod_simplex:test_progress_counts(Complained)),

        Sparse = #{B => {Sink, make_ref()}},
        Dialing = #{C => 999999999999, D => 999999999999},
        Paused = quod_simplex:on_progress_timeout(
                   6, st(Common#{sync => ready, inbound_conns => Sparse,
                                 peer_readiness => Readiness, dialing => Dialing,
                                 head_progress => {6, awaiting_proposal, false}})),
        ?assertEqual({none, false, false}, quod_simplex:test_round(6, Paused)),
        ?assertEqual({1, 1}, quod_simplex:test_progress_counts(Paused)),

        Recovering = quod_simplex:on_progress_timeout(
                       6, st(Common#{sync => unconfirmed, inbound_conns => Sparse,
                                     peer_readiness => Readiness, dialing => Dialing,
                                     head_progress => {6, awaiting_proposal, false}})),
        ?assertEqual({none, false, false}, quod_simplex:test_round(6, Recovering)),
        ?assertEqual({1, 0}, quod_simplex:test_progress_counts(Recovering)),

        Disconnected = st(Common#{sync => ready,
                                  head_progress => {6, awaiting_proposal, false}}),
        Connected = st(Common#{sync => ready,
                               head_progress => {6, awaiting_proposal, true}}),
        ?assertMatch([{{timeout, progress}, _, {progress_timeout, 6}}],
                     quod_simplex:progress_timer_actions(Disconnected, Connected)),
        ?assertEqual([], quod_simplex:progress_timer_actions(Connected, Disconnected))
    after
        exit(Sink, kill)
    end.

%% A valid proposal received while recovery forbids voting is retained without starting a complaint timer.
%% Once ready, the node watches it and its first timeout emits ordinary support rather than skipping it.
ready_after_passive_ingest_supports_before_complaining_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Tx = signed_tx(<<"t">>, <<"passive-recovery">>,
                   [{assert, {{recovered, proposal}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = [Tx]},
    BH = quod_simplex:block_hash(Block),
    {Eng, []} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    try
        Inbound = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
                    D => {Sink, make_ref()}},
        Readiness = voting_readiness([B, C, D], Sink, 5),
        Recovering = st(#{self => A, id => IdA, validators => pubs(Committee),
                          slot => 5, approved => 5, eng => Eng, sync => unconfirmed,
                          inbound_conns => Inbound, peer_readiness => Readiness}),
        ?assertEqual(idle, quod_simplex:test_progress(
                             quod_simplex:reconcile_head_progress(Recovering))),
        Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 5, approved => 5, eng => Eng, sync => ready,
                     inbound_conns => Inbound, peer_readiness => Readiness}),
        Watched = quod_simplex:reconcile_head_progress(Ready),
        ?assertEqual({6, awaiting_notarization, true},
                     quod_simplex:test_progress(Watched)),
        Supported = quod_simplex:on_progress_timeout(6, Watched),
        ?assertEqual({BH, false, false}, quod_simplex:test_round(6, Supported))
    after
        exit(Sink, kill)
    end.

%% Live recovery regression: the below-quorum survivors may already have support-signed the retained
%% proposal. When quorum returns, their first timeout must re-echo support and leave complaint unsigned,
%% giving the leader's proposal redrive one Delta to reach a recovered voter. The grace is exactly once:
%% if notarization still does not form, the following timeout may complain and preserve leader-failure
%% liveness.
supported_proposal_gets_one_redrive_before_complaint_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Tx = signed_tx(<<"t">>, <<"supported-recovery">>,
                   [{assert, {{recovered, supported}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = [Tx]},
    BH = quod_simplex:block_hash(Block),
    {Eng, []} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    try
        Inbound = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
                    D => {Sink, make_ref()}},
        Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 5, approved => 5, eng => Eng, sync => ready,
                     inbound_conns => Inbound,
                     peer_readiness => voting_readiness([B, C, D], Sink, 5),
                     head_progress => {6, awaiting_notarization, true}}),

        Supported = quod_simplex:on_progress_timeout(6, Ready),
        ?assertEqual({BH, false, false}, quod_simplex:test_round(6, Supported)),
        ?assertNot(quod_simplex:test_support_grace(Supported)),

        Retried = quod_simplex:on_progress_timeout(6, Supported),
        ?assertEqual({BH, false, false}, quod_simplex:test_round(6, Retried)),
        ?assert(quod_simplex:test_support_grace(Retried)),

        Complained = quod_simplex:on_progress_timeout(6, Retried),
        ?assertEqual({BH, false, true}, quod_simplex:test_round(6, Complained))
    after
        exit(Sink, kill)
    end.

%% A retained leader proposal must be queued for validators that are not connected yet. The old live-link
%% filter omitted them entirely, so a recovered validator could advertise readiness but never receive the
%% proposal whose support was needed to complete notarization.
redrive_queues_proposal_for_disconnected_validators_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Tx = signed_tx(<<"t">>, <<"redrive-disconnected">>,
                   [{assert, {{recovered, redrive}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = [Tx]},
    BH = quod_simplex:block_hash(Block),
    {Eng, []} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
    S = st(#{self => A, id => IdA, validators => pubs(Committee),
             slot => 5, approved => 5, eng => Eng, sync => ready}),
    Redriven = quod_simplex:test_redrive_head(6, BH, S),
    ?assertEqual({[], [], lists:sort([B, C, D]), lists:sort([B, C, D])},
                 quod_simplex:test_link_peers(Redriven)).

%% A validator that has a support certificate but lost the corresponding block asks one holder at a
%% time. The request itself is tiny; it must not fan a complete block out from every validator.
certified_block_request_targets_one_holder_test() ->
    Committee = [{A, IdA} | _] = committee(4),
    Tx = signed_tx(<<"t">>, <<"missing-block">>,
                   [{assert, {{recovered, block}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = [Tx]},
    {Eng, _} = feed_shares(supports(Block, Committee, 3),
                           quod_simplex:eng_new(pubs(Committee), 5)),
    Missing = st(#{self => A, id => IdA, validators => pubs(Committee),
                   slot => 5, approved => 5, eng => Eng, sync => ready}),

    Requested = quod_simplex:reconcile_block_requests(Missing),
    {[], [], OutboxPeers, DialPeers} = quod_simplex:test_link_peers(Requested),
    ?assertEqual(1, length(OutboxPeers)),
    ?assertEqual(OutboxPeers, DialPeers),
    ?assertEqual(1, map_size(quod_simplex:test_block_requests(Requested))).

%% Any active validator holding both the exact block and its support certificate may answer, but an
%% authenticated non-member cannot use block recovery as an oracle or make the node queue large frames.
certified_block_request_is_committee_scoped_test() ->
    Committee = [{A, IdA}, {B, _} | _] = committee(4),
    Tx = signed_tx(<<"t">>, <<"serve-certified-block">>,
                   [{assert, {{recovered, served}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = [Tx]},
    BH = quod_simplex:block_hash(Block),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 3), Eng1),
    Holder = st(#{self => B, validators => pubs(Committee), slot => 5,
                  approved => 6, eng => Eng2, sync => ready}),

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
    Block = #block{slot = 6, parent = 5, payload = [Tx]},
    BH = quod_simplex:block_hash(Block),
    SupportShares = supports(Block, Committee, 3),
    {ok, Cert} = quod_simplex:form_cert(support, 6, BH, SupportShares, pubs(Committee)),
    {CertOnly, _} = feed_shares(SupportShares, quod_simplex:eng_new(pubs(Committee), 5)),
    Requester = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 5, approved => 5, eng => CertOnly, sync => ready,
                     block_requests => #{{6, BH} => {1, 0}}}),
    Leader = quod_simplex:leader(6, pubs(Committee)),
    Sender = hd([Peer || {Peer, _} <- Peers, Peer =/= Leader]),

    Restored = quod_simplex:dispatch(Sender, {certified_block, Block, Cert}, Requester),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Restored)),
    ?assertEqual(0, map_size(quod_simplex:test_block_requests(Restored))).

certified_block_response_requires_outstanding_request_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Tx = signed_tx(<<"t">>, <<"unsolicited-certified-block">>,
                   [{assert, {{recovered, requested_only}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = [Tx]},
    BH = quod_simplex:block_hash(Block),
    SupportShares = supports(Block, Committee, 3),
    {ok, Cert} = quod_simplex:form_cert(support, 6, BH, SupportShares,
                                        pubs(Committee)),
    {CertOnly, _} = feed_shares(SupportShares,
                                quod_simplex:eng_new(pubs(Committee), 5)),
    S = st(#{self => A, id => IdA, validators => pubs(Committee),
             slot => 5, approved => 5, eng => CertOnly, sync => ready}),
    Sender = element(1, hd(Peers)),

    Ignored = quod_simplex:dispatch(Sender, {certified_block, Block, Cert}, S),
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
    Losing = #block{slot = 6, parent = 5,
                    payload = [signed_tx(<<"t">>, <<"losing-support">>,
                                             [{assert, {{proposal, losing}, true}}],
                                             {Leader, LeaderId})]},
    Winning = #block{slot = 6, parent = 5,
                     payload = [signed_tx(<<"t">>, <<"winning-support">>,
                                              [{assert, {{proposal, winning}, true}}],
                                              hd(OtherValidators))]},
    WinningHash = quod_simplex:block_hash(Winning),
    {ok, WinningCert} = quod_simplex:form_cert(
                          support, 6, WinningHash,
                          supports(Winning, OtherValidators, 3), Validators),
    Initial = st(#{self => Self, id => SelfId, validators => Validators,
                   slot => 5, approved => 5,
                   eng => quod_simplex:eng_new(Validators, 5), sync => ready}),
    SupportedLosing = quod_simplex:dispatch(Leader, {propose, Losing}, Initial),
    LosingHash = quod_simplex:block_hash(Losing),
    ?assertEqual({LosingHash, false, false},
                 quod_simplex:test_round(6, SupportedLosing)),
    HasCertificate = quod_simplex:dispatch(Leader, {cert, WinningCert}, SupportedLosing),
    Requested = quod_simplex:reconcile_block_requests(HasCertificate),
    Sender = element(1, hd(OtherValidators)),

    Restored = quod_simplex:dispatch(
                 Sender, {certified_block, Winning, WinningCert}, Requested),
    ?assertEqual({LosingHash, true, false}, quod_simplex:test_round(6, Restored)),
    ?assertEqual(0, map_size(quod_simplex:test_block_requests(Restored))).

certified_block_hash_mismatch_is_rejected_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Tx = signed_tx(<<"t">>, <<"certified-good">>,
                   [{assert, {{recovered, correct}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = [Tx]},
    BH = quod_simplex:block_hash(Block),
    {ok, Cert} = quod_simplex:form_cert(
                   support, 6, BH, supports(Block, Committee, 3), pubs(Committee)),
    Different = Block#block{timestamp = 1},
    DifferentHash = quod_simplex:block_hash(Different),
    S = st(#{self => A, id => IdA, validators => pubs(Committee),
             slot => 5, approved => 5,
             eng => quod_simplex:eng_new(pubs(Committee), 5), sync => ready,
             block_requests => #{{6, DifferentHash} => {1, 0}}}),
    Rejected = quod_simplex:dispatch(element(1, hd(Peers)),
                                     {certified_block, Different, Cert}, S),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6, Rejected)).

%% Recovery metrics count signatures carried by a verified certificate even when individual share frames
%% were not received, and expose the exact "certificate present, block absent" condition.
recovery_stats_include_certificate_evidence_test() ->
    Committee = [{A, _} | _] = committee(4),
    Block = blk(6),
    BH = quod_simplex:block_hash(Block),
    {ok, Cert} = quod_simplex:form_cert(
                   support, 6, BH, supports(Block, Committee, 3), pubs(Committee)),
    {CertOnly, _} = quod_simplex:eng_offer(
                      {cert, Cert}, quod_simplex:eng_new(pubs(Committee), 5)),
    Stats = quod_simplex:stats_map(
              st(#{self => A, validators => pubs(Committee), slot => 5,
                   approved => 5, eng => CertOnly, sync => ready})),
    ?assertEqual(3, maps:get(head_support_votes, Stats)),
    ?assertEqual(0, maps:get(head_commit_votes, Stats)),
    ?assertEqual(0, maps:get(head_complaint_votes, Stats)),
    ?assertEqual(1, maps:get(missing_certified_blocks, Stats)).

%% Quorum restoration may grant a few fresh Deltas for transient reconnects, but an unchanged slot/phase
%% eventually exhausts that budget. Further false->true flaps leave the existing deadline untouched.
quorum_restoration_rearm_is_bounded_test() ->
    Common = #{slot => 5, approved => 5, eng => quod_simplex:eng_new([<<"self">>], 5),
               self => <<"self">>, validators => [<<"self">>], sync => ready},
    BelowCap = st(Common#{head_progress => {6, awaiting_proposal, false, 2, true}}),
    Restored = quod_simplex:reconcile_head_progress(BelowCap),
    ?assertEqual(3, quod_simplex:test_progress_rearms(Restored)),
    ?assertNot(quod_simplex:test_support_grace(Restored)),
    ?assertMatch([{{timeout, progress}, _, {progress_timeout, 6}}],
                 quod_simplex:progress_timer_actions(BelowCap, Restored)),
    AtCap = st(Common#{head_progress => {6, awaiting_proposal, false, 3, true}}),
    Capped = quod_simplex:reconcile_head_progress(AtCap),
    ?assertEqual(3, quod_simplex:test_progress_rearms(Capped)),
    ?assert(quod_simplex:test_support_grace(Capped)),
    ?assertEqual([], quod_simplex:progress_timer_actions(AtCap, Capped)),
    NewPhase = st(Common#{approved => 6,
                         head_progress => {6, awaiting_notarization, false, 3, true}}),
    Advanced = quod_simplex:reconcile_head_progress(NewPhase),
    ?assertEqual(0, quod_simplex:test_progress_rearms(Advanced)),
    ?assertNot(quod_simplex:test_support_grace(Advanced)).

%% A block can be notarized while a restarted member is still `unconfirmed`: it is deliberately forbidden
%% to vote, and the engine's one-shot notarized event is consumed. Regaining `ready` must reconstruct the
%% commit latch from the complete tree, otherwise this validator never contributes to finality. It must
%% not invent a support vote: membership support requires a separate local KB verdict.
resume_notarized_after_recovery_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Block = blk(6),
    {Eng1, _} = quod_simplex:eng_offer({block, Block},
                                       quod_simplex:eng_new(pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 3), Eng1),
    ?assert(maps:is_key(6, quod_simplex:eng_tree(Eng2))),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    Conns = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
              D => {Sink, make_ref()}},
    Recovering = st(#{self => A, id => IdA, validators => pubs(Committee),
                      slot => 5, approved => 6, eng => Eng2,
                      sync => unconfirmed, conns => Conns}),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6, Recovering)),
    ?assertEqual({none, false, false},
                 quod_simplex:test_round(
                   6, quod_simplex:resume_ready_rounds(Recovering))),

    Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 6, eng => Eng2,
                 sync => ready, conns => Conns}),
    Resumed = quod_simplex:resume_ready_rounds(Ready),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Resumed)),
    exit(Sink, kill).

%% A recovered validator must not blindly join the commit side of a notarized
%% round when f+1 distinct peers have already complaint-signed the durable
%% head. At N=10, four complaint latches leave at most six commit-eligible
%% validators, so choosing commit would recreate the permanent 4/6 split seen
%% at live slot 6180. Complaint evidence is deliberately below certificate
%% quorum here: this exercises camp selection, not ordinary skip processing.
resume_notarized_joins_amplified_complaint_test() ->
    Committee = [{A, IdA} | Peers] = committee(10),
    Block = blk(6),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 7), Eng1),
    Complaints = [quod_simplex:make_share(complaint, 6, none, Id)
                  || {_Pub, Id} <- take(4, Peers)],
    {Eng3, _} = feed_shares(Complaints, Eng2),
    Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 6, eng => Eng3, sync => ready}),

    Resumed = quod_simplex:resume_ready_rounds(Ready),
    ?assertEqual({none, false, true}, quod_simplex:test_round(6, Resumed)).

%% Approval does not close complaint amplification. The fourth peer complaint at N=10 is f+1 evidence;
%% an uncommitted head already awaiting final votes must join the skip side instead of freezing a 4/6 split.
awaiting_commit_joins_amplified_complaint_test() ->
    Committee = [{A, IdA} | Peers] = committee(10),
    Block = blk(6),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 7), Eng1),
    ComplaintShares = [{Pub, quod_simplex:make_share(complaint, 6, none, Id)}
                       || {Pub, Id} <- take(4, Peers)],
    Prefix = [Share || {_Pub, Share} <- take(3, ComplaintShares)],
    {Eng3, _} = feed_shares(Prefix, Eng2),
    [{LastPeer, LastShare}] = lists:nthtail(3, ComplaintShares),
    AwaitingCommit = st(#{self => A, id => IdA, validators => pubs(Committee),
                          slot => 5, approved => 6, eng => Eng3, sync => ready,
                          head_progress => {6, awaiting_commit, true}}),

    Joined = quod_simplex:dispatch(LastPeer, {share, LastShare}, AwaitingCommit),
    ?assertEqual({none, false, true}, quod_simplex:test_round(6, Joined)).

%% Final-vote ownership covers the complete depth-one pipeline, not only committed+1. A child already
%% notarized over the head must join amplified skip evidence immediately; its skip is buffered until the
%% parent finalizes, but the two slots do not need serial evidence collection.
pipelined_child_joins_amplified_complaint_test() ->
    Committee = [{A, IdA} | Peers] = committee(10),
    Parent = blk(6),
    Child = blk(7),
    {E1, _} = quod_simplex:eng_offer(
                {block, Parent}, quod_simplex:eng_new(pubs(Committee), 5)),
    {E2, _} = quod_simplex:eng_offer({block, Child}, E1),
    {E3, _} = feed_shares(supports(Parent, Committee, 7), E2),
    {E4, _} = feed_shares(supports(Child, Committee, 7), E3),
    ComplaintShares = [{Pub, quod_simplex:make_share(complaint, 7, none, Id)}
                       || {Pub, Id} <- take(4, Peers)],
    Prefix = [Share || {_Pub, Share} <- take(3, ComplaintShares)],
    {E5, _} = feed_shares(Prefix, E4),
    [{LastPeer, LastShare}] = lists:nthtail(3, ComplaintShares),
    Pipelined = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 5, approved => 7, eng => E5, sync => ready}),

    Joined = quod_simplex:dispatch(LastPeer, {share, LastShare}, Pipelined),
    ?assertEqual({none, false, true}, quod_simplex:test_round(7, Joined)),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6, Joined)).

%% At most f peer complaints cannot steer an unlatched validator away from a notarized block. This pins
%% the threshold so Byzantine validators alone cannot force the honest committee onto the skip side.
resume_notarized_commits_below_complaint_amplification_test() ->
    Committee = [{A, IdA} | Peers] = committee(10),
    Block = blk(6),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 7), Eng1),
    Complaints = [quod_simplex:make_share(complaint, 6, none, Id)
                  || {_Pub, Id} <- take(3, Peers)],
    {Eng3, _} = feed_shares(Complaints, Eng2),
    Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 6, eng => Eng3, sync => ready}),

    Resumed = quod_simplex:resume_ready_rounds(Ready),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Resumed)).

%% Live commit/skip self-corroboration can restore voting between periodic ticks. The common transition
%% hook must reconcile an already-notarized successor immediately on that false->true capability edge.
live_finality_ready_edge_resumes_successor_test() ->
    Committee = [{A, IdA}, {_, _}, {_, _}, {_, _}] = committee(4),
    Block = blk(6),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 3), Eng1),
    Before = st(#{self => A, id => IdA, validators => pubs(Committee),
                  slot => 5, approved => 6, eng => Eng2, sync => unconfirmed}),
    After = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 6, eng => Eng2, sync => ready}),
    Settled = quod_simplex:settle_readiness(Before, After),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Settled)).

%% The recovery fold snapshots slot numbers. An earlier iteration can commit and prune a buffered successor;
%% revisiting that stale snapshot entry must be a no-op rather than maps:get(tree_hashes) crashing the statem.
resume_stale_snapshot_slot_is_skipped_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    [{A, IdA}] = Committee = committee(1),
    B6 = blk(6),
    B7 = blk(7),
    {E1, _} = quod_simplex:eng_offer(
                {block, B6}, quod_simplex:eng_new(pubs(Committee), 5)),
    {E2, _} = quod_simplex:eng_offer({block, B7}, E1),
    {E3, _} = feed_shares(supports(B6, Committee, 1) ++
                          supports(B7, Committee, 1), E2),
    B7Hash = quod_simplex:block_hash(B7),
    B7Commit = quod_simplex:make_share(commit, 7, B7Hash, IdA),
    {ok, B7Cert} = quod_simplex:form_cert(
                     commit, 7, B7Hash, [B7Commit], pubs(Committee)),
    Eng = quod_simplex:eng_buffered_commit(7, B7, B7Cert, E3),
    Dir = filename:join(
            "/tmp", "quod_resume_snapshot_" ++
                    integer_to_list(erlang:unique_integer([positive]))),
    {ok, Store0} = quod_ledger_store:open(<<"t">>, Dir),
    Prefix = [#entry{index = I, data = noop, timestamp = I} ||
                 I <- lists:seq(1, 5)],
    {ok, Store1} = quod_ledger_store:append(Store0, Prefix),
    try
        Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 5, approved => 7, eng => Eng, sync => ready,
                     store => Store1, last_applied => 5,
                     commit_buf => #{7 => {commit, B7}}}),
        Resumed = quod_simplex:resume_ready_rounds(Ready),
        {7, FinalStore} = quod_simplex:test_committed_store(Resumed),
        ?assertMatch({ok, #entry{index = 6}},
                     quod_ledger_store:read_at(FinalStore, 6)),
        ?assertMatch({ok, #entry{index = 7}},
                     quod_ledger_store:read_at(FinalStore, 7))
    after
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

%% More than one notarized entry may be present when recovery grants voting capability. Reconcile every
%% still-live tree slot, but create final-vote latches only; no synthetic support vote is permitted.
resume_multiple_notarized_slots_test() ->
    Committee = [{A, IdA}, {_, _}, {_, _}, {_, _}] = committee(4),
    B6 = blk(6),
    B7 = blk(7),
    {E1, _} = quod_simplex:eng_offer({block, B6},
                                     quod_simplex:eng_new(pubs(Committee), 5)),
    {E2, _} = quod_simplex:eng_offer({block, B7}, E1),
    {E3, _} = feed_shares(supports(B6, Committee, 3), E2),
    {E4, _} = feed_shares(supports(B7, Committee, 3), E3),
    Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 7, eng => E4, sync => ready}),
    Resumed = quod_simplex:resume_ready_rounds(Ready),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Resumed)),
    ?assertEqual({none, true, false}, quod_simplex:test_round(7, Resumed)).

%% Membership proposals use the same final-vote recovery but retain their stricter support boundary:
%% recovery may commit a quorum-notarized block and must never manufacture the skipped local KB verdict.
resume_membership_notarization_does_not_support_test() ->
    Committee = [{A, IdA}, {_, _}, {_, _}, {_, _}] = committee(4),
    {E, _NewId} = id(),
    Membership = signed_tx(<<"t">>, <<"recovery-membership">>, [pa(E)], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = [Membership]},
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 3), Eng1),
    Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 6, eng => Eng2, sync => ready}),
    Resumed = quod_simplex:resume_ready_rounds(Ready),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Resumed)).

%% A restart reloads the validator's own final-vote decision before recovery sees network evidence. A
%% notarized block therefore cannot recruit a validator that complaint-signed this slot before crashing.
restart_preserves_complaint_latch_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    Dir = filename:join("/tmp", "quod_simplex_vote_restart_" ++
                                integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_vote_journal:open(<<"t">>, Dir, 5),
        Inbound = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
                    D => {Sink, make_ref()}},
        Readiness = voting_readiness([B, C, D], Sink, 5),
        EmptyEng = quod_simplex:eng_new(pubs(Committee), 5),
        BeforeCrash = st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 5, approved => 5, eng => EmptyEng, sync => ready,
                           vote_journal => Journal0,
                           inbound_conns => Inbound, peer_readiness => Readiness,
                           head_progress => {6, awaiting_proposal, true}}),
        Complained = quod_simplex:on_progress_timeout(6, BeforeCrash),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, Complained)),
        ok = quod_vote_journal:close(quod_simplex:test_vote_journal(Complained)),

        Block = blk(6),
        {E1, _} = quod_simplex:eng_offer(
                    {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
        {Notarized, _} = feed_shares(supports(Block, Committee, 3), E1),
        {ok, Journal1} = quod_vote_journal:open(<<"t">>, Dir, 5),
        Restarted = quod_simplex:restore_vote_rounds(
                      st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 5, approved => 6, eng => Notarized, sync => ready,
                           vote_journal => Journal1})),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, Restarted)),
        AfterRestart = quod_simplex:resume_ready_rounds(Restarted),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, AfterRestart)),
        ok = quod_vote_journal:close(quod_simplex:test_vote_journal(AfterRestart))
    after
        exit(Sink, kill),
        file:del_dir_r(Dir)
    end.

%% The opposite final camp is equally durable. Once recovery commit-signs a notarized block, reopening the
%% journal must keep later amplified complaint evidence from moving this validator to the skip side.
restart_preserves_commit_latch_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Block = blk(6),
    {E1, _} = quod_simplex:eng_offer(
                {block, Block}, quod_simplex:eng_new(pubs(Committee), 5)),
    {Notarized, _} = feed_shares(supports(Block, Committee, 3), E1),
    Dir = filename:join("/tmp", "quod_simplex_commit_restart_" ++
                                integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_vote_journal:open(<<"t">>, Dir, 5),
        BeforeCrash = st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 5, approved => 6, eng => Notarized, sync => ready,
                           vote_journal => Journal0}),
        Committed = quod_simplex:resume_ready_rounds(BeforeCrash),
        ?assertEqual({none, true, false}, quod_simplex:test_round(6, Committed)),
        ok = quod_vote_journal:close(quod_simplex:test_vote_journal(Committed)),

        Complaints = [quod_simplex:make_share(complaint, 6, none, Id)
                      || {_Pub, Id} <- take(2, Peers)],
        {WithComplaints, _} = feed_shares(Complaints, Notarized),
        {ok, Journal1} = quod_vote_journal:open(<<"t">>, Dir, 5),
        Restarted = quod_simplex:restore_vote_rounds(
                      st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 5, approved => 6, eng => WithComplaints, sync => ready,
                           vote_journal => Journal1})),
        ?assertEqual({none, true, false}, quod_simplex:test_round(6, Restarted)),
        StillCommitted = quod_simplex:resume_ready_rounds(Restarted),
        ?assertEqual({none, true, false}, quod_simplex:test_round(6, StillCommitted)),
        ok = quod_vote_journal:close(quod_simplex:test_vote_journal(StillCommitted))
    after
        file:del_dir_r(Dir)
    end.

%% Drive the repaired liveness path through the state-machine boundary: f+1 peer complaints for an already
%% notarized head recruit this validator, its durable share completes the skip certificate, the noop is
%% appended, and the rotated slot then accepts and commits a normal signed transaction. This is the complete
%% join -> skip -> continue guarantee rather than three isolated predicate assertions.
amplified_complaint_skips_and_next_slot_commits_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = [{Self, SelfId} | Peers] = committee(4),
    Validators = pubs(Committee),
    SkippedBlock = blk(6),
    {E1, _} = quod_simplex:eng_offer(
                {block, SkippedBlock}, quod_simplex:eng_new(Validators, 5)),
    {Notarized, _} = feed_shares(supports(SkippedBlock, Committee, 3), E1),
    [FirstComplainer, SecondComplainer | _] = Peers,
    FirstShare = complaint_share(6, FirstComplainer),
    {WithOneComplaint, _} = feed_shares([FirstShare], Notarized),
    SecondShare = complaint_share(6, SecondComplainer),
    Dir = filename:join("/tmp", "quod_finality_continue_" ++
                                integer_to_list(erlang:unique_integer([positive]))),
    {ok, Store0} = quod_ledger_store:open(<<"t">>, Dir),
    Prefix = [#entry{index = I, data = noop, timestamp = I}
              || I <- lists:seq(1, 5)],
    {ok, Store1} = quod_ledger_store:append(Store0, Prefix),
    {ok, Journal0} = quod_vote_journal:open(<<"t">>, Dir, 5),
    try
        Split = st(#{self => Self, id => SelfId, validators => Validators,
                     slot => 5, approved => 6, eng => WithOneComplaint,
                     sync => ready, store => Store1, vote_journal => Journal0,
                     last_applied => 5}),
        Skipped = quod_simplex:dispatch(
                    element(1, SecondComplainer), {share, SecondShare}, Split),
        {6, Store2} = quod_simplex:test_committed_store(Skipped),
        ?assertMatch({ok, #entry{index = 6, data = noop}},
                     quod_ledger_store:read_at(Store2, 6)),

        Leader7 = quod_simplex:leader(7, Validators),
        {Leader7, LeaderId} = lists:keyfind(Leader7, 1, Committee),
        Tx7 = signed_tx(<<"t">>, <<"after-amplified-skip">>,
                        [{assert, {{after_skip, live}, true}}],
                        {Leader7, LeaderId}),
        Block7 = #block{slot = 7, parent = 6, payload = [Tx7]},
        Proposed = quod_simplex:dispatch(Leader7, {propose, Block7}, Skipped),
        OtherVoters = [Pair || {Pub, _} = Pair <- Committee, Pub =/= Self],
        Supported = dispatch_shares(supports(Block7, OtherVoters, 2), Proposed),
        Final = dispatch_shares(commits(Block7, OtherVoters, 2), Supported),
        {7, FinalStore} = quod_simplex:test_committed_store(Final),
        ?assertMatch({ok, #entry{index = 7}},
                     quod_ledger_store:read_at(FinalStore, 7))
    after
        quod_vote_journal:close(Journal0),
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

%% Content transactions may batch. A committee transaction is legal only as a
%% singleton at the committed frontier, making it a pipeline barrier by construction.
batch_membership_barrier_test() ->
    [{A, IdA}, {B, _IdB}] = committee(2),
    Eng = quod_simplex:eng_new([A, B], 5),
    S0 = st(#{self => A, validators => [A, B], slot => 5, approved => 5,
              eng => Eng, sync => ready}),
    C1 = signed_tx(<<"t">>, <<"one">>, [{assert, {{fact, one}, true}}], {A, IdA}),
    C2 = signed_tx(<<"t">>, <<"two">>, [{assert, {{fact, two}, true}}], {A, IdA}),
    Membership = signed_tx(<<"t">>, <<"membership">>, [pa(B)], {A, IdA}),
    ?assert(quod_simplex:acceptable_payload([C1, C2], S0)),
    ?assertNot(quod_simplex:acceptable_payload([C1, C1], S0)),
    ?assertNot(quod_simplex:acceptable_payload([C1 | malformed_tail], S0)),
    ?assert(quod_simplex:acceptable_payload([Membership], S0)),
    ?assertNot(quod_simplex:acceptable_payload([C1, Membership], S0)),
    S1 = st(#{self => A, validators => [A, B], slot => 5, approved => 6,
              eng => Eng, sync => ready}),
    ?assertNot(quod_simplex:acceptable_payload([Membership], S1)).

transaction_signature_acceptance_test() ->
    [{Author, AuthorId}, {Outsider, OutsiderId}] = committee(2),
    State = st(#{self => Author, validators => [Author], slot => 5,
                 approved => 5, eng => quod_simplex:eng_new([Author], 5),
                 sync => ready}),
    Good = signed_tx(<<"t">>, <<"good">>,
                     [{assert, {{fact, signed}, true}}], {Author, AuthorId}),
    Forged = Good#transaction{sig = flip1(Good#transaction.sig)},
    Unsigned = Good#transaction{sig = none},
    WrongNamespace = signed_tx(
                       <<"other">>, <<"wrong-ns">>,
                       [{assert, {{fact, other}, true}}], {Author, AuthorId}),
    Unauthorized = signed_tx(
                     <<"t">>, <<"outsider">>,
                     [{assert, {{fact, outsider}, true}}], {Outsider, OutsiderId}),
    ?assert(quod_simplex:acceptable_payload([Good], State)),
    ?assertNot(quod_simplex:acceptable_payload([Unsigned], State)),
    ?assertNot(quod_simplex:acceptable_payload([Forged], State)),
    ?assertNot(quod_simplex:acceptable_payload([WrongNamespace], State)),
    ?assertNot(quod_simplex:acceptable_payload([Unauthorized], State)),
    ?assertNot(quod_simplex:acceptable_payload([Good, Forged], State)).

committed_author_sequence_replay_test() ->
    [{Author, AuthorId}] = committee(1),
    State = st(#{self => Author, validators => [Author], slot => 5,
                 approved => 5, eng => quod_simplex:eng_new([Author], 5),
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
    ?assert(quod_simplex:acceptable_payload([Fresh], State)),
    ?assertNot(quod_simplex:acceptable_payload([Replay], State)),
    ?assertNot(quod_simplex:acceptable_payload([Fresh, SameSeq], State)).

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

%% The CROSS-SLOT half of the exclusion, load-bearing for the depth-1 pipeline: committing a block
%% implicitly finalizes its APPROVED PARENT (slot-1), so an honest validator that complained slot v must
%% not commit its child v+1 (that would finalize v — the fork the naive per-slot latch allowed), and
%% symmetrically must not complain v after committing v+1. Without this, a complaint cert on v and a
%% commit cert on v+1 could both form from honest signers and split the committee on v.
cross_slot_exclusion_test() ->
    %% complained the PARENT (4) ⇒ must not commit the child (5), which would implicitly finalize 4
    ?assertNot(quod_simplex:may_commit(5, [4])),
    ?assert(quod_simplex:may_commit(5, [6])),          %% complaining a LATER slot never bars committing 5
    %% committed the CHILD (6) ⇒ must not complain the parent (5), already implicitly finalized
    ?assertNot(quod_simplex:may_complain(5, [6])),
    ?assert(quod_simplex:may_complain(5, [4])),        %% committing an EARLIER slot never bars complaining 5
    %% genesis edge: slot 1's parent is 0 (the origin sentinel), never a votable slot
    ?assert(quod_simplex:may_commit(1, [])),
    ?assertNot(quod_simplex:may_commit(1, [0])).       %% (defensive) 0 in the complained set still bars

%% The FORK the depth-1 pipeline opened, reproduced at the certificate level. A child's commit implicitly
%% finalizes its approved PARENT, so a complaint cert on slot v and a commit cert on its child v+1 must
%% never both form — otherwise v is skipped (noop) on some nodes and block-committed on others. This runs
%% each honest node's REAL guarded vote (may_commit/may_complain over its own latch) across both adversarial
%% orderings and forms the certs with `form_cert`, asserting the two conflicting certs cannot coexist.
%% PRE-FIX (per-slot latch only) BOTH certs formed — the split-brain finalize. Complements the pure-guard
%% cross_slot_exclusion_test with the quorum/cert-formation layer.
fork_certs_cannot_coexist_test() ->
    C    = committee(4),                        %% N=4, quorum(4) = 3
    Vals = pubs(C),
    BH5  = quod_simplex:block_hash(blk(5)),     %% the child block at slot 5 (parent = 4)
    %% (1) every node complains parent 4, THEN is asked to commit child 5: the child-commit cert must NOT form
    {Cpl1, Cmt1} = run_schedule(C, [{complaint, 4, none}, {commit, 5, BH5}]),
    ?assertMatch({ok, _}, quod_simplex:form_cert(complaint, 4, none, Cpl1, Vals)),   %% parent-skip cert forms
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(commit, 5, BH5, Cmt1, Vals)),
    %% (2) mirror — every node commits child 5 (finalizing 4), THEN is asked to complain 4: the skip cert must NOT form
    {Cpl2, Cmt2} = run_schedule(C, [{commit, 5, BH5}, {complaint, 4, none}]),
    ?assertMatch({ok, _}, quod_simplex:form_cert(commit, 5, BH5, Cmt2, Vals)),       %% child-commit cert forms
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(complaint, 4, none, Cpl2, Vals)).

%% A batch still being COLLECTED (not yet sealed into a proposal) whose slot is complaint-skipped must nack
%% its parked callers {error, skipped} so they retry at once. Pre-fix, finalize/2 dropped the batch silently
%% (clear_collecting_le) and the caller heard nothing, hanging until the ~30s park TTL; the former API then
%% incorrectly reported failure instead of the immediate retryable {error, skipped}.
skipped_batch_nacks_its_callers_test() ->
    Ref  = make_ref(),
    From = {self(), Ref},
    S = quod_simplex:test_state(#{slot => 4, eng => quod_simplex:eng_with_certs(4, []),
                                  collecting => {5, [From]}}),
    _ = quod_simplex:finalize(5, S),   %% slot 5 finalized (skipped) while its batch was still collecting
    receive
        {_Tag, Reply} -> ?assertEqual({error, skipped}, Reply)
    after 0 -> ?assert(false)          %% no reply => the caller would hang to the park TTL (the bug)
    end.

%% A competing block can notarize while this leader is still collecting its own batch for the same slot.
%% The approval frontier then moves past the collection; it must be nacked immediately rather than leaving
%% a stale batch that makes the next append miss every `collect_append` clause and crash the statem.
competing_notarization_nacks_collected_batch_test() ->
    Ref = make_ref(),
    From = {self(), Ref},
    S = quod_simplex:test_state(
          #{slot => 4, approved => 4, eng => quod_simplex:eng_with_certs(4, []),
            collecting => {5, [From]}}),
    _ = quod_simplex:approve_block(blk(5), S),
    receive
        {_Tag, Reply} -> ?assertEqual({error, skipped}, Reply)
    after 0 -> ?assert(false)
    end.

%% Batch capacity limits, driven through the real append entry (running/3). An oversized single change is
%% rejected fast ({error, too_large}) so a block can never blow past the wire frame; a leader whose
%% depth-one pipeline is already full now PARKS the append in the bounded ingress queue instead of
%% rejecting {error, busy} — the caller waits for the pipeline's own events, not a retry timer.
batch_caps_reject_oversized_and_park_test() ->
    {Me, Id} = id(),
    Base = #{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             eng => quod_simplex:eng_with_certs(0, [])},   %% a caught-up sole leader
    From = {self(), make_ref()},
    %% oversized single transaction (> MAX_BLOCK_BYTES = 256 KiB) => too_large, never batched, never parked
    Big  = #transaction{tx_id = <<"big">>, caller_ns = <<"t">>, author = Me, sig = none, read_check = #{},
                        diff = [{assert, {{blob, binary:copy(<<0>>, 300 * 1024)}, true}}]},
    {keep_state, _, A1} = quod_simplex:running({call, From}, {append, Big}, st(Base)),
    ?assert(lists:member({reply, From, {error, too_large}}, A1)),
    %% depth-one pipeline already full (committed 3, approved 5 => gap 2, the max): the append PARKS —
    %% no reply action, no busy, one queued item under this author.
    Small = #transaction{tx_id = <<"s">>, caller_ns = <<"t">>, author = Me, sig = none, read_check = #{},
                         diff = [{assert, {{k, v}, true}}]},
    {keep_state, SParked, A2} =
        quod_simplex:running({call, From}, {append, Small}, st(Base#{approved => 5})),
    ?assertEqual([], [R || {reply, _, _} = R <- A2]),
    {1, _, Authors, [{local, <<"s">>, _}]} = quod_simplex:test_ingress(SParked),
    ?assertEqual(#{Me => 1}, Authors),
    ?assertEqual(0, maps:get(r_busy, quod_simplex:stats_map(SParked))),
    %% a change whose tx_id is already in the collecting batch is rejected (no double-apply of one write)
    {keep_state, S1, _} = quod_simplex:running({call, From}, {append, Small}, st(Base)),   %% collect Small
    {keep_state, _, A3} = quod_simplex:running({call, From}, {append, Small}, S1),          %% same tx_id
    ?assert(lists:member({reply, From, {error, bad_change}}, A3)).

%%%===================================================================
%%% ingress park queue — park, drain, forward, expire (event-driven ingress)
%%%===================================================================

lt(N) -> #transaction{tx_id = <<"lt", N>>, caller_ns = <<"t">>, author = undefined,
                      sig = none, read_check = #{},
                      diff = [{assert, {{loadfact, N}, true}}]}.
lt(N, Author) -> (lt(N))#transaction{author = Author}.

%% Two parked items drain into ONE immediately-sealed block the moment the pipeline
%% opens — no micro-batch window for backlog that already waited a full flight.
%% Planting the blocked queue directly keeps this test about drain/seal,
%% independently of source-side target selection.
multi_item_drain_seals_one_block_test() ->
    Committee = committee(3),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, approved => 5,
                   eng => quod_simplex:eng_with_certs(3, [])}),
    F1 = {self(), make_ref()}, F2 = {self(), make_ref()},
    P2 = quod_simplex:test_state_set(
           ingress,
           [{local, F1, lt($a, Me), quod_time:mono_ms()},
            {local, F2, lt($b, Me), quod_time:mono_ms() + 1}],
           Blocked),
    {2, _, _, [{local, <<"lt", $a>>, _}, {local, <<"lt", $b>>, _}]} =
        quod_simplex:test_ingress(P2),
    %% pipeline opens (approval frontier back at the durable head) => drain pours + seals NOW
    Opened = quod_simplex:test_state_set(approved, 3, P2),
    ?assert(quod_simplex:test_ingress_needs_drain(P2, Opened)),
    {Drained, Actions} = quod_simplex:test_drain(Opened),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    %% sealed immediately: no open batch survives, both waiters sit on the in-flight
    %% proposal (pending counts local_proposal waiters), the head watchdog is armed.
    ?assert(lists:member({{timeout, batch}, cancel}, Actions)),
    ?assertMatch({4, _, _}, quod_simplex:test_progress(Drained)),
    ?assertEqual(2, maps:get(pending, quod_simplex:stats_map(Drained))),
    ?assertEqual(2, maps:get(batched_txs, quod_simplex:stats_map(Drained))).

%% A singleton drain keeps the normal micro-batch window (its arm action threads out),
%% so the post-rotation re-send wave can still join the same block.
singleton_drain_keeps_batch_window_test() ->
    Committee = committee(3),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, approved => 5,
                   batch_window_ms => 37,
                   eng => quod_simplex:eng_with_certs(3, [])}),
    F = {self(), make_ref()},
    P1 = quod_simplex:test_state_set(
           ingress, [{local, F, lt($c, Me), quod_time:mono_ms()}], Blocked),
    {Drained, Actions} = quod_simplex:test_drain(
                           quod_simplex:test_state_set(approved, 3, P1)),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual([{{timeout, batch}, 37, {flush_batch, 4}}],
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
    Approved = #block{slot = 4, parent = 3, payload = []},
    {E1, _} = quod_simplex:eng_offer(
                {block, Approved}, quod_simplex:eng_new(Validators, 3)),
    {Eng, _} = feed_shares(supports(Approved, Committee, 3), E1),
    Now = quod_time:mono_ms(),
    Queued = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                  slot => 3, approved => 4,
                  eng => Eng,
                  ingress =>
                      [{relayed, {relay, AuthorA, <<10:128>>}, Membership, Now},
                       {relayed, {relay, AuthorB, <<11:128>>}, Ordinary, Now}]}),
    %% The ordinary write could enter slot 5 in isolation; queue ordering is what
    %% deliberately holds it behind the membership boundary.
    ?assertEqual({collect, 5},
                 quod_simplex:route(drain, {relayed, 5}, Ordinary, Queued)),
    {Drained, _Actions} = quod_simplex:test_drain(Queued),
    {2, _, #{AuthorA := 1, AuthorB := 1},
     [{relayed, <<"membership-head">>, _},
      {relayed, <<"ordinary-ready">>, _}]} =
        quod_simplex:test_ingress(Drained),
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
               [{assert, {{blob, binary:copy(<<1>>, 190000)}, true}}],
               {FillerAuthor, FillerId}),
    A1 = signed_tx_seq(
           <<"t">>, <<"a-large">>, 10,
           [{assert, {{blob, binary:copy(<<2>>, 90000)}, true}}],
           {AuthorA, IdA}),
    A2 = signed_tx_seq(
           <<"t">>, <<"a-small">>, 11,
           [{assert, {{ordinary, a2}, true}}], {AuthorA, IdA}),
    B = signed_tx(
          <<"t">>, <<"b-small">>,
          [{assert, {{ordinary, b}, true}}], {AuthorB, IdB}),
    Base = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                slot => 3, approved => 3,
                eng => quod_simplex:eng_with_certs(3, [])}),
    {WithBatch, _BatchActions} =
        quod_simplex:test_relayed_append(
          {relay, FillerAuthor, <<12:128>>}, Filler, Base),
    Now = quod_time:mono_ms(),
    Queued = quod_simplex:test_state_set(
               ingress,
               [{relayed, {relay, AuthorA, <<13:128>>}, A1, Now},
                {relayed, {relay, AuthorA, <<14:128>>}, A2, Now + 1},
               {relayed, {relay, AuthorB, <<15:128>>}, B, Now + 2}],
               WithBatch),
    ?assert(quod_simplex:test_ingress_needs_drain(WithBatch, Queued)),
    ?assertMatch({park, _},
                 quod_simplex:route(drain, {relayed, 4}, A1, Queued)),
    ?assertEqual({collect, 4},
                 quod_simplex:route(drain, {relayed, 4}, A2, Queued)),
    ?assertEqual({collect, 4},
                 quod_simplex:route(drain, {relayed, 4}, B, Queued)),
    {Drained, _Actions} = quod_simplex:test_drain(Queued),
    {2, _, #{AuthorA := 2},
     [{relayed, <<"a-large">>, _}, {relayed, <<"a-small">>, _}]} =
        quod_simplex:test_ingress(Drained),
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
               [{assert, {{blob, binary:copy(<<1>>, 190000)}, true}}],
               {FillerAuthor, FillerId}),
    A1 = signed_tx_seq(
           <<"t">>, <<"multipass-a-large">>, 10,
           [{assert, {{blob, binary:copy(<<2>>, 90000)}, true}}],
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
                slot => 3, approved => 3,
                eng => quod_simplex:eng_with_certs(3, [])}),
    {WithBatch, _} =
        quod_simplex:test_relayed_append(
          {relay, FillerAuthor, <<21:128>>}, Filler, Base),
    Now = quod_time:mono_ms(),
    Queued = quod_simplex:test_state_set(
               ingress,
               [{relayed, {relay, AuthorA, <<22:128>>}, A1, Now},
                {relayed, {relay, AuthorA, <<23:128>>}, A2, Now + 1},
                {relayed, {relay, AuthorB, <<24:128>>}, B, Now + 2},
                {relayed, {relay, AuthorC, <<25:128>>}, C, Now + 3}],
               WithBatch),
    {Drained, _Actions} = quod_simplex:test_drain(Queued),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    Stats = quod_simplex:stats_map(Drained),
    ?assertEqual(3, maps:get(appends, Stats)),
    ?assertEqual(2, maps:get(r_redirect, Stats)).

%% A participant can temporarily lose voting capability while recovering or while a
%% finality cert arrives before its block. Local unsigned work is refused, but an
%% authenticated relay transfers custody and is held until readiness returns; re-seat
%% owns explicit retry replies if recovery replaces the volatile window.
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
                     sync => unconfirmed, slot => 3, approved => 3,
                     eng => quod_simplex:eng_with_certs(3, []),
                     ingress =>
                         [{relayed, {relay, Author, <<16:128>>}, Tx, Now}]}),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:route(entry, {relayed, 4}, Tx, Recovering)),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:route(drain, {relayed, 4}, Tx, Recovering)),
    ?assertEqual(redirect,
                 quod_simplex:route(entry, {relayed, 5}, Tx, Recovering)),
    {Held, []} = quod_simplex:test_drain(Recovering),
    {1, _, _, [{relayed, <<"recovering-queue">>, _}]} =
        quod_simplex:test_ingress(Held),
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
                   slot => 3, approved => 5,
                   eng => quod_simplex:eng_with_certs(0, [])}),
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
                  {relay, Other, binary:copy(<<2>>, 16)}, OtherTx, S65),
    {65, _, #{Other := 1}, _} = quod_simplex:test_ingress(S66).

%% TTL expiry fails VISIBLY (busy) and walks only the queue head — a stalled cluster
%% must never silently hold callers hostage.
ingress_ttl_expires_visibly_test() ->
    {Me, Id} = id(),
    Old = quod_time:mono_ms() - 60000,
    From = {self(), make_ref()},
    S = st(#{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             approved => 5, eng => quod_simplex:eng_with_certs(0, [])}),
    {Parked, []} = quod_simplex:test_append(From, lt($e, Me), S),
    %% age the single parked item by rebuilding it with an old enqueue stamp
    Aged = st(#{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
                approved => 5, eng => quod_simplex:eng_with_certs(0, []),
                ingress => [{local, From, lt($e, Me), Old}]}),
    {1, _, _, _} = quod_simplex:test_ingress(Aged),
    Expired = quod_simplex:test_expire_ingress(Aged),
    {0, 0, _, []} = quod_simplex:test_ingress(Expired),
    receive {_Ref, Reply} -> ?assertEqual({error, busy}, Reply)
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
             slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(0, []),
             ingress => [{local, From, lt($f, Me), Anchor}]}),
    {Drained, []} = quod_simplex:test_drain(S),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual(1, maps:get(ingress_forwarded, quod_simplex:stats_map(Drained))),
    %% the relay is pending toward leader(4) with its deadline anchored at the ORIGINAL
    %% enqueue time — park time counts against the caller's budget, not on top of it
    {_, _, OutboxPeers, _} = quod_simplex:test_link_peers(Drained),
    ?assertEqual([TargetLeader], OutboxPeers),
    [{_ReqId, Target, 4, Deadline}] = quod_simplex:test_relay_pending(Drained),
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
             slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    {Sent, []} = quod_simplex:test_append(From, lt($g, Me), S),
    {0, 0, _, []} = quod_simplex:test_ingress(Sent),
    [{_ReqId, Target, 4, _Deadline}] = quod_simplex:test_relay_pending(Sent),
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
                      slot => 3, approved => 3,
                      eng => quod_simplex:eng_with_certs(3, [])}),
             case quod_simplex:route(entry, local, lt($d, Author), S) of
                 {collect, 4} -> quod_simplex:leader(4, Validators);
                 {relay, Target, 4} -> Target
             end
         end || {Author, AuthorId} <- Committee],
    ?assertEqual(
       lists:duplicate(length(Committee), quod_simplex:leader(4, Validators)),
       Targets).

%% If this node proposes the earliest usable slot, it holds the change locally
%% until that exact slot opens.
origin_parks_when_it_owns_the_next_seat_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(5, Validators), 1, Committee),
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(Validators, 3)),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, approved => 3, eng => E2}),
    {Parked, []} = quod_simplex:test_append(From, lt($g, Me), S),
    {1, _, _, [{local, _, _}]} = quod_simplex:test_ingress(Parked),
    ?assertEqual([], quod_simplex:test_relay_pending(Parked)),
    {Still, []} = quod_simplex:test_drain(Parked),   %% the drain holds it for our turn
    {1, _, _, _} = quod_simplex:test_ingress(Still).

%% Every parked item sits under an armed head watchdog: for each blocked cause the
%% reconciled head_progress is non-idle (the liveness invariant behind park-not-poll).
parked_ingress_implies_armed_watchdog_test() ->
    {Me, Id} = id(),
    Base = #{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             eng => quod_simplex:eng_with_certs(0, [])},
    F = fun(Over) ->
            {S, []} = quod_simplex:test_append({self(), make_ref()}, lt($h, Me),
                                               st(maps:merge(Base, Over))),
            {C, _, _, _} = quod_simplex:test_ingress(S),
            ?assertEqual(1, C),
            ?assertNotEqual(idle,
                            quod_simplex:test_progress(
                              quod_simplex:reconcile_head_progress(S)))
        end,
    F(#{approved => 5}),                                   %% pipeline full
    F(#{approved => 3, commit_buf => #{4 => skip}}),       %% commit_buf holds Next
    %% a sealed local proposal in flight for Next
    B4 = blk(4),
    F(#{approved => 3,
        local_proposal => {4, quod_simplex:block_hash(B4)}}),
    %% membership barrier: a notarized committee-touching block above the head (a
    %% one-member engine notarizes it from a single support share; the barrier and the
    %% watchdog evidence both read the engine, not the state's validator list)
    {MPub, MId} = id(),
    MTx = signed_tx(<<"t">>, <<"barrier">>, [pa(MPub)], {MPub, MId}),
    MBlock = #block{slot = 4, parent = 3, payload = [MTx]},
    {EngB0, _} = quod_simplex:eng_offer({block, MBlock},
                                        quod_simplex:eng_new([MPub], 3)),
    {BarrierEng, _} = feed_shares(
                        [quod_simplex:make_share(
                           support, 4, quod_simplex:block_hash(MBlock), MId)],
                        EngB0),
    F(#{approved => 3, eng => BarrierEng}).

%% A pre-signed relayed change whose sequence fell below the floor is STALE_SEQ —
%% retryable by contract — never terminal bad_change.
stale_seq_is_retryable_test() ->
    [{A, IdA}] = Committee = committee(1),
    Signed = signed_tx_seq(<<"t">>, <<"stale">>, 2,
                           [{assert, {{stale, fact}, true}}], {A, IdA}),
    S = st(#{self => A, id => IdA, validators => pubs(Committee), sync => ready,
             slot => 5, approved => 5, eng => quod_simplex:eng_with_certs(0, []),
             author_seqs => #{A => 9}}),   %% committed floor already past seq 2
    ReplyTo = {relay, A, binary:copy(<<1>>, 16)},
    {S1, []} = quod_simplex:test_relayed_append(ReplyTo, Signed, S),
    %% the relay result frame carrying {error, stale_seq} is queued toward the origin
    {_, _, OutboxPeers, _} = quod_simplex:test_link_peers(S1),
    ?assertEqual([A], OutboxPeers),
    %% counted as a ROUTING RACE, never as malformed input — r_bad is the loadtest's
    %% "malformed workload" alarm and must stay quiet for retryable races
    ?assertEqual(1, maps:get(r_stale, quod_simplex:stats_map(S1))),
    ?assertEqual(0, maps:get(r_bad, quod_simplex:stats_map(S1))).

%% reseat (recovery) nacks the whole parked window retryably, like a discarded batch.
reseat_nacks_parked_ingress_test() ->
    {Me, Id} = id(),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             approved => 5, eng => quod_simplex:eng_with_certs(0, []),
             ingress => [{local, From, lt($i, Me), quod_time:mono_ms()}]}),
    Reseated = quod_simplex:reseat_engine(3, S),
    {0, 0, _, []} = quod_simplex:test_ingress(Reseated),
    receive {_Ref2, Reply2} -> ?assertEqual({error, skipped}, Reply2)
    after 0 -> ?assert(false) end.

%% Delivery can race the selected slot closing. The receiver rejects the now-stale
%% placement instead of silently retaining it until another full rotation.
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
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(Validators, 3)),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    Closed = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                  slot => 3, approved => 3, eng => E2}),
    ?assert(quod_simplex:proposal_visible(4, Closed)),
    ?assertEqual(redirect,
                 quod_simplex:route(entry, {relayed, 4}, Tx, Closed)),
    {Rejected, []} = quod_simplex:test_relayed_append(
                       {relay, Author, binary:copy(<<4>>, 16)}, 4, Tx, Closed),
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
                slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(3, [])}),
    %% This node does not own target slot 4, so it refuses that placement.
    ?assertEqual(redirect,
                 quod_simplex:route(entry, {relayed, 4}, Tx, Open)),
    %% It does own target slot 7 and may safely hold it until that slot opens.
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:route(entry, {relayed, 7}, Tx, Open)),
    %% The same exact-slot rule holds while the pipeline is full.
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, approved => 5, eng => quod_simplex:eng_with_certs(3, [])}),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:route(entry, {relayed, 7}, Tx, Blocked)),
    %% Another participant accepts only the slot it actually owns.
    {Far, FarId} = lists:keyfind(L(9), 1, Committee),
    BlockedFar = st(#{self => Far, id => FarId, validators => Validators,
                      sync => ready, slot => 3, approved => 5,
                      eng => quod_simplex:eng_with_certs(3, [])}),
    FarTx = signed_tx(<<"t">>, <<"cellf">>, [{assert, {{cellf, fact}, true}}],
                      {Author, AuthorId}),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:route(entry, {relayed, 9}, FarTx, BlockedFar)),
    %% membership barrier: park UNCONDITIONALLY, both origins — the post-adoption
    %% schedule is unknowable until the committee block commits
    {MPub, MId} = id(),
    MTx = signed_tx(<<"t">>, <<"mb">>, [pa(MPub)], {MPub, MId}),
    MBlock = #block{slot = 4, parent = 3, payload = [MTx]},
    {EngB0, _} = quod_simplex:eng_offer({block, MBlock},
                                        quod_simplex:eng_new([MPub], 3)),
    {BarrierEng, _} = feed_shares(
                        [quod_simplex:make_share(
                           support, 4, quod_simplex:block_hash(MBlock), MId)],
                        EngB0),
    Barrier = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, approved => 3, eng => BarrierEng}),
    ?assertEqual({park, barrier},
                 quod_simplex:route(entry, {relayed, 7}, Tx, Barrier)),
    ?assertEqual({park, barrier},
                 quod_simplex:route(entry, local, lt($m, Me), Barrier)),
    %% FIFO egress: with a live queue a local ENTRY joins the tail (ordered dispatch),
    %% while the DRAIN pass relays that same item to the first seat's leader
    Queued = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                  slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(3, []),
                  ingress => [{local, {self(), make_ref()}, lt($q, Me),
                               quod_time:mono_ms()}]}),
    ?assertEqual({park, fifo},
                 quod_simplex:route(entry, local, lt($n, Me), Queued)),
    ?assertEqual({relay, L(4), 4},
                 quod_simplex:route(drain, local, lt($q, Me), Queued)).

%% The round-phase probe follows an own proposal: stamped when the proposal seals
%% (mono-ms, approval mark still `none`), and pruned by finalize/2 — which both the
%% commit and skip paths run, so a probe entry can never outlive its slot.
round_probe_lifecycle_test() ->
    Committee = committee(3),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, approved => 5,
                   eng => quod_simplex:eng_with_certs(3, [])}),
    ?assertEqual(#{}, quod_simplex:test_round_probe(Blocked)),
    F1 = {self(), make_ref()}, F2 = {self(), make_ref()},
    P2 = quod_simplex:test_state_set(
           ingress,
           [{local, F1, lt($p, Me), quod_time:mono_ms()},
            {local, F2, lt($q, Me), quod_time:mono_ms() + 1}],
           Blocked),
    %% pipeline opens => the multi-item drain seals OUR block for slot 4 => stamped
    {Drained, _} = quod_simplex:test_drain(quod_simplex:test_state_set(approved, 3, P2)),
    Probe = quod_simplex:test_round_probe(Drained),
    ?assertMatch(#{4 := {At, none}} when is_integer(At), Probe),
    %% the slot finalizing (commit OR skip both run finalize/2) prunes the entry
    Finalized = quod_simplex:finalize(4, Drained),
    ?assertEqual(#{}, quod_simplex:test_round_probe(Finalized)).

%% Creation owns the one-lane invariant: a future call site cannot silently add
%% a different target or slot to the map that relay_lane/2 reads in O(1).
relay_lane_creation_rejects_divergent_target_test() ->
    Target4 = <<1:256>>,
    Target5 = <<2:256>>,
    S0 = st(#{}),
    {ok, S1} = quod_simplex:test_put_pending_relay(Target4, 4, S0),
    {ok, S2} = quod_simplex:test_put_pending_relay(Target4, 4, S1),
    ?assertEqual(
       [{Target4, 4}, {Target4, 4}],
       lists:sort([{Target, Slot}
                   || {_ReqId, Target, Slot, _Deadline} <-
                          quod_simplex:test_relay_pending(S2)])),
    ?assertEqual(
       {error, {relay_lane_conflict, {Target4, 4}, {Target5, 5}}},
       quod_simplex:test_put_pending_relay(Target5, 5, S2)).

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
             slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(3, [])}),
    {Sent1, []} = quod_simplex:test_append({self(), make_ref()}, lt($r, Me), S),
    [{_, LaneTarget, 4, _}] = quod_simplex:test_relay_pending(Sent1),
    %% Locally, slot 4 closes and a fresh route would now choose leader(5).
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(Validators, 3)),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    Advanced = quod_simplex:test_state_set(eng, E2, Sent1),
    ?assert(quod_simplex:proposal_visible(4, Advanced)),
    ?assertEqual(
       {relay, Target5, 5},
       quod_simplex:route(entry, local, lt($x, Me),
                          quod_simplex:test_state_set(eng, E2, S))),
    {Sent2, []} =
        quod_simplex:test_append({self(), make_ref()}, lt($s, Me), Advanced),
    [{_, LaneTarget, 4, _}] = quod_simplex:test_relay_pending(Sent2),
    {1, _, _, [{local, <<"lts">>, _}]} = quod_simplex:test_ingress(Sent2),
    Finalized = quod_simplex:finalize(4, Sent2),
    ?assertEqual([], quod_simplex:test_relay_pending(Finalized)),
    receive {_Tag, {error, skipped}} -> ok
    after 0 -> ?assert(false)
    end,
    {Retried, []} = quod_simplex:test_drain(
                      quod_simplex:test_state_set(approved, 4, Finalized)),
    [{_, Target5, 5, _}] = quod_simplex:test_relay_pending(Retried),
    {0, 0, _, []} = quod_simplex:test_ingress(Retried).

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
                  sync => ready, slot => 3, approved => 3,
                  eng => quod_simplex:eng_with_certs(3, [])}),
    {Held, []} = quod_simplex:test_relayed_append(
                   {relay, Author, binary:copy(<<8>>, 16)}, 5, Tx, Before),
    {1, _, _, _} = quod_simplex:test_ingress(Held),
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer(
                {block, B4}, quod_simplex:eng_new(Validators, 3)),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    AtTurn = quod_simplex:test_state_set(
               approved, 4, quod_simplex:test_state_set(eng, E2, Held)),
    {Drained, _} = quod_simplex:test_drain(AtTurn),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual(1, maps:get(appends, quod_simplex:stats_map(Drained))).

%% A target refusal makes the exact-slot lane retryable; the author can re-prove
%% against its current frontier without following peer-supplied routing hints.
stale_target_fails_lane_retryably_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader4 = quod_simplex:leader(4, Validators),
    {Me, MyId} = hd([P || {Pub, _} = P <- Committee, Pub =/= Leader4]),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(3, []),
             ingress => [{local, From, lt($u, Me), quod_time:mono_ms()}]}),
    {Sent, []} = quod_simplex:test_drain(S),
    [{ReqId, Target, 4, _}] = quod_simplex:test_relay_pending(Sent),
    Done = quod_simplex:test_relay_result(
             Target, ReqId, {error, not_in_charge, none}, Sent),
    ?assertEqual([], quod_simplex:test_relay_pending(Done)),
    receive {_Tag, Reply} -> ?assertEqual({error, skipped}, Reply)
    after 0 -> ?assert(false) end.

%% Receipt acknowledgement changes relay recovery from the fast 300ms lost-send
%% loop to a slow final-result probe. A spoofed acknowledgement from another peer
%% cannot alter the pending request.
relay_accepted_suppresses_fast_retry_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    ImmediateLeader = quod_simplex:leader(4, Validators),
    {Me, MyId} = hd([P || {Pub, _} = P <- Committee,
                          Pub =/= ImmediateLeader]),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(0, []),
             ingress => [{local, From, lt($t, Me), quod_time:mono_ms()}]}),
    {Sent, []} = quod_simplex:test_drain(S),
    [{ReqId, Target, 4, _Deadline, FastRetry, false}] =
        quod_simplex:test_relay_pending_detail(Sent),
    ?assert(FastRetry < quod_time:mono_ms() + 1000),
    [Other | _] = Validators -- [Target],
    ?assertEqual(quod_simplex:test_relay_pending_detail(Sent),
                 quod_simplex:test_relay_pending_detail(
                   quod_simplex:test_relay_accepted(Other, ReqId, Sent))),
    Accepted = quod_simplex:test_relay_accepted(Target, ReqId, Sent),
    [{ReqId, Target, 4, _Deadline2, SlowRetry, true}] =
        quod_simplex:test_relay_pending_detail(Accepted),
    ?assert(SlowRetry >= quod_time:mono_ms() + 4000),
    ?assertEqual(1, maps:get(relay_accepted, quod_simplex:stats_map(Accepted))).

%% Duplicate requests are acknowledged again so a sender that missed the first
%% acknowledgement can stop retrying. Deduplication remains before signature work.
duplicate_inflight_relay_is_acknowledged_test() ->
    [{Author, AuthorId}] = Committee = committee(1),
    Tx = signed_tx(<<"t">>, <<"duplicate-inflight">>,
                   [{assert, {{duplicate, inflight}, true}}], {Author, AuthorId}),
    {ok, Submission} = quod_transaction:submission(<<"t">>, Tx),
    ReqId = quod_transaction:submission_id(Submission),
    S = st(#{self => Author, id => AuthorId, validators => pubs(Committee),
             sync => ready, slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, []),
             relay_inflight => #{ReqId => Author}}),
    {Acked, []} = quod_simplex:test_dispatch_relay(
                    Author, {relay_submit, ReqId, 4, Submission, []}, S),
    {_, _, OutboxPeers, _} = quod_simplex:test_link_peers(Acked),
    ?assertEqual([Author], OutboxPeers),
    ?assertEqual(1, maps:get(relay_duplicates, quod_simplex:stats_map(Acked))).

%% The codec is deployed before v2 serving. A valid authenticated v2 frame reaching a v1-only state
%% machine must be ignored without changing state or crashing the consensus owner.
unsupported_v2_relay_is_safely_dropped_test() ->
    Ns = <<"relay:v2:safe-drop">>,
    Peer = <<3:256>>,
    V2 = {relay_submit_v2, <<1:128>>, <<2:128>>, <<8:256>>, 7,
          {submit, Peer, <<4:512>>, <<5, 6, 7>>}, []},
    {relay, Decoded} =
        quod_relay:decode_frame(quod_relay:encode(Ns, V2), Ns),
    S = st(#{self => <<"self">>, validators => [<<"self">>],
             slot => 6, approved => 6,
             eng => quod_simplex:eng_with_certs(6, [])}),
    {S1, Actions} = quod_simplex:test_dispatch_relay(Peer, Decoded, S),
    ?assertEqual(S, S1),
    ?assertEqual([], Actions).

%% A leader latched into a final-vote camp for its OWN in-flight slot must STILL redrive
%% the proposal on every Δ: the link send is fire-and-forget, so the Δ re-fire is the
%% only retransmit of a lost proposal frame. (Live regression: a leader that
%% complaint-signed its slot before proposing stopped redriving, no follower ever saw
%% the proposal, and the burst wedged with zero support votes.)
latched_leader_still_redrives_proposal_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    B4 = blk(4),
    BH = quod_simplex:block_hash(B4),
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(Validators, 3)),
    %% latch the complaint exactly as the pre-proposal timeout path does
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    try
        Inbound = maps:from_list([{P, {Sink, make_ref()}} || P <- Validators, P =/= Me]),
        Readiness = voting_readiness([P || P <- Validators, P =/= Me], Sink, 3),
        SReady = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                      slot => 3, approved => 3, eng => E1,
                      inbound_conns => Inbound, peer_readiness => Readiness,
                      head_progress => {4, awaiting_proposal, true}}),
        Complained = quod_simplex:on_progress_timeout(4, SReady),
        ?assertEqual({none, false, true}, quod_simplex:test_round(4, Complained)),
        %% now it proposes (the drain would do this); then the next Δ must RE-SEND it
        Redriven = quod_simplex:on_progress_timeout(
                     4, quod_simplex:test_state_set(
                          local_proposal, {4, BH}, Complained)),
        ?assertEqual(1, maps:get(redrives, quod_simplex:stats_map(Redriven)))
    after
        exit(Sink, kill)
    end.

%% The quod_metrics matcher and stats_map can never drift: every key the Prometheus
%% refresh pattern requires must exist in the stats map (a miss silently zeroes ALL
%% consensus gauges).
metrics_matcher_lockstep_test() ->
    {Me, Id} = id(),
    Stats = quod_simplex:stats_map(
              st(#{self => Me, id => Id, validators => [Me], sync => ready,
                   slot => 1, approved => 1,
                   eng => quod_simplex:eng_with_certs(0, [])})),
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
    ?assert(quod_simplex:complaint_amplified(me, Vs(2), Bucket([me, {peer, 1}]))),
    %% Cached shares from outsiders or removed validators do not count in the current committee.
    ?assertNot(quod_simplex:complaint_amplified(
                 me, Vs(4), Bucket([{peer, 1}, outsider]))),
    ?assert(quod_simplex:complaint_amplified(
              me, Vs(4), Bucket([{peer, 1}, {peer, 2}, outsider]))).

%% Malformed shapes are rejected even with a valid signature over their (malformed) bytes.
share_shape_test() ->
    {_, Id} = id(),
    H = quod_simplex:block_hash(blk(1)),
    ?assert(quod_simplex:verify_share(quod_simplex:make_share(support, 1, H, Id))),
    ?assertNot(quod_simplex:verify_share(quod_simplex:make_share(complaint, 1, H, Id))),   %% complaint w/ hash
    ?assertNot(quod_simplex:verify_share(quod_simplex:make_share(support, 1, <<1, 2, 3>>, Id))),  %% short hash
    Wrapped = (quod_simplex:make_share(support, 1, H, Id))#share{slot = (1 bsl 64) + 1},
    ?assertNot(quod_simplex:verify_share(Wrapped)).   %% slot encoding must never wrap modulo 2^64

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
    ?assertNot(quod_simplex:verify_cert(#cert{kind = support, slot = 1, block_hash = H, sigs = Bloat}, Vals)),
    {ok, Good} = quod_simplex:form_cert(support, 1, H, supports(blk(1), Ids, 3), Vals),
    [First | _] = Good#cert.sigs,
    Improper = Good#cert{sigs = [First | bad_tail]},
    ?assertNot(quod_simplex:well_formed_cert(Improper)),
    ?assertNot(quod_simplex:verify_cert(Improper, Vals)),
    Wrapped = Good#cert{slot = (1 bsl 64) + 1},
    ?assertNot(quod_simplex:well_formed_cert(Wrapped)),
    ?assertNot(quod_simplex:verify_cert(Wrapped, Vals)).

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

%% Slice E — the weak-cert finalize guard (the mid-flight committee-change / stale-cert hazard). A commit
%% cert that met quorum under a committee is SUB-QUORUM once the committee grows; finalizing it would fork a
%% laggard from the honest network. persisted_cert returns none (the trigger the statem refuses on),
%% eng_evict_final backs out the premature commit-marking, and a fresh share under the grown set re-forms a
%% genuine cert that re-commits — proving the wait re-drives rather than wedging forever.
weak_cert_guard_test() ->
    C5 = committee(5),
    C4 = take(4, C5),               %% the 4-set is the first 4 of the 5-set (all still members after growth)
    B  = blk(1),
    BH = quod_simplex:block_hash(B),
    E0 = quod_simplex:eng_new(pubs(C4), 0),
    {E1, _}  = quod_simplex:eng_offer({block, B}, E0),
    {E2, _}  = feed_shares(supports(B, C4, 3), E1),                         %% notarize under the 4-set
    {E3, Ev} = feed_shares(commits(B, C4, 3), E2),                          %% commit cert forms (quorum(4)=3)
    ?assert(lists:member({committed, 1, B}, Ev)),
    ?assertMatch(#cert{}, quod_simplex:persisted_cert(commit, 1, BH, E3)),  %% valid under the 4-set

    %% the committee grows to 5 (quorum 4): the 3-sig cert is now sub-quorum.
    E4 = quod_simplex:eng_set_validators(pubs(C5), E3),
    ?assertEqual(none, quod_simplex:persisted_cert(commit, 1, BH, E4)),     %% THE TRIGGER the statem refuses on

    %% back out the premature commit-marking, then a 4th distinct share under the 5-set re-forms + re-commits.
    E5 = quod_simplex:eng_evict_final(commit, 1, BH, E4),
    ?assertNot(maps:is_key(1, quod_simplex:eng_committed(E5))),             %% un-marked ⇒ detect_commits can re-fire
    {E6, Ev6} = feed_shares(commits(B, C5, 5) -- commits(B, C4, 3), E5),    %% shares from members 4 + 5
    ?assert(lists:member({committed, 1, B}, Ev6)),                          %% re-committed under the 5-set
    ?assertMatch(#cert{}, quod_simplex:persisted_cert(commit, 1, BH, E6)).  %% now a genuine 4-sig cert

%% Verified shares may stay cached across a committee transition, but a removed signer must stop counting.
%% Re-offering a current member's duplicate exercises the no-reverify/re-form path: one current + one removed
%% share is below quorum(3)=3; only after both remaining current members sign may it notarize.
cached_removed_share_not_counted_test() ->
    C4 = committee(4),
    [C1, _Removed, C3, C4th] = C4,
    C3set = [C1, C3, C4th],
    B = blk(1),
    [S1, SRemoved] = supports(B, C4, 2),
    {E1, _} = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(pubs(C4), 0)),
    {E2, _} = feed_shares([S1, SRemoved], E1),
    E3 = quod_simplex:eng_set_validators(pubs(C3set), E2),
    {E4, Ev4} = quod_simplex:eng_offer({share, S1}, E3),
    ?assertNot(lists:member({notarized, B}, Ev4)),
    ?assertNot(maps:is_key(1, quod_simplex:eng_tree(E4))),
    [_Same, S3, S4] = supports(B, C3set, 3),
    {E5, Ev5} = quod_simplex:eng_offer({share, S3}, E4),
    ?assertNot(lists:member({notarized, B}, Ev5)),
    {E6, Ev6} = quod_simplex:eng_offer({share, S4}, E5),
    ?assert(lists:member({notarized, B}, Ev6)),
    ?assertEqual(B, maps:get(1, quod_simplex:eng_tree(E6))).

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

%% Consensus ordering is pipelined independently of state execution: a child can
%% notarize and even obtain its own commit certificate while its parent has no commit
%% certificate yet. The driver buffers finalization and applies slots in order.
eng_child_finalizes_before_parent_test() ->
    C = committee(4),
    B1 = blk(1), B2 = blk(2),
    E0 = quod_simplex:eng_new(pubs(C), 0),
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
    ?assertEqual({[A], [B]}, quod_simplex:committee_delta({batch, [Tx]})),
    ?assertEqual([A], quod_simplex:apply_committee_delta(Tx, [])),
    ?assertEqual(lists:usort([A, C]), quod_simplex:apply_committee_delta(Tx, [A, C, B])),  %% A dup, C kept, B dropped
    ?assertEqual({[], []}, quod_simplex:committee_delta({batch, [Tx | bad_tail]})),
    ?assertEqual({[], []}, quod_simplex:committee_delta(noop)),                 %% a noop carries no change
    ?assertEqual(lists:usort([A, C]), quod_simplex:apply_committee_delta(noop, [C, A])).

%% Slice D dial-hint extractor: the SIBLING of committee_delta yielding each peer_admitted ASSERT's
%% {Pk, {Host, Port}}. Retracts and noise yield nothing (removal ≠ reachability change); a `noop` (the
%% skip entries that populate catch-up windows) yields []; last-wins is the map fold's job at the hook.
admitted_endpoints_test() ->
    [A, B, _] = [P || {P, _} <- committee(3)],
    Full = tx([{assert,  {{peer_admitted, A, "10.0.0.1", 9001, A}, true}},
               {retract, {{peer_admitted, B, "10.0.0.2", 9002, B}, true}},   %% retract → not a hint
               {assert,  {{other, foo}, true}}]),                            %% noise → ignored
    ?assertEqual([{A, {"10.0.0.1", 9001}}], quod_simplex:admitted_endpoints({batch, [Full]})),
    ?assertEqual([], quod_simplex:admitted_endpoints(noop)),                  %% skip entry: no hint, no crash
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

%% A non-PROPER-list diff (an improper list `[Op|junk]`, or a non-list) must be rejected, never crash.
%% `binary_to_term` on the untrusted consensus wire can decode either shape, and a shallow `[Op | _]`
%% match would let it through to crash `committee_delta`'s fold during commit/restart.
membership_gate_improper_list_test() ->
    [A] = pubs(committee(1)),
    Improper = tx([{assert, {{other, x}, true}} | 2]),
    NonList  = tx(not_a_list),
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
                 Good#transaction{read_check = #{{fact, -1} => 0}}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{tx_id = <<>>}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{submitted_at = 1.5}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{sig = unsigned}, [A])).

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

%% Run each honest node through an ordered list of vote steps against the REAL guards, threading its own
%% {Committed, Complained} latch; returns {AllComplaintShares, AllCommitShares}. A step emits a share only
%% if the guard permits (mirroring apply_event/on_progress_timeout), so the cross-slot exclusion decides
%% which shares exist. Used by fork_certs_cannot_coexist_test.
run_schedule(Committee, Steps) ->
    lists:foldl(
      fun({_Pub, Id}, {CplAcc, CmtAcc}) ->
          {Cpl, Cmt, _Latch} = lists:foldl(fun(Step, A) -> guarded_vote(Step, Id, A) end,
                                           {[], [], {[], []}}, Steps),
          {Cpl ++ CplAcc, Cmt ++ CmtAcc}
      end, {[], []}, Committee).

guarded_vote({complaint, Sl, none}, Id, {Cpl, Cmt, {Committed, Complained}}) ->
    case quod_simplex:may_complain(Sl, Committed) of   %% barred if this node committed Sl or its child Sl+1
        true  -> {[quod_simplex:make_share(complaint, Sl, none, Id) | Cpl], Cmt, {Committed, [Sl | Complained]}};
        false -> {Cpl, Cmt, {Committed, Complained}}
    end;
guarded_vote({commit, Sl, BH}, Id, {Cpl, Cmt, {Committed, Complained}}) ->
    case quod_simplex:may_commit(Sl, Complained) of    %% barred if this node complained Sl or its parent Sl-1
        true  -> {Cpl, [quod_simplex:make_share(commit, Sl, BH, Id) | Cmt], {[Sl | Committed], Complained}};
        false -> {Cpl, Cmt, {Committed, Complained}}
    end.

%% committee-projection fixtures: a transaction whose diff is a list of peer_admitted asserts/retracts
pa(Pk)  -> {assert,  {{peer_admitted, Pk, undefined, undefined, Pk}, true}}.
rm(Pk)  -> {retract, {{peer_admitted, Pk, undefined, undefined, Pk}, true}}.
tx(Ops) -> #transaction{tx_id = <<"t">>, caller_ns = <<"ns">>, diff = Ops,
                        read_check = #{}, author = <<1:256>>, sig = none}.

signed_tx(Ns, TxId, Ops, {Pub, Identity}) ->
    signed_tx_seq(Ns, TxId, erlang:phash2(TxId) + 1, Ops,
                  {Pub, Identity}).

signed_tx_seq(Ns, TxId, Seq, Ops, {Pub, Identity}) ->
    Unsigned = #transaction{tx_id = TxId, caller_ns = Ns, diff = Ops,
                            read_check = #{}, author = Pub, author_seq = Seq,
                            sig = none},
    {ok, Signed} = quod_transaction:sign(Ns, Unsigned, Identity),
    Signed.

%% support/commit shares for block B from the first K committee members
supports(B, C, K) -> [quod_simplex:make_share(support, B#block.slot, quod_simplex:block_hash(B), Id)
                      || {_, Id} <- take(K, C)].
commits(B, C, K)  -> [quod_simplex:make_share(commit, B#block.slot, quod_simplex:block_hash(B), Id)
                      || {_, Id} <- take(K, C)].
complaint_share(Slot, {_Pub, Id}) ->
    quod_simplex:make_share(complaint, Slot, none, Id).

dispatch_shares(Shares, S) ->
    lists:foldl(
      fun(#share{signer = Peer} = Share, Acc) ->
              quod_simplex:dispatch(Peer, {share, Share}, Acc)
      end, S, Shares).

%% offer each share to the engine in turn, accumulating all emitted events
feed_shares(Shares, Eng) ->
    lists:foldl(fun(S, {E, Evs}) ->
                    {E1, Es} = quod_simplex:eng_offer({share, S}, E),
                    {E1, Evs ++ Es}
                end, {Eng, []}, Shares).
