-module(quod_explorer_ws).
-moduledoc """
Live event stream of the explorer (`m:quod_explorer`). One WebSocket per browser tab;
each pushes JSON frames built by `m:quod_explorer_http`'s shared renderers, fusing the
two commit-side seams:

- **`{committed, Ns}`** (pre-apply, from `quod_simplex:publish_feed/3`) — the full block
  the instant it finalizes: every transaction with author, submit time, diff, result and
  the quorum certificate. This paints the row immediately.
- **`{runtime, Ns}`** (post-apply, from `quod_prolog`) — the per-transaction apply outcome:
  `applied_live` when it changed the kb (flips the row to *applied*) and `rejected_live` when
  it committed but its OCC re-check failed at apply (flips the row to *rejected*). Every
  committed transaction yields exactly one of the two, so the client never has to infer
  rejection. The replay boundaries on the same property become an untagged `sync` nudge (they
  carry no namespace) telling the client to refetch `/api/summary`.

Frames: `hello` (summary, on connect) · `block` · `applied` · `rejected` · `sync`.

The endpoint reads nothing from clients, so inbound frames are capped small (anything
large is abuse), and `idle_timeout => infinity` keeps a quiet ledger from closing the
socket; a real TCP close still terminates the handler.
""".
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
-include("quod_ledger.hrl").

init(Req, _Opts) ->
    {cowboy_websocket, Req, #{}, #{max_frame_size => 4096, idle_timeout => infinity}}.

websocket_init(State) ->
    Nss = lists:usort(quod_simplex:namespaces()),
    [quod_reg:subscribe({committed, Ns}) || Ns <- Nss],
    [quod_reg:subscribe({runtime, Ns}) || Ns <- Nss],
    {reply, {text, frame(#{type => hello, summary => quod_explorer_http:summary()})}, State}.

websocket_handle(_Frame, State) -> {ok, State}.

%% A finalized block. The event carries no namespace, but every transaction in a per-ns
%% quod_simplex's block names it (`caller_ns`); a `noop` skip-slot has none to attribute
%% and paints nothing, so it is dropped.
websocket_info({committed, Slot, #entry{} = E}, State) ->
    case quod_explorer_http:entry_txs(E) of
        [] -> {ok, State};
        [#transaction{caller_ns = Ns} | _] = Txs ->
            {reply, {text, frame(#{type => block, ns => Ns, slot => Slot,
                                   time => E#entry.timestamp,
                                   cert => quod_explorer_http:cert_json(E#entry.cert),
                                   txs => [quod_explorer_http:tx_json_full(T, E) || T <- Txs]})},
             State}
    end;
websocket_info({applied_live, #{ns := Ns, height := H, tx_id := Id}}, State) ->
    {reply, {text, frame(#{type => applied, ns => Ns, height => H,
                           tx_id => quod_explorer_http:tx_id_text(Id)})}, State};
%% The explicit "committed but OCC-rejected at apply" outcome, so the client shows `rejected` directly
%% instead of inferring it from a later commit (which never arrives for the last block).
websocket_info({rejected_live, #{ns := Ns, height := H, tx_id := Id}}, State) ->
    {reply, {text, frame(#{type => rejected, ns => Ns, height => H,
                           tx_id => quod_explorer_http:tx_id_text(Id)})}, State};
websocket_info({replay_started, _Id, _From}, State) ->
    {reply, {text, frame(#{type => sync})}, State};
websocket_info({replay_ready, _Id, _Height}, State) ->
    {reply, {text, frame(#{type => sync})}, State};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, _State) -> ok.

frame(Json) -> quod_explorer_http:encode(Json).
