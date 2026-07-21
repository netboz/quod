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
  `{committed, Slot, Entry}` on the `{committed, Ns}` property; the feed **eager-pushes** the block to a
  small fanout of the node's `quod_brahms:view/1` (the Byzantine-resistant `sample/1` is reserved for
  the F2 anti-entropy pull-source selection). Never on the replay/rebuild path, so catching up
  never re-broadcasts history (`content-layer-design.md` §14 live-vs-replay).
- **Relay / follower** (a caught-up non-member — see `follows/4`): a gossiped `{block, Entry}` for slot
  `H+1` is verified against the current committee (`quod_catchup:verify_forward/4`) and, if genuine,
  handed to `m:quod_simplex` to append+apply (the sole store writer); then eager-pushed onward. A
  duplicate (`slot ≤ H`) is dropped and **never re-pushed** (loop suppression); a gap (`slot > H+1`) is
  dropped and recovered by anti-entropy.
- **Anti-entropy** (the completeness guarantee): every `?ANTI_ENTROPY_MS` a follower advertises its
  height (`{digest, Hi}`) to one `quod_brahms:sample/1` peer AND to every committee member; a behind
  node PULLs the gap, an ahead node replies its height so the sender pulls. The pull is the SAME
  trustless driver as cold-start catch-up (`quod_catchup:catch_up/6`) sourced from a live peer, so a
  block missed by eager push (loss, an out-of-fanout peer, a transient ingest error) is always
  recovered — and because members are always-known contacts, a caught-up observer keeps tracking the
  head even with no overlay.
- **Passive liveness** (the `peer_ready` readiness gate): every inbound digest is recorded as
  `Pk => {Height, SeenAt}` in a public named per-ns ETS table (written only by this process; one atom
  per operator-created namespace). `peer_ready/3` reads it DIRECTLY in the caller's process — the
  admission rule (`can_join :- peer_ready(Pk)` in the root ontology) consults it from inside
  `m:quod_prolog`, where a gen_server round-trip into the feed would deadlock. The digest sender is
  authenticated (link header + mutual TLS); the HEIGHT is unauthenticated content — this is liveness
  UX for admission, not a security boundary.

To avoid a sync `quod_simplex:status` call per inbound digest (O(followers) per round on a member), the
feed keeps a cached consensus snapshot `{Height, Committee, Syncing}`: folded forward on each local commit
and each ingest, refetched once per anti-entropy round (so a sync → settled transition is observed), and
reset on any contiguity gap — fail-closed by construction (a stale snapshot only mis-classifies a block,
never mis-verifies it).

**Built (F1 + F2):** eager-push + fast-path verify/ingest/relay, and digest-driven anti-entropy pull.
**Deferred:** IHAVE (per-block lazy advertisement, a push-latency tweak), the split cert/hash/payload
verify-before-decode frame (`doc/deferred.md` §2), and chunking for a single block over the frame cap.
""".
-behaviour(gen_server).
-include("quod_ledger.hrl").

-export([start_link/2, stats/1, peer_ready/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([classify/2, encode/2, decode/2, digest_table/1, record_digest/3, ready/4, readiness_config_ok/1,
         fold_snapshot/3]).
-endif.

-define(PUSH_FANOUT,     4).             %% eager-push targets per fresh block (best-effort; anti-entropy backstops)
-define(MAX_FRAME_BYTES, (1 bsl 20)).    %% drop an inbound frame ≥ 1 MiB before decode (matches quod_link)
-define(INGEST_MS,       5000).          %% budget for ONE fast-path block's append+apply through quod_simplex
-define(PULL_SINK_MS,    30000).         %% budget for a whole anti-entropy WINDOW (up to ?WINDOW entries;
                                         %% matches quod_simplex's ?SINK_MS for the identical sink)
-define(ANTI_ENTROPY_MS, 3000).          %% base period of the anti-entropy digest round (jittered ±20%)
-define(MIN_ANTI_ENTROPY_MS, 200).       %% floor for the (operator-tunable) period — never busy-loop
-define(WINDOW,          256).           %% entries per anti-entropy pull window (matches quod_catchup's block cap)
-define(READY_FRESH_MS,  15000).         %% peer_ready freshness: a digest older than this is a dead/mute peer
                                         %% (5 rounds at the default period; readiness_config_ok/0 enforces
                                         %% the window spans ≥2 periods so one lost digest can't drop a peer)

-record(s, {ns       :: binary(),
            self     :: node_id(),
            chan     :: binary(),                                       %% term_to_binary({feed, Ns}, [deterministic])
            digests  :: atom(),                  %% the per-ns liveness table (digest_table/1) this process owns
            %% cached consensus snapshot {Height, Committee, Syncing} — folded forward per commit/ingest,
            %% refetched once per anti-entropy round, so the O(followers) sync status calls per round on a
            %% member (Slice C's per-digest read) collapse to ~1. `none` = must (re)fetch. `Syncing` is
            %% exactly `quod_simplex:status`'s `syncing` flag — the value `follows/4` keys on (`not Syncing`).
            snap     = none :: none | {log_index(), [node_id()], boolean()},
            pulling  = false :: false | pid(),   %% the in-flight anti-entropy pull worker (at most one)
            pushed   = 0 :: non_neg_integer(),   %% local commits we originated onto the feed
            ingested = 0 :: non_neg_integer(),   %% gossiped blocks we verified, applied, and relayed
            pulled   = 0 :: non_neg_integer(),   %% anti-entropy pull rounds we started
            %% per-reason drop counters (bump via drop/2). `duplicate` (already have it, loop-suppressed) is
            %% benign gossip redundancy; `gap` is recovered by anti-entropy; `unverified` (bad cert) is the
            %% security-relevant one to watch. Pre-seeded to 0 so every reason is a stable metric series.
            dropped  = #{oversized => 0, non_following => 0, duplicate => 0,
                         gap => 0, unverified => 0, ingest_busy => 0}
                       :: #{atom() => non_neg_integer()}}).

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

-doc """
Is `Pk` a live, caught-up follower of `Ns`, as observed by THIS node? True iff its latest
authenticated feed digest is fresh (`?READY_FRESH_MS`) and its height is within one catch-up window
(`?WINDOW`) of `JudgeHeight` (the caller's own applied height) — the reality read behind the
`peer_ready/1` admission predicate.

Runs in the CALLER's process: a direct read of the public digest table, never a call into the feed —
the predicate consults this from inside `m:quod_prolog` (both on the submitter's `admit` proof and on
every validator's membership-verdict re-proof), where a gen_server round-trip would deadlock. Fail-
closed: no table (feed down/restarting) or no digest ⇒ `false`.
""".
-spec peer_ready(binary(), binary(), non_neg_integer()) -> boolean().
peer_ready(Ns, Pk, JudgeHeight) ->
    try ets:lookup(binary_to_existing_atom(digest_table_name(Ns), utf8), Pk) of
        [{_, Height, SeenAt}] -> ready(Height, SeenAt, quod_time:mono_ms(), JudgeHeight);
        []                    -> false
    catch
        %% no such atom (the feed never created this ns's table) or absent table: fail closed. Using
        %% binary_to_EXISTING_atom on the read path means a lookup miss never MINTS an atom — init and the
        %% writer create it via digest_table/1; a read can only ever resolve one that already exists.
        error:badarg -> false
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    case readiness_config_ok() of
        {error, Reason} -> {stop, {bad_config, Reason}};   %% fail-fast: a mis-tuned digest period silently
                                                           %% breaks admission — refuse to start, don't hide it
        ok              -> start(Ns, Config)
    end.

start(Ns, Config) ->
    Self = maps:get(node_id, Config),
    Chan = term_to_binary({feed, Ns}, [deterministic]),
    quod_reg:subscribe({channel, Chan}),   %% gossiped blocks + digests on {feed, Ns}
    quod_reg:subscribe({committed, Ns}),   %% local live commits from quod_simplex
    %% the peer_ready liveness table: public so readers (`peer_ready/3`) never call into this process;
    %% named so they can derive it from Ns alone; owned here, so it dies (and fails readers closed)
    %% with the feed and is rebuilt empty on restart. Plain `set` — it is write-mostly (a digest per
    %% follower per round) and read only rarely (per admit), so read_concurrency would tax the wrong path.
    Digests = ets:new(digest_table(Ns), [named_table, public, set]),
    arm_anti_entropy(),
    {ok, #s{ns = Ns, self = Self, chan = Chan, digests = Digests}}.

handle_call(get_stats, _From, S) ->
    {Tracked, Fresh} = digest_counts(S#s.digests),
    {reply, #{pushed => S#s.pushed, ingested => S#s.ingested,
              pulled => S#s.pulled, dropped => S#s.dropped,
              digests => Tracked, fresh_digests => Fresh}, S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

%% A local live commit: we are the ORIGIN for this block — eager-push it to the crowd (never ingest, we
%% already hold it). Fires only on the live commit path (quod_simplex publishes here from commit_block/
%% skip_block), never on rebuild/catch-up, so history is never re-broadcast. Also folds the snapshot
%% forward (this is how a MEMBER keeps its cache fresh between rounds without any status call).
handle_info({committed, Slot, #entry{data = Data} = Entry}, S) ->
    {noreply, eager_push(Entry, fold_snap(Slot, Data, S#s{pushed = S#s.pushed + 1}))};
%% A gossiped block or digest from a peer on our {feed, Ns} channel. `Peer` is the sender's node id and
%% `Addr` its announced endpoint (both from the authenticated link header). The transport has already
%% learned `Peer => Addr`, so anti-entropy keeps the peer ID as its contact and catch-up responses remain
%% bound to that authenticated identity.
handle_info({quod_message, {{Peer, _Addr}, _InLink}, Chan, Payload}, S = #s{chan = Chan}) ->
    {noreply, inbound(Peer, Payload, S)};
handle_info({quod_message, _, _OtherChan, _}, S) -> {noreply, S};   %% Brahms / another namespace
%% Anti-entropy round: advertise our height to every committee member (they judge admission readiness from
%% it) and to one Byzantine-resistant sampled peer, then re-arm. A peer that is behind pulls the gap from
%% us; if WE are behind, its reply digest makes us pull from it.
handle_info(anti_entropy, S) ->
    arm_anti_entropy(),
    %% invalidate the snapshot once per round ONLY while still syncing (a Syncing → settled transition
    %% happens inside quod_simplex with no event to us, so a joiner/resuming node must refetch to observe it).
    %% A SETTLED node (`Syncing=false`) keeps its fold-forward snapshot — its height is already tracked by the
    %% commit/ingest fold and the pull-worker DOWN reset, so a per-round status call would be pure waste (the
    %% very O(followers)/round cost this cache exists to remove).
    {noreply, send_digest(invalidate_transient(S))};
%% The anti-entropy pull worker finished (or died) — clear the in-flight latch so the next round can pull.
%% It may have sunk windows out-of-process (advancing our height invisibly to us), so drop the snapshot
%% too — the next use refetches. (Link lifecycle is owned by the transport now: we send fire-and-forget
%% via quod_quic:send/3 and never monitor links ourselves, so the only process we monitor is the pull worker.)
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S = #s{pulling = Pid}) ->
    {noreply, S#s{pulling = false, snap = none}};
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #s{ns = Ns, chan = Chan}) ->
    _ = try quod_reg:unsubscribe({channel, Chan}) catch _:_ -> ok end,
    _ = try quod_reg:unsubscribe({committed, Ns}) catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% inbound gossip: verify → ingest → relay (per-hop Byzantine check)
%%%===================================================================

inbound(_Peer, Payload, S) when byte_size(Payload) > ?MAX_FRAME_BYTES ->
    drop(oversized, S);   %% drop oversized BEFORE decode — bound binary_to_term memory
inbound(Peer, Payload, S) ->
    case decode(Payload, S#s.ns) of
        {block, #entry{} = Entry}      -> on_block(Entry, S);
        {digest, Hi} when is_integer(Hi), Hi >= 0 ->
            %% record the sender's liveness FIRST — every node keeps the table (a committee member is
            %% exactly the judge that never gets past the follows/eligibility gates below).
            record_digest(S#s.digests, Peer, Hi),
            on_digest(Peer, Hi, S);
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
on_block(#entry{index = Slot, data = Data} = Entry, S0 = #s{ns = Ns, self = Self}) ->
    {{Height, Committee, Syncing}, S} = current(S0),
    case follows(Self, Committee, Syncing, Height) of
        false -> drop(non_following, S);            %% a voter / still-syncing / unfounded node doesn't ingest pushes
        true  ->
            case classify(Slot, Height) of
                duplicate -> drop(duplicate, S);     %% already applied — loop suppression (benign gossip redundancy)
                gap       -> drop(gap, S);           %% ahead of H+1 — anti-entropy will re-pull the missing prefix
                next ->
                    case quod_catchup:verify_forward(Ns, Committee, Slot, [Entry]) of
                        {ok, [_], _} ->
                            case ingest(Ns, [Entry], ?INGEST_MS, live) of
                                ok         -> %% our height advanced to Slot — fold the snapshot forward too
                                              S1 = fold_snap(Slot, Data, S),
                                              eager_push(Entry, S1#s{ingested = S1#s.ingested + 1});
                                {error, _} -> drop(ingest_busy, S)   %% verified but consensus busy; anti-entropy re-pulls
                            end;
                        {error, _} -> drop(unverified, S)   %% bad cert ⇒ drop, NEVER relay (the one to watch)
                    end
            end
    end.

%% Bump one per-reason drop counter. Reasons are pre-seeded in #s so the metric series are stable.
drop(Reason, S = #s{dropped = D}) ->
    S#s{dropped = maps:update_with(Reason, fun(C) -> C + 1 end, 1, D)}.

%% A node ingests pushed blocks (follows the feed) ONLY when it is a caught-up NON-member observer of a
%% founded namespace:
%%   - past genesis (`Height >= 1`): slot 1 and its committee are established only by the anchored
%%     catch-up path; ingesting a slot-1 push would bypass the `genesis_hash` anchor (verify_forward
%%     accepts a `cert=none` genesis on trust) and let a peer forge our origin;
%%   - not still syncing (`not Syncing`): quod_simplex's own boot-sync / gap-fill worker owns ingestion
%%     while it runs — racing it on the store churns/aborts the sync. Once settled (`Syncing=false`) the
%%     feed takes over as the observer's completeness path (F1 one-puller handoff);
%%   - not a committee voter (`Self ∉ Committee`): a member advances via consensus and finalizes the slot
%%     in its own engine; sinking a copy through the catch-up path advances the store without pruning the
%%     engine, wedging the just-committed slot in `commit_buf` forever.
follows(Self, Committee, Syncing, Height) ->
    Height >= 1
        andalso not Syncing
        andalso not lists:member(Self, Committee).

%% Slot vs our contiguous height: already-have / the next block / a gap (out of order).
-spec classify(slot(), log_index()) -> duplicate | next | gap.
classify(Slot, Height) when Slot =< Height     -> duplicate;
classify(Slot, Height) when Slot =:= Height + 1 -> next;
classify(_Slot, _Height)                        -> gap.

%% Our contiguous committed height, current validator set (= committee-as-of-(H+1)), and `syncing` flag,
%% as a cached snapshot threaded through the state. On a hit, return the cache; on a miss, ONE status call
%% (quod_simplex is the single source of truth). If consensus is unreachable the fail-closed triple
%% `{0,[],true}` makes `follows/4` false (we don't follow while consensus is down) — and it is NEVER cached,
%% so a transient timeout can't poison the snapshot. Height and committee always come from ONE read (the
%% as-of pairing: the committee used to verify slot H+1 is committee-as-of-H), so a whole-snapshot staleness
%% only ever MIS-CLASSIFIES a block (→ drop → anti-entropy repull), never mis-verifies.
current(S = #s{snap = {_, _, _} = Snap}) -> {Snap, S};
current(S = #s{ns = Ns, snap = none}) ->
    case quod_simplex:status(Ns) of
        St when map_size(St) > 0 ->
            Snap = {maps:get(slot, St, 0), maps:get(committee, St, []), maps:get(syncing, St, true)},
            {Snap, S#s{snap = Snap}};
        _ -> {{0, [], true}, S}   %% consensus unreachable: fail-closed (Syncing=true ⇒ don't follow), never cached
    end.

%% Fold a just-committed / just-ingested entry into the cached snapshot: advance height + the committee
%% projection TOGETHER (the as-of pairing). [DA#5] only on a contiguous entry (Slot = cached+1); on any gap
%% — e.g. a feed that restarted alone under rest_for_one while simplex kept committing — reset to `none` and
%% let the next use refetch. `noop` skips fold the committee to identity.
fold_snap(Slot, Data, S) -> S#s{snap = fold_snapshot(Slot, Data, S#s.snap)}.

%% The cached committee tracks the `peer_admitted` FACTS (the same fold `status.committee` reports today,
%% epoch length 1). When epoch-frozen validators land (`quod_simplex:active_validators/1`, deferred.md §3),
%% a block is verified against the FROZEN active set, not the per-commit facts — this fold and the meaning
%% of `status.committee` must migrate together, or the feed's cached committee would drift from the
%% verifying set. Fail-closed until then (a drifted snapshot mis-classifies → repull, never mis-verifies).
fold_snapshot(Slot, Data, {SnapSlot, Committee, Syncing}) when Slot =:= SnapSlot + 1 ->
    {Slot, quod_simplex:apply_committee_delta(Data, Committee), Syncing};
fold_snapshot(_Slot, _Data, _Snap) -> none.

%% Drop the cached snapshot only while still syncing — see the anti_entropy handler.
invalidate_transient(S = #s{snap = {_, _, true}}) -> S#s{snap = none};
invalidate_transient(S) -> S.

%% Hand a verified, contiguous window to quod_simplex — the SOLE store writer. Reuses the catch-up sink
%% (append + committee fold + KB apply, contiguity-checked); a duplicate/non-contiguous window is
%% rejected there and surfaces as {error, _}. A verified next-block push is `live` for this settled
%% observer and drives P incrementally. An anti-entropy gap window is `replay`: P reconciles once at
%% its explicit ready edge, so best-effort effects are not reconstructed from missed history.
ingest(Ns, Entries, Timeout, Mode) when Mode =:= live; Mode =:= replay ->
    Source = {feed, Mode},
    try gen_server:call(quod_reg:via({quod_simplex, Ns}),
                        {sink_catchup, Source, Entries}, Timeout)
    catch exit:_ -> {error, unavailable} end.

%%%===================================================================
%%% anti-entropy — the completeness path (gap repair by verified pull)
%%%===================================================================

arm_anti_entropy() -> erlang:send_after(jitter(anti_entropy_period()), self(), anti_entropy).

%% The effective digest / anti-entropy period (ms): operator-tunable `feed_anti_entropy_ms`, floored so a
%% mistyped/zero value can never turn the timer into a busy loop (mirrors quod_simplex's delta_ms guard).
%% Read by both the boot consistency check (readiness_config_ok/0) and every round's re-arm.
anti_entropy_period() ->
    case application:get_env(quod, feed_anti_entropy_ms, ?ANTI_ENTROPY_MS) of
        N when is_integer(N), N >= ?MIN_ANTI_ENTROPY_MS -> N;
        _                                               -> ?ANTI_ENTROPY_MS
    end.

%% Guard the freshness↔period coupling at boot. A candidate proves liveness by digesting to the committee
%% every `anti_entropy_period()` ms; a member admits it only while that digest is fresher than
%% ?READY_FRESH_MS. So a node digesting SLOWER than the window can NEVER be admitted — its rows go stale
%% between rounds and every member judges it dead, refusing the admit with no error (the height claim is
%% not an error). We require the window to span at least two periods (one lost digest can't drop a live
%% candidate) and refuse to start otherwise, so the misconfig surfaces at boot instead of as silently-
%% wedged growth. The period is a NODE-LOCAL transport knob (not committed policy), so this is a per-node
%% boot check; a value changed at RUNTIME (application:set_env) is not re-checked — tune via config, not a
%% live poke. (The freshness gauge in a later slice makes a stale-but-live candidate observable too.)
readiness_config_ok() -> readiness_config_ok(anti_entropy_period()).

readiness_config_ok(Period) when is_integer(Period), Period * 2 =< ?READY_FRESH_MS -> ok;
readiness_config_ok(Period) -> {error, {feed_anti_entropy_ms_too_slow, Period, readiness_window, ?READY_FRESH_MS}}.

%% ±20% jitter so a fleet doesn't synchronise its digest rounds into a thundering herd.
jitter(Base) -> Base - (Base div 5) + rand:uniform(2 * (Base div 5) + 1) - 1.

%% Advertise our contiguous height to EVERY committee member plus ONE peer drawn from the Byzantine-
%% resistant sample. We only need to reconcile as a FOLLOWER (a committee member is authoritative), so an
%% unfounded / member / mid-catch-up node stays silent. Members get a digest every round because they judge
%% admission readiness from it (`peer_ready/3` — a rotating/sampled schedule is too sparse for the
%% ?READY_FRESH_MS window and loss-fragile; ≤5 members × a ~30-node crowd is trivial load), and their
%% ahead-reply keeps an overlay-less observer tracking the head. Sampled-peer selection uses `sample/1`
%% (not `view/1`): an eclipse biasing whom we PULL from is a real attack; the sampler resists it, and
%% every pulled block is cert-verified regardless.
send_digest(S0 = #s{ns = Ns, self = Self, chan = Chan}) ->
    {{Height, Committee, Syncing}, S} = current(S0),
    case follows(Self, Committee, Syncing, Height) of
        false -> S;
        true  ->
            Frame = encode(Ns, {digest, Height}),
            _ = [quod_quic:send(Member, Chan, Frame) || Member <- Committee],
            case pick_peer(quod_brahms:sample(Ns)) of
                none -> S;
                Peer -> _ = quod_quic:send(Peer, Chan, Frame), S
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
on_digest(Peer, PeerHi, S0 = #s{ns = Ns, self = Self, chan = Chan}) ->
    {{Height, Committee, Syncing}, S} = current(S0),
    if
        Height < PeerHi ->
            case S#s.pulling =:= false andalso follows(Self, Committee, Syncing, Height) of
                true  -> start_pull(Peer, Height + 1, Committee, S);
                false -> S   %% already pulling, or not an eligible follower
            end;
        Height > PeerHi -> _ = quod_quic:send(Peer, Chan, encode(Ns, {digest, Height})), S;   %% let them pull from us
        true            -> S
    end.

%%%===================================================================
%%% passive liveness — the digest table behind peer_ready/3
%%%===================================================================

%% The per-ns table's atom, minted here (creator/writer path). One atom per namespace — bounded: namespaces
%% are operator-created (their lifecycle, atoms included, is a known open topic app-wide). The READ path
%% (peer_ready/3) resolves the SAME name via binary_to_existing_atom, so it can never mint a fresh atom.
digest_table(Ns) -> binary_to_atom(digest_table_name(Ns), utf8).

digest_table_name(Ns) -> <<"quod_feed_digests_", Ns/binary>>.

%% Record an authenticated digest sender's height. Only real (pubkey) ids are tracked — a no-identity/
%% test id is an address tuple, which can never be a `peer_ready` admission candidate.
record_digest(Table, Pk, Height) when is_binary(Pk) ->
    true = ets:insert(Table, {Pk, Height, quod_time:mono_ms()});   %% monotonic: node-local age, NTP-immune
record_digest(_Table, _NonPubkey, _Height) -> true.

%% The pure readiness verdict: the digest is fresh AND its height is within one pull window of the
%% judge's own applied height (a candidate any further behind would join a t=0 quorum mid-catch-up).
ready(Height, SeenAt, NowMs, JudgeHeight) ->
    NowMs - SeenAt =< ?READY_FRESH_MS andalso Height + ?WINDOW >= JudgeHeight.

%% Observability (metrics): how many peers this node tracks a liveness digest for, and how many of those
%% are FRESH (digested within ?READY_FRESH_MS) — i.e. how many peers are currently liveness-admittable.
%% Scans the (small, fleet-sized) table; runs only in the owning feed process on the ~5s stats poll.
digest_counts(Table) ->
    Now = quod_time:mono_ms(),
    ets:foldl(fun({_Pk, _H, SeenAt}, {Sz, Fr}) ->
                  {Sz + 1, Fr + case Now - SeenAt =< ?READY_FRESH_MS of true -> 1; false -> 0 end}
              end, {0, 0}, Table).

%% Reconcile the gap by running the SAME trustless catch-up driver used at cold-start, but sourced from a
%% live sampled peer (`Contact = Addr`) instead of a boot seed: pull a window via quod_catchup, which
%% verifies each entry's cert and transactions against the committee it folds forward, then sinks it
%% through quod_simplex
%% (the sole writer, contiguity-checked). `From > 1` here (a follower is past genesis), so the genesis
%% anchor is skipped — every block is proven inductively from the committee we already hold. One worker
%% at a time (`pulling`); its `DOWN` clears the latch.
start_pull(Peer, From, Committee, S = #s{ns = Ns}) ->
    {Pid, _Ref} = spawn_monitor(
        fun() ->
            Fetch = fun(F)  -> quod_catchup:pull(Ns, F, F + ?WINDOW - 1, Peer) end,
            Sink  = fun(Es) -> ingest(Ns, Es, ?PULL_SINK_MS, replay) end,
            try
                quod_catchup:catch_up(Ns, <<>>, Fetch, Sink, From, Committee)
            after
                %% Close even a failed or partial pull at its valid durable prefix. Simplex sent
                %% every Prolog apply cast, so its ready edge cannot overtake the final apply.
                _ = finish_pull_replay(Ns)
            end
        end),
    S#s{pulling = Pid, pulled = S#s.pulled + 1}.

finish_pull_replay(Ns) ->
    try gen_statem:call(quod_reg:via({quod_simplex, Ns}),
                        finish_feed_replay, ?PULL_SINK_MS)
    catch exit:_ -> {error, unavailable}
    end.

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
            drop(oversized, S);
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
