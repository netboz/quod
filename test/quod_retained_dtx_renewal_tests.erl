-module(quod_retained_dtx_renewal_tests).
-moduledoc """
Classify retained Prepare alternatives before renewing their signatures.

Permanent version of the constructive stale-retained probe: real N=4
genesis admissions, signed Begin histories, two valid finality-proof subsets,
two owners' actual selectors, checked committed projections and real journals.
Only exported TEST delegations and the production relay dispatcher are used.
These tests compose the commit transition seams; the separate Begin ordering
tests own the integrated live-commit/catch-up publication-order regression.
""".

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

stale_alternative_prepare_retires_without_signing_test_() ->
    {timeout, 30, fun() -> isolated_scenario(alternate) end}.

unrelated_prepare_commit_renews_live_retained_prepare_test_() ->
    {timeout, 30, fun() -> isolated_scenario(unrelated_only) end}.

exact_prepare_digests_drain_without_renewal_test_() ->
    {timeout, 30, fun() -> isolated_scenario(exact) end}.

stale_signature_only_invariant_has_bounded_diagnostic_test_() ->
    {timeout, 30, fun() -> isolated_scenario(diagnostic) end}.

diagnostic_namespace_bounds_test_() ->
    [{atom_to_list(Variant),
      {timeout, 30, fun() -> isolated_scenario({diagnostic, Variant}) end}}
     || Variant <- [namespace_255, oversized_printable, oversized_nonprintable]].

isolated_scenario(Mode) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_opt(
      fun() ->
          Result = try scenario(Mode) of _ -> ok
                   catch Class:Reason:Stack -> {raise, Class, Reason, Stack}
                   end,
          Parent ! {Ref, Result}
      end, [link, monitor]),
    receive
        {Ref, Result} ->
            receive {'DOWN', Monitor, process, Pid, normal} -> ok end,
            case Result of
                ok -> ok;
                {raise, Class, Reason, Stack} -> erlang:raise(Class, Reason, Stack)
            end
    end.

scenario(Mode) ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
    Dir = filename:join("/tmp", "quod-retained-renewal-" ++ binary_to_list(Suffix)),
    %% Exclusive creation makes cleanup belong only to this test invocation.
    ok = file:make_dir(Dir),
    try
        Fixture = prepare_fixture(Dir, Suffix, Mode),
        Schedule = case Mode of {diagnostic, _} -> diagnostic; _ -> Mode end,
        with_journals(Fixture, fun(Journal, RemoteJournal, Store) ->
            with_recorders(fun(P1Waiter, QWaiter) ->
                exercise(Schedule, Fixture, Journal, RemoteJournal, Store,
                         P1Waiter, QWaiter)
            end)
        end)
    after
        ok = file:del_dir_r(Dir)
    end.

prepare_fixture(Dir, Suffix, Mode) ->
    Identities = identities(),
    Committee = lists:sort(maps:keys(Identities)),
    OriginNs = <<"quod:renewal-origin-", Suffix/binary>>,
    TargetNs = target_namespace(Mode, Suffix),
    %% Oversized diagnostic identities cannot use the production base64 name
    %% as a filesystem component. Use a short *physical storage label* only
    %% for these invariant controls. Every signed target, genesis, checked
    %% projection and journal consensus domain still uses the actual TargetNs.
    %% This is a diagnostic boundary test, not a claim that oversized names
    %% are admitted by the runtime's directory or storage owners.
    StorageNs = case Mode of
                    {diagnostic, _} -> <<"quod:renewal-diagnostic-storage-", Suffix/binary>>;
                    _ -> TargetNs
                end,
    {_OriginGenesis, Origin, OriginProjection} = genesis(OriginNs, Committee),
    {TargetGenesis, Target, Projection} = genesis(TargetNs, Committee),
    Admissions = maps:get(admissions, Projection),
    Ordered = lists:sort([{maps:get(Key, Admissions), Key} || Key <- Committee]),
    {RemoteAdmission, RemoteKey} = RemoteLane = hd(Ordered),
    {_LocalAdmission, LocalKey} = LocalLane = lists:last(Ordered),
    ?assert(RemoteLane < LocalLane),
    Local = maps:get(LocalKey, Identities),
    Remote = maps:get(RemoteKey, Identities),
    OriginAdmission = maps:get(LocalKey, maps:get(admissions, OriginProjection)),
    Common = #{target => Origin, participant_target => Target,
               node_identity => Local, admission => OriginAdmission},
    F1 = quod_ct:signed_dtx_begin_fixture(
           Common#{goal_text => <<"assertz(group_one(ok)).">>,
                   proof_id => <<1:256>>, operation_id => <<1:256>>}),
    F2 = quod_ct:signed_dtx_begin_fixture(
           Common#{goal_text => <<"assertz(group_two(ok)).">>,
                   proof_id => <<2:256>>, operation_id => <<2:256>>}),
    Begin1 = maps:get('begin', F1),
    BeginControl1 = maps:get(begin_control, F1),
    Begin2 = maps:get('begin', F2),
    {ok, BeginControl2} = quod_dtx:sign_control(
                           Origin, Begin2, OriginAdmission, 2, 3, Local),
    {BeginEntry1, BeginEntry1Alt} = certified_entries(
                                    Origin, 2, 1, [BeginControl1], Identities, Committee),
    {BeginEntry2, _} = certified_entries(
                       Origin, 3, 2, [BeginControl2], Identities, Committee),
    {ok, BeginRef1} = quod_dtx:certified_entry_ref(Origin, BeginEntry1, BeginControl1),
    {ok, BeginRef1Alt} = quod_dtx:certified_entry_ref(
                         Origin, BeginEntry1Alt, BeginControl1),
    {ok, BeginRef2} = quod_dtx:certified_entry_ref(Origin, BeginEntry2, BeginControl2),
    ?assertNotEqual(BeginRef1, BeginRef1Alt),
    ?assert(quod_dtx:same_certified_ref(BeginRef1, BeginRef1Alt)),
    lists:foreach(
      fun(Ref) ->
          ?assert(quod_dtx:certified_entry_ref_matches(
                    Origin, BeginEntry1, BeginControl1, Ref, Committee))
      end, [BeginRef1, BeginRef1Alt]),
    %% Advance both actual Begin histories with their finality and references;
    %% neither the target DTX projection nor readiness is manufactured.
    {ok, OriginIndex} = quod_dtx_phase_index:open(
                         filename:join(Dir, "origin-phase"), OriginNs),
    try
        quod_ct:with_network_identity(maps:get(network, F1), fun() ->
            {ok, OP1, _} = quod_simplex:history_advance(
                             Origin, BeginEntry1, OriginProjection, OriginIndex),
            {ok, _OP2, _} = quod_simplex:history_advance(
                              Origin, BeginEntry2, OP1, OriginIndex)
        end)
    after
        ok = quod_dtx_phase_index:close(OriginIndex)
    end,
    {ok, P1} = quod_dtx:new_prepare(Begin1, BeginRef1, Target),
    {ok, P2} = quod_dtx:new_prepare(Begin1, BeginRef1Alt, Target),
    {ok, Q} = quod_dtx:new_prepare(Begin2, BeginRef2, Target),
    ?assertNotEqual(quod_dtx:record_digest(P1), quod_dtx:record_digest(P2)),
    ?assertEqual(quod_dtx:group_id(P1), quod_dtx:group_id(P2)),
    ?assertNotEqual(quod_dtx:group_id(P1), quod_dtx:group_id(Q)),
    #{dir => Dir, target => Target, storage_ns => StorageNs, projection => Projection,
      genesis => TargetGenesis, identities => Identities, committee => Committee,
      local => Local, remote => Remote, local_lane => LocalLane,
      remote_lane => {RemoteAdmission, RemoteKey}, p1 => P1, p2 => P2, q => Q,
      evidence => [{BeginRef1, BeginControl1}, {BeginRef1Alt, BeginControl1},
                   {BeginRef2, BeginControl2}]}.

target_namespace({diagnostic, namespace_255}, _Suffix) ->
    <<"quod:", (binary:copy(<<"x">>, 250))/binary>>;
target_namespace({diagnostic, oversized_printable}, _Suffix) ->
    <<"quod:", (binary:copy(<<"x">>, 1000))/binary, "forbidden_namespace_tail">>;
target_namespace({diagnostic, oversized_nonprintable}, _Suffix) ->
    <<"quod:", (binary:copy(<<255, 0, 10, 13, 27>>, 200))/binary,
      "forbidden_namespace_tail">>;
target_namespace(_Mode, Suffix) ->
    <<"quod:renewal-target-", Suffix/binary>>.

with_journals(F = #{dir := Dir, target := {Ns, Anchor}, storage_ns := StorageNs}, Fun) ->
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    LocalDir = filename:join(Dir, "local"),
    {ok, Journal} = quod_signing_journal:initialize(StorageNs, Domain, LocalDir),
    try
        {ok, RemoteJournal} = quod_signing_journal:initialize(
                                StorageNs, Domain, filename:join(Dir, "remote")),
        try
            {ok, Store0} = quod_ledger_store:open(StorageNs, LocalDir),
            try
                {ok, Store} = quod_ledger_store:append(Store0, [maps:get(genesis, F)]),
                Fun(Journal, RemoteJournal, Store)
            after
                ok = quod_ledger_store:close(Store0)
            end
        after
            ok = quod_signing_journal:close(RemoteJournal)
        end
    after
        ok = quod_signing_journal:close(Journal)
    end.

exercise(Mode, F = #{target := Target, projection := Before,
                     p1 := P1, p2 := P2, q := Q, local_lane := Lane},
         Journal, RemoteJournal, Store0, P1Waiter, QWaiter) ->
    D1 = quod_dtx:record_digest(P1),
    D2 = quod_dtx:record_digest(P2),
    DQ = quod_dtx:record_digest(Q),
    A0 = state(Target, Before, maps:get(local, F), Journal),
    {ok, A1} = quod_simplex:test_retain_dtx_record(P1, {dtx_endpoint, P1Waiter}, A0),
    {ok, A2} = quod_simplex:test_retain_dtx_record(Q, {dtx_endpoint, QWaiter}, A1),
    CP1 = retained_control(D1, A2),
    CQ = retained_control(DQ, A2),
    ?assertEqual([1, 2], [sequence(CP1), sequence(CQ)]),
    ?assertEqual([D1, DQ], wave_digests(A2)),
    ?assertEqual(2, quod_simplex:test_dtx_submission_waiters(A2)),
    ?assertEqual(2, quod_signing_journal:dtx_floor(
                     quod_simplex:test_signing_journal(A2), Lane)),
    R0 = state(Target, Before, maps:get(remote, F), RemoteJournal),
    %% Authenticated production relay admission preserves A's exact envelopes.
    R1 = quod_simplex:dispatch(element(2, Lane),
                              {dtx_submit, envelopes([CP1, CQ]), []}, R0),
    ?assertEqual(CP1, retained_control(D1, R1)),
    ?assertEqual(CQ, retained_control(DQ, R1)),
    {ok, R2} = quod_simplex:test_retain_dtx_record(P2, none, R1),
    CP2 = retained_control(D2, R2),
    ?assertEqual(1, sequence(CP2)),
    ?assertEqual([D2, DQ], wave_digests(R2)),
    ?assertEqual(0, quod_signing_journal:dtx_floor(
                     quod_simplex:test_signing_journal(R2), Lane)),
    ?assertEqual(1, quod_signing_journal:dtx_floor(
                     quod_simplex:test_signing_journal(R2), maps:get(remote_lane, F))),
    lists:foreach(
      fun({Control, {Ref, BeginControl}}) ->
          ?assert(quod_dtx:verify_control(Target, Control)),
          ?assertEqual(ok, quod_dtx:validate_references(
                             Control, [{'begin', Ref, BeginControl}]))
      end, lists:zip([CP1, CP2, CQ], maps:get(evidence, F))),
    Controls = case Mode of
                   alternate -> [CP2, CQ];
                   diagnostic -> [CP2, CQ];
                   unrelated_only -> [CQ];
                   exact -> [CP1, CQ]
               end,
    {Entry, _} = certified_entries(Target, 2, 1, Controls,
                                   maps:get(identities, F), maps:get(committee, F)),
    ?assertEqual(ok, quod_catchup:verify_entry(Target, Entry, Before)),
    {ok, Store} = quod_ledger_store:append(Store0, [Entry]),
    After = advance_target(F, Entry),
    ?assertEqual(2, maps:get(Lane, maps:get(dtx_lanes, After))),
    ?assertEqual(case Mode of unrelated_only -> ready; _ -> stale end,
                 quod_dtx:proposal_readiness(P1, maps:get(dtx, After))),
    ?assertEqual(stale, quod_dtx:proposal_readiness(Q, maps:get(dtx, After))),
    Resolved = quod_simplex:test_resolve_committed_dtx(Entry, payload(Controls), A2),
    ?assertEqual(case Mode of exact -> []; _ -> [D1] end,
                 maps:keys(rows(Resolved))),
    QReply = committed_reply(Target, Entry, CQ),
    ?assertEqual([QReply], take_messages(QWaiter)),
    ?assertEqual(case Mode of exact -> [committed_reply(Target, Entry, CP1)];
                             _ -> [] end, take_messages(P1Waiter)),
    Adopted = quod_simplex:test_state_set(slot, 2,
                quod_simplex:test_install_projection(After, Resolved)),
    Committed = F#{entry => Entry, controls => Controls, store => Store,
                   'after' => After, original => CP1},
    case Mode of
        diagnostic -> assert_diagnostic(Committed, Adopted, P1Waiter, QWaiter);
        _ -> assert_reconciliation(Mode, Committed, Adopted, P1Waiter, QWaiter)
    end.

assert_reconciliation(Mode,
                      F = #{target := Target, local_lane := Lane, p1 := P1,
                            entry := Entry, controls := Controls, store := Store,
                            'after' := After, original := CP1},
                      Adopted, P1Waiter, QWaiter) ->
    D1 = quod_dtx:record_digest(P1),
    {{Outcome, SigningCalls}, Reports} = capture_invariant_reports(Target, fun() ->
        trace_signing(fun() -> quod_simplex:test_reconcile_signing_state(Adopted) end)
    end),
    %% Reopen even on a regression: the fail-before evidence must expose the
    %% irreversible extra floor, not just the stale installer exception.
    ExpectedFloor = case Mode of unrelated_only -> 3; _ -> 2 end,
    CurrentJournal = case Outcome of
                         {returned, {S, _}} -> quod_simplex:test_signing_journal(S);
                         {raised, _, _} -> quod_simplex:test_signing_journal(Adopted)
                     end,
    ok = quod_signing_journal:close(CurrentJournal),
    {ok, Reopened} = quod_signing_journal:recover(
                       element(1, Target),
                       quod_simplex:consensus_domain(element(1, Target), element(2, Target)),
                       filename:join(maps:get(dir, F), "local")),
    try
        Floor = quod_signing_journal:dtx_floor(Reopened, Lane),
        io:format("retained renewal: ~p~n",
                  [#{mode => Mode, signing_calls => SigningCalls,
                     committed_floor => 2, reopened_floor => Floor}]),
        ?assertMatch({returned, {_, none}}, Outcome),
        ?assertEqual([], Reports),
        ?assertEqual(case Mode of unrelated_only -> 1; _ -> 0 end, SigningCalls),
        ?assertEqual(ExpectedFloor, Floor),
        ?assertEqual(#{}, quod_signing_journal:pending_begins(Reopened)),
        {returned, {Reconciled0, none}} = Outcome,
        Reconciled = quod_simplex:test_state_set(signing_journal, Reopened, Reconciled0),
        assert_retained_result(Mode, D1, CP1, Reconciled, Target, P1Waiter),
        ?assertEqual([], take_messages(QWaiter)),
        %% Repeat exact resolution and the entire reconciliation against the
        %% unchanged projection and reopened journal: no duplicate waiter,
        %% no row resurrection and no second healthy renewal.
        Again0 = quod_simplex:test_resolve_committed_dtx(
                   Entry, payload(Controls), Reconciled),
        {{{returned, {Again, none}}, RepeatCalls}, RepeatReports} =
            capture_invariant_reports(Target, fun() ->
                trace_signing(fun() -> quod_simplex:test_reconcile_signing_state(Again0) end)
            end),
        ?assertEqual([], RepeatReports),
        ?assertEqual(0, RepeatCalls),
        ?assertEqual(quod_simplex:test_retained_dtx_state(Reconciled),
                     quod_simplex:test_retained_dtx_state(Again)),
        ?assertEqual(maps:get(dtx, After), maps:get(fingerprint,
                     quod_simplex:test_retained_dtx_state(Again))),
        ?assertEqual(ExpectedFloor, quod_signing_journal:dtx_floor(
                                     quod_simplex:test_signing_journal(Again), Lane)),
        ?assertEqual([], take_messages(P1Waiter)),
        ?assertEqual([], take_messages(QWaiter)),
        {ok, Persisted} = quod_ledger_store:read_at(Store, 2),
        ?assertEqual(quod_ledger:encode_entry(Entry), quod_ledger:encode_entry(Persisted))
    after
        ok = quod_signing_journal:close(Reopened)
    end.

assert_diagnostic(#{target := Target = {Ns, Anchor}, storage_ns := StorageNs,
                    p1 := P1, local := Local,
                    local_lane := Lane, dir := Dir, original := CP1,
                    entry := Entry, store := Store},
                  Adopted, P1Waiter, QWaiter) ->
    %% Deliberately violate the owner ordering using the signature-only seam.
    %% This must throw the original invariant, never return apparent success.
    {{Outcome, SigningCalls}, Reports} = capture_invariant_reports(Target, fun() ->
        trace_signing(fun() ->
            ?assertError(stale_retained_dtx,
                         quod_simplex:test_refresh_retained_dtx_signatures(Adopted))
        end)
    end),
    ?assertEqual({returned, ok}, Outcome),
    ?assertEqual(1, SigningCalls),
    ?assertEqual(1, length(Reports)),
    [Event = #{level := error, msg := {report, Report}}] = Reports,
    %% Equality is also the whitelist: no state, journal, plan, goal, envelope,
    %% signature, signer or raw exception may appear as an additional field.
    ExpectedNamespace = case byte_size(Ns) of
                            Size when Size =< 255 -> Ns;
                            Size -> {truncated, binary:part(Ns, 0, 255), Size}
                        end,
    Expected = #{event => stale_retained_dtx, namespace => ExpectedNamespace,
                 group_digest => binary:encode_hex(quod_dtx:group_id(P1)),
                 record_digest => binary:encode_hex(quod_dtx:record_digest(P1)),
                 phase => prepare, committed_height => 2, old_sequence => 1,
                 proposed_sequence => 3, committed_floor => 2, readiness => stale},
    ?assertEqual(Expected, Report),
    Encoded = iolist_to_binary(quod_log_formatter:format(Event, #{})),
    Decoded = json:decode(Encoded),
    ?assertEqual(<<"error">>, maps:get(<<"level">>, Decoded)),
    Message = maps:get(<<"msg">>, Decoded),
    ?assertEqual(iolist_to_binary(io_lib:format("~p", [Expected])), Message),
    MessageLimit = case ExpectedNamespace of
                       {truncated, _, _} -> 2048;
                       _ -> 1024
                   end,
    ?assert(byte_size(Message) < MessageLimit),
    [Envelope] = envelopes([CP1]),
    {quod_dtx_control, _, prepare, _, _, _, _, _, _, Signature} = CP1,
    {quod_dtx_prepare, _, _, _, _, _, PlanBlob} = P1,
    #'ECPrivateKey'{privateKey = Seed} = maps:get(key, Local),
    Forbidden = [<<"group_one">>, <<"group_two">>, <<"plan">>, <<"manifest">>,
                 <<"goal">>, <<"signer">>, <<"forbidden_namespace_tail">>,
                 <<"quod_dtx_prepare">>, <<"quod_dtx_control">>,
                 <<"signature">>, <<"envelope">>, <<"private_key">>,
                 <<"ECPrivateKey">>, <<"ed_pri">>,
                 iolist_to_binary(io_lib:format("~p", [CP1])),
                 iolist_to_binary(io_lib:format("~p", [maps:get(key, Local)]))]
                ++ lists:flatmap(fun(Bin) ->
                    [Bin, binary:encode_hex(Bin), binary:encode_hex(Bin, lowercase),
                     base64:encode(Bin), iolist_to_binary(io_lib:format("~p", [Bin]))]
                end, [Envelope, Signature, PlanBlob, Seed]),
    lists:foreach(fun(Secret) ->
        ?assertEqual(nomatch, binary:match(Encoded, Secret)),
        ?assertEqual(nomatch, binary:match(Message, Secret))
    end, Forbidden),
    %% The intentionally bypassed guard already exposed sequence 3. Keep it
    %% monotonic on reopen; this is not the healthy path's expected floor 2.
    ok = quod_signing_journal:close(quod_simplex:test_signing_journal(Adopted)),
    {ok, Reopened} = quod_signing_journal:recover(
                       StorageNs, quod_simplex:consensus_domain(Ns, Anchor),
                       filename:join(Dir, "local")),
    try
        ?assertEqual(3, quod_signing_journal:dtx_floor(Reopened, Lane)),
        ?assertEqual(#{}, quod_signing_journal:pending_begins(Reopened))
    after
        ok = quod_signing_journal:close(Reopened)
    end,
    ?assertEqual([], take_messages(P1Waiter)),
    ?assertEqual([], take_messages(QWaiter)),
    {ok, Persisted} = quod_ledger_store:read_at(Store, 2),
    ?assertEqual(quod_ledger:encode_entry(Entry), quod_ledger:encode_entry(Persisted)).

capture_invariant_reports({Ns, _Anchor}, Fun) ->
    Owner = self(),
    Ref = make_ref(),
    Filter = fun(Event = #{msg := {report, #{event := stale_retained_dtx}},
                          meta := #{pid := Pid}}, _Extra) when Pid =:= Owner ->
                     Owner ! {Ref, Event},
                     ignore;
                (_Event, _Extra) -> ignore
             end,
    %% Primary filters run synchronously in the logging process. Capturing
    %% only this owner's events needs neither a sleep nor handler flushing.
    Id = ?MODULE,
    ok = logger:add_primary_filter(Id, {Filter, Ns}),
    try
        Result = Fun(),
        {Result, drain_reports(Ref)}
    after
        ok = logger:remove_primary_filter(Id)
    end.

drain_reports(Ref) ->
    receive {Ref, Event} -> [Event | drain_reports(Ref)]
    after 0 -> []
    end.

assert_retained_result(unrelated_only, Digest, Original, S, Target, Waiter) ->
    ?assertMatch(#{retained := 1, ready := 1, blocked := 0, waiters := 1},
                 quod_simplex:test_retained_dtx_state(S)),
    ?assertEqual([Digest], wave_digests(S)),
    Renewed = retained_control(Digest, S),
    ?assertEqual(3, sequence(Renewed)),
    ?assertEqual(quod_dtx:control_body(Original), quod_dtx:control_body(Renewed)),
    ?assertEqual(maps:with([author, author_admission], quod_dtx:control_metadata(Original)),
                 maps:with([author, author_admission], quod_dtx:control_metadata(Renewed))),
    ?assert(quod_dtx:verify_control(Target, Renewed)),
    ?assertEqual([], take_messages(Waiter));
assert_retained_result(Mode, _Digest, _Original, S, _Target, Waiter) ->
    ?assertMatch(#{retained := 0, ready := 0, blocked := 0, waiters := 0,
                   bytes := 0, rows := #{}, ready_order := [], blocked_order := [],
                   waiter_index := #{}}, quod_simplex:test_retained_dtx_state(S)),
    ?assertEqual(case Mode of alternate -> [{error, stale_dtx_submission}];
                             exact -> [] end, take_messages(Waiter)).

advance_target(#{dir := Dir, target := Target, storage_ns := StorageNs,
                 projection := Before}, Entry) ->
    {ok, Index} = quod_dtx_phase_index:open(filename:join(Dir, "target-phase"), StorageNs),
    try
        {ok, After, _Effects} = quod_simplex:history_advance(Target, Entry, Before, Index),
        After
    after
        ok = quod_dtx_phase_index:close(Index)
    end.

committed_reply(Target, Entry, Control) ->
    {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Control),
    {ok, Ref, [{Ref, Entry}]}.

rows(S) -> maps:get(rows, quod_simplex:test_retained_dtx_state(S)).
wave_digests(S) -> [D || {D, _} <- quod_simplex:test_eligible_dtx_wave(S)].
retained_control(Digest, S) ->
    {ok, Control} = quod_dtx:decode_control(maps:get(envelope, maps:get(Digest, rows(S)))),
    Control.
sequence(Control) -> maps:get(sequence, quod_dtx:control_metadata(Control)).
envelopes(Controls) ->
    lists:map(fun(C) -> {ok, Envelope} = quod_dtx:encode_control(C), Envelope end, Controls).
payload(Controls) -> {batch, [{dtx, Envelope} || Envelope <- envelopes(Controls)]}.

identities() ->
    maps:from_list(
      [begin
           {Pub, Seed} = crypto:generate_key(eddsa, ed25519, <<N:256>>),
           {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}
       end || N <- lists:seq(1, 4)]).

genesis(Ns, Committee) ->
    {ok, Entry, Anchor} = quod_simplex:prepare_genesis(
      #{mode => create, committee => Committee, genesis_diff => []}, Ns, hd(Committee)),
    Identity = {Ns, Anchor},
    {ok, Projection} = quod_simplex:history_validate_advance(
      Identity, Entry, quod_simplex:history_projection(Identity)),
    {Entry, Identity, Projection}.

state({Ns, Anchor}, Projection, Signer = #{pubkey := Pub}, Journal) ->
    quod_simplex:test_install_projection(Projection, quod_simplex:test_state(
      #{ns => Ns, genesis_hash => Anchor, slot => 1,
        self => Pub, id => Signer, sync => ready, prolog_ready => true,
        signing_journal => Journal,
        consensus_domain => quod_simplex:consensus_domain(Ns, Anchor)})).

certified_entries({Ns, Anchor}, Slot, Parent, Controls, Identities, Committee) ->
    {ok, Block} = quod_ledger:new_block(Slot, Parent, payload(Controls), Slot),
    Hash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Shares = maps:map(fun(_, Signer) ->
        quod_simplex:make_share(Domain, commit, Slot, Hash, Signer)
    end, Identities),
    [A, B, C, D] = Committee,
    Make = fun(Keys) ->
        {ok, Cert} = quod_simplex:form_cert(Domain, commit, Slot, Hash,
                         [maps:get(Key, Shares) || Key <- Keys], Committee),
        quod_ledger:entry(Block, Cert)
    end,
    {Make([A, B, C]), Make([B, C, D])}.

with_recorders(Fun) ->
    {P1, M1} = spawn_opt(fun() -> recorder([]) end, [link, monitor]),
    try
        {Q, M2} = spawn_opt(fun() -> recorder([]) end, [link, monitor]),
        try Fun(P1, Q)
        after stop_recorder(Q, M2) end
    after stop_recorder(P1, M1) end.

recorder(Reverse) ->
    receive
        {dtx_submit_result, Reply} -> recorder([Reply | Reverse]);
        {trace, _Pid, call, {quod_dtx, sign_control, 6}} ->
            recorder([sign_control | Reverse]);
        {take_messages, From, Ref} ->
            From ! {Ref, lists:reverse(Reverse)}, recorder([]);
        stop -> ok
    end.

take_messages(Pid) ->
    Ref = make_ref(),
    Pid ! {take_messages, self(), Ref},
    receive {Ref, Messages} -> Messages
    after 1000 -> error(recorder_barrier_failed)
    end.

stop_recorder(Pid, Monitor) ->
    Pid ! stop,
    receive {'DOWN', Monitor, process, Pid, normal} -> ok
    after 1000 -> error(recorder_did_not_stop)
    end.

trace_signing(Fun) ->
    {Tracer, Monitor} = spawn_opt(fun() -> recorder([]) end, [link, monitor]),
    try
        1 = erlang:trace_pattern({quod_dtx, sign_control, 6}, true, []),
        %% Arity-only tracing must never copy the signer's key or envelope.
        1 = erlang:trace(self(), true, [call, arity, {tracer, Tracer}]),
        try
            Outcome = try Fun() of Value -> {returned, Value}
                      catch Class:Reason -> {raised, Class, Reason}
                      end,
            1 = erlang:trace(self(), false, [call]),
            Barrier = erlang:trace_delivered(self()),
            receive {trace_delivered, _, Barrier} -> ok
            after 1000 -> error(signing_trace_barrier_failed)
            end,
            {Outcome, length(take_messages(Tracer))}
        after
            erlang:trace(self(), false, [call]),
            erlang:trace_pattern({quod_dtx, sign_control, 6}, false, [])
        end
    after
        stop_recorder(Tracer, Monitor)
    end.
