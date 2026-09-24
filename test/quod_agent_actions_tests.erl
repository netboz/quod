-module(quod_agent_actions_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

initial_assignment_requires_inactive_instance_and_epoch_one_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    with_actor([], <<"can_assign_agent_host(_, actor, _, _, _, _).\n">>, fun(St, _) ->
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {goal, {agent_assignment, actor, Node, 1, Node, 2, hash(6)}}, St)),
        {succeed, Started} = erlog_int:prove_goal(
          {goal, {agent_hosted, actor, Node, 1, hash(6)}}, St),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {goal, {agent_hosted, actor, Node, 1, hash(7)}}, Started)),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {goal, {agent_assignment, actor, Node, 1, Node, 2, hash(7)}}, Started))
    end),
    with_actor([{agent_key, actor, hash(6), revoked}],
      <<"can_assign_agent_host(_, actor, _, _, _, _).\n">>, fun(St, _) ->
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {goal, {agent_hosted, actor, Node, 1, hash(7)}}, St))
    end).

same_node_epoch_rotates_key_and_refuses_reuse_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    Facts = [{agent_host, actor, Node, 1, hash(6)},
             {agent_key, actor, hash(6), active}],
    with_actor(Facts, <<"can_assign_agent_host(_, actor, _, _, _, _).\n">>,
      fun(St, _) ->
          {succeed, Next} = erlog_int:prove_goal(
            {goal, {agent_assignment, actor, Node, 1, Node, 2, hash(7)}}, St),
          ?assertMatch({succeed, _}, erlog_int:prove_goal(
            {agent_key, actor, hash(6), revoked}, Next)),
          ?assertMatch({fail, _}, erlog_int:prove_goal(
            {goal, {agent_assignment, actor, Node, 2, Node, 3, hash(6)}}, Next)),
          ?assertMatch({fail, _}, erlog_int:prove_goal(
            {goal, {agent_assignment, actor, Node, 2, Node, 4, hash(8)}}, Next))
      end).

ambiguous_host_has_no_current_assignment_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    with_actor([{agent_host, actor, Node, 1, hash(6)},
                {agent_host, actor, Node, 2, hash(6)},
                {agent_key, actor, hash(6), active}],
      <<"can_assign_agent_host(_, actor, _, _, _, _).\n">>, fun(St, _) ->
          ?assertMatch({fail, _}, erlog_int:prove_goal(
            {agent_hosted, actor, {'N'}, {'E'}, {'K'}}, St)),
          ?assertMatch({fail, _}, erlog_int:prove_goal(
            {goal, {agent_assignment, actor, Node, 2, Node, 3, hash(7)}}, St))
      end).

unauthorized_assignment_changes_nothing_test() ->
    with_actor([], <<>>, fun(St, _) ->
        {fail, Final} = erlog_int:prove_goal(
          {goal, {agent_hosted, actor,
                  {agent_instance_ref, <<"node">>, hash(5), physical_node}, 1, hash(6)}}, St),
        ?assertEqual([], changes(Final))
    end).

signing_grant_cannot_delegate_host_identity_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    Ref = {agent_instance_ref, <<"agent">>, hash(1), actor},
    Typed = {agent_goal_v1, hash(1), Ref, <<"actor.">>, hash(6),
             hash(7), 1000, execute, 2, <<"true.">>},
    with_actor([{agent_host, actor, Node, 1, hash(6)},
                {agent_key, actor, hash(6), active},
                {can_request_agent_signature, Node, actor, Typed},
                {can_request_agent_signature, other, actor, Typed}], <<>>, fun(St, _) ->
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {can_sign_agent_request, Node, Node, Typed}, St)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {can_sign_agent_request, other, Node, Typed}, St))
    end).

hash(N) -> binary:copy(<<N>>, 32).

failure_report_is_bounded_state_and_unasserted_event_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    Round = hash(10),
    with_actor([{agent_host, actor, Node, 1, hash(6)},
                {agent_key, actor, hash(6), active}],
      <<"can_report_agent_failure(_, actor, _, _).\n">>, fun(St, Observer) ->
        {ok, Expiry} = quod_proof_context:request_expiry(),
        {succeed, Started} = erlog_int:prove_goal(
            {goal, {agent_recovery_current, actor, Node, 1, Round}}, St),
        Report = {agent_failure_report, actor, Node, 1, Round,
                  Observer, {observation, 1, hash(11), Expiry}, suspected_unreachable},
        {succeed, Reported} = erlog_int:prove_goal({goal, Report}, Started),
        Event = setelement(1, Report, agent_failure_observed),
        ?assert(lists:member({event, Event}, changes(Reported))),
        ?assertMatch({fail, _}, erlog_int:prove_goal(Event, Reported)),
        {succeed, Duplicate} = erlog_int:prove_goal({goal, Report}, Reported),
        ?assertEqual(changes(Reported), changes(Duplicate)),
        Withdrawal = {agent_failure_report, actor, Node, 1, Round,
                      Observer, {observation, 2, hash(12), Expiry}, reachable},
        {succeed, Withdrawn} = erlog_int:prove_goal({goal, Withdrawal}, Reported),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
            {agent_failure_support, actor, Node, 1, Round, Observer, reachable}, Withdrawn)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(Report, Withdrawn)),
        ?assertMatch({fail, _}, erlog_int:prove_goal({goal, Report}, Withdrawn)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
            {goal, setelement(7, Withdrawal, {observation, 4, hash(13), Expiry})}, Withdrawn))
    end).

failure_report_rejects_wrong_principal_round_and_epoch_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    Round = hash(10),
    Facts = [{agent_host, actor, Node, 1, hash(6)},
             {agent_key, actor, hash(6), active},
             {agent_recovery_round, actor, Node, 1, Round}],
    with_actor(Facts, <<"can_report_agent_failure(_, actor, _, _).\n">>,
      fun(St, Observer) ->
        {ok, Expiry} = quod_proof_context:request_expiry(),
        Report = {agent_failure_report, actor, Node, 1, Round,
                  Observer, {observation, 1, hash(11), Expiry}, suspected_unreachable},
        lists:foreach(fun(Bad) ->
            {fail, Final} = erlog_int:prove_goal({goal, Bad}, St),
            ?assertEqual([], changes(Final))
        end, [setelement(4, Report, 2), setelement(5, Report, hash(12)),
              setelement(6, Report, other), setelement(8, Report, dead),
              setelement(7, Report, {observation, 1, hash(11), Expiry + 1})])
    end),
    with_actor(Facts, <<>>, fun(St, Observer) ->
        {ok, Expiry} = quod_proof_context:request_expiry(),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {goal, {agent_failure_report, actor, Node, 1, Round,
                  Observer, {observation, 1, hash(11), Expiry}, suspected_unreachable}}, St))
    end).

first_observation_establishes_round_without_rebasing_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    Round = hash(10),
    Facts = [{agent_host, actor, Node, 1, hash(6)},
             {agent_key, actor, hash(6), active}],
    with_actor(Facts, <<"can_report_agent_failure(_, actor, _, _).\n">>,
      fun(St, Observer) ->
        {ok, Expiry} = quod_proof_context:request_expiry(),
        First = {report_agent_observation, actor, Node, 1, none, Round,
                 {observation, 1, hash(11), Expiry}, suspected_unreachable},
        {succeed, Reported} = erlog_int:prove_goal(First, St),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_failure_report, actor, Node, 1, Round, Observer,
           {observation, 1, hash(11), Expiry}, suspected_unreachable}, Reported)),
        %% Even an identical first report is not a fresh observation of the
        %% now-existing round; the expectation is checked before goal/1.
        ?assertMatch({fail, _}, erlog_int:prove_goal(First, Reported)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          setelement(6, First, hash(12)), Reported)),
        Next = {report_agent_observation, actor, Node, 1, {current, Round}, Round,
                {observation, 2, hash(13), Expiry}, reachable},
        ?assertMatch({succeed, _}, erlog_int:prove_goal(Next, Reported)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(Next, St)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          setelement(5, First, {'Expected'}), St))
    end).

takeover_request_cannot_outlive_its_report_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    Round = hash(10),
    Facts = [{agent_host, actor, Node, 1, hash(6)},
             {agent_key, actor, hash(6), active},
             {agent_recovery_round, actor, Node, 1, Round}],
    with_actor(Facts, <<>>, fun(St, Observer) ->
        {ok, Expiry} = quod_proof_context:request_expiry(),
        lists:foreach(fun({ReportExpiry, Expected}) ->
            Report = {agent_failure_report, actor, Node, 1, Round, Observer,
                      {observation, 1, hash(11), ReportExpiry}, suspected_unreachable},
            {succeed, WithReport} = erlog_int:prove_goal({assertz, Report}, St),
            Result = erlog_int:prove_goal(
                {agent_failure_support, actor, Node, 1, Round, Observer,
                 suspected_unreachable}, WithReport),
            ?assertEqual(Expected, element(1, Result))
        end, [{Expiry - 1, fail}, {Expiry, succeed}, {Expiry + 1, succeed}])
    end).

assignment_clears_obsolete_recovery_state_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    Facts = [{agent_host, actor, Node, 1, hash(6)},
             {agent_key, actor, hash(6), active},
             {agent_recovery_round, actor, Node, 1, hash(10)},
             {agent_failure_report, actor, Node, 1, hash(10), observer,
              {observation, 1, hash(11), 1000}, suspected_unreachable}],
    with_actor(Facts, <<"can_assign_agent_host(_, actor, _, _, _, _).\n">>, fun(St, _) ->
        {succeed, Moved} = erlog_int:prove_goal(
            {goal, {agent_assignment, actor, Node, 1, Node, 2, hash(7)}}, St),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
            {agent_recovery_round, actor, {'N'}, {'E'}, {'R'}}, Moved)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
            {agent_failure_report, actor, {'N'}, {'E'}, {'R'}, {'O'}, {'Id'}, {'K'}}, Moved))
    end).

recovery_assignment_cannot_rebase_stale_or_unbound_expectation_test() ->
    Old = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    New = setelement(2, Old, <<"new">>),
    with_actor([{agent_host, actor, Old, 1, hash(6)},
                {agent_key, actor, hash(6), active}],
      <<"can_assign_agent_host(_, actor, _, _, _, _).\n">>, fun(St, _) ->
        Move = {goal, {agent_assignment, actor, Old, 1, New, 2, hash(7)}},
        {succeed, Moved} = erlog_int:prove_goal(Move, St),
        {succeed, Duplicate} = erlog_int:prove_goal(Move, Moved),
        ?assertEqual(changes(Moved), changes(Duplicate)),
        lists:foreach(fun(State) ->
            ?assertMatch({fail, _}, erlog_int:prove_goal({goal, State}, Moved))
        end, [{agent_assignment, actor, Old, 1, Old, {'Epoch'}, hash(8)},
              {agent_assignment, actor, New, {'OldEpoch'}, Old, {'Epoch'}, hash(8)},
              {agent_assignment, actor, {'Old'}, 2, Old, {'Epoch'}, hash(8)},
              {agent_hosted, actor, Old, {'Epoch'}, hash(8)}])
    end).

explicit_recovery_resolution_rearms_without_asserted_history_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    Round = hash(10),
    Rules = <<"can_report_agent_failure(_, actor, _, _).\n"
              "can_resolve_agent_recovery(_, I, N, E, R) :- "
              "\\+ (agent_failure_report(I,N,E,R,_,_,K), agent_failure_kind(K)).\n">>,
    with_actor([{agent_host, actor, Node, 1, hash(6)},
                {agent_key, actor, hash(6), active},
                {agent_recovery_round, actor, Node, 1, Round},
                {agent_candidate_key, actor, Node, 1, destination, hash(7)}], Rules,
      fun(St, Observer) ->
        {ok, Expiry} = quod_proof_context:request_expiry(),
        Report = {agent_failure_report, actor, Node, 1, Round, Observer,
                   {observation, 1, hash(11), Expiry}, suspected_unreachable},
        {succeed, Suspect} = erlog_int:prove_goal({goal, Report}, St),
        Resolve = {goal, {agent_recovery_resolved, actor, Node, 1, Round}},
        ?assertMatch({fail, _}, erlog_int:prove_goal(Resolve, Suspect)),
        {succeed, Reachable} = erlog_int:prove_goal(
          {goal, setelement(8, setelement(7, Report,
            {observation, 2, hash(12), Expiry}), reachable)}, Suspect),
        {succeed, Resolved} = erlog_int:prove_goal(Resolve, Reachable),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_candidate_key, actor, Node, 1, destination, hash(7)}, Resolved)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {agent_failure_report, actor, Node, 1, Round, Observer, {'O'}, {'K'}}, Resolved)),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {goal, {agent_recovery_current, actor, Node, 1, hash(13)}}, Resolved))
    end).

atomic_report_converges_only_with_prepared_key_and_threshold_test() ->
    recovery_fixture(fun(St, Observer, Old, Round, Expiry) ->
        Candidate = {agent_candidate_key, actor, Old, 1, Observer, hash(7)},
        {succeed, Prepared} = erlog_int:prove_goal({goal, Candidate}, St),
        Report = {observation, 1, hash(11), Expiry},
        Goal = {report_agent_and_converge, actor, Old, 1, Round, Report, suspected_unreachable},
        {succeed, Moved} = erlog_int:prove_goal(Goal, Prepared),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_hosted, actor, Observer, 2, hash(7)}, Moved)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(Candidate, Moved)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {agent_recovery_round, actor, Old, 1, Round}, Moved)),
        ?assert(lists:member({event, {agent_failure_observed, actor, Old, 1, Round,
                     Observer, Report, suspected_unreachable}}, changes(Moved))),
        ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, Moved)),
        %% Without a key, the observation persists as current state. Installing
        %% the key later invokes the very same convergence proof.
        {succeed, Reported} = erlog_int:prove_goal(Goal, St),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_hosted, actor, Old, 1, hash(6)}, Reported)),
        {succeed, LatePrepared} = erlog_int:prove_goal(
          {prepare_agent_and_converge, actor, Old, 1, Observer, hash(7)}, Reported),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_hosted, actor, Observer, 2, hash(7)}, LatePrepared)),
        %% A duplicate observation still evaluates convergence when a candidate
        %% has arrived, without publishing the observation a second time.
        {succeed, HasKey} = erlog_int:prove_goal({goal, Candidate}, Reported),
        {succeed, Duplicate} = erlog_int:prove_goal(Goal, HasKey),
        ?assertEqual(1, length([E || {event, E = {agent_failure_observed, _, _, _, _, _, _, _}}
                                      <- changes(Duplicate)]))
    end).

candidate_key_requires_destination_authority_and_fresh_custody_test() ->
    recovery_fixture(fun(St, Observer, Old, _Round, _Expiry) ->
        lists:foreach(fun(Candidate) ->
          {fail, Failed} = erlog_int:prove_goal({goal, Candidate}, St),
          ?assertEqual([], changes(Failed))
        end, [{agent_candidate_key, actor, Old, 1, other, hash(7)},
              {agent_candidate_key, actor, Old, 1, Observer, hash(6)},
              {agent_candidate_key, actor, Old, 2, Observer, hash(7)}]),
        Candidate = {agent_candidate_key, actor, Old, 1, Observer, hash(7)},
        {succeed, Prepared} = erlog_int:prove_goal({goal, Candidate}, St),
        {succeed, Duplicate} = erlog_int:prove_goal({goal, Candidate}, Prepared),
        ?assertEqual(changes(Prepared), changes(Duplicate)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {goal, setelement(6, Candidate, hash(8))}, Prepared))
    end).

report_composition_refuses_inferred_observation_or_kind_test() ->
    recovery_fixture(fun(St, _Observer, Old, Round, Expiry) ->
        lists:foreach(fun({Observation, Kind}) ->
            {fail, Final} = erlog_int:prove_goal(
              {report_agent_and_converge, actor, Old, 1, Round, Observation, Kind}, St),
            ?assertEqual([], changes(Final))
        end, [{{observation, 1, hash(11), Expiry}, {'Kind'}},
              {{observation, {'Sequence'}, hash(11), Expiry}, reachable},
              {{'Observation'}, reachable}]),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {prepare_agent_and_converge, {'Instance'}, Old, 1, {'Destination'}, hash(7)}, St))
    end).

assignment_grant_binds_threshold_expected_host_and_exact_candidate_key_test() ->
    Authority = <<"can_assign_agent_host(P,I,H,E,N,K) :- "
                  "agent_recovery_current(I,H,E,R), agent_candidate_key(I,H,E,N,K), "
                  "agent_recovery_candidate(P,I,H,E,R,N,_).\n">>,
    recovery_fixture(fun(St, Observer, Old, Round, Expiry) ->
        {succeed, Prepared} = erlog_int:prove_goal(
          {goal, {agent_candidate_key, actor, Old, 1, Observer, hash(7)}}, St),
        Move = {agent_assignment, actor, Old, 1, Observer, 2, hash(7)},
        %% Calling the ordinary assignment action directly must still prove
        %% the threshold; convergence is not a separate security boundary.
        ?assertMatch({fail, _}, erlog_int:prove_goal({goal, Move}, Prepared)),
        Report = {agent_failure_report, actor, Old, 1, Round, Observer,
                   {observation, 1, hash(11), Expiry}, suspected_unreachable},
        {succeed, Supported} = erlog_int:prove_goal({goal, Report}, Prepared),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {goal, setelement(7, Move, hash(8))}, Supported)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {goal, setelement(4, Move, {'OldEpoch'})}, Supported)),
        ?assertMatch({succeed, _}, erlog_int:prove_goal({goal, Move}, Supported))
    end, Authority).

remote_policy_requires_distinct_current_authorized_observers_test() ->
    with_remote_policy(fun(St, Observer, Old, Other, Destination, Round, Expiry) ->
        Move = {goal, {agent_assignment, actor, Old, 1, Destination, 2, hash(7)}},
        ?assertMatch({fail, _}, erlog_int:prove_goal(Move, St)),
        %% Repeating the same authorized observer cannot manufacture a vote.
        {succeed, Duplicate} = erlog_int:prove_goal(
          {assertz, {agent_recovery_observer, actor, Other}}, St),
        ?assertMatch({fail, _}, erlog_int:prove_goal(Move, Duplicate)),
        Report = {report_agent_and_converge, actor, Old, 1, Round,
                    {observation, 1, hash(20), Expiry}, suspected_unreachable},
        {succeed, Moved} = erlog_int:prove_goal(Report, Duplicate),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_hosted, actor, Destination, 2, hash(7)}, Moved)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {agent_failure_report, actor, Old, 1, Round, Observer, {'O'}, {'K'}}, Moved)),
        %% A principal removed from current observer policy contributes no
        %% support, even if its old signed observation remains in the ontology.
        {succeed, Removed} = erlog_int:prove_goal(
          {retract, {agent_recovery_observer, actor, Other}}, St),
        {succeed, Reported} = erlog_int:prove_goal(Report, Removed),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_hosted, actor, Old, 1, hash(6)}, Reported)),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_failure_report, actor, Old, 1, Round, Observer,
           {observation, 1, hash(20), Expiry}, suspected_unreachable}, Reported))
    end).

remote_policy_refuses_ambiguous_threshold_and_expired_support_test() ->
    with_remote_policy(fun(St, Observer, Old, Other, Destination, Round, Expiry) ->
        Report = {goal, {agent_failure_report, actor, Old, 1, Round, Observer,
                         {observation, 1, hash(20), Expiry}, suspected_unreachable}},
        {succeed, Supported} = erlog_int:prove_goal(Report, St),
        Move = {goal, {agent_assignment, actor, Old, 1, Destination, 2, hash(7)}},
        ?assertMatch({succeed, _}, erlog_int:prove_goal(Move, Supported)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {goal, {agent_assignment, actor, Old, 1, Destination, 2, hash(8)}}, Supported)),
        {succeed, Ambiguous} = erlog_int:prove_goal(
          {assertz, {agent_recovery_threshold, actor, 1}}, Supported),
        ?assertMatch({fail, _}, erlog_int:prove_goal(Move, Ambiguous)),
        {succeed, Expired} = erlog_int:prove_goal(
          {',', {retract, {agent_failure_report, actor, Old, 1, Round, Other, {'O'}, {'K'}}},
                {assertz, {agent_failure_report, actor, Old, 1, Round, Other,
                            {observation, 2, hash(22), 1}, suspected_unreachable}}}, Supported),
        ?assertMatch({fail, _}, erlog_int:prove_goal(Move, Expired))
    end).

remote_policy_resolves_false_alarm_without_losing_prepared_custody_test() ->
    with_remote_policy(fun(St, Observer, Old, Other, Destination, Round, Expiry) ->
        {succeed, Reachable} = erlog_int:prove_goal(
          {',', {retract, {agent_failure_report, actor, Old, 1, Round, Other, {'O'}, {'K'}}},
                {assertz, {agent_failure_report, actor, Old, 1, Round, Other,
                            {observation, 2, hash(22), Expiry}, reachable}}}, St),
        Resolution = {goal, {agent_recovery_resolved, actor, Old, 1, Round}},
        ?assertMatch({fail, _}, erlog_int:prove_goal(Resolution, Reachable)),
        {succeed, Resolved} = erlog_int:prove_goal(
          {',', {report_agent_and_converge, actor, Old, 1, Round,
                   {observation, 1, hash(20), Expiry}, reachable}, Resolution}, Reachable),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {agent_failure_report, actor, Old, 1, Round, Observer, {'R'}, {'T'}}, Resolved)),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_candidate_key, actor, Old, 1, Destination, hash(7)}, Resolved))
    end).

remote_policy_requires_fresh_destination_report_before_selecting_prepared_key_test() ->
    with_remote_policy(fun(St, Observer, Old, _Other, Destination, Round, Expiry) ->
        Third = {agent_instance_ref, <<"third-observer">>, hash(31), node},
        {succeed, Quorum} = erlog_int:prove_goal(
          {',', {assertz, {agent_recovery_observer, actor, Third}},
                {assertz, {agent_failure_report, actor, Old, 1, Round, Third,
                            {observation, 1, hash(32), Expiry}, suspected_unreachable}}}, St),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_observer_threshold, actor, Old, 1, Round, suspected_unreachable}, Quorum)),
        Move = {goal, {agent_assignment, actor, Old, 1, Destination, 2, hash(7)}},
        ?assertMatch({fail, _}, erlog_int:prove_goal(Move, Quorum)),
        {succeed, PreparedAndLive} = erlog_int:prove_goal(
          {goal, {agent_failure_report, actor, Old, 1, Round, Observer,
                   {observation, 1, hash(33), Expiry}, suspected_unreachable}}, Quorum),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(Move, PreparedAndLive))
    end).

repeated_observation_keeps_support_stable_without_losing_new_work_test() ->
    Observer = {agent_instance_ref, <<"observer">>, hash(11), node},
    Old = {agent_instance_ref, <<"old">>, hash(5), node},
    Round = hash(10), Now = 1000000, Expiry = Now + 30000,
    Report = {agent_failure_report, actor, Old, 1, Round, Observer,
              {observation, 1, hash(45), Expiry}, suspected_unreachable},
    Candidate = {agent_candidate_key, actor, Old, 1, Observer, hash(7)},
    Facts = [{local_node_agent, Observer},
             {agent_host, actor, Old, 1, hash(6)}, {agent_key, actor, hash(6), active},
             {agent_recovery_round, actor, Old, 1, Round},
             {agent_recovery_observer, actor, Observer},
             {eligible_agent_host, actor, Observer}, {agent_recovery_threshold, actor, 2}],
    {ok, Instance} = file:read_file(filename:join(code:priv_dir(quod),
                                                  "ontologies/agent_instance.pl")),
    {ok, Policy} = file:read_file(filename:join(code:priv_dir(quod),
                                                "ontologies/agent_recovery_policy.pl")),
    %% Exercise the actual reaction's decision and binding. These interpreted
    %% leaves record its external submission boundary; custody and signed ingress
    %% are exercised separately by quod_agent_custody_tests and the QUIC suite.
    Leaves = <<"submit_node_goal(execute,G,E) :- assertz(submitted(plain(G,E))).\n"
               "submit_node_prepared_goal(I,H,P,G,E) :- P=unavailable(test_vault), "
               "assertz(submitted(prepared(I,H,G,E))).\n">>,
    Cases = [{[Report, Candidate], suspected_unreachable, Now, 2, none},
             {[Report, Candidate], suspected_unreachable, Expiry, 2, plain},
             {[Report, Candidate], reachable, Now, 2, plain},
             {[Report], suspected_unreachable, Now, 2, prepared},
             {[Report, setelement(7, Report, {observation, 2, hash(47), Expiry}), Candidate],
              suspected_unreachable, Now, 0, ambiguous},
             {[setelement(5, Report, hash(48)), Candidate], suspected_unreachable, Now, 1, plain}],
    lists:foreach(fun({Rows, Kind, At, Sequence, Wanted}) ->
        St = quod_ct:action_overlay(iolist_to_binary([Instance, Policy, Leaves]), [], Facts ++ Rows),
        Maximum = At + 60000,
        Goal = {react_agent_host_observation, Observer, actor, Old, 1, {current, Round},
                Round, hash(46), Kind, At, Maximum},
        {Status, Final} = erlog_int:prove_goal(Goal, St),
        ExpectedStatus = case Wanted of ambiguous -> fail; _ -> succeed end,
        ?assertEqual(ExpectedStatus, Status),
        Entry = {report_agent_observation, actor, Old, 1, {current, Round}, Round,
                 {observation, Sequence, hash(46), Maximum}, Kind},
        Submitted = case Wanted of
            none -> [];
            ambiguous -> [];
            plain -> [{plain, Entry, Maximum}];
            prepared ->
                Prepared = list_to_tuple([report_agent_observation_with_custody |
                                         tl(tuple_to_list(Entry))] ++ [{unavailable, test_vault}]),
                [{prepared, actor, 1, Prepared, Maximum}]
        end,
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {findall, {'S'}, {submitted, {'S'}}, Submitted}, Final))
    end, Cases).

observation_expiry_uses_live_authorized_subset_test() ->
    with_remote_policy(fun(St, Observer, Old, Other, _Destination, Round, _Signed) ->
        Now = quod_time:now_ms(), Maximum = Now + 60000, Short = Now + 30000,
        Add = [{agent_recovery_observer, actor, shorter},
               {agent_recovery_observer, actor, shorter},
               {agent_failure_report, actor, Old, 1, Round, shorter,
                {observation, 1, hash(40), Short}, suspected_unreachable},
               {agent_recovery_observer, actor, expired},
               {agent_failure_report, actor, Old, 1, Round, expired,
                {observation, 1, hash(41), Now - 1}, suspected_unreachable}],
        WithRows = lists:foldl(fun(F, Acc) ->
            {succeed, Next} = erlog_int:prove_goal({assertz, F}, Acc), Next
        end, St, Add),
        Deadline = fun(E) -> {agent_observation_expiry, actor, Old, 1, Round,
                              Observer, suspected_unreachable, Now, Maximum, E} end,
        %% One long-lived authorized vote is sufficient; a shorter irrelevant
        %% vote, expired vote and an untrusted vote cannot cap the request.
        ?assertMatch({succeed, _}, erlog_int:prove_goal(Deadline(Maximum), WithRows)),
        {succeed, WithoutLong} = erlog_int:prove_goal(
            {retract, {agent_recovery_observer, actor, Other}}, WithRows),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(Deadline(Short), WithoutLong)),
        {succeed, RemovedOnce} = erlog_int:prove_goal(
            {retract, {agent_recovery_observer, actor, shorter}}, WithoutLong),
        {succeed, RemovedTwice} = erlog_int:prove_goal(
            {retract, {agent_recovery_observer, actor, shorter}}, RemovedOnce),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(Deadline(Maximum), RemovedTwice))
    end).

reachable_observation_resolves_in_its_own_transaction_test() ->
    Node = {agent_instance_ref, <<"node">>, hash(5), physical_node}, Round = hash(10),
    Rules = <<"can_report_agent_failure(_, actor, _, _).\n"
              "can_resolve_agent_recovery(P,I,H,E,R) :- "
              "agent_failure_report(I,H,E,R,P,_,reachable).\n">>,
    with_actor([{agent_host, actor, Node, 1, hash(6)}, {agent_key, actor, hash(6), active},
                {agent_recovery_round, actor, Node, 1, Round},
                {agent_candidate_key, actor, Node, 1, destination, hash(7)}], Rules,
      fun(St, Observer) ->
        {ok, Expiry} = quod_proof_context:request_expiry(),
        {succeed, Resolved} = erlog_int:prove_goal(
          {report_agent_observation, actor, Node, 1, {current, Round}, Round,
           {observation, 1, hash(11), Expiry}, reachable}, St),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {agent_recovery_round, actor, Node, 1, Round}, Resolved)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
          {agent_failure_report, actor, Node, 1, Round, Observer, {'_'}, {'_'}}, Resolved)),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
          {agent_candidate_key, actor, Node, 1, destination, hash(7)}, Resolved))
    end).

with_remote_policy(Fun) ->
    {ok, Policy} = file:read_file(filename:join(code:priv_dir(quod),
                                               "ontologies/agent_recovery_policy.pl")),
    Old = {agent_instance_ref, <<"old">>, hash(5), node},
    Other = {agent_instance_ref, <<"observer">>, hash(11), node},
    Round = hash(10), Expiry = quod_time:now_ms() + 600000,
    Facts = [{agent_host, actor, Old, 1, hash(6)}, {agent_key, actor, hash(6), active},
             {agent_recovery_round, actor, Old, 1, Round},
             {agent_recovery_threshold, actor, 2},
             {agent_recovery_observer, actor, Other},
             {agent_failure_report, actor, Old, 1, Round, Other,
              {observation, 1, hash(21), Expiry}, suspected_unreachable},
             {agent_failure_report, actor, Old, 1, Round, untrusted,
              {observation, 1, hash(23), Expiry}, suspected_unreachable}],
    with_actor(Facts, Policy, fun(St, Observer) ->
        {succeed, Configured} = erlog_int:prove_goal(
          {',', {assertz, {agent_recovery_observer, actor, Observer}},
            {',', {assertz, {eligible_agent_host, actor, Observer}},
              {',', {assertz, {agent_host_rank, actor, Observer, 1}},
                    {assertz, {agent_candidate_key, actor, Old, 1, Observer, hash(7)}}}}}, St),
        {ok, SignedExpiry} = quod_proof_context:request_expiry(),
        Fun(Configured, Observer, Old, Other, Observer, Round, SignedExpiry)
    end).

recovery_fixture(Fun) ->
    recovery_fixture(Fun, <<"can_assign_agent_host(_, actor, _, _, _, _).\n">>).

recovery_fixture(Fun, Authority) ->
    Old = {agent_instance_ref, <<"node">>, hash(5), physical_node},
    Round = hash(10),
    Rules = iolist_to_binary([Authority, <<"can_prepare_agent_key(_, actor, _, _).\n"
              "can_report_agent_failure(_, actor, _, _).\n"
              "agent_recovery_candidate(_, I, H, E, R, _, 1) :- "
              "findall(O, agent_failure_support(I,H,E,R,O,_), Os), "
              "sort(Os, Unique), length(Unique, Count), Count >= 2.\n">>]),
    with_actor([{agent_host, actor, Old, 1, hash(6)},
                {agent_key, actor, hash(6), active},
                {agent_recovery_round, actor, Old, 1, Round},
                {agent_failure_report, actor, Old, 1, Round, other,
                 {observation, 1, hash(12), quod_time:now_ms() + 600000}, suspected_unreachable}], Rules,
      fun(St, Observer) ->
        {ok, Expiry} = quod_proof_context:request_expiry(),
        Fun(St, Observer, Old, Round, Expiry)
      end).

changes(#est{db = #db{ref = Overlay}}) ->
    quod_erlog_db_local_prove:get_local_changes(Overlay).

with_actor(Facts, Rules, Fun) ->
    #{principal := Principal, agent_reference := Sender,
      evidence := Evidence} = quod_ct:signed_goal_fixture(
        #{target => {<<"sender">>, hash(9)}, goal_text => <<"true.">>,
          deadline => quod_time:now_ms() + 60000}),
    {ok, Source} = file:read_file(filename:join(code:priv_dir(quod),
                                                "ontologies/agent_instance.pl")),
    Overlay = quod_ct:action_overlay(
                iolist_to_binary([Source, Rules]), [quod_agent_predicates], Facts),
    St = quod_predicates:set_context(Overlay,
           quod_predicates:proof_context(<<"receiver">>, 1, undefined,
             [{<<"receiver">>, hash(1)}, {<<"sender">>, hash(9)}])),
    _ = quod_proof_context:start(crypto:strong_rand_bytes(32), false,
               {<<"sender">>, hash(9)}, quod_time:mono_ms() + 5000,
               Principal, Evidence),
    try Fun(St, Sender)
    after quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end) end.
