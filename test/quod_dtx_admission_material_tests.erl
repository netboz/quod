-module(quod_dtx_admission_material_tests).
-moduledoc """
Authenticated owner material and same-turn proposal selection.

Real signed two-target proof plans and production owner callbacks; the owner
states are callback fixtures, not complete consensus nodes. Counts pin work,
not timing. The existing commit/catch-up and renewal suites pin publication.
""".
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_dtx_owner.hrl").

checked_material_preserves_exact_body_and_rejects_bad_attestation_test() ->
    [F | _] = fixtures(),
    Begin = maps:get('begin', F),
    {ok, Before} = quod_dtx:encode_record(Begin),
    {ok, {Begin, Digest, Plans}} = quod_dtx:admission_material(Begin),
    ?assertEqual(quod_dtx:record_digest(Begin), Digest),
    ?assertEqual(lists:sort(maps:get(participant_targets, F)), lists:sort(maps:keys(Plans))),
    ?assertEqual({ok, Before}, quod_dtx:encode_record(Begin)),
    {quod_dtx_begin, V, Manifest, Request, [{T, D, B, A} | Rest]} = Begin,
    Bad = {quod_dtx_begin, V, Manifest, Request,
           [{T, D, B, setelement(7, A, <<0:512>>)} | Rest]},
    ?assertEqual({error, invalid_record}, quod_dtx:admission_material(Bad)),
    ?assertEqual({error, invalid_record}, quod_dtx:admission_material(not_a_record)),
    ?assertEqual({error, invalid_record}, quod_dtx:admission_material(
                   {quod_dtx_begin, V, Manifest, Request, []})).

retained_material_cannot_be_attached_to_another_control_test() ->
    [F, Other | _] = fixtures(),
    Row = row(F),
    ?assertException(error, {badmatch, _}, quod_dtx_owner:put_new(
        Row#dtx_submission{control = maps:get(begin_control, Other)}, quod_dtx_owner:new())).

installed_projection_queries_do_not_reauthenticate_test() ->
    [F, Other | _] = fixtures(),
    Control = maps:get(begin_control, F),
    Target = maps:get(origin, F),
    P0 = quod_dtx:initial_projection(Target, 0),
    Ref = reference(Control, 2),
    {ok, _, P1, _} = quod_dtx:reduce(Control, Ref, quod_dtx:initial_group_history(), P0),
    Row = row(Other), Material = Row#dtx_submission.material,
    Registry = quod_dtx_owner:put_new(Row, quod_dtx_owner:new()),
    Binding = quod_dtx:manifest_coordinator(maps:get(manifest, F)),
    {_, Counts} = counted(fun() ->
        ?assertEqual(ready, quod_dtx:proposal_readiness(Material, P1)),
        ?assertEqual([{quod_dtx:group_id(Control), Ref}], quod_dtx:origin_recoveries(P1)),
        {Classified, []} = quod_dtx_owner:classify(P1, Registry),
        ?assertEqual(2, map_size(quod_dtx_owner:desired({ok, Binding}, P1, Classified)))
    end),
    assert_no_auth(Counts).

blocked_owner_does_no_candidate_work_test_() ->
    [{integer_to_list(N), {timeout, 30, fun() -> isolated(fun() -> blocked(N) end) end}}
     || N <- [1, 3]].

blocked(N) ->
    {ok, _} = application:ensure_all_started(gproc),
    Fs = lists:sublist(fixtures(), N), [F | _] = Fs,
    {Ns, _} = maps:get(origin, F),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        S0 = state(F),
        Retained = lists:foldl(fun(X, S) ->
            quod_simplex:test_seed_dtx_submission(maps:get(begin_control, X), [], S)
        end, S0, Fs),
        %% A signed Begin parent (not a signature-free terminal control)
        %% also proves that the barrier query does not decode its payload.
        {ok, Blob} = quod_dtx:encode_control(maps:get(begin_control, F)),
        {ok, Parent} = quod_ledger:new_block(2, 1, {batch, [{dtx, Blob}]}, 2),
        S = quod_simplex:test_blocked_dtx_owner(Parent, Retained),
        {S, Counts} = counted(fun() -> quod_simplex:test_drive_retained_dtx(S) end),
        assert_no_auth(Counts),
        ?assertEqual(0, count(quod_ledger, new_block, Counts)),
        %% Run the real callback twice, including coordinator reconciliation.
        {keep_state, Installed, _} = quod_simplex:running({timeout, batch}, {flush_batch, 0}, S),
        {{keep_state, _, _}, AllCounts} = counted(fun() ->
            quod_simplex:running({timeout, batch}, {flush_batch, 0}, Installed)
        end),
        assert_no_auth(AllCounts),
        ?assertEqual(0, count(quod_ledger, new_block, AllCounts))
    after true = gproc:unreg(quod_reg:name({quod_prolog, Ns})) end.

eligible_wave_folds_each_candidate_once_without_plan_decode_test() ->
    Fs = fixtures(), [F | _] = Fs,
    S = lists:foldl(fun(X, Acc) ->
        quod_simplex:test_seed_dtx_submission(maps:get(begin_control, X), [], Acc)
    end, state(F), lists:reverse(Fs)),
    {Selected, Counts} = counted(fun() -> quod_simplex:test_eligible_dtx_wave(S) end),
    ?assertEqual([{quod_dtx:record_digest(maps:get(begin_control, X)), maps:get('begin', X)}
                  || X <- Fs], Selected),
    ?assertEqual(0, count(quod_dtx, decode, Counts)),
    ?assertEqual(3, count(quod_dtx, begin_transition, Counts)).

unready_relay_owner_does_not_build_a_wave_test() ->
    [F | _] = fixtures(), #{pubkey := Self} = maps:get(node_identity, F),
    Peer = crypto:hash(sha256, <<"fixture relay peer">>), Vs = lists:sort([Self, Peer]),
    Slot = hd([H || H <- [2, 3], quod_simplex:leader(H, Vs) =/= Self]),
    S0 = lists:foldl(fun({K,V}, Acc) -> quod_simplex:test_state_set(K,V,Acc) end,
                    state(F), [{validators, Vs}, {slot, Slot - 1}, {approved, Slot - 1},
                               {eng, quod_simplex:eng_with_certs(Slot - 1, [])}]),
    S = quod_simplex:test_seed_dtx_submission(maps:get(begin_control, F), [], S0),
    ?assertEqual(blocked, quod_simplex:test_dtx_slot_route(Slot, S)),
    {S, Counts} = counted(fun() -> quod_simplex:test_drive_retained_dtx(S) end),
    assert_no_auth(Counts),
    ?assertEqual(0, count(quod_ledger, new_block, Counts)).

selected_block_is_not_reconstructed_for_local_proposal_test() ->
    isolated(fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        Fs = fixtures(), [F | _] = Fs, {Ns, Anchor} = maps:get(origin, F),
        true = quod_reg:reg({quod_prolog, Ns}),
        try
            S0 = quod_simplex:test_state_set(history_head, {1, Anchor}, state(F)),
            S = lists:foldl(fun(X, Acc) ->
                quod_simplex:test_seed_dtx_submission(maps:get(begin_control, X), [], Acc)
            end, S0, Fs),
            {Next, Counts} = counted(fun() -> quod_simplex:test_drive_retained_dtx(S) end),
            ?assertEqual(1, maps:get(proposals, quod_simplex:stats_map(Next))),
            %% Canonical size/frame checks still build each growing candidate.
            %% The final accepted block is reused, not built for a fourth time.
            ?assertEqual(3, count(quod_ledger, new_block, Counts))
        after true = gproc:unreg(quod_reg:name({quod_prolog, Ns})) end
    end).

preview_and_certified_reducer_produce_the_same_projection_test() ->
    Fs = fixtures(), [F | _] = Fs, Target = maps:get(origin, F),
    P0 = quod_dtx:initial_projection(Target, 0),
    Candidates = [begin C = maps:get(begin_control, X), {ok, M} = quod_dtx:admission_material(
        quod_dtx:control_body(C)), {C, M, Target, 2, <<19:256>>} end || X <- Fs],
    {ok, Histories, Projection, Items} = quod_dtx:preview_batch(Candidates, #{}, P0),
    ?assertEqual({ok, Histories, Projection, Items}, quod_dtx:reduce_batch(
        [{maps:get(control, I), maps:get(ref, I)} || I <- Items], #{}, P0)),
    [{C, M, T, H, B}, {_, OtherMaterial, _, _, _} | _] = Candidates,
    ?assertMatch({error, _}, quod_dtx:preview_batch([{C, OtherMaterial, T, H, B}], #{}, P0)),
    ?assertMatch({error, _}, quod_dtx:preview_batch([{C, M, {<<"wrong">>, <<0:256>>}, H, B}], #{}, P0)).

fixtures() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    [begin
        F = quod_ct:signed_dtx_begin_fixture(#{node_identity => Signer,
            target => {<<"quod:material-owner">>, <<32:256>>}, proof_id => <<I:256>>,
            goal_text => Goal}),
        {ok, C} = quod_dtx:sign_control(maps:get(origin, F), maps:get('begin', F),
            maps:get(admission, F), I, I, Signer),
        F#{begin_control := C}
    end || {I, Goal} <- [{1, <<"assertz(material_a(1)).">>},
                        {2, <<"assertz(material_b(1)).">>},
                        {3, <<"assertz(material_c(1)).">>}]].

state(F) ->
    {Ns, Anchor} = maps:get(origin, F), #{pubkey := Pub} = maps:get(node_identity, F),
    quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor, self => Pub,
        id => maps:get(node_identity, F), validators => [Pub], slot => 1, approved => 1,
        author_admissions => #{Pub => maps:get(admission, F)},
        committee_id => <<18:256>>, sync => ready, prolog_ready => true,
        dtx_projection => quod_dtx:initial_projection(maps:get(origin, F), 0),
        eng => quod_simplex:eng_with_certs(1, [])}).

row(F) ->
    C = maps:get(begin_control, F), {ok, Envelope} = quod_dtx:encode_control(C),
    {ok, M = {_, D, _}} = quod_dtx:admission_material(quod_dtx:control_body(C)),
    #dtx_submission{material = M, control = C, envelope = Envelope,
        group_id = quod_dtx:group_id(C), digest = D, inserted_at = 0,
        observation_started_at = 0, placement = ready, bytes = byte_size(Envelope)}.

reference(C, H) ->
    {Ns, Anchor} = quod_dtx:control_target(C),
    {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, H, <<19:256>>,
        quod_dtx:record_digest(C), <<"fixture-certified-reference">>), Ref.

counted(Fun) ->
    [{module, M} = code:ensure_loaded(M) || M <- [quod_identity, quod_dtx, quod_ledger]],
    {{Result, Owner}, {call_time, Rows}} = tprof:profile(fun() -> {Fun(), self()} end,
        #{type => call_time, report => return, set_on_spawn => false,
        pattern => [{quod_identity, verify, 3}, {quod_dtx, decode, 1},
                    {quod_dtx, begin_transition, 6}, {quod_ledger, new_block, 4}]}),
    %% call_count is VM-global; call_time retains per-process call counts.
    %% Ignore elapsed time and other processes, including fixture cleanup.
    {Result, [{{M, F}, lists:sum([N || {Pid, N, _} <- Ps, Pid =:= Owner])}
              || {M, F, _, Ps} <- Rows]}.
count(M, F, Counts) -> proplists:get_value({M, F}, Counts, 0).
assert_no_auth(Counts) ->
    ?assertEqual(0, count(quod_identity, verify, Counts)),
    ?assertEqual(0, count(quod_dtx, decode, Counts)).

isolated(Fun) ->
    Caller = self(), Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Result = try Fun(), ok catch C:R:S -> {raise, C, R, S} end,
        Caller ! {Ref, Result}
    end),
    receive {Ref, Result} ->
        receive {'DOWN', Monitor, process, Pid, normal} -> ok end,
        case Result of ok -> ok; {raise, C, R, S} -> erlang:raise(C, R, S) end
    end.
