-module(quod_dtx_recovery_tests).
-include_lib("eunit/include/eunit.hrl").

%% Pure planner controls. Own plans and AM3 statements are signed; ledger refs
%% represent evidence already accepted by the coordinator's real verifier.
%% These are not consensus-admission or whole-node restart witnesses.

three_role_commit_recovery_closes_the_complete_vector_test() ->
    F = fixture(3), O = maps:get(origin, F), Roles = maps:get(roles, F),
    Id = maps:get(group_id, F), Votes = votes(F), Own = own(maps:get(O, Votes)),
    Empty = quod_dtx_recovery:empty(),
    {Own, Durable, Resolves} = resolved(F, Votes, []),
    ?assertEqual(Roles, [T || {T, _, _} <- Resolves]),
    Commands = [{applied, T, Id, Ref, 2, commit} || {T, _, Ref} <- Resolves, T =/= O],
    ?assertEqual({ok, {independent, applied, Commands}}, quod_dtx_recovery:next(Own, Durable)),
    ?assertEqual(pending, quod_dtx_recovery:terminal(Own, Durable)),
    Ready = certify(F, Own, Commands, Durable),
    Slots = [{T, slot(R), 2} || {T, _, R} <- Resolves],
    {O, SourceSlot, 2} = lists:keyfind(O, 1, Slots),
    ?assertEqual({ok, #{verdict => commit, reasons => none, source_slot => SourceSlot,
                       participant_slots => Slots}}, quod_dtx_recovery:terminal(Own, Ready)),
    {ok, {ordered, complete, [{submit, O, Complete}]}} = quod_dtx_recovery:next(Own, Ready),
    {quod_dtx_complete, 4, Id, O, _, commit, Rows, Certificates} = Complete,
    ?assertEqual([{T, R, 2} || {T, _, R} <- Resolves], Rows),
    ?assertEqual(Roles -- [O], [T || {T, _} <- Certificates]),
    %% Certified Complete needs no previous worker's volatile inventory.
    Done = evidence(F, O, Complete, 40), Ref = ref(Done),
    ?assertEqual({done, Ref}, quod_dtx_recovery:next(Own, observe(Own, [Done], Empty))).

target_refusal_preserves_reasons_and_closes_unvoted_role_test() ->
    F = fixture(3), [O, A, B] = maps:get(roles, F),
    Name = <<"quod_recovery_unknown_", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    Reasons = [{{'$quod_symbol', Name}, {cannot_link, bob, tom}}],
    ?assertException(error, badarg, binary_to_existing_atom(Name, utf8)),
    V0 = #{O => vote(F, O, prepared)},
    Vs = V0#{A => vote(F, A, {refused, Reasons})},
    Missing = maps:get(roles, F) -- maps:keys(Vs),
    {Own, Durable, Resolves} = resolved(F, Vs, Missing),
    NegativeRef = ref(maps:get(A, Vs)), OriginRef = ref(maps:get(O, Vs)),
    lists:foreach(fun({T, C, _}) ->
        {quod_dtx_resolve, 4, _, T, _, abort, OriginRef,
            {refused, NegativeRef}, OwnRef, Generation, Blob} = quod_atomic:control_body(C),
        ?assertEqual({ok, Reasons}, quod_wire_term:decode_failure_reasons(Blob)),
        case maps:find(T, Vs) of
            {ok, V} -> ?assertEqual(ref(V), OwnRef), ?assertEqual(1, Generation);
            error -> ?assertEqual(none, OwnRef), ?assertEqual(0, Generation)
        end
    end, Resolves),
    ?assert(lists:member(B, Missing)),
    Commands = [{applied, T, maps:get(group_id, F), R, 1, abort}
                || {T, _, R} <- Resolves, T =/= O, maps:is_key(T, Vs)],
    Ready = certify(F, Own, Commands, Durable),
    ?assertMatch({ok, #{verdict := abort, reasons := Reasons}}, quod_dtx_recovery:terminal(Own, Ready)),
    ?assertMatch({ok, {ordered, complete, [_]}}, quod_dtx_recovery:next(Own, Ready)),
    ?assertException(error, badarg, binary_to_existing_atom(Name, utf8)).

certified_resolve_does_not_require_prior_volatile_vote_observation_test() ->
    F = fixture(2), [O, T] = maps:get(roles, F), Vs = votes(F),
    {Own, _Durable, Resolves} = resolved(F, Vs, []),
    S0 = observe(Own, [lists:keyfind(T, 1, Resolves)], quod_dtx_recovery:empty()),
    Id = maps:get(group_id, F),
    %% Keep resolution while asking for missing facts; do not reject due to
    %% this worker's observation order or resubmit the already-resolved target.
    ?assertEqual({ok, {independent, vote, [{phase, T, Id, vote}]}}, quod_dtx_recovery:next(Own, S0)),
    S1 = observe(Own, [maps:get(T, Vs)], S0),
    ?assertEqual({ok, {independent, resolve, [{phase, O, Id, resolve}]}}, quod_dtx_recovery:next(Own, S1)),
    ?assertMatch({ok, {independent, resolve, [{submit, O, _}]}},
                 quod_dtx_recovery:next(Own, absent([O], resolve, S1))).

equivalent_finality_subsets_preserve_first_fact_but_not_another_claim_test() ->
    F = fixture(2), [O, T] = maps:get(roles, F), Vs = votes(F), Own = own(maps:get(O, Vs)),
    {T, C, R} = V = maps:get(T, Vs),
    S = observe(Own, [V], quod_dtx_recovery:empty()),
    Equivalent = setelement(8, R, <<"other-quorum-proof">>),
    ?assertEqual({ok, S}, quod_dtx_recovery:observe(Own, {T, C, Equivalent}, S)),
    ?assertEqual({error, conflicting_phase_evidence},
        quod_dtx_recovery:observe(Own, {T, C, setelement(6, Equivalent, <<249:256>>)}, S)),
    ?assertEqual({error, invalid_phase_evidence},
        quod_dtx_recovery:observe(Own, {T, C, setelement(7, R, <<250:256>>)}, S)).

applied_certificate_binds_exact_resolve_generation_outcome_and_role_test() ->
    F = fixture(2), [O, T] = maps:get(roles, F),
    {Own, S, Resolves} = resolved(F, votes(F), []),
    {T, _, R} = lists:keyfind(T, 1, Resolves), Cert = applied(F, T, R, 2, commit),
    Equivalent = setelement(7, Cert, setelement(8, R, <<"other-resolve-quorum">>)),
    ?assertMatch({ok, _}, quod_dtx_recovery:applied(Own, T, Equivalent, S)),
    lists:foreach(fun(Bad) ->
        ?assertEqual({error, invalid_applied_evidence}, quod_dtx_recovery:applied(Own, T, Bad, S))
    end, [setelement(8, Cert, 3), setelement(9, Cert, abort), setelement(6, Cert, <<251:256>>),
          setelement(7, Cert, setelement(6, R, <<252:256>>)), setelement(4, Cert, O)]),
    ?assertEqual({error, invalid_applied_evidence}, quod_dtx_recovery:applied(Own, O, Cert, S)).

lost_volatile_certificate_is_recertified_then_carried_by_complete_test() ->
    F = fixture(2), [O, T] = maps:get(roles, F),
    {Own, Durable, Resolves} = resolved(F, votes(F), []),
    {T, _, R} = lists:keyfind(T, 1, Resolves),
    Command = {applied, T, maps:get(group_id, F), R, 2, commit},
    {ok, Before} = quod_dtx_recovery:applied(Own, T, applied(F, T, R, 2, commit), Durable),
    {ok, {ordered, complete, [{submit, O, First}]}} = quod_dtx_recovery:next(Own, Before),
    ?assertEqual({ok, {independent, applied, [Command]}}, quod_dtx_recovery:next(Own, Durable)),
    {Pub, Seed} = quod_identity:generate(),
    Replacement = F#{node_identity := #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}},
    {ok, After} = quod_dtx_recovery:applied(Own, T, applied(Replacement, T, R, 2, commit), Durable),
    {ok, {ordered, complete, [{submit, O, Second}]}} = quod_dtx_recovery:next(Own, After),
    %% I1 carries portable certificates, not volatile sidecars. A different
    %% verified quorum changes proof bytes, but not the resolved role vector.
    ?assertNotEqual(First, Second),
    ?assertEqual(setelement(8, First, []), setelement(8, Second, [])),
    Done = evidence(F, O, Second, 40),
    ?assertEqual({done, ref(Done)}, quod_dtx_recovery:next(Own, observe(Own, [Done], Durable))).

fixture(N) ->
    O = {<<"quod:recovery-a">>, <<1:256>>},
    Roles = lists:sublist([O, {<<"quod:recovery-b">>, <<2:256>>},
                          {<<"quod:recovery-c">>, <<3:256>>}], N),
    F = quod_ct:signed_plan_fixture(#{target => O, atomic => true}, Roles),
    {ok, G} = quod_atomic:new_group(maps:get(manifest, F), maps:get(auth, F),
                                    maps:get(O, maps:get(attestations, F))),
    F#{group => G, group_id => quod_atomic:group_id(G), roles => Roles}.
votes(F) -> maps:from_list([{T, vote(F, T, prepared)} || T <- maps:get(roles, F)]).
vote(F, T, Choice) ->
    {ok, V} = quod_atomic:new_vote(maps:get(group, F), T,
                                  lists:keyfind(T, 1, maps:get(bundles, F)), Choice),
    evidence(F, T, V, 2).
evidence(F, T = {Ns, Anchor}, Record, Slot) ->
    {ok, M} = quod_atomic:admission_material(Record),
    {ok, C} = quod_atomic:sign_control(T, M, maps:get(admission, F), Slot, Slot,
                                      maps:get(node_identity, F)),
    {ok, R} = quod_dtx:certified_ref(Ns, Anchor, Slot, <<Slot:256>>,
                                     quod_atomic:record_digest(C), <<"fixture-quorum">>),
    {T, C, R}.
own({_, C, R}) -> #{material => quod_atomic:control_material(C), ref => R, resolution => none}.
ref({_, _, R}) -> R.
slot(R) -> {ok, _, S, _} = quod_dtx:certified_ref_binding(R), S.
observe(Own, Rows, Snapshot) ->
    lists:foldl(fun(Row, S) -> {ok, Next} = quod_dtx_recovery:observe(Own, Row, S), Next end, Snapshot, Rows).
absent(Targets, Kind, Snapshot) ->
    lists:foldl(fun(T, S) -> quod_dtx_recovery:absent(T, Kind, S) end, Snapshot, Targets).
resolved(F, Votes, Unvoted) ->
    Own = own(maps:get(maps:get(origin, F), Votes)),
    S0 = observe(Own, maps:values(Votes), quod_dtx_recovery:empty()),
    S1 = absent(maps:get(roles, F), resolve, absent(Unvoted, vote, S0)),
    {ok, {independent, resolve, Commands}} = quod_dtx_recovery:next(Own, S1),
    Rows = [evidence(F, T, Record, 20 + I)
            || {{submit, T, Record}, I} <- lists:zip(Commands, lists:seq(1, length(Commands)))],
    {Own, observe(Own, Rows, S1), Rows}.
certify(F, Own, Commands, S) ->
    lists:foldl(fun({applied, T, _, R, Gen, Result}, Acc) ->
        {ok, Next} = quod_dtx_recovery:applied(Own, T, applied(F, T, R, Gen, Result), Acc), Next
    end, S, Commands).
applied(F, T, Ref, Gen, Result) ->
    Network = maps:get(network, F), Committee = <<240:256>>, Id = maps:get(group_id, F),
    {ok, Signature} = quod_applied_certificate:sign_applied_vote(Network, T, Committee,
        Id, Ref, Gen, Result, maps:get(node_identity, F)),
    {ok, Certificate} = quod_applied_certificate:applied_certificate(
        {Network, T, Committee, Id, Ref, Gen, Result}, [Signature]),
    Certificate.
