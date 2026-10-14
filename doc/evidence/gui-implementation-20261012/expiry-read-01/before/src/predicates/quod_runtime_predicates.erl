-module(quod_runtime_predicates).
-moduledoc """
Ordinary reactions match an event and local owner eligibility once in a read-only
committed snapshot. The actual bound goal enters the owner's existing queue and
ordinary authorization path. Matching grants no authenticated proof authority.

The universal `current_ontology_identity/2` query reads the exact executing
scope from engine-owned proof context, without a live lookup or authority grant.

Request expiry and optional custody preparation are private match metadata.
Their variables belong to the Erlog proof, so failed alternatives discard them;
no native preparation or submission occurs while eligibility is being proved.
""".

-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-export([quod_predicate_module/0, load/1, diff_to_events/1, run_reaction/6,
         me/3, current_ontology_identity/3, scope_identity/1,
         committed_operation_outcome/3,
         current_request_operation/3,
         current_request_expiry/3, limit_reaction_expiry/3, prepare_agent_custody/3,
         recovery_observation/3, prepare_signed_request/3,
         reaction_match_5/3, reaction_result_2/3, reaction_metadata/1, request_resource/4]).

quod_predicate_module() -> true.

load(Est) ->
    Actor = quod_predicates:register(Est, {me, 1}, query, proof_bound, ?MODULE, me),
    Identity = quod_predicates:register(Actor, {current_ontology_identity, 2}, query,
                                        proof_bound, ?MODULE, current_ontology_identity),
    Outcome = quod_predicates:register(Identity, {committed_operation_outcome, 2}, query,
                                       committed_snapshot, ?MODULE, committed_operation_outcome),
    Expiry = quod_predicates:register(Outcome, {current_request_expiry, 1}, query,
                                      proof_bound, ?MODULE, current_request_expiry),
    Operation = quod_predicates:register(Expiry, {current_request_operation, 1}, query,
                                         proof_bound, ?MODULE, current_request_operation),
    Limit = quod_predicates:register(Operation, {limit_reaction_expiry, 1}, reaction,
                                     ?MODULE, limit_reaction_expiry),
    Preparation = quod_predicates:register(Limit, {prepare_agent_custody, 3}, reaction,
                                           ?MODULE, prepare_agent_custody),
    Observation = quod_predicates:register(Preparation, {recovery_observation, 1}, reaction,
                                             ?MODULE, recovery_observation),
    Signed = quod_predicates:register(Observation, {prepare_signed_request, 3}, reaction,
                                      ?MODULE, prepare_signed_request),
    Match = quod_predicates:register(Signed, {'$quod_reaction_match', 5}, reaction,
                                     ?MODULE, reaction_match_5),
    quod_predicates:register(Match, {'$quod_reaction_result', 2}, reaction,
                             ?MODULE, reaction_result_2).

-doc "The selected actor during reaction discovery, otherwise the authenticated proof principal.".
me({me, Actor}, Next, St) ->
    Context = quod_predicates:context(St),
    case {quod_predicates:ctx_kind(Context), quod_predicates:ctx_executor(Context)} of
        {reaction, {actor, Reference, _Metadata}} ->
            erlog_int:unify_prove_body(Actor, Reference, Next, St);
        _ ->
            quod_ontology_predicates:current_principal_predicate(
              {current_principal, Actor}, Next, St)
    end.

-doc "Bind the exact identity of the executing proof scope without a live lookup.".
-spec current_ontology_identity(term(), term(), tuple()) -> term().
current_ontology_identity({current_ontology_identity, Namespace, Anchor}, Next, St) ->
    case scope_identity(St) of
        {ok, {Ns, Hash}} ->
            erlog_int:unify_prove_body([Namespace, Anchor], [Ns, Hash], Next, St);
        error -> quod_predicates:fail_reason(scope_identity_unavailable,St)
    end.

scope_identity(St) ->
    Context = quod_predicates:context(St),
    case {quod_predicates:ctx_ns(Context), quod_predicates:ctx_chain(Context)} of
        {Ns, [{Ns, <<_:256>> = Hash} | _]} when is_binary(Ns), byte_size(Ns) > 0 ->
            {ok, {Ns, Hash}};
        _ -> error
    end.

%% Positive terminal evidence is tracked before unification, so alternatives,
%% negation and cuts cannot erase a read that influenced the selected answer.
committed_operation_outcome({committed_operation_outcome, B0, Status}, Next,
                            St = #est{bs = Bs}) ->
    Context = quod_predicates:context(St),
    case quod_predicates:ctx_kind(Context) of
        proof -> ok;
        Other -> throw({erlog_error,
                       {context_violation, committed_operation_outcome, query, Other}})
    end,
    Bytes = erlog_int:dderef(B0, Bs),
    case {scope_identity(St), outcome_request(Bytes)} of
        {{ok, {Ns, Anchor}}, {ok, Ns, Anchor, Agent, Id, Digest}} ->
            Remaining = case quod_scope_session:remaining_ms() of
                            {ok, R} -> R;
                            error -> quod_proof_context:remaining_ms()
                        end,
            Key = {1, Agent, Id},
            case quod_prolog:operation_dependency(
                   Ns, Key, quod_predicates:ctx_height(Context), Remaining) of
                {ok, {StoredDigest, _, _, Code, _, _} = Token} ->
                    ok = quod_erlog_db_local_prove:absorb_read_set(St, #{Key => Token}),
                    case StoredDigest =:= Digest of
                        true ->
                            Value = case Code of 0 -> committed; 1 -> rejected; 2 -> aborted end,
                            erlog_int:unify_prove_body(Status, Value, Next, St);
                        false -> erlog_int:fail(St)
                    end;
                Unavailable ->
                    %% A caught error can return an answer, but cannot authorize
                    %% a diff. Reuse the monotonic live-bridge sealing veto.
                    ok = quod_erlog_db_local_prove:record_live_bridge(
                           St, {committed_operation_outcome, 2}),
                    throw({erlog_error, {operation_outcome_unavailable, Unavailable}})
            end;
        {error,_} -> quod_predicates:fail_reason(scope_identity_unavailable,St);
        _ -> erlog_int:fail(St)
    end.

%% Request bytes select exact committed evidence; they confer no authority.
%% Identity parsing stays atom-safe and the goal is never parsed or executed.
outcome_request(Bytes) ->
    case quod_client_goal:request_identity(Bytes) of
        {ok, #{request := #{mode := execute},
               operation_ref := {operation, Ns, Anchor, Agent, Id},
               request_digest := Digest}} -> {ok, Ns, Anchor, Agent, Id, Digest};
        _ -> error
    end.

-doc "Bind verified request metadata; no live clock observation enters the proof.".
current_request_expiry({current_request_expiry, Expiry}, Next, St) ->
    Bound = case reaction_metadata(St) of
        {ok, #{ceiling := Upper, expiry_variable := Variable}} ->
            case erlog_int:deref(Variable, St#est.bs) of
                {_} -> {ok, Upper};
                Narrowed -> {ok, Narrowed}
            end;
        _ ->
            case quod_scope_session:request_expiry() of
                error -> quod_proof_context:request_expiry();
                ScopeExpiry -> ScopeExpiry
            end
    end,
    case Bound of
        {ok, Value} -> erlog_int:unify_prove_body(Expiry, Value, Next, St);
        none -> erlog_int:fail(St)
    end.

-doc "Bind the original signed operation, including when proving in a foreign scope.".
current_request_operation({current_request_operation, Operation}, Next, St) ->
    case quod_predicates:ctx_kind(quod_predicates:context(St)) of
        proof ->
            Bound = case quod_scope_session:request_operation() of
                error -> quod_proof_context:request_operation();
                ScopeOperation -> ScopeOperation
            end,
            case Bound of
                {ok, Value} -> erlog_int:unify_prove_body(Operation, Value, Next, St);
                none -> erlog_int:fail(St)
            end;
        Kind -> erlog_int:erlog_error(
            {context_violation, current_request_operation, query, Kind}, St)
    end.

-doc "Constrain this match's request expiry within its owner-authenticated upper bound.".
limit_reaction_expiry({limit_reaction_expiry, Expiry0}, Next, St = #est{bs = Bs}) ->
    Expiry = erlog_int:dderef(Expiry0, Bs),
    case reaction_metadata(St) of
        {ok,#{ceiling := Upper,expiry_variable := Variable}} ->
            case Expiry of
                {_} -> erlog_int:instantiation_error(St);
                _ when not is_integer(Expiry) -> erlog_int:type_error(integer,Expiry,St);
                _ when Expiry =< 0 -> erlog_int:domain_error(request_expiry,Expiry,St);
                _ when Expiry > Upper -> erlog_int:fail(St);
                _ -> erlog_int:unify_prove_body(Variable,Expiry,Next,St)
            end;
        _ -> erlog_int:fail(St)
    end.

%% A public term resembling a notice is not an authenticated observation.
recovery_observation({recovery_observation, Event}, Next, St) ->
    case reaction_metadata(St) of
        {ok, #{mode := {node, Observer, execute},
               recovery := #{observer := Observer, event := Owned}}} ->
            erlog_int:unify_prove_body(Event, Owned, Next, St);
        _ -> erlog_int:fail(St)
    end.

-doc "Describe custody for the observed anchored agent; matching never opens the vault.".
prepare_agent_custody({prepare_agent_custody, Target0, Epoch0, Result0}, Next,
                      St = #est{bs = Bs}) ->
    [Target, Epoch, Result] = erlog_int:dderef([Target0, Epoch0, Result0], Bs),
    case reaction_metadata(St) of
        {ok,#{mode := {node,Observer,execute},recovery := Recovery,
               preparation_variable := Variable}} ->
            case quod_wire_term:is_ground([Target,Epoch]) of
                true -> ok;
                false -> erlog_int:instantiation_error(St)
            end,
            case {Target,Epoch,Result} of
                {{agent_instance_ref,Ns,<<_:256>>,_},E,{_}}
                  when is_binary(Ns),byte_size(Ns) > 0,is_integer(E),E > 0,E < (1 bsl 64) ->
                    case Recovery of
                        #{target := Target,epoch := Epoch,observer := Observer} ->
                            erlog_int:unify_prove_body(Variable,{custody,Target,Epoch,Result},Next,St);
                        _ -> erlog_int:fail(St)
                    end;
                _ -> erlog_int:domain_error(agent_custody,{Target,Epoch,Result},St)
            end;
        _ -> erlog_int:fail(St)
    end.

%% The template's two holes remain ordinary proof variables, so failed
%% candidates and backtracking cannot leak a custody preparation.
prepare_signed_request({prepare_signed_request, Bytes, Signature, Template}, Next, St = #est{bs = Bs}) ->
    [B,S,T] = erlog_int:dderef([Bytes,Signature,Template], Bs),
    case reaction_metadata(St) of
        {ok,#{physics := _,preparation_variable := Variable}} ->
            case quod_agent:valid_signed_preparation(B,S,T) of
                true -> erlog_int:unify_prove_body(Variable,{signed_store,B,S,T},Next,St);
                false -> erlog_int:domain_error(signed_preparation,T,St)
            end;
        _ -> erlog_int:fail(St)
    end.

-doc "Convert canonical applied operations to ordered reaction events.".
-spec diff_to_events([op()]) -> [term()].
diff_to_events(AppliedOps) when is_list(AppliedOps) ->
    lists:filtermap(
      fun({asserta, {Fact, {[], false}}}) ->
              {true, {assert, Fact}};
         ({Kind, {Fact, {[], false}}})
            when Kind =:= assert; Kind =:= retract ->
              {true, {Kind, Fact}};
         ({event, Term}) ->
              {true, Term};
         (_) ->
              false
      end, AppliedOps).

-doc "Match one declaration for its current owner and queue its ordinary goal once.".
-spec run_reaction(binary(), non_neg_integer(), map(), tuple(), term(), tuple()) ->
          executed | unmatched | {failed, term()}.
run_reaction(Ns, Height, Binding = #{request_timeout_ms := Timeout},
             Source, Event0, Est) ->
    %% A committed clause-head event can itself contain variables. Its scope
    %% is independent of this declaration, just as two ordinary Prolog clauses
    %% are standardized apart before unification.
    {{':-', {react_on, Pattern, Goal}, Guard}, _SourceVariables, NextVariable} =
        erlog_int:term_instance(Source, 0),
    {Event, _EventVariables, _Next} = erlog_int:term_instance(Event0, NextVariable),
    {Actor, Anchor, Executor, Mode} = request_owner(Ns, Binding),
    ConfiguredExpiry = quod_time:now_ms() + Timeout,
    UpperExpiry = min(ConfiguredExpiry, maps:get(request_expiry, Binding, ConfiguredExpiry)),
    Metadata = (maps:with([recovery,physics], Binding))#{
                 ceiling => UpperExpiry, mode => Mode, source => {Ns, Anchor}},
    Ctx = quod_predicates:with_chain(
            quod_predicates:with_executor(
              quod_predicates:reaction_context(Ns, Height), {actor, Actor, Metadata}),
            [{Ns, Anchor}]),
    Match = {'$quod_reaction_match', Pattern, Event, Guard, Goal, {'$ReactionRequest'}},
    case quod_proof_session:run_first(
           Match, quod_predicates:set_context(Est, Ctx),
           #{read_set => true, read_only => true}) of
        {ok, #{'$ReactionRequest' := {request, BoundGoal, Expiry, Preparation}}, [], _ReadSet}
          when is_integer(Expiry), Expiry > 0, Expiry =< UpperExpiry ->
            {RequestMode,Work} = case Preparation of
                none -> {Mode,BoundGoal};
                {custody, Ref, Epoch, Variable} -> {Mode,{custody,Ref,Epoch,Variable,BoundGoal}};
                {signed_store,B,S,T} -> {{custodied,B,S,T},BoundGoal}
            end,
            {OwnedMode,BoundMetadata} = case maps:find(physics, Metadata) of
                {ok, Physics} -> {{owned_physics,Physics,RequestMode},Physics};
                error -> {RequestMode,maps:get(recovery,Metadata,none)}
            end,
            Budget = case BoundMetadata of
                #{deadline := Deadline} -> {expires, Expiry, Deadline};
                none -> {expires, Expiry}
            end,
            case quod_runtime:agent_request(
                   Ns, Height, Executor, OwnedMode, Work, Budget) of
                ok -> executed;
                {error, Reason} -> {failed, {reaction_submission, Reason}}
            end;
        {ok, _, _, _} -> {failed, invalid_reaction_request};
        {fail, _Reasons} -> unmatched;
        {error, Reason} -> {failed, {reaction_guard, Reason}}
    end.

request_owner(Ns, #{reference := {agent_instance_ref, Ns, Anchor, _} = Actor,
                    credential := node, public_key := Key}) ->
    {Actor, Anchor, {node, Key}, {node, Actor, execute}};
request_owner(Ns, #{reference := {agent_instance_ref, Ns, Anchor, Instance} = Actor,
                    epoch := Epoch, public_key := Key}) ->
    {Actor, Anchor, {agent, Instance, Epoch, Key}, execute}.

%% Allocate the hidden request variables after the caller's source variables
%% have been freshened. Ordinary Erlog bindings give metadata the same cut and
%% backtracking semantics as the selected goal.
reaction_match_5({'$quod_reaction_match', Pattern, Event, Guard, Goal, Result},
                 Next, St = #est{vn = Vn}) ->
    Context = quod_predicates:context(St),
    {actor, Actor, Metadata} = quod_predicates:ctx_executor(Context),
    Scoped = Metadata#{expiry_variable => {Vn}, preparation_variable => {Vn + 1}},
    Ctx = quod_predicates:with_executor(Context, {actor, Actor, Scoped}),
    Continue = [{call, {once, Guard}}, {'$quod_reaction_result', Goal, Result} | Next],
    erlog_int:unify_prove_body(Pattern, Event, Continue,
      quod_predicates:set_context(St#est{vn = Vn + 2}, Ctx)).

reaction_result_2({'$quod_reaction_result', Goal, Result}, Next, St = #est{bs = Bs}) ->
    {ok, #{ceiling := Upper, expiry_variable := ExpiryVar,
           preparation_variable := PreparationVar} = Metadata} = reaction_metadata(St),
    Expiry = metadata_value(erlog_int:deref(ExpiryVar, Bs), Upper),
    Preparation = metadata_value(erlog_int:deref(PreparationVar, Bs), none),
    case Preparation of
        {custody, _, _, Variable} ->
            case quod_agent:valid_preparation_goal(
                   erlog_int:deref(Variable, Bs), erlog_int:dderef(Goal, Bs)) of
                true -> erlog_int:unify_prove_body(
                          Result, {request, Goal, Expiry, Preparation}, Next, St);
                false -> erlog_int:domain_error(preparation_goal,erlog_int:dderef(Goal,Bs),St)
            end;
        {signed_store,B,S,T} ->
            case quod_agent:valid_signed_preparation(B,S,T) andalso quod_wire_term:is_ground(erlog_int:dderef(Goal,Bs)) of
                true -> erlog_int:unify_prove_body(Result, {request,Goal,Expiry,Preparation}, Next, St);
                false -> erlog_int:domain_error(preparation_goal,erlog_int:dderef(Goal,Bs),St)
            end;
        %% A private physics request asks for a custodied consequence. An
        %% unrelated generic observed(_) clause cannot consume that request.
        none when is_map_key(physics,Metadata) -> erlog_int:fail(St);
        none -> erlog_int:unify_prove_body(Result, {request, Goal, Expiry, Preparation}, Next, St)
    end.

metadata_value({_Variable}, Default) -> Default;
metadata_value(Value, _) -> Value.

reaction_metadata(St) ->
    Context = quod_predicates:context(St),
    case {quod_predicates:ctx_kind(Context), quod_predicates:ctx_executor(Context)} of
        {reaction, {actor, _Actor, Metadata}} -> {ok, Metadata};
        _ -> error
    end.

request_resource(Kind, Scope0, Next, St = #est{bs = Bs}) ->
    Context = quod_predicates:context(St),
    case quod_predicates:ctx_kind(Context) of
        proof -> ok;
        Other -> throw({erlog_error, {context_violation, resource_reconciliation, query, Other}})
    end,
    Scope = erlog_int:dderef(Scope0, Bs),
    case quod_wire_term:is_ground(Scope) of
        true ->
            Deadline = case quod_scope_session:remaining_ms() of
                           {ok, Remaining} -> quod_time:mono_ms() + Remaining;
                           error -> quod_proof_context:deadline_ms()
                       end,
            Ns = quod_predicates:ctx_ns(Context),
            case quod_runtime:reconcile_resource(
                   Ns, quod_predicates:ctx_height(Context), Kind, Scope, Deadline) of
                ok -> erlog_int:prove_body(Next, St);
                {error, Reason} ->
                    throw({erlog_error, {resource_reconciliation_failed, Kind, Reason}})
            end;
        false -> erlog_int:instantiation_error(St)
    end.
