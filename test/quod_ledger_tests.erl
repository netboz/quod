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
