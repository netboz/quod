-module(quod_ontology_predicates).
-moduledoc """
The governed Prolog boundary for node-local ontology lifecycle policy and
state.

`authorized_ontology_lifecycle/1` is an action-only authorization check. It
reads the engine-owned lifecycle principal from the private proof overlay and
proves root policy against an isolated, read-only committed view. It never
performs lifecycle IO. The actual create/join call is made only by
`quod_prolog:run_action/2` after the complete action proof succeeds.

`ontology_join_state/2` remains a read-only view of this node. The low-level
`quod_ontology` APIs and `execute_prepared/2` are trusted same-VM APIs, not
remote authorization boundaries.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([authorized_ontology_lifecycle_predicate/3,
         ontology_join_state_predicate/3,
         ontology_genesis_anchor_predicate/3]).
-export([authorize_lifecycle/5,
         execute_prepared/2, lifecycle_error/2, failure_reason/2]).

-define(ROOT_NS, <<"quod:root">>).

-spec authorized_ontology_lifecycle_predicate(term(), term(), tuple()) -> term().
authorized_ontology_lifecycle_predicate(Goal, Next, #est{bs = Bs} = St) ->
    case quod_predicates:ctx_ns(quod_predicates:context(St)) of
        ?ROOT_NS ->
            authorize_predicate(erlog_int:dderef(Goal, Bs), Next, St);
        _ ->
            fail_reason(action_failure(Goal, root_only), St)
    end.

authorize_predicate({authorized_ontology_lifecycle, Action}, Next, St) ->
    case quod_predicates:is_ground(Action) of
        false ->
            fail_reason(failure_reason(Action, invalid_arguments), St);
        true ->
            case quod_erlog_db_local_prove:lifecycle_principal(St) of
                {ok, Principal} ->
                    Base = quod_erlog_db_local_prove:committed_state(St),
                    Ctx = quod_predicates:context(St),
                    case authorize_lifecycle(
                           Action, Principal, Base,
                           quod_predicates:ctx_ns(Ctx),
                           quod_predicates:ctx_height(Ctx)) of
                        ok -> erlog_int:prove_body(Next, St);
                        {error, Reason} -> fail_reason(Reason, St)
                    end;
                undefined ->
                    fail_reason(failure_reason(Action, not_authorized), St)
            end
    end;
authorize_predicate(_Goal, _Next, St) ->
    fail_reason({ontology_lifecycle_failed, invalid_arguments}, St).

-doc """
Authorize one already-ground lifecycle action against the captured committed
root state. The node principal is engine-owned; callers cannot supply it
through Prolog. Policy runs in the existing strictly-local verdict context and
through the overlay's read-only mode.
""".
-spec authorize_lifecycle(term(), term(), tuple(), binary(), non_neg_integer()) ->
          ok | {error, term()}.
authorize_lifecycle(Action, {node, NodeKey} = Principal, CommittedEst,
                    ?ROOT_NS, Height)
  when is_binary(NodeKey), byte_size(NodeKey) =:= 32,
       is_integer(Height), Height >= 0 ->
    case policy_goal(Action, Principal) of
        {ok, Goal} ->
            VerdictEst = verdict_state(CommittedEst, Height),
            case quod_prolog:prove_est_read_only(Goal, VerdictEst) of
                {ok, _Bindings, [], _ReadSet} -> ok;
                _ -> {error, failure_reason(Action, not_authorized)}
            end;
        error ->
            {error, failure_reason(Action, invalid_arguments)}
    end;
authorize_lifecycle(Action, _Principal, _CommittedEst, _Ns, _Height) ->
    {error, failure_reason(Action, not_authorized)}.

policy_goal({create_ontology, Name, Options}, Principal) ->
    {ok, {can_create_ontology, Principal, Name, Options}};
policy_goal({join_ontology, Name, GenesisHash, Seeds}, Principal) ->
    {ok, {can_join_ontology, Principal, Name, GenesisHash, Seeds}};
policy_goal(_Action, _Principal) ->
    error.

verdict_state(CommittedEst, Height) ->
    quod_predicates:set_context(
      CommittedEst,
      quod_predicates:verdict_context(?ROOT_NS, Height)).

-doc "Execute one previously prepared lifecycle request without rereading its input.".
-spec execute_prepared(term(), term()) -> ok | {error, term()}.
execute_prepared(Action, Prepared) ->
    case quod_ontology:execute_prepared(Prepared) of
        {ok, _Status, _Ns, _RawGenesisHash} -> ok;
        {error, outcome_unknown} -> {error, outcome_unknown};
        {error, Reason} -> {error, lifecycle_error(Action, Reason)}
    end.

-doc "Map a typed lifecycle API error to its bounded public Prolog reason.".
-spec lifecycle_error(term(), term()) -> term().
lifecycle_error({create_ontology, _, _} = Action, Reason) ->
    failure_reason(Action, creation_reason(Reason));
lifecycle_error({join_ontology, _, _, _} = Action, Reason) ->
    failure_reason(Action, join_reason(Reason));
lifecycle_error(Action, _Reason) ->
    failure_reason(Action, invalid_action).

-spec failure_reason(term(), term()) -> term().
failure_reason({create_ontology, _, _}, Reason) ->
    {ontology_creation_failed, Reason};
failure_reason({join_ontology, _, _, _}, Reason) ->
    {ontology_join_failed, Reason};
failure_reason(_Action, Reason) ->
    {ontology_lifecycle_failed, Reason}.

action_failure({authorized_ontology_lifecycle, Action}, Reason) ->
    failure_reason(Action, Reason);
action_failure(_Goal, Reason) ->
    {ontology_lifecycle_failed, Reason}.

creation_reason(invalid_name) -> invalid_name;
creation_reason(reserved_system_namespace) -> reserved_system_namespace;
creation_reason(invalid_options) -> invalid_options;
creation_reason(invalid_initial_terms) -> invalid_initial_terms;
creation_reason(initial_content_too_large) -> initial_content_too_large;
creation_reason({invalid_initial_term, _Term}) -> invalid_initial_terms;
creation_reason({source_error, Index, Line, _Detail}) ->
    {invalid_source, Index, Line};
creation_reason({source_file_error, Index, _Path, _Reason}) ->
    {source_file_error, Index};
creation_reason({already_configured, _Ns}) -> already_hosted;
creation_reason(_Reason) -> start_failed.

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
        _ -> fail_reason({ontology_state_failed, root_only}, St)
    end.

state({ontology_join_state, Name, State}, Next, St) ->
    case quod_predicates:is_ground(Name) of
        false ->
            fail_reason({ontology_state_failed, invalid_arguments}, St);
        true ->
            case quod_ontology:local_state(Name) of
                {ok, LocalState} ->
                    erlog_int:prove_body(
                      [{'=', State, LocalState} | Next], St);
                {error, _Reason} ->
                    fail_reason({ontology_state_failed, invalid_name}, St)
            end
    end;
state(_Goal, _Next, St) ->
    fail_reason({ontology_state_failed, invalid_arguments}, St).

-spec ontology_genesis_anchor_predicate(term(), term(), tuple()) -> term().
ontology_genesis_anchor_predicate(Goal, Next, #est{bs = Bs} = St) ->
    case quod_predicates:ctx_ns(quod_predicates:context(St)) of
        ?ROOT_NS -> genesis_anchor(erlog_int:dderef(Goal, Bs), Next, St);
        _ -> fail_reason({ontology_anchor_failed, root_only}, St)
    end.

genesis_anchor({ontology_genesis_anchor, Name, Expected}, Next,
               #est{bs = Bs} = St) ->
    case quod_predicates:is_ground(Name) of
        false ->
            fail_reason({ontology_anchor_failed, invalid_arguments}, St);
        true ->
            case quod_ontology:genesis_anchor(Name) of
                {ok, RawAnchor} ->
                    match_genesis_anchor(Expected, RawAnchor, Next, Bs, St);
                {error, not_hosted} ->
                    erlog_int:fail(St);
                {error, Reason} ->
                    fail_reason({ontology_anchor_failed, Reason}, St)
            end
    end;
genesis_anchor(_Goal, _Next, St) ->
    fail_reason({ontology_anchor_failed, invalid_arguments}, St).

match_genesis_anchor(Expected, RawAnchor, Next, Bs, St) ->
    case erlog_int:deref(Expected, Bs) of
        {_Variable} ->
            erlog_int:prove_body([{'=', Expected, RawAnchor} | Next], St);
        Value ->
            case normalize_public_anchor(Value) of
                {ok, RawAnchor} -> erlog_int:prove_body(Next, St);
                {ok, _OtherAnchor} -> erlog_int:fail(St);
                error ->
                    fail_reason(
                      {ontology_anchor_failed, invalid_genesis_hash}, St)
            end
    end.

normalize_public_anchor(Raw) when is_binary(Raw), byte_size(Raw) =:= 32 ->
    {ok, Raw};
normalize_public_anchor(Value) ->
    try unicode:characters_to_binary(Value) of
        Hex when is_binary(Hex), byte_size(Hex) =:= 64 ->
            try binary:decode_hex(Hex) of
                Raw when byte_size(Raw) =:= 32 -> {ok, Raw}
            catch _:_ -> error
            end;
        _ -> error
    catch _:_ -> error
    end.

fail_reason(Reason, St) ->
    erlog_int:prove_body([{fail_with_reason, Reason}], St).
