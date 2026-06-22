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

> #### Deferred {: .info }
>
> v1 has no probe-based eviction; PUSH uses reliable streams. Those come later.
""".

-behaviour(gen_statem).

-export([start_namespace/2, start_link/2, view/1, sample/1]).
-export([init/1, callback_mode/0, terminate/3]).
-export([idle/3, collecting/3]).

-ifdef(TEST).
-export([split_counts/1, reconstruct/8, encode/1, decode/1, take_random/2, clean_resp/3]).
-endif.

-define(DEFAULTS,
        #{view_size   => 16,
          alpha       => 0.45,   %% push share
          beta        => 0.45,   %% pull share
          gamma       => 0.10,   %% sample share
          sample_size => 32,     %% sampler slots K
          round_ms    => 5000,
          collect_ms  => 1500,
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
common(info, {link_up, NodeId, Ns, LinkPid}, D = #d{ns = Ns}) ->
    case maybe_cache(NodeId, LinkPid, out, D) of
        {true, D1}  -> {keep_state, D1};
        {false, D1} -> _ = quod_link:close(LinkPid), {keep_state, D1}
    end;
common(info, {link_error, _Channel}, D) ->
    {keep_state, D};                               %% open failed; next round retries
%% a cached link died -> the peer dropped; evict it (pid-matched, so a replacement
%% link already cached under the same NodeId survives).
common(info, {'DOWN', _Ref, process, LinkPid, _Reason}, D = #d{conns = Conns}) ->
    {keep_state, D#d{conns = maps:filter(fun(_, {P, _, _}) -> P =/= LinkPid end, Conns)}};
common({call, From}, get_view, D) ->
    {keep_state, D, [{reply, From, D#d.view}]};
common({call, From}, get_sample, D) ->
    {keep_state, D, [{reply, From, quod_brahms_sampler:sample(D#d.sampler)}]};
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

do_round(D = #d{self = Self, view = V, counts = {L1, L2, _}}) ->
    {Push, Pull} = partition(L1, L2, V),           %% disjoint target sets
    PushBin = encode({push, Self}),                %% encode once, fan out
    PullBin = encode({pull_req, Self}),
    D1 = lists:foldl(fun(T, A) -> send_msg(T, PushBin, A) end, D, Push),
    D2 = lists:foldl(fun(T, A) -> send_msg(T, PullBin, A) end, D1, Pull),
    D2#d{vpush = [], vpull = [], pushes = 0, pulled = Pull}.

handle_inbound(_Peer, Payload, _Mode, D) when byte_size(Payload) > ?MAX_GOSSIP_BYTES ->
    D;                                             %% oversized gossip -> drop
handle_inbound({RemoteNodeId, ReplyLink}, Payload, Mode, D0 = #d{self = Self, counts = {_, L2, _}}) ->
    %% a peer's link is bidirectional: cache it for our own sends so a peer pair
    %% shares ONE stream per channel (no separate dial-back).
    D = cache_inbound(RemoteNodeId, ReplyLink, D0),
    case decode(Payload) of
        {push, Id} when Id =/= Self ->
            D1 = observe(Id, D),                   %% sampler sees every received id
            case Mode of collecting -> accumulate_push(Id, D1); idle -> D1 end;
        {pull_req, From} when From =/= Self ->
            reply_view(ReplyLink, D),              %% answer on the inbound link
            observe(From, D);
        {pull_resp, From, Ids} when is_list(Ids) ->
            %% accept only a response we solicited this round
            case lists:member(From, D#d.pulled) of
                true ->
                    Clean = clean_resp(Ids, L2, Self),
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
        conns = prune_conns(NewV, Conns),
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
    {_Cached, D1} = maybe_cache(NodeId, LinkPid, in, D),
    D1.

%% cache LinkPid (origin `out` = we opened it, `in` = peer opened it) under NodeId
%% with a monitor, iff the peer is in the view and we don't already hold a link.
%% The cheap maps:is_key check runs first to short-circuit the common cached case.
maybe_cache(NodeId, LinkPid, Origin, D = #d{view = V, conns = Conns}) ->
    case (not maps:is_key(NodeId, Conns)) andalso lists:member(NodeId, V) of
        true ->
            MonRef = erlang:monitor(process, LinkPid),
            {true, D#d{conns = Conns#{NodeId => {LinkPid, MonRef, Origin}}}};
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

round_delay(Cfg) ->
    Base = maps:get(round_ms, Cfg),
    J    = maps:get(jitter, Cfg),
    Base + round((rand:uniform() * 2 - 1) * Base * J).

%% Payload is already an encoded message binary. A cached link -> direct
%% (non-blocking) send; otherwise open one ASYNCHRONOUSLY and drop this round's
%% payload (gossip is periodic — the next round reaches the peer once it is up,
%% and `{link_up, ...}` caches the link in the meantime).
send_msg(NodeId, Payload, D = #d{ns = Ns, conns = Conns}) ->
    case maps:get(NodeId, Conns, undefined) of
        {LinkPid, _MonRef, _Origin} ->
            _ = quod_link:send(LinkPid, Payload),
            D;
        undefined ->
            _ = quod_quicer:open_link(NodeId, Ns),
            D
    end.
