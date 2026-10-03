%% Optional remote-host recovery policy, composed with agent_instance.pl.
%% The containing ontology supplies agent_recovery_observer/2,
%% agent_recovery_threshold/2, eligible_agent_host/2 and agent_host_rank/3.
%% No observers, destinations, initial-assignment or invocation rights are
%% granted implicitly. Observer reports are trusted statements, not proof of
%% physical death. Deployment must retain both report and commit quorum.

can_report_agent_failure(Observer, Instance, OldHost, Kind) :-
    agent_recovery_observer(Instance, Observer),
    Observer \= OldHost,
    agent_remote_observation_kind(Kind).

agent_remote_observation_kind(begin).
agent_remote_observation_kind(suspected_unreachable).
agent_remote_observation_kind(reachable).
agent_remote_observation_kind(withdrawing).

can_prepare_agent_key(Destination, Instance, OldHost, Epoch) :-
    agent_hosted(Instance, OldHost, Epoch, _),
    eligible_agent_host(Instance, Destination),
    Destination \= OldHost.

agent_recovery_executor(Principal, Instance) :-
    agent_recovery_observer(Instance, Principal).
agent_recovery_executor(Principal, Instance) :-
    eligible_agent_host(Instance, Principal).

agent_recovery_candidate(Principal, Instance, OldHost, Epoch, Round, Destination, Rank) :-
    agent_recovery_executor(Principal, Instance),
    Principal \= OldHost,
    agent_recovery_current(Instance, OldHost, Epoch, Round),
    eligible_agent_host(Instance, Destination),
    Destination \= OldHost,
    agent_host_rank(Instance, Destination, Rank),
    agent_recovery_observer(Instance, Destination),
    agent_report_support(Instance, OldHost, Epoch, Round, Destination, suspected_unreachable),
    agent_observer_threshold(Instance, OldHost, Epoch, Round, suspected_unreachable).

%% This public grant repeats no weaker alternative to the candidate policy:
%% direct assignment goals must prove the same threshold and exact custody.
can_assign_agent_host(Principal, Instance, OldHost, Epoch, Destination, PublicKey) :-
    agent_recovery_current(Instance, OldHost, Epoch, Round),
    agent_candidate_key(Instance, OldHost, Epoch, Destination, PublicKey),
    agent_recovery_candidate(Principal, Instance, OldHost, Epoch, Round, Destination, _).

can_resolve_agent_recovery(Principal, Instance, OldHost, Epoch, Round) :-
    agent_recovery_observer(Instance, Principal),
    Principal \= OldHost,
    agent_observer_threshold(Instance, OldHost, Epoch, Round, reachable).

%% Duplicate observer declarations do not add votes. Ambiguous threshold
%% configuration fails closed. Only current authorized observers count, and
%% every supporting report must cover the signed request's own expiry.
agent_observer_threshold(Instance, OldHost, Epoch, Round, Kind) :-
    findall(N, agent_recovery_threshold(Instance, N), [Required]),
    integer(Required), Required > 0,
    findall(Observer,
        (agent_recovery_observer(Instance, Observer),
         Observer \= OldHost,
         agent_report_support(Instance, OldHost, Epoch, Round, Observer, Kind)),
        Observers),
    sort(Observers, Distinct),
    length(Distinct, Count),
    Count >= Required.

%% The containing ontology owns its current observation inventory.
agent_observation_projection(Scope, Observer, Scope, Watches) :-
    (Observer \= none ->
        agent_observation_instances(Scope, Observer, Instances),
        findall(watch(I, Host, Epoch, Round),
            (member(I, Instances), agent_recovery_observer(I, Observer),
             agent_hosted(I, Host, Epoch, _), Host \= Observer,
             agent_observed_round(I, Host, Epoch, Round)), Raw),
        sort(Raw, Watches)
    ; Watches = []).

agent_observation_instances(keys(Instances), _, Instances).
agent_observation_instances(all, Observer, Instances) :-
    findall(I, agent_recovery_observer(I, Observer), Raw), sort(Raw, Instances).

agent_observed_round(I, Host, Epoch, Round) :-
    findall(recovery(H, E, R), agent_recovery_round(I, H, E, R), Rows),
    agent_observed_round_rows(Rows, Host, Epoch, Round).
agent_observed_round_rows([], _, _, none).
agent_observed_round_rows([recovery(H, E, R)], H, E, current(R)).

%% The source worker selects data under restricted committed policy. The
%% observer and observation fields are authenticated inputs, not policy output.
agent_recovery_data(Observer, I, Host, Epoch, Expected, Round, Kind,
                    ObservedAt, Maximum, recovery(Sequence, Expiry, Preparation)) :-
    can_report_agent_failure(Observer, I, Host, Kind),
    agent_hosted(I, Host, Epoch, _),
    agent_observed_round(I, Host, Epoch, Expected),
    agent_report_next(I, Host, Epoch, Round, Observer, Sequence),
    agent_observation_expiry(I, Host, Epoch, Round, Observer, Kind,
                             ObservedAt, Maximum, Expiry),
    (Kind = suspected_unreachable,
     can_prepare_agent_key(Observer, I, Host, Epoch),
     \+ agent_candidate_key(I, Host, Epoch, Observer, _) -> Preparation = required
    ; agent_failure_report(I, Host, Epoch, Round, Observer,
                           observation(_, _, ReportExpiry), Kind),
      ReportExpiry > ObservedAt -> fail
    ; Preparation = none).

%% Choose a live supporting subset. Expired or unauthorized rows cannot veto
%% renewal, and the new request may not outlive the reports it needs to count.
agent_observation_expiry(I, Host, Epoch, Round, Observer, Kind, Now, Maximum, Expiry) :-
    findall(N, agent_recovery_threshold(I, N), [Required]),
    integer(Required), Required > 0,
    Needed is Required - 1,
    findall(support(NegativeExpiry, Other),
        (agent_recovery_observer(I, Other), Other \= Observer, Other \= Host,
         findall(report(Observation, K),
            agent_failure_report(I, Host, Epoch, Round, Other, Observation, K),
            [report(observation(_, _, ReportExpiry), Kind)]),
         integer(ReportExpiry), ReportExpiry > Now,
         NegativeExpiry is -ReportExpiry), Raw),
    sort(Raw, Supports), length(Supports, Count),
    (Count >= Needed -> agent_support_expiry(Needed, Supports, Maximum, Expiry)
    ; Expiry = Maximum).

agent_support_expiry(0, _, Expiry, Expiry).
agent_support_expiry(Needed, [support(Negative, _)|Rest], Maximum, Expiry) :-
    Needed > 0, Remaining is Needed - 1,
    SupportedExpiry is -Negative,
    (SupportedExpiry < Maximum -> Ceiling = SupportedExpiry ; Ceiling = Maximum),
    agent_support_expiry(Remaining, Rest, Ceiling, Expiry).
