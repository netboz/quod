-module(quod_ledger_tests).
-moduledoc """
Pure-logic unit tests for `quod_ledger`'s safety-critical Raft helpers — the parts that
must be correct independently of the network: quorum math, the election restriction,
committee derivation, the AppendEntries truncate-vs-skip decision, and the commit rule
with the **Figure-8 current-term guard**. Multi-node behaviour is in `raft_safety_SUITE`.
""".
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(A, {"a", 1}).
-define(B, {"b", 2}).
-define(C, {"c", 3}).

ent(I, T) -> #entry{index = I, term = T, kind = block, data = noop}.

%%%===================================================================
%%% quorum / committee
%%%===================================================================

quorum_test() ->
    ?assertEqual(1, quod_ledger:quorum(quod_ledger:mk_d(#{snap_cfg => [?A]}))),
    ?assertEqual(2, quod_ledger:quorum(quod_ledger:mk_d(#{snap_cfg => [?A, ?B, ?C]}))),
    ?assertEqual(3, quod_ledger:quorum(quod_ledger:mk_d(#{snap_cfg => [?A, ?B, ?C, {"d", 4}, {"e", 5}]}))).

derive_committee_base_test() ->
    D = quod_ledger:mk_d(#{snap_cfg => [?A, ?B, ?C]}),
    ?assertEqual([?A, ?B, ?C], lists:sort(quod_ledger:derive_committee(D))).

derive_committee_add_remove_test() ->
    %% snap_cfg overlaid with in-log config entries, in index order.
    Log = [#entry{index = 1, term = 0, kind = config, data = {add, ?A}},
           #entry{index = 2, term = 0, kind = config, data = {add, ?B}},
           #entry{index = 3, term = 1, kind = config, data = {add, ?C}},
           #entry{index = 4, term = 1, kind = config, data = {remove, ?B}}],
    D = quod_ledger:mk_d(#{snap_cfg => [], log => Log}),
    ?assertEqual([?A, ?C], lists:sort(quod_ledger:derive_committee(D))).

%%%===================================================================
%%% election restriction (up_to_date/4)
%%%===================================================================

up_to_date_test() ->
    %% candidate (CandT, CandI) vs voter (MyT, MyI)
    ?assert(quod_ledger:up_to_date(2, 1, 1, 9)),        %% higher term wins regardless of index
    ?assertNot(quod_ledger:up_to_date(1, 9, 2, 1)),     %% lower term loses regardless of index
    ?assert(quod_ledger:up_to_date(2, 5, 2, 5)),        %% equal term+index ⇒ up to date (>=)
    ?assert(quod_ledger:up_to_date(2, 6, 2, 5)),        %% equal term, longer log wins
    ?assertNot(quod_ledger:up_to_date(2, 4, 2, 5)).     %% equal term, shorter log loses

%%%===================================================================
%%% term_at / last_log_*
%%%===================================================================

term_at_test() ->
    D = quod_ledger:mk_d(#{log => [ent(1, 1), ent(2, 1), ent(3, 2)]}),
    ?assertEqual(0, quod_ledger:term_at(0, D)),         %% index-0 sentinel
    ?assertEqual(1, quod_ledger:term_at(1, D)),
    ?assertEqual(2, quod_ledger:term_at(3, D)),
    ?assertEqual(undefined, quod_ledger:term_at(4, D)).

term_at_snapshot_sentinel_test() ->
    D = quod_ledger:mk_d(#{snap_idx => 7, snap_term => 3, log => []}),
    ?assertEqual(3, quod_ledger:term_at(7, D)),         %% snapshot point
    ?assertEqual(7, quod_ledger:last_log_index(D)),     %% empty log ⇒ snapshot index/term
    ?assertEqual(3, quod_ledger:last_log_term(D)).

last_log_nonempty_test() ->
    D = quod_ledger:mk_d(#{log => [ent(1, 1), ent(2, 4)]}),
    ?assertEqual(2, quod_ledger:last_log_index(D)),
    ?assertEqual(4, quod_ledger:last_log_term(D)).

%%%===================================================================
%%% AppendEntries merge: truncate_append/2
%%%   - same index+term ⇒ skip (idempotent, NEVER truncate on a match)
%%%   - same index, different term ⇒ truncate from there, append suffix
%%%   - beyond the tail ⇒ append
%%%===================================================================

truncate_append_pure_append_test() ->
    D = quod_ledger:mk_d(#{log => [ent(1, 1), ent(2, 1)]}),
    {NewLog, Action} = quod_ledger:truncate_append(D, [ent(3, 2), ent(4, 2)]),
    ?assertEqual({append, [ent(3, 2), ent(4, 2)]}, Action),
    ?assertEqual([1, 2, 3, 4], [I || #entry{index = I} <- NewLog]).

truncate_append_idempotent_skip_test() ->
    %% a delayed/duplicate AE re-sends entries we already hold (same term) ⇒ no truncate.
    D = quod_ledger:mk_d(#{log => [ent(1, 1), ent(2, 1), ent(3, 1)]}),
    {NewLog, Action} = quod_ledger:truncate_append(D, [ent(2, 1), ent(3, 1)]),
    ?assertEqual(noop, Action),
    ?assertEqual([1, 2, 3], [I || #entry{index = I} <- NewLog]).

truncate_append_conflict_test() ->
    %% index 2 exists at term 1 but the leader sends it at term 2 ⇒ drop 2.. and append.
    D = quod_ledger:mk_d(#{log => [ent(1, 1), ent(2, 1), ent(3, 1)]}),
    {NewLog, Action} = quod_ledger:truncate_append(D, [ent(2, 2), ent(3, 2)]),
    ?assertEqual({truncate_append, 2, [ent(2, 2), ent(3, 2)]}, Action),
    ?assertEqual([{1, 1}, {2, 2}, {3, 2}], [{I, T} || #entry{index = I, term = T} <- NewLog]).

truncate_append_partial_overlap_test() ->
    %% first entry matches (skip), the next diverges (conflict from there).
    D = quod_ledger:mk_d(#{log => [ent(1, 1), ent(2, 1), ent(3, 1)]}),
    {NewLog, Action} = quod_ledger:truncate_append(D, [ent(2, 1), ent(3, 2), ent(4, 2)]),
    ?assertEqual({truncate_append, 3, [ent(3, 2), ent(4, 2)]}, Action),
    ?assertEqual([{1, 1}, {2, 1}, {3, 2}, {4, 2}], [{I, T} || #entry{index = I, term = T} <- NewLog]).

truncate_append_heartbeat_test() ->
    D = quod_ledger:mk_d(#{log => [ent(1, 1)]}),
    ?assertEqual({[ent(1, 1)], noop}, quod_ledger:truncate_append(D, [])).

%%%===================================================================
%%% commit rule + Figure-8 current-term guard (advance_commit/1)
%%%===================================================================

%% A leader at term 2 with prior-term entries (1,2 @ term 1) a majority already holds
%% must NOT commit them by replica count alone — only once a current-term entry above
%% them (3 @ term 2) is itself majority-replicated (Raft Figure 8).
figure8_prior_term_not_committed_test() ->
    Log = [ent(1, 1), ent(2, 1), ent(3, 2)],
    D = quod_ledger:mk_d(#{self => ?A, snap_cfg => [?A, ?B, ?C], cur_term => 2,
                        commit_index => 0, log => Log,
                        match_index => #{?B => 2, ?C => 0}}),   %% B holds 1,2 but NOT 3
    ?assertEqual(0, commit_index_of(quod_ledger:advance_commit(D))).

%% Once a current-term entry (3 @ term 2) is majority-replicated, it commits — and
%% indirectly commits the prior-term entries below it.
figure8_current_term_commits_test() ->
    Log = [ent(1, 1), ent(2, 1), ent(3, 2)],
    D0 = quod_ledger:mk_d(#{self => ?A, snap_cfg => [?A, ?B, ?C], cur_term => 2,
                         commit_index => 0, log => Log,
                         match_index => #{?B => 3, ?C => 0}}),   %% B now holds up to 3
    ?assertEqual(3, commit_index_of(quod_ledger:advance_commit(D0))).

current_term_majority_commits_test() ->
    Log = [ent(1, 2), ent(2, 2)],
    D0 = quod_ledger:mk_d(#{self => ?A, snap_cfg => [?A, ?B, ?C], cur_term => 2,
                         commit_index => 0, log => Log,
                         match_index => #{?B => 2, ?C => 0}}),
    ?assertEqual(2, commit_index_of(quod_ledger:advance_commit(D0))).

no_majority_no_commit_test() ->
    Log = [ent(1, 2)],
    D0 = quod_ledger:mk_d(#{self => ?A, snap_cfg => [?A, ?B, ?C], cur_term => 2,
                         commit_index => 0, log => Log,
                         match_index => #{?B => 0, ?C => 0}}),   %% only self ⇒ 1 < quorum 2
    ?assertEqual(0, commit_index_of(quod_ledger:advance_commit(D0))).

%%%===================================================================
%%% join path: voter/learner split, promote, and the safety gate
%%%===================================================================

cfg(I, T, Data) -> #entry{index = I, term = T, kind = config, data = Data}.

%% {add_learner} admits a non-voter; {promote} moves it into the committee.
derive_learners_and_promote_test() ->
    Log = [cfg(1, 0, {add, ?A}), cfg(2, 1, {add_learner, ?B})],
    D = quod_ledger:mk_d(#{self => ?A, snap_cfg => [], log => Log}),
    ?assertEqual([?A], quod_ledger:derive_committee(D)),    %% B is NOT a voter
    ?assertEqual([?B], quod_ledger:derive_learners(D)),
    D2 = quod_ledger:mk_d(#{self => ?A, snap_cfg => [],
                            log => Log ++ [cfg(3, 1, {promote, ?B})]}),
    ?assertEqual([?A, ?B], lists:sort(quod_ledger:derive_committee(D2))),  %% now a voter
    ?assertEqual([], quod_ledger:derive_learners(D2)).                     %% no longer a learner

%% Replication targets include learners; the vote/quorum set does not.
peers_split_test() ->
    Log = [cfg(1, 0, {add, ?A}), cfg(2, 1, {add_learner, ?B})],
    D = quod_ledger:mk_d(#{self => ?A, snap_cfg => [], log => Log}),
    ?assertEqual([?B], quod_ledger:repl_peers(D)),    %% B is replicated to
    ?assertEqual([], quod_ledger:voter_peers(D)),     %% but B never votes
    ?assertEqual(1, quod_ledger:quorum(D)).           %% quorum is over voters only (just A)

%% remove drops a node from both the voter and learner sets.
remove_drops_both_test() ->
    Log = [cfg(1, 0, {add, ?A}), cfg(2, 0, {add, ?B}), cfg(3, 1, {add_learner, ?C}),
           cfg(4, 1, {remove, ?B}), cfg(5, 1, {remove, ?C})],
    D = quod_ledger:mk_d(#{self => ?A, snap_cfg => [], log => Log}),
    ?assertEqual([?A], quod_ledger:derive_committee(D)),
    ?assertEqual([], quod_ledger:derive_learners(D)).

%% A join_request from an un-accepted outsider must not crash the leader: only a well-formed
%% {Host, Port} id is processed; anything else is rejected at the door.
valid_server_id_test() ->
    ?assert(quod_ledger:valid_server_id({"127.0.0.1", 14567})),
    ?assert(quod_ledger:valid_server_id({<<"host">>, 1})),
    ?assertNot(quod_ledger:valid_server_id(<<"not-a-tuple">>)),
    ?assertNot(quod_ledger:valid_server_id({"h", 1, 2})),       %% wrong arity
    ?assertNot(quod_ledger:valid_server_id({"h", 0})),          %% port out of range
    ?assertNot(quod_ledger:valid_server_id({"h", 70000})),      %% port out of range
    ?assertNot(quod_ledger:valid_server_id({123, 14567})),      %% host not a string/binary
    ?assertNot(quod_ledger:valid_server_id(an_atom)).

%% The promote target is recovered from the LOG alone (no volatile state), so a freshly
%% built #d — as a restarted or newly-elected leader has — still knows each pending learner's
%% target and never strands one. `none` once promoted/removed.
learner_target_derived_from_log_test() ->
    Admit = [cfg(1, 0, {add, ?A}), cfg(2, 1, {add_learner, ?B})],
    %% a brand-new #d (empty volatile fields — the new-leader case) recovers B's target = 2.
    D = quod_ledger:mk_d(#{self => ?A, snap_cfg => [], log => Admit}),
    ?assertEqual(2, quod_ledger:learner_target(?B, D)),
    ?assertEqual(none, quod_ledger:learner_target(?A, D)),   %% a voter, not a pending learner
    ?assertEqual(none, quod_ledger:learner_target(?C, D)),   %% unknown node
    %% once promoted (or removed), the target clears.
    DP = quod_ledger:mk_d(#{self => ?A, snap_cfg => [],
                            log => Admit ++ [cfg(3, 1, {promote, ?B})]}),
    ?assertEqual(none, quod_ledger:learner_target(?B, DP)),
    DR = quod_ledger:mk_d(#{self => ?A, snap_cfg => [],
                            log => Admit ++ [cfg(3, 1, {remove, ?B})]}),
    ?assertEqual(none, quod_ledger:learner_target(?B, DR)).

%% A learner's match_index never counts toward the commit majority — only voters do.
learner_match_excluded_from_commit_test() ->
    Log = [cfg(1, 1, {add, ?A}), cfg(2, 1, {add, ?B}), cfg(3, 1, {add_learner, ?C}),
           ent(4, 1)],
    %% voters {A,B} (quorum 2); B reached 3, learner C reached 4 (excluded). So index 4 is
    %% held only by self(A) ⇒ not committed; the highest both voters hold is 3.
    D = quod_ledger:mk_d(#{self => ?A, snap_cfg => [], cur_term => 1, commit_index => 0,
                           log => Log, match_index => #{?B => 3, ?C => 4}}),
    ?assertEqual(3, commit_index_of(quod_ledger:advance_commit(D))).

%% A config entry above the commit index = a change in flight; only config entries count.
cfg_uncommitted_test() ->
    Log = [cfg(1, 0, {add, ?A}), cfg(2, 1, {add_learner, ?B})],
    ?assert(quod_ledger:cfg_uncommitted(
              quod_ledger:mk_d(#{snap_cfg => [], log => Log, commit_index => 1}))),
    ?assertNot(quod_ledger:cfg_uncommitted(
                 quod_ledger:mk_d(#{snap_cfg => [], log => Log, commit_index => 2}))),
    %% a block entry above the commit index does NOT block a membership change
    Log2 = Log ++ [ent(3, 1)],
    ?assertNot(quod_ledger:cfg_uncommitted(
                 quod_ledger:mk_d(#{snap_cfg => [], log => Log2, commit_index => 2}))).

%% The current-term-commit gate: exactly the sole-founder scenario. Genesis (term 0)
%% committed, cur_term 1 ⇒ no current-term commit yet (promote blocked); after the term-1
%% {add_learner} commits ⇒ the gate opens.
has_current_term_commit_test() ->
    Log0 = [cfg(1, 0, {add, ?A}), ent(2, 0)],
    ?assertNot(quod_ledger:has_current_term_commit(
                 quod_ledger:mk_d(#{cur_term => 1, commit_index => 2, log => Log0}))),
    Log1 = Log0 ++ [cfg(3, 1, {add_learner, ?B})],
    ?assert(quod_ledger:has_current_term_commit(
              quod_ledger:mk_d(#{cur_term => 1, commit_index => 3, log => Log1}))).

%% The committed-membership view (a joiner's stop condition / reply gate): a learner counts only
%% once its {add_learner} is at or below commit_index — a tentative (truncatable) entry does NOT
%% make a joiner consider itself in. (issue 4a)
committed_view_membership_test() ->
    Log = [cfg(1, 0, {add, ?A}), cfg(2, 1, {add_learner, ?B})],
    %% {add_learner, B} @2 ABOVE commit_index 1 ⇒ B not yet a committed member
    DCn = quod_ledger:committed_view(
            quod_ledger:mk_d(#{self => ?B, snap_cfg => [], log => Log, commit_index => 1})),
    ?assertEqual([],   quod_ledger:derive_learners(DCn)),
    ?assertEqual([?A], quod_ledger:derive_committee(DCn)),
    %% at commit_index 2 ⇒ B is a committed learner (safe to stop asking)
    DCy = quod_ledger:committed_view(
            quod_ledger:mk_d(#{self => ?B, snap_cfg => [], log => Log, commit_index => 2})),
    ?assertEqual([?B], quod_ledger:derive_learners(DCy)).

%% A read-replica ({add_replica}) is a non-voting member: replicated to (in derive_learners /
%% repl_peers), NOT a voter (excluded from derive_committee / quorum), and NEVER promoted
%% (learner_target returns none, so maybe_promote_learner no-ops).
add_replica_is_nonvoting_never_promoted_test() ->
    Log = [cfg(1, 0, {add, ?A}), cfg(2, 1, {add_replica, ?B})],
    D = quod_ledger:mk_d(#{self => ?A, snap_cfg => [], log => Log}),
    ?assertEqual([?A], quod_ledger:derive_committee(D)),     %% B is NOT a voter
    ?assertEqual([?B], quod_ledger:derive_learners(D)),      %% B IS replicated to
    ?assertEqual([?B], quod_ledger:repl_peers(D)),           %% the leader feeds B
    ?assertEqual(none, quod_ledger:learner_target(?B, D)),   %% B is never promoted
    ?assertEqual(1, quod_ledger:quorum(D)).                  %% B doesn't move quorum

%% Anti-drift property (issue 9, kept two folds): the replication set is ALWAYS exactly the
%% union of voters and learners, minus self — so the two separate folds can never silently drift.
repl_peers_is_voters_union_learners_test() ->
    Log = [cfg(1, 0, {add, ?A}), cfg(2, 0, {add, ?B}), cfg(3, 1, {add_learner, ?C}),
           cfg(4, 1, {add_learner, {"d", 4}})],
    D = quod_ledger:mk_d(#{self => ?A, snap_cfg => [], log => Log}),
    Union = lists:usort(quod_ledger:derive_committee(D) ++ quod_ledger:derive_learners(D)),
    ?assertEqual(Union -- [?A], lists:usort(quod_ledger:repl_peers(D))).

%% evict_one/1 (the follower's transient redirect table makes room by dropping one entry).
evict_one_test() ->
    ?assertEqual(#{}, quod_ledger:evict_one(#{})),                 %% empty: no-op
    ?assertEqual(0, maps:size(quod_ledger:evict_one(#{a => 1}))),  %% single: emptied
    M = #{?A => x, ?B => y, ?C => z},
    E = quod_ledger:evict_one(M),
    ?assertEqual(2, maps:size(E)),                                 %% dropped exactly one
    ?assert(lists:all(fun(K) -> maps:is_key(K, M) end, maps:keys(E))).  %% remaining were present

%%%===================================================================
%%% wire codec
%%%===================================================================

codec_roundtrip_test() ->
    RV = #request_vote{term = 3, candidate_id = ?A, last_log_index = 5, last_log_term = 2},
    ?assertEqual(RV, quod_ledger:decode(quod_ledger:encode(RV))),
    AE = #append_entries{term = 3, leader_id = ?A, prev_log_index = 4, prev_log_term = 2,
                         entries = [ent(5, 3)], leader_commit = 4},
    ?assertEqual(AE, quod_ledger:decode(quod_ledger:encode(AE))).

codec_garbage_is_safe_test() ->
    ?assertEqual(error, quod_ledger:decode(<<"not-a-term">>)).

%% #d{} is private; read commit_index back via the TEST accessor.
commit_index_of(D) -> quod_ledger:commit_index(D).
