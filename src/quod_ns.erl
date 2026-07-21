-module(quod_ns).
-moduledoc """
Per-namespace sub-supervisor — the unit of **fate-sharing** for one ontology's
content processes. Supervises, with **`rest_for_one`** (in order): `m:quod_simplex`
(consensus + durable block log), `m:quod_prolog` (the KB projection), `m:quod_prove`
(remote-read endpoint), `m:quod_catchup` (trustless catch-up endpoint), and
`m:quod_feed` (the dissemination feed — gossips committed blocks to the crowd).

The durable log rebuilds the kb, never the other way round: if `quod_simplex` crashes,
`rest_for_one` restarts it *and then* every sibling after it (`quod_prolog` rebuilds
from the reloaded log; the read/catch-up endpoints re-subscribe their channels); if a
later sibling crashes alone, only it — and those after it — restart. `quod_prolog`
rebuilds from `quod_simplex`'s committed prefix via the rebuild handshake.
""".
-behaviour(supervisor).
-export([start_link/2]).
-export([init/1]).

start_link(Ns, Config) ->
    supervisor:start_link(quod_reg:via({quod_ns, Ns}), ?MODULE, {Ns, Config}).

init({Ns, Config}) ->
    Flags = #{strategy => rest_for_one, intensity => 10, period => 10},
    Children =
        [#{id => quod_simplex, start => {quod_simplex, start_link, [Ns, Config]},
           restart => permanent, type => worker},
         #{id => quod_prolog, start => {quod_prolog, start_link, [Ns, Config]},
           restart => permanent, type => worker},
         %% remote-READ endpoint ({prove, Ns} channel): serves reads to non-committee nodes from
         %% this node's committed kb. Depends on quod_prolog.
         #{id => quod_prove,  start => {quod_prove,  start_link, [Ns, Config]},
           restart => permanent, type => worker},
         %% catch-up endpoint ({catchup, Ns} channel): serves the committed block+cert log to a joiner
         %% from a READ-ONLY store view (it opens its own fd; never touches the writer's handle). Last in
         %% the rest_for_one chain — it holds no state the others need, so its own crash restarts only
         %% itself; being last it also re-subscribes harmlessly whenever an earlier sibling restarts.
         #{id => quod_catchup, start => {quod_catchup, start_link, [Ns, Config]},
           restart => permanent, type => worker},
         %% dissemination feed ({feed, Ns} channel): push-pull epidemic gossip of committed blocks to the
         %% non-voting crowd, each block verified against its quorum cert per hop. Last in the chain — it
         %% depends on the others (reads consensus commits via {committed, Ns}, ingests through quod_simplex,
         %% samples quod_brahms) and holds no state they need, so its crash restarts only itself.
         #{id => quod_feed, start => {quod_feed, start_link, [Ns, Config]},
           restart => permanent, type => worker},
         %% runtime projection orchestrator (P tier, agent-fipa-plan §7/§8): rebuilds derived
         %% local state from the committed kb. LAST in the chain: it must come after
         %% quod_prolog (the attach monitor is one-way — a kb restart must restart the runtime
         %% so it re-attaches), and being last means its own crash restarts nothing else, so a
         %% runtime fault never bounces the serving endpoints or amplifies restart intensity.
         #{id => quod_runtime, start => {quod_runtime, start_link, [Ns, Config]},
           restart => permanent, type => worker}],
    {ok, {Flags, Children}}.
