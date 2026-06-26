-module(quod_ns_sup).
-moduledoc """
Root of the content-layer subtree: a `simple_one_for_one` parent that starts one
`quod_ns` per ontology namespace. Mirrors `m:quod_brahms_sup`. See
`doc/ordering-layer-spec.md` §5.1.
""".
-behaviour(supervisor).
-export([start_link/0, start_namespace/2, stop_namespace/1, namespaces/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link(quod_reg:via({quod_ns_sup, node}), ?MODULE, []).

-spec start_namespace(binary(), map()) -> supervisor:startchild_ret().
start_namespace(Ns, Config) ->
    supervisor:start_child(quod_reg:via({quod_ns_sup, node}), [Ns, Config]).

-spec stop_namespace(binary()) -> ok | {error, not_found}.
stop_namespace(Ns) ->
    case quod_reg:where({quod_ns, Ns}) of
        undefined -> {error, not_found};
        Pid       -> supervisor:terminate_child(quod_reg:via({quod_ns_sup, node}), Pid)
    end.

namespaces() -> gproc:select([{{{n, l, {quod_ns, '$1'}}, '_', '_'}, [], ['$1']}]).

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Child = #{id => quod_ns, start => {quod_ns, start_link, []},
              restart => transient, type => supervisor},
    {ok, {Flags, [Child]}}.
