-module(quod_atomic_admission_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_dtx_owner.hrl").
-include("quod_ingress_limits.hrl").

many_reservations_keep_arrival_order_and_exact_engine_tokens_test() ->
    Empty = quod_atomic_admission:new(),
    Rows = [{make_ref(), material()} || _ <- lists:seq(1, 65)],
    Q = lists:foldl(fun({Token, M}, Acc) ->
        {ok, Next} = quod_atomic_admission:reserve(self(), Token, M, #{}, Acc), Next
    end, Empty, Rows),
    ?assertEqual({0, 65}, quod_atomic_admission:counts(Q)),
    [{First, M1}, {Second, _}, {Third, M3} | _] = Rows,
    ?assertEqual({none, Q}, quod_atomic_admission:activate(not_the_engine, First, Q)),
    ?assertEqual(Q, quod_atomic_admission:cancel(not_the_engine, First, Q)),
    {M3, Q1} = quod_atomic_admission:activate(self(), Third, Q),
    {M1, Q2} = quod_atomic_admission:activate(self(), First, Q1),
    Cancelled = quod_atomic_admission:cancel(self(), Second, Q2),
    ?assertEqual({3, 62}, quod_atomic_admission:counts(Cancelled)),
    {Commands, _} = quod_atomic_admission:next(parent1, 1, Cancelled),
    ?assertEqual([group(M) || {_, M} <- lists:sublist(Rows, 3)],
                 [Id || {Id, _, _, _} <- Commands]),
    [_, {_, _, Missing, _}, _] = Commands,
    ?assertMatch({_, _, #{group := _}}, Missing),
    ?assertEqual(none, element(5, element(1, Missing))).

reservation_activation_is_a_lifetime_transfer_test() ->
    Empty = quod_atomic_admission:new(),
    M = material(), Engine = self(), Token = make_ref(),
    {ok, Reserved} = quod_atomic_admission:reserve(Engine, Token, M, #{}, Empty),
    ?assertEqual({0, 1}, quod_atomic_admission:counts(Reserved)),
    ?assertEqual({[], Reserved}, quod_atomic_admission:next(parent1, 99, Reserved)),
    Cancelled = quod_atomic_admission:cancel(Engine, Token, Reserved),
    ?assertEqual(Cancelled, quod_atomic_admission:engine_lost(Engine, Reserved)),
    Missing = quod_atomic:source_presentation(M),
    {[{_, _, Missing, _}], _} = quod_atomic_admission:next(parent1, 99, Cancelled),
    ?assertEqual({none, Cancelled}, quod_atomic_admission:activate(Engine, Token, Cancelled)),
    %% A duplicate endpoint delivery never stands in for private activation.
    ?assertEqual(Reserved, quod_atomic_admission:admit(M, none, #{}, Reserved)),
    {M, Active} = quod_atomic_admission:activate(Engine, Token, Reserved),
    ?assertEqual({1, 0}, quod_atomic_admission:counts(Active)),
    ?assertEqual(Active, quod_atomic_admission:cancel(Engine, Token, Active)),
    ?assertEqual(Active, quod_atomic_admission:engine_lost(Engine, Active)),
    {[{_, _, M, #{}}], _} = quod_atomic_admission:next(parent1, 99, Active),
    ok.

caller_loss_never_drops_or_restarts_accepted_work_test() ->
    Empty = quod_atomic_admission:new(),
    M = material(), Id = group(M),
    Q = quod_atomic_admission:admit(M, {dtx_endpoint, self()}, #{}, Empty),
    {[{Id, Tag, M, _}], Checking} = quod_atomic_admission:next(parent1, 1, Q),
    Detached = quod_atomic_admission:detach_waiter(self(), Checking),
    ?assertEqual({[], Detached}, quod_atomic_admission:next(parent1, 1, Detached)),
    {selected, #{material := M, waiters := []}, Ready} =
        verdict(Tag, parent1, {vote, M}, Detached),
    {#{material := M, waiters := []}, Empty} = quod_atomic_admission:take(Id, Ready),
    ok.

parent_incarnation_and_deadline_edges_are_the_only_redrives_test() ->
    Empty = quod_atomic_admission:new(),
    M = material(), Id = group(M), Deadline = deadline(M),
    Q = quod_atomic_admission:admit(M, none, #{}, Empty),
    {[{Id, T1, M, _}], Q1} = quod_atomic_admission:next(parent1, Deadline - 1, Q),
    ?assertEqual({[], Q1}, quod_atomic_admission:next(parent1, Deadline, Q1)),
    {waiting, Q2} = verdict(T1, parent1, abstain, Q1),
    ?assertEqual({[], Q2}, quod_atomic_admission:next(parent1, Deadline, Q2)),
    {[{Id, T2, M, _}], Q3} = quod_atomic_admission:next(parent1, Deadline + 1, Q2),
    ?assertNotEqual(T1, T2),
    ?assertEqual(stale, verdict(T1, parent1, {vote, M}, Q3)),
    ?assertEqual({[], Q3}, quod_atomic_admission:next(parent1, Deadline + 2, Q3)),
    {[{Id, T3, M, _}], Q4} = quod_atomic_admission:next(parent2, Deadline + 2,
        quod_atomic_admission:parent_applied(parent2, #{}, Q3)),
    ?assertEqual(stale, verdict(T2, parent1, {vote, M}, Q4)),
    ?assertEqual(stale, verdict(T3, parent1, {vote, M}, Q4)),
    Lost = quod_atomic_admission:engine_lost(self(), Q4),
    {[{Id, T4, M, _}], _} = quod_atomic_admission:next(parent2, Deadline + 2, Lost),
    ?assertNotEqual(T3, T4).

missing_material_does_not_block_later_groups_or_replace_owned_material_test() ->
    Empty = quod_atomic_admission:new(),
    M = material(), Missing = missing(M), Other = material(),
    Id = group(M), OtherId = group(Other),
    Q0 = quod_atomic_admission:admit(Missing, none, #{}, Empty),
    Q1 = quod_atomic_admission:admit(Other, none, #{}, Q0),
    {[{Id, T1, Missing, _}, {OtherId, T2, Other, _}], Q2} =
        quod_atomic_admission:next(parent1, 1, Q1),
    {waiting, Q3} = verdict(T1, parent1, abstain, Q2),
    {selected, #{material := Other}, Selected} =
        verdict(T2, parent1, {vote, Other}, Q3),
    {#{material := Other}, Q4} = quod_atomic_admission:take(OtherId, Selected),
    ?assertEqual({[], Q4}, quod_atomic_admission:next(parent1, 1, Q4)),
    Q5 = quod_atomic_admission:admit(M, {dtx_endpoint, self()}, #{}, Q4),
    {[{Id, T3, M, _}], Q6} = quod_atomic_admission:next(parent1, 1, Q5),
    Q7 = quod_atomic_admission:admit(Missing, none, #{}, Q6),
    ?assertEqual(Q6, Q7),
    ?assertEqual({[], Q7}, quod_atomic_admission:next(parent1, 1, Q7)),
    ?assertEqual(stale, verdict(T1, parent1, {vote, Missing}, Q7)),
    {selected, #{material := M, waiters := [Me]}, Ready} =
        verdict(T3, parent1, {vote, M}, Q7),
    {#{material := M}, Empty} = quod_atomic_admission:take(Id, Ready),
    ?assertEqual(self(), Me).

repeated_manifest_does_not_restart_a_waiting_selection_test() ->
    Empty = quod_atomic_admission:new(),
    M = material(), Missing = missing(M), Id = group(M),
    Q = quod_atomic_admission:admit(Missing, none, #{}, Empty),
    {[{Id, Tag, _, _}], Q1} = quod_atomic_admission:next(parent1, 1, Q),
    {waiting, Q2} = verdict(Tag, parent1, abstain, Q1),
    {ok, OtherProposal} = quod_atomic:select_vote(Missing, {refused, [conflict]}),
    ?assertEqual(Q2, quod_atomic_admission:admit(OtherProposal, none, #{}, Q2)),
    ?assertEqual({[], Q2}, quod_atomic_admission:next(parent1, 2, Q2)).

indexed_completion_and_selected_refusal_consume_one_row_test() ->
    Empty = quod_atomic_admission:new(),
    M = material(), Id = group(M),
    Q = quod_atomic_admission:admit(M, {dtx_endpoint, self()}, #{}, Empty),
    {#{material := M, waiters := [Me]}, Empty} = quod_atomic_admission:take(Id, Q),
    ?assertEqual(self(), Me),
    {[{Id, Tag, _, _}], Q1} = quod_atomic_admission:next(parent1, deadline(M) + 1, Q),
    ?assertEqual(stale, verdict(Tag, parent1, {vote, material()}, Q1)),
    {ok, N} = quod_atomic:select_vote(M, {refused, [vote_deadline]}),
    {selected, #{material := N, waiters := [Me]}, Ready} =
        verdict(Tag, parent1, {vote, N}, Q1),
    {#{material := N}, Empty} = quod_atomic_admission:take(Id, Ready),
    ?assertEqual(error, quod_atomic_admission:take(Id, Empty)),
    ?assertNot(quod_atomic_admission:contains(Id, Empty)).

selected_material_waits_for_writer_readiness_without_revalidation_test() ->
    Empty = quod_atomic_admission:new(),
    M = material(), Id = group(M), D = deadline(M),
    Q = quod_atomic_admission:admit(M, none, #{}, Empty),
    {[{Id, Tag, M, _}], Q1} = quod_atomic_admission:next(parent1, D - 1, Q),
    {selected, _, Ready} = verdict(Tag, parent1, {vote, M}, Q1),
    ?assertEqual({1, 0}, quod_atomic_admission:counts(Ready)),
    %% A paused writer simply does not take this command. Reopening admission
    %% under the same parent gets the same material, never another policy walk.
    {[{Id, selected, M, _}], Ready} = quod_atomic_admission:next(parent1, D, Ready),
    {[{Id, NewTag, M, _}], _} = quod_atomic_admission:next(parent1, D + 1, Ready),
    ?assertMatch({Id, Ref} when is_reference(Ref), NewTag),
    ?assertNotEqual(Tag, NewTag).

journaled_selection_keeps_original_custody_until_replacement_test() ->
    Empty = quod_atomic_admission:new(),
    {M, F} = material_fixture(),
    Row = retained(M, F), Id = group(M),
    Q = quod_atomic_admission:recheck(Row, Empty),
    ?assertException(error, {badmatch, true}, quod_atomic_admission:recheck(Row, Q)),
    {[{Id, Tag, M, _}], Checking} = quod_atomic_admission:next(parent2, deadline(M) + 1, Q),
    {ok, Negative} = quod_atomic:select_vote(M, {refused, [vote_deadline]}),
    {selected, #{material := Negative, retained := Row}, Ready} =
        verdict(Tag, parent2, {vote, Negative}, Checking),
    %% The chosen negative is not durable until the owner's journal effect:
    %% the original exact retained envelope remains in the selected row.
    {#{material := Negative, retained := Row, waiters := [Me],
       selection := {{parent2, true}, #{parent := true}}}, Empty} = quod_atomic_admission:take(Id, Ready),
    ?assertEqual(self(), Me).

signed_missing_material_cannot_be_upgraded_to_another_intent_test() ->
    Empty = quod_atomic_admission:new(),
    {M, F} = material_fixture(), Missing = missing(M), Row = retained(Missing, F),
    Q = quod_atomic_admission:recheck(Row, Empty),
    ?assertNotEqual(quod_atomic:intent_id(M), quod_atomic:intent_id(Missing)),
    ?assertEqual(Q, quod_atomic_admission:admit(M, none, #{}, Q)),
    ?assertMatch([#{material := Missing, retained := Row}], quod_atomic_admission:take_all(Q)).

admission_release_returns_the_one_owned_envelope_and_current_waiters_test() ->
    Empty = quod_atomic_admission:new(),
    {M, F} = material_fixture(), Row = retained(M, F),
    Q = quod_atomic_admission:recheck(Row, Empty),
    ?assertMatch([#{material := M, retained := Row, waiters := [_]}],
                 quod_atomic_admission:take_all(Q)),
    ?assertEqual([], quod_atomic_admission:take_all(Empty)).

waiting_selection_never_retries_without_a_changed_binding_test() ->
    M = material(), Id = group(M), Empty = quod_atomic_admission:new(),
    Q = quod_atomic_admission:admit(M, none, #{}, Empty),
    {[{Id, Tag, _, _}], Checking} = quod_atomic_admission:next(parent1, 1, Q),
    {waiting, Parked} = verdict(Tag, parent1, abstain, Checking),
    lists:foreach(fun(_) ->
        ?assertEqual({[], Parked}, quod_atomic_admission:next(parent1, 1, Parked))
    end, lists:seq(1, 20)),
    {[{Id, Tag3, _, _}], Changed} = quod_atomic_admission:next(parent2, 1,
        quod_atomic_admission:parent_applied(parent2, #{}, Parked)),
    {selected, _, _} = verdict(Tag3, parent2, {vote, M}, Changed).

policy_wait_does_not_restart_selection_test() ->
    M = material(), Id = group(M),
    Q = quod_atomic_admission:admit(M, none, #{}, quod_atomic_admission:new()),
    {[{Id, Tag, _, _}], Checking} = quod_atomic_admission:next(parent1, 1, Q),
    {waiting, Parked} = verdict(Tag, parent1, abstain, Checking),
    ?assertEqual(Parked, quod_atomic_admission:parent_applied(parent1, #{}, Parked)),
    ?assertEqual({[], Parked}, quod_atomic_admission:next(parent1, 1, Parked)).

only_the_applied_parent_wakes_an_abstained_validation_test() ->
    M = material(), Id = group(M),
    Parent = {self(), {2, <<2:256>>}}, Earlier = {self(), {1, <<1:256>>}},
    Q = quod_atomic_admission:admit(M, none, #{}, quod_atomic_admission:new()),
    {[{Id, Tag, _, _}], Checking} = quod_atomic_admission:next(Parent, 1, Q),
    ?assertEqual(Checking, quod_atomic_admission:parent_applied(Parent, #{}, Checking)),
    {waiting, Parked} = verdict(Tag, Parent, await_parent, Checking),
    ?assertEqual(Parked, quod_atomic_admission:parent_applied(Earlier, #{}, Parked)),
    {[{Id, Tag2, _, _}], Checking2} = quod_atomic_admission:next(
        Parent, 1, quod_atomic_admission:parent_applied(Parent, #{}, Parked)),
    ?assertNotEqual(Tag, Tag2),
    ?assertEqual(stale, verdict(Tag, Parent, {vote, M}, Checking2)),
    {selected, _, Ready} = verdict(Tag2, Parent, {vote, M}, Checking2),
    ?assertEqual(Ready, quod_atomic_admission:parent_applied(Parent, #{}, Ready)).

out_of_order_removal_keeps_fifo_and_rejects_cross_group_tags_test() ->
    Materials = [material() || _ <- lists:seq(1, 4)],
    Empty = quod_atomic_admission:new(),
    Q = lists:foldl(fun(M, Acc) -> quod_atomic_admission:admit(M, none, #{}, Acc) end,
                    Empty, Materials),
    [First, Second, Third, Fourth] = Materials,
    {_, Removed} = quod_atomic_admission:take(group(Second), Q),
    Fifth = material(), Q1 = quod_atomic_admission:admit(Fifth, none, #{}, Removed),
    {Commands, Checking} = quod_atomic_admission:next(parent1, 1, Q1),
    ?assertEqual([group(M) || M <- [First, Third, Fourth, Fifth]],
                 [Id || {Id, _, _, _} <- Commands]),
    [{_, {_, Ref}, _, _} | _] = Commands,
    ?assertEqual(stale, verdict({group(Third), Ref}, parent1, {vote, Third}, Checking)),
    Finished = lists:foldl(fun(M, Acc) -> {_, Next} = quod_atomic_admission:take(group(M), Acc), Next end,
                           Checking, [Fifth, Fourth, First, Third]),
    ?assertEqual(Empty, Finished).

admission_bound_preserves_existing_and_durable_work_test_() ->
    {timeout, 30, fun() ->
        Materials = [material() || _ <- lists:seq(1, ?MAX_INGRESS_TXS + 1)],
        [Extra | Enrolled] = Materials,
        Full = lists:foldl(fun(M, Acc) ->
            {ok, Next} = quod_atomic_admission:reserve(self(), make_ref(), M, #{}, Acc), Next
        end, quod_atomic_admission:new(), Enrolled),
        ?assertEqual({0, ?MAX_INGRESS_TXS}, quod_atomic_admission:counts(Full)),
        ?assertNot(quod_atomic_admission:has_capacity(group(Extra), Full)),
        ?assertEqual({error, busy}, quod_atomic_admission:reserve(self(), make_ref(), Extra, #{}, Full)),
        First = hd(Enrolled),
        ?assert(quod_atomic_admission:has_capacity(group(First), Full)),
        Attached = quod_atomic_admission:admit(First, {dtx_endpoint, self()}, #{}, Full),
        ?assertEqual(quod_atomic_admission:counts(Full), quod_atomic_admission:counts(Attached)),
        %% Restore is not a fresh admission: a journal duty must never be
        %% discarded just because the volatile capacity is already occupied.
        Restored = quod_atomic_admission:admit(Extra, none, #{}, Attached),
        ?assertEqual({1, ?MAX_INGRESS_TXS}, quod_atomic_admission:counts(Restored)),
        {_, Removed} = quod_atomic_admission:take(group(Extra), Restored),
        {_, Released} = quod_atomic_admission:take(group(First), Removed),
        ?assert(quod_atomic_admission:has_capacity(group(Extra), Released))
    end}.

retained(M, F) ->
    {Record, Digest, _} = M,
    {ok, Control} = quod_atomic:sign_control(quod_atomic:record_target(Record), M,
                      maps:get(admission, F), 1, 0, maps:get(node_identity, F)),
    {ok, Envelope} = quod_atomic:encode_control(Control),
    #dtx_submission{control = Control, envelope = Envelope, group_id = group(M), digest = Digest,
                    inserted_at = 7, observation_started_at = 7, bytes = byte_size(Envelope),
                    placement = blocked, waiters = #{self() => true}}.

material() -> element(1, material_fixture()).
material_fixture() ->
    O = {<<"admission:source">>, <<1:256>>}, T = {<<"admission:target">>, <<2:256>>},
    F = quod_ct:signed_plan_fixture(#{target => O, atomic => true}, [O, T]),
    {ok, Group} = quod_atomic:new_group(maps:get(manifest, F), maps:get(auth, F),
                                       maps:get(O, maps:get(attestations, F))),
    {ok, Vote} = quod_atomic:new_vote(Group, O, lists:keyfind(O, 1, maps:get(bundles, F)), prepared),
    {ok, M} = quod_atomic:admission_material(Vote), {M, F}.
missing({{quod_dtx_vote, _, G, T, _, _}, _, _}) ->
    {ok, Vote} = quod_atomic:new_vote(G, T, none, {refused, [vote_deadline]}),
    {ok, M} = quod_atomic:admission_material(Vote), M.
group({Record, _, _}) -> quod_atomic:group_id(Record).
deadline({_, _, #{group := #{vote_deadline_ms := D}}}) -> D.

installed_dependency_edges_rebase_without_another_validation_test() ->
    M = material(), Id = group(M), P1 = {self(), {1, <<1:256>>}}, P2 = {self(), {2, <<2:256>>}},
    Basis = #{{fact, {policy, 1}} => true, {request, request1} => true,
              {reservation, {<<"saved">>, 1}} => true},
    Q = quod_atomic_admission:admit(M, none, #{}, quod_atomic_admission:new()),
    {[{Id, Tag, _, _}], Checking} = quod_atomic_admission:next(P1, 1, Q),
    {selected, _, Ready} = quod_atomic_admission:verdict(Tag, P1, {{vote, M}, Basis}, Checking),
    %% Consensus advancement is not proof that the engine applied its delta.
    ?assertEqual({[], Ready}, quod_atomic_admission:next(P2, 1, Ready)),
    Advanced = quod_atomic_admission:parent_applied(P2, #{{fact, {unrelated, 1}} => true}, Ready),
    ?assertEqual({[{Id, selected, M, #{}}], Advanced}, quod_atomic_admission:next(P2, 1, Advanced)),
    ?assertEqual(Advanced, quod_atomic_admission:parent_applied(P1, #{}, Advanced)),
    ?assertEqual(Advanced, quod_atomic_admission:parent_applied(P2, #{}, Advanced)),
    %% Every dependency class shares the same invalidation predicate.
    lists:foreach(fun(Key) ->
        Changed = quod_atomic_admission:parent_applied(P2, #{Key => true}, Ready),
        {[{Id, NewTag, _, _}], Rechecking} = quod_atomic_admission:next(P2, 1, Changed),
        ?assertMatch({Id, Ref} when is_reference(Ref), NewTag),
        ?assertNotEqual(Tag, NewTag),
        ?assertEqual(stale, verdict(Tag, P1, {vote, M}, Rechecking))
    end, maps:keys(Basis)).

missing_delta_engine_change_and_deadline_never_reuse_a_selection_test() ->
    M = material(), Id = group(M), P1 = {self(), {1, <<1:256>>}},
    Q = quod_atomic_admission:admit(M, none, #{}, quod_atomic_admission:new()),
    {[{Id, Tag, _, _}], Checking} = quod_atomic_admission:next(P1, 1, Q),
    {selected, _, Ready} = quod_atomic_admission:verdict(Tag, P1, {{vote, M}, #{}}, Checking),
    lists:foreach(fun(Parent) ->
        Changed = quod_atomic_admission:parent_applied(Parent, #{}, Ready),
        ?assertMatch({[{Id, {Id, _}, M, _}], _}, quod_atomic_admission:next(Parent, 1, Changed))
    end, [{self(), {3, <<3:256>>}}, {self(), {1, <<99:256>>}}, {other_engine, {2, <<2:256>>}}]),
    ?assertMatch({[{Id, {Id, _}, M, _}], _},
        quod_atomic_admission:next(P1, deadline(M) + 1, Ready)).

application_overtaking_a_queued_verdict_requires_fresh_selection_test() ->
    M = material(), Id = group(M), P1 = {self(), {1, <<1:256>>}}, P2 = {self(), {2, <<2:256>>}},
    Q = quod_atomic_admission:admit(M, none, #{}, quod_atomic_admission:new()),
    {[{Id, Tag, _, _}], Checking} = quod_atomic_admission:next(P1, 1, Q),
    Applied = quod_atomic_admission:parent_applied(P2, #{}, Checking),
    ?assertEqual(stale, quod_atomic_admission:verdict(Tag, P1, {{vote, M}, #{}}, Applied)),
    ?assertMatch({[{Id, {Id, _}, M, _}], _}, quod_atomic_admission:next(P2, 1, Applied)),
    %% Also overtake a recheck whose row carries an older, reusable basis.
    %% That basis does not describe the evaluation still in flight.
    {selected, _, Ready} = quod_atomic_admission:verdict(Tag, P1, {{vote, M}, #{}}, Checking),
    Late = deadline(M) + 1,
    {[{Id, LateTag, _, _}], Rechecking} = quod_atomic_admission:next(P1, Late, Ready),
    Overtaken = quod_atomic_admission:parent_applied(P2, #{}, Rechecking),
    ?assertEqual(stale, quod_atomic_admission:verdict(LateTag, P1, {{vote, M}, #{}}, Overtaken)),
    ?assertMatch({[{Id, {Id, _}, M, _}], _}, quod_atomic_admission:next(P2, Late, Overtaken)).

%% These lifetime controls deliberately use an unclassified, parent-bound basis.
verdict(Tag, Parent, Result, Rows) ->
    quod_atomic_admission:verdict(Tag, Parent, {Result, #{parent => true}}, Rows).
