-module(quod_diff).
-moduledoc """
Pure helpers over the committed erlog database for the content layer.

- `functor_hash/3` — a content hash of one predicate `{Functor, Arity}` (the
  `{Head, Body}` list, tags stripped). The read-set captured by
  `m:quod_erlog_db_local_prove` uses *this* function, and `quod_prolog`'s
  apply-time OCC re-check uses it too, so producer and validator agree exactly.
- `validate/3` — re-check a read-set against the committed db: `ok` if every
  predicate still hashes to the recorded value, else `{conflict, Functor}`.
- `apply_ops/2` — apply a `#transaction.diff` (`[op()]`) to the committed erlog state,
  with content-identity dedup (asserting an identical fact is a no-op; retract is
  by content).
- `has_clause/4` — is a specific `{Head, Body}` clause present in the committed db? The
  content-identity check `apply_ops` uses for retract, exposed for the membership verdict
  (a `retract(peer_admitted(...))` is only a real removal if that exact clause exists).

`op()` and `clause()` are defined in `quod_ledger.hrl`; `#est{}`/`#db{}` in
`erlog_int.hrl`.
""".
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-export([functor_hash/3, validate/3, apply_ops/2, has_clause/4]).

-doc "Content hash of predicate `F` in the db `Mod:Ref` ({Head,Body} list, tags dropped).".
-spec functor_hash(module(), term(), term()) -> integer().
functor_hash(Mod, Ref, F) ->
    case Mod:get_procedure(Ref, F) of
        {clauses, Cs} -> erlang:phash2([{H, B} || {_Tag, H, B} <- Cs]);
        undefined     -> erlang:phash2(undefined);
        _             -> erlang:phash2(immutable)   %% built_in / compiled — unwritable
    end.

-doc "`ok` if every predicate in `ReadCheck` still hashes as recorded, else the first `{conflict, F}`.".
-spec validate(read_check(), module(), term()) -> ok | {conflict, term()}.
validate(ReadCheck, Mod, Ref) ->
    maps:fold(
      fun(_F, _Exp, {conflict, _} = C) -> C;
         (F, Exp, ok) ->
              case functor_hash(Mod, Ref, F) of
                  Exp -> ok;
                  _   -> {conflict, F}
              end
      end, ok, ReadCheck).

-doc "Apply a diff (`[op()]`) to a committed erlog state, with content-identity dedup.".
-spec apply_ops(tuple(), [op()]) -> {ok, tuple()}.
apply_ops(#est{db = #db{mod = M, ref = R0} = Db} = Est, Ops) ->
    R1 = lists:foldl(fun(Op, R) -> apply_op(M, R, Op) end, R0, Ops),
    {ok, Est#est{db = Db#db{ref = R1}}}.

-doc "Is the exact `{Head, Body}` clause present in the committed db `Mod:Ref`? (Content identity.)".
-spec has_clause(module(), term(), term(), term()) -> boolean().
has_clause(M, R, H, B) -> clause_present(M, R, erlog_int:functor(H), H, B).

%%%===================================================================
%%% internals
%%%===================================================================

apply_op(M, R, {assert, {H, B}}) ->
    F = erlog_int:functor(H),
    case clause_present(M, R, F, H, B) of
        true  -> R;                                   %% content dedup: no-op
        false -> case M:assertz_clause(R, F, H, B) of
                     {ok, R1} -> R1;
                     error    -> R
                 end
    end;
apply_op(M, R, {retract, {H, B}}) ->
    F = erlog_int:functor(H),
    case find_tag(M, R, F, H, B) of
        {ok, Tag} -> case M:retract_clause(R, F, Tag) of
                         {ok, R1} -> R1;
                         error    -> R
                     end;
        none      -> R
    end.

clause_present(M, R, F, H, B) ->
    case find_tag(M, R, F, H, B) of {ok, _} -> true; none -> false end.

find_tag(M, R, F, H, B) ->
    case M:get_procedure(R, F) of
        {clauses, Cs} ->
            case lists:search(fun({_T, H2, B2}) -> H2 =:= H andalso B2 =:= B end, Cs) of
                {value, {Tag, _, _}} -> {ok, Tag};
                false                -> none
            end;
        _ -> none
    end.
