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
    _ = [refresh_ns(Ns) || Ns <- quod_brahms:namespaces()],
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
    ok.

refresh_ns(Ns) ->
    case quod_brahms:stats(Ns) of
        #{view := V, sample := S, conns := C, rounds := R, evictions := E, tombstones := T} ->
            _ = prometheus_gauge:set(quod_brahms_view_size,   [Ns], V),
            _ = prometheus_gauge:set(quod_brahms_sample_size, [Ns], S),
            _ = prometheus_gauge:set(quod_brahms_links,       [Ns], C),
            _ = prometheus_gauge:set(quod_brahms_rounds,      [Ns], R),
            _ = prometheus_gauge:set(quod_brahms_evictions,   [Ns], E),
            _ = prometheus_gauge:set(quod_brahms_tombstones,  [Ns], T),
            ok;
        _ ->
            ok
    end.
