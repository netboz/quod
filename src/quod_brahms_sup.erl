-module(quod_brahms_sup).
-moduledoc """
Dynamic supervisor for one `m:quod_brahms` instance per ontology. Stable child
ids and permanent restart semantics handle worker exits; the separate
`m:quod_namespace_manager` reconstructs desired children if this supervisor
process is replaced.
""".

-behaviour(supervisor).

-export([start_link/0, start_child/2, stop_child/1, children/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link(quod_reg:via({quod_brahms_sup, node}), ?MODULE, []).

start_child(Ns, Config) ->
    supervisor:start_child(
      quod_reg:via({quod_brahms_sup, node}),
      #{id => {quod_brahms, Ns},
        start => {quod_brahms, start_link, [Ns, Config]},
        restart => permanent,
        type => worker}).

stop_child(Ns) ->
    Sup = quod_reg:via({quod_brahms_sup, node}),
    Id = {quod_brahms, Ns},
    case supervisor:terminate_child(Sup, Id) of
        ok -> supervisor:delete_child(Sup, Id);
        {error, not_found} = Error -> Error;
        Error -> Error
    end.

children() ->
    try maps:from_list(
          [{Ns, Pid}
           || {{quod_brahms, Ns}, Pid, _Type, _Modules} <-
                  supervisor:which_children(
                    quod_reg:via({quod_brahms_sup, node})),
              is_pid(Pid)])
    catch exit:_ -> #{}
    end.

init([]) ->
    Flags = #{strategy => one_for_one, intensity => 10, period => 10},
    {ok, {Flags, []}}.
