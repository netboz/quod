-module(quod_prove).
-moduledoc """
Per-namespace **remote-read** endpoint — the path by which a node that is NOT on a namespace's
consensus committee reads it without going through consensus (the Subscriber/Neither read path of the
reader/subscriber layer).

Two halves in one `gen_server`, riding a dedicated **`{prove, Ns}`** `quod_link` channel (separate
from `quod_simplex`'s `{log, Ns}` — the channel-match hazard):

- **Responder** (on a Member/Replica that holds the kb): serves a `{prove_req, ...}` against the
  local committed kb via `quod_prolog:prove_ro/3` (READ-ONLY — a write goal is refused, so a remote
  reader can never write through a Member). Each request runs in a worker so a slow prove never
  blocks the endpoint; concurrency is capped (`?MAX_INFLIGHT`) as a hostile-net bound.
- **Client** (any reader): `remote/4,5` sends a `{prove_req, ...}` to a contact Replica/Member and
  awaits the `{prove_resp, ...}`.

**Freshness contract:** the response carries the committed log height the answer was proved at.
Reads are eventual / bounded-stale; `MinHeight` gives read-your-writes — a responder whose applied
height is below `MinHeight` replies `stale` so the caller retries a fresher peer.

**Trust (P1):** reads are open (content is gated per-clause by `can_read`); the inner record decodes
without `[safe]` — same trusted-fleet posture as `quod_simplex` today. Authenticated/​rate-limited
remote reads on a hostile network arrive with the identity milestone.
""".
-behaviour(gen_server).
-include("quod_ledger.hrl").

-export([start_link/2, remote/4, remote/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(REQ_TIMEOUT_MS, 5000).
-define(MAX_INFLIGHT,   64).            %% responder: concurrent prove workers (bound prove-flood CPU)
-define(MAX_FRAME_BYTES, (1 bsl 20)).  %% drop frames larger than 1 MiB before decode (bound memory).
                                       %% A prove result above this is unsupported (chunking is future).

-record(s, {ns       :: binary(),
            self     :: node_id(),
            chan     :: binary(),                      %% term_to_binary({prove, Ns}, [deterministic])
            contacts = []  :: [endpoint()],          %% default responder candidates (seed endpoints)
            pending  = #{} :: #{reference() => {gen_server:from(), reference()}},  %% client: ReqId => {From, TRef}
            inflight = 0   :: non_neg_integer()}).      %% responder: live prove workers

%%%===================================================================
%%% API
%%%===================================================================

start_link(Ns, Config) ->
    gen_server:start_link(quod_reg:via({quod_prove, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Remote-read `Goal` against `Ns` via a default contact. `MinHeight` = read-your-writes floor.".
-spec remote(binary(), term(), binary(), log_index()) ->
        {ok, [map()], log_index()} | fail | {stale, log_index()} | {error, term()}.
remote(Ns, Goal, CallerNs, MinHeight) -> remote(Ns, Goal, CallerNs, MinHeight, undefined).

-doc "As `remote/4` but against an explicit contact Replica/Member `{Host, Port}`.".
-spec remote(binary(), term(), binary(), log_index(), endpoint() | undefined) ->
        {ok, [map()], log_index()} | fail | {stale, log_index()} | {error, term()}.
remote(Ns, Goal, CallerNs, MinHeight, Contact) ->
    case quod_reg:where({quod_prove, Ns}) of
        undefined -> {error, no_prove_endpoint};
        Pid -> try gen_server:call(Pid, {remote, Goal, CallerNs, MinHeight, Contact}, ?REQ_TIMEOUT_MS + 1000)
               catch exit:_ -> {error, timeout} end
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    Self = maps:get(node_id, Config),
    Chan = term_to_binary({prove, Ns}, [deterministic]),
    quod_reg:subscribe({channel, Chan}),
    {ok, #s{ns = Ns, self = Self, chan = Chan, contacts = maps:get(seed_peers, Config, [])}}.

handle_call({remote, Goal, CallerNs, MinHeight, Contact0}, From, S) ->
    case (case Contact0 of undefined -> pick_contact(S); C -> C end) of
        none    -> {reply, {error, no_contact}, S};
        Contact ->
            ReqId = make_ref(),
            TRef  = erlang:send_after(?REQ_TIMEOUT_MS, self(), {req_timeout, ReqId}),
            S1    = send(Contact, {prove_req, ReqId, Goal, CallerNs, MinHeight}, S),
            {noreply, S1#s{pending = (S1#s.pending)#{ReqId => {From, TRef}}}}
    end;
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast({send_resp, Peer, Resp}, S) ->
    {noreply, (send(Peer, Resp, S))#s{inflight = max(0, S#s.inflight - 1)}};
handle_cast(_Msg, S) -> {noreply, S}.

handle_info({quod_message, {{Peer, _Addr}, _In}, Chan, Payload}, S = #s{chan = Chan}) ->
    {noreply, inbound(Peer, Payload, S)};   %% Peer = the reader's node_id (header pubkey)
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
    %% envelope is [safe] (known atoms only); the inner record carries Prolog terms (atoms the
    %% receiver may not have seen) so it decodes WITHOUT [safe] — trusted-fleet posture (P1).
    try binary_to_term(Payload, [safe]) of
        {prove, Ns, Bin} when Ns =:= S#s.ns ->
            try route(Peer, binary_to_term(Bin), S) catch _:_ -> S end;
        _ -> S
    catch _:_ -> S end.

route(Peer, {prove_req, ReqId, Goal, CallerNs, MinHeight}, S) ->
    handle_req(Peer, ReqId, Goal, CallerNs, MinHeight, S);
route(_Peer, {prove_resp, ReqId, Result, Height}, S) ->
    handle_resp(ReqId, Result, Height, S);
route(_Peer, _Other, S) -> S.

%% Responder: serve a read against the local kb in a worker (never block; concurrency-capped).
%% No local kb (a client-only node) or over the cap ⇒ drop; the client times out and retries.
handle_req(Peer, ReqId, Goal, CallerNs, MinHeight, S = #s{ns = Ns}) ->
    case (quod_reg:where({quod_prolog, Ns}) =/= undefined) andalso S#s.inflight < ?MAX_INFLIGHT of
        false -> S;
        true  ->
            Self = self(),
            %% the worker ALWAYS casts a response back (try/catch), so inflight is always
            %% decremented even if serve/5 somehow throws — no leak that would pin the cap.
            _ = spawn(fun() ->
                          Resp = try serve(Ns, ReqId, Goal, CallerNs, MinHeight)
                                 catch _:_ -> {prove_resp, ReqId, {error, internal}, 0} end,
                          gen_server:cast(Self, {send_resp, Peer, Resp})
                      end),
            S#s{inflight = S#s.inflight + 1}
    end.

serve(Ns, ReqId, Goal, CallerNs, MinHeight) ->
    H0 = quod_prolog:applied(Ns),   %% snapshot the freshness height once
    case H0 >= MinHeight of
        false -> {prove_resp, ReqId, stale, H0};
        true  ->
            case quod_prolog:prove_ro(Ns, Goal, CallerNs) of
                {ok, Bs, H}     -> {prove_resp, ReqId, {ok, Bs}, H};
                fail            -> {prove_resp, ReqId, fail, H0};
                {error, Reason} -> {prove_resp, ReqId, {error, Reason}, H0}
            end
    end.

%% Client: match a response to its parked caller and reply with the freshness height.
handle_resp(ReqId, Result, Height, S) ->
    case maps:take(ReqId, S#s.pending) of
        {{From, TRef}, P1} ->
            _ = erlang:cancel_timer(TRef),
            gen_server:reply(From, to_result(Result, Height)),
            S#s{pending = P1};
        error -> S   %% unknown / already-timed-out ReqId
    end.

to_result({ok, Bs}, H)    -> {ok, Bs, H};
to_result(fail, _H)       -> fail;
to_result(stale, H)       -> {stale, H};
to_result({error, R}, _H) -> {error, R}.

%%%===================================================================
%%% transport
%%%===================================================================

%% Fire-and-forget send on our {prove, Ns} channel — the transport (`quod_quic:send/3`) owns the link
%% (dial on demand, buffer until ready, reuse). A dropped frame just times out the request and it retries.
send(Peer, Term, S = #s{ns = Ns, chan = Chan}) ->
    _ = quod_quic:send(Peer, Chan, term_to_binary({prove, Ns, term_to_binary(Term)})),
    S.

pick_contact(#s{contacts = []})      -> none;
pick_contact(#s{contacts = [C | _]}) -> C.
