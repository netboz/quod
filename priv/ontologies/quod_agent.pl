%% Hosting and recovery behavior for exact agent references. The storing
%% ontology owns the facts and its ACL; this owner supplies the transitions.
acl_sovereign(quod:agent).
can_invoke(Goal, _, _, _) :- agent_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- agent_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).
agent_query(isa(_, _)).
agent_query(class_eidolon(_, _, _, _)).
agent_query(class_permission(_, _, _)).
agent_query(class_requirement(_, _, _)).
agent_query('$quod_constructor_metadata'(_, _, _)).
agent_query(have_attribute(_, _, _)).
agent_query(have_attribute(_, _, _, _)).
agent_query(attribute_value(binary, _)).
agent_query(goal(_)).
agent_query(agent_hosted(_, _, _, _)).
agent_query(agent_preparation_assignment(_, _, _)).
agent_query(agent_identifier(_)).
agent_query(agent_key_preparation(_, _, _, _, _)).
agent_query(can_sign_agent_request(_, _, _)).
agent_query(agent_recovery_current(_, _, _, _)).
agent_query(agent_report_next(_, _, _, _, _, _)).
agent_query(agent_report_support(_, _, _, _, _, _)).
agent_query(agent_failure_support(_, _, _, _, _, _)).
agent_query(report_agent_observation(_, _, _, _, _, _, _)).
agent_query(report_agent_observation_with_custody(_, _, _, _, _, _, _, _)).
agent_query(prepare_agent_and_converge(_, _, _, _, _)).
agent_query(Goal) :- public_source_query(Goal).
isa(agent, thing).
class_permission(agent, space_enter, allow).
class_permission(agent, space_leave, allow).
agent_identifier(Value) :- binary_codes(Value, Bytes), length(Bytes, 32).

agent_hosted(agent_instance_ref(Ns, Anchor, Instance), Node, Epoch, Key) :-
    in_ontology(Ns, Anchor, agent_hosted(Instance, Node, Epoch, Key)).
agent_host(agent_instance_ref(Ns, Anchor, Instance), Node, Epoch, Key) :-
    in_ontology(Ns, Anchor, agent_host(Instance, Node, Epoch, Key)).
agent_key(agent_instance_ref(Ns, Anchor, Instance), Key, Status) :-
    in_ontology(Ns, Anchor, agent_key(Instance, Key, Status)).
agent_candidate_key(agent_instance_ref(Ns, Anchor, Instance), Host, Epoch, Destination, Key) :-
    in_ontology(Ns, Anchor, agent_candidate_key(Instance, Host, Epoch, Destination, Key)).
agent_recovery_round(agent_instance_ref(Ns, Anchor, Instance), Host, Epoch, Round) :-
    in_ontology(Ns, Anchor, agent_recovery_round(Instance, Host, Epoch, Round)).
agent_failure_report(agent_instance_ref(Ns, Anchor, Instance), Host, Epoch, Round,
                     Observer, Observation, Kind) :-
    in_ontology(Ns, Anchor,
        agent_failure_report(Instance, Host, Epoch, Round, Observer, Observation, Kind)).
can_prepare_agent_key(Caller, agent_instance_ref(Ns, Anchor, Instance), Host, Epoch, Destination) :-
    in_ontology(Ns, Anchor, can_prepare_agent_key(Caller, Instance, Host, Epoch, Destination)).
can_assign_agent_host(Caller, agent_instance_ref(Ns, Anchor, Instance), Host, Epoch, Destination, Key) :-
    in_ontology(Ns, Anchor, can_assign_agent_host(Caller, Instance, Host, Epoch, Destination, Key)).
can_report_agent_failure(Caller, agent_instance_ref(Ns, Anchor, Instance), Host, Kind) :-
    in_ontology(Ns, Anchor, can_report_agent_failure(Caller, Instance, Host, Kind)).
can_resolve_agent_recovery(Caller, agent_instance_ref(Ns, Anchor, Instance), Host, Epoch, Round) :-
    in_ontology(Ns, Anchor, can_resolve_agent_recovery(Caller, Instance, Host, Epoch, Round)).
agent_recovery_candidate(Caller, agent_instance_ref(Ns, Anchor, Instance), Host, Epoch,
                         Round, Destination, Rank) :-
    in_ontology(Ns, Anchor,
        agent_recovery_candidate(Caller, Instance, Host, Epoch, Round, Destination, Rank)).

agent_preparation_assignment(Instance, none, 0) :-
    \+ agent_host(Instance, _, _, _), \+ agent_key(Instance, _, _).
agent_preparation_assignment(Instance, Host, Epoch) :-
    integer(Epoch), Epoch > 0,
    agent_hosted(Instance, Host, Epoch, _).

agent_key_preparation(Caller, Instance, OldHost, OldEpoch, Destination) :-
    agent_preparation_assignment(Instance, OldHost, OldEpoch),
    can_prepare_agent_key(Caller, Instance, OldHost, OldEpoch, Destination).

action(initialize_agent_host(Instance, NodeRef, PublicKey),
       [current_principal(Administrator),
        can_assign_agent_host(Administrator, Instance, none, 0, NodeRef, PublicKey),
        agent_preparation_assignment(Instance, none, 0),
        term_variables(Instance, []), term_variables(NodeRef, []),
        agent_identifier(PublicKey)],
       agent_hosted(Instance, NodeRef, 1, PublicKey)).

initialize_agent_host(agent_instance_ref(Ns, Anchor, Instance), NodeRef, PublicKey) :-
    in_ontology(Ns, Anchor,
        (assertz(agent_key(Instance, PublicKey, active)),
         assertz(agent_host(Instance, NodeRef, 1, PublicKey)))).

%% The expected assignment is supplied by the request, never inferred by the
%% desired-state planner. This prevents a stale recovery from rebasing a move.
agent_assignment(Instance, OldNode, OldEpoch, NodeRef, Epoch, PublicKey) :-
    term_variables(old(OldNode, OldEpoch), []),
    integer(OldEpoch), Epoch is OldEpoch + 1,
    agent_hosted(Instance, NodeRef, Epoch, PublicKey).

action(assign_agent_host(Instance, OldNode, OldEpoch, NodeRef, Epoch, PublicKey),
       [term_variables(old(OldNode, OldEpoch), []),
        current_principal(Principal),
        can_assign_agent_host(Principal, Instance, OldNode, OldEpoch, NodeRef, PublicKey),
        agent_hosted(Instance, OldNode, OldEpoch, _OldKey),
        integer(OldEpoch), Epoch is OldEpoch + 1,
        term_variables(NodeRef, []), agent_identifier(PublicKey),
        \+ agent_key(Instance, PublicKey, _)],
       agent_assignment(Instance, OldNode, OldEpoch, NodeRef, Epoch, PublicKey)).

assign_agent_host(Agent, OldNode, OldEpoch, NodeRef, Epoch, PublicKey) :-
    Agent = agent_instance_ref(Ns, Anchor, Instance),
    agent_hosted(Agent, OldNode, OldEpoch, OldKey),
    in_ontology(Ns, Anchor,
        (retract(agent_host(Instance, OldNode, OldEpoch, OldKey)),
         retract(agent_key(Instance, OldKey, active)),
         assertz(agent_key(Instance, OldKey, revoked)),
         assertz(agent_key(Instance, PublicKey, active)),
         assertz(agent_host(Instance, NodeRef, Epoch, PublicKey)))),
    agent_retract_matching(agent_recovery_round(Agent, _, _, _)),
    agent_retract_matching(agent_failure_report(Agent, _, _, _, _, _, _)),
    agent_retract_matching(agent_candidate_key(Agent, _, _, _, _)).

%% Recovery reports are current state, not an asserted event history. The
%% containing ontology grants observer authority and decides takeover policy.
%% Round and expected-report checks fence delayed reports and withdrawals.
agent_recovery_current(Instance, NodeRef, Epoch, Round) :-
    agent_hosted(Instance, NodeRef, Epoch, _),
    findall(recovery(N, E, R), agent_recovery_round(Instance, N, E, R),
            [recovery(NodeRef, Epoch, Round)]).

action(begin_agent_recovery(Instance, NodeRef, Epoch, Round),
       [current_principal(Observer),
        can_report_agent_failure(Observer, Instance, NodeRef, begin),
        agent_hosted(Instance, NodeRef, Epoch, _),
        \+ agent_recovery_round(Instance, _, _, _),
        agent_identifier(Round)],
       agent_recovery_current(Instance, NodeRef, Epoch, Round)).

begin_agent_recovery(agent_instance_ref(Ns, Anchor, Instance), NodeRef, Epoch, Round) :-
    in_ontology(Ns, Anchor,
        (assertz(agent_recovery_round(Instance, NodeRef, Epoch, Round)),
         trigger_event(agent_recovery_started(Instance, NodeRef, Epoch, Round)))).

%% Explicit resolution is governed by domain policy, including how to resolve
%% rounds whose observers have themselves disappeared. It grants no takeover.
agent_recovery_resolved(Instance, NodeRef, Epoch, Round) :-
    term_variables(recovery(Instance, NodeRef, Epoch, Round), []),
    agent_hosted(Instance, NodeRef, Epoch, _),
    \+ agent_recovery_round(Instance, NodeRef, Epoch, Round).

action(resolve_agent_recovery(Instance, NodeRef, Epoch, Round),
       [term_variables(recovery(Instance, NodeRef, Epoch, Round), []),
        current_principal(Principal),
        can_resolve_agent_recovery(Principal, Instance, NodeRef, Epoch, Round),
        agent_recovery_current(Instance, NodeRef, Epoch, Round)],
       agent_recovery_resolved(Instance, NodeRef, Epoch, Round)).

resolve_agent_recovery(Agent, NodeRef, Epoch, Round) :-
    Agent = agent_instance_ref(Ns, Anchor, Instance),
    in_ontology(Ns, Anchor, retract(agent_recovery_round(Instance, NodeRef, Epoch, Round))),
    agent_retract_matching(agent_failure_report(Agent, NodeRef, Epoch, Round, _, _, _)).

%% Custody is prepared by the destination principal and scoped to the current
%% assignment. Private keys remain in that node's vault, never in ontology facts.
action(prepare_agent_key(Instance, OldNode, OldEpoch, NodeRef, PublicKey),
       [current_principal(NodeRef),
        term_variables(old(OldNode, OldEpoch), []),
        integer(OldEpoch), OldEpoch > 0,
        agent_key_preparation(NodeRef, Instance, OldNode, OldEpoch, NodeRef),
        agent_identifier(PublicKey),
        \+ agent_key(Instance, PublicKey, _),
        \+ agent_candidate_key(Instance, OldNode, OldEpoch, NodeRef, _)],
       agent_candidate_key(Instance, OldNode, OldEpoch, NodeRef, PublicKey)).

prepare_agent_key(agent_instance_ref(Ns, Anchor, Instance), OldNode, OldEpoch, NodeRef, PublicKey) :-
    in_ontology(Ns, Anchor,
        assertz(agent_candidate_key(Instance, OldNode, OldEpoch, NodeRef, PublicKey))).

%% These compositions run inside the caller's ordinary signed transaction.
%% Check each action's postcondition before convergence consumes its state.
%% A first report establishes its round in the same transaction. The producer
%% captures ExpectedRound before observing: none cannot be rebased onto a
%% competing round, and current(Round) cannot silently start another one.
report_agent_observation(Instance, NodeRef, Epoch, ExpectedRound, Round, Observation, Kind) :-
    term_variables(report(Instance, NodeRef, Epoch, ExpectedRound, Round, Observation, Kind), []),
    agent_observation_round(ExpectedRound, Instance, NodeRef, Epoch, Round),
    report_agent_and_converge(Instance, NodeRef, Epoch, Round, Observation, Kind),
    (agent_recovery_current(Instance, NodeRef, Epoch, Round),
     current_principal(Principal),
     can_resolve_agent_recovery(Principal, Instance, NodeRef, Epoch, Round) ->
        goal(agent_recovery_resolved(Instance, NodeRef, Epoch, Round))
    ; true).

%% A newly measured observation may supply its destination's stable custody in
%% the same proof. Convergence follows reporting, after every prerequisite is
%% present. Neither branch retries an earlier uncertain signed operation.
report_agent_observation_with_custody(Instance, NodeRef, Epoch, ExpectedRound,
                                      Round, Observation, Kind, Preparation) :-
    term_variables(report(Instance, NodeRef, Epoch, ExpectedRound, Round,
                           Observation, Kind, Preparation), []),
    agent_observation_custody(Preparation, Instance, NodeRef, Epoch),
    report_agent_observation(Instance, NodeRef, Epoch, ExpectedRound,
                             Round, Observation, Kind).

agent_observation_custody(prepared(PublicKey), Instance, OldNode, OldEpoch) :-
    current_principal(Destination),
    goal(agent_candidate_key(Instance, OldNode, OldEpoch, Destination, PublicKey)).
agent_observation_custody(unavailable(_Reason), _, _, _).

agent_observation_round(none, Instance, NodeRef, Epoch, Round) :-
    \+ agent_recovery_round(Instance, _, _, _),
    goal(agent_recovery_current(Instance, NodeRef, Epoch, Round)).
agent_observation_round(current(Round), Instance, NodeRef, Epoch, Round) :-
    agent_recovery_current(Instance, NodeRef, Epoch, Round).

report_agent_and_converge(Instance, NodeRef, Epoch, Round, Observation, Kind) :-
    term_variables(report(Instance, NodeRef, Epoch, Round, Observation, Kind), []),
    current_principal(Observer),
    goal(agent_failure_report(Instance, NodeRef, Epoch, Round, Observer, Observation, Kind)),
    converge_agent_assignment(Instance, NodeRef, Epoch, Round).

prepare_agent_and_converge(Instance, OldNode, OldEpoch, NodeRef, PublicKey) :-
    term_variables(preparation(Instance, OldNode, OldEpoch, NodeRef, PublicKey), []),
    goal(agent_candidate_key(Instance, OldNode, OldEpoch, NodeRef, PublicKey)),
    (agent_recovery_current(Instance, OldNode, OldEpoch, Round) ->
        converge_agent_assignment(Instance, OldNode, OldEpoch, Round)
    ; true).

%% The containing ontology owns eligibility, observer threshold and ranking.
%% Only a prepared key for this exact assignment may be selected. Sorting makes
%% ties deterministic; the assignment action retains its ordinary authorization.
converge_agent_assignment(Instance, OldNode, OldEpoch, Round) :-
    term_variables(recovery(Instance, OldNode, OldEpoch, Round), []),
    agent_recovery_current(Instance, OldNode, OldEpoch, Round),
    current_principal(Principal),
    findall(candidate(Rank, NodeRef, PublicKey),
        (agent_candidate_key(Instance, OldNode, OldEpoch, NodeRef, PublicKey),
         \+ agent_key(Instance, PublicKey, _),
         agent_recovery_candidate(Principal, Instance, OldNode, OldEpoch, Round, NodeRef, Rank),
         term_variables(candidate(Rank, NodeRef, PublicKey), []),
         can_assign_agent_host(Principal, Instance, OldNode, OldEpoch, NodeRef, PublicKey)),
        Candidates),
    sort(Candidates, Ranked),
    agent_converge_candidate(Ranked, Instance, OldNode, OldEpoch).

agent_converge_candidate([], _, _, _).
agent_converge_candidate([candidate(_, NodeRef, PublicKey)|_], Instance, OldNode, OldEpoch) :-
    Epoch is OldEpoch + 1,
    goal(agent_assignment(Instance, OldNode, OldEpoch, NodeRef, Epoch, PublicKey)).

%% Multiple current rows are malformed state, not a sequence to guess past.
agent_report_next(Instance, NodeRef, Epoch, Round, Observer, Sequence) :-
    findall(Observation,
            agent_failure_report(Instance, NodeRef, Epoch, Round, Observer,
                                 Observation, _),
            Sequences),
    agent_report_sequence(Sequences, Sequence).

agent_report_sequence([], 1).
agent_report_sequence([observation(Previous, _, _)], Sequence) :-
    integer(Previous), Previous > 0, Sequence is Previous + 1.

agent_observation_kind(process_down).
agent_observation_kind(suspected_unreachable).
agent_observation_kind(reachable).
agent_observation_kind(withdrawing).

agent_failure_kind(process_down).
agent_failure_kind(suspected_unreachable).

action(report_agent_failure(Instance, NodeRef, Epoch, Round,
                            observation(Sequence, Observation, Expires), Kind),
       [current_principal(Observer),
        can_report_agent_failure(Observer, Instance, NodeRef, Kind),
        agent_recovery_current(Instance, NodeRef, Epoch, Round),
        agent_identifier(Observation), agent_observation_kind(Kind),
        current_request_expiry(Expires),
        agent_report_next(Instance, NodeRef, Epoch, Round, Observer, Sequence)],
       agent_failure_report(Instance, NodeRef, Epoch, Round,
                            Observer, observation(Sequence, Observation, Expires), Kind)).

report_agent_failure(Agent, NodeRef, Epoch, Round, Observation, Kind) :-
    current_principal(Observer),
    agent_retract_matching(agent_failure_report(Agent, NodeRef, Epoch, Round, Observer, _, _)),
    Agent = agent_instance_ref(Ns, Anchor, Instance),
    in_ontology(Ns, Anchor,
        (assertz(agent_failure_report(Instance, NodeRef, Epoch, Round, Observer, Observation, Kind)),
         trigger_event(agent_failure_observed(Instance, NodeRef, Epoch, Round,
                                              Observer, Observation, Kind)))).

%% A takeover request cannot outlive the signed observations it uses. This is
%% a comparison of authenticated/committed data, not a live clock predicate.
%% A containing ontology still supplies the observer set and threshold policy.
agent_failure_support(Instance, NodeRef, Epoch, Round, Observer, Kind) :-
    agent_failure_kind(Kind),
    agent_report_support(Instance, NodeRef, Epoch, Round, Observer, Kind).

agent_report_support(Instance, NodeRef, Epoch, Round, Observer, Kind) :-
    agent_observation_kind(Kind),
    agent_recovery_current(Instance, NodeRef, Epoch, Round),
    current_request_expiry(RequestExpiry),
    agent_failure_report(Instance, NodeRef, Epoch, Round, Observer, _, Kind),
    findall(report(Observation, ReportKind),
            agent_failure_report(Instance, NodeRef, Epoch, Round, Observer,
                                 Observation, ReportKind),
            [report(observation(_, _, ReportExpiry), Kind)]),
    RequestExpiry =< ReportExpiry.

can_sign_agent_request(Principal, NodeRef, Typed) :-
    Principal = NodeRef,
    Typed = agent_goal_v1(_, Agent, _, PublicKey, _, _, _, _, _),
    Agent = agent_instance_ref(Ns,A,Instance),
    agent_hosted(Agent,NodeRef,_,PublicKey),
    in_ontology(Ns,A,can_request_agent_signature(Principal,Instance,Typed)).

agent_retract_matching(Pattern) :-
    Pattern =.. [Name, agent_instance_ref(Ns, Anchor, Instance)|Arguments],
    Local =.. [Name, Instance|Arguments],
    in_ontology(Ns, Anchor, findall(Local, Local, Rows)),
    agent_retract_rows(ontology_ref(Ns, Anchor), Rows).

agent_retract_rows(_, []).
agent_retract_rows(ontology_ref(Ns, Anchor), [Row|Rows]) :-
    in_ontology(Ns, Anchor, retract(Row)),
    agent_retract_rows(ontology_ref(Ns, Anchor), Rows).
