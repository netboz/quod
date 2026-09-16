-module(quod_atomic_origin_tests).
-include_lib("eunit/include/eunit.hrl").

%% The proof/session owners and staging stores are real. The co-hosted scope
%% handles here stay in one VM; these cases do not claim distributed admission.
unsigned_empty_source_seals_only_for_multiple_foreign_writers_test() ->
    lists:foreach(fun(N) ->
        with_scopes(N, fun(Origin, Targets, _Handles) ->
            {ok, Plans} = quod_proof_context:seal_plans(),
            Expected = case N >= 2 of true -> [Origin | Targets]; false -> Targets end,
            ?assertEqual(lists:sort(Expected), lists:sort(maps:keys(Plans))),
            ?assertEqual({ok, Plans}, quod_proof_context:seal_plans()),
            case maps:find(Origin, Plans) of
                {ok, Plan} ->
                    ?assert(quod_dtx:verify(Plan)),
                    ?assertEqual(0, quod_dtx:diff_ops(Plan)),
                    ?assertEqual(0, quod_dtx:effects_count(Plan)),
                    ?assertEqual(#{}, quod_ct:plan_material(read_check, Plan));
                error -> ok
            end
        end)
    end, [0, 1, 2, 4]).

empty_source_is_sealed_once_and_can_attest_the_group_test() ->
    {ok, Count} = seal_count(fun() -> with_scopes(2, fun(Origin, Targets, Handles) ->
        {ok, Plans} = quod_proof_context:seal_plans(),
        SourcePlan = maps:get(Origin, Plans),
        Manifest = unsigned_manifest(Origin, Targets, Plans, quod_proof_context:vote_deadline_ms()),
        Handle = maps:get(Origin, Handles),
        {ok, Attestation} = quod_scope_session:attest_plan(Handle, SourcePlan, Manifest),
        {ok, Group} = quod_atomic:new_group(Manifest, none, Attestation),
        {ok, Blob} = quod_dtx:encode(SourcePlan),
        Bundle = {Origin, quod_dtx:digest(SourcePlan), Blob, Attestation},
        {ok, Vote} = quod_atomic:new_vote(Group, Origin, Bundle, prepared),
        {ok, Material} = quod_atomic:admission_material(Vote),
        ?assertNot(quod_atomic:requires_network_identity(Material)),
        ?assertEqual({ok, none}, quod_atomic:validate_request(none, Origin, 0, Material)),
        %% A changed seal binding would be rejected by the existing session.
        %% The same stored set is reused after attestation, not re-sealed.
        ?assertEqual({ok, Plans}, quod_proof_context:seal_plans())
    end) end),
    ?assertEqual(3, Count).

unsigned_atomic_group_cannot_omit_deadline_test() ->
    with_scopes(2, fun(Origin, Targets, Handles) ->
        {ok, Plans} = quod_proof_context:seal_plans(),
        Manifest = unsigned_manifest(Origin, Targets, Plans, none),
        {ok, Attestation} = quod_scope_session:attest_plan(
                             maps:get(Origin, Handles), maps:get(Origin, Plans), Manifest),
        ?assertEqual({error, invalid_group}, quod_atomic:new_group(Manifest, none, Attestation))
    end).

unsigned_manifest({Ns, Anchor} = Origin, Targets, Plans, Deadline) ->
    {ok, Goal} = quod_durable_term:encode_goal(true),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    {ok, Manifest} = quod_dtx:new_manifest(
      #{proof_id => quod_proof_context:proof_id(),
        coordinator => {Ns, Anchor, quod_dtx:signer(maps:get(Origin, Plans)), <<8:256>>},
        nonce => <<9:256>>, principal => anonymous, request_binding => none,
        goal => Goal, result => Result,
        participants => [{T, quod_dtx:digest(maps:get(T, Plans))} || T <- [Origin | Targets]],
        vote_deadline_ms => Deadline}),
    Manifest.

empty_source_vote_admission_uses_the_existing_own_plan_header_test() ->
    with_scopes(2, fun({Ns, Anchor} = Origin, Targets, Handles) ->
        {ok, Plans} = quod_proof_context:seal_plans(),
        Plan = maps:get(Origin, Plans),
        ?assertNot(quod_dtx:participates(Plan)),
        Manifest = unsigned_manifest(Origin, Targets, Plans, quod_proof_context:vote_deadline_ms()),
        {ok, Attestation} = quod_scope_session:attest_plan(maps:get(Origin, Handles), Plan, Manifest),
        {ok, Group} = quod_atomic:new_group(Manifest, none, Attestation),
        {ok, Blob} = quod_dtx:encode(Plan),
        {ok, Vote} = quod_atomic:new_vote(Group, Origin,
            {Origin, quod_dtx:digest(Plan), Blob, Attestation}, prepared),
        {ok, Material} = quod_atomic:admission_material(Vote),
        Signer = quod_dtx:signer(Plan),
        Est = quod_ct:committed_kb([{can_invoke, true, anonymous, [], Ns},
                                  {peer_admitted, Signer, "validator", 14567, Signer}]),
        {ok, Index} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
        try
            Context = quod_commit_validation:new(Origin, 1, Est, Index, none),
            ?assertMatch({ok, prepared, _}, quod_commit_validation:vote_choice(Material, 1, Context))
        after ok = quod_outcome:close(Index)
        end
    end).

origin_role_cannot_be_forced_on_a_foreign_scope_test() ->
    with_scopes(1, fun(Origin, [Target], Handles) ->
        ?assertEqual({error, {protocol_error, session_binding}},
          quod_scope_session:seal(maps:get(Target, Handles), Origin, anonymous, none, true)),
        ?assertMatch({ok, _}, quod_proof_context:seal_plans())
    end).

source_role_selection_matches_routing_test() ->
    lists:foreach(fun(N) ->
        with_scopes(N, fun(Origin, Targets, _Handles) ->
            {ok, Plans} = quod_proof_context:seal_plans(),
            Route = quod_prolog:test_route_plans(Plans, Origin, false),
            Expected = case Targets of
                [] -> read;
                [T] -> {single, T, []};
                _ -> {group, lists:sort([Origin | Targets])}
            end,
            ?assertEqual(Expected, Route)
        end)
    end, [0, 1, 2, 4]).

source_last_sealing_keeps_failed_branch_material_atomic_test() ->
    Fallback = {';', {independent, {',', {assertz, residue}, fail}}, {assertz, fallback}},
    with_scopes(2, #{signed => true, foreign_goals => [Fallback, {assertz, other}]},
      fun(Origin, Targets, _Handles) ->
          ?assertNot(quod_proof_context:independent()),
          {ok, Plans} = quod_proof_context:seal_plans(),
          ?assertEqual([fallback, residue], sealed_facts(maps:get(hd(Targets), Plans))),
          ?assertEqual({group, lists:sort([Origin | Targets])},
                       quod_prolog:test_route_plans(Plans, Origin, true, false))
      end).

source_last_sealing_keeps_cut_pruned_residue_atomic_test() ->
    Cut = {';', {independent, {',', {assertz, residue}, {',', '!', fail}}}, true},
    with_scopes(2, #{signed => true, foreign_goals => [Cut, {assertz, other}]},
      fun(Origin, Targets, _Handles) ->
          ?assertNot(quod_proof_context:independent()),
          {ok, Plans} = quod_proof_context:seal_plans(),
          ?assertEqual([residue], sealed_facts(maps:get(hd(Targets), Plans))),
          ?assertEqual({group, lists:sort([Origin | Targets])},
                       quod_prolog:test_route_plans(Plans, Origin, true, false))
      end).

source_last_sealing_does_not_erase_mixed_provenance_test() ->
    with_scopes(2, #{signed => true, origin_goal => {independent, true},
                    foreign_goals => [{assertz, ordinary}, {independent, {assertz, wrapped}}]},
      fun(_Origin, _Targets, _Handles) ->
          ?assert(quod_proof_context:independent()),
          ?assertEqual({error, independent_mixed_writes}, quod_proof_context:seal_plans())
      end).

source_last_sealing_keeps_selected_independent_intent_test() ->
    Retained = {',', {';', {independent, {',', {assertz, residue}, fail}}, true},
                {independent, {assertz, selected}}},
    with_scopes(2, #{signed => true, origin_goal => {independent, true},
                    foreign_goals => [Retained, {independent, {assertz, other}}]},
      fun(Origin, Targets, _Handles) ->
          ?assert(quod_proof_context:independent()),
          {ok, Plans} = quod_proof_context:seal_plans(),
          ?assertEqual([residue, selected], sealed_facts(maps:get(hd(Targets), Plans))),
          ?assertMatch({remote_claim, Targets, _},
                       quod_prolog:test_route_plans(Plans, Origin, true, true)),
          ?assertEqual({ok, Plans}, quod_proof_context:seal_plans())
      end).

source_last_sealing_keeps_failed_branch_events_in_order_test() ->
    Events = {';', {',', {trigger_event, first}, fail}, {trigger_event, second}},
    with_scopes(2, #{foreign_goals => [Events, {assertz, other}]},
      fun(Origin, [Target | _], _Handles) ->
          {ok, Plans} = quod_proof_context:seal_plans(),
          ?assert(maps:is_key(Origin, Plans)),
          ?assertEqual([{event, first}, {event, second}],
                       quod_ct:plan_material(diff, maps:get(Target, Plans)))
      end).

source_last_sealing_uses_restored_writes_and_monotone_reads_test() ->
    with_scopes(2, #{foreign_goals => [true, {assertz, other}], facts => [{input, value}]},
      fun(Origin, [Target, Writer], Handles) ->
          Session = element(6, maps:get(Target, Handles)),
          ok = quod_proof_session:checkpoint_many(Session, [before_candidate]),
          Candidate = {',', {input, value},
                        {',', {assertz, removed}, {trigger_event, removed_event}}},
          {_Id, {solution, _}} = invoke(Session, Target, Candidate),
          ok = quod_proof_session:restore_many(Session, [before_candidate]),
          ok = quod_proof_session:release_many(Session, [before_candidate]),
          {ok, Plans} = quod_proof_context:seal_plans(),
          ?assertNot(maps:is_key(Origin, Plans)),
          ReaderPlan = maps:get(Target, Plans),
          ?assertEqual([], quod_ct:plan_material(diff, ReaderPlan)),
          ?assert(maps:is_key({input, 1}, quod_ct:plan_material(read_check, ReaderPlan))),
          ?assertEqual({single, Writer, [{Target, ReaderPlan}]},
                       quod_prolog:test_route_plans(Plans, Origin, false))
      end).

whole_proof_failure_never_seals_any_scope_test() ->
    {ok, Count} = seal_count(fun() ->
      with_scopes(2, #{origin_goal => {',', {assertz, doomed}, fail}},
      fun(_Origin, _Targets, Handles) ->
          %% This is the production failure boundary, not seal_plans/0.
          %% Aborting drops sessions without manufacturing a sealed plan.
          ?assertEqual(3, map_size(Handles)),
          quod_proof_context:finalize(abort)
      end)
    end),
    ?assertEqual(0, Count).

sealed_facts(Plan) ->
    lists:sort([Head || {assert, {Head, _}} <- quod_ct:plan_material(diff, Plan)]).

seal_count(Fun) ->
    {{Result, Owner}, {call_time, Rows}} = tprof:profile(fun() -> {Fun(), self()} end,
      #{type => call_time, report => return, set_on_spawn => false,
        pattern => [{quod_proof_session, seal, 2}]}),
    {Result, lists:sum([N || {quod_proof_session, seal, 2, Ps} <- Rows,
                           {Pid, N, _} <- Ps, Pid =:= Owner])}.

with_scopes(N, Fun) -> with_scopes(N, #{}, Fun).
with_scopes(N, Options, Fun) ->
    Origin = {<<"quod:atomic-empty-a">>, <<1:256>>},
    Targets = [{<<"quod:atomic-empty-b", (integer_to_binary(I))/binary>>, <<I:256>>}
               || I <- lists:seq(1, N)],
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Signed = maps:get(signed, Options, false),
    {Principal, Evidence} = case Signed of
        false -> {anonymous, none};
        true -> Request = quod_ct:signed_goal_fixture(#{target => Origin}),
                {maps:get(principal, Request), maps:get(evidence, Request)}
    end,
    _ = quod_proof_context:start(<<7:256>>, false, Origin,
                                  quod_time:mono_ms() + 60000, Principal, Evidence),
    KB = quod_transaction_predicates:load(quod_ct:committed_kb(maps:get(facts, Options, []))),
    Sessions = [{T, quod_proof_session:start(KB,
                    #{read_set => true, signed_request => Signed,
                      proof_context => {origin, atomic_fixture}, signer => Signer})}
                || T <- [Origin | Targets]],
    ForeignGoals = maps:get(foreign_goals, Options,
                           [{assertz, {own, Ns}} || {Ns, _} <- Targets]),
    Goals = maps:from_list([{Origin, maps:get(origin_goal, Options, true)} |
                            lists:zip(Targets, ForeignGoals)]),
    try
        Handles = maps:from_list([begin
            {Ns, Anchor} = Target,
            {Invocation, Result} = invoke(Session, Target, maps:get(Target, Goals)),
            case {Target =:= Origin, Result} of
                {true, {solution, _}} -> ok = quod_proof_context:select_independent(
                                              quod_proof_session:independent_intent(Session, Invocation));
                {true, {complete, _}} -> ok;
                {false, {solution, _}} -> ok
            end,
            {ok, _, Handle} = quod_proof_context:get_or_open_scope(Target,
              fun(ScopeId) -> {ok, self(), {local_scope, ScopeId, Ns, Anchor, 1, Session}} end),
            {Target, Handle}
        end || {Target, Session} <- Sessions]),
        Fun(Origin, Targets, Handles)
    after
        quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end),
        [quod_proof_session:stop(S) || {_, S} <- Sessions]
    end.

invoke(Session, {Ns, _} = Target, Goal) ->
    Invocation = crypto:strong_rand_bytes(16),
    ok = quod_proof_session:open(Session, Invocation, Goal, allowed,
             quod_predicates:proof_context(Ns, 1, undefined, [Target]),
             quod_transaction_scope:empty_selection()),
    {Invocation, quod_proof_session:next(Session, Invocation)}.
