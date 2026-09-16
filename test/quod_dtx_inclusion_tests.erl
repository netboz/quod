-module(quod_dtx_inclusion_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% The fixture has real signed local certificates and the production history
%% reducer/index. Its foreign references are protocol fixtures, not a claim of
%% full multi-node proof admission. This scope tests exact local inclusion.
late_phase_returns_exact_reference_without_new_custody_test_() ->
    [{atom_to_list(Kind) ++ "_" ++ atom_to_list(Path), fun() -> with_target(Kind, fun(F, S) ->
        Ref = maps:get(ref, F), Control = maps:get(control, F),
        Record = quod_atomic:control_body(Control),
        {ok, Blob} = quod_atomic:encode_record(Record),
        Request = {submit, <<55:128>>, Blob},
        Ns = maps:get(ns, F), Pub = maps:get(pub, F),
        Journal = quod_simplex:test_signing_journal(S),
        Lane = {maps:get(admission, F), Pub},
        Floor = quod_signing_journal:dtx_floor(Journal, Lane),
        {Next, Response} = deliver(Path, F, Request, S),
        ?assertEqual({accepted, <<55:128>>, quod_atomic:record_digest(Record), Ref}, Response),
        ?assert(quod_dtx_endpoint:correlates(Request, Response)),
        ?assertEqual(0, maps:get(retained, quod_simplex:test_retained_dtx_state(Next))),
        ?assertNot(quod_simplex:test_dtx_drive_scheduled(Next)),
        ?assertEqual(Floor, quod_signing_journal:dtx_floor(
                            quod_simplex:test_signing_journal(Next), Lane)),
        ?assertMatch({ok, {Ns, _}, _, _}, quod_dtx:certified_ref_binding(Ref)),
        %% A distinct delivery ID must reuse the SAME exact committed phase,
        %% without a second row, signature floor advance or scheduled proposal.
        Request2 = {submit, <<56:128>>, Blob},
        {Again, Response2} = deliver(Path, F, Request2, Next),
        ?assertEqual({accepted, <<56:128>>, quod_atomic:record_digest(Record), Ref}, Response2),
        ?assert(quod_dtx_endpoint:correlates(Request2, Response2)),
        ?assertEqual(0, maps:get(retained, quod_simplex:test_retained_dtx_state(Again))),
        ?assertNot(quod_simplex:test_dtx_drive_scheduled(Again)),
        ?assertEqual(Floor, quod_signing_journal:dtx_floor(
                            quod_simplex:test_signing_journal(Again), Lane))
    end) end} || Kind <- [vote, resolve, complete], Path <- [local, remote] ].

late_relayed_vote_does_not_reenter_consensus_test() ->
    with_target(fun(F, S) ->
        Record = quod_atomic:control_body(maps:get(control, F)),
        Target = {maps:get(ns, F), maps:get(anchor, F)},
        %% A current, newly signed outer envelope for the same semantic phase
        %% passes the ordinary signature/sequence gate. Inclusion must still
        %% suppress it; this is not merely rejection of a consumed sequence.
        {ok, Material} = quod_atomic:admission_material(Record),
        {ok, Control} = quod_atomic:sign_control(
                         Target, Material, maps:get(admission, F), 3, 3, maps:get(signer, F)),
        {ok, Envelope} = quod_atomic:encode_control(Control),
        Next = quod_simplex:dispatch(maps:get(pub, F), {dtx_submit, [Envelope], []}, S),
        ?assertEqual(0, maps:get(retained, quod_simplex:test_retained_dtx_state(Next))),
        ?assertNot(quod_simplex:test_dtx_drive_scheduled(Next))
    end).

pending_vote_duplicates_share_one_signature_and_exact_resolution_test() ->
    with_target(pending_vote, fun(F, S0) ->
        Parent = self(), Record = quod_atomic:control_body(maps:get(control, F)),
        Digest = quod_atomic:record_digest(Record),
        {First, M1} = spawn_monitor(fun() -> waiter(Parent) end),
        {Second, M2} = spawn_monitor(fun() -> waiter(Parent) end),
        Lane = {maps:get(admission, F), maps:get(pub, F)},
        Floor0 = quod_signing_journal:dtx_floor(quod_simplex:test_signing_journal(S0), Lane),
        try
            %% Empty custody: this executes the real FIRST signing path,
            %% rather than seeding an already-signed retained envelope.
            ?assertEqual(0, maps:get(retained, quod_simplex:test_retained_dtx_state(S0))),
            {ok, S1} = quod_simplex:test_retain_dtx_record(Record, {dtx_endpoint, First}, S0),
            #{retained := 1, rows := #{Digest := #{envelope := Envelope}}} =
                quod_simplex:test_retained_dtx_state(S1),
            Floor1 = quod_signing_journal:dtx_floor(quod_simplex:test_signing_journal(S1), Lane),
            ?assertEqual(Floor0 + 1, Floor1),
            {ok, S2} = quod_simplex:test_retain_dtx_record(Record, {dtx_endpoint, Second}, S1),
            {ok, S3} = quod_simplex:test_retain_dtx_record(Record, {dtx_endpoint, First}, S2),
            ?assertMatch(#{retained := 1, rows := #{Digest := #{envelope := Envelope}}},
                         quod_simplex:test_retained_dtx_state(S3)),
            ?assertEqual(2, quod_simplex:test_dtx_submission_waiters(S3)),
            ?assertEqual(Floor1, quod_signing_journal:dtx_floor(
                                  quod_simplex:test_signing_journal(S3), Lane)),
            Entry = maps:get(vote_entry, F), #entry{data = Payload} = quod_ledger:entry_view(Entry),
            Done = quod_simplex:test_resolve_committed_dtx(Entry, Payload, S3),
            Ref = maps:get(vote_ref, F),
            lists:foreach(fun(Pid) ->
                receive {resolved, Pid, Reply} -> ?assertMatch({ok, Ref, [{Ref, Entry}]}, Reply)
                after 1000 -> error(missing_exact_pending_resolution) end
            end, [First, Second]),
            Again = quod_simplex:test_resolve_committed_dtx(Entry, Payload, Done),
            ?assertEqual(0, maps:get(retained, quod_simplex:test_retained_dtx_state(Again))),
            ?assertEqual(0, quod_simplex:test_dtx_submission_waiters(Again)),
            lists:foreach(fun(Pid) ->
                Tag = make_ref(), Pid ! {barrier, Tag},
                receive {waiter_barrier, Pid, Tag} -> ok after 1000 -> error(no_waiter_barrier) end
            end, [First, Second]),
            receive {resolved, _, _} -> error(duplicate_pending_resolution) after 0 -> ok end
        after
            First ! stop, Second ! stop,
            receive {'DOWN', M1, process, First, normal} -> ok end,
            receive {'DOWN', M2, process, Second, normal} -> ok end
        end
    end).

waiter(Parent) ->
    receive
        {dtx_submit_result, Reply} -> Parent ! {resolved, self(), Reply}, waiter(Parent);
        {barrier, Tag} -> Parent ! {waiter_barrier, self(), Tag}, waiter(Parent);
        stop -> ok
    end.

same_phase_different_digest_is_not_accepted_test() ->
    with_target(resolve, fun(F, S) ->
        Record = quod_atomic:control_body(maps:get(control, F)),
        %% Another generation is structurally valid but is not this group's
        %% certified Resolve. Inclusion never authenticates a different claim.
        Changed = setelement(10, Record, element(10, Record) + 1),
        ?assertMatch({ok, _}, quod_atomic:encode_record(Changed)),
        ?assertNotEqual(quod_atomic:record_digest(Record), quod_atomic:record_digest(Changed)),
        ?assertEqual({error, stale_dtx_submission},
                     quod_simplex:test_retain_dtx_record(Changed, none, S))
    end).

deliver(local, _F, Request, S) ->
    From = {self(), make_ref()},
    {ok, Started, []} = quod_simplex:test_start_local_dtx_endpoint_request(
                      Request, [], 1000, From, S),
    {Pid, Result} = worker_result(),
    {Done, [{reply, From, {ok, Response, []}}]} =
        quod_simplex:test_finish_dtx_worker(Pid, Result, Started),
    {Done, Response};
deliver(remote, F, Request, S) ->
    Ns = maps:get(ns, F), Peer = {maps:get(pub, F), {{127, 0, 0, 1}, 45678}},
    {ok, Frame} = quod_dtx_endpoint:encode_request(Ns, Request, []),
    {Started, []} = quod_simplex:test_dtx_endpoint_frame(Ns, serve, Peer, self(), Frame, S),
    {Pid, Result} = worker_result(),
    {Done, []} = quod_simplex:test_finish_dtx_worker(Pid, Result, Started),
    receive {send_ordered, ResponseFrame} ->
        {ok, Response, []} = quod_dtx_endpoint:decode_response(Ns, ResponseFrame),
        {Done, Response}
    after 1000 -> error(no_endpoint_response)
    end.

worker_result() ->
    receive
        {dtx_endpoint_worker_result, _, {submit_result, _, {error, timeout}}} ->
            error(certified_phase_was_resubmitted);
        {dtx_endpoint_worker_result, Pid, Result} -> {Pid, Result}
    after 1500 -> error(certified_phase_was_resubmitted)
    end.

with_target(Fun) ->
    with_target(vote, Fun).

with_target(Kind, Fun) ->
    isolated(fun() -> target(Kind, Fun) end).

isolated(Fun) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Result = try Fun(), ok catch C:R:St -> {raise, C, R, St} end,
        Parent ! {Ref, Result}
    end),
    receive {Ref, Result} ->
        receive {'DOWN', Mon, process, Pid, normal} -> ok end,
        case Result of ok -> ok; {raise, C, R, St} -> erlang:raise(C, R, St) end
    end.

recovery_preserves_owner_apply_progress_test_() ->
    [{atom_to_list(Role) ++ "_" ++ atom_to_list(Ack), fun() -> isolated(fun() ->
      with_recovery_target(Role, fun(F, Index, S3, View3) ->
        Group = maps:get(group_id, F), Target = {maps:get(ns, F), maps:get(anchor, F)},
        ?assertMatch(#{Group := #{blocking := true}}, apply_fences(S3)),
        BeforeCapture = case Ack of before_capture -> acknowledge(F, S3); _ -> S3 end,
        View = case Ack of
            before_capture ->
                {ok, Captured} = quod_simplex:test_local_history_view(Target, committed, BeforeCapture),
                Captured;
            _ -> View3
        end,
        #{projection := Capture} = View,
        Noop = skipped_entry(4, F),
        {ok, [Noop], P4, Delta} = quod_catchup:verify_forward(element(1, Target), element(2, Target),
            Capture, 4, [Noop], maps:get(history_index, Capture)),
        %% Real callback order: capture/verify, then exact local acknowledgement,
        %% then the real sink. No fabricated cross-recipient message ordering.
        BeforeSink = case Ack of during_verify -> acknowledge(F, BeforeCapture); _ -> BeforeCapture end,
        {S4, {ok, _}} = recovery_sink([Noop], P4, Delta, BeforeSink),
        Installed = case Ack of after_install -> acknowledge(F, S4); _ -> S4 end,
        case {Role, Ack} of
            {_, none} -> ?assertMatch(#{Group := #{blocking := true}}, apply_fences(Installed));
            {source, _} -> ?assertMatch(#{Group := #{blocking := false}}, apply_fences(Installed));
            {participant, _} -> ?assertEqual(#{}, apply_fences(Installed))
        end,
        ?assertEqual(4, element(1, quod_simplex:test_committed_store(Installed))),
        case Role of
            source -> assert_complete_verdict(F, Index, Installed, Ack);
            participant -> ok
        end
      end)
    end) end} || Role <- [source, participant], Ack <- [before_capture, during_verify, after_install, none]].

recovery_new_resolve_is_not_acknowledged_by_an_earlier_notification_test() ->
    isolated(fun() ->
        with_recovery_target(participant, 2, fun(F, _Index, S2, #{projection := Capture}) ->
            %% An ack for a not-yet-installed application is inert. Installing
            %% that new application must still close its proof fence.
            S2 = acknowledge(F, S2),
            [_, _, Resolve] = maps:get(chain, F),
            {ok, [Resolve], P3, Delta} = quod_catchup:verify_forward(maps:get(ns, F), maps:get(anchor, F),
                Capture, 3, [Resolve], maps:get(history_index, Capture)),
            {S3, {ok, _}} = recovery_sink([Resolve], P3, Delta, S2),
            Group = maps:get(group_id, F),
            ?assertMatch(#{Group := #{slot := 3, generation := 2, blocking := true}}, apply_fences(S3))
        end)
    end).

recovery_complete_does_not_restore_an_acknowledged_source_marker_test() ->
    isolated(fun() -> with_recovery_target(source, fun(F, _Index, S3, #{projection := Capture}) ->
        SApplied = acknowledge(F, S3),
        {Complete, _, _} = phase_entry({maps:get(ns, F), maps:get(anchor, F)},
            quod_atomic:control_body(maps:get(complete_control, F)), 4, F),
        {ok, [Complete], P4, Delta} = quod_catchup:verify_forward(maps:get(ns, F), maps:get(anchor, F),
            Capture, 4, [Complete], maps:get(history_index, Capture)),
        {S4, {ok, _}} = recovery_sink([Complete], P4, Delta, SApplied),
        ?assertEqual(#{}, apply_fences(S4)),
        ?assertEqual(#{}, maps:get(groups, maps:get(dtx, quod_simplex:test_state_projection(S4))))
    end) end).

assert_complete_verdict(F, Index, S, Ack) ->
    Group = maps:get(group_id, F),
    {ok, History} = quod_dtx_phase_index:history(Index, Group),
    {ok, Block} = quod_ledger:block_from_entry(maps:get(complete_entry, F)),
    Hash = quod_simplex:block_hash(Block),
    Parent = maps:get(history_head, quod_simplex:test_state_projection(S)),
    %% Exercise the actual final local check, with its two upstream valid
    %% verdicts as inputs. This is not a full foreign-admission fixture.
    Checked = quod_simplex:apply_dtx_verdict({valid, #{Group => History}},
        Block#block.payload, Block, 5, Hash, Parent, S),
    case Ack of
        none -> ?assertEqual({Hash, {invalid_transition, apply}}, quod_simplex:test_proposal_rejection(5, Checked));
        _ -> ?assertEqual({none, none}, quod_simplex:test_proposal_rejection(5, Checked))
    end.

with_recovery_target(Role, Fun) -> with_recovery_target(Role, 3, Fun).
with_recovery_target(Role, Height, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Base = quod_foreign_log_tests:prepared_then_committed_fixture(quod_foreign_log_tests:unique_ns()),
    F = case Role of source -> source_commit_fixture(Base); participant -> Base end,
    Ns = maps:get(ns, F), Anchor = maps:get(anchor, F),
    Root = quod_foreign_log_tests:temp_dir("dtx-projection-install"),
    {ok, Store} = quod_ledger_store:open(Ns, Root),
    {ok, Index} = quod_dtx_phase_index:open(Root, Ns),
    try quod_ct:with_network_identity(maps:get(network, F, <<202:256>>), fun() ->
        S0 = quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
            consensus_domain => quod_simplex:consensus_domain(Ns, Anchor),
            store => Store, phase_index => Index, sync => {pulling, self()},
            eng => quod_simplex:eng_with_certs(0, [])}),
        Prefix = lists:sublist(maps:get(chain, F), Height),
        {ok, Prefix, P, Delta} = quod_catchup:verify_forward(Ns, Anchor,
            quod_simplex:history_projection({Ns, Anchor}), 1, Prefix, Index),
        {S, {ok, View}} = recovery_sink(Prefix, P, Delta, S0),
        Fun(F, Index, S, View)
    end)
    after
        quod_dtx_phase_index:close(Index), quod_ledger_store:close(Store),
        ok = file:del_dir_r(Root)
    end.

source_commit_fixture(Base) ->
    Target = {maps:get(ns, Base), maps:get(anchor, Base)},
    Signed = quod_ct:signed_atomic_fixture(#{target => Target,
        node_identity => maps:get(signer, Base), admission => maps:get(admission, Base)}),
    Group = maps:get(group, Signed), Id = quod_atomic:group_id(Group),
    Bundles = maps:get(bundles, Signed),
    [Remote] = [T || {T, _, _, _} <- Bundles, T =/= Target],
    {ok, Vote} = quod_atomic:new_vote(Group, Target, lists:keyfind(Target, 1, Bundles), prepared),
    {VoteEntry, _, VoteRef} = phase_entry(Target, Vote, 2, Base),
    {ok, RemoteVote} = quod_atomic:new_vote(Group, Remote, lists:keyfind(Remote, 1, Bundles), prepared),
    {_, _, RemoteRef} = phase_entry(Remote, RemoteVote, 2, Base),
    Evidence = {all_prepared, lists:sort([{Target, VoteRef}, {Remote, RemoteRef}])},
    {ok, Resolve} = quod_atomic:new_resolve(Group, VoteRef, Target, commit, Evidence, VoteRef, 2),
    {ResolveEntry, _, ResolveRef} = phase_entry(Target, Resolve, 3, Base),
    {ok, RemoteResolve} = quod_atomic:new_resolve(Group, VoteRef, Remote, commit, Evidence, RemoteRef, 2),
    {_, _, RemoteResolveRef} = phase_entry(Remote, RemoteResolve, 3, Base),
    Network = maps:get(network, Signed), Committee = <<71:256>>,
    {ok, AppliedVote} = quod_applied_certificate:sign_applied_vote(
        Network, Remote, Committee, Id, RemoteResolveRef, 2, commit, maps:get(signer, Base)),
    {ok, Certificate} = quod_applied_certificate:applied_certificate(
        {Network, Remote, Committee, Id, RemoteResolveRef, 2, commit}, [AppliedVote]),
    {ok, Complete} = quod_atomic:new_complete(Group, commit,
        lists:sort([{Target, ResolveRef, 2}, {Remote, RemoteResolveRef, 2}]), [{Remote, Certificate}]),
    {CompleteEntry, CompleteControl, CompleteRef} = phase_entry(Target, Complete, 5, Base),
    Base#{chain := [hd(maps:get(chain, Base)), VoteEntry, ResolveEntry],
        group_id := Id, complete_control => CompleteControl, complete_entry => CompleteEntry,
        complete_ref => CompleteRef, network => Network}.

recovery_sink(Entries, Projection, Delta, S) ->
    From = {self(), make_ref()},
    {keep_state, Next, Actions} = quod_simplex:running({call, From},
        {sink_catchup, {recovery, self()}, Entries, Projection, Delta}, S),
    [Reply] = [R || {reply, Who, R} <- Actions, Who =:= From], {Next, Reply}.

acknowledge(F, S) ->
    case quod_simplex:running(cast, {resolve_applied, maps:get(group_id, F), 3, 2}, S) of
        {keep_state, Next} -> Next;
        {keep_state, Next, _} -> Next
    end.

apply_fences(S) -> maps:get(apply_fences, maps:get(dtx, quod_simplex:test_state_projection(S))).

skipped_entry(Slot, F) ->
    #share{sig = Sig} = quod_simplex:make_share(
        quod_simplex:consensus_domain(maps:get(ns, F), maps:get(anchor, F)),
        complaint, Slot, none, maps:get(signer, F)),
    quod_ledger:noop_entry(Slot, #cert{kind = complaint, slot = Slot, block_hash = none,
        sigs = [{maps:get(pub, F), Sig}]}).

target(Kind, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"quod:included-", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    F = phase_fixture(Kind, Ns),
    Anchor = maps:get(anchor, F), Target = {Ns, Anchor},
    Root = filename:join("/tmp", binary_to_list(Ns)),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    {ok, Index} = quod_dtx_phase_index:open(Root, Ns),
    {ok, Journal} = quod_signing_journal:initialize(Ns, Domain, Root),
    {ok, Store} = quod_ledger_store:open(Ns, Root),
    try
        P = quod_ct:with_network_identity(maps:get(network, F, <<202:256>>), fun() ->
            lists:foldl(fun(Entry, Acc) ->
                {ok, Next, _} = quod_simplex:history_advance(Target, Entry, Acc, Index), Next
            end, quod_simplex:history_projection(Target), maps:get(chain, F))
        end),
        ?assertEqual(#{}, maps:get(groups, maps:get(dtx, P))),
        Height = length(maps:get(chain, F)),
        {ok, Written} = quod_ledger_store:append(Store, maps:get(chain, F)),
        {ok, Reconciled} = quod_dtx_owner:reconcile_journal(Height, P, Index, Journal),
        Pub = maps:get(pub, F),
        S = quod_simplex:test_install_projection(P, quod_simplex:test_state(
              #{ns => Ns, genesis_hash => Anchor, self => Pub, id => maps:get(signer, F),
                slot => Height, last_applied => Height, sync => ready, prolog_ready => true,
                phase_index => Index, signing_journal => Reconciled, store => Written,
                consensus_domain => Domain, eng => quod_simplex:eng_new(Domain, [Pub], Height)})),
        quod_ct:with_network_identity(maps:get(network, F), fun() -> Fun(F, S) end)
    after
        _ = catch quod_signing_journal:close(Journal),
        ok = quod_ledger_store:close(Store),
        ok = quod_dtx_phase_index:close(Index),
        ok = file:del_dir_r(Root)
    end.

phase_fixture(vote, Ns) ->
    quod_foreign_log_tests:prepared_then_committed_fixture(Ns);
phase_fixture(pending_vote, Ns) ->
    F = quod_foreign_log_tests:prepared_then_committed_fixture(Ns),
    [Genesis, VoteEntry, _] = maps:get(chain, F),
    F#{chain := [Genesis], vote_entry => VoteEntry};
phase_fixture(resolve, Ns) ->
    F = quod_foreign_log_tests:prepared_then_committed_fixture(Ns),
    #entry{data = {batch, [{dtx, Control}]}} = quod_ledger:entry_view(lists:last(maps:get(chain, F))),
    F#{control := Control, ref := maps:get(resolve_ref, F)};
phase_fixture(complete, Ns) ->
    %% Same source reducer as recovery; the foreign certificate is signed but
    %% its committee is a fixture, not a full foreign-admission witness.
    F = source_commit_fixture(quod_foreign_log_tests:prepared_then_committed_fixture(Ns)),
    F#{chain := maps:get(chain, F) ++ [skipped_entry(4, F), maps:get(complete_entry, F)],
       control := maps:get(complete_control, F), ref := maps:get(complete_ref, F)}.

phase_entry({Ns, Anchor} = Target, Record, Slot, F) ->
    Signer = maps:get(signer, F),
    {ok, Material} = quod_atomic:admission_material(Record),
    {ok, Control} = quod_atomic:sign_control(Target, Material, maps:get(admission, F),
                                         Slot - 1, Slot - 1, Signer),
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, {batch, [{dtx, Control}]}, 0),
    Hash = quod_simplex:block_hash(Block),
    #share{sig = Sig} = quod_simplex:make_share(
        quod_simplex:consensus_domain(Ns, Anchor), commit, Slot, Hash, Signer),
    Entry = quod_ledger:entry(Block, #cert{kind = commit, slot = Slot,
                            block_hash = Hash, sigs = [{maps:get(pub, F), Sig}]}),
    {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Control),
    {Entry, Control, Ref}.
