-module(quod_explorer).
-moduledoc """
Read-only ledger Explorer listener.

The Explorer displays live and historical node state. Goal submission no
longer has an Explorer-specific server path: its console uses the authenticated
signed-goal API on `m:quod_client`, including the shared cursor owner.

The listener remains optional and unauthenticated because every route here is
read-only. It binds loopback by default; a bind failure never affects
consensus.
""".

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(LISTENER, quod_explorer_listener).

start_link() ->
    case application:get_env(quod, explorer_enabled, false) of
        true -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        _ -> ignore
    end.

init([]) ->
    Port = application:get_env(quod, explorer_port, 14569),
    Ip = application:get_env(quod, explorer_ip, {127, 0, 0, 1}),
    case quod_http_listener:start(
           #{name => ?LISTENER, ip => Ip, port => Port, routes => routes()}) of
        {ok, _} ->
            logger:info("quod: explorer on ~p:~p/", [Ip, Port]),
            {ok, #{}};
        {error, Reason} ->
            logger:warning(
              "quod: explorer disabled — listen on ~p:~p failed (~p)",
              [Ip, Port, Reason]),
            {ok, #{}}
    end.

routes() ->
    [{'_', [
        {"/", cowboy_static, {priv_file, quod, "explorer/index.html"}},
        {"/favicon.png", cowboy_static,
         {priv_file, quod, "explorer/favicon.png"}},
        {"/assets/[...]", cowboy_static,
         {priv_dir, quod, "explorer/assets"}},
        {"/health", quod_explorer_http, health},
        {"/ws", quod_explorer_ws, []},
        {"/api/summary", quod_explorer_http, summary},
        {"/api/txs", quod_explorer_http, txs},
        {"/api/tx/:ns/:id", quod_explorer_http, tx},
        {"/api/block/:ns/:slot", quod_explorer_http, block}
    ]}].

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, _State) ->
    quod_http_listener:stop(?LISTENER).
