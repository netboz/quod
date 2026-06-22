-module(quod_brahms_sup).
-moduledoc """
Supervises one `m:quod_brahms` instance per namespace (ontology), on demand.

`simple_one_for_one`: namespaces are started via `quod_brahms:start_namespace/2`
and are independent. Each child is a per-namespace Brahms membership statem.
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link(quod_reg:via({quod_brahms_sup, node}), ?MODULE, []).

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Child = #{id => quod_brahms,
              start => {quod_brahms, start_link, []},
              restart => transient,
              type => worker},
    {ok, {Flags, [Child]}}.
