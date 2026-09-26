-module(quod_retained_dtx_vote_order_tests).
-moduledoc """
Pending Vote publication preserves the existing apply-before-notify boundary.

Real signed own plans, N=4 finality, on-disk journal and phase index. A source
Vote commits while another group remains in source custody. Applied changes
return the conflicting Vote to selection; they never erase its completion duty.
The registered Prolog receiver observes actual production casts in FIFO order.
""".

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

publication_order_test_() ->
    [{atom_to_list(Mode), {timeout, 30, fun() -> isolated_scenario(Mode) end}}
     || Mode <- [live, catchup, catchup_paused]].

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
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Ns = <<"quod:vote-order-", Suffix/binary>>,
    Dir = filename:join("/tmp", binary_to_list(Ns)),
    Identities = identities(), Committee = lists:sort(maps:keys(Identities)),
    {Genesis, Identity, Projection0} = genesis(Ns, Committee),
    [Author | OtherPeers] = Committee, Signer = maps:get(Author, Identities),
    Admission = maps:get(Author, maps:get(admissions, Projection0)),
    Lane = {Admission, Author},
    Domain = quod_simplex:consensus_domain(Ns, element(2, Identity)),
    Common = #{target => Identity, node_identity => Signer, admission => Admission,
               goal_text => <<"assertz(overlapping_balance(ok)).">>},
    [First, Second] = [quod_ct:signed_atomic_fixture(
        Common#{proof_id => <<N:256>>, operation_id => <<N:256>>}) || N <- [1, 2]],
    M1 = quod_atomic:control_material(maps:get(vote_control, First)),
    M2 = quod_atomic:control_material(maps:get(vote_control, Second)),
    G1 = quod_atomic:group_id(maps:get(group, First)),
    G2 = quod_atomic:group_id(maps:get(group, Second)),
    {ok, Ref1} = quod_atomic:source_group_ref(M1),
    {ok, Ref2} = quod_atomic:source_group_ref(M2),
    {Receiver, Monitor} = start_receiver(Ns),
    {ok, J0} = quod_signing_journal:initialize(Ns, Domain, Dir),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
    try
        {ok, Store} = quod_ledger_store:append(Store0, {none, [Genesis]}),
        {ok, Projection0, _} = quod_ct:history_advance(
            Identity, Genesis, quod_simplex:history_projection(Identity), Index),
        Root = maps:get(protocol_root, Projection0),
        %% These are already parent-selected owner rows. The real journal
        %% records both controls; no history-side shadow inventory is seeded.
        {ok, C2} = quod_atomic:sign_control(Identity, M2, Admission, 1, 1, Signer),
        {ok, C1} = quod_atomic:sign_control(Identity, M1, Admission, 2, 1, Signer),
        {ok, J1, _} = quod_signing_journal:record_dtx(J0, C2),
        {ok, J2, _} = quod_signing_journal:record_dtx(J1, C1),
        S0 = quod_simplex:test_install_projection(Projection0, quod_simplex:test_state(
               #{ns => Ns, genesis_hash => element(2, Identity), self => Author, id => Signer,
                 consensus_domain => Domain, store => Store, signing_journal => J2,
                 phase_index => Index, slot => 1, last_applied => 1, sync => ready,
                 prolog_ready => true, archive_tip => {Root, 0},
                 eng => quod_simplex:eng_new(Domain, Committee, {Root, 1, 0})})),
        S1 = quod_simplex:test_seed_dtx_submission(C2, [{dtx_endpoint, self()}], S0),
        Both = quod_simplex:test_seed_dtx_submission(C1, [], S1),
        ?assertEqual(lists:sort([G1, G2]), lists:sort(maps:keys(
                         quod_signing_journal:pending_dtx(J2)))),
        Before = quod_simplex:test_state_projection(Both),
        {Block, Entry} = certified_entry(Identity, C1, Identities, Committee),
        ?assertEqual(ok, quod_ct:verify_finality(Identity, Entry, Before)),
        Bytes = quod_ledger:block_bytes(Block),
        {ok, AfterProjection, Delta, Summary} = quod_ct:with_network_identity(maps:get(network, First),
          fun() -> quod_catchup:verify_forward_group(Identity, [Entry], Before, Index,
              {fun([]) -> done; ([B]) -> {ok, B, []} end, [Bytes]}) end),
        Verified = #{entries => [Entry], projection => AfterProjection, delta => Delta, finality => Summary,
                     proof => {quod_ledger_store:proof_frame_size(Bytes),
                               fun([]) -> done; ([B]) -> {B, []} end, [Bytes]}},
        _ = receiver_messages(Receiver),
        Dispatched = apply_scenario(Mode, Block, Entry, Before, Verified,
                               OtherPeers, Identities, Domain, Both),
        Messages = receiver_messages(Receiver),
        assert_order(Mode, Entry, Ref1, G1, Messages),
        ?assertEqual([Ref1], [R || {dtx_group_resolved, R} <- Messages]),
        ?assertNot(lists:member({dtx_group_resolved, Ref2}, Messages)),
        ?assertNot(maps:is_key(dtx_pending, quod_simplex:test_state_projection(Dispatched))),
        ?assertEqual([], quod_simplex:test_eligible_dtx_wave(Dispatched)),
        %% This receiver records casts; it does not run a Prolog engine. After
        %% its delivery barrier, inject the installed change at the production
        %% owner callback. Real reducer/publication is covered separately.
        Changes = maps:from_keys(quod_selection_basis:reservation_keys(M1), true),
        Applied = quod_simplex:on_admission_parent_applied(Receiver,
                    {{2, quod_simplex:entry_history_hash(Entry)}, Changes}, Dispatched),
        After = quod_simplex:test_refresh_retained_readiness(Applied),
        %% The installed conflicting parent invalidates only the selection. The exact
        %% pending Vote and its waiter transfer to the same admission FIFO;
        %% no new signature or fabricated conflict refusal can escape here.
        ?assertMatch(#{retained := 0}, quod_simplex:test_retained_dtx_state(After)),
        ?assertMatch(#{active := 1}, quod_simplex:test_dtx_admission_state(After)),
        JAfter = quod_simplex:test_signing_journal(After),
        Pending = quod_signing_journal:pending_dtx(JAfter),
        ?assertEqual([G2], maps:keys(Pending)),
        #{G2 := #{sequence := 1, envelope := Envelope}} = Pending,
        ?assertEqual({ok, C2}, quod_atomic:decode_control(Envelope)),
        ?assertEqual(2, quod_signing_journal:dtx_floor(JAfter, Lane)),
        receive {dtx_submit_result, Reply} -> error({uncommitted_vote_released, Reply})
        after 0 -> ok end,
        ok = quod_signing_journal:close(JAfter),
        {ok, Reopened} = quod_signing_journal:recover(Ns, Domain, Dir),
        try
            ?assertEqual(Pending, quod_signing_journal:pending_dtx(Reopened)),
            ?assertEqual(2, quod_signing_journal:dtx_floor(Reopened, Lane))
        after ok = quod_signing_journal:close(Reopened) end,
        _ = quod_simplex:test_stop_dtx_coordinator(After)
    after
        catch quod_signing_journal:close(J0),
        catch quod_dtx_phase_index:close(Index),
        catch quod_ledger_store:close(Store0),
        stop_receiver(Receiver, Monitor),
        ok = file:del_dir_r(Dir),
        receive dtx_drive -> ok after 0 -> ok end
    end.

apply_scenario(live, Block, _Entry, Before, _After, OtherPeers,
               Identities, Domain, S0) ->
    Hash = quod_simplex:block_hash(Block),
    Parent = maps:get(history_head, Before),
    {Monitor, Pending} = quod_simplex:test_latch_dtx_validation(
                           Block#block.slot, Hash, Parent, self(), Block, S0),
    %% A fresh group's verified history is empty. The production verdict
    %% handler still previews this exact signed Vote against its parent.
    Supported = quod_simplex:test_on_dtx_verdict(
                  Block#block.slot, Hash, Parent, self(), 1, {valid, #{}}, Pending),
    ?assertNot(erlang:demonitor(Monitor, [info])),
    {_Validating, _Validation, _Candidate,
     {Hash, Parent, #{}, ParentDtx}, _RetainedBlock} =
        quod_simplex:test_dtx_round(Block#block.slot, Supported),
    ?assertEqual(maps:get(dtx, Before), ParentDtx),
    %% The local share plus two authenticated peers reaches each real
    %% threshold. The final dispatch enters commit_block, not a test fold.
    Peers = lists:sublist(OtherPeers, 2),
    lists:foldl(
      fun({Kind, Peer}, S) ->
          Share = quod_simplex:make_share(
                    Domain, Kind, {Block#block.era, Block#block.slot}, Hash, maps:get(Peer, Identities)),
          quod_simplex:dispatch(Peer, {share, Share}, S)
      end, Supported,
      [{Kind, Peer} || Kind <- [support, commit], Peer <- Peers]);
apply_scenario(catchup, _Block, _Entry, _Before, Verified, _Peers,
               _Identities, _Domain, S0) ->
    {S, ok} = quod_simplex:test_apply_catchup_window(
                {recovery, self()}, Verified, S0),
    S;
apply_scenario(catchup_paused, Block, Entry, Before, After, Peers,
               Identities, Domain, S0) ->
    Pulling = quod_simplex:test_state_set(sync, {pulling, self()}, S0),
    apply_scenario(catchup, Block, Entry, Before, After, Peers, Identities, Domain, Pulling).

assert_order(Mode, Entry, GroupRef, _GroupId, Messages) ->
    Resolutions = [I || {I, {dtx_group_resolved, Ref}} <- numbered(Messages),
                         Ref =:= GroupRef],
    ?assertEqual(1, length(Resolutions)),
    [ResolvedAt] = Resolutions,
    EmptyProjections =
        [I || {I, {project_pending_votes, Rows}} <- numbered(Messages),
              not lists:member(GroupRef, Rows)],
    ?assertNotEqual([], EmptyProjections),
    ?assert(lists:last(EmptyProjections) < ResolvedAt),
    [{AppliedAt, ActualEntry, Origin}] =
        [{I, E, O} || {I, {apply_entry, E, O}} <- numbered(Messages)],
    ?assertEqual(quod_ledger:encode_entry(Entry), quod_ledger:encode_entry(ActualEntry)),
    ?assertEqual(case Mode of live -> live; _ -> replay end, Origin),
    case AppliedAt < ResolvedAt of
        true -> ok;
        false -> error({resolution_before_apply, Mode, Messages})
    end,
    ?assert(lists:last(EmptyProjections) < AppliedAt).

numbered(Messages) -> lists:zip(lists:seq(1, length(Messages)), Messages).

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

certified_entry({Ns, Anchor} = Identity, Control, Identities, Committee) ->
    Era = quod_ledger:initial_era(Identity),
    {ok, Block} = quod_ledger:new_block(
                    {Era, 1}, {Era, 0, Anchor}, 2, {batch, [{dtx, Control}]}, quod_time:now_ms()),
    Hash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Shares = [quod_simplex:make_share(
                Domain, commit, {Era, 1}, Hash, maps:get(Key, Identities))
              || Key <- lists:sublist(Committee, 3)],
    {ok, Cert} = quod_simplex:form_cert(Domain, commit, {Era, 1}, Hash, Shares, Committee),
    {Block, quod_ledger:entry(2, Block, Cert)}.

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
