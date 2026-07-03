-module(simplex_SUITE).
-moduledoc """
Stage-2b integration: a real **3-node DispersedSimplex committee over loopback QUIC**. Each validator
runs in its own OS Erlang node (via `peer`, stdio-controlled, no Erlang distribution), with its own
`quod_quic` listener on a distinct port and its own Ed25519 identity — so the `{log, Ns}` proposal /
share / cert traffic between them is genuine loopback QUIC, exactly the deployment shape.

The three co-found the same committee (`mode=create`, `committee` = the three pubkeys, no genesis so
their logs are byte-identical). A write submitted to the **leader** (the lowest-pubkey validator)
proposes a block; the committee collects `⅔` support then commit certs; every node commits and applies
it. A write submitted to a **follower** is redirected. This is the multi-node validation the engine's
eunit tests (a simulated committee) cannot give.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-import(quod_ct, [eventually/2, match_ok/1]).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([commits_across_committee/1, follower_redirects/1]).

-define(NS, <<"simplex:2b">>).
-define(PORTS, [15820, 15821, 15822]).

all() -> [commits_across_committee, follower_redirects].

%%%===================================================================
%%% suite setup: one 3-node committee, shared across the (ordered) tests
%%%===================================================================

init_per_suite(Config) ->
    Keys = [quod_identity:generate() || _ <- ?PORTS],       %% [{Pubkey, Seed}]
    Pubs = [P || {P, _} <- Keys],
    Addrs = [{P, {"127.0.0.1", Port}} || {{P, _}, Port} <- lists:zip(Keys, ?PORTS)],
    Nodes = [start_member(Port, Key, Pubs, Addrs, Config)
             || {Port, Key} <- lists:zip(?PORTS, Keys)],
    [{nodes, Nodes}, {leader, lists:min(Pubs)} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(Peer) || {Peer, _Pub} <- ?config(nodes, Config)],
    ok.

%% Start one validator in its own OS node: its own identity (env), its own QUIC listener on Port, the
%% resolver pre-seeded with every peer's pubkey→addr (so consensus can dial by pubkey), then the
%% namespace as a co-founder of the shared committee. Returns {Peer, Pubkey}.
start_member(Port, {Pub, Seed}, Pubs, Addrs, Config) ->
    Name = list_to_atom("sx_" ++ integer_to_list(Port)),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io, args => ["-pa" | code:get_path()]}),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    KeyTerm = quod_identity:key_term({Pub, Seed}),
    Set = fun(K, V) -> ok = peer:call(Peer, application, set_env, [quod, K, V]) end,
    Set(listen_port,   Port),
    Set(node_addr,     {"127.0.0.1", Port}),   %% advertised endpoint (identity is node_pubkey, below)
    Set(node_pubkey,   Pub),
    Set(identity_key,  KeyTerm),
    Set(identity_cert, quod_identity:mint_cert({Pub, Seed})),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    %% pre-seed the pubkey→addr resolver for the OTHER validators (the first dial needs it; later
    %% ones ride the link header). Then co-found the namespace.
    _ = [peer:call(Peer, quod_quic, learn, [Pj, Addr]) || {Pj, Addr} <- Addrs, Pj =/= Pub],
    DataDir = filename:join(?config(priv_dir, Config), "data_" ++ integer_to_list(Port)),
    Cfg = #{mode => create, node_id => Pub,
            identity  => #{pubkey => Pub, key => KeyTerm},
            committee => Pubs -- [Pub],   %% co-founders (bootstrap usorts [Self | this])
            data_dir  => DataDir},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    {Peer, Pub}.

%%%===================================================================
%%% tests
%%%===================================================================

%% A write submitted to the leader commits across the whole committee and its fact reaches every KB.
commits_across_committee(Config) ->
    Nodes  = ?config(nodes, Config),
    {LeaderPeer, _} = leader_node(Config),
    %% all three co-founded the same 3-validator committee at height 3 (3 {add,M} entries, no genesis)
    [ ?assertEqual(3, slot(Peer)) || {Peer, _} <- Nodes ],
    %% ONE write on the leader commits across the committee (propose -> ⅔ support -> ⅔ commit -> apply).
    %% Retried: quod_prolog answers {error,rebuilding} until its async post-boot replay marks ready, so
    %% the first prove may pre-date readiness. {error,rebuilding} never reaches consensus, so retrying
    %% still yields exactly one committed write — every node advances to height 4, no over-shoot.
    ?assert(eventually(fun() -> match_ok(prove(LeaderPeer, {assertz, {capital, france, paris}})) end, 20000)),
    %% the commit propagates: every node reaches height 4 and reads the fact from its OWN kb
    [ begin
          ?assert(eventually(fun() -> slot(Peer) >= 4 end, 15000)),
          ?assert(eventually(fun() -> match_ok(prove(Peer, {capital, france, {'X'}})) end, 10000))
      end || {Peer, _} <- Nodes ],
    %% the committed height is identical across the committee — no gaps, no over-shoot
    ?assertEqual([4], lists:usort([slot(Peer) || {Peer, _} <- Nodes])).

%% A write submitted to a follower is redirected to the leader, not silently dropped or mis-committed.
follower_redirects(Config) ->
    Nodes = ?config(nodes, Config),
    {LeaderPeer, _} = leader_node(Config),
    [{FollowerPeer, _} | _] = [N || {P, _} = N <- Nodes, P =/= LeaderPeer],
    ?assertMatch({error, {not_leader, _}}, prove(FollowerPeer, {assertz, {should, not_commit}})).

%%%===================================================================
%%% helpers
%%%===================================================================

leader_node(Config) ->
    Leader = ?config(leader, Config),
    lists:keyfind(Leader, 2, ?config(nodes, Config)).

status(Peer) -> peer:call(Peer, quod_simplex, status, [?NS]).
%% -1 (not a valid slot) if status/1 hits its internal timeout and returns #{} — a clean, retryable
%% miss instead of a {badkey,slot} crash. Numeric so `>= 4` in eventually stays false (atom > int in
%% Erlang term order would make an atom sentinel spuriously satisfy it).
slot(Peer) -> maps:get(slot, status(Peer), -1).
prove(Peer, Goal) -> peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]).
