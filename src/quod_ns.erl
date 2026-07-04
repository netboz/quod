-module(quod_ns).
-moduledoc """
Per-namespace sub-supervisor — the unit of **fate-sharing** for one ontology's
content processes. Supervises `quod_simplex` then `quod_prolog` with **`rest_for_one`**.

The durable log rebuilds the kb, never the other way round: if `quod_simplex` crashes,
`rest_for_one` restarts it *and then* `quod_prolog` (which rebuilds from the
reloaded log); if `quod_prolog` crashes alone, only it restarts and rebuilds from
`quod_simplex`'s committed prefix via the rebuild handshake. See
`doc/ordering-layer-spec.md` §5.2.
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
           restart => permanent, type => worker}],
    {ok, {Flags, Children}}.
