-module(quod_common_primitives).
-moduledoc """
Common execution primitives available to every ontology's Prolog.

Local proof helpers with no reality behind them, installed by
`m:quod_committed_projection` next to the action mechanics. They are not
governed bridges (`m:quod_predicates`): neither reads node state, so a plan
that used them stays sealable.

- `'$quod_draw'(+Salt, +N, -I)` — the proof-bound draw. `I` is
  `hmac_sha256(ProofId, canonical(Salt)) mod N`, where `ProofId` is the
  32-byte identity the engine mints before the proof runs and binds into
  every sealed plan and committed transaction. Same proof, same salt, same
  `I`, in the origin worker and in every co-hosted or remote scope of that
  proof; a retried request is a new proof and draws afresh. Fails plainly
  (never errors) when `N` is not a positive integer, `Salt` is not ground,
  the context kind is not `proof`, or the state carries no proof identity
  (verdict re-proofs, bare engines). Ontologies reach it through
  `proof_draw/3` in `common_predicates.pl`. It is deterministic selection:
  neither secure randomness nor a uniqueness guarantee.
- `binary_codes(?Binary, ?Codes)` — a binary and its byte list, either way
  round, so generated text stays a binary and never becomes an atom. Fails
  plainly for anything that is not a binary or a list of bytes.
- `'$quod_predicate_source'(+Name/Arity, ?Source)` — canonical source of the
  ordered authored clauses in the current staged view, excluding generated
  following clauses. Facts print as `Head :- true`; a bound source compares
  exactly. Erlog's own `clause/2` decodes the compiled bodies, without exposing
  inspection variables in the caller's answer.
- `'$quod_retract_exact'(+Clause)` — remove the first authored clause whose
  source is identical up to variable renaming. A fact is shorthand for
  `Head :- true`. It uses ordinary overlay mutations and savepoints, never
  unifies a requested specific clause with an earlier general clause.
- `'$quod_program_source'(?Clauses, ?Source)` — parse a binary program or
  format an ordered clause list. Variable scope restarts per clause. Parsing
  never creates atoms: new symbols remain data until the client submits its
  actual editing goal through ordinary signed admission.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([load/1, draw_3/3, binary_codes_2/3,
         predicate_source_2/3, retract_exact_1/3, program_source_2/3,
         authored_clauses/2]).

-define(DRAW, '$quod_draw').
-define(BINARY_CODES, binary_codes).

-doc "Install the common primitives into a base engine state.".
-spec load(tuple()) -> tuple().
load(#est{db = Db0} = Est) ->
    Db1 = erlog_int:add_compiled_proc({?DRAW, 3}, ?MODULE, draw_3, Db0),
    Db2 = erlog_int:add_compiled_proc(
            {?BINARY_CODES, 2}, ?MODULE, binary_codes_2, Db1),
    Db3 = erlog_int:add_compiled_proc(
            {'$quod_predicate_source', 2}, ?MODULE, predicate_source_2, Db2),
    Db4 = erlog_int:add_compiled_proc(
            {'$quod_retract_exact', 1}, ?MODULE, retract_exact_1, Db3),
    Est#est{db = erlog_int:add_compiled_proc(
                   {'$quod_program_source', 2}, ?MODULE, program_source_2, Db4)}.

program_source_2({'$quod_program_source', Clauses, Source0}, Next,
                 #est{bs = Bs, vn = Vn} = St) ->
    case erlog_int:deref(Source0, Bs) of
        Source when is_binary(Source) ->
            case quod_client_goal_parser:parse_program(Source, 3) of
                {ok, Parsed} ->
                    {Fresh, NextVn} = fresh_program(Parsed, Vn),
                    erlog_int:unify_prove_body(
                      Clauses, Fresh, Next, St#est{vn = NextVn});
                {error, invalid_syntax} ->
                    erlog_int:erlog_error({syntax_error, invalid_syntax}, St);
                {error, Reason} ->
                    erlog_int:erlog_error({program_source_error, Reason}, St)
            end;
        {_} ->
            case erlog_int:dderef(Clauses, Bs) of
                Program when is_list(Program) ->
                    Text = iolist_to_binary([format_clause(C, St) || C <- Program]),
                    erlog_int:unify_prove_body(Source0, Text, Next, St);
                _ -> erlog_int:instantiation_error(St)
            end;
        _ -> erlog_int:type_error(binary, Source0, St)
    end.

fresh_program([#{goal := Clause} | Tail], Vn) ->
    {Fresh, _Variables, Vn1} = erlog_int:term_instance(existing_symbols(Clause), Vn),
    {Rest, Vn2} = fresh_program(Tail, Vn1),
    {[Fresh | Rest], Vn2};
fresh_program([], Vn) -> {[], Vn}.

format_clause(Clause, St) ->
    case quod_client_goal_parser:format_clause(canonical_source(Clause)) of
        {ok, Text} -> [Text, $\n];
        {error, Reason} -> erlog_int:erlog_error({program_format, Reason}, St)
    end.

predicate_source_2({'$quod_predicate_source', Indicator0, Source}, Next,
                   #est{bs = Bs} = St) ->
    case existing_symbols(erlog_int:dderef(Indicator0, Bs)) of
        {'/', Name, Arity} when is_atom(Name), is_integer(Arity), Arity >= 0 ->
            {_Tags, Sources} = authored_clauses({Name, Arity}, St),
            Text = iolist_to_binary([format_clause(C, St) || C <- Sources]),
            erlog_int:unify_prove_body(Source, Text, Next, St);
        {'/', {'$quod_symbol', Name}, Arity}
          when is_binary(Name), is_integer(Arity), Arity >= 0 ->
            %% A name absent from the VM cannot name stored callable clauses.
            %% Reading its empty baseline must not allocate an atom. Ordinary
            %% signed edit admission later allocates and tracks the functor.
            erlog_int:unify_prove_body(Source, <<>>, Next, St);
        _ -> erlog_int:fail(St)
    end.

retract_exact_1({'$quod_retract_exact', Clause0}, Next,
                #est{bs = Bs, db = Db} = St) ->
    Clause = source_clause(existing_symbols(erlog_int:dderef(Clause0, Bs))),
    {':-', Head, _Body} = Clause,
    Functor = erlog_int:functor(Head),
    {Tags, Sources} = authored_clauses(Functor, St),
    case exact_tag(Tags, Sources, source_key(Clause)) of
        none -> erlog_int:fail(St);
        {ok, Tag} ->
            case maps:find(Functor, Db#db.retract_hooks) of
                {ok, {Module, Function}} ->
                    Module:Function(retract, Head, Tag, Next, St);
                error ->
                    Updated = erlog_int:retract_clause(Functor, Tag, Db),
                    erlog_int:prove_body(Next, St#est{db = Updated})
            end
    end.

%% The nested clause query shares the caller's overlay and monotonic read set.
%% Its local-only view and fresh bindings never replace the caller's view.
authored_clauses({Name, Arity} = Functor, St) ->
    #est{db = #db{mod = Module, ref = Ref}} =
        Authored = quod_erlog_db_local_prove:authored_state(St),
    case Module:get_procedure(Ref, Functor) of
        undefined -> {[], []};
        {clauses, Stored} ->
            Head = case Arity of
                       0 -> Name;
                       _ -> list_to_tuple([Name | erlog_int:make_var_list(Arity, 0)])
                   end,
            Body = {Arity}, List = {Arity + 1},
            Goal = {findall, {':-', Head, Body}, {clause, Head, Body}, List},
            {succeed, Result} = erlog_int:prove_goal(Goal, Authored),
            {[Tag || {Tag, _, _} <- Stored], erlog_int:dderef(List, Result#est.bs)};
        _ -> erlog_int:permission_error(access, private_procedure,
                                        {'/', Name, Arity}, St)
    end.

source_clause({':-', _, _} = Clause) -> Clause;
source_clause(Head) -> {':-', Head, true}.

canonical_source(Clause) ->
    {Canonical, _Variables, _NextVn} = erlog_int:term_instance(Clause, 0),
    Canonical.

source_key(Clause) ->
    {ok, Encoded} = quod_wire_term:encode_canonical(canonical_source(Clause)),
    Encoded.

existing_symbols(Term) ->
    {ok, Wire} = quod_wire_term:encode(Term),
    {ok, Existing} = quod_wire_term:decode(Wire),
    Existing.

exact_tag([Tag | Tags], [Source | Sources], Wanted) ->
    case source_key(Source) of
        Wanted -> {ok, Tag};
        _ -> exact_tag(Tags, Sources, Wanted)
    end;
exact_tag([], [], _Wanted) -> none.

-spec draw_3(term(), list(), tuple()) -> term().
draw_3({?DRAW, Salt0, N0, I0}, Next, #est{bs = Bs} = St) ->
    Salt = erlog_int:dderef(Salt0, Bs),
    case {erlog_int:deref(N0, Bs), proof_id(St)} of
        {N, {ok, ProofId}} when is_integer(N), N > 0 ->
            case quod_wire_term:is_ground(Salt)
                 andalso quod_wire_term:encode_canonical(Salt) of
                {ok, SaltBytes} ->
                    Mac = crypto:mac(hmac, sha256, ProofId, SaltBytes),
                    erlog_int:unify_prove_body(
                      I0, binary:decode_unsigned(Mac) rem N, Next, St);
                _ ->
                    erlog_int:fail(St)
            end;
        _ ->
            erlog_int:fail(St)
    end.

%% The proof identity lives where the engine put it: the origin worker keeps
%% it in its proof context, a co-hosted or remote scope worker carries it in
%% the session metadata the engine opened the scope with. Content can forge
%% neither. Anything else — no session, a verdict engine — is not a proof.
proof_id(St) ->
    case quod_predicates:ctx_kind(quod_predicates:context(St)) of
        proof ->
            try quod_proof_session:context(St) of
                {origin, _} ->
                    try {ok, quod_proof_context:proof_id()}
                    catch error:no_proof_context -> error
                    end;
                {scope, ProofId, _Origin, _Ref, _ScopeId}
                  when is_binary(ProofId), byte_size(ProofId) =:= 32 ->
                    {ok, ProofId};
                _ ->
                    error
            catch error:badarg -> error
            end;
        _ ->
            error
    end.

-spec binary_codes_2(term(), list(), tuple()) -> term().
binary_codes_2({?BINARY_CODES, Binary0, Codes0}, Next, #est{bs = Bs} = St) ->
    case erlog_int:deref(Binary0, Bs) of
        Binary when is_binary(Binary) ->
            erlog_int:unify_prove_body(
              Codes0, binary_to_list(Binary), Next, St);
        {_} ->
            case erlog_int:dderef(Codes0, Bs) of
                Codes when is_list(Codes) ->
                    case bytes(Codes) of
                        true -> erlog_int:unify_prove_body(
                                  Binary0, list_to_binary(Codes), Next, St);
                        false -> erlog_int:fail(St)
                    end;
                _ ->
                    erlog_int:fail(St)
            end;
        _ ->
            erlog_int:fail(St)
    end.

bytes([Code | Codes]) when is_integer(Code), Code >= 0, Code =< 255 ->
    bytes(Codes);
bytes([]) -> true;
bytes(_) -> false.
