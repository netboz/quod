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
  or reject — identical verdict on every member.

Proves are gated until an initial **rebuild** completes (`ready`), so a freshly
(re)started engine never answers from a half-built kb. The kb is built with the
erlog flag `unknown = fail`. See `doc/ordering-layer-spec.md` §4.
""".
-behaviour(gen_server).
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-export([start_link/2, prove/3, prove_ro/3, applied/1, apply_block/3, mark_ready/1, sync/1,
         stats/1, namespaces/0]).
-export([genesis_diff/1, read_terms/1, terms_to_diff/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULTS, #{node_id => undefined, park_ttl_ms => 30000}).

-record(s, {ns        :: binary(),
            self      :: node_id(),
            est       :: tuple(),                 %% committed erlog #est{} (unknown=fail)
            ready     = false :: boolean(),       %% true once the initial rebuild has run
            ttl       = 30000 :: pos_integer(),
            applied   = 0  :: log_index(),
            %% tx_id => {From, Bindings, HeightRead, TimerRef}
            parked    = #{} :: #{binary() => {gen_server:from(), [map()], log_index(), reference()}},
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
Apply a committed entry (called by `quod_simplex`, strictly in index order). **Async (cast)
on purpose:** `quod_simplex` calls this while it may itself be the target of a synchronous
`quod_simplex:append` from this very process (the write path). A synchronous `apply_block`
would close that call cycle into a deadlock (each waits on the other). As a cast,
`quod_simplex` never blocks on us, so it stays free to service `append`. The OCC verdict is
delivered straight to the parked client here; a forward gap asks `quod_simplex` to re-drive.
""".
-spec apply_block(binary(), pos_integer(), #transaction{} | noop) -> ok.
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

stats(Ns) ->
    try gen_server:call(quod_reg:via({quod_prolog, Ns}), get_stats, 1000)
    catch exit:_ -> #{} end.

namespaces() -> gproc:select([{{{n, l, {quod_prolog, '$1'}}, '_', '_'}, [], ['$1']}]).

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    Cfg  = maps:merge(?DEFAULTS, Config),
    put('$quod_ns', Ns),   %% so external predicates (e.g. admit) can recover their namespace in-process
    S = #s{ns = Ns, self = maps:get(node_id, Cfg), est = build_kb(),
           ttl = maps:get(park_ttl_ms, Cfg), ready = false},
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
handle_cast(_Msg, S)       -> {noreply, S}.

%% A parked write whose verdict never arrived (leader change / lost block): reap it
%% so the caller gets a definite answer instead of hanging.
handle_info({park_timeout, Tx}, S = #s{parked = P}) ->
    case maps:take(Tx, P) of
        {{From, _B, _H, _TRef}, P1} ->
            gen_server:reply(From, {error, timeout}),
            {noreply, S#s{parked = P1, park_timeouts = S#s.park_timeouts + 1}};
        error -> {noreply, S}
    end;
handle_info(_Info, S) -> {noreply, S}.

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

%% MVP: only own-namespace writes. Park the caller (with a TTL), then submit to
%% quod_simplex; the verdict is delivered via apply_block (correlated by tx_id) or the
%% TTL fires. Only a *definite* not-leader rejection unparks immediately — a submit
%% timeout is ambiguous (the block may still commit), so we keep the caller parked.
submit_write(From, Bindings, Diff, ReadSet, CallerNs, S = #s{ns = Ns}) when CallerNs =:= Ns ->
    Tx     = tx_id(S#s.self),
    Change = #transaction{tx_id = Tx, caller_ns = CallerNs, diff = Diff,
                     read_check = ReadSet, author = S#s.self,
                     submitted_at = quod_time:now_ms(), sig = none},
    TRef   = erlang:send_after(S#s.ttl, self(), {park_timeout, Tx}),
    S1     = S#s{parked = (S#s.parked)#{Tx => {From, [Bindings], S#s.applied, TRef}}},
    case quod_simplex:append(Ns, Change) of
        {ok, _Index}                        -> {noreply, S1};
        {error, not_in_charge, unavailable} -> {noreply, S1};   %% ambiguous — TTL/apply resolves
        {error, not_in_charge, Hint}        -> {reply, {error, {not_leader, Hint}}, unpark(Tx, S1)};
        {error, skipped}                    -> {reply, {error, retry}, unpark(Tx, S1)};   %% our slot was skipped: retry
        {error, Reason}                     -> {reply, {error, Reason}, unpark(Tx, S1)}    %% busy (backpressure) |
                                               %% bad_change (consensus gate rejected the shape/floor — not
                                               %% retryable as-is) | any future flat error: report as-is, no nesting
    end;
submit_write(_From, _B, _D, _R, _CallerNs, S) ->
    {reply, {error, foreign_write_unsupported}, S}.

%%%===================================================================
%%% apply (deterministic; identical on every member)
%%%===================================================================

%% Each clause returns the new #s{}. Index is the committed entry's log index; entries
%% arrive in order on the (FIFO) cast channel from quod_simplex.
%%
%% Already applied (e.g. a rebuild re-drive): idempotent no-op.
apply_committed(Index, _Change, S = #s{applied = A}) when Index =< A ->
    S;
%% Forward gap: quod_simplex is ahead of us (we restarted, or missed a cast). Don't apply out
%% of order — ask quod_simplex to re-drive from the snapshot so we receive a contiguous run.
apply_committed(Index, _Change, S = #s{ns = Ns, applied = A}) when Index > A + 1 ->
    _ = try quod_simplex:rebuild(Ns) catch _:_ -> ok end,
    S;
apply_committed(Index, noop, S) ->                          %% Index == applied+1
    S#s{applied = Index};
apply_committed(Index, #transaction{tx_id = Tx, diff = Diff, read_check = RC}, S) ->
    #est{db = #db{mod = M, ref = R}} = S#s.est,
    case quod_diff:validate(RC, M, R) of
        ok ->
            {ok, Est1} = quod_diff:apply_ops(S#s.est, Diff),
            release(Tx, fun(From, B, H) -> gen_server:reply(From, {ok, B, H}) end,
                    S#s{est = Est1, applied = Index, applies = S#s.applies + 1});
        {conflict, _F} ->
            release(Tx, fun(From, _B, _H) -> gen_server:reply(From, {error, conflict_retry}) end,
                    S#s{applied = Index, rejects = S#s.rejects + 1, conflicts = S#s.conflicts + 1})
    end;
%% Defensive: a committed payload that is neither `noop` nor a `#transaction` (e.g. a stale-format entry on
%% a cross-version replay) advances the cursor + logs, rather than function_clause-crashing the apply loop
%% into a restart crash-loop on the same entry.
apply_committed(Index, Other, S = #s{ns = Ns}) ->
    logger:warning("quod_prolog[~s]: skipping unexpected committed payload at ~p: ~0p", [Ns, Index, Other]),
    S#s{applied = Index}.

%% Deliver the verdict to a parked caller (only on the submitting node) and cancel
%% its TTL. ReplyFun :: (From, Bindings, Height) -> _.
release(Tx, ReplyFun, S = #s{parked = P}) ->
    case maps:take(Tx, P) of
        {{From, B, H, TRef}, P1} ->
            _ = erlang:cancel_timer(TRef),
            ReplyFun(From, B, H),
            S#s{parked = P1};
        error -> S
    end.

unpark(Tx, S = #s{parked = P}) ->
    case maps:take(Tx, P) of
        {{_From, _B, _H, TRef}, P1} -> _ = erlang:cancel_timer(TRef), S#s{parked = P1};
        error                       -> S
    end.

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
