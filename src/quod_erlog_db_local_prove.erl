-module(quod_erlog_db_local_prove).
-moduledoc """
A **staging overlay** for the erlog database, used to run a proof against the
committed knowledge base without touching it.

Wrap a committed erlog state with `wrap_state/1,2`, run the goal, then extract:

- `get_local_changes/1` — the **write-set**: the asserts/retracts the proof made,
  as content-only `op()`s.
- `get_read_set/1` — the **read-set**: one mutation-version token per
  `{Functor, Arity}` the proof read from the committed db (for the apply-time
  OCC re-check).

Asserts/retracts are shadowed per functor; reads merge `asserta ++ committed ++
assertz`. The committed db (`out_db`) is read-only throughout. This is a slimmed
port of bbsvx's `bbsvx_erlog_db_local_prove` (federation/ACL/provenance dropped).

Ported against erlog's `#est{}`/`#db{}` (see `erlog_int.hrl`); read-set capture
records `quod_erlog_db_mvcc:version_token/2` — the same function `quod_diff`'s
apply-time validator resolves — so producer and validator agree bit-for-bit.
""".
-include_lib("erlog/src/erlog_int.hrl").

%% erlog db callbacks
-export([new/1, add_built_in/2, add_compiled_proc/4,
         asserta_clause/4, assertz_clause/4, retract_clause/3, abolish_clauses/2,
         get_procedure/2, get_procedure_type/2, get_interpreted_functors/1,
         choicepoint_checkpoint/1, choicepoint_restore/2]).
%% overlay API
-export([wrap_state/1, wrap_state/2, access_guard/1, check_access/1,
         proof_context/1, fresh_proof_state/1,
         revision/1, replace_revision/2,
         live_transaction_tokens/1,
         committed_state/1, checkpoint/1, restore/2,
         enter_read_only/1, leave_read_only/2,
         get_local_changes/1, get_read_set/1, get_dependencies/1,
         get_live_bridges/1, record_live_bridge/2, absorb_read_set/2,
         absorb_live_bridges/2, get_effects/1,
         register_action_request/3, action_request/3,
         put_prepared_effect/5, prepared_effect/2,
         staged_desired_state/2,
         cleanup_read_set/1]).
-export_type([access_guard/0, revision/0, checkpoint/0, read_only_frame/0]).

-type access_guard() ::
        unguarded |
        {quod_proof_access, binary(), non_neg_integer()}.

-record(fstate, {abolished = false :: boolean(),
                 asserta   = []    :: [{integer(), term(), term()}],
                 assertz_rev = []  :: [{integer(), term(), term()}],
                 retracted = #{}   :: #{integer() => {term(), term()}}}).

-record(lp, {out_db   :: #db{},
             scope_id = undefined :: reference() | undefined,
             local    = #{}      :: #{term() => #fstate{}},
             effects = []       :: [quod_effect:effect()],
             next_tag = 1000000  :: integer(),   %% above any committed-db tag
             read_ets = undefined :: ets:tid() | undefined,
             %% Read-time link following is disabled inside a committee membership verdict
             %% (a vote must never make network hops). Snapshotted from the `#est{}`'s
             %% execution context at wrap time — the db callback layer cannot see `#est.fs`,
             %% so the flag is carried here rather than read per-lookup.
             follow_disabled = false :: boolean(),
             %% Opaque requests allocated by governed public staging bridges.
             %% The handles never enter ontology content or durable material;
             %% only the matching internal continuation can consume one.
             action_requests = #{} :: map(),
             %% Private preparation for effects which survived the current
             %% rollback-safe revision. The public descriptor is separately
             %% present in `effects`; journal custody starts only at handoff.
             prepared_effects = #{} :: map(),
             %% Worker-owned distributed-proof state. It must never enter the
             %% Prolog-visible flag store.
             proof_context = undefined :: term(),
             %% Immutable generation-bound access authority acquired from the
             %% namespace's consensus projection. The overlay understands no
             %% lock policy: it only revalidates this opaque data token through
             %% quod_simplex at every externally-visible database operation.
             access_guard = unguarded :: access_guard(),
             %% Policy sub-proofs must reject the first attempted mutation,
             %% including changes whose eventual net diff would be empty.
             read_only = false :: boolean()}).

%% Both tokens retain immutable terms already owned by the overlay. Creating or
%% restoring one therefore copies no clause data. The identity fields prevent a
%% savepoint or mode frame from being applied to another proof's overlay.
-type distributed_token() :: {batch, <<_:128>>} | {pending, <<_:128>>}.
-record(checkpoint, {scope_id :: reference(),
                     local    :: #{term() => #fstate{}},
                     effects = [] :: [quod_effect:effect()],
                     prepared_effects = #{} :: map(),
                     next_tag :: integer(),
                     distributed = [] :: [distributed_token()]}).
-opaque checkpoint() :: #checkpoint{}.

%% An immutable overlay revision. It shares the committed database and read-set
%% table; taking or installing one copies no clause data.
-record(revision, {scope_id :: reference(),
                   overlay  :: #lp{}}).
-opaque revision() :: #revision{}.

-record(read_only_frame, {scope_id      :: reference(),
                          read_only     :: boolean(),
                          assert_hooks  :: map(),
                          retract_hooks :: map()}).
-opaque read_only_frame() :: #read_only_frame{}.

%%%===================================================================
%%% wrapping + extraction
%%%===================================================================

-doc "Wrap a committed `#est{}` so a proof stages onto a private overlay.".
-spec wrap_state(tuple()) -> tuple().
wrap_state(#est{db = #db{mod = OutMod, ref = OutRef,
                         assert_hooks = AH, retract_hooks = RH} = OutDb} = St) ->
    Overlay = (new({OutRef, OutMod}))#lp{
                out_db = OutDb,
                follow_disabled = quod_predicates:local_only(St)},
    St#est{db = #db{mod = ?MODULE, ref = Overlay, loc = [],
                    assert_hooks = AH, retract_hooks = RH}}.

-doc """
As `wrap_state/1`, with private overlay options:

- `read_set => true` tracks the committed read-set;
- `proof_context => Context` carries worker-owned proof/session authority;
- `access_guard => Guard` carries the immutable namespace access generation;
- `read_only => true` rejects every interpreted database mutation.
""".
-spec wrap_state(tuple(), map()) -> tuple().
wrap_state(St, Opts) ->
    #est{db = #db{ref = Ov} = Db} = Wrapped = wrap_state(St),
    ReadOnly = boolean_option(read_only, Opts),
    ProofContext = maps:get(proof_context, Opts, undefined),
    AccessGuard = access_guard_option(Opts),
    Ov1 = Ov#lp{proof_context = ProofContext,
                access_guard = AccessGuard,
                read_only = ReadOnly},
    Ov2 =
        case maps:get(read_set, Opts, false) of
            true  ->
                %% Read-set capture records exact MVCC version tokens over a
                %% PUBLISHED snapshot; no other committed store has a version
                %% history to token, and a mid-apply handle would capture the
                %% uncapturable `staged` sentinel. Fail here with a named
                %% reason, not undef or a poisoned read set mid-proof.
                case Ov1#lp.out_db of
                    #db{mod = quod_erlog_db_mvcc, ref = OutRef} ->
                        quod_erlog_db_mvcc:published(OutRef)
                            orelse erlang:error(
                                     read_set_over_unpublished_snapshot);
                    #db{mod = OtherMod} ->
                        erlang:error({read_set_requires_mvcc, OtherMod})
                end,
                Ets = ets:new(quod_read_set, [set, private]),
                Ov1#lp{read_ets = Ets};
            false -> Ov1
        end,
    %% Erlog invokes clause hooks before database callbacks. A strict read-only
    %% overlay therefore removes mutation hooks so every attempt reaches the
    %% rejecting callbacks below. Ordinary overlays retain the hooks unchanged.
    Db1 = case ReadOnly of
              true  -> Db#db{assert_hooks = #{}, retract_hooks = #{}};
              false -> Db
          end,
    Wrapped#est{db = Db1#db{ref = Ov2}}.

-doc "Return the immutable proof-access guard carried by a wrapped state.".
-spec access_guard(tuple()) -> access_guard().
access_guard(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{access_guard = AccessGuard}}}) ->
    AccessGuard;
access_guard(_St) ->
    erlang:error(badarg).

-doc "Revalidate a wrapped state or overlay against its namespace access generation.".
-spec check_access(tuple() | #lp{}) -> ok | {error, term()}.
check_access(#est{db = #db{mod = ?MODULE, ref = Ov}}) ->
    check_access(Ov);
check_access(#lp{access_guard = unguarded}) ->
    ok;
check_access(
  #lp{access_guard = {quod_proof_access, _Ns, _Generation} = AccessGuard}) ->
    quod_simplex:check_proof_access(AccessGuard);
check_access(_State) ->
    {error, invalid_proof_access}.

-doc "Allocate one proof-local opaque handle for a governed action request.".
-spec register_action_request(tuple(), term(), term()) -> {reference(), tuple()}.
register_action_request(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{action_requests = Requests} = Ov} = Db} = St,
  Action, Structural) ->
    ensure_access(Ov),
    Handle = make_ref(),
    {Handle,
     St#est{db = Db#db{ref = Ov#lp{
         action_requests = Requests#{Handle => {Action, Structural}}}}}};
register_action_request(_St, _Action, _Structural) ->
    erlang:error(badarg).

-doc "Resolve only the exact action bound to a proof-local opaque handle.".
-spec action_request(tuple(), reference(), term()) -> {ok, term()} | error.
action_request(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{action_requests = Requests} = Ov}},
  Handle, Action) when is_reference(Handle) ->
    ensure_access(Ov),
    case maps:get(Handle, Requests, undefined) of
        {Action, Structural} -> {ok, Structural};
        _ -> error
    end;
action_request(_St, _Handle, _Action) -> error.

-doc "Stage one public effect and its private preparation in the same revision.".
-spec put_prepared_effect(tuple(), term(), term(), quod_effect:effect(), term()) ->
          tuple().
put_prepared_effect(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{effects = Effects,
                          prepared_effects = Prepared0} = Ov} = Db} = St,
  Action, Desired, Effect, Prepared) ->
    ensure_access(Ov),
    Candidate = Effects ++ [Effect],
    case quod_effect:validate_list(Candidate) of
        true ->
            EffectId = quod_effect:effect_id(Effect),
            Row = {Action, Desired, Effect, Prepared},
            St#est{db = Db#db{ref = Ov#lp{
                effects = Candidate,
                prepared_effects = Prepared0#{EffectId => Row}}}};
        false -> erlang:error(invalid_direct_effect)
    end;
put_prepared_effect(_St, _Action, _Desired, _Effect, _Prepared) ->
    erlang:error(badarg).

-doc "Return private preparation only for this revision's exact active effect.".
-spec prepared_effect(tuple(), quod_effect:effect()) ->
          {ok, {term(), term(), quod_effect:effect(), term()}} | error.
prepared_effect(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{effects = Effects,
                          prepared_effects = Prepared} = Ov}}, Effect) ->
    ensure_access(Ov),
    EffectId = quod_effect:effect_id(Effect),
    case {lists:member(Effect, Effects), maps:get(EffectId, Prepared, undefined)} of
        {true, {_Action, _Desired, Effect, _Private} = Row} -> {ok, Row};
        _ -> error
    end;
prepared_effect(_St, _Effect) -> error.

-doc "Whether this rollback-safe revision contains an exact active effect promising the desired state.".
-spec staged_desired_state(tuple(), term()) -> boolean().
staged_desired_state(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{effects = Effects,
                          prepared_effects = Prepared} = Ov}}, Desired) ->
    ensure_access(Ov),
    lists:any(
      fun(Effect) ->
          EffectId = quod_effect:effect_id(Effect),
          case maps:get(EffectId, Prepared, undefined) of
              {_Action, Desired, Effect, _Private} -> true;
              _ -> false
          end
      end, Effects);
staged_desired_state(_St, _Desired) -> false.

-doc "Return the worker-owned proof context carried by a wrapped state.".
-spec proof_context(tuple()) -> {ok, term()} | undefined.
proof_context(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{proof_context = Context}}})
  when Context =/= undefined ->
    {ok, Context};
proof_context(_) ->
    undefined.

-doc "Reset interpreter-local proof data while retaining the current overlay revision.".
-spec fresh_proof_state(tuple()) -> tuple().
fresh_proof_state(
  #est{db = #db{mod = ?MODULE} = Db} = St) ->
    St#est{cps = [], bs = erlog_int:new_bindings(), vn = 0,
           db = Db#db{loc = []},
           fail_reasons = [], fail_reason_count = 0,
           fail_reasons_truncated = false, fail_boundaries = 0,
           checkpoint_depth = 0};
fresh_proof_state(_St) ->
    erlang:error(badarg).

-doc "Capture the current immutable overlay revision in O(1).".
-spec revision(tuple()) -> revision().
revision(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{scope_id = ScopeId} = Overlay}}) ->
    #revision{scope_id = ScopeId, overlay = Overlay};
revision(_St) ->
    erlang:error(badarg).

-doc "Replace only a proof frame's overlay revision, retaining its continuation and context.".
-spec replace_revision(tuple(), revision()) -> tuple().
replace_revision(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{scope_id = ScopeId,
                          access_guard = AccessGuard}} = Db} = St,
  #revision{scope_id = ScopeId,
            overlay = #lp{access_guard = AccessGuard} = Overlay}) ->
    St#est{db = Db#db{ref = Overlay}};
replace_revision(_St, _Revision) ->
    erlang:error(badarg).

-doc "Return transaction tokens retained by the invocation's live choice points.".
-spec live_transaction_tokens(tuple()) -> [distributed_token()].
live_transaction_tokens(#est{cps = Choicepoints}) ->
    lists:usort(live_transaction_tokens(Choicepoints, []));
live_transaction_tokens(_St) ->
    erlang:error(badarg).

live_transaction_tokens(
  [#cp{db_checkpoint = {_Depth,
                        #checkpoint{distributed = Tokens}}} | Rest], Acc) ->
    live_transaction_tokens(Rest, lists:reverse(Tokens, Acc));
live_transaction_tokens([_ | Rest], Acc) ->
    live_transaction_tokens(Rest, Acc);
live_transaction_tokens([], Acc) ->
    Acc.

-doc """
Return a fresh proof frame over a wrapped state's captured committed view.

Bindings, choice points, and failure diagnostics belong to the caller's proof
and are reset; the execution-context flags are retained for the isolated
sub-proof.
""".
-spec committed_state(tuple()) -> tuple().
committed_state(
  #est{db = #db{mod = ?MODULE, ref = #lp{out_db = OutDb}}} = St) ->
    ensure_access(St),
    St#est{cps = [], bs = erlog_int:new_bindings(), vn = 0, db = OutDb,
           fail_reasons = [], fail_reason_count = 0,
           fail_reasons_truncated = false, fail_boundaries = 0,
           checkpoint_depth = 0}.

-doc "Capture the wrapped overlay's staged writes and assertion-order cursor in O(1).".
-spec checkpoint(tuple()) -> checkpoint().
checkpoint(
  #est{db = #db{mod = ?MODULE, ref = Ov}}) ->
    ensure_access(Ov),
    choicepoint_checkpoint(Ov).

-doc "Restore staged writes from a checkpoint while retaining monotonic proof reads.".
-spec restore(tuple(), checkpoint()) -> tuple().
restore(
  #est{db = #db{mod = ?MODULE, ref = Ov} = Db} = St,
  #checkpoint{} = Checkpoint) ->
    ensure_access(Ov),
    %% `read_ets` deliberately comes from the current overlay. It is the same
    %% table named by the token and contains the union of every read performed
    %% since the checkpoint, including reads in discarded alternatives.
    St#est{db = Db#db{ref = choicepoint_restore(Ov, Checkpoint)}};
restore(_St, _Checkpoint) ->
    erlang:error(badarg).

-doc "Enter a nestable strict read-only frame on the current staged overlay.".
-spec enter_read_only(tuple()) -> {read_only_frame(), tuple()}.
enter_read_only(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{scope_id = ScopeId,
                          read_only = ReadOnly} = Ov,
                assert_hooks = AssertHooks,
                retract_hooks = RetractHooks} = Db} = St) ->
    ensure_access(Ov),
    Frame = #read_only_frame{scope_id = ScopeId,
                             read_only = ReadOnly,
                             assert_hooks = AssertHooks,
                             retract_hooks = RetractHooks},
    {Frame,
     St#est{db = Db#db{ref = Ov#lp{read_only = true},
                       assert_hooks = #{}, retract_hooks = #{}}}}.

-doc "Leave a read-only frame without replacing its staged view or accumulated reads.".
-spec leave_read_only(tuple(), read_only_frame()) -> tuple().
leave_read_only(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{scope_id = ScopeId} = Ov} = Db} = St,
  #read_only_frame{scope_id = ScopeId,
                   read_only = ReadOnly,
                   assert_hooks = AssertHooks,
                   retract_hooks = RetractHooks}) ->
    ensure_access(Ov),
    St#est{db = Db#db{ref = Ov#lp{read_only = ReadOnly},
                      assert_hooks = AssertHooks,
                      retract_hooks = RetractHooks}};
leave_read_only(_St, _Frame) ->
    erlang:error(badarg).

-doc "The write-set: the proof's asserts/retracts as content-only ops.".
-spec get_local_changes(#lp{}) -> [{assert | retract, {term(), term()}}].
get_local_changes(
  #lp{local = Local, out_db = #db{mod = M, ref = R}} = Ov) ->
    ensure_access(Ov),
    maps:fold(fun(F, FS, Acc) -> functor_ops(F, FS, M, R) ++ Acc end, [], Local).

-doc "The rollback-safe direct effects staged in this overlay revision.".
-spec get_effects(#lp{}) -> [quod_effect:effect()].
get_effects(#lp{effects = Effects} = Ov) ->
    ensure_access(Ov),
    Effects.

functor_ops(F, #fstate{abolished = Ab, asserta = A, assertz_rev = ZR,
                       retracted = Ret}, M, R) ->
    Retracts = case Ab of
                   true  -> [{retract, {H, B}} || {_T, H, B} <- committed_clauses(M, R, F)];
                   false -> [{retract, {H, B}} || {_Tag, {H, B}} <- maps:to_list(Ret)]
               end,
    Asserts = [{assert, {H, B}} || {_T, H, B} <- A ++ lists:reverse(ZR)],
    Retracts ++ Asserts.

-doc "The read-set: `#{ {Functor,Arity} => version-token }` of what the proof read.".
-spec get_read_set(#lp{}) -> map().
get_read_set(#lp{read_ets = ReadEts} = Ov) ->
    ensure_access(Ov),
    read_set(ReadEts).

read_set(undefined) -> #{};
read_set(Ets) ->
    maps:from_list(
      [Entry || {{_Name, Arity}, _Token} = Entry <- ets:tab2list(Ets),
                is_integer(Arity)]).

-doc """
Every recorded dependency — OCC read tokens **and** live-bridge markers — as
one map, for absorbing a policy sub-proof's influence into its parent overlay.
""".
-spec get_dependencies(#lp{}) -> map().
get_dependencies(#lp{read_ets = ReadEts} = Ov) ->
    ensure_access(Ov),
    dependencies(ReadEts).

dependencies(undefined) -> #{};
dependencies(Ets) -> maps:from_list(ets:tab2list(Ets)).

-doc "The live reality-bridge predicates this proof consulted, sorted.".
-spec get_live_bridges(#lp{}) -> [{atom(), arity()}].
get_live_bridges(#lp{read_ets = ReadEts} = Ov) ->
    ensure_access(Ov),
    live_bridges(ReadEts).

live_bridges(undefined) -> [];
live_bridges(Ets) ->
    lists:sort(
      [Functor || {{'$quod_live_bridge', Functor}, true}
                      <- ets:tab2list(Ets)]).

-doc """
Record that the proof consulted a live reality bridge (a query-class external
predicate reading non-replicated node state).

The marker shares the read-set table's lifecycle deliberately: it is monotonic
across savepoint restores — a discarded alternative still consulted the bridge
— and `absorb_read_set/2` carries it from a policy sub-proof into the parent
overlay unchanged. The marker key's second element is a functor tuple, so it
can never collide with an OCC entry, whose key is `{Name, Arity}`.
""".
-spec record_live_bridge(tuple(), {atom(), arity()}) -> ok.
record_live_bridge(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{read_ets = Ets} = Ov}}, Functor)
  when Ets =/= undefined ->
    ensure_access(Ov),
    _ = ets:insert_new(Ets, {{'$quod_live_bridge', Functor}, true}),
    ok;
record_live_bridge(
  #est{db = #db{mod = ?MODULE, ref = #lp{} = Ov}}, _Functor) ->
    ensure_access(Ov),
    %% No read-set table means this frame can never seal a plan (absorb fails
    %% loudly on any real dependency), so there is no plan to taint.
    ok;
record_live_bridge(_St, _Functor) ->
    erlang:error(badarg).

-doc """
Merge another proof's captured reads into this overlay's monotonic read set.

An authorization proof runs on its own strict read-only frame over the same
pinned committed base, so its tokens are identical to the ones this overlay
would have captured. Absorbing them makes the policy a real OCC dependency of
the plan this scope seals: a committed change to a policy predicate the decision
read invalidates the transaction. First-read-wins is preserved — an existing
entry is never overwritten.
""".
-spec absorb_read_set(tuple(), map()) -> ok.
absorb_read_set(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{read_ets = Ets} = Ov}}, Reads)
  when Ets =/= undefined ->
    ensure_access(Ov),
    maps:foreach(
      fun(Functor, Token) -> _ = ets:insert_new(Ets, {Functor, Token}), ok end,
      Reads);
absorb_read_set(
  #est{db = #db{mod = ?MODULE, ref = #lp{} = Ov}}, Reads)
  when map_size(Reads) =:= 0 ->
    ensure_access(Ov),
    %% Nothing to absorb — a policy proof that read nothing committed.
    ok;
absorb_read_set(
  #est{db = #db{mod = ?MODULE, ref = #lp{} = Ov}}, _Reads) ->
    ensure_access(Ov),
    %% The target overlay has no read-set table, so making the authorization
    %% policy an OCC dependency is impossible — silently dropping it would let a
    %% concurrently-revoked grant commit unconflicted. That "policy is an OCC
    %% dependency" is a real invariant, not best-effort: fail loudly here rather
    %% than at some later apply that no longer conflicts.
    erlang:error(absorb_read_set_without_read_ets);
absorb_read_set(_St, _Reads) ->
    erlang:error(badarg).

-doc "Merge validated live-bridge markers without treating them as OCC tokens.".
-spec absorb_live_bridges(tuple(), [{atom(), arity()}]) -> ok.
absorb_live_bridges(
  #est{db = #db{mod = ?MODULE,
                ref = #lp{read_ets = Ets} = Ov}}, Bridges)
  when Ets =/= undefined, is_list(Bridges) ->
    ensure_access(Ov),
    case lists:all(fun valid_bridge/1, Bridges) of
        true ->
            lists:foreach(
              fun(Functor) ->
                      _ = ets:insert_new(
                            Ets, {{'$quod_live_bridge', Functor}, true}),
                      ok
              end,
              Bridges),
            ok;
        false ->
            erlang:error(badarg)
    end;
absorb_live_bridges(
  #est{db = #db{mod = ?MODULE, ref = #lp{} = Ov}}, []) ->
    ensure_access(Ov),
    ok;
absorb_live_bridges(
  #est{db = #db{mod = ?MODULE, ref = #lp{} = Ov}}, _Bridges) ->
    ensure_access(Ov),
    erlang:error(absorb_live_bridges_without_read_ets);
absorb_live_bridges(_St, _Bridges) ->
    erlang:error(badarg).

valid_bridge({Name, Arity}) ->
    is_atom(Name) andalso is_integer(Arity) andalso Arity >= 0;
valid_bridge(_) -> false.

-doc "Drop the read-set table for a finished proof (pass the final `#est{}`).".
-spec cleanup_read_set(tuple()) -> ok.
cleanup_read_set(#est{db = #db{ref = #lp{read_ets = Ets}}}) when Ets =/= undefined ->
    catch ets:delete(Ets), ok;
cleanup_read_set(_) -> ok.

%%%===================================================================
%%% erlog db callbacks (Mod:Fun(Ref, Args))
%%%===================================================================

new({OutRef, OutMod}) ->
    #lp{out_db = #db{mod = OutMod, ref = OutRef, loc = []},
        scope_id = make_ref()}.

%% Erlog's opt-in choice-point hooks reuse the same immutable overlay token as
%% the explicit transaction entry savepoint. Neither callback traverses clause
%% data; restore retains the current monotonic read-set and overlay metadata.
choicepoint_checkpoint(
  #lp{scope_id = ScopeId, local = Local, effects = Effects,
      prepared_effects = PreparedEffects,
      next_tag = NextTag}) ->
    #checkpoint{scope_id = ScopeId, local = Local, effects = Effects,
                prepared_effects = PreparedEffects,
                next_tag = NextTag,
                distributed = quod_transaction_scope:checkpoint_token()}.

choicepoint_restore(
  #lp{scope_id = ScopeId} = Ov,
  #checkpoint{scope_id = ScopeId,
              local = Local, effects = Effects,
              prepared_effects = PreparedEffects, next_tag = NextTag,
              distributed = Distributed}) ->
    ok = quod_transaction_scope:restore_token(Distributed),
    Ov#lp{local = Local, effects = Effects,
          prepared_effects = PreparedEffects, next_tag = NextTag};
choicepoint_restore(_Ov, _Checkpoint) ->
    erlang:error(badarg).

%% Built-ins/compiled procs already live in the committed db; the overlay never
%% adds them (it is created over an already-built db).
add_built_in(St, _Functor)            -> St.
add_compiled_proc(St, _F, _M, _Fn)    -> {ok, St}.

asserta_clause(#lp{} = St, F, Head, Body) ->
    ensure_access(St),
    case St#lp.read_only orelse not modifiable(St, F) of
        true -> error;
        false ->
            L = St#lp.local,
            Tag = St#lp.next_tag,
            FS = maps:get(F, L, #fstate{}),
            FS1 = FS#fstate{asserta = [{Tag, Head, Body} | FS#fstate.asserta]},
            {ok, St#lp{local = L#{F => FS1}, next_tag = Tag + 1}}
    end.

assertz_clause(#lp{} = St, F, Head, Body) ->
    ensure_access(St),
    case St#lp.read_only orelse not modifiable(St, F) of
        true -> error;
        false ->
            L = St#lp.local,
            Tag = St#lp.next_tag,
            FS = maps:get(F, L, #fstate{}),
            FS1 = FS#fstate{assertz_rev = [{Tag, Head, Body} | FS#fstate.assertz_rev]},
            {ok, St#lp{local = L#{F => FS1}, next_tag = Tag + 1}}
    end.

retract_clause(#lp{out_db = #db{mod = M, ref = R}, local = L} = St, F, Tag) ->
    ensure_access(St),
    case St#lp.read_only of
        true -> error;
        false ->
            case M:get_procedure_type(R, F) of
                built_in -> error;
                compiled -> error;
                _ ->
                    FS = maps:get(F, L, #fstate{}),
                    case local_tag(Tag, FS) of
                        {true, asserta} ->
                            {ok, St#lp{local = L#{F => FS#fstate{asserta = lists:keydelete(Tag, 1, FS#fstate.asserta)}}}};
                        {true, assertz} ->
                            {ok, St#lp{local = L#{F => FS#fstate{
                                assertz_rev = lists:keydelete(Tag, 1, FS#fstate.assertz_rev)}}}};
                        false ->
                            case committed_clause(M, R, F, Tag) of
                                undefined -> {ok, St};
                                {H, B}    -> Ret = (FS#fstate.retracted)#{Tag => {H, B}},
                                             {ok, St#lp{local = L#{F => FS#fstate{retracted = Ret}}}}
                            end
                    end
            end
    end.

abolish_clauses(
  #lp{out_db = #db{mod = M, ref = R},
      local = L, read_ets = RS} = St,
  F) ->
    ensure_access(St),
    case St#lp.read_only of
        true -> error;
        false ->
            case M:get_procedure_type(R, F) of
                built_in -> error;
                _ ->
                    %% The resulting retract set is derived from the committed
                    %% procedure later in get_local_changes/1. Therefore abolish is a
                    %% read-modify-write even when the Prolog goal never reads F.
                    record_read(RS, F, R),
                    {ok, St#lp{local = L#{F => #fstate{abolished = true}}}}
            end
    end.

get_procedure(St, F) ->
    ensure_access(St),
    Base = raw_get_procedure(St, F),
    case is_tuple(F) andalso not St#lp.follow_disabled of
        true  -> add_followers(St, F, Base);     %% synthesize read-time link followers
        false -> Base                            %% non-tuple functor, or a strictly-local verdict
    end.

raw_get_procedure(#lp{out_db = #db{mod = M, ref = R}, local = L, read_ets = RS}, F) ->
    FS = maps:get(F, L, #fstate{}),
    A = FS#fstate.asserta, Z = lists:reverse(FS#fstate.assertz_rev),
    case FS#fstate.abolished of
        true  -> record_read(RS, F, R),
                 clauses_or_undef(A ++ Z);
        false ->
            case M:get_procedure(R, F) of
                built_in     -> built_in;
                {code, _} = C -> C;
                {clauses, Cs} ->
                    record_read(RS, F, R),
                    clauses_or_undef(A ++ filter_retracted(Cs, FS#fstate.retracted) ++ Z);
                undefined ->
                    record_read(RS, F, R),
                    clauses_or_undef(A ++ Z)
            end
    end.

%% A virtual follower is a LAST clause for every argument position. Its head only
%% matches a structured foreign name (Owner:Name), and its body strips that
%% prefix before asking the owner. The clauses never enter local, so they cannot
%% be committed or affect a captured read-set token.
add_followers(_St, {no_follow, 1}, Base) -> Base;
add_followers(_St, _F, Base) when Base =:= built_in -> Base;
add_followers(_St, _F, {code, _} = Base) -> Base;
add_followers(St, {Functor, Arity} = F, Base)
  when is_atom(Functor), is_integer(Arity), Arity > 0 ->
    case no_follow(St, F) of
        true  -> Base;
        false -> clauses_or_undef(
                   append_followers(base_clauses(Base), F))
    end;
add_followers(_St, _F, Base) -> Base.

base_clauses({clauses, Cs}) -> Cs;
base_clauses(undefined)      -> [].

no_follow(St, {Functor, Arity}) ->
    case raw_get_procedure(St, {no_follow, 1}) of
        {clauses, Cs} ->
            lists:any(fun({_Tag, {no_follow, {'/', F1, A1}}, _Body}) ->
                              F1 =:= Functor andalso A1 =:= Arity;
                         (_) -> false
                      end, Cs);
        _ -> false
    end.

append_followers([Clause | Rest], F) ->
    [Clause | append_followers(Rest, F)];
append_followers([], {Functor, Arity}) ->
    follower_clauses(Functor, Arity, 1).

follower_clauses(Functor, Arity, Pos) when Pos =< Arity ->
    [follower_clause(Functor, Arity, Pos) |
     follower_clauses(Functor, Arity, Pos + 1)];
follower_clauses(Functor, Arity, _Pos) ->
    [follower_end_clause(Functor, Arity)].

follower_clause(Functor, Arity, Pos) ->
    Ns = {'$quod_follow_ns'},
    %% Erlog variables are one-tuples. Keep the index inside the variable name
    %% rather than creating an atom for every generated clause.
    Args = [{{'$quod_follow_arg', I}} || I <- lists:seq(1, Arity)],
    Name = {':', Ns, lists:nth(Pos, Args)},
    Head = list_to_tuple([Functor | replace_nth(Pos, Name, Args)]),
    Inner = list_to_tuple([Functor | Args]),
    %% A variable argument must remain a variable. Without this guard a normal
    %% call such as diet(dog, D) would bind D to a synthetic foreign term and
    %% then attempt to ask an unbound namespace.
    Body = {',', {nonvar, Ns},
            {',', {'::', Ns, Inner}, {'$quod_follow_unique', Head}}},
    {{'$quod_follower', Pos}, Head, erlog_int:well_form_body(Body, false, sture)}.

%% Keep one terminal clause so every real follower runs with the relation's
%% choice point present. Its owned dedup state disappears before this clause fails.
follower_end_clause(Functor, Arity) ->
    Args = [{{'$quod_follow_fail_arg', I}} || I <- lists:seq(1, Arity)],
    Head = list_to_tuple([Functor | Args]),
    {'$quod_follower_end', Head, erlog_int:well_form_body(fail, false, sture)}.

replace_nth(1, Value, [_ | Tail]) -> [Value | Tail];
replace_nth(N, Value, [Head | Tail]) when N > 1 ->
    [Head | replace_nth(N - 1, Value, Tail)].

%% A type check must NOT record a read-set dependency (review #8): compute from the
%% committed type + local presence directly, never via the recording get_procedure/2.
get_procedure_type(
  #lp{} = St, F) ->
    ensure_access(St),
    procedure_type(St, F).

procedure_type(#lp{out_db = #db{mod = M, ref = R}, local = L}, F) ->
    FS = maps:get(F, L, #fstate{}),
    HasLocal = FS#fstate.asserta =/= [] orelse FS#fstate.assertz_rev =/= [],
    case M:get_procedure_type(R, F) of
        built_in    -> built_in;
        compiled    -> compiled;
        interpreted -> case {FS#fstate.abolished, HasLocal} of
                           {true, false} -> undefined;
                           _             -> interpreted
                       end;
        undefined   -> case HasLocal of true -> interpreted; false -> undefined end
    end.

get_interpreted_functors(#lp{out_db = #db{mod = M, ref = R}, local = L} = St) ->
    ensure_access(St),
    Locals = [F || {F, FS} <- maps:to_list(L),
                   FS#fstate.asserta =/= [] orelse FS#fstate.assertz_rev =/= []],
    All = lists:usort(M:get_interpreted_functors(R) ++ Locals),
    [F || F <- All, procedure_type(St, F) =:= interpreted].

%%%===================================================================
%%% internals
%%%===================================================================

boolean_option(Key, Opts) ->
    case maps:get(Key, Opts, false) of
        true  -> true;
        false -> false
    end.

access_guard_option(Opts) ->
    case maps:get(access_guard, Opts, unguarded) of
        unguarded ->
            %% Only isolated/internal callers that cannot select a live
            %% namespace use this sentinel. Production proof entry points
            %% acquire a generation-bound token before starting the session.
            unguarded;
        {quod_proof_access, Ns, Generation} = AccessGuard
          when is_binary(Ns), is_integer(Generation), Generation >= 0 ->
            AccessGuard;
        _ ->
            erlang:error(invalid_proof_access)
    end.

ensure_access(State) ->
    case check_access(State) of
        ok -> ok;
        {error, Reason} -> throw({quod_ask_error, Reason})
    end.

%% A pure write doesn't create a read-dependency: check the committed type
%% directly (no read-set recording) rather than through get_procedure/2.
modifiable(#lp{out_db = #db{mod = M, ref = R}}, F) ->
    case M:get_procedure_type(R, F) of
        built_in -> false;
        compiled -> false;
        _        -> true
    end.

local_tag(Tag, #fstate{asserta = A, assertz_rev = Z}) ->
    case lists:keymember(Tag, 1, A) of
        true  -> {true, asserta};
        false -> case lists:keymember(Tag, 1, Z) of true -> {true, assertz}; false -> false end
    end.

committed_clauses(M, R, F) ->
    case M:get_procedure(R, F) of {clauses, Cs} -> Cs; _ -> [] end.

committed_clause(M, R, F, Tag) ->
    case lists:keyfind(Tag, 1, committed_clauses(M, R, F)) of
        {Tag, H, B} -> {H, B};
        false       -> undefined
    end.

filter_retracted(Cs, Ret) -> [C || {Tag, _, _} = C <- Cs, not maps:is_key(Tag, Ret)].

clauses_or_undef([]) -> undefined;
clauses_or_undef(Cs) -> {clauses, Cs}.

%% First-read-wins. Local writes change the overlay's visible procedure, but every
%% interpreted lookup still depends on the committed predicate version underneath it:
%% a concurrent commit can change which clauses survive a retract/abolish or precede a
%% local assert. Always capture that original committed version token; write-only
%% operations use modifiable/2 and never enter this path. `staged` cannot be
%% captured here: wrap_state admits only published MVCC snapshots for read-set
%% overlays, and the immutable handle can never gain pending afterwards.
record_read(undefined, _F, _R) -> ok;
record_read(Ets, F, R) ->
    case ets:member(Ets, F) of
        true  -> ok;
        false -> ets:insert(Ets, {F, quod_erlog_db_mvcc:version_token(R, F)}), ok
    end.
