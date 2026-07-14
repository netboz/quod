-module(quod_prolog).
-moduledoc """
Per-namespace fact engine: owns the committed erlog knowledge base for one
ontology, serves `prove/3`, and applies committed blocks from `quod_simplex` in log
order. One `gen_server` per namespace.

- **Reads** run on a copy-on-write overlay (`m:quod_erlog_db_local_prove`) so the
  committed kb is never touched; the answer is bindings, returned to the caller.
- **Writes** (a proof that staged asserts/retracts) become a `#transaction{}` submitted
  to `quod_simplex`; the caller is parked and replied to when the block applies (or
  reaped by a per-tx TTL if the verdict never arrives).
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
-define(DEFAULTS, #{node_id => undefined, park_ttl_ms => 30000, validation_ttl_ms => 2000}).

-record(s, {ns        :: binary(),
            self      :: node_id(),
            est       :: tuple(),                 %% committed erlog #est{} (unknown=fail)
            ready     = false :: boolean(),       %% true once the initial rebuild has run
            ttl       = 30000 :: pos_integer(),
            vttl      = 2000 :: pos_integer(),    %% membership-verdict park budget (ms)
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
            park_timeouts = 0 :: non_neg_integer()}).   %% parked writes reaped by TTL (verdict never arrived)

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
        Pid -> try gen_server:call(Pid, {prove, Goal, CallerNs}, 35000)
               catch exit:_ -> fail end
    end.

-doc "Read-only prove: like `prove/3` but a write goal is refused (`{error, read_only}`).".
-spec prove_ro(binary(), term(), binary()) ->
        {ok, [map()], log_index()} | {error, term()} | fail.
prove_ro(TargetNs, Goal, CallerNs) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Pid -> try gen_server:call(Pid, {prove_ro, Goal, CallerNs}, 35000)
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

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    Cfg  = maps:merge(?DEFAULTS, Config),
    put('$quod_ns', Ns),        %% so external predicates (e.g. admit) can recover their namespace in-process
    put('$quod_applied', 0),    %% ... and the applied height (peer_ready's slack judge; kept current below)
    S = #s{ns = Ns, self = maps:get(node_id, Cfg), est = build_kb(),
           requests = gen_statem:reqids_new(),
           ttl = maps:get(park_ttl_ms, Cfg), vttl = maps:get(validation_ttl_ms, Cfg), ready = false},
    %% Ask quod_simplex (already up under the per-ns sub-sup) to replay committed blocks
    %% into this fresh kb; it casts mark_ready when the kb is caught up. Async, so
    %% init does not block on a callback.
    case quod_reg:where({quod_simplex, Ns}) of
        undefined -> ok;
        _Pid      -> catch quod_simplex:rebuild(Ns)
    end,
    {ok, S}.

%% Proves are refused until the rebuild has caught the kb up (never a half-built read).
handle_call({prove, _G, _C}, _From, S = #s{ready = false}) ->
    {reply, {error, rebuilding}, S};
handle_call({prove, Goal, CallerNs}, From, S) ->
    case run_proof(Goal, S) of
        fail            -> {reply, fail, bump_proves(S)};
        {error, _} = E  -> {reply, E, bump_proves(S)};
        {ok, Bindings, [], _ReadSet} ->                    %% a read — nothing committed
            {reply, {ok, [Bindings], S#s.applied}, bump_proves(S)};
        {ok, Bindings, Diff, ReadSet} ->                   %% a write
            submit_write(From, Bindings, Diff, ReadSet, CallerNs, S)
    end;
%% Read-only prove (the remote-read path): identical to a read, but a goal that stages a WRITE
%% is REFUSED ({error, read_only}) instead of submitted — a remote reader can never write through
%% a Member's responder. Reads carry the committed height they were proved at (the freshness
%% contract). Gated on readiness like {prove}.
handle_call({prove_ro, _G, _C}, _From, S = #s{ready = false}) ->
    {reply, {error, rebuilding}, S};
handle_call({prove_ro, Goal, _CallerNs}, _From, S) ->
    case run_proof(Goal, S) of
        fail                         -> {reply, fail, bump_proves(S)};
        {error, _} = E               -> {reply, E, bump_proves(S)};
        {ok, Bindings, [], _ReadSet} -> {reply, {ok, [Bindings], S#s.applied}, bump_proves(S)};
        {ok, _Bindings, _Diff, _RS}  -> {reply, {error, read_only}, bump_proves(S)}
    end;

handle_call(get_stats, _From, S) ->
    {reply, #{applied   => S#s.applied,  applies => S#s.applies,
              rejects   => S#s.rejects,  proves  => S#s.proves,
              conflicts => S#s.conflicts,
              parked    => map_size(S#s.parked),        %% in-flight writes awaiting commit (liveness gauge)
              park_timeouts => S#s.park_timeouts}, S};  %% writes that never committed (reaped)

handle_call(sync, _From, S) -> {reply, ok, S};   %% replay backpressure barrier (sync/1)

handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast({apply_block, Index, Change}, S) ->
    {noreply, apply_committed(Index, Change, S)};
handle_cast(mark_ready, S) -> {noreply, S#s{ready = true}};
%% A membership-verdict request (request_membership_verdict/5): judge it against the KB at the
%% proposal's parent height (Slot-1), delivering now or parking until the kb catches up.
handle_cast({membership_verdict_req, Change, Slot, ReplyTo, Tag}, S) ->
    {noreply, request_verdict(Change, Slot, ReplyTo, Tag, S)};
handle_cast(_Msg, S)       -> {noreply, S}.

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
handle_info(Info, S = #s{requests = Requests}) ->
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

terminate(_Reason, _S) -> ok.

%%%===================================================================
%%% proof execution (inline; copy-on-write overlay)
%%%===================================================================

run_proof(Goal, #s{est = Est}) ->
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

bump_proves(S) -> S#s{proves = S#s.proves + 1}.

%% Only own-namespace writes. Submit with OTP's asynchronous gen_statem request API,
%% then park the caller until ordered apply (or a definite consensus rejection). This
%% keeps the KB free to prove and apply while consensus runs, without spawning one
%% blocked helper process for every write.
submit_write(From, Bindings, Diff, ReadSet, CallerNs, S = #s{ns = Ns}) when CallerNs =:= Ns ->
    Tx     = tx_id(S#s.self),
    Change = #transaction{tx_id = Tx, caller_ns = CallerNs, diff = Diff,
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
submit_write(_From, _B, _D, _R, _CallerNs, S) ->
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
    S#s{applied = Index};
apply_step(Index, {batch, _} = Batch, S) ->
    case quod_ledger:payload(Batch) of
        {ok, Transactions} ->
            S1 = lists:foldl(fun apply_transaction/2, S, Transactions),
            S1#s{applied = Index};
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
    S#s{applied = Index}.

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
        false -> case run_proof({can_join, Ns, [H, P], Pk}, S) of
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
    W0 = quod_erlog_db_local_prove:wrap_state(build_kb(), #{read_set => false}),
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
        quod_erlog_db_local_prove:cleanup_read_set(W0)
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
    %% erlog_db_dict (functional) avoids a per-namespace named ETS table / global atom
    %% (review #10); the committed db is threaded through #s.est.
    {ok, Erl} = erlog:new(erlog_db_dict, null),
    Est0 = element(3, Erl),
    %% unknown predicate => fail (not error): a goal over an undefined predicate just
    %% has no solution, rather than crashing.
    {succeed, Est1} = erlog_int:prove_goal({set_prolog_flag, unknown, fail}, Est0),
    %% register the external Erlang predicates (admit/remove — the committee interface).
    quod_committee_predicates:load(Est1).

tx_id(Self) -> <<(erlang:phash2(Self)):32, (erlang:unique_integer([positive])):64>>.
