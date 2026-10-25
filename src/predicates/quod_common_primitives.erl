-module(quod_common_primitives).
-moduledoc """
Common execution primitives available to every ontology's Prolog.

Proof mechanics installed by `m:quod_committed_projection` next to actions.
The assertion hook enters Prolog construction under the shared savepoint.
Generated identities are sealed as ordinary result data, like selected names;
validation consumes that material under the existing trusted execution boundary.

- `'$quod_instance_id'(-Id)` allocates a full ULID in a writable live proof:
  Unix milliseconds and 80 secure random bits, encoded as 26 Crockford bytes.
  Construction policy, collision refusal and dispatch remain Prolog rules.

- `'$quod_draw'(+Salt, +N, -I)` — the proof-bound draw. `I` is
  `hmac_sha256(ProofId, canonical(Salt)) mod N`, where `ProofId` is the
  32-byte identity the engine mints before the proof runs and binds into
  every sealed plan and committed transaction. Same proof, same salt, same
  `I`, in the origin worker and in every co-hosted or remote scope of that
  proof; a retried request is a new proof and draws afresh. Missing proof
  identity (verdict re-proofs, bare engines) fails plainly. An unbound salt or
  divisor, wrong divisor type/domain, or nonportable salt raises an error. Ontologies reach it through
  `proof_draw/3` in `common_predicates.pl`. It is deterministic selection:
  neither secure randomness nor a uniqueness guarantee.
- `'$quod_committed_check'(+Goal)` — a boolean, strictly local read-only
  policy check over the pinned committed base. Reuses custody authorization's
  evaluator and absorbs its read dependencies even on denial; never exports
  bindings or consults staged policy. The shared Prolog operation guard binds
  the authenticated actor before calling it.
- `'$quod_with_build_plan'(+Inputs, Goal)` and `'$quod_build_plan'(-Inputs)`
  carry temporary constructor inputs through private logical bindings. Prolog
  owns shape checks, inheritance and defaults. Scope release restores inputs on
  success, failure, redo and error; no facts, transaction mode or authority change.
- `binary_codes(?Binary, ?Codes)` — a binary and its byte list, either way
  round, so generated text stays a binary and never becomes an atom. Fails
  on unequal valid values; malformed arguments raise errors.
- `binary(?Value)` — type test, like `integer/1`; never binds its argument.
- `'$quod_voxel'(+Request, +Allowances, ?Result)` — versioned terrain
  arithmetic over explicit samples, recipes and current patches. No world
  lookup, policy, mutable cache or I/O; admission remains in the ontology.
  Invalid numerical inputs and exhausted allowances fail with their reason.
- `agent_request_bytes(+Intent, ?Bytes)` — encode an exact `agent_goal_v1`
  intent with the signed-request codec. No key access, signature, clock,
  submission or authority check; the bytes are inert data.
- `'$quod_predicate_source'(+Name/Arity, ?Source)` — canonical source of the
  ordered authored clauses in the current staged view, excluding generated
  following clauses. Facts print as `Head :- true`; a bound source compares
  exactly. Erlog's own `clause/2` decodes the compiled bodies, without exposing
  inspection variables in the caller's answer.
- `'$quod_source_indicator'(+Clause, ?Name/Arity)` — the callable head's
  indicator, including atom-safe names not yet materialized by admission.
- `'$quod_source_chunk'(+Selection, +Bytes, ?Chunk)` — stored interpreted clauses in
  the same staged snapshot, in canonical predicate order. Backtracking yields
  bounded binary chunks, including the final empty chunk for an empty state.
  Selection is `all`, `predicates(Indicators)` or `terms(SelectedData)`.
  The caller's ontology supplies the selection and transport allowance.
  An unbound, non-integer or nonpositive allowance raises an argument error;
  an unequal bound chunk remains ordinary failure.
- `'$quod_retract_exact'(+Clause)` — remove the first authored clause whose
  source is identical up to variable renaming. A fact is shorthand for
  `Head :- true`. It uses ordinary overlay mutations and savepoints, never
  unifies a requested specific clause with an earlier general clause.
- `'$quod_program_source'(?Clauses, ?Source)` — parse a binary program or
  format an ordered clause list. Variable scope restarts per clause. Parsing
  never creates atoms: new symbols remain data until the client submits its
  actual editing goal through ordinary signed admission. Invalid source fails
  with a bounded syntax/parser-resource reason through the ordinary diagnostics.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([load/1, draw_3/3, binary_codes_2/3, term_digest_2/3, variant_digest_2/3,
         ontology_name_2/3, binary_1/3, agent_request_bytes_2/3, signed_agent_request_3/3,
         predicate_source_2/3, source_chunk_3/3, source_indicator_2/3, retract_exact_1/3, program_source_2/3,
         authored_clauses/2, voxel_compute_3/3, committed_check_1/3,
         with_build_plan_2/3, build_plan_1/3, build_plan_return_1/3,
         assert_instance/4, instance_id_1/3]).

-define(DRAW, '$quod_draw').
-define(BINARY_CODES, binary_codes).
-define(BUILD_INPUTS, {{?MODULE, build_inputs}}).
-record(build_scope, {ref, previous, next}).

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
    Db5 = erlog_int:add_compiled_proc(
            {'$quod_source_chunk', 3}, ?MODULE, source_chunk_3, Db4),
    Db6 = erlog_int:add_compiled_proc(
            {'$quod_program_source', 2}, ?MODULE, program_source_2, Db5),
    Db7 = erlog_int:add_compiled_proc(
            {term_digest, 2}, ?MODULE, term_digest_2, Db6),
    Db8 = erlog_int:add_compiled_proc(
            {ontology_name, 2}, ?MODULE, ontology_name_2, Db7),
    Db9 = erlog_int:add_compiled_proc(
            {variant_digest, 2}, ?MODULE, variant_digest_2, Db8),
    Db10 = erlog_int:add_compiled_proc({binary, 1}, ?MODULE, binary_1, Db9),
    Db11 = erlog_int:add_compiled_proc(
        {'$quod_source_indicator', 2}, ?MODULE, source_indicator_2, Db10),
    Db12 = erlog_int:add_compiled_proc(
        {agent_request_bytes, 2}, ?MODULE, agent_request_bytes_2, Db11),
    Db13 = erlog_int:add_compiled_proc(
        {signed_agent_request, 3}, ?MODULE, signed_agent_request_3, Db12),
    Db14 = erlog_int:add_compiled_proc(
        {'$quod_committed_check', 1}, ?MODULE, committed_check_1, Db13),
    Db15 = erlog_int:add_compiled_proc(
        {'$quod_voxel', 3}, ?MODULE, voxel_compute_3, Db14),
    Db16 = erlog_int:add_compiled_proc(
        {'$quod_with_build_plan', 2}, ?MODULE, with_build_plan_2, Db15),
    Db17 = erlog_int:add_compiled_proc(
        {'$quod_build_plan', 1}, ?MODULE, build_plan_1, Db16),
    Db18 = erlog_int:add_compiled_proc(
        {'$quod_build_plan_return', 1}, ?MODULE, build_plan_return_1, Db17),
    Est#est{db = erlog_int:add_compiled_proc(
        {'$quod_instance_id', 1}, ?MODULE, instance_id_1, Db18)}.

%% Explicit clauses are authored source, including fact clauses (Head :- true).
%% Only bare membership assertions request the Prolog-owned live lifecycle.
assert_instance(Method, {':-', _, _} = Clause, Next, #est{db = Db} = St) ->
    Inserted = case Method of
        asserta -> erlog_int:asserta_clause(Clause, Db);
        _ -> erlog_int:assertz_clause(Clause, Db)
    end,
    erlog_int:prove_body(Next, St#est{db = Inserted});
assert_instance(Method, {instance_of, Class, Instance}, Next, St) ->
    quod_proof_savepoint:run(
        {'$quod_assert_instance', Method, Class, Instance}, Next, St,
        quod_erlog_db_local_prove:write_intent(St)).

%% Full ULID: 48-bit Unix milliseconds and 80 independently secure random bits.
%% The selected value travels as ordinary bindings/facts in the sealed result;
%% validators and projections apply that material, never call this allocator.
instance_id_1({'$quod_instance_id', Instance}, Next,
              #est{bs = Bs, db = #db{assert_hooks = Hooks}} = St) ->
    case {erlog_int:deref(Instance, Bs), proof_id(St),
          maps:is_key({instance_of, 2}, Hooks)} of
        {{_}, {ok, _}, true} ->
            Time = quod_time:now_ms(),
            true = Time >= 0 andalso Time < (1 bsl 48),
            <<Random:80>> = crypto:strong_rand_bytes(10),
            <<Value:128>> = <<Time:48, Random:80>>,
            Alphabet = <<"0123456789ABCDEFGHJKMNPQRSTVWXYZ">>,
            Id = << <<(binary:at(Alphabet, (Value bsr Shift) band 31))>>
                    || Shift <- lists:seq(125, 0, -5) >>,
            erlog_int:unify_prove_body(Instance, Id, Next, St);
        _ -> erlog_int:fail(St)
    end.

%% Inputs are ordinary proof-local bindings, never facts, flags or authority.
%% Choice points restore them on redo/cut. Only the scope's continuation and
%% error boundary need restoration; this control neither stages nor rolls back
%% writes and does not choose a transaction lane.
with_build_plan_2({'$quod_with_build_plan', Plan0, Goal}, Next,
                  #est{bs = Bs, vn = Vn, cps = Cps} = St) ->
    Plan = erlog_int:dderef(Plan0, Bs),
    Scope = #build_scope{ref = make_ref(), previous = build_inputs(Bs), next = Next},
    Boundary = #cp{type = compiled, label = {?MODULE, Scope#build_scope.ref},
                  next = Scope, bs = Bs, vn = Vn,
                  data = fun build_plan_failed/3},
    Active = set_build_inputs(Plan, St#est{cps = [Boundary | Cps]}),
    build_plan_step(fun() -> erlog_int:prove_body(
        [{call, Goal}, {'$quod_build_plan_return', Scope#build_scope.ref}], Active) end, Scope).

build_plan_1({'$quod_build_plan', Plan}, Next, #est{bs = Bs} = St) ->
    erlog_int:unify_prove_body(Plan, build_inputs(Bs), Next, St).

build_plan_return_1({'$quod_build_plan_return', Ref}, _,
                    #est{cps = Cps, bs = Bs, vn = Vn} = St) when is_reference(Ref) ->
    {ok, _, _, #build_scope{previous = Previous, next = Next} = Scope, _} =
        quod_proof_continuation:take_boundary({?MODULE, Ref}, Cps),
    Redo = #cp{type = compiled, next = Scope, bs = Bs, vn = Vn,
               data = fun build_plan_redo/3},
    Released = set_build_inputs(Previous, erlog_int:push_choicepoint(Redo, St)),
    quod_proof_continuation:prove(Ref, Next, Released).

build_plan_redo(#cp{next = Scope, bs = Bs, vn = Vn}, Cps, St) ->
    build_plan_step(fun() -> erlog_int:fail(St#est{bs = Bs, vn = Vn, cps = Cps}) end,
                    Scope).

build_plan_failed(#cp{next = #build_scope{ref = Ref}, bs = Bs, vn = Vn}, Cps, St) ->
    quod_proof_continuation:prove(Ref, [fail], St#est{bs = Bs, vn = Vn, cps = Cps}).

build_plan_step(Fun, #build_scope{ref = Ref, previous = Previous}) ->
    quod_proof_continuation:run(Ref, Fun, fun
        (throw, {erlog_error, Error, ErrorSt}, _, _) ->
            erlog_int:erlog_error(Error, set_build_inputs(Previous, ErrorSt));
        (Class, Reason, Stack, _) -> erlang:raise(Class, Reason, Stack)
    end, none).

build_inputs(Bs) ->
    case erlog_int:get_binding(?BUILD_INPUTS, Bs) of
        {ok, Plan} -> Plan;
        error -> []
    end.

set_build_inputs(Plan, #est{bs = Bs} = St) ->
    St#est{bs = erlog_int:add_binding(?BUILD_INPUTS, Plan, Bs)}.

%% Boolean only: policy bindings and staged mutations cannot escape this check.
committed_check_1({'$quod_committed_check', Goal0}, Next, #est{bs = Bs} = St) ->
    Goal = erlog_int:dderef(Goal0, Bs),
    case quod_wire_term:is_ground(Goal) of
        false -> erlog_int:instantiation_error(St);
        true ->
            case quod_ask:committed_authorization_result(Goal, St) of
                allowed -> erlog_int:prove_body(Next, St);
                denied -> erlog_int:fail(St);
                invalid -> erlog_int:erlog_error(invalid_committed_policy, St)
            end
    end.

%% Numerical data only: domain selection, permission and allocation remain in
%% the calling ontology. The same implementation serves retained consumers.
voxel_compute_3({'$quod_voxel', Request0, Limits0, Result}, Next, #est{bs = Bs} = St) ->
    Request = erlog_int:dderef(Request0,Bs),
    Limits = erlog_int:dderef(Limits0,Bs),
    case quod_wire_term:is_ground({Request,Limits}) of
        false -> erlog_int:instantiation_error(St);
        true ->
            Computed = case Request of
                {sample,Spec,Origin,Dimensions} -> quod_voxel:sample(Spec,Origin,Dimensions,Limits);
                {surface,Samples,Dimensions,Spacing} -> quod_voxel:surface(Samples,Dimensions,Spacing,Limits);
                {edit,Spec,Chunk,Patch,Brush} -> quod_voxel:edit(Spec,Chunk,Patch,Brush,Limits);
                {brush_chunks,Brush,Spacing} -> quod_voxel:brush_chunks(Brush,Spacing,Limits);
                {resident_chunks,Initial,Ranges} -> quod_voxel:resident_chunks(Initial,Ranges,Limits);
                {chunk,Spec,Chunk,Overrides} -> quod_voxel:chunk(Spec,Chunk,Overrides,Limits);
                {chunk_surface,Samples,Spacing} -> quod_voxel:chunk_surface(Samples,Spacing,Limits);
                _ -> {error,invalid_voxel_field}
            end,
            case Computed of
                {ok,Value} -> erlog_int:unify_prove_body(Result,Value,Next,St);
                {error,Reason} -> erlog_int:fail(erlog_int:add_failure_reason(Reason,St))
            end
    end.

agent_request_bytes_2({agent_request_bytes, Intent0, Bytes}, Next, #est{bs = Bs} = St) ->
    Intent = erlog_int:dderef(Intent0, Bs),
    case {quod_wire_term:is_ground(Intent), erlog_int:deref(Bytes, Bs)} of
        {false, Encoded} when is_binary(Encoded) ->
            case quod_client_goal:decode_typed(Encoded) of
                {ok, Typed} -> erlog_int:unify_prove_body(Intent0, Typed, Next, St);
                {error, _} -> erlog_int:domain_error(agent_request, Encoded, St)
            end;
        {false, _} -> erlog_int:instantiation_error(St);
        {true, _} -> case quod_client_goal:encode_typed(Intent) of
            {ok, _, Encoded} -> erlog_int:unify_prove_body(Bytes, Encoded, Next, St);
            {error, _} -> erlog_int:domain_error(agent_request, Intent, St)
        end
    end.

%% Cryptographic data verification only. Current keys, scope, delegation,
%% deadlines and allowed work remain the caller's Prolog policy.
signed_agent_request_3({signed_agent_request, Bytes0, Sig0, Typed}, Next, #est{bs = Bs} = St) ->
    [Bytes, Signature] = erlog_int:dderef([Bytes0, Sig0], Bs),
    case quod_client_goal:verify(Bytes, Signature) of
        {ok, _} -> agent_request_bytes_2({agent_request_bytes, Typed, Bytes}, Next, St);
        {error, _} -> erlog_int:fail(St)
    end.

binary_1({binary, Value}, Next, #est{bs = Bs} = St) ->
    case erlog_int:deref(Value, Bs) of
        B when is_binary(B) -> erlog_int:prove_body(Next, St);
        _ -> erlog_int:fail(St)
    end.

%% Hash a variable-bearing declaration modulo variable names, retaining the
%% canonical wire distinction between variables and authored '$VAR'/1 terms.
%% This does not bind the declaration or expose proof-local variable numbers.
variant_digest_2({variant_digest, Term0, Digest}, Next, #est{bs = Bs} = St) ->
    Term = erlog_int:dderef(Term0, Bs),
    {Canonical, _, _} = erlog_int:term_instance(Term, 0),
    case quod_wire_term:encode_canonical(Canonical) of
        {ok, Bytes} -> erlog_int:unify_prove_body(
            Digest, crypto:hash(sha256, Bytes), Next, St);
        {error, bad_term} -> erlog_int:domain_error(canonical_term, Term, St)
    end.

%% Pure name conversion shares the selector's grammar. Comparing configured
%% identities must not require opening a scope, or creating atoms from names.
ontology_name_2({ontology_name, Name0, Canonical}, Next, #est{bs = Bs} = St) ->
    Name = erlog_int:dderef(Name0, Bs),
    case quod_wire_term:is_ground(Name) of
        false -> erlog_int:instantiation_error(St);
        true -> case quod_ontology_name:flatten(Name) of
            error -> erlog_int:domain_error(ontology_name, Name, St);
            Binary -> erlog_int:unify_prove_body(Canonical, Binary, Next, St)
        end
    end.

%% Canonical symbols make the digest independent of local atom materialization.
term_digest_2({term_digest, Term0, Digest}, Next, #est{bs = Bs} = St) ->
    Term = erlog_int:dderef(Term0, Bs),
    case quod_wire_term:is_ground(Term) of
        false -> erlog_int:instantiation_error(St);
        true -> case quod_wire_term:encode_canonical(Term) of
            {ok, Bytes} -> erlog_int:unify_prove_body(
                               Digest, crypto:hash(sha256, Bytes), Next, St);
            {error, bad_term} -> erlog_int:domain_error(canonical_term, Term, St)
        end
    end.

%% Atom-safe clause grouping shares signed admission's callable alphabet.
source_indicator_2({'$quod_source_indicator', Clause0, Indicator}, Next,
                   #est{bs = Bs} = St) ->
    {':-', Head, _} = source_clause(erlog_int:dderef(Clause0, Bs)),
    case quod_wire_term:callable_functor(Head) of
        {ok, {Name, Arity}} -> erlog_int:unify_prove_body(
            Indicator, {'/', Name, Arity}, Next, St);
        error -> erlog_int:type_error(callable, Head, St)
    end.

source_chunk_3({'$quod_source_chunk', Selection0, Bytes0, Chunk}, Next,
               #est{bs = Bs} = St) ->
    case erlog_int:deref(Bytes0, Bs) of
        Bytes when is_integer(Bytes), Bytes > 0 ->
            Selection = erlog_int:dderef(Selection0, Bs),
            Clauses = selected_source(Selection, St),
            Text = iolist_to_binary([format_clause(C, St) || C <- Clauses]),
            erlog_int:prove_body([{member, Chunk, source_chunks(Text, Bytes)} | Next], St);
        {_} -> erlog_int:instantiation_error(St);
        Bytes when not is_integer(Bytes) -> erlog_int:type_error(integer, Bytes, St);
        Bytes -> erlog_int:domain_error(source_chunk_bytes, Bytes, St)
    end.

selected_source(all, St) ->
    #est{db = #db{mod = Module, ref = Ref}} =
        quod_erlog_db_local_prove:authored_state(St),
    lists:append([element(2, authored_clauses(F, St))
                  || F <- lists:sort(Module:get_interpreted_functors(Ref))]);
selected_source({predicates, Indicators}, St) when is_list(Indicators) ->
    lists:append([indicator_source(existing_symbols(I), St) || I <- Indicators]);
selected_source({terms, Terms}, _St) when is_list(Terms) -> Terms;
selected_source(Selection, St) ->
    erlog_int:domain_error(source_selection, Selection, St).

indicator_source({'/', Name, Arity}, St)
  when is_atom(Name), is_integer(Arity), Arity >= 0 ->
    element(2, authored_clauses({Name, Arity}, St));
indicator_source({'/', {'$quod_symbol', Name}, Arity}, _St)
  when is_binary(Name), is_integer(Arity), Arity >= 0 -> [];
indicator_source(Indicator, St) ->
    erlog_int:domain_error(predicate_indicator, Indicator, St).

source_chunks(Text, Bytes) when byte_size(Text) =< Bytes -> [{source_chunk, done, Text}];
source_chunks(Text, Bytes) ->
    <<Chunk:Bytes/binary, Rest/binary>> = Text,
    [{source_chunk, more, Chunk} | source_chunks(Rest, Bytes)].

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
                    erlog_int:fail(erlog_int:add_failure_reason(
                        {syntax_error, invalid_syntax}, St));
                {error, Reason} ->
                    erlog_int:fail(erlog_int:add_failure_reason(
                        {program_source_error, Reason}, St))
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
        Indicator ->
            case quod_wire_term:is_ground(Indicator) of
                false -> erlog_int:instantiation_error(St);
                true -> erlog_int:domain_error(predicate_indicator,Indicator,St)
            end
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
    Salt = erlog_int:dderef(Salt0,Bs), N = erlog_int:deref(N0,Bs),
    case proof_id(St) of
        error -> erlog_int:fail(St);
        {ok,ProofId} ->
            case quod_wire_term:is_ground([Salt,N]) of
                false -> erlog_int:instantiation_error(St);
                true when not is_integer(N) -> erlog_int:type_error(integer,N,St);
                true when N =< 0 -> erlog_int:domain_error(proof_draw_divisor,N,St);
                true ->
                    case quod_wire_term:encode_canonical(Salt) of
                        {ok,SaltBytes} ->
                            Mac = crypto:mac(hmac,sha256,ProofId,SaltBytes),
                            erlog_int:unify_prove_body(I0,binary:decode_unsigned(Mac) rem N,Next,St);
                        {error,_} -> erlog_int:domain_error(proof_salt,Salt,St)
                    end
            end
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
                        false ->
                            case quod_wire_term:is_ground(Codes) of
                                false -> erlog_int:instantiation_error(St);
                                true -> erlog_int:domain_error(byte_list,Codes,St)
                            end
                    end;
                {_} -> erlog_int:instantiation_error(St);
                Codes ->
                    case quod_wire_term:is_ground(Codes) of
                        false -> erlog_int:instantiation_error(St);
                        true -> erlog_int:type_error(list,Codes,St)
                    end
            end;
        Binary -> erlog_int:type_error(binary,Binary,St)
    end.

bytes([Code | Codes]) when is_integer(Code), Code >= 0, Code =< 255 ->
    bytes(Codes);
bytes([]) -> true;
bytes(_) -> false.
