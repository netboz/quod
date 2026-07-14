-module(join_SUITE).
-moduledoc """
Stage-3 (Simplex 4) integration: **trustless catch-up over loopback QUIC**. A single founder (`mode=create`,
N=1) founds `join:s5a`, commits a fact, and goes quiescent. A second node (`mode=join`) then boots UNFOUNDED
and, given only the founder's seed address and the out-of-band-pinned genesis hash, **catches up the whole
committed log** — pulling each block+cert on the dedicated `{catchup, Ns}` channel, verifying every cert
against the committee it reconstructs (never trusting the server), and replaying each verified block into its
own KB as it lands. It ends caught up to the founder's height and can `prove` the founder's fact from its OWN
KB, WITHOUT being a committee member (a read-only observer).

Then **S5b admission-to-voter**: the founder admits the caught-up observer (one ordinary
transaction through the normal write path), the observer sees its own `peer_admitted` fact arrive over the
live feed and **self-promotes to a voter** (`maybe_promote` — the committed fact is the signal), and then
proves it really votes: probe writes commit at `quorum(2) = 2` under EACH member's leadership, including a
slot the promoted joiner leads. The admit passes the **readiness gate** (`can_join :- peer_ready(Pk)`,
judged from the observer's live feed digests); a never-seen candidate is refused first.

The suite doubles as the **contact-selection regression** (the 2026-07-12 live wedge — a restarted founder
whose seed head was its OWN endpoint pulled history from itself forever): the joiner's `seed_peers` put its
own address FIRST (selection must self-filter the seeds against `node_addr`), and the final case starts an
observer whose seed list is ENTIRELY itself, so catch-up must find its contact in the live Brahms view.

Each node is its own OS Erlang node (`peer`, stdio-controlled) with its own `quod_quic` listener and Ed25519
identity, so the catch-up request/response is genuine loopback QUIC — the deployment shape.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("quod_ledger.hrl").
-import(quod_ct, [eventually/2, match_ok/1]).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([joiner_catches_up/1, joiner_resumes_after_restart/1, joiner_promoted_to_voter/1,
         self_seeded_joiner_catches_up/1]).

-define(NS, <<"join:s5a">>).
-define(FOUNDER_PORT,  15840).
-define(JOINER_PORT,   15841).
-define(OBSERVER_PORT, 15842).

%% Ordered: the joiner first catches up (height 2), then — after being STOPPED and the founder committing a
%% NEW fact while it is down — a restart RESUMES catch-up from its persisted height and picks up the delta;
%% then the founder ADMITS the caught-up observer and it self-promotes to a voting member (S5b); finally a
%% fresh observer with a USELESS (self-only) seed list catches up via the Brahms view (the wedge regression).
all() -> [joiner_catches_up, joiner_resumes_after_restart, joiner_promoted_to_voter,
          self_seeded_joiner_catches_up].

%%%===================================================================
%%% suite setup: found N=1, commit a fact, then start a mode=join node
%%%===================================================================

init_per_suite(Config) ->
    {FPub, _} = FKey = quod_identity:generate(),
    %% JPub sorts AFTER FPub, pinning round-robin leadership at N=2: the founder leads odd slots (incl.
    %% slot 5, the unpaced post-admit write = the promotion race) and the joiner leads even slots (incl.
    %% slot 6, the promoted-joiner-leads acceptance).
    {JPub, _} = JKey = quod_ct:generate_key_gt(FPub),
    FAddr = {"127.0.0.1", ?FOUNDER_PORT},
    JAddr = {"127.0.0.1", ?JOINER_PORT},

    %% 1. the founder: create a self-only (N=1) committee with the REAL root ontology as genesis (it
    %% carries the `peer_ready`-gated `can_join` rule the admission case gates on — the production
    %% shape), then commit one fact (slot 2).
    Founder = start_node(?FOUNDER_PORT, FKey, Config, founder_cfg()),
    ?assert(eventually(fun() -> slot(Founder) =:= 1 end, 10000)),   %% genesis committed
    ?assert(eventually(fun() -> match_ok(prove(Founder, {assertz, {capital, france, paris}})) end, 20000)),
    ?assert(eventually(fun() -> slot(Founder) =:= 2 end, 10000)),   %% the fact committed

    %% 2. the anchor: the founder's genesis block_hash, delivered to the joiner out-of-band (config), never
    %% TOFU'd from the contact — this is what makes catch-up trustless.
    GH = peer:call(Founder, quod_simplex, genesis_hash, [?NS]),
    ?assert(is_binary(GH)),

    %% 3. the joiner: mode=join, the pinned genesis hash, and a seed list with the joiner's OWN endpoint
    %% FIRST — the exact live-wedge shape (2026-07-12: the restarted founder's Consul-rendered seeds had
    %% itself at the head, and the old head-of-list pick pulled history from itself forever). Contact
    %% selection must self-filter the seeds against `node_addr` (the node's id is its PUBKEY, which never
    %% equals a {Host, Port} seed) and catch up via the founder; this joiner runs NO Brahms overlay during
    %% catch-up, so the self-filtered static seeds are the only contact pool — the fallback path under test.
    %% The explicit cross-learn below is a belt-and-suspenders convenience — the founder actually learns the
    %% joiner from its inbound catch-up header and the joiner learns the founder from the reply header
    %% (growth_SUITE proves growth needs ZERO pre-seeding); kept here to keep this suite's timing crisp.
    JExtra = #{mode => join, genesis_hash => GH, seed_peers => [JAddr, FAddr]},
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

    %% it reaches the founder's height (2) purely by catch-up, and reports itself settled (not syncing).
    ?assert(eventually(fun() -> slot(Joiner) =:= 2 end, 30000)),
    ?assert(eventually(fun() -> maps:get(syncing, status(Joiner), true) =:= false end, 30000)),

    %% every cert verified: the joiner's committee is exactly the founder's (folded from the genesis it
    %% anchored), and the joiner is NOT in it — a read-only observer, not a voter.
    FPub = pub_of(Founder),
    ?assertEqual([FPub], peer:call(Joiner, quod_simplex, committee, [?NS])),
    ?assertNot(lists:member(pub_of(Joiner), peer:call(Joiner, quod_simplex, committee, [?NS]))),

    %% the replayed fact is readable from the joiner's OWN kb (proof the diff was applied, not just stored).
    ?assert(eventually(fun() -> match_ok(prove(Joiner, {capital, france, {'X'}})) end, 15000)),

    %% a write to the non-member joiner is refused (it is not a committee member) — it cannot lead a slot.
    ?assertMatch({error, not_in_charge, none}, peer:call(Joiner, quod_simplex, append, [?NS, dummy_tx()])).

%% After the founder commits a NEW fact the joiner never saw, the WHOLE namespace restarts from disk (a
%% fleet redeploy): the founder re-derives its full log (mode=create, non-empty ⇒ no re-found), and the
%% joiner RESUMES catch-up from its persisted partial height — never re-appending its on-disk prefix (which
%% would hit the store's contiguity check), never treating the partial log as complete — reaching the new
%% height and reading the new fact. Exercises the resume-from-persisted-height path (both create + join on
%% restart). The joiner is stopped BEFORE the founder's commit: a live caught-up observer now TRACKS the
%% head without any overlay (its readiness digests to the committee trigger ahead-replies → verified pull),
%% so the resume-delta only exists while it is down.
joiner_resumes_after_restart(Config) ->
    Founder = ?config(founder, Config),
    Joiner  = ?config(joiner, Config),

    %% take the joiner down, then commit a second fact (height 3) it cannot have seen.
    ok = peer:stop(Joiner),
    ?assert(eventually(fun() -> match_ok(prove(Founder, {assertz, {population, france, 67}})) end, 20000)),
    ?assert(eventually(fun() -> slot(Founder) =:= 3 end, 10000)),

    %% restart both on their SAME data_dirs (founder first so it is serving before the joiner resumes).
    Founder2 = restart_node(Founder, ?FOUNDER_PORT, ?config(fkey, Config), founder_cfg(), Config),
    Joiner2  = start_node(?JOINER_PORT, ?config(jkey, Config), Config, ?config(jextra, Config)),
    ok = peer:call(Founder2, quod_quic, learn, [pub_of(Joiner2), ?config(jaddr, Config)]),
    ok = peer:call(Joiner2,  quod_quic, learn, [?config(fpub, Config), ?config(faddr, Config)]),

    ?assert(eventually(fun() -> slot(Founder2) =:= 3 end, 10000)),   %% founder re-derived its full log
    ?assert(eventually(fun() -> slot(Joiner2) =:= 3 end, 30000)),    %% joiner RESUMED from 2 to 3
    ?assert(eventually(fun() -> maps:get(syncing, status(Joiner2), true) =:= false end, 30000)),
    ?assert(eventually(fun() -> match_ok(prove(Joiner2, {population, france, {'X'}})) end, 15000)),
    ?assert(match_ok(prove(Joiner2, {capital, france, {'X'}}))),   %% the pre-restart prefix survived too
    {save_config, [{founder2, Founder2}, {joiner2, Joiner2}]}.     %% the promotion case runs on these

%% S5b admission-to-voter. The founder ADMITS the caught-up observer — one ordinary transaction through the
%% normal write path (`admit_3` gates `can_join`, stages the `peer_admitted` assert, consensus commits it).
%% The observer, following live commits over the feed, applies the block that admits ITSELF: the committed
%% fact is the signal — `maybe_promote` re-arms its engine over the new committee and `is_participant`
%% flips. Then the proof that it really votes: at N=2 quorum(2)=2, so NOTHING commits unless BOTH members
%% sign — two probe writes, one led by each member (round-robin), must both commit and fan out.
joiner_promoted_to_voter(Config) ->
    {joiner_resumes_after_restart, Saved} = ?config(saved_config, Config),
    Founder = ?config(founder2, Saved),
    Joiner  = ?config(joiner2, Saved),
    FPub  = ?config(fpub, Config),
    JPub  = pub_of(Joiner),
    FAddr = ?config(faddr, Config),
    JAddr = ?config(jaddr, Config),

    %% the feed needs the per-ns Brahms overlay (production wiring lives in quod_app, which CT bypasses):
    %% without it the live commit never reaches the observer and the whole path under test is inert.
    {ok, _} = peer:call(Founder, quod_brahms, start_namespace,
                        [?NS, #{node_id => FAddr, seed_peers => [JAddr]}]),
    {ok, _} = peer:call(Joiner, quod_brahms, start_namespace,
                        [?NS, #{node_id => JAddr, seed_peers => [FAddr]}]),

    %% pre-admit: a caught-up read-only observer.
    ?assertEqual(observer, maps:get(role, status(Joiner))),

    %% the readiness gate (root ontology: `can_join :- peer_ready(Pk)`) refuses a candidate that has
    %% never digested — cold, dead, or still mid-catch-up (`follows/4` keeps it silent until it is settled).
    %% A failed proof commits nothing, so slot numbering below is unaffected.
    {GhostPub, _} = quod_identity:generate(),
    ?assertEqual(fail, prove(Founder, {admit, GhostPub, "127.0.0.1", 9999})),

    %% the founder admits the joiner (slot 4) — retried until the joiner's periodic digests (it has been
    %% feed-following since its restart) register as fresh in the founder's liveness table.
    ?assert(eventually(fun() -> match_ok(prove(Founder, {admit, JPub, "127.0.0.1", ?JOINER_PORT})) end,
                       30000)),

    %% THE PROMOTION RACE, deliberately unpaced: the very next write goes to the founder IMMEDIATELY
    %% after the admit committed — quorum is now 2 but the joiner has (very likely) not yet seen its own
    %% admission over the feed, so the founder's slot-5 proposal lands on a node that drops it. Without
    %% the stuck-head redrive the founder's Δ would self-complain, latch complained[5], and wedge the
    %% namespace forever; with it, the founder re-broadcasts the in-flight proposal each Δ until the
    %% joiner promotes and votes. The prove blocks until the commit — its {ok,_,_} IS the assertion.
    ?assertMatch({ok, _, _}, prove(Founder, {assertz, {promoted, probe, 5}})),
    ?assert(eventually(fun() -> slot(Founder) =:= 5 andalso slot(Joiner) =:= 5 end, 20000)),

    %% the joiner self-promoted along the way: committee, role, and settled state all flipped.
    Both = lists:sort([FPub, JPub]),
    ?assertEqual(Both, lists:sort(peer:call(Joiner, quod_simplex, committee, [?NS]))),
    ?assertEqual(validator, maps:get(role, status(Joiner))),
    ?assertEqual(false, maps:get(syncing, status(Joiner))),
    ?assertEqual(Both, lists:sort(peer:call(Founder, quod_simplex, committee, [?NS]))),

    %% and it LEADS: slot 6 is the joiner's by round-robin (JPub > FPub by construction), so this write
    %% commits only if the promoted joiner proposes + leads it — the milestone's acceptance.
    ?assertMatch({ok, _, _}, prove(Joiner, {assertz, {promoted, probe, 6}})),
    ?assert(eventually(fun() -> slot(Founder) =:= 6 andalso slot(Joiner) =:= 6 end, 20000)),

    %% both probes readable on BOTH nodes (committed by the committee, not one side's illusion).
    ?assert(eventually(fun() -> match_ok(prove(Joiner, {promoted, probe, {'X'}})) end, 15000)),
    ?assert(match_ok(prove(Founder, {promoted, probe, {'X'}}))),
    {save_config, [{founder2, Founder}, {joiner2, Joiner}]}.   %% the wedge-regression case runs on these

%% THE CONTACT-SELECTION REGRESSION (live wedge, 2026-07-12): a joiner whose static seed list is ENTIRELY
%% USELESS — its only seed is ITSELF — must still catch up, because the download contact is sampled from
%% the live Brahms view (self-filtered, gossip-maintained), with the seeds only a cold-start fallback.
%% The old picker took `seeds[0]` unfiltered on every attempt: this node would have pulled from itself
%% forever ({error,{fetch,_}} / no_log), permanently wedged mid-sync. The first attempts here DO
%% fail (Brahms starts just after the namespace ⇒ no view, no usable seed ⇒ {error,no_contact}), which
%% also exercises the quiet re-sample-on-retry path.
self_seeded_joiner_catches_up(Config) ->
    {joiner_promoted_to_voter, Saved} = ?config(saved_config, Config),
    Founder = ?config(founder2, Saved),
    FAddr   = ?config(faddr, Config),
    OKey    = quod_identity:generate(),
    OAddr   = {"127.0.0.1", ?OBSERVER_PORT},
    GH      = peer:call(Founder, quod_simplex, genesis_hash, [?NS]),
    Target  = slot(Founder),
    ?assert(Target >= 6),   %% the full N=2 history (admit + both probes) is what it must pull
    Obs = start_node(?OBSERVER_PORT, OKey, Config,
                     #{mode => join, genesis_hash => GH, seed_peers => [OAddr]}),   %% seeds = [SELF] only
    %% the Brahms overlay is the ONLY usable contact source (production wiring lives in quod_app; CT
    %% starts it explicitly): its view is seeded with the founder, so sampling must find FAddr there.
    {ok, _} = peer:call(Obs, quod_brahms, start_namespace,
                        [?NS, #{node_id => OAddr, seed_peers => [FAddr]}]),
    try
        ?assert(eventually(fun() -> slot(Obs) >= Target end, 60000)),
        ?assert(eventually(fun() -> maps:get(syncing, status(Obs), true) =:= false end, 30000)),
        %% caught up THROUGH the view-sampled contact: the replayed history is in its OWN KB
        ?assert(eventually(fun() -> match_ok(prove(Obs, {capital, france, {'X'}})) end, 15000))
    after
        catch peer:stop(Obs)
    end.

%%%===================================================================
%%% helpers
%%%===================================================================

%% Stop a node and start a fresh OS node reusing its data_dir (derived from the port) + identity + config —
%% a crash/redeploy recovering from disk. Returns the new handle.
restart_node(Old, Port, Key, Extra, Config) ->
    _ = catch peer:stop(Old),
    start_node(Port, Key, Config, Extra).

%% The founder's namespace config: self-only committee, the REAL root ontology as genesis (carries the
%% `peer_ready`-gated `can_join` the admission case gates on). Also used on restart, where the genesis
%% file is simply unused (non-empty log ⇒ no re-found).
founder_cfg() ->
    #{mode => create, committee => [],
      genesis_file => filename:join(code:priv_dir(quod), "ontologies/quod_root.pl")}.

status(Peer) -> peer:call(Peer, quod_simplex, status, [?NS]).
slot(Peer)   -> maps:get(slot, status(Peer), -1).
prove(Peer, Goal) -> peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]).
pub_of(Peer) -> peer:call(Peer, application, get_env, [quod, node_pubkey, undefined]).

%% A shape-valid #transaction (tx_id, caller_ns, diff, read_check, author, sig) — never committed: the
%% non-member joiner refuses the append before any consensus step even inspects it.
dummy_tx() -> #transaction{tx_id = <<"probe">>, caller_ns = ?NS, diff = [],
                           read_check = #{}, author = <<0:256>>}.
