-module(quod_ontology_predicates).
-moduledoc """
Thin Erlog boundary for local ontology creation, joining, and lifecycle state.

The two lifecycle adapters are explicit live effects. The state predicate is a
read-only view of this node. All three are available only while executing
`quod:root` and delegate their work to `m:quod_ontology`.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([create_ontology_effect_predicate/3,
         join_ontology_effect_predicate/3,
         ontology_join_state_predicate/3]).

-define(ROOT_NS, <<"quod:root">>).

-spec create_ontology_effect_predicate(term(), term(), tuple()) -> term().
create_ontology_effect_predicate(Goal, Next, #est{bs = Bs} = St) ->
    case quod_predicates:ctx_ns(quod_predicates:context(St)) of
        ?ROOT_NS ->
            create(erlog_int:dderef(Goal, Bs), Next, St);
        _ ->
            fail_with(ontology_creation_failed, root_only, St)
    end.

create({create_ontology_effect, Name, Options}, Next, St) ->
    case quod_predicates:is_ground({Name, Options}) of
        false ->
            fail_with(
              ontology_creation_failed, invalid_arguments, St);
        true ->
            case quod_ontology:create(Name, Options) of
                {ok, _Status, _Ns, _GenesisHash} ->
                    erlog_int:prove_body(Next, St);
                {error, Reason} ->
                    fail_with(
                      ontology_creation_failed,
                      creation_reason(Reason), St)
            end
    end;
create(_Goal, _Next, St) ->
    fail_with(ontology_creation_failed, invalid_arguments, St).

creation_reason(invalid_name) -> invalid_name;
creation_reason(reserved_system_namespace) -> reserved_system_namespace;
creation_reason(invalid_options) -> invalid_options;
creation_reason(invalid_initial_terms) -> invalid_initial_terms;
creation_reason({invalid_initial_term, _Term}) -> invalid_initial_terms;
creation_reason({source_error, Index, Line, _Detail}) ->
    {invalid_source, Index, Line};
creation_reason({source_file_error, Index, _Path, _Reason}) ->
    {source_file_error, Index};
creation_reason({already_configured, _Ns}) -> already_hosted;
creation_reason(_Reason) -> start_failed.

-spec join_ontology_effect_predicate(term(), term(), tuple()) -> term().
join_ontology_effect_predicate(Goal, Next, #est{bs = Bs} = St) ->
    case quod_predicates:ctx_ns(quod_predicates:context(St)) of
        ?ROOT_NS -> join(erlog_int:dderef(Goal, Bs), Next, St);
        _ -> fail_with(ontology_join_failed, root_only, St)
    end.

join({join_ontology_effect, Name, GenesisHash, Seeds}, Next, St) ->
    case quod_predicates:is_ground({Name, GenesisHash, Seeds}) of
        false ->
            fail_with(ontology_join_failed, invalid_arguments, St);
        true ->
            case quod_ontology:join(Name, GenesisHash, Seeds) of
                {ok, _Status, _Ns, _RawGenesisHash} ->
                    erlog_int:prove_body(Next, St);
                {error, Reason} ->
                    fail_with(
                      ontology_join_failed, join_reason(Reason), St)
            end
    end;
join(_Goal, _Next, St) ->
    fail_with(ontology_join_failed, invalid_arguments, St).

join_reason(invalid_name) -> invalid_name;
join_reason(reserved_system_namespace) -> reserved_system_namespace;
join_reason(invalid_genesis_hash) -> invalid_genesis_hash;
join_reason(invalid_seeds) -> invalid_seeds;
join_reason({already_configured, _Ns}) -> already_hosted;
join_reason(root_unavailable) -> root_unavailable;
join_reason(_Reason) -> start_failed.

-spec ontology_join_state_predicate(term(), term(), tuple()) -> term().
ontology_join_state_predicate(Goal, Next, #est{bs = Bs} = St) ->
    case quod_predicates:ctx_ns(quod_predicates:context(St)) of
        ?ROOT_NS -> state(erlog_int:dderef(Goal, Bs), Next, St);
        _ -> fail_with(ontology_state_failed, root_only, St)
    end.

state({ontology_join_state, Name, State}, Next, St) ->
    case quod_predicates:is_ground(Name) of
        false ->
            fail_with(ontology_state_failed, invalid_arguments, St);
        true ->
            case quod_ontology:local_state(Name) of
                {ok, LocalState} ->
                    erlog_int:prove_body(
                      [{'=', State, LocalState} | Next], St);
                {error, _Reason} ->
                    fail_with(ontology_state_failed, invalid_name, St)
            end
    end;
state(_Goal, _Next, St) ->
    fail_with(ontology_state_failed, invalid_arguments, St).

fail_with(Functor, Reason, St) ->
    erlog_int:prove_body(
      [{fail_with_reason, {Functor, Reason}}], St).
