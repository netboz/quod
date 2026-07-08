-module(join_SUITE).
-moduledoc """
Stage-3 (Simplex 4) integration: **trustless catch-up over loopback QUIC**. A single founder (`mode=create`,
N=1) founds `join:s5a`, commits a fact, and goes quiescent. A second node (`mode=join`) then boots UNFOUNDED
and, given only the founder's seed address and the out-of-band-pinned genesis hash, **catches up the whole
committed log** — pulling each block+cert on the dedicated `{catchup, Ns}` channel, verifying every cert
against the committee it reconstructs (never trusting the server), and replaying each verified block into its
own KB as it lands. It ends caught up to the founder's height and can `prove` the founder's fact from its OWN
KB, WITHOUT being a committee member (a read-only observer; admission to voter is the next slice).

Each node is its own OS Erlang node (`peer`, stdio-controlled) with its own `quod_quic` listener and Ed25519
identity, so the catch-up request/response is genuine loopback QUIC — the deployment shape.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("quod_ledger.hrl").
-import(quod_ct, [eventually/2, match_ok/1]).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([joiner_catches_up/1, joiner_resumes_after_restart/1]).

-define(NS, <<"join:s5a">>).
-define(FOUNDER_PORT, 15840).
-define(JOINER_PORT,  15841).

%% Ordered: the joiner first catches up (height 2), then — after the founder commits a NEW fact it did NOT
%% follow live — a restart RESUMES catch-up from its persisted height and picks up the delta.
all() -> [joiner_catches_up, joiner_resumes_after_restart].

%%%===================================================================
%%% suite setup: found N=1, commit a fact, then start a mode=join node
%%%===================================================================

init_per_suite(Config) ->
    [{FPub, _} = FKey, {JPub, _} = JKey] = [quod_identity:generate() || _ <- [f, j]],
    FAddr = {"127.0.0.1", ?FOUNDER_PORT},
    JAddr = {"127.0.0.1", ?JOINER_PORT},

    %% 1. the founder: create a self-only (N=1) committee, then commit one fact (slot 2).
    Founder = start_node(?FOUNDER_PORT, FKey, Config,
                         #{mode => create, committee => []}),
    ?assert(eventually(fun() -> slot(Founder) =:= 1 end, 10000)),   %% genesis committed
    ?assert(eventually(fun() -> match_ok(prove(Founder, {assertz, {capital, france, paris}})) end, 20000)),
    ?assert(eventually(fun() -> slot(Founder) =:= 2 end, 10000)),   %% the fact committed

    %% 2. the anchor: the founder's genesis block_hash, delivered to the joiner out-of-band (config), never
    %% TOFU'd from the contact — this is what makes catch-up trustless.
    GH = peer:call(Founder, quod_simplex, genesis_hash, [?NS]),
    ?assert(is_binary(GH)),

    %% 3. the joiner: mode=join, the founder as its only seed contact, the pinned genesis hash. It founds
    %% NOTHING; it catches up. Cross-seed the resolvers so the founder can dial the joiner back with the
    %% response (the joiner reaches the founder by its seed address).
    JExtra = #{mode => join, genesis_hash => GH, seed_peers => [FAddr]},
    Joiner = start_node(?JOINER_PORT, JKey, Config, JExtra),
    ok = peer:call(Founder, quod_quic, learn, [JPub, JAddr]),
    ok = peer:call(Joiner,  quod_quic, learn, [FPub, FAddr]),

    [{founder, Founder}, {joiner, Joiner}, {fkey, FKey}, {fpub, FPub}, {faddr, FAddr},
     {jkey, JKey}, {jaddr, JAddr}, {jextra, JExtra} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(P) || P <- [?config(founder, Config), ?config(joiner, Config)]],
    ok.

%% Start one node in its own OS node: its own identity (env), its own QUIC listener on Port, then the
%% namespace with the given extra config (mode/committee/genesis_hash/seed_peers). Returns the peer handle.
start_node(Port, {Pub, Seed}, Config, Extra) ->
    Name = list_to_atom("join_" ++ integer_to_list(Port)),
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
%%% test
%%%===================================================================

%% The joiner catches up the founder's log trustlessly and reads the founder's fact from its own KB, while
%% remaining a NON-member (read-only): its committee is the founder alone, and it never joins the vote.
joiner_catches_up(Config) ->
    Founder = ?config(founder, Config),
    Joiner  = ?config(joiner, Config),

    %% it reaches the founder's height (2) purely by catch-up, and reports itself done.
    ?assert(eventually(fun() -> slot(Joiner) =:= 2 end, 30000)),
    ?assert(eventually(fun() -> maps:get(join, status(Joiner), undefined) =:= done end, 30000)),

    %% every cert verified: the joiner's committee is exactly the founder's (folded from the genesis it
    %% anchored), and the joiner is NOT in it — a read-only observer, not a voter.
    FPub = pub_of(Founder),
    ?assertEqual([FPub], peer:call(Joiner, quod_simplex, committee, [?NS])),
    ?assertNot(lists:member(pub_of(Joiner), peer:call(Joiner, quod_simplex, committee, [?NS]))),

    %% the replayed fact is readable from the joiner's OWN kb (proof the diff was applied, not just stored).
    ?assert(eventually(fun() -> match_ok(prove(Joiner, {capital, france, {'X'}})) end, 15000)),

    %% a write to the non-member joiner is refused (it is not a committee member) — it cannot lead a slot.
    ?assertMatch({error, not_in_charge, none}, peer:call(Joiner, quod_simplex, append, [?NS, dummy_tx()])).

%% A caught-up read-only joiner does NOT follow live commits (it dropped the {log,Ns} stream). After the
%% founder commits a NEW fact, the joiner stays behind. Then the WHOLE namespace restarts from disk (a fleet
%% redeploy): the founder re-derives its full log (mode=create, non-empty ⇒ no re-found), and the joiner
%% RESUMES catch-up from its persisted partial height — never re-appending its on-disk prefix (which would
%% hit the store's contiguity check), never treating the partial log as complete — reaching the new height
%% and reading the new fact. Exercises the resume-from-persisted-height path (both create + join on restart).
joiner_resumes_after_restart(Config) ->
    Founder = ?config(founder, Config),
    Joiner  = ?config(joiner, Config),

    %% the founder commits a second fact (height 3); the read-only joiner does NOT follow it live.
    ?assert(eventually(fun() -> match_ok(prove(Founder, {assertz, {population, france, 67}})) end, 20000)),
    ?assert(eventually(fun() -> slot(Founder) =:= 3 end, 10000)),
    timer:sleep(1500),                                   %% give any (wrongly) live-followed commit time to land
    ?assertEqual(2, slot(Joiner)),                       %% still at the catch-up snapshot — it did not follow live
    ?assertNot(match_ok(prove(Joiner, {population, france, {'X'}}))),

    %% restart both on their SAME data_dirs (founder first so it is serving before the joiner resumes).
    Founder2 = restart_node(Founder, ?FOUNDER_PORT, ?config(fkey, Config),
                            #{mode => create, committee => []}, Config),
    Joiner2  = restart_node(Joiner, ?JOINER_PORT, ?config(jkey, Config), ?config(jextra, Config), Config),
    ok = peer:call(Founder2, quod_quic, learn, [pub_of(Joiner2), ?config(jaddr, Config)]),
    ok = peer:call(Joiner2,  quod_quic, learn, [?config(fpub, Config), ?config(faddr, Config)]),

    ?assert(eventually(fun() -> slot(Founder2) =:= 3 end, 10000)),   %% founder re-derived its full log
    ?assert(eventually(fun() -> slot(Joiner2) =:= 3 end, 30000)),    %% joiner RESUMED from 2 to 3
    ?assert(eventually(fun() -> maps:get(join, status(Joiner2), undefined) =:= done end, 30000)),
    ?assert(eventually(fun() -> match_ok(prove(Joiner2, {population, france, {'X'}})) end, 15000)),
    ?assert(match_ok(prove(Joiner2, {capital, france, {'X'}}))).   %% the pre-restart prefix survived too

%%%===================================================================
%%% helpers
%%%===================================================================

%% Stop a node and start a fresh OS node reusing its data_dir (derived from the port) + identity + config —
%% a crash/redeploy recovering from disk. Returns the new handle.
restart_node(Old, Port, Key, Extra, Config) ->
    _ = catch peer:stop(Old),
    start_node(Port, Key, Config, Extra).

status(Peer) -> peer:call(Peer, quod_simplex, status, [?NS]).
slot(Peer)   -> maps:get(slot, status(Peer), -1).
prove(Peer, Goal) -> peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]).
pub_of(Peer) -> peer:call(Peer, application, get_env, [quod, node_pubkey, undefined]).

%% A shape-valid #transaction (tx_id, caller_ns, diff, read_check, author, sig) — never committed: the
%% non-member joiner refuses the append before any consensus step even inspects it.
dummy_tx() -> #transaction{tx_id = <<"probe">>, caller_ns = ?NS, diff = [],
                           read_check = #{}, author = <<0:256>>}.
