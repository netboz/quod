-module(quod_brahms).
-moduledoc """
Brahms membership for one namespace (ontology) — the View `V` + round driver.

One `gen_statem` per namespace `Ns`, registered `{quod_brahms, Ns}`, holding the
view `V` and the `m:quod_brahms_sampler` as inline state. Gossip for `Ns` flows
on channel `Ns`.

## A round

`idle` arms a jittered timer; on tick (`do_round/1`) it pushes its own id to
`α·ℓ` peers of `V` and pulls views from `β·ℓ` **disjoint** peers, then collects
responses and **reconstructs** `V` from `α·ℓ` pushes, `β·ℓ` pulls, and `γ·ℓ`
(always ≥1) sampler ids.

## Byzantine handling

- **Push is unsolicited** → *limited-push reception*: pushes are counted only
  while collecting; once past `push_limit` the push contribution is dropped for
  that round (pull + sample still rebuild V, so the sampler keeps healing it).
- **Pull is solicited** → a `pull_resp` is accepted only from a peer we actually
  pulled this round, and is capped to the pull quota; unsolicited responses are
  dropped.
- **Self-exclusion**, **never collapse to empty**, **defensive + size-capped
  decode**, **link cache pruned & closed** to the view each round.

Each cached link to a view peer is `erlang:monitor`ed; its `DOWN` *is* the
disconnect signal and evicts the peer at once (see `m:quod_link`).

## Sample validation (failure detector)

The min-wise sampler is **sticky** by design — a sampled id is retained until a
lower-hash id beats it — so a sampled node that dies (or, with dynamic ports,
restarts under a *new* id) would otherwise be re-dialed forever. Brahms closes
this with **sample validation**: each round we probe a few sampled ids whose
liveness is unknown (`probe_fanout` ids that are in the sample but not currently
linked) by opening a link to them. An id that does **not** come up within
`probe_rounds` is declared dead — every sampler slot holding it is
**reset to a fresh key** (`quod_brahms_sampler:invalidate/2`) and it is evicted
from `V`. A `link_up` (or any message from the peer) is the liveness proof. This
is the eviction half of the sampler's guarantee; without it, the very stickiness
that makes the sample attack-resistant would pin dead ids in place.

### Tombstones (beyond Brahms — SWIM-style)

Resetting our sample removes a dead id from *us*, but a peer that hasn't evicted
it yet re-gossips it back, so it re-enters, is re-probed, and is re-evicted —
wasteful churn until the whole fleet converges. Brahms does not address this (its
analysis is asymptotic; it only guarantees convergence). We borrow the **SWIM**
idea: a just-evicted id is **tombstoned** for `tombstone_rounds` and refused
re-admission from *third-party* gossip (push / pull bodies) during that window.
Only a **direct message that announces the id as its own sender** lifts the
tombstone (SWIM **refutation**). As everywhere in v1, this trusts the *announced*
node id — the gossip layer does not yet verify identity (see
`m:quod_brahms_sampler`'s sybil caveat) — so refutation is only as strong as that
announced identity; an authenticated-identity layer would tighten it. The
eviction it guards is sound w.r.t. Brahms: the detector evicts only on a probe
unanswered for `probe_rounds`, which a live node clears well within, so a live id
is evicted (and tombstoned) only on a rare timing miss, and that self-heals the
moment it next contacts us.

> #### Deferred {: .info }
>
> PUSH uses reliable streams; that optimisation comes later.
""".

-behaviour(gen_statem).

-export([start_namespace/2, start_link/2, view/1, sample/1, stats/1, namespaces/0]).
-export([init/1, callback_mode/0, terminate/3]).
-export([idle/3, collecting/3]).

-ifdef(TEST).
-export([split_counts/1, reconstruct/8, encode/1, decode/1, take_random/2, clean_resp/3,
         due_probes/3, probe_candidates/4, prune_tombstones/3]).
-endif.

-define(DEFAULTS,
        #{view_size   => 16,
          alpha       => 0.45,   %% push share
          beta        => 0.45,   %% pull share
          gamma       => 0.10,   %% sample share
          sample_size => 32,     %% sampler slots K
          round_ms    => 5000,
          collect_ms  => 1500,
          probe_fanout => 5,     %% cold ids liveness-probed per round (higher drains a churn backlog faster)
          probe_rounds => 2,     %% rounds to await a probe answer before evicting
          %% A just-evicted id is refused re-admission for this many rounds. It MUST
          %% exceed the backlog-drain time (~(view_size + sample_size) / probe_fanout
          %% rounds, ~10 here) with margin — otherwise, after a mass departure, an
          %% evicted id's tombstone expires before every peer has stopped gossiping
          %% it, so it re-circulates and re-evicts (non-converging churn).
          tombstone_rounds => 60,
          jitter      => 0.2}).

-define(MAX_GOSSIP_BYTES, 65536).  %% drop oversized gossip payloads before decode

-record(d, {ns         :: binary(),
            self       :: term(),
            cfg        :: map(),
            counts     :: {non_neg_integer(), non_neg_integer(), pos_integer()},
            push_limit :: pos_integer(),
            pull_limit :: pos_integer(),
            view    = [] :: [term()],
            sampler :: quod_brahms_sampler:sampler(),
            conns   = #{} :: #{term() => {pid(), reference(), out | in}},  %% NodeId => {LinkPid, MonRef, Origin}
            outbox  = #{} :: #{term() => binary()},  %% latest payload queued for a link being opened
            probing = #{} :: #{term() => non_neg_integer()},  %% NodeId => round the liveness probe was sent
            rounds  = 0  :: non_neg_integer(),   %% rounds driven (for metrics)
            evictions = 0 :: non_neg_integer(),  %% dead peers evicted by sample validation (metrics)
            tombstones = #{} :: #{term() => non_neg_integer()},  %% evicted id => round; refuse re-admission (SWIM-style)
            vpush   = [] :: [term()],
            vpull   = [] :: [term()],
            pushes  = 0  :: non_neg_integer(),
            pulled  = [] :: [term()]}).   %% peers we sent a pull_req to this round

%% ======================================================================
%% API
%% ======================================================================

-doc """
Start (join) Brahms membership for an ontology namespace `Ns`. `Config` needs
`node_id`; `seed_peers` is optional. Spawns a supervised per-namespace statem.
""".
-spec start_namespace(binary(), map()) -> supervisor:startchild_ret().
start_namespace(Ns, Config) ->
    supervisor:start_child(quod_reg:via({quod_brahms_sup, node}), [Ns, Config]).

-doc "Start the per-namespace statem (called by `m:quod_brahms_sup`, not directly).".
-spec start_link(binary(), map()) -> gen_statem:start_ret().
start_link(Ns, Config) ->
    gen_statem:start_link(quod_reg:via({quod_brahms, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Current view `V` of namespace `Ns` (degrades to `[]` if unavailable).".
-spec view(binary()) -> [term()].
view(Ns) -> call(Ns, get_view).

-doc "Current uniform sample of namespace `Ns` (degrades to `[]`).".
-spec sample(binary()) -> [term()].
sample(Ns) -> call(Ns, get_sample).

-doc "Counters for namespace `Ns`: view/sample sizes, live links, rounds driven.".
-spec stats(binary()) -> #{view => non_neg_integer(), sample => non_neg_integer(),
                           conns => non_neg_integer(), rounds => non_neg_integer(),
                           evictions => non_neg_integer(),
                           tombstones => non_neg_integer()} | undefined.
stats(Ns) ->
    try gen_statem:call(quod_reg:via({quod_brahms, Ns}), get_stats, 1000)
    catch exit:_ -> undefined
    end.

-doc "All namespaces with a running Brahms statem on this node.".
-spec namespaces() -> [binary()].
namespaces() ->
    gproc:select([{{{n, l, {quod_brahms, '$1'}}, '_', '_'}, [], ['$1']}]).

call(Ns, Req) ->
    try gen_statem:call(quod_reg:via({quod_brahms, Ns}), Req, 1000)
    catch exit:_ -> []
    end.

%% ======================================================================
%% gen_statem
%% ======================================================================

callback_mode() -> [state_functions].

init({Ns, Config}) ->
    Cfg = maps:merge(?DEFAULTS, Config),
    case valid_cfg(Config, Cfg) of
        ok ->
            Self  = maps:get(node_id, Config),
            Seeds = [P || P <- maps:get(seed_peers, Config, []), P =/= Self],
            K     = maps:get(sample_size, Cfg),
            {L1, L2, _L3} = Counts = split_counts(Cfg),
            PushLimit = maps:get(push_limit, Config, max(2, 2 * L1)),
            PullLimit = maps:get(pull_limit, Config, max(2, 2 * L2)),
            Sampler = quod_brahms_sampler:observe_all(Seeds, quod_brahms_sampler:new(K)),
            quod_reg:subscribe({channel, Ns}),
            D = #d{ns = Ns, self = Self, cfg = Cfg, counts = Counts,
                   push_limit = PushLimit, pull_limit = PullLimit,
                   view = Seeds, sampler = Sampler},
            {ok, idle, D, [{state_timeout, round_delay(Cfg), tick}]};
        {error, Reason} ->
            {stop, {bad_config, Reason}}
    end.

%% --- idle: between rounds; responsive but does not accumulate ------------
idle(state_timeout, tick, D0) ->
    D1 = do_round(D0),
    {next_state, collecting, D1,
     [{state_timeout, maps:get(collect_ms, D1#d.cfg), close}]};
idle(info, {quod_message, Peer, Ns, Payload}, D = #d{ns = Ns}) ->
    {keep_state, handle_inbound(Peer, Payload, idle, D)};
idle(EventType, Event, D) ->
    common(EventType, Event, D).

%% --- collecting: the round window ---------------------------------------
collecting(state_timeout, close, D0) ->
    D1 = reconstruct_and_update(D0),
    {next_state, idle, D1, [{state_timeout, round_delay(D1#d.cfg), tick}]};
collecting(info, {quod_message, Peer, Ns, Payload}, D = #d{ns = Ns}) ->
    {keep_state, handle_inbound(Peer, Payload, collecting, D)};
collecting(EventType, Event, D) ->
    common(EventType, Event, D).

%% --- shared --------------------------------------------------------------
%% a link we opened is ready: cache it (with a monitor) while its peer is in the
%% view; if it is not needed (out of view, or we already hold one) close it,
%% since we own this outbound link.
common(info, {link_up, NodeId, Ns, LinkPid}, D0 = #d{ns = Ns}) ->
    D = clear_probe(NodeId, D0),                        %% it came up -> proven alive
    case maybe_cache(NodeId, LinkPid, out, D) of
        {true, D1}  -> {keep_state, D1};               %% cached + flushed (buffer kept)
        {false, D1} -> _ = quod_link:close(LinkPid),    %% out of view / already held
                       {keep_state, D1}                 %% leave the buffer; prune handles ex-view
    end;
common(info, {link_error, NodeId, Ns}, D = #d{ns = Ns, outbox = Outbox}) ->
    %% A failed open is NOT proof of death: link_error also fires on TRANSIENT
    %% stream-open failures over a live connection (m:quod_conn — open_stream
    %% {error,_}, fail_pending), not just on a non-dialable id. So we do NOT evict
    %% here; we only clear the buffered send (retried next round). Eviction is
    %% decided solely by the probe-timeout path (resolve_probes), which grants a
    %% probe_rounds grace — and a genuinely dead id we probed stays in `probing`
    %% and is evicted there even though its link_error already arrived.
    {keep_state, D#d{outbox = maps:remove(NodeId, Outbox)}};
%% a cached link died. Evict it (pid-matched). If a send is still buffered for
%% that peer and it is still in the view, RE-OPEN now instead of waiting for the
%% next round tick — the buffer re-flushes on the new link. (Cleared within a
%% round by the next direct send, so this cannot storm; an idle link with nothing
%% buffered just dies and waits for the round.)
common(info, {'DOWN', _Ref, process, LinkPid, _Reason},
       D = #d{ns = Ns, conns = Conns, view = V, outbox = Outbox}) ->
    case take_conn(LinkPid, Conns) of
        {NodeId, Conns1} ->
            _ = case maps:is_key(NodeId, Outbox) andalso lists:member(NodeId, V) of
                    true  -> quod_quic:open_link(NodeId, Ns);
                    false -> ok
                end,
            {keep_state, D#d{conns = Conns1}};
        error ->
            {keep_state, D}
    end;
common({call, From}, get_view, D) ->
    {keep_state, D, [{reply, From, D#d.view}]};
common({call, From}, get_sample, D) ->
    {keep_state, D, [{reply, From, quod_brahms_sampler:sample(D#d.sampler)}]};
common({call, From}, get_stats, D) ->
    Stats = #{view       => length(D#d.view),
              sample     => length(quod_brahms_sampler:sample(D#d.sampler)),
              conns      => map_size(D#d.conns),
              rounds     => D#d.rounds,
              evictions  => D#d.evictions,
              tombstones => map_size(D#d.tombstones)},
    {keep_state, D, [{reply, From, Stats}]};
common(info, {quod_message, _, _OtherNs, _}, D) ->
    {keep_state, D};                               %% another namespace
common(_ET, _E, D) ->
    {keep_state, D}.

terminate(_Reason, _State, #d{ns = Ns}) ->
    try quod_reg:unsubscribe({channel, Ns})
    catch _:_ -> ok
    end,
    ok.

%% ======================================================================
%% round
%% ======================================================================

do_round(D0 = #d{self = Self, view = V, counts = {L1, L2, _}, cfg = Cfg}) ->
    R = D0#d.rounds + 1,
    D = D0#d{rounds = R,
             tombstones = prune_tombstones(D0#d.tombstones, R, maps:get(tombstone_rounds, Cfg))},
    {Push, Pull} = partition(L1, L2, V),           %% disjoint target sets
    PushBin = encode({push, Self}),                %% encode once, fan out
    PullBin = encode({pull_req, Self}),
    D1 = lists:foldl(fun(T, A) -> send_msg(T, PushBin, A) end, D, Push),
    D2 = lists:foldl(fun(T, A) -> send_msg(T, PullBin, A) end, D1, Pull),
    %% Brahms sample validation: retire probes that went unanswered (evict +
    %% reset sampler), then probe a fresh batch of cold sampled ids.
    D3 = resolve_probes(D2),
    D4 = start_probes(D3),
    D4#d{vpush = [], vpull = [], pushes = 0, pulled = Pull}.

handle_inbound(_Peer, Payload, _Mode, D) when byte_size(Payload) > ?MAX_GOSSIP_BYTES ->
    D;                                             %% oversized gossip -> drop
handle_inbound({RemoteNodeId, ReplyLink}, Payload, Mode, D0 = #d{self = Self, counts = {_, L2, _}}) ->
    %% a peer's link is bidirectional: cache it for our own sends so a peer pair
    %% shares ONE stream per channel (no separate dial-back). Hearing from a peer
    %% is also liveness proof: it answers any in-flight probe AND lifts any
    %% tombstone on the SENDER (SWIM refutation — only the node itself can prove
    %% it is alive; third-party gossip below cannot resurrect a tombstoned id).
    D = untombstone(RemoteNodeId,
                    clear_probe(RemoteNodeId, cache_inbound(RemoteNodeId, ReplyLink, D0))),
    case decode(Payload) of
        {push, Id} when Id =/= Self ->
            case tombstoned(Id, D) of
                true  -> D;                        %% a tombstoned (dead) id, re-gossiped -> ignore
                false -> D1 = observe(Id, D),      %% sampler sees every received id
                         case Mode of collecting -> accumulate_push(Id, D1); idle -> D1 end
            end;
        {pull_req, From} when From =/= Self ->
            reply_view(ReplyLink, D),              %% answer on the inbound link
            observe(From, D);
        {pull_resp, From, Ids} when is_list(Ids) ->
            %% accept only a response we solicited this round
            case lists:member(From, D#d.pulled) of
                true ->
                    %% drop tombstoned ids the responder is still re-gossiping
                    Clean = [I || I <- clean_resp(Ids, L2, Self), not tombstoned(I, D)],
                    D1 = observe_all(Clean, D),
                    case Mode of collecting -> accumulate_pull(Clean, D1); idle -> D1 end;
                false ->
                    D                              %% unsolicited -> drop
            end;
        _ ->
            D                                      %% bad/unknown -> drop
    end.

accumulate_push(Id, D = #d{push_limit = PL, pushes = P, vpush = Vpush}) ->
    P1 = P + 1,
    Vpush1 = case P1 =< PL of
                 true  -> [Id | Vpush];            %% limited push reception
                 false -> Vpush
             end,
    D#d{pushes = P1, vpush = Vpush1}.

accumulate_pull(Ids, D = #d{pull_limit = PL, vpull = Vpull}) ->
    D#d{vpull = lists:sublist(Ids ++ Vpull, PL)}.  %% bound the per-round pull pool

%% answer a pull on the very link the request arrived on (the stream is bidi).
reply_view(ReplyLink, #d{self = Self, view = V}) ->
    _ = quod_link:send(ReplyLink, encode({pull_resp, Self, V})),
    ok.

reconstruct_and_update(D = #d{counts = {L1, L2, L3}, cfg = Cfg, self = Self, view = OldV,
                              conns = Conns, vpush = Vpush, vpull = Vpull,
                              sampler = S, pushes = P, push_limit = PL}) ->
    Limited = P > PL,
    Sampled = quod_brahms_sampler:sample(S),
    NewV = reconstruct(OldV, Vpush, Vpull, Sampled, {L1, L2, L3},
                       maps:get(view_size, Cfg), Self, Limited),
    D#d{view = NewV,
        conns  = prune_conns(NewV, Conns),
        outbox = prune_outbox(NewV, D#d.outbox),       %% don't queue for ex-view peers
        vpush = [], vpull = [], pushes = 0, pulled = []}.

%% ======================================================================
%% pure logic (unit-tested)
%% ======================================================================

valid_cfg(Config, #{alpha := A, beta := B, gamma := G,
                    view_size := VS, sample_size := SS}) ->
    Sum  = A + B + G,
    %% validate the user-supplied limits (when present); the defaults that init
    %% derives, max(2, 2·L), are always valid. (these are not guard-safe.)
    PuLBad = is_map_key(push_limit, Config) andalso not valid_limit(maps:get(push_limit, Config)),
    PlLBad = is_map_key(pull_limit, Config) andalso not valid_limit(maps:get(pull_limit, Config)),
    if not is_map_key(node_id, Config)             -> {error, missing_node_id};
       not (is_integer(VS) andalso VS > 0)         -> {error, {bad_view_size, VS}};
       not (is_integer(SS) andalso SS > 0)         -> {error, {bad_sample_size, SS}};
       PuLBad                                      -> {error, bad_push_limit};
       PlLBad                                      -> {error, bad_pull_limit};
       abs(Sum - 1.0) > 0.001                      -> {error, {shares_must_sum_to_1, Sum}};
       A + B >= 1.0                                -> {error, sample_share_must_be_positive};
       true                                        -> ok
    end.

valid_limit(L) -> is_integer(L) andalso L >= 1.

%% l1=α·ℓ (push), l2=β·ℓ (pull), l3=remainder (sample), forced ≥1 so the
%% Byzantine-resistant sampler ALWAYS contributes to V.
-spec split_counts(map()) -> {non_neg_integer(), non_neg_integer(), pos_integer()}.
split_counts(Cfg) ->
    L  = maps:get(view_size, Cfg),
    L1 = round(maps:get(alpha, Cfg) * L),
    L2 = round(maps:get(beta, Cfg) * L),
    {L1, L2, max(1, L - L1 - L2)}.

%% cap a pull response to the pull quota and strip self.
clean_resp(Ids, L2, Self) ->
    [I || I <- take(L2, Ids), I =/= Self].

%% Rebuild V. Under limited-push the push contribution is dropped (Vpush := [])
%% but pull + sample still rebuild V; an empty candidate set keeps OldV. The mix
%% takes priority; the remainder is topped up from a SHUFFLED sample+old set.
-spec reconstruct([term()], [term()], [term()], [term()],
                  {non_neg_integer(), non_neg_integer(), pos_integer()},
                  non_neg_integer(), term(), boolean()) -> [term()].
reconstruct(OldV, Vpush0, Vpull, Sampled, {L1, L2, L3}, L, Self, Limited) ->
    Vpush = case Limited of true -> []; false -> Vpush0 end,
    P = take_random(L1, udedup(Vpush)),
    Q = take_random(L2, udedup(Vpull)),
    R = take(L3, Sampled),
    Cand = udedup(P ++ Q ++ R) -- [Self],
    case Cand of
        [] -> OldV;
        _  ->
            Filler = shuffle((udedup(Sampled ++ OldV) -- [Self]) -- Cand),
            take(L, Cand ++ Filler)
    end.

encode(Msg) -> term_to_binary(Msg).

decode(Bin) ->
    try binary_to_term(Bin, [safe]) of T -> T
    catch _:_ -> error
    end.

-spec take_random(non_neg_integer(), [term()]) -> [term()].
take_random(N, List) when N >= length(List) -> shuffle(List);
take_random(N, List) -> take(N, shuffle(List)).

%% ======================================================================
%% helpers
%% ======================================================================

observe(Id, D)      -> D#d{sampler = quod_brahms_sampler:observe(Id, D#d.sampler)}.
observe_all(Ids, D) -> D#d{sampler = quod_brahms_sampler:observe_all(Ids, D#d.sampler)}.

take(N, L) -> lists:sublist(L, N).
shuffle(L) -> [X || {_, X} <- lists:sort([{rand:uniform(), E} || E <- L])].

%% order-preserving dedup (no sort bias)
udedup(L) -> udedup(L, #{}, []).
udedup([], _, Acc) -> lists:reverse(Acc);
udedup([H | T], Seen, Acc) ->
    case Seen of
        #{H := _} -> udedup(T, Seen, Acc);
        _         -> udedup(T, Seen#{H => []}, [H | Acc])
    end.

%% disjoint push/pull target sets from a single shuffle of V.
partition(L1, L2, V) ->
    S = shuffle(V),
    {take(L1, S), take(L2, lists:nthtail(min(L1, length(S)), S))}.

%% cache a peer's (bidirectional) inbound link for our own sends. It is owned by
%% `m:quod_conn` (origin `in`), so on eviction we drop+demonitor but DON'T close
%% it; when we don't cache it (already hold one) we just leave it serving.
%% Keyed by the peer's announced node id (v1 trusts the announced identity).
cache_inbound(NodeId, LinkPid, D) ->
    {_Cached, D1} = maybe_cache(NodeId, LinkPid, in, D),  %% caches + flushes if fresh
    D1.

%% a link to NodeId is now up: send any payload buffered while it was opening.
%% PEEK, don't take — the payload stays buffered so that if this link dies during
%% the send race it can be re-flushed on a reactively re-opened link. It is
%% cleared by the next confirmed direct send (send_msg) or a view-prune.
flush_outbox(NodeId, LinkPid, D = #d{outbox = Outbox}) ->
    case Outbox of
        #{NodeId := Payload} -> _ = quod_link:send(LinkPid, Payload), D;
        _                    -> D
    end.

%% find the NodeId a dead link pid was cached under (and the map without it).
take_conn(LinkPid, Conns) ->
    case [N || {N, {P, _, _}} <- maps:to_list(Conns), P =:= LinkPid] of
        [NodeId | _] -> {NodeId, maps:remove(NodeId, Conns)};
        []           -> error
    end.

%% keep only buffered payloads for peers still in the view; skip the rebuild in
%% the steady state (empty outbox), which is the overwhelmingly common case.
prune_outbox(_NewV, Outbox) when map_size(Outbox) =:= 0 -> Outbox;
prune_outbox(NewV, Outbox) -> maps:with(NewV, Outbox).

%% cache LinkPid (origin `out` = we opened it, `in` = peer opened it) under NodeId
%% with a monitor, iff the peer is in the view and we don't already hold a link.
%% The cheap maps:is_key check runs first to short-circuit the common cached case.
%% On a fresh cache, flush anything buffered while the link was opening (so both
%% callers get that for free — no repeated cache-then-flush dance).
maybe_cache(NodeId, LinkPid, Origin, D = #d{view = V, conns = Conns}) ->
    case (not maps:is_key(NodeId, Conns)) andalso lists:member(NodeId, V) of
        true ->
            MonRef = erlang:monitor(process, LinkPid),
            D1 = D#d{conns = Conns#{NodeId => {LinkPid, MonRef, Origin}}},
            {true, flush_outbox(NodeId, LinkPid, D1)};
        false ->
            {false, D}
    end.

%% drop links for ids no longer in the view: demonitor (so their DOWN is
%% swallowed), and close ONLY links we own (origin `out`); inbound links are
%% closed by their owning `m:quod_conn`, not by us. O(n) via a membership set.
prune_conns(NewV, Conns) ->
    Keep = maps:from_keys(NewV, []),
    maps:filter(fun(K, {LinkPid, MonRef, Origin}) ->
                    case maps:is_key(K, Keep) of
                        true -> true;
                        false ->
                            _ = erlang:demonitor(MonRef, [flush]),
                            _ = case Origin of out -> quod_link:close(LinkPid); in -> ok end,
                            false
                    end
                end, Conns).

%% ======================================================================
%% Brahms sample validation (failure detector)
%% ======================================================================

%% Probe a fresh batch of COLD sampled ids — sampled, but not currently linked
%% and not already under probe. Opening a link is the probe; its `link_up` (or
%% any message from the peer) is the answer. We remember the round each probe
%% was sent so `resolve_probes/1` can time it out.
start_probes(D = #d{ns = Ns, view = V, sampler = S, conns = Conns, probing = Pr,
                    self = Self, rounds = R, cfg = Cfg, tombstones = Tomb}) ->
    Fanout = maps:get(probe_fanout, Cfg),
    %% Probe unlinked ids from BOTH the view and the sample. A dead id can sit in
    %% V (kept by reconstruct's filler / re-gossiped by peers that haven't evicted
    %% it) without ever winning a sampler slot; probing the sample alone would
    %% never evict it, so it would be re-dialed forever. Probing view members not
    %% in `conns` closes that — the probe_rounds grace still spares a live peer
    %% that is merely slow to connect. Tombstoned ids are never probed (mark_dead
    %% already reset their sampler slots; this guards any re-entry race).
    Pool   = V ++ quod_brahms_sampler:sample(S),
    Cands  = [N || N <- probe_candidates(Pool, Conns, Pr, Self),
                   not maps:is_key(N, Tomb)],
    lists:foldl(fun(NodeId, A) ->
                    _ = quod_quic:open_link(NodeId, Ns),
                    A#d{probing = (A#d.probing)#{NodeId => R}}
                end, D, take(Fanout, shuffle(Cands))).

%% Retire probes still unanswered after `probe_rounds`: a peer that meanwhile
%% linked (in `conns`) answered late and lives; the rest are declared dead.
resolve_probes(D = #d{probing = Pr, rounds = R, cfg = Cfg}) ->
    ProbeRounds = maps:get(probe_rounds, Cfg),
    lists:foldl(fun(NodeId, A) ->
                    case maps:is_key(NodeId, A#d.conns) of
                        true  -> clear_probe(NodeId, A);   %% answered late -> alive
                        false -> mark_dead(NodeId, A)      %% no answer -> dead
                    end
                end, D, due_probes(Pr, R, ProbeRounds)).

%% A sampled/view id failed liveness: reset every sampler slot holding it (a
%% fresh key, exactly Brahms' sampler reset), drop it from V, stop probing it,
%% and tear down any link we still cache for it. Idempotent.
mark_dead(NodeId, D = #d{ns = Ns, view = V, sampler = S, probing = Pr,
                         conns = Conns, outbox = Outbox}) ->
    Conns1 = case maps:take(NodeId, Conns) of
                 {{LinkPid, MonRef, Origin}, C} ->
                     _ = erlang:demonitor(MonRef, [flush]),
                     _ = case Origin of out -> quod_link:close(LinkPid); in -> ok end,
                     C;
                 error -> Conns
             end,
    is_map_key(NodeId, Pr) andalso
        logger:info("quod[~s]: evicting unreachable peer ~p (sampler reset)", [Ns, NodeId]),
    D#d{sampler = quod_brahms_sampler:invalidate(NodeId, S),
        view    = V -- [NodeId],
        probing = maps:remove(NodeId, Pr),
        conns   = Conns1,
        outbox  = maps:remove(NodeId, Outbox),
        evictions = D#d.evictions + 1,
        tombstones = (D#d.tombstones)#{NodeId => D#d.rounds}}.   %% refuse re-admission for a while

clear_probe(NodeId, D = #d{probing = Pr}) ->
    case maps:is_key(NodeId, Pr) of
        true  -> D#d{probing = maps:remove(NodeId, Pr)};
        false -> D
    end.

%% probes sent at least `ProbeRounds` rounds ago and still open (pure/testable).
-spec due_probes(#{term() => non_neg_integer()}, non_neg_integer(), pos_integer()) -> [term()].
due_probes(Probing, CurRound, ProbeRounds) ->
    [NodeId || {NodeId, Sent} <- maps:to_list(Probing), CurRound - Sent >= ProbeRounds].

%% From a `Pool` of candidate ids (the view ++ the sample), keep those whose
%% liveness is unknown: not self, not already linked (those are proven alive), not
%% already under probe. Covers both sticky dead samples AND dead view members that
%% never won a sampler slot (pure/testable).
-spec probe_candidates([term()], #{term() => _}, #{term() => _}, term()) -> [term()].
probe_candidates(Pool, Conns, Probing, Self) ->
    [NodeId || NodeId <- udedup(Pool),
               NodeId =/= Self,
               not maps:is_key(NodeId, Conns),
               not maps:is_key(NodeId, Probing)].

%% --- tombstones (SWIM-style; refuse re-admission of a just-evicted id) ---

tombstoned(Id, #d{tombstones = T}) -> maps:is_key(Id, T).

%% a direct message from a tombstoned id proves it alive -> lift the tombstone.
untombstone(Id, D = #d{tombstones = T}) ->
    case maps:is_key(Id, T) of
        true  -> D#d{tombstones = maps:remove(Id, T)};
        false -> D
    end.

%% drop tombstones older than TombRounds — long enough for the eviction to reach
%% the whole fleet, short enough that a legitimately reused id is not blocked for
%% good (pure/testable).
-spec prune_tombstones(#{term() => non_neg_integer()}, non_neg_integer(), pos_integer()) ->
          #{term() => non_neg_integer()}.
prune_tombstones(T, CurRound, TombRounds) ->
    maps:filter(fun(_Id, Stamped) -> CurRound - Stamped < TombRounds end, T).

round_delay(Cfg) ->
    Base = maps:get(round_ms, Cfg),
    J    = maps:get(jitter, Cfg),
    Base + round((rand:uniform() * 2 - 1) * Base * J).

%% Payload is already an encoded message binary. A cached link -> direct
%% (non-blocking) send. Otherwise open one ASYNCHRONOUSLY (retried each round) and
%% buffer the latest payload so it is flushed the instant the link comes up.
%%
%% This fully recovers PUSH (the sampler heals from any received id, any round). A
%% buffered PULL_REQ only helps if the link comes up within this round's collect
%% window — a later flush still warms the link, but its pull_resp arrives after
%% `pulled` is reset and is dropped as unsolicited. Push/pull_req are
%% content-invariant, so keeping only the latest per peer bounds the buffer to the
%% view size with no staleness.
send_msg(NodeId, Payload, D = #d{ns = Ns, conns = Conns, outbox = Outbox}) ->
    case maps:get(NodeId, Conns, undefined) of
        {LinkPid, _MonRef, _Origin} ->
            _ = quod_link:send(LinkPid, Payload),
            D#d{outbox = maps:remove(NodeId, Outbox)};   %% live link confirmed; drop any buffered copy
        undefined ->
            _ = quod_quic:open_link(NodeId, Ns),
            D#d{outbox = Outbox#{NodeId => Payload}}
    end.
