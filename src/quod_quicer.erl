-module(quod_quicer).
-moduledoc """
QUIC transport: the listener + dialer, and the **connection authority**.

It owns the QUIC listener, accepts inbound connections (each handed to a
`m:quod_conn` process), and serializes outbound connection creation so there is
**one connection per peer** (no dial race). Streams/links and message delivery
live in `m:quod_conn` / `m:quod_link`.

Upper layers use one async call:

```erlang
quod_quicer:open_link(NodeId, Channel)        %% -> caller gets {link_up, NodeId, Channel, LinkPid}
quod_link:send(LinkPid, Payload)              %% direct, non-blocking
%% messages arrive on the gproc property {channel, Channel}
%% erlang:monitor(LinkPid) -> 'DOWN' is the disconnect
```
""".

-behaviour(gen_server).

-export([start_link/0, open_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(KEY, {transport, node}).
-define(IDLE_TIMEOUT_MS, 30000).
-define(ACCEPTOR_BACKOFF_MS, 500).

-record(state, {listener, port, alpn, self, conns = #{}}).

%% ======================================================================
%% API
%% ======================================================================

start_link() ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, [], []).

-doc """
Open (or reuse) a link to `NodeId = {Host,Port}` for `Channel`. Asynchronous: the
caller receives `{link_up, NodeId, Channel, LinkPid}` when it is ready (or
`{link_error, Channel}`).
""".
-spec open_link({inet:hostname(), inet:port_number()}, binary()) -> ok.
open_link(NodeId, Channel) ->
    gen_server:cast(quod_reg:via(?KEY), {open_link, NodeId, Channel, self()}).

%% ======================================================================
%% gen_server
%% ======================================================================

init([]) ->
    process_flag(trap_exit, true),
    Port = env(listen_port, 14567),
    ALPN = env(alpn, "quod"),
    Self = env(node_id, {"127.0.0.1", Port}),
    ListenOpts =
        [{certfile, env(certfile, "priv/certs/cert.pem")},
         {keyfile,  env(keyfile,  "priv/certs/key.pem")},
         {alpn, [ALPN]},
         {peer_bidi_stream_count, 256},
         {idle_timeout_ms, ?IDLE_TIMEOUT_MS}],
    case quicer:listen(Port, ListenOpts) of
        {ok, Listener} ->
            logger:info("quod: QUIC listening on ~p (alpn ~s, node_id ~p)", [Port, ALPN, Self]),
            _ = spawn_acceptor(Listener, Self),
            {ok, #state{listener = Listener, port = Port, alpn = ALPN, self = Self}};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% the connection authority: one connection per peer, created here.
handle_cast({open_link, NodeId, Channel, ReplyTo}, State) ->
    case dialable(NodeId) of
        true ->
            {ConnPid, State1} = ensure_conn(NodeId, State),
            quod_conn:open_link(ConnPid, Channel, ReplyTo),
            {noreply, State1};
        false ->
            %% a view id that isn't a dialable {Host, Port} must never reach
            %% quicer:connect — it would crash this authority. Refuse it.
            logger:warning("quod: open_link to non-dialable node id ~p dropped", [NodeId]),
            ReplyTo ! {link_error, Channel},
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State = #state{conns = Conns}) ->
    {noreply, State#state{conns = maps:filter(fun(_, P) -> P =/= Pid end, Conns)}};
handle_info({'EXIT', _Pid, Reason}, State) when Reason =:= normal; Reason =:= shutdown ->
    {noreply, State};
handle_info({'EXIT', _Pid, Reason}, State) ->
    logger:warning("quod: acceptor exited (~p), restarting in ~bms", [Reason, ?ACCEPTOR_BACKOFF_MS]),
    _ = erlang:send_after(?ACCEPTOR_BACKOFF_MS, self(), restart_acceptor),
    {noreply, State};
handle_info(restart_acceptor, State = #state{listener = L, self = Self}) when L =/= undefined ->
    _ = spawn_acceptor(L, Self),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{listener = L}) when L =/= undefined ->
    _ = quicer:close_listener(L),
    ok;
terminate(_Reason, _State) ->
    ok.

%% ======================================================================
%% connection authority
%% ======================================================================

ensure_conn(NodeId, State = #state{conns = Conns}) ->
    case maps:get(NodeId, Conns, undefined) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true  -> {Pid, State};
                false -> adopt_or_start(NodeId, State)
            end;
        undefined ->
            adopt_or_start(NodeId, State)
    end.

%% prefer an already-established connection to this peer — e.g. one the peer
%% dialed to US, which `m:quod_conn` registers as `{conn, NodeId}` — over dialing
%% a duplicate. Adopting it (and monitoring it) keeps "one connection per peer".
adopt_or_start(NodeId, State = #state{conns = Conns, self = Self, alpn = ALPN}) ->
    case quod_reg:where({conn, NodeId}) of
        Pid when is_pid(Pid) ->
            _ = erlang:monitor(process, Pid),
            {Pid, State#state{conns = maps:put(NodeId, Pid, Conns)}};
        _ ->
            start_conn(NodeId, Self, ALPN, State)
    end.

start_conn({Host, Port} = NodeId, Self, ALPN, State = #state{conns = Conns}) ->
    ConnOpts = [{alpn, [ALPN]}, {verify, none}, {idle_timeout_ms, ?IDLE_TIMEOUT_MS}],
    Pid = quod_conn:start_outbound(Host, Port, NodeId, Self, ConnOpts),
    _ = erlang:monitor(process, Pid),
    {Pid, State#state{conns = maps:put(NodeId, Pid, Conns)}}.

%% ======================================================================
%% acceptor
%% ======================================================================

spawn_acceptor(Listener, Self) ->
    spawn_link(fun() -> acceptor_loop(Listener, Self) end).

acceptor_loop(Listener, Self) ->
    case quicer:accept(Listener, [], infinity) of
        {ok, Conn} ->
            ConnProc = quod_conn:start_inbound(Conn, Self),
            case quicer:controlling_process(Conn, ConnProc) of
                ok -> ConnProc ! go;
                _  -> exit(ConnProc, kill)
            end,
            acceptor_loop(Listener, Self);
        {error, Reason} ->
            exit({accept_failed, Reason})
    end.

%% ======================================================================

%% a node id is dialable only if it is a `{Host, Port}` with a valid port; any
%% other term (a gossiped binary/atom, a malformed id) must not reach quicer.
dialable({Host, Port}) when is_integer(Port), Port > 0, Port =< 65535 ->
    is_list(Host) orelse is_binary(Host) orelse is_atom(Host) orelse is_tuple(Host);
dialable(_) ->
    false.

env(Key, Default) -> application:get_env(quod, Key, Default).
