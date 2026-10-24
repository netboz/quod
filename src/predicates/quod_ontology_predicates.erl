-module(quod_ontology_predicates).
-import(quod_predicates, [fail_reason/2]).
-moduledoc """
Governed Prolog bridges for ontology creation and node-local hosting.

`create_ontology/3` and `join_ontology/3` are ordinary staging predicates. A
public call is
structurally validated, bound to an opaque proof-local handle, and continued
through the shared `action/3` relation in `common_predicates.pl`. Only the
private continuation reached after that relation's declared prerequisites may
prepare and stage the direct effect.

The module performs no authorization proof of its own. The normal
`can_invoke/4` entry check and the action's ordinary Prolog prerequisites are
the complete policy path. `ontology_join_state/2` and
`ontology_genesis_anchor/2` remain read-only views of the local node.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([quod_predicate_module/0, load/1,
         lifecycle_request_predicate/3,
         lifecycle_continuation_predicate/3,
         current_principal_predicate/3,
         current_executor_key_predicate/3,
         ontology_join_state_predicate/3,
         ontology_genesis_anchor_predicate/3,
         reconcile_effect_custody/3, reconcile_node_ontologies/3]).

-define(ROOT_NS, <<"quod:root">>).
-define(NODE_NS, <<"quod:node">>).
-define(CONTINUATION, '$quod_stage_ontology').

quod_predicate_module() -> true.

-spec load(tuple()) -> tuple().
load(Est0) ->
    WithPrincipal = quod_predicates:register(
      Est0, {current_principal, 1}, query, proof_bound,
      ?MODULE, current_principal_predicate),
    WithExecutor = quod_predicates:register(
      WithPrincipal, {current_executor_key, 1}, query, proof_bound,
      ?MODULE, current_executor_key_predicate),
    Entries =
        [{{create_ontology, 3}, staging, lifecycle_request_predicate},
         {{join_ontology, 3}, staging, lifecycle_request_predicate},
         {{?CONTINUATION, 3}, staging, lifecycle_continuation_predicate},
         {{ontology_join_state, 2}, query, ontology_join_state_predicate},
         {{ontology_genesis_anchor, 2}, query,
          ontology_genesis_anchor_predicate},
         {{reconcile_effect_custody, 0}, query, reconcile_effect_custody},
         {{reconcile_node_ontologies, 1}, query, reconcile_node_ontologies}],
    lists:foldl(
      fun({Functor, Class, Function}, Est) ->
              quod_predicates:register(
                Est, Functor, Class, ?MODULE, Function)
      end, WithExecutor, Entries).

%% This is the signer already bound to this exact proof scope, not a live
%% process/endpoint lookup. Direct effects carry the same executor in their
%% sealed descriptor and validators check it against the transaction author.
current_executor_key_predicate({current_executor_key, Key}, Next, St) ->
    case quod_proof_session:signer_from_state(St) of
        #{pubkey := <<_:256>> = PublicKey} ->
            erlog_int:unify_prove_body(Key, PublicKey, Next, St);
        none -> erlog_int:fail(St)
    end.

-doc "Enter the shared action relation with one opaque proof-local request.".
-spec lifecycle_request_predicate(term(), term(), tuple()) -> term().
lifecycle_request_predicate(Goal, Next, #est{bs = Bs} = St) ->
    Action = erlog_int:dderef(Goal, Bs),
    Ns = quod_predicates:ctx_ns(quod_predicates:context(St)),
    case {supported_action(Ns, Action), structural_action(Action)} of
        {true, {ok, RequestAction}} ->
            case quod_ontology:validate_action(RequestAction) of
                {ok, Structural} ->
                    {Handle, St1} =
                        quod_erlog_db_local_prove:register_action_request(
                          St, RequestAction, Structural),
                    Vn = St1#est.vn,
                    Transition = {?CONTINUATION, Handle, Action, {Vn}},
                    erlog_int:prove_body(
                      [{run_declared_action, Transition} | Next], St1#est{vn = Vn + 1});
                {error,invalid_arguments} -> erlog_int:instantiation_error(St);
                {error,_} -> erlog_int:domain_error(ontology_action,Action,St)
            end;
        {false,{ok,_}} -> erlog_int:erlog_error(
            {context_violation,element(1,Action),staging,wrong_ontology},St);
        {_,error} -> erlog_int:domain_error(ontology_action,Action,St)
    end.

structural_action({create_ontology, Name, Options, _Anchor}) ->
    {ok, {create_ontology, Name, Options}};
structural_action({join_ontology, _, _, _} = Action) -> {ok, Action};
structural_action(_) -> error.

supported_action(?ROOT_NS, {create_ontology, _, _, _}) -> true;
supported_action(?NODE_NS, {join_ontology, _, _, _}) -> true;
supported_action(_, _) -> false.

%% Prepare and stage only a request carrying this proof's exact opaque handle.
%% Creation binds its prepared anchor into the caller's variable before the
%% immutable action/effect row is staged.
-spec lifecycle_continuation_predicate(term(), term(), tuple()) -> term().
lifecycle_continuation_predicate(
  {?CONTINUATION, Handle0, Action0, Desired0}, Next,
  #est{bs = Bs} = St) ->
    Handle = erlog_int:dderef(Handle0, Bs),
    Action = erlog_int:dderef(Action0, Bs),
    case structural_action(Action) of
        {ok, RequestAction} ->
            case quod_erlog_db_local_prove:action_request(
                   St, Handle, RequestAction) of
                {ok, Structural} ->
                    prepare_and_stage_action(
                      Action0, Desired0, RequestAction, Structural, Next, St);
                error -> erlog_int:domain_error(ontology_request_handle,Handle,St)
            end;
        error ->
            erlog_int:domain_error(ontology_action,Action,St)
    end;
lifecycle_continuation_predicate(Goal, _Next, St) ->
    erlog_int:domain_error(ontology_action,Goal,St).

prepare_and_stage_action(Action0, Desired0, RequestAction, Structural, Next, St) ->
    Committed = quod_erlog_db_local_prove:committed_state(St),
    Admission = case RequestAction of
        {create_ontology, _, _} -> quod_material_admission:policy(founding, Committed);
        {join_ontology, _, _, _} -> {ok, #{}, #{}}
    end,
    PreparedResult = case Admission of
        {ok, Limits, Reads} ->
            ok = quod_erlog_db_local_prove:absorb_read_set(St, Reads),
            quod_ontology:prepare_action(Structural, Limits);
        {error, _} = PolicyError -> PolicyError
    end,
    case PreparedResult of
        {ok, Prepared} ->
            bind_prepared_action(
              Action0, Desired0, RequestAction, Prepared, Next, St);
        {error,invalid_arguments} -> erlog_int:instantiation_error(St);
        {error,invalid_action} -> erlog_int:erlog_error({system_error,invalid_lifecycle_descriptor},St);
        {error,Reason} when Reason =:= invalid_initial_terms; Reason =:= invalid_options ->
            erlog_int:domain_error(ontology_action,RequestAction,St);
        {error,{invalid_initial_term,_}} -> erlog_int:domain_error(ontology_action,RequestAction,St);
        {error,{source_error,_,_,_}} -> erlog_int:domain_error(ontology_action,RequestAction,St);
        {error,Reason} -> fail_reason(lifecycle_error(RequestAction,Reason),St)
    end.

bind_prepared_action(
  {create_ontology, Name, Options, Anchor0}, Desired0,
  {create_ontology, Name, Options}, Prepared, Next, #est{bs = Bs} = St) ->
    Anchor = quod_ontology:prepared_anchor(Prepared),
    case erlog_int:unify(Anchor0, Anchor, Bs) of
        {succeed, Bs1} ->
            St1 = St#est{bs = Bs1},
            Action = erlog_int:dderef(
                       {create_ontology, Name, Options, Anchor0}, Bs1),
            Desired = erlog_int:dderef(Desired0, Bs1),
            stage_prepared_action(Action, Desired, Prepared, Next, St1);
        fail -> erlog_int:fail(St)
    end;
bind_prepared_action(Action0, Desired0, RequestAction, Prepared, Next,
                     #est{bs = Bs} = St) ->
    Action = erlog_int:dderef(Action0, Bs),
    Desired = erlog_int:dderef(Desired0, Bs),
    case quod_wire_term:is_ground({Action, Desired}) andalso
         Action =:= RequestAction of
        true ->
            stage_prepared_action(Action, Desired, Prepared, Next, St);
        false ->
            case quod_wire_term:is_ground({Action,Desired}) of
                false -> erlog_int:instantiation_error(St);
                true -> erlog_int:domain_error(ontology_action,Action,St)
            end
    end.

stage_prepared_action(Action, Desired, Prepared, Next, St) ->
    case quod_wire_term:is_ground({Action, Desired}) of
        true ->
            Principal = authenticated_principal(),
            case quod_proof_session:signer_from_state(St) of
                #{pubkey := <<_:256>> = Executor} ->
                    case quod_ontology:prepared_effect(
                           Action, Prepared, Executor, Principal) of
                        {ok, Effect} ->
                            St1 = quod_erlog_db_local_prove:put_prepared_effect(
                                    St, Action, Desired, Effect, Prepared),
                            erlog_int:prove_body(Next, St1);
                        {error,_} -> erlog_int:erlog_error({system_error,invalid_prepared_effect},St)
                    end;
                none ->
                    fail_reason(failure_reason(Action, rebuilding), St)
            end;
        false -> erlog_int:instantiation_error(St)
    end.

-doc "Bind the authenticated principal owned by the current proof.".
-spec current_principal_predicate(term(), term(), tuple()) -> term().
current_principal_predicate({current_principal, Principal}, Next, St) ->
    case policy_principal(authenticated_principal()) of
        {ok, PolicyPrincipal} ->
            erlog_int:unify_prove_body(Principal, PolicyPrincipal, Next, St);
        error -> erlog_int:erlog_error(invalid_authenticated_principal,St)
    end;
current_principal_predicate(Goal, _Next, St) ->
    erlog_int:domain_error(principal_query,Goal,St).

authenticated_principal() ->
    case quod_scope_session:principal() of
        {ok, Principal} -> Principal;
        error -> quod_proof_context:principal()
    end.

%% Keep lifecycle prerequisites and can_invoke/4 on the same Prolog-visible
%% identity.  The canonical blob is only the wire/storage representation.
policy_principal({agent, _Blob} = Principal) ->
    case quod_agent_ref:materialize_principal(Principal) of
        {ok, AgentRef} -> {ok, AgentRef};
        {error, _} -> error
    end;
policy_principal(Principal) ->
    {ok, Principal}.

%% Only operational preparation refusals reach this vocabulary. Argument
%% and descriptor errors have already used the Erlog error channel.
lifecycle_error({create_ontology, _, _} = Action, Reason) ->
    failure_reason(Action, creation_reason(Reason));
lifecycle_error({join_ontology, _, _, _} = Action, Reason) ->
    failure_reason(Action, join_reason(Reason)).

failure_reason({create_ontology, _, _, _}, Reason) -> {ontology_creation_failed,Reason};
failure_reason({create_ontology, _, _}, Reason) -> {ontology_creation_failed,Reason};
failure_reason({join_ontology, _, _, _}, Reason) -> {ontology_join_failed,Reason}.

creation_reason({material_limit, founding, _, _, _} = Reason) -> Reason;
creation_reason({invalid_material_policy, founding} = Reason) -> Reason;
creation_reason({source_file_error, Index, _Path, _Reason}) -> {source_file_error,Index};
creation_reason({already_configured, _Ns}) -> already_hosted;
creation_reason(_Reason) -> start_failed.

join_reason({already_configured, _Ns}) -> already_hosted;
join_reason(root_unavailable) -> root_unavailable;
join_reason(_Reason) -> start_failed.

-spec ontology_join_state_predicate(term(), term(), tuple()) -> term().
ontology_join_state_predicate(Goal, Next, #est{bs = Bs} = St) ->
    state(erlog_int:dderef(Goal, Bs), Next, St).

state({ontology_join_state, Name, State}, Next, St) ->
    case quod_wire_term:is_ground(Name) of
        false ->
            erlog_int:instantiation_error(St);
        true ->
            case quod_ontology:local_state(Name) of
                {ok, LocalState} ->
                    erlog_int:unify_prove_body(State, LocalState, Next, St);
                {error, _Reason} ->
                    erlog_int:domain_error(ontology_name,Name,St)
            end
    end;
state(Goal, _Next, St) -> erlog_int:domain_error(ontology_state_query,Goal,St).

-spec ontology_genesis_anchor_predicate(term(), term(), tuple()) -> term().
ontology_genesis_anchor_predicate(Goal, Next, #est{bs = Bs} = St) ->
    genesis_anchor(erlog_int:dderef(Goal, Bs), Next, St).

genesis_anchor({ontology_genesis_anchor, Name, Expected}, Next, St) ->
    case quod_wire_term:is_ground(Name) of
        false ->
            erlog_int:instantiation_error(St);
        true ->
            case quod_ontology:genesis_anchor(Name) of
                {ok, RawAnchor} ->
                    match_genesis_anchor(Expected, RawAnchor, Next, St);
                {error, not_hosted} -> fail_reason({ontology_anchor_failed,not_hosted},St);
                {error,invalid_name} -> erlog_int:domain_error(ontology_name,Name,St);
                {error,Reason} -> fail_reason({ontology_anchor_failed,Reason},St)
            end
    end;
genesis_anchor(Goal, _Next, St) -> erlog_int:domain_error(ontology_anchor_query,Goal,St).

match_genesis_anchor(Expected, RawAnchor, Next, St) ->
    case erlog_int:deref(Expected, St#est.bs) of
        {_Variable} ->
            erlog_int:unify_prove_body(Expected, RawAnchor, Next, St);
        Value ->
            case normalize_public_anchor(Value) of
                {ok, RawAnchor} -> erlog_int:prove_body(Next, St);
                {ok, _OtherAnchor} -> erlog_int:fail(St);
                error ->
                    erlog_int:domain_error(genesis_anchor,Value,St)
            end
    end.

-doc "Ask the existing journal owner to apply its committed root capacity policy.".
reconcile_effect_custody(reconcile_effect_custody, Next, St) ->
    case quod_predicates:ctx_ns(quod_predicates:context(St)) of
        ?ROOT_NS -> request_resource(effect_custody, all, Next, St);
        _ -> throw({erlog_error, wrong_effect_custody_ontology})
    end.

-doc "Ask the current node policy owner to select committed hosting state.".
reconcile_node_ontologies({reconcile_node_ontologies, Scope0}, Next, #est{bs = Bs} = St) ->
    request_resource(node_ontologies, erlog_int:dderef(Scope0, Bs), Next, St).

request_resource(Resource, Scope, Next, St) ->
    quod_runtime_predicates:request_resource(Resource, Scope, Next, St).

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
