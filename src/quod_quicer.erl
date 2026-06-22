-module(quod_quicer).
-moduledoc """
QUIC transport backend (quicer / msquic).

The QUIC transport: a listener (accepts inbound peers) and a dialer
(`connect/2`). Registered through gproc as `{transport, node}`.

## Per-connection handlers

Each accepted/dialed connection is owned by a handler process that

- registers its **name** `{n, l, {peer, PeerId}}` (addressable), and
- posts its **events** to the property `{p, l, {peer, PeerId}}` (subscribable).

Anything interested in a peer calls `quod_reg:subscribe({peer, PeerId})` and
then receives, in its mailbox:

```erlang
{quod_peer_up,   Peer}
{quod_message,   Peer, Channel, Payload}
{quod_peer_down, Peer, Reason}
```

A *peer* is `#{conn, stream, id => PeerId}`; one bidi stream multiplexes all
channels via a small length-prefixed frame (see `frame/2`). Channel
subscription itself is plain gproc via `m:quod_reg` keyed by `{channel, Name}`.

> #### Status {: .warning }
>
> Starting skeleton. Confirm the exact quicer active-message patterns and the
> accept/handshake/ownership handoff against quicer's own examples.
""".

-behaviour(gen_server).

-include("quod.hrl").

%% public API
-export([start_link/0, connect/2, send/3, close/1]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([peer/0, channel/0]).

-type peer()    :: #{conn := term(), stream := term(),
                     id := term(), addr => term()}.
-type channel() :: binary().

-ifdef(TEST).
%% expose private wire framing for unit tests
-export([frame/2, unframe/1]).
-endif.

-define(KEY, {transport, node}).
-define(IDLE_TIMEOUT_MS, 30000).

-record(state, {listener :: quicer:listener_handle() | undefined,
                port     :: inet:port_number(),
                alpn     :: string()}).

%% ======================================================================
%% public API
%% ======================================================================

start_link() ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, [], []).

-doc "Dial `Host`:`Port`. Returns an opaque peer whose events appear on `{peer, PeerId}`.".
-spec connect(inet:hostname() | inet:ip_address(), inet:port_number()) ->
          {ok, peer()} | {error, term()}.
connect(Host, Port) ->
    gen_server:call(quod_reg:via(?KEY), {connect, Host, Port}, 10000).

-doc "Send `Payload` on `Channel` to a connected peer.".
-spec send(peer(), channel(), iodata()) -> ok | {error, term()}.
send(#{stream := Stream}, Channel, Payload) ->
    Frame = frame(Channel, iolist_to_binary(Payload)),
    case quicer:send(Stream, Frame) of
        {ok, _Len} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Close a peer's QUIC connection.".
-spec close(peer()) -> ok.
close(#{conn := Conn}) ->
    _ = quicer:close_connection(Conn),
    ok.

%% ======================================================================
%% gen_server
%% ======================================================================

init([]) ->
    process_flag(trap_exit, true),
    Port = env(listen_port, 14567),
    ALPN = env(alpn, "quod"),
    ListenOpts =
        [{certfile, env(certfile, "priv/certs/cert.pem")},
         {keyfile,  env(keyfile,  "priv/certs/key.pem")},
         {alpn, [ALPN]},
         {peer_bidi_stream_count, 64},
         {idle_timeout_ms, ?IDLE_TIMEOUT_MS}],
    case quicer:listen(Port, ListenOpts) of
        {ok, Listener} ->
            logger:info("quod: QUIC listening on ~p (alpn ~s)", [Port, ALPN]),
            _Acceptor = spawn_link(fun() -> acceptor_loop(Listener) end),
            {ok, #state{listener = Listener, port = Port, alpn = ALPN}};
        {error, Reason} ->
            logger:error("quod: QUIC listen failed: ~p", [Reason]),
            {stop, {listen_failed, Reason}}
    end.

handle_call({connect, Host, Port}, _From, State) ->
    {reply, do_connect(Host, Port, State), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, Reason}, State = #state{listener = L}) ->
    logger:warning("quod: acceptor exited (~p), restarting", [Reason]),
    _ = spawn_link(fun() -> acceptor_loop(L) end),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{listener = L}) when L =/= undefined ->
    _ = quicer:close_listener(L),
    ok;
terminate(_Reason, _State) ->
    ok.

%% ======================================================================
%% dialer
%% ======================================================================

do_connect(Host, Port, #state{alpn = ALPN}) ->
    ConnOpts = [{alpn, [ALPN]}, {verify, none}, {idle_timeout_ms, ?IDLE_TIMEOUT_MS}],
    case quicer:connect(Host, Port, ConnOpts, 5000) of
        {ok, Conn} ->
            case quicer:start_stream(Conn, [{active, true}]) of
                {ok, Stream} ->
                    Peer = #{conn => Conn, stream => Stream,
                             id => uid(), addr => {Host, Port}},
                    Handler = spawn(fun() -> start_peer(Peer) end),
                    _ = quicer:controlling_process(Conn, Handler),
                    {ok, Peer};
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end.

%% ======================================================================
%% acceptor + per-connection handler
%% ======================================================================

acceptor_loop(Listener) ->
    case quicer:accept(Listener, [], infinity) of
        {ok, Conn} ->
            Handler = spawn(fun() -> handle_inbound(Conn) end),
            _ = quicer:controlling_process(Conn, Handler),
            acceptor_loop(Listener);
        {error, Reason} ->
            logger:warning("quod: accept error: ~p", [Reason]),
            timer:sleep(100),
            acceptor_loop(Listener)
    end.

handle_inbound(Conn) ->
    case quicer:handshake(Conn) of
        {ok, Conn} ->
            %% Announce the peer on handshake (so it is discoverable) BEFORE
            %% blocking on accept_stream, which only returns once the peer
            %% actually opens a stream by sending.
            Peer0 = #{conn => Conn, stream => undefined,
                      id => uid(), addr => peer_addr(Conn)},
            Key = register_peer(Peer0),
            case quicer:accept_stream(Conn, [{active, true}]) of
                {ok, Stream} ->
                    conn_loop(Peer0#{stream => Stream}, Key);
                {error, Reason} ->
                    peer_down(Peer0, Key, Reason)
            end;
        {error, Reason} ->
            logger:warning("quod: handshake failed: ~p", [Reason])
    end.

%% Outbound peers already hold their stream, so register and loop directly.
start_peer(Peer) ->
    conn_loop(Peer, register_peer(Peer)).

%% Register {n,l,{peer,PeerId}} and announce peer-up on {p,l,{peer,PeerId}}.
register_peer(Peer = #{id := PeerId}) ->
    Key = {peer, PeerId},
    _ = quod_reg:reg(Key),
    _ = quod_reg:publish(Key, ?QUOD_PEER_UP(Peer)),
    logger:info("quod: peer up ~p", [PeerId]),
    Key.

conn_loop(Peer = #{conn := Conn, stream := Stream}, Key) ->
    receive
        {quic, Data, Stream, _Props} when is_binary(Data) ->
            {Channel, Payload} = unframe(Data),
            Msg = ?QUOD_MESSAGE(Peer, Channel, Payload),
            _ = quod_reg:publish(Key, Msg),                  %% per-peer events
            _ = quod_reg:publish({channel, Channel}, Msg),   %% per-channel (namespace router)
            conn_loop(Peer, Key);
        {quic, peer_send_shutdown, Stream, _} ->
            conn_loop(Peer, Key);
        {quic, stream_closed, Stream, _} ->
            conn_loop(Peer, Key);
        {quic, closed, Conn, _} ->
            peer_down(Peer, Key, closed);
        {quic, transport_shutdown, Conn, Reason} ->
            peer_down(Peer, Key, Reason);
        {quic, shutdown, Conn} ->
            peer_down(Peer, Key, shutdown);
        Other ->
            logger:debug("quod: unhandled quic msg: ~p", [Other]),
            conn_loop(Peer, Key)
    end.

peer_down(Peer = #{id := PeerId}, Key, Reason) ->
    logger:info("quod: peer down ~p (~p)", [PeerId, Reason]),
    _ = quod_reg:publish(Key, ?QUOD_PEER_DOWN(Peer, Reason)),
    ok.

%% Unique per-connection id. Becomes the remote node's public key once identity
%% exists; for now a monotonic integer so registrations never collide.
uid() -> erlang:unique_integer([positive, monotonic]).

%% Best-effort remote address, kept as info on the peer.
peer_addr(Conn) ->
    try quicer:peername(Conn) of
        {ok, Addr} -> Addr;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

%% ======================================================================
%% wire framing: <<CLen:16, Channel:CLen/binary, Payload/binary>> so one
%% stream multiplexes many channels.
%% ======================================================================

-spec frame(binary(), binary()) -> binary().
frame(Channel, Payload) ->
    CLen = byte_size(Channel),
    <<CLen:16/unsigned, Channel/binary, Payload/binary>>.

-spec unframe(binary()) -> {binary(), binary()}.
unframe(<<CLen:16/unsigned, Rest/binary>>) ->
    <<Channel:CLen/binary, Payload/binary>> = Rest,
    {Channel, Payload}.

%% ======================================================================
env(Key, Default) -> application:get_env(quod, Key, Default).
