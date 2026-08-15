-module(quod_client).
-moduledoc """
Dedicated browser client endpoint.

The listener is disabled by default. It provides static client assets, fixed
Ed25519 authentication messages, and the single signed-goal API used for
reads, writes and retained backtracking cursors. User-home creation is an
ordinary signed root goal; this boundary has no predicate-specific command.

**It is served over TLS.** Not for confidentiality alone: a browser withholds
Web Crypto entirely outside a secure context, so over plain HTTP the client
cannot generate, unlock, or sign with a key at all. Without a configured
certificate the node serves its own self-signed one (`m:quod_client_tls`).

The client endpoint is important, but it must never stop consensus from
starting. A TLS or bind failure stays inside this process and is retried with a
bounded delay. While it is down the node remains a normal Quod node; the
client's own health endpoint is simply unavailable.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(LISTENER, quod_client_listener).
-define(RETRY_INITIAL_MS, 5000).
-define(RETRY_MAX_MS, 5 * 60 * 1000).
-define(TLS_CHECK_MS, 24 * 60 * 60 * 1000).

start_link() ->
    case application:get_env(quod, client_enabled, false) of
        true -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        _ -> ignore
    end.

init([]) ->
    %% Trap exits so a supervisor shutdown runs terminate/2: it holds the only
    %% stop_listener call, and a listener outliving its owner would keep serving
    %% routes whose backing processes are already gone.
    process_flag(trap_exit, true),
    Port = application:get_env(quod, client_port, 14570),
    Ip = application:get_env(quod, client_ip, {127, 0, 0, 1}),
    {ok, attempt_listener(#{ip => Ip, port => Port, listener => down,
                            tls => undefined, retry_ms => ?RETRY_INITIAL_MS})}.

attempt_listener(State) ->
    case tls_material() of
        {ok, Tls} -> start_listener(State, Tls);
        {error, Reason} ->
            logger:error("quod: client TLS material unavailable (~p); retrying", [Reason]),
            schedule_retry(State#{listener => down, tls => undefined})
    end.

start_listener(State, Tls) ->
    start_listener(State, Tls, false).

start_listener(State = #{ip := Ip, port := Port}, Tls, Replaced) ->
    case quod_http_listener:start(
           #{name => ?LISTENER, ip => Ip, port => Port, routes => routes(),
             stream_handlers => [quod_http_headers_h], tls => Tls}) of
        {ok, started} ->
            logger:info("quod: client bootstrap on https://~s:~p/",
                        [inet:ntoa(Ip), Port]),
            schedule_tls_check(Tls),
            State#{listener => up, tls => Tls, retry_ms => ?RETRY_INITIAL_MS};
        {ok, already_started} ->
            %% `already_started` keeps the previous Cowboy options, including
            %% its certificate.  Reuse would make our state claim new material
            %% while the old listener may serve an expired certificate forever.
            %% This endpoint owns no long-lived client connections, so replace
            %% the orphaned listener before adopting it.
            replace_or_retry_listener(State, Tls, Replaced);
        {error, Reason} ->
            logger:error("quod: client bootstrap failed — listen on ~s:~p (~p)",
                         [inet:ntoa(Ip), Port, Reason]),
            schedule_retry(State#{listener => down, tls => undefined})
    end.

replace_or_retry_listener(State, Tls, false) ->
    logger:warning("quod: replacing orphaned client listener"),
    quod_http_listener:stop(?LISTENER),
    start_listener(State, Tls, true);
replace_or_retry_listener(State, _Tls, true) ->
    %% The stop/rebind sequence should be synchronous.  If another owner keeps
    %% recreating this global listener, yield to the normal bounded retry rather
    %% than recursing inside this server forever.
    logger:error("quod: client listener remained registered after replacement; retrying"),
    schedule_retry(State#{listener => down, tls => undefined}).

routes() ->
    [{'_', [
        {"/", cowboy_static, {priv_file, quod, "client/index.html"}},
        {"/assets/[...]", cowboy_static, {priv_dir, quod, "client/assets"}},
        {"/explorer", quod_client_http, explorer_index},
        {"/explorer/favicon.png", cowboy_static,
         {priv_file, quod, "explorer/favicon.png"}},
        {"/explorer/assets/[...]", cowboy_static,
         {priv_dir, quod, "explorer/assets"}},
        {"/explorer/ws", quod_explorer_ws, []},
        {"/explorer/api/summary", quod_explorer_http, summary},
        {"/explorer/api/txs", quod_explorer_http, txs},
        {"/explorer/api/tx/:ns/:id", quod_explorer_http, tx},
        {"/explorer/api/block/:ns/:slot", quod_explorer_http, block},
        {"/health", quod_client_http, health},
        {"/api/auth/challenge", quod_client_http, auth_challenge},
        {"/api/auth/complete", quod_client_http, auth_complete},
        {"/api/goals/read", quod_client_http, signed_goal_read},
        {"/api/goals/execute", quod_client_http, signed_goal_execute},
        {"/api/goals/outcomes", quod_client_http, signed_goal_outcome},
        {"/api/goals/cursors", quod_client_http, signed_goal_cursor},
        {"/api/goals/cursors/:id/next", quod_client_http,
         signed_cursor_next},
        {"/api/goals/cursors/:id/accept", quod_client_http,
         signed_cursor_accept},
        {"/api/goals/cursors/:id", quod_client_http, signed_cursor_stop}
     ]}].

%% A configured certificate wins; otherwise the node's own self-signed browser
%% certificate, kept beside its identity key.
tls_material() ->
    case {env_path(client_certfile), env_path(client_keyfile)} of
        {undefined, undefined} -> self_signed();
        {CertFile, KeyFile} when CertFile =/= undefined, KeyFile =/= undefined ->
            {ok, #{certfile => CertFile, keyfile => KeyFile}};
        _ ->
            {error, client_certfile_and_keyfile_must_be_set_together}
    end.

%% The identity directory is where the node's persistent secrets live; without
%% it there is nowhere to keep a certificate that survives a restart, and
%% minting a fresh one each boot would ask every visitor to accept it again.
self_signed() ->
    case application:get_env(quod, identity_dir) of
        {ok, Dir} -> quod_client_tls:ensure(Dir);
        undefined -> {error, no_identity_dir}
    end.

env_path(Key) ->
    case application:get_env(quod, Key, <<>>) of
        <<>> -> undefined;
        "" -> undefined;
        Path when is_binary(Path) -> binary_to_list(Path);
        Path when is_list(Path) -> Path
    end.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Message, State) -> {noreply, State}.
handle_info(retry_listener, #{listener := down} = State) ->
    {noreply, attempt_listener(State)};
handle_info(retry_listener, State) ->
    {noreply, State};
handle_info(check_tls, #{listener := up, tls := #{cert := CurrentCert}} = State) ->
    %% The listener keeps the certificate in memory. When `ensure/1` renewed
    %% the self-signed material, restart only this endpoint to present it.
    case self_signed() of
        {ok, #{cert := CurrentCert}} ->
            schedule_tls_check(#{cert => CurrentCert}),
            {noreply, State};
        {ok, Tls} ->
            quod_http_listener:stop(?LISTENER),
            {noreply, start_listener(State#{listener => down}, Tls)};
        {error, Reason} ->
            logger:error("quod: client TLS renewal check failed (~p); retaining current certificate", [Reason]),
            schedule_tls_check(#{cert => CurrentCert}),
            {noreply, State}
    end;
handle_info(check_tls, State) ->
    {noreply, State};
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> quod_http_listener:stop(?LISTENER).

schedule_retry(#{retry_ms := Delay} = State) ->
    erlang:send_after(Delay, self(), retry_listener),
    State#{retry_ms => min(Delay * 2, ?RETRY_MAX_MS)}.

%% Only self-signed material belongs to this process. Operator-managed PEM
%% files are deliberately not polled or replaced here.
schedule_tls_check(#{cert := _}) ->
    erlang:send_after(?TLS_CHECK_MS, self(), check_tls),
    ok;
schedule_tls_check(#{certfile := _, keyfile := _}) ->
    %% Operator-managed PEM material is deliberately left untouched.
    ok.
