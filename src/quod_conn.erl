-module(quod_conn).
-moduledoc """
A **connection**: one process per peer, owning the QUIC connection and spawning
one `m:quod_link` process per stream.

- **outbound** (`start_outbound/5`): dials, then on `{open_link, Channel, _}`
  opens a stream and starts an outbound link.
- **inbound** (`start_inbound/2`): owns an accepted connection; each peer-opened
  stream becomes an inbound link, whose header reveals the peer's node id (the
  identity handshake).

Either side may open streams, so **both** directions arm
`quicer:async_accept_stream/2` and serve peer-opened streams.

Streams are opened/accepted **passive** and handed to their link via
`quicer:controlling_process/2`; only once the link owns the stream does it go
active (`quod_link:owned/1`), so no inbound bytes are delivered to the wrong
process. Link processes are **linked** to the connection, so when the connection
dies every link dies with it — and each link's death is the disconnect signal
its holder monitors.
""".

-export([start_outbound/5, start_inbound/2, open_link/3]).

-record(s, {conn, self, peer = undefined, pending = #{}, links = #{}}).

-define(HANDSHAKE_TIMEOUT_MS, 5000).

%% --- API -----------------------------------------------------------------

-doc "Dial `Host:Port` (known node id `Peer`), then serve link requests.".
-spec start_outbound(inet:hostname(), inet:port_number(), term(), term(), list()) -> pid().
start_outbound(Host, Port, Peer, Self, ConnOpts) ->
    spawn(fun() ->
        process_flag(trap_exit, true),
        case quicer:connect(Host, Port, ConnOpts, ?HANDSHAKE_TIMEOUT_MS) of
            {ok, Conn} ->
                _ = reg_conn(Peer),
                arm(Conn),
                loop(#s{conn = Conn, self = Self, peer = Peer});
            {error, Reason} ->
                logger:warning("quod: connect ~p:~p failed: ~p", [Host, Port, Reason])
        end
    end).

-doc """
Own an accepted connection `Conn`; learn the peer from its first inbound link.
Waits for a `go` message so the acceptor can transfer ownership before we touch
the connection (handshake-handoff race).
""".
-spec start_inbound(term(), term()) -> pid().
start_inbound(Conn, Self) ->
    spawn(fun() ->
        process_flag(trap_exit, true),
        receive go -> ok after ?HANDSHAKE_TIMEOUT_MS -> exit(no_go) end,
        case quicer:handshake(Conn) of
            {ok, Conn} ->
                arm(Conn),
                loop(#s{conn = Conn, self = Self});
            {error, Reason} ->
                logger:warning("quod: inbound handshake failed: ~p", [Reason])
        end
    end).

-doc "Ask this connection to open (or reuse) a link for `Channel`, replying to `ReplyTo`.".
-spec open_link(pid(), binary(), pid()) -> ok.
open_link(ConnPid, Channel, ReplyTo) ->
    ConnPid ! {open_link, Channel, ReplyTo},
    ok.

%% --- loop ----------------------------------------------------------------

loop(S = #s{conn = Conn, pending = Pending, links = Links}) ->
    receive
        {open_link, Channel, ReplyTo} ->
            loop(handle_open(Channel, ReplyTo, S));
        {quic, new_stream, Stream, _} ->
            L = quod_link:start_inbound(Stream, self()),
            S1 = case quicer:controlling_process(Stream, L) of
                     ok -> link(L), quod_link:owned(L), S;
                     _  -> exit(L, kill), _ = quicer:close_stream(Stream), S
                 end,
            arm(Conn),                                     %% re-arm for the next stream
            loop(S1);
        {link_up, Channel, RemotePeer, LinkPid} ->
            loop(handle_link_up(Channel, RemotePeer, LinkPid, S));
        {'EXIT', LinkPid, _Reason} ->
            loop(S#s{links   = drop_pid(LinkPid, Links),
                     pending = fail_pending(LinkPid, Pending)});
        {quic, C, _, _} when C =:= closed; C =:= transport_shutdown;
                             C =:= connection_closed; C =:= shutdown ->
            exit(conn_closed);
        _Other ->
            loop(S)
    end.

%% a link finished opening. Enforce ONE link per channel: keep a live existing
%% link and close the colliding newcomer, otherwise adopt the new link.
handle_link_up(Channel, RemotePeer, LinkPid, S = #s{links = Links, pending = Pending}) ->
    case maps:get(Channel, Links, undefined) of
        Existing when is_pid(Existing), Existing =/= LinkPid ->
            case is_process_alive(Existing) of
                true ->
                    _ = quod_link:close(LinkPid),          %% duplicate stream -> drop newcomer
                    notify_waiters(Channel, RemotePeer, Existing, Pending),
                    S#s{pending = maps:remove(Channel, Pending)};
                false ->
                    adopt_link(Channel, RemotePeer, LinkPid, S)
            end;
        _ ->
            adopt_link(Channel, RemotePeer, LinkPid, S)
    end.

adopt_link(Channel, RemotePeer, LinkPid, S = #s{links = Links, pending = Pending}) ->
    S1 = ensure_peer(RemotePeer, S),
    notify_waiters(Channel, RemotePeer, LinkPid, Pending),
    S1#s{links   = Links#{Channel => LinkPid},
         pending = maps:remove(Channel, Pending)}.

%% open (or reuse) an outbound stream for Channel; ReplyTo is told when it is up.
handle_open(Channel, ReplyTo, S = #s{peer = Peer, links = Links}) ->
    case maps:get(Channel, Links, undefined) of
        LinkPid when is_pid(LinkPid) ->
            case is_process_alive(LinkPid) of
                true  -> ReplyTo ! {link_up, Peer, Channel, LinkPid}, S;   %% reuse
                false -> open_new(Channel, ReplyTo, S#s{links = maps:remove(Channel, Links)})
            end;
        undefined ->
            open_new(Channel, ReplyTo, S)
    end.

open_new(Channel, ReplyTo, S = #s{conn = Conn, peer = Peer, self = Self, pending = Pending}) ->
    case maps:is_key(Channel, Pending) of
        true ->
            %% a stream for this channel is already opening; wait on it.
            Pending1 = maps:update_with(Channel, fun({Lp, Ws}) -> {Lp, [ReplyTo | Ws]} end, Pending),
            S#s{pending = Pending1};
        false ->
            case quicer:start_stream(Conn, [{active, false}]) of
                {ok, Stream} ->
                    L = quod_link:start_outbound(Stream, Peer, Channel, Self, self()),
                    case quicer:controlling_process(Stream, L) of
                        ok ->
                            link(L),
                            quod_link:owned(L),
                            S#s{pending = Pending#{Channel => {L, [ReplyTo]}}};
                        _ ->
                            exit(L, kill),
                            _ = quicer:close_stream(Stream),
                            ReplyTo ! {link_error, Channel},
                            S
                    end;
                {error, _} ->
                    ReplyTo ! {link_error, Channel},
                    S
            end
    end.

%% --- helpers -------------------------------------------------------------

%% tell every waiter queued for Channel which link came up.
notify_waiters(Channel, RemotePeer, LinkPid, Pending) ->
    Waiters = case maps:get(Channel, Pending, undefined) of
                  {_Opening, Ws} -> Ws;
                  undefined      -> []
              end,
    _ = [W ! {link_up, RemotePeer, Channel, LinkPid} || W <- Waiters],
    ok.

%% a link died: if it was the one opening a pending channel, fail that channel's
%% waiters (so they are not wedged forever) and drop the entry.
fail_pending(LinkPid, Pending) ->
    maps:filter(fun(Channel, {Opening, Waiters}) ->
                    case Opening =:= LinkPid of
                        true  -> _ = [W ! {link_error, Channel} || W <- Waiters], false;
                        false -> true
                    end
                end, Pending).

drop_pid(LinkPid, Links) ->
    maps:filter(fun(_, P) -> P =/= LinkPid end, Links).

%% arm reception of the next peer-opened stream; it is delivered passive so the
%% owning link controls when bytes start flowing.
arm(Conn) ->
    _ = quicer:async_accept_stream(Conn, #{active => false}),
    ok.

ensure_peer(RemotePeer, S = #s{peer = undefined}) ->
    _ = reg_conn(RemotePeer),
    S#s{peer = RemotePeer};
ensure_peer(_RemotePeer, S) ->
    S.

%% best-effort {conn, Peer} registration for reuse (a duplicate from a
%% simultaneous inbound+outbound just isn't the registered alias — both work).
reg_conn(Peer) ->
    try quod_reg:reg({conn, Peer}) catch _:_ -> ok end.
