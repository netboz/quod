-module(quod_link).
-moduledoc """
A **link**: one process owning exactly one QUIC stream = one channel to one peer.

The first frame on a stream is a **header** naming the opener's node id and the
channel; subsequent frames are payloads. A link:

- **sends** via `send/2` (a cast — never blocks the caller),
- **receives** on its own stream (own reassembly buffer) and publishes
  `{quod_message, {Peer, self()}, Channel, Payload}` to `{channel, Channel}`,
- **dies** when its stream or connection closes — its death *is* the disconnect
  signal (whoever holds the pid `erlang:monitor`s it).

Because each stream has its own process, channels are concurrent on the BEAM
too — no shared receive loop, no shared send path.
""".

-export([start_outbound/5, start_inbound/2, send/2, close/1, owned/1]).

-ifdef(TEST).
-export([header/2, parse_header/1, frame/1, parse/1]).
-endif.

-define(HEADER_TIMEOUT_MS, 5000).
-define(MAX_FRAME_BYTES, (1 bsl 20)).

-record(s, {stream, channel, peer, conn, buf = <<>>}).

%% --- API -----------------------------------------------------------------

-doc "We opened `Stream` to `Peer` for `Channel`; announce `Self` then serve it.".
-spec start_outbound(term(), term(), binary(), term(), pid()) -> pid().
start_outbound(Stream, Peer, Channel, Self, Conn) ->
    spawn(fun() ->
        await_ownership(Stream),
        _ = quicer:send(Stream, header(Self, Channel)),
        Conn ! {link_up, Channel, Peer, self()},
        loop(#s{stream = Stream, channel = Channel, peer = Peer, conn = Conn})
    end).

-doc "A peer opened `Stream`; read its header to learn (peer, channel), then serve it.".
-spec start_inbound(term(), pid()) -> pid().
start_inbound(Stream, Conn) ->
    spawn(fun() ->
        await_ownership(Stream),
        case read_header(Stream, <<>>) of
            {ok, Peer, Channel, Rest} ->
                Conn ! {link_up, Channel, Peer, self()},
                %% serve any payload bytes that arrived in the same buffer as the header
                loop(loop_msgs(Rest, #s{stream = Stream, channel = Channel, peer = Peer, conn = Conn}));
            _ ->
                _ = quicer:close_stream(Stream),
                ok
        end
    end).

-doc "Signal a freshly spawned link that it now owns its stream (handed off by `m:quod_conn`).".
-spec owned(pid()) -> ok.
owned(LinkPid) ->
    LinkPid ! owned,
    ok.

%% block until the connection has transferred stream ownership to us, then start
%% receiving — bytes only flow once we are the owner (no handoff race).
await_ownership(Stream) ->
    receive owned -> ok after ?HEADER_TIMEOUT_MS -> exit(no_owner) end,
    _ = quicer:setopt(Stream, active, true),
    ok.

-doc "Queue `Payload` to be sent on this link (non-blocking).".
-spec send(pid(), iodata()) -> ok.
send(LinkPid, Payload) ->
    LinkPid ! {send, iolist_to_binary(Payload)},
    ok.

-doc "Close this link and its stream (its holder's `erlang:monitor` then fires `DOWN`).".
-spec close(pid()) -> ok.
close(LinkPid) ->
    LinkPid ! close,
    ok.

%% --- loop ----------------------------------------------------------------

loop(S = #s{stream = Stream}) ->
    receive
        {send, Payload} ->
            _ = quicer:send(Stream, frame(Payload)),
            loop(S);
        close ->
            _ = quicer:close_stream(Stream),
            exit(normal);
        {quic, Data, Stream, _} when is_binary(Data) ->
            loop(loop_msgs(Data, S));
        {quic, send_complete, Stream, _}       -> loop(S);
        {quic, peer_send_shutdown, Stream, _}  -> loop(S);
        {quic, stream_closed, _, _}            -> exit(normal);
        {quic, closed, _, _}                   -> exit(normal);
        {quic, transport_shutdown, _, _}       -> exit(normal);
        {quic, shutdown, _, _}                 -> exit(normal);
        _Other -> loop(S)
    end.

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

%% --- wire ----------------------------------------------------------------

%% header: <<NLen:16, NodeId, CLen:16, Channel>>  (one, at stream open)
header(NodeId, Channel) ->
    NB = term_to_binary(NodeId, [deterministic]),
    <<(byte_size(NB)):16, NB/binary, (byte_size(Channel)):16, Channel/binary>>.

read_header(Stream, Acc) ->
    receive
        {quic, Data, Stream, _} when is_binary(Data) ->
            Buf = <<Acc/binary, Data/binary>>,
            case parse_header(Buf) of
                {ok, _, _, _} = Ok -> Ok;
                error             -> error;
                more              -> read_header(Stream, Buf)
            end;
        close -> error;   %% asked to shut down before the header arrived
        {quic, C, _, _} when C =:= closed; C =:= shutdown; C =:= transport_shutdown -> error
    after ?HEADER_TIMEOUT_MS -> error
    end.

%% decode one header from a buffer: {ok, NodeId, Channel, Rest} | more | error.
%% NLen/CLen are 16-bit, so a complete header is <= ~131 KB; an incomplete one is
%% bounded by read_header's timeout — no separate size cap is needed here.
parse_header(<<NLen:16, NB:NLen/binary, CLen:16, Channel:CLen/binary, Rest/binary>>) ->
    try {ok, binary_to_term(NB, [safe]), Channel, Rest}
    catch _:_ -> error end;
parse_header(_Buf) -> more.

%% payload frame: <<PLen:32, Payload>>
frame(Payload) -> <<(byte_size(Payload)):32, Payload/binary>>.

parse(Bin) -> parse(Bin, []).
parse(<<PLen:32, _/binary>>, _Acc) when PLen > ?MAX_FRAME_BYTES -> {error, oversized};
parse(<<PLen:32, Rest/binary>> = Bin, Acc) ->
    case Rest of
        <<Payload:PLen/binary, Tail/binary>> -> parse(Tail, [Payload | Acc]);
        _ -> {lists:reverse(Acc), Bin}
    end;
parse(Bin, Acc) -> {lists:reverse(Acc), Bin}.
