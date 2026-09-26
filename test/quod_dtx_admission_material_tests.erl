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
-include_lib("opentelemetry/include/otel_span.hrl").

candidate_preview_rejection_keeps_owned_vote_for_reselection_test() ->
  isolated(fun() ->
    [F | _] = fixtures(), C = maps:get(vote_control, F),
    Payload = {batch, [{dtx, C}]},
    {_, Anchor} = Target = maps:get(origin, F),
    Era = quod_ledger:initial_era(Target),
    {ok, Block} = quod_ledger:new_block({Era, 1}, {Era, 0, Anchor}, Payload, 0),
    Hash = quod_simplex:block_hash(Block), Parent = {1, <<17:256>>},
    S = quod_simplex:test_state_set(history_head, Parent,
        quod_simplex:test_state_set(validators, [], state(F))),
    Retained = quod_simplex:test_seed_dtx_submission(C, [{dtx_endpoint, self()}], S),
    {Monitor, Validating} = quod_simplex:test_latch_dtx_validation(
        1, Hash, Parent, self(), Block, Retained),
    %% There is no second material decoder to diverge from ingress. Exercise
    %% the actual preview refusal instead: a same-group negative vote already
    %% occupies the parent. Rejection cannot discard accepted own work.
    {ok, Negative} = quod_atomic:select_vote(quod_atomic:control_material(C),
                                           {refused, [vote_deadline]}),
    {ok, N} = quod_atomic:sign_control(maps:get(origin, F), Negative,
                    maps:get(admission, F), 2, 1, maps:get(node_identity, F)),
    {ok, H, P, _} = quod_atomic:reduce(N, reference(N, 2),
        quod_atomic:initial_group_history(), quod_atomic:initial_projection(maps:get(origin, F), 0)),
    Bound = quod_simplex:test_state_set(dtx_projection, P, Validating),
    try
        Done = quod_simplex:test_on_dtx_verdict(1, Hash, Parent, self(), 1,
                      {valid, #{quod_atomic:group_id(C) => H}}, Bound),
        ?assertMatch({none, none, none, none, _}, quod_simplex:test_dtx_round(1, Done)),
        ?assertEqual(0, maps:get(submissions, quod_simplex:test_dtx_endpoint_counts(Done))),
        ?assertMatch(#{active := 1, reserved := 0}, quod_simplex:test_dtx_admission_state(Done)),
        receive {dtx_submit_result, _} -> error(accepted_vote_lost_on_preview_rejection)
        after 0 -> ok end
    after erlang:demonitor(Monitor, [flush]) end
  end).

submit_admission_is_keyed_on_the_existing_owner_turn_test() ->
    isolated(fun() -> quod_trace_tests:with_tracer(fun() ->
        [F | _] = fixtures(), Vote = maps:get(vote, F), {Ns, _} = maps:get(origin, F),
        {ok, Blob} = quod_atomic:encode_record(Vote),
        S = quod_simplex:test_seed_dtx_submission(maps:get(vote_control, F), [], state(F)),
        %% An exact retained submission uses the real endpoint without another
        %% signature. The only spawned process is its existing reply waiter.
        {ok, Next, []} = quod_trace:with_owner_turn(#{'quod.namespace' => Ns}, fun() ->
            quod_simplex:test_start_local_dtx_endpoint_request(
              {submit, <<17:128>>, Blob}, [], 5000, {self(), make_ref()}, S)
        end),
        try
            Span = quod_trace_tests:take_span(<<"quod.consensus.owner_turn">>),
            [Event = #event{name = <<"consensus.control_admission_decoded">>}] =
                otel_events:list(Span#span.events),
            Attributes = otel_attributes:map(Event#event.attributes),
            ?assertEqual(#{'quod.dtx.record_digest' =>
                <<"hex:", (binary:encode_hex(quod_atomic:record_digest(Vote), lowercase))/binary>>,
                'quod.dtx.phase' => <<"vote">>}, Attributes),
            ?assert(Event#event.system_time_native >= Span#span.start_time),
            ?assert(Event#event.system_time_native =< Span#span.end_time)
        after quod_simplex:test_close_dtx_endpoint(Next) end
    end) end).

relayed_vote_validation_carries_owner_context_on_existing_cast_test() ->
    isolated(fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        quod_trace_tests:with_tracer(fun() ->
            [F | _] = fixtures(), {Ns, Anchor} = maps:get(origin, F),
            S = quod_simplex:test_state_set(history_head, {1, Anchor}, state(F)),
            true = quod_reg:reg({quod_prolog, Ns}),
            try
                _ = quod_trace:with_owner_turn(#{'quod.namespace' => Ns}, fun() ->
                    quod_simplex:test_propose_dtx_wave(2, [vote_blob(F)], [], S)
                end),
                Span = quod_trace_tests:take_span(<<"quod.consensus.owner_turn">>),
                receive
                    {'$gen_cast', {dtx_verdict_req, {wave, [_]}, _, 2, _, {2, _, {1, Anchor}}, Ctx}} ->
                        Parent = otel_tracer:current_span_ctx(Ctx),
                        ?assertEqual(Span#span.trace_id, otel_span:trace_id(Parent)),
                        ?assertEqual(Span#span.span_id, otel_span:span_id(Parent))
                after 1000 -> error(parent_request_missing) end
            after true = gproc:unreg(quod_reg:name({quod_prolog, Ns})) end
        end)
    end).

checked_material_preserves_exact_body_and_rejects_bad_attestation_test() ->
    [F | _] = fixtures(),
    Vote = maps:get(vote, F),
    {ok, Before} = quod_atomic:encode_record(Vote),
    {ok, {Vote, Digest, #{plans := Plans}}} = quod_atomic:admission_material(Vote),
    ?assertEqual(quod_atomic:record_digest(Vote), Digest),
    ?assertEqual([maps:get(origin, F)], maps:keys(Plans)),
    ?assertEqual({ok, Before}, quod_atomic:encode_record(Vote)),
    {quod_dtx_vote, V, Group, T, {T, D, B, A}, prepared} = Vote,
    Bad = {quod_dtx_vote, V, Group, T, {T, D, B, setelement(7, A, <<0:512>>)}, prepared},
    ?assertEqual(error, quod_atomic:admission_material(Bad)),
    ?assertEqual(error, quod_atomic:admission_material(not_a_record)),
    ?assertEqual(error, quod_atomic:admission_material(
                   {quod_dtx_vote, V, Group, T, none, prepared})).

retained_material_cannot_be_attached_to_another_control_test() ->
    [F, Other | _] = fixtures(),
    Row = row(F),
    ?assertException(error, {badmatch, _}, quod_dtx_owner:put_new(
        Row#dtx_submission{control = maps:get(vote_control, Other)}, quod_dtx_owner:new())).

installed_projection_queries_do_not_reauthenticate_test() ->
    [F, Other | _] = fixtures(),
    Control = maps:get(vote_control, F),
    Target = maps:get(origin, F),
    P0 = quod_atomic:initial_projection(Target, 0),
    Ref = reference(Control, 2),
    {ok, _, P1, _} = quod_atomic:reduce(Control, Ref, quod_atomic:initial_group_history(), P0),
    Row = row(Other), Material = quod_atomic:control_material(Row#dtx_submission.control),
    Registry = quod_dtx_owner:put_new(Row, quod_dtx_owner:new()),
    Binding = quod_dtx:manifest_coordinator(maps:get(manifest, F)),
    {_, Counts} = counted(fun() ->
        ?assertEqual(ready, quod_atomic:proposal_readiness(Material, P1)),
        ?assertMatch(#{material := _, ref := Ref, resolution := none},
          maps:get(quod_atomic:group_id(Control), quod_atomic:recovery_rows(P1, 0))),
        {Classified, []} = quod_dtx_owner:classify(P1,
            fun(M) -> quod_dtx_owner:admission(M, quod_atomic:initial_group_history(), P1) end,
            Registry),
        ?assertEqual(1, quod_dtx_owner:count(Classified)),
        ?assertEqual(2, map_size(quod_dtx_owner:desired({ok, Binding}, P1, [Material], 0)))
    end),
    assert_no_auth(Counts).

blocked_owner_does_no_candidate_work_test_() ->
    [{integer_to_list(N), {timeout, 30, fun() -> isolated(fun() -> blocked(N) end) end}}
     || N <- [1, 3]].

queued_blocked_intent_does_no_authentication_on_progress_test_() ->
    {timeout, 30, fun() -> isolated(fun queued_blocked_intent/0) end}.

queued_blocked_intent() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_ct:signed_atomic_fixture(#{}),
    Target = {Ns, Anchor} = maps:get(origin, F),
    Other = quod_ct:signed_atomic_fixture(#{target => Target,
        node_identity => maps:get(node_identity, F), admission => maps:get(admission, F),
        key_pair => maps:get(key_pair, F), proof_id => <<401:256>>,
        operation_id => <<402:256>>, submitted_at => 2}),
    [Waiter, Holder] = lists:sort(fun(X, Y) ->
        quod_atomic:group_id(maps:get(vote, X)) < quod_atomic:group_id(maps:get(vote, Y))
    end, [F, Other]),
    Control = maps:get(vote_control, Holder),
    %% Real signatures and reducer; structural reference, not consensus admission.
    {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, 2, <<9:256>>,
        quod_atomic:record_digest(Control), quod_ct:fixture_finality(1, <<9:256>>)),
    {ok, _, Locked, _} = quod_atomic:reduce(Control, Ref,
        quod_atomic:initial_group_history(), quod_atomic:initial_projection(Target, 0)),
    {ok, Material} = quod_atomic:admission_material(maps:get(vote, Waiter)),
    {ok, Group} = quod_atomic:source_group_ref(Material),
    Dir = filename:join("/tmp", "quod-queued-intent-" ++
                         binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Journal} = quod_signing_journal:initialize(Ns, <<31:256>>, Dir),
    S0 = quod_simplex:test_state_set(signing_journal, Journal,
         quod_simplex:test_state_set(history_head, {1, Anchor},
         quod_simplex:test_state_set(dtx_projection, Locked, state(F)))),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        Intent = make_ref(), From = {self(), make_ref()}, Deadline = quod_time:mono_ms() + 20000,
        {ok, Reserved} = quod_simplex:test_enqueue_dtx_intent(
            From, self(), Intent, Material, Group, Deadline, S0),
        ?assertMatch(#{active := 0, reserved := 1},
                     quod_simplex:test_dtx_admission_state(Reserved)),
        Active = quod_simplex:test_activate_dtx_intent(self(), Intent, Reserved),
        {Selecting, []} = quod_simplex:test_progress_dtx_admission(Active),
        Tag = receive
            {'$gen_cast', {dtx_verdict_req, {vote, Material}, _, 2, _, T, _}} -> T
        after 1000 -> error(missing_vote_selection_request) end,
        {keep_state, Queued, _} = quod_simplex:running(info,
            {dtx_verdict, Tag, self(), 1, abstain}, Selecting),
        ?assertMatch(#{active := 1, reserved := 0},
                     quod_simplex:test_dtx_admission_state(Queued)),
        lists:foreach(fun(Sync) ->
            S = quod_simplex:test_state_set(sync, Sync, Queued),
            {ok, Counts} = counted(fun() -> lists:foreach(fun(_) ->
                ?assertEqual({S, []}, quod_simplex:test_progress_dtx_admission(S))
            end, lists:seq(1, 4)) end),
            assert_no_auth(Counts)
        end, [ready, unconfirmed]),
        %% The full installed callback includes both the FIFO and retained owner.
        Era = quod_ledger:initial_era(Target),
        {ok, Parent} = quod_ledger:new_block({Era, 1}, {Era, 0, Anchor},
                                           {batch, [{dtx, Control}]}, 2),
        Blocked = quod_simplex:test_blocked_dtx_owner(Parent, Queued),
        {keep_state, Installed, _} = quod_simplex:running({timeout, batch}, {flush_batch, 0}, Blocked),
        {{keep_state, Next, _}, Counts} = counted(fun() ->
            quod_simplex:running({timeout, batch}, {flush_batch, 0}, Installed)
        end),
        assert_no_auth(Counts),
        ?assertEqual(0, count(quod_ledger, new_block, Counts)),
        ?assertEqual(quod_simplex:test_dtx_admission_state(Queued),
                     quod_simplex:test_dtx_admission_state(Next)),
        receive {'$gen_cast', {dtx_verdict_req, _, _, _, _, _, _}} ->
            error(repeated_selection_without_parent_or_deadline_progress)
        after 0 -> ok end,
        %% Readiness cannot erase accepted work, nor can a late caller cancel.
        %% Installed membership-loss release has its own production-callback
        %% coverage in quod_atomic_projection_tests.
        ?assertEqual(Queued, quod_simplex:test_cancel_dtx_intent(self(), Intent, Queued))
    after
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        ok = quod_signing_journal:close(Journal),
        ok = file:del_dir_r(Dir)
    end.

vote_blob(F) ->
    {ok, Blob} = quod_atomic:encode_control(maps:get(vote_control, F)), Blob.

blocked(N) ->
    {ok, _} = application:ensure_all_started(gproc),
    Fs = lists:sublist(fixtures(), N), [F | _] = Fs,
    {Ns, _} = maps:get(origin, F),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        S0 = state(F),
        Retained = lists:foldl(fun(X, S) ->
            quod_simplex:test_seed_dtx_submission(maps:get(vote_control, X), [], S)
        end, S0, Fs),
        %% A signed Vote parent (not a signature-free terminal control)
        %% also proves that the barrier query does not decode its payload.
        {_, Anchor} = Target = maps:get(origin, F),
        Era = quod_ledger:initial_era(Target),
        {ok, Parent} = quod_ledger:new_block({Era, 1}, {Era, 0, Anchor},
            {batch, [{dtx, maps:get(vote_control, F)}]}, 2),
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
        quod_simplex:test_seed_dtx_submission(maps:get(vote_control, X), [], Acc)
    end, state(F), lists:reverse(Fs)),
    {Selected, Counts} = counted(fun() -> quod_simplex:test_eligible_dtx_wave(S) end),
    ?assertEqual([{quod_atomic:record_digest(maps:get(vote_control, X)), maps:get(vote, X)}
                  || X <- Fs], Selected),
    ?assertEqual(0, count(quod_dtx, decode, Counts)),
    ?assertEqual(3, count(quod_atomic, transition, Counts)).

unready_relay_owner_does_not_build_a_wave_test() ->
    [F | _] = fixtures(), #{pubkey := Self} = maps:get(node_identity, F),
    Peer = crypto:hash(sha256, <<"fixture relay peer">>), Vs = lists:sort([Self, Peer]),
    Slot = hd([H || H <- [2, 3], quod_simplex:leader(H, Vs) =/= Self]),
    S0 = lists:foldl(fun({K,V}, Acc) -> quod_simplex:test_state_set(K,V,Acc) end,
                    state(F), [{validators, Vs}, {slot, 1},
                               {eng, engine(F, Vs, Slot - 1)}]),
    S = quod_simplex:test_seed_dtx_submission(maps:get(vote_control, F), [], S0),
    ?assertEqual(blocked, quod_simplex:test_dtx_slot_route(Slot, S)),
    {S, Counts} = counted(fun() -> quod_simplex:test_drive_retained_dtx(S) end),
    assert_no_auth(Counts),
    ?assertEqual(0, count(quod_ledger, new_block, Counts)).

%% A placed reliable relay is waiting for consensus, not another candidate
%% construction. Count the real driver before and after actual link delivery;
%% a send-trace notification is deliberately not used as a mailbox barrier.
placed_relay_does_no_candidate_work_test_() ->
    [fun() -> isolated(fun() -> relay_work_case(N) end) end || N <- [1, 3]].

relay_work_case(N) ->
    Fs = fixtures(), [F | _] = Fs, #{pubkey := Self} = maps:get(node_identity, F),
    Peer = crypto:hash(sha256, <<"retained relay work peer">>),
    Vs = lists:sort([Self, Peer]),
    Slot = hd([H || H <- [2, 3], quod_simplex:leader(H, Vs) =:= Peer]),
    Link = spawn(fun() -> relay_frames([]) end),
    Replacement = spawn(fun() -> relay_frames([]) end),
    try
        S0 = lists:foldl(fun({K,V}, S) -> quod_simplex:test_state_set(K,V,S) end,
            state(F), [{validators, Vs}, {slot, 1},
              {eng, engine(F, Vs, Slot - 1)},
              {conns, #{Peer => {Link, make_ref()}}},
              {inbound_conns, #{Peer => {Link, make_ref()}}},
              {peer_readiness, #{Peer => {Link, Slot - 1, true, quod_time:mono_ms()}}}]),
        S = lists:foldl(fun(X, Acc) -> quod_simplex:test_seed_dtx_submission(
            maps:get(vote_control, X), [], Acc) end, S0, lists:sublist(Fs,N)),
        {{Placed, [Frame]}, FirstCounts} = counted(fun() ->
            Next = quod_simplex:test_drive_retained_dtx(S),
            {Next, read_relay_frames(Link)}
        end),
        ?assertEqual(N, count(quod_ledger, new_block, FirstCounts)),
        {Placed, RepeatCounts} = counted(fun() ->
            Placed = quod_simplex:test_drive_retained_dtx(Placed),
            Placed = quod_simplex:test_drive_retained_dtx(Placed),
            ?assertEqual([Frame], read_relay_frames(Link)),
            Placed
        end),
        ?assertEqual(0, count(quod_atomic, transition, RepeatCounts)),
        ?assertEqual(0, count(quod_ledger, new_block, RepeatCounts)),
        assert_no_auth(RepeatCounts),
        Reconnected = quod_simplex:test_state_set(
            conns, #{Peer => {Replacement, make_ref()}}, Placed),
        {{Again, [Frame]}, ReconnectCounts} = counted(fun() ->
            Next = quod_simplex:test_drive_retained_dtx(Reconnected),
            {Next, read_relay_frames(Replacement)}
        end),
        ?assertEqual(N, count(quod_ledger, new_block, ReconnectCounts)),
        {Again, FinalCounts} = counted(fun() -> quod_simplex:test_drive_retained_dtx(Again) end),
        ?assertEqual(0, count(quod_ledger, new_block, FinalCounts)),
        case N of
            1 ->
                New = tl(Fs),
                Added = lists:foldl(fun(X, Acc) -> quod_simplex:test_seed_dtx_submission(
                    maps:get(vote_control, X), [], Acc) end, Again, New),
                {{_, [Frame, NewFrame]}, NewCounts} = counted(fun() ->
                    Next = quod_simplex:test_drive_retained_dtx(Added),
                    {Next, read_relay_frames(Replacement)}
                end),
                %% Work eligibility must not trim the canonical selection fold.
                %% It still checks all three rows, but transmits only the two new ones.
                ?assertEqual(3, count(quod_ledger, new_block, NewCounts)),
                ?assertEqual(quod_simplex:encode(element(1,maps:get(origin,F)),
                    {dtx_submit, [vote_blob(X) || X <- New], []}), NewFrame);
            3 -> ok
        end
    after Link ! stop, Replacement ! stop end.

relay_frames(Frames) ->
    receive
        {send_ordered, Frame} -> relay_frames([Frame | Frames]);
        {read_frames, From, Ref} ->
            From ! {Ref, lists:reverse(Frames)}, relay_frames(Frames);
        stop -> ok
    end.

read_relay_frames(Link) ->
    Ref = make_ref(), Link ! {read_frames, self(), Ref},
    receive {Ref, Frames} -> Frames after 1000 -> error(relay_delivery_barrier_timeout) end.

selected_block_is_not_reconstructed_for_local_proposal_test() ->
    isolated(fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        Fs = fixtures(), [F | _] = Fs, {Ns, Anchor} = maps:get(origin, F),
        true = quod_reg:reg({quod_prolog, Ns}),
        try
            S0 = quod_simplex:test_state_set(history_head, {1, Anchor}, state(F)),
            S = lists:foldl(fun(X, Acc) ->
                quod_simplex:test_seed_dtx_submission(maps:get(vote_control, X), [], Acc)
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
    P0 = quod_atomic:initial_projection(Target, 0),
    Candidates = [{maps:get(vote_control, X), Target, 2, <<19:256>>} || X <- Fs],
    {ok, Histories, Projection, Items} = quod_atomic:preview_batch(Candidates, #{}, P0),
    ?assertMatch({error, {invalid_transition, bad_binding}}, quod_atomic:reduce_batch(
        [{maps:get(control, I), maps:get(ref, I)} || I <- Items], #{}, P0)),
    References = maps:from_list([{maps:get(ref, I), reference(maps:get(control, I), 2)}
                                || I <- Items]),
    Bind = fun Walk(Term) ->
        case maps:find(Term, References) of
            {ok, Ref} -> Ref;
            error when is_map(Term) -> maps:map(fun(_, V) -> Walk(V) end, Term);
            error when is_list(Term) -> [Walk(V) || V <- Term];
            error when is_tuple(Term) -> list_to_tuple([Walk(V) || V <- tuple_to_list(Term)]);
            error -> Term
        end
    end,
    ?assertEqual(Bind({ok, Histories, Projection, Items}), quod_atomic:reduce_batch(
        [{maps:get(control, I), reference(maps:get(control, I), 2)} || I <- Items], #{}, P0)),
    [{C, _T, H, B} | _] = Candidates,
    %% One control owns its material; the old five-field candidate carrying
    %% an independently replaceable second copy is not a current input.
    ?assertMatch({error, _}, quod_atomic:preview_batch(
        [{C, quod_atomic:control_material(C), Target, H, B}], #{}, P0)),
    ?assertMatch({error, _}, quod_atomic:preview_batch([{C, {<<"wrong">>, <<0:256>>}, H, B}], #{}, P0)).

fixtures() ->
    {ok, _} = application:ensure_all_started(gproc),
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    [begin
        F = quod_ct:signed_atomic_fixture(#{node_identity => Signer,
            target => {<<"quod:material-owner">>, <<32:256>>}, proof_id => <<I:256>>,
            goal_text => Goal}),
        {ok, M} = quod_atomic:admission_material(maps:get(vote, F)),
        {ok, C} = quod_atomic:sign_control(maps:get(origin, F), M,
            maps:get(admission, F), I, I, Signer),
        F#{vote_control := C}
    end || {I, Goal} <- [{1, <<"assertz(material_a(1)).">>},
                        {2, <<"assertz(material_b(1)).">>},
                        {3, <<"assertz(material_c(1)).">>}]].

engine(F, Validators, View) ->
    Identity = {Ns, Anchor} = maps:get(origin, F),
    quod_simplex:eng_new(quod_simplex:consensus_domain(Ns, Anchor), Validators,
        {{quod_ledger:initial_era(Identity), View, Anchor}, 0}).

state(F) ->
    {Ns, Anchor} = maps:get(origin, F), #{pubkey := Pub} = maps:get(node_identity, F),
    quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor, self => Pub,
        id => maps:get(node_identity, F), validators => [Pub], slot => 1, history_head => {1, Anchor},
        author_admissions => #{Pub => maps:get(admission, F)},
        committee_id => <<18:256>>, sync => ready, prolog_ready => true,
        dtx_projection => quod_atomic:initial_projection(maps:get(origin, F), 0),
        eng => engine(F, [Pub], 0)}).

row(F) ->
    C = maps:get(vote_control, F), {ok, Envelope} = quod_atomic:encode_control(C),
    {_, D, _} = quod_atomic:control_material(C),
    #dtx_submission{control = C, envelope = Envelope,
        group_id = quod_atomic:group_id(C), digest = D, inserted_at = 0,
        observation_started_at = 0, placement = ready, bytes = byte_size(Envelope)}.

reference(C, H) ->
    {Ns, Anchor} = quod_atomic:control_target(C),
    {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, H, <<19:256>>,
        quod_atomic:record_digest(C), quod_ct:fixture_finality(1, <<19:256>>)), Ref.

counted(Fun) ->
    [{module, M} = code:ensure_loaded(M) || M <- [quod_identity, quod_dtx, quod_atomic, quod_ledger]],
    {{Result, Owner}, {call_time, Rows}} = tprof:profile(fun() -> {Fun(), self()} end,
        #{type => call_time, report => return, set_on_spawn => false,
        pattern => [{quod_identity, verify, 3}, {quod_dtx, decode, 1},
                    {quod_atomic, transition, 6}, {quod_ledger, new_block, 4}]}),
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
