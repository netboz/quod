-module(quod_predicates).
-moduledoc """
The typed **external-predicate contract** and the per-run **execution context**
(`doc/agent-fipa-plan.md` §5). Two jobs, one module:

1. **Context.** Every proof, membership verdict, and served ask runs with an
   execution context — the namespace, the applied height, the authenticated
   subject (none yet), and the inter-ontology ask chain. It rides in the erlog
   flag store (`#est.fs`) as a single `none`-valued flag, so it survives the MVCC
   worker boundary and cannot be forged by ontology content: the flag-setting
   builtin `set_prolog_flag/2` refuses a `none`-valued flag
   (`erlog_int:prove_set_prolog_flag/5`), so only this module's Erlang code — never
   a Prolog rule — can write it. This replaces the former per-process-dictionary
   `$quod_ns` / `$quod_applied` / `$quod_ask_chain` / `$quod_in_verdict` values.

   > #### The flag is forge-resistant, not secret {: .warning }
   >
   > The `none`-valued slot blocks *writes*, but `current_prolog_flag/2` still
   > enumerates every flag, so a Prolog rule CAN *read* `'$quod_ctx'` and
   > destructure the `#qctx{}`. That is acceptable for the fields carried today —
   > `ns`/`height`/`kind`/`chain` are already visible to a target's `can_read`
   > policies by design, and `subject` is `undefined`. But it means the
   > authenticated **subject** (Slice 5, §10) MUST NOT be placed raw in this flag:
   > carry it out-of-band where content cannot read it — the `#lp{}` overlay
   > pattern used for `follow_disabled` (snapshotted at `wrap_state`) is the
   > available seam. `proof_context/3,4` therefore takes `Subject` but every caller
   > passes `undefined` until that hiding mechanism exists.

2. **Classes.** Each governed external predicate declares a class:

   | class | may read runtime | may stage D | may mutate P | may perform E |
   |---|---|---|---|---|
   | `query`      | yes | no  | no  | no  |
   | `staging`    | yes | yes | no  | no  |
   | `projection` | yes | no  | yes | no  |
   | `effect`     | yes | no  | no  | yes |

   Governed predicates register through `load/1`, which routes them via
   `dispatch/3`. Before delegating to the real handler, `dispatch/3` checks the
   predicate's class against the running context's *kind* and **fails closed**:
   a wrong-context call throws a distinct `{context_violation, …}` error rather
   than silently succeeding. `effect`-class predicates are therefore never
   reachable from an ordinary ontology proof.

The context *kinds* are `proof` (a normal client proof or a staged write),
`verdict` (a committee membership re-proof — strictly local, following disabled),
`projection` (a runtime P handler, §8), and `effect` (the action-only boundary
used by lifecycle authorization now and live E handlers in §9).
""".
-include_lib("erlog/src/erlog_int.hrl").

%% registration + dispatch
-export([load/1, dispatch/3]).
%% context read/write on an #est{}
-export([set_context/2, context/1, in_verdict/1]).
%% context constructors
-export([proof_context/3, proof_context/4, verdict_context/2, effect_context/2]).
%% context accessors
-export([ctx_kind/1, ctx_ns/1, ctx_height/1, ctx_chain/1]).
-export([projection_context/3]).
%% class metadata (also drives dispatch)
-export([class/1, allowed/2, is_ground/1]).
-export([projection_noop_1/3]).

-define(CTX_FLAG, '$quod_ctx').

%% The execution context threaded through a run. `subject` is `undefined` until signed
%% subjects land (§10); `chain` is the inter-ontology ask chain (`doc/inter-ontology.md` §6).
-record(qctx, {kind    :: kind(),
               ns      :: binary() | undefined,
               height  = 0 :: non_neg_integer(),
               subject = undefined :: term(),
               chain   = [] :: [binary()],
               %% the executing declaration: a state_handler id in a `projection` context
               %% (an effect/reaction id in an `effect` context, Slice 3). `undefined` elsewhere.
               id      = undefined :: term()}).

-type kind()  :: proof | verdict | projection | effect.
-type class() :: query | staging | projection | effect.
-type ctx()   :: #qctx{} | undefined.
-export_type([kind/0, class/0, ctx/0]).

%%%===================================================================
%%% registration + dispatch
%%%===================================================================

-doc """
Register the governed external predicates onto a freshly-built kb (`#est{}`),
routing each through `dispatch/3` for context enforcement. The committee
predicates keep their handlers in `m:quod_committee_predicates`; only their
registration lives here so class enforcement has a single home.
""".
-spec load(tuple()) -> tuple().
load(#est{db = Db0} = Est) ->
    Db1 = lists:foldl(
            fun(Functor, Db) -> erlog_int:add_compiled_proc(Functor, ?MODULE, dispatch, Db) end,
            Db0, governed()),
    Est#est{db = Db1}.

%% The governed predicates, in registration order. Their class + real handler is in registry/1.
governed() -> [{peer_ready, 1}, {directory_host, 4},
               {directory_control_peer, 1},
               {admit, 3}, {remove, 1},
               {authorized_ontology_lifecycle, 1},
               {ontology_join_state, 2}, {ontology_genesis_anchor, 2},
               {projection_noop, 1}, {enqueue_projection, 2}].

%% {Class, HandlerModule, HandlerFunction} for a governed predicate, or `undefined`.
registry({peer_ready, 1}) -> {query,   quod_committee_predicates, peer_ready_1};
registry({directory_host, 4}) ->
    {query, quod_directory_predicates, directory_host_4};
registry({directory_control_peer, 1}) ->
    {query, quod_directory_predicates, directory_control_peer_1};
registry({admit, 3})      -> {staging, quod_committee_predicates, admit_3};
registry({remove, 1})     -> {staging, quod_committee_predicates, remove_1};
%% Read-only itself, but deliberately action-only: only the lifecycle runner
%% carries an effect context, so ordinary proofs cannot probe its private
%% engine-owned principal.
registry({authorized_ontology_lifecycle, 1}) ->
    {effect, quod_ontology_predicates,
     authorized_ontology_lifecycle_predicate};
registry({ontology_join_state, 2}) ->
    {query, quod_ontology_predicates,
     ontology_join_state_predicate};
registry({ontology_genesis_anchor, 2}) ->
    {query, quod_ontology_predicates,
     ontology_genesis_anchor_predicate};
%% arity 1: a handler ConvergeGoal is invoked with the scope argument appended, so the
%% declared atom `projection_noop` reaches the KB as {projection_noop, Scope}.
registry({projection_noop, 1}) -> {projection, ?MODULE, projection_noop_1};
%% heavy work leaves the ordered tier through this bridge (m:quod_runtime_predicates)
registry({enqueue_projection, 2}) -> {projection, quod_runtime_predicates, enqueue_projection_2};
registry(_)               -> undefined.

-doc """
The erlog entry point for every governed predicate. Checks the predicate's class
against the running context and either delegates to the real handler or fails
closed:

- **no managed context** (genesis compilation, a bare test) — no solution
  (`erlog_int:fail/1`). Content cannot engineer this: it can neither set nor clear
  the context flag.
- **wrong context** (e.g. an `effect` predicate in a `proof`) — a distinct
  `{context_violation, Functor, Class, Kind}` thrown as an `erlog_error`, surfaced
  to the caller by `quod_prolog`'s proof runner.
""".
-spec dispatch(term(), term(), tuple()) -> term().
dispatch(Goal, Next, St) ->
    case context(St) of
        undefined -> erlog_int:fail(St);
        Ctx ->
            Functor = functor(Goal),
            case registry(Functor) of
                undefined -> erlog_int:fail(St);
                {Class, Mod, Fun} ->
                    case allowed(Class, ctx_kind(Ctx)) of
                        true  -> Mod:Fun(Goal, Next, St);
                        false -> throw({erlog_error,
                                        {context_violation, Functor, Class, ctx_kind(Ctx)}})
                    end
            end
    end.

functor(Goal) when is_atom(Goal)  -> {Goal, 0};
functor(Goal) when is_tuple(Goal) -> {element(1, Goal), tuple_size(Goal) - 1}.

-doc "Class of a governed predicate functor (`{Name, Arity}`), or `undefined`.".
-spec class({atom(), arity()}) -> class() | undefined.
class(Functor) ->
    case registry(Functor) of
        {Class, _, _} -> Class;
        undefined     -> undefined
    end.

-doc """
Whether a predicate of `Class` may run in a context of `Kind` (the matrix in the
module doc). `query` reads anywhere; `staging` writes only inside a `proof`
(never a `verdict` — a membership re-proof must be side-effect-free); `projection`
and `effect` run only in their own contexts.
""".
-spec allowed(class(), kind() | undefined) -> boolean().
allowed(_Class,     undefined)   -> false;
allowed(query,      _Kind)       -> true;
allowed(staging,    proof)       -> true;
allowed(staging,    _Kind)       -> false;
allowed(projection, projection)  -> true;
allowed(projection, _Kind)       -> false;
allowed(effect,     effect)      -> true;
allowed(effect,     _Kind)       -> false.

-doc "Whether an Erlog term contains no unbound variable (including anonymous `_`).".
-spec is_ground(term()) -> boolean().
is_ground(T) when is_tuple(T), tuple_size(T) =:= 1 -> false;
is_ground(T) when is_tuple(T) ->
    lists:all(fun is_ground/1, tuple_to_list(T));
is_ground([H | T]) ->
    is_ground(H) andalso is_ground(T);
is_ground([]) ->
    true;
is_ground(_) ->
    true.

%% The no-op projection ConvergeGoal (`m:quod_runtime` handlers, Slice 2): succeeds under a
%% `projection` context, refused everywhere else by `dispatch/3`. Real P-mutating projection
%% primitives arrive with their first consumer (AMS/DF, Slice 4) and must be ensure-style.
-spec projection_noop_1(term(), term(), tuple()) -> term().
projection_noop_1(_Goal, Next, St) -> erlog_int:prove_body(Next, St).

%%%===================================================================
%%% context: read/write on #est.fs
%%%===================================================================

-doc "Set the execution context on an `#est{}` (a `none`-valued, content-unforgeable flag).".
-spec set_context(tuple(), ctx()) -> tuple().
set_context(#est{fs = Fs} = Est, #qctx{} = Ctx) ->
    Est#est{fs = lists:keystore(?CTX_FLAG, 1, Fs, {?CTX_FLAG, Ctx, none})}.

-doc "Read the execution context off an `#est{}`, or `undefined` if none is set.".
-spec context(tuple()) -> ctx().
context(#est{fs = Fs}) ->
    case lists:keyfind(?CTX_FLAG, 1, Fs) of
        {?CTX_FLAG, Ctx, _} -> Ctx;
        false               -> undefined
    end.

-doc """
Whether the `#est{}` carries a `verdict` context. Read by the inter-ontology ask
handler (which refuses a hop mid-verdict) and by the proof overlay (which disables
read-time link following mid-verdict) — both must see the same signal that used to
be the `$quod_in_verdict` process-dictionary flag.
""".
-spec in_verdict(tuple()) -> boolean().
in_verdict(Est) -> ctx_kind(context(Est)) =:= verdict.

%%%===================================================================
%%% context constructors + accessors
%%%===================================================================

-doc "A `proof` context whose ask chain is just this ontology.".
-spec proof_context(binary() | undefined, non_neg_integer(), term()) -> #qctx{}.
proof_context(Ns, Height, Subject) -> proof_context(Ns, Height, Subject, [Ns]).

-doc "A `proof` context with an explicit ask chain (a served ask carries the caller's chain).".
-spec proof_context(binary() | undefined, non_neg_integer(), term(), [binary()]) -> #qctx{}.
proof_context(Ns, Height, Subject, Chain) ->
    #qctx{kind = proof, ns = Ns, height = Height, subject = Subject, chain = Chain}.

-doc "A `verdict` context: a strictly-local membership re-proof at a parent height.".
-spec verdict_context(binary() | undefined, non_neg_integer()) -> #qctx{}.
verdict_context(Ns, Height) ->
    #qctx{kind = verdict, ns = Ns, height = Height, subject = undefined, chain = [Ns]}.

-doc "An `effect` context for action-only authorization and live E handlers.".
-spec effect_context(binary() | undefined, non_neg_integer()) -> #qctx{}.
effect_context(Ns, Height) ->
    #qctx{kind = effect, ns = Ns, height = Height, subject = undefined,
          chain = [Ns]}.

-doc """
A `projection` context: a `m:quod_runtime` handler converging its piece of P against the
frozen snapshot at `Height`. `HandlerId` identifies the executing declaration (readable by
content via `current_prolog_flag`, like every context field — forge-resistant, not secret).
""".
-spec projection_context(binary() | undefined, non_neg_integer(), term()) -> #qctx{}.
projection_context(Ns, Height, HandlerId) ->
    #qctx{kind = projection, ns = Ns, height = Height, subject = undefined,
          chain = [Ns], id = HandlerId}.

-spec ctx_kind(ctx()) -> kind() | undefined.
ctx_kind(#qctx{kind = K}) -> K;
ctx_kind(undefined)       -> undefined.

-spec ctx_ns(ctx()) -> binary() | undefined.
ctx_ns(#qctx{ns = Ns}) -> Ns;
ctx_ns(undefined)      -> undefined.

-spec ctx_height(ctx()) -> non_neg_integer() | undefined.
ctx_height(#qctx{height = H}) -> H;
ctx_height(undefined)         -> undefined.

-spec ctx_chain(ctx()) -> [binary()].
ctx_chain(#qctx{chain = C}) -> C;
ctx_chain(undefined)        -> [].
