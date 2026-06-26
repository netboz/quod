-module(quod_ns).
-moduledoc """
Per-namespace sub-supervisor — the unit of **fate-sharing** for one ontology's
content processes. Supervises `quod_log` then `quod_prolog` with **`rest_for_one`**.

The durable log rebuilds the kb, never the other way round: if `quod_log` crashes,
`rest_for_one` restarts it *and then* `quod_prolog` (which rebuilds from the
reloaded log); if `quod_prolog` crashes alone, only it restarts and rebuilds from
`quod_log`'s committed prefix via the rebuild handshake. See
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
        [#{id => quod_log,    start => {quod_log,    start_link, [Ns, Config]},
           restart => permanent, type => worker},
         #{id => quod_prolog, start => {quod_prolog, start_link, [Ns, Config]},
           restart => permanent, type => worker}],
    {ok, {Flags, Children}}.
