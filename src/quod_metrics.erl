-module(quod_metrics).
-moduledoc """
Prometheus metrics for quod, served at `GET /metrics` on `metrics_port` (default 14568).

Every series carries a constant **`node_id`** label — this node's identity (`kp_<hex>`, from
`m:quod_identity`) — so a fleet-wide Prometheus tells nodes apart by their stable pubkey rather than a
volatile host:port. Per-namespace series add a **`namespace`** label.

Two collection paths:

  * **Poll (5s).** Scalar gauges are refreshed from each subsystem's `stats/1`
    (`m:quod_brahms`, `m:quod_simplex`, `m:quod_prolog`, `m:quod_runtime`, `m:quod_feed`). Cumulative counts are exposed
    as gauges set to the running total (use `rate()`/`increase()` in Grafana).
  * **Event.** The LIVE `{committed, Ns}` event carries its target namespace and drives finalized-transaction size and
    author metrics (never replay — see `quod_simplex:publish_feed/3`). The submitting
    Prolog process records end-to-end latency and authoritative retry outcomes; the
    proposer records one batching sample per proposed block; completion of an
    origin-owned submission records how many internal retargets it needed.

| metric | type | extra labels | what it means (plain) |
| ------ | ---- | ------------ | --------------------- |
| `quod_up` | gauge | | 1 while the node is running |
| `quod_brahms_*{namespace}` | gauge | | peer discovery plus each node's bounded, signed estimate of total live population |
| `quod_consensus_slot/committed/approved/last_applied/committee_size{namespace}` | gauge | | block numbers (newest / final / votable / applied) and how many nodes may vote |
| `quod_consensus_pipeline_gap{namespace}` | gauge | | blocks with enough votes but not yet final (stays 0-2 by design) |
| `quod_consensus_appends/proposals/batched_txs/commits/submitted/skips{namespace}` | gauge | | running totals of change and block activity |
| `quod_consensus_batch_window_ms{namespace}` | gauge | | configured time a proposer waits for more transactions before sealing a block |
| `quod_consensus_batch_size/batch_wait_ms{namespace}` | histogram | | transactions per proposed block and actual collection time |
| `quod_consensus_pending{namespace}` | gauge | | change requests waiting to be made final right now |
| `quod_consensus_append_busy/redirect/bad{namespace}` | gauge | | running totals of turned-away change requests, by reason |
| `quod_consensus_custody_depth/custody_ready/custody_bytes{namespace}` | gauge | | origin-owned signed submissions retained until local durable resolution, the subset ready for placement, and their encoded byte budget |
| `quod_consensus_ingress_retargets{namespace}` | gauge | | running total of retained submissions placed again after authoritative exclusion from an earlier slot |
| `quod_consensus_ingress_retarget_hops{namespace}` | histogram | | internal retarget count per completed origin-owned submission; zero means its first placement resolved |
| `quod_consensus_is_validator{namespace}` | gauge | | 1 if this node may vote (it actually votes only when `syncing` is 0) |
| `quod_consensus_syncing{namespace}` | gauge | | 1 while catching up / confirming the latest block, 0 once up to date |
| `quod_consensus_progress_slot/progress_phase/progress_quorum_ready{namespace}` | gauge | | oldest unfinished slot, its phase (0 idle, 1 proposal, 2 notarization, 3 commit), and whether enough connected validators have freshly reported they are caught up |
| `quod_consensus_progress_timeouts/quorum_pauses{namespace}` | gauge | | watchdog expirations and complaints deliberately withheld while fewer than a quorum were ready |
| `quod_consensus_head_*_votes/head_complaint_signed{namespace}` | gauge | | verified finality evidence for the oldest unfinished block and this node's own skip decision |
| `quod_consensus_missing_certified_blocks{namespace}` | gauge | | quorum-approved in-flight blocks whose content this node is retrieving from another validator |
| `quod_consensus_signing_journal_vote_sync_seconds{namespace}` | histogram | | time to make one local vote decision crash-durable before its signature is sent |
| `quod_consensus_redrives/weak_cert_waits{namespace}` | gauge | | running totals: proposals re-sent while waiting, and blocks held back for lack of votes |
| `quod_consensus_ahead_gap{namespace}` | gauge | | how many final blocks the network is ahead of this node (0 = up to date) |
| `quod_runtime_healthy/handlers_active/subscriptions_active/reactions_active/source_targets_active/source_interests_active/source_views_active/source_views_ready/source_views_building/source_views_unreachable/p_height/e_frontier/queue_len{namespace}` | gauge | | the P tier: live flag, active founding handlers, local subscription/reaction catalogue and certified source-view states, rebuilt-through height, effect-release frontier, queued events |
| `quod_runtime_reconciles/collapses/dropped_events/rejected_dynamic/rejected_subscriptions{namespace}` | gauge | | running totals: full P rebuilds, work collapsed into a rebuild, dropped events, refused executable declarations, and malformed subscription clauses |
| `quod_runtime_reaction_candidates/matches/reactions_executed/reaction_inert/reaction_failures{namespace}` | gauge | | running totals for local and subscribed reaction selection, Erlog matches, completed handlers, non-local/ambiguous executors, and handler failures |
| `quod_runtime_reaction_seconds{namespace,result}` | histogram | | local and subscribed reaction matching, owner resolution, and handler time by bounded result |
| `quod_runtime_heavy_pending/heavy_running/heavy_superseded/heavy_rejected/heavy_failures{namespace}` | gauge | | bounded heavy background work: queued, running, coalesced, rejected by limits, and failed |
| `quod_foreign_follow_*` / `quod_foreign_projection_*` | gauge | | node-wide certified-follow targets, consumers, work, memory, health, traffic and rebuild totals; no target namespace label is exposed |
| `quod_effect_custody_*` | gauge | | node-wide direct-effect rows (including the group-active subset), reservations, and the committed capacity policy projected from root |
| `quod_prolog_applied/applies/rejects/proves/conflicts{namespace}` | gauge | | this node's stored-data activity (written / rejected / queried) |
| `quod_prolog_parked{namespace}` | gauge | | writes waiting here for their change to be made final |
| `quod_prolog_park_timeouts{namespace}` | gauge | | running total of writes whose final outcome was still unknown when their caller deadline elapsed |
| `quod_prolog_proof_workers/scope_workers{namespace}` | gauge | | origin proofs and selected proof scopes currently using a frozen data snapshot |
| `quod_prolog_kb_memory_words{namespace}` | gauge | | Erlang VM words used by the committed knowledge-base ETS table |
| `quod_prolog_kb_history_predicates{namespace}` | gauge | | predicates retaining an older version because a query still needs it |
| `quod_feed_pushed/ingested/pulled{namespace}` | gauge | | running totals of blocks spread / received / pulled to fill gaps |
| `quod_feed_dropped{namespace}` | gauge | `reason` | blocks thrown away, by reason (duplicate / gap / unverified / ...) |
| `quod_feed_digests/fresh_digests{namespace}` | gauge | | nodes sending 'alive' heartbeats / of those, still fresh |
| `quod_tx_commit_latency_ms{namespace}` | histogram | | submit → committed-and-applied, measured on the SUBMITTING node with one monotonic clock (one sample per change, at its author) |
| `quod_tx_diff_ops{namespace}` | histogram | | pieces of data added or removed per finished change, attributed to the target ontology |
| `quod_tx_committed_total{namespace}` | counter | `author` | finished changes in the target ontology, by its submitting node |
| `quod_dtx_committed_total{namespace}` | counter | `phase` | committed distributed-control barriers, by protocol phase |
| `quod_dtx_validation_events_total{namespace}` | counter | `event` | temporary DTX validation abstentions and normal-path redrives |
| `quod_dtx_submit_fanout_total{namespace}` | counter | `result` | bounded target-validator DTX delivery attempts and outcomes |
| `quod_tx_signature_validation_seconds{namespace}` | histogram | | time spent checking one transaction author's signature |
| `quod_tx_invalid_signatures_total{namespace}` | counter | | transaction signatures that failed cryptographic verification |
| `quod_tx_retries_total{namespace}` | counter | `reason` | operations explicitly told to prove and submit again |
| `quod_link_send_drops_total` | counter | `peer`, `channel`, `reason` | frames discarded at the QUIC send gate instead of transmitted; channel is the bounded `log`, `ingress`, or `other` class |
| `quod_consensus_round_approve_ms{namespace}` | histogram | | own proposal: broadcast to support-quorum approval, this node's clock |
| `quod_consensus_round_commit_ms{namespace}` | histogram | | own proposal: approval to final-and-durable here, this node's clock |
| `quod_consensus_event_ms{namespace}` | histogram | `class` | opt-in wall time handling one consensus event, by event class |
| `quod_consensus_event_qlen{namespace}` | histogram | `class` | opt-in mailbox depth found at consensus event entry |
| `quod_consensus_share_lag_ms{namespace}` | histogram | `kind` | own proposal: broadcast to each peer vote share arriving back |
| `quod_consensus_step_ms{namespace}` | histogram | `step` | named sub-steps inside consensus handlers (the slow-handler decomposition) |
| `quod_quic_srtt_ms/min_rtt_ms/cwnd_bytes/bytes_in_flight/send_queue_bytes/congested/in_recovery` | gauge | `peer` | per-peer QUIC transport health: RTT estimate vs wire floor, congestion window, unacked bytes, data queued behind pacing/cwnd, throttle flags |
""".

-behaviour(gen_server).

-export([start_link/0, observe_transaction_signature/3,
         observe_signing_journal_vote_sync/2,
         observe_tx_latency/2, count_link_send_drop/3, observe_round_phase/3,
         observe_consensus_event/4, observe_share_lag/3, observe_consensus_step/3,
         observe_batch/3, observe_ingress_retarget_hops/2, count_tx_retry/2,
         count_dtx_validation/2, count_dtx_submit_fanout/3,
         observe_runtime_reaction/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([consensus_stat_keys/0, declare/1, test_observe_commit/2]).
-endif.

-include("quod_ledger.hrl").

-define(REFRESH_MS, 5000).
-define(LAT_BUCKETS,  [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]).  %% ms: submit→commit
-define(ROUND_BUCKETS, [1, 2, 5, 10, 25, 50, 100, 150, 200, 300, 400, 500, 750,
                        1000, 2000, 5000]).   %% ms: one consensus round phase — fine-grained around the
                                              %% suspicious 100-750ms range so the probe can localize it
-define(EVENT_BUCKETS, [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 25, 50, 100,
                        250, 500, 1000]).  %% ms per statem event; sub-ms resolution to
                                           %% split "fast handler" from "slow handler"
-define(QLEN_BUCKETS, [0, 1, 2, 5, 10, 25, 50, 100, 500, 1000]).  %% mailbox depth at entry
-define(DIFF_BUCKETS, [1, 2, 4, 8, 16, 32, 64, 128]).                               %% asserts+retracts per tx
-define(BATCH_SIZE_BUCKETS, [1, 2, 4, 8, 16, 32, 64, 128, 256]).
-define(BATCH_WAIT_BUCKETS, [0, 1, 2, 5, 10, 15, 25, 40, 75, 100, 250, 500, 1000]).
-define(RETARGET_HOPS_BUCKETS, [0, 1, 2, 3, 5, 8, 13, 21, 34]).
-define(SIG_BUCKETS,  [0.00005, 0.0001, 0.00025, 0.0005, 0.001,
                       0.0025, 0.005, 0.01, 0.025, 0.05]).                            %% seconds per verify
-define(VOTE_SYNC_BUCKETS, [0.0001, 0.00025, 0.0005, 0.001, 0.0025,
                            0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5]).               %% seconds per datasync
-define(REACTION_BUCKETS, [0.00005, 0.0001, 0.00025, 0.0005, 0.001,
                           0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25,
                           0.5, 1.0]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    Port = application:get_env(quod, metrics_port, 14568),
    application:set_env(prometheus, prometheus_http, [{path, "/metrics"}, {port, Port}]),
    case prometheus_httpd:start() of
        {ok, _}                        -> ok;
        {error, {already_started, _}}  -> ok;
        Other -> logger:warning("quod: prometheus_httpd start: ~p", [Other])
    end,
    declare(local_node_id()),
    prometheus_gauge:set(quod_up, 1),
    self() ! refresh,
    logger:info("quod: prometheus metrics on :~p/metrics", [Port]),
    {ok, #{subs => #{}}}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State)        -> {noreply, State}.

handle_info(refresh, State) ->
    _ = [refresh_ns(Ns)        || Ns <- quod_brahms:namespaces()],
    _ = [refresh_log_ns(Ns)    || Ns <- quod_simplex:namespaces()],
    _ = [refresh_runtime_ns(Ns) || Ns <- quod_prolog:namespaces()],  %% runtime runs beside each kb
    _ = refresh_foreign_log(),                                      %% one shared owner per node
    _ = refresh_effect_custody(),                                   %% one shared owner per node
    _ = [refresh_prolog_ns(Ns) || Ns <- quod_prolog:namespaces()],
    _ = [refresh_feed_ns(Ns)   || Ns <- quod_simplex:namespaces()],   %% feed runs per-ns alongside consensus
    _ = refresh_transport(),                                          %% per-peer QUIC srtt/cwnd/in-flight
    State1 = subscribe_commits(State),
    erlang:send_after(?REFRESH_MS, self(), refresh),
    {noreply, State1};
handle_info({committed, Ns, _Slot, #entry{} = Entry}, State) ->
    _ = observe_commit(Ns, Entry),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

%% --- declare -------------------------------------------------------------

%% `NodeId` becomes a constant label on EVERY series (this whole endpoint is one node), so it is attached
%% at declare time rather than threaded through every set/observe/inc. `declare` is idempotent.
declare(NodeId) ->
    CL = #{node_id => NodeId},
    _ = prometheus_gauge:declare([{name, quod_up}, {help, "1 while this node is running (0 or missing means it is down)."},
                                  {constant_labels, CL}]),
    G = fun(Name, Help) ->
            prometheus_gauge:declare([{name, Name}, {help, Help}, {labels, [namespace]},
                                      {constant_labels, CL}])
        end,
    H = fun(Name, Help, Buckets) ->
            prometheus_histogram:declare([{name, Name}, {help, Help}, {labels, [namespace]},
                                          {buckets, Buckets}, {constant_labels, CL}])
        end,
    RH = fun(Name, Help, Buckets) ->
             prometheus_histogram:declare(
               [{name, Name}, {help, Help}, {labels, [namespace, result]},
                {buckets, Buckets}, {constant_labels, CL}])
         end,
    N = fun(Name, Help) ->
            prometheus_gauge:declare([{name, Name}, {help, Help},
                                      {constant_labels, CL}])
        end,
    %% Peer discovery: how this node finds and keeps track of the other nodes.
    _ = G(quod_brahms_view_size,   "How many other nodes this node currently knows about."),
    _ = G(quod_brahms_sample_size, "How many of those known nodes are in the small random set this node shares updates with, so gossip stays even."),
    _ = G(quod_brahms_links,       "How many other nodes this node has an open connection to right now."),
    _ = G(quod_brahms_rounds,      "Total number of update-sharing rounds this node has run (only ever goes up)."),
    _ = G(quod_brahms_evictions,   "Total number of nodes this node has dropped after they stopped responding (only ever goes up)."),
    _ = G(quod_brahms_tombstones,  "Nodes just marked dead and remembered for a short while so they are not added straight back (temporary; returns to 0)."),
    _ = G(quod_brahms_estimated_n, "Estimated total number of live nodes in this Brahms overlay. Nodes gossip a bounded sketch of signed, expiring stable identities, so a departed node ages out and a port change does not count as a new node."),
    %% Consensus: how the nodes agree on one shared, ordered history of changes.
    _ = G(quod_consensus_slot,            "The number of the newest block this node has. Higher means more history; all healthy nodes should track close together."),
    _ = G(quod_consensus_committed,       "The number of the newest block that is final and can never change."),
    _ = G(quod_consensus_approved,        "The number of the newest block that has enough votes for the next block to be built on top of it (usually one ahead of the final block)."),
    _ = G(quod_consensus_pipeline_gap,    "How many blocks have enough votes but are not final yet. By design this stays at 0, 1, or 2; a value stuck at 2 means finishing blocks is lagging."),
    _ = G(quod_consensus_last_applied,    "The number of the newest block whose changes this node has written into its own copy of the data."),
    _ = G(quod_consensus_committee_size,  "How many nodes are currently allowed to vote on changes."),
    _ = G(quod_consensus_appends,         "Total change requests this node accepted (while it was the leader) to put into blocks (only ever goes up)."),
    _ = G(quod_consensus_proposals,       "Total blocks this node has proposed while it was the leader (only ever goes up)."),
    _ = G(quod_consensus_batched_txs,     "Total changes packed into the blocks this node proposed. Divide its rate by the proposal rate to get the average number of changes per block."),
    _ = G(quod_consensus_batch_window_ms, "How many milliseconds this ontology's proposer is configured to wait after the first transaction before sealing a block. A larger value usually packs more transactions together but adds up to that much delay to a quiet write."),
    _ = G(quod_consensus_commits,         "Total blocks that have been made final and applied (only ever goes up)."),
    _ = G(quod_consensus_submitted,       "Total change requests handed to this node (only ever goes up)."),
    _ = G(quod_consensus_skips,           "Total times a turn was skipped because that turn's leader did not produce a block in time (only ever goes up)."),
    _ = G(quod_consensus_pending,         "Change requests waiting to be made final right now."),
    _ = G(quod_consensus_append_busy,     "Total change requests turned away as overloaded: the bounded waiting line was full, or a request waited past its cutoff during a stall. Requests that merely arrive at a busy moment now wait in line instead of being turned away, so any sustained increase here is an overload or a stalled cluster and deserves an alert (only ever goes up)."),
    _ = G(quod_consensus_ingress_queued,  "Change requests this node is holding right now. Relayed requests wait only for their explicitly named target slot; local requests may wait behind an unresolved author lane. Membership changes also wait for the current pipeline to become final. A value that stays high means consensus is not making room as fast as requests arrive."),
    _ = G(quod_consensus_ingress_overflow, "Total requests refused because the bounded ingress line (or one author's fair share of it) was full (only ever goes up)."),
    _ = G(quod_consensus_ingress_expired, "Total waiting requests cut loose because the cluster made no room for them within the ingress cutoff - a visible sign of a stall (only ever goes up)."),
    _ = G(quod_consensus_ingress_forwarded, "Total locally queued requests sent to the proposer of their exact target slot when the queue became dispatchable (only ever goes up)."),
    _ = G(quod_consensus_custody_depth, "Origin-owned signed content submissions this node is retaining until its local durable log proves inclusion or exclusion."),
    _ = G(quod_consensus_custody_ready, "Retained origin-owned submissions eligible for placement in the next usable consensus slot."),
    _ = G(quod_consensus_custody_bytes, "Encoded bytes held by this node's origin-owned submission custody. It is bounded independently of the ordinary ingress queue."),
    _ = G(quod_consensus_ingress_retargets, "Total times this node placed the same retained signed submission again after its local durable log excluded an earlier placement (only ever goes up)."),
    _ = G(quod_consensus_relay_accepted, "Total relayed requests whose destination acknowledged that it was holding or processing them. Once acknowledged, the sender stops its fast retry loop (only ever goes up)."),
    _ = G(quod_consensus_relay_redrives, "Total relay request retries. Before a destination acknowledges receipt they recover dropped sends quickly; after acknowledgement they run slowly only to recover a lost result hint (only ever goes up)."),
    _ = G(quod_consensus_relay_duplicates, "Total duplicate relay submissions received while the original request was already being processed. This should stay low; a high rate means retries are adding avoidable consensus-mailbox work (only ever goes up)."),
    _ = G(quod_consensus_append_redirect, "Total change requests refused because the local consensus process was unavailable, the receiver did not own the declared target slot, or that slot had already closed. This should stay near zero (only ever goes up)."),
    _ = G(quod_consensus_append_bad,      "Total change requests rejected because they were malformed or not allowed (only ever goes up)."),
    _ = G(quod_consensus_append_stale,    "Total otherwise-valid requests whose author sequence had already been superseded by newer approved history. This is a locally confirmed rejection, so the caller can safely re-prove with a fresh sequence (only ever goes up)."),
    _ = G(quod_consensus_membership_rejects, "Total requests to add or remove a voting node that this node judged invalid and refused (only ever goes up)."),
    _ = G(quod_consensus_redrives,        "Total times this node re-sent a proposal it was still waiting on instead of giving up. Climbing steadily means one of the voting nodes is not responding."),
    _ = G(quod_consensus_progress_slot,   "The oldest unfinished block slot watched by this node; 0 means no block is currently waiting for progress."),
    _ = G(quod_consensus_progress_phase,  "What the oldest unfinished block is waiting for: 0 idle, 1 a proposal, 2 a notarization certificate, 3 enough final votes to commit."),
    _ = G(quod_consensus_progress_quorum_ready, "1 when this node has live consensus links to enough validators that freshly reported being caught up to this node's current block, 0 otherwise. Complaint voting pauses while this is 0."),
    _ = G(quod_consensus_progress_timeouts, "Total oldest-block watchdog expirations. Occasional increases recover packet loss; sustained increases mean consensus is not advancing."),
    _ = G(quod_consensus_quorum_pauses,   "Total watchdog expirations where this node withheld a complaint because fewer than a certificate quorum of validators had a live consensus link and freshly reported being caught up. It prevents recovering sockets from being mistaken for voting nodes."),
    _ = G(quod_consensus_head_support_votes, "Verified support votes this node currently holds for the strongest block at the oldest unfinished slot. Reaching the certificate quorum approves that block."),
    _ = G(quod_consensus_head_commit_votes, "Verified commit votes this node currently holds for the strongest block at the oldest unfinished slot. Reaching the certificate quorum makes that block final."),
    _ = G(quod_consensus_head_complaint_votes, "Verified skip votes this node currently holds for the oldest unfinished slot. Reaching the certificate quorum skips that slot without applying its proposed changes."),
    _ = G(quod_consensus_head_complaint_signed, "1 when this validator has itself durably voted to skip the oldest unfinished slot, 0 otherwise. A mixture of this value across nodes explains which finality camp each validator is locked into."),
    _ = G(quod_consensus_missing_certified_blocks, "Quorum-approved in-flight blocks whose vote certificate this node has but whose transaction content it is still retrieving. A value that stays above 0 means block recovery is not reaching any holder."),
    _ = G(quod_consensus_is_validator,    "1 if this node is allowed to vote on changes, 0 if it only reads and follows along. It actually casts votes only when 'syncing' is also 0."),
    _ = G(quod_consensus_syncing,         "1 while this node is still catching up or confirming it is on the latest block; 0 once it is up to date. A voting node cannot vote until this is 0."),
    _ = G(quod_consensus_weak_cert_waits, "Total times this node held off finishing a block because it did not yet have enough valid votes from the current voting set, and waited for them. Climbing means this node fell behind around a change to the voting set (only ever goes up)."),
    _ = G(quod_consensus_ahead_gap,       "How many final blocks the rest of the network is ahead of this node (0 means up to date). A value that stays above 0 means this node has fallen behind and is fetching the blocks it is missing."),
    %% Runtime (P tier): this node's derived working state, rebuilt from stored data by handlers.
    _ = G(quod_runtime_healthy,         "1 while the runtime is live and processing; 0 while booting, replaying, reconciling, or unhealthy. Missing means the runtime process is absent. A persistent 0 means it cannot currently release effects; check runtime logs and the failure metrics."),
    _ = G(quod_runtime_handlers_active, "How many founding-declared handlers are active in this namespace."),
    _ = G(quod_runtime_subscriptions_active, "How many distinct valid anchored subscribes/2 facts are active in this namespace's local runtime catalogue."),
    _ = G(quod_runtime_reactions_active, "How many founding-authorized react_on/3 declarations are active."),
    _ = G(quod_runtime_reaction_candidates, "Total react_on/3 clauses considered for canonical applied fact events (only ever goes up)."),
    _ = G(quod_runtime_reaction_matches, "Total react_on/3 event matches produced by Erlog unification (only ever goes up)."),
    _ = G(quod_runtime_reactions_executed, "Total matched reaction handlers completed on their unique owner node (only ever goes up)."),
    _ = G(quod_runtime_reaction_inert, "Total matched reactions not run because their executor had no unique local owner (only ever goes up)."),
    _ = G(quod_runtime_reaction_failures, "Total matched reaction handlers that failed, errored, or attempted to stage durable data (only ever goes up)."),
    _ = RH(quod_runtime_reaction_seconds, "Time spent matching, resolving and running one reaction candidate, split by its bounded result.", ?REACTION_BUCKETS),
    _ = G(quod_runtime_source_targets_active, "How many distinct anchored remote ontologies have at least one active source-qualified reaction interest."),
    _ = G(quod_runtime_source_interests_active, "How many active source-qualified react_on/3 interests are compiled across all targets."),
    _ = G(quod_runtime_source_views_active, "How many durable subscription targets this namespace runtime is currently following or retrying."),
    _ = G(quod_runtime_source_views_ready, "How many subscribed foreign projections are currently certified and materialized for this namespace."),
    _ = G(quod_runtime_source_views_building, "How many subscribed foreign projections are currently rebuilding from certified history."),
    _ = G(quod_runtime_source_views_unreachable, "How many durable subscription targets this runtime cannot currently certify or reach."),
    _ = G(quod_runtime_p_height,        "The newest block whose derived working state this node has finished rebuilding."),
    _ = G(quod_runtime_e_frontier,      "The newest local block whose state handlers and reactions have completed; effects for a block are released only once this reaches it."),
    _ = G(quod_runtime_queue_len,       "Local and certified subscribed publications waiting for ordered state convergence and reactions right now."),
    _ = G(quod_runtime_reconciles,      "Total full rebuilds of the derived working state (only ever goes up). One per boot or recovery is normal; climbing steadily means handlers keep failing."),
    _ = G(quod_runtime_collapses,       "Total times pending handler work was thrown away and replaced by one full rebuild, due to overload or a handler failure (only ever goes up)."),
    _ = G(quod_runtime_dropped_events,  "Total change events dropped because a rebuild made them redundant or the queue overflowed (only ever goes up)."),
    _ = G(quod_runtime_rejected_dynamic,"Total executable runtime declarations refused because they were written after the ontology was founded (only ever goes up). Any value above 0 deserves a look: someone tried to install running code."),
    _ = G(quod_runtime_rejected_subscriptions,"Total malformed subscribes/2 clauses ignored by local runtime reconciliation (only ever goes up)."),
    _ = G(quod_runtime_heavy_pending,   "Heavy background jobs queued, one slot per resource (newer jobs replace older queued ones)."),
    _ = G(quod_runtime_heavy_running,   "Heavy background jobs running right now."),
    _ = G(quod_runtime_heavy_superseded,"Total queued heavy jobs replaced by a newer job for the same resource before they ran (only ever goes up)."),
    _ = G(quod_runtime_heavy_rejected,  "Total heavy jobs refused before retention because the bounded pending-resource queue was full or the encoded job exceeded its size limit (only ever goes up). Any increase means handlers are producing work faster or larger than configured."),
    _ = G(quod_runtime_heavy_failures,  "Total heavy background jobs that failed or were killed (only ever goes up). These are isolated from the handler pipeline; a climbing value means one heavy resource is broken while the rest of the node keeps working."),
    %% One node-wide certified foreign-history/fact owner. Target namespaces
    %% are deliberately absent from labels so hostile or high-cardinality
    %% durable subscription catalogues cannot grow Prometheus series.
    _ = N(quod_foreign_follow_targets, "Distinct foreign ontology histories actively followed on this node."),
    _ = N(quod_foreign_follow_consumers, "Local runtime consumer references sharing the node-wide certified follows."),
    _ = N(quod_foreign_projection_workers, "Foreign fact-projection workers currently materializing or holding certified state."),
    _ = N(quod_foreign_projection_bytes, "MVCC memory bytes held by foreign fact projections currently active on this node."),
    _ = N(quod_foreign_follow_building, "Followed targets whose certified fact projection is rebuilding."),
    _ = N(quod_foreign_follow_unreachable, "Followed targets currently unreachable or not certifiable."),
    _ = N(quod_foreign_follow_polls, "Total certified-follow refresh attempts started (only ever goes up)."),
    _ = N(quod_foreign_follow_pages, "Total certified history pages added by follow refreshes (only ever goes up)."),
    _ = N(quod_foreign_follow_entries, "Total certified ledger entries added by follow refreshes (only ever goes up)."),
    _ = N(quod_foreign_follow_bytes, "Total certified cache bytes added by follow refreshes (only ever goes up)."),
    _ = N(quod_foreign_follow_coalesced, "Total source-view notices collapsed behind an unacknowledged notice (only ever goes up)."),
    _ = N(quod_foreign_follow_resnapshots, "Total state-only follow resnapshots delivered for initial attachment, rebuild, or lost occurrence continuity (only ever goes up)."),
    _ = N(quod_foreign_follow_retries, "Total certified-follow retries scheduled after unavailable work (only ever goes up)."),
    _ = N(quod_foreign_projection_rebuilds, "Total foreign fact-projection generations started (only ever goes up)."),
    _ = N(quod_foreign_follow_max_lag, "Largest certified source height lag observed since this owner started."),
    _ = N(quod_foreign_bootstrap_candidates, "TLS-authenticated foreign route candidates retained separately from dormant verified histories."),
    _ = N(quod_foreign_bootstrap_accepted, "Total authenticated foreign route candidate observations accepted into the lazy history owner (only ever goes up)."),
    _ = N(quod_foreign_bootstrap_rejected, "Total authenticated foreign route candidate observations refused by validation (only ever goes up)."),
    _ = N(quod_foreign_bootstrap_evicted, "Total older candidate endpoints evicted by the per-identity source bound (only ever goes up)."),
    %% One node-wide direct-effect journal. Capacity comes from committed
    %% root policy; the two flags distinguish a real zero capacity from
    %% unlimited or a node that has not received its projection yet.
    _ = N(quod_effect_custody_active, "Direct effects in crash-durable custody that have not reached a terminal result."),
    _ = N(quod_effect_custody_group_active, "Direct effects in active DTX group custody. This is a subset of active custody, not an additional row count."),
    _ = N(quod_effect_custody_reservations, "Direct-effect custody places reserved by proofs that have not yet bound their transaction."),
    _ = N(quod_effect_custody_terminal, "Completed direct-effect rows retained for local outcome lookup or later compaction."),
    _ = N(quod_effect_custody_capacity, "Committed bounded direct-effect custody capacity. Zero is also used when the separate unlimited or configured flag explains that no numeric bound applies yet."),
    _ = N(quod_effect_custody_capacity_configured, "1 after committed root policy has configured direct-effect custody; 0 while startup projection is unavailable."),
    _ = N(quod_effect_custody_capacity_unlimited, "1 when committed root policy explicitly makes direct-effect custody unlimited; 0 for a numeric capacity or before configuration."),
    %% Stored data: this node's own copy of the shared data.
    _ = G(quod_prolog_applied,       "The number of the newest block this node has written into its stored data."),
    _ = G(quod_prolog_applies,       "Total finished changes this node has written into its stored data (only ever goes up)."),
    _ = G(quod_prolog_rejects,       "Total finished changes not written because the data they depended on had already changed (only ever goes up)."),
    _ = G(quod_prolog_proves,        "Total read queries this node has answered (only ever goes up)."),
    _ = G(quod_prolog_conflicts,     "Total finished changes skipped because they clashed with newer data (only ever goes up)."),
    _ = G(quod_prolog_parked,        "Write requests waiting here for their change to be made final right now."),
    _ = G(quod_prolog_park_timeouts, "Total write callers whose transaction still had no final result at the local waiting deadline. The transaction may finalize later, so inspect the returned target-anchored outcome reference instead of retrying the same non-idempotent operation (only ever goes up)."),
    _ = G(quod_prolog_proof_workers, "How many local queries are running right now. Each uses a frozen view of the data, so a value at the configured limit means new queries are being turned away until one finishes."),
    _ = G(quod_prolog_scope_workers, "How many selected proof scopes this node is serving right now. Each keeps one reusable frozen-base session until the origin proof closes it."),
    _ = G(quod_prolog_kb_memory_words, "How much Erlang VM memory, in words, this ontology's shared knowledge-base table is using. Multiply by the VM word size (normally 8 bytes on a 64-bit node) for an approximate byte count."),
    _ = G(quod_prolog_kb_history_predicates, "How many predicates are temporarily keeping an older data version because a running origin proof or selected scope still needs it. It should return to 0 after those proof scopes finish."),
    %% Spreading finished blocks to the rest of the network.
    _ = G(quod_feed_pushed,   "Total final blocks this node produced and started sending out to the rest of the network (only ever goes up)."),
    _ = G(quod_feed_ingested, "Total blocks this node received from others, checked, applied, and passed along (only ever goes up)."),
    _ = G(quod_feed_pulled,   "Total times this node asked others to send it blocks it was missing (only ever goes up)."),
    _ = G(quod_feed_digests,       "How many other nodes this node is currently getting 'still alive' heartbeats from (used to judge whether a candidate is alive enough to add as a voting node)."),
    _ = G(quod_feed_fresh_digests, "How many of those nodes sent a heartbeat recently enough to still count as alive."),
    _ = prometheus_gauge:declare([{name, quod_feed_dropped},
                                  {help, "Total blocks received from other nodes that this node threw away, grouped by why (only ever goes up). "
                                         "duplicate = already had it (harmless); gap = arrived out of order and fetched again later; "
                                         "unverified = failed its vote check, possibly a faulty or dishonest node (the one to watch); "
                                         "the other reasons are minor."},
                                  {labels, [namespace, reason]}, {constant_labels, CL}]),
    %% Per-change timing and size.
    _ = H(quod_tx_commit_latency_ms, "How long each change took from being handed in to being made final and applied, in milliseconds. Measured on the node that submitted the change, with a single clock - so it is honest end-to-end time, never a comparison of two machines' clocks - and each change is counted exactly once.", ?LAT_BUCKETS),
    _ = H(quod_tx_diff_ops,          "How many individual pieces of data each finished change added or removed.", ?DIFF_BUCKETS),
    _ = H(quod_consensus_batch_size,
          "How many transactions this node packed into each block it proposed. Values near 1 under a busy workload mean transactions are missing the same collection window and causing extra blocks.",
          ?BATCH_SIZE_BUCKETS),
    _ = H(quod_consensus_batch_wait_ms,
          "How long, in milliseconds, this node kept each new block open to collect more transactions before proposing it. Full or membership blocks can seal early; ordinary quiet blocks should be close to the configured batch window.",
          ?BATCH_WAIT_BUCKETS),
    _ = H(quod_consensus_ingress_retarget_hops,
          "How many internal retargets each completed origin-owned submission needed. Zero means its first placement resolved; values above zero expose slot-boundary churn without turning it into a client retry.",
          ?RETARGET_HOPS_BUCKETS),
    _ = H(quod_tx_signature_validation_seconds,
          "How long this node spent checking one transaction author's Ed25519 signature before accepting it. Higher values mean transaction authentication is consuming more consensus time.",
          ?SIG_BUCKETS),
    _ = H(quod_consensus_signing_journal_vote_sync_seconds,
          "How long this node took to make one support, commit, or skip vote crash-durable before sending its signature. Every new vote waits for this small disk sync; sustained high values directly delay block finality.",
          ?VOTE_SYNC_BUCKETS),
    _ = H(quod_consensus_round_approve_ms,
          "When it was this node's turn to build a block: how long, in milliseconds, from sending the new block out to the other nodes until enough of them agreed to accept it. This is the first half of agreeing on a block; on a fast local network it should be a few tens of milliseconds, and rising values mean agreement is getting slower.",
          ?ROUND_BUCKETS),
    _ = prometheus_histogram:declare(
          [{name, quod_consensus_event_ms},
           {help, "How long, in milliseconds, this node spent dealing with one incoming message, grouped by the kind of message. If these stay small while blocks are still slow, the delay is somewhere other than this node's own work."},
           {labels, [namespace, class]}, {buckets, ?EVENT_BUCKETS}, {constant_labels, CL}]),
    _ = prometheus_histogram:declare(
          [{name, quod_consensus_event_qlen},
           {help, "How many messages were already waiting in line when this node picked up the next one to handle, grouped by kind. A number that climbs means messages are arriving faster than the node can handle them, so work backs up and everything slows down."},
           {labels, [namespace, class]}, {buckets, ?QLEN_BUCKETS}, {constant_labels, CL}]),
    _ = prometheus_histogram:declare(
          [{name, quod_consensus_step_ms},
           {help, "How long, in milliseconds, each individual step of handling a block took (saving a vote to disk, saving the block, sending it on, and so on), grouped by step name. When a block is slow, the step with the biggest number here is the cause."},
           {labels, [namespace, step]}, {buckets, ?EVENT_BUCKETS}, {constant_labels, CL}]),
    _ = prometheus_histogram:declare(
          [{name, quod_consensus_share_lag_ms},
           {help, "When it was this node's turn to build a block: how long, in milliseconds, from sending the block out until each other node's vote came back. The plain measure of how long it takes to collect votes from the others."},
           {labels, [namespace, kind]}, {buckets, ?ROUND_BUCKETS}, {constant_labels, CL}]),
    _ = H(quod_consensus_round_commit_ms,
          "When it was this node's turn to build a block: how long, in milliseconds, from the block being accepted until it is made final and saved to disk here. This is the second half of agreeing on a block; add it to the first half for the full time a block takes.",
          ?ROUND_BUCKETS),
    _ = prometheus_counter:declare([{name, quod_tx_committed_total},
                                    {help, "Total finished changes, grouped by the node that submitted them (only ever goes up)."},
                                    {labels, [namespace, author]}, {constant_labels, CL}]),
    _ = prometheus_counter:declare([{name, quod_dtx_committed_total},
                                    {help, "Committed distributed-transaction control barriers, grouped by protocol phase."},
                                    {labels, [namespace, phase]}, {constant_labels, CL}]),
    _ = prometheus_counter:declare(
          [{name, quod_dtx_validation_events_total},
           {help, "Distributed-control validation attempts that temporarily abstained or were redriven through the normal validation path."},
           {labels, [namespace, event]}, {constant_labels, CL}]),
    _ = prometheus_counter:declare(
          [{name, quod_dtx_submit_fanout_total},
           {help, "Bounded target-validator delivery attempts and their correlated results for distributed controls."},
           {labels, [namespace, result]}, {constant_labels, CL}]),
    _ = prometheus_counter:declare(
          [{name, quod_tx_invalid_signatures_total},
           {help, "Total transaction author signatures that failed cryptographic verification. Any increase means malformed, corrupted, or dishonest transaction input was rejected before this node voted for its block."},
           {labels, [namespace]}, {constant_labels, CL}]),
    _ = prometheus_counter:declare(
          [{name, quod_tx_retries_total},
           {help, "Total operations explicitly told to prove and submit again, grouped by cause. membership_skipped is the terminal membership re-proof path; stale_sequence means newer approved history overtook the signed author sequence. Ordinary retained content is internally retargeted after slot exclusion and does not increment this counter."},
           {labels, [namespace, reason]}, {constant_labels, CL}]),
    P = fun(Name, Help) ->
            prometheus_gauge:declare([{name, Name}, {help, Help}, {labels, [peer]},
                                      {constant_labels, CL}])
        end,
    _ = P(quod_quic_srtt_ms,
          "The typical time, in milliseconds, for a message to reach each other node and a reply to come back, as the network connection estimates it. On a local network this should be a few milliseconds; if it is much larger than quod_quic_min_rtt_ms, something (a busy machine or slow replies) is adding delay on top of the network, and that slows every block."),
    _ = P(quod_quic_min_rtt_ms,
          "The fastest round trip ever seen to each other node, in milliseconds - the raw speed of the network with nothing slowing it down. Compare it against quod_quic_srtt_ms: a big gap between them means delay is being added on top of the network."),
    _ = P(quod_quic_cwnd_bytes,
          "How many bytes the connection to each other node is currently willing to have traveling at once. Anything beyond this waits its turn quietly instead of going out immediately, so a small number here can slow sending down without showing any error."),
    _ = P(quod_quic_bytes_in_flight,
          "How many bytes have been sent to each other node but not yet confirmed as arrived. If this sits right at the limit above (quod_quic_cwnd_bytes), the connection itself is what is holding sending back."),
    _ = P(quod_quic_send_queue_bytes,
          "How many bytes have been handed to the connection for sending to each other node but are still waiting inside it to actually go out. The node believes it already sent them, so this is hidden delay; a value that stays above zero means the connection is holding messages back."),
    _ = P(quod_quic_congested,
          "1 when the connection to this other node is deliberately slowing sending because the link looks full, 0 otherwise."),
    _ = P(quod_quic_in_recovery,
          "1 when the connection to this other node is recovering from data lost on the network, 0 otherwise."),
    _ = prometheus_counter:declare(
          [{name, quod_link_send_drops_total},
           {help, "Total messages this node threw away instead of sending, grouped by destination, bounded channel class, and reason. channel='log' is consensus, channel='ingress' is retained relay traffic, and channel='other' covers every non-Simplex or malformed channel without creating arbitrary labels. 'flow_control' means that node was reading too slowly to accept more; 'queue_full' means this node's own outbound buffer was full. A thrown-away message is re-sent later by a timer, so a steady climb here quietly slows agreement down (only ever goes up)."},
           {labels, [peer, channel, reason]}, {constant_labels, CL}]),
    ok.

%% Signature checks happen in the consensus and history-validation paths. Metrics
%% must never become a dependency of either path, including during supervisor
%% startup or a metrics-process restart.
-spec observe_transaction_signature(binary(), boolean(), non_neg_integer()) -> ok.
observe_transaction_signature(Ns, Valid, DurationNative)
  when is_binary(Ns), is_boolean(Valid), is_integer(DurationNative), DurationNative >= 0 ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                Seconds = erlang:convert_time_unit(DurationNative, native, nanosecond) / 1000000000,
                _ = prometheus_histogram:observe(
                      quod_tx_signature_validation_seconds, [label(Ns)], Seconds),
                _ = case Valid of
                        true  -> ok;
                        false -> prometheus_counter:inc(
                                   quod_tx_invalid_signatures_total, [label(Ns)])
                    end,
                ok
            catch
                _:_ -> ok
            end
    end.

%% Vote persistence is on the consensus hot path, but observability must remain optional during
%% supervisor startup and metrics-process restarts.
-spec observe_signing_journal_vote_sync(binary(), non_neg_integer()) -> ok.
observe_signing_journal_vote_sync(Ns, DurationNative)
  when is_binary(Ns), is_integer(DurationNative), DurationNative >= 0 ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                Seconds = erlang:convert_time_unit(DurationNative, native, nanosecond) / 1000000000,
                _ = prometheus_histogram:observe(
                      quod_consensus_signing_journal_vote_sync_seconds,
                      [label(Ns)], Seconds),
                ok
            catch
                _:_ -> ok
            end
    end.

%% --- poll refresh --------------------------------------------------------

refresh_ns(Ns) ->
    case quod_brahms:stats(Ns) of
        #{view := V, sample := S, conns := C, rounds := R, evictions := E,
          tombstones := T, estimated_n := EN} ->
            _ = prometheus_gauge:set(quod_brahms_view_size,   [label(Ns)], V),
            _ = prometheus_gauge:set(quod_brahms_sample_size, [label(Ns)], S),
            _ = prometheus_gauge:set(quod_brahms_links,       [label(Ns)], C),
            _ = prometheus_gauge:set(quod_brahms_rounds,      [label(Ns)], R),
            _ = prometheus_gauge:set(quod_brahms_evictions,   [label(Ns)], E),
            _ = prometheus_gauge:set(quod_brahms_tombstones,  [label(Ns)], T),
            _ = prometheus_gauge:set(quod_brahms_estimated_n, [label(Ns)], EN),
            ok;
        _ -> ok
    end.

refresh_runtime_ns(Ns) ->
    case quod_runtime:stats(Ns) of
        #{mode := Mode, handlers_active := HA, subscriptions_active := SA,
          reactions_active := RA, source_targets_active := STA,
          source_interests_active := SIA, p_height := PH, e_frontier := EF,
          source_views_active := SVA, source_views_ready := SVR,
          source_views_building := SVB, source_views_unreachable := SVU,
          queue_len := QL, reconciles := RC, collapses := CO, dropped_events := DE,
          rejected_dynamic := RJ, rejected_subscriptions := RS,
          reaction_candidates := RCa, reaction_matches := RM,
          reactions_executed := RE, reaction_inert := RI,
          reaction_failures := RF,
          heavy_pending := HP, heavy_running := HR,
          heavy_superseded := HS, heavy_rejected := HX, heavy_failures := HF} ->
            S = fun(Name, V) -> prometheus_gauge:set(Name, [label(Ns)], V) end,
            _ = S(quod_runtime_healthy, case Mode of live -> 1; _ -> 0 end),
            _ = S(quod_runtime_handlers_active, HA),
            _ = S(quod_runtime_subscriptions_active, SA),
            _ = S(quod_runtime_reactions_active, RA),
            _ = S(quod_runtime_reaction_candidates, RCa),
            _ = S(quod_runtime_reaction_matches, RM),
            _ = S(quod_runtime_reactions_executed, RE),
            _ = S(quod_runtime_reaction_inert, RI),
            _ = S(quod_runtime_reaction_failures, RF),
            _ = S(quod_runtime_source_targets_active, STA),
            _ = S(quod_runtime_source_interests_active, SIA),
            _ = S(quod_runtime_source_views_active, SVA),
            _ = S(quod_runtime_source_views_ready, SVR),
            _ = S(quod_runtime_source_views_building, SVB),
            _ = S(quod_runtime_source_views_unreachable, SVU),
            _ = S(quod_runtime_p_height, PH),
            _ = S(quod_runtime_e_frontier, EF),
            _ = S(quod_runtime_queue_len, QL),
            _ = S(quod_runtime_reconciles, RC),
            _ = S(quod_runtime_collapses, CO),
            _ = S(quod_runtime_dropped_events, DE),
            _ = S(quod_runtime_rejected_dynamic, RJ),
            _ = S(quod_runtime_rejected_subscriptions, RS),
            _ = S(quod_runtime_heavy_pending, HP),
            _ = S(quod_runtime_heavy_running, HR),
            _ = S(quod_runtime_heavy_superseded, HS),
            _ = S(quod_runtime_heavy_rejected, HX),
            _ = S(quod_runtime_heavy_failures, HF),
            ok;
        _ -> remove_runtime_metrics(Ns)
    end.

remove_runtime_metrics(Ns) ->
    Labels = [label(Ns)],
    Names = [quod_runtime_healthy, quod_runtime_handlers_active,
             quod_runtime_subscriptions_active, quod_runtime_reactions_active,
             quod_runtime_reaction_candidates, quod_runtime_reaction_matches,
             quod_runtime_reactions_executed, quod_runtime_reaction_inert,
             quod_runtime_reaction_failures,
             quod_runtime_source_targets_active, quod_runtime_source_interests_active,
             quod_runtime_source_views_active, quod_runtime_source_views_ready,
             quod_runtime_source_views_building,
             quod_runtime_source_views_unreachable,
             quod_runtime_p_height, quod_runtime_e_frontier, quod_runtime_queue_len,
             quod_runtime_reconciles, quod_runtime_collapses, quod_runtime_dropped_events,
             quod_runtime_rejected_dynamic, quod_runtime_rejected_subscriptions,
             quod_runtime_heavy_pending,
             quod_runtime_heavy_running, quod_runtime_heavy_superseded,
             quod_runtime_heavy_rejected, quod_runtime_heavy_failures],
    _ = [prometheus_gauge:remove(Name, Labels) || Name <- Names],
    ok.

refresh_foreign_log() ->
    Stats = quod_foreign_log:stats(),
    Set = fun(Name, Key) ->
                  prometheus_gauge:set(Name, maps:get(Key, Stats, 0))
          end,
    _ = Set(quod_foreign_follow_targets, followed_histories),
    _ = Set(quod_foreign_follow_consumers, follow_consumers),
    _ = Set(quod_foreign_projection_workers, projection_workers),
    _ = Set(quod_foreign_projection_bytes, projection_bytes),
    _ = Set(quod_foreign_follow_building, follow_building),
    _ = Set(quod_foreign_follow_unreachable, follow_unreachable),
    _ = Set(quod_foreign_follow_polls, follow_polls),
    _ = Set(quod_foreign_follow_pages, follow_pages),
    _ = Set(quod_foreign_follow_entries, follow_entries),
    _ = Set(quod_foreign_follow_bytes, follow_bytes),
    _ = Set(quod_foreign_follow_coalesced, follow_coalesced),
    _ = Set(quod_foreign_follow_resnapshots, follow_resnapshots),
    _ = Set(quod_foreign_follow_retries, follow_retries),
    _ = Set(quod_foreign_projection_rebuilds, projection_rebuilds),
    _ = Set(quod_foreign_follow_max_lag, max_follow_lag),
    _ = Set(quod_foreign_bootstrap_candidates, bootstrap_candidates),
    _ = Set(quod_foreign_bootstrap_accepted, bootstrap_accepted),
    _ = Set(quod_foreign_bootstrap_rejected, bootstrap_rejected),
    _ = Set(quod_foreign_bootstrap_evicted, bootstrap_evicted),
    ok.

refresh_effect_custody() ->
    case quod_effect_journal:stats() of
        #{capacity := Capacity, active := Active, group_active := GroupActive,
          reservations := Reservations, terminal := Terminal} ->
            _ = prometheus_gauge:set(quod_effect_custody_active, Active),
            _ = prometheus_gauge:set(
                  quod_effect_custody_group_active, GroupActive),
            _ = prometheus_gauge:set(
                  quod_effect_custody_reservations, Reservations),
            _ = prometheus_gauge:set(quod_effect_custody_terminal, Terminal),
            {Value, Configured, Unlimited} =
                effect_capacity_metrics(Capacity),
            _ = prometheus_gauge:set(quod_effect_custody_capacity, Value),
            _ = prometheus_gauge:set(
                  quod_effect_custody_capacity_configured, Configured),
            _ = prometheus_gauge:set(
                  quod_effect_custody_capacity_unlimited, Unlimited),
            ok;
        _ ->
            _ = prometheus_gauge:set(quod_effect_custody_active, 0),
            _ = prometheus_gauge:set(quod_effect_custody_group_active, 0),
            _ = prometheus_gauge:set(
                  quod_effect_custody_reservations, 0),
            _ = prometheus_gauge:set(quod_effect_custody_terminal, 0),
            _ = prometheus_gauge:set(quod_effect_custody_capacity, 0),
            _ = prometheus_gauge:set(
                  quod_effect_custody_capacity_configured, 0),
            _ = prometheus_gauge:set(
                  quod_effect_custody_capacity_unlimited, 0),
            ok
    end.

effect_capacity_metrics(unconfigured) -> {0, 0, 0};
effect_capacity_metrics(unlimited) -> {0, 1, 1};
effect_capacity_metrics(Capacity)
  when is_integer(Capacity), Capacity >= 0 ->
    {Capacity, 1, 0}.

refresh_log_ns(Ns) ->
    case quod_simplex:stats(Ns) of
        %% This pattern MUST stay a subset of quod_simplex:stats_map/1 — a key listed
        %% here but absent there silently skips EVERY consensus gauge (falls through to
        %% the `_ -> ok` arm). consensus_stat_keys/0 mirrors this list; the lockstep
        %% eunit in quod_simplex_tests pins the two together.
        #{slot := Sl, committed := CI, approved := AV, pipeline_gap := PG,
          last_applied := LA, committee_size := CS,
          appends := AP, proposals := PR, batched_txs := BT,
          batch_window_ms := BW,
          commits := CM, submitted := SU, skips := SK, pending := PE,
          r_busy := RB, r_redirect := RR, r_bad := RD, r_stale := RS,
          membership_rejects := MR,
          ingress_queued := IQ, ingress_overflow := IO,
          ingress_expired := IE, ingress_forwarded := IF,
          custody_depth := CD, custody_ready := CR, custody_bytes := CB,
          ingress_retargets := IRT,
          relay_accepted := RA, relay_redrives := RRD,
          relay_duplicates := RDU,
          redrives := RV, progress_slot := PS, progress_phase_code := PP,
          progress_quorum_ready := PQ, progress_timeouts := PT,
          quorum_pauses := QP, head_support_votes := HSV, head_commit_votes := HCV,
          head_complaint_votes := HXV, head_complaint_signed := HXS,
          missing_certified_blocks := MCB,
          weak_cert_waits := WC, is_validator := IV, syncing := SY,
          ahead_gap := AG} ->
            S = fun(Name, V) -> prometheus_gauge:set(Name, [label(Ns)], V) end,
            _ = S(quod_consensus_slot,            Sl),
            _ = S(quod_consensus_committed,       CI),
            _ = S(quod_consensus_approved,        AV),
            _ = S(quod_consensus_pipeline_gap,    PG),
            _ = S(quod_consensus_last_applied,    LA),
            _ = S(quod_consensus_committee_size,  CS),
            _ = S(quod_consensus_appends,         AP),
            _ = S(quod_consensus_proposals,       PR),
            _ = S(quod_consensus_batched_txs,     BT),
            _ = S(quod_consensus_batch_window_ms, BW),
            _ = S(quod_consensus_commits,         CM),
            _ = S(quod_consensus_submitted,       SU),
            _ = S(quod_consensus_skips,           SK),
            _ = S(quod_consensus_pending,         PE),
            _ = S(quod_consensus_append_busy,     RB),
            _ = S(quod_consensus_ingress_queued,  IQ),
            _ = S(quod_consensus_ingress_overflow, IO),
            _ = S(quod_consensus_ingress_expired, IE),
            _ = S(quod_consensus_ingress_forwarded, IF),
            _ = S(quod_consensus_custody_depth, CD),
            _ = S(quod_consensus_custody_ready, CR),
            _ = S(quod_consensus_custody_bytes, CB),
            _ = S(quod_consensus_ingress_retargets, IRT),
            _ = S(quod_consensus_relay_accepted, RA),
            _ = S(quod_consensus_relay_redrives, RRD),
            _ = S(quod_consensus_relay_duplicates, RDU),
            _ = S(quod_consensus_append_redirect, RR),
            _ = S(quod_consensus_append_bad,      RD),
            _ = S(quod_consensus_append_stale,    RS),
            _ = S(quod_consensus_membership_rejects, MR),
            _ = S(quod_consensus_redrives,        RV),
            _ = S(quod_consensus_progress_slot,   PS),
            _ = S(quod_consensus_progress_phase,  PP),
            _ = S(quod_consensus_progress_quorum_ready, PQ),
            _ = S(quod_consensus_progress_timeouts, PT),
            _ = S(quod_consensus_quorum_pauses,   QP),
            _ = S(quod_consensus_head_support_votes, HSV),
            _ = S(quod_consensus_head_commit_votes, HCV),
            _ = S(quod_consensus_head_complaint_votes, HXV),
            _ = S(quod_consensus_head_complaint_signed, HXS),
            _ = S(quod_consensus_missing_certified_blocks, MCB),
            _ = S(quod_consensus_is_validator,    IV),
            _ = S(quod_consensus_syncing,         SY),
            _ = S(quod_consensus_weak_cert_waits, WC),
            _ = S(quod_consensus_ahead_gap,       AG),
            ok;
        _ -> ok
    end.

%% Ask every live connection process for its QUIC transport stats and surface them
%% per peer. The conn processes register on the `{conn_stats, local}` property; a
%% bounded selective receive per conn keeps a wedged connection from stalling the
%% refresh. Stats RTTs arrive in MICROseconds (the lib's public contract) — convert.
refresh_transport() ->
    Pids = try gproc:lookup_pids(quod_reg:prop({conn_stats, local}))
           catch _:_ -> []
           end,
    lists:foreach(
      fun(Pid) ->
              Ref = make_ref(),
              Pid ! {transport_stats, self(), Ref},
              receive
                  {Ref, {Peer, {ok, Stats}}} when is_binary(Peer) ->
                      set_transport_gauges(author_label(Peer), Stats);
                  {Ref, _} ->
                      ok   %% peer not yet learned, or stats unavailable
              after 50 -> ok
              end
      end, Pids).

set_transport_gauges(Peer, Stats) ->
    Num = fun(Name, Key, Scale) ->
                  case maps:get(Key, Stats, undefined) of
                      V when is_number(V) ->
                          prometheus_gauge:set(Name, [Peer], V / Scale);
                      _ -> ok
                  end
          end,
    Bool = fun(Name, Key) ->
                   case maps:get(Key, Stats, undefined) of
                       true  -> prometheus_gauge:set(Name, [Peer], 1);
                       false -> prometheus_gauge:set(Name, [Peer], 0);
                       _     -> ok
                   end
           end,
    _ = Num(quod_quic_srtt_ms, srtt, 1000),            %% us -> ms
    _ = Num(quod_quic_min_rtt_ms, min_rtt, 1000),      %% us -> ms
    _ = Num(quod_quic_cwnd_bytes, cwnd, 1),
    _ = Num(quod_quic_bytes_in_flight, bytes_in_flight, 1),
    _ = Num(quod_quic_send_queue_bytes, send_queue_bytes, 1),
    _ = Bool(quod_quic_congested, congested),
    _ = Bool(quod_quic_in_recovery, in_recovery),
    ok.

refresh_prolog_ns(Ns) ->
    case quod_prolog:stats(Ns) of
        #{applied := A, applies := AP, rejects := RJ, proves := PR, conflicts := CF,
          parked := PK, park_timeouts := PT, proof_workers := PW, scope_workers := SW,
          kb_memory_words := MW, kb_history_predicates := HP} ->
            S = fun(Name, V) -> prometheus_gauge:set(Name, [label(Ns)], V) end,
            _ = S(quod_prolog_applied,       A),
            _ = S(quod_prolog_applies,       AP),
            _ = S(quod_prolog_rejects,       RJ),
            _ = S(quod_prolog_proves,        PR),
            _ = S(quod_prolog_conflicts,     CF),
            _ = S(quod_prolog_parked,        PK),
            _ = S(quod_prolog_park_timeouts, PT),
            _ = S(quod_prolog_proof_workers, PW),
            _ = S(quod_prolog_scope_workers, SW),
            _ = S(quod_prolog_kb_memory_words, MW),
            _ = S(quod_prolog_kb_history_predicates, HP),
            ok;
        _ -> ok
    end.

refresh_feed_ns(Ns) ->
    case quod_feed:stats(Ns) of
        #{pushed := PU, ingested := IN, pulled := PL, dropped := DR,
          digests := DG, fresh_digests := FR} ->
            S = fun(Name, V) -> prometheus_gauge:set(Name, [label(Ns)], V) end,
            _ = S(quod_feed_pushed,   PU),
            _ = S(quod_feed_ingested, IN),
            _ = S(quod_feed_pulled,   PL),
            _ = S(quod_feed_digests,       DG),
            _ = S(quod_feed_fresh_digests, FR),
            _ = maps:foreach(fun(Reason, C) ->
                                 prometheus_gauge:set(quod_feed_dropped, [label(Ns), atom_to_binary(Reason, utf8)], C)
                             end, DR),
            ok;
        _ -> ok
    end.

%% --- live commit event ---------------------------------------------------

%% Subscribe (once per namespace) to the LIVE {committed, Ns} event so the per-tx histograms/counter see
%% each finalized transaction. Idempotent: only namespaces not already subscribed are registered, and the
%% subscription lives on THIS process, so it survives a quod_simplex restart.
subscribe_commits(State = #{subs := Subs}) ->
    Subs1 = lists:foldl(fun(Ns, Acc) ->
                            case maps:is_key(Ns, Acc) of
                                true  -> Acc;
                                false -> _ = quod_reg:subscribe({committed, Ns}), Acc#{Ns => true}
                            end
                        end, Subs, quod_simplex:namespaces()),
    State#{subs => Subs1}.

%% A live-committed entry: observe content per transaction and DTX controls per
%% phase. A `noop` skip is neither. Deliberately NOT observed here: commit latency — the block timestamp is the
%% proposer's wall clock (ratcheted to the fleet maximum) and `submitted_at` is the author's, so their
%% difference measures clock skew as much as processing time. Latency is observed at the SUBMITTING
%% node instead (`observe_tx_latency/2`, called by quod_prolog when the parked write resolves).
observe_commit(Ns, #entry{data = Data}) ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            lists:foreach(fun(T) -> observe_transaction(Ns, T) end,
                          Transactions);
        {'begin', _Control} -> observe_dtx(Ns, 'begin');
        {prepare, _Control} -> observe_dtx(Ns, prepare);
        {decision, _Control} -> observe_dtx(Ns, decision);
        {finalize, _Control} -> observe_dtx(Ns, finalize);
        {complete, _Control} -> observe_dtx(Ns, complete);
        noop -> ok;
        invalid -> ok
    end.

-ifdef(TEST).
test_observe_commit(Ns, Entry) -> observe_commit(Ns, Entry).
-endif.

observe_transaction(Ns, #transaction{author = Author, diff = Diff}) ->
    L = label(Ns),
    _ = prometheus_histogram:observe(quod_tx_diff_ops, [L], length(Diff)),
    _ = prometheus_counter:inc(quod_tx_committed_total, [L, author_label(Author)]),
    ok.

observe_dtx(Ns, Phase) ->
    _ = prometheus_counter:inc(
          quod_dtx_committed_total,
          [label(Ns), atom_to_binary(Phase, utf8)]),
    ok.

-doc "Observe one local or subscribed reaction candidate without making metrics a runtime dependency.".
-spec observe_runtime_reaction(binary(),
                               executed | unmatched | {inert, term()} |
                               {failed, term()},
                               non_neg_integer()) -> ok.
observe_runtime_reaction(Ns, Result, ElapsedUs)
  when is_binary(Ns), is_integer(ElapsedUs), ElapsedUs >= 0 ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            Label =
                case Result of
                    executed -> <<"executed">>;
                    unmatched -> <<"unmatched">>;
                    {inert, _} -> <<"inert">>;
                    {failed, _} -> <<"failed">>
                end,
            try
                _ = prometheus_histogram:observe(
                      quod_runtime_reaction_seconds,
                      [label(Ns), Label],
                      erlang:convert_time_unit(
                        ElapsedUs, microsecond, native)),
                ok
            catch _:_ -> ok
            end
    end.

-doc """
One frame discarded at the QUIC send gate (`m:quod_link` ignores backpressure by design;
this makes the ignored return VISIBLE). The transport channel is reduced to the fixed
`log`, `ingress`, or `other` label set: only an exact deterministic `{log, Namespace}`
or `{ingress, Namespace}` identity receives its named label. Called from bare link
processes on the send path, so — like every observe helper here — an absent metrics
process makes it a no-op.
""".
-spec count_link_send_drop(binary() | term(), binary() | term(), term()) -> ok.
count_link_send_drop(Peer, Channel, Reason) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                _ = prometheus_counter:inc(
                      quod_link_send_drops_total,
                      [author_label(Peer), link_channel_label(Channel),
                       drop_reason(Reason)]),
                ok
            catch _:_ -> ok
            end
    end.

%% Channels are opaque bytes at the transport boundary. Decode with `safe` so a
%% peer-supplied identity can never intern atoms, then require byte-for-byte equality
%% with quod's deterministic encoding. Labels themselves are fixed literals; unrelated,
%% malformed, and non-canonical channels all share one bounded `other` value.
link_channel_label(Channel) when is_binary(Channel) ->
    try binary_to_term(Channel, [safe]) of
        {log, Ns} when is_binary(Ns) ->
            exact_channel_label(Channel, {log, Ns}, <<"log">>);
        {ingress, Ns} when is_binary(Ns) ->
            exact_channel_label(Channel, {ingress, Ns}, <<"ingress">>);
        _ ->
            <<"other">>
    catch _:_ ->
        <<"other">>
    end;
link_channel_label(_) ->
    <<"other">>.

exact_channel_label(Channel, Identity, Label) ->
    case term_to_binary(Identity, [deterministic]) of
        Channel -> Label;
        _       -> <<"other">>
    end.

drop_reason({flow_control_blocked, connection})  -> <<"flow_control_conn">>;
drop_reason({flow_control_blocked, {stream, _}}) -> <<"flow_control_stream">>;
drop_reason(send_queue_full)                     -> <<"queue_full">>;
drop_reason(_)                                   -> <<"other">>.

-doc """
One consensus-round phase sample for a block THIS node proposed, `Ms` on this node's
monotonic clock: `approve` = proposal broadcast → support quorum held; `commit` =
approval → final and durable here. Called from the consensus statem's hot path, so an
absent metrics process makes it a no-op (same contract as every observe helper here).
""".
-spec observe_round_phase(binary(), approve | commit, integer()) -> ok.
observe_round_phase(Ns, Phase, Ms)
  when is_binary(Ns), (Phase =:= approve orelse Phase =:= commit),
       is_integer(Ms), Ms >= 0 ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                Name = case Phase of
                           approve -> quod_consensus_round_approve_ms;
                           commit  -> quod_consensus_round_commit_ms
                       end,
                _ = prometheus_histogram:observe(Name, [label(Ns)], Ms),
                ok
            catch _:_ -> ok
            end
    end;
observe_round_phase(_Ns, _Phase, _Ms) ->
    ok.

-doc """
One consensus statem event handled: wall `Us` (microseconds) and the mailbox depth found
at entry, by event class. The consensus state machine calls this only when
`detailed_consensus_metrics` is enabled; an absent metrics process makes it a no-op.
""".
-spec observe_consensus_event(binary(), atom(), integer(), non_neg_integer()) -> ok.
observe_consensus_event(Ns, Class, Us, QLen)
  when is_binary(Ns), is_atom(Class), is_integer(Us), Us >= 0, is_integer(QLen) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                L = [label(Ns), atom_to_binary(Class, utf8)],
                _ = prometheus_histogram:observe(quod_consensus_event_ms, L, Us / 1000),
                _ = prometheus_histogram:observe(quod_consensus_event_qlen, L, QLen),
                ok
            catch _:_ -> ok
            end
    end;
observe_consensus_event(_Ns, _Class, _Us, _QLen) ->
    ok.

-doc "One named sub-step inside a consensus handler took `Us` microseconds (guarded no-op without a metrics process).".
-spec observe_consensus_step(binary(), atom(), integer()) -> ok.
observe_consensus_step(Ns, Step, Us)
  when is_binary(Ns), is_atom(Step), is_integer(Us), Us >= 0 ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                _ = prometheus_histogram:observe(
                      quod_consensus_step_ms,
                      [label(Ns), atom_to_binary(Step, utf8)], Us / 1000),
                ok
            catch _:_ -> ok
            end
    end;
observe_consensus_step(_Ns, _Step, _Us) ->
    ok.

-doc "A peer's vote share arrived for a slot this node proposed, `Ms` after the proposal broadcast (one clock).".
-spec observe_share_lag(binary(), atom(), integer()) -> ok.
observe_share_lag(Ns, Kind, Ms)
  when is_binary(Ns), is_atom(Kind), is_integer(Ms), Ms >= 0 ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                _ = prometheus_histogram:observe(
                      quod_consensus_share_lag_ms,
                      [label(Ns), atom_to_binary(Kind, utf8)], Ms),
                ok
            catch _:_ -> ok
            end
    end;
observe_share_lag(_Ns, _Kind, _Ms) ->
    ok.

-doc """
One end-to-end latency sample: a write submitted on THIS node resolved as committed and applied,
`Ms` measured by the caller on one monotonic clock. The submitting node is the only place that
latency is real — any cross-node timestamp difference embeds wall-clock skew. Like every observe
helper here, metrics must never become a dependency of the observed path (write resolution), so
an absent/mid-restart metrics process makes this a no-op.
""".
-spec observe_tx_latency(binary(), integer()) -> ok.
observe_tx_latency(Ns, Ms) when is_binary(Ns), is_integer(Ms), Ms >= 0 ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                _ = prometheus_histogram:observe(quod_tx_commit_latency_ms, [label(Ns)], Ms),
                ok
            catch _:_ -> ok
            end
    end;
observe_tx_latency(_Ns, _Ms) ->
    ok.

-doc """
Record one proposed block's transaction count and collection wait. This is called
once per local proposal, not once per consensus message, so it remains cheap enough
to keep enabled during performance runs.
""".
-spec observe_batch(binary(), pos_integer(), non_neg_integer()) -> ok.
observe_batch(Ns, Size, WaitMs)
  when is_binary(Ns), is_integer(Size), Size > 0,
       is_integer(WaitMs), WaitMs >= 0 ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                _ = prometheus_histogram:observe(
                      quod_consensus_batch_size, [label(Ns)], Size),
                _ = prometheus_histogram:observe(
                      quod_consensus_batch_wait_ms, [label(Ns)], WaitMs),
                ok
            catch _:_ -> ok
            end
    end;
observe_batch(_Ns, _Size, _WaitMs) ->
    ok.

-doc """
Record how many internal retargets an origin-owned submission needed before it
resolved. Zero is a first-placement completion. Observability is never a
dependency of caller resolution, including while the metrics process is absent
or restarting.
""".
-spec observe_ingress_retarget_hops(binary(), non_neg_integer()) -> ok.
observe_ingress_retarget_hops(Ns, Hops)
  when is_binary(Ns), is_integer(Hops), Hops >= 0 ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                _ = prometheus_histogram:observe(
                      quod_consensus_ingress_retarget_hops,
                      [label(Ns)], Hops),
                ok
            catch _:_ -> ok
            end
    end;
observe_ingress_retarget_hops(_Ns, _Hops) ->
    ok.

-doc "Count one locally authoritative re-proof response returned to a caller.".
-spec count_tx_retry(binary(), membership_skipped | stale_sequence) -> ok.
count_tx_retry(Ns, Reason)
  when is_binary(Ns),
       (Reason =:= membership_skipped orelse Reason =:= stale_sequence) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                _ = prometheus_counter:inc(
                      quod_tx_retries_total,
                      [label(Ns), atom_to_binary(Reason, utf8)]),
                ok
            catch _:_ -> ok
            end
    end;
count_tx_retry(_Ns, _Reason) ->
    ok.

-doc "Count one temporary DTX validation abstention or normal-path redrive.".
-spec count_dtx_validation(binary(), abstain | redrive) -> ok.
count_dtx_validation(Ns, Event)
  when is_binary(Ns), (Event =:= abstain orelse Event =:= redrive) ->
    count_fixed_event(
      quod_dtx_validation_events_total, Ns, Event, 1);
count_dtx_validation(_Ns, _Event) ->
    ok.

-doc "Count bounded DTX target-delivery attempts and correlated outcomes.".
-spec count_dtx_submit_fanout(
        binary(), attempted | accepted | refused | uncertain | unavailable,
        non_neg_integer()) -> ok.
count_dtx_submit_fanout(Ns, Result, Count)
  when is_binary(Ns), is_integer(Count), Count >= 0,
       (Result =:= attempted orelse Result =:= accepted orelse
        Result =:= refused orelse Result =:= uncertain orelse
        Result =:= unavailable) ->
    count_fixed_event(quod_dtx_submit_fanout_total, Ns, Result, Count);
count_dtx_submit_fanout(_Ns, _Result, _Count) ->
    ok.

count_fixed_event(_Name, _Ns, _Event, 0) ->
    ok;
count_fixed_event(Name, Ns, Event, Count) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            try
                _ = prometheus_counter:inc(
                      Name, [label(Ns), atom_to_binary(Event, utf8)], Count),
                ok
            catch _:_ -> ok
            end
    end.

%% --- labels --------------------------------------------------------------

%% This node's stable identity for the constant `node_id` label. `node_pubkey` is set by
%% quod_app:apply_identity before the supervisor (hence this process) starts;
%% the `local` fallback covers configuration-free tests.
local_node_id() ->
    case application:get_env(quod, node_pubkey) of
        {ok, Pub} when is_binary(Pub) -> quod_identity:short(Pub);
        _                             -> <<"local">>
    end.

author_label(A) when is_binary(A) -> quod_identity:short(A);
author_label(A)                   -> iolist_to_binary(io_lib:format("~0p", [A])).

%% A prometheus label value must be printable UTF-8. A well-formed namespace passes through unchanged; a
%% pathological one is base64'd so it can never produce a malformed /metrics exposition line.
label(Ns) when is_binary(Ns) ->
    case unicode:characters_to_binary(Ns) of
        B when is_binary(B) -> B;
        _                   -> base64:encode(Ns)
    end.

-ifdef(TEST).
%% EXACTLY the keys refresh_log_ns/1's map pattern requires of quod_simplex:stats_map/1.
%% The lockstep eunit (quod_simplex_tests) asserts every one exists in stats_map — a key
%% added to the pattern without the stat would otherwise silently zero ALL consensus gauges.
consensus_stat_keys() ->
    [slot, committed, approved, pipeline_gap, last_applied, committee_size,
     appends, proposals, batched_txs, batch_window_ms,
     commits, submitted, skips, pending,
     r_busy, r_redirect, r_bad, r_stale, membership_rejects,
     ingress_queued, ingress_overflow, ingress_expired, ingress_forwarded,
     custody_depth, custody_ready, custody_bytes, ingress_retargets,
     relay_accepted, relay_redrives, relay_duplicates,
     redrives, progress_slot, progress_phase_code, progress_quorum_ready,
     progress_timeouts, quorum_pauses, head_support_votes, head_commit_votes,
     head_complaint_votes, head_complaint_signed, missing_certified_blocks,
     weak_cert_waits, is_validator, syncing, ahead_gap].
-endif.
