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
- **publishes** ordinary payloads as `{quod_message, {Peer, self()}, Channel, Payload}`
  on `{channel, Channel}`; catch-up instead gates page credit and delivers
  raw controls directly to the exact serving/producing owner,
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
Catch-up additionally requires the initial page grant before `link_up`. ACK
and grant share one absolute bootstrap deadline; partial bytes cannot renew it.
""".

-include("quod_transport_limits.hrl").

-export([start_outbound/7, start_inbound/3, peer_key/1,
         send/2, send_ordered/2, send_reliable/3, close/1,
         bind_catchup/2, request_page/6, complete_page/3]).

-ifdef(TEST).
-export([header/3, parse_header/1, frame/1, parse/1,
         test_fail_next_ordered/2, test_transport/1]).
-endif.

-define(HEADER_TIMEOUT_MS, 5000).
-define(ACK_TIMEOUT_MS, 5000).   %% opener waits this long for the peer's ACK before failing the link
-type send_item() ::
        {best_effort, binary()}
      | {ordered, binary()}
      | {ordered, binary(), term()}
      | {reliable, pid(), reference(), binary(), integer()}.
-type send_queue() :: {[send_item()], [send_item()]}.
-record(credit, {ns, role, grant = none, owner = none,
                 binding = none, pending = none}).
-record(s, {conn, sid, channel, peer, direction, buf = <<>>,
            catchup = none :: none | #credit{},
            %% One mailbox-ordered send FIFO. An ordered/reliable frame at its
            %% head parks until quod_conn forwards QUIC's exact send_ready for
            %% this stream; successors cannot pass it.
            sendq = {[], []} :: send_queue(),
            send_wait = none :: none | {reference(), reference()}}).

-doc "Extract the authenticated key from either transport identity shape.".
-spec peer_key(term()) -> <<_:256>> | undefined.
peer_key(<<_:256>> = PeerKey) -> PeerKey;
peer_key({<<_:256>> = PeerKey, _Endpoint}) -> PeerKey;
peer_key(_Malformed) -> undefined.

-ifdef(TEST).
-define(ORDERED_SEND_RESULT(Conn, Sid, Frame),
        test_ordered_send_result(Conn, Sid, Frame)).
-define(TEST_ORDERED_FAILURE_KEY,
        {?MODULE, test_ordered_failure}).
-define(OTHER_LOOP_CLAUSES(S),
        {test_fail_next_ordered, From, Ref, Reason} ->
            _ = put(?TEST_ORDERED_FAILURE_KEY, Reason),
            From ! {Ref, armed},
            loop(S);
        {test_transport, From, Ref} ->
            From ! {Ref, {S#s.conn, S#s.sid}},
            loop(S);
        _Other ->
            loop(S)).
-else.
-define(ORDERED_SEND_RESULT(Conn, Sid, Frame),
        send_once(Conn, Sid, Frame)).
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
        Deadline = erlang:monotonic_time(millisecond) + ?ACK_TIMEOUT_MS,
        _ = quic:send_data(Conn, Sid, header(Self, Channel, LearnHint), false),
        await_ack(ConnProc, ack, Deadline,
                  #s{conn = Conn, sid = Sid, channel = Channel,
                     peer = Peer, direction = out,
                     catchup = catchup_channel(Channel, requester)})
    end).

%% Wait for the peer's first frame (its ACK that it authenticated our header)
%% before announcing link_up (catch-up also consumes its initial grant here).
%% The original deadline covers every partial read. No ACK within it ⇒ exit so the
%% holder sees `link_error` (quod_conn fail_pending), NOT a phantom link_up.
await_ack(ConnProc, Stage, Deadline, S = #s{buf = Acc}) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {data, Bin, _Fin} ->
            bootstrap_frames(ConnProc, Stage, Deadline,
                             S#s{buf = <<Acc/binary, Bin/binary>>});
        close -> protocol_failed(normal, S)
    after Remaining -> protocol_failed(no_ack, S)
    end.

bootstrap_frames(ConnProc, Stage, Deadline, S = #s{buf = Buf}) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> protocol_failed(no_ack, S);
        false ->
            case parse_one(Buf) of
                more -> await_ack(ConnProc, Stage, Deadline, S);
                {error, oversized} -> protocol_failed(frame_too_large, S);
                {ok, Payload, Rest} ->
                    bootstrap_frame(ConnProc, Stage, Deadline, Payload,
                                    S#s{buf = Rest})
            end
    end.

bootstrap_frame(ConnProc, ack, _Deadline, <<>>, S = #s{catchup = none}) ->
    announce_outbound(ConnProc, S);
bootstrap_frame(ConnProc, ack, Deadline, <<>>, S) ->
    bootstrap_frames(ConnProc, credit, Deadline, S);
bootstrap_frame(ConnProc, credit, _Deadline, Payload,
                S = #s{catchup = C = #credit{ns = Ns}}) ->
    case quod_catchup:decode_frame(Ns, Payload) of
        {ok, {blocks_credit, Grant}, _Bytes} ->
            announce_outbound(ConnProc, S#s{catchup = C#credit{grant = Grant}});
        _ -> protocol_failed(invalid_initial_credit, S)
    end;
bootstrap_frame(_ConnProc, _Stage, _Deadline, _Payload, S) ->
    protocol_failed(unexpected_first_frame, S).

announce_outbound(ConnProc, S = #s{channel = Channel, peer = Peer, buf = Rest}) ->
    ConnProc ! {link_up, Channel, Peer, self(), out},
    loop(loop_msgs(Rest, S#s{buf = <<>>})).

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
refuses the frame. The link retries transient refusal in mailbox order when
QUIC reports progress. If the transport remains silent for its configured
connection-idle bound, the link exits so every queued successor is discarded
and its owner can reconnect and reconstruct the ordered prefix from retained
state. The timer detects terminal silence; it never discovers normal progress.
""".
-spec send_ordered(pid(), iodata()) -> ok.
send_ordered(LinkPid, Payload) ->
    LinkPid ! {send_ordered, iolist_to_binary(Payload)},
    ok.

-doc "Bind this outbound catch-up link to its existing producer incarnation.".
-spec bind_catchup(pid(), reference()) -> ok.
bind_catchup(Link, BindingRef) when is_pid(Link), is_reference(BindingRef) ->
    Link ! {bind_catchup, self(), BindingRef},
    ok.

-doc "Spend one catch-up grant; the producer retains all unsent request rows.".
-spec request_page(pid(), reference(), binary(), binary(), pos_integer(),
                   pos_integer()) -> ok.
request_page(Link, BindingRef, Grant, ReqId, From, To) ->
    Link ! {request_page, self(), BindingRef, Grant, ReqId, From, To},
    ok.

-doc "Finish an admitted server page after reader DOWN; acceptance is asynchronous.".
-spec complete_page(pid(), reference(), {ok, [binary()], non_neg_integer()} |
                    {error, not_ready | server_error}) -> ok.
complete_page(Link, OperationRef, Result) ->
    Link ! {complete_page, self(), OperationRef, Result},
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

%% Return the real QUIC connection and stream id so transport integration tests
%% can inject the library's documented send_ready event at quod_conn and verify
%% that it reaches this exact link. TEST-only: no runtime inspection API.
test_transport(LinkPid) ->
    Ref = make_ref(),
    LinkPid ! {test_transport, self(), Ref},
    receive
        {Ref, Transport} -> {ok, Transport}
    after 1000 ->
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
        close ->
            _ = catch quic:reset_stream(Conn, Sid, 0),
            exit(normal)
    after ?HEADER_TIMEOUT_MS -> exit(header_timeout)
    end.

await_header_auth(Conn, Sid, ConnProc, Ref, Peer, Channel, Rest) ->
    receive
        {link_authenticated, ConnProc, Ref} ->
            S = #s{conn = Conn, sid = Sid, channel = Channel,
                   peer = Peer, direction = in,
                   catchup = catchup_channel(Channel, server)},
            S1 = case S#s.catchup of
                     none ->
                         _ = quic:send_data(Conn, Sid, ack_frame(), false),
                         S;
                     #credit{ns = Ns} ->
                         Grant = fresh_grant(none),
                         Payload = quod_catchup:encode_frame(Ns, {blocks_credit, Grant}),
                         Frames = <<(ack_frame())/binary, (frame(Payload))/binary>>,
                         enqueue_send({ordered, Frames, {initial_credit, Grant}}, S)
                 end,
            loop(loop_msgs(Rest, S1));
        close ->
            _ = catch quic:reset_stream(Conn, Sid, 0),
            exit(normal)
    after ?HEADER_TIMEOUT_MS ->
        exit(header_auth_timeout)
    end.

loop(S = #s{conn = Conn, sid = Sid}) ->
    receive
        {data, Bin, _Fin} ->
            loop(loop_msgs(Bin, S));
        {bind_catchup, Producer, BindingRef} ->
            loop(bind_producer(Producer, BindingRef, S));
        {request_page, Producer, BindingRef, Grant, ReqId, From, To} ->
            loop(submit_page(Producer, BindingRef, Grant, ReqId, From, To, S));
        {complete_page, Owner, OperationRef, Result} ->
            loop(complete_server_page(Owner, OperationRef, Result, S));
        {'DOWN', MRef, process, Owner, _Reason}
          when S#s.catchup =/= none ->
            case (S#s.catchup)#credit.owner of
                {Owner, MRef} -> protocol_failed(catchup_owner_down, S);
                _ -> loop(S)
            end;
        {send, Payload} ->
            require_generic_channel(S),
            loop(enqueue_send({best_effort, frame(Payload)}, S));
        {send_ordered, Payload} ->
            require_generic_channel(S),
            loop(enqueue_send({ordered, frame(Payload)}, S));
        {send_reliable, From, Ref, Payload, Deadline} ->
            require_generic_channel(S),
            loop(enqueue_send(
                   {reliable, From, Ref, frame(Payload), Deadline}, S));
        {send_ready, Sid} ->
            loop(resume_sends(S));
        {send_deadline, Token} ->
            loop(send_deadline(Token, S));
        {reset_inbound_channel, Channel}
          when S#s.direction =:= in, S#s.channel =:= Channel ->
            %% The runtime owner of this inbound channel restarted and lost
            %% volatile peer registrations. Reset only this peer-opened stream;
            %% its source observes DOWN and reconnects/re-registers.
            _ = quic:reset_stream(Conn, Sid, 0),
            reply_queued_reliable({error, channel_owner_restarted}, S),
            cancel_send_timer(S),
            exit(normal);
        {reset_inbound_channel, _OtherChannel} ->
            loop(S);
        close ->
            _ = quic:reset_stream(Conn, Sid, 0),
            reply_queued_reliable({error, closed}, S),
            cancel_send_timer(S),
            exit(normal);
        ?OTHER_LOOP_CLAUSES(S)
    end.

-ifdef(TEST).
test_ordered_send_result(Conn, Sid, Frame) ->
    case erase(?TEST_ORDERED_FAILURE_KEY) of
        undefined ->
            send_once(Conn, Sid, Frame);
        Reason ->
            {error, Reason}
    end.
-endif.

enqueue_send(Item, S = #s{sendq = Q0}) ->
    drain_sends(S#s{sendq = sendq_in(Item, Q0)}).

%% Try each accepted frame once. Transient QUIC refusal parks the FIFO head;
%% progress resumes only from the transport's send_ready message. There is no
%% retry loop and the link remains free to receive data, close, and DOWN events.
drain_sends(S = #s{send_wait = {_Token, _TimerRef}}) ->
    S;
drain_sends(S = #s{sendq = Q0}) ->
    case sendq_head(Q0) of
        empty ->
            S;
        {value, Item, Q} ->
            case send_item(Item, S) of
                ok ->
                    Q1 = sendq_drop(Q),
                    drain_sends(sent_item(Item, S#s{sendq = Q1}));
                {blocked, best_effort, Reason} ->
                    count_drop(Reason, S),
                    Q1 = sendq_drop(Q),
                    drain_sends(S#s{sendq = Q1});
                {blocked, _Protected, _Reason} ->
                    park_send(Item, S#s{sendq = Q});
                {error, ordered, Reason} ->
                    ordered_send_failed(Reason, S);
                {error, best_effort, Reason} ->
                    count_drop(Reason, S),
                    Q1 = sendq_drop(Q),
                    drain_sends(S#s{sendq = Q1});
                {error, reliable, Reason} ->
                    reliable_result(Item, {error, Reason}),
                    Q1 = sendq_drop(Q),
                    drain_sends(S#s{sendq = Q1})
            end
    end.

%% Local two-list FIFO.  This is intentionally owned here rather than
%% pattern-matching `queue`'s opaque representation: the link needs only four
%% operations, and Dialyzer must be able to verify every stream-reset cleanup.
sendq_in(Item, {Front, Rear}) ->
    {Front, [Item | Rear]}.

sendq_head({[], []}) ->
    empty;
sendq_head({[], Rear}) ->
    sendq_head({lists:reverse(Rear), []});
sendq_head(Q = {[Item | _], _Rear}) ->
    {value, Item, Q}.

sendq_drop({[_Item | Rest], Rear}) ->
    {Rest, Rear}.

sendq_to_list({Front, Rear}) ->
    Front ++ lists:reverse(Rear).

send_item({ordered, Frame}, #s{conn = Conn, sid = Sid}) ->
    classify_send(ordered, ?ORDERED_SEND_RESULT(Conn, Sid, Frame));
send_item({ordered, Frame, _Receipt}, #s{conn = Conn, sid = Sid}) ->
    classify_send(ordered, ?ORDERED_SEND_RESULT(Conn, Sid, Frame));
send_item({best_effort, Frame}, #s{conn = Conn, sid = Sid}) ->
    classify_send(best_effort, send_once(Conn, Sid, Frame));
send_item({reliable, _From, _Ref, Frame, Deadline},
          #s{conn = Conn, sid = Sid}) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        true -> classify_send(reliable, send_once(Conn, Sid, Frame));
        false -> {error, reliable, backpressure_timeout}
    end.

send_once(Conn, Sid, Frame) ->
    case catch quic:send_data(Conn, Sid, Frame, false) of
        ok -> ok;
        {error, Reason} -> {error, Reason};
        {'EXIT', Reason} -> {error, Reason}
    end.

classify_send(_Kind, ok) ->
    ok;
classify_send(Kind, {error, {flow_control_blocked, _} = Reason}) ->
    {blocked, Kind, Reason};
classify_send(Kind, {error, send_queue_full}) ->
    {blocked, Kind, send_queue_full};
classify_send(Kind, {error, Reason}) ->
    {error, Kind, Reason}.

sent_item({reliable, From, Ref, _Frame, _Deadline}, S) ->
    From ! {Ref, ok},
    S;
sent_item({ordered, _Frame, Receipt}, S) ->
    catchup_send_accepted(Receipt, S);
sent_item(_Item, S) ->
    S.

reliable_result({reliable, From, Ref, _Frame, _Deadline}, Result) ->
    From ! {Ref, Result},
    ok;
reliable_result(_Item, _Result) ->
    ok.

park_send(Item, S) ->
    Delay = send_silence_timeout(Item),
    Token = make_ref(),
    TimerRef = erlang:send_after(Delay, self(), {send_deadline, Token}),
    S#s{send_wait = {Token, TimerRef}}.

send_silence_timeout({ordered, _Frame}) ->
    %% Reuse the operator-owned transport failure bound. Normal progress wakes
    %% this link through send_ready; this is only the final silent-transport
    %% safeguard and must not become a short polling/retry cadence.
    maps:get(idle_timeout, quod_quic:liveness_opts());
send_silence_timeout({ordered, _Frame, _Receipt}) ->
    maps:get(idle_timeout, quod_quic:liveness_opts());
send_silence_timeout({reliable, _From, _Ref, _Frame, Deadline}) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

resume_sends(S = #s{send_wait = none}) ->
    S;
resume_sends(S) ->
    cancel_send_timer(S),
    drain_sends(S#s{send_wait = none}).

send_deadline(Token, S = #s{send_wait = {Token, _TimerRef}, sendq = Q0}) ->
    case sendq_head(Q0) of
        {value, {ordered, _Frame, _Receipt}, Q} ->
            ordered_send_failed(backpressure_timeout,
                                S#s{sendq = Q, send_wait = none});
        {value, {ordered, _Frame}, Q} ->
            ordered_send_failed(backpressure_timeout,
                                S#s{sendq = Q, send_wait = none});
        {value,
         {reliable, _From, _Ref, _Frame, _Deadline} = Item, Q} ->
            reliable_result(Item, {error, backpressure_timeout}),
            Q1 = sendq_drop(Q),
            drain_sends(S#s{sendq = Q1, send_wait = none});
        _ ->
            S#s{send_wait = none}
    end;
send_deadline(_StaleToken, S) ->
    S.

-spec ordered_send_failed(term(), #s{}) -> no_return().
ordered_send_failed(Reason, S = #s{conn = Conn, sid = Sid}) ->
    count_drop(Reason, S),
    reply_queued_reliable({error, {ordered_send_failed, Reason}}, S),
    cancel_send_timer(S),
    _ = catch quic:reset_stream(Conn, Sid, 0),
    exit({ordered_send_failed, Reason}).

reply_queued_reliable(Result, #s{sendq = Q}) ->
    lists:foreach(
      fun(Item) -> reliable_result(Item, Result) end,
      sendq_to_list(Q)),
    ok.

count_drop(Reason, #s{peer = Peer, channel = Channel}) ->
    _ = quod_metrics:count_link_send_drop(Peer, Channel, Reason),
    ok.

cancel_send_timer(#s{send_wait = {_Token, TimerRef}}) ->
    _ = erlang:cancel_timer(TimerRef, [{async, false}, {info, false}]),
    ok;
cancel_send_timer(#s{send_wait = none}) ->
    ok.

%% append bytes, publish every complete payload frame, keep the remainder
loop_msgs(Data, S = #s{buf = Buf, catchup = #credit{}}) ->
    catchup_frames(S#s{buf = <<Buf/binary, Data/binary>>});
loop_msgs(Data, S = #s{buf = Buf, peer = Peer, channel = Ch}) ->
    case parse(<<Buf/binary, Data/binary>>) of
        {error, oversized} -> exit({frame_too_large, Ch});
        {Frames, Buf1} ->
            lists:foreach(
              fun(Payload) -> publish(Peer, Ch, Payload) end,
              Frames),
            S#s{buf = Buf1}
    end.

%% Catch-up gates one frame before parsing/publication of its successor. A
%% malicious batch can therefore admit only the one granted operation.
catchup_frames(S = #s{buf = Buf, catchup = #credit{ns = Ns}}) ->
    case parse_one(Buf) of
        more -> S;
        {error, oversized} -> protocol_failed(frame_too_large, S);
        {ok, Payload, Rest} ->
            case quod_catchup:decode_frame(Ns, Payload) of
                {ok, Control, _Bytes} ->
                    catchup_frames(catchup_control(Control, S#s{buf = Rest}));
                {error, _} -> protocol_failed(invalid_catchup_frame, S)
            end
    end.

catchup_channel(Channel, Role) ->
    case quod_safe_term:decode_wrapped(Channel, 16#FFFF) of
        {ok, {catchup, Ns}} when is_binary(Ns), byte_size(Ns) > 0 ->
            #credit{ns = Ns, role = Role};
        _ -> none
    end.

require_generic_channel(#s{catchup = none}) -> ok;
require_generic_channel(S) -> protocol_failed(uncredited_local_send, S).

bind_producer(Producer, BindingRef,
              S = #s{catchup = C = #credit{role = requester, owner = none}})
  when is_pid(Producer), is_reference(BindingRef) ->
    MRef = erlang:monitor(process, Producer),
    Producer ! {catchup_credit, self(), BindingRef, C#credit.grant},
    S#s{catchup = C#credit{owner = {Producer, MRef}, binding = BindingRef}};
bind_producer(Producer, BindingRef,
              S = #s{catchup = #credit{role = requester,
                                       owner = {Producer, _MRef},
                                       binding = BindingRef}}) ->
    %% No repeated callback: re-open/bind messages cannot duplicate credit.
    S;
bind_producer(_Producer, _BindingRef, S = #s{catchup = #credit{role = requester}}) ->
    protocol_failed(catchup_producer_replaced, S);
bind_producer(_Producer, _BindingRef, S) -> S.

submit_page(Producer, BindingRef, Grant, ReqId, From, To,
            S = #s{catchup = C = #credit{role = requester, ns = Ns,
                                         owner = {Producer, _MRef},
                                         binding = BindingRef, grant = Grant,
                                         pending = none}})
  when is_binary(Grant), byte_size(Grant) =:= 16 ->
    Payload = quod_catchup:encode_frame(Ns, {blocks_req, Grant, ReqId, From, To}),
    S1 = S#s{catchup = C#credit{grant = none, pending = {Grant, ReqId}}},
    enqueue_send({ordered, frame(Payload), request_accepted}, S1);
submit_page(_Producer, _BindingRef, _Grant, _ReqId, _From, _To, S) ->
    %% Late controls belong to their original binding, never a replacement.
    S.

catchup_control({blocks_req, Grant, ReqId, From, To},
                S = #s{catchup = C = #credit{role = server, ns = Ns,
                                             grant = Grant, pending = none}})
  when is_binary(Grant) ->
    StartedMs = quod_time:mono_ms(),
    OperationRef = make_ref(),
    C1 = C#credit{grant = none, pending = {OperationRef, Grant, ReqId, reading}},
    case quod_reg:where({quod_catchup, Ns}) of
        Owner when is_pid(Owner) ->
            MRef = erlang:monitor(process, Owner),
            Owner ! {catchup_request, self(), OperationRef, From, To, StartedMs},
            S#s{catchup = C1#credit{owner = {Owner, MRef}}};
        undefined ->
            queue_page_response({error, not_ready}, S#s{catchup = C1})
    end;
catchup_control({blocks_resp_bytes, Grant, ReqId, Blobs, Height, Next}, S) ->
    accept_page(Grant, ReqId, {ok, Blobs, Height}, Next, S);
catchup_control({blocks_err, Grant, ReqId, Reason, Next}, S) ->
    accept_page(Grant, ReqId, {error, Reason}, Next, S);
catchup_control(_Control, S) -> protocol_failed(catchup_credit_violation, S).

accept_page(Grant, ReqId, Result, Next,
            S = #s{catchup = C = #credit{role = requester,
                                         owner = {Producer, _MRef},
                                         binding = BindingRef,
                                         pending = {Grant, ReqId}}})
  when Next =/= Grant ->
    Producer ! {catchup_page, self(), BindingRef, Grant, ReqId, Result, Next},
    S#s{catchup = C#credit{grant = Next, pending = none}};
accept_page(_Grant, _ReqId, _Result, _Next, S) ->
    protocol_failed(catchup_response_violation, S).

complete_server_page(Owner, OperationRef, Result,
                     S = #s{catchup = #credit{role = server,
                          owner = {Owner, _MRef},
                          pending = {OperationRef, _Grant, _ReqId, reading}}}) ->
    queue_page_response(Result, S);
complete_server_page(_Owner, _OperationRef, _Result, S) -> S.

queue_page_response(Result,
                    S = #s{catchup = C = #credit{ns = Ns,
                           pending = {OperationRef, Grant, ReqId, reading}}}) ->
    Next = fresh_grant(Grant),
    Control = case Result of
                  {ok, Blobs, Height} ->
                      {blocks_resp_bytes, Grant, ReqId, Blobs, Height, Next};
                  {error, Reason} when Reason =:= not_ready; Reason =:= server_error ->
                      {blocks_err, Grant, ReqId, Reason, Next}
              end,
    Payload = quod_catchup:encode_frame(Ns, Control),
    S1 = S#s{catchup = C#credit{pending = {OperationRef, Grant, ReqId, sending}}},
    enqueue_send({ordered, frame(Payload), {page_sent, OperationRef, Next}}, S1).

catchup_send_accepted({initial_credit, Grant}, S = #s{catchup = C}) ->
    S#s{catchup = C#credit{grant = Grant}};
catchup_send_accepted(request_accepted, S) -> S;
catchup_send_accepted({page_sent, OperationRef, Next}, S = #s{catchup = C}) ->
    _ = case C#credit.owner of
        {Owner, MRef} ->
            _ = erlang:demonitor(MRef, [flush]),
            Owner ! {catchup_page_sent, self(), OperationRef};
        none -> ok
    end,
    S#s{catchup = C#credit{grant = Next, owner = none, pending = none}}.

fresh_grant(Previous) ->
    case crypto:strong_rand_bytes(16) of
        Previous -> fresh_grant(Previous);
        Grant -> Grant
    end.

-spec protocol_failed(term(), #s{}) -> no_return().
protocol_failed(Reason, S = #s{conn = Conn, sid = Sid}) ->
    cancel_send_timer(S),
    reply_queued_reliable({error, Reason}, S),
    _ = catch quic:reset_stream(Conn, Sid, 0),
    exit(Reason).

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

parse_one(<<PLen:32, _/binary>>) when PLen > ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    {error, oversized};
parse_one(<<PLen:32, Payload:PLen/binary, Rest/binary>>) ->
    {ok, Payload, Rest};
parse_one(_Bin) -> more.

parse(Bin) -> parse(Bin, []).
parse(<<PLen:32, _/binary>>, _Acc)
  when PLen > ?QUOD_TRANSPORT_MAX_FRAME_BYTES -> {error, oversized};
parse(<<PLen:32, Rest/binary>> = Bin, Acc) ->
    case Rest of
        <<Payload:PLen/binary, Tail/binary>> -> parse(Tail, [Payload | Acc]);
        _ -> {lists:reverse(Acc), Bin}
    end;
parse(Bin, Acc) -> {lists:reverse(Acc), Bin}.
