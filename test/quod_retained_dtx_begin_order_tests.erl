-module(quod_retained_dtx_begin_order_tests).
-moduledoc """
Pending Begin retirement must preserve the existing apply/publication order.

Both groups are built by the ordinary signed proof constructors. A real N=4
certified older Begin conflicts with a younger, already-journaled Begin.
The live case enters commit_block through the normal quorum-share dispatcher;
the catch-up case enters the existing verified-window sink. A registered
Prolog receiver records the actual production casts in arrival order.
""".

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

live_commit_applies_before_conflicting_begin_resolution_test_() ->
    {timeout, 30, fun() -> isolated_scenario(live) end}.

catchup_window_applies_before_conflicting_begin_resolution_test_() ->
    {timeout, 30, fun() -> isolated_scenario(catchup) end}.

ordinary_retirement_resolves_at_its_existing_boundary_test_() ->
    {timeout, 30, fun() -> isolated_scenario(ordinary) end}.

live_commit_renews_but_retains_blocked_begin_test_() ->
    {timeout, 30, fun() -> isolated_scenario({blocked, live}) end}.

catchup_window_renews_but_retains_blocked_begin_test_() ->
    {timeout, 30, fun() -> isolated_scenario({blocked, catchup}) end}.

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

scenario(Scenario) ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Ns = <<"quod:begin-order-", Suffix/binary>>,
    Dir = filename:join("/tmp", binary_to_list(Ns)),
    Identities = identities(),
    Committee = lists:sort(maps:keys(Identities)),
    {Genesis, Identity, Projection0} = genesis(Ns, Committee),
    [Author | OtherPeers] = Committee,
    Signer = maps:get(Author, Identities),
    Admission = maps:get(Author, maps:get(admissions, Projection0)),
    Lane = {Admission, Author},
    Domain = quod_simplex:consensus_domain(Ns, element(2, Identity)),
    Common = #{target => Identity, node_identity => Signer,
               admission => Admission,
               goal_text => <<"assertz(overlapping_balance(ok)).">>},
    First = quod_ct:signed_dtx_begin_fixture(
              Common#{proof_id => <<1:256>>, operation_id => <<1:256>>}),
    Second = quod_ct:signed_dtx_begin_fixture(
               Common#{proof_id => <<2:256>>, operation_id => <<2:256>>}),
    [Older, Younger] = lists:sort(
        [{quod_dtx:group_id(maps:get('begin', F)), F}
         || F <- [First, Second]]),
    %% Wait-die refuses a younger pending group, but an older pending group
    %% must survive as blocked even when its outer sequence needs renewal.
    {Mode, Disposition, [{G1, Committing}, {G2, Pending}]} =
        case Scenario of
            {blocked, Path} -> {Path, {blocked, active_group}, [Younger, Older]};
            Path -> {Path, {refused, conflict}, [Older, Younger]}
        end,
    Begin1 = maps:get('begin', Committing),
    Begin2 = maps:get('begin', Pending),
    {ok, GroupRef1} = quod_dtx:begin_group_ref(Begin1),
    {ok, GroupRef2} = quod_dtx:begin_group_ref(Begin2),
    {Receiver, ReceiverMonitor} = start_receiver(Ns),
    try
        {ok, Journal0} = quod_signing_journal:initialize(Ns, Domain, Dir),
        try
            {ok, Store0} = quod_ledger_store:open(Ns, Dir),
            try
                {ok, Store1} = quod_ledger_store:append(Store0, [Genesis]),
                {ok, PhaseIndex} = quod_dtx_phase_index:open(Dir, Ns),
                try
                    S0 = quod_simplex:test_install_projection(
                           Projection0,
                           quod_simplex:test_state(
                             #{ns => Ns, genesis_hash => element(2, Identity),
                               self => Author, id => Signer,
                               consensus_domain => Domain,
                               store => Store1, signing_journal => Journal0,
                               slot => 1, last_applied => 1, sync => ready,
                               prolog_ready => true,
                               eng => quod_simplex:eng_new(
                                        Domain, Committee, 1)})),
                    %% G2 is legitimately ready when its durable custody is
                    %% accepted. Another leader may see/select G1 alone.
                    ?assertEqual(ready, quod_dtx:proposal_readiness(
                                          Begin2, maps:get(dtx, Projection0))),
                    {ok, SYounger} = quod_simplex:test_retain_dtx_record(
                                       Begin2, {dtx_endpoint, self()}, S0),
                    {ok, SBoth0} = quod_simplex:test_retain_dtx_record(
                                     Begin1, none, SYounger),
                    Control1 = retained_control(Begin1, SBoth0),
                    Control2 = retained_control(Begin2, SBoth0),
                    ?assertEqual([1, 2],
                                 [sequence(Control2), sequence(Control1)]),
                    Journal = quod_simplex:test_signing_journal(SBoth0),
                    ?assertEqual(lists:sort([G1, G2]),
                                 lists:sort(maps:keys(
                                   quod_signing_journal:pending_begins(Journal)))),
                    %% The live intent owner projects these journaled
                    %% obligations into the same committed-history seed.
                    SBoth = quod_simplex:test_state_set(
                              dtx_pending, #{G1 => Lane, G2 => Lane}, SBoth0),
                    ProjectionBefore = quod_simplex:test_state_projection(SBoth),
                    {Block, Entry} = certified_entry(
                                       Identity, Control1, Identities, Committee),
                    ?assertEqual(ok, quod_catchup:verify_entry(
                                       Identity, Entry, ProjectionBefore)),
                    {ok, ProjectionAfter, _} = quod_ct:with_network_identity(
                      maps:get(network, Committing),
                      fun() -> quod_simplex:history_advance(
                                 Identity, Entry, ProjectionBefore, PhaseIndex)
                      end),
                    ?assertEqual(#{G2 => Lane},
                                 maps:get(dtx_pending, ProjectionAfter)),
                    ?assertEqual(Disposition,
                                 quod_dtx:proposal_readiness(
                                   Begin2, maps:get(dtx, ProjectionAfter))),
                    ?assertEqual(Admission,
                                 maps:get(Author, maps:get(admissions, ProjectionAfter))),
                    _ = receiver_messages(Receiver),
                    After = apply_scenario(
                              Mode, Block, Entry, ProjectionBefore,
                              ProjectionAfter, OtherPeers, Identities,
                              Domain, SBoth),
                    Messages = receiver_messages(Receiver),
                    %% Pin the original journal transition as well as the
                    %% newly retired alternative: merging must lose neither.
                    assert_order(Mode, Entry, GroupRef1, G1, Messages),
                    ExpectedResolved = case Disposition of
                        {refused, conflict} -> [GroupRef1, GroupRef2];
                        {blocked, active_group} -> [GroupRef1]
                    end,
                    ?assertEqual(lists:sort(ExpectedResolved),
                                 lists:sort([R || {dtx_group_resolved, R}
                                                     <- Messages])),
                    {ExpectedPending, ExpectedFloor} =
                        assert_retirement_or_blocking(
                          Disposition, Mode, Entry, GroupRef2, G2, Lane,
                          Begin2, After, Messages),
                    AfterJournal = quod_simplex:test_signing_journal(After),
                    ?assertEqual(ExpectedPending,
                                 quod_signing_journal:pending_begins(AfterJournal)),
                    ?assertEqual(ExpectedFloor,
                                 quod_signing_journal:dtx_floor(AfterJournal, Lane)),
                    ok = quod_signing_journal:close(AfterJournal),
                    {ok, Reopened} = quod_signing_journal:recover(Ns, Domain, Dir),
                    try
                        ?assertEqual(ExpectedPending,
                                     quod_signing_journal:pending_begins(Reopened)),
                        ?assertEqual(ExpectedFloor,
                                     quod_signing_journal:dtx_floor(Reopened, Lane))
                    after
                        ok = quod_signing_journal:close(Reopened)
                    end,
                    ?assertEqual([], receiver_messages(Receiver))
                after
                    catch quod_dtx_phase_index:close(PhaseIndex)
                end
            after
                catch quod_ledger_store:close(Store0)
            end
        after
            catch quod_signing_journal:close(Journal0)
        end
    after
        stop_receiver(Receiver, ReceiverMonitor),
        file:del_dir_r(Dir),
        receive dtx_drive -> ok after 0 -> ok end
    end.

assert_retirement_or_blocking(
  {refused, conflict}, Mode, Entry, GroupRef, GroupId, _Lane, _Begin, S, Messages) ->
    assert_order(Mode, Entry, GroupRef, GroupId, Messages),
    assert_begin_reply(),
    ?assertEqual(0, maps:get(retained, quod_simplex:test_retained_dtx_state(S))),
    ?assertEqual(#{}, maps:get(dtx_pending, quod_simplex:test_state_projection(S))),
    {#{}, 2};
assert_retirement_or_blocking(
  {blocked, active_group}, Mode, Entry, GroupRef, GroupId, Lane, Begin, S, Messages) ->
    ?assertMatch(#{retained := 1, blocked := 1, ready := 0, waiters := 1},
                 quod_simplex:test_retained_dtx_state(S)),
    ?assertEqual(#{GroupId => Lane},
                 maps:get(dtx_pending, quod_simplex:test_state_projection(S))),
    Control = retained_control(Begin, S),
    ?assertEqual(Begin, quod_dtx:control_body(Control)),
    ?assertEqual(3, sequence(Control)),
    Pending = quod_signing_journal:pending_begins(
                quod_simplex:test_signing_journal(S)),
    ?assertEqual([GroupId], maps:keys(Pending)),
    #{GroupId := #{sequence := 3, lane := Lane, envelope := Envelope}} = Pending,
    ?assertEqual({ok, Control}, quod_dtx:decode_control(Envelope)),
    ?assertEqual([], [Ref || {dtx_group_resolved, Ref} <- Messages,
                            Ref =:= GroupRef]),
    [{AppliedAt, ActualEntry, Origin}] =
        [{I, E, O} || {I, {apply_entry, E, O}} <- numbered(Messages)],
    ?assertEqual(quod_ledger:encode_entry(Entry), quod_ledger:encode_entry(ActualEntry)),
    ?assertEqual(case Mode of live -> live; catchup -> replay end, Origin),
    RenewedProjections =
        [I || {I, {project_pending_begins, Rows}} <- numbered(Messages),
              lists:any(fun(#{group_id := G, sequence := Seq}) ->
                                G =:= GroupId andalso Seq =:= 3
                        end, Rows)],
    ?assertNotEqual([], RenewedProjections),
    ?assert(lists:last(RenewedProjections) < AppliedAt),
    receive
        {dtx_submit_result, Unexpected} -> error({blocked_waiter_released, Unexpected})
    after 0 -> ok
    end,
    {Pending, 3}.

apply_scenario(live, Block, _Entry, Before, _After, OtherPeers,
               Identities, Domain, S0) ->
    Hash = quod_simplex:block_hash(Block),
    Parent = maps:get(history_head, Before),
    {Monitor, Pending} = quod_simplex:test_latch_dtx_validation(
                           2, Hash, Parent, self(), Block, S0),
    %% A fresh group's verified history is empty. The production verdict
    %% handler still previews this exact signed Begin against its parent.
    Supported = quod_simplex:test_on_dtx_verdict(
                  2, Hash, Parent, self(), 1, {valid, #{}}, Pending),
    ?assertNot(erlang:demonitor(Monitor, [info])),
    {_Validating, _Validation, _Candidate,
     {Hash, Parent, #{}, ParentDtx}, _RetainedBlock} =
        quod_simplex:test_dtx_round(2, Supported),
    ?assertEqual(maps:get(dtx, Before), ParentDtx),
    %% The local share plus two authenticated peers reaches each real
    %% threshold. The final dispatch enters commit_block, not a test fold.
    Peers = lists:sublist(OtherPeers, 2),
    lists:foldl(
      fun({Kind, Peer}, S) ->
          Share = quod_simplex:make_share(
                    Domain, Kind, 2, Hash, maps:get(Peer, Identities)),
          quod_simplex:dispatch(Peer, {share, Share}, S)
      end, Supported,
      [{Kind, Peer} || Kind <- [support, commit], Peer <- Peers]);
apply_scenario(catchup, _Block, Entry, _Before, After, _Peers,
               _Identities, _Domain, S0) ->
    {S, ok} = quod_simplex:test_apply_catchup_window(
                recovery, [Entry], After, S0),
    S;
apply_scenario(ordinary, Block, Entry, _Before, After, _Peers,
               _Identities, _Domain, S0) ->
    %% This boundary is already after application, not nested in a new
    %% commit. Keep ordinary retirement immediate, without any synthetic
    %% ledger apply or added asynchronous turn.
    {1, Store0} = quod_simplex:test_committed_store(S0),
    {ok, Store1} = quod_ledger_store:append(Store0, [Entry]),
    Resolved = quod_simplex:test_resolve_committed_dtx(
                 Entry, Block#block.payload, S0),
    Current = quod_simplex:test_state_set(
                last_applied, 2,
                quod_simplex:test_state_set(
                  slot, 2, quod_simplex:test_state_set(store, Store1, Resolved))),
    Adopted = quod_simplex:test_install_projection(After, Current),
    %% Exercise the real outer publication boundary, not a test wrapper
    %% which could publish the returned transition on its behalf. An
    %% unconfirmed node still classifies retained work but cannot start new
    %% coordinators/voting while this local projection settles.
    Unconfirmed = quod_simplex:test_state_set(sync, unconfirmed, Adopted),
    {keep_state, Classified, _Actions} =
        quod_simplex:test_keep_progress_transition(Unconfirmed, Unconfirmed),
    Classified.

assert_order(Mode, Entry, GroupRef, GroupId, Messages) ->
    Resolutions = [I || {I, {dtx_group_resolved, Ref}} <- numbered(Messages),
                         Ref =:= GroupRef],
    ?assertEqual(1, length(Resolutions)),
    [ResolvedAt] = Resolutions,
    EmptyProjections =
        [I || {I, {project_pending_begins, Rows}} <- numbered(Messages),
              not lists:any(fun(#{group_id := RowGroup}) -> RowGroup =:= GroupId end,
                            Rows)],
    ?assertNotEqual([], EmptyProjections),
    ?assert(lists:last(EmptyProjections) < ResolvedAt),
    Applies = [{I, E, Origin} || {I, {apply_entry, E, Origin}} <- numbered(Messages)],
    case Mode of
        ordinary -> ?assertEqual([], Applies);
        _ ->
            [{AppliedAt, ActualEntry, Origin}] = Applies,
            ?assertEqual(quod_ledger:encode_entry(Entry),
                         quod_ledger:encode_entry(ActualEntry)),
            ?assertEqual(case Mode of live -> live; catchup -> replay end, Origin),
            case AppliedAt < ResolvedAt of
                true -> ok;
                false -> error({resolution_before_apply, Mode, Messages})
            end,
            ?assert(lists:last(EmptyProjections) < AppliedAt)
    end.

numbered(Messages) -> lists:zip(lists:seq(1, length(Messages)), Messages).

assert_begin_reply() ->
    receive
        {dtx_submit_result, Reply} -> ?assertEqual({error, retry}, Reply)
    after 1000 -> error(conflicting_begin_waiter_was_not_released)
    end,
    receive
        {dtx_submit_result, Extra} -> error({duplicate_begin_reply, Extra})
    after 0 -> ok
    end.

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

retained_control(Record, S) ->
    Row = maps:get(quod_dtx:record_digest(Record),
                  maps:get(rows, quod_simplex:test_retained_dtx_state(S))),
    {ok, Control} = quod_dtx:decode_control(maps:get(envelope, Row)),
    Control.

sequence(Control) -> maps:get(sequence, quod_dtx:control_metadata(Control)).

certified_entry({Ns, Anchor}, Control, Identities, Committee) ->
    {ok, Envelope} = quod_dtx:encode_control(Control),
    {ok, Block} = quod_ledger:new_block(
                    2, 1, {batch, [{dtx, Envelope}]}, quod_time:now_ms()),
    Hash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Shares = [quod_simplex:make_share(
                Domain, commit, 2, Hash, maps:get(Key, Identities))
              || Key <- lists:sublist(Committee, 3)],
    {ok, Cert} = quod_simplex:form_cert(Domain, commit, 2, Hash, Shares, Committee),
    {Block, quod_ledger:entry(Block, Cert)}.

start_receiver(Ns) ->
    Parent = self(),
    {Pid, Monitor} = spawn_opt(
      fun() ->
          true = quod_reg:reg({quod_prolog, Ns}),
          Parent ! {receiver_ready, self()},
          receiver([])
      end, [link, monitor]),
    receive {receiver_ready, Pid} -> {Pid, Monitor}
    after 1000 -> error(prolog_receiver_did_not_register)
    end.

receiver(Reverse) ->
    receive
        {'$gen_cast', Message} -> receiver([Message | Reverse]);
        {'$gen_call', From, sync} -> gen_server:reply(From, ok), receiver(Reverse);
        {take_messages, From, Ref} ->
            From ! {Ref, lists:reverse(Reverse)}, receiver([]);
        stop -> ok
    end.

receiver_messages(Pid) ->
    Ref = make_ref(),
    Pid ! {take_messages, self(), Ref},
    receive {Ref, Messages} -> Messages
    after 1000 -> error(prolog_receiver_barrier_failed)
    end.

stop_receiver(Pid, Monitor) ->
    Pid ! stop,
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> exit(Pid, kill),
                  receive {'DOWN', Monitor, process, Pid, _} -> ok end
    end.
