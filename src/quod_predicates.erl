-module(quod_predicates).
-moduledoc """
The typed **external-predicate contract** and the per-run **execution context**
(`doc/agent-fipa-plan.md` §5). Two jobs, one module:

1. **Context.** Every proof, deterministic verdict, and selected proof scope runs with
   an execution context — the namespace, the applied height, and the
   inter-ontology selection chain. It rides in the erlog
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
   > `ns`/`height`/`kind`/`chain` are already visible to a target's `can_invoke`
   > policies by design, and `subject` remains `undefined`. Authenticated
   > authority is carried out-of-band by `quod_proof_context` and the proof
   > session, where ontology content cannot replace it; it is passed explicitly
   > to `can_invoke/4` rather than copied into this readable flag.

2. **Classes.** Each governed external predicate declares a class:

   | class | may read runtime | may stage D | may mutate P | may perform E |
   |---|---|---|---|---|
   | `query`      | yes | no  | no  | no  |
   | `staging`    | yes | yes | no  | no  |
   | `projection` | yes | no  | yes | no  |
   | `reaction`   | yes | no  | no  | yes |

   Governed predicates register through `load/1`, which routes them via
   `dispatch/3`. Before delegating to the real handler, `dispatch/3` checks the
   predicate's class against the running context's *kind* and **fails closed**:
   a wrong-context call throws a distinct `{context_violation, …}` error rather
   than silently succeeding.

The context *kinds* are `proof` (a normal client proof or staged write),
`verdict` (a committee membership re-proof — strictly local),
`policy_verdict` (a strictly local authorization re-proof with every governed
bridge disabled), `projection` (a runtime P handler, §8), and `reaction` (one
post-commit `react_on/3` continuation).
""".
-include_lib("erlog/src/erlog_int.hrl").

%% registration + dispatch
-export([load/1, load_manifest/2,
         module_manifest/1, valid_module_names/1,
         valid_manifest_shape/1, register/5, dispatch/3]).
-ifdef(TEST).
-export([load_modules/2, valid_manifest/1, descriptor/2]).
-endif.
%% context read/write on an #est{}
-export([set_context/2, context/1, local_only/1]).
%% context constructors
-export([proof_context/3, proof_context/4, verdict_context/2,
         policy_verdict_context/2, reaction_context/2]).
%% context accessors
-export([ctx_kind/1, ctx_ns/1, ctx_height/1, ctx_chain/1,
         with_chain/2]).
-export([projection_context/3]).
%% class metadata (also drives dispatch)
-export([class/2, allowed/2, is_ground/1]).

-define(CTX_FLAG, '$quod_ctx').
-define(REGISTRY_FLAG, '$quod_predicate_registry').

-type module_manifest() :: [{module(), <<_:256>>}].
-export_type([module_manifest/0]).

%% The execution context threaded through a run. `subject` remains undefined:
%% authenticated authority is private proof-session state and is passed
%% explicitly to policy. `chain` is the inter-ontology ask chain
%% (`doc/inter-ontology.md` §6).
-record(qctx, {kind    :: kind(),
               ns      :: binary() | undefined,
               height  = 0 :: non_neg_integer(),
               subject = undefined :: term(),
               chain   = [] :: [quod_proof_context:identity()],
               %% the executing state_handler in a `projection` context;
               %% `undefined` elsewhere.
               id      = undefined :: term()}).

-type kind()  :: proof | verdict | policy_verdict | projection | reaction.
-type class() :: query | staging | projection | reaction.
-type ctx()   :: #qctx{} | undefined.
-export_type([kind/0, class/0, ctx/0]).

%%%===================================================================
%%% registration + dispatch
%%%===================================================================

-doc """
Register only the common bridges which belong to every ontology. Predicate
ownership remains in the modules themselves; this module supplies the shared
registration and context-checking machinery.
""".
-spec load(tuple()) -> tuple().
load(Est) ->
    load_modules(
      Est, [quod_committee_predicates, quod_runtime_predicates]).

-doc "Load the application's common bridge modules in their explicit order.".
-spec load_modules(tuple(), [module()]) -> tuple().
load_modules(Est, Modules) when is_list(Modules) ->
    lists:foldl(
      fun(Module, Acc) when is_atom(Module) ->
              case load_predicate_module(Acc, Module) of
                  {ok, Loaded} -> Loaded;
                  {error, Reason} -> error(Reason)
              end
      end, Est, Modules).

-doc "Build the immutable genesis manifest for Quod-owned predicate modules.".
-spec module_manifest([module()]) ->
          {ok, module_manifest()} | {error, term()}.
module_manifest(Modules) when is_list(Modules) ->
    case valid_module_names(Modules) of
        true -> module_manifest_entries(Modules, []);
        false -> {error, invalid_external_predicate_modules}
    end;
module_manifest(_) ->
    {error, invalid_external_predicate_modules}.

-doc "Whether a module-name list is proper, ordered, atom-only, and duplicate-free.".
-spec valid_module_names(term()) -> boolean().
valid_module_names(Modules) ->
    proper_distinct_atoms(Modules).

module_manifest_entries([], Acc) ->
    {ok, lists:reverse(Acc)};
module_manifest_entries([Module | Rest], Acc) ->
    case predicate_module_beam(Module) of
        {ok, Beam} ->
            Digest = crypto:hash(sha256, Beam),
            module_manifest_entries(Rest, [{Module, Digest} | Acc]);
        {error, _} = Error -> Error
    end.

-doc "Validate one committed manifest against the exact local BEAM files.".
-spec valid_manifest(term()) ->
          {ok, [module()]} | {error, term()}.
valid_manifest(Manifest) when is_list(Manifest) ->
    case manifest_shape(Manifest, #{}) of
        ok -> validate_manifest_entries(Manifest, []);
        error -> {error, invalid_external_predicate_manifest}
    end;
valid_manifest(_) ->
    {error, invalid_external_predicate_manifest}.

-doc "Validate only the durable shape, without requiring the module locally.".
-spec valid_manifest_shape(term()) -> boolean().
valid_manifest_shape(Manifest) when is_list(Manifest) ->
    manifest_shape(Manifest, #{}) =:= ok;
valid_manifest_shape(_) -> false.

validate_manifest_entries([], Acc) ->
    {ok, lists:reverse(Acc)};
validate_manifest_entries([{Module, ExpectedDigest} | Rest], Acc) ->
    case predicate_module_beam(Module) of
        {ok, Beam} ->
            case crypto:hash(sha256, Beam) of
                ExpectedDigest ->
                    validate_manifest_entries(Rest, [Module | Acc]);
                _ ->
                    {error, {predicate_module_digest_mismatch, Module}}
            end;
        {error, _} = Error -> Error
    end.

-doc "Load only modules whose local code matches the committed genesis manifest.".
-spec load_manifest(tuple(), module_manifest()) ->
          {ok, tuple()} | {error, term()}.
load_manifest(Est, Manifest) ->
    case valid_manifest(Manifest) of
        {ok, Modules} -> load_manifest_modules(Est, Modules);
        {error, _} = Error -> Error
    end.

load_manifest_modules(Est, []) -> {ok, Est};
load_manifest_modules(Est, [Module | Rest]) ->
    case load_predicate_module(Est, Module) of
        {ok, Loaded} -> load_manifest_modules(Loaded, Rest);
        {error, _} = Error -> Error
    end.

%% Loading is the only point where committed module code is executed.  Keep
%% that dependency boundary typed: a missing module, failed on_load, false
%% marker, or failing load/1 makes this ontology unavailable and is reported by
%% its projection owner. Common protocol modules call the same helper through
%% load_modules/2 and still fail the application loudly on any defect.
load_predicate_module(Est, Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            load_marked_module(Est, Module);
        {error, Reason} ->
            {error, {predicate_module_unavailable, Module, Reason}}
    end.

load_marked_module(Est, Module) ->
    Marker =
        try Module:quod_predicate_module()
        catch Class0:Reason0:Stack0 ->
            {failed, Class0, Reason0, Stack0}
        end,
    case Marker of
        true ->
            try {ok, Module:load(Est)}
            catch Class:Reason:Stack ->
                {error,
                 {predicate_module_load_failed,
                  Module, Class, Reason, Stack}}
            end;
        _ ->
            {error, {invalid_predicate_module_marker, Module, Marker}}
    end.

manifest_shape([], _Seen) -> ok;
manifest_shape([{Module, <<_:256>>} | Rest], Seen) when is_atom(Module) ->
    case maps:is_key(Module, Seen) of
        true -> error;
        false -> manifest_shape(Rest, Seen#{Module => true})
    end;
manifest_shape(_, _Seen) -> error.

proper_distinct_atoms(Modules) ->
    proper_distinct_atoms(Modules, #{}).

proper_distinct_atoms([], _Seen) -> true;
proper_distinct_atoms([Module | Rest], Seen) when is_atom(Module) ->
    case maps:is_key(Module, Seen) of
        true -> false;
        false -> proper_distinct_atoms(Rest, Seen#{Module => true})
    end;
proper_distinct_atoms(_, _Seen) -> false.

predicate_module_beam(Module) when is_atom(Module) ->
    Name = atom_to_list(Module),
    case safe_module_basename(Name) of
        true -> predicate_module_beam(Module, Name);
        false -> {error, {invalid_predicate_module, Module}}
    end.

predicate_module_beam(Module, Name) ->
    %% Predicate modules are part of the exact Quod artifact executing this
    %% dispatcher.  Derive its ebin directory from the loaded dispatcher,
    %% rather than asking the application controller to reconstruct a library
    %% path (which may name the source tree in an isolated peer VM).
    AppEbin = filename:dirname(code:which(?MODULE)),
    Path = filename:join(AppEbin, Name ++ ".beam"),
    case file:read_file(Path) of
        {ok, Beam} ->
            case beam_lib:chunks(Beam, [exports]) of
                {ok, {Module, [{exports, Exports}]}} ->
                    case lists:member({load, 1}, Exports)
                         andalso lists:member(
                                   {quod_predicate_module, 0}, Exports) of
                        true -> {ok, Beam};
                        false ->
                            {error, {invalid_predicate_module, Module}}
                    end;
                _ -> {error, {invalid_predicate_module, Module}}
            end;
        {error, _} -> {error, {predicate_module_unavailable, Module}}
    end.

safe_module_basename([]) -> false;
safe_module_basename(Name) ->
    filename:pathtype(Name) =:= relative
        andalso filename:basename(Name) =:= Name
        andalso not lists:member(0, Name).

-doc "Register one bridge in this Erlog engine; conflicting ownership fails loud.".
-spec register(tuple(), {atom(), arity()}, class(), module(), atom()) -> tuple().
register(#est{db = Db0, fs = Fs0} = Est, {Name, Arity} = Functor,
         Class, Module, Function)
  when is_atom(Name), is_integer(Arity), Arity >= 0,
       (Class =:= query orelse Class =:= staging orelse
        Class =:= projection orelse Class =:= reaction),
       is_atom(Module), is_atom(Function) ->
    Registry0 = registry(Fs0),
    Descriptor = {Class, Module, Function},
    case maps:get(Functor, Registry0, undefined) of
        undefined ->
            Db1 = erlog_int:add_compiled_proc(
                    Functor, ?MODULE, dispatch, Db0),
            Registry1 = Registry0#{Functor => Descriptor},
            Est#est{db = Db1,
                    fs = lists:keystore(
                           ?REGISTRY_FLAG, 1, Fs0,
                           {?REGISTRY_FLAG, Registry1, none})};
        Descriptor ->
            Est;
        Other ->
            error({external_predicate_conflict,
                   Functor, Other, Descriptor})
    end.

registry(Fs) ->
    case lists:keyfind(?REGISTRY_FLAG, 1, Fs) of
        {?REGISTRY_FLAG, Registry, _} when is_map(Registry) -> Registry;
        false -> #{}
    end.

-doc "Return this engine's exact bridge descriptor for one functor.".
-spec descriptor(tuple(), {atom(), arity()}) ->
          {class(), module(), atom()} | undefined.
descriptor(#est{fs = Fs}, Functor) ->
    maps:get(Functor, registry(Fs), undefined).

-doc """
The erlog entry point for every governed predicate. Checks the predicate's class
against the running context and either delegates to the real handler or fails
closed:

- **no managed context** (genesis compilation, a bare test) — no solution
  (`erlog_int:fail/1`). Content cannot engineer this: it can neither set nor clear
  the context flag.
- **wrong context** (e.g. a `staging` predicate in a verdict) — a distinct
  `{context_violation, Functor, Class, Kind}` thrown as an `erlog_error`, surfaced
  to the caller by `quod_prolog`'s proof runner.
""".
-spec dispatch(term(), term(), tuple()) -> term().
dispatch(Goal, Next, St) ->
    case context(St) of
        undefined -> erlog_int:fail(St);
        Ctx ->
            Functor = functor(Goal),
            case descriptor(St, Functor) of
                undefined -> erlog_int:fail(St);
                {Class, Mod, Fun} ->
                    case allowed(Class, ctx_kind(Ctx)) of
                        true  ->
                            ok = record_bridge_use(Functor, Class, Ctx, St),
                            Mod:Fun(Goal, Next, St);
                        false -> throw({erlog_error,
                                        {context_violation, Functor, Class, ctx_kind(Ctx)}})
                    end
            end
    end.

%% A query-class bridge reads live node state no later validation can re-prove,
%% so a sealed plan must not silently depend on one (`m:quod_dtx`). Recorded at
%% dispatch — a bridge that found no solution still influenced the outcome.
%% Proof contexts can seal plans. The sealing boundary decides
%% whether a live bridge is admissible for the exact resulting diff/effect;
%% dispatch cannot know that yet.
record_bridge_use(Functor, query, Ctx, St) ->
    case ctx_kind(Ctx) =:= proof of
        true -> quod_erlog_db_local_prove:record_live_bridge(St, Functor);
        false -> ok
    end;
record_bridge_use(_Functor, _Class, _Ctx, _St) ->
    ok.

functor(Goal) when is_atom(Goal)  -> {Goal, 0};
functor(Goal) when is_tuple(Goal) -> {element(1, Goal), tuple_size(Goal) - 1}.

-doc "Class of a bridge functor installed in this exact engine.".
-spec class(tuple(), {atom(), arity()}) -> class() | undefined.
class(Est, Functor) ->
    case descriptor(Est, Functor) of
        {Class, _, _} -> Class;
        undefined -> undefined
    end.

-doc """
Whether a predicate of `Class` may run in a context of `Kind` (the matrix in the
module doc). `query` reads everywhere except a deterministic policy verdict;
`staging` writes only inside a `proof`; `projection` runs only in its own
context.
""".
-spec allowed(class(), kind() | undefined) -> boolean().
allowed(_Class,     undefined)   -> false;
allowed(query,      policy_verdict) -> false;
allowed(query,      _Kind)       -> true;
allowed(staging,    proof)       -> true;
allowed(staging,    _Kind)       -> false;
allowed(projection, projection)  -> true;
allowed(projection, _Kind)       -> false;
allowed(reaction,   reaction)    -> true;
allowed(reaction,   _Kind)       -> false.

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

-doc "Whether this execution is confined to its local committed ontology.".
-spec local_only(tuple()) -> boolean().
local_only(Est) ->
    Kind = ctx_kind(context(Est)),
    Kind =:= verdict orelse Kind =:= policy_verdict.

%%%===================================================================
%%% context constructors + accessors
%%%===================================================================

-doc "A local `proof` context without distributed selector authority.".
-spec proof_context(binary() | undefined, non_neg_integer(), term()) -> #qctx{}.
proof_context(Ns, Height, Subject) -> proof_context(Ns, Height, Subject, []).

-doc "A `proof` context with an exact anchored ontology call chain.".
-spec proof_context(binary() | undefined, non_neg_integer(), term(),
                    [quod_proof_context:identity()]) -> #qctx{}.
proof_context(Ns, Height, Subject, Chain) ->
    #qctx{kind = proof, ns = Ns, height = Height, subject = Subject, chain = Chain}.

-doc "A `verdict` context: a strictly-local membership re-proof at a parent height.".
-spec verdict_context(binary() | undefined, non_neg_integer()) -> #qctx{}.
verdict_context(Ns, Height) ->
    #qctx{kind = verdict, ns = Ns, height = Height, subject = undefined}.

-doc "A strictly local authorization re-proof with no governed bridges.".
-spec policy_verdict_context(binary() | undefined, non_neg_integer()) -> #qctx{}.
policy_verdict_context(Ns, Height) ->
    #qctx{kind = policy_verdict, ns = Ns, height = Height,
          subject = undefined}.

-doc """
A `projection` context: a `m:quod_runtime` handler converging its piece of P against the
frozen snapshot at `Height`. `HandlerId` identifies the executing declaration (readable by
content via `current_prolog_flag`, like every context field — forge-resistant, not secret).
""".
-spec projection_context(binary() | undefined, non_neg_integer(), term()) -> #qctx{}.
projection_context(Ns, Height, HandlerId) ->
    #qctx{kind = projection, ns = Ns, height = Height, subject = undefined,
          id = HandlerId}.

-doc "A post-commit reaction continuation over the frozen block snapshot.".
-spec reaction_context(binary() | undefined, non_neg_integer()) -> #qctx{}.
reaction_context(Ns, Height) ->
    #qctx{kind = reaction, ns = Ns, height = Height, subject = undefined}.

-doc "Install the engine-owned anchored call chain without changing context kind.".
-spec with_chain(ctx(), [quod_proof_context:identity()]) -> ctx().
with_chain(#qctx{} = Ctx, Chain) when is_list(Chain) ->
    Ctx#qctx{chain = Chain};
with_chain(undefined, _Chain) ->
    undefined.

-spec ctx_kind(ctx()) -> kind() | undefined.
ctx_kind(#qctx{kind = K}) -> K;
ctx_kind(undefined)       -> undefined.

-spec ctx_ns(ctx()) -> binary() | undefined.
ctx_ns(#qctx{ns = Ns}) -> Ns;
ctx_ns(undefined)      -> undefined.

-spec ctx_height(ctx()) -> non_neg_integer() | undefined.
ctx_height(#qctx{height = H}) -> H;
ctx_height(undefined)         -> undefined.

-spec ctx_chain(ctx()) -> [quod_proof_context:identity()].
ctx_chain(#qctx{chain = C}) -> C;
ctx_chain(undefined)        -> [].
