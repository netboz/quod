-module(quod_sup).
-moduledoc """
quod top-level supervisor.

Owns transport, directory control, namespace supervision, metrics, and the
explorer. Each ontology's consensus and Prolog processes live under
`quod_ns_sup`; `quod_namespace_manager` owns the desired content and Brahms
sets and restores them if either dynamic supervisor is replaced.
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
         #{id => quod_ask_router,
           start => {quod_ask_router, start_link, []},
           type => worker},
         #{id => quod_directory,
           start => {quod_directory, start_link, []},
           type => worker},
         #{id => quod_directory_control,
           start => {quod_directory_control, start_link, []},
           type => worker},
         #{id => quod_foreign_log,
           start => {quod_foreign_log, start_link, []},
           type => worker},
         %% One node-wide owner for private direct-effect custody. Public
         %% effect descriptors remain in their controlling ontology ledgers;
         %% this process only retains the local preparation until ordered apply.
         #{id => quod_effect_journal,
           start => {quod_effect_journal, start_link, []},
           type => worker},
         #{id => quod_brahms_sup,
           start => {quod_brahms_sup, start_link, []},
           type => supervisor},
         #{id => quod_ns_sup,
           start => {quod_ns_sup, start_link, []},
           type => supervisor},
         #{id => quod_namespace_manager,
           start => {quod_namespace_manager, start_link, []},
           type => worker},
         #{id => quod_metrics,
           start => {quod_metrics, start_link, []},
           type => worker},
         #{id => quod_explorer,
           start => {quod_explorer, start_link, []},
           type => worker},
         #{id => quod_client_auth,
           start => {quod_client_auth, start_link, []},
           type => worker},
         #{id => quod_client_cursor,
           start => {quod_client_cursor, start_link, []},
           type => worker},
         #{id => quod_client_goal_router,
           start => {quod_client_goal_router, start_link, []},
           type => worker},
         #{id => quod_client,
           start => {quod_client, start_link, []},
           type => worker}
        ],
    {ok, {SupFlags, ChildSpecs}}.
