-module(quod_tx_view).
-moduledoc """
Optional **live transaction viewer** — a small read-only web page + WebSocket that streams committed
transactions as they finalize. It is a debug/observability surface, NOT part of consensus.

**Disabled by default.** It is unauthenticated, so it must be turned on deliberately (`transactions.enabled`)
and binds **loopback** (`transactions.ip`, default `127.0.0.1`) unless an operator widens it on purpose.
When disabled, `start_link/0` returns `ignore`, so the supervisor starts no listener at all — a bind
failure can never crash node boot, co-located test nodes never collide on the port, and no node exposes
ledger content unless explicitly asked to.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(LISTENER, quod_tx_view_listener).

start_link() ->
    case application:get_env(quod, transactions_enabled, false) of
        true -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        _    -> ignore   %% opt-in only — no process, no listener
    end.

init([]) ->
    Port = application:get_env(quod, transactions_port, 14569),
    Ip   = application:get_env(quod, transactions_ip, {127, 0, 0, 1}),
    Dispatch = cowboy_router:compile([{'_', [
        {"/", quod_tx_view_page, []},
        {"/health", quod_tx_view_page, health},
        {"/ws", quod_tx_view_ws, []}
    ]}]),
    %% NEVER let a viewer bind failure take down the node: on error, log and run without a listener (the
    %% viewer is optional; consensus must not depend on it). Reuse a listener that survived our own restart
    %% (terminate stops it on a clean exit; a brutal kill can leave it up).
    case cowboy:start_clear(?LISTENER, [{port, Port}, {ip, Ip}], #{env => #{dispatch => Dispatch}}) of
        {ok, _} ->
            logger:info("quod: transaction view on ~p:~p/", [Ip, Port]),
            {ok, #{}};
        {error, {already_started, _}} ->
            {ok, #{}};
        {error, Reason} ->
            logger:warning("quod: transaction view disabled — listen on ~p:~p failed (~p)", [Ip, Port, Reason]),
            {ok, #{}}
    end.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> _ = cowboy:stop_listener(?LISTENER), ok.
