-module(quod_node_context_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

permitted_recovery_helper_cannot_borrow_node_privileges_test_() ->
    {timeout, 90, fun() -> quod_agent_hosting_tests:with_host(
      fun(#{namespace := Source, reference := {agent_instance_ref, Source, Anchor, _},
            node := Node = {agent_instance_ref, NodeNs, _, _},
            identity := Identity, directory := Directory}) ->
          %% The hosting fixture supplies an unrestricted testing grant. Use
          %% the actual node admission clauses for this security boundary.
          NodePolicy = policy_terms("node_execution.pl"),
          Admissions = [Clause || Clause <- NodePolicy, admission_clause(Clause)],
          commit(NodeNs, conjunction(
            [{abolish, {'/', can_invoke, 4}},
             {assertz, {can_invoke, {'_'}, {'_'}, [], NodeNs}},
             {assertz, {node_ontology, NodeNs}},
             {assertz, {instance_of, node, physical_node}}] ++
            [{assertz, Clause} || Clause <- Admissions] ++
            [{assertz, {can_execute_for, Source, Anchor, recovery_operation}}])),
          Target = <<"host-test-privileged">>, Relay = <<"host-test-relay">>,
          Privileged = start_policy_ontology(Target, Directory, Identity,
                         policy_terms("quod_root.pl") ++ [{root_administrator_agent, Node}]),
          try
              Intermediary = start_policy_ontology(Relay, Directory, Identity,
                [{can_invoke, {'_'}, {'_'}, {'_'}, {'_'}},
                 {':-', relay_privilege, {'::', Target, {set_effect_custody_capacity, unlimited}}}]),
              try
                  commit(Source, {assertz, {':-', recovery_operation, {recovery_helper, unit}}}),
                  replace_recovery_helper(Source, {record_ping, recovery_allowed}),
                  Request = {node_authorized_goal, Source, Anchor, recovery_operation},
                  ?assertMatch({ok, _, {normalized, {committed, _, _}}}, signed_node(Request)),
                  ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Source, {ping, recovery_allowed})),
                  %% The third target explicitly grants this exact principal
                  %% direct access, so a later refusal is caused by context.
                  ?assertMatch({ok, _, {normalized, {committed, _, _}}},
                               signed_node({'::', Target, {set_effect_custody_capacity, 17}})),
                  lists:foreach(fun(Implementation) ->
                      replace_recovery_helper(Source, Implementation),
                      ?assertMatch({ok, _, {normalized, {failed, _}}}, signed_node(Request)),
                      ?assertMatch({fail, _}, quod_prolog:prove_ro(NodeNs, borrowed_node_authority)),
                      ?assertMatch({ok, [#{'Capacity' := 17}], _},
                                   quod_prolog:prove_ro(Target, {effect_custody_capacity, {'Capacity'}}))
                  end, [{'::', NodeNs, {assertz, borrowed_node_authority}},
                        {'::', Target, {set_effect_custody_capacity, unlimited}},
                        {'::', Relay, relay_privilege}])
              after stop_policy_ontology(Intermediary) end
          after stop_policy_ontology(Privileged) end
      end) end}.

node_self_hosting_alternatives_do_not_lend_authority_test() ->
    Node = identity(<<"node:context">>, 1),
    Ref = reference(Node, physical_node),
    Helper = identity(<<"user:editable">>, 2),
    Intermediary = identity(<<"system:intermediary">>, 3),
    Name = <<"private:target">>,
    Anchor = <<4:256>>,
    Goals = [{assertz, {ontology_hosting_policy, Name, Anchor}},
             {host_ontology, Ref, Name, Anchor, private},
             {request_ontology_hosting, Ref, Ref, Name, Anchor, private}],
    with_policy("node_execution.pl",
                [{node_ontology, element(1, Node)},
                 {instance_of, node, physical_node},
                 %% Even an additional explicit self hosting grant cannot
                 %% bypass context through the alternative hosting entry.
                 {can_host_ontology, Ref, Ref, Name, Anchor, private}],
      fun(Est) ->
          lists:foreach(fun(Goal) ->
              admission(allowed, Node, Node, Ref, [Node], Goal, Est),
              admission(denied, Node, Node, Ref, [Helper, Node], Goal, Est),
              admission(denied, Node, Node, Ref,
                        [Intermediary, Helper, Node], Goal, Est)
          end, Goals)
      end).

node_keeps_independent_hosting_requests_test() ->
    Node = identity(<<"node:hosting">>, 5),
    NodeRef = reference(Node, physical_node),
    User = identity(<<"human:caller">>, 6),
    UserRef = reference(User, human),
    Signup = identity(<<"quod:signup">>, 7),
    Name = <<"human:caller/lobby">>,
    Anchor = <<8:256>>,
    with_policy("node_execution.pl",
                [{node_ontology, element(1, Node)},
                 {instance_of, node, physical_node},
                 {can_host_ontology, UserRef, NodeRef, Name, Anchor, discoverable}],
      fun(Est) ->
          Host = {host_ontology, NodeRef, Name, Anchor, discoverable},
          Request = {request_ontology_hosting,
                     UserRef, NodeRef, Name, Anchor, discoverable},
          admission(allowed, Node, User, UserRef, [Signup, User], Host, Est),
          admission(allowed, Node, User, UserRef, [Signup, User], Request, Est),
          admission(denied, Node, User, UserRef, [Signup, User],
                    {request_ontology_hosting,
                     NodeRef, NodeRef, Name, Anchor, discoverable}, Est),
          admission(denied, Node, User, UserRef, [User],
                    {assertz, {hosts_ontology, NodeRef, Name, Anchor, discoverable}}, Est)
      end).

root_administrator_and_public_creation_require_direct_context_test() ->
    Root = identity(<<"quod:root">>, 9),
    Node = identity(<<"node:administrator">>, 10),
    Ref = reference(Node, physical_node),
    Helper = identity(<<"user:recovery">>, 11),
    Intermediary = identity(<<"system:helper">>, 12),
    with_policy("quod_root.pl", [{root_administrator_agent, Ref},
                                  {ontology_creator_agent, Ref}],
      fun(Est) ->
          Goals = [{set_effect_custody_capacity, unlimited},
                   {create_ontology, <<"private:new">>, [], {'Anchor'}}],
          lists:foreach(fun(Goal) ->
              admission(allowed, Root, Node, Ref, [Node], Goal, Est),
              admission(denied, Root, Node, Ref, [Helper, Node], Goal, Est),
              admission(denied, Root, Node, Ref,
                        [Intermediary, Helper, Node], Goal, Est)
          end, Goals),
          %% An exact principal grant must not match a replacement history
          %% merely because the policy-visible namespace path is unchanged.
          OtherNode = identity(element(1, Node), 13),
          admission(denied, Root, OtherNode, reference(OtherNode, physical_node),
                    [OtherNode], {set_effect_custody_capacity, unlimited}, Est),
          %% Public catalogue reads remain available through foreign code.
          admission(allowed, Root, Node, Ref, [Helper, Node],
                    {system_ontology, {'Name'}, {'Anchor'}}, Est)
      end).

root_creator_grant_cannot_bypass_context_through_public_entry_test() ->
    Root = identity(<<"quod:root">>, 14),
    Node = identity(<<"node:creator">>, 15),
    Ref = reference(Node, physical_node),
    Helper = identity(<<"user:implementation">>, 16),
    Goal = {create_ontology, <<"private:created">>, [], {'Anchor'}},
    with_policy("quod_root.pl", [{ontology_creator_agent, Ref}],
      fun(Est) ->
          %% The action prerequisite alone accepts this exact principal. The
          %% public invocation boundary must still reject the borrowed path.
          ?assertMatch({succeed, _}, erlog_int:prove_goal(
                         {can_create_ontology, Ref, <<"private:created">>, []}, Est)),
          admission(allowed, Root, Node, Ref, [Node], Goal, Est),
          admission(denied, Root, Node, Ref, [Helper, Node], Goal, Est),
          admission(denied, Root, Node, Ref, [Node],
                    {set_effect_custody_capacity, unlimited}, Est)
      end).

root_keeps_delegated_creation_entry_for_other_callers_test() ->
    Root = identity(<<"quod:root">>, 17),
    User = identity(<<"human:new">>, 18),
    Ref = reference(User, human),
    Signup = identity(<<"quod:signup">>, 19),
    with_policy("quod_root.pl", [], fun(Est) ->
        %% Entry is public; the ordinary action must still prove its delegated
        %% creation policy. This does not assert that arbitrary creation works.
        admission(allowed, Root, User, Ref, [Signup, User],
                  {create_ontology, <<"human:new/lobby">>, [], {'Anchor'}}, Est),
        admission(denied, Root, User, Ref, [User],
                  {set_effect_custody_capacity, unlimited}, Est)
    end).

physical_node_root_privileges_stay_in_the_root_context_test() ->
    Root = identity(<<"quod:root">>, 20),
    Foreign = identity(<<"user:foreign">>, 21),
    Key = <<22:256>>,
    Principal = {node, Key},
    with_policy("quod_root.pl", [{peer_admitted, Key, peer, address, Key}],
      fun(Est) ->
          lists:foreach(fun(Goal) ->
              admission(allowed, Root, Root, Principal, [], Goal, Est),
              admission(allowed, Root, Root, Principal, [Root], Goal, Est),
              admission(denied, Root, Foreign, Principal, [Foreign], Goal, Est),
              admission(denied, Root, Root, Principal, [Foreign, Root], Goal, Est)
          end, [{set_effect_custody_capacity, unlimited},
                {create_ontology, <<"private:physical">>, [], {'Anchor'}}])
      end).

%% Use the production admission reproof and the shipped policies. FullChain
%% is the anchored engine transcript, not a hand-built can_invoke/4 call.
%% Checking both verdicts also distinguishes a real refusal from proof errors.
admission(Expected, Target, Origin, Ref, Callers, Goal, Est) ->
    Principal = principal(Ref),
    {ok, GoalBlob} = quod_wire_term:encode_canonical(Goal),
    Transcript = fun(Verdict) ->
        [{<<1:128>>, [Target | Callers], GoalBlob,
          Verdict, 0, <<0:256>>, complete}]
    end,
    ?assertEqual(ok, quod_ask:validate_authorization_transcript(
                       Target, Origin, Principal, 1, Transcript(Expected), Est)),
    Opposite = case Expected of allowed -> denied; denied -> allowed end,
    ?assertEqual({error, invalid_authorization_transcript},
                 quod_ask:validate_authorization_transcript(
                   Target, Origin, Principal, 1, Transcript(Opposite), Est)).

principal({agent_instance_ref, _, _, _} = Ref) ->
    {ok, Blob} = quod_wire_term:encode_canonical(Ref),
    {ok, Principal} = quod_agent_ref:principal(Blob),
    Principal;
principal(Principal) -> Principal.

identity(Namespace, Number) -> {Namespace, <<Number:256>>}.

reference({Namespace, Anchor}, Instance) ->
    {agent_instance_ref, Namespace, Anchor, Instance}.

with_policy(File, Facts, Fun) ->
    Est = quod_ct:commit_kb(quod_ct:assert_facts(
                            policy_terms(File) ++ Facts, quod_committed_projection:new_est())),
    try Fun(Est)
    after
        #est{db = #db{ref = Database}} = Est,
        quod_erlog_db_mvcc:delete(Database)
    end.

policy_terms(File) ->
    quod_committed_projection:read_terms(
      filename:join([code:priv_dir(quod), "ontologies", File])).

admission_clause({':-', Head, _}) -> admission_clause(Head);
admission_clause({can_invoke, _, _, _, _}) -> true;
admission_clause(_) -> false.

conjunction([Goal]) -> Goal;
conjunction([Goal | Rest]) -> {',', Goal, conjunction(Rest)}.

commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).

replace_recovery_helper(Ns, Goal) ->
    commit(Ns, {',', {abolish, {'/', recovery_helper, 1}},
                     {assertz, {':-', {recovery_helper, unit}, Goal}}}).

signed_node(Goal) ->
    {ok, Bytes, Signature} = quod_node_actor:signed_goal(
        execute, Goal, crypto:strong_rand_bytes(32), quod_time:now_ms() + 30000),
    quod_client_goal_ingress:submit(Bytes, Signature).

start_policy_ontology(Ns, Directory, Identity, Terms) ->
    true = quod_reg:subscribe({runtime, Ns}),
    try
        {ok, Sup} = quod_ns:start_link(Ns,
          #{node_id => maps:get(pubkey, Identity), identity => Identity, mode => create,
            data_dir => filename:join(Directory, binary_to_list(Ns)),
            external_predicate_modules => [], genesis_diff => quod_prolog:terms_to_diff(Terms)}),
        unlink(Sup),
        receive {replay_ready, _, _} -> ok
        after 10000 -> error({policy_target_not_ready, Ns}) end,
        {ok, #{content := Content} = Desired} = application:get_env(quod, namespace_desired),
        application:set_env(quod, namespace_desired,
          Desired#{content => Content#{Ns => #{genesis_hash => quod_simplex:genesis_hash(Ns)}}}),
        Sup
    after quod_reg:unsubscribe({runtime, Ns}) end.

stop_policy_ontology(Sup) ->
    Monitor = monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Monitor, process, Sup, _} -> ok
    after 5000 -> error(policy_target_did_not_stop) end.
