-module(quod_brahms).
-moduledoc """
Brahms membership for one namespace (ontology) — the View `V` + round driver.

One `gen_statem` per namespace `Ns`, registered `{quod_brahms, Ns}`, holding the
view `V` (a small set of node ids) and the `m:quod_brahms_sampler` as inline
state. Gossip for `Ns` flows on channel `Ns` (the namespace *is* the channel).

## A round

`idle` arms a jittered timer; on tick (`do_round/1`) it pushes its own id to
`α·ℓ` peers of `V` and pulls views from `β·ℓ` **disjoint** peers, then collects
responses and **reconstructs** `V` from three sources — `α·ℓ` from pushes,
`β·ℓ` from pulls, `γ·ℓ` (always ≥1) from `sampler:sample` — feeding observed ids
to the sampler.

## Traps handled

- **Self-exclusion**: never push/pull/insert self.
- **Limited push reception**: pushes are counted *only while collecting*; once
  past `push_limit` the round keeps the old view (attack signal).
- **Pulls are attacker input too**: `pull_resp` is capped to `ℓ` ids on receipt.
- **No reflection/SSRF**: `pull_req` is answered on the *inbound* connection,
  never by dialling the attacker-supplied `From`.
- **Non-blocking**: dialling happens off the statem (async); only cached sends
  run inline, so a round never stalls on an unreachable peer.
- **Never collapse to empty**; **defensive decode** (garbage dropped).
- **Bounded state**: the connection cache is pruned to the current view each round.

> #### Deferred {: .info }
>
> v1 has no probe-based eviction, and PUSH uses reliable streams. PUSH over
> `quicer:send_dgram` and probe liveness come later.
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
          push_limit  => 16,     %% limited-push-reception threshold
          round_ms    => 5000,
          collect_ms  => 1500,
          jitter      => 0.2}).

-record(d, {ns      :: binary(),
            self    :: term(),
            cfg     :: map(),
            view    = [] :: [term()],
            sampler :: quod_brahms_sampler:sampler(),
            conns   = #{} :: #{term() => quod_quicer:peer()},
            vpush   = [] :: [term()],
            vpull   = [] :: [term()],
            pushes  = 0  :: non_neg_integer()}).

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
    case valid_cfg(Cfg) of
        ok ->
            Self  = maps:get(node_id, Config),
            Seeds = [P || P <- maps:get(seed_peers, Config, []), P =/= Self],
            K     = maps:get(sample_size, Cfg),
            Sampler = quod_brahms_sampler:observe_all(Seeds, quod_brahms_sampler:new(K)),
            quod_reg:subscribe({channel, Ns}),
            D = #d{ns = Ns, self = Self, cfg = Cfg, view = Seeds, sampler = Sampler},
            {ok, idle, D, [{state_timeout, round_delay(Cfg), tick}]};
        {error, Reason} ->
            {stop, {bad_config, Reason}}
    end.

%% --- idle: between rounds. Stays responsive (answers pull/pull-req, feeds the
%% sampler) but does NOT accumulate for reconstruction. ---------------------
idle(state_timeout, tick, D0) ->
    D1 = do_round(D0),
    {next_state, collecting, D1,
     [{state_timeout, maps:get(collect_ms, D1#d.cfg), close}]};
idle(info, {quod_message, Peer, Ns, Payload}, D = #d{ns = Ns}) ->
    {keep_state, handle_inbound(Peer, Payload, idle, D)};
idle(EventType, Event, D) ->
    common(EventType, Event, D).

%% --- collecting: the round window — accumulate, then reconstruct ----------
collecting(state_timeout, close, D0) ->
    D1 = reconstruct_and_update(D0),
    {next_state, idle, D1, [{state_timeout, round_delay(D1#d.cfg), tick}]};
collecting(info, {quod_message, Peer, Ns, Payload}, D = #d{ns = Ns}) ->
    {keep_state, handle_inbound(Peer, Payload, collecting, D)};
collecting(EventType, Event, D) ->
    common(EventType, Event, D).

%% --- shared ---------------------------------------------------------------
common(cast, {cache_conn, NodeId, Peer}, D) ->
    {keep_state, D#d{conns = (D#d.conns)#{NodeId => Peer}}};
common({call, From}, get_view, D) ->
    {keep_state, D, [{reply, From, D#d.view}]};
common({call, From}, get_sample, D) ->
    {keep_state, D, [{reply, From, quod_brahms_sampler:sample(D#d.sampler)}]};
common(info, {quod_message, _, _OtherNs, _}, D) ->
    {keep_state, D};                                    %% another namespace
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

do_round(D = #d{cfg = Cfg, self = Self, view = V}) ->
    {L1, L2, _L3} = split_counts(Cfg),
    {Push, Pull} = partition(L1, L2, V),               %% disjoint target sets
    D1 = lists:foldl(fun(T, A) -> send_msg(T, {push, Self}, A) end, D, Push),
    D2 = lists:foldl(fun(T, A) -> send_msg(T, {pull_req, Self}, A) end, D1, Pull),
    D2#d{vpush = [], vpull = [], pushes = 0}.           %% open the round window

%% Mode is `idle` (responsive, no accumulation) or `collecting` (accumulate).
handle_inbound(Peer, Payload, Mode, D = #d{self = Self}) ->
    case decode(Payload) of
        {push, Id} when Id =/= Self ->
            D1 = observe(Id, D),
            case Mode of collecting -> accumulate_push(Id, D1); idle -> D1 end;
        {pull_req, From} when From =/= Self ->
            reply_view(Peer, D),                        %% answer on the inbound conn
            observe(From, D);
        {pull_resp, Ids} when is_list(Ids) ->
            Clean = clean_resp(Ids, maps:get(view_size, D#d.cfg), Self),
            D1 = observe_all(Clean, D),
            case Mode of collecting -> D1#d{vpull = Clean ++ D1#d.vpull}; idle -> D1 end;
        _ ->
            D                                           %% bad/unknown -> drop
    end.

accumulate_push(Id, D = #d{cfg = Cfg, pushes = P, vpush = Vpush}) ->
    P1 = P + 1,
    Vpush1 = case P1 =< maps:get(push_limit, Cfg) of
                 true  -> [Id | Vpush];                 %% limited push reception
                 false -> Vpush
             end,
    D#d{pushes = P1, vpush = Vpush1}.

reply_view(Peer, #d{ns = Ns, view = V}) ->
    _ = quod_quicer:send(Peer, Ns, encode({pull_resp, V})),
    ok.

reconstruct_and_update(D = #d{cfg = Cfg, self = Self, view = OldV, conns = Conns,
                              vpush = Vpush, vpull = Vpull, sampler = S, pushes = P}) ->
    {L1, L2, L3} = split_counts(Cfg),
    Limited = P > maps:get(push_limit, Cfg),
    Sampled = quod_brahms_sampler:sample(S),
    NewV = reconstruct(OldV, Vpush, Vpull, Sampled, {L1, L2, L3},
                       maps:get(view_size, Cfg), Self, Limited),
    S1 = quod_brahms_sampler:observe_all(NewV, S),
    D#d{view = NewV,
        sampler = S1,
        conns = maps:with(NewV, Conns),                %% prune cache to the view
        vpush = [], vpull = [], pushes = 0}.

%% ======================================================================
%% pure logic (unit-tested)
%% ======================================================================

valid_cfg(#{alpha := A, beta := B, gamma := G}) ->
    Sum = A + B + G,
    if abs(Sum - 1.0) > 0.001 -> {error, {shares_must_sum_to_1, Sum}};
       A + B >= 1.0           -> {error, sample_share_must_be_positive};
       true                   -> ok
    end.

%% l1=α·ℓ (push), l2=β·ℓ (pull), l3=remainder (sample) — l3 is forced ≥1 so the
%% Byzantine-resistant sampler ALWAYS contributes to V.
-spec split_counts(map()) -> {non_neg_integer(), non_neg_integer(), pos_integer()}.
split_counts(Cfg) ->
    L  = maps:get(view_size, Cfg),
    L1 = round(maps:get(alpha, Cfg) * L),
    L2 = round(maps:get(beta, Cfg) * L),
    {L1, L2, max(1, L - L1 - L2)}.

%% cap a pull response to ℓ ids and strip self (pulls are attacker-controllable).
clean_resp(Ids, L, Self) ->
    [I || I <- take(L, Ids), I =/= Self].

%% Rebuild V from the three sources. Limited-push or an empty candidate set keeps
%% the old view; otherwise Cand (the α/β/γ mix) takes priority and the rest is
%% topped up from a SHUFFLED sample+old set — no sort, so no bias toward low ids.
-spec reconstruct([term()], [term()], [term()], [term()],
                  {non_neg_integer(), non_neg_integer(), pos_integer()},
                  non_neg_integer(), term(), boolean()) -> [term()].
reconstruct(OldV, _Vpush, _Vpull, _Sampled, _Counts, _L, _Self, true) ->
    OldV;
reconstruct(OldV, Vpush, Vpull, Sampled, {L1, L2, L3}, L, Self, false) ->
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

%% order-preserving dedup (keeps first occurrence; no sort bias)
udedup(L) -> udedup(L, #{}, []).
udedup([], _, Acc) -> lists:reverse(Acc);
udedup([H | T], Seen, Acc) ->
    case Seen of
        #{H := _} -> udedup(T, Seen, Acc);
        _         -> udedup(T, Seen#{H => []}, [H | Acc])
    end.

%% split a shuffled view into DISJOINT push and pull target sets.
partition(L1, L2, V) ->
    S = shuffle(V),
    {take(L1, S), take(L2, lists:nthtail(min(L1, length(S)), S))}.

round_delay(Cfg) ->
    Base = maps:get(round_ms, Cfg),
    J    = maps:get(jitter, Cfg),
    Base + round((rand:uniform() * 2 - 1) * Base * J).

%% Send Msg on channel Ns. Cached connection -> direct (non-blocking) send.
%% Otherwise dial ASYNCHRONOUSLY off the statem and cache the handle back, so a
%% round never blocks on an unreachable peer.
send_msg(NodeId, Msg, D = #d{ns = Ns, conns = Conns}) ->
    Payload = encode(Msg),
    case maps:get(NodeId, Conns, undefined) of
        undefined ->
            async_dial_send(NodeId, Ns, Payload, self()),
            D;
        Peer ->
            case quod_quicer:send(Peer, Ns, Payload) of
                ok -> D;
                {error, _} ->
                    async_dial_send(NodeId, Ns, Payload, self()),
                    D#d{conns = maps:remove(NodeId, Conns)}
            end
    end.

async_dial_send({Host, Port} = NodeId, Ns, Payload, Statem) ->
    _ = spawn(fun() ->
        case quod_quicer:connect(Host, Port) of
            {ok, Peer} ->
                _ = quod_quicer:send(Peer, Ns, Payload),
                gen_statem:cast(Statem, {cache_conn, NodeId, Peer});
            _ -> ok
        end
    end),
    ok;
async_dial_send(_BadId, _Ns, _Payload, _Statem) ->
    ok.
