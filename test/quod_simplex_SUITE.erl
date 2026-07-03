-module(quod_simplex_SUITE).
-moduledoc """
Single-validator (N=1) integration tests for the `quod_simplex` consensus `gen_statem`: a founder
bootstraps its committee + genesis, `append/2` commits and durably persists each block (the sole
validator IS the `⅔` quorum), and a restart REPLAYS the durable log — recovering the height and the
validator set from disk. No `quod_prolog` is started, so these pin the consensus/persistence layer in
isolation; the apply→KB→prove path is covered end-to-end once `quod_prolog` is rewired to this module.
The multi-validator BFT path (shares/certs/complaint) is Stage 2's `simplex_SUITE`.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("quod_ledger.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([t_founder_bootstrap/1, t_genesis_seeds_content/1, t_append_commits_and_persists/1,
         t_restart_replays/1, t_status_stats/1, t_multi_member_accepted/1,
         t_admit_learner_survives_restart/1, t_membership_gate_rejects/1]).

all() ->
    [t_founder_bootstrap, t_genesis_seeds_content, t_append_commits_and_persists,
     t_restart_replays, t_status_stats, t_multi_member_accepted,
     t_admit_learner_survives_restart, t_membership_gate_rejects].

init_per_testcase(_TC, Cfg) ->
    {ok, _} = application:ensure_all_started(gproc),
    U   = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_simplex_" ++ U),
    Ns  = list_to_binary("simplex:" ++ U),
    {Pub, Seed} = quod_identity:generate(),
    Id = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},   %% signing identity for shares
    Base = #{node_id => Pub, identity => Id, data_dir => Dir},   %% the store wants a string path, not a binary
    [{ns, Ns}, {dir, Dir}, {node_id, Pub}, {base_cfg, Base} | Cfg].

end_per_testcase(_TC, Cfg) ->
    _ = stop(?config(ns, Cfg)),
    _ = file:del_dir_r(?config(dir, Cfg)),
    ok.

%%%===================================================================
%%% tests
%%%===================================================================

%% A sole founder (no explicit committee) seeds a 1-validator committee: one `{add, self}` config
%% entry at slot 1, and nothing else.
t_founder_bootstrap(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    _ = start(Cfg, #{}),
    ?assertEqual([Self], quod_simplex:committee(Ns)),
    St = quod_simplex:status(Ns),
    ?assertEqual([Self], maps:get(committee, St)),
    ?assertEqual(1, maps:get(slot, St)),
    ?assertEqual(1, maps:get(committed, St)).

%% On create the founder commits the genesis `.pl` content as a block right after the committee:
%% slot 1 = the `{add, self}` committee entry, slot 2 = the genesis content block. Read the block
%% back off disk to confirm it actually holds the genesis transaction with a non-empty diff (not an
%% empty/wrong block that would still bump the height).
t_genesis_seeds_content(Cfg) ->
    Ns   = ?config(ns, Cfg),
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    _ = start(Cfg, #{genesis_file => File}),
    St = quod_simplex:status(Ns),
    ?assertEqual(2, maps:get(slot, St)),
    ?assertEqual(2, maps:get(committed, St)),
    {ok, Store} = quod_ledger_store:open(Ns, ?config(dir, Cfg)),
    try
        {ok, #entry{kind = block, data = Tx}} = quod_ledger_store:read_at(Store, 2),
        ?assertMatch(#transaction{tx_id = <<"genesis:", _/binary>>}, Tx),
        ?assert(length(Tx#transaction.diff) >= 1)
    after quod_ledger_store:close(Store) end.

%% Stage 2 ACCEPTS a multi-member committee (co-founders): the founder bootstraps the full validator
%% set from it. (Reaching a ⅔ quorum needs the peers — that is the multi-node CT; here we just check
%% the config is accepted and the committee is seeded.)
t_multi_member_accepted(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    {P2, _} = quod_identity:generate(),
    _ = start(Cfg, #{committee => [P2]}),
    ?assertEqual(lists:usort([Self, P2]), quod_simplex:committee(Ns)).

%% Each append commits (N=1: on its own fsync) and advances the height by one.
t_append_commits_and_persists(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    _ = start(Cfg, #{}),
    ?assertEqual({ok, 2}, quod_simplex:append(Ns, tx(Ns, Self, <<"a">>))),   %% slot 1 = committee
    ?assertEqual({ok, 3}, quod_simplex:append(Ns, tx(Ns, Self, <<"b">>))),
    St = quod_simplex:status(Ns),
    ?assertEqual(3, maps:get(slot, St)),
    ?assertEqual(3, maps:get(committed, St)).

%% A restart reloads the durable log: the height and the committee are recovered from disk (the
%% blocks themselves are NOT kept in memory — the store is the archive).
t_restart_replays(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    _ = start(Cfg, #{}),
    ?assertEqual({ok, 2}, quod_simplex:append(Ns, tx(Ns, Self, <<"a">>))),
    ?assertEqual({ok, 3}, quod_simplex:append(Ns, tx(Ns, Self, <<"b">>))),
    stop(Ns),
    _ = start(Cfg, #{}),                       %% durable state present ⇒ from_durable, not bootstrap
    St = quod_simplex:status(Ns),
    ?assertEqual(3, maps:get(slot, St)),
    ?assertEqual(3, maps:get(committed, St)),
    ?assertEqual([Self], quod_simplex:committee(Ns)).

t_status_stats(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    _ = start(Cfg, #{}),
    _ = quod_simplex:append(Ns, tx(Ns, Self, <<"a">>)),
    S = quod_simplex:stats(Ns),
    ?assertEqual(1, maps:get(appends, S)),
    ?assertEqual(1, maps:get(committee_size, S)),
    ?assertEqual(2, maps:get(slot, S)),
    ?assertEqual(2, maps:get(committed, S)).

%% A learner (a non-voting member-op) is admitted, committed at N=1, and SURVIVES restart: the fold
%% re-reads it from the durable `config` entry. Persisting a member-op as a `block` (the pre-fix bug) would
%% make the re-fold drop it — so `nonvoting=[LPub]` after restart is the assertion that pins the fix. And
%% because a learner does not change the voting set, the founder keeps committing at quorum 1 afterward.
t_admit_learner_survives_restart(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    {LPub, _} = quod_identity:generate(),                   %% a fresh learner pubkey (no live process)
    _ = start(Cfg, #{}),
    ?assertEqual({ok, 2}, quod_simplex:append(Ns, tx(Ns, Self, <<"a">>))),
    ?assertEqual({ok, 3}, quod_simplex:append(Ns, {add_learner, LPub})),    %% member-op via append
    ?assertEqual({ok, 4}, quod_simplex:append(Ns, tx(Ns, Self, <<"b">>))),  %% still commits — quorum stayed 1
    St = quod_simplex:status(Ns),
    ?assertEqual([Self],  maps:get(committee, St)),
    ?assertEqual([LPub],  maps:get(nonvoting, St)),
    ?assertEqual(4, maps:get(slot, St)),
    stop(Ns),
    _ = start(Cfg, #{}),                                    %% restart ⇒ re-fold the committee from disk
    St2 = quod_simplex:status(Ns),
    ?assertEqual([Self],  maps:get(committee, St2)),
    ?assertEqual([LPub],  maps:get(nonvoting, St2)),        %% the learner survived (kind=config re-fold)
    ?assertEqual(4, maps:get(slot, St2)).

%% The membership gate: this increment admits only a genuinely NEW non-voting member. Voter-changing ops
%% (add/promote/remove), a demotion (add_learner naming a CURRENT voter), and garbage are rejected with
%% {error,bad_change} and never commit — so a bad caller / Byzantine leader can't empty, shrink, or pack the
%% committee (those land with the live-joiner increment). The process stays alive + serving after each reject.
t_membership_gate_rejects(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    {P2, _} = quod_identity:generate(),
    _ = start(Cfg, #{}),
    ?assertEqual({ok, 2}, quod_simplex:append(Ns, tx(Ns, Self, <<"a">>))),
    ?assertEqual({error, bad_change}, quod_simplex:append(Ns, {add, P2})),           %% voter change
    ?assertEqual({error, bad_change}, quod_simplex:append(Ns, {promote, P2})),       %% voter change
    ?assertEqual({error, bad_change}, quod_simplex:append(Ns, {remove, Self})),      %% would empty the set
    ?assertEqual({error, bad_change}, quod_simplex:append(Ns, {add_learner, Self})), %% demote a current voter
    ?assertEqual({error, bad_change}, quod_simplex:append(Ns, {frobnicate, P2})),    %% garbage (not crashed)
    St = quod_simplex:status(Ns),                              %% nothing committed: unchanged + still alive
    ?assertEqual([Self], maps:get(committee, St)),
    ?assertEqual([],     maps:get(nonvoting, St)),
    ?assertEqual(2, maps:get(slot, St)),
    ?assertEqual({ok, 3}, quod_simplex:append(Ns, {add_learner, P2})).   %% a genuinely-new learner still OK

%%%===================================================================
%%% helpers
%%%===================================================================

start(Cfg, Extra) ->
    Ns = ?config(ns, Cfg),
    {ok, Pid} = quod_simplex:start_link(Ns, maps:merge(?config(base_cfg, Cfg), Extra)),
    unlink(Pid),
    Pid.

%% gen_statem:stop is a synchronous, clean shutdown that RUNS terminate/3 (closing the store) —
%% unlike exit(Pid, shutdown) on a non-trapping gen_statem, which would skip terminate entirely.
stop(Ns) ->
    case quod_reg:where({quod_simplex, Ns}) of
        undefined -> ok;
        Pid       -> _ = catch gen_statem:stop(Pid, shutdown, 5000), ok
    end.

tx(Ns, Author, Id) ->
    #transaction{tx_id = Id, caller_ns = Ns, diff = [], read_check = #{}, author = Author, sig = none}.
