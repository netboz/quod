-module(quod_client_registration_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PEER, {127, 0, 0, 1}).

registration_rejects_an_unknown_session_test() ->
    ?assertEqual(
       {error, client_auth_unavailable},
       quod_client_registration:register(<<0:256>>, <<1:256>>, <<2:512>>, ?PEER)).

%% The open-registration budget guards durable ontology creation, so only a
%% request that reaches that step may spend from it. A session is free to
%% obtain, so charging on arrival would let one holder starve a node's
%% registrations without performing any.
%%
%% This node has no founded root, so the request is refused at the anchor lookup
%% rather than at the signature — either way it never founds a home, and the
%% budget must be untouched. The signature-checked path over a real root is
%% covered by `quod_ontology_tests:authenticated_registration_creates_its_home`.
failed_requests_do_not_spend_the_budget_test() ->
    Pid = start_auth(#{registration_limit => #{window_ms => 60000,
                                               max_total => 1, max_per_key => 1,
                                               max_keys => 4}}),
    try
        SessionId = login(quod_identity:generate()),
        ?assertEqual(
           {error, registration_unavailable},
           quod_client_registration:register(
             SessionId, <<16#55:256>>, <<0:512>>, ?PEER)),
        %% The single registration in the window is still available, which it
        %% would not be had the failed attempt been charged.
        ?assertEqual(ok, quod_client_auth:reserve_registration(?PEER))
    after stop_auth(Pid)
    end.

%% ======================================================================
%% harness
%% ======================================================================
login(KeyPair) ->
    {PublicKey, _} = KeyPair,
    ClientNonce = <<16#12:256>>,
    {ok, Challenge} =
        quod_client_auth:issue_challenge(PublicKey, ClientNonce, ?PEER),
    ChallengeId = maps:get(challenge_id, Challenge),
    {ok, Bytes} = quod_user:challenge_bytes(
                    <<16#10:256>>, <<16#11:256>>, ChallengeId, PublicKey,
                    ClientNonce, maps:get(server_nonce, Challenge),
                    maps:get(expires_ms, Challenge)),
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(KeyPair)),
    {ok, #{session_id := SessionId}} =
        quod_client_auth:complete_challenge(ChallengeId, Signature),
    SessionId.

start_auth(Options) ->
    {ok, Pid} = quod_client_auth:start_link(
                  maps:merge(#{network_id => <<16#10:256>>,
                               node_key => <<16#11:256>>, ttl_ms => 60000,
                               max_challenges => 4},
                             Options)),
    Pid.

stop_auth(Pid) ->
    unlink(Pid),
    MRef = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok
    after 5000 -> demonitor(MRef, [flush]), error(client_auth_stop_timeout)
    end.
