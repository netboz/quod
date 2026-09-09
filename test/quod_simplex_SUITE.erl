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

-define(GENESIS_TX_VERSION, 1).
-define(GENESIS_TX_TAG, "quod/genesis").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([t_founder_bootstrap/1, t_genesis_seeds_content/1, t_append_commits_and_persists/1,
         t_restart_replays/1, t_unsigned_history_rejected/1, t_status_stats/1,
         t_multi_member_accepted/1, t_commit_carries_cert/1,
         t_concurrent_appends_batch/1, t_join_anchor_validation/1,
         t_fresh_foundings_are_distinct/1,
         t_genesis_hash_is_lock_free_and_lifetime_bound/1]).

all() ->
    [t_founder_bootstrap, t_genesis_seeds_content, t_append_commits_and_persists,
     t_restart_replays, t_unsigned_history_rejected, t_status_stats,
     t_multi_member_accepted, t_commit_carries_cert, t_concurrent_appends_batch,
     t_join_anchor_validation, t_fresh_foundings_are_distinct,
     t_genesis_hash_is_lock_free_and_lifetime_bound].

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

%% A sole founder (no explicit committee) seeds a 1-validator committee: the genesis block (slot 1)
%% asserts its own `peer_admitted` fact, and the committee is derived from it — `[Self]`.
t_founder_bootstrap(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    _ = start(Cfg, #{}),
    ?assertEqual([Self], quod_simplex:committee(Ns)),
    St = quod_simplex:status(Ns),
    ?assertEqual([Self], maps:get(committee, St)),
    ?assertEqual(1, maps:get(slot, St)),
    ?assertEqual(1, maps:get(committed, St)).

%% On create the founder commits ONE genesis block (slot 1): the transaction records the random
%% incarnation, asserts the committee's `peer_admitted` fact(s), and includes the genesis `.pl` content.
t_genesis_seeds_content(Cfg) ->
    Ns   = ?config(ns, Cfg),
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    _ = start(Cfg, #{genesis_file => File}),
    St = quod_simplex:status(Ns),
    ?assertEqual(1, maps:get(slot, St)),
    ?assertEqual(1, maps:get(committed, St)),
    {ok, Store} = quod_ledger_store:open(Ns, ?config(dir, Cfg)),
    try
        {ok, Entry} = quod_ledger_store:read_at(Store, 1),
        #entry{data = {batch, [Tx]}} = quod_ledger:entry_view(Entry),
        {ok, Incarnation} = decode_genesis_id(Ns, Tx#transaction.tx_id),
        ?assertEqual(
           [Incarnation],
           [Nonce
            || {assert, {{consensus_incarnation, Nonce}, _Body}} <-
                   Tx#transaction.diff]),
        %% incarnation + founder peer_admitted + root content
        ?assert(length(Tx#transaction.diff) >= 3)
    after quod_ledger_store:close(Store) end.

%% The canonical (smallest-key) founder may seed the complete validator set.
%% Another configured member cannot independently create a competing genesis.
t_multi_member_accepted(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    Lower = <<0:256>>,
    ?assert(Lower < Self),
    ?assertMatch(
       {error, {bad_config, {create_requires_canonical_founder, Lower}}},
       failed_start(
         Ns, maps:merge(?config(base_cfg, Cfg),
                        #{mode => create, committee => [Lower]}))),
    Higher = binary:copy(<<16#ff>>, 32),
    ?assert(Self < Higher),
    _ = start(Cfg, #{committee => [Higher]}),
    ?assertEqual([Self, Higher], quod_simplex:committee(Ns)).

%% Each append commits (N=1: on its own fsync) and advances the height by one.
t_append_commits_and_persists(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    _ = start(Cfg, #{}),
    ?assertEqual({ok, 2}, quod_simplex:append(Ns, tx(Ns, Self, <<"a">>))),   %% slot 1 = genesis
    ?assertEqual({ok, 3}, quod_simplex:append(Ns, tx(Ns, Self, <<"b">>))),
    St = quod_simplex:status(Ns),
    ?assertEqual(3, maps:get(slot, St)),
    ?assertEqual(3, maps:get(committed, St)),
    %% block timestamps are populated + monotonic non-decreasing across slots
    {ok, Store} = quod_ledger_store:open(Ns, ?config(dir, Cfg)),
    try
        {ok, E2} = quod_ledger_store:read_at(Store, 2),
        {ok, E3} = quod_ledger_store:read_at(Store, 3),
        #entry{timestamp = T2} = quod_ledger:entry_view(E2),
        #entry{timestamp = T3} = quod_ledger:entry_view(E3),
        ?assert(T2 > 0),
        ?assert(T3 >= T2)
    after quod_ledger_store:close(Store) end.

%% A restart reloads the durable log: the height and the committee are recovered from disk (the
%% blocks themselves are NOT kept in memory — the store is the archive).
t_restart_replays(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    _ = start(Cfg, #{}),
    GenesisHash = quod_simplex:genesis_hash(Ns),
    ?assertEqual({ok, 2}, quod_simplex:append(Ns, tx(Ns, Self, <<"a">>))),
    ?assertEqual({ok, 3}, quod_simplex:append(Ns, tx(Ns, Self, <<"b">>))),
    stop(Ns),
    _ = start(Cfg, #{}),                       %% durable state present ⇒ from_durable, not bootstrap
    ?assertEqual(GenesisHash, quod_simplex:genesis_hash(Ns)),
    St = quod_simplex:status(Ns),
    ?assertEqual(3, maps:get(slot, St)),
    ?assertEqual(3, maps:get(committed, St)),
    ?assertEqual([Self], quod_simplex:committee(Ns)),
    ?assertEqual({ok, 4}, quod_simplex:append(Ns, tx(Ns, Self, <<"c">>))),
    {ok, Store} = quod_ledger_store:open(Ns, ?config(dir, Cfg)),
    try
        {ok, Entry} = quod_ledger_store:read_at(Store, 4),
        #entry{data = {batch, [T]}} = quod_ledger:entry_view(Entry),
        ?assertEqual(3, T#transaction.author_seq)
    after quod_ledger_store:close(Store) end.

%% A new ledger is a new consensus incarnation even when namespace, identity,
%% committee, and ontology content are otherwise identical.
t_fresh_foundings_are_distinct(Cfg) ->
    Ns = ?config(ns, Cfg),
    _ = start(Cfg, #{}),
    First = quod_simplex:genesis_hash(Ns),
    stop(Ns),
    Dir2 = lists:flatten([?config(dir, Cfg), "_second"]),
    Config2 = maps:put(data_dir, Dir2, ?config(base_cfg, Cfg)),
    try
        {ok, Pid} = quod_simplex:start_link(Ns, Config2),
        unlink(Pid),
        Second = quod_simplex:genesis_hash(Ns),
        ?assertEqual(32, byte_size(Second)),
        ?assertNotEqual(First, Second)
    after
        stop(Ns),
        _ = file:del_dir_r(Dir2)
    end.

%% The feed starts after `quod_prolog` asks simplex to replay the committed ledger. That replay can
%% legitimately occupy simplex's mailbox, but the anchor was already validated at init and is immutable.
%% Suspending the statem makes a mailbox-backed accessor return its timeout default; this direct read
%% must still work. Stopping the owner then proves the table cannot leak an anchor into a re-founding.
t_genesis_hash_is_lock_free_and_lifetime_bound(Cfg) ->
    Ns = ?config(ns, Cfg),
    Pid = start(Cfg, #{}),
    GenesisHash = quod_simplex:genesis_hash(Ns),
    ok = sys:suspend(Pid),
    try
        %% Establish the premise: a state-machine call cannot pass the suspended mailbox.
        ?assertEqual(undefined, quod_simplex:stats(Ns)),
        ?assertEqual(GenesisHash, quod_simplex:genesis_hash(Ns))
    after
        ok = sys:resume(Pid)
    end,
    ok = stop(Ns),
    ?assertEqual(undefined, quod_simplex:genesis_hash(Ns)).

%% Signature enforcement also applies while rebuilding the node's own durable
%% log. An unsigned submitted transaction cannot become an artifact at all.
%% A canonical genesis-shaped unsigned payload in a later, properly certified
%% slot still reaches recovery's semantic check and must fail the restart.
t_unsigned_history_rejected(Cfg) ->
    Ns = ?config(ns, Cfg),
    Dir = ?config(dir, Cfg),
    Self = ?config(node_id, Cfg),
    _ = start(Cfg, #{}),
    ?assertEqual({ok, 2}, quod_simplex:append(Ns, tx(Ns, Self, <<"signed">>))),
    stop(Ns),
    {ok, Source} = quod_ledger_store:open(Ns, Dir),
    {ok, Genesis} = quod_ledger_store:read_at(Source, 1),
    {ok, E2} = quod_ledger_store:read_at(Source, 2),
    #entry{data = {batch, [Signed]}, timestamp = T2, cert = Cert2} =
        quod_ledger:entry_view(E2),
    ok = quod_ledger_store:close(Source),
    ok = file:del_dir_r(quod_ledger_store:ns_dir(Dir, Ns)),
    {ok, Rewritten0} = quod_ledger_store:open(Ns, Dir),
    Unsigned = Signed#transaction{sig = none},
    ?assertEqual({error, bad_entry}, quod_ledger:new_entry(
                                      2, {batch, [Unsigned]}, T2, Cert2)),
    #entry{data = {batch, [GenesisTx]}} = quod_ledger:entry_view(Genesis),
    {ok, UnsignedBlock} = quod_ledger:new_block(2, 1, {batch, [GenesisTx]}, T2),
    {ok, GenesisBlock} = quod_simplex:block_from_entry(Genesis),
    GenesisHash = quod_simplex:block_hash(GenesisBlock),
    Domain = quod_simplex:consensus_domain(Ns, GenesisHash),
    UnsignedHash = quod_simplex:block_hash(UnsignedBlock),
    Share = quod_simplex:make_share(
              Domain, commit, 2, UnsignedHash,
              maps:get(identity, ?config(base_cfg, Cfg))),
    {ok, UnsignedCert} = quod_simplex:form_cert(
                           Domain, commit, 2, UnsignedHash, [Share], [Self]),
    UnsignedEntry = quod_ledger:entry(UnsignedBlock, UnsignedCert),
    {ok, Rewritten1} = quod_ledger_store:append(
                         Rewritten0,
                         [Genesis, UnsignedEntry]),
    ok = quod_ledger_store:close(Rewritten1),
    %% Existing storage must have the new, domain-bound signing journal before
    %% recovery reaches the deliberately malformed ledger payload below.
    {ok, Journal} = quod_signing_journal:initialize(
                      Ns,
                      Domain,
                      Dir),
    ok = quod_signing_journal:close(Journal),
    ?assertEqual({error, {invalid_transaction_history, 2}},
                 quod_simplex:start_link(Ns, ?config(base_cfg, Cfg))).

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

%% Each committed block carries the quorum certificate that finalized it, persisted on the `#entry` — so a
%% catch-up joiner can trustlessly verify it (Simplex 4 / mode=join). At N=1 the commit cert is the founder's
%% own single commit share (quorum(1)=1) and verifies against the committee; the self-signed genesis (slot 1)
%% carries no cert (it is the out-of-band trust anchor).
t_commit_carries_cert(Cfg) ->
    Ns   = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    _ = start(Cfg, #{}),
    ?assertEqual({ok, 2}, quod_simplex:append(Ns, tx(Ns, Self, <<"a">>))),
    {ok, Store} = quod_ledger_store:open(Ns, ?config(dir, Cfg)),
    try
        {ok, E1} = quod_ledger_store:read_at(Store, 1),
        #entry{cert = none} = quod_ledger:entry_view(E1), %% pinned genesis
        {ok, E2} = quod_ledger_store:read_at(Store, 2),
        #entry{data = {batch, [#transaction{}]}, timestamp = Ts, cert = Cert} =
            quod_ledger:entry_view(E2),
        ?assertMatch(#cert{kind = commit, slot = 2}, Cert),
        ?assert(Ts > 0),                              %% leader stamped a real wall-clock block time (not the 0 default)
        %% the cert BINDS this specific block: block_from_entry/1 rebuilds the exact #block{} (timestamp
        %% mirrored in the entry) so a joiner recomputes the same hash to check the cert names THIS block.
        {ok, PersistedBlock} = quod_simplex:block_from_entry(E2),
        ?assertEqual(quod_simplex:block_hash(PersistedBlock), Cert#cert.block_hash),
        GenesisHash = quod_simplex:genesis_hash(Ns),
        Domain = quod_simplex:consensus_domain(Ns, GenesisHash),
        ?assert(quod_simplex:verify_cert(Domain, Cert, [Self]))            %% ⅔ (=1) valid sig vs the committee
    after quod_ledger_store:close(Store) end.

%% Concurrent callers are sealed into one consensus slot and all receive that slot's
%% durable acknowledgement. This is the throughput path the old `proposing` latch rejected.
t_concurrent_appends_batch(Cfg) ->
    Ns = ?config(ns, Cfg),
    Self = ?config(node_id, Cfg),
    _ = start(Cfg, #{batch_window_ms => 50}),
    Parent = self(),
    Count = 8,
    _ = [spawn(fun() -> Parent ! {batch_result, N,
                                  quod_simplex:append(Ns, tx(Ns, Self, integer_to_binary(N)))}
               end) || N <- lists:seq(1, Count)],
    Results = [receive {batch_result, N, Result} -> {N, Result} after 5000 -> timeout end
               || N <- lists:seq(1, Count)],
    ?assertEqual([{N, {ok, 2}} || N <- lists:seq(1, Count)], lists:sort(Results)),
    {ok, Store} = quod_ledger_store:open(Ns, ?config(dir, Cfg)),
    try
        {ok, Entry} = quod_ledger_store:read_at(Store, 2),
        #entry{data = {batch, Transactions}} = quod_ledger:entry_view(Entry),
        ?assertEqual(Count, length(Transactions)),
        ?assertEqual(lists:seq(1, Count),
                     lists:sort([T#transaction.author_seq
                                 || T <- Transactions]))
    after quod_ledger_store:close(Store) end,
    Stats = quod_simplex:stats(Ns),
    ?assertEqual(1, maps:get(proposals, Stats)),
    ?assertEqual(Count, maps:get(batched_txs, Stats)),
    ?assertEqual(50, maps:get(batch_window_ms, Stats)),
    ?assertEqual(0, maps:get(pending, Stats)).

%% Once a node has durable history, a join configuration must pin the exact
%% slot-1 anchor reconstructed from that history. A typo must fail before the
%% vote journal is restored, while the correct anchor resumes the same chain.
t_join_anchor_validation(Cfg) ->
    Ns = ?config(ns, Cfg),
    _ = start(Cfg, #{}),
    GenesisHash = quod_simplex:genesis_hash(Ns),
    ?assertEqual(32, byte_size(GenesisHash)),
    stop(Ns),
    WrongHash = crypto:hash(sha256, <<"wrong consensus anchor">>),
    ?assertNotEqual(GenesisHash, WrongHash),
    Base = ?config(base_cfg, Cfg),
    ?assertEqual(
       {error, {bad_config, genesis_anchor_mismatch}},
       failed_start(
         Ns, maps:merge(Base, #{mode => join, genesis_hash => WrongHash}))),
    ?assertEqual(
       {error, {bad_config, join_requires_genesis_hash}},
       failed_start(
         Ns, maps:merge(Base, #{mode => join, genesis_hash => <<1, 2, 3>>}))),
    {ok, Pid} = quod_simplex:start_link(
                  Ns, maps:merge(Base, #{mode => join,
                                         genesis_hash => GenesisHash})),
    unlink(Pid),
    ?assertEqual(GenesisHash, quod_simplex:genesis_hash(Ns)).

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

%% A failed `start_link` exits its transient child while the caller is still
%% linked. Trap that expected signal locally so the CT process can assert the
%% returned configuration error without weakening production startup.
failed_start(Ns, Config) ->
    WasTrapping = process_flag(trap_exit, true),
    try
        quod_simplex:start_link(Ns, Config)
    after
        receive {'EXIT', _Pid, _Reason} -> ok after 0 -> ok end,
        process_flag(trap_exit, WasTrapping)
    end.

tx(Ns, Author, Id) ->
    Anchor = quod_simplex:genesis_hash(Ns),
    {ok, Goal} = quod_durable_term:encode_goal({test_append, Id}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    PlanDigest = crypto:hash(
                   sha256,
                   term_to_binary({test_append, Id}, [deterministic])),
    quod_transaction:bind_id(
      {Ns, Anchor},
      #transaction{tx_id = <<>>, origin = {Ns, Anchor},
                   proof_id = <<0:256>>, plan_digest = PlanDigest,
                   goal = Goal, result = Result,
                   diff = [], read_check = #{}, author = Author, sig = none}).

decode_genesis_id(Ns, TxId) ->
    NsLen = byte_size(Ns),
    case TxId of
        <<?GENESIS_TX_TAG, 0, ?GENESIS_TX_VERSION:8, NsLen:32,
          Ns:NsLen/binary, Nonce:32/binary>> ->
            {ok, Nonce};
        _ ->
            error
    end.
