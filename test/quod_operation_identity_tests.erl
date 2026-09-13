-module(quod_operation_identity_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Real signed request/plan envelopes; no claim of consensus admission. Counts
%% are structural, from OTP's isolated profiling session, never wall-clock limits.
old_signed_bytes_and_target_ids_are_preserved_test() ->
    %% Cold standalone VMs need the application's protocol vocabulary loaded;
    %% never allocate symbols by decoding captured signed bytes unsafely.
    case application:load(quod) of
        ok -> ok;
        {error, {already_loaded, quod}} -> ok
    end,
    {ok, Modules} = application:get_key(quod, modules),
    [{module, M} = code:ensure_loaded(M) || M <- Modules],
    lists:foreach(fun(N) ->
        {ok, Bytes} = file:read_file(filename:join(
          ["test", "fixtures", "operation-identity179", "claim-" ++ integer_to_list(N) ++ ".etf"])),
        {ok, Claim} = quod_transaction:decode_ledger_transaction(Bytes, wrapped),
        ?assertEqual({ok, Bytes}, quod_transaction:encode_ledger_transaction(Claim)),
        {ok, Refs} = quod_transaction:remote_claim_references(Claim),
        ?assertEqual(N, length(Refs)),
        {Ns, Anchor} = Claim#transaction.origin,
        lists:foreach(fun(Ref) ->
            App = quod_transaction:remote_application(
                {transaction, Ns, Anchor, Claim#transaction.tx_id}, Claim,
                quod_operation_vector:target(Ref)),
            ?assertEqual(element(4, Ref), App#transaction.tx_id)
        end, Refs)
    end, [1,2,4,8]).

one_source_derivation_per_constructor_vector_test() ->
    lists:foreach(fun(N) ->
        F = fixture(N),
        {Claim, Counts} = counted(fun() -> construct(F) end),
        ?assertMatch(#transaction{role = {remote_claim, _, _, _}}, Claim),
        ?assertEqual(1, maps:get(request, Counts)),
        ?assertEqual(1, maps:get(identity, Counts)),
        {ok, Refs} = quod_transaction:remote_claim_references(Claim),
        ?assertEqual(N, length(Refs)),
        lists:foreach(fun(Ref) ->
            Target = quod_operation_vector:target(Ref),
            App = quod_transaction:remote_application(claim_ref(F, Claim), Claim, Target),
            ?assertEqual(element(4, Ref), App#transaction.tx_id)
        end, Refs)
    end, [1, 2, 4, 8]).

one_source_derivation_per_decoded_vector_test() ->
    lists:foreach(fun(N) ->
        F = fixture(N), Signed = signed(F, construct(F)),
        {ok, Bytes} = quod_transaction:encode_ledger_transaction(Signed),
        {{ok, Decoded}, Counts} = counted(fun() ->
            quod_transaction:decode_ledger_transaction(Bytes, wrapped)
        end),
        ?assertEqual(1, maps:get(request, Counts)),
        ?assertEqual(1, maps:get(identity, Counts)),
        ?assertEqual(Signed#transaction.tx_id, Decoded#transaction.tx_id),
        ?assertEqual(Signed#transaction.signed_bytes, Decoded#transaction.signed_bytes),
        ?assertEqual({ok, Bytes}, quod_transaction:encode_ledger_transaction(Decoded))
    end, [1, 2, 4, 8]).

client_signature_is_still_verified_before_admission_test() ->
    F = fixture(2), Claim = signed(F, construct(F)),
    {agent_goal_v1, Digest, Payload, <<Byte, Tail/binary>>} = Claim#transaction.request_auth,
    BadAuth = {agent_goal_v1, Digest, Payload, <<(Byte bxor 1), Tail/binary>>},
    ?assertException(error, _, construct(F#{auth => BadAuth})),
    %% Re-sign the outer envelope so ONLY the inner client signature is bad.
    ?assertMatch({error, _}, quod_transaction:decode_ledger_transaction(
        resigned(F, Claim, fun(T) -> setelement(17, T, BadAuth) end), wrapped)).

explicit_and_stored_claim_ids_remain_bound_test() ->
    F = fixture(2), Claim = construct(F), [Target | _] = maps:get(targets, F),
    {transaction, Ns, Anchor, _} = claim_ref(F, Claim),
    ?assertException(error, _, quod_transaction:remote_application(
        {transaction, Ns, Anchor, <<0:256>>}, Claim, Target)),
    ?assertException(error, _, quod_transaction:remote_application(
        claim_ref(F, Claim), Claim#transaction{tx_id = <<0:256>>}, Target)),
    Signed = signed(F, Claim),
    ?assertMatch({error, _}, quod_transaction:decode_ledger_transaction(
        resigned(F, Signed, fun(T) -> setelement(6, T, <<0:256>>) end), wrapped)).

complete_prediction_vector_remains_exact_test() ->
    F = fixture(4), Claim = signed(F, construct(F)),
    lists:foreach(fun(Change) ->
        ?assertMatch({error, _}, quod_transaction:decode_ledger_transaction(
            resigned(F, Claim, fun(T) ->
                {remote_claim, M, B, Refs} = element(14, T),
                setelement(14, T, {remote_claim, M, B, Change(Refs)})
            end), wrapped))
    end, [fun tl/1, fun lists:reverse/1, fun([A | Rest]) -> [A, A | Rest] end,
          fun([{transaction, Ns, Anchor, _} | Rest]) ->
              [{transaction, Ns, Anchor, <<0:256>>} | Rest] end]).

request_goal_binding_remains_exact_test() ->
    F = fixture(2), Claim = signed(F, construct(F)),
    {ok, OtherGoal} = quod_durable_term:encode_goal(false),
    ?assertMatch({error, _}, quod_transaction:decode_ledger_transaction(
        resigned(F, Claim, fun(T) -> setelement(10, T, OtherGoal) end), wrapped)).

every_target_plan_still_binds_the_verified_request_test() ->
    F = fixture(2),
    Other = quod_ct:signed_goal_fixture(#{target => maps:get(origin, F),
        key_pair => maps:get(key_pair, F), operation_id => <<93:256>>}),
    ?assertEqual(maps:get(goal_blob, F), maps:get(goal_blob, Other)),
    ?assertNotEqual(maps:get(binding, F), maps:get(binding, Other)),
    %% Both requests are authentically signed by the same client for the same
    %% parsed goal. Only their operation identity differs. Neither target's
    %% original authenticated seal may be borrowed for that new request.
    ?assertException(error, _, construct(F#{auth => maps:get(auth, Other)})).

fixture(N) ->
    Origin = {<<"quod:identity-source">>, <<71:256>>},
    Targets = [{<<"quod:identity-target-", (integer_to_binary(I))/binary>>, <<I:256>>}
               || I <- lists:seq(1, N)],
    F = quod_ct:signed_plan_fixture(
          #{target => Origin, participant_target => hd(Targets)}, Targets),
    F#{origin => Origin, targets => Targets}.

construct(F) ->
    quod_transaction:remote_claim(maps:get(origin, F), maps:get(manifest, F),
                                  maps:get(bundles, F), maps:get(auth, F), []).
claim_ref(F, Claim) ->
    {Ns, Anchor} = maps:get(origin, F), {transaction, Ns, Anchor, Claim#transaction.tx_id}.
signed(F, Claim) ->
    Signer = #{pubkey := Key} = maps:get(node_identity, F),
    {Ns, Anchor} = maps:get(origin, F),
    {ok, Signed} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)},
        Claim#transaction{author = Key, author_seq = 1, submitted_at = 1}, Signer), Signed.
resigned(F, Claim, Change) ->
    Canonical = term_to_binary(Change(binary_to_term(Claim#transaction.signed_bytes, [safe])), [deterministic]),
    Signature = quod_identity:sign(Canonical, maps:get(node_identity, F)),
    term_to_binary({submit, Claim#transaction.author, Signature, Canonical}, [deterministic]).

counted(Fun) ->
    %% Profiling patterns must bind loaded code, including in a standalone
    %% first test; a future module load does not install this function pattern.
    [{module, M} = code:ensure_loaded(M) || M <- [quod_client_goal, quod_transaction]],
    {Result, {call_count, Rows}} = tprof:profile(Fun,
        #{type => call_count, report => return,
          pattern => [{quod_client_goal, verify_durable_request, 2},
                      {quod_transaction, semantic_id, 2}], timeout => 30000}),
    Count = fun(M, F) -> lists:sum([N || {Mod, Fn, 2, Ps} <- Rows,
                         Mod =:= M, Fn =:= F, {_Pid, N, _} <- Ps]) end,
    {Result, #{request => Count(quod_client_goal, verify_durable_request),
               identity => Count(quod_transaction, semantic_id)}}.
