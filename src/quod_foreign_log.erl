-module(quod_foreign_log).
-moduledoc """
Bounded node-wide verifier/cache for foreign certified DTX references.

The owner is intentionally separate from every hosted namespace.  A caller
supplies an authenticated directory route (`PeerKey`, `Endpoint`) and an exact
certified reference.  The owner admits the request under global/per-peer and
history/cache bounds, then a monitored worker pulls the existing catch-up page
format over an identity-pinned connection.  The worker folds the history from
the caller-pinned `{Namespace, GenesisAnchor}` through `quod_catchup`; no route,
peer response, cache checkpoint, or reference field is trusted by itself.
Success additionally requires that `PeerKey` belongs to the committee in the
verified post-reference-slot projection; a directory `validator` label is only
a candidate hint.  A non-member is a retryable route failure, never proof that
the certified reference itself is invalid.

The same owner also derives a certificate-verified current committee view for
an anchored identity. `quod_dtx_current_view` uses that frozen view to select
distinct current validator keys and to bind outcome/application probes to one
committee id and minimum slot. Routes remain transport hints and never become
committee evidence.

`verify/5` and the current-view APIs are synchronous only from the caller's
perspective. The gen_server never waits for network, disk replay, certificate
verification, or crypto; DTX validation callers invoke them from their existing
asynchronous verdict/recovery worker boundary.
""".

-behaviour(gen_server).

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").
-include("quod_directory_limits.hrl").
-include("quod_transport_limits.hrl").

-export([start_link/0, start_link/1,
         verify/5, verify_local/4,
         verify_current/3, verify_local_current/3,
         current/3, local_current/3,
         required_references/1, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([cache_namespace/1, valid_projection/2]).
-endif.

-define(KEY, {foreign_log, node}).
-define(DEFAULT_PAGE_TIMEOUT_MS, 8000).
-define(MANIFEST, "identity.term").
-define(CHECKPOINT, "checkpoint.term").
-define(LOG, "log.0001").
-define(CACHE_VERSION, 2).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).
-define(MAX_TIMER_MS, 16#FFFFFFFF).
-define(MANIFEST_RESERVE_BYTES, 4096).
-define(MAX_CURRENT_ROUTE_HINTS, (2 * ?MAX_VALIDATORS)).

-record(history, {
          identity :: {binary(), <<_:256>>},
          cache_ns :: binary(),
          height = 0 :: non_neg_integer(),
          bytes = 0 :: non_neg_integer(),
          projection = undefined :: undefined | map(),
          last_used = 0 :: integer(),
          active = none :: none | reference()
         }).

-record(request, {
          from :: gen_server:from(),
          peer :: term(),
          identity :: {binary(), <<_:256>>},
          worker :: pid(),
          mref :: reference(),
          timer :: reference(),
          timed_out = false :: boolean()
         }).

-record(pull, {
          from :: gen_server:from(),
          request_ref :: reference(),
          peer :: <<_:256>>,
          timer :: reference()
         }).

-record(s, {
          root :: file:filename_all(),
          fetch_fun = undefined :: undefined | function(),
          page_timeout_ms = ?DEFAULT_PAGE_TIMEOUT_MS :: pos_integer(),
          pending = #{} :: #{reference() => #request{}},
          peer_counts = #{} :: #{binary() => pos_integer()},
          pulls = #{} :: #{reference() => #pull{}},
          histories = #{} :: #{{binary(), binary()} => #history{}},
          total_bytes = 0 :: non_neg_integer(),
          channels = #{} :: #{binary() => {binary(), pos_integer()}}
         }).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(application:get_env(quod, foreign_log, #{})).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, Opts, []).

-doc """
Verify one exact foreign DTX reference and return its certified evidence.

`ExpectedPhase` is one of `'begin' | prepare | decision | finalize | complete`.
Any unavailable route/history, timeout, owner restart, or peer failure returns
`{error, retry}`.  It is never converted to valid or definitive absence.
""".
-spec verify(<<_:256>>, term(), quod_dtx:certified_ref(),
             'begin' | prepare | decision | finalize | complete,
             pos_integer()) ->
          {ok, map()} | {error, term()}.
verify(PeerKey, Endpoint, Ref, ExpectedPhase, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(
                  Pid, {verify, PeerKey, Endpoint, Ref, ExpectedPhase,
                        TimeoutMs}, TimeoutMs + 1000)
            catch exit:_ -> {error, retry}
            end;
        undefined ->
            {error, retry}
    end;
verify(_PeerKey, _Endpoint, _Ref, _ExpectedPhase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Verify one exact reference against a co-hosted namespace's durable ledger.

The same bounded cache and forward verifier as `verify/5` are used, but pages
come from `LedgerRoot` instead of the network and no route-peer membership
claim is needed.  Returned generation, committee, committee id, and validator
routes are those immediately after the referenced slot, never current state.
""".
-spec verify_local(file:filename_all(), quod_dtx:certified_ref(),
                   'begin' | prepare | decision | finalize | complete,
                   pos_integer()) ->
          {ok, map()} | {error, term()}.
verify_local(LedgerRoot, Ref, ExpectedPhase, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(
                  Pid,
                  {verify_local, LedgerRoot, Ref, ExpectedPhase, TimeoutMs},
                  TimeoutMs + 1000)
            catch exit:_ -> {error, retry}
            end;
        undefined ->
            {error, retry}
    end;
verify_local(_LedgerRoot, _Ref, _ExpectedPhase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Return one quorum-corroborated certified view at or after `FinalizeRef`.

`Routes` are identity-pinned fetch hints, never committee evidence.  The
worker verifies the exact Finalize, takes one bounded snapshot of the available
next page, folds only the longest certificate-valid prefix observed in that
snapshot, then requires a full quorum of distinct keys in the resulting
committee to report a durable height at least as high.  Content appended after
the snapshot is deliberately not chased; an applied-status committee-id
mismatch makes the caller take another snapshot.
""".
-spec verify_current([{<<_:256>>, term()}], quod_dtx:certified_ref(),
                     pos_integer()) ->
          {ok, map()} | {error, term()}.
verify_current(Routes0, Ref, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case normalize_route_hints(Routes0) of
        {ok, [_ | _] = Routes} ->
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(
                          Pid, {verify_current, Routes, Ref, TimeoutMs},
                          TimeoutMs + 1000)
                    catch exit:_ -> {error, retry}
                    end;
                undefined ->
                    {error, retry}
            end;
        error ->
            {error, bad_foreign_reference}
    end;
verify_current(_Routes, _Ref, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Return the certified projection at a co-hosted ledger's captured durable head.

The exact Finalize and every entry through that head are folded through the
same verifier/cache as foreign history.  No network route or remote height is
consulted.
""".
-spec verify_local_current(file:filename_all(), quod_dtx:certified_ref(),
                           pos_integer()) ->
          {ok, map()} | {error, term()}.
verify_local_current(LedgerRoot, Ref, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(
                  Pid, {verify_local_current, LedgerRoot, Ref, TimeoutMs},
                  TimeoutMs + 1000)
            catch exit:_ -> {error, retry}
            end;
        undefined ->
            {error, retry}
    end;
verify_local_current(_LedgerRoot, _Ref, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Return one certificate-verified current committee view for an anchored identity.

Unlike `verify_current/3`, this form has no phase reference to establish first.
It starts from the pinned genesis anchor, advances the shared bounded history
cache through certified entries, then requires a full quorum of the resulting
committee to corroborate the captured durable height.  Supplied routes remain
identity-pinned fetch hints only.
""".
-spec current([{<<_:256>>, term()}], {binary(), <<_:256>>}, pos_integer()) ->
          {ok, map()} | {error, term()}.
current(Routes0, Identity, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case {normalize_route_hints(Routes0), valid_identity(Identity)} of
        {{ok, [_ | _] = Routes}, true} ->
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(
                          Pid, {current, Routes, Identity, TimeoutMs},
                          TimeoutMs + 1000)
                    catch exit:_ -> {error, retry}
                    end;
                undefined ->
                    {error, retry}
            end;
        _ ->
            {error, bad_foreign_reference}
    end;
current(_Routes, _Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Return the certified current view at a co-hosted anchored ledger's captured
durable head.  It uses the same shared cache and history fold as `current/3`,
without requiring a DTX phase reference.
""".
-spec local_current(file:filename_all(), {binary(), <<_:256>>},
                    pos_integer()) ->
          {ok, map()} | {error, term()}.
local_current(LedgerRoot, Identity, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case valid_identity(Identity) of
        true ->
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(
                          Pid,
                          {local_current, LedgerRoot, Identity, TimeoutMs},
                          TimeoutMs + 1000)
                    catch exit:_ -> {error, retry}
                    end;
                undefined ->
                    {error, retry}
            end;
        false ->
            {error, bad_foreign_reference}
    end;
local_current(_LedgerRoot, _Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Return every foreign reference carried by one already-decoded DTX control.

This is the exhaustive pure seam used before a validator calls
`quod_dtx:preview/6`/`reduce/4`; a future control kind cannot silently inherit
an empty foreign-check set.  Row order is the control's canonical target order.
""".
-spec required_references(quod_dtx:control()) ->
          {ok, [{'begin' | prepare | decision | finalize,
                 quod_dtx:certified_ref()}]} |
          {error, invalid_control}.
required_references(Control) ->
    try required_references(
          quod_dtx:control_kind(Control), quod_dtx:control_body(Control))
    catch
        error:function_clause -> {error, invalid_control};
        error:{badmatch, _} -> {error, invalid_control}
    end.

required_references('begin', _Begin) ->
    {ok, []};
required_references(
  prepare,
  {quod_dtx_prepare, 2, _GroupId, BeginRef, _Manifest,
   _PlanDigest, _PlanBlob}) ->
    checked_references([{'begin', BeginRef}]);
required_references(
  decision,
  {quod_dtx_decision, 2, _GroupId, BeginRef, _Verdict, Rows, _Reasons}) ->
    case reference_rows(Rows, prepare, 0, []) of
        {ok, References} ->
            checked_references([{'begin', BeginRef} | References]);
        error ->
            {error, invalid_control}
    end;
required_references(
  finalize,
  {quod_dtx_finalize, 2, _GroupId, DecisionRef, _Verdict,
   PrepareRef, _Generation}) ->
    Tail = case PrepareRef of none -> []; _ -> [{prepare, PrepareRef}] end,
    checked_references([{decision, DecisionRef} | Tail]);
required_references(
  complete,
  {quod_dtx_complete, 2, _GroupId, DecisionRef, Rows}) ->
    case finalize_rows(Rows, 0, []) of
        {ok, References} ->
            checked_references([{decision, DecisionRef} | References]);
        error ->
            {error, invalid_control}
    end;
required_references(_Kind, _Record) ->
    {error, invalid_control}.

reference_rows([], _Phase, _Count, Acc) -> {ok, lists:reverse(Acc)};
reference_rows([{Identity, Ref} | Rest], Phase, Count, Acc)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS ->
    case ref_identity(Ref) of
        Identity ->
            reference_rows(Rest, Phase, Count + 1, [{Phase, Ref} | Acc]);
        _ -> error
    end;
reference_rows(_, _Phase, _Count, _Acc) -> error.

finalize_rows([], _Count, Acc) -> {ok, lists:reverse(Acc)};
finalize_rows([{Identity, Ref, Generation} | Rest], Count, Acc)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    case ref_identity(Ref) of
        Identity ->
            finalize_rows(Rest, Count + 1, [{finalize, Ref} | Acc]);
        _ -> error
    end;
finalize_rows(_, _Count, _Acc) -> error.

checked_references(References) ->
    case lists:all(
           fun({_Phase, Ref}) -> quod_dtx:validate_certified_ref(Ref) end,
           References) of
        true -> {ok, References};
        false -> {error, invalid_control}
    end.

-spec stats() -> map().
stats() ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(Pid, stats)
            catch exit:_ -> empty_stats()
            end;
        undefined -> empty_stats()
    end.

empty_stats() ->
    #{pending => 0, pulls => 0, histories => 0, cache_bytes => 0,
      peers => 0}.

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    Root = maps:get(
             cache_dir, Opts,
             filename:join(
               quod_ledger_store:default_data_dir(), "foreign-log")),
    FetchFun = maps:get(fetch_fun, Opts, undefined),
    PageTimeout = maps:get(page_timeout_ms, Opts, ?DEFAULT_PAGE_TIMEOUT_MS),
    case valid_options(Root, FetchFun, PageTimeout) of
        true ->
            ok = filelib:ensure_path(filename:join(Root, "cache")),
            {Histories, Total} = load_histories(Root),
            S0 = #s{root = Root, fetch_fun = FetchFun,
                    page_timeout_ms = PageTimeout,
                    histories = Histories, total_bytes = Total},
            {ok, subscribe_histories(S0)};
        false ->
            {stop, bad_foreign_log_config}
    end.

valid_options(Root, FetchFun, PageTimeout) ->
    (is_list(Root) orelse is_binary(Root)) andalso
        (FetchFun =:= undefined orelse is_function(FetchFun, 5)) andalso
        is_integer(PageTimeout) andalso PageTimeout > 0 andalso
        PageTimeout =< ?MAX_TIMER_MS - 1000.

handle_call(stats, _From, S) ->
    Reply = #{pending => map_size(S#s.pending),
              pulls => map_size(S#s.pulls),
              histories => map_size(S#s.histories),
              cache_bytes => S#s.total_bytes,
              peers => map_size(S#s.peer_counts)},
    {reply, Reply, S};
handle_call(
  {verify, Peer, Endpoint, Ref, Phase, TimeoutMs}, From, S0) ->
    case validate_request(Peer, Endpoint, Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            begin_verification(
              Peer, Endpoint, Ref, Phase, TimeoutMs,
              S0#s.fetch_fun, Identity, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {verify_local, LedgerRoot, Ref, Phase, TimeoutMs}, From, S0) ->
    case validate_local_request(LedgerRoot, Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            LocalPeer = {local, Identity},
            FetchFun =
                fun(_Peer, _Endpoint, Ns, FromIndex, ToIndex) ->
                    quod_catchup:serve_blocks(
                      Ns, LedgerRoot, FromIndex, ToIndex)
                end,
            begin_verification(
              LocalPeer, local, Ref, Phase, TimeoutMs,
              FetchFun, Identity, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {verify_current, Routes, Ref, TimeoutMs}, From, S0) ->
    case validate_current_request(Routes, Ref, TimeoutMs) of
        {ok, Identity} ->
            [{ChargePeer, _} | _] = Routes,
            begin_worker(
              ChargePeer, Identity, TimeoutMs,
              {current, Routes, Ref}, S0#s.fetch_fun, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {verify_local_current, LedgerRoot, Ref, TimeoutMs}, From, S0) ->
    case validate_local_current_request(
           LedgerRoot, Ref, TimeoutMs) of
        {ok, Identity} ->
            LocalPeer = {local, Identity},
            FetchFun =
                fun(_Peer, _Endpoint, Ns, FromIndex, ToIndex) ->
                    quod_catchup:serve_blocks(
                      Ns, LedgerRoot, FromIndex, ToIndex)
                end,
            begin_worker(
              LocalPeer, Identity, TimeoutMs,
              {local_current, LedgerRoot, Ref}, FetchFun, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {current, Routes, Identity, TimeoutMs}, From, S0) ->
    case validate_current_identity_request(
           Routes, Identity, TimeoutMs) of
        ok ->
            [{ChargePeer, _} | _] = Routes,
            begin_worker(
              ChargePeer, Identity, TimeoutMs,
              {current_identity, Routes, Identity},
              S0#s.fetch_fun, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {local_current, LedgerRoot, Identity, TimeoutMs}, From, S0) ->
    case validate_local_current_identity_request(
           LedgerRoot, Identity, TimeoutMs) of
        ok ->
            LocalPeer = {local, Identity},
            {Ns, _Anchor} = Identity,
            FetchFun =
                fun(_Peer, _Endpoint, RequestedNs, FromIndex, ToIndex) ->
                    case RequestedNs =:= Ns of
                        true -> quod_catchup:serve_blocks(
                                  Ns, LedgerRoot, FromIndex, ToIndex);
                        false -> {error, wrong_namespace}
                    end
                end,
            begin_worker(
              LocalPeer, Identity, TimeoutMs,
              {local_current_identity, LedgerRoot, Identity},
              FetchFun, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {pull_page, RequestRef, Peer, Endpoint, Ns, FromIndex, ToIndex}, From,
  S = #s{fetch_fun = undefined}) ->
    case maps:get(RequestRef, S#s.pending, undefined) of
        #request{identity = {Ns, _Anchor}} ->
            ReqId = make_ref(),
            Timer = erlang:send_after(
                      S#s.page_timeout_ms, self(), {pull_timeout, ReqId}),
            Chan = quod_catchup:channel(Ns),
            Frame = quod_catchup:encode_frame(
                      Ns, {blocks_req, ReqId, FromIndex, ToIndex}),
            ok = quod_quic:send_pinned(Peer, Endpoint, Chan, Frame),
            Pull = #pull{from = From, request_ref = RequestRef,
                         peer = Peer, timer = Timer},
            {noreply, S#s{pulls = (S#s.pulls)#{ReqId => Pull}}};
        _ ->
            {reply, {error, retry}, S}
    end;
handle_call({reserve_page, RequestRef, Bytes}, _From, S0)
  when is_integer(Bytes), Bytes >= 0 ->
    case reserve_page(RequestRef, Bytes, S0) of
        {ok, S1} -> {reply, ok, S1};
        {error, S1} -> {reply, {error, cache_full}, S1}
    end;
handle_call({set_cache_size, RequestRef, Bytes}, _From, S0)
  when is_integer(Bytes), Bytes >= 0 ->
    case set_cache_size(RequestRef, Bytes, S0) of
        {ok, S1} -> {reply, ok, S1};
        {error, S1} -> {reply, {error, cache_full}, S1}
    end;
handle_call({reset_cache, RequestRef}, _From, S0) ->
    case reset_cache_accounting(RequestRef, S0) of
        {ok, S1} -> {reply, ok, S1};
        error -> {reply, {error, retry}, S0}
    end;
handle_call(_Request, _From, S) ->
    {reply, {error, bad_request}, S}.

begin_verification(Peer, Endpoint, Ref, Phase, TimeoutMs, FetchFun,
                   Identity, From, S0) ->
    begin_worker(
      Peer, Identity, TimeoutMs,
      {exact, Peer, Endpoint, Ref, Phase}, FetchFun, From, S0).

begin_worker(Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) ->
    case admit_request(Peer, Identity, S0) of
        {ok, RequestRef, S1} ->
            Owner = self(),
            Root = S1#s.root,
            PageTimeout = S1#s.page_timeout_ms,
            Worker = spawn_opt(
                       fun() ->
                           verification_worker(
                             Owner, RequestRef, Work,
                             Root, FetchFun, PageTimeout)
                       end,
                       [{max_heap_size,
                         #{size => foreign_worker_heap_words(),
                           kill => true, error_logger => true}}]),
            MRef = erlang:monitor(process, Worker),
            Timer = erlang:send_after(
                      TimeoutMs, self(),
                      {verification_timeout, RequestRef}),
            Request = #request{from = From, peer = Peer,
                               identity = Identity, worker = Worker,
                               mref = MRef, timer = Timer},
            Pending1 = (S1#s.pending)#{RequestRef => Request},
            {noreply, S1#s{pending = Pending1}};
        {error, Reason, S1} ->
            {reply, {error, Reason}, S1}
    end.

handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(
  {quod_message, {PeerIdentity, _Link}, Chan, Payload}, S) ->
    case quod_link:peer_key(PeerIdentity) of
        undefined -> {noreply, S};
        Peer -> {noreply, handle_catchup_frame(Peer, Chan, Payload, S)}
    end;
handle_info({foreign_worker_done, RequestRef, Result, Meta}, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{timed_out = false} ->
            S1 = install_worker_meta(RequestRef, Meta, S0),
            {noreply, finish_request(RequestRef, Result, S1)};
        #request{timed_out = true} ->
            {noreply, finish_request(RequestRef, {error, retry}, S0)};
        undefined ->
            {noreply, S0}
    end;
handle_info({verification_timeout, RequestRef}, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{worker = Worker} = Request ->
            exit(Worker, kill),
            %% Keep this identity active until the monitor confirms that the
            %% cache worker is dead.  Releasing it here could admit a second
            %% writer against the same ledger/checkpoint between `exit/2` and
            %% the eventual DOWN message.
            Pending1 = (S0#s.pending)#{
                         RequestRef => Request#request{timed_out = true}},
            {noreply, S0#s{pending = Pending1}};
        undefined ->
            {noreply, S0}
    end;
handle_info({pull_timeout, ReqId}, S0) ->
    case maps:take(ReqId, S0#s.pulls) of
        {#pull{from = From}, Pulls1} ->
            gen_server:reply(From, {error, retry}),
            {noreply, S0#s{pulls = Pulls1}};
        error ->
            {noreply, S0}
    end;
handle_info({'DOWN', MRef, process, _Pid, _Reason}, S0) ->
    case request_by_monitor(MRef, S0#s.pending) of
        {ok, RequestRef} ->
            {noreply, finish_request(RequestRef, {error, retry}, S0)};
        error ->
            {noreply, S0}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #s{channels = Channels}) ->
    _ = [catch quod_reg:unsubscribe({channel, Chan})
         || Chan <- maps:keys(Channels)],
    ok.

%%%===================================================================
%%% Admission and owner accounting
%%%===================================================================

validate_request(
  <<_:256>>, Endpoint,
  {quod_dtx_ref, 2, Ns, <<_:256>> = Anchor, Slot,
   <<_:256>>, <<_:256>>, Proof} = Ref,
  Phase, TimeoutMs)
  when is_binary(Ns), byte_size(Ns) > 0,
       byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
       is_integer(Slot), Slot > 0,
       is_binary(Proof), byte_size(Proof) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_quic:valid_endpoint(Endpoint) andalso valid_phase(Phase)
         andalso quod_dtx:validate_certified_ref(Ref) of
        true -> {ok, {Ns, Anchor}};
        false -> {error, bad_foreign_reference}
    end;
validate_request(_Peer, _Endpoint, _Ref, _Phase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_local_request(
  LedgerRoot,
  {quod_dtx_ref, 2, Ns, <<_:256>> = Anchor, Slot,
   <<_:256>>, <<_:256>>, Proof} = Ref,
  Phase, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_binary(Ns), byte_size(Ns) > 0,
       byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
       is_integer(Slot), Slot > 0,
       is_binary(Proof), byte_size(Proof) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case valid_phase(Phase) andalso quod_dtx:validate_certified_ref(Ref) of
        true -> {ok, {Ns, Anchor}};
        false -> {error, bad_foreign_reference}
    end;
validate_local_request(_LedgerRoot, _Ref, _Phase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_current_request([_ | _] = Routes, Ref, TimeoutMs) ->
    case normalize_route_hints(Routes) of
        {ok, Routes} ->
            validate_current_ref(Ref, TimeoutMs);
        _ ->
            {error, bad_foreign_reference}
    end;
validate_current_request(_Routes, _Ref, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_local_current_request(LedgerRoot, Ref, TimeoutMs) ->
    case validate_local_request(
           LedgerRoot, Ref, finalize, TimeoutMs) of
        {ok, Identity} -> {ok, Identity};
        {error, _} = Error -> Error
    end.

validate_current_identity_request([_ | _] = Routes, Identity, TimeoutMs) ->
    case normalize_route_hints(Routes) of
        {ok, Routes} ->
            validate_current_identity(Identity, TimeoutMs);
        _ ->
            {error, bad_foreign_reference}
    end;
validate_current_identity_request(_Routes, _Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_local_current_identity_request(
  LedgerRoot, Identity, TimeoutMs)
  when is_list(LedgerRoot); is_binary(LedgerRoot) ->
    validate_current_identity(Identity, TimeoutMs);
validate_local_current_identity_request(
  _LedgerRoot, _Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_current_identity(Identity, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case valid_identity(Identity) of
        true -> ok;
        false -> {error, bad_foreign_reference}
    end;
validate_current_identity(_Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

valid_identity({Ns, <<_:256>>})
  when is_binary(Ns), byte_size(Ns) > 0,
       byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES ->
    true;
valid_identity(_) ->
    false.

validate_current_ref(Ref, TimeoutMs) ->
    case Ref of
        {quod_dtx_ref, 2, Ns, <<_:256>> = Anchor, Slot,
         <<_:256>>, <<_:256>>, Proof}
          when is_binary(Ns), byte_size(Ns) > 0,
               byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
               is_integer(Slot), Slot > 0,
               is_binary(Proof), byte_size(Proof) > 0,
               is_integer(TimeoutMs), TimeoutMs > 0,
               TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
            case quod_dtx:validate_certified_ref(Ref) of
                true -> {ok, {Ns, Anchor}};
                false -> {error, bad_foreign_reference}
            end;
        _ ->
            {error, bad_foreign_reference}
    end.

normalize_route_hints(Routes) when is_list(Routes) ->
    normalize_route_hints(Routes, 0, []);
normalize_route_hints(_) ->
    error.

normalize_route_hints([], _Count, Acc) ->
    {ok, lists:usort(Acc)};
normalize_route_hints(
  [{<<_:256>> = Peer, Endpoint} | Rest], Count, Acc)
  when Count < ?MAX_VALIDATORS ->
    case quod_quic:valid_endpoint(Endpoint) of
        true -> normalize_route_hints(Rest, Count + 1,
                                      [{Peer, Endpoint} | Acc]);
        false -> error
    end;
normalize_route_hints(_, _Count, _Acc) ->
    error.

valid_phase('begin') -> true;
valid_phase(prepare) -> true;
valid_phase(decision) -> true;
valid_phase(finalize) -> true;
valid_phase(complete) -> true;
valid_phase(_) -> false.

admit_request(Peer, Identity, S0) ->
    PeerCount = maps:get(Peer, S0#s.peer_counts, 0),
    case map_size(S0#s.pending) < ?QUOD_MAX_FOREIGN_PENDING andalso
         PeerCount < ?QUOD_MAX_FOREIGN_PENDING_PER_PEER of
        false ->
            {error, busy, S0};
        true ->
            case ensure_history(Identity, S0) of
                {ok, S1} ->
                    History = maps:get(Identity, S1#s.histories),
                    case History#history.active of
                        none ->
                            Ref = make_ref(),
                            H1 = History#history{active = Ref,
                                                 last_used = quod_time:mono_ms()},
                            Counts1 = (S1#s.peer_counts)#{Peer => PeerCount + 1},
                            {ok, Ref,
                             S1#s{histories =
                                      (S1#s.histories)#{Identity => H1},
                                   peer_counts = Counts1}};
                        _ ->
                            {error, history_busy, S1}
                    end;
                {error, S1} ->
                    {error, cache_full, S1}
            end
    end.

ensure_history(Identity, S = #s{histories = Histories})
  when is_map_key(Identity, Histories) ->
    {ok, S};
ensure_history(Identity = {Ns, _Anchor}, S0) ->
    case make_history_room(S0) of
        {ok, S1} ->
            CacheNs = cache_namespace(Identity),
            H = #history{identity = Identity, cache_ns = CacheNs,
                         last_used = quod_time:mono_ms()},
            S2 = add_channel(Ns, S1),
            {ok, S2#s{histories = (S2#s.histories)#{Identity => H}}};
        {error, S1} ->
            {error, S1}
    end.

make_history_room(S) when map_size(S#s.histories) < ?QUOD_MAX_FOREIGN_HISTORIES ->
    {ok, S};
make_history_room(S) ->
    evict_one(S, none).

reserve_page(RequestRef, Bytes, S0) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            case make_byte_room(Bytes, Identity, S0) of
                {ok, S1} ->
                    H0 = maps:get(Identity, S1#s.histories),
                    H1 = H0#history{bytes = H0#history.bytes + Bytes},
                    {ok, S1#s{histories =
                                  (S1#s.histories)#{Identity => H1},
                               total_bytes = S1#s.total_bytes + Bytes}};
                {error, S1} -> {error, S1}
            end;
        error -> {error, S0}
    end.

set_cache_size(RequestRef, Bytes, S0) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            H0 = maps:get(Identity, S0#s.histories),
            case Bytes =< H0#history.bytes of
                true ->
                    H1 = H0#history{bytes = Bytes},
                    {ok, S0#s{histories =
                                  (S0#s.histories)#{Identity => H1},
                               total_bytes =
                                   S0#s.total_bytes -
                                       (H0#history.bytes - Bytes)}};
                false ->
                    Delta = Bytes - H0#history.bytes,
                    case make_byte_room(Delta, Identity, S0) of
                        {ok, S1} ->
                            H1 = H0#history{bytes = Bytes},
                            {ok, S1#s{histories =
                                         (S1#s.histories)#{Identity => H1},
                                      total_bytes = S1#s.total_bytes + Delta}};
                        {error, S1} -> {error, S1}
                    end
            end;
        error -> {error, S0}
    end.

make_byte_room(Bytes, _Identity, S)
  when Bytes > ?QUOD_MAX_FOREIGN_CACHE_BYTES ->
    {error, S};
make_byte_room(Bytes, _Identity, S)
  when S#s.total_bytes + Bytes =< ?QUOD_MAX_FOREIGN_CACHE_BYTES ->
    {ok, S};
make_byte_room(Bytes, Identity, S0) ->
    case evict_one(S0, Identity) of
        {ok, S1} -> make_byte_room(Bytes, Identity, S1);
        {error, S1} -> {error, S1}
    end.

evict_one(S = #s{histories = Histories}, ExceptIdentity) ->
    Candidates =
        [H || {Identity, H = #history{active = none}} <- maps:to_list(Histories),
              Identity =/= ExceptIdentity],
    case Candidates of
        [] -> {error, S};
        _ ->
            [First | Tail] = Candidates,
            Victim = lists:foldl(
                       fun(H = #history{last_used = Used},
                           Best = #history{last_used = BestUsed}) ->
                               case Used < BestUsed of
                                   true -> H;
                                   false -> Best
                               end
                       end, First, Tail),
            evict_history(Victim#history.identity, S)
    end.

evict_history(Identity = {Ns, _}, S0) ->
    H = maps:get(Identity, S0#s.histories),
    _ = file:del_dir_r(cache_dir(S0#s.root, H#history.cache_ns)),
    Histories1 = maps:remove(Identity, S0#s.histories),
    S1 = S0#s{histories = Histories1,
              total_bytes = max(0, S0#s.total_bytes - H#history.bytes)},
    {ok, remove_channel(Ns, S1)}.

reset_cache_accounting(RequestRef, S0) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            H0 = maps:get(Identity, S0#s.histories),
            H1 = H0#history{height = 0, bytes = 0,
                            projection = undefined},
            {ok, S0#s{histories = (S0#s.histories)#{Identity => H1},
                      total_bytes = max(
                                      0, S0#s.total_bytes - H0#history.bytes)}};
        error -> error
    end.

request_identity(RequestRef, #s{pending = Pending}) ->
    case maps:get(RequestRef, Pending, undefined) of
        #request{identity = Identity} -> {ok, Identity};
        undefined -> error
    end.

request_by_monitor(MRef, Pending) ->
    case [Ref || {Ref, #request{mref = RefM}} <- maps:to_list(Pending),
                 RefM =:= MRef] of
        [Ref] -> {ok, Ref};
        [] -> error
    end.

finish_request(RequestRef, Reply, S0) ->
    case maps:take(RequestRef, S0#s.pending) of
        {#request{from = From, peer = Peer, identity = Identity,
                  mref = MRef, timer = Timer}, Pending1} ->
            _ = erlang:cancel_timer(Timer),
            _ = erlang:demonitor(MRef, [flush]),
            gen_server:reply(From, Reply),
            Count = maps:get(Peer, S0#s.peer_counts, 1),
            Counts1 = case Count of
                          1 -> maps:remove(Peer, S0#s.peer_counts);
                          _ -> (S0#s.peer_counts)#{Peer => Count - 1}
                      end,
            Histories1 =
                case maps:get(Identity, S0#s.histories, undefined) of
                    #history{} = H ->
                        (S0#s.histories)#{Identity =>
                                             H#history{active = none,
                                                       last_used =
                                                           quod_time:mono_ms()}};
                    undefined -> S0#s.histories
                end,
            S1 = S0#s{pending = Pending1, peer_counts = Counts1,
                      histories = Histories1},
            cancel_request_pulls(RequestRef, S1);
        error ->
            S0
    end.

cancel_request_pulls(RequestRef, S0) ->
    {Keep, Drop} = maps:fold(
                     fun(ReqId, Pull = #pull{request_ref = Ref}, {K, D}) ->
                             case Ref =:= RequestRef of
                                 true -> {K, [{ReqId, Pull} | D]};
                                 false -> {K#{ReqId => Pull}, D}
                             end
                     end, {#{}, []}, S0#s.pulls),
    _ = [begin
             _ = erlang:cancel_timer(Pull#pull.timer),
             gen_server:reply(Pull#pull.from, {error, retry})
         end || {_ReqId, Pull} <- Drop],
    S0#s{pulls = Keep}.

install_worker_meta(RequestRef, Meta, S0) when is_map(Meta) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            case maps:get(Identity, S0#s.histories, undefined) of
                #history{} = H0 ->
                    ActualBytes = maps:get(bytes, Meta, H0#history.bytes),
                    H1 = H0#history{height = maps:get(height, Meta, H0#history.height),
                                    bytes = ActualBytes,
                                    projection = maps:get(
                                                   projection, Meta,
                                                   H0#history.projection)},
                    Total1 = max(
                               0, S0#s.total_bytes - H0#history.bytes +
                                      ActualBytes),
                    S0#s{histories = (S0#s.histories)#{Identity => H1},
                         total_bytes = Total1};
                undefined -> S0
            end;
        error -> S0
    end;
install_worker_meta(_RequestRef, _Meta, S) -> S.

foreign_worker_heap_words() ->
    max(1, ?QUOD_SCOPE_WORKER_MAX_HEAP_BYTES div erlang:system_info(wordsize)).

%%%===================================================================
%%% Catch-up transport
%%%===================================================================

handle_catchup_frame(Peer, Chan, Payload, S0) ->
    case maps:get(Chan, S0#s.channels, undefined) of
        {Ns, _Count} ->
            case quod_catchup:decode_frame(Ns, Payload) of
                {ok, {blocks_resp, ReqId, Entries, Height}, InnerBytes}
                  when InnerBytes =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
                    reply_pull(Peer, ReqId, {ok, Entries, Height}, S0);
                {ok, {blocks_err, ReqId}, _InnerBytes} ->
                    reply_pull(Peer, ReqId, {error, retry}, S0);
                _ -> S0
            end;
        undefined -> S0
    end.

reply_pull(Peer, ReqId, Reply, S0) ->
    case maps:get(ReqId, S0#s.pulls, undefined) of
        #pull{peer = Peer, from = From, timer = Timer} ->
            _ = erlang:cancel_timer(Timer),
            gen_server:reply(From, Reply),
            S0#s{pulls = maps:remove(ReqId, S0#s.pulls)};
        _ ->
            S0
    end.

add_channel(Ns, S0) ->
    Chan = quod_catchup:channel(Ns),
    case maps:get(Chan, S0#s.channels, undefined) of
        undefined ->
            true = quod_reg:subscribe({channel, Chan}),
            S0#s{channels = (S0#s.channels)#{Chan => {Ns, 1}}};
        {Ns, Count} ->
            S0#s{channels = (S0#s.channels)#{Chan => {Ns, Count + 1}}}
    end.

remove_channel(Ns, S0) ->
    Chan = quod_catchup:channel(Ns),
    case maps:get(Chan, S0#s.channels, undefined) of
        {Ns, 1} ->
            _ = catch quod_reg:unsubscribe({channel, Chan}),
            S0#s{channels = maps:remove(Chan, S0#s.channels)};
        {Ns, Count} when Count > 1 ->
            S0#s{channels = (S0#s.channels)#{Chan => {Ns, Count - 1}}};
        _ -> S0
    end.

subscribe_histories(S0) ->
    lists:foldl(
      fun({Ns, _Anchor}, Acc) -> add_channel(Ns, Acc) end,
      S0, maps:keys(S0#s.histories)).

%%%===================================================================
%%% Verification worker
%%%===================================================================

verification_worker(Owner, RequestRef, Work, Root, FetchFun, PageTimeout) ->
    %% Probe children are linked so killing a timed-out verification also
    %% kills every in-flight route fetch. Expected transport exits are
    %% normalized where the dependency is called; an internal fault takes
    %% down this monitored worker and remains visible to the runtime.
    Result0 = verification_work(
                Work, Owner, RequestRef, Root, FetchFun, PageTimeout),
    {Result, Meta} = normalize_worker_result(Result0),
    Owner ! {foreign_worker_done, RequestRef, Result, Meta}.

verification_work(
  {exact, Peer, Endpoint, Ref, Phase}, Owner, RequestRef,
  Root, FetchFun, PageTimeout) ->
    verify_cached(
      Owner, RequestRef, Peer, Endpoint, Ref, Phase, ref_identity(Ref),
      Root, FetchFun, PageTimeout, true, false);
verification_work(
  {current, Routes, Ref}, Owner, RequestRef,
  Root, FetchFun, PageTimeout) ->
    verify_current_cached(
      Owner, RequestRef, Routes, Ref, Root, FetchFun, PageTimeout);
verification_work(
  {local_current, LedgerRoot, Ref}, Owner, RequestRef,
  Root, FetchFun, PageTimeout) ->
    verify_local_current_cached(
      Owner, RequestRef, LedgerRoot, Ref, Root, FetchFun, PageTimeout);
verification_work(
  {current_identity, Routes, Identity}, Owner, RequestRef,
  Root, FetchFun, PageTimeout) ->
    certified_current_snapshot(
      Owner, RequestRef, Routes, Identity,
      Root, FetchFun, PageTimeout);
verification_work(
  {local_current_identity, LedgerRoot, Identity}, Owner, RequestRef,
  Root, FetchFun, PageTimeout) ->
    verify_local_current_identity_cached(
      Owner, RequestRef, LedgerRoot, Identity,
      Root, FetchFun, PageTimeout).

normalize_worker_result({{ok, _} = Result, Meta}) when is_map(Meta) ->
    {Result, Meta};
normalize_worker_result({{error, _} = Result, Meta}) when is_map(Meta) ->
    {Result, Meta}.

verify_cached(Owner, RequestRef, Peer, Endpoint, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, RequirePeer, Retried) ->
    Slot = ref_slot(Ref),
    case open_cache(Owner, RequestRef, Identity, Root, Slot) of
        {ok, Store0, Height0, Projection0, PhaseIndex, SlotProjection0} ->
            Outcome = try
                          case fetch_to_height(
                                 Owner, RequestRef, Peer, Endpoint, Slot,
                                 Identity, Store0, Height0, Projection0,
                                 SlotProjection0, PhaseIndex, Root, FetchFun,
                                 PageTimeout) of
                              {ok, Store1, CacheHeight, CacheProjection,
                               EvidenceProjection} ->
                                  {verified,
                                   verify_reference_source(
                                     Peer,
                                     verify_exact_reference(
                                       Store1, Ref, Phase,
                                       EvidenceProjection),
                                     RequirePeer),
                                   CacheHeight, CacheProjection};
                              Other -> Other
                          end
            after
                _ = quod_dtx_phase_index:close(PhaseIndex),
                _ = quod_ledger_store:close(Store0)
            end,
            case Outcome of
                {verified, Result, VerifiedHeight, VerifiedProjection} ->
                    Bytes = cache_persisted_bytes(
                              Root, cache_namespace(Identity)),
                    {Result,
                     #{height => VerifiedHeight, bytes => Bytes,
                       projection => VerifiedProjection}};
                {error, cache_corrupt} ->
                    retry_corrupt_cache(
                      Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                      Identity, Root, FetchFun, PageTimeout,
                      RequirePeer, Retried);
                {error, _} ->
                    {{error, retry},
                     #{height => Height0,
                       bytes => cache_persisted_bytes(
                                  Root, cache_namespace(Identity)),
                       projection => Projection0}}
            end;
        {error, cache_corrupt} ->
            retry_corrupt_cache(
              Owner, RequestRef, Peer, Endpoint, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, RequirePeer, Retried);
        {error, _} ->
            {{error, retry}, #{}}
    end.

retry_corrupt_cache(_Owner, _RequestRef, _Peer, _Endpoint, _Ref, _Phase,
                    _Identity, _Root, _FetchFun, _PageTimeout,
                    _RequirePeer, true) ->
    {{error, retry}, #{}};
retry_corrupt_cache(Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                    Identity, Root, FetchFun, PageTimeout,
                    RequirePeer, false) ->
    case gen_server:call(Owner, {reset_cache, RequestRef}) of
        ok ->
            _ = file:del_dir_r(
                  cache_dir(Root, cache_namespace(Identity))),
            verify_cached(Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                          Identity, Root, FetchFun, PageTimeout,
                          RequirePeer, true);
        {error, _} ->
            {{error, retry}, #{}}
    end.

verify_current_cached(
  Owner, RequestRef, Routes, Ref, Root, FetchFun, PageTimeout) ->
    Identity = ref_identity(Ref),
    case verify_current_reference(
           Routes, Owner, RequestRef, Ref, Identity,
           Root, FetchFun, PageTimeout) of
        {{ok, _FinalizeEvidence}, _Meta} ->
            certified_current_snapshot(
              Owner, RequestRef, Routes, Identity,
              Root, FetchFun, PageTimeout);
        {{error, _} = Error, Meta} ->
            {Error, Meta}
    end.

verify_current_reference(
  [], _Owner, _RequestRef, _Ref, _Identity,
  _Root, _FetchFun, _PageTimeout) ->
    {{error, retry}, #{}};
verify_current_reference(
  [{Peer, Endpoint} | Rest], Owner, RequestRef, Ref, Identity,
  Root, FetchFun, PageTimeout) ->
    case verify_cached(
           Owner, RequestRef, Peer, Endpoint, Ref, finalize, Identity,
           Root, FetchFun, PageTimeout, false, false) of
        {{ok, _} = Ok, Meta} ->
            {Ok, Meta};
        {{error, retry}, _Meta} ->
            verify_current_reference(
              Rest, Owner, RequestRef, Ref, Identity,
              Root, FetchFun, PageTimeout);
        Definitive ->
            Definitive
    end.

certified_current_snapshot(
  Owner, RequestRef, Routes, Identity = {Ns, Anchor},
  Root, FetchFun, PageTimeout) ->
    case open_cache(Owner, RequestRef, Identity, Root, none) of
        {ok, Store0, Height0, Projection0, PhaseIndex, _RefProjection} ->
            Outcome =
                try
                    Hints = current_route_hints(Routes, Projection0),
                    Results = probe_pages(
                                Owner, RequestRef, Hints, Ns, Height0,
                                FetchFun, PageTimeout),
                    case advance_snapshot(
                           Owner, RequestRef, Identity, Store0, Height0,
                           Projection0, PhaseIndex, Root, Results,
                           FetchFun, PageTimeout) of
                        {ok, Height1, Projection1} ->
                            ConfirmHints = current_route_hints(
                                             Routes, Projection1),
                            case current_view_confirmed(
                                   Owner, RequestRef, ConfirmHints, Ns,
                                   Anchor, Identity, Height1, Projection1,
                                   PhaseIndex,
                                   FetchFun, PageTimeout) of
                                true ->
                                    {ok, current_view_evidence(
                                           Identity, Height1, Projection1),
                                     Height1, Projection1};
                                false ->
                                    {unconfirmed, Height1, Projection1}
                            end;
                        {error, _} = Error ->
                            Error
                    end
                after
                    _ = quod_dtx_phase_index:close(PhaseIndex),
                    _ = quod_ledger_store:close(Store0)
                end,
            current_snapshot_result(Outcome, Root, Identity,
                                    Height0, Projection0);
        {error, _} ->
            {{error, retry}, #{}}
    end.

current_snapshot_result(
  {ok, Evidence, Height, Projection}, Root, Identity,
  _OldHeight, _OldProjection) ->
    {{ok, Evidence},
     #{height => Height,
       bytes => cache_persisted_bytes(Root, cache_namespace(Identity)),
       projection => Projection}};
current_snapshot_result(
  {unconfirmed, Height, Projection}, Root, Identity,
  _OldHeight, _OldProjection) ->
    {{error, retry},
     #{height => Height,
       bytes => cache_persisted_bytes(Root, cache_namespace(Identity)),
       projection => Projection}};
current_snapshot_result(
  {error, _}, Root, Identity, Height, Projection) ->
    {{error, retry},
     #{height => Height,
       bytes => cache_persisted_bytes(Root, cache_namespace(Identity)),
       projection => Projection}}.

verify_local_current_cached(
  Owner, RequestRef, LedgerRoot, Ref, Root, FetchFun, PageTimeout) ->
    Identity = {Ns, _Anchor} = ref_identity(Ref),
    case quod_ledger_store:open_ro(Ns, LedgerRoot) of
        {ok, Source} ->
            Height = quod_ledger_store:last(Source),
            _ = quod_ledger_store:close(Source),
            case Height >= ref_slot(Ref) of
                true ->
                    verify_local_current_height(
                      Owner, RequestRef, {finalize, Ref}, Identity, Height,
                      Root, FetchFun, PageTimeout);
                false ->
                    {{error, retry}, #{}}
            end;
        _ ->
            {{error, retry}, #{}}
    end.

verify_local_current_identity_cached(
  Owner, RequestRef, LedgerRoot,
  Identity = {Ns, _Anchor}, Root, FetchFun, PageTimeout) ->
    case quod_ledger_store:open_ro(Ns, LedgerRoot) of
        {ok, Source} ->
            Height = quod_ledger_store:last(Source),
            _ = quod_ledger_store:close(Source),
            case Height > 0 of
                true ->
                    verify_local_current_height(
                      Owner, RequestRef, none, Identity, Height,
                      Root, FetchFun, PageTimeout);
                false ->
                    {{error, retry}, #{}}
            end;
        _ ->
            {{error, retry}, #{}}
    end.

verify_local_current_height(
  Owner, RequestRef, RequiredReference, Identity, Height,
  Root, FetchFun, PageTimeout) ->
    LocalPeer = {local, Identity},
    case open_cache(Owner, RequestRef, Identity, Root, Height) of
        {ok, Store0, Height0, Projection0, PhaseIndex, HeightProjection0} ->
            Outcome =
                try
                    case fetch_to_height(
                           Owner, RequestRef, LocalPeer, local,
                           Height, Identity,
                           Store0, Height0, Projection0, HeightProjection0,
                           PhaseIndex, Root, FetchFun, PageTimeout) of
                        {ok, Store1, CacheHeight, CacheProjection,
                         CurrentProjection}
                          when CacheHeight >= Height ->
                            case verify_current_basis(
                                   Store1, RequiredReference,
                                   CurrentProjection) of
                                ok ->
                                    {ok, current_view_evidence(
                                           Identity, Height,
                                           CurrentProjection),
                                     CacheHeight, CacheProjection};
                                {error, _} = Error -> Error
                            end;
                        {ok, _Store1, _CacheHeight, _Projection,
                         _CurrentProjection} ->
                            {error, retry};
                        {error, _} = Error -> Error
                    end
                after
                    _ = quod_dtx_phase_index:close(PhaseIndex),
                    _ = quod_ledger_store:close(Store0)
                end,
            current_snapshot_result(Outcome, Root, Identity,
                                    Height0, Projection0);
        {error, _} ->
            {{error, retry}, #{}}
    end.

verify_current_basis(_Store, none, _CurrentProjection) ->
    ok;
verify_current_basis(Store, {Phase, Ref}, CurrentProjection) ->
    case verify_exact_reference(Store, Ref, Phase, CurrentProjection) of
        {ok, _Evidence} -> ok;
        {error, _} = Error -> Error
    end.

open_cache(Owner, RequestRef, Identity = {Ns, Anchor}, Root, TargetSlot) ->
    CacheNs = cache_namespace(Identity),
    Dir = cache_dir(Root, CacheNs),
    ok = cleanup_cache_temps(Dir),
    _ = quod_dtx_phase_index:cleanup(Root, CacheNs),
    case ensure_manifest(Owner, RequestRef, Root, Identity, CacheNs) of
        ok ->
            try quod_ledger_store:open(CacheNs, Root) of
                {ok, Store} ->
                    Height = quod_ledger_store:last(Store),
                    case load_checkpoint(Root, Identity, CacheNs, Height) of
                        {ok, CheckpointProjection} ->
                            case quod_dtx_phase_index:open(Root, CacheNs) of
                                {ok, PhaseIndex} ->
                                    Projection0 = quod_simplex:history_projection(
                                                    {Ns, Anchor}),
                                    case replay_cache(
                                           Store, Ns, Anchor, Height,
                                           Projection0, PhaseIndex,
                                           TargetSlot) of
                                        {ok, Projection, TargetProjection}
                                          when Projection =:=
                                                   CheckpointProjection ->
                                            {ok, Store, Height, Projection,
                                             PhaseIndex, TargetProjection};
                                        {ok, _Different, _TargetProjection} ->
                                            _ = quod_dtx_phase_index:close(
                                                  PhaseIndex),
                                            _ = quod_ledger_store:close(Store),
                                            {error, cache_corrupt};
                                        {error, retry} ->
                                            _ = quod_dtx_phase_index:close(
                                                  PhaseIndex),
                                            _ = quod_ledger_store:close(Store),
                                            {error, retry};
                                        {error, _} ->
                                            _ = quod_dtx_phase_index:close(
                                                  PhaseIndex),
                                            _ = quod_ledger_store:close(Store),
                                            {error, cache_corrupt}
                                    end;
                                {error, _} ->
                                    _ = quod_ledger_store:close(Store),
                                    {error, cache_io}
                            end;
                        new when Height =:= 0 ->
                            case quod_dtx_phase_index:open(Root, CacheNs) of
                                {ok, PhaseIndex} ->
                                    Projection = quod_simplex:history_projection(
                                                   {Ns, Anchor}),
                                    {ok, Store, 0, Projection, PhaseIndex,
                                     undefined};
                                {error, _} ->
                                    _ = quod_ledger_store:close(Store),
                                    {error, cache_io}
                            end;
                        _ ->
                            _ = quod_ledger_store:close(Store),
                            {error, cache_corrupt}
                    end
            catch _:_ ->
                {error, cache_corrupt}
            end;
        {error, _} ->
            {error, cache_corrupt}
    end.

replay_cache(_Store, _Ns, _Anchor, 0, Projection, _PhaseIndex,
             _TargetSlot) ->
    {ok, Projection, undefined};
replay_cache(Store, Ns, Anchor, Height, Projection0, PhaseIndex,
             TargetSlot) ->
    replay_cache(Store, Ns, Anchor, 1, Height, Projection0, PhaseIndex,
                 TargetSlot, undefined).

replay_cache(_Store, Ns, Anchor, From, Height, Projection, _PhaseIndex,
             TargetSlot, TargetProjection)
  when From > Height ->
    TargetOk = case TargetSlot of
                   none -> true;
                   _ -> TargetSlot > Height orelse
                            valid_projection(
                              TargetProjection, {Ns, Anchor})
               end,
    case valid_projection(Projection, {Ns, Anchor}) andalso TargetOk of
        true -> {ok, Projection, TargetProjection};
        false -> {error, cache_corrupt}
    end;
replay_cache(Store, Ns, Anchor, From, Height, Projection0, PhaseIndex,
             TargetSlot, TargetProjection0) ->
    WindowTo = min(Height, From + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1),
    %% End one replay window exactly at the requested reference slot so the
    %% evidence projection is the post-slot state even when this durable cache
    %% has already advanced beyond it.
    To = case is_integer(TargetSlot) andalso
                  TargetSlot >= From andalso TargetSlot < WindowTo of
             true -> TargetSlot;
             false -> WindowTo
         end,
    try quod_ledger_store:read_range(Store, From, To) of
        {ok, Entries} ->
            case quod_catchup:page_stats(Entries) of
                {ok, Count, _Bytes} when Count =:= To - From + 1 ->
                    case quod_catchup:verify_forward(
                           Ns, Anchor, Projection0, From, Entries,
                           PhaseIndex) of
                        {ok, _Verified, Projection1, Delta} ->
                            case valid_projection(Projection1, {Ns, Anchor})
                                 andalso quod_dtx_phase_index:commit_delta(
                                           PhaseIndex, Delta) =:= ok of
                                true ->
                                    TargetProjection1 =
                                        case is_integer(TargetSlot) andalso
                                                  To =:= TargetSlot of
                                            true -> Projection1;
                                            false -> TargetProjection0
                                        end,
                                    replay_cache(
                                      Store, Ns, Anchor, To + 1, Height,
                                      Projection1, PhaseIndex, TargetSlot,
                                      TargetProjection1);
                                false -> {error, cache_corrupt}
                            end;
                        {error, {unavailable, network_identity, _Reason}} ->
                            {error, retry};
                        {error, _} -> {error, cache_corrupt}
                    end;
                _ -> {error, cache_corrupt}
            end
    catch _:_ ->
        {error, cache_corrupt}
    end.

fetch_to_height(Owner, RequestRef, Peer, Endpoint, Slot,
                Identity = {Ns, Anchor}, Store0, Height0, Projection0,
                SlotProjection0, PhaseIndex, Root, FetchFun, PageTimeout) ->
    case Height0 >= Slot of
        true when is_map(SlotProjection0) ->
            {ok, Store0, Height0, Projection0, SlotProjection0};
        true ->
            {error, cache_corrupt};
        false ->
            From = Height0 + 1,
            To = min(Slot, From + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1),
            case fetch_page(Owner, RequestRef, Peer, Endpoint, Ns,
                            From, To, FetchFun, PageTimeout) of
                {ok, Entries, RemoteHeight} when is_integer(RemoteHeight),
                                                  RemoteHeight >= 0 ->
                    case prepare_verified_page(
                           Ns, Anchor, Identity, Projection0, PhaseIndex,
                           From, To, Entries, RemoteHeight) of
                        {ok, Prepared} ->
                            case persist_verified_page(
                                   Owner, RequestRef, Identity, Store0,
                                   Height0, PhaseIndex, Root, Prepared) of
                                {ok, Store1, Height1, Projection1} ->
                                    SlotProjection1 =
                                        case Height1 =:= Slot of
                                            true -> Projection1;
                                            false -> undefined
                                        end,
                                    fetch_to_height(
                                      Owner, RequestRef, Peer, Endpoint, Slot,
                                      Identity, Store1, Height1, Projection1,
                                      SlotProjection1, PhaseIndex, Root,
                                      FetchFun, PageTimeout);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                _ ->
                    {error, retry}
            end
    end.

prepare_verified_page(
  Ns, Anchor, Identity, Projection0, PhaseIndex,
  From, To, Entries, RemoteHeight) ->
    case validate_page(Entries, From, To, RemoteHeight) of
        {ok, Count, EntryBytes} ->
            case quod_catchup:verify_forward(
                   Ns, Anchor, Projection0, From, Entries, PhaseIndex) of
                {ok, Verified, Projection1, Delta}
                  when length(Verified) =:= Count ->
                    case valid_projection(Projection1, Identity) of
                        true ->
                            {ok, #{verified => Verified,
                                   projection => Projection1,
                                   phase_delta => Delta,
                                   count => Count,
                                   stored_bytes => EntryBytes + 12 * Count}};
                        false ->
                            {error, invalid_history}
                    end;
                {error, {unavailable, network_identity, _Reason}} ->
                    {error, retry};
                {error, _} ->
                    {error, invalid_history}
            end;
        {error, _} ->
            {error, invalid_history}
    end.

persist_verified_page(
  Owner, RequestRef, Identity, Store0, Height0, PhaseIndex, Root,
  #{verified := Verified, projection := Projection1,
    phase_delta := Delta, count := Count, stored_bytes := StoredBytes}) ->
    %% The checkpoint replaces its predecessor after the append. Reserve its
    %% complete maximum before either durable allocation, then reconcile to
    %% the exact persisted bytes after the atomic rename.
    Reservation = StoredBytes + ?QUOD_MAX_FOREIGN_PAGE_BYTES,
    case gen_server:call(
           Owner, {reserve_page, RequestRef, Reservation}) of
        ok ->
            try quod_ledger_store:append(Store0, Verified) of
                {ok, Store1} ->
                    case quod_dtx_phase_index:commit_delta(PhaseIndex, Delta) of
                        ok ->
                            Height1 = Height0 + Count,
                            case write_checkpoint(
                                   Root, Identity, cache_namespace(Identity),
                                   Height1, Projection1) of
                                ok ->
                                    ActualBytes = cache_persisted_bytes(
                                                    Root,
                                                    cache_namespace(Identity)),
                                    case gen_server:call(
                                           Owner,
                                           {set_cache_size, RequestRef,
                                            ActualBytes}) of
                                        ok ->
                                            {ok, Store1, Height1, Projection1};
                                        {error, _} ->
                                            {error, cache_corrupt}
                                    end;
                                {error, _} ->
                                    {error, cache_corrupt}
                            end;
                        {error, _} ->
                            {error, cache_corrupt}
                    end
            catch _:_ ->
                {error, cache_corrupt}
            end;
        {error, _} ->
            {error, cache_full}
    end.

current_route_hints(Supplied, Projection) ->
    Certified = maps:to_list(
                  quod_simplex:history_validator_routes(Projection)),
    Hints = lists:usort(Certified ++ Supplied),
    case length(Hints) =< ?MAX_CURRENT_ROUTE_HINTS of
        true -> Hints;
        false -> []
    end.

probe_pages(Owner, RequestRef, Hints, Ns, Height, FetchFun, PageTimeout) ->
    %% Snapshot probes need only the first available certified candidate plus
    %% the responder's captured durable height. Keeping one entry per route
    %% prevents an N-validator fanout from retaining N near-900-KiB pages.
    To = Height + 1,
    parallel_probes(
      Hints,
      fun({Peer, Endpoint}) ->
          fetch_page(Owner, RequestRef, Peer, Endpoint, Ns,
                     Height + 1, To, FetchFun, PageTimeout)
      end,
      PageTimeout).

parallel_probes(Items, Probe, TimeoutMs) ->
    Parent = self(),
    Tag = make_ref(),
    Pending = lists:foldl(
                fun(Item, Acc) ->
                    {Pid, MRef} = spawn_opt(
                                    fun() ->
                                        Result = Probe(Item),
                                        Parent ! {foreign_probe, Tag, self(),
                                                  Item, Result}
                                    end, [link, monitor]),
                    Acc#{Pid => {MRef, Item}}
                end, #{}, Items),
    Deadline = quod_time:mono_ms() + TimeoutMs,
    collect_probes(Tag, Pending, Deadline, []).

collect_probes(_Tag, Pending, _Deadline, Acc)
  when map_size(Pending) =:= 0 ->
    lists:reverse(Acc);
collect_probes(Tag, Pending, Deadline, Acc) ->
    Wait = max(0, Deadline - quod_time:mono_ms()),
    receive
        {foreign_probe, Tag, Pid, Item, Result}
          when is_map_key(Pid, Pending) ->
            {{MRef, Item}, Pending1} = maps:take(Pid, Pending),
            _ = erlang:demonitor(MRef, [flush]),
            collect_probes(
              Tag, Pending1, Deadline, [{Item, Result} | Acc]);
        {'DOWN', MRef, process, Pid, _Reason}
          when is_map_key(Pid, Pending) ->
            case maps:get(Pid, Pending) of
                {MRef, _Item} ->
                    collect_probes(
                      Tag, maps:remove(Pid, Pending), Deadline, Acc);
                _ ->
                    collect_probes(Tag, Pending, Deadline, Acc)
            end
    after Wait ->
        stop_current_probes(Pending),
        lists:reverse(Acc)
    end.

stop_current_probes(Pending) ->
    maps:foreach(
      fun(Pid, {MRef, _Item}) ->
          _ = erlang:demonitor(MRef, [flush]),
          _ = unlink(Pid),
          exit(Pid, kill)
      end, Pending).

advance_snapshot(
  Owner, RequestRef, Identity = {Ns, Anchor}, Store0, Height0,
  Projection0, PhaseIndex, Root, Results, FetchFun, PageTimeout) ->
    ProbeTo = Height0 + 1,
    Candidates =
        [{RemoteHeight, Source}
         || {Source, {ok, Entries, RemoteHeight}} <- Results,
            is_integer(RemoteHeight), RemoteHeight > Height0,
            validate_page(Entries, Height0 + 1, ProbeTo, RemoteHeight)
                =/= {error, bad_page}],
    case Candidates of
        [] ->
            {ok, Height0, Projection0};
        _ ->
            Advertised = lists:max([H || {H, _Source} <- Candidates]),
            Target = min(
                       Advertised,
                       Height0 + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES),
            Sources = [Source
                       || {_H, Source} <- lists:reverse(
                                             lists:keysort(1, Candidates))],
            advance_snapshot_sources(
              Sources, Owner, RequestRef, Ns, Anchor, Identity,
              Store0, Height0, Projection0, PhaseIndex, Root, Target,
              FetchFun, PageTimeout)
    end.

advance_snapshot_sources(
  [], _Owner, _RequestRef, _Ns, _Anchor, _Identity,
  _Store, _Height, _Projection, _PhaseIndex, _Root, _Target,
  _FetchFun, _PageTimeout) ->
    {error, invalid_history};
advance_snapshot_sources(
  [{Peer, Endpoint} | Rest], Owner, RequestRef,
  Ns, Anchor, Identity, Store0, Height0, Projection0,
  PhaseIndex, Root, Target, FetchFun, PageTimeout) ->
    case fetch_page(
           Owner, RequestRef, Peer, Endpoint, Ns,
           Height0 + 1, Target, FetchFun, PageTimeout) of
        {ok, Entries, RemoteHeight}
          when is_list(Entries), is_integer(RemoteHeight), RemoteHeight >= 0 ->
            case prepare_verified_page(
                   Ns, Anchor, Identity, Projection0, PhaseIndex,
                   Height0 + 1, Target, Entries, RemoteHeight) of
                {ok, Prepared} ->
                    case persist_verified_page(
                           Owner, RequestRef, Identity, Store0, Height0,
                           PhaseIndex, Root, Prepared) of
                        {ok, _Store1, Height1, Projection1} ->
                            {ok, Height1, Projection1};
                        {error, _} = Error ->
                            Error
                    end;
                {error, invalid_history} ->
                    advance_snapshot_sources(
                      Rest, Owner, RequestRef, Ns, Anchor, Identity,
                      Store0, Height0, Projection0, PhaseIndex, Root,
                      Target, FetchFun, PageTimeout);
                {error, retry} ->
                    {error, retry}
            end;
        _ ->
            advance_snapshot_sources(
              Rest, Owner, RequestRef, Ns, Anchor, Identity,
              Store0, Height0, Projection0, PhaseIndex, Root,
              Target, FetchFun, PageTimeout)
    end.

current_view_confirmed(
  Owner, RequestRef, Hints, Ns, Anchor, Identity, Height, Projection,
  PhaseIndex,
  FetchFun, PageTimeout) ->
    Committee = quod_simplex:history_committee(Projection),
    case Committee of
        [] ->
            false;
        [_ | _] ->
            current_committee_confirmed(
              Committee, Owner, RequestRef, Hints, Ns, Anchor, Identity,
              Height, Projection, PhaseIndex, FetchFun, PageTimeout)
    end.

current_committee_confirmed(
  Committee, Owner, RequestRef, Hints, Ns, Anchor, Identity, Height,
  Projection, PhaseIndex, FetchFun, PageTimeout) ->
    ByPeer = route_hints_by_peer(Hints, Committee),
    Needed = quod_simplex:quorum(length(Committee)),
    Results = parallel_probes(
                maps:to_list(ByPeer),
                fun({Peer, Endpoints}) ->
                    probe_peer_endpoints(
                      Endpoints, Owner, RequestRef, Peer, Ns, Height,
                      FetchFun, PageTimeout)
                end,
                PageTimeout),
    Confirmed = lists:usort(
                  [Peer
                   || {{Peer, _Endpoints}, Responses} <- Results,
                      lists:member(Peer, Committee),
                      lists:any(
                        fun(Response) ->
                            tip_response_at_least(
                              Response, Ns, Anchor, Identity, Height,
                              Projection, PhaseIndex)
                        end,
                        Responses)]),
    length(Confirmed) >= Needed.

route_hints_by_peer(Hints, Committee) ->
    lists:foldl(
      fun({Peer, Endpoint}, Acc) ->
          case lists:member(Peer, Committee) of
              true ->
                  Acc#{Peer => lists:usort(
                                  [Endpoint | maps:get(Peer, Acc, [])])};
              false -> Acc
          end
      end, #{}, Hints).

probe_peer_endpoints(
  [], _Owner, _RequestRef, _Peer, _Ns, _Height,
  _FetchFun, _PageTimeout) ->
    [];
probe_peer_endpoints(
  [Endpoint | Rest], Owner, RequestRef, Peer, Ns, Height,
  FetchFun, PageTimeout) ->
    To = Height + 1,
    Result = fetch_page(
               Owner, RequestRef, Peer, Endpoint, Ns,
               Height + 1, To, FetchFun, PageTimeout),
    [Result | probe_peer_endpoints(
                Rest, Owner, RequestRef, Peer, Ns, Height,
                FetchFun, PageTimeout)].

tip_response_at_least(
  {ok, [], RemoteHeight}, _Ns, _Anchor, _Identity,
  Height, _Projection, _PhaseIndex) ->
    is_integer(RemoteHeight) andalso RemoteHeight >= Height;
tip_response_at_least(
  {ok, Entries, RemoteHeight}, Ns, Anchor, Identity,
  Height, Projection, PhaseIndex) when is_list(Entries) ->
    To = Height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES,
    case prepare_verified_page(
           Ns, Anchor, Identity, Projection, PhaseIndex,
           Height + 1, To, Entries, RemoteHeight) of
        {ok, _Prepared} -> RemoteHeight >= Height;
        {error, _} -> false
    end;
tip_response_at_least(
  _Result, _Ns, _Anchor, _Identity, _Height, _Projection, _PhaseIndex) ->
    false.

current_view_evidence(Identity, Height, Projection) ->
    Dtx = maps:get(dtx, Projection),
    #{identity => Identity,
      slot => Height,
      generation => maps:get(generation, Dtx),
      committee => quod_simplex:history_committee(Projection),
      committee_id => maps:get(committee_id, Projection),
      routes => quod_simplex:history_validator_routes(Projection)}.

fetch_page(Owner, RequestRef, Peer, Endpoint, Ns, From, To, undefined,
           PageTimeout) ->
    try gen_server:call(
          Owner, {pull_page, RequestRef, Peer, Endpoint, Ns, From, To},
          PageTimeout + 1000)
    catch exit:_ -> {error, retry}
    end;
fetch_page(_Owner, _RequestRef, Peer, Endpoint, Ns, From, To, FetchFun,
           _PageTimeout) ->
    try FetchFun(Peer, Endpoint, Ns, From, To)
    catch exit:_ -> {error, retry}
    end.

validate_page(Entries, From, To, RemoteHeight) ->
    case quod_catchup:page_stats(Entries) of
        {ok, Count, Bytes} when Count > 0, Count =< To - From + 1 ->
            case page_indices(Entries, From, To) andalso
                 RemoteHeight >= From + Count - 1 of
                true -> {ok, Count, Bytes};
                false -> {error, bad_page}
            end;
        _ ->
            {error, bad_page}
    end.

page_indices([], _Next, _To) -> true;
page_indices([#entry{index = Next} | Rest], Next, To) when Next =< To ->
    page_indices(Rest, Next + 1, To);
page_indices(_, _Next, _To) -> false.

verify_exact_reference(Store, Ref, ExpectedPhase, Projection) ->
    Slot = ref_slot(Ref),
    case quod_ledger_store:read_at(Store, Slot) of
        {ok, #entry{data = Data} = Entry} ->
            case quod_ledger:classify(Data) of
                {ExpectedPhase, Control} ->
                    Identity = ref_identity(Ref),
                    case quod_dtx:certified_entry_ref(
                           Identity, Entry, Control) of
                        {ok, Ref} ->
                            DtxProjection = maps:get(dtx, Projection),
                            Generation = maps:get(generation, DtxProjection),
                            Committee = quod_simplex:history_committee(
                                          Projection),
                            Routes = quod_simplex:history_validator_routes(
                                       Projection),
                            {ok,
                             #{identity => Identity,
                               slot => Slot,
                               block_hash => ref_block_hash(Ref),
                               record_digest => ref_record_digest(Ref),
                               phase => ExpectedPhase,
                               generation => Generation,
                               control => Control,
                               committee => Committee,
                               committee_id => maps:get(
                                                 committee_id,
                                                 Projection),
                               routes => Routes}};
                        _ -> {error, invalid_foreign_reference}
                    end;
                {_OtherPhase, _Control} ->
                    {error, phase_mismatch};
                _ ->
                    {error, invalid_foreign_reference}
            end;
        not_found ->
            {error, retry}
    end.

verify_reference_source(Peer, {ok, #{committee := Committee}} = Result,
                        true) ->
    case verified_route_peer(Peer, Committee) of
        true -> Result;
        false ->
            %% This is a route failure, not evidence that the certified
            %% reference is false; callers may try another candidate.
            {error, retry}
    end;
verify_reference_source(_Peer, Result, _RequirePeer) ->
    Result.

verified_route_peer({local, _Identity}, _Committee) -> true;
verified_route_peer(Peer, Committee) -> lists:member(Peer, Committee).

%%%===================================================================
%%% Durable cache
%%%===================================================================

cache_namespace({Ns, Anchor}) ->
    crypto:hash(
      sha256,
      term_to_binary({quod_foreign_log, ?CACHE_VERSION, Ns, Anchor},
                     [deterministic])).

cache_dir(Root, CacheNs) ->
    quod_ledger_store:ns_dir(Root, CacheNs).

manifest_path(Root, CacheNs) ->
    filename:join(cache_dir(Root, CacheNs), ?MANIFEST).

checkpoint_path(Root, CacheNs) ->
    filename:join(cache_dir(Root, CacheNs), ?CHECKPOINT).

cache_log_bytes(Root, CacheNs) ->
    case file:read_file_info(filename:join(cache_dir(Root, CacheNs), ?LOG)) of
        {ok, Info} -> element(2, Info);
        {error, _} -> 0
    end.

cache_persisted_bytes(Root, CacheNs) ->
    Dir = cache_dir(Root, CacheNs),
    file_bytes(filename:join(Dir, ?LOG)) +
        file_bytes(filename:join(Dir, ?MANIFEST)) +
        file_bytes(filename:join(Dir, ?CHECKPOINT)).

file_bytes(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(2, Info);
        {error, _} -> 0
    end.

ensure_manifest(Owner, RequestRef, Root, {Ns, Anchor}, CacheNs) ->
    Path = manifest_path(Root, CacheNs),
    Expected = {quod_foreign_log_cache, ?CACHE_VERSION,
                Ns, Anchor, CacheNs},
    case read_small_term(Path) of
        {ok, Expected} -> ok;
        {error, enoent} ->
            case gen_server:call(
                   Owner,
                   {reserve_page, RequestRef, ?MANIFEST_RESERVE_BYTES}) of
                ok ->
                    atomic_write(
                      Path, term_to_binary(Expected, [deterministic]));
                {error, _} ->
                    {error, cache_full}
            end;
        _ ->
            {error, corrupt_manifest}
    end.

write_checkpoint(Root, {Ns, Anchor}, CacheNs, Height, Projection) ->
    Bytes = cache_log_bytes(Root, CacheNs),
    Term = {quod_foreign_log_checkpoint, ?CACHE_VERSION,
            Ns, Anchor, Height, Bytes, Projection},
    Blob = term_to_binary(Term, [deterministic]),
    case byte_size(Blob) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES of
        true -> atomic_write(checkpoint_path(Root, CacheNs), Blob);
        false -> {error, checkpoint_too_large}
    end.

load_checkpoint(Root, Identity = {Ns, Anchor}, CacheNs, Height) ->
    Path = checkpoint_path(Root, CacheNs),
    case read_small_term(Path) of
        {ok, {quod_foreign_log_checkpoint, ?CACHE_VERSION,
              Ns, Anchor, Height, StoredBytes, Projection}}
          when is_integer(StoredBytes), StoredBytes >= 0 ->
            case StoredBytes =:= cache_log_bytes(Root, CacheNs) andalso
                 valid_projection(Projection, Identity) of
                true -> {ok, Projection};
                false -> {error, corrupt_checkpoint}
            end;
        {error, enoent} -> new;
        _ -> {error, corrupt_checkpoint}
    end.

read_small_term(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} when element(2, Info) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES ->
            case file:read_file(Path) of
                {ok, Bin} ->
                    case quod_safe_term:decode(
                           Bin, ?QUOD_MAX_FOREIGN_PAGE_BYTES) of
                        {ok, Term} ->
                            case term_to_binary(Term, [deterministic]) =:= Bin of
                                true -> {ok, Term};
                                false -> {error, noncanonical}
                            end;
                        {error, _} -> {error, bad_term}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {ok, _} -> {error, too_large};
        {error, Reason} -> {error, Reason}
    end.

atomic_write(Path, Blob) ->
    ok = filelib:ensure_dir(Path),
    Token = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Tmp = Path ++ ".new." ++ Token,
    case file:open(Tmp, [write, raw, binary, exclusive]) of
        {ok, Fd} ->
            Result =
                try
                    ok = file:write(Fd, Blob),
                    ok = file:datasync(Fd),
                    ok
                catch _:_ -> {error, write_failed}
                after _ = file:close(Fd)
                end,
            case Result of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok -> sync_dir(filename:dirname(Path));
                        {error, _} = Error -> _ = file:delete(Tmp), Error
                    end;
                {error, _} = Error ->
                    _ = file:delete(Tmp),
                    Error
            end;
        {error, _} = Error -> Error
    end.

sync_dir(Dir) ->
    case file:open(Dir, [read, raw]) of
        {ok, Fd} ->
            Result = file:datasync(Fd),
            _ = file:close(Fd),
            case Result of
                ok -> ok;
                {error, eisdir} -> ok;
                Error -> Error
            end;
        {error, eisdir} -> ok;
        {error, Reason} -> {error, Reason}
    end.

load_histories(Root) ->
    case file:list_dir(Root) of
        {ok, Names} -> load_history_dirs(Root, Names, #{}, 0);
        {error, enoent} -> {#{}, 0};
        {error, _} -> {#{}, 0}
    end.

load_history_dirs(_Root, [], Histories, Total) ->
    {Histories, Total};
load_history_dirs(Root, [Name | Rest], Histories0, Total0) ->
    Dir = filename:join(Root, Name),
    case load_history_dir(Root, Dir) of
        {ok, H = #history{identity = Identity, bytes = Bytes}}
          when map_size(Histories0) < ?QUOD_MAX_FOREIGN_HISTORIES,
               Total0 + Bytes =< ?QUOD_MAX_FOREIGN_CACHE_BYTES ->
            load_history_dirs(
              Root, Rest, Histories0#{Identity => H}, Total0 + Bytes);
        {ok, _OverLimit} ->
            _ = remove_cache_path(Dir),
            load_history_dirs(Root, Rest, Histories0, Total0);
        error ->
            _ = remove_cache_path(Dir),
            load_history_dirs(Root, Rest, Histories0, Total0)
    end.

load_history_dir(Root, Dir) ->
    ok = cleanup_cache_temps(Dir),
    case read_small_term(filename:join(Dir, ?MANIFEST)) of
        {ok, {quod_foreign_log_cache, ?CACHE_VERSION,
              Ns, <<_:256>> = Anchor, <<_:256>> = CacheNs}}
          when is_binary(Ns), byte_size(Ns) > 0,
               byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES ->
            Identity = {Ns, Anchor},
            Bytes = cache_persisted_bytes(Root, CacheNs),
            case CacheNs =:= cache_namespace(Identity) andalso
                 cache_dir(Root, CacheNs) =:= Dir of
                true ->
                    case load_checkpoint(Root, Identity, CacheNs,
                                         checkpoint_height(Root, CacheNs)) of
                        {ok, Projection} ->
                            Height = checkpoint_height(Root, CacheNs),
                            {ok, #history{identity = Identity,
                                          cache_ns = CacheNs,
                                          height = Height, bytes = Bytes,
                                          projection = Projection,
                                          last_used = 0}};
                        _ -> error
                    end;
                false -> error
            end;
        _ -> error
    end.

cleanup_cache_temps(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            _ = [file:delete(filename:join(Dir, Name))
                 || Name <- Names, is_cache_temp(Name)],
            ok;
        {error, _} -> ok
    end.

is_cache_temp(Name) when is_list(Name) ->
    lists:prefix(?MANIFEST ++ ".new.", Name) orelse
        lists:prefix(?CHECKPOINT ++ ".new.", Name).

remove_cache_path(Path) ->
    case file:del_dir_r(Path) of
        ok -> ok;
        {error, enotdir} ->
            case file:delete(Path) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, _} = Error -> Error
            end;
        {error, enoent} -> ok;
        {error, _} = Error -> Error
    end.

checkpoint_height(Root, CacheNs) ->
    case read_small_term(checkpoint_path(Root, CacheNs)) of
        {ok, {quod_foreign_log_checkpoint, ?CACHE_VERSION,
              _Ns, _Anchor, Height, _Bytes, _Projection}}
          when is_integer(Height), Height >= 0 -> Height;
        _ -> -1
    end.

%%%===================================================================
%%% Shared bounded-shape checks and ref accessors
%%%===================================================================

valid_projection(
  #{committee := Committee, validator_routes := Routes,
    committee_id := CommitteeId,
    admissions := Admissions, sequences := Sequences,
    dtx := Dtx, dtx_lanes := DtxLanes} = Projection,
  ExpectedIdentity)
  when is_map(Routes), is_map(Admissions), is_map(Sequences),
       is_map(DtxLanes),
       map_size(Routes) =< ?MAX_VALIDATORS,
       map_size(Admissions) =< ?MAX_VALIDATORS,
       map_size(Sequences) =< ?MAX_VALIDATORS,
       map_size(DtxLanes) =< ?MAX_VALIDATORS ->
    bounded_committee(Committee, 0) andalso
        valid_validator_routes(Routes, Committee) andalso
        (CommitteeId =:= undefined orelse
         (is_binary(CommitteeId) andalso byte_size(CommitteeId) =:= 32)) andalso
        valid_dtx_target(Dtx, ExpectedIdentity) andalso
        map_size(Projection) =:= 11;
valid_projection(_, _) -> false.

valid_validator_routes(Routes, Committee) ->
    maps:fold(
      fun(<<_:256>> = Key, Endpoint, Valid) ->
              Valid andalso lists:member(Key, Committee) andalso
                  quod_quic:valid_endpoint(Endpoint);
         (_Key, _Endpoint, _Valid) ->
              false
      end, true, Routes).

bounded_committee([], _Count) -> true;
bounded_committee([<<_:256>> | Rest], Count) when Count < ?MAX_VALIDATORS ->
    bounded_committee(Rest, Count + 1);
bounded_committee(_, _Count) -> false.

valid_dtx_target(
  #{target := Identity, generation := Generation}, Identity)
  when is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 -> true;
valid_dtx_target(_, _) -> false.

ref_identity(
  {quod_dtx_ref, 2, Ns, Anchor, _Slot, _BlockHash, _Digest, _Proof}) ->
    {Ns, Anchor};
ref_identity(_) -> invalid.

ref_slot({quod_dtx_ref, 2, _Ns, _Anchor, Slot, _BlockHash, _Digest, _Proof}) ->
    Slot.

ref_block_hash(
  {quod_dtx_ref, 2, _Ns, _Anchor, _Slot, BlockHash, _Digest, _Proof}) ->
    BlockHash.

ref_record_digest(
  {quod_dtx_ref, 2, _Ns, _Anchor, _Slot, _BlockHash, Digest, _Proof}) ->
    Digest.
