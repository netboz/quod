-module(quod_metrics).
-moduledoc """
Prometheus metrics for quod, served at `GET /metrics` on `metrics_port`
(default 14568).

Per-namespace Brahms gauges (`m:quod_brahms`) are refreshed on a short timer and
labelled by `namespace`:

| metric | meaning |
| ------ | ------- |
| `quod_up` | 1 while the node is up |
| `quod_brahms_view_size{namespace}` | size of the view `V` |
| `quod_brahms_sample_size{namespace}` | size of the uniform sample |
| `quod_brahms_links{namespace}` | live cached links to peers |
| `quod_brahms_rounds{namespace}` | rounds driven so far |
| `quod_brahms_evictions{namespace}` | dead peers evicted by sample validation (cumulative) |
| `quod_brahms_tombstones{namespace}` | current tombstone entries (bounded; drains to 0) |
| `quod_brahms_estimated_n{namespace}` | estimated network size n̂ (KMV; exact below k) |
""".

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(REFRESH_MS, 5000).

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
    declare(),
    prometheus_gauge:set(quod_up, 1),
    self() ! refresh,
    logger:info("quod: prometheus metrics on :~p/metrics", [Port]),
    {ok, #{}}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State)        -> {noreply, State}.

handle_info(refresh, State) ->
    _ = [refresh_ns(Ns)        || Ns <- quod_brahms:namespaces()],
    _ = [refresh_log_ns(Ns)    || Ns <- quod_simplex:namespaces()],
    _ = [refresh_prolog_ns(Ns) || Ns <- quod_prolog:namespaces()],
    erlang:send_after(?REFRESH_MS, self(), refresh),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

%% --- helpers -------------------------------------------------------------

declare() ->
    _ = prometheus_gauge:declare([{name, quod_up}, {help, "1 while the quod node is up"}]),
    G = fun(Name, Help) ->
            prometheus_gauge:declare([{name, Name}, {help, Help}, {labels, [namespace]}])
        end,
    _ = G(quod_brahms_view_size,   "Brahms view size per namespace"),
    _ = G(quod_brahms_sample_size, "Brahms uniform sample size per namespace"),
    _ = G(quod_brahms_links,       "Live cached links to peers per namespace"),
    _ = G(quod_brahms_rounds,      "Brahms rounds driven per namespace"),
    _ = G(quod_brahms_evictions,   "Dead peers evicted by sample validation per namespace (cumulative)"),
    _ = G(quod_brahms_tombstones,  "Current tombstone entries per namespace (bounded; drains to 0)"),
    _ = G(quod_brahms_estimated_n, "Estimated network size n-hat per namespace (KMV; exact below k)"),
    %% consensus (m:quod_simplex) + fact engine (m:quod_prolog), per namespace
    _ = G(quod_consensus_slot,           "Height: index of the last block"),
    _ = G(quod_consensus_committed,      "Highest committed slot"),
    _ = G(quod_consensus_last_applied,   "Highest applied slot"),
    _ = G(quod_consensus_committee_size, "Committee (validator set) size"),
    _ = G(quod_consensus_appends,        "Appends accepted (cumulative)"),
    _ = G(quod_consensus_commits,        "Blocks committed + applied (cumulative)"),
    _ = G(quod_prolog_applied,     "Highest applied block index (fact engine)"),
    _ = G(quod_prolog_applies,     "Blocks applied to the kb (cumulative)"),
    _ = G(quod_prolog_rejects,     "Blocks rejected by the apply-time OCC check (cumulative)"),
    _ = G(quod_prolog_proves,      "Read proofs served (cumulative)"),
    _ = G(quod_prolog_conflicts,   "OCC conflicts detected (cumulative)"),
    ok.

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
        _ ->
            ok
    end.

refresh_log_ns(Ns) ->
    case quod_simplex:stats(Ns) of
        #{slot := Sl, committed := CI, last_applied := LA,
          committee_size := CS, appends := AP, commits := CM} ->
            S = fun(Name, V) -> prometheus_gauge:set(Name, [label(Ns)], V) end,
            _ = S(quod_consensus_slot,           Sl),
            _ = S(quod_consensus_committed,      CI),
            _ = S(quod_consensus_last_applied,   LA),
            _ = S(quod_consensus_committee_size, CS),
            _ = S(quod_consensus_appends,        AP),
            _ = S(quod_consensus_commits,        CM),
            ok;
        _ -> ok
    end.

refresh_prolog_ns(Ns) ->
    case quod_prolog:stats(Ns) of
        #{applied := A, applies := AP, rejects := RJ, proves := PR, conflicts := CF} ->
            S = fun(Name, V) -> prometheus_gauge:set(Name, [label(Ns)], V) end,
            _ = S(quod_prolog_applied,   A),
            _ = S(quod_prolog_applies,   AP),
            _ = S(quod_prolog_rejects,   RJ),
            _ = S(quod_prolog_proves,    PR),
            _ = S(quod_prolog_conflicts, CF),
            ok;
        _ -> ok
    end.

%% A prometheus label value must be valid (printable) UTF-8 (review #12). A
%% well-formed namespace passes through unchanged; a pathological one is base64'd
%% so it can never produce a malformed /metrics exposition line.
label(Ns) when is_binary(Ns) ->
    case unicode:characters_to_binary(Ns) of
        B when is_binary(B) -> B;
        _                   -> base64:encode(Ns)
    end.
