-module(quod_metrics).
-moduledoc """
Prometheus metrics for quod, served at `GET /metrics` on `metrics_port` (default 14568).

Every series carries a constant **`node_id`** label — this node's identity (`kp_<hex>`, from
`m:quod_identity`) — so a fleet-wide Prometheus tells nodes apart by their stable pubkey rather than a
volatile host:port. Per-namespace series add a **`namespace`** label.

Two collection paths:

  * **Poll (5s).** Scalar gauges are refreshed from each subsystem's `stats/1`
    (`m:quod_brahms`, `m:quod_simplex`, `m:quod_prolog`, `m:quod_feed`). Cumulative counts are exposed
    as gauges set to the running total (use `rate()`/`increase()` in Grafana).
  * **Event.** Per-transaction histograms + a per-author counter are driven by the LIVE
    `{committed, Ns}` commit event (never replay — see `quod_simplex:publish_feed/3`), so they observe
    each finalized transaction exactly once on the committing node.

| metric | type | extra labels | meaning |
| ------ | ---- | ------------ | ------- |
| `quod_up` | gauge | — | 1 while the node is up |
| `quod_brahms_*{namespace}` | gauge | | overlay view/sample/links/rounds/evictions/tombstones/n̂ |
| `quod_consensus_slot/committed/last_applied/committee_size{namespace}` | gauge | | consensus height + committee |
| `quod_consensus_appends/commits/submitted/skips{namespace}` | gauge | | cumulative append/commit/submit/skip counts |
| `quod_consensus_pending{namespace}` | gauge | | in-flight appends awaiting commit |
| `quod_consensus_append_busy/redirect/bad{namespace}` | gauge | | append rejections by reason (cumulative) |
| `quod_consensus_is_validator{namespace}` | gauge | | 1 if committee facts include this node; pair with `syncing=0` for voting readiness |
| `quod_consensus_syncing{namespace}` | gauge | | 1 until recovery has corroborated the local tip; 0 when settled |
| `quod_consensus_redrives/weak_cert_waits{namespace}` | gauge | | stuck-proposal re-sends / weak-cert finalize refusals (cumulative) |
| `quod_consensus_ahead_gap{namespace}` | gauge | | committed slots the committee is ahead of this node (0 = caught up; sustained >0 = fell behind the live window) |
| `quod_prolog_applied/applies/rejects/proves/conflicts{namespace}` | gauge | | fact-engine apply/prove/OCC counts |
| `quod_prolog_parked{namespace}` | gauge | | writes parked awaiting commit |
| `quod_prolog_park_timeouts{namespace}` | gauge | | parked writes reaped by TTL (cumulative) |
| `quod_feed_pushed/ingested/pulled{namespace}` | gauge | | dissemination health (cumulative) |
| `quod_feed_dropped{namespace}` | gauge | `reason` | dropped blocks by reason (duplicate/gap/unverified/…) |
| `quod_feed_digests/fresh_digests{namespace}` | gauge | | peers tracked for liveness / of those, fresh now (admission readiness) |
| `quod_tx_commit_latency_ms{namespace}` | histogram | | submit→commit latency per tx |
| `quod_tx_diff_ops{namespace}` | histogram | | asserts+retracts per committed tx |
| `quod_tx_committed_total{namespace}` | counter | `author` | committed txs by submitting node |
""".

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("quod_ledger.hrl").

-define(REFRESH_MS, 5000).
-define(LAT_BUCKETS,  [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]).  %% ms: submit→commit
-define(DIFF_BUCKETS, [1, 2, 4, 8, 16, 32, 64, 128]).                               %% asserts+retracts per tx

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
    _ = [refresh_prolog_ns(Ns) || Ns <- quod_prolog:namespaces()],
    _ = [refresh_feed_ns(Ns)   || Ns <- quod_simplex:namespaces()],   %% feed runs per-ns alongside consensus
    State1 = subscribe_commits(State),
    erlang:send_after(?REFRESH_MS, self(), refresh),
    {noreply, State1};
handle_info({committed, _Slot, #entry{} = Entry}, State) ->
    _ = observe_commit(Entry),
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
    %% Peer discovery (how this node finds and tracks other nodes hosting the same ontology)
    _ = G(quod_brahms_view_size,   "How many peers this node currently knows about for this ontology."),
    _ = G(quod_brahms_sample_size, "How many of those peers are in this node's small random sample used to gossip fairly."),
    _ = G(quod_brahms_links,       "How many peers this node currently has an open connection to for this ontology."),
    _ = G(quod_brahms_rounds,      "How many peer-gossip rounds this node has run for this ontology (running total)."),
    _ = G(quod_brahms_evictions,   "How many peers this node has dropped after finding them unreachable (running total)."),
    _ = G(quod_brahms_tombstones,  "Peers just marked dead and remembered briefly so they are not re-added (temporary; returns to 0)."),
    _ = G(quod_brahms_estimated_n, "This node's estimate of how many nodes are in the whole network for this ontology."),
    %% Consensus (agreeing on the ordered ledger of changes for this ontology)
    _ = G(quod_consensus_slot,            "The height of this ontology's ledger: the number of the most recent block."),
    _ = G(quod_consensus_committed,       "The height of the last block that is final and permanent."),
    _ = G(quod_consensus_last_applied,    "The height of the last block whose changes have been written into this node's database."),
    _ = G(quod_consensus_committee_size,  "How many nodes are on the committee that votes on changes to this ontology."),
    _ = G(quod_consensus_appends,         "How many changes this node has proposed while acting as the leader (running total)."),
    _ = G(quod_consensus_commits,         "How many blocks have been finalised and applied (running total)."),
    _ = G(quod_consensus_submitted,       "How many change requests have been submitted at this node (running total)."),
    _ = G(quod_consensus_skips,           "How many ledger slots were skipped because a leader did not produce a block in time (running total)."),
    _ = G(quod_consensus_pending,         "How many submitted changes are waiting to be finalised right now."),
    _ = G(quod_consensus_append_busy,     "Change requests turned away because this node was already busy finalising one (running total)."),
    _ = G(quod_consensus_append_redirect, "Change requests sent to the wrong node (not the current leader) and redirected (running total)."),
    _ = G(quod_consensus_append_bad,      "Change requests rejected as malformed or not allowed (running total)."),
    _ = G(quod_consensus_membership_rejects, "Proposed committee changes (adding or removing a voting node) that this node checked against its own data and rejected as invalid (running total)."),
    _ = G(quod_consensus_redrives,        "How many times this node re-sent a proposal it was still waiting on, instead of giving up on it (running total). Climbing steadily means a committee member is not responding."),
    _ = G(quod_consensus_is_validator,    "1 if this node is listed in this ontology's committee facts, 0 if it is a read-only observer. It may vote only when consensus_syncing is also 0."),
    _ = G(quod_consensus_syncing,         "1 while this node is recovering or corroborating its ledger tip, 0 when it is settled. A validator must be 0 before it may vote."),
    _ = G(quod_consensus_weak_cert_waits, "How many times this node refused to finalise a block because its proof-of-agreement did not have enough signatures from the current committee, and waited for a valid one instead (running total). Climbing means this node fell behind across a committee change and is waiting to catch up."),
    _ = G(quod_consensus_ahead_gap,       "How many committed slots the committee has finalised beyond this node's own height (0 = caught up). A sustained positive value means this node has fallen behind the live window and will fetch the missing blocks to catch back up."),
    %% Knowledge base (this node's copy of the ontology's facts)
    _ = G(quod_prolog_applied,       "The height of the last block written into this node's knowledge base."),
    _ = G(quod_prolog_applies,       "How many blocks have been written into the knowledge base (running total)."),
    _ = G(quod_prolog_rejects,       "Finalised changes that were not written because the data they relied on had changed in the meantime (running total)."),
    _ = G(quod_prolog_proves,        "How many read queries this node has answered (running total)."),
    _ = G(quod_prolog_conflicts,     "How many times a finalised change clashed with newer data and was skipped (running total)."),
    _ = G(quod_prolog_parked,        "How many write requests are waiting here for their change to be finalised right now."),
    _ = G(quod_prolog_park_timeouts, "Write requests that gave up waiting because their change never finalised (running total)."),
    %% Spreading finalised blocks to the wider network (gossip)
    _ = G(quod_feed_pushed,   "Blocks this node finalised and started spreading to the rest of the network (running total)."),
    _ = G(quod_feed_ingested, "Blocks received from other nodes, checked, applied, and passed along (running total)."),
    _ = G(quod_feed_pulled,   "How many times this node asked peers to send blocks it was missing (running total)."),
    _ = G(quod_feed_digests,       "How many peers this node currently tracks a liveness heartbeat for (used to decide whether a candidate is alive enough to admit to the committee)."),
    _ = G(quod_feed_fresh_digests, "How many of those tracked peers sent a heartbeat recently enough to count as alive right now."),
    _ = prometheus_gauge:declare([{name, quod_feed_dropped},
                                  {help, "Blocks received from peers that this node dropped, grouped by reason (running total). "
                                         "duplicate = already had it (harmless); gap = arrived out of order, fetched again later; "
                                         "unverified = failed its proof-of-agreement check (the one to watch); "
                                         "non_following / oversized / ingest_busy = other reasons."},
                                  {labels, [namespace, reason]}, {constant_labels, CL}]),
    %% Per-change timing and size
    _ = H(quod_tx_commit_latency_ms, "How long each change took from being submitted to being finalised, in milliseconds.", ?LAT_BUCKETS),
    _ = H(quod_tx_diff_ops,          "How many facts each finalised change added or removed.",    ?DIFF_BUCKETS),
    _ = prometheus_counter:declare([{name, quod_tx_committed_total},
                                    {help, "Finalised changes, grouped by the node that submitted them (running total)."},
                                    {labels, [namespace, author]}, {constant_labels, CL}]),
    ok.

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

refresh_log_ns(Ns) ->
    case quod_simplex:stats(Ns) of
        #{slot := Sl, committed := CI, last_applied := LA, committee_size := CS,
          appends := AP, commits := CM, submitted := SU, skips := SK, pending := PE,
          r_busy := RB, r_redirect := RR, r_bad := RD, membership_rejects := MR,
          redrives := RV, weak_cert_waits := WC, is_validator := IV, syncing := SY,
          ahead_gap := AG} ->
            S = fun(Name, V) -> prometheus_gauge:set(Name, [label(Ns)], V) end,
            _ = S(quod_consensus_slot,            Sl),
            _ = S(quod_consensus_committed,       CI),
            _ = S(quod_consensus_last_applied,    LA),
            _ = S(quod_consensus_committee_size,  CS),
            _ = S(quod_consensus_appends,         AP),
            _ = S(quod_consensus_commits,         CM),
            _ = S(quod_consensus_submitted,       SU),
            _ = S(quod_consensus_skips,           SK),
            _ = S(quod_consensus_pending,         PE),
            _ = S(quod_consensus_append_busy,     RB),
            _ = S(quod_consensus_append_redirect, RR),
            _ = S(quod_consensus_append_bad,      RD),
            _ = S(quod_consensus_membership_rejects, MR),
            _ = S(quod_consensus_redrives,        RV),
            _ = S(quod_consensus_is_validator,    IV),
            _ = S(quod_consensus_syncing,         SY),
            _ = S(quod_consensus_weak_cert_waits, WC),
            _ = S(quod_consensus_ahead_gap,       AG),
            ok;
        _ -> ok
    end.

refresh_prolog_ns(Ns) ->
    case quod_prolog:stats(Ns) of
        #{applied := A, applies := AP, rejects := RJ, proves := PR, conflicts := CF,
          parked := PK, park_timeouts := PT} ->
            S = fun(Name, V) -> prometheus_gauge:set(Name, [label(Ns)], V) end,
            _ = S(quod_prolog_applied,       A),
            _ = S(quod_prolog_applies,       AP),
            _ = S(quod_prolog_rejects,       RJ),
            _ = S(quod_prolog_proves,        PR),
            _ = S(quod_prolog_conflicts,     CF),
            _ = S(quod_prolog_parked,        PK),
            _ = S(quod_prolog_park_timeouts, PT),
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

%% A live-committed entry: observe the per-tx dimensions a scalar counter can't carry. A `noop` skip is not
%% a transaction. Latency needs both wall-clocks real (submit > 0, commit ≥ submit); a cross-node skew that
%% would make it negative is dropped rather than recorded as a bogus sample.
observe_commit(#entry{data = #transaction{caller_ns = Ns, author = Author, diff = Diff,
                                          submitted_at = Sub}, timestamp = BlockTs}) ->
    L = label(Ns),
    _ = case is_integer(Sub) andalso Sub > 0 andalso is_integer(BlockTs) andalso BlockTs >= Sub of
            true  -> prometheus_histogram:observe(quod_tx_commit_latency_ms, [L], BlockTs - Sub);
            false -> ok
        end,
    _ = prometheus_histogram:observe(quod_tx_diff_ops, [L], length(Diff)),
    _ = prometheus_counter:inc(quod_tx_committed_total, [L, author_label(Author)]),
    ok;
observe_commit(#entry{data = noop}) -> ok.   %% a complaint-skipped slot is not a transaction

%% --- labels --------------------------------------------------------------

%% This node's stable identity for the constant `node_id` label. `node_pubkey` is set by
%% quod_app:apply_identity before the supervisor (hence this process) starts; the `local` fallback covers
%% the no-identity/legacy path.
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
