-module(quod_ontology_predicates).
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
         ontology_join_state_predicate/3,
         ontology_genesis_anchor_predicate/3,
         effect_custody_capacity_projection_predicate/3,
         node_ontology_hosting_projection_predicate/3]).
-export([lifecycle_error/2, failure_reason/2]).

-define(ROOT_NS, <<"quod:root">>).
-define(NODE_NS, <<"quod:node">>).
-define(CONTINUATION, '$quod_stage_ontology').
-define(EFFECT_CAPACITY_PROJECTION,
        '$quod_project_effect_custody_capacity').
-define(NODE_HOSTING_PROJECTION, '$quod_project_node_ontology_hosting').

quod_predicate_module() -> true.

-spec load(tuple()) -> tuple().
load(Est0) ->
    Entries =
        [{{create_ontology, 3}, staging, lifecycle_request_predicate},
         {{join_ontology, 3}, staging, lifecycle_request_predicate},
         {{?CONTINUATION, 3}, staging, lifecycle_continuation_predicate},
         {{current_principal, 1}, query, current_principal_predicate},
         {{ontology_join_state, 2}, query, ontology_join_state_predicate},
         {{ontology_genesis_anchor, 2}, query,
          ontology_genesis_anchor_predicate},
         {{?EFFECT_CAPACITY_PROJECTION, 2}, projection,
          effect_custody_capacity_projection_predicate},
         {{?NODE_HOSTING_PROJECTION, 3}, projection,
          node_ontology_hosting_projection_predicate}],
    lists:foldl(
      fun({Functor, Class, Function}, Est) ->
              quod_predicates:register(
                Est, Functor, Class, ?MODULE, Function)
      end, Est0, Entries).

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
                    erlog_int:prove_body(
                      [{run_declared_action, Action, Handle} | Next], St1);
                {error, Reason} ->
                    fail_reason(lifecycle_error(Action, Reason), St)
            end;
        {false, _} ->
            fail_reason(failure_reason(Action, wrong_ontology), St);
        {true, error} ->
            fail_reason(failure_reason(Action, invalid_action), St)
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
                error ->
                    fail_reason(failure_reason(Action, invalid_action), St)
            end;
        error ->
            fail_reason(failure_reason(Action, invalid_action), St)
    end;
lifecycle_continuation_predicate(_Goal, _Next, St) ->
    fail_reason({ontology_lifecycle_failed, invalid_action}, St).

prepare_and_stage_action(Action0, Desired0, RequestAction, Structural, Next, St) ->
    Principal = authenticated_principal(),
    case quod_ontology:prepare_action(Structural, Principal) of
        {ok, Prepared} ->
            bind_prepared_action(
              Action0, Desired0, RequestAction, Prepared, Next, St);
        {error, Reason} ->
            fail_reason(lifecycle_error(RequestAction, Reason), St)
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
        false -> fail_reason(failure_reason(Action, invalid_action), St)
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
                        {error, Reason} ->
                            fail_reason(lifecycle_error(Action, Reason), St)
                    end;
                none ->
                    fail_reason(failure_reason(Action, rebuilding), St)
            end;
        false -> fail_reason(failure_reason(Action, invalid_action), St)
    end.

-doc "Bind the authenticated principal owned by the current proof.".
-spec current_principal_predicate(term(), term(), tuple()) -> term().
current_principal_predicate({current_principal, Principal}, Next, St) ->
    case policy_principal(authenticated_principal()) of
        {ok, PolicyPrincipal} ->
            erlog_int:unify_prove_body(Principal, PolicyPrincipal, Next, St);
        error ->
            erlog_int:fail(St)
    end;
current_principal_predicate(_Goal, _Next, St) ->
    erlog_int:fail(St).

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

-doc "Map a typed lifecycle API error to its bounded public Prolog reason.".
-spec lifecycle_error(term(), term()) -> term().
lifecycle_error({create_ontology, _, _, _} = Action, Reason) ->
    failure_reason(Action, creation_reason(Reason));
lifecycle_error({create_ontology, _, _} = Action, Reason) ->
    failure_reason(Action, creation_reason(Reason));
lifecycle_error({join_ontology, _, _, _} = Action, Reason) ->
    failure_reason(Action, join_reason(Reason));
lifecycle_error(Action, _Reason) ->
    failure_reason(Action, invalid_action).

-spec failure_reason(term(), term()) -> term().
failure_reason({create_ontology, _, _, _}, Reason) ->
    {ontology_creation_failed, Reason};
failure_reason({create_ontology, _, _}, Reason) ->
    {ontology_creation_failed, Reason};
failure_reason({join_ontology, _, _, _}, Reason) ->
    {ontology_join_failed, Reason};
failure_reason(_Action, Reason) ->
    {ontology_lifecycle_failed, Reason}.

creation_reason(invalid_name) -> invalid_name;
creation_reason(invalid_arguments) -> invalid_arguments;
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
join_reason(invalid_arguments) -> invalid_arguments;
join_reason(invalid_genesis_hash) -> invalid_genesis_hash;
join_reason(invalid_seeds) -> invalid_seeds;
join_reason({already_configured, _Ns}) -> already_hosted;
join_reason(root_unavailable) -> root_unavailable;
join_reason(_Reason) -> start_failed.

-spec ontology_join_state_predicate(term(), term(), tuple()) -> term().
ontology_join_state_predicate(Goal, Next, #est{bs = Bs} = St) ->
    state(erlog_int:dderef(Goal, Bs), Next, St).

state({ontology_join_state, Name, State}, Next, St) ->
    case quod_wire_term:is_ground(Name) of
        false ->
            fail_reason({ontology_state_failed, invalid_arguments}, St);
        true ->
            case quod_ontology:local_state(Name) of
                {ok, LocalState} ->
                    erlog_int:unify_prove_body(State, LocalState, Next, St);
                {error, _Reason} ->
                    fail_reason({ontology_state_failed, invalid_name}, St)
            end
    end;
state(_Goal, _Next, St) ->
    fail_reason({ontology_state_failed, invalid_arguments}, St).

-spec ontology_genesis_anchor_predicate(term(), term(), tuple()) -> term().
ontology_genesis_anchor_predicate(Goal, Next, #est{bs = Bs} = St) ->
    genesis_anchor(erlog_int:dderef(Goal, Bs), Next, St).

genesis_anchor({ontology_genesis_anchor, Name, Expected}, Next, St) ->
    case quod_wire_term:is_ground(Name) of
        false ->
            fail_reason({ontology_anchor_failed, invalid_arguments}, St);
        true ->
            case quod_ontology:genesis_anchor(Name) of
                {ok, RawAnchor} ->
                    match_genesis_anchor(Expected, RawAnchor, Next, St);
                {error, not_hosted} -> erlog_int:fail(St);
                {error, Reason} ->
                    fail_reason({ontology_anchor_failed, Reason}, St)
            end
    end;
genesis_anchor(_Goal, _Next, St) ->
    fail_reason({ontology_anchor_failed, invalid_arguments}, St).

match_genesis_anchor(Expected, RawAnchor, Next, St) ->
    case erlog_int:deref(Expected, St#est.bs) of
        {_Variable} ->
            erlog_int:unify_prove_body(Expected, RawAnchor, Next, St);
        Value ->
            case normalize_public_anchor(Value) of
                {ok, RawAnchor} -> erlog_int:prove_body(Next, St);
                {ok, _OtherAnchor} -> erlog_int:fail(St);
                error ->
                    fail_reason(
                      {ontology_anchor_failed, invalid_genesis_hash}, St)
            end
    end.

-doc "Project the one effective root-owned effect-custody capacity.".
-spec effect_custody_capacity_projection_predicate(
        term(), term(), tuple()) -> term().
effect_custody_capacity_projection_predicate(
  {?EFFECT_CAPACITY_PROJECTION, Capacities0, _Scope}, Next,
  #est{bs = Bs} = St) ->
    Capacities = erlog_int:dderef(Capacities0, Bs),
    Ctx = quod_predicates:context(St),
    case {quod_predicates:ctx_ns(Ctx), Capacities} of
        {?ROOT_NS, [Capacity]}
          when (is_integer(Capacity) andalso Capacity >= 0) orelse
               Capacity =:= unlimited ->
            case quod_effect_journal:configure_capacity(Capacity) of
                ok -> erlog_int:prove_body(Next, St);
                {error, Reason} ->
                    throw({erlog_error,
                           {effect_custody_capacity_unavailable, Reason}})
            end;
        {?ROOT_NS, _} ->
            throw({erlog_error, invalid_effect_custody_capacity});
        _ ->
            throw({erlog_error, wrong_effect_custody_ontology})
    end;
effect_custody_capacity_projection_predicate(_Goal, _Next, _St) ->
    throw({erlog_error, invalid_effect_custody_capacity}).

-doc "Project the node actor's complete committed hosting policy.".
node_ontology_hosting_projection_predicate(
  {?NODE_HOSTING_PROJECTION, Hosts0, Contacts0, Scope0}, Next,
  #est{bs = Bs} = St) ->
    Hosts = erlog_int:dderef(Hosts0, Bs),
    Contacts = erlog_int:dderef(Contacts0, Bs),
    Scope = erlog_int:dderef(Scope0, Bs),
    Ctx = quod_predicates:context(St),
    case quod_node_actor:hosting_projection(
           quod_predicates:ctx_ns(Ctx), quod_predicates:ctx_height(Ctx),
           Scope, Hosts, Contacts) of
        ok -> erlog_int:prove_body(Next, St);
        {error, Reason} -> throw({erlog_error, Reason})
    end;
node_ontology_hosting_projection_predicate(_Goal, _Next, _St) ->
    throw({erlog_error, malformed_node_hosting_projection}).

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
