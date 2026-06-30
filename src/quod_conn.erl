-module(quod_conn).
-moduledoc """
A **connection**: one process per peer, **owning** one pure-Erlang `quic`
connection and routing its streams to `m:quod_link` processes.

The `quic` owner model delivers every stream's events to this one process, so
`quod_conn` is the demux point: `{quic, Conn, {stream_data, StreamId, Bin, Fin}}`
is forwarded to the link registered for `StreamId` (a peer-opened stream gets a
fresh inbound link on first sight). It opens outbound streams on `{open_link,
Channel, _}` and learns an inbound peer's node id from the link's header.

Links are **linked** to the connection, so when the connection drops every link
dies with it — and each link's death is the disconnect signal its holder
monitors.
""".

-export([start_outbound/7, start_inbound/2, open_link/3]).

-record(s, {conn, self, peer = undefined,
            streams = #{},   %% StreamId => LinkPid   (every link, for routing inbound data)
            chans   = #{},   %% Channel  => LinkPid   (our OUTBOUND links only, for send reuse/dedup)
            pending = #{}}). %% Channel  => {StreamId, [ReplyTo]} (outbound opens in flight)

-define(CONNECT_TIMEOUT_MS, 5000).

%% --- API -----------------------------------------------------------------

-doc """
Dial `Host:Port` (known node id `Peer`), become the connection owner, serve links.
We present our own `Cert`/`Key` so the peer (the TLS server) can authenticate us via
mutual TLS. `verify => false` skips validating the *peer's* self-signed server cert (no
CA chain); the peer authenticates US, and we authenticate it when it dials back — every
directed pair is server-verifies-client.
""".
-spec start_outbound(inet:hostname(), inet:port_number(), term(), term(), [binary()],
                     term(), term()) -> pid().
start_outbound(Host, Port, Peer, Self, ALPN, Cert, Key) ->
    spawn(fun() ->
        process_flag(trap_exit, true),
        case quic:connect(Host, Port, #{verify => false, cert => Cert, key => Key,
                                        alpn => ALPN}, self()) of
            {ok, Conn} ->
                receive
                    {quic, Conn, {connected, _}} ->
                        loop(#s{conn = Conn, self = Self, peer = Peer});
                    {quic, Conn, {closed, R}} ->
                        logger:debug("quod: connect ~p:~p closed: ~p", [Host, Port, R]),
                        fail_queued_opens(Peer)
                after ?CONNECT_TIMEOUT_MS ->
                    logger:debug("quod: connect ~p:~p timed out", [Host, Port]),
                    fail_queued_opens(Peer)
                end;
            {error, Reason} ->
                logger:debug("quod: connect ~p:~p failed: ~p", [Host, Port, Reason]),
                fail_queued_opens(Peer)
        end
    end).

%% A connection that never comes up (timeout / closed / connect error) would otherwise
%% leave its already-queued {open_link, Channel, ReplyTo} requests with no answer — the
%% waiter (e.g. quod_ledger) gets neither link_up nor link_error and re-buffers forever.
%% Drain the mailbox and reply link_error so the dial fast-fails. (Brief settle so a
%% just-cast open_link races in.)
fail_queued_opens(Peer) ->
    receive
        {open_link, Channel, ReplyTo} ->
            ReplyTo ! {link_error, Peer, Channel},
            fail_queued_opens(Peer)
    after 50 -> ok
    end.

-doc "Own an accepted connection `Conn` (the `quic` listener transfers ownership to us).".
-spec start_inbound(pid(), term()) -> pid().
start_inbound(Conn, Self) ->
    spawn(fun() ->
        process_flag(trap_exit, true),
        loop(#s{conn = Conn, self = Self})
    end).

-doc "Ask this connection to open (or reuse) a link for `Channel`, replying to `ReplyTo`.".
-spec open_link(pid(), binary(), pid()) -> ok.
open_link(ConnPid, Channel, ReplyTo) ->
    ConnPid ! {open_link, Channel, ReplyTo},
    ok.

%% --- loop ----------------------------------------------------------------

loop(S = #s{conn = Conn}) ->
    receive
        {open_link, Channel, ReplyTo} ->
            loop(handle_open(Channel, ReplyTo, S));
        {quic, Conn, {stream_data, Sid, Data, Fin}} ->
            loop(route_data(Sid, Data, Fin, S));
        {quic, Conn, {stream_opened, Sid}} ->
            {_, S1} = ensure_link(Sid, S),       %% pre-create the inbound link
            loop(S1);
        {quic, Conn, {stream_reset, Sid, _}} ->
            loop(drop_stream(Sid, S));
        %% Tear down with `{shutdown, _}`, not a raw `conn_closed`: `quic_connection`
        %% is a `gen_statem` linked to us, so a non-normal/non-shutdown exit
        %% propagated down that link is logged as a CRASH REPORT (the "crash" noise
        %% on every connection drop). `{shutdown, _}` still propagates — the
        %% connection and every link die exactly as before, holders still get their
        %% `DOWN` — but OTP treats it as an intentional stop, so nothing is logged.
        {quic, Conn, {closed, _}} ->
            exit({shutdown, conn_closed});
        {quic, Conn, {transport_error, _, _}} ->
            exit({shutdown, conn_closed});
        {quic, Conn, _Other} ->                  %% connected, send_ready, timer, ...
            loop(S);
        {link_up, Channel, RemotePeer, LinkPid, Origin} ->
            loop(handle_link_up(Channel, RemotePeer, LinkPid, Origin, S));
        {'EXIT', LinkPid, _Reason} ->
            loop(drop_link(LinkPid, S));
        _Other ->
            loop(S)
    end.

%% route inbound bytes to the link owning StreamId (spawning an inbound link the
%% first time we see a peer-opened stream).
route_data(Sid, Data, Fin, S) ->
    {LinkPid, S1} = ensure_link(Sid, S),
    LinkPid ! {data, Data, Fin},
    S1.

ensure_link(Sid, S = #s{streams = Streams, conn = Conn}) ->
    case maps:get(Sid, Streams, undefined) of
        undefined ->
            L = quod_link:start_inbound(Conn, Sid, self()),
            link(L),
            {L, S#s{streams = Streams#{Sid => L}}};
        LinkPid ->
            {LinkPid, S}
    end.

%% open (or reuse) an outbound stream for Channel; ReplyTo is told when it is up.
handle_open(Channel, ReplyTo, S = #s{peer = Peer, chans = Chans, pending = Pending}) ->
    case maps:get(Channel, Chans, undefined) of
        LinkPid when is_pid(LinkPid) ->
            case is_process_alive(LinkPid) of
                true  -> ReplyTo ! {link_up, Peer, Channel, LinkPid}, S;   %% reuse
                false -> open_new(Channel, ReplyTo, S#s{chans = maps:remove(Channel, Chans)})
            end;
        undefined ->
            case maps:is_key(Channel, Pending) of
                true ->
                    Pending1 = maps:update_with(Channel, fun({Sid, W}) -> {Sid, [ReplyTo | W]} end, Pending),
                    S#s{pending = Pending1};
                false ->
                    open_new(Channel, ReplyTo, S)
            end
    end.

open_new(Channel, ReplyTo, S = #s{conn = Conn, peer = Peer, self = Self,
                                  streams = Streams, pending = Pending}) ->
    case quic:open_stream(Conn) of
        {ok, Sid} ->
            L = quod_link:start_outbound(Conn, Sid, Peer, Channel, Self, self()),
            link(L),
            S#s{streams = Streams#{Sid => L},
                pending = Pending#{Channel => {Sid, [ReplyTo]}}};
        {error, _} ->
            ReplyTo ! {link_error, Peer, Channel},
            S
    end.

%% A link finished its header handshake. We cache only the links WE opened (`out`) in
%% `chans` — those are the ones `handle_open` reuses for our sends. An inbound link
%% (`in`, a stream the peer opened) is NEVER cached for sending: we reply on our own
%% outbound stream instead, because sending "backwards" on a peer's stream silently
%% stops delivering across role changes with no DOWN (the phantom-link bug). An inbound
%% link still routes received data (via `streams`); here it only teaches us the peer id
%% so future dials adopt this connection.
handle_link_up(_Channel, RemotePeer, _LinkPid, in, S) ->
    ensure_peer(RemotePeer, S);
handle_link_up(Channel, RemotePeer, LinkPid, out, S = #s{chans = Chans, pending = Pending}) ->
    case maps:get(Channel, Chans, undefined) of
        Existing when is_pid(Existing), Existing =/= LinkPid ->
            case is_process_alive(Existing) of
                true ->
                    _ = quod_link:close(LinkPid),     %% one outbound link per channel; drop the newcomer
                    notify_waiters(Channel, RemotePeer, Existing, Pending),
                    S#s{pending = maps:remove(Channel, Pending)};
                false ->
                    adopt_link(Channel, RemotePeer, LinkPid, S)
            end;
        _ ->
            adopt_link(Channel, RemotePeer, LinkPid, S)
    end.

adopt_link(Channel, RemotePeer, LinkPid, S = #s{chans = Chans, pending = Pending}) ->
    S1 = ensure_peer(RemotePeer, S),
    notify_waiters(Channel, RemotePeer, LinkPid, Pending),
    S1#s{chans   = Chans#{Channel => LinkPid},
         pending = maps:remove(Channel, Pending)}.

%% --- helpers -------------------------------------------------------------

notify_waiters(Channel, RemotePeer, LinkPid, Pending) ->
    Waiters = case maps:get(Channel, Pending, undefined) of
                  {_Sid, Ws} -> Ws;
                  undefined  -> []
              end,
    _ = [W ! {link_up, RemotePeer, Channel, LinkPid} || W <- Waiters],
    ok.

%% a peer reset a stream -> kill the link serving it.
drop_stream(Sid, S = #s{streams = Streams}) ->
    case maps:get(Sid, Streams, undefined) of
        undefined -> S;
        LinkPid   -> _ = quod_link:close(LinkPid), S
    end.

%% a link died -> drop it from both indexes, and fail any pending waiters on it.
drop_link(LinkPid, S = #s{streams = Streams, chans = Chans, pending = Pending, peer = Peer}) ->
    S#s{streams = maps:filter(fun(_, P) -> P =/= LinkPid end, Streams),
        chans   = maps:filter(fun(_, P) -> P =/= LinkPid end, Chans),
        pending = fail_pending(LinkPid, Peer, Streams, Pending)}.

%% if the dead link was the one opening a pending channel, fail its waiters.
fail_pending(LinkPid, Peer, Streams, Pending) ->
    DeadSids = [Sid || {Sid, P} <- maps:to_list(Streams), P =:= LinkPid],
    maps:filter(fun(Channel, {Sid, Waiters}) ->
                    case lists:member(Sid, DeadSids) of
                        true  -> _ = [W ! {link_error, Peer, Channel} || W <- Waiters], false;
                        false -> true
                    end
                end, Pending).

%% Learn (once) which peer this connection serves — used to tag link_up / link_error and
%% to address sends. We no longer register a {conn, Peer} gproc name: connection adoption
%% was removed (each node dials its own outbound conn, never adopts a peer's), so nothing
%% reads it and a second registration for a mutually-dialed pair only clashed silently.
ensure_peer(RemotePeer, S = #s{peer = undefined}) -> S#s{peer = RemotePeer};
ensure_peer(_RemotePeer, S)                       -> S.
