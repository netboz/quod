-module(quod_feed).
-moduledoc """
Per-namespace dissemination over the existing Brahms overlay and history service.

Local live commits eager-push their canonical material entry. A settled
observer treats a received entry as a live notification and acquires its
selected ancestry through the same asynchronous, single-worker catch-up path
used for digest-driven gap repair. The sole Simplex writer persists complete
verified groups before applying or relaying any received material.

The feed coalesces consecutively received live heights into one receipt
interval. This is volatile delivery metadata, not a copy of history or proof
authority. Only verified entries inside that interval receive live apply and
eager relay; other fetched entries are replay. Restart, gaps and later replay
cannot recreate a live interval from the ledger. Already installed heights
retire receipts and suppress duplicate gossip. Reactions remain in Prolog.

Authenticated recipient registrations carry coalesced height wakes only.
Periodic anti-entropy digests maintain dissemination and admission liveness;
they neither certify history nor discover local readiness by polling. The
cached committee/height snapshot is invalidated on certified-head changes,
worker retirement or an unrepresentable projection transition. No owner
waits on network I/O, and one existing pull worker owns each acquisition.
""".
-behaviour(gen_server).
-include("quod_ledger.hrl").
-include("quod_transport_limits.hrl").

-export([start_link/2, stats/1, peer_ready/3,
         channel/1, progress_signal/2, progress_height/2,
         recipient_register_frame/3, recipient_ack_frame/4,
         recipient_unregister_frame/3, decode_recipient/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([encode/2, decode/2, digest_table/1, record_digest/3, ready/4, readiness_config_ok/1,
         fold_snapshot/3, test_recipient_state/2,
         test_recipient_control/5, test_recipient_commit/2,
         test_recipient_down/3, test_recipient_rows/1,
         test_set_snapshot/2, test_snapshot/1, test_pull_state/3, test_received/1]).
-endif.

-define(PUSH_FANOUT,     4).             %% eager-push targets per fresh block (best-effort; anti-entropy backstops)
-define(INGEST_MS,       5000).          %% existing live-group sink budget through quod_simplex
-define(PULL_SINK_MS,    30000).         %% budget for one verified anti-entropy group
                                         %% matches quod_simplex's ?SINK_MS for the identical sink
-define(ANTI_ENTROPY_MS, 3000).          %% base period of the anti-entropy digest round (jittered ±20%)
-define(MIN_ANTI_ENTROPY_MS, 200).       %% floor for the (operator-tunable) period — never busy-loop
-define(READY_LAG, 256).                %% existing admission-readiness tolerance in material heights
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
            chan     :: binary(),                                       %% term_to_binary({feed, Ns}, [deterministic])
            digests  :: atom(),                  %% the per-ns liveness table (digest_table/1) this process owns
            %% cached consensus snapshot {Height, HistoryProjection, Syncing} — folded forward per commit/ingest,
            %% refetched once per anti-entropy round, so the O(followers) sync status calls per round on a
            %% member (Slice C's per-digest read) collapse to ~1. `none` = must (re)fetch. `Syncing` is
            %% exactly `quod_simplex:status`'s `syncing` flag — the value `follows/4` keys on (`not Syncing`).
            snap     = none :: none | {log_index(), quod_simplex:history_projection(), boolean()},
            pulling  = false :: false | pid(),   %% the existing proof-acquisition worker
            pull_stage = none :: none | file:filename_all(),
            pull_observed = 0 :: non_neg_integer(),
            %% Receipt interval only, not a second history: consecutive live
            %% notifications received after the settled local prefix. The
            %% ordinary group verifier still supplies all material authority.
            received = none :: none | {pos_integer(), pos_integer(), term()},
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

-doc """
Read the claimed height from the feed's small digest shape.

The height is only a freshness hint from the authenticated peer. It never
authorizes or advances history. Large block frames are deliberately left
opaque here and return `unknown`.
""".
-spec progress_height(binary(), binary()) ->
          {ok, non_neg_integer()} | unknown | error.
progress_height(Payload, Ns)
  when is_binary(Payload), is_binary(Ns),
       byte_size(Payload) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
    case outer_envelope(Payload, Ns) of
        {ok, Inner} when byte_size(Inner) =< 64 ->
            try binary_to_term(Inner, [safe]) of
                {digest, Height} when is_integer(Height), Height >= 0 ->
                    {ok, Height};
                _ ->
                    unknown
            catch
                _:_ -> unknown
            end;
        {ok, _OpaqueBlock} ->
            unknown;
        error ->
            error
    end;
progress_height(_Payload, _Ns) ->
    error.

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
(`?READY_LAG`) of `JudgeHeight` (the caller's own applied height) — the reality read behind the
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
                    chan = Chan, digests = Digests}};
        _ ->
            {stop, missing_consensus_anchor}
    end.

handle_call({pull_stage, Path}, {Worker, _}, S = #s{pulling = Worker, pull_stage = none}) ->
    {reply, ok, S#s{pull_stage = Path}};
handle_call(pull_live_interval, {Worker, _}, S = #s{pulling = Worker, received = Received}) ->
    Interval = case Received of none -> replay; {First, Last, _} -> {live, First, Last} end,
    {reply, Interval, S};
handle_call(get_stats, _From, S) ->
    {Tracked, Fresh} = digest_counts(S#s.digests),
    {reply, #{pushed => S#s.pushed, ingested => S#s.ingested,
              pulled => S#s.pulled, dropped => S#s.dropped,
              digests => Tracked, fresh_digests => Fresh,
              recipients => map_size(S#s.recipients)}, S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

%% A local live commit: we are the ORIGIN for this block — eager-push it to the crowd (never ingest, we
%% already hold it). Simplex publishes here only for live material finality, never
%% for carriers or historical replay, so history is never re-broadcast. Also folds the snapshot
%% forward (this is how a MEMBER keeps its cache fresh between rounds without any status call).
handle_info({committed, Ns, Slot, Entry}, S = #s{ns = Ns}) ->
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
handle_info({feed_ingested, Worker, Entries, Interval}, S = #s{pulling = Worker}) ->
    %% Only the sole writer's successful acknowledgement reaches this seam.
    %% Historical rows are neither live events nor eager gossip.
    Live = [E || E <- Entries, live_height(quod_ledger:entry_index(E), Interval)],
    Next = lists:foldl(fun eager_push/2, S#s{ingested = S#s.ingested + length(Live)}, Live),
    {noreply, Next};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S = #s{pulling = Pid}) ->
    Next = cleanup_pull_stage(S#s{pulling = false, snap = none}),
    %% A newer receipt is a real dependency edge. Failure with no new receipt
    %% cannot turn worker retirement into a self-triggered retry loop.
    case S#s.received of
        {_, Last, Peer} when Last > S#s.pull_observed ->
            {noreply, start_pull(Peer, Next)};
        _ -> {noreply, Next}
    end;
handle_info({'DOWN', MRef, process, Pid, _Reason}, S) ->
    {noreply, recipient_down(MRef, Pid, S)};
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, S = #s{ns = Ns, chan = Chan, recipients = Recipients}) ->
    _ = cleanup_pull_stage(S),
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
        {block, Entry}                -> on_block(Peer, Entry, S);
        {digest, Hi} when is_integer(Hi), Hi >= 0 ->
            %% record the sender's liveness FIRST — every node keeps the table (a committee member is
            %% exactly the judge that never gets past the follows/eligibility gates below).
            record_digest(S#s.digests, Peer, Hi),
            on_digest(Peer, Hi, S);
        _                              -> S
    end.

%% A live notification is an observation, not a self-contained ancestry
%% proof. Coalesce consecutive receipts and let the existing pull worker
%% acquire the selected witness; the feed owner never waits on network I/O.
on_block(Peer, Entry, S0 = #s{self = Self}) ->
    Slot = quod_ledger:entry_index(Entry),
    {{Height, Projection, Syncing}, Captured} = current(S0),
    S = retire_live_heights(Height, Captured),
    case follows(Self, quod_simplex:history_committee(Projection), Syncing, Height) of
        false -> drop(non_following, S);
        true ->
            case observe_live_height(Slot, Height, Peer, S#s.received) of
                {ok, Received} ->
                    Next = S#s{received = Received},
                    case S#s.pulling of false -> start_pull(Peer, Next); _ -> Next end;
                {error, Reason} -> drop(Reason, S)
            end
    end.

observe_live_height(Slot, Height, _Peer, _Received) when Slot =< Height -> {error, duplicate};
observe_live_height(Slot, Height, Peer, none) when Slot =:= Height + 1 -> {ok, {Slot, Slot, Peer}};
observe_live_height(Slot, _Height, Peer, {First, Last, _}) when Slot =:= Last + 1 ->
    {ok, {First, Slot, Peer}};
observe_live_height(Slot, _Height, _Peer, {_, Last, _}) when Slot =< Last -> {error, duplicate};
observe_live_height(_, _, _, _) -> {error, gap}.

live_height(Height, {live, First, Last}) -> Height >= First andalso Height =< Last;
live_height(_, replay) -> false.

retire_live_heights(Height, S = #s{received = {_, Last, _}}) when Height >= Last -> S#s{received = none};
retire_live_heights(Height, S = #s{received = {First, Last, Peer}}) when Height >= First ->
    S#s{received = {Height + 1, Last, Peer}};
retire_live_heights(_, S) -> S.

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
local_head_advanced(Height, certified, S) ->
    recipient_committed(Height, retire_live_heights(Height, S#s{snap = none}));
local_head_advanced(Height, Entry, S) ->
    recipient_committed(Height, retire_live_heights(Height, fold_snap(Entry, S))).

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
%%     in its own engine. Recovery and observer ingestion have distinct owner
%%     capabilities; the feed must not compete with the active consensus owner.
follows(Self, Committee, Syncing, Height) ->
    Height >= 1
        andalso not Syncing
        andalso not lists:member(Self, Committee).

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

%% This is the shared content reducer over already-installed material.
%% DTX transitions need the owner's phase index and invalidate this cache.
fold_snapshot(Ns, Entry, {SnapSlot, Projection, Syncing}) ->
    #entry{index = Slot, data = Data} = quod_ledger:entry_view(Entry),
    case Slot =:= SnapSlot + 1 of
        true ->
            case quod_ledger:classify(Data) of
                {content, _} ->
                    {Slot, quod_simplex:history_advance(Ns, Entry, Projection),
                     Syncing};
                {controls, _Controls} -> none;
                _ -> none
            end;
        false -> none
    end;
fold_snapshot(_Ns, _Entry, _Snap) -> none.

%% Drop the cached snapshot only while still syncing — see the anti_entropy handler.
invalidate_transient(S = #s{snap = {_, _, true}}) -> S#s{snap = none};
invalidate_transient(S) -> S.

%% Simplex is the sole archive writer. The frozen receipt interval selects
%% live apply per entry; all other material in a shared group remains replay.
ingest(Server, Group, Timeout, Mode) ->
    try gen_server:call(Server, {sink_catchup, {feed, Mode}, Group}, Timeout)
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
                true  -> start_pull(Peer, S);
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
    NowMs - SeenAt =< ?READY_FRESH_MS andalso Height + ?READY_LAG >= JudgeHeight.

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
start_pull(Peer, S = #s{ns = Ns, genesis_hash = GenesisHash}) ->
    Deadline = quod_time:mono_ms() + ?PULL_SINK_MS,
    Owner = quod_reg:where({quod_simplex, Ns}),
    Feed = self(),
    {Pid, _Ref} = spawn_monitor(fun() ->
        _ = quod_process:kill_when_owner_dies(Feed, self()),
        Fetch = fun(Query, PullDeadline, Consume) ->
            quod_catchup:pull(Ns, Query, Peer, PullDeadline, Consume)
        end,
        Sink = fun(Group = #{entries := Entries}) ->
            Interval = gen_server:call(Feed, pull_live_interval, ?INGEST_MS),
            Timeout = case Interval of replay -> ?PULL_SINK_MS; _ -> ?INGEST_MS end,
            case ingest(Owner, Group, Timeout, Interval) of
                {ok, _} = Ok -> Feed ! {feed_ingested, self(), Entries, Interval}, Ok;
                {error, _} = Error -> Error
            end
        end,
        case quod_simplex:history_view({Owner, {Ns, GenesisHash}}, committed, Deadline) of
            {ok, #{slot := Height, projection := Projection, snapshot := Snapshot} = View} ->
                _ = quod_process:kill_when_owner_dies(Owner, self()),
                Path = quod_ledger_store:staging_path(Snapshot),
                ok = gen_server:call(Feed, {pull_stage, Path}, ?INGEST_MS),
                try
                    quod_catchup:catch_up(Ns, GenesisHash, Fetch, Sink, Height + 1, Projection,
                                          #{history_view => View, stage_path => Path})
                after _ = finish_pull_replay(Owner) end;
            {error, _} = Error -> Error
        end
    end),
    Observed = case S#s.received of none -> 0; {_, Last, _} -> Last end,
    S#s{pulling = Pid, pull_observed = Observed, pulled = S#s.pulled + 1}.

cleanup_pull_stage(S = #s{pull_stage = none}) -> S;
cleanup_pull_stage(S = #s{pull_stage = Path}) ->
    _ = file:delete(Path),
    S#s{pull_stage = none}.

finish_pull_replay(Owner) ->
    try gen_statem:call(Owner,
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
eager_push(Entry, S = #s{ns = Ns, chan = Chan}) ->
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

%% The envelope and inner control shape contain only protocol vocabulary.
%% A committed entry travels exactly once as the canonical blob owned by
%% quod_ledger; its decoded record is an endpoint-local view, never a second
%% wire identity. The split cert/hash/payload verify-before-decode frame
%% (deferred.md §2) is a later slice.
encode(Ns, {block, Entry}) ->
    {ok, EntryBlob} = quod_ledger:encode_entry(Entry),
    term_to_binary(
      {feed, Ns, term_to_binary({block_bytes, EntryBlob}, [deterministic])},
      [deterministic]);
encode(Ns, Msg) ->
    term_to_binary({feed, Ns, term_to_binary(Msg, [deterministic])},
                   [deterministic]).

decode(Payload, Ns) ->
    case outer_envelope(Payload, Ns) of
        {ok, Bin} -> decode_inner(Bin);
        error -> error
    end.

decode_inner(Bin) ->
    try binary_to_term(Bin, [safe]) of
        {block_bytes, EntryBlob} when is_binary(EntryBlob) ->
            case quod_ledger:decode_entry(EntryBlob) of
                {ok, Entry} -> {block, Entry};
                {error, _} -> error
            end;
        {block, _OldRecord} ->
            %% There is no record-carrying compatibility wire in this cut.
            error;
        Message ->
            Message
    catch _:_ ->
        error
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

test_pull_state(Pid, Observed, S) -> S#s{pulling = Pid, pull_observed = Observed}.
test_received(#s{received = Received, pulling = Pulling}) -> {Received, Pulling}.

test_set_snapshot(Snapshot, S) ->
    S#s{snap = Snapshot}.

test_snapshot(#s{snap = Snapshot}) ->
    Snapshot.

-endif.
