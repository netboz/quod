-module(quod_feed).
-moduledoc """
Per-namespace **dissemination** endpoint — how a finalized block spreads from the small committee to
the non-voting crowd (replicas, subscribers) by **push-pull epidemic gossip over the Brahms overlay**,
so a change reaches far more nodes than a leader-star ever could. Every block carries the quorum
`#cert{}` that finalized it, and **every hop verifies that cert against the committee-as-of-that-slot
before it applies or re-pushes** — a tampering/equivocating relay is dropped, never propagated
(`doc/deferred.md` §4 P2; design `~/.claude/plans/quod-feed-dissemination.md`).

A per-namespace `gen_server` sibling on channel **`{feed, Ns}`**, after catch-up
and before the rebuildable runtime in the `m:quod_ns` `rest_for_one` chain (it
holds no state the others need). It has two halves:

- **Producer** (a committee Member): on each *live* commit `m:quod_simplex` publishes
  `{committed, Ns, Slot, Entry}` on the shared `{committed, Ns}` property; the feed **eager-pushes** the block to a
  small fanout of the node's `quod_brahms:view/1` (the Byzantine-resistant `sample/1` is reserved for
  the F2 anti-entropy pull-source selection). Never on the replay/rebuild path, so catching up
  never re-broadcasts history (`content-layer-design.md` §14 live-vs-replay). A completed certified
  catch-up publishes only `{certified_head, Ns, Slot}` on that property: this invalidates a stale cached
  snapshot and wakes registered followers, but carries no block and fires no historical event.
- **Relay / follower** (a caught-up non-member — see `follows/4`): a gossiped `{block, Entry}` for slot
  `H+1` is verified against the current committee and this process's pinned
  namespace/genesis domain (`quod_catchup:verify_forward/5`) and, if genuine,
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
-include("quod_transport_limits.hrl").

-export([start_link/2, stats/1, peer_ready/3,
         channel/1, progress_signal/2,
         recipient_register_frame/3, recipient_ack_frame/4,
         recipient_unregister_frame/3, decode_recipient/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([classify/2, encode/2, decode/2, digest_table/1, record_digest/3, ready/4, readiness_config_ok/1,
         fold_snapshot/3, test_recipient_state/2,
         test_recipient_control/5, test_recipient_commit/2,
         test_recipient_down/3, test_recipient_rows/1,
         test_set_snapshot/2, test_snapshot/1]).
-endif.

-define(PUSH_FANOUT,     4).             %% eager-push targets per fresh block (best-effort; anti-entropy backstops)
-define(INGEST_MS,       5000).          %% budget for ONE fast-path block's append+apply through quod_simplex
-define(PULL_SINK_MS,    30000).         %% budget for a whole anti-entropy WINDOW (up to ?WINDOW entries;
                                         %% matches quod_simplex's ?SINK_MS for the identical sink)
-define(ANTI_ENTROPY_MS, 3000).          %% base period of the anti-entropy digest round (jittered ±20%)
-define(MIN_ANTI_ENTROPY_MS, 200).       %% floor for the (operator-tunable) period — never busy-loop
-define(WINDOW,          256).           %% entries per anti-entropy pull window (matches quod_catchup's block cap)
-define(READY_FRESH_MS,  15000).         %% peer_ready freshness: a digest older than this is a dead/mute peer
                                         %% (5 rounds at the default period; readiness_config_ok/0 enforces
                                         %% the window spans ≥2 periods so one lost digest can't drop a peer)
-define(RECIPIENT_VERSION, 1).

-record(recipient, {
            link :: pid(),
            mref :: reference(),
            registration_id :: <<_:128>>,
            acked_height = 0 :: non_neg_integer(),
            in_flight = none :: none | non_neg_integer(),
            pending_height = none :: none | non_neg_integer()
           }).

-record(s, {ns       :: binary(),
            genesis_hash :: <<_:256>>,
            self     :: node_id(),
            ledger_root :: file:filename_all(),
            chan     :: binary(),                                       %% term_to_binary({feed, Ns}, [deterministic])
            digests  :: atom(),                  %% the per-ns liveness table (digest_table/1) this process owns
            %% cached consensus snapshot {Height, HistoryProjection, Syncing} — folded forward per commit/ingest,
            %% refetched once per anti-entropy round, so the O(followers) sync status calls per round on a
            %% member (Slice C's per-digest read) collapse to ~1. `none` = must (re)fetch. `Syncing` is
            %% exactly `quod_simplex:status`'s `syncing` flag — the value `follows/4` keys on (`not Syncing`).
            snap     = none :: none | {log_index(), quod_simplex:history_projection(), boolean()},
            pulling  = false :: false | pid(),   %% the in-flight anti-entropy pull worker (at most one)
            pushed   = 0 :: non_neg_integer(),   %% local commits we originated onto the feed
            ingested = 0 :: non_neg_integer(),   %% gossiped blocks we verified, applied, and relayed
            pulled   = 0 :: non_neg_integer(),   %% anti-entropy pull rounds we started
            %% Volatile height-wake recipients.  One authenticated node gets
            %% one row regardless of how many of its local consumers follow
            %% this namespace.  A row owns no history or authority: it merely
            %% keeps one correlated wake in flight and coalesces later heights.
            recipients = #{} :: #{<<_:256>> => #recipient{}},
            recipient_mrefs = #{} :: #{reference() => <<_:256>>},
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

-doc "The existing dissemination channel for one ontology namespace.".
-spec channel(binary()) -> binary().
channel(Ns) when is_binary(Ns) ->
    term_to_binary({feed, Ns}, [deterministic]).

-doc """
Recognize a feed frame as a freshness signal for one namespace.

This intentionally validates only the small safe outer envelope.  The inner
block or digest remains untrusted and is never decoded or accepted here.  A
caller may use `true` only to wake its ordinary certified-history verifier;
the signal is not history evidence and grants no authority.
""".
-spec progress_signal(binary(), binary()) -> boolean().
progress_signal(Payload, Ns)
  when is_binary(Payload), is_binary(Ns),
       byte_size(Payload) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    case outer_envelope(Payload, Ns) of
        {ok, _Inner} -> true;
        error -> false
    end;
progress_signal(_Payload, _Ns) ->
    false.

-doc "Build one request to receive correlated height wakes for an exact feed.".
-spec recipient_register_frame(binary(), <<_:256>>, <<_:128>>) -> binary().
recipient_register_frame(Ns, <<_:256>> = Anchor,
                         <<_:128>> = RegistrationId)
  when is_binary(Ns) ->
    encode(
      Ns,
      {recipient_register, ?RECIPIENT_VERSION, RegistrationId, Anchor}).

-doc "Acknowledge the exact correlated height last received on a feed link.".
-spec recipient_ack_frame(binary(), <<_:256>>, <<_:128>>,
                          non_neg_integer()) -> binary().
recipient_ack_frame(Ns, <<_:256>> = Anchor,
                    <<_:128>> = RegistrationId, Height)
  when is_binary(Ns), is_integer(Height), Height >= 0 ->
    encode(
      Ns,
      {recipient_ack, ?RECIPIENT_VERSION, RegistrationId, Anchor, Height}).

-doc "Remove one exact volatile feed-recipient registration.".
-spec recipient_unregister_frame(binary(), <<_:256>>, <<_:128>>) -> binary().
recipient_unregister_frame(Ns, <<_:256>> = Anchor,
                           <<_:128>> = RegistrationId)
  when is_binary(Ns) ->
    encode(
      Ns,
      {recipient_unregister, ?RECIPIENT_VERSION, RegistrationId, Anchor}).

-doc "Decode only the bounded, atom-safe recipient controls in a feed frame.".
-spec decode_recipient(binary(), binary()) ->
          {register, <<_:128>>, <<_:256>>}
        | {registered, <<_:128>>, <<_:256>>, non_neg_integer()}
        | {wake, <<_:128>>, <<_:256>>, non_neg_integer()}
        | {ack, <<_:128>>, <<_:256>>, non_neg_integer()}
        | {unregister, <<_:128>>, <<_:256>>}
        | error.
decode_recipient(Payload, Ns)
  when is_binary(Payload), is_binary(Ns),
       byte_size(Payload) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    case outer_envelope(Payload, Ns) of
        {ok, Inner} -> decode_recipient_inner(Inner);
        error -> error
    end;
decode_recipient(_Payload, _Ns) ->
    error.

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
    case quod_simplex:genesis_hash(Ns) of
        GenesisHash when is_binary(GenesisHash), byte_size(GenesisHash) =:= 32 ->
            Self = maps:get(node_id, Config),
            Chan = channel(Ns),
            quod_reg:subscribe({channel, Chan}),   %% gossiped blocks + digests on {feed, Ns}
            quod_reg:subscribe({committed, Ns}),   %% local live commits from quod_simplex
            %% the peer_ready liveness table: public so readers (`peer_ready/3`) never call into this process;
            %% named so they can derive it from Ns alone; owned here, so it dies (and fails readers closed)
            %% with the feed and is rebuilt empty on restart. Plain `set` — it is write-mostly (a digest per
            %% follower per round) and read only rarely (per admit), so read_concurrency would tax the wrong path.
            Digests = ets:new(digest_table(Ns), [named_table, public, set]),
            %% Inbound links belong to the transport, not this process.  A link
            %% may therefore outlive a killed feed after its one-shot recipient
            %% registration was delivered to the old owner (or to no owner
            %% during startup).  Reset only this feed's peer-opened links after
            %% subscribing: their source-side monitors reconnect and re-register,
            %% while unrelated channels and outbound links remain untouched.
            ok = quod_conn:reset_inbound_channel(Chan),
            arm_anti_entropy(),
            {ok, #s{ns = Ns, genesis_hash = GenesisHash, self = Self,
                    ledger_root = quod_ledger_store:ledger_dir(Config),
                    chan = Chan, digests = Digests}};
        _ ->
            {stop, missing_consensus_anchor}
    end.

handle_call(get_stats, _From, S) ->
    {Tracked, Fresh} = digest_counts(S#s.digests),
    {reply, #{pushed => S#s.pushed, ingested => S#s.ingested,
              pulled => S#s.pulled, dropped => S#s.dropped,
              digests => Tracked, fresh_digests => Fresh,
              recipients => map_size(S#s.recipients)}, S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

%% A local live commit: we are the ORIGIN for this block — eager-push it to the crowd (never ingest, we
%% already hold it). Fires only on the live commit path (quod_simplex publishes here from commit_block/
%% skip_block), never on rebuild/catch-up, so history is never re-broadcast. Also folds the snapshot
%% forward (this is how a MEMBER keeps its cache fresh between rounds without any status call).
handle_info({committed, Ns, Slot, #entry{} = Entry}, S = #s{ns = Ns}) ->
    S1 = local_head_advanced(
           Slot, Entry, S#s{pushed = S#s.pushed + 1}),
    {noreply, eager_push(Entry, S1)};
%% Catch-up/replay installed a certified head without creating a new live
%% event.  Wake recipients so their ordinary certified follower re-reads that
%% head, but do not fold the feed snapshot or gossip historical blocks.
handle_info({certified_head, Ns, Slot}, S = #s{ns = Ns})
  when is_integer(Slot), Slot >= 0 ->
    {noreply, local_head_advanced(Slot, certified, S)};
%% A gossiped block or digest from a peer on our {feed, Ns} channel. `Peer` is the sender's node id and
%% `Addr` its announced endpoint (both from the authenticated link header). The transport has already
%% learned `Peer => Addr`, so anti-entropy keeps the peer ID as its contact and catch-up responses remain
%% bound to that authenticated identity.
handle_info({quod_message, {{Peer, _Addr}, InLink}, Chan, Payload},
            S = #s{chan = Chan}) ->
    {noreply, inbound(Peer, InLink, Payload, S)};
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
handle_info({'DOWN', MRef, process, Pid, _Reason}, S) ->
    {noreply, recipient_down(MRef, Pid, S)};
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #s{ns = Ns, chan = Chan, recipients = Recipients}) ->
    maps:foreach(
      fun(_Peer, Recipient) -> retire_recipient(Recipient, true) end,
      Recipients),
    _ = try quod_reg:unsubscribe({channel, Chan}) catch _:_ -> ok end,
    _ = try quod_reg:unsubscribe({committed, Ns}) catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% inbound gossip: verify → ingest → relay (per-hop Byzantine check)
%%%===================================================================

inbound(_Peer, _InLink, Payload, S)
  when byte_size(Payload) > ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    drop(oversized, S);   %% drop oversized BEFORE decode — bound binary_to_term memory
inbound(Peer, InLink, Payload, S0) ->
    case decode_recipient(Payload, S0#s.ns) of
        {register, RegistrationId, Anchor} ->
            {{Height, _Projection, _Syncing}, S} = current(S0),
            recipient_control(
              Peer, InLink, {register, RegistrationId, Anchor}, Height, S);
        {ack, RegistrationId, Anchor, Height} ->
            recipient_control(
              Peer, InLink, {ack, RegistrationId, Anchor, Height},
              undefined, S0);
        {unregister, RegistrationId, Anchor} ->
            recipient_control(
              Peer, InLink, {unregister, RegistrationId, Anchor},
              undefined, S0);
        %% Responses and wakes belong to a remote registration owner.  A
        %% hosted feed never treats them as target-side commands.
        {registered, _, _, _} -> S0;
        {wake, _, _, _} -> S0;
        error ->
            inbound_gossip(Peer, Payload, S0)
    end.

inbound_gossip(Peer, Payload, S) ->
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
on_block(#entry{index = Slot} = Entry,
         S0 = #s{ns = Ns, genesis_hash = GenesisHash, self = Self}) ->
    {{Height, Projection, Syncing}, S} = current(S0),
    Committee = quod_simplex:history_committee(Projection),
    case follows(Self, Committee, Syncing, Height) of
        false -> drop(non_following, S);            %% a voter / still-syncing / unfounded node doesn't ingest pushes
        true  ->
            case classify(Slot, Height) of
                duplicate -> drop(duplicate, S);     %% already applied — loop suppression (benign gossip redundancy)
                gap       -> drop(gap, S);           %% ahead of H+1 — anti-entropy will re-pull the missing prefix
                next ->
                    case quod_catchup:verify_forward(
                           Ns, GenesisHash, Projection, Slot, [Entry]) of
                        {ok, [_], Projection1} ->
                            case ingest(
                                   Ns, [Entry], Projection1,
                                   ?INGEST_MS, live) of
                                ok         -> %% our height advanced to Slot — fold the snapshot forward too
                                              S1 = fold_snap(Entry, S),
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

%%%===================================================================
%%% authenticated volatile feed recipients
%%%===================================================================

%% A recipient receives only a correlated height hint.  The authenticated
%% link supplies the node identity; the payload supplies neither authority nor
%% an endpoint.  History still enters exclusively through certified follow.
recipient_control(
  <<_:256>> = Peer, Link,
  {register, <<_:128>> = RegistrationId, <<_:256>> = Anchor}, Height,
  S = #s{genesis_hash = Anchor})
  when is_pid(Link), is_integer(Height), Height >= 0 ->
    register_recipient(Peer, Link, RegistrationId, Height, S);
recipient_control(
  <<_:256>> = Peer, Link,
  {ack, <<_:128>> = RegistrationId, <<_:256>> = Anchor, Height},
  _CurrentHeight, S = #s{genesis_hash = Anchor})
  when is_pid(Link), is_integer(Height), Height >= 0 ->
    acknowledge_recipient(Peer, Link, RegistrationId, Height, S);
recipient_control(
  <<_:256>> = Peer, Link,
  {unregister, <<_:128>> = RegistrationId, <<_:256>> = Anchor},
  _CurrentHeight, S = #s{genesis_hash = Anchor})
  when is_pid(Link) ->
    unregister_recipient(Peer, Link, RegistrationId, S);
recipient_control(_Peer, _Link, _Control, _Height, S) ->
    S.

register_recipient(Peer, Link, RegistrationId, Height,
                   S0 = #s{ns = Ns, genesis_hash = Anchor,
                           recipients = Recipients0,
                           recipient_mrefs = MonitorRefs0}) ->
    case maps:get(Peer, Recipients0, undefined) of
        #recipient{link = Link, registration_id = RegistrationId} ->
            %% The ordered response on this live link cannot be overtaken.
            %% Treat an exact duplicate as the same registration, not another
            %% send or another monitor.
            S0;
        Old ->
            {Recipients1, MonitorRefs1} =
                case Old of
                    #recipient{link = OldLink, mref = OldMRef} ->
                        _ = erlang:demonitor(OldMRef, [flush]),
                        case OldLink =:= Link of
                            true -> ok;
                            false -> retire_recipient(Old, true)
                        end,
                        {maps:remove(Peer, Recipients0),
                         maps:remove(OldMRef, MonitorRefs0)};
                    undefined ->
                        {Recipients0, MonitorRefs0}
                end,
            MRef = erlang:monitor(process, Link),
            Recipient = #recipient{
                           link = Link, mref = MRef,
                           registration_id = RegistrationId,
                           in_flight = Height},
            quod_link:send_ordered(
              Link,
              encode(
                Ns,
                {recipient_registered, ?RECIPIENT_VERSION,
                 RegistrationId, Anchor, Height})),
            S0#s{recipients = Recipients1#{Peer => Recipient},
                 recipient_mrefs = MonitorRefs1#{MRef => Peer}}
    end.

acknowledge_recipient(
  Peer, Link, RegistrationId, Height,
  S = #s{ns = Ns, genesis_hash = Anchor, recipients = Recipients}) ->
    case maps:get(Peer, Recipients, undefined) of
        #recipient{link = Link, registration_id = RegistrationId,
                   in_flight = Height, pending_height = Pending} = Recipient ->
            Recipient1 =
                case Pending of
                    Next when is_integer(Next), Next > Height ->
                        quod_link:send_ordered(
                          Link,
                          encode(
                            Ns,
                            {recipient_wake, ?RECIPIENT_VERSION,
                             RegistrationId, Anchor, Next})),
                        Recipient#recipient{
                          acked_height = Height, in_flight = Next,
                          pending_height = none};
                    _ ->
                        Recipient#recipient{
                          acked_height = max(Height,
                                             Recipient#recipient.acked_height),
                          in_flight = none, pending_height = none}
                end,
            S#s{recipients = Recipients#{Peer => Recipient1}};
        _ ->
            %% Wrong peer, link, generation, or height is crossed/stale.
            S
    end.

unregister_recipient(Peer, Link, RegistrationId,
                     S = #s{recipients = Recipients}) ->
    case maps:get(Peer, Recipients, undefined) of
        #recipient{link = Link, registration_id = RegistrationId} ->
            remove_recipient(Peer, true, S);
        _ ->
            S
    end.

recipient_committed(Height, S = #s{recipients = Recipients})
  when is_integer(Height), Height >= 0 ->
    Recipients1 = maps:map(
                    fun(_Peer, Recipient) ->
                        queue_recipient_height(Height, Recipient, S)
                    end, Recipients),
    S#s{recipients = Recipients1}.

queue_recipient_height(
  Height,
  Recipient = #recipient{acked_height = Acked, in_flight = none,
                         link = Link, registration_id = RegistrationId},
  #s{ns = Ns, genesis_hash = Anchor}) when Height > Acked ->
    quod_link:send_ordered(
      Link,
      encode(
        Ns,
        {recipient_wake, ?RECIPIENT_VERSION,
         RegistrationId, Anchor, Height})),
    Recipient#recipient{in_flight = Height};
queue_recipient_height(
  Height, Recipient = #recipient{in_flight = InFlight,
                                 pending_height = Pending}, _S)
  when is_integer(InFlight), Height > InFlight ->
    Recipient#recipient{pending_height = newest_height(Height, Pending)};
queue_recipient_height(_Height, Recipient, _S) ->
    Recipient.

newest_height(Height, none) -> Height;
newest_height(Height, Existing) -> max(Height, Existing).

%% One local head-advance owner updates both recipient freshness and the
%% feed's cached consensus view.  A live commit carries the exact entry needed
%% to fold that view.  Catch-up carries only a certified height, so invalidate
%% the cache and let current/1 refresh it from Simplex on the next read.
local_head_advanced(Height, #entry{} = Entry, S) ->
    recipient_committed(Height, fold_snap(Entry, S));
local_head_advanced(Height, certified, S) ->
    recipient_committed(Height, S#s{snap = none}).

recipient_down(MRef, Pid,
               S = #s{recipient_mrefs = MonitorRefs,
                      recipients = Recipients}) ->
    case maps:get(MRef, MonitorRefs, undefined) of
        <<_:256>> = Peer ->
            case maps:get(Peer, Recipients, undefined) of
                #recipient{link = Pid, mref = MRef} ->
                    remove_recipient(Peer, false, S);
                _ ->
                    S#s{recipient_mrefs = maps:remove(MRef, MonitorRefs)}
            end;
        undefined ->
            S
    end.

remove_recipient(Peer, Close,
                 S = #s{recipients = Recipients,
                        recipient_mrefs = MonitorRefs}) ->
    case maps:take(Peer, Recipients) of
        {Recipient = #recipient{mref = MRef}, Recipients1} ->
            _ = erlang:demonitor(MRef, [flush]),
            retire_recipient(Recipient, Close),
            S#s{recipients = Recipients1,
                recipient_mrefs = maps:remove(MRef, MonitorRefs)};
        error ->
            S
    end.

retire_recipient(#recipient{link = Link}, true) ->
    _ = quod_link:close(Link),
    ok;
retire_recipient(#recipient{}, false) ->
    ok.

%% A node ingests pushed blocks (follows the feed) ONLY when it is a caught-up NON-member observer of a
%% founded namespace:
%%   - past genesis (`Height >= 1`): slot 1 and its committee are established only by the anchored
%%     catch-up owner. `verify_forward/5` also checks the slot-1 hash against `genesis_hash`, but the
%%     feed must not race boot recovery or become a second genesis-ingestion path;
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
            Snap = {maps:get(slot, St, 0),
                    maps:get(history_projection, St),
                    maps:get(syncing, St, true)},
            {Snap, S#s{snap = Snap}};
        _ -> {{0, quod_simplex:history_projection(), true}, S}
    end.

%% Fold a just-committed / just-ingested entry into the cached snapshot: advance height + the committee
%% projection TOGETHER (the as-of pairing). [DA#5] only on a contiguous entry (Slot = cached+1); on any gap
%% — e.g. a feed that restarted alone under rest_for_one while simplex kept committing — reset to `none` and
%% let the next use refetch. DTX controls also reset the cache: reducing one requires the exact per-group
%% phase history owned by Simplex/catch-up, while this cache is only an optimization. The next use reads the
%% already-applied authoritative projection from Simplex instead of creating a second phase-history owner.
fold_snap(Entry, S = #s{ns = Ns}) ->
    S#s{snap = fold_snapshot(Ns, Entry, S#s.snap)}.

%% The cached committee tracks the `peer_admitted` FACTS (the same fold `status.committee` reports today,
%% epoch length 1). When epoch-frozen validators land (`quod_simplex:active_validators/1`, deferred.md §3),
%% a block is verified against the FROZEN active set, not the per-commit facts — this fold and the meaning
%% of `status.committee` must migrate together, or the feed's cached committee would drift from the
%% verifying set. Fail-closed until then (a drifted snapshot mis-classifies → repull, never mis-verifies).
fold_snapshot(Ns, #entry{index = Slot} = Entry,
              {SnapSlot, Projection, Syncing}) when Slot =:= SnapSlot + 1 ->
    case quod_ledger:classify(Entry#entry.data) of
        {content, _} ->
            {Slot, quod_simplex:history_advance(Ns, Entry, Projection),
             Syncing};
        noop ->
            {Slot, quod_simplex:history_advance(Ns, Entry, Projection),
             Syncing};
        {controls, _Controls} -> none;
        invalid -> none
    end;
fold_snapshot(_Ns, _Entry, _Snap) -> none.

%% Drop the cached snapshot only while still syncing — see the anti_entropy handler.
invalidate_transient(S = #s{snap = {_, _, true}}) -> S#s{snap = none};
invalidate_transient(S) -> S.

%% Hand a verified, contiguous window to quod_simplex — the SOLE store writer. Reuses the catch-up sink
%% (append + committee fold + KB apply, contiguity-checked); a duplicate/non-contiguous window is
%% rejected there and surfaces as {error, _}. A verified next-block push is `live` for this settled
%% observer and drives P incrementally. An anti-entropy gap window is `replay`: P reconciles once at
%% its explicit ready edge, so best-effort effects are not reconstructed from missed history.
ingest(Ns, Entries, Projection, Timeout, Mode)
  when Mode =:= live; Mode =:= replay ->
    Source = {feed, Mode},
    try gen_server:call(quod_reg:via({quod_simplex, Ns}),
                        {sink_catchup, Source, Entries, Projection}, Timeout)
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
    {{Height, Projection, Syncing}, S} = current(S0),
    Committee = quod_simplex:history_committee(Projection),
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
    {{Height, Projection, Syncing}, S} = current(S0),
    Committee = quod_simplex:history_committee(Projection),
    if
        Height < PeerHi ->
            case S#s.pulling =:= false andalso follows(Self, Committee, Syncing, Height) of
                true  -> start_pull(Peer, Height + 1, Projection, S);
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
%% (the sole writer, contiguity-checked). `From > 1` here (a follower is past genesis), but the pinned
%% anchor still derives the signature domain for every mid-chain certificate. One worker
%% at a time (`pulling`); its `DOWN` clears the latch.
start_pull(Peer, From, Projection,
           S = #s{ns = Ns, genesis_hash = GenesisHash,
                  ledger_root = LedgerRoot}) ->
    {Pid, _Ref} = spawn_monitor(
        fun() ->
            Fetch = fun(F)  -> quod_catchup:pull(Ns, F, F + ?WINDOW - 1, Peer) end,
            Sink  = fun(Es, Projection1) ->
                        ingest(Ns, Es, Projection1,
                               ?PULL_SINK_MS, replay)
                    end,
            try
                quod_catchup:catch_up(
                  Ns, GenesisHash, Fetch, Sink, From, Projection,
                  #{ledger_root => LedgerRoot})
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
    case byte_size(Frame) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES of
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
    case outer_envelope(Payload, Ns) of
        {ok, Bin} -> try binary_to_term(Bin) catch _:_ -> error end;
        error -> error
    end.

%% Unlike the block codec, recipient control decoding never needs to create
%% atoms or materialize arbitrary history terms.  Keep the normalized shapes
%% here so both sides of the link share one wire owner.
decode_recipient_inner(Inner) ->
    try binary_to_term(Inner, [safe]) of
        {recipient_register, ?RECIPIENT_VERSION,
         <<_:128>> = RegistrationId, <<_:256>> = Anchor} ->
            {register, RegistrationId, Anchor};
        {recipient_registered, ?RECIPIENT_VERSION,
         <<_:128>> = RegistrationId, <<_:256>> = Anchor, Height}
          when is_integer(Height), Height >= 0 ->
            {registered, RegistrationId, Anchor, Height};
        {recipient_wake, ?RECIPIENT_VERSION,
         <<_:128>> = RegistrationId, <<_:256>> = Anchor, Height}
          when is_integer(Height), Height >= 0 ->
            {wake, RegistrationId, Anchor, Height};
        {recipient_ack, ?RECIPIENT_VERSION,
         <<_:128>> = RegistrationId, <<_:256>> = Anchor, Height}
          when is_integer(Height), Height >= 0 ->
            {ack, RegistrationId, Anchor, Height};
        {recipient_unregister, ?RECIPIENT_VERSION,
         <<_:128>> = RegistrationId, <<_:256>> = Anchor} ->
            {unregister, RegistrationId, Anchor};
        _ ->
            error
    catch _:_ ->
        error
    end.

%% One safe owner for the feed's wire envelope. Consumers which need only a
%% freshness hint stop here; the feed owner alone decodes the inner payload.
outer_envelope(Payload, Ns) ->
    try binary_to_term(Payload, [safe]) of
        {feed, Ns, Bin} when is_binary(Bin) -> {ok, Bin};
        _ -> error
    catch _:_ -> error end.

-ifdef(TEST).

test_recipient_state(Ns, <<_:256>> = Anchor) when is_binary(Ns) ->
    #s{ns = Ns, genesis_hash = Anchor, chan = channel(Ns)}.

test_recipient_control(Peer, Link, Control, Height, State) ->
    recipient_control(Peer, Link, Control, Height, State).

test_recipient_commit(Height, State) ->
    recipient_committed(Height, State).

test_recipient_down(MRef, Pid, State) ->
    recipient_down(MRef, Pid, State).

test_recipient_rows(#s{recipients = Recipients}) ->
    maps:map(
      fun(_Peer, #recipient{link = Link, mref = MRef,
                            registration_id = RegistrationId,
                            acked_height = Acked,
                            in_flight = InFlight,
                            pending_height = Pending}) ->
          #{link => Link, monitor => MRef,
            registration_id => RegistrationId,
            acked_height => Acked, in_flight => InFlight,
            pending_height => Pending}
      end, Recipients).

test_set_snapshot(Snapshot, S) ->
    S#s{snap = Snapshot}.

test_snapshot(#s{snap = Snapshot}) ->
    Snapshot.

-endif.
