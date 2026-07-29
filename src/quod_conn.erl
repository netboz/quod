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

-export([start_outbound/8, start_inbound/2, open_link/3, send/3]).

-record(s, {conn, self, peer = undefined,
            expected_peer = undefined,  %% pinned outbound identity, `any` for directory-seed TOFU
            learn_hint = learn,         %% what our outbound stream headers ask the receiver to do
            streams = #{},   %% StreamId => LinkPid   (every link, for routing inbound data)
            chans   = #{},   %% Channel  => LinkPid   (our OUTBOUND links only, for send reuse/dedup)
            pending = #{},   %% Channel  => {StreamId, [ReplyTo]} (outbound opens in flight)
            sendq   = #{}}). %% Channel => {Count, ReverseFrames} while a link opens

-define(CONNECT_TIMEOUT_MS, 5000).
-define(MAX_SENDQ, 1024).   %% per-channel cap on frames buffered while an outbound link opens

%% --- API -----------------------------------------------------------------

-doc """
Dial `Host:Port` (known node id `Peer`), become the connection owner, serve links.
We present our own `Cert`/`Key` so the peer (the TLS server) can authenticate us via
mutual TLS. `verify => false` skips validating the *peer's* self-signed server cert (no
CA chain); the peer authenticates US, and we authenticate it when it dials back — every
directed pair is server-verifies-client.
""".
-spec start_outbound(inet:hostname(), inet:port_number(), term(), term(), [binary()],
                     term(), term(), map()) -> pid().
start_outbound(Host, Port, Peer, Self, ALPN, Cert, Key, Policy) ->
    spawn(fun() ->
        process_flag(trap_exit, true),
        %% QUIC liveness (idle_timeout + keep_alive_interval) for fast dead-peer detection, from
        %% config via `quod_quic:liveness_opts/0` — the SAME source the server listener uses, so
        %% both directions detect symmetrically (the fork's RFC 9000 §10.1 fix makes idle fire even
        %% while WE keep sending; it enforces each side's own idle timeout, no RFC min negotiation).
        Opts = maps:merge(#{verify => false, cert => Cert, key => Key, alpn => ALPN},
                          quod_quic:liveness_opts()),
        case quic:connect(Host, Port, Opts, self()) of
            {ok, Conn} ->
                receive
                    {quic, Conn, {connected, _}} ->
                        case outbound_identity(Conn, Peer, Policy) of
                            {ok, BoundPeer, ExpectedPeer, LearnHint} ->
                                run(#s{conn = Conn, self = Self, peer = BoundPeer,
                                       expected_peer = ExpectedPeer, learn_hint = LearnHint});
                            {error, Reason} ->
                                logger:warning(
                                  "quod: dropping outbound connection to ~p — peer identity ~p",
                                  [Peer, Reason]),
                                _ = catch quic:close(Conn, normal),
                                fail_queued_opens(Peer)
                        end;
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
%% waiter (e.g. quod_simplex) gets neither link_up nor link_error and re-buffers forever.
%% Drain the mailbox and reply link_error so the dial fast-fails. (Brief settle so a
%% just-cast open_link races in.)
fail_queued_opens(Peer) ->
    receive
        {open_link, Channel, ReplyTo} ->
            notify_link_error(ReplyTo, Peer, Channel),
            fail_queued_opens(Peer)
    after 50 -> ok
    end.

-doc "Own an accepted connection `Conn` (the `quic` listener transfers ownership to us).".
-spec start_inbound(pid(), term()) -> pid().
start_inbound(Conn, Self) ->
    spawn(fun() ->
        process_flag(trap_exit, true),
        run(#s{conn = Conn, self = Self})
    end).

-doc "Ask this connection to open (or reuse) a link for `Channel`, replying to `ReplyTo`.".
-spec open_link(pid(), binary(), pid() | {pid(), reference()}) -> ok.
open_link(ConnPid, Channel, ReplyTo) ->
    ConnPid ! {open_link, Channel, ReplyTo},
    ok.

-doc """
Fire-and-forget send of `Frame` on `Channel` over this connection: reuse the live outbound link if there
is one, else open it and **buffer** `Frame` (FIFO, capped) until the link is ready, flushing on link-up.
No caller-side link handling — the connection owns the link lifecycle. Callers reach this via
`quod_quic:send/3`.
""".
-spec send(pid(), binary(), binary()) -> ok.
send(ConnPid, Channel, Frame) ->
    ConnPid ! {send, Channel, Frame},
    ok.

%% --- loop ----------------------------------------------------------------

%% Register on the connection-stats property before entering the loop: the metrics
%% refresh enumerates these processes and asks each for its QUIC transport stats
%% (srtt / cwnd / in-flight), the per-peer numbers that decide whether the transport
%% or the application is pacing consensus. Property, not name: many conns, gproc
%% auto-cleans on death.
run(S) ->
    _ = quod_reg:subscribe({conn_stats, local}),
    loop(S).

loop(S = #s{conn = Conn}) ->
    receive
        {open_link, Channel, ReplyTo} ->
            loop(handle_open(Channel, ReplyTo, S));
        {send, Channel, Frame} ->
            loop(handle_send(Channel, Frame, S));
        {transport_stats, From, Ref} ->
            %% get_path_stats (NOT get_stats, which is packet counters only) carries
            %% srtt/min_rtt/cwnd/in-flight; the send-queue depth — data accepted but
            %% still waiting behind pacing/cwnd — is the most direct evidence of the
            %% transport queueing, so merge it in when available.
            Stats = case quic:get_path_stats(Conn) of
                        {ok, Path} ->
                            case quic:get_send_queue_info(Conn) of
                                {ok, #{bytes := QBytes}} ->
                                    {ok, Path#{send_queue_bytes => QBytes}};
                                _ ->
                                    {ok, Path}
                            end;
                        Error -> Error
                    end,
            From ! {Ref, {S#s.peer, Stats}},
            loop(S);
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
            loop(handle_link_up(
                   Channel, RemotePeer, LinkPid, Origin, undefined, S));
        {authenticate_link, LinkPid, Ref, _Channel, RemotePeer, LearnHint}
          when is_pid(LinkPid), is_reference(Ref) ->
            case authenticate_inbound(RemotePeer, LearnHint, S) of
                {ok, S1} ->
                    LinkPid ! {link_authenticated, self(), Ref},
                    loop(S1);
                {error, Reason} ->
                    logger:warning(
                      "quod: dropping inbound connection — peer identity ~p",
                      [Reason]),
                    exit({shutdown, {peer_identity, Reason}})
            end;
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
                true  ->
                    notify_link_up(ReplyTo, Peer, Channel, LinkPid),
                    S;
                false -> open_new(Channel, [ReplyTo], S#s{chans = maps:remove(Channel, Chans)})
            end;
        undefined ->
            case maps:is_key(Channel, Pending) of
                true ->
                    Pending1 = maps:update_with(Channel, fun({Sid, W}) -> {Sid, [ReplyTo | W]} end, Pending),
                    S#s{pending = Pending1};
                false ->
                    open_new(Channel, [ReplyTo], S)
            end
    end.

%% fire-and-forget send: reuse a live outbound link, else buffer the frame and ensure an open is in
%% flight (flushed on link-up). No ReplyTo — the caller does not track the link.
handle_send(Channel, Frame, S = #s{chans = Chans}) ->
    case maps:get(Channel, Chans, undefined) of
        LinkPid when is_pid(LinkPid) ->
            case is_process_alive(LinkPid) of
                true  -> _ = quod_link:send(LinkPid, Frame), S;
                false -> buffer_send(Channel, Frame, S#s{chans = maps:remove(Channel, Chans)})
            end;
        undefined ->
            buffer_send(Channel, Frame, S)
    end.

buffer_send(Channel, Frame, S = #s{pending = Pending, sendq = SendQ}) ->
    {Count, Buf} = maps:get(Channel, SendQ, {0, []}),
    %% Buffers are reverse-FIFO so adding a frame is O(1). At the hard cap,
    %% preserve the already accepted oldest frames and drop the newcomer.
    Buffered = case Count < ?MAX_SENDQ of
               true -> {Count + 1, [Frame | Buf]};
               false -> {Count, Buf}
           end,
    S1  = S#s{sendq = SendQ#{Channel => Buffered}},
    case maps:is_key(Channel, Pending) of
        true  -> S1;                          %% an open is already in flight; flush on link-up
        false -> open_new(Channel, [], S1)    %% start the open with no link_up waiter (we buffer instead)
    end.

open_new(Channel, Waiters, S = #s{conn = Conn, peer = Peer, self = Self,
                                  learn_hint = LearnHint,
                                  streams = Streams, pending = Pending, sendq = SendQ}) ->
    case quic:open_stream(Conn) of
        {ok, Sid} ->
            L = quod_link:start_outbound(
                  Conn, Sid, Peer, Channel, Self, self(), LearnHint),
            link(L),
            S#s{streams = Streams#{Sid => L},
                pending = Pending#{Channel => {Sid, Waiters}}};
        {error, _} ->
            %% The open failed synchronously: notify link_up waiters (open_link callers) with link_error,
            %% and DROP any fire-and-forget frames buffered for this channel — with no stream and no
            %% pending entry they would otherwise sit in sendq until a later send retries (fire-and-forget
            %% callers retry at the app layer). Keeps sendq from orphaning a frame on open failure.
            lists:foreach(
              fun(Waiter) ->
                  notify_link_error(Waiter, Peer, Channel)
              end, Waiters),
            S#s{sendq = maps:remove(Channel, SendQ)}
    end.

%% Authenticate a peer-opened stream before its link ACKs or publishes payload.
%% Inbound links are never cached for sending: replies use our own outbound
%% connection rather than the lesser-tested server-initiated stream path.
authenticate_inbound(RemotePeer, LearnHint,
                     S = #s{conn = Conn,
                            expected_peer = ExpectedPeer}) ->
    %% Identity bind: a peer dialed US (we are the TLS server, verify=>true), so its header
    %% claims a pubkey AND mutual TLS proved one via `quic:peercert/1`. They must match — else
    %% the peer is lying about who it is, or presented no cert. Drop the whole connection.
    %% Malformed or non-keyed headers are rejected before they reach upper layers.
    case {bind_ok(RemotePeer, Conn), expected_peer_ok(RemotePeer, ExpectedPeer)} of
        {ok, true} ->
            %% Cache learning is deliberately after the certificate/header bind:
            %% a mismatched valid-cert peer must not write a forged key's hint,
            %% even transiently.
            EffectivePolicy = effective_learn_policy(LearnHint, S),
            maybe_learn_remote(EffectivePolicy, RemotePeer),
            {ok, (ensure_peer(RemotePeer, S))#s{
                   learn_hint = EffectivePolicy}};
        {{fail, Reason}, _} ->
            {error, Reason};
        {ok, false} ->
            {error, expected_peer_mismatch}
    end.

handle_link_up(Channel, RemotePeer, LinkPid, out, _LearnHint,
               S = #s{chans = Chans, pending = Pending}) ->
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

adopt_link(Channel, RemotePeer, LinkPid, S = #s{chans = Chans, pending = Pending, sendq = SendQ}) ->
    S1 = ensure_peer(RemotePeer, S),
    notify_waiters(Channel, RemotePeer, LinkPid, Pending),
    {_Count, ReverseFrames} = maps:get(Channel, SendQ, {0, []}),
    lists:foreach(
      fun(Frame) -> quod_link:send(LinkPid, Frame) end,
      lists:reverse(ReverseFrames)),
    S1#s{chans   = Chans#{Channel => LinkPid},
         pending = maps:remove(Channel, Pending),
         sendq   = maps:remove(Channel, SendQ)}.

%% --- helpers -------------------------------------------------------------

notify_waiters(Channel, RemotePeer, LinkPid, Pending) ->
    Waiters = case maps:get(Channel, Pending, undefined) of
                  {_Sid, Ws} -> Ws;
                  undefined  -> []
              end,
    lists:foreach(
      fun(Waiter) ->
          notify_link_up(Waiter, RemotePeer, Channel, LinkPid)
      end, Waiters),
    ok.

%% a peer reset a stream -> kill the link serving it.
drop_stream(Sid, S = #s{streams = Streams}) ->
    case maps:get(Sid, Streams, undefined) of
        undefined -> S;
        LinkPid   -> _ = quod_link:close(LinkPid), S
    end.

%% a link died -> drop it from both indexes, fail any pending waiters on it, and discard any frames
%% buffered for the channel it was opening (their fire-and-forget send is lost; the caller retries).
drop_link(LinkPid, S = #s{streams = Streams, chans = Chans, pending = Pending, sendq = SendQ, peer = Peer}) ->
    DeadSids =
        maps:from_keys(
          [Sid || {Sid, Pid} <- maps:to_list(Streams),
                  Pid =:= LinkPid],
          true),
    {Pending1, PendingChans} =
        partition_pending(Peer, DeadSids, Pending),
    DeadChans =
        maps:fold(
          fun(Channel, Pid, Acc) when Pid =:= LinkPid ->
                  [Channel | Acc];
             (_Channel, _Pid, Acc) ->
                  Acc
          end, PendingChans, Chans),
    S#s{streams = maps:filter(fun(_, P) -> P =/= LinkPid end, Streams),
        chans   = maps:filter(fun(_, P) -> P =/= LinkPid end, Chans),
        pending = Pending1,
        sendq   = maps:without(DeadChans, SendQ)}.

%% Partition pending opens once. Dead channels are returned for send-queue
%% cleanup; live entries retain their original map values.
partition_pending(Peer, DeadSids, Pending) ->
    maps:fold(
      fun(Channel, {Sid, Waiters} = Entry, {Kept, DeadChannels}) ->
          case maps:is_key(Sid, DeadSids) of
              true ->
                  lists:foreach(
                    fun(Waiter) ->
                        notify_link_error(Waiter, Peer, Channel)
                    end, Waiters),
                  {Kept, [Channel | DeadChannels]};
              false ->
                  {Kept#{Channel => Entry}, DeadChannels}
          end
      end, {#{}, []}, Pending).

%% Learn (once) which peer this connection serves — used to tag link_up / link_error and
%% to address sends. We no longer register a {conn, Peer} gproc name: connection adoption
%% was removed (each node dials its own outbound conn, never adopts a peer's), so nothing
%% reads it and a second registration for a mutually-dialed pair only clashed silently.
ensure_peer(RemotePeer, S = #s{peer = undefined}) -> S#s{peer = RemotePeer};
ensure_peer(_RemotePeer, S)                       -> S.

%% The header's claimed pubkey must equal the TLS-proven peer cert's pubkey. A 32-byte
%% binary id ⇒ a real identity, enforced. There is no unauthenticated fallback.
bind_ok({Pubkey, _Addr}, Conn) when is_binary(Pubkey), byte_size(Pubkey) =:= 32 ->
    case quic:peercert(Conn) of
        {ok, Der} ->
            case quod_identity:pubkey_of_cert(Der) of
                {ok, Pubkey} -> ok;
                {ok, _Other} -> {fail, pubkey_mismatch};
                error        -> {fail, bad_peer_cert}
            end;
        {error, _} -> {fail, no_peercert}
    end;
bind_ok(_RemotePeer, _Conn) -> {fail, malformed_header_identity}.

%% Directory dials are scoped: `ExpectedPeer` pins a known route key; `any` is the
%% one-shot private-seed TOFU mode. Ordinary transport keeps its existing unpinned
%% endpoint/cache behavior. The certificate is checked before any stream can open.
outbound_identity(_Conn, Peer, #{expected_peer := undefined, learn_hint := LearnHint}) ->
    {ok, Peer, undefined, LearnHint};
outbound_identity(Conn, _Peer, #{expected_peer := Expected, learn_hint := LearnHint})
  when Expected =:= any; is_binary(Expected) ->
    case cert_pubkey(Conn) of
        {ok, Actual} when Expected =:= any ->
            {ok, Actual, any, LearnHint};
        {ok, Expected} ->
            {ok, Expected, Expected, LearnHint};
        {ok, _Other} ->
            {error, pubkey_mismatch};
        {error, Reason} ->
            {error, Reason}
    end.

cert_pubkey(Conn) ->
    case quic:peercert(Conn) of
        {ok, Der} ->
            case quod_identity:pubkey_of_cert(Der) of
                {ok, Pubkey} -> {ok, Pubkey};
                error -> {error, bad_peer_cert}
            end;
        {error, _} ->
            {error, no_peercert}
    end.

expected_peer_ok(_RemotePeer, undefined) -> true;
expected_peer_ok(_RemotePeer, any)       -> true;
expected_peer_ok({Pubkey, _Addr}, Pubkey) -> true;
expected_peer_ok(_RemotePeer, _Expected) -> false.

notify_link_up({ReplyTo, Ref}, Peer, Channel, LinkPid)
  when is_pid(ReplyTo), is_reference(Ref) ->
    ReplyTo ! {link_up, Ref, Peer, Channel, LinkPid},
    ok;
notify_link_up(ReplyTo, Peer, Channel, LinkPid) when is_pid(ReplyTo) ->
    ReplyTo ! {link_up, Peer, Channel, LinkPid},
    ok.

notify_link_error({ReplyTo, Ref}, Peer, Channel)
  when is_pid(ReplyTo), is_reference(Ref) ->
    ReplyTo ! {link_error, Ref, Peer, Channel},
    ok;
notify_link_error(ReplyTo, Peer, Channel) when is_pid(ReplyTo) ->
    ReplyTo ! {link_error, Peer, Channel},
    ok.

maybe_learn_remote(learn, {Pubkey, Addr}) when is_binary(Pubkey) ->
    _ = quod_quic:learn(Pubkey, Addr),
    ok;
maybe_learn_remote(_Policy, _Peer) ->
    ok.

%% A directory opener's no-learn policy covers the whole directed connection.
%% Once any authenticated stream suppresses learning, a later stream cannot
%% re-enable it before the policy is applied.
effective_learn_policy(_HeaderPolicy, #s{learn_hint = no_learn}) ->
    no_learn;
effective_learn_policy(no_learn, _S) ->
    no_learn;
effective_learn_policy(learn, _S) ->
    learn.
