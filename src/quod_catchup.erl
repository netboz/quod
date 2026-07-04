-module(quod_catchup).
-moduledoc """
Per-namespace **catch-up** endpoint — the path by which a joining node pulls the committed block log
(each block with the quorum certificate that finalized it) so it can **trustlessly** replay a namespace it
was not present for (`mode=join`, Simplex 4).

Two halves in one `gen_server`, riding a dedicated **`{catchup, Ns}`** `quod_link` channel (separate from
`quod_simplex`'s `{log, Ns}` and `quod_prove`'s `{prove, Ns}` — the channel-match hazard):

- **Server** (any Member holding the durable log): serves a `{blocks_req, From, To}` by reading the
  committed `#entry{}` range from the store via `quod_ledger_store:open_ro/2` — a **read-only,
  non-truncating** handle opened alongside the live writer, so a slow/large pull never touches the
  consensus `gen_statem` and never corrupts the log. Each request runs in a worker; concurrency + range +
  frame size are bounded (hostile-net + memory caps).
- **Client** (a joiner): `pull/3,4` requests `[From, To]` from a contact Member and awaits the entries.
  The caller (`mode=join` init) drives the loop and **verifies each block's cert** against the committee it
  reconstructs — the server is never trusted (the certificate is the proof).

**Trust (trusted-fleet P1):** the inner record decodes without `[safe]` — same posture as `quod_simplex` /
`quod_prove`. Trustlessness comes from cert verification at the caller, not from trusting this transport.
""".
-behaviour(gen_server).
-include("quod_ledger.hrl").

-export([start_link/2, pull/3, pull/4, serve_blocks/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(REQ_TIMEOUT_MS,  8000).
-define(MAX_INFLIGHT,    32).            %% server: concurrent read workers (bound a pull-flood)
-define(MAX_BLOCKS,      256).           %% server: max entries served per request (a coarse count cap)
-define(RESP_BUDGET,     (900 bsl 10)).  %% server: byte budget for the served entries — the whole response
                                         %% frame MUST fit quod_link's 1 MiB cap (it EXITs the link on a
                                         %% larger frame), so we leave headroom for the envelope
-define(MAX_FRAME_BYTES, (1 bsl 20)).    %% drop an inbound frame ≥ 1 MiB before decode (matches quod_link)

-record(s, {ns       :: binary(),
            self     :: node_id(),
            chan     :: binary(),                       %% term_to_binary({catchup, Ns}, [deterministic])
            data_dir :: file:filename_all(),
            contacts = []  :: [endpoint()],             %% seed endpoints a joiner pulls from
            conns    = #{} :: #{node_id() | endpoint() => {pid(), reference()}},   %% OUTBOUND links
            outbox   = #{} :: #{node_id() | endpoint() => [binary()]},             %% per-peer FIFO
            pending  = #{} :: #{reference() => {gen_server:from(), reference()}},  %% client: ReqId=>{From,TRef}
            inflight = 0   :: non_neg_integer()}).       %% server: live read workers

%%%===================================================================
%%% API
%%%===================================================================

start_link(Ns, Config) ->
    gen_server:start_link(quod_reg:via({quod_catchup, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Pull committed entries `[From, To]` from a default seed contact.".
-spec pull(binary(), pos_integer(), log_index()) ->
        {ok, [#entry{}], log_index()} | {error, term()}.
pull(Ns, From, To) -> pull(Ns, From, To, undefined).

-doc "As `pull/3` but from an explicit contact `{Host, Port}`. Returns the entries + the server's height.".
-spec pull(binary(), pos_integer(), log_index(), endpoint() | undefined) ->
        {ok, [#entry{}], log_index()} | {error, term()}.
pull(Ns, From, To, Contact) ->
    case quod_reg:where({quod_catchup, Ns}) of
        undefined -> {error, no_catchup_endpoint};
        Pid -> try gen_server:call(Pid, {pull, From, To, Contact}, ?REQ_TIMEOUT_MS + 1000)
               catch exit:_ -> {error, timeout} end
    end.

-doc """
Read the committed `#entry{}` range `[From, To]` (capped to `?MAX_BLOCKS` and the readable height) from a
READ-ONLY store view. Returns the entries + the server's current committed height. Used by the server
worker; pure w.r.t. the gen_server (opens/closes its own handle).
""".
-spec serve_blocks(binary(), file:filename_all(), pos_integer(), log_index()) ->
        {ok, [#entry{}], log_index()} | {error, term()}.
serve_blocks(Ns, DataDir, From0, To) ->
    From = max(1, From0),
    case quod_ledger_store:open_ro(Ns, DataDir) of
        {error, _} = E -> E;
        {ok, Store}    ->
            try
                {LastI, _} = quod_ledger_store:last(Store),
                To1 = lists:min([To, LastI, From + ?MAX_BLOCKS - 1]),
                {ok, Es} = quod_ledger_store:read_range(Store, From, To1),
                {ok, cap_bytes(Es, 0), LastI}   %% keep the response within one quod_link frame
            catch _:R -> {error, R}
            after quod_ledger_store:close(Store)
            end
    end.

%% The longest PREFIX of `Es` whose serialized size stays within ?RESP_BUDGET, so the whole response frame
%% fits quod_link's 1 MiB cap (it EXITs the link on a larger frame). Always keeps ≥ 1 entry so a joiner
%% makes progress and loops for the rest; a lone entry over budget is a genuinely oversized block that
%% needs chunking (deferred) — degenerate, not the common path.
cap_bytes([], _Acc) -> [];
cap_bytes([E | Rest], Acc) ->
    Acc1 = Acc + byte_size(term_to_binary(E, [deterministic])),
    case Acc =:= 0 orelse Acc1 =< ?RESP_BUDGET of
        true  -> [E | cap_bytes(Rest, Acc1)];
        false -> []
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    Self = maps:get(node_id, Config),
    Chan = term_to_binary({catchup, Ns}, [deterministic]),
    quod_reg:subscribe({channel, Chan}),
    {ok, #s{ns = Ns, self = Self, chan = Chan,
            data_dir = data_dir(Config), contacts = maps:get(seed_peers, Config, [])}}.

handle_call({pull, From, To, Contact0}, ReplyTo, S) ->
    case (case Contact0 of undefined -> pick_contact(S); C -> C end) of
        none    -> {reply, {error, no_contact}, S};
        Contact ->
            ReqId = make_ref(),
            TRef  = erlang:send_after(?REQ_TIMEOUT_MS, self(), {req_timeout, ReqId}),
            S1    = send(Contact, {blocks_req, ReqId, From, To}, S),
            {noreply, S1#s{pending = (S1#s.pending)#{ReqId => {ReplyTo, TRef}}}}
    end;
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast({send_resp, Peer, Resp}, S) ->
    {noreply, (send(Peer, Resp, S))#s{inflight = max(0, S#s.inflight - 1)}};
handle_cast(_Msg, S) -> {noreply, S}.

handle_info({link_up, Peer, Chan, LinkPid}, S = #s{chan = Chan}) ->
    case maps:is_key(Peer, S#s.conns) of
        true  -> _ = quod_link:close(LinkPid), {noreply, S};
        false ->
            Ref = erlang:monitor(process, LinkPid),
            S1  = S#s{conns = (S#s.conns)#{Peer => {LinkPid, Ref}}},
            _   = [quod_link:send(LinkPid, F) || F <- maps:get(Peer, S1#s.outbox, [])],
            {noreply, S1#s{outbox = maps:remove(Peer, S1#s.outbox)}}
    end;
handle_info({link_error, Peer, Chan}, S = #s{chan = Chan}) ->
    {noreply, S#s{outbox = maps:remove(Peer, S#s.outbox)}};
handle_info({'DOWN', _Ref, process, LinkPid, _Reason}, S) ->
    {noreply, drop_conn(LinkPid, S)};
handle_info({quod_message, {{Peer, _Addr}, _In}, Chan, Payload}, S = #s{chan = Chan}) ->
    {noreply, inbound(Peer, Payload, S)};
handle_info({quod_message, _, _OtherChan, _}, S) -> {noreply, S};
handle_info({req_timeout, ReqId}, S) ->
    case maps:take(ReqId, S#s.pending) of
        {{From, _TRef}, P1} -> gen_server:reply(From, {error, timeout}), {noreply, S#s{pending = P1}};
        error               -> {noreply, S}
    end;
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #s{chan = Chan}) ->
    _ = try quod_reg:unsubscribe({channel, Chan}) catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% wire / dispatch
%%%===================================================================

inbound(_Peer, Payload, S) when byte_size(Payload) > ?MAX_FRAME_BYTES ->
    S;   %% drop an oversized frame BEFORE decoding — bound binary_to_term memory (hostile peer)
inbound(Peer, Payload, S) ->
    try binary_to_term(Payload, [safe]) of
        {catchup, Ns, Bin} when Ns =:= S#s.ns ->
            try route(Peer, binary_to_term(Bin), S) catch _:_ -> S end;
        _ -> S
    catch _:_ -> S end.

route(Peer, {blocks_req, ReqId, From, To}, S) -> handle_req(Peer, ReqId, From, To, S);
route(_Peer, {blocks_resp, ReqId, Entries, Height}, S) -> handle_resp(ReqId, Entries, Height, S);
route(_Peer, {blocks_err, ReqId}, S) -> handle_err(ReqId, S);
route(_Peer, _Other, S) -> S.

%% Server: read the requested range in a worker (never block the endpoint; concurrency-capped). Over the
%% cap ⇒ drop; the client times out and retries a fresher/other peer.
handle_req(Peer, ReqId, From, To, S = #s{ns = Ns, data_dir = Dir}) when is_integer(From), is_integer(To) ->
    case S#s.inflight < ?MAX_INFLIGHT of
        false -> S;
        true  ->
            Self = self(),
            %% The worker ALWAYS casts a response (whole body in try/catch), so `inflight` is decremented
            %% even if serve_blocks throws — otherwise a crashed worker would leak a slot and, after
            %% ?MAX_INFLIGHT such crashes, wedge the endpoint. An error sends a distinct `blocks_err` (never
            %% a misleading empty `{[], 0}` that a joiner would read as "namespace empty").
            _ = spawn(fun() ->
                          Resp = try case serve_blocks(Ns, Dir, From, To) of
                                          {ok, Es, H} -> {blocks_resp, ReqId, Es, H};
                                          {error, _}  -> {blocks_err, ReqId}
                                      end
                                 catch _:_ -> {blocks_err, ReqId}
                                 end,
                          gen_server:cast(Self, {send_resp, Peer, Resp})
                      end),
            S#s{inflight = S#s.inflight + 1}
    end;
handle_req(_Peer, _ReqId, _From, _To, S) -> S.   %% malformed range ⇒ drop

%% Client: match a response to its parked caller.
handle_resp(ReqId, Entries, Height, S) ->
    reply_pending(ReqId, {ok, Entries, Height}, S).

%% Client: the server hit a read error (distinct from an empty log) — fail the pull so the caller retries
%% another contact rather than concluding the namespace is empty.
handle_err(ReqId, S) ->
    reply_pending(ReqId, {error, server_error}, S).

reply_pending(ReqId, Reply, S) ->
    case maps:take(ReqId, S#s.pending) of
        {{From, TRef}, P1} ->
            _ = erlang:cancel_timer(TRef),
            gen_server:reply(From, Reply),
            S#s{pending = P1};
        error -> S   %% unknown / already-timed-out ReqId
    end.

%%%===================================================================
%%% transport (symmetric: we always send on our OWN outbound link)
%%%===================================================================

send(Peer, Term, S = #s{ns = Ns, conns = Conns, outbox = Outbox}) ->
    Frame = term_to_binary({catchup, Ns, term_to_binary(Term)}),
    case maps:get(Peer, Conns, undefined) of
        {LinkPid, _Ref} -> _ = quod_link:send(LinkPid, Frame), S;
        undefined ->
            Buf = maps:get(Peer, Outbox, []),
            _ = case Buf of [] -> quod_quic:open_link(Peer, S#s.chan); _ -> ok end,
            S#s{outbox = Outbox#{Peer => Buf ++ [Frame]}}
    end.

drop_conn(LinkPid, S = #s{conns = Conns}) ->
    case [P || {P, {Pid, _}} <- maps:to_list(Conns), Pid =:= LinkPid] of
        [Peer | _] -> {_Pid, Ref} = maps:get(Peer, Conns),
                      _ = erlang:demonitor(Ref, [flush]),
                      S#s{conns = maps:remove(Peer, Conns)};
        []         -> S
    end.

pick_contact(#s{contacts = []})      -> none;
pick_contact(#s{contacts = [C | _]}) -> C.

data_dir(Config) ->
    case maps:get(data_dir, Config, undefined) of
        undefined -> filename:join(filename:basedir(user_cache, "quod"), "data");
        Dir       -> Dir
    end.
