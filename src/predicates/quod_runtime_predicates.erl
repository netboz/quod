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
         current_request_expiry/3, limit_reaction_expiry/3, prepare_agent_custody/3,
         recovery_observation/3,
         reaction_match_5/3, reaction_result_2/3, reaction_metadata/1, request_resource/4]).

quod_predicate_module() -> true.

load(Est) ->
    Actor = quod_predicates:register(Est, {me, 1}, query, proof_bound, ?MODULE, me),
    Identity = quod_predicates:register(Actor, {current_ontology_identity, 2}, query,
                                        proof_bound, ?MODULE, current_ontology_identity),
    Expiry = quod_predicates:register(Identity, {current_request_expiry, 1}, query,
                                      proof_bound, ?MODULE, current_request_expiry),
    Limit = quod_predicates:register(Expiry, {limit_reaction_expiry, 1}, reaction,
                                     ?MODULE, limit_reaction_expiry),
    Preparation = quod_predicates:register(Limit, {prepare_agent_custody, 3}, reaction,
                                           ?MODULE, prepare_agent_custody),
    Observation = quod_predicates:register(Preparation, {recovery_observation, 1}, reaction,
                                             ?MODULE, recovery_observation),
    Match = quod_predicates:register(Observation, {'$quod_reaction_match', 5}, reaction,
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
        error -> erlog_int:fail(St)
    end.

scope_identity(St) ->
    Context = quod_predicates:context(St),
    case {quod_predicates:ctx_ns(Context), quod_predicates:ctx_chain(Context)} of
        {Ns, [{Ns, <<_:256>> = Hash} | _]} when is_binary(Ns), byte_size(Ns) > 0 ->
            {ok, {Ns, Hash}};
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

-doc "Constrain this match's request expiry within its owner-authenticated upper bound.".
limit_reaction_expiry({limit_reaction_expiry, Expiry0}, Next, St = #est{bs = Bs}) ->
    Expiry = erlog_int:dderef(Expiry0, Bs),
    case reaction_metadata(St) of
        {ok, #{ceiling := Upper, expiry_variable := Variable}}
          when is_integer(Expiry), Expiry > 0, Expiry =< Upper ->
            erlog_int:unify_prove_body(Variable, Expiry, Next, St);
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
    case {reaction_metadata(St), Target, quod_wire_term:is_ground(Target), Result} of
        {{ok, #{mode := {node, Observer, execute},
                recovery := #{target := Target, epoch := Epoch, observer := Observer},
                preparation_variable := Variable}},
         {agent_instance_ref, Ns, <<_:256>>, _}, true, {_}}
          when is_binary(Ns), byte_size(Ns) > 0,
               is_integer(Epoch), Epoch > 0, Epoch < (1 bsl 64) ->
            Preparation = {custody, Target, Epoch, Result},
            erlog_int:unify_prove_body(Variable, Preparation, Next, St);
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
    Metadata = (maps:with([recovery], Binding))#{
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
            Work = case Preparation of
                       none -> BoundGoal;
                       {custody, Ref, Epoch, Variable} ->
                           {custody, Ref, Epoch, Variable, BoundGoal}
                   end,
            Budget = case maps:get(recovery, Metadata, none) of
                #{deadline := Deadline} -> {expires, Expiry, Deadline};
                none -> {expires, Expiry}
            end,
            case quod_runtime:agent_request(
                   Ns, Height, Executor, Mode, Work, Budget) of
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
           preparation_variable := PreparationVar}} = reaction_metadata(St),
    Expiry = metadata_value(erlog_int:deref(ExpiryVar, Bs), Upper),
    Preparation = metadata_value(erlog_int:deref(PreparationVar, Bs), none),
    case Preparation of
        {custody, _, _, Variable} ->
            case quod_agent:valid_preparation_goal(
                   erlog_int:deref(Variable, Bs), erlog_int:dderef(Goal, Bs)) of
                true -> erlog_int:unify_prove_body(
                          Result, {request, Goal, Expiry, Preparation}, Next, St);
                false -> erlog_int:fail(St)
            end;
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
        false -> erlog_int:fail(St)
    end.
