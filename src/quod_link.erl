-module(quod_link).
-moduledoc """
A **link**: one process per (peer, channel) = one QUIC stream's framing.

Unlike a NIF stream, a pure-Erlang `quic` connection delivers *all* of its
streams' data to a single owner (`m:quod_conn`). So a link does **not** own its
stream — `m:quod_conn` routes inbound bytes for the link's `StreamId` to it as
`{data, Bin, Fin}`, and the link sends with `quic:send_data/4` directly (any
process holding the connection pid may send). A link:

- **frames** an opener's first write as a **header** (`<<NLen:16, NodeId,
  CLen:16, Channel, LearnHint:8>>`), then length-prefixed payloads
  (`<<PLen:32, Payload>>`),
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
holder gets `link_error` (never a phantom `link_up`). The receiver asks the
connection owner to bind the claimed header key to the TLS certificate before
it ACKs or publishes any coalesced payload bytes. This makes a link to a
dead, unreachable, or wrongly authenticated peer fail to come up.
""".

-include("quod_transport_limits.hrl").

-export([start_outbound/7, start_inbound/3, send/2, send_ordered/2,
         send_reliable/3, close/1]).

-ifdef(TEST).
-export([header/3, parse_header/1, frame/1, parse/1,
         test_fail_next_ordered/2]).
-endif.

-define(HEADER_TIMEOUT_MS, 5000).
-define(ACK_TIMEOUT_MS, 5000).   %% opener waits this long for the peer's ACK before failing the link
-define(ORDERED_SEND_TIMEOUT_MS, 250).

-record(s, {conn, sid, channel, peer, buf = <<>>}).

-ifdef(TEST).
-define(ORDERED_SEND_RESULT(Conn, Sid, Frame, Deadline),
        test_ordered_send_result(Conn, Sid, Frame, Deadline)).
-define(TEST_ORDERED_FAILURE_KEY,
        {?MODULE, test_ordered_failure}).
-define(OTHER_LOOP_CLAUSES(S),
        {test_fail_next_ordered, From, Ref, Reason} ->
            _ = put(?TEST_ORDERED_FAILURE_KEY, Reason),
            From ! {Ref, armed},
            loop(S);
        _Other ->
            loop(S)).
-else.
-define(ORDERED_SEND_RESULT(Conn, Sid, Frame, Deadline),
        send_until_accepted(Conn, Sid, Frame, Deadline)).
-define(OTHER_LOOP_CLAUSES(S),
        _Other ->
            loop(S)).
-endif.

%% --- API -----------------------------------------------------------------

-doc """
We opened `Sid` to `Peer` for `Channel`; announce `Self` (the header), then wait
for the peer's ACK before declaring `link_up`. No ACK ⇒ the link dies (`link_error`
to the holder) — a write alone is never treated as liveness.
""".
-spec start_outbound(pid(), non_neg_integer(), term(), binary(), term(), pid(),
                     learn | no_learn) -> pid().
start_outbound(Conn, Sid, Peer, Channel, Self, ConnProc, LearnHint) ->
    spawn(fun() ->
        _ = quic:send_data(Conn, Sid, header(Self, Channel, LearnHint), false),
        await_ack(ConnProc, <<>>, #s{conn = Conn, sid = Sid, channel = Channel, peer = Peer})
    end).

%% Wait for the peer's first frame (its ACK that it authenticated our header)
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
                    lists:foreach(
                      fun(Payload) -> publish(Peer, Channel, Payload) end,
                      Msgs),
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
Queue a payload whose successors must never pass it if local QUIC backpressure
refuses the frame. The link retries transient refusal in mailbox order; if the
frame is still not accepted within the bound, the link exits so every queued
successor is discarded and its owner can reconnect and reconstruct the ordered
prefix from retained state.
""".
-spec send_ordered(pid(), iodata()) -> ok.
send_ordered(LinkPid, Payload) ->
    LinkPid ! {send_ordered, iolist_to_binary(Payload)},
    ok.

-ifdef(TEST).
%% Deterministically exercise the real ordered-send failure/reset/exit arm on
%% an otherwise real link. The seam exists only in test builds; it changes no
%% production wire or runtime behavior.
test_fail_next_ordered(LinkPid, Reason) ->
    Ref = make_ref(),
    MRef = monitor(process, LinkPid),
    LinkPid ! {test_fail_next_ordered, self(), Ref, Reason},
    receive
        {Ref, armed} ->
            demonitor(MRef, [flush]),
            ok;
        {'DOWN', MRef, process, LinkPid, DownReason} ->
            {error, DownReason}
    after 1000 ->
        demonitor(MRef, [flush]),
        {error, timeout}
    end.
-endif.

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
                {ok, Peer, Channel, LearnHint, Rest} ->
                    %% Hold every coalesced payload byte until the connection
                    %% owner binds the claimed header key to the TLS certificate.
                    %% Only an authenticated header earns an ACK or publication.
                    Ref = make_ref(),
                    ConnProc ! {authenticate_link, self(), Ref, Channel,
                                Peer, LearnHint},
                    await_header_auth(
                      Conn, Sid, ConnProc, Ref, Peer, Channel, Rest);
                error -> exit(bad_header);
                more  -> read_header(Conn, Sid, ConnProc, Buf)
            end;
        close -> exit(normal)
    after ?HEADER_TIMEOUT_MS -> exit(header_timeout)
    end.

await_header_auth(Conn, Sid, ConnProc, Ref, Peer, Channel, Rest) ->
    receive
        {link_authenticated, ConnProc, Ref} ->
            _ = quic:send_data(Conn, Sid, ack_frame(), false),
            S = #s{conn = Conn, sid = Sid, channel = Channel, peer = Peer},
            loop(loop_msgs(Rest, S));
        close ->
            exit(normal)
    after ?HEADER_TIMEOUT_MS ->
        exit(header_auth_timeout)
    end.

loop(S = #s{conn = Conn, sid = Sid}) ->
    receive
        {data, Bin, _Fin} ->
            loop(loop_msgs(Bin, S));
        {send, Payload} ->
            %% Do not ACT on the return: it includes TRANSIENT backpressure
            %% ({flow_control_blocked,_}, send_queue_full) that must NOT tear the link
            %% down — doing so churns links under load. A genuinely dead stream/connection
            %% kills this (linked) process via quod_conn, which is the real disconnect
            %% signal. But COUNT every refusal: a dropped frame only exists again once
            %% some layer's recovery timer repairs it, so the drop rate is the hidden
            %% pacemaker of consensus latency and must be visible per receiving peer.
            case quic:send_data(Conn, Sid, frame(Payload), false) of
                ok              -> ok;
                {error, Reason} ->
                    quod_metrics:count_link_send_drop(
                      S#s.peer, S#s.channel, Reason)
            end,
            loop(S);
        {send_ordered, Payload} ->
            Deadline =
                erlang:monotonic_time(millisecond)
                + ?ORDERED_SEND_TIMEOUT_MS,
            case ?ORDERED_SEND_RESULT(
                    Conn, Sid, frame(Payload), Deadline) of
                ok ->
                    loop(S);
                {error, Reason} ->
                    quod_metrics:count_link_send_drop(
                      S#s.peer, S#s.channel, Reason),
                    _ = catch quic:reset_stream(Conn, Sid, 0),
                    exit({ordered_send_failed, Reason})
            end;
        {send_reliable, From, Ref, Payload, Deadline} ->
            Result = send_until_accepted(Conn, Sid, frame(Payload), Deadline),
            From ! {Ref, Result},
            loop(S);
        close ->
            _ = quic:reset_stream(Conn, Sid, 0),
            exit(normal);
        ?OTHER_LOOP_CLAUSES(S)
    end.

-ifdef(TEST).
test_ordered_send_result(Conn, Sid, Frame, Deadline) ->
    case erase(?TEST_ORDERED_FAILURE_KEY) of
        undefined ->
            send_until_accepted(Conn, Sid, Frame, Deadline);
        Reason ->
            {error, Reason}
    end.
-endif.

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
            lists:foreach(
              fun(Payload) -> publish(Peer, Ch, Payload) end,
              Frames),
            S#s{buf = Buf1}
    end.

publish(Peer, Channel, Payload) ->
    _ = quod_reg:publish({channel, Channel}, {quod_message, {Peer, self()}, Channel, Payload}),
    ok.

%% --- wire ----------------------------------------------------------------

%% header: <<NLen:16, NodeId, CLen:16, Channel, LearnHint:8>> (one, at stream open). NodeId is the
%% sender's transport identity `{Pubkey, Addr}`: the receiver binds the pubkey to the
%% connection's `peercert`. `LearnHint=1` retains ordinary address-cache learning;
%% directory-scoped links send 0 so neither this header nor reverse streams on the
%% same connection can pollute that cache.
header(NodeId, Channel, LearnHint) ->
    NB = term_to_binary(NodeId, [deterministic]),
    <<(byte_size(NB)):16, NB/binary, (byte_size(Channel)):16, Channel/binary,
      (encode_learn_hint(LearnHint)):8>>.

%% {ok, NodeId, Channel, LearnHint, Rest} | more | error
parse_header(<<NLen:16, NB:NLen/binary, CLen:16, Channel:CLen/binary,
               LearnByte:8, Rest/binary>>) ->
    case {quod_safe_term:decode(NB, 16#FFFF),
          decode_learn_hint(LearnByte)} of
        {{ok, Peer}, {ok, LearnHint}} ->
            case valid_identity(Peer) of
                true  -> {ok, Peer, Channel, LearnHint, Rest};
                false -> error
            end;
        _ ->
            error
    end;
parse_header(_Buf) -> more.

encode_learn_hint(learn)    -> 1;
encode_learn_hint(no_learn) -> 0.

decode_learn_hint(1) -> {ok, learn};
decode_learn_hint(0) -> {ok, no_learn};
decode_learn_hint(_) -> error.

valid_identity({Pubkey, Addr}) ->
    is_binary(Pubkey) andalso byte_size(Pubkey) =:= 32 andalso
        quod_quic:valid_endpoint(Addr);
valid_identity(_) -> false.

%% payload frame: <<PLen:32, Payload>>
frame(Payload) -> <<(byte_size(Payload)):32, Payload/binary>>.

%% The liveness/authentication ACK: an empty frame sent only after the receiver
%% binds the header identity to TLS. The opener consumes the first frame as the
%% ACK; real payloads are never empty, so there is no ambiguity.
ack_frame() -> frame(<<>>).

parse(Bin) -> parse(Bin, []).
parse(<<PLen:32, _/binary>>, _Acc)
  when PLen > ?QUOD_TRANSPORT_MAX_FRAME_BYTES -> {error, oversized};
parse(<<PLen:32, Rest/binary>> = Bin, Acc) ->
    case Rest of
        <<Payload:PLen/binary, Tail/binary>> -> parse(Tail, [Payload | Acc]);
        _ -> {lists:reverse(Acc), Bin}
    end;
parse(Bin, Acc) -> {lists:reverse(Acc), Bin}.
