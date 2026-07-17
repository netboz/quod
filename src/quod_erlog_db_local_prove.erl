-module(quod_erlog_db_local_prove).
-moduledoc """
A **staging overlay** for the erlog database, used to run a proof against the
committed knowledge base without touching it.

Wrap a committed erlog state with `wrap_state/1,2`, run the goal, then extract:

- `get_local_changes/1` — the **write-set**: the asserts/retracts the proof made,
  as content-only `op()`s.
- `get_read_set/1` — the **read-set**: one content hash per `{Functor, Arity}` the
  proof read from the committed db (for the apply-time OCC re-check).

Asserts/retracts are shadowed per functor; reads merge `asserta ++ committed ++
assertz`. The committed db (`out_db`) is read-only throughout. This is a slimmed
port of bbsvx's `bbsvx_erlog_db_local_prove` (federation/ACL/provenance dropped).

Ported against erlog's `#est{}`/`#db{}` (see `erlog_int.hrl`); read-set hashing is
shared with `m:quod_diff` so the producer here and the validator in `quod_prolog`
agree bit-for-bit.
""".
-include_lib("erlog/src/erlog_int.hrl").

%% erlog db callbacks
-export([new/1, add_built_in/2, add_compiled_proc/4,
         asserta_clause/4, assertz_clause/4, retract_clause/3, abolish_clauses/2,
         get_procedure/2, get_procedure_type/2, get_interpreted_functors/1]).
%% overlay API
-export([wrap_state/1, wrap_state/2, get_local_changes/1, get_read_set/1,
         cleanup_read_set/1]).

-record(fstate, {abolished = false :: boolean(),
                 asserta   = []    :: [{integer(), term(), term()}],
                 assertz_rev = []  :: [{integer(), term(), term()}],
                 retracted = #{}   :: #{integer() => {term(), term()}}}).

-record(lp, {out_db   :: #db{},
             local    = #{}      :: #{term() => #fstate{}},
             next_tag = 1000000  :: integer(),   %% above any committed-db tag
             read_ets = undefined :: ets:tid() | undefined,
             %% Read-time link following is disabled inside a committee membership verdict
             %% (a vote must never make network hops). Snapshotted from the `#est{}`'s
             %% execution context at wrap time — the db callback layer cannot see `#est.fs`,
             %% so the flag is carried here rather than read per-lookup.
             follow_disabled = false :: boolean()}).

%%%===================================================================
%%% wrapping + extraction
%%%===================================================================

-doc "Wrap a committed `#est{}` so a proof stages onto a private overlay.".
-spec wrap_state(tuple()) -> tuple().
wrap_state(#est{db = #db{mod = OutMod, ref = OutRef,
                         assert_hooks = AH, retract_hooks = RH}} = St) ->
    Overlay = (new({OutRef, OutMod}))#lp{follow_disabled = quod_predicates:in_verdict(St)},
    St#est{db = #db{mod = ?MODULE, ref = Overlay, loc = [],
                    assert_hooks = AH, retract_hooks = RH}}.

-doc "As `wrap_state/1`; `#{read_set => true}` also tracks the read-set.".
-spec wrap_state(tuple(), map()) -> tuple().
wrap_state(St, Opts) ->
    #est{db = #db{ref = Ov} = Db} = Wrapped = wrap_state(St),
    case maps:get(read_set, Opts, false) of
        true  -> Ets = ets:new(quod_read_set, [set, private]),
                 Wrapped#est{db = Db#db{ref = Ov#lp{read_ets = Ets}}};
        false -> Wrapped
    end.

-doc "The write-set: the proof's asserts/retracts as content-only ops.".
-spec get_local_changes(#lp{}) -> [{assert | retract, {term(), term()}}].
get_local_changes(#lp{local = Local, out_db = #db{mod = M, ref = R}}) ->
    maps:fold(fun(F, FS, Acc) -> functor_ops(F, FS, M, R) ++ Acc end, [], Local).

functor_ops(F, #fstate{abolished = Ab, asserta = A, assertz_rev = ZR,
                       retracted = Ret}, M, R) ->
    Retracts = case Ab of
                   true  -> [{retract, {H, B}} || {_T, H, B} <- committed_clauses(M, R, F)];
                   false -> [{retract, {H, B}} || {_Tag, {H, B}} <- maps:to_list(Ret)]
               end,
    Asserts = [{assert, {H, B}} || {_T, H, B} <- A ++ lists:reverse(ZR)],
    Retracts ++ Asserts.

-doc "The read-set: `#{ {Functor,Arity} => content-hash }` of what the proof read.".
-spec get_read_set(#lp{}) -> map().
get_read_set(#lp{read_ets = undefined}) -> #{};
get_read_set(#lp{read_ets = Ets})       -> maps:from_list(ets:tab2list(Ets)).

-doc "Drop the read-set table for a finished proof (pass the final `#est{}`).".
-spec cleanup_read_set(tuple()) -> ok.
cleanup_read_set(#est{db = #db{ref = #lp{read_ets = Ets}}}) when Ets =/= undefined ->
    catch ets:delete(Ets), ok;
cleanup_read_set(_) -> ok.

%%%===================================================================
%%% erlog db callbacks (Mod:Fun(Ref, Args))
%%%===================================================================

new({OutRef, OutMod}) ->
    #lp{out_db = #db{mod = OutMod, ref = OutRef, loc = []}}.

%% Built-ins/compiled procs already live in the committed db; the overlay never
%% adds them (it is created over an already-built db).
add_built_in(St, _Functor)            -> St.
add_compiled_proc(St, _F, _M, _Fn)    -> {ok, St}.

asserta_clause(#lp{local = L, next_tag = Tag} = St, F, Head, Body) ->
    case modifiable(St, F) of
        false -> error;
        true  ->
            FS = maps:get(F, L, #fstate{}),
            FS1 = FS#fstate{asserta = [{Tag, Head, Body} | FS#fstate.asserta]},
            {ok, St#lp{local = L#{F => FS1}, next_tag = Tag + 1}}
    end.

assertz_clause(#lp{local = L, next_tag = Tag} = St, F, Head, Body) ->
    case modifiable(St, F) of
        false -> error;
        true  ->
            FS = maps:get(F, L, #fstate{}),
            FS1 = FS#fstate{assertz_rev = [{Tag, Head, Body} | FS#fstate.assertz_rev]},
            {ok, St#lp{local = L#{F => FS1}, next_tag = Tag + 1}}
    end.

retract_clause(#lp{out_db = #db{mod = M, ref = R}, local = L} = St, F, Tag) ->
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
    end.

abolish_clauses(#lp{out_db = #db{mod = M, ref = R}, local = L} = St, F) ->
    case M:get_procedure_type(R, F) of
        built_in -> error;
        _        -> {ok, St#lp{local = L#{F => #fstate{abolished = true}}}}
    end.

get_procedure(St, F) ->
    Base = raw_get_procedure(St, F),
    case is_tuple(F) andalso not St#lp.follow_disabled of
        true  -> add_followers(St, F, Base);     %% synthesize read-time link followers
        false -> Base                            %% non-tuple functor, or a strictly-local verdict
    end.

raw_get_procedure(#lp{out_db = #db{mod = M, ref = R}, local = L, read_ets = RS}, F) ->
    FS = maps:get(F, L, #fstate{}),
    A = FS#fstate.asserta, Z = lists:reverse(FS#fstate.assertz_rev),
    case FS#fstate.abolished of
        true  -> record_read(RS, F, M, R),
                 clauses_or_undef(A ++ Z);
        false ->
            case M:get_procedure(R, F) of
                built_in     -> built_in;
                {code, _} = C -> C;
                {clauses, Cs} ->
                    record_read(RS, F, M, R),
                    clauses_or_undef(A ++ filter_retracted(Cs, FS#fstate.retracted) ++ Z);
                undefined ->
                    record_read(RS, F, M, R),
                    clauses_or_undef(A ++ Z)
            end
    end.

%% A virtual follower is a LAST clause for every argument position. Its head only
%% matches a structured foreign name (Owner:Name), and its body strips that
%% prefix before asking the owner. The clauses never enter local, so they cannot
%% be committed or included in a content hash.
add_followers(_St, {no_follow, 1}, Base) -> Base;
add_followers(_St, _F, Base) when Base =:= built_in -> Base;
add_followers(_St, _F, {code, _} = Base) -> Base;
add_followers(St, {Functor, Arity} = F, Base)
  when is_atom(Functor), is_integer(Arity), Arity > 0 ->
    case no_follow(St, F) of
        true  -> Base;
        false -> clauses_or_undef(base_clauses(Base) ++ follower_clauses(F))
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

follower_clauses({Functor, Arity}) ->
    [follower_clause(Functor, Arity, Pos) || Pos <- lists:seq(1, Arity)] ++
    [follower_clear_clause(Functor, Arity),
     follower_end_clause(Functor, Arity)].

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

%% Keep one clause after cleanup so Erlog retains the relation choice point while
%% `$quod_follow_clear` recovers its stable label.
follower_clear_clause(Functor, Arity) ->
    Args = [{{'$quod_follow_end_arg', I}} || I <- lists:seq(1, Arity)],
    Head = list_to_tuple([Functor | Args]),
    Body = '$quod_follow_clear',
    {'$quod_follower_clear', Head, erlog_int:well_form_body(Body, false, sture)}.

follower_end_clause(Functor, Arity) ->
    Args = [{{'$quod_follow_fail_arg', I}} || I <- lists:seq(1, Arity)],
    Head = list_to_tuple([Functor | Args]),
    {'$quod_follower_end', Head, erlog_int:well_form_body(fail, false, sture)}.

replace_nth(1, Value, [_ | Tail]) -> [Value | Tail];
replace_nth(N, Value, [Head | Tail]) when N > 1 ->
    [Head | replace_nth(N - 1, Value, Tail)].

%% A type check must NOT record a read-set dependency (review #8): compute from the
%% committed type + local presence directly, never via the recording get_procedure/2.
get_procedure_type(#lp{out_db = #db{mod = M, ref = R}, local = L}, F) ->
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
    Locals = [F || {F, FS} <- maps:to_list(L),
                   FS#fstate.asserta =/= [] orelse FS#fstate.assertz_rev =/= []],
    All = lists:usort(M:get_interpreted_functors(R) ++ Locals),
    [F || F <- All, get_procedure_type(St, F) =:= interpreted].

%%%===================================================================
%%% internals
%%%===================================================================

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
%% local assert. Always capture that original committed hash; write-only operations use
%% modifiable/2 and never enter this path.
record_read(undefined, _F, _M, _R) -> ok;
record_read(Ets, F, M, R) ->
    case ets:member(Ets, F) of
        true  -> ok;
        false -> ets:insert(Ets, {F, quod_diff:functor_hash(M, R, F)}), ok
    end.
