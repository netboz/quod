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
| `quod_prolog_applied/applies/rejects/proves/conflicts{namespace}` | gauge | | fact-engine apply/prove/OCC counts |
| `quod_prolog_parked{namespace}` | gauge | | writes parked awaiting commit |
| `quod_prolog_park_timeouts{namespace}` | gauge | | parked writes reaped by TTL (cumulative) |
| `quod_feed_pushed/ingested/pulled{namespace}` | gauge | | dissemination health (cumulative) |
| `quod_feed_dropped{namespace}` | gauge | `reason` | dropped blocks by reason (duplicate/gap/unverified/…) |
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
    _ = prometheus_gauge:declare([{name, quod_up}, {help, "1 while the quod node is up"},
                                  {constant_labels, CL}]),
    G = fun(Name, Help) ->
            prometheus_gauge:declare([{name, Name}, {help, Help}, {labels, [namespace]},
                                      {constant_labels, CL}])
        end,
    H = fun(Name, Help, Buckets) ->
            prometheus_histogram:declare([{name, Name}, {help, Help}, {labels, [namespace]},
                                          {buckets, Buckets}, {constant_labels, CL}])
        end,
    %% Brahms overlay
    _ = G(quod_brahms_view_size,   "Brahms view size per namespace"),
    _ = G(quod_brahms_sample_size, "Brahms uniform sample size per namespace"),
    _ = G(quod_brahms_links,       "Live cached links to peers per namespace"),
    _ = G(quod_brahms_rounds,      "Brahms rounds driven per namespace"),
    _ = G(quod_brahms_evictions,   "Dead peers evicted by sample validation per namespace (cumulative)"),
    _ = G(quod_brahms_tombstones,  "Current tombstone entries per namespace (bounded; drains to 0)"),
    _ = G(quod_brahms_estimated_n, "Estimated network size n-hat per namespace (KMV; exact below k)"),
    %% consensus (m:quod_simplex)
    _ = G(quod_consensus_slot,            "Height: index of the last block"),
    _ = G(quod_consensus_committed,       "Highest committed slot"),
    _ = G(quod_consensus_last_applied,    "Highest applied slot"),
    _ = G(quod_consensus_committee_size,  "Committee (validator set) size"),
    _ = G(quod_consensus_appends,         "Appends accepted as leader (cumulative)"),
    _ = G(quod_consensus_commits,         "Blocks committed + applied (cumulative)"),
    _ = G(quod_consensus_submitted,       "Append attempts (cumulative)"),
    _ = G(quod_consensus_skips,           "Complaint-skipped (noop) slots (cumulative)"),
    _ = G(quod_consensus_pending,         "In-flight appends awaiting commit"),
    _ = G(quod_consensus_append_busy,     "Appends rejected: a proposal already in flight (cumulative)"),
    _ = G(quod_consensus_append_redirect, "Appends redirected: not this slot's leader / not a member (cumulative)"),
    _ = G(quod_consensus_append_bad,      "Appends rejected: unacceptable change (cumulative)"),
    _ = G(quod_consensus_membership_rejects, "Membership proposals a KB verdict rejected as invalid (cumulative)"),
    %% fact engine (m:quod_prolog)
    _ = G(quod_prolog_applied,       "Highest applied block index (fact engine)"),
    _ = G(quod_prolog_applies,       "Blocks applied to the kb (cumulative)"),
    _ = G(quod_prolog_rejects,       "Blocks rejected by the apply-time OCC check (cumulative)"),
    _ = G(quod_prolog_proves,        "Read proofs served (cumulative)"),
    _ = G(quod_prolog_conflicts,     "OCC conflicts detected (cumulative)"),
    _ = G(quod_prolog_parked,        "Writes parked awaiting commit"),
    _ = G(quod_prolog_park_timeouts, "Parked writes reaped by TTL (cumulative)"),
    %% dissemination feed (m:quod_feed)
    _ = G(quod_feed_pushed,   "Local commits originated onto the feed (cumulative)"),
    _ = G(quod_feed_ingested, "Gossiped blocks verified + applied + relayed (cumulative)"),
    _ = G(quod_feed_pulled,   "Anti-entropy pull rounds started (cumulative)"),
    _ = prometheus_gauge:declare([{name, quod_feed_dropped},
                                  {help, "Gossiped blocks dropped by reason (cumulative): duplicate = benign loop-"
                                         "suppressed redundancy, gap = re-pulled by anti-entropy, unverified = bad "
                                         "cert (the one to watch), non_following/oversized/ingest_busy"},
                                  {labels, [namespace, reason]}, {constant_labels, CL}]),
    %% per-transaction (LIVE {committed,Ns} event)
    _ = H(quod_tx_commit_latency_ms, "Submit-to-commit latency per transaction (ms)", ?LAT_BUCKETS),
    _ = H(quod_tx_diff_ops,          "Asserts+retracts per committed transaction",    ?DIFF_BUCKETS),
    _ = prometheus_counter:declare([{name, quod_tx_committed_total},
                                    {help, "Committed transactions by submitting node"},
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
          r_busy := RB, r_redirect := RR, r_bad := RD, membership_rejects := MR} ->
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
        #{pushed := PU, ingested := IN, pulled := PL, dropped := DR} ->
            S = fun(Name, V) -> prometheus_gauge:set(Name, [label(Ns)], V) end,
            _ = S(quod_feed_pushed,   PU),
            _ = S(quod_feed_ingested, IN),
            _ = S(quod_feed_pulled,   PL),
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
observe_commit(#entry{data = noop}) -> ok;   %% a complaint-skipped slot is not a transaction
observe_commit(_)                   -> ok.

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
