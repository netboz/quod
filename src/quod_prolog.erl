-module(quod_prolog).
-moduledoc """
Per-namespace fact engine: owns the committed erlog knowledge base for one
ontology, serves `prove/3`, and applies committed blocks from `quod_simplex` in log
order. One `gen_server` per namespace.

- **Every proof runs in its own bounded WORKER process** — the engine never blocks
  on a proof (doc/inter-ontology.md §4.1). The worker gets a small shared-store snapshot
  handle, never the knowledge base. A wedged proof wedges only its worker (killed after
  past its configured absolute lifetime, and the per-proof overlay dies with it.
- **Reads** run on a copy-on-write overlay (`m:quod_erlog_db_local_prove`) so the
  committed kb is never touched; the answer is bindings (stamped with the height the
  frozen view was taken at), returned to the caller.
- **Writes** (a proof that staged asserts/retracts) are handed back to the engine and
  become a `#transaction{}` submitted to `quod_simplex`; the caller is parked and
  replied to when the block applies (or reaped by a per-tx TTL if the verdict never
  arrives).
- **`apply_block/3`** is the deterministic state machine `quod_simplex` drives on every
  member: re-check the read-set against the committed kb (OCC), then apply the diff
  or reject — identical verdict on every member. A **committee-changing** transaction
  (its diff asserts/retracts `peer_admitted`) is the exception: it applies
  **unconditionally**, skipping OCC, because it was already re-validated against the
  parent state before the vote (see `request_membership_verdict/5`) — this keeps the kb
  and `quod_simplex`'s validator-set projection in lockstep.

Proves are gated until an initial **rebuild** completes (`ready`), so a freshly
(re)started engine never answers from a half-built kb. The kb is built with the
erlog flag `unknown = fail`. See `doc/ordering-layer-spec.md` §4.
""".
-behaviour(gen_server).
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-export([start_link/2, prove/3, prove_ro/3, applied/1, apply_block/3, mark_ready/1, sync/1,
         request_membership_verdict/5, stats/1, namespaces/0]).
-export([genesis_diff/1, read_terms/1, terms_to_diff/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([membership_verdict/2]).   %% the pure verdict over #s.est — driven directly by eunit
-endif.

%% The membership-verdict park budget: a verdict parked past the slot's Δ complaint-skip is moot, so this
%% is a short FIXED budget (default 2000 ms — on the order of the consensus Δ_timeout, `?DELTA_MS` ~1 s in
%% quod_simplex), deliberately NOT the 30 s write TTL. Reaping a stale parked verdict delivers `abstain`.
-define(DEFAULTS, #{node_id => undefined, park_ttl_ms => 30000,
                    validation_ttl_ms => 2000, max_proof_workers => 64,
                    max_ask_workers => 64, proof_timeout_ms => 60000,
                    ask_timeout_ms => 60000, ask_step_timeout_ms => 30000}).

%% Busy/rebuilding replies are deliberately rate-limited: an authenticated peer can
%% still flood valid open frames, and rejecting them must not create unbounded work.
-define(MAX_ASK_REJECTS_PER_SECOND, 32).

-record(proof_worker, {pid         :: pid(),
                       worker_mref :: reference(),
                       caller_mref :: reference(),
                       from        :: gen_server:from(),
                       timer       :: reference(),
                       token       :: reference(),
                       height = 0  :: non_neg_integer()}).

-record(ask_worker, {pid        :: pid(),
                     owner_mref :: reference(),
                     id = undefined :: binary() | undefined,
                     height = 0 :: non_neg_integer(),
                     timer = undefined :: reference() | undefined,
                     token = undefined :: reference() | undefined,
                     lifetime_timer :: reference(),
                     lifetime_token :: reference(),
                     pending = false :: boolean(),
                     queued = false :: boolean()}).

-record(s, {ns        :: binary(),
            self      :: node_id(),
            est       :: tuple(),                 %% committed erlog #est{} (unknown=fail)
            ready     = false :: boolean(),       %% true once the initial rebuild has run
            ttl       = 30000 :: pos_integer(),
            vttl      = 2000 :: pos_integer(),    %% membership-verdict park budget (ms)
            max_proof_workers = 64 :: pos_integer(),
            max_ask_workers = 64 :: pos_integer(),
            proof_timeout_ms = 60000 :: pos_integer(),
            ask_timeout_ms = 60000 :: pos_integer(),
            ask_step_timeout_ms = 30000 :: pos_integer(),
            applied   = 0  :: log_index(),
            %% tx_id => {From, Bindings, HeightRead, TimerRef, AsyncRequestId | none}
            parked    = #{} :: #{binary() => {gen_server:from(), [map()], log_index(),
                                               reference(), term()}},
            requests  :: term(),                 %% gen_statem async-request collection, labelled by tx_id
            %% membership verdicts parked until the KB reaches the proposal's parent height (Slot-1),
            %% then delivered to ReplyTo as {membership_verdict, Tag, Verdict}. Keyed by the unique Tag.
            %% Tag => {Slot, Change, ReplyTo, TimerRef}
            validations = #{} :: #{term() => {log_index(), term(), pid(), reference()}},
            applies   = 0, rejects = 0, proves = 0, conflicts = 0,
            park_timeouts = 0 :: non_neg_integer(),     %% parked writes reaped by TTL (verdict never arrived)
            %% Ref => #proof_worker{}
            workers   = #{} :: map(),
            %% WorkerMon => #ask_worker{}. The reverse index makes both normal
            %% completion and asker cancellation O(1), bounded by max_ask_workers.
            ask_workers = #{} :: map(),
            ask_callers = #{} :: map(),
            ask_pids = #{} :: map(),
            ask_ids = #{} :: map(),
            reject_window = 0 :: integer(),
            reject_count = 0 :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(binary(), map()) -> {ok, pid()} | {error, term()}.
start_link(Ns, Config) ->
    gen_server:start_link(quod_reg:via({quod_prolog, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Prove `Goal` (emitted from `CallerNs`) against namespace `TargetNs`.".
-spec prove(binary(), term(), binary()) ->
        {ok, [map()], log_index()} | {error, term()} | fail.
prove(TargetNs, Goal, CallerNs) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Pid -> try gen_server:call(Pid, {prove, Goal, CallerNs}, infinity)
               catch exit:_ -> fail end
    end.

-doc "Read-only prove: like `prove/3` but a write goal is refused (`{error, read_only}`).".
-spec prove_ro(binary(), term(), binary()) ->
        {ok, [map()], log_index()} | {error, term()} | fail.
prove_ro(TargetNs, Goal, CallerNs) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Pid -> try gen_server:call(Pid, {prove_ro, Goal, CallerNs}, infinity)
               catch exit:_ -> fail end
    end.

-doc "The committed log index this kb has applied (the freshness height for a read).".
-spec applied(binary()) -> log_index().
applied(Ns) ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> 0;
        _Pid      -> maps:get(applied, stats(Ns), 0)
    end.

-doc """
Apply a committed entry (called by `quod_simplex`, strictly in index order). This is an async
cast so durable consensus is not serialized behind proof execution in this process. Write
submission itself uses OTP asynchronous `gen_statem` requests, so the fact engine can continue
proving and consuming commits while append calls are outstanding. The OCC verdict is delivered
straight to the parked client here; a forward gap asks `quod_simplex` to re-drive.
""".
-spec apply_block(binary(), pos_integer(), {batch, [#transaction{}]} | noop) -> ok.
apply_block(Ns, Index, Change) ->
    gen_server:cast(quod_reg:via({quod_prolog, Ns}), {apply_block, Index, Change}).

-doc "Signal that the initial rebuild is complete and proves may be served.".
-spec mark_ready(binary()) -> ok.
mark_ready(Ns) -> gen_server:cast(quod_reg:via({quod_prolog, Ns}), mark_ready).

-doc """
Synchronous no-op barrier: returns once every message already in this kb's queue — in
particular a burst of `apply_block/3` casts — has been consumed. `quod_simplex`'s streamed
replay calls this every few hundred casts so a long rebuild can't flood the mailbox with
the whole log (backpressure); the applies themselves must stay casts (see `apply_block/3`).
Deadlock-safe from the replay: it only runs while this kb is UNREADY, and an unready kb
refuses proves, so it can never be parked in an `append` back into `quod_simplex`.
""".
-spec sync(binary()) -> ok.
sync(Ns) -> gen_server:call(quod_reg:via({quod_prolog, Ns}), sync, 30000).

-doc """
Ask this kb to judge a committee-changing `Change` proposed for `Slot`, and deliver the verdict
ASYNCHRONOUSLY as `{membership_verdict, Tag, valid | {invalid, Reason} | abstain}` to `ReplyTo`.

A **cast** on purpose: membership validation can require Prolog work while the consensus statem
is handling the proposal. Neither process waits synchronously for the other; the verdict returns
as a correlated message.

The verdict is judged against the KB **as of the proposal's parent** (`Slot-1`), so every honest node
reaches the same verdict deterministically: if the kb is already there it is delivered now; if it is
behind, the request parks until `apply_block` reaches `Slot-1` (or a short fixed TTL — `validation_ttl_ms`,
on the order of Δ — reaps it to `abstain`); if the kb is already past the slot, the slot resolved without
us — `abstain`. Re-issuing the same `Tag` supersedes a still-parked request for it.
""".
-spec request_membership_verdict(binary(), term(), pos_integer(), pid(), term()) -> ok.
request_membership_verdict(Ns, Change, Slot, ReplyTo, Tag) ->
    gen_server:cast(quod_reg:via({quod_prolog, Ns}), {membership_verdict_req, Change, Slot, ReplyTo, Tag}).

stats(Ns) ->
    try gen_server:call(quod_reg:via({quod_prolog, Ns}), get_stats, 1000)
    catch exit:_ -> #{} end.

namespaces() -> gproc:select([{{{n, l, {quod_prolog, '$1'}}, '_', '_'}, [], ['$1']}]).

positive_limit(_Name, Value) when is_integer(Value), Value > 0 -> Value;
positive_limit(Name, Value) -> error({bad_config, {Name, Value}}).

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    Cfg  = maps:merge(?DEFAULTS, Config),
    MaxProofWorkers = positive_limit(max_proof_workers, maps:get(max_proof_workers, Cfg)),
    MaxAskWorkers = positive_limit(max_ask_workers, maps:get(max_ask_workers, Cfg)),
    put('$quod_ns', Ns),        %% so external predicates (e.g. admit) can recover their namespace in-process
    put('$quod_applied', 0),    %% ... and the applied height (peer_ready's slack judge; kept current below)
    S = #s{ns = Ns, self = maps:get(node_id, Cfg), est = build_kb(),
           requests = gen_statem:reqids_new(),
           ttl = maps:get(park_ttl_ms, Cfg), vttl = maps:get(validation_ttl_ms, Cfg),
           max_proof_workers = MaxProofWorkers, max_ask_workers = MaxAskWorkers,
           proof_timeout_ms = positive_limit(proof_timeout_ms,
                                             maps:get(proof_timeout_ms, Cfg)),
           ask_timeout_ms = positive_limit(ask_timeout_ms, maps:get(ask_timeout_ms, Cfg)),
           ask_step_timeout_ms = positive_limit(ask_step_timeout_ms,
                                                maps:get(ask_step_timeout_ms, Cfg)),
           ready = false},
    true = quod_ask:subscribe(Ns),
    %% Ask quod_simplex (already up under the per-ns sub-sup) to replay committed blocks
    %% into this fresh kb; it casts mark_ready when the kb is caught up. Async, so
    %% init does not block on a callback.
    case quod_reg:where({quod_simplex, Ns}) of
        undefined -> ok;
        _Pid      -> catch quod_simplex:rebuild(Ns)
    end,
    {ok, S}.

%% Proves are refused until the rebuild has caught the kb up (never a half-built read).
%% A ready engine SPAWNS a worker per proof and returns immediately — the engine never
%% blocks on a proof (doc/inter-ontology.md §4.1); the worker reports its result back
%% to this engine, which owns the single reply path to the caller.
handle_call({prove, _G, _C}, _From, S = #s{ready = false}) ->
    {reply, {error, rebuilding}, S};
handle_call({prove, _Goal, _CallerNs}, _From,
            S = #s{workers = Workers, max_proof_workers = Max})
  when map_size(Workers) >= Max ->
    {reply, {error, busy}, S};
handle_call({prove, Goal, CallerNs}, From, S) ->
    {noreply, spawn_proof(prove, Goal, CallerNs, From, S)};
%% Read-only prove (the remote-read path): identical to a read, but a goal that stages a WRITE
%% is REFUSED ({error, read_only}) instead of submitted — a remote reader can never write through
%% a Member's responder. Reads carry the committed height of the frozen view they were proved
%% against (the freshness contract). Gated on readiness like {prove}.
handle_call({prove_ro, _G, _C}, _From, S = #s{ready = false}) ->
    {reply, {error, rebuilding}, S};
handle_call({prove_ro, _Goal, _CallerNs}, _From,
            S = #s{workers = Workers, max_proof_workers = Max})
  when map_size(Workers) >= Max ->
    {reply, {error, busy}, S};
handle_call({prove_ro, Goal, CallerNs}, From, S) ->
    {noreply, spawn_proof(prove_ro, Goal, CallerNs, From, S)};

handle_call(get_stats, _From, S) ->
    #est{db = #db{ref = StoreRef}} = S#s.est,
    {reply, #{applied   => S#s.applied,  applies => S#s.applies,
              rejects   => S#s.rejects,  proves  => S#s.proves,
              conflicts => S#s.conflicts,
              parked    => map_size(S#s.parked),        %% in-flight writes awaiting commit (liveness gauge)
              park_timeouts => S#s.park_timeouts,       %% writes that never committed (reaped)
              proof_workers => map_size(S#s.workers),
              ask_workers => map_size(S#s.ask_workers),
              kb_memory_words => quod_erlog_db_mvcc:memory_words(StoreRef),
              kb_history_predicates => quod_erlog_db_mvcc:history_predicates(StoreRef)}, S};

handle_call(sync, _From, S) -> {reply, ok, S};   %% replay backpressure barrier (sync/1)

%% A co-hosted `::` ask (quod_ask:open/3): spawn a demand-driven answer worker holding this
%% kb's shared snapshot handle, and hand its pid back to the asker. The engine only
%% spawns — it never runs the ask, so it stays free (doc/inter-ontology.md §4.1). Gated on
%% readiness like a prove.
handle_call({ask_open, _G, _C, _A}, _From, S = #s{ready = false}) ->
    {reply, {error, not_ready}, S};
handle_call({ask_open, _Goal, _Chain, _Asker}, _From,
            S = #s{ask_workers = AW, max_ask_workers = Max}) when map_size(AW) >= Max ->
    {reply, {error, busy}, S};
handle_call({ask_open, Goal, Chain, Asker}, _From, S) ->
    Stream = quod_ask:start_answer(S#s.ns, S#s.est, S#s.applied,
                                   Goal, Chain, Asker, self()),
    WorkerMRef = monitor(process, Stream),
    AskerMRef = monitor(process, Asker),
    Worker = new_ask_worker(Stream, WorkerMRef, AskerMRef,
                            undefined, S#s.applied, S),
    AW1 = (S#s.ask_workers)#{WorkerMRef => Worker},
    AC1 = (S#s.ask_callers)#{AskerMRef => WorkerMRef},
    AP1 = (S#s.ask_pids)#{Stream => WorkerMRef},
    {reply, {ok, Stream},
     bump_proves(S#s{ask_workers = AW1, ask_callers = AC1, ask_pids = AP1})};

handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast({apply_block, Index, Change}, S) ->
    {noreply, apply_committed(Index, Change, S)};
%% Workers report through the engine so exactly one process owns reply and lifecycle state.
handle_cast({proof_result, Ref, Kind, Goal, CallerNs, Result}, S) ->
    {noreply, finish_proof(Ref, Kind, Goal, CallerNs, Result, S)};
handle_cast({ask_cancel, Pid}, S) ->
    {noreply, cancel_ask(Pid, S)};
handle_cast(mark_ready, S) -> {noreply, S#s{ready = true}};
%% A membership-verdict request (request_membership_verdict/5): judge it against the KB at the
%% proposal's parent height (Slot-1), delivering now or parking until the kb catches up.
handle_cast({membership_verdict_req, Change, Slot, ReplyTo, Tag}, S) ->
    {noreply, request_verdict(Change, Slot, ReplyTo, Tag, S)};
handle_cast(_Msg, S)       -> {noreply, S}.

%% A proof worker finished (normal: it already replied / handed off) or crashed
%% (abnormal: the caller still waits — reply the distinct error here). MUST come
%% before the check_response fallback clause.
handle_info(Info = {'DOWN', MRef, process, _Pid, Reason}, S) ->
    case handle_worker_down(MRef, Reason, S) of
        unhandled -> handle_response_info(Info, S);
        Reply     -> Reply
    end;
%% A proof outlived its kill budget: end it (the DOWN above replies no_progress).
handle_info({proof_kill, Ref, Token}, S = #s{workers = W}) ->
    case W of
        #{Ref := #proof_worker{pid = Pid, token = Token}} -> kill_worker(Pid);
        _ -> ok
    end,
    {noreply, S};
%% Ask derivation is guarded outside the worker so cancellation and no-progress
%% remain preemptive even while erlog is inside an unbounded goal.
handle_info({ask_step_started, Pid}, S = #s{ask_pids = Pids}) ->
    case maps:get(Pid, Pids, undefined) of
        WorkerMRef when is_reference(WorkerMRef) -> {noreply, arm_ask(WorkerMRef, S)};
        _ -> {noreply, S}
    end;
handle_info({ask_step_finished, Pid}, S = #s{ask_pids = Pids}) ->
    case maps:get(Pid, Pids, undefined) of
        WorkerMRef when is_reference(WorkerMRef) -> {noreply, disarm_ask(WorkerMRef, S)};
        _ -> {noreply, S}
    end;
handle_info({ask_step_kill, WorkerMRef, Token}, S = #s{ask_workers = Workers}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #ask_worker{token = Token} -> {noreply, kill_ask(WorkerMRef, S)};
        _ -> {noreply, S}
    end;
handle_info({ask_lifetime_kill, WorkerMRef, Token}, S = #s{ask_workers = Workers}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #ask_worker{lifetime_token = Token} -> {noreply, kill_ask(WorkerMRef, S)};
        _ -> {noreply, S}
    end;
%% Remote asks arrive on the fixed channel owned by this ontology. The request link is
%% deliberately kept separate from the answer link; its monitor is the cancellation
%% signal for the target-side worker.
handle_info({quod_message, {{Peer, _Addr}, RequestLink}, Channel, Payload},
            S = #s{ns = Ns}) ->
    case Channel =:= quod_ask:ask_channel(Ns) of
        true  ->
            case quod_ask:decode_cancel(Payload) of
                {ok, AskId} ->
                    {noreply, handle_remote_cancel(AskId, S)};
                error ->
                    case quod_ask:decode_next(Payload) of
                        {ok, AskId} ->
                            {noreply, remote_next(AskId, S)};
                        error ->
                            {noreply, handle_remote_ask(Peer, RequestLink, Payload, S)}
                    end
            end;
        false -> handle_response_info({quod_message, {{Peer, _Addr}, RequestLink}, Channel, Payload}, S)
    end;
%% A parked write whose verdict never arrived (leader change / lost block): reap it
%% so the caller gets a definite answer instead of hanging.
handle_info({park_timeout, Tx}, S = #s{parked = P}) ->
    case maps:take(Tx, P) of
        {{From, _B, _H, _TRef, ReqId}, P1} ->
            gen_server:reply(From, {error, timeout}),
            {noreply, S#s{parked = P1, requests = abandon_request(ReqId, S#s.requests),
                          park_timeouts = S#s.park_timeouts + 1}};
        error -> {noreply, S}
    end;
%% A parked membership verdict whose parent height never arrived in time (the kb is too far behind, or
%% the slot was skipped before we caught up): reap it and deliver `abstain` so the voter stops waiting.
handle_info({validation_timeout, Tag}, S = #s{validations = V}) ->
    case maps:take(Tag, V) of
        {{_Slot, _Change, ReplyTo, _TRef}, V1} ->
            deliver_verdict(ReplyTo, Tag, abstain),
            {noreply, S#s{validations = V1}};
        error -> {noreply, S}
    end;
%% `send_request/2` gives us a non-blocking gen_statem call without a helper process per
%% transaction. Responses are matched through the opaque request-id collection and labelled
%% with their tx id. A successful append still resolves through ordered `apply_block`; only a
%% definite consensus rejection releases the parked client here.
handle_info(Info, S) ->
    handle_response_info(Info, S).

handle_remote_ask(Peer, RequestLink, Payload,
                  S = #s{ns = Ns, ready = Ready, ask_workers = AW, ask_ids = Ids,
                         max_ask_workers = Max}) ->
    case quod_ask:decode_open(Payload) of
        error -> S;
        {ok, AskId, Goal, Chain, AnswerCh} ->
            case maps:is_key(AskId, Ids) of
                true -> S; %% duplicate request frame: the existing run owns this id
                false when not Ready ->
                    reject_remote(Peer, AnswerCh, AskId, rebuilding, S);
                false when map_size(AW) >= Max ->
                    reject_remote(Peer, AnswerCh, AskId, busy, S);
                false when is_pid(RequestLink) ->
                    Stream = quod_ask:start_answer_remote(Ns, S#s.est, S#s.applied,
                                                          Goal, Chain, AskId, Peer,
                                                          AnswerCh, self()),
                    WorkerMRef = monitor(process, Stream),
                    RequestMRef = monitor(process, RequestLink),
                    Worker = new_ask_worker(Stream, WorkerMRef, RequestMRef,
                                            AskId, S#s.applied, S),
                    AW1 = AW#{WorkerMRef => Worker},
                    AC1 = (S#s.ask_callers)#{RequestMRef => WorkerMRef},
                    AP1 = (S#s.ask_pids)#{Stream => WorkerMRef},
                    AI1 = Ids#{AskId => WorkerMRef},
                    S#s{ask_workers = AW1, ask_callers = AC1,
                        ask_pids = AP1, ask_ids = AI1, proves = S#s.proves + 1};
                false -> S
            end
    end.

reject_remote(Peer, AnswerCh, AskId, Reason,
              S = #s{reject_window = Window, reject_count = Count}) ->
    Now = erlang:monotonic_time(millisecond),
    case Window =:= 0 orelse Now - Window >= 1000 of
        true ->
            quod_ask:reject_remote(Peer, AnswerCh, AskId, Reason),
            S#s{reject_window = Now, reject_count = 1};
        false when Count < ?MAX_ASK_REJECTS_PER_SECOND ->
            quod_ask:reject_remote(Peer, AnswerCh, AskId, Reason),
            S#s{reject_count = Count + 1};
        false -> S
    end.

handle_remote_cancel(AskId, S = #s{ask_ids = Ids}) ->
    case maps:get(AskId, Ids, undefined) of
        WorkerMRef when is_reference(WorkerMRef) -> kill_ask(WorkerMRef, S);
        _ -> S
    end.

remote_next(AskId, S = #s{ask_ids = Ids, ask_workers = Workers}) ->
    case maps:get(AskId, Ids, undefined) of
        WorkerMRef when is_reference(WorkerMRef) ->
            case maps:get(WorkerMRef, Workers, undefined) of
                #ask_worker{pending = false, pid = Pid} ->
                    Pid ! {next, AskId},
                    arm_ask(WorkerMRef, S);
                #ask_worker{pending = true} = Worker ->
                    %% Collapse arbitrarily many premature/duplicate demands into one.
                    S#s{ask_workers = Workers#{WorkerMRef => Worker#ask_worker{queued = true}}};
                _ -> S
            end;
        _ -> S
    end.

handle_response_info(Info, S = #s{requests = Requests}) ->
    case gen_statem:check_response(Info, Requests, true) of
        {{reply, Result}, Tx, Requests1} ->
            {noreply, append_result(Tx, Result, S#s{requests = Requests1})};
        {{error, _Reason}, Tx, Requests1} ->
            %% The server may have committed immediately before exiting. Keep the caller
            %% parked so replay/apply can still provide the unambiguous result.
            {noreply, request_completed(Tx, S#s{requests = Requests1})};
        no_reply ->
            {noreply, S};
        no_request ->
            {noreply, S}
    end.

terminate(_Reason, #s{ns = Ns, workers = W, ask_workers = AW}) ->
    maps:foreach(fun(_Ref, #proof_worker{pid = Pid}) -> kill_worker(Pid) end, W),
    maps:foreach(fun(_WM, #ask_worker{pid = Pid}) -> kill_worker(Pid) end, AW),
    _ = try quod_reg:unsubscribe({channel, quod_ask:ask_channel(Ns)}) catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% proof execution (worker-per-proof; copy-on-write overlay)
%%%===================================================================

%% Spawn one worker for this proof. The worker gets a small table/height snapshot handle,
%% never the committed KB contents, plus the height stamped on the public reply.
%% The engine only tracks the monitor + a kill timer; it never runs the proof.
spawn_proof(Kind, Goal, CallerNs, From,
            S = #s{ns = Ns, est = Est, applied = Applied,
                   proof_timeout_ms = ProofTimeout}) ->
    Engine = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_opt(fun() ->
        proof_worker(Engine, Ref, Kind, Goal, CallerNs, Ns, Est, Applied)
    end, [monitor]),
    CallerMRef = monitor(process, element(1, From)),
    Token = make_ref(),
    KillRef = erlang:send_after(ProofTimeout, Engine, {proof_kill, Ref, Token}),
    Worker = #proof_worker{pid = Pid, worker_mref = MRef, caller_mref = CallerMRef,
                           from = From, timer = KillRef, token = Token,
                           height = Applied},
    S#s{workers = (S#s.workers)#{Ref =>
          Worker},
        proves  = S#s.proves + 1}.

bump_proves(S) -> S#s{proves = S#s.proves + 1}.

%% Runs in the worker process. Primes the same per-proof context the engine used to
%% hold (external predicates read it from the process dictionary), proves against the
%% frozen view, and reports one correlated result to the engine. The per-proof read-set
%% ETS table is created here, so an abandoned/killed run can never leak it.
proof_worker(Engine, Ref, Kind, Goal, CallerNs, Ns, Est, Applied) ->
    _ = watch_engine(Engine, self()),
    put('$quod_ns', Ns),
    put('$quod_applied', Applied),
    put('$quod_ask_chain', [Ns]),   %% the ask path starts at this ontology (for `::` cycle/depth guards)
    Result = run_proof_est(Goal, Est),
    gen_server:cast(Engine, {proof_result, Ref, Kind, Goal, CallerNs, Result}).

finish_proof(Ref, Kind, Goal, CallerNs, Result, S) ->
    case take_proof_worker(Ref, S) of
        error -> S;
        {{From, Applied}, S1} ->
            case {Kind, Result} of
                {_, fail} -> gen_server:reply(From, fail), S1;
                {_, {error, _} = E} -> gen_server:reply(From, E), S1;
                {_, {ok, Bindings, [], _ReadSet}} ->
                    gen_server:reply(From, {ok, [Bindings], Applied}), S1;
                {prove_ro, {ok, _B, _Diff, _RS}} ->
                    gen_server:reply(From, {error, read_only}), S1;
                {prove, {ok, Bindings, Diff, RS}} ->
                    case submit_write(From, Goal, Bindings, Diff, RS, CallerNs, S1) of
                        {noreply, S2} -> S2;
                        {reply, Reply, S2} -> gen_server:reply(From, Reply), S2
                    end
            end
    end.

take_proof_worker(Ref, S = #s{workers = W}) ->
    case maps:take(Ref, W) of
        {#proof_worker{worker_mref = WorkerMRef, caller_mref = CallerMRef,
                       from = From, timer = TimerRef, height = Applied}, W1} ->
            _ = erlang:cancel_timer(TimerRef),
            demonitor(WorkerMRef, [flush]),
            demonitor(CallerMRef, [flush]),
            {{From, Applied}, S#s{workers = W1}};
        error -> error
    end.

handle_worker_down(MRef, Reason,
                   S = #s{ask_workers = AW, ask_callers = AC}) ->
    case maps:is_key(MRef, AW) of
        true -> {noreply, drop_ask(MRef, S)};
        false ->
            case maps:get(MRef, AC, undefined) of
                WorkerMRef when is_reference(WorkerMRef) ->
                    {noreply, kill_ask(WorkerMRef, S)};
                _ -> handle_proof_down(MRef, Reason, S)
            end
    end.

handle_proof_down(MRef, Reason, S = #s{workers = W}) ->
    case find_proof_monitor(MRef, W) of
        {worker, Ref, From} ->
            case take_proof_worker(Ref, S) of
                {{_From, _Height}, S1} ->
                    Reply = case Reason of killed -> {error, no_progress}; _ -> {error, prove_failed} end,
                    gen_server:reply(From, Reply),
                    {noreply, S1};
                error -> {noreply, S}
            end;
        {caller, Ref, Pid} ->
            kill_worker(Pid),
            case take_proof_worker(Ref, S) of
                {{_From, _Height}, S1} -> {noreply, S1};
                error -> {noreply, S}
            end;
        false -> unhandled
    end.

find_proof_monitor(MRef, W) ->
    maps:fold(
      fun(Ref, #proof_worker{pid = Pid, worker_mref = WorkerMRef,
                             caller_mref = CallerMRef, from = From}, Acc) ->
          case Acc of
              false when WorkerMRef =:= MRef -> {worker, Ref, From};
              false when CallerMRef =:= MRef -> {caller, Ref, Pid};
              _ -> Acc
          end
      end, false, W).

cancel_ask(Pid, S = #s{ask_pids = Pids}) ->
    case maps:get(Pid, Pids, undefined) of
        WorkerMRef when is_reference(WorkerMRef) -> kill_ask(WorkerMRef, S);
        _ -> S
    end.

arm_ask(WorkerMRef, S = #s{ask_workers = Workers,
                            ask_step_timeout_ms = StepTimeout}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #ask_worker{pending = false} = Worker ->
            Token = make_ref(),
            Timer = erlang:send_after(StepTimeout, self(),
                                      {ask_step_kill, WorkerMRef, Token}),
            S#s{ask_workers = Workers#{WorkerMRef =>
                Worker#ask_worker{pending = true, timer = Timer, token = Token}}};
        _ -> S
    end.

disarm_ask(WorkerMRef, S0 = #s{ask_workers = Workers}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #ask_worker{timer = Timer, queued = Queued, pid = Pid, id = AskId} = Worker ->
            cancel_ask_timer(Timer),
            Worker1 = Worker#ask_worker{pending = false, queued = false,
                                        timer = undefined, token = undefined},
            S1 = S0#s{ask_workers = Workers#{WorkerMRef => Worker1}},
            case Queued andalso is_binary(AskId) of
                true -> Pid ! {next, AskId}, arm_ask(WorkerMRef, S1);
                false -> S1
            end;
        _ -> S0
    end.

kill_ask(WorkerMRef, S = #s{ask_workers = Workers}) ->
    case maps:get(WorkerMRef, Workers, undefined) of
        #ask_worker{pid = Pid} -> kill_worker(Pid), drop_ask(WorkerMRef, S);
        _ -> S
    end.

drop_ask(WorkerMRef, S = #s{ask_workers = Workers, ask_callers = Callers,
                             ask_pids = Pids, ask_ids = Ids}) ->
    case maps:take(WorkerMRef, Workers) of
        {#ask_worker{pid = Pid, owner_mref = OwnerMRef, id = AskId,
                     timer = Timer, lifetime_timer = LifetimeTimer}, Workers1} ->
            cancel_ask_timer(Timer),
            cancel_ask_timer(LifetimeTimer),
            demonitor(WorkerMRef, [flush]),
            demonitor(OwnerMRef, [flush]),
            Ids1 = case AskId of undefined -> Ids; _ -> maps:remove(AskId, Ids) end,
            S#s{ask_workers = Workers1,
                ask_callers = maps:remove(OwnerMRef, Callers),
                ask_pids = maps:remove(Pid, Pids), ask_ids = Ids1};
        error -> S
    end.

cancel_ask_timer(undefined) -> ok;
cancel_ask_timer(Timer) -> _ = erlang:cancel_timer(Timer), ok.

new_ask_worker(Pid, WorkerMRef, OwnerMRef, AskId, Height,
               #s{ask_timeout_ms = AskTimeout}) ->
    Token = make_ref(),
    Timer = erlang:send_after(AskTimeout, self(),
                              {ask_lifetime_kill, WorkerMRef, Token}),
    #ask_worker{pid = Pid, owner_mref = OwnerMRef, id = AskId, height = Height,
                lifetime_timer = Timer, lifetime_token = Token}.

watch_engine(Engine, Worker) ->
    spawn(fun() ->
        EngineRef = monitor(process, Engine),
        WorkerRef = monitor(process, Worker),
        receive
            {'DOWN', EngineRef, process, Engine, _Reason} -> exit(Worker, kill);
            {'DOWN', WorkerRef, process, Worker, _Reason} ->
                demonitor(EngineRef, [flush])
        end
    end).

kill_worker(Pid) ->
    unlink(Pid),
    exit(Pid, kill).

%% The engine-side callers (membership verdicts) prove against the current state inline.
run_proof(Goal, #s{est = Est}) -> run_proof_est(Goal, Est).

run_proof_est(Goal, Est) ->
    Vs = erlog:vars_in(Goal),
    W0 = quod_erlog_db_local_prove:wrap_state(Est, #{read_set => true}),
    try erlog_int:prove_goal(Goal, W0) of
        {succeed, Final} ->
            Ov = (Final#est.db)#db.ref,
            {ok, bindings_map(erlog_int:dderef(Vs, Final#est.bs)),
             quod_erlog_db_local_prove:get_local_changes(Ov),
             quod_erlog_db_local_prove:get_read_set(Ov)};
        {fail, _}            -> fail;
        {erlog_error, E, _}  -> {error, {erlog, E}}
    catch
        %% A cross-ontology `::` ask raises a distinct, loud error (doc/inter-ontology.md §8);
        %% surface it verbatim rather than as a generic failure.
        throw:{quod_ask_error, R}   -> {error, R};
        %% erlog_error/2 THROWS — without these clauses every typed error a predicate
        %% raises would collapse into the catch-all {error, prove_failed} and be invisible.
        throw:{erlog_error, E, _St} -> {error, {erlog, E}};
        throw:{erlog_error, E}      -> {error, {erlog, E}};
        Class:Reason ->
            logger:warning("quod_prolog[~p]: prove crashed: ~p:~p", [self(), Class, Reason]),
            {error, prove_failed}
    after
        %% the read-set table lives in the overlay created above; reclaim it on
        %% EVERY exit path (success, fail, error, crash).
        quod_erlog_db_local_prove:cleanup_read_set(W0)
    end.

bindings_map(Pairs) when is_list(Pairs) -> maps:from_list(Pairs);
bindings_map(_)                         -> #{}.

%% Only own-namespace writes. Submit with OTP's asynchronous gen_statem request API,
%% then park the caller until ordered apply (or a definite consensus rejection). This
%% keeps the KB free to prove and apply while consensus runs, without spawning one
%% blocked helper process for every write.
submit_write(From, Goal, Bindings, Diff, ReadSet, CallerNs, S = #s{ns = Ns}) when CallerNs =:= Ns ->
    Tx     = tx_id(S#s.self),
    Change = #transaction{tx_id = Tx, caller_ns = CallerNs, goal = Goal, result = Bindings, diff = Diff,
                     read_check = ReadSet, author = S#s.self,
                     submitted_at = quod_time:now_ms(), sig = none},
    try gen_statem:send_request(quod_reg:via({quod_simplex, Ns}), {append, Change}) of
        ReqId ->
            Requests1 = gen_statem:reqids_add(ReqId, Tx, S#s.requests),
            TRef = erlang:send_after(S#s.ttl, self(), {park_timeout, Tx}),
            S1 = S#s{parked = (S#s.parked)#{Tx =>
                       {From, [Bindings], S#s.applied, TRef, ReqId}},
                     requests = Requests1},
            {noreply, S1}
    catch
        error:badarg ->
            {reply, {error, consensus_unavailable}, S}
    end;
submit_write(_From, _Goal, _B, _D, _R, _CallerNs, S) ->
    {reply, {error, foreign_write_unsupported}, S}.

append_result(Tx, {ok, _Slot}, S) ->
    request_completed(Tx, S);
append_result(Tx, {error, not_in_charge, unavailable}, S) ->
    request_completed(Tx, S);   %% ambiguous: a late ordered apply or the parked TTL decides
append_result(Tx, {error, not_in_charge, Hint}, S) ->
    reject_parked(Tx, {error, {not_leader, Hint}}, request_completed(Tx, S));
append_result(Tx, {error, skipped}, S) ->
    reject_parked(Tx, {error, retry}, request_completed(Tx, S));
append_result(Tx, {error, Reason}, S) ->
    reject_parked(Tx, {error, Reason}, request_completed(Tx, S));
append_result(Tx, Other, S) ->
    reject_parked(Tx, {error, {consensus_reply, Other}}, request_completed(Tx, S)).

request_completed(Tx, S = #s{parked = Parked}) ->
    case maps:get(Tx, Parked, undefined) of
        {From, Bindings, Height, TRef, _ReqId} ->
            S#s{parked = Parked#{Tx => {From, Bindings, Height, TRef, none}}};
        undefined ->
            S
    end.

%%%===================================================================
%%% apply (deterministic; identical on every member)
%%%===================================================================

%% Apply one committed entry, then — in a SHARED tail across every applied-advancing path — resolve any
%% membership verdict parked for the parent height we just reached. Whether the applied step commits a
%% tx, skips a `noop`, or logs an unexpected payload, a validation whose parent is that slot must be
%% answered (and never leak), so `resolve_validations/1` runs once here, keyed on the new `applied`.
%% The pdict height mirror is refreshed BEFORE the verdicts resolve — their `can_join` re-proof may read
%% it through the `peer_ready` external predicate.
apply_committed(Index, Change, S) ->
    S1 = apply_step(Index, Change, S),
    put('$quod_applied', S1#s.applied),
    resolve_validations(S1).

%% Each clause returns the new #s{}. Index is the committed entry's log index; entries
%% arrive in order on the (FIFO) cast channel from quod_simplex.
%%
%% Already applied (e.g. a rebuild re-drive): idempotent no-op.
apply_step(Index, _Change, S = #s{applied = A}) when Index =< A ->
    S;
%% Forward gap: quod_simplex is ahead of us (we restarted, or missed a cast). Don't apply out
%% of order — ask quod_simplex to re-drive from the snapshot so we receive a contiguous run.
apply_step(Index, _Change, S = #s{ns = Ns, applied = A}) when Index > A + 1 ->
    _ = try quod_simplex:rebuild(Ns) catch _:_ -> ok end,
    S;
apply_step(Index, noop, S) ->                              %% Index == applied+1
    publish_snapshot(Index, S);
apply_step(Index, {batch, _} = Batch, S) ->
    case quod_ledger:payload(Batch) of
        {ok, Transactions} ->
            S1 = lists:foldl(fun apply_transaction/2, S, Transactions),
            publish_snapshot(Index, S1);
        error ->
            skip_unexpected(Index, Batch, S)
    end;
%% Defensive: a committed payload that is neither `noop`, a transaction, nor a
%% well-formed batch advances the cursor instead of restart-looping on old/corrupt data.
apply_step(Index, Other, S) ->
    skip_unexpected(Index, Other, S).

apply_transaction(#transaction{tx_id = Tx, diff = Diff} = Change, S) ->
    %% A committee-changing transaction applies UNCONDITIONALLY — skip the OCC read-check. It was
    %% re-validated against the parent state before the vote (`membership_verdict/2`), so OCC is
    %% redundant here AND is the source of a real divergence: `quod_simplex:adopt_committee` folds the
    %% validator set unconditionally at commit, so an OCC-skipped membership diff would leave the KB fact
    %% behind the validator set. Applying it here keeps the two projections in lockstep. (On a single
    %% `peer_admitted` op — Slice A guarantees exactly one — apply is idempotent: an already-present
    %% assert dedups, an absent retract is a no-op.) Content txs keep OCC.
    case is_membership_change(Change) of
        true ->
            {ok, Est1} = quod_diff:apply_ops(S#s.est, Diff),
            release(Tx, fun(From, B, H) -> gen_server:reply(From, {ok, B, H}) end,
                    S#s{est = Est1, applies = S#s.applies + 1});
        false ->
            apply_content(Change, S)
    end.

skip_unexpected(Index, Other, S = #s{ns = Ns}) ->
    logger:warning("quod_prolog[~s]: skipping unexpected committed payload at ~p: ~0p", [Ns, Index, Other]),
    publish_snapshot(Index, S).

publish_snapshot(Index, S = #s{est = #est{db = #db{mod = quod_erlog_db_mvcc,
                                                     ref = Ref0} = Db} = Est}) ->
    Floor = oldest_snapshot(Index, S),
    Ref1 = quod_erlog_db_mvcc:commit(Ref0, Index, Floor),
    S#s{est = Est#est{db = Db#db{ref = Ref1}}, applied = Index}.

oldest_snapshot(Current, #s{workers = Workers, ask_workers = AskWorkers}) ->
    ProofHeights = [Height || {_Ref, #proof_worker{height = Height}}
                                 <- maps:to_list(Workers)],
    AskHeights = [Height || {_MRef, #ask_worker{height = Height}}
                                <- maps:to_list(AskWorkers)],
    lists:min([Current | ProofHeights ++ AskHeights]).

%% A normal content transaction: OCC re-check the read-set, then apply the diff or reject.
apply_content(#transaction{tx_id = Tx, diff = Diff, read_check = RC}, S) ->
    #est{db = #db{mod = M, ref = R}} = S#s.est,
    case quod_diff:validate(RC, M, R) of
        ok ->
            {ok, Est1} = quod_diff:apply_ops(S#s.est, Diff),
            release(Tx, fun(From, B, H) -> gen_server:reply(From, {ok, B, H}) end,
                    S#s{est = Est1, applies = S#s.applies + 1});
        {conflict, _F} ->
            release(Tx, fun(From, _B, _H) -> gen_server:reply(From, {error, conflict_retry}) end,
                    S#s{rejects = S#s.rejects + 1, conflicts = S#s.conflicts + 1})
    end.

%% A committee-changing tx = its diff asserts/retracts `peer_admitted` (a PURE fold in quod_simplex —
%% no process message, so no append<->apply deadlock).
is_membership_change(Change) -> quod_simplex:committee_delta(Change) =/= {[], []}.

%% Deliver the verdict to a parked caller (only on the submitting node) and cancel
%% its TTL. ReplyFun :: (From, Bindings, Height) -> _.
release(Tx, ReplyFun, S = #s{parked = P}) ->
    case maps:take(Tx, P) of
        {{From, B, H, TRef, ReqId}, P1} ->
            _ = erlang:cancel_timer(TRef),
            ReplyFun(From, B, H),
            S#s{parked = P1, requests = abandon_request(ReqId, S#s.requests)};
        error -> S
    end.

reject_parked(Tx, Reply, S) ->
    release(Tx, fun(From, _Bindings, _Height) -> gen_server:reply(From, Reply) end, S).

abandon_request(none, Requests) ->
    Requests;
abandon_request(ReqId, Requests) ->
    %% A zero-time receive consumes an already-arrived reply or deactivates the alias so
    %% a future reply cannot become an unmatched mailbox message.
    _ = catch gen_statem:receive_response(ReqId, 0),
    drop_request(ReqId, Requests).

drop_request(ReqId, Requests) ->
    lists:foldl(
      fun({ReqId0, Label}, Acc) when ReqId0 =/= ReqId ->
              gen_statem:reqids_add(ReqId0, Label, Acc);
         ({_ReqId0, _Label}, Acc) ->
              Acc
      end, gen_statem:reqids_new(), gen_statem:reqids_to_list(Requests)).

%%%===================================================================
%%% membership verdict (the Prolog-side re-check of a committee change)
%%%===================================================================
%%
%% A validator re-judges a proposed committee change against ITS OWN kb before voting, so a committee
%% is a projection of the `peer_admitted` FACTS on every node — never something a single submitter can
%% forge. The verdict is pinned to the proposal's PARENT height (`Slot-1`): the same past kb state on
%% every honest node ⇒ the same verdict, so honest votes never split. Delivered asynchronously (a cast
%% back), because a synchronous call here would deadlock the append<->apply cycle.

%% A re-issued Tag (a re-proposed slot after a view change) SUPERSEDES any request still parked under it:
%% drop the stale entry and cancel its timer first, so an orphaned timer can never fire against the new
%% request and reap it to a premature abstain. The superseded request's `ReplyTo` hears back via the fresh
%% verdict for the same Tag.
request_verdict(Change, Slot, ReplyTo, Tag, S0) ->
    do_request_verdict(Change, Slot, ReplyTo, Tag, supersede_validation(Tag, S0)).

%% Judge `Change` at height `Slot-1`: answer now if the kb is exactly there, park if it is behind, or
%% abstain if it is already past the slot (which resolved without us — slots are never reused).
do_request_verdict(Change, Slot, ReplyTo, Tag, S = #s{applied = A}) when A =:= Slot - 1 ->
    deliver_verdict(ReplyTo, Tag, membership_verdict(Change, S)), S;
do_request_verdict(Change, Slot, ReplyTo, Tag, S = #s{applied = A, validations = V, vttl = Vttl})
  when A < Slot - 1 ->
    TRef = erlang:send_after(Vttl, self(), {validation_timeout, Tag}),
    S#s{validations = V#{Tag => {Slot, Change, ReplyTo, TRef}}};
do_request_verdict(_Change, _Slot, ReplyTo, Tag, S) ->   %% applied > Slot-1: too late, the slot is decided
    deliver_verdict(ReplyTo, Tag, abstain), S.

supersede_validation(Tag, S = #s{validations = V}) ->
    case maps:take(Tag, V) of
        {{_Slot, _Change, _ReplyTo, OldTRef}, V1} -> _ = erlang:cancel_timer(OldTRef), S#s{validations = V1};
        error                                     -> S
    end.

%% Once the kb reaches a slot, answer every verdict parked for that slot's children (parent == applied).
%% Judged against the just-advanced `est` (state exactly at the parent height). Cancels each timer.
resolve_validations(S = #s{applied = A, validations = V}) ->
    Ready = [{Tag, Rec} || {Tag, {Slot, _, _, _} = Rec} <- maps:to_list(V), Slot =:= A + 1],
    lists:foldl(
      fun({Tag, {_Slot, Change, ReplyTo, TRef}}, Acc) ->
              _ = erlang:cancel_timer(TRef),
              deliver_verdict(ReplyTo, Tag, membership_verdict(Change, Acc)),
              Acc#s{validations = maps:remove(Tag, Acc#s.validations)}
      end, S, Ready).

%% The verdict for the single guaranteed-shape `peer_admitted` op (Slice A's gate ensures exactly one),
%% judged against `S#s.est` (the parent-height kb):
%% - assert: reject a pubkey already admitted (the one-fact-per-pubkey invariant that keeps the KB + the
%%   validator set in lockstep on retract); else re-prove the SAME `can_join` goal `admit_3` staged. A
%%   `can_join` that stages writes is rejected — it must be side-effect-free, or the overlay would ride
%%   its ops into the committed diff network-wide. NB the KB state is pinned to the parent height, but a
%%   `can_join` rule may also read REALITY through a read-only external predicate (`peer_ready`), and
%%   there honest validators MAY split (each judges from its own liveness observations). Intentional and
%%   fail-closed: a support shortfall Δ-skips the slot and the submitter retries — the admit commits only
%%   once quorum-many validators independently observed the candidate ready.
%% - retract: valid only if that exact `peer_admitted` clause is present — a fabricated-address retract
%%   matches nothing, so it can never eject a validator from the set while missing in the KB.
-spec membership_verdict(term(), #s{}) -> valid | {invalid, term()}.
membership_verdict(#transaction{diff = [{assert, {{peer_admitted, Pk, H, P, Pk}, _B}}]},
                   S = #s{ns = Ns, est = Est}) ->
    case lists:member(Pk, quod_committee_predicates:admitted_pubkeys(Est)) of
        true  -> {invalid, already_admitted};
        false -> %% The re-proof runs INLINE in the engine (deterministic, parent-height-pinned)
                 %% with cross-ontology asks DISABLED: a committee vote must never make network
                 %% hops mid-verdict (doc/inter-ontology.md §11) — the ask handler refuses when
                 %% this flag is set.
                 put('$quod_in_verdict', true),
                 R = run_proof({can_join, Ns, [H, P], Pk}, S),
                 erase('$quod_in_verdict'),
                 case R of
                     {ok, _, [], _}    -> valid;
                     {ok, _, _Diff, _} -> {invalid, can_join_side_effects};
                     fail              -> {invalid, can_join};
                     {error, _}        -> {invalid, can_join}
                 end
    end;
membership_verdict(#transaction{diff = [{retract, {{peer_admitted, _Id, _H, _P, _Pk}, _B} = Clause}]},
                   #s{est = #est{db = #db{mod = M, ref = R}}}) ->
    {ClauseHead, ClauseBody} = Clause,
    case quod_diff:has_clause(M, R, ClauseHead, ClauseBody) of
        true  -> valid;
        false -> {invalid, no_such_member}
    end;
membership_verdict(_Change, _S) ->
    {invalid, malformed}.   %% Slice A's gate makes this unreachable in production; kept total for tests/robustness

%% Async delivery to the requesting statem (or a test pid) — a plain message so the statem consumes it
%% as an `info` event and a test just `receive`s the bare tuple.
deliver_verdict(ReplyTo, Tag, Verdict) -> ReplyTo ! {membership_verdict, Tag, Verdict}, ok.

%%%===================================================================
%%% kb construction
%%%===================================================================

-doc """
Build the genesis write-set from a `.pl` file — `terms_to_diff(read_terms(File))`.

Used at create only: the founder reads the root `.pl`, and `quod_simplex` prepends the
founding committee's `peer_admitted/4` facts, compiling both into one genesis
transaction it commits as slot 1. A missing/unparseable file throws `{genesis_failed, _}`,
which `quod_simplex:init/1` turns into `{stop, _}` (fail-fast — a node with no root is
useless).
""".
-spec genesis_diff(file:filename()) -> [op()].
genesis_diff(File) -> terms_to_diff(read_terms(File)).

-doc """
Compile a list of Prolog terms (facts or rules) into a write-set of `op()`.

Turns each term into a write-set `op()` in the SAME compiled form the live write path
produces — so it commits and replays through the normal apply path. erlog's `assertz`
compiles the body (`well_form_body`, yielding `{Body, HasCut}`); we capture the result
with the `m:quod_erlog_db_local_prove` overlay, exactly as `run_proof/2` does for a live
write. Hand-building `{Head, true}` would store a malformed clause and crash on the first
prove — the body must be the compiled form, not raw `true`. Used to build the genesis
transaction (the committee's `peer_admitted` facts + the root content).
""".
-spec terms_to_diff([term()]) -> [op()].
terms_to_diff(Terms) ->
    Base = build_kb(),
    W0 = quod_erlog_db_local_prove:wrap_state(Base, #{read_set => false}),
    try
        WN = lists:foldl(
               fun(T, W) ->
                   case erlog_int:prove_goal({assertz, T}, W) of
                       {succeed, W1} -> W1;
                       Other         -> throw({genesis_failed, {assert, T, Other}})
                   end
               end, W0, Terms),
        quod_erlog_db_local_prove:get_local_changes((WN#est.db)#db.ref)
    after
        quod_erlog_db_local_prove:cleanup_read_set(W0),
        #est{db = #db{ref = Ref}} = Base,
        quod_erlog_db_mvcc:delete(Ref)
    end.

-doc "Parse a `.pl` file into a list of Prolog terms; a missing/unparseable file throws `{genesis_failed, _}`.".
-spec read_terms(file:filename()) -> [term()].
read_terms(File) ->
    Res = try erlog_io:read_file(File) catch C0:E0 -> {caught, C0, E0} end,
    case Res of
        {ok, Terms}     -> Terms;
        {error, Reason} -> throw({genesis_failed, {read_file, File, Reason}});
        {caught, C, E}  -> throw({genesis_failed, {parse, File, {C, E}}})
    end.

build_kb() ->
    %% erlog:new/2 loads bips + lists + dcg; #est{} is element 3 of #erlog{vs, est}.
    %% The MVCC database keeps the full KB once in an unnamed ETS table. Proof workers
    %% receive only its table/height handle; interpreted predicate versions give each
    %% worker a stable frozen view while commits continue.
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Est0 = element(3, Erl),
    %% unknown predicate => fail (not error): a goal over an undefined predicate just
    %% has no solution, rather than crashing.
    {succeed, Est1} = erlog_int:prove_goal({set_prolog_flag, unknown, fail}, Est0),
    %% register the external Erlang predicates: admit/remove (the committee interface)
    %% and `::` (the cross-ontology ask, doc/inter-ontology.md).
    Est2 = quod_committee_predicates:load(Est1),
    quod_ask:load(Est2).

tx_id(Self) -> <<(erlang:phash2(Self)):32, (erlang:unique_integer([positive])):64>>.
