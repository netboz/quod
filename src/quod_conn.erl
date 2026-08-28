-module(quod_conn).
-moduledoc """
A **connection owner**: one process per pure-Erlang `quic` connection, routing
its streams to `m:quod_link` processes. A physical peer can intentionally have
separate ordinary, pinned, and identity-discovery connections.

The `quic` owner model delivers every stream's events to this one process, so
`quod_conn` is the demux point: `{quic, Conn, {stream_data, StreamId, Bin, Fin}}`
is forwarded to the link registered for `StreamId` (a peer-opened stream gets a
fresh inbound link on first sight). It opens outbound streams on `{open_link,
Channel, _}` and learns an inbound peer's node id from the link's header.

Links are **linked** to the connection, so when the connection drops every link
dies with it — and each link's death is the disconnect signal its holder
monitors.
""".

-export([start_outbound/9, start_inbound/3, open_link/3, open_link_lease/3,
         release_link/3, send/3,
         reset_inbound_channel/1]).
-ifdef(TEST).
-export([test_late_link_up_generation/4]).
-endif.

-record(s, {conn, owner, self, peer = undefined,
            expected_peer = undefined,  %% pinned outbound identity, `any` for identity discovery
            learn_hint = learn,         %% what our outbound stream headers ask the receiver to do
            streams = #{},   %% StreamId => LinkPid   (every link, for routing inbound data)
            chans   = #{},   %% Channel  => LinkPid   (our OUTBOUND links only, for send reuse/dedup)
            pending = #{},   %% Channel  => {StreamId, [ReplyTo]} (outbound opens in flight)
            sendq   = #{},   %% Channel => ReverseFrames while a link opens
            %% Explicit links remain owned by their opener processes. This
            %% monitor-backed relation closes the link when its last owner dies;
            %% no is_process_alive check or late-mailbox drain is an ownership proof.
            link_owners = #{}, %% Channel => #{Lease => MonitorRef}
            owner_refs = #{},  %% MonitorRef => {Channel, Lease}
            send_owned = #{}}). %% channels used by connection-owned send/3

-define(CONNECT_TIMEOUT_MS, 5000).

%% --- API -----------------------------------------------------------------

-doc """
Dial `Host:Port` (known node id `Peer`), become the connection owner, serve links.
We present our own `Cert`/`Key` so the peer (the TLS server) can authenticate us via
mutual TLS. `verify => false` skips CA-chain validation of the peer's
self-signed server certificate. The identity policy below still extracts its
Ed25519 key and pins it whenever the caller supplied a node key.
""".
-spec start_outbound(inet:hostname(), inet:port_number(), term(), term(), [binary()],
                     term(), term(), map(), pid()) -> pid().
start_outbound(Host, Port, Peer, Self, ALPN, Cert, Key, Policy, Owner) ->
    spawn(fun() ->
        link(Owner),
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
                                run(#s{conn = Conn, owner = Owner,
                                       self = Self, peer = BoundPeer,
                                       expected_peer = ExpectedPeer, learn_hint = LearnHint});
                            {error, Reason} ->
                                logger:warning(
                                  "quod: dropping outbound connection to ~p — peer identity ~p",
                                  [Peer, Reason]),
                                _ = catch quic:close(Conn, normal),
                                terminal_start(
                                  Peer, Owner, {peer_identity, Reason})
                        end;
                    {quic, Conn, {closed, R}} ->
                        logger:debug("quod: connect ~p:~p closed: ~p", [Host, Port, R]),
                        terminal_start(Peer, Owner, {connect_closed, R});
                    {'EXIT', Owner, Reason} ->
                        fail_owner_startup(Peer),
                        exit({shutdown, {transport_owner_down, Reason}})
                after ?CONNECT_TIMEOUT_MS ->
                    logger:debug("quod: connect ~p:~p timed out", [Host, Port]),
                    _ = catch quic:close(Conn, normal),
                    terminal_start(Peer, Owner, connect_timeout)
                end;
            {error, Reason} ->
                logger:debug("quod: connect ~p:~p failed: ~p", [Host, Port, Reason]),
                terminal_start(Peer, Owner, {connect_failed, Reason})
        end
    end).

%% Owner death is already the terminal ordering barrier: every message the
%% owner sent this process precedes its linked EXIT signal. Drain those queued
%% requests without a settle timer, resolve their callers, then stop.
fail_owner_startup(Peer) ->
    receive
        {open_link, Channel, ReplyTo} ->
            notify_link_error(ReplyTo, Peer, Channel),
            fail_owner_startup(Peer);
        {send, _Channel, _Frame} ->
            fail_owner_startup(Peer)
    after 0 ->
        ok
    end.

-doc "Own an accepted connection `Conn` (the `quic` listener transfers ownership to us).".
-spec start_inbound(pid(), term(), pid()) -> pid().
start_inbound(Conn, Self, Owner) ->
    spawn(fun() ->
        link(Owner),
        process_flag(trap_exit, true),
        run(#s{conn = Conn, owner = Owner, self = Self})
    end).

-doc "Ask this connection to open (or reuse) a link for `Channel`, replying to `ReplyTo`.".
-spec open_link(pid(), binary(), pid() | {pid(), reference()}) -> ok.
open_link(ConnPid, Channel, ReplyTo) ->
    ConnPid ! {open_link, Channel, ReplyTo},
    ok.

-doc "Ask this connection for a ref-correlated link with an explicitly releasable lease.".
-spec open_link_lease(pid(), binary(), {pid(), reference()}) -> ok.
open_link_lease(ConnPid, Channel, {Pid, Ref} = Lease)
  when is_pid(ConnPid), is_binary(Channel), is_pid(Pid), is_reference(Ref) ->
    ConnPid ! {open_link, Channel, {lease, Lease}},
    ok.

-doc "Release one exact ref-correlated link lease without affecting other users of the stream.".
-spec release_link(pid(), binary(), {pid(), reference()}) -> ok.
release_link(ConnPid, Channel, {Pid, Ref} = Lease)
  when is_pid(ConnPid), is_binary(Channel), is_pid(Pid), is_reference(Ref) ->
    ConnPid ! {release_link, Channel, Lease},
    ok.

-doc """
Fire-and-forget send of `Frame` on `Channel` over this connection: reuse the live outbound link if there
is one, else open it and **buffer** `Frame` FIFO until the link is ready, flushing on link-up.
No caller-side link handling — the connection owns the link lifecycle. Callers reach this via
`quod_quic:send/3`.
""".
-spec send(pid(), binary(), binary()) -> ok.
send(ConnPid, Channel, Frame) ->
    ConnPid ! {send, Channel, Frame},
    ok.

-doc "Reset every existing peer-opened link for `Channel`; other links are untouched.".
-spec reset_inbound_channel(binary()) -> ok.
reset_inbound_channel(Channel) when is_binary(Channel) ->
    %% Connection owners already share this process property for enumeration.
    %% Broadcasting keeps channel lifecycle inside the transport; callers do
    %% not inspect connections or link pids.
    _ = quod_reg:publish(
          {connections, local}, {reset_inbound_channel, Channel}),
    ok.

%% --- loop ----------------------------------------------------------------

%% Register on the shared connection-owner property before entering the loop.
%% Transport control can address all local owners without inspecting their
%% links, and metrics uses the same enumeration to request QUIC path stats.
%% Property, not name: many conns, and gproc auto-cleans it on death.
run(S) ->
    _ = quod_reg:subscribe({connections, local}),
    loop(S).

loop(S = #s{conn = Conn}) ->
    receive
        {open_link, Channel, ReplyTo} ->
            loop(handle_open(Channel, ReplyTo, S));
        {release_link, Channel, Lease} ->
            loop(release_link_owner(Channel, Lease, S));
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
        {reset_inbound_channel, Channel} ->
            maps:foreach(
              fun(_Sid, LinkPid) ->
                  LinkPid ! {reset_inbound_channel, Channel}
              end,
              S#s.streams),
            loop(S);
        {quic, Conn, {stream_data, Sid, Data, Fin}} ->
            loop(route_data(Sid, Data, Fin, S));
        {quic, Conn, {stream_opened, Sid}} ->
            {_, S1} = ensure_link(Sid, S),       %% pre-create the inbound link
            loop(S1);
        {quic, Conn, {stream_reset, Sid, _}} ->
            loop(drop_stream(Sid, S));
        {quic, Conn, {send_ready, Sid}} ->
            %% QUIC owns flow-control/congestion progress. Forward its exact
            %% stream wake to the link parked on that stream; the link retries
            %% from its FIFO without polling the transport.
            loop(route_send_ready(Sid, S));
        %% Tear down with `{shutdown, _}`, not a raw `conn_closed`: `quic_connection`
        %% is a `gen_statem` linked to us, so a non-normal/non-shutdown exit
        %% propagated down that link is logged as a CRASH REPORT (the "crash" noise
        %% on every connection drop). `{shutdown, _}` still propagates — the
        %% connection and every link die exactly as before, holders still get their
        %% `DOWN` — but OTP treats it as an intentional stop, so nothing is logged.
        {quic, Conn, {closed, _}} ->
            connection_down(conn_closed, S);
        {quic, Conn, {transport_error, _, _}} ->
            connection_down(conn_closed, S);
        {quic, Conn, _Other} ->                  %% connected, timer, ...
            loop(S);
        {link_up, Channel, RemotePeer, LinkPid, out} ->
            loop(handle_link_up(
                   Channel, RemotePeer, LinkPid, S));
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
                    _ = catch quic:close(Conn, normal),
                    connection_down({peer_identity, Reason}, S)
            end;
        {'EXIT', Conn, Reason} ->
            connection_down({conn_closed, Reason}, S);
        {'EXIT', Owner, Reason} when Owner =:= S#s.owner ->
            _ = catch quic:close(Conn, normal),
            owner_down({transport_owner_down, Reason}, S);
        {'EXIT', LinkPid, _Reason} ->
            loop(drop_link(LinkPid, S));
        {'DOWN', MRef, process, Pid, _Reason} ->
            loop(handle_link_owner_down(MRef, Pid, S));
        _Other ->
            loop(S)
    end.

%% route inbound bytes to the link owning StreamId (spawning an inbound link the
%% first time we see a peer-opened stream).
route_data(Sid, Data, Fin, S) ->
    {LinkPid, S1} = ensure_link(Sid, S),
    LinkPid ! {data, Data, Fin},
    S1.

route_send_ready(Sid, S = #s{streams = Streams}) ->
    case maps:get(Sid, Streams, undefined) of
        LinkPid when is_pid(LinkPid) ->
            LinkPid ! {send_ready, Sid},
            S;
        undefined ->
            S
    end.

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
    S0 = add_link_owner(Channel, ReplyTo, S),
    case maps:get(Channel, Chans, undefined) of
        LinkPid when is_pid(LinkPid) ->
            case is_process_alive(LinkPid) of
                true  ->
                    notify_link_up(ReplyTo, Peer, Channel, LinkPid),
                    S0;
                false ->
                    open_new(Channel, [ReplyTo],
                             S0#s{chans = maps:remove(Channel, Chans)})
            end;
        undefined ->
            case maps:is_key(Channel, Pending) of
                true ->
                    Pending1 = maps:update_with(Channel, fun({Sid, W}) -> {Sid, [ReplyTo | W]} end, Pending),
                    S0#s{pending = Pending1};
                false ->
                    open_new(Channel, [ReplyTo], S0)
            end
    end.

%% fire-and-forget send: reuse a live outbound link, else buffer the frame and ensure an open is in
%% flight (flushed on link-up). No ReplyTo — the caller does not track the link.
handle_send(Channel, Frame, S = #s{chans = Chans}) ->
    S0 = S#s{send_owned = (S#s.send_owned)#{Channel => true}},
    case maps:get(Channel, Chans, undefined) of
        LinkPid when is_pid(LinkPid) ->
            case is_process_alive(LinkPid) of
                true  -> _ = quod_link:send(LinkPid, Frame), S0;
                false -> buffer_send(Channel, Frame,
                                     S0#s{chans = maps:remove(Channel, Chans)})
            end;
        undefined ->
            buffer_send(Channel, Frame, S0)
    end.

buffer_send(Channel, Frame, S = #s{pending = Pending, sendq = SendQ}) ->
    Buf = maps:get(Channel, SendQ, []),
    %% Reverse-FIFO makes acceptance O(1); link-up reverses once to preserve
    %% mailbox order. Capacity is governed by the node/process memory owner,
    %% not an arbitrary transport message count.
    S1  = S#s{sendq = SendQ#{Channel => [Frame | Buf]}},
    case maps:is_key(Channel, Pending) of
        true  -> S1;                          %% an open is already in flight; flush on link-up
        false -> open_new(Channel, [], S1)    %% start the open with no link_up waiter (we buffer instead)
    end.

open_new(Channel, Waiters, S = #s{conn = Conn, peer = Peer, self = Self,
                                  learn_hint = LearnHint,
                                  streams = Streams, pending = Pending,
                                  sendq = SendQ, send_owned = SendOwned}) ->
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
            release_channel_owners(
              Channel,
              S#s{sendq = maps:remove(Channel, SendQ),
                  send_owned = maps:remove(Channel, SendOwned)})
    end.

%% Authenticate a peer-opened stream before its link ACKs or publishes payload.
%% Peer-opened links are not inserted into the outbound channel cache. A
%% request handler may reply on that exact bidirectional link; an independent
%% outbound open still uses this node's client-initiated connection.
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

handle_link_up(Channel, RemotePeer, LinkPid,
               S = #s{chans = Chans, pending = Pending,
                      streams = Streams}) ->
    case pending_link(Channel, Pending, Streams) of
        LinkPid ->
            case maps:get(Channel, Chans, undefined) of
                Existing when is_pid(Existing), Existing =/= LinkPid ->
                    case is_process_alive(Existing) of
                        true ->
                            _ = quod_link:close(LinkPid),
                            notify_waiters(
                              Channel, RemotePeer, Existing, Pending),
                            S#s{pending = maps:remove(Channel, Pending)};
                        false ->
                            adopt_link(Channel, RemotePeer, LinkPid, S)
                    end;
                _ ->
                    adopt_link(Channel, RemotePeer, LinkPid, S)
            end;
        _OtherGeneration ->
            %% A released opening can authenticate after a replacement open is
            %% already pending for the same channel. Only the LinkPid derived
            %% from the current pending Sid may consume its exact waiters.
            _ = quod_link:close(LinkPid),
            S
    end.

pending_link(Channel, Pending, Streams) ->
    case maps:get(Channel, Pending, undefined) of
        {Sid, _Waiters} -> maps:get(Sid, Streams, undefined);
        undefined -> undefined
    end.

-ifdef(TEST).
%% Model the precise post-release/reopen state without constructing a QUIC
%% connection: L1 still exists in the stream index, while L2 owns the current
%% pending Sid and exact waiter. L1's late callback must be closed and inert;
%% only L2 may consume the waiter.
test_late_link_up_generation(Channel, Peer, OldLink, NewLink)
  when is_binary(Channel), is_pid(OldLink), is_pid(NewLink) ->
    Ref = make_ref(),
    Lease = {self(), Ref},
    S0 = #s{peer = Peer,
            streams = #{1 => OldLink, 2 => NewLink},
            pending = #{Channel => {2, [{lease, Lease}]}},
            link_owners = #{Channel => #{Lease => make_ref()}}},
    S1 = handle_link_up(Channel, Peer, OldLink, S0),
    PendingAfterOld = maps:is_key(Channel, S1#s.pending),
    S2 = handle_link_up(Channel, Peer, NewLink, S1),
    #{ref => Ref,
      pending_after_old => PendingAfterOld,
      pending_after_new => maps:is_key(Channel, S2#s.pending),
      active => maps:get(Channel, S2#s.chans, undefined)}.
-endif.

adopt_link(Channel, RemotePeer, LinkPid, S = #s{chans = Chans, pending = Pending, sendq = SendQ}) ->
    S1 = ensure_peer(RemotePeer, S),
    Waiters = pending_waiters(Channel, Pending),
    ReverseFrames = maps:get(Channel, SendQ, []),
    case {channel_has_owner(Channel, S1), ReverseFrames} of
        {false, []} ->
            %% Every explicit opener disappeared while the authenticated
            %% stream was coming up, and no fire-and-forget frame owns it.
            %% Do not cache an orphan link indefinitely in the transport.
            _ = quod_link:close(LinkPid),
            S1#s{pending = maps:remove(Channel, Pending),
                 sendq = maps:remove(Channel, SendQ)};
        _ ->
            notify_waiter_list(Waiters, Channel, RemotePeer, LinkPid),
            lists:foreach(
              fun(Frame) -> quod_link:send(LinkPid, Frame) end,
              lists:reverse(ReverseFrames)),
            S1#s{chans   = Chans#{Channel => LinkPid},
                 pending = maps:remove(Channel, Pending),
                 sendq   = maps:remove(Channel, SendQ)}
    end.

%% --- helpers -------------------------------------------------------------

notify_waiters(Channel, RemotePeer, LinkPid, Pending) ->
    Waiters = pending_waiters(Channel, Pending),
    notify_waiter_list(Waiters, Channel, RemotePeer, LinkPid).

pending_waiters(Channel, Pending) ->
    case maps:get(Channel, Pending, undefined) of
        {_Sid, Waiters} -> Waiters;
        undefined -> []
    end.

notify_waiter_list(Waiters, Channel, RemotePeer, LinkPid) ->
    lists:foreach(
      fun(Waiter) ->
          notify_link_up(Waiter, RemotePeer, Channel, LinkPid)
      end, Waiters),
    ok.

add_link_owner(Channel, ReplyTo,
               S = #s{link_owners = Owners, owner_refs = OwnerRefs}) ->
    case link_lease(ReplyTo) of
        undefined ->
            S;
        Lease ->
            ChannelOwners = maps:get(Channel, Owners, #{}),
            case maps:is_key(Lease, ChannelOwners) of
                true ->
                    S;
                false ->
                    Pid = lease_pid(Lease),
                    MRef = erlang:monitor(process, Pid),
                    S#s{
                      link_owners =
                        Owners#{Channel => ChannelOwners#{Lease => MRef}},
                      owner_refs = OwnerRefs#{MRef => {Channel, Lease}}}
            end
    end.

link_lease({lease, {Pid, Ref} = Lease})
  when is_pid(Pid), is_reference(Ref) -> Lease;
%% Existing ref-correlated opens retain their original process-owned lifetime.
%% Only open_link_lease/3 opts into per-request release ownership.
link_lease({Pid, Ref}) when is_pid(Pid), is_reference(Ref) -> Pid;
link_lease(Pid) when is_pid(Pid) -> Pid;
link_lease(_Malformed) -> undefined.

lease_pid({Pid, Ref}) when is_pid(Pid), is_reference(Ref) -> Pid;
lease_pid(Pid) when is_pid(Pid) -> Pid.

channel_has_owner(Channel, #s{link_owners = Owners,
                              send_owned = SendOwned}) ->
    maps:is_key(Channel, SendOwned) orelse
    map_size(maps:get(Channel, Owners, #{})) > 0.

handle_link_owner_down(MRef, Pid,
                       S = #s{owner_refs = OwnerRefs,
                              link_owners = Owners,
                              pending = Pending}) ->
    case maps:take(MRef, OwnerRefs) of
        error ->
            S;
        {{Channel, {Pid, _Ref} = Lease}, OwnerRefs1} ->
            retire_link_owner(
              Channel, Lease, OwnerRefs1, Owners, Pending, S);
        {{Channel, Pid = Lease}, OwnerRefs1} ->
            retire_link_owner(
              Channel, Lease, OwnerRefs1, Owners, Pending, S);
        {{_Channel, _OtherLease}, OwnerRefs1} ->
            %% A monitor ref is the identity; a mismatched DOWN pid is ignored
            %% fail-closed while removing the stale reverse entry.
            S#s{owner_refs = OwnerRefs1}
    end.

retire_link_owner(Channel, Lease, OwnerRefs1, Owners, Pending, S) ->
            ChannelOwners0 = maps:get(Channel, Owners, #{}),
            ChannelOwners1 = maps:remove(Lease, ChannelOwners0),
            Owners1 = case map_size(ChannelOwners1) of
                          0 -> maps:remove(Channel, Owners);
                          _ -> Owners#{Channel => ChannelOwners1}
                      end,
            Pending1 = remove_waiter(Channel, Lease, Pending),
            retire_unowned_channel(
              Channel,
              S#s{owner_refs = OwnerRefs1,
                  link_owners = Owners1,
                  pending = Pending1}).

release_link_owner(
  Channel, {Pid, Ref} = Lease,
  S = #s{link_owners = Owners, owner_refs = OwnerRefs, pending = Pending})
  when is_pid(Pid), is_reference(Ref) ->
    ChannelOwners0 = maps:get(Channel, Owners, #{}),
    case maps:take(Lease, ChannelOwners0) of
        error ->
            S;
        {MRef, ChannelOwners1} ->
            _ = erlang:demonitor(MRef, [flush]),
            Owners1 = case map_size(ChannelOwners1) of
                          0 -> maps:remove(Channel, Owners);
                          _ -> Owners#{Channel => ChannelOwners1}
                      end,
            retire_unowned_channel(
              Channel,
              S#s{link_owners = Owners1,
                  owner_refs = maps:remove(MRef, OwnerRefs),
                  pending = remove_waiter(Channel, Lease, Pending)})
    end;
release_link_owner(_Channel, _Malformed, S) ->
    S.

remove_waiter(Channel, Lease, Pending) ->
    case maps:get(Channel, Pending, undefined) of
        {Sid, Waiters0} ->
            Waiters1 = remove_owned_waiters(Lease, Waiters0),
            Pending#{Channel => {Sid, Waiters1}};
        undefined ->
            Pending
    end.

remove_owned_waiters(Pid, Waiters) when is_pid(Pid) ->
    [Waiter || Waiter <- Waiters, waiter_pid(Waiter) =/= Pid];
remove_owned_waiters({_Pid, _Ref} = Lease, Waiters) ->
    [Waiter || Waiter <- Waiters, Waiter =/= {lease, Lease}].

waiter_pid({lease, {Pid, Ref}}) when is_pid(Pid), is_reference(Ref) -> Pid;
waiter_pid({Pid, Ref}) when is_pid(Pid), is_reference(Ref) -> Pid;
waiter_pid(Pid) when is_pid(Pid) -> Pid;
waiter_pid(_Malformed) -> undefined.

retire_unowned_channel(Channel, S) ->
    case channel_has_owner(Channel, S) of
        true ->
            S;
        false ->
            retire_channel_link(Channel, S)
    end.

retire_channel_link(Channel,
                    S = #s{chans = Chans, pending = Pending,
                           streams = Streams, sendq = SendQ}) ->
    Active = maps:get(Channel, Chans, undefined),
    PendingLink =
        case maps:get(Channel, Pending, undefined) of
            {Sid, _Waiters} -> maps:get(Sid, Streams, undefined);
            undefined -> undefined
        end,
    _ = [quod_link:close(LinkPid)
         || LinkPid <- lists:usort([Active, PendingLink]),
            is_pid(LinkPid)],
    S#s{chans = maps:remove(Channel, Chans),
        pending = maps:remove(Channel, Pending),
        sendq = maps:remove(Channel, SendQ)}.

release_channel_owners(Channel,
                       S = #s{link_owners = Owners,
                              owner_refs = OwnerRefs}) ->
    ChannelOwners = maps:get(Channel, Owners, #{}),
    maps:foreach(
      fun(_Lease, MRef) ->
          _ = erlang:demonitor(MRef, [flush])
      end,
      ChannelOwners),
    MRefs = maps:values(ChannelOwners),
    S#s{link_owners = maps:remove(Channel, Owners),
        owner_refs = maps:without(MRefs, OwnerRefs)}.

%% a peer reset a stream -> kill the link serving it.
drop_stream(Sid, S = #s{streams = Streams}) ->
    case maps:get(Sid, Streams, undefined) of
        undefined -> S;
        LinkPid   -> _ = quod_link:close(LinkPid), S
    end.

%% a link died -> drop it from both indexes, fail any pending waiters on it, and discard any frames
%% buffered for the channel it was opening (their fire-and-forget send is lost; the caller retries).
drop_link(LinkPid, S = #s{streams = Streams, chans = Chans,
                          pending = Pending, sendq = SendQ,
                          send_owned = SendOwned, peer = Peer}) ->
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
    S1 = S#s{streams = maps:filter(fun(_, P) -> P =/= LinkPid end, Streams),
              chans   = maps:filter(fun(_, P) -> P =/= LinkPid end, Chans),
              pending = Pending1,
              sendq   = maps:without(DeadChans, SendQ),
              send_owned = maps:without(DeadChans, SendOwned)},
    lists:foldl(fun release_channel_owners/2, S1, DeadChans).

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

%% A connection can die before its opening links do, so waiting for linked
%% link EXIT messages cannot resolve their open_link callers: this process is
%% itself about to stop. Resolve every still-pending accepted open exactly once
%% at the connection ownership boundary, then let the linked exit tear down the
%% streams. Openers that already received link_up are no longer in `pending` and
%% continue to observe the link's normal DOWN signal instead.
connection_down(Reason, #s{peer = Peer, owner = Owner,
                           pending = Pending}) ->
    fail_pending(Peer, Pending),
    terminal_start(Peer, Owner, Reason).

owner_down(Reason, #s{peer = Peer, pending = Pending}) ->
    fail_pending(Peer, Pending),
    exit({shutdown, Reason}).

fail_pending(Peer, Pending) ->
    maps:foreach(
      fun(Channel, {_Sid, Waiters}) ->
          lists:foreach(
            fun(Waiter) ->
                notify_link_error(Waiter, Peer, Channel)
            end,
            Waiters)
      end,
      Pending),
    ok.

%% The transport authority is the sole owner of its connection cache. On a
%% terminal dial/connection result, remain as a failure responder until that
%% authority removes this exact pid and acknowledges it. Every open the owner
%% sent before removal precedes the ACK (same sender ordering), so each gets one
%% terminal link_error; every later open selects a replacement connection.
%% There is no settle timer and no dead-pid race.
terminal_start(Peer, Owner, Reason) ->
    Ref = make_ref(),
    Owner ! {conn_terminal, self(), Ref},
    terminal_loop(Peer, Owner, Ref, Reason).

terminal_loop(Peer, Owner, Ref, Reason) ->
    receive
        {open_link, Channel, ReplyTo} ->
            notify_link_error(ReplyTo, Peer, Channel),
            terminal_loop(Peer, Owner, Ref, Reason);
        {send, _Channel, _Frame} ->
            terminal_loop(Peer, Owner, Ref, Reason);
        {conn_terminal_ack, Owner, Ref} ->
            exit({shutdown, Reason});
        {'EXIT', Owner, OwnerReason} ->
            fail_owner_startup(Peer),
            exit({shutdown, {transport_owner_down, OwnerReason}});
        _Other ->
            terminal_loop(Peer, Owner, Ref, Reason)
    end.

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

%% `ExpectedPeer` pins a known route key; `any` authenticates and returns the
%% certificate key for identity discovery. A bare endpoint has no expected key
%% and remains address-routed. The check completes before a stream can open.
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
notify_link_up({lease, {ReplyTo, Ref}}, Peer, Channel, LinkPid)
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
notify_link_error({lease, {ReplyTo, Ref}}, Peer, Channel)
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
