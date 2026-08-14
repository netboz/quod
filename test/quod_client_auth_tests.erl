-module(quod_client_auth_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NETWORK, <<16#10:256>>).
-define(NODE, <<16#11:256>>).
-define(PEER, {127, 0, 0, 1}).

challenge_is_single_use_test() ->
    with_auth(
      fun() ->
         {PublicKey, _} = KeyPair = quod_identity:generate(),
         ClientNonce = <<16#12:256>>,
         {ChallengeId, Signature} = signed_challenge(KeyPair, ClientNonce),
         {ok, #{public_key := PublicKey, session_id := SessionId,
                principal := {user, PublicKey}}} =
             quod_client_auth:complete_challenge(ChallengeId, Signature),
         ?assertMatch({ok, #{session_id := SessionId}},
                      quod_client_auth:session(SessionId)),
         ?assertEqual(
            {error, invalid_challenge},
            quod_client_auth:complete_challenge(ChallengeId, Signature))
      end).

session_is_node_local_and_bounded_test() ->
    with_auth(
      fun() ->
         {PublicKey, _} = KeyPair = quod_identity:generate(),
         {ChallengeId, Signature} = signed_challenge(KeyPair, <<16#42:256>>),
         {ok, #{session_id := SessionId}} =
             quod_client_auth:complete_challenge(ChallengeId, Signature),
         ?assertEqual({error, invalid_session},
                      quod_client_auth:session(<<0:256>>)),
         ?assertMatch({ok, #{public_key := PublicKey}},
                      quod_client_auth:session(SessionId))
      end).

invalid_signature_consumes_challenge_test() ->
    with_auth(
      fun() ->
         {PublicKey, _} = quod_identity:generate(),
         {ok, Challenge} =
             quod_client_auth:issue_challenge(PublicKey, <<16#23:256>>, ?PEER),
         ChallengeId = maps:get(challenge_id, Challenge),
         ?assertEqual(
            {error, invalid_challenge_signature},
            quod_client_auth:complete_challenge(ChallengeId, <<0:512>>)),
         ?assertEqual(
            {error, invalid_challenge},
            quod_client_auth:complete_challenge(ChallengeId, <<0:512>>))
      end).

%% A challenge is single-use, so a node at its session ceiling must refuse the
%% login without spending one — otherwise every retry costs a round trip.
full_sessions_do_not_consume_a_challenge_test() ->
    with_auth(
      #{max_sessions => 1},
      fun() ->
         {ChallengeId, Signature} =
             signed_challenge(quod_identity:generate(), <<16#31:256>>),
         {Other, OtherSignature} =
             signed_challenge(quod_identity:generate(), <<16#32:256>>),
         {ok, _} = quod_client_auth:complete_challenge(Other, OtherSignature),
         ?assertEqual({error, client_session_busy},
                      quod_client_auth:complete_challenge(ChallengeId, Signature)),
         %% Still there: the refusal cost nothing.
         ?assertEqual({error, client_session_busy},
                      quod_client_auth:complete_challenge(ChallengeId, Signature))
      end).

%% Issuing is unauthenticated, so one address must not be able to hold every
%% challenge slot and lock the node's logins.
challenge_budget_is_bounded_per_peer_test() ->
    with_auth(
      #{challenge_limit => #{window_ms => 60000, max_total => 3,
                             max_per_key => 2, max_keys => 2}},
      fun() ->
         {PublicKey, _} = quod_identity:generate(),
         Issue = fun(Peer) ->
                     quod_client_auth:issue_challenge(
                       PublicKey, <<16#23:256>>, Peer)
                 end,
         ?assertMatch({ok, _}, Issue(?PEER)),
         ?assertMatch({ok, _}, Issue(?PEER)),
         ?assertEqual({error, client_auth_rate_limited}, Issue(?PEER)),
         ?assertMatch({ok, _}, Issue({127, 0, 0, 2})),
         ?assertEqual({error, client_auth_busy}, Issue({127, 0, 0, 3}))
      end).

%% A full node-wide challenge table is not a failed login by this peer. It must
%% refuse without consuming the peer's small rate budget, or another caller can
%% turn a temporary capacity burst into a minute-long per-user lockout.
full_challenge_table_does_not_charge_the_peer_test() ->
    with_auth(
      #{max_challenges => 1,
        challenge_limit => #{window_ms => 60000, max_total => 8,
                             max_per_key => 1, max_keys => 2}},
      fun() ->
         {PublicKey, _} = quod_identity:generate(),
         {ok, First} = quod_client_auth:issue_challenge(
                         PublicKey, <<16#41:256>>, {127, 0, 0, 2}),
         ?assertEqual(
            {error, client_auth_busy},
            quod_client_auth:issue_challenge(PublicKey, <<16#42:256>>, ?PEER)),
         %% Consume the first challenge, freeing the table. The same peer has
         %% one real issuance left because the full-table refusal charged none.
         ?assertEqual(
            {error, invalid_challenge_signature},
            quod_client_auth:complete_challenge(
              maps:get(challenge_id, First), <<0:512>>)),
         ?assertMatch(
            {ok, _},
            quod_client_auth:issue_challenge(PublicKey, <<16#43:256>>, ?PEER))
      end).

registration_budget_is_bounded_per_peer_test() ->
    with_auth(
      #{registration_limit => #{window_ms => 60000, max_total => 3,
                                max_per_key => 2, max_keys => 2}},
      fun() ->
         ?assertEqual(ok, quod_client_auth:reserve_registration(?PEER)),
         ?assertEqual(ok, quod_client_auth:reserve_registration(?PEER)),
         ?assertEqual(
            {error, client_registration_rate_limited},
            quod_client_auth:reserve_registration(?PEER)),
         ?assertEqual(ok, quod_client_auth:reserve_registration({127, 0, 0, 2})),
         ?assertEqual(
            {error, client_registration_busy},
            quod_client_auth:reserve_registration({127, 0, 0, 3}))
      end).

signed_goal_admission_is_bounded_by_user_and_peer_test() ->
    Limit = #{window_ms => 60000, max_total => 8,
              max_per_key => 1, max_keys => 8},
    with_auth(
      #{goal_user_limit => Limit,
        goal_peer_limit => Limit#{max_per_key => 2}},
      fun() ->
         KeyPair = quod_identity:generate(),
         {ok, #{session_id := SessionId}} = open_session(KeyPair, <<51:256>>),
         ?assertMatch({ok, _}, quod_client_auth:admit_goal(SessionId, ?PEER)),
         ?assertEqual(
            {error, client_goal_rate_limited},
            quod_client_auth:admit_goal(SessionId, {127, 0, 0, 2})),
         ?assertEqual(
            {error, invalid_session},
            quod_client_auth:admit_goal(<<0:256>>, ?PEER))
      end).

paired_goal_budgets_commit_only_when_both_admit_test() ->
    Limit = #{window_ms => 60000, max_total => 8,
              max_per_key => 1, max_keys => 8},
    with_auth(
      #{goal_user_limit => Limit,
        goal_peer_limit => Limit},
      fun() ->
         {ok, #{session_id := SessionA}} =
             open_session(quod_identity:generate(), <<52:256>>),
         {ok, #{session_id := SessionB}} =
             open_session(quod_identity:generate(), <<53:256>>),
         ?assertMatch({ok, _}, quod_client_auth:admit_goal(SessionA, ?PEER)),
         %% B's user budget provisionally admits, but the shared peer budget
         %% refuses. That failed pair must not spend B's user allowance.
         ?assertEqual(
            {error, client_goal_rate_limited},
            quod_client_auth:admit_goal(SessionB, ?PEER)),
         ?assertMatch(
            {ok, _},
            quod_client_auth:admit_goal(SessionB, {127, 0, 0, 2}))
      end).

paired_symbol_budgets_commit_only_when_both_admit_test() ->
    Limit = #{window_ms => 60000, max_total => 8,
              max_per_key => 1, max_keys => 8},
    {UserA, _} = quod_identity:generate(),
    {UserB, _} = quod_identity:generate(),
    First = unique_symbol(<<"paired_symbol_functor_">>),
    Second = unique_symbol(<<"paired_symbol_functor_">>),
    with_auth(
      #{max_materialized_atoms => 1024,
        symbol_user_limit => Limit,
        symbol_peer_limit => Limit},
      fun() ->
         ?assertMatch(
            {ok, _},
            quod_client_auth:materialize_goal(
              UserA, ?PEER, {{'$quod_symbol', First}, ok})),
         ?assertEqual(
            {error, client_goal_rate_limited},
            quod_client_auth:materialize_goal(
              UserB, ?PEER, {{'$quod_symbol', Second}, ok})),
         ?assertError(badarg, binary_to_existing_atom(Second, utf8)),
         ?assertMatch(
            {ok, _},
            quod_client_auth:materialize_goal(
              UserB, {127, 0, 0, 2},
              {{'$quod_symbol', Second}, ok}))
      end).

signed_goal_materialization_leaves_data_opaque_test() ->
    {PublicKey, _} = quod_identity:generate(),
    Functor = unique_symbol(<<"signed_functor_">>),
    Data = unique_symbol(<<"signed_data_">>),
    Baseline = erlang:system_info(atom_count),
    with_auth(
      #{atom_baseline => Baseline,
        max_materialized_atoms => 1024,
        symbol_user_limit => #{window_ms => 60000, max_total => 8,
                               max_per_key => 8, max_keys => 8},
        symbol_peer_limit => #{window_ms => 60000, max_total => 8,
                               max_per_key => 8, max_keys => 8}},
      fun() ->
         Goal = {{'$quod_symbol', Functor}, {'$quod_symbol', Data}},
         ?assertError(badarg, binary_to_existing_atom(Functor, utf8)),
         ?assertError(badarg, binary_to_existing_atom(Data, utf8)),
         {ok, Materialized} =
             quod_client_auth:materialize_goal(PublicKey, ?PEER, Goal),
         ?assertEqual({binary_to_existing_atom(Functor, utf8),
                       {'$quod_symbol', Data}}, Materialized),
         %% Ordinary data is not allocated merely because it appeared in a
         %% signed request.
         ?assertError(badarg, binary_to_existing_atom(Data, utf8))
      end).

materialized_atom_ceiling_survives_auth_owner_restart_test() ->
    Baseline = erlang:system_info(atom_count),
    Options = #{atom_baseline => Baseline,
                max_materialized_atoms => 1024},
    Pid1 = start_auth(Options),
    {PublicKey, _} = quod_identity:generate(),
    First = unique_symbol(<<"restart_bound_functor_">>),
    try
        ?assertMatch(
           {ok, _},
           quod_client_auth:materialize_goal(
             PublicKey, ?PEER, {{'$quod_symbol', First}, ok}))
    after
        stop_auth(Pid1)
    end,
    Used = erlang:system_info(atom_count) - Baseline,
    ?assert(Used >= 1),
    Pid2 = start_auth(
             Options#{max_materialized_atoms => Used}),
    Second = unique_symbol(<<"restart_bound_functor_">>),
    try
        ?assertEqual(
           {error, client_symbol_budget_exhausted},
           quod_client_auth:materialize_goal(
             PublicKey, ?PEER, {{'$quod_symbol', Second}, ok}))
    after
        stop_auth(Pid2)
    end.

malformed_requests_are_not_authentication_failures_test() ->
    with_auth(
      fun() ->
         ?assertEqual({error, invalid_public_key},
                      quod_client_auth:issue_challenge(<<0:8>>, <<16#23:256>>, ?PEER)),
         {PublicKey, _} = quod_identity:generate(),
         ?assertEqual({error, invalid_client_nonce},
                      quod_client_auth:issue_challenge(PublicKey, <<0:8>>, ?PEER))
      end).

%% ======================================================================
%% harness
%% ======================================================================

signed_challenge(KeyPair, ClientNonce) ->
    {PublicKey, _} = KeyPair,
    {ok, Challenge} =
        quod_client_auth:issue_challenge(PublicKey, ClientNonce, ?PEER),
    ChallengeId = maps:get(challenge_id, Challenge),
    {ok, Bytes} = quod_user:challenge_bytes(
                    ?NETWORK, ?NODE, ChallengeId, PublicKey, ClientNonce,
                    maps:get(server_nonce, Challenge),
                    maps:get(expires_ms, Challenge)),
    {ChallengeId, quod_identity:sign(Bytes, quod_identity:key_term(KeyPair))}.

open_session(KeyPair, ClientNonce) ->
    {ChallengeId, Signature} = signed_challenge(KeyPair, ClientNonce),
    quod_client_auth:complete_challenge(ChallengeId, Signature).

unique_symbol(Prefix) ->
    <<Prefix/binary,
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

with_auth(Fun) -> with_auth(#{}, Fun).

with_auth(Options, Fun) ->
    Pid = start_auth(Options),
    try Fun()
    after stop_auth(Pid)
    end.

start_auth(Options) ->
    {ok, Pid} = quod_client_auth:start_link(
                  maps:merge(#{network_id => ?NETWORK, node_key => ?NODE,
                               ttl_ms => 60000, max_challenges => 4},
                             Options)),
    Pid.

%% Synchronous: the registered name is released as the process dies, and the
%% next test registers it again immediately. Returning before that completes
%% would make consecutive tests race for the name.
stop_auth(Pid) ->
    unlink(Pid),
    MRef = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok
    after 5000 -> demonitor(MRef, [flush]), error(client_auth_stop_timeout)
    end.
