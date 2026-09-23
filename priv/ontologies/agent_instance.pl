%% Actor-instance rules. The founding ontology supplies its administrator,
%% hosting policy and explicit signing grants. Messaging belongs to the domain.

agent_identifier(Value) :- binary_codes(Value, Bytes), length(Bytes, 32).

agent_hosted(Instance, NodeRef, Epoch, PublicKey) :-
    findall(host(N, E, K), agent_host(Instance, N, E, K),
            [host(NodeRef, Epoch, PublicKey)]),
    findall(K, agent_key(Instance, K, active), [PublicKey]).

state_handler(agent_hosting, [agent_host/4, agent_key/3], [], reconcile_agent_hosting).

reconcile_agent_hosting(Changed) :-
    agent_hosting_scope(Changed, Scope),
    (local_node_agent(Node) ->
        agent_hosting_instances(Scope, Node, Instances),
        findall(host(I, Node, E, K),
                (member(I, Instances), agent_hosted(I, Node, E, K)), Hosts)
    ; Hosts = []),
    project_agent_hosts(Scope, Hosts).

agent_hosting_scope(keys(Heads), keys(Instances)) :-
    findall(I, (member(Head, Heads), agent_hosting_head(Head, I)), Changed),
    term_variables(Changed, []),
    !,
    sort(Changed, Instances).
agent_hosting_scope(_, all).

agent_hosting_head(agent_host(I, _, _, _), I).
agent_hosting_head(agent_key(I, _, _), I).

agent_hosting_instances(keys(Instances), _, Instances).
agent_hosting_instances(all, Node, Instances) :-
    findall(I, agent_host(I, Node, _, _), Local),
    sort(Local, Instances).

executor_owner_node(agent(Instance), host(NodeRef, Epoch, PublicKey)) :-
    agent_hosted(Instance, NodeRef, Epoch, PublicKey).

action(initialize_agent_host(Instance, NodeRef, PublicKey),
       [current_principal(Administrator),
        can_assign_agent_host(Administrator, Instance, none, 0, NodeRef, PublicKey),
        \+ agent_host(Instance, _, _, _),
        \+ agent_key(Instance, _, _),
        term_variables(Instance, []), term_variables(NodeRef, []),
        agent_identifier(PublicKey)],
       agent_hosted(Instance, NodeRef, 1, PublicKey)).

initialize_agent_host(Instance, NodeRef, PublicKey) :-
    assertz(agent_key(Instance, PublicKey, active)),
    assertz(agent_host(Instance, NodeRef, 1, PublicKey)).

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

assign_agent_host(Instance, OldNode, OldEpoch, NodeRef, Epoch, PublicKey) :-
    agent_hosted(Instance, OldNode, OldEpoch, OldKey),
    retract(agent_host(Instance, OldNode, OldEpoch, OldKey)),
    retract(agent_key(Instance, OldKey, active)),
    assertz(agent_key(Instance, OldKey, revoked)),
    assertz(agent_key(Instance, PublicKey, active)),
    assertz(agent_host(Instance, NodeRef, Epoch, PublicKey)),
    agent_retract_matching(agent_recovery_round(Instance, _, _, _)),
    agent_retract_matching(agent_failure_report(Instance, _, _, _, _, _, _)),
    agent_retract_matching(agent_candidate_key(Instance, _, _, _, _)).

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

begin_agent_recovery(Instance, NodeRef, Epoch, Round) :-
    assertz(agent_recovery_round(Instance, NodeRef, Epoch, Round)),
    trigger_event(agent_recovery_started(Instance, NodeRef, Epoch, Round)).

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

resolve_agent_recovery(Instance, NodeRef, Epoch, Round) :-
    retract(agent_recovery_round(Instance, NodeRef, Epoch, Round)),
    agent_retract_matching(agent_failure_report(Instance, NodeRef, Epoch, Round, _, _, _)).

%% Custody is prepared by the destination principal and scoped to the current
%% assignment. Private keys remain in that node's vault, never in ontology facts.
action(prepare_agent_key(Instance, OldNode, OldEpoch, NodeRef, PublicKey),
       [current_principal(NodeRef),
        can_prepare_agent_key(NodeRef, Instance, OldNode, OldEpoch),
        term_variables(old(OldNode, OldEpoch), []),
        agent_hosted(Instance, OldNode, OldEpoch, _),
        agent_identifier(PublicKey),
        \+ agent_key(Instance, PublicKey, _),
        \+ agent_candidate_key(Instance, OldNode, OldEpoch, NodeRef, _)],
       agent_candidate_key(Instance, OldNode, OldEpoch, NodeRef, PublicKey)).

prepare_agent_key(Instance, OldNode, OldEpoch, NodeRef, PublicKey) :-
    assertz(agent_candidate_key(Instance, OldNode, OldEpoch, NodeRef, PublicKey)).

%% These compositions run inside the caller's ordinary signed transaction.
%% Check each action's postcondition before convergence consumes its state.
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

report_agent_failure(Instance, NodeRef, Epoch, Round, Observation, Kind) :-
    current_principal(Observer),
    agent_retract_matching(agent_failure_report(Instance, NodeRef, Epoch, Round, Observer, _, _)),
    assertz(agent_failure_report(Instance, NodeRef, Epoch, Round, Observer, Observation, Kind)),
    trigger_event(agent_failure_observed(Instance, NodeRef, Epoch, Round,
                                         Observer, Observation, Kind)).

%% A takeover request cannot outlive the signed observations it uses. This is
%% a comparison of authenticated/committed data, not a live clock predicate.
%% A containing ontology still supplies the observer set and threshold policy.
agent_failure_support(Instance, NodeRef, Epoch, Round, Observer, Kind) :-
    agent_failure_kind(Kind),
    agent_recovery_current(Instance, NodeRef, Epoch, Round),
    current_request_expiry(RequestExpiry),
    agent_failure_report(Instance, NodeRef, Epoch, Round, Observer, _, Kind),
    findall(report(Observation, ReportKind),
            agent_failure_report(Instance, NodeRef, Epoch, Round, Observer,
                                 Observation, ReportKind),
            [report(observation(_, _, ReportExpiry), Kind)]),
    RequestExpiry =< ReportExpiry.

can_sign_agent_request(Principal, NodeRef,
                       agent_goal_v1(Network, AgentRef, InstanceText, PublicKey,
                                     Operation, Deadline, Mode, Parser, GoalText)) :-
    Principal = NodeRef,
    AgentRef = agent_instance_ref(_, _, Instance),
    agent_hosted(Instance, NodeRef, _, PublicKey),
    can_request_agent_signature(Principal, Instance,
        agent_goal_v1(Network, AgentRef, InstanceText, PublicKey,
                      Operation, Deadline, Mode, Parser, GoalText)).

agent_retract_matching(Pattern) :-
    findall(Pattern, Pattern, Rows),
    agent_retract_rows(Rows).

agent_retract_rows([]).
agent_retract_rows([Row|Rows]) :-
    retract(Row),
    agent_retract_rows(Rows).
