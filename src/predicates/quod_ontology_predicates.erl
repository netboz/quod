-module(quod_ontology_predicates).
-moduledoc """
Thin Erlog boundary for local ontology creation.

`create_ontology/2` is an explicit live effect. It is available only while
executing `quod:root`; the handler checks that scope itself, then delegates all
validation, genesis, and lifecycle work to `m:quod_ontology`.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([create_ontology_predicate/3]).

-define(ROOT_NS, <<"quod:root">>).

-spec create_ontology_predicate(term(), term(), tuple()) -> term().
create_ontology_predicate(Goal, Next, #est{bs = Bs} = St) ->
    case quod_predicates:ctx_ns(quod_predicates:context(St)) of
        ?ROOT_NS ->
            create(erlog_int:dderef(Goal, Bs), Next, St);
        _ ->
            fail_with(root_only, St)
    end.

create({create_ontology, Name, InitialFacts}, Next, St)
  when is_list(InitialFacts) ->
    case quod_predicates:is_ground({Name, InitialFacts}) of
        false ->
            fail_with(invalid_arguments, St);
        true ->
            case quod_ontology:create(Name, InitialFacts) of
                {ok, _Status, _Ns, _GenesisHash} ->
                    erlog_int:prove_body(Next, St);
                {error, Reason} ->
                    fail_with(public_reason(Reason), St)
            end
    end;
create(_Goal, _Next, St) ->
    fail_with(invalid_arguments, St).

public_reason(invalid_name) -> invalid_name;
public_reason(reserved_system_namespace) -> reserved_system_namespace;
public_reason(invalid_initial_terms) -> invalid_initial_terms;
public_reason({invalid_initial_term, _Term}) -> invalid_initial_terms;
public_reason(_Reason) -> start_failed.

fail_with(Reason, St) ->
    erlog_int:prove_body(
      [{fail_with_reason, {ontology_creation_failed, Reason}}], St).
