-module(quod_diff).
-moduledoc """
Pure helpers over the committed erlog database for the content layer.

- `validate/2` — re-check a read-set against the MVCC handle at the change's
  position: `ok` if every predicate's exact mutation-version token
  (`quod_erlog_db_mvcc:version_token/2`, the same function the capture side in
  `m:quod_erlog_db_local_prove` records) still equals the recorded value, else
  `{conflict, Functor}` for a conflicting predicate. A recorded `staged`
  expectation is rejected outright: it is never a capturable token, and
  accepting it would invert the same-block read-after-write rejection.
- `apply_ops/2` — apply a `#transaction.diff` (`[op()]`) to the committed erlog state,
  normalizing legal source-form bodies to Erlog's durable compiled form, with
  content-identity dedup (asserting an identical fact is a no-op; retract is by content).
- `has_clause/4` — is a specific `{Head, Body}` clause present in the committed db? It
  performs the same body normalization as `apply_ops`, then uses the same content-identity
  check. The membership verdict uses it to prove that a removal names an exact clause.

`op()` and `clause()` are defined in `quod_ledger.hrl`; `#est{}`/`#db{}` in
`erlog_int.hrl`.
""".
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-export([validate/2, apply_ops/2, has_clause/4]).

-doc "`ok` if every predicate in `ReadCheck` still carries the recorded token, else `{conflict, F}` for a conflicting predicate.".
-spec validate(read_check(), quod_erlog_db_mvcc:ref()) -> ok | {conflict, term()}.
validate(ReadCheck, Ref) ->
    maps:fold(
      fun(_F, _Exp, {conflict, _} = C) -> C;
         (F, staged, ok) ->
              %% `staged` is never a capturable token; matching it against a
              %% same-block staged write would invert the deterministic
              %% read-after-write rejection into an accept.
              {conflict, F};
         (F, Exp, ok) ->
              case quod_erlog_db_mvcc:version_token(Ref, F) of
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
has_clause(M, R, H, B0) ->
    B = normalize_body(B0),
    clause_present(M, R, erlog_int:functor(H), H, B).

%%%===================================================================
%%% internals
%%%===================================================================

apply_op(M, R, {assert, Clause}) ->
    {H, B} = normalize_clause(Clause),
    F = erlog_int:functor(H),
    case clause_present(M, R, F, H, B) of
        true  -> R;                                   %% content dedup: no-op
        false -> case M:assertz_clause(R, F, H, B) of
                     {ok, R1} -> R1;
                     error    -> R
                 end
    end;
apply_op(M, R, {retract, Clause}) ->
    {H, B} = normalize_clause(Clause),
    F = erlog_int:functor(H),
    case find_tag(M, R, F, H, B) of
        {ok, Tag} -> case M:retract_clause(R, F, Tag) of
                         {ok, R1} -> R1;
                         error    -> R
                     end;
        none      -> R
    end.

%% Live proofs already emit Erlog's durable `{Code, HasCut}` body. Normalize the
%% legal source-body form accepted from explicitly constructed transactions so
%% every node stores and compares the same compiled clause representation.
normalize_clause({Head, Body}) -> {Head, normalize_body(Body)}.

normalize_body({Code, HasCut} = Body) when is_list(Code), is_boolean(HasCut) -> Body;
normalize_body(Body) -> erlog_int:well_form_body(Body, false, sture).

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
