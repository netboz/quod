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

Frames: `hello` (summary, on connect) · `block` (content or DTX phase) ·
`applied` · `rejected` · `sync`.

The namespace manager publishes each validated local topology change. This
socket updates its committed/runtime subscriptions in place and emits `sync`,
so the browser refreshes its namespace list without reconnecting.

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
    true = quod_reg:subscribe({namespace_topology, node}),
    subscribe_namespaces(Nss),
    {reply,
     {text, frame(#{type => hello, summary => quod_explorer_http:summary()})},
     State#{namespaces => Nss}}.

websocket_handle(_Frame, State) -> {ok, State}.

%% A finalized block carries its target ontology explicitly. A proof origin may
%% differ for a foreign write and is never used to route or attribute the block.
websocket_info({committed, Ns, _Slot, #entry{} = E}, State) ->
    Block = quod_explorer_http:block_json(Ns, E),
    case maps:get(kind, Block) of
        content -> committed_block_frame(Ns, Block, State);
        'begin' -> committed_block_frame(Ns, Block, State);
        prepare -> committed_block_frame(Ns, Block, State);
        decision -> committed_block_frame(Ns, Block, State);
        finalize -> committed_block_frame(Ns, Block, State);
        complete -> committed_block_frame(Ns, Block, State);
        noop -> {ok, State};
        invalid -> {ok, State}
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
websocket_info({namespace_topology, Nss0}, State) when is_list(Nss0) ->
    Nss = lists:usort([Ns || Ns <- Nss0, is_binary(Ns)]),
    Old = maps:get(namespaces, State, []),
    Added = Nss -- Old,
    Removed = Old -- Nss,
    subscribe_namespaces(Added),
    unsubscribe_namespaces(Removed),
    {reply, {text, frame(#{type => sync})},
     State#{namespaces => Nss}};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, State) ->
    unsubscribe_namespaces(maps:get(namespaces, State, [])),
    _ = quod_reg:unsubscribe({namespace_topology, node}),
    ok.

committed_block_frame(Ns, Block, State) ->
    {reply, {text, frame(Block#{type => block, ns => Ns})},
     State}.

frame(Json) -> quod_explorer_http:encode(Json).

subscribe_namespaces(Nss) ->
    [begin
         true = quod_reg:subscribe({committed, Ns}),
         true = quod_reg:subscribe({runtime, Ns})
     end || Ns <- Nss],
    ok.

unsubscribe_namespaces(Nss) ->
    [begin
         true = quod_reg:unsubscribe({committed, Ns}),
         true = quod_reg:unsubscribe({runtime, Ns})
     end || Ns <- Nss],
    ok.
