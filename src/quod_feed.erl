-module(quod_feed).
-moduledoc """
Per-namespace **dissemination** endpoint — how a finalized block spreads from the small committee to
the non-voting crowd (replicas, subscribers) by **push-pull epidemic gossip over the Brahms overlay**,
so a change reaches far more nodes than a leader-star ever could. Every block carries the quorum
`#cert{}` that finalized it, and **every hop verifies that cert against the committee-as-of-that-slot
before it applies or re-pushes** — a tampering/equivocating relay is dropped, never propagated
(`doc/deferred.md` §4 P2; design `~/.claude/plans/quod-feed-dissemination.md`).

A per-namespace `gen_server` sibling on channel **`{feed, Ns}`**, last in the `m:quod_ns`
`rest_for_one` chain (it holds no state the others need). It has two halves:

- **Producer** (a committee Member): on each *live* commit `m:quod_simplex` publishes
  `{committed, Slot, Entry}` on the `{feed_src, Ns}` property; the feed **eager-pushes** the block to a
  small fanout of the node's `quod_brahms:view/1` (the Byzantine-resistant `sample/1` is reserved for
  the F2 anti-entropy pull-source selection). Never on the replay/rebuild path, so catching up
  never re-broadcasts history (`content-layer-design.md` §14 live-vs-replay).
- **Relay / follower** (a caught-up non-member — see `follows/4`): a gossiped `{block, Entry}` for slot
  `H+1` is verified against the current committee (`quod_catchup:verify_forward/3`) and, if genuine,
  handed to `m:quod_simplex` to append+apply (the sole store writer); then eager-pushed onward. A
  duplicate (`slot ≤ H`) is dropped and **never re-pushed** (loop suppression); a gap (`slot > H+1`) is
  dropped and recovered by anti-entropy.
- **Anti-entropy** (the completeness guarantee): every `?ANTI_ENTROPY_MS` a follower advertises its
  height to one `quod_brahms:sample/1` peer (`{digest, Hi}`); a behind node PULLs the gap, an ahead
  node replies its height so the sender pulls. The pull is the SAME trustless driver as cold-start
  catch-up (`quod_catchup:catch_up/5`) sourced from a live sampled peer, so a block missed by eager
  push (loss, an out-of-fanout peer, a transient ingest error) is always recovered.

**Built (F1 + F2):** eager-push + fast-path verify/ingest/relay, and digest-driven anti-entropy pull.
**Deferred:** IHAVE (per-block lazy advertisement, a push-latency tweak), the split cert/hash/payload
verify-before-decode frame (`doc/deferred.md` §2), and chunking for a single block over the frame cap.
""".
-behaviour(gen_server).
-include("quod_ledger.hrl").

-export([start_link/2, stats/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([classify/2, encode/2, decode/2]).
-endif.

-define(PUSH_FANOUT,     4).             %% eager-push targets per fresh block (best-effort; anti-entropy backstops)
-define(MAX_FRAME_BYTES, (1 bsl 20)).    %% drop an inbound frame ≥ 1 MiB before decode (matches quod_link)
-define(INGEST_MS,       5000).          %% budget for ONE fast-path block's append+apply through quod_simplex
-define(PULL_SINK_MS,    30000).         %% budget for a whole anti-entropy WINDOW (up to ?WINDOW entries;
                                         %% matches quod_simplex's ?SINK_MS for the identical sink)
-define(ANTI_ENTROPY_MS, 3000).          %% base period of the anti-entropy digest round (jittered ±20%)
-define(MIN_ANTI_ENTROPY_MS, 200).       %% floor for the (operator-tunable) period — never busy-loop
-define(WINDOW,          256).           %% entries per anti-entropy pull window (matches quod_catchup's block cap)

-record(s, {ns       :: binary(),
            self     :: node_id(),
            chan     :: binary(),                                       %% term_to_binary({feed, Ns}, [deterministic])
            pulling  = false :: false | pid(),   %% the in-flight anti-entropy pull worker (at most one)
            pushed   = 0 :: non_neg_integer(),   %% local commits we originated onto the feed
            ingested = 0 :: non_neg_integer(),   %% gossiped blocks we verified, applied, and relayed
            pulled   = 0 :: non_neg_integer(),   %% anti-entropy pull rounds we started
            dropped  = 0 :: non_neg_integer()}).  %% duplicate / gap / unverified / non-following

%%%===================================================================
%%% API
%%%===================================================================

start_link(Ns, Config) ->
    gen_server:start_link(quod_reg:via({quod_feed, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Dissemination counters for `Ns` (pushed/ingested/pulled/dropped), or `undefined` if down.".
-spec stats(binary()) -> map() | undefined.
stats(Ns) ->
    case quod_reg:where({quod_feed, Ns}) of
        undefined -> undefined;
        Pid -> try gen_server:call(Pid, get_stats, 1000) catch exit:_ -> undefined end
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    Self = maps:get(node_id, Config),
    Chan = term_to_binary({feed, Ns}, [deterministic]),
    quod_reg:subscribe({channel, Chan}),   %% gossiped blocks + digests on {feed, Ns}
    quod_reg:subscribe({feed_src, Ns}),    %% local live commits from quod_simplex
    arm_anti_entropy(),
    {ok, #s{ns = Ns, self = Self, chan = Chan}}.

handle_call(get_stats, _From, S) ->
    {reply, #{pushed => S#s.pushed, ingested => S#s.ingested,
              pulled => S#s.pulled, dropped => S#s.dropped}, S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

%% A local live commit: we are the ORIGIN for this block — eager-push it to the crowd (never ingest, we
%% already hold it). Fires only on the live commit path (quod_simplex publishes here from commit_block/
%% skip_block), never on rebuild/catch-up, so history is never re-broadcast.
handle_info({committed, _Slot, #entry{} = Entry}, S) ->
    {noreply, eager_push(Entry, S#s{pushed = S#s.pushed + 1})};
%% A gossiped block or digest from a peer on our {feed, Ns} channel. `Addr` is the sender's announced
%% endpoint (from the authenticated link header) — used as the pull contact when we reconcile a gap.
handle_info({quod_message, {{_Peer, Addr}, _InLink}, Chan, Payload}, S = #s{chan = Chan}) ->
    {noreply, inbound(Addr, Payload, S)};
handle_info({quod_message, _, _OtherChan, _}, S) -> {noreply, S};   %% Brahms / another namespace
%% Anti-entropy round: advertise our height to one Byzantine-resistant sampled peer, then re-arm. A peer
%% that is behind pulls the gap from us; if WE are behind, its reply digest makes us pull from it.
handle_info(anti_entropy, S) ->
    arm_anti_entropy(),
    {noreply, send_digest(S)};
%% The anti-entropy pull worker finished (or died) — clear the in-flight latch so the next round can pull.
%% (Link lifecycle is owned by the transport now: we send fire-and-forget via quod_quic:send/3 and never
%% monitor links ourselves, so the only process we monitor is the pull worker.)
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S = #s{pulling = Pid}) ->
    {noreply, S#s{pulling = false}};
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #s{ns = Ns, chan = Chan}) ->
    _ = try quod_reg:unsubscribe({channel, Chan}) catch _:_ -> ok end,
    _ = try quod_reg:unsubscribe({feed_src, Ns}) catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% inbound gossip: verify → ingest → relay (per-hop Byzantine check)
%%%===================================================================

inbound(_Addr, Payload, S) when byte_size(Payload) > ?MAX_FRAME_BYTES ->
    S#s{dropped = S#s.dropped + 1};   %% drop oversized BEFORE decode — bound binary_to_term memory
inbound(Addr, Payload, S) ->
    case decode(Payload, S#s.ns) of
        {block, #entry{} = Entry}      -> on_block(Entry, S);
        {digest, Hi} when is_integer(Hi), Hi >= 0 -> on_digest(Addr, Hi, S);
        _                              -> S
    end.

%% Handle one gossiped committed block. Two gates before we touch it:
%%   1. `follows/4` — only a caught-up NON-member observer of a FOUNDED namespace ingests from the feed
%%      (see its comment): a voter would desync its own engine, a mid-catch-up node would race the
%%      catch-up worker, and an unfounded (slot-0) node must get genesis from the ANCHORED catch-up path,
%%      never an unauthenticated feed push (else the genesis_hash trust anchor is bypassed).
%%   2. the cert is the proof: verify it against the committee AS-OF-its-slot (for the fast path,
%%      slot = H+1, that IS our current validator set) before we apply or re-push.
%% Never applies out of order — a gap is left for anti-entropy (F2).
on_block(#entry{index = Slot} = Entry, S = #s{ns = Ns, self = Self}) ->
    {Height, Committee, Join} = current(Ns),
    case follows(Self, Committee, Join, Height) andalso classify(Slot, Height) of
        next ->
            case quod_catchup:verify_forward(Committee, Slot, [Entry]) of
                {ok, [_], _} ->
                    case ingest(Ns, [Entry], ?INGEST_MS) of
                        ok         -> eager_push(Entry, S#s{ingested = S#s.ingested + 1});
                        {error, _} -> S   %% consensus busy/restarting ⇒ drop; anti-entropy re-pulls it
                    end;
                {error, _} -> S#s{dropped = S#s.dropped + 1}   %% unverified ⇒ drop, NEVER relay
            end;
        _ -> S#s{dropped = S#s.dropped + 1}   %% duplicate / gap / not a following node
    end.

%% A node ingests pushed blocks (follows the feed) ONLY when it is a caught-up NON-member observer of a
%% founded namespace:
%%   - past genesis (`Height >= 1`): slot 1 and its committee are established only by the anchored
%%     catch-up path; ingesting a slot-1 push would bypass the `genesis_hash` anchor (verify_forward
%%     accepts a `cert=none` genesis on trust) and let a peer forge our origin;
%%   - not mid-catch-up (`Join ∈ {none, done}`): the catch-up worker owns ingestion while joining —
%%     racing it on the store churns/aborts catch-up;
%%   - not a committee voter (`Self ∉ Committee`): a member advances via consensus and finalizes the slot
%%     in its own engine; sinking a copy through the catch-up path advances the store without pruning the
%%     engine, wedging the just-committed slot in `commit_buf` forever.
follows(Self, Committee, Join, Height) ->
    Height >= 1
        andalso (Join =:= none orelse Join =:= done)
        andalso not lists:member(Self, Committee).

%% Slot vs our contiguous height: already-have / the next block / a gap (out of order).
-spec classify(slot(), log_index()) -> duplicate | next | gap.
classify(Slot, Height) when Slot =< Height     -> duplicate;
classify(Slot, Height) when Slot =:= Height + 1 -> next;
classify(_Slot, _Height)                        -> gap.

%% Our contiguous committed height, current validator set (= committee-as-of-(H+1)), and join lifecycle.
%% quod_simplex is the single source of truth; if it is unreachable the defaults make `follows/4` false
%% (we don't follow while consensus is down) rather than trusting a block.
current(Ns) ->
    St = quod_simplex:status(Ns),
    {maps:get(slot, St, 0), maps:get(committee, St, []), maps:get(join, St, none)}.

%% Hand a verified, contiguous window to quod_simplex — the SOLE store writer. Reuses the catch-up sink
%% (append + committee fold + KB replay, contiguity-checked); a duplicate/non-contiguous window is
%% rejected there and surfaces as {error, _}. (When the event system's live reactions land, a fresh
%% fast-path block routes through the live-apply seam; today apply is D-only on both paths.)
ingest(Ns, Entries, Timeout) ->
    try gen_server:call(quod_reg:via({quod_simplex, Ns}), {sink_catchup, Entries}, Timeout)
    catch exit:_ -> {error, unavailable} end.

%%%===================================================================
%%% anti-entropy — the completeness path (gap repair by verified pull)
%%%===================================================================

%% The digest period is operator-tunable (`feed_anti_entropy_ms`) but floored so a mistyped/zero value
%% can never turn the timer into a busy loop (mirrors quod_simplex's delta_ms guard).
arm_anti_entropy() ->
    Base = case application:get_env(quod, feed_anti_entropy_ms, ?ANTI_ENTROPY_MS) of
               N when is_integer(N), N >= ?MIN_ANTI_ENTROPY_MS -> N;
               _                                               -> ?ANTI_ENTROPY_MS
           end,
    erlang:send_after(jitter(Base), self(), anti_entropy).

%% ±20% jitter so a fleet doesn't synchronise its digest rounds into a thundering herd.
jitter(Base) -> Base - (Base div 5) + rand:uniform(2 * (Base div 5) + 1) - 1.

%% Advertise our contiguous height to ONE peer drawn from the Byzantine-resistant sample. We only need to
%% reconcile as a FOLLOWER (a committee member is authoritative), so an unfounded / member / mid-catch-up
%% node stays silent. Source selection uses `sample/1` (not `view/1`): an eclipse biasing whom we PULL
%% from is a real attack; the sampler resists it, and every pulled block is cert-verified regardless.
send_digest(S = #s{ns = Ns, self = Self, chan = Chan}) ->
    {Height, Committee, Join} = current(Ns),
    case follows(Self, Committee, Join, Height) of
        false -> S;
        true  ->
            case pick_peer(quod_brahms:sample(Ns)) of
                none -> S;
                Peer -> _ = quod_quic:send(Peer, Chan, encode(Ns, {digest, Height})), S
            end
    end.

%% One random peer from the (deduped) sample, via the shared Brahms sampler — the Brahms sample is a
%% MULTISET, so `usort` first and let `take_random/2` do the unbiased pick.
pick_peer(Peers) ->
    case quod_brahms:take_random(1, lists:usort(Peers)) of
        [P | _] -> P;
        []      -> none
    end.

%% A peer advertised height `PeerHi`. If we are behind and eligible to follow, PULL the gap from it — but
%% only if no pull is already in flight (one worker at a time). If we are AHEAD, reply with our own height
%% so it pulls from us — this reply is NOT gated by our own in-flight pull (a node still catching up must
%% still help peers behind it). Equal ⇒ nothing.
on_digest(Addr, PeerHi, S = #s{ns = Ns, self = Self, chan = Chan}) ->
    {Height, Committee, Join} = current(Ns),
    if
        Height < PeerHi ->
            case S#s.pulling =:= false andalso follows(Self, Committee, Join, Height) of
                true  -> start_pull(Addr, Height + 1, Committee, S);
                false -> S   %% already pulling, or not an eligible follower
            end;
        Height > PeerHi -> _ = quod_quic:send(Addr, Chan, encode(Ns, {digest, Height})), S;   %% let them pull from us
        true            -> S
    end.

%% Reconcile the gap by running the SAME trustless catch-up driver used at cold-start, but sourced from a
%% live sampled peer (`Contact = Addr`) instead of a boot seed: pull a window via quod_catchup, which
%% verifies each entry's cert against the committee it folds forward, and sink it through quod_simplex
%% (the sole writer, contiguity-checked). `From > 1` here (a follower is past genesis), so the genesis
%% anchor is skipped — every block is proven inductively from the committee we already hold. One worker
%% at a time (`pulling`); its `DOWN` clears the latch.
start_pull(Addr, From, Committee, S = #s{ns = Ns}) ->
    {Pid, _Ref} = spawn_monitor(
        fun() ->
            Fetch = fun(F)  -> quod_catchup:pull(Ns, F, F + ?WINDOW - 1, Addr) end,
            Sink  = fun(Es) -> ingest(Ns, Es, ?PULL_SINK_MS) end,
            _ = quod_catchup:catch_up(<<>>, Fetch, Sink, From, Committee)
        end),
    S#s{pulling = Pid, pulled = S#s.pulled + 1}.

%%%===================================================================
%%% eager push over the Brahms view
%%%===================================================================

%% Push a block to up to ?PUSH_FANOUT peers from this namespace's Brahms VIEW (the node's partial
%% membership = its eager-push peers, à la Plumtree), fire-and-forget via the transport. Best-effort; the
%% anti-entropy pull path is the completeness guarantee (its pull SOURCES come from the Byzantine-resistant
%% `quod_brahms:sample/1` — source selection is where an eclipse would bias what we ACCEPT; pushing a
%% self-verifying block out is safe to anyone). The view is address-based and may be empty (no overlay /
%% degraded) — then this is a no-op, exactly right for a solo/founder node.
eager_push(#entry{} = Entry, S = #s{ns = Ns, chan = Chan}) ->
    Frame = encode(Ns, {block, Entry}),
    case byte_size(Frame) =< ?MAX_FRAME_BYTES of
        false ->
            %% A block whose framed size exceeds quod_link's 1 MiB cap would EXIT the RECEIVER's link
            %% (not merely be dropped), so we never push it — the pull path (with chunking) carries an
            %% oversized block. Degenerate, not the common path (same posture as quod_catchup:cap_bytes).
            S#s{dropped = S#s.dropped + 1};
        true ->
            _ = [quod_quic:send(Peer, Chan, Frame) || Peer <- fanout(quod_brahms:view(Ns))],
            S
    end.

%% Up to ?PUSH_FANOUT DISTINCT peers chosen at random from the view, via the shared Brahms sampler — a
%% fixed prefix would systematically starve the higher-address peers of every node's push set.
fanout(Peers) -> quod_brahms:take_random(?PUSH_FANOUT, lists:usort(Peers)).

%%%===================================================================
%%% wire
%%%===================================================================

%% Envelope is [safe] (known atoms only); the inner {block, #entry{}} carries a #transaction's Prolog
%% atoms, so it decodes WITHOUT [safe] — same trusted-fleet posture as quod_simplex/quod_catchup, and
%% SAFE against tampering because the block is verified against its commit cert before it is applied or
%% relayed. The split cert/hash/payload verify-before-decode frame (deferred.md §2) is a later slice.
encode(Ns, Msg) -> term_to_binary({feed, Ns, term_to_binary(Msg)}).

decode(Payload, Ns) ->
    try binary_to_term(Payload, [safe]) of
        {feed, Ns2, Bin} when Ns2 =:= Ns -> try binary_to_term(Bin) catch _:_ -> error end;
        _ -> error
    catch _:_ -> error end.
