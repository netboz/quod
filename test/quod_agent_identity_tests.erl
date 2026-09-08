-module(quod_agent_identity_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NETWORK, <<16#a1:256>>).
-define(ANCHOR, <<16#a2:256>>).
-define(PROOF_ID, <<16#a3:256>>).
-define(COMMITTEE_ID, <<16#a4:256>>).
-define(NS, <<"quod:agent-identity">>).

quorum_certificate_verifies_distinct_current_members_test() ->
    F = fixture(4),
    Statement = maps:get(statement, F),
    Signatures = sign_with(Statement, lists:sublist(maps:get(keys, F), 3)),
    {ok, Certificate} = quod_agent_identity:certificate(
                          Statement, Signatures, []),
    ?assertEqual(
       ok,
       quod_agent_identity:verify(
         Certificate, maps:get(evidence, F), ?PROOF_ID,
         maps:get(view, F), maps:get(now, F))).

duplicate_outsider_and_subquorum_signatures_do_not_authorize_test() ->
    F = fixture(4),
    Statement = maps:get(statement, F),
    [A, B | _] = maps:get(keys, F),
    [ASig] = sign_with(Statement, [A]),
    [BSig] = sign_with(Statement, [B]),
    Outsider = quod_identity:generate(),
    [OutsiderSig] = sign_with(Statement, [Outsider]),
    Rows = [ASig, ASig, BSig, OutsiderSig],
    {ok, Certificate} = quod_agent_identity:certificate(
                          Statement, Rows, []),
    ?assertEqual(
       {error, invalid_request},
       quod_agent_identity:verify(
         Certificate, maps:get(evidence, F), ?PROOF_ID,
         maps:get(view, F), maps:get(now, F))).

certificate_is_bound_to_proof_request_committee_and_expiry_test() ->
    F = fixture(1),
    Statement = maps:get(statement, F),
    Signatures = sign_with(Statement, maps:get(keys, F)),
    {ok, Certificate} = quod_agent_identity:certificate(
                          Statement, Signatures, []),
    View = maps:get(view, F),
    Evidence = maps:get(evidence, F),
    Now = maps:get(now, F),
    ?assertEqual(
       {error, invalid_request},
       quod_agent_identity:verify(
         Certificate, Evidence, <<16#ff:256>>, View, Now)),
    ?assertEqual(
       {error, invalid_request},
       quod_agent_identity:verify(
         Certificate, Evidence, ?PROOF_ID,
         View#{committee_id => <<16#fe:256>>}, Now)),
    ?assertEqual(
       {error, retry},
       quod_agent_identity:verify(
         Certificate, Evidence, ?PROOF_ID, View,
         quod_agent_identity:not_after_ms(Certificate) + 1)).

fully_replaced_committee_cannot_authorize_fresh_request_test() ->
    F = fixture(4),
    OldView = maps:get(view, F),
    OldKeys = maps:get(keys, F),
    OldCommitteeId = maps:get(committee_id, OldView),
    NewKeys = [quod_identity:generate() || _ <- lists:seq(1, 4)],
    NewCommittee = lists:sort([Key || {Key, _Seed} <- NewKeys]),
    NewCommitteeId = <<16#c1:256>>,
    %% Unit verifier boundary: the caller supplies the certified current view.
    %% These maps model complete replacement, not a live history transition.
    CurrentView = OldView#{committee => NewCommittee,
                          committee_id => NewCommitteeId},
    ?assertEqual([], ordsets:intersection(maps:get(committee, OldView),
                                         NewCommittee)),

    %% After replacement, retained old keys sign a new request and ProofId.
    %% Its future expiry rules out rejecting a mere expired-certificate replay.
    Now = maps:get(not_after, F) + 1,
    NotAfter = Now + 5000,
    FreshProofId = crypto:strong_rand_bytes(32),
    AgentKeyPair = quod_identity:generate(),
    {AgentKey, _} = AgentKeyPair,
    OldEvidence = maps:get(evidence, F),
    OldRequest = maps:get(request, OldEvidence),
    FreshRequest = OldRequest#{signing_public_key => AgentKey,
                              operation_id => <<16#c3:256>>,
                              not_after_ms => NotAfter},
    {ok, RequestBytes} = quod_client_goal:encode(FreshRequest),
    RequestSignature = quod_identity:sign(
                         RequestBytes, quod_identity:key_term(AgentKeyPair)),
    {ok, Evidence} = quod_client_goal:verify(RequestBytes, RequestSignature),
    ?assertNotEqual(maps:get(request_digest, OldEvidence),
                    maps:get(request_digest, Evidence)),
    ?assertNotEqual(?PROOF_ID, FreshProofId),
    {ok, OldStatement} = quod_agent_identity:statement(
                           Evidence, FreshProofId, OldCommitteeId, NotAfter),
    {ok, RetiredCertificate} = quod_agent_identity:certificate(
                                OldStatement, sign_with(OldStatement, OldKeys), []),
    ?assertEqual(OldCommitteeId,
                 quod_agent_identity:committee_id(RetiredCertificate)),
    ?assert(quod_agent_identity:not_after_ms(RetiredCertificate) > Now),
    %% Real signatures form an unexpired quorum under the historic view.
    ?assertEqual(
       ok,
       quod_agent_identity:verify(
         RetiredCertificate, Evidence, FreshProofId, OldView, Now)),
    ?assertEqual(
       {error, invalid_request},
       quod_agent_identity:verify(
         RetiredCertificate, Evidence, FreshProofId, CurrentView, Now)),

    {ok, CurrentStatement} = quod_agent_identity:statement(
                               Evidence, FreshProofId, NewCommitteeId, NotAfter),
    {ok, CurrentCertificate} = quod_agent_identity:certificate(
                                CurrentStatement,
                                sign_with(CurrentStatement, NewKeys), []),
    ?assertEqual(
       ok,
       quod_agent_identity:verify(
         CurrentCertificate, Evidence, FreshProofId, CurrentView, Now)),
    %% Retired keys cannot recover authority by signing the current ID either.
    {ok, RelabelledCertificate} = quod_agent_identity:certificate(
                                   CurrentStatement,
                                   sign_with(CurrentStatement, OldKeys), []),
    ?assertEqual(
       {error, invalid_request},
       quod_agent_identity:verify(
         RelabelledCertificate, Evidence, FreshProofId, CurrentView, Now)).

request_and_response_wire_are_closed_and_correlated_test() ->
    F = fixture(1),
    Evidence = maps:get(evidence, F),
    NotAfter = maps:get(not_after, F),
    RequestId = <<16#b1:128>>,
    Request = {agent_identity_request, RequestId, ?PROOF_ID,
               maps:get(request_bytes, Evidence),
               maps:get(signature, Evidence), NotAfter},
    {ok, RequestBytes} = quod_agent_identity:encode_request(Request),
    ?assertEqual({ok, Request},
                 quod_agent_identity:decode_request(RequestBytes)),
    [{Signer, Signature}] = sign_with(
                              maps:get(statement, F), maps:get(keys, F)),
    Response = {agent_identity_response, RequestId, Signer,
                ?COMMITTEE_ID, NotAfter, Signature},
    {ok, ResponseBytes} = quod_agent_identity:encode_response(Response),
    ?assertEqual({ok, Response},
                 quod_agent_identity:decode_response(ResponseBytes)),
    Refusal = {agent_identity_refusal, RequestId},
    {ok, RefusalBytes} = quod_agent_identity:encode_response(Refusal),
    ?assertEqual({ok, Refusal},
                 quod_agent_identity:decode_response(RefusalBytes)),
    ?assertEqual(
       {error, invalid_request},
       quod_agent_identity:decode_request(ResponseBytes)),
    ?assertEqual(
       {error, invalid_request},
       quod_agent_identity:decode_request(RefusalBytes)),
    OldWire = term_to_binary(
                {<<"quod.agent.identity.wire", 0>>, 1,
                 response, Refusal}, [deterministic]),
    ?assertEqual(
       {error, invalid_request},
       quod_agent_identity:decode_response(OldWire)).

fixture(N) ->
    Now = quod_time:now_ms(),
    NotAfter = Now + 5000,
    AgentKeyPair = quod_identity:generate(),
    {AgentKey, _} = AgentKeyPair,
    Request = #{network_identity => ?NETWORK,
                signing_public_key => AgentKey,
                operation_id => <<16#a5:256>>,
                agent_namespace => ?NS,
                agent_genesis_anchor => ?ANCHOR,
                agent_instance_text => <<"human_user(alice).">>,
                mode => execute,
                parser_version => 2,
                not_after_ms => NotAfter,
                goal_text => <<"assertz(done).">>},
    {ok, RequestBytes} = quod_client_goal:encode(Request),
    RequestSignature = quod_identity:sign(
                         RequestBytes, quod_identity:key_term(AgentKeyPair)),
    {ok, Evidence} = quod_client_goal:verify(RequestBytes, RequestSignature),
    Keys = [quod_identity:generate() || _ <- lists:seq(1, N)],
    Committee = lists:sort([Key || {Key, _Seed} <- Keys]),
    {ok, Statement} = quod_agent_identity:statement(
                        Evidence, ?PROOF_ID, ?COMMITTEE_ID, NotAfter),
    #{now => Now, not_after => NotAfter,
      evidence => Evidence, statement => Statement, keys => Keys,
      view => #{identity => {?NS, ?ANCHOR}, committee => Committee,
                committee_id => ?COMMITTEE_ID}}.

sign_with(Statement, Keys) ->
    lists:sort(
      [begin
           Signer = #{pubkey => PublicKey,
                      key => quod_identity:key_term(KeyPair)},
           {ok, Row} = quod_agent_identity:sign(Statement, Signer),
           Row
       end || KeyPair = {PublicKey, _Seed} <- Keys]).
