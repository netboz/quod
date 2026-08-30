-module(quod_prolog_scope_target_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

%% B's first invocation is suspended while it asks C.  C re-enters B through
%% a second invocation, whose controller traffic must correlate to request 2;
%% once request 2 completes, B resumes request 1 and its later controller
%% traffic must recover request 1's correlation.  A single active-command slot
%% either rejects request 2 or loses request 1 and fails this test.
reentrant_scope_command_correlation_is_lifo_test() ->
    Request1 = {<<1:128>>, 7},
    Request2 = {<<2:128>>, 11},
    ?assertEqual(
       {ok, [Request1, Request2, Request1], []},
       quod_prolog:test_active_command_stack(
         [{push, Request1}, top,
          {push, Request2}, top,
          {pop, Request2}, top,
          {pop, Request1}])).

out_of_order_terminal_reply_is_rejected_test() ->
    Request1 = {<<3:128>>, 3},
    Request2 = {<<4:128>>, 4},
    ?assertEqual(
       error,
       quod_prolog:test_active_command_stack(
         [{push, Request1}, {push, Request2}, {pop, Request1}])).

pending_remote_open_reserves_shared_capacity_test() ->
    %% A return-link handshake has not spawned its worker yet, but it already
    %% owns the last capacity slot.  A co-hosted open must not pass this gate.
    ?assert(quod_prolog:test_scope_capacity_available(2, 1, 0)),
    ?assertNot(quod_prolog:test_scope_capacity_available(2, 1, 1)),
    ?assertNot(quod_prolog:test_scope_capacity_available(2, 0, 2)).

unknown_internal_error_is_not_put_on_the_wire_test() ->
    Ns = <<"quod:target">>,
    ?assertEqual(
       {ontology_busy, Ns},
       quod_prolog:test_public_scope_reason({ontology_busy, Ns}, Ns)),
    ?assertEqual(
       {not_allowed, Ns},
       quod_prolog:test_public_scope_reason(not_allowed, Ns)),
    ?assertEqual(
       {protocol_error, proof_engine},
       quod_prolog:test_public_scope_reason(
         {unexpected_internal_detail, make_ref()}, Ns)),
    ?assertEqual(
       {protocol_error, proof_engine},
       quod_prolog:test_public_scope_reason(
         {protocol_error, not_in_the_wire_catalog}, Ns)).

signed_scope_authentication_is_verified_and_bound_test() ->
    Network = <<91:256>>,
    Origin = {<<"quod:signed-origin">>, <<92:256>>},
    Fixture = quod_ct:signed_goal_fixture(
                #{network => Network, target => Origin,
                  deadline => quod_time:now_ms() + 60000}),
    ProofId = <<90:256>>,
    {Certificate, View} = identity_certificate(Fixture, ProofId),
    Authentication =
        {signed_goal, maps:get(request_bytes, Fixture),
         maps:get(signature, Fixture), Certificate},
    {ok, AuthenticationDigest} =
        quod_scope_wire:authentication_digest(Authentication),
    Principal = maps:get(principal, Fixture),
    OriginKey = <<93:256>>,
    quod_ct:with_network_identity(
      Network,
      fun() ->
          {ok, Authorization} =
              quod_prolog:test_scope_authentication_reason(
                Authentication, OriginKey, Origin, Principal,
                AuthenticationDigest, ProofId, {ok, View}),
          ?assertEqual(
             quod_client_goal:request_binding(Fixture),
             maps:get(request_binding, Authorization)),
          ?assertEqual(
             quod_client_goal:request_auth(Fixture),
             maps:get(request_auth, Authorization)),
          lists:foreach(
            fun({Auth, Identity, TestPrincipal, Digest}) ->
                ?assertEqual(
                   {error, {protocol_error, request_binding}},
                   quod_prolog:test_scope_authentication_reason(
                     Auth, OriginKey, Identity, TestPrincipal, Digest,
                     ProofId, {ok, View}))
            end,
            [{Authentication, Origin, {agent, <<94:256>>},
              AuthenticationDigest},
             {Authentication, {<<"quod:other">>, element(2, Origin)},
              Principal, AuthenticationDigest},
             {Authentication, Origin, Principal, <<95:256>>},
             {{signed_goal, <<(maps:get(request_bytes, Fixture))/binary, 0>>,
               maps:get(signature, Fixture), Certificate},
              Origin, Principal, AuthenticationDigest}])
      end).

signed_scope_waits_when_network_identity_is_temporarily_unavailable_test() ->
    Origin = {<<"quod:signed-origin">>, <<96:256>>},
    Fixture = quod_ct:signed_goal_fixture(
                #{target => Origin,
                  deadline => quod_time:now_ms() + 60000}),
    ProofId = <<95:256>>,
    {Certificate, _View} = identity_certificate(Fixture, ProofId),
    Authentication =
        {signed_goal, maps:get(request_bytes, Fixture),
         maps:get(signature, Fixture), Certificate},
    {ok, AuthenticationDigest} =
        quod_scope_wire:authentication_digest(Authentication),
    SavedDesired = application:get_env(quod, namespace_desired),
    application:set_env(quod, namespace_desired, #{content => #{}}),
    try
        ?assertMatch(
           {error, {network_identity_unavailable, _}},
           quod_prolog:test_scope_authentication_reason(
             Authentication, <<97:256>>, Origin,
             maps:get(principal, Fixture), AuthenticationDigest,
             ProofId, {error, unavailable}))
    after
        case SavedDesired of
            {ok, Desired} ->
                application:set_env(quod, namespace_desired, Desired);
            undefined ->
                application:unset_env(quod, namespace_desired)
        end
    end.

expired_signed_scope_is_refused_before_execution_test() ->
    Network = <<98:256>>,
    Origin = {<<"quod:expired-origin">>, <<99:256>>},
    Fixture = quod_ct:signed_goal_fixture(
                #{network => Network, target => Origin,
                  deadline => quod_time:now_ms() - 1}),
    ProofId = <<97:256>>,
    {Certificate, View} = identity_certificate(Fixture, ProofId),
    Authentication =
        {signed_goal, maps:get(request_bytes, Fixture),
         maps:get(signature, Fixture), Certificate},
    {ok, AuthenticationDigest} =
        quod_scope_wire:authentication_digest(Authentication),
    quod_ct:with_network_identity(
      Network,
      fun() ->
          ?assertEqual(
             {error, {scope_expired, <<"quod:test-target">>}},
             quod_prolog:test_scope_authentication_reason(
               Authentication, <<100:256>>, Origin,
               maps:get(principal, Fixture), AuthenticationDigest,
               ProofId, {ok, View}))
      end).

target_owns_scope_timeout_classification_test() ->
    Ns = <<"quod:target">>,
    ?assertEqual(
       {proof_limit_exceeded, Ns},
       quod_prolog:test_scope_timeout_reason(active, Ns)),
    ?assertEqual(
       {scope_expired, Ns},
       quod_prolog:test_scope_timeout_reason(idle, Ns)).

remote_worker_death_has_one_wire_safe_failure_class_test() ->
    Ns = <<"quod:target">>,
    ?assertEqual(
       {scope_expired, Ns},
       quod_prolog:test_scope_worker_failure(
         {scope_error, {scope_expired, Ns}}, Ns)),
    ?assertEqual(
       {proof_limit_exceeded, Ns},
       quod_prolog:test_scope_worker_failure(killed, Ns)),
    ?assertEqual(
       {protocol_error, proof_engine},
       quod_prolog:test_scope_worker_failure(unexpected_crash, Ns)),
    ?assertMatch(
       {ok, _},
       quod_scope_wire:encode_event(
         {scope_event, test_binding(Ns), 1, <<1:128>>, 1, 0, false,
          {scope_error, {protocol_error, proof_engine}}})).

target_deadline_reserves_terminal_event_delivery_time_test() ->
    ?assertEqual(
       60000 - ?QUOD_SCOPE_TIMEOUT_REPLY_GRACE_MS,
       quod_prolog:test_target_scope_lifetime_ms(60000, 60000)),
    ?assertEqual(
       30000 - ?QUOD_SCOPE_TIMEOUT_REPLY_GRACE_MS,
       quod_prolog:test_target_scope_lifetime_ms(60000, 30000)),
    ?assertEqual(
       ?QUOD_SCOPE_TIMEOUT_REPLY_GRACE_MS div 2,
       quod_prolog:test_target_scope_lifetime_ms(
         ?QUOD_SCOPE_TIMEOUT_REPLY_GRACE_MS, 60000)),
    ?assertEqual(
       250,
       quod_prolog:test_target_scope_lifetime_ms(500, 60000)).

cleanup_remains_valid_after_execution_budget_expires_test() ->
    Past = quod_time:mono_ms() - 1,
    ?assert(
       quod_prolog:test_scope_command_budget_valid(scope_close, 0, Past)),
    ?assertNot(
       quod_prolog:test_scope_command_budget_valid(
         {invoke_next, <<1:128>>, 1}, 0, Past)).

sealed_target_accepts_only_attestation_terminal_submit_and_close_test() ->
    ManifestBlob = <<"manifest">>,
    Submit = {submit_plan, <<"plan">>, <<"goal">>, <<"result">>, []},
    ?assertEqual(
       active,
       quod_prolog:test_scope_command_route(active, scope_seal)),
    ?assertEqual(
       sealed,
       quod_prolog:test_scope_command_route(
         sealed, {scope_attest, ManifestBlob})),
    ?assertEqual(
       sealed,
       quod_prolog:test_scope_command_route(sealed, certify_reads)),
    ?assertEqual(
       sealed,
       quod_prolog:test_scope_command_route(sealed, scope_close)),
    ?assertEqual(
       sealed,
       quod_prolog:test_scope_command_route(sealed, Submit)),
    ?assertEqual(
       error,
       quod_prolog:test_scope_command_route(active, Submit)),
    ?assertEqual(
       error,
       quod_prolog:test_scope_command_route(submitting, Submit)),
    ?assertEqual(
       error,
       quod_prolog:test_scope_command_route(submitted, Submit)),
    ?assertEqual(
       {submitted, error},
       quod_prolog:test_sealed_submit_transition()),
    ?assertEqual(
       sealed,
       quod_prolog:test_scope_command_route(submitted, scope_close)),
    lists:foreach(
      fun(Operation) ->
          ?assertEqual(
             error,
             quod_prolog:test_scope_command_route(sealed, Operation))
      end,
      [scope_seal,
       {invoke_open, <<1:128>>, {tx_selection, none, []}, [], <<>>},
       {invoke_next, <<1:128>>, 1},
       {invoke_cancel, <<1:128>>},
       {materialize, <<1:128>>, <<2:128>>, <<3:128>>, [<<4:128>>]},
       {batch_restore, [<<4:128>>]},
       {batch_release, [<<4:128>>]}]),
    ?assertEqual(
       error,
       quod_prolog:test_scope_command_route(
         opening_session, {scope_attest, ManifestBlob})),
    ?assertEqual(
       error,
       quod_prolog:test_scope_command_route(active, certify_reads)).

read_certificate_reply_and_capacity_use_the_existing_scope_seams_test() ->
    Ns = <<"quod:certificate-target">>,
    Certificate = read_certificate(Ns),
    {event, {reads_certified, Blob}} =
        quod_prolog:test_read_certificate_scope_reply(
          {ok, Certificate}, Ns),
    ?assertEqual(
       {ok, Certificate},
       quod_scope_wire:decode_payload(read_certificate, Blob)),
    ?assertEqual(
       {error, conflict_retry},
       quod_prolog:test_read_certificate_scope_reply(
         {error, conflict_retry}, Ns)),
    ?assertEqual(
       {error, {protocol_error, proof_engine}},
       quod_prolog:test_read_certificate_scope_reply(
         {error, unlisted_internal_reason}, Ns)),
    ?assertEqual(
       {error, {protocol_error, proof_engine}},
       quod_prolog:test_read_certificate_scope_reply(malformed, Ns)),
    ?assertEqual(
       ok,
       quod_prolog:test_certify_reads_pending_reason(
         ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE - 1, Ns)),
    ?assertEqual(
       {error, {proof_limit_exceeded, Ns}},
       quod_prolog:test_certify_reads_pending_reason(
         ?QUOD_MAX_ROUTER_PENDING_PER_SCOPE, Ns)).

idle_expiry_reuses_exact_last_command_correlation_test() ->
    OpenRequest = <<1:128>>,
    LaterRequest = <<2:128>>,
    ActiveRequest = <<3:128>>,
    ?assertEqual(
       {OpenRequest, 1},
       quod_prolog:test_remote_timeout_correlation(
         OpenRequest, 2, [])),
    ?assertEqual(
       {LaterRequest, 9},
       quod_prolog:test_remote_timeout_correlation(
         LaterRequest, 10, [])),
    ?assertEqual(
       {ActiveRequest, 12},
       quod_prolog:test_remote_timeout_correlation(
         LaterRequest, 10, [{ActiveRequest, 12}])).

top_level_deadline_and_crash_use_current_public_errors_test() ->
    Ns = <<"quod:origin">>,
    OutcomeRef = {transaction, Ns, <<7:256>>, <<8:256>>},
    ?assertEqual(
       {error, {proof_limit_exceeded, Ns}},
       quod_prolog:test_proof_down_reply(prove, killed, Ns)),
    ?assertEqual(
       {error, {protocol_error, proof_worker_crash}},
       quod_prolog:test_proof_down_reply(prove, unexpected_crash, Ns)),
    ?assertEqual(
       {error, {outcome_unknown, OutcomeRef}},
       quod_prolog:test_proof_down_reply(
         prove, unexpected_crash, Ns, OutcomeRef)).

public_proof_engine_death_is_checkpoint_sensitive_test() ->
    Ns = <<"quod:origin">>,
    CallRef1 = make_ref(),
    Engine1 = spawn(fun() -> receive stop -> ok end end),
    MRef1 = monitor(process, Engine1),
    Engine1 ! stop,
    ?assertEqual(
       {error, {ontology_unavailable, Ns}},
       quod_prolog:test_await_public_proof(
         Engine1, MRef1, CallRef1, Ns, none)),

    GroupRef = {group, Ns, <<1:256>>, <<2:256>>, <<3:256>>, <<4:256>>},
    CallRef2 = make_ref(),
    Engine2 = spawn(fun() -> receive stop -> ok end end),
    MRef2 = monitor(process, Engine2),
    self() ! {quod_proof_checkpoint, Engine2, CallRef2, GroupRef},
    Engine2 ! stop,
    ?assertEqual(
       {error, {outcome_unknown, GroupRef}},
       quod_prolog:test_await_public_proof(
         Engine2, MRef2, CallRef2, Ns, none)).

public_proof_normal_reply_wins_after_checkpoint_test() ->
    Ns = <<"quod:origin">>,
    CallRef = make_ref(),
    Engine = spawn(fun() -> receive stop -> ok end end),
    MRef = monitor(process, Engine),
    OutcomeRef = {transaction, Ns, <<5:256>>, <<6:256>>},
    Expected = {ok, [#{}], 7},
    self() ! {quod_proof_checkpoint, Engine, CallRef, OutcomeRef},
    self() ! {quod_proof_reply, Engine, CallRef, Expected},
    ?assertEqual(
       Expected,
       quod_prolog:test_await_public_proof(
         Engine, MRef, CallRef, Ns, none)),
    Engine ! stop,
    demonitor(MRef, [flush]).

test_binding(Ns) ->
    {ok, AuthenticationDigest} =
        quod_scope_wire:authentication_digest(node),
    {scope_binding, <<1:256>>, <<2:256>>, <<3:256>>, <<4:128>>,
     {<<"quod:origin">>, <<5:256>>}, {Ns, <<6:256>>}, read_write,
     {node, <<1:256>>}, AuthenticationDigest}.

read_certificate(Ns) ->
    Anchor = <<201:256>>,
    Target = {Ns, Anchor},
    ProofId = <<202:256>>,
    PlanDigest = <<203:256>>,
    CommitteeId = <<204:256>>,
    {Pubkey, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pubkey,
               key => quod_identity:key_term({Pubkey, Seed})},
    {ok, AnchorRef} = quod_dtx:certified_ref(
                        Ns, Anchor, 2, <<205:256>>, <<206:256>>,
                        term_to_binary(read_certificate, [deterministic])),
    {ok, SignedRow} = quod_read_certificate:sign(
                        Target, ProofId, PlanDigest, AnchorRef,
                        CommitteeId, Signer),
    {ok, Certificate} = quod_read_certificate:new(
                          Target, ProofId, PlanDigest, AnchorRef,
                          CommitteeId, [SignedRow]),
    Certificate.

identity_certificate(Fixture, ProofId) ->
    Evidence = maps:get(evidence, Fixture),
    NotAfter = maps:get(deadline, Fixture),
    CommitteeId = <<101:256>>,
    KeyPair = quod_identity:generate(),
    {Validator, Seed} = KeyPair,
    {ok, Statement} = quod_agent_identity:statement(
                        Evidence, ProofId, CommitteeId, NotAfter),
    {ok, SignatureRow} = quod_agent_identity:sign(
                           Statement,
                           #{pubkey => Validator,
                             key => quod_identity:key_term(
                                      {Validator, Seed})}),
    {ok, Certificate} = quod_agent_identity:certificate(
                          Statement, [SignatureRow], []),
    View = #{identity => maps:get(target, Fixture),
             committee => [Validator], committee_id => CommitteeId},
    {Certificate, View}.
