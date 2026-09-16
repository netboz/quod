-module(quod_dtx_deadline_tests).
-include_lib("eunit/include/eunit.hrl").

manifest_requires_an_explicit_bounded_deadline_test() ->
    Input = manifest_input(),
    ?assertEqual({error, invalid_manifest},
                 quod_dtx:new_manifest(maps:remove(vote_deadline_ms, Input))),
    [?assertEqual({error, invalid_manifest},
                  quod_dtx:new_manifest(Input#{vote_deadline_ms := Bad}))
     || Bad <- [0, -1, 1 bsl 64, infinity, <<100>>]],
    {ok, Manifest} = quod_dtx:new_manifest(Input),
    ?assertEqual(100, quod_dtx:manifest_deadline(Manifest)),
    Participants = maps:get(participants, Input),
    ?assertEqual({ok, Manifest}, quod_dtx:new_manifest(
                   Input#{participants := lists:reverse(Participants)})),
    TooMany = [{{<<"quod:bounded">>, <<N:256>>}, <<N:256>>}
               || N <- lists:seq(1, 9)],
    [?assertEqual({error, invalid_manifest}, quod_dtx:new_manifest(Input#{participants := Bad}))
     || Bad <- [TooMany, [hd(Participants) | bad_tail],
                [hd(Participants), hd(Participants)]]].

deadline_is_canonical_and_changes_manifest_authority_test() ->
    Input = manifest_input(),
    {ok, First} = quod_dtx:new_manifest(Input),
    {ok, Second} = quod_dtx:new_manifest(Input#{vote_deadline_ms := 101}),
    ?assertNotEqual(quod_dtx:manifest_digest(First),
                    quod_dtx:manifest_digest(Second)),
    {ok, Bytes} = quod_dtx:encode_manifest(First),
    ?assertEqual({ok, First}, quod_dtx:decode_manifest(Bytes)),
    %% Deliberately retain the exact old shape; no default deadline decoder.
    Old = setelement(2, erlang:delete_element(13, First), 3),
    ?assertEqual({error, {protocol_error, bad_payload}},
                 quod_dtx:decode_manifest(term_to_binary(Old, [deterministic]))).

independent_claim_has_no_atomic_vote_deadline_test() ->
    F = remote_fixture(#{}),
    Manifest = maps:get(manifest, F),
    ?assertEqual(none, quod_dtx:manifest_deadline(Manifest)),
    {ok, Bytes} = quod_dtx:encode_manifest(Manifest),
    ?assertEqual({ok, Manifest}, quod_dtx:decode_manifest(Bytes)),
    Claim = quod_transaction:remote_claim(maps:get(origin, F), Manifest,
              maps:get(bundles, F), maps:get(auth, F), []),
    ?assertEqual(ok, quod_transaction:validate_independent_claim(Claim)),
    Atomic = remote_fixture(#{atomic => true}),
    ?assertError({badmatch, error}, quod_transaction:remote_claim(
      maps:get(origin, Atomic), maps:get(manifest, Atomic),
      maps:get(bundles, Atomic), maps:get(auth, Atomic), [])).

atomic_group_cannot_use_an_independent_manifest_test() ->
    Origin = {<<"quod:o">>, <<2:256>>}, Target = {<<"quod:b">>, <<7:256>>},
    F = quod_ct:signed_plan_fixture(#{target => Origin}, [Origin, Target]),
    %% All attestations and client bindings are genuine; only the absent
    %% atomic deadline makes this inadmissible as an atomic group.
    ?assertEqual({error, invalid_group}, quod_atomic:new_group(
      maps:get(manifest, F), maps:get(auth, F),
      maps:get(Origin, maps:get(attestations, F)))).

remote_fixture(Options) ->
    Origin = {<<"quod:origin">>, <<2:256>>}, Target = {<<"quod:target">>, <<7:256>>},
    quod_ct:signed_plan_fixture(Options#{target => Origin, participant_target => Target}, [Target]).

unsigned_expired_budget_stays_expired_test() ->
    with_deadline(quod_time:mono_ms() - 60000, none,
      fun() ->
          ?assert(quod_proof_context:vote_deadline_ms() < quod_time:now_ms()),
          ?assertEqual(0, quod_proof_context:remaining_ms())
      end).

signed_expiry_can_only_shorten_the_admitted_budget_test() ->
    Fixture = quod_ct:signed_goal_fixture(#{deadline => 10}),
    with_deadline(quod_time:mono_ms() + 60000, maps:get(evidence, Fixture),
      fun() -> ?assertEqual(10, quod_proof_context:vote_deadline_ms()) end).

large_signed_expiry_does_not_replace_the_caller_budget_test() ->
    Fixture = quod_ct:signed_goal_fixture(#{deadline => (1 bsl 64) - 1}),
    with_deadline(quod_time:mono_ms() - 60000, maps:get(evidence, Fixture),
      fun() -> ?assert(quod_proof_context:vote_deadline_ms() < quod_time:now_ms()) end).

with_deadline(Deadline, Evidence, Fun) ->
    _ = quod_proof_context:start(
          <<1:256>>, false, {<<"quod:deadline">>, <<2:256>>},
          Deadline, anonymous, Evidence),
    try Fun()
    after quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end)
    end.

manifest_input() ->
    {ok, Goal} = quod_durable_term:encode_goal(true),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    #{proof_id => <<1:256>>, coordinator => {<<"quod:o">>, <<2:256>>, <<3:256>>, <<4:256>>},
      nonce => <<5:256>>, principal => anonymous, goal => Goal, result => Result,
      request_binding => none,
      participants => [{{<<"quod:o">>, <<2:256>>}, <<6:256>>},
                       {{<<"quod:b">>, <<7:256>>}, <<8:256>>}],
      vote_deadline_ms => 100}.
