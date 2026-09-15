-module(quod_dtx_inclusion_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% The fixture has real signed local certificates and the production history
%% reducer/index. Its foreign references are protocol fixtures, not a claim of
%% full multi-node proof admission. This scope tests exact local inclusion.
late_phase_returns_exact_reference_without_new_custody_test_() ->
    [{atom_to_list(Kind) ++ "_" ++ atom_to_list(Path), fun() -> with_target(Kind, fun(F, S) ->
        Ref = maps:get(ref, F), Control = maps:get(control, F),
        Record = quod_dtx:control_body(Control),
        {ok, Blob} = quod_dtx:encode_record(Record),
        Request = {submit, <<55:128>>, Blob},
        Ns = maps:get(ns, F), Pub = maps:get(pub, F),
        Journal = quod_simplex:test_signing_journal(S),
        Lane = {maps:get(admission, F), Pub},
        Floor = quod_signing_journal:dtx_floor(Journal, Lane),
        {Next, Response} = deliver(Path, F, Request, S),
        ?assertEqual({accepted, <<55:128>>, quod_dtx:record_digest(Record), Ref}, Response),
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
        ?assertEqual({accepted, <<56:128>>, quod_dtx:record_digest(Record), Ref}, Response2),
        ?assert(quod_dtx_endpoint:correlates(Request2, Response2)),
        ?assertEqual(0, maps:get(retained, quod_simplex:test_retained_dtx_state(Again))),
        ?assertNot(quod_simplex:test_dtx_drive_scheduled(Again)),
        ?assertEqual(Floor, quod_signing_journal:dtx_floor(
                            quod_simplex:test_signing_journal(Again), Lane))
    end) end} || Kind <- [prepare, decision, finalize, complete], Path <- [local, remote] ].

late_relayed_prepare_does_not_reenter_consensus_test() ->
    with_target(fun(F, S) ->
        Record = quod_dtx:control_body(maps:get(control, F)),
        Target = {maps:get(ns, F), maps:get(anchor, F)},
        %% A current, newly signed outer envelope for the same semantic phase
        %% passes the ordinary signature/sequence gate. Inclusion must still
        %% suppress it; this is not merely rejection of a consumed sequence.
        {ok, Control} = quod_dtx:sign_control(
                         Target, Record, maps:get(admission, F), 3, 3, maps:get(signer, F)),
        {ok, Envelope} = quod_dtx:encode_control(Control),
        Next = quod_simplex:dispatch(maps:get(pub, F), {dtx_submit, [Envelope], []}, S),
        ?assertEqual(0, maps:get(retained, quod_simplex:test_retained_dtx_state(Next))),
        ?assertNot(quod_simplex:test_dtx_drive_scheduled(Next))
    end).

pending_prepare_duplicates_share_one_signature_and_exact_resolution_test() ->
    with_target(pending_prepare, fun(F, S0) ->
        Parent = self(), Record = quod_dtx:control_body(maps:get(control, F)),
        Digest = quod_dtx:record_digest(Record),
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
            Entry = maps:get(prepare_entry, F), #entry{data = Payload} = quod_ledger:entry_view(Entry),
            Done = quod_simplex:test_resolve_committed_dtx(Entry, Payload, S3),
            Ref = maps:get(prepare_ref, F),
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
    with_target(fun(F, S) ->
        Record = quod_dtx:control_body(maps:get(control, F)),
        %% A changed manifest nonce is still a well-shaped request, but is
        %% not the record certified by this target's existing Prepare.
        Changed = setelement(5, Record, setelement(5, element(5, Record), <<127:256>>)),
        ?assertMatch({ok, _}, quod_dtx:encode_record(Changed)),
        ?assertNotEqual(quod_dtx:record_digest(Record), quod_dtx:record_digest(Changed)),
        ?assertEqual({error, stale_dtx_submission},
                     quod_simplex:test_retain_dtx_record(Changed, none, S))
    end).

deliver(local, _F, Request, S) ->
    From = {self(), make_ref()},
    {ok, Started} = quod_simplex:test_start_local_dtx_endpoint_request(
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
    with_target(prepare, Fun).

with_target(Kind, Fun) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Result = try target(Kind, Fun), ok catch C:R:St -> {raise, C, R, St} end,
        Parent ! {Ref, Result}
    end),
    receive {Ref, Result} ->
        receive {'DOWN', Mon, process, Pid, normal} -> ok end,
        case Result of ok -> ok; {raise, C, R, St} -> erlang:raise(C, R, St) end
    end.

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
        Fun(F, S)
    after
        _ = catch quod_signing_journal:close(Journal),
        ok = quod_ledger_store:close(Store),
        ok = quod_dtx_phase_index:close(Index),
        ok = file:del_dir_r(Root)
    end.

phase_fixture(prepare, Ns) ->
    quod_foreign_log_tests:prepared_then_committed_fixture(Ns);
phase_fixture(pending_prepare, Ns) ->
    F = quod_foreign_log_tests:prepared_then_committed_fixture(Ns),
    [Genesis, PrepareEntry, _] = maps:get(chain, F),
    F#{chain := [Genesis], prepare_entry => PrepareEntry};
phase_fixture(finalize, Ns) ->
    F = quod_foreign_log_tests:prepared_then_committed_fixture(Ns),
    #entry{data = {batch, [{dtx, Envelope}]}} = quod_ledger:entry_view(lists:last(maps:get(chain, F))),
    {ok, Control} = quod_dtx:decode_control(Envelope),
    F#{control := Control, ref := maps:get(finalize_ref, F)};
phase_fixture(Kind, Ns) when Kind =:= decision; Kind =:= complete ->
    %% Reuse the signed genesis/committee fixture. The local Begin -> Decision
    %% -> Complete chain goes through the actual history reducer and index;
    %% foreign references retain the same explicit fixture-only scope above.
    Base = quod_foreign_log_tests:prepared_then_committed_fixture(Ns),
    Target = {Ns, maps:get(anchor, Base)},
    Signed = quod_ct:signed_dtx_begin_fixture(#{target => Target,
        node_identity => maps:get(signer, Base), admission => maps:get(admission, Base)}),
    Begin = maps:get('begin', Signed), Group = quod_dtx:group_id(Begin),
    {BeginEntry, _, BeginRef} = phase_entry(Target, Begin, 2, Base),
    {ok, Target, Group, Plans} = quod_dtx:begin_recovery_rows(Begin),
    [Remote] = [T || {T, _} <- Plans, T =/= Target],
    Reasons = [{prepare_refused, {ontology, element(1, Remote), element(2, Remote)}}],
    {ok, Decision} = quod_dtx:new_decision(Group, BeginRef, {abort, Reasons}, [{Target, BeginRef}]),
    {DecisionEntry, DecisionControl, DecisionRef} = phase_entry(Target, Decision, 3, Base),
    {ok, Finalize} = quod_dtx:new_finalize(Group, DecisionRef, abort, none, 1),
    {_, _, FinalizeRef} = phase_entry(Remote, Finalize, 2, Base),
    {ok, Complete} = quod_dtx:new_complete(Group, DecisionRef,
        lists:sort([{Target, DecisionRef, 1}, {Remote, FinalizeRef, 1}])),
    {CompleteEntry, CompleteControl, CompleteRef} = phase_entry(Target, Complete, 4, Base),
    {Control, Ref} = case Kind of
        decision -> {DecisionControl, DecisionRef};
        complete -> {CompleteControl, CompleteRef}
    end,
    Base#{chain := [hd(maps:get(chain, Base)), BeginEntry, DecisionEntry, CompleteEntry],
          control := Control, ref := Ref, network => maps:get(network, Signed)}.

phase_entry({Ns, Anchor} = Target, Record, Slot, F) ->
    Signer = maps:get(signer, F),
    {ok, Control} = quod_dtx:sign_control(Target, Record, maps:get(admission, F),
                                         Slot - 1, Slot - 1, Signer),
    {ok, Blob} = quod_dtx:encode_control(Control),
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, {batch, [{dtx, Blob}]}, 0),
    Hash = quod_simplex:block_hash(Block),
    #share{sig = Sig} = quod_simplex:make_share(
        quod_simplex:consensus_domain(Ns, Anchor), commit, Slot, Hash, Signer),
    Entry = quod_ledger:entry(Block, #cert{kind = commit, slot = Slot,
                            block_hash = Hash, sigs = [{maps:get(pub, F), Sig}]}),
    {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Control),
    {Entry, Control, Ref}.
