-module(quod_link).
-moduledoc """
A **link**: one process per (peer, channel) = one QUIC stream's framing.

Unlike a NIF stream, a pure-Erlang `quic` connection delivers *all* of its
streams' data to a single owner (`m:quod_conn`). So a link does **not** own its
stream — `m:quod_conn` routes inbound bytes for the link's `StreamId` to it as
`{data, Bin, Fin}`, and the link sends with `quic:send_data/4` directly (any
process holding the connection pid may send). A link:

- **frames** an opener's first write as a **header** (`<<NLen:16, NodeId,
  CLen:16, Channel>>`), then length-prefixed payloads (`<<PLen:32, Payload>>`),
- **publishes** each payload as `{quod_message, {Peer, self()}, Channel, Payload}`
  on the gproc property `{channel, Channel}`,
- **dies** when its stream/connection drops — its death *is* the disconnect
  signal its holder `erlang:monitor`s.

## Liveness handshake (`link_up` requires a peer ACK)

Over a connectionless (UDP/QUIC) transport a *send* is **not** proof the peer is
alive — a dead peer's connection lingers and a write to it silently succeeds (this
is the SWIM rule: only a received reply proves liveness). So the **opener does not
declare `link_up` until the peer ACKs its header**: it writes the header, then
waits for the peer's first frame (an empty ACK frame the peer emits as soon as it
reads the header). No ACK within `?ACK_TIMEOUT_MS` ⇒ the link **dies** and its
holder gets `link_error` (never a phantom `link_up`). The receiver, having read the
header, already has proof the opener exists, so it `link_up`s immediately *and*
sends the ACK back. This makes a link to a dead/unreachable peer fail to come up,
so the membership layer's probe correctly evicts it.
""".

-export([start_outbound/6, start_inbound/3, send/2, send_reliable/3, close/1]).

-ifdef(TEST).
-export([header/2, parse_header/1, frame/1, parse/1]).
-endif.

-define(HEADER_TIMEOUT_MS, 5000).
-define(ACK_TIMEOUT_MS, 5000).   %% opener waits this long for the peer's ACK before failing the link
-define(MAX_FRAME_BYTES, (1 bsl 20)).

-record(s, {conn, sid, channel, peer, buf = <<>>}).

%% --- API -----------------------------------------------------------------

-doc """
We opened `Sid` to `Peer` for `Channel`; announce `Self` (the header), then wait
for the peer's ACK before declaring `link_up`. No ACK ⇒ the link dies (`link_error`
to the holder) — a write alone is never treated as liveness.
""".
-spec start_outbound(pid(), non_neg_integer(), term(), binary(), term(), pid()) -> pid().
start_outbound(Conn, Sid, Peer, Channel, Self, ConnProc) ->
    spawn(fun() ->
        _ = quic:send_data(Conn, Sid, header(Self, Channel), false),
        await_ack(ConnProc, <<>>, #s{conn = Conn, sid = Sid, channel = Channel, peer = Peer})
    end).

%% Wait for the peer's first frame (its ACK that it read our header and is alive)
%% before announcing link_up. The ACK is consumed here; any frames already past it
%% are real payloads and are published. No ACK within the timeout ⇒ exit so the
%% holder sees `link_error` (quod_conn fail_pending), NOT a phantom link_up.
await_ack(ConnProc, Acc, S = #s{channel = Channel, peer = Peer}) ->
    receive
        {data, Bin, _Fin} ->
            Buf = <<Acc/binary, Bin/binary>>,
            case parse(Buf) of
                {error, oversized} -> exit({frame_too_large, Channel});
                {[], _}            -> await_ack(ConnProc, Buf, S);   %% ACK frame still partial
                {[<<>> | Msgs], Rest} ->                            %% first frame MUST be the empty ACK
                    ConnProc ! {link_up, Channel, Peer, self(), out},   %% WE opened this stream
                    _ = [publish(Peer, Channel, P) || P <- Msgs],
                    loop(S#s{buf = Rest});
                {[_NonEmpty | _], _} -> exit(unexpected_first_frame) %% not an ACK -> fail the link
            end;
        close -> exit(normal)
    after ?ACK_TIMEOUT_MS -> exit(no_ack)
    end.

-doc "A peer opened `Sid`; read its header (from forwarded data) to learn (peer, channel).".
-spec start_inbound(pid(), non_neg_integer(), pid()) -> pid().
start_inbound(Conn, Sid, ConnProc) ->
    spawn(fun() -> read_header(Conn, Sid, ConnProc, <<>>) end).

-doc "Queue `Payload` to be sent on this link (non-blocking).".
-spec send(pid(), iodata()) -> ok.
send(LinkPid, Payload) ->
    LinkPid ! {send, iolist_to_binary(Payload)},
    ok.

-doc """
Send one frame and wait until the local QUIC connection accepts it. Transient
flow-control pressure is retried until `Timeout`; no peer acknowledgement is
involved. Intended for bounded request/response protocols, not gossip.
""".
-spec send_reliable(pid(), iodata(), pos_integer()) -> ok | {error, term()}.
send_reliable(LinkPid, Payload, Timeout)
  when is_pid(LinkPid), is_integer(Timeout), Timeout > 0 ->
    Ref = make_ref(),
    MRef = monitor(process, LinkPid),
    LinkPid ! {send_reliable, self(), Ref, iolist_to_binary(Payload),
               erlang:monotonic_time(millisecond) + Timeout},
    receive
        {Ref, Result} ->
            demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, LinkPid, Reason} ->
            {error, Reason}
    after Timeout + 100 ->
        demonitor(MRef, [flush]),
        {error, timeout}
    end.

-doc "Close this link and reset its stream (its holder's `erlang:monitor` then fires `DOWN`).".
-spec close(pid()) -> ok.
close(LinkPid) ->
    LinkPid ! close,
    ok.

%% --- loop ----------------------------------------------------------------

%% read the one-shot header out of the inbound byte stream, then serve payloads.
read_header(Conn, Sid, ConnProc, Acc) ->
    receive
        {data, Bin, _Fin} ->
            Buf = <<Acc/binary, Bin/binary>>,
            case parse_header(Buf) of
                {ok, Peer, Channel, Rest} ->
                    %% we hold proof the opener exists (its header); ACK it so its
                    %% outbound link can come up, then serve normally.
                    _ = quic:send_data(Conn, Sid, ack_frame(), false),
                    learn_hint(Peer),                                  %% header reveals pubkey => addr
                    ConnProc ! {link_up, Channel, Peer, self(), in},   %% the PEER opened this stream
                    loop(loop_msgs(Rest, #s{conn = Conn, sid = Sid, channel = Channel, peer = Peer}));
                error -> exit(bad_header);
                more  -> read_header(Conn, Sid, ConnProc, Buf)
            end;
        close -> exit(normal)
    after ?HEADER_TIMEOUT_MS -> exit(header_timeout)
    end.

loop(S = #s{conn = Conn, sid = Sid}) ->
    receive
        {data, Bin, _Fin} ->
            loop(loop_msgs(Bin, S));
        {send, Payload} ->
            %% Ignore the return: it includes TRANSIENT backpressure ({flow_control_blocked,
            %% _}, send_queue_full) that must NOT tear the link down — doing so churns links
            %% under load. A genuinely dead stream/connection kills this (linked) process via
            %% quod_conn, which is the real disconnect signal.
            _ = quic:send_data(Conn, Sid, frame(Payload), false),
            loop(S);
        {send_reliable, From, Ref, Payload, Deadline} ->
            Result = send_until_accepted(Conn, Sid, frame(Payload), Deadline),
            From ! {Ref, Result},
            loop(S);
        close ->
            _ = quic:reset_stream(Conn, Sid, 0),
            exit(normal);
        _Other ->
            loop(S)
    end.

send_until_accepted(Conn, Sid, Frame, Deadline) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        false ->
            {error, backpressure_timeout};
        true ->
            case catch quic:send_data(Conn, Sid, Frame, false) of
                ok ->
                    ok;
                {error, {flow_control_blocked, _}} ->
                    retry_send(Conn, Sid, Frame, Deadline);
                {error, send_queue_full} ->
                    retry_send(Conn, Sid, Frame, Deadline);
                {error, Reason} ->
                    {error, Reason};
                {'EXIT', Reason} ->
                    {error, Reason}
            end
    end.

retry_send(Conn, Sid, Frame, Deadline) ->
    timer:sleep(2),
    send_until_accepted(Conn, Sid, Frame, Deadline).

%% append bytes, publish every complete payload frame, keep the remainder
loop_msgs(Data, S = #s{buf = Buf, peer = Peer, channel = Ch}) ->
    case parse(<<Buf/binary, Data/binary>>) of
        {error, oversized} -> exit({frame_too_large, Ch});
        {Frames, Buf1} ->
            _ = [publish(Peer, Ch, P) || P <- Frames],
            S#s{buf = Buf1}
    end.

publish(Peer, Channel, Payload) ->
    _ = quod_reg:publish({channel, Channel}, {quod_message, {Peer, self()}, Channel, Payload}),
    ok.

%% The header announces `{Pubkey, Addr}`; when the pubkey is a real key, record the
%% `Pubkey => Addr` resolution hint so dials-by-pubkey can find this peer.
learn_hint({Pubkey, Addr}) when is_binary(Pubkey) -> _ = quod_quic:learn(Pubkey, Addr), ok;
learn_hint(_)                                     -> ok.

%% --- wire ----------------------------------------------------------------

%% header: <<NLen:16, NodeId, CLen:16, Channel>>  (one, at stream open). NodeId is the
%% sender's transport identity `{Pubkey, Addr}`: the receiver binds the pubkey to the
%% connection's `peercert` and learns `Pubkey => Addr` for resolution.
header(NodeId, Channel) ->
    NB = term_to_binary(NodeId, [deterministic]),
    <<(byte_size(NB)):16, NB/binary, (byte_size(Channel)):16, Channel/binary>>.

%% {ok, NodeId, Channel, Rest} | more | error
parse_header(<<NLen:16, NB:NLen/binary, CLen:16, Channel:CLen/binary, Rest/binary>>) ->
    try binary_to_term(NB, [safe]) of
        Peer ->
            case valid_identity(Peer) of
                true  -> {ok, Peer, Channel, Rest};
                false -> error
            end
    catch _:_ -> error end;
parse_header(_Buf) -> more.

valid_identity({Pubkey, Addr}) ->
    is_binary(Pubkey) andalso byte_size(Pubkey) =:= 32 andalso valid_endpoint(Addr);
valid_identity(_) -> false.

valid_endpoint({Host, Port}) when is_integer(Port), Port > 0, Port =< 65535,
                                  (is_list(Host) orelse is_binary(Host) orelse
                                   is_tuple(Host)) -> true;
valid_endpoint(_) -> false.

%% payload frame: <<PLen:32, Payload>>
frame(Payload) -> <<(byte_size(Payload)):32, Payload/binary>>.

%% the liveness ACK: an empty (zero-length) frame the receiver sends back as soon
%% as it has read the opener's header. The opener consumes the FIRST frame it
%% receives as the ACK; real payloads are never empty, so there is no ambiguity.
ack_frame() -> frame(<<>>).

parse(Bin) -> parse(Bin, []).
parse(<<PLen:32, _/binary>>, _Acc) when PLen > ?MAX_FRAME_BYTES -> {error, oversized};
parse(<<PLen:32, Rest/binary>> = Bin, Acc) ->
    case Rest of
        <<Payload:PLen/binary, Tail/binary>> -> parse(Tail, [Payload | Acc]);
        _ -> {lists:reverse(Acc), Bin}
    end;
parse(Bin, Acc) -> {lists:reverse(Acc), Bin}.
