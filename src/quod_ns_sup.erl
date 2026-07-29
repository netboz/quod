-module(quod_ns_sup).
-moduledoc """
Dynamic supervisor for one `quod_ns` subtree per ontology. Child specs have
stable namespace ids and permanent restart semantics. Desired configurations
are owned separately by `m:quod_namespace_manager`, which reconstructs these
children if this supervisor process itself is replaced.
""".
-behaviour(supervisor).
-export([start_link/0, start_namespace/2, stop_namespace/1, namespaces/0,
         start_child/2, stop_child/1, children/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link(quod_reg:via({quod_ns_sup, node}), ?MODULE, []).

-spec start_namespace(binary(), map()) -> supervisor:startchild_ret().
start_namespace(Ns, Config) ->
    quod_namespace_manager:start_content(Ns, Config).

-spec stop_namespace(binary()) -> ok | {error, term()}.
stop_namespace(Ns) ->
    quod_namespace_manager:stop_content(Ns).

start_child(Ns, Config) ->
    supervisor:start_child(
      quod_reg:via({quod_ns_sup, node}),
      #{id => {quod_ns, Ns},
        start => {quod_ns, start_link, [Ns, Config]},
        restart => permanent,
        type => supervisor}).

stop_child(Ns) ->
    Sup = quod_reg:via({quod_ns_sup, node}),
    Id = {quod_ns, Ns},
    case supervisor:terminate_child(Sup, Id) of
        ok -> supervisor:delete_child(Sup, Id);
        {error, not_found} = Error -> Error;
        Error -> Error
    end.

children() ->
    try maps:from_list(
          [{Ns, Pid}
           || {{quod_ns, Ns}, Pid, _Type, _Modules} <-
                  supervisor:which_children(
                    quod_reg:via({quod_ns_sup, node})),
              is_pid(Pid)])
    catch exit:_ -> #{}
    end.

namespaces() -> gproc:select([{{{n, l, {quod_ns, '$1'}}, '_', '_'}, [], ['$1']}]).

init([]) ->
    Flags = #{strategy => one_for_one, intensity => 10, period => 10},
    {ok, {Flags, []}}.
