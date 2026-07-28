-module(quod_sup).
-moduledoc """
quod top-level supervisor.

Owns transport, directory control, namespace supervision, metrics, and the
explorer. Each ontology's consensus and Prolog processes live under
`quod_ns_sup`.
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link(quod_reg:via({sup, node}), ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 10},
    ChildSpecs =
        [#{id => quod_quic,
           start => {quod_quic, start_link, []},
           type => worker},
         #{id => quod_directory,
           start => {quod_directory, start_link, []},
           type => worker},
         #{id => quod_directory_control,
           start => {quod_directory_control, start_link, []},
           type => worker},
         #{id => quod_brahms_sup,
           start => {quod_brahms_sup, start_link, []},
           type => supervisor},
         #{id => quod_ns_sup,
           start => {quod_ns_sup, start_link, []},
           type => supervisor},
         #{id => quod_metrics,
           start => {quod_metrics, start_link, []},
           type => worker},
         #{id => quod_explorer,
           start => {quod_explorer, start_link, []},
           type => worker}
        ],
    {ok, {SupFlags, ChildSpecs}}.
