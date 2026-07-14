-module(quod_tx_view).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    Port = application:get_env(quod, transactions_port, 14569),
    Dispatch = cowboy_router:compile([{'_', [
        {"/", quod_tx_view_page, []},
        {"/health", quod_tx_view_page, health},
        {"/ws", quod_tx_view_ws, []}
    ]}]),
    {ok, _} = cowboy:start_clear(quod_tx_view_listener, [{port, Port}],
                                 #{env => #{dispatch => Dispatch}}),
    logger:info("quod: transaction view on :~p/", [Port]),
    {ok, #{}}.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> cowboy:stop_listener(quod_tx_view_listener).
