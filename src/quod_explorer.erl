-module(quod_explorer).
-moduledoc """
The **quod explorer** — an Etherscan-style web panel over one node: a live transaction
list fed over WebSocket (no polling), per-transaction detail, history paged off the
durable ledger, and a prove console that submits goals through the normal write path.

Serving layout (all under one cowboy listener):

| route | serves |
| ----- | ------ |
| `/`, `/assets/…` | the React bundle committed under `priv/explorer/` (source in `ui/`) |
| `/api/…` | REST reads + the prove/submit endpoint (`m:quod_explorer_http`) |
| `/ws` | the live event stream (`m:quod_explorer_ws`) |
| `/health` | plain liveness probe for the orchestrator |

**Disabled by default.** It is unauthenticated — and the prove endpoint **writes** —
so it must be turned on deliberately (`explorer.enabled`) and binds **loopback**
(`explorer.ip`, default `127.0.0.1`) unless an operator widens it on purpose. When
disabled, `start_link/0` returns `ignore`, so the supervisor starts no listener at
all — a bind failure can never crash node boot, co-located test nodes never collide
on the port, and no node exposes ledger content unless explicitly asked to.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(LISTENER, quod_explorer_listener).

start_link() ->
    case application:get_env(quod, explorer_enabled, false) of
        true -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        _    -> ignore   %% opt-in only — no process, no listener
    end.

init([]) ->
    Port = application:get_env(quod, explorer_port, 14569),
    Ip   = application:get_env(quod, explorer_ip, {127, 0, 0, 1}),
    Dispatch = cowboy_router:compile([{'_', [
        {"/", cowboy_static, {priv_file, quod, "explorer/index.html"}},
        {"/favicon.png", cowboy_static, {priv_file, quod, "explorer/favicon.png"}},
        {"/assets/[...]", cowboy_static, {priv_dir, quod, "explorer/assets"}},
        {"/health", quod_explorer_http, health},
        {"/ws", quod_explorer_ws, []},
        {"/api/summary", quod_explorer_http, summary},
        {"/api/txs", quod_explorer_http, txs},
        {"/api/tx/:ns/:id", quod_explorer_http, tx},
        {"/api/block/:ns/:slot", quod_explorer_http, block},
        {"/api/prove", quod_explorer_http, prove}
    ]}]),
    %% NEVER let the explorer take down the node: on bind error, log and run without a listener (it
    %% is optional; consensus must not depend on it). Reuse a listener that survived our own restart
    %% (terminate stops it on a clean exit; a brutal kill can leave it up).
    case cowboy:start_clear(?LISTENER, [{port, Port}, {ip, Ip}], #{env => #{dispatch => Dispatch}}) of
        {ok, _} ->
            logger:info("quod: explorer on ~p:~p/", [Ip, Port]),
            {ok, #{}};
        {error, {already_started, _}} ->
            {ok, #{}};
        {error, Reason} ->
            logger:warning("quod: explorer disabled — listen on ~p:~p failed (~p)", [Ip, Port, Reason]),
            {ok, #{}}
    end.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> _ = cowboy:stop_listener(?LISTENER), ok.
