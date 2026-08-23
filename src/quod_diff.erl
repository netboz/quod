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
- `valid_read_check/1` and `valid_ops/1` — total shape validation for the
  untrusted durable material consumed by both ordinary and distributed
  transactions.
- `apply_ops/2` — apply a `#transaction.diff` (`[op()]`) to the committed erlog state,
  normalizing legal source-form bodies to Erlog's durable compiled form, with
  content-identity dedup (asserting an identical fact is a no-op; retract is by content).
- `apply_ops_preserving_policy/2` — build that same immutable post-diff state and,
  only when the diff touches `{can_invoke,4}`, require the final state to retain
  at least one interpreted policy clause.
- `has_clause/4` — is a specific `{Head, Body}` clause present in the committed db? It
  performs the same body normalization as `apply_ops`, then uses the same content-identity
  check. The membership verdict uses it to prove that a removal names an exact clause.
- `interpreted_clauses/2` — read the exact stored clauses for one interpreted
  functor from a frozen `#est{}`. Runtime declaration reconciliation uses this
  instead of executing the predicate and accidentally treating derived answers
  as declarations.
- `touches_functor/2` — one exact clause-head check shared by immutable-manifest
  validation and root system-catalogue change detection.

`op()` and `clause()` are defined in `quod_ledger.hrl`; `#est{}`/`#db{}` in
`erlog_int.hrl`.
""".
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-export([valid_read_check/1, valid_ops/1,
         valid_event/1, valid_event_pattern/1,
         validate/2, apply_ops/2, apply_ops_report/2,
         apply_ops_preserving_policy/2,
         apply_ops_preserving_policy_report/2, has_clause/4,
         interpreted_clauses/2, touches_functor/2]).
-export([assertion_only/1, asserts_functor/2]).

-doc "Whether an untrusted read check uses only valid functor keys and durable MVCC tokens.".
-spec valid_read_check(term()) -> boolean().
valid_read_check(ReadCheck) when is_map(ReadCheck) ->
    maps:fold(
      fun({Functor, Arity}, Token, true) ->
              is_atom(Functor) andalso is_integer(Arity) andalso Arity >= 0
                  andalso valid_read_token(Token);
         (_Key, _Token, _Acc) ->
              false
      end, true, ReadCheck);
valid_read_check(_) -> false.

-doc "Whether an untrusted diff is a proper list of legal durable operations.".
-spec valid_ops(term()) -> boolean().
valid_ops([Op | Rest]) -> valid_op(Op) andalso valid_ops(Rest);
valid_ops([]) -> true;
valid_ops(_) -> false.

-doc "True when every operation in `Diff` is an assert — the only shape a genesis may carry.".
-spec assertion_only([op()]) -> boolean().
assertion_only([{assert, _} | Rest]) -> assertion_only(Rest);
assertion_only([]) -> true;
assertion_only(_) -> false.

-doc """
True when `Diff` asserts at least one clause whose head is `Functor`.

With `assertion_only/1` this is the pure genesis policy-presence invariant: a
founding diff must assert a `{can_invoke, 4}` head, so neither an
assert-then-retract trick nor a hand-built policy-less genesis can create an
ontology that denies the very proof that would give it a policy.
""".
-spec asserts_functor([op()], {atom(), non_neg_integer()}) -> boolean().
asserts_functor(Diff, Functor) ->
    lists:any(
      fun({assert, {Head, _Body}}) -> erlog_int:functor(Head) =:= Functor;
         (_) -> false
      end, Diff).

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
apply_ops(#est{} = Est, Ops) ->
    {ok, Est1, _AppliedOps} = apply_ops_report(Est, Ops),
    {ok, Est1}.

-doc "Apply a diff and return only the operations that changed the committed projection.".
-spec apply_ops_report(tuple(), [op()]) -> {ok, tuple(), [op()]}.
apply_ops_report(#est{db = #db{mod = M, ref = R0} = Db} = Est, Ops) ->
    {R1, RevApplied} =
        lists:foldl(
          fun(Op, {R, Applied}) ->
                  case apply_op(M, R, Op) of
                      {RNext, changed} -> {RNext, [normalize_op(Op) | Applied]};
                      {RNext, unchanged} -> {RNext, Applied}
                  end
          end, {R0, []}, Ops),
    {ok, Est#est{db = Db#db{ref = R1}}, lists:reverse(RevApplied)}.

-doc """
Apply `Ops`, rejecting a final state with no interpreted `can_invoke/4` clause.

Unrelated diffs return the already-built candidate without inspecting its
policy procedure. A touching diff is judged on that candidate's final state,
so an atomic replacement is valid regardless of operation order.
""".
-spec apply_ops_preserving_policy(tuple(), [op()]) ->
          {ok, tuple()} | {error, policy_self_seal_forbidden}.
apply_ops_preserving_policy(Est, Ops) ->
    case apply_ops_preserving_policy_report(Est, Ops) of
        {ok, Candidate, _AppliedOps} -> {ok, Candidate};
        {error, _} = Error -> Error
    end.

-doc "Policy-preserving apply with the exact operations that changed the projection.".
-spec apply_ops_preserving_policy_report(tuple(), [op()]) ->
          {ok, tuple(), [op()]} | {error, policy_self_seal_forbidden}.
apply_ops_preserving_policy_report(Est, Ops) ->
    {ok, Candidate, AppliedOps} = apply_ops_report(Est, Ops),
    case touches_functor(Ops, {can_invoke, 4}) of
        false -> {ok, Candidate, AppliedOps};
        true ->
            case require_interpreted_policy(Candidate) of
                {ok, Candidate} -> {ok, Candidate, AppliedOps};
                {error, _} = Error -> Error
            end
    end.

-doc "Is the exact `{Head, Body}` clause present in the committed db `Mod:Ref`? (Content identity.)".
-spec has_clause(module(), term(), term(), term()) -> boolean().
has_clause(M, R, H, B0) ->
    B = normalize_body(B0),
    clause_present(M, R, erlog_int:functor(H), H, B).

-doc "Return exact stored `{Head, Body}` clauses for one interpreted functor in a frozen snapshot.".
-spec interpreted_clauses(tuple(), {atom(), non_neg_integer()}) ->
          {ok, [clause()]} | {error, not_interpreted}.
interpreted_clauses(#est{db = #db{mod = M, ref = R}}, {F, A} = Functor)
  when is_atom(F), is_integer(A), A >= 0 ->
    case M:get_procedure(R, Functor) of
        {clauses, Clauses} ->
            {ok, [{Head, Body} || {_Tag, Head, Body} <- Clauses]};
        undefined ->
            {ok, []};
        _BuiltInOrCompiled ->
            {error, not_interpreted}
    end;
interpreted_clauses(_Est, _Functor) ->
    {error, not_interpreted}.

%%%===================================================================
%%% internals
%%%===================================================================

valid_read_token(never_present) -> true;
valid_read_token(static) -> true;
valid_read_token({present, Slot}) -> is_integer(Slot) andalso Slot >= 0;
valid_read_token({absent, Slot}) -> is_integer(Slot) andalso Slot >= 0;
valid_read_token(_) -> false.

valid_op({Kind, {Head, Body}}) when Kind =:= assert; Kind =:= retract ->
    callable_head(Head) andalso valid_stored_term(Head) andalso valid_clause_body(Body);
valid_op({event, Term}) ->
    valid_event(Term);
valid_op(_) -> false.

-doc "Whether one concrete explicit event is ground and valid on the bounded wire.".
-spec valid_event(term()) -> boolean().
valid_event(Term) ->
    quod_wire_term:is_ground(Term) andalso valid_event_pattern(Term).

-doc "Whether one possibly-variable bare explicit-event pattern is valid.".
-spec valid_event_pattern(term()) -> boolean().
valid_event_pattern(Term) ->
    callable_head(Term)
        andalso not reserved_event_wrapper(Term)
        andalso valid_wire_term(Term).

reserved_event_wrapper({assert, _}) -> true;
reserved_event_wrapper({retract, _}) -> true;
reserved_event_wrapper({from, _, _, _}) -> true;
reserved_event_wrapper(_) -> false.

valid_wire_term(Term) ->
    case quod_wire_term:encode(Term) of
        {ok, _} -> true;
        {error, bad_term} -> false
    end.

callable_head(Head) when is_atom(Head) -> true;
callable_head(Head) when is_tuple(Head), tuple_size(Head) >= 2 ->
    is_atom(element(1, Head));
callable_head(_) -> false.

%% Erlog stores clause bodies in compiled `{Code, HasCut}` form. Explicitly
%% constructed transactions may carry a legal source body instead; apply_ops/2
%% normalizes it deterministically before applying it. Validate both forms fully.
valid_clause_body(Body) -> valid_compiled_body(Body) orelse valid_raw_body(Body).

valid_compiled_body({Code, HasCut}) when is_boolean(HasCut) -> valid_code(Code);
valid_compiled_body(_) -> false.

valid_code([Instruction | Rest]) -> valid_instruction(Instruction) andalso valid_code(Rest);
valid_code([]) -> true;
valid_code(_) -> false.

valid_instruction({{disj}, Left, Right}) ->
    valid_code(Left) andalso valid_code(Right);
valid_instruction({{if_then}, Cond, Then, Label}) ->
    valid_code(Cond) andalso valid_code(Then) andalso valid_code_label(Label);
valid_instruction({{if_then_else}, Cond, Then, Else, Label}) ->
    valid_code(Cond) andalso valid_code(Then) andalso valid_code(Else)
        andalso valid_code_label(Label);
valid_instruction({{once}, Goal, Label}) ->
    valid_code(Goal) andalso valid_code_label(Label);
valid_instruction({{cut}, Label, Last}) ->
    valid_code_label(Label) andalso is_boolean(Last);
valid_instruction({call, {Variable}}) ->
    valid_variable(Variable);
valid_instruction(Goal) ->
    callable_head(Goal) andalso valid_stored_term(Goal).

valid_raw_body(Body) -> callable_body(Body) andalso valid_stored_term(Body).

callable_body(Body) when is_atom(Body) -> true;
callable_body({Variable}) -> valid_variable(Variable);
callable_body(Body) -> callable_head(Body).

valid_code_label(Label) -> is_atom(Label) orelse (is_integer(Label) andalso Label >= 0).
valid_variable(Variable) -> is_atom(Variable) orelse (is_integer(Variable) andalso Variable >= 0).

%% Stored clauses use integer variable ids after compilation (`{0}`, `{1}`, ...),
%% while source terms use atom ids. Erlog's public `is_legal_term/1` only accepts
%% the latter, so the durable representation needs this small explicit walker.
valid_stored_term({Variable}) -> valid_variable(Variable);
valid_stored_term(Term) when is_tuple(Term), tuple_size(Term) >= 2,
                             is_atom(element(1, Term)) ->
    valid_tuple_args(Term, 2, tuple_size(Term));
valid_stored_term([Head | Tail]) ->
    valid_stored_term(Head) andalso valid_stored_term(Tail);
valid_stored_term(Term) ->
    not is_tuple(Term) andalso not (is_list(Term) andalso Term =/= []).

valid_tuple_args(_Term, Index, Size) when Index > Size -> true;
valid_tuple_args(Term, Index, Size) ->
    valid_stored_term(element(Index, Term))
        andalso valid_tuple_args(Term, Index + 1, Size).

apply_op(M, R, {assert, Clause}) ->
    {H, B} = normalize_clause(Clause),
    F = erlog_int:functor(H),
    case clause_present(M, R, F, H, B) of
        true  -> {R, unchanged};                       %% content dedup: no-op
        false -> case M:assertz_clause(R, F, H, B) of
                     {ok, R1} -> {R1, changed};
                     error    -> {R, unchanged}
                 end
    end;
apply_op(M, R, {retract, Clause}) ->
    {H, B} = normalize_clause(Clause),
    F = erlog_int:functor(H),
    case find_tag(M, R, F, H, B) of
        {ok, Tag} -> case M:retract_clause(R, F, Tag) of
                         {ok, R1} -> {R1, changed};
                         error    -> {R, unchanged}
                     end;
        none      -> {R, unchanged}
    end;
apply_op(_M, R, {event, _Term}) ->
    {R, changed}.

normalize_op({Kind, Clause}) when Kind =:= assert; Kind =:= retract ->
    {Kind, normalize_clause(Clause)};
normalize_op({event, Term}) ->
    {event, Term}.

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

-doc "Whether a diff asserts or retracts any clause with the exact functor.".
-spec touches_functor(list(), {atom(), arity()}) -> boolean().
touches_functor(Ops, Functor) when is_list(Ops) ->
    lists:any(
      fun({assert, {Head, _Body}}) -> erlog_int:functor(Head) =:= Functor;
         ({retract, {Head, _Body}}) -> erlog_int:functor(Head) =:= Functor;
         (_) -> false
      end, Ops).

require_interpreted_policy(
  #est{db = #db{mod = M, ref = R}} = Candidate) ->
    case M:get_procedure(R, {can_invoke, 4}) of
        {clauses, [_ | _]} -> {ok, Candidate};
        _ -> {error, policy_self_seal_forbidden}
    end.
