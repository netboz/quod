-module(quod_sup).
-moduledoc """
quod top-level supervisor.

Boots the QUIC transport. Brahms/Tendermint/Prolog layers get added as children
here.
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
         #{id => quod_brahms_sup,
           start => {quod_brahms_sup, start_link, []},
           type => supervisor}
         %% TODO: quod_tendermint, quod_prolog ...
        ],
    {ok, {SupFlags, ChildSpecs}}.
