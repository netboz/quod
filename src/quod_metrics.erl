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

| metric | type | extra labels | what it means (plain) |
| ------ | ---- | ------------ | --------------------- |
| `quod_up` | gauge | | 1 while the node is running |
| `quod_brahms_*{namespace}` | gauge | | peer discovery: how many other nodes are known / sampled / connected, plus the estimated network size |
| `quod_consensus_slot/committed/approved/last_applied/committee_size{namespace}` | gauge | | block numbers (newest / final / votable / applied) and how many nodes may vote |
| `quod_consensus_pipeline_gap{namespace}` | gauge | | blocks with enough votes but not yet final (stays 0-2 by design) |
| `quod_consensus_appends/proposals/batched_txs/commits/submitted/skips{namespace}` | gauge | | running totals of change and block activity |
| `quod_consensus_pending{namespace}` | gauge | | change requests waiting to be made final right now |
| `quod_consensus_append_busy/redirect/bad{namespace}` | gauge | | running totals of turned-away change requests, by reason |
| `quod_consensus_is_validator{namespace}` | gauge | | 1 if this node may vote (it actually votes only when `syncing` is 0) |
| `quod_consensus_syncing{namespace}` | gauge | | 1 while catching up / confirming the latest block, 0 once up to date |
| `quod_consensus_redrives/weak_cert_waits{namespace}` | gauge | | running totals: proposals re-sent while waiting, and blocks held back for lack of votes |
| `quod_consensus_ahead_gap{namespace}` | gauge | | how many final blocks the network is ahead of this node (0 = up to date) |
| `quod_prolog_applied/applies/rejects/proves/conflicts{namespace}` | gauge | | this node's stored-data activity (written / rejected / queried) |
| `quod_prolog_parked{namespace}` | gauge | | writes waiting here for their change to be made final |
| `quod_prolog_park_timeouts{namespace}` | gauge | | running total of writes that gave up waiting |
| `quod_prolog_proof_workers/ask_workers{namespace}` | gauge | | queries and cross-ontology answer streams currently using a frozen data snapshot |
| `quod_prolog_kb_memory_words{namespace}` | gauge | | Erlang VM words used by the committed knowledge-base ETS table |
| `quod_prolog_kb_history_predicates{namespace}` | gauge | | predicates retaining an older version because a query still needs it |
| `quod_feed_pushed/ingested/pulled{namespace}` | gauge | | running totals of blocks spread / received / pulled to fill gaps |
| `quod_feed_dropped{namespace}` | gauge | `reason` | blocks thrown away, by reason (duplicate / gap / unverified / ...) |
| `quod_feed_digests/fresh_digests{namespace}` | gauge | | nodes sending 'alive' heartbeats / of those, still fresh |
| `quod_tx_commit_latency_ms{namespace}` | histogram | | time from handing in a change to it being made final |
| `quod_tx_diff_ops{namespace}` | histogram | | pieces of data added or removed per finished change |
| `quod_tx_committed_total{namespace}` | counter | `author` | finished changes, by the node that submitted them |
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
    %% Peer discovery: how this node finds and keeps track of the other nodes.
    _ = G(quod_brahms_view_size,   "How many other nodes this node currently knows about."),
    _ = G(quod_brahms_sample_size, "How many of those known nodes are in the small random set this node shares updates with, so gossip stays even."),
    _ = G(quod_brahms_links,       "How many other nodes this node has an open connection to right now."),
    _ = G(quod_brahms_rounds,      "Total number of update-sharing rounds this node has run (only ever goes up)."),
    _ = G(quod_brahms_evictions,   "Total number of nodes this node has dropped after they stopped responding (only ever goes up)."),
    _ = G(quod_brahms_tombstones,  "Nodes just marked dead and remembered for a short while so they are not added straight back (temporary; returns to 0)."),
    _ = G(quod_brahms_estimated_n, "This node's estimate of how many nodes are in the whole network."),
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
    _ = G(quod_consensus_commits,         "Total blocks that have been made final and applied (only ever goes up)."),
    _ = G(quod_consensus_submitted,       "Total change requests handed to this node (only ever goes up)."),
    _ = G(quod_consensus_skips,           "Total times a turn was skipped because that turn's leader did not produce a block in time (only ever goes up)."),
    _ = G(quod_consensus_pending,         "Change requests waiting to be made final right now."),
    _ = G(quod_consensus_append_busy,     "Total change requests turned away because this node was already busy finishing another one (only ever goes up)."),
    _ = G(quod_consensus_append_redirect, "Total change requests that reached a node that was not the current leader and were pointed to the right one (only ever goes up)."),
    _ = G(quod_consensus_append_bad,      "Total change requests rejected because they were malformed or not allowed (only ever goes up)."),
    _ = G(quod_consensus_membership_rejects, "Total requests to add or remove a voting node that this node judged invalid and refused (only ever goes up)."),
    _ = G(quod_consensus_redrives,        "Total times this node re-sent a proposal it was still waiting on instead of giving up. Climbing steadily means one of the voting nodes is not responding."),
    _ = G(quod_consensus_is_validator,    "1 if this node is allowed to vote on changes, 0 if it only reads and follows along. It actually casts votes only when 'syncing' is also 0."),
    _ = G(quod_consensus_syncing,         "1 while this node is still catching up or confirming it is on the latest block; 0 once it is up to date. A voting node cannot vote until this is 0."),
    _ = G(quod_consensus_weak_cert_waits, "Total times this node held off finishing a block because it did not yet have enough valid votes from the current voting set, and waited for them. Climbing means this node fell behind around a change to the voting set (only ever goes up)."),
    _ = G(quod_consensus_ahead_gap,       "How many final blocks the rest of the network is ahead of this node (0 means up to date). A value that stays above 0 means this node has fallen behind and is fetching the blocks it is missing."),
    %% Stored data: this node's own copy of the shared data.
    _ = G(quod_prolog_applied,       "The number of the newest block this node has written into its stored data."),
    _ = G(quod_prolog_applies,       "Total finished changes this node has written into its stored data (only ever goes up)."),
    _ = G(quod_prolog_rejects,       "Total finished changes not written because the data they depended on had already changed (only ever goes up)."),
    _ = G(quod_prolog_proves,        "Total read queries this node has answered (only ever goes up)."),
    _ = G(quod_prolog_conflicts,     "Total finished changes skipped because they clashed with newer data (only ever goes up)."),
    _ = G(quod_prolog_parked,        "Write requests waiting here for their change to be made final right now."),
    _ = G(quod_prolog_park_timeouts, "Total write requests that gave up waiting because their change was never made final (only ever goes up)."),
    _ = G(quod_prolog_proof_workers, "How many local queries are running right now. Each uses a frozen view of the data, so a value at the configured limit means new queries are being turned away until one finishes."),
    _ = G(quod_prolog_ask_workers, "How many cross-ontology answer streams this node is serving right now. Each keeps a frozen view of the requested ontology until it finishes or is cancelled."),
    _ = G(quod_prolog_kb_memory_words, "How much Erlang VM memory, in words, this ontology's shared knowledge-base table is using. Multiply by the VM word size (normally 8 bytes on a 64-bit node) for an approximate byte count."),
    _ = G(quod_prolog_kb_history_predicates, "How many predicates are temporarily keeping an older data version because a running query or cross-ontology answer stream still needs its frozen view. It should return to 0 after those queries finish."),
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
    _ = H(quod_tx_commit_latency_ms, "How long each change took from being handed in to being made final, in milliseconds.", ?LAT_BUCKETS),
    _ = H(quod_tx_diff_ops,          "How many individual pieces of data each finished change added or removed.", ?DIFF_BUCKETS),
    _ = prometheus_counter:declare([{name, quod_tx_committed_total},
                                    {help, "Total finished changes, grouped by the node that submitted them (only ever goes up)."},
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
        #{slot := Sl, committed := CI, approved := AV, pipeline_gap := PG,
          last_applied := LA, committee_size := CS,
          appends := AP, proposals := PR, batched_txs := BT,
          commits := CM, submitted := SU, skips := SK, pending := PE,
          r_busy := RB, r_redirect := RR, r_bad := RD, membership_rejects := MR,
          redrives := RV, weak_cert_waits := WC, is_validator := IV, syncing := SY,
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
          parked := PK, park_timeouts := PT, proof_workers := PW, ask_workers := AW,
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
            _ = S(quod_prolog_ask_workers, AW),
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

%% A live-committed entry: observe the per-tx dimensions a scalar counter can't carry. A `noop` skip is not
%% a transaction. Latency needs both wall-clocks real (submit > 0, commit ≥ submit); a cross-node skew that
%% would make it negative is dropped rather than recorded as a bogus sample.
observe_commit(#entry{data = Data, timestamp = BlockTs}) ->
    case quod_ledger:payload(Data) of
        {ok, Payload} -> lists:foreach(fun(T) -> observe_payload(T, BlockTs) end, Payload);
        error         -> ok
    end.

observe_payload(#transaction{} = Transaction, BlockTs) -> observe_transaction(Transaction, BlockTs);
observe_payload(noop, _BlockTs)                         -> ok.   %% complaint skip, not a transaction

observe_transaction(#transaction{caller_ns = Ns, author = Author, diff = Diff,
                                  submitted_at = Sub}, BlockTs) ->
    L = label(Ns),
    _ = case is_integer(Sub) andalso Sub > 0 andalso is_integer(BlockTs) andalso BlockTs >= Sub of
            true  -> prometheus_histogram:observe(quod_tx_commit_latency_ms, [L], BlockTs - Sub);
            false -> ok
        end,
    _ = prometheus_histogram:observe(quod_tx_diff_ops, [L], length(Diff)),
    _ = prometheus_counter:inc(quod_tx_committed_total, [L, author_label(Author)]),
    ok.

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
