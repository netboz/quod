-module(quod_outcome_endpoint_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Real endpoint workers and owner transitions, with only the Prolog snapshot
%% reply held by a message-controlled fixture. No ledger timing is assumed.
replay_ready_at_unchanged_height_releases_the_same_request_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        assert_subscribed(F, Worker),
        gen_server:reply(From, {error, {ontology_rebuilding, maps:get(ns, F)}}),
        await_result(F, {error, not_ready}),
        ?assertEqual(1, worker_count(F)),
        update_owner(F, #{prolog_ready => true}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_outcome(F, outcome, 3),
        assert_worker_gone(F, Worker)
    end).

snapshot_result_racing_newer_head_is_resampled_test() ->
    with_endpoint(true, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        update_owner(F, #{slot => 4, last_applied => 4}),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(4)),
        assert_outcome(F, outcome, 4),
        assert_worker_gone(F, Worker)
    end).

unchanged_stale_snapshot_parks_without_a_resampling_loop_test() ->
    with_endpoint(true, fun(F) ->
        update_owner(F, #{slot => 4, last_applied => 4}),
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        assert_no_snapshot(F),
        ?assertEqual(1, worker_count(F)),
        Ns = maps:get(ns, F),
        quod_reg:publish({runtime, Ns}, {projection_advanced, self(), 3}),
        assert_no_snapshot(F),
        quod_reg:publish({runtime, Ns}, {projection_advanced, self(), 4}),
        {Worker, From3} = snapshot_call(F),
        gen_server:reply(From3, snapshot(4)),
        assert_outcome(F, outcome, 4),
        assert_worker_gone(F, Worker)
    end).

runtime_edge_queued_before_owner_decision_is_not_lost_test() ->
    with_endpoint(true, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        assert_subscribed(F, Worker),
        Ns = maps:get(ns, F),
        %% The subscription precedes the query. This ready edge arrives while
        %% the helper still awaits its first reply, before parent parking.
        quod_reg:publish({runtime, Ns}, {replay_ready, make_ref(), 3}),
        gen_server:reply(From, {error, {ontology_rebuilding, Ns}}),
        await_result(F, {error, not_ready}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_outcome(F, outcome, 3),
        assert_worker_gone(F, Worker)
    end).

wrong_anchor_or_era_is_refused_without_a_worker_test() ->
    with_endpoint(false, fun(F) ->
        Request = request(F, outcome),
        {transaction, Ns, _Anchor, TxId} = element(3, Request),
        BadAnchor = setelement(3, Request, {transaction, Ns, <<99:256>>, TxId}),
        BadEra = setelement(4, Request, <<98:256>>),
        ?assertEqual({error, not_ready}, admit(F, BadAnchor, 3000)),
        ?assertEqual({error, not_ready}, admit(F, BadEra, 3000)),
        ?assertEqual(0, worker_count(F)),
        ?assertEqual([], subscribers(F)),
        assert_no_snapshot(F)
    end).

parked_request_refuses_a_changed_committee_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        update_owner(F, #{committee_id => <<98:256>>}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_refused(F),
        assert_worker_gone(F, Worker)
    end).

parked_deadline_removes_worker_and_subscription_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 100),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        assert_refused(F),
        assert_worker_gone(F, Worker)
    end).

owner_death_releases_parked_worker_and_subscription_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        Monitor = monitor(process, Worker),
        exit(maps:get(owner, F), kill),
        receive {'DOWN', Monitor, process, Worker, normal} -> ok
        after 1000 -> error(worker_retained_after_owner_death)
        end,
        ?assertEqual([], subscribers(F))
    end).

operation_applied_pins_history_and_waits_for_durable_publication_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 3000),
        {Worker, From} = snapshot_call(F),
        assert_subscribed(F, Worker),
        assert_one_history_capture(F),
        %% Included bytes exist at slot 2, but the outcome owner has only
        %% published slot 1. Even a terminal-looking row is not signable yet.
        Pending = operation_snapshot(F, 1, committed),
        gen_server:reply(From, Pending),
        await_operation_snapshot(F, Pending),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, Pending),
        await_operation_snapshot(F, Pending),
        assert_no_reply(F),
        assert_no_snapshot(F),
        Ns = maps:get(ns, F),
        quod_reg:publish({runtime, Ns}, {projection_advanced, self(), 1}),
        assert_no_snapshot(F),
        quod_reg:publish({runtime, Ns}, {projection_advanced, self(), 2}),
        {Worker, From3} = snapshot_call(F),
        gen_server:reply(From3, operation_snapshot(F, 2, committed)),
        assert_operation_vote(F, applied),
        assert_worker_gone(F, Worker),
        assert_no_history_capture(F)
    end).

operation_applied_signs_historical_not_current_committee_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 3000),
        {Worker, From} = snapshot_call(F),
        %% Membership has advanced, but this signer belonged to the exact
        %% application's historical committee. A current committee cannot
        %% reinterpret the statement or substitute its identity.
        update_owner(F, #{committee_id => <<91:256>>, validators => [<<92:256>>]}),
        gen_server:reply(From, operation_snapshot(F, 2, {rejected, conflict_retry})),
        assert_operation_vote(F, {rejected, conflict_retry}),
        assert_worker_gone(F, Worker),
        assert_one_history_capture(F),
        assert_no_history_capture(F)
    end).

operation_applied_current_member_cannot_replace_historical_signer_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 3000),
        {Worker, From} = snapshot_call(F),
        {Pub, Seed} = quod_identity:generate(),
        update_owner(F, #{self => Pub, validators => [Pub],
                          id => #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}),
        gen_server:reply(From, operation_snapshot(F, 2, committed)),
        assert_refused(F),
        assert_worker_gone(F, Worker)
    end).

operation_applied_wrong_occurrence_is_not_signed_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 3000),
        {Worker, From} = snapshot_call(F),
        {ok, Snapshot = #{outcome := Row}} = operation_snapshot(F, 2, committed),
        gen_server:reply(From, {ok, Snapshot#{outcome := Row#{height := 1}}}),
        assert_refused(F),
        assert_worker_gone(F, Worker)
    end).

operation_applied_deadline_does_not_restart_while_parked_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 150),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, operation_snapshot(F, 1, committed)),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, operation_snapshot(F, 1, committed)),
        assert_refused(F),
        assert_worker_gone(F, Worker),
        assert_one_history_capture(F),
        assert_no_history_capture(F)
    end).

operation_applied_owner_death_releases_the_pinned_capture_test() ->
    with_operation_endpoint(fun(F) ->
        start_request(F, operation_applied, 3000),
        {Worker, From} = snapshot_call(F),
        Pending = operation_snapshot(F, 1, committed),
        gen_server:reply(From, Pending),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, Pending),
        await_operation_snapshot(F, Pending),
        M = monitor(process, Worker),
        exit(maps:get(owner, F), kill),
        receive {'DOWN', M, process, Worker, normal} -> ok
        after 1000 -> error(operation_worker_survived_owner)
        end,
        ?assertEqual([], subscribers(F)),
        assert_no_reply(F)
    end).

operation_collector_uses_the_real_endpoint_and_exact_result_test() ->
    with_operation_endpoint(fun(F = #{ns := Ns, target := Target,
      certified_target_ref := Ref, evidence := E0, network := Network}) ->
        E = E0#{routes => #{}}, Parent = self(),
        {Collector, M} = spawn_monitor(fun() ->
            Parent ! {collected, self(), quod_dtx_current_view:certify_operation_evidence(
              Ns, Target, Ref, E, none, quod_time:mono_ms() + 3000)}
        end),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, operation_snapshot(F, 2, {rejected, conflict_retry})),
        receive {collected, Collector, {ok, Ref, E, Cert}} ->
            ?assert(quod_applied_certificate:verify_operation_certificate(Cert, Network, E)),
            ?assertMatch({ok, #{result := {rejected, conflict_retry}}},
                         quod_applied_certificate:operation_certificate_binding(Cert))
        after 1000 -> error(collector_did_not_certify)
        end,
        receive {'DOWN', M, process, Collector, normal} -> ok after 1000 -> error(collector_retained) end,
        assert_worker_gone(F, Worker),
        assert_one_history_capture(F), assert_no_history_capture(F)
    end).

operation_collector_expiry_keeps_inclusion_but_invents_no_verdict_test() ->
    with_operation_endpoint(fun(F = #{ns := Ns, target := Target,
      certified_target_ref := Ref, evidence := E0}) ->
        E = E0#{routes => #{}}, Parent = self(),
        {Collector, M} = spawn_monitor(fun() ->
            Parent ! {collected, self(), quod_dtx_current_view:certify_operation_evidence(
              Ns, Target, Ref, E, none, quod_time:mono_ms() + 200)}
        end),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, operation_snapshot(F, 1, committed)),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, operation_snapshot(F, 1, committed)),
        receive {collected, Collector, {error, retry}} -> ok
        after 1000 -> error(expired_collector_invented_verdict)
        end,
        receive {'DOWN', M, process, Collector, normal} -> ok after 1000 -> error(collector_retained) end,
        %% The worker's existing deadline/owner protocol performs cleanup.
        assert_worker_gone(F, Worker)
    end).

target_endpoint_refuses_a_signed_vector_without_its_own_independent_seal_test() ->
    with_operation_endpoint(2, fun(F = #{target := Target, origin := {SourceNs, SourceAnchor} = Origin,
      claim := Claim, node_identity := Signer, admission := Admission, tag := Tag}) ->
        #transaction{role = {remote_claim, Manifest, Bundles, _}} = Claim,
        {_, Plan, _, _} = quod_transaction:remote_application_material(
            {transaction, SourceNs, SourceAnchor, Claim#transaction.tx_id}, Claim, Target),
        {ok, Ordinary} = quod_dtx:attest_plan(1, Target, Plan, Manifest, Signer),
        Own = lists:keyfind(Target, 1, Bundles),
        Refused0 = quod_transaction:remote_claim(Origin, Manifest,
          lists:keyreplace(Target, 1, Bundles, setelement(4, Own, Ordinary)),
          Claim#transaction.request_auth, []),
        {ok, Refused} = quod_transaction:sign({SourceNs, SourceAnchor, Admission},
          Refused0#transaction{author = maps:get(pubkey, Signer), author_seq = 1, submitted_at = 1}, Signer),
        Entry = quod_operation_fixture:entry(Origin, Signer, 2,
          {quod_ledger:initial_era(Origin), 0, SourceAnchor}, Refused),
        {ok, ClaimRef} = quod_dtx:certified_entry_ref(Origin, Entry, Refused),
        {ok, Blob} = quod_transaction:encode_evidence(ClaimRef, Refused),
        Id = maps:get(request_id, F),
        ?assertEqual(ok, admit(F, {apply_claim, Id, Target, Blob}, 3000)),
        receive {Tag, Reply} -> ?assertEqual({ok, {error, Id, independent_scope_required}, []}, Reply)
        after 1000 -> error(ordinary_target_seal_admitted)
        end,
        ?assertEqual(0, worker_count(F)),
        assert_no_snapshot(F), assert_no_history_capture(F),
        ?assertEqual(2, quod_ledger_store:last(maps:get(store, F)))
    end).

%% Real Prolog admission/apply and real endpoint workers; the consensus owner
%% interface is held, not a second consensus implementation. The signed fixture
%% history is deliberately not claimed as consensus-admitted (the CT redelivery
%% witness covers that). No receipt or unrelated block releases these callers.
exact_claim_reuses_live_consensus_custody_test() ->
    quod_operation_fixture:with(2, fun(#{target := {Ns, Anchor},
      projection := Projection, node_identity := Signer, application := Signed,
      claim := Claim, certified_claim_ref := ClaimRef}) ->
        {Ref, AlternateRef} = equivalent_claim_certificates(ClaimRef, Claim),
        Key = maps:get(pubkey, Signer),
        S0 = quod_simplex:test_state(#{ns => Ns, self => Key, id => Signer,
          genesis_hash => Anchor, validators => [Key], slot => 1,
          last_applied => 1, sync => ready, prolog_ready => true, store => memory,
          eng => quod_simplex:eng_new(quod_simplex:consensus_domain(Ns, Anchor),
                    [Key], {maps:get(protocol_root, Projection), element(1, maps:get(history_head, Projection)), 0})}),
        S = quod_simplex:test_install_projection(Projection, S0),
        Change = Signed#transaction{author_seq = 0, sig = none,
                                    signed_bytes = none, authentication = none,
                                    evidence = {Ref, Claim}},
        First = {self(), make_ref()}, Duplicate = {self(), make_ref()},
        {Owned, _} = quod_simplex:test_append(First, Change, S),
        [Original = {SubmissionId, 1, _, _, Deadline, _}] =
            quod_simplex:test_custody(Owned),
        Redelivery = Change#transaction{submitted_at = Change#transaction.submitted_at + 1},
        {Joined, [{reply, Duplicate, {ok, pending}}]} =
            quod_simplex:test_append(Duplicate, Redelivery, Owned),
        ?assertEqual([Original], quod_simplex:test_custody(Joined)),
        EquivalentFrom = {self(), make_ref()},
        {Equivalent, [{reply, EquivalentFrom, {ok, pending}}]} =
            quod_simplex:test_append(EquivalentFrom,
              Redelivery#transaction{evidence = {AlternateRef, Claim}}, Joined),
        ?assertEqual([Original], quod_simplex:test_custody(Equivalent)),
        %% Missing claim evidence is refused by ordinary ingress encoding
        %% before it can join the existing valid custody.
        BadFrom = {self(), make_ref()},
        {Unchanged, [{reply, BadFrom, {error, too_large}}]} =
            quod_simplex:test_append(BadFrom, Redelivery#transaction{evidence = none}, Equivalent),
        ?assertEqual([Original], quod_simplex:test_custody(Unchanged)),
        Expired = quod_simplex:test_expire_custody(Unchanged),
        ?assertEqual([], quod_simplex:test_custody(Expired)),
        FirstTag = element(2, First),
        receive {FirstTag, {error, not_in_charge, unavailable}} -> ok
        after 1000 -> error(custody_did_not_expire) end,
        {Resumed, _} = quod_simplex:test_append({self(), make_ref()}, Redelivery, Expired),
        [{NewSubmissionId, 2, _, _, NewDeadline, _}] = quod_simplex:test_custody(Resumed),
        ?assertNotEqual(SubmissionId, NewSubmissionId),
        ?assert(NewDeadline >= Deadline)
    end).

%% Independently valid quorum subsets certify the exact same claim/block.
%% As above, this is a custody-owner control, not source history admission.
equivalent_claim_certificates(
  {quod_dtx_ref, _, Ns, Anchor, Slot, _, _, _}, Claim) ->
    Signers = [begin
        {Key, Seed} = quod_identity:generate(),
        #{pubkey => Key, key => quod_identity:key_term({Key, Seed})}
    end || _ <- lists:seq(1, 4)],
    Committee = lists:sort([maps:get(pubkey, S) || S <- Signers]),
    Era = quod_ledger:initial_era({Ns, Anchor}),
    Position = {Era, Slot - 1},
    {ok, Block} = quod_ledger:new_block(Position, {Era, Slot - 2, Anchor},
                                      Slot, {batch, [Claim]}, Slot),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Hash = quod_simplex:block_hash(Block),
    Shares = maps:from_list([{maps:get(pubkey, S),
      quod_simplex:make_share(Domain, commit, Position, Hash, S)} || S <- Signers]),
    [A, B, C, D] = Committee,
    Make = fun(Keys) ->
        {ok, Cert} = quod_simplex:form_cert(Domain, commit, Position, Hash,
                       [maps:get(K, Shares) || K <- Keys], Committee),
        ?assert(quod_simplex:verify_cert(Domain, Cert, Committee)),
        Entry = quod_ledger:entry(Slot, Block, Cert),
        {ok, Ref} = quod_dtx:certified_entry_ref({Ns, Anchor}, Entry, Claim),
        ?assert(quod_dtx:certified_entry_claim_matches(
                  {Ns, Anchor}, Entry, Claim, Ref)),
        Ref
    end,
    Ref = Make([A, B, C]), Alternate = Make([B, C, D]),
    ?assertNotEqual(Ref, Alternate),
    ?assert(quod_dtx:same_certified_ref(Ref, Alternate)),
    {Ref, Alternate}.

%% Both deadline orders occur: caller custody normally ends first, but a
%% delivery refusal may arrive while callers still wait. Reopening the actual
%% DETS index must preserve the same uncertainty and deterministic application.
uncertain_claim_redelivery_test_() ->
    [{atom_to_list(Mode), fun() -> uncertain_claim_redelivery(Mode) end}
     || Mode <- [caller_expired, custody_expired, restarted]].

uncertain_claim_redelivery(Mode) ->
    with_claim_prolog(fun(F = #{target := Target, target_ref := TargetRef,
      entry := Entry}, Ns, Prolog, Config, Genesis, Bytes) ->
        A = maps:get(request_id, F), B = crypto:strong_rand_bytes(16),
        ok = admit(F, {apply_claim, A, Target, Bytes}, 3000),
        {First, FirstFrom} = claim_append(),
        OriginalTimer = quod_prolog:test_parked_timer(Prolog, First#transaction.tx_id),
        case Mode of
            custody_expired ->
                gen_statem:reply(FirstFrom, {error, not_in_charge, unavailable}),
                ?assertEqual(1, maps:get(parked, quod_prolog:stats(Ns)));
            _ ->
                await_claim_uncertainty(F, A),
                ?assertEqual(0, maps:get(parked, quod_prolog:stats(Ns))),
                %% The original alias has expired. Its later custody signal
                %% cannot be mistaken for the new delivery's completion.
                gen_statem:reply(FirstFrom, {error, not_in_charge, unavailable})
        end,
        Active = case Mode of
            restarted ->
                ok = gen_server:stop(Prolog),
                {ok, Restarted} = quod_prolog:start_link(Ns, Config),
                unlink(Restarted),
                ok = quod_prolog:apply_entry(Ns, Genesis, replay),
                ok = quod_prolog:mark_ready(Ns),
                Restarted;
            _ -> Prolog
        end,
        try
            ?assertMatch({ok, #{status := pending}}, quod_prolog:outcome(TargetRef)),
            ok = admit(F, {apply_claim, B, Target, Bytes}, 3000),
            {Resumed, ResumedFrom} = claim_append(),
            case Mode of
                custody_expired ->
                    ?assertEqual(OriginalTimer,
                        quod_prolog:test_parked_timer(Active, Resumed#transaction.tx_id));
                _ -> ok
            end,
            ?assertEqual(First#transaction{submitted_at = Resumed#transaction.submitted_at},
                         Resumed),
            %% A refusal of this delivery is NOT rejection of the earlier
            %% in-flight envelope. In particular it must not delete pending.
            gen_statem:reply(ResumedFrom, {error, busy}),
            ?assertEqual(1, maps:get(parked, quod_prolog:stats(Ns))),
            ?assertMatch({ok, #{status := pending}}, quod_prolog:outcome(TargetRef)),
            assert_no_reply(F),
            ok = quod_prolog:apply_entry(Ns, Entry, live),
            Ids = case Mode of custody_expired -> [A, B]; _ -> [B] end,
            lists:foreach(fun(Id) -> await_claim_committed(F, Id, TargetRef) end, Ids),
            ?assertMatch({ok, #{status := committed, height := 2}},
                         quod_prolog:outcome(TargetRef)),
            %% Terminal redelivery remains read-only and retains its first slot.
            C = crypto:strong_rand_bytes(16),
            ok = admit(F, {apply_claim, C, Target, Bytes}, 3000),
            await_claim_committed(F, C, TargetRef),
            receive {append_call, _, _} -> error(terminal_delivery_appended)
            after 0 -> ok end
        after gen_server:stop(Active) end
    end).

with_claim_prolog(Test) ->
    Diff = quod_prolog:terms_to_diff([{can_invoke, {'G'}, {'P'}, {'C'}, {'N'}}]),
    with_operation_endpoint(2, Diff, fun(F = #{target := {Ns, Anchor},
      store := Store, node_identity := Signer, claim := Claim,
      certified_claim_ref := ClaimRef}) ->
        stop_process(quod_reg:where({quod_prolog, Ns})),
        Table = ets:new(binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>),
                        [named_table, protected]),
        true = ets:insert(Table, {anchor, Anchor}),
        Dir = filename:join("/tmp", binary_to_list(Ns)),
        Config = #{node_id => maps:get(pubkey, Signer), identity => Signer,
                   outcome_backend => disk, ledger_dir => Dir,
                   transaction_ttl_ms => 500},
        {ok, Prolog} = quod_prolog:start_link(Ns, Config),
        unlink(Prolog),
        try
            {ok, [Genesis]} = quod_ledger_store:read_range(Store, 1, 1, all),
            ok = quod_prolog:apply_entry(Ns, Genesis, replay),
            ok = quod_prolog:mark_ready(Ns),
            {ok, Bytes} = quod_transaction:encode_evidence(ClaimRef, Claim),
            Test(F, Ns, Prolog, Config, Genesis, Bytes)
        after
            case quod_reg:where({quod_prolog, Ns}) of
                undefined -> ok;
                Current -> gen_server:stop(Current)
            end,
            ets:delete(Table), file:del_dir_r(Dir)
        end
    end).

claim_append() ->
    receive {append_call, Change, From} -> {Change, From}
    after 1000 -> error(exact_claim_has_no_submission_owner) end.

await_claim_uncertainty(#{tag := Tag}, Id) ->
    receive {Tag, {ok, {error, Id, not_ready}, _}} -> ok
    after 1500 -> error(missing_claim_uncertainty) end.

await_claim_committed(#{tag := Tag}, Id, TargetRef) ->
    receive {Tag, {ok, {application, Id, committed, Evidence}, _}} ->
        {ok, Ref, _} = quod_transaction:decode_evidence(Evidence),
        ?assertEqual(TargetRef, quod_transaction:stable_ref(Ref))
    after 1000 -> error(missing_claim_commit) end.

pending_application_joins_the_existing_owner_test_() ->
    [{atom_to_list(Mode), fun() -> pending_application_joins_owner(Mode) end}
     || Mode <- [committed, rejected, committed_before_apply]].
pending_application_joins_owner(Mode) ->
    Result = case Mode of committed_before_apply -> committed; _ -> Mode end,
    Diff = case Result of
        committed -> quod_prolog:terms_to_diff([{can_invoke, {'G'}, {'P'}, {'C'}, {'N'}}]);
        rejected -> []
    end,
    with_operation_endpoint(2, Diff, fun(F = #{target := {Ns, Anchor} = Target,
      store := Store, entry := Entry, node_identity := Signer,
      claim := Claim, certified_claim_ref := ClaimRef, target_ref := TargetRef}) ->
        stop_process(quod_reg:where({quod_prolog, Ns})),
        Table = ets:new(binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>),
                        [named_table, protected]),
        true = ets:insert(Table, {anchor, Anchor}),
        {ok, Prolog} = quod_prolog:start_link(Ns, #{node_id => maps:get(pubkey, Signer),
          identity => Signer, outcome_backend => memory}),
        unlink(Prolog),
        try
            {ok, [Genesis]} = quod_ledger_store:read_range(Store, 1, 1, all),
            ok = quod_prolog:apply_entry(Ns, Genesis, replay),
            ok = quod_prolog:mark_ready(Ns),
            ?assertEqual(1, quod_prolog:applied(Ns)),
            {ok, Bytes} = quod_transaction:encode_evidence(ClaimRef, Claim),
            A = maps:get(request_id, F), B = crypto:strong_rand_bytes(16),
            ?assertEqual(ok, admit(F, {apply_claim, A, Target, Bytes}, 3000)),
            receive {append_call, #transaction{tx_id = TxId}, AppendFrom} ->
                ?assertEqual(element(4, TargetRef), TxId),
                case Mode of
                    committed_before_apply -> gen_statem:reply(AppendFrom, {ok, 2});
                    _ -> ok
                end
            after 1000 -> error(no_first_admission) end,
            %% Same-sender call observes the reply before the next delivery;
            %% ordered apply is deliberately withheld until after admission.
            ?assertEqual(1, maps:get(parked, quod_prolog:stats(Ns))),
            erlang:trace_pattern({quod_prolog, admit_bound_plan, 9}, true, [local]),
            erlang:trace_pattern({quod_prolog, submit_plan, 7}, true, [local]),
            erlang:trace(Prolog, true, [call, {tracer, self()}]),
            ?assertEqual(ok, admit(F, {apply_claim, B, Target, Bytes}, 3000)),
            receive {trace, Prolog, call, {quod_prolog, admit_bound_plan, _}} -> ok
            after 1000 -> error(pending_delivery_bypassed_owner) end,
            ?assertEqual(1, maps:get(parked, quod_prolog:stats(Ns))),
            Barrier = erlang:trace_delivered(Prolog),
            receive {trace_delivered, Prolog, Barrier} -> ok after 1000 -> error(no_trace_barrier) end,
            receive {trace, Prolog, call, {quod_prolog, submit_plan, _}} ->
                error(duplicate_proposal) after 0 -> ok end,
            assert_no_reply(F),
            ok = quod_prolog:apply_entry(Ns, Entry, live),
            ?assertMatch({ok, #{outcome := #{status := Result}}},
                         quod_prolog:outcome_snapshot(Ns, TargetRef, 1000)),
            Expected = case Result of committed -> committed; rejected -> {rejected, not_authorized} end,
            Results = lists:map(fun(Id) ->
                Tag = maps:get(tag, F),
                receive {Tag, {ok, {application, Id, Expected, Evidence}, Sidecar}} ->
                    {ok, Ref, _} = quod_transaction:decode_evidence(Evidence),
                    ?assertEqual(TargetRef, quod_transaction:stable_ref(Ref)),
                    ?assertEqual(Sidecar, quod_dtx_endpoint:normalize_sidecar(Sidecar)),
                    ?assertMatch({Ref, _}, lists:keyfind(Ref, 1, Sidecar)),
                    VoteKey = {operation_vote, Ref, maps:get(pubkey, Signer)},
                    {VoteKey, {Statement, Signature}} = lists:keyfind(VoteKey, 1, Sidecar),
                    ?assert(quod_applied_certificate:verify_operation_vote(
                              Statement, maps:get(pubkey, Signer), Signature)),
                    Evidence;
                    {Tag, {ok, Reply, _Sidecar}} when element(2, Reply) =:= Id ->
                        error({unexpected_application_result, element(1, Reply)})
                after 1000 -> error({missing_own_block_result, Id}) end
            end, [A, B]),
            ?assertEqual(1, length(lists:usort(Results))),
            ?assertEqual(2, quod_prolog:applied(Ns)),
            ?assertEqual(0, maps:get(parked, quod_prolog:stats(Ns)))
        after
            erlang:trace_pattern({quod_prolog, admit_bound_plan, 9}, false, [local]),
            erlang:trace_pattern({quod_prolog, submit_plan, 7}, false, [local]),
            stop_process(Prolog), ets:delete(Table)
        end
    end).

with_operation_endpoint(Test) -> with_operation_endpoint(1, Test).
with_operation_endpoint(N, Test) -> with_operation_endpoint(N, [], Test).
with_operation_endpoint(N, GenesisDiff, Test) ->
    quod_operation_fixture:with(N, GenesisDiff, fun(F = #{target := {Ns, Anchor},
      store := Store, projection := P, entry := Entry, node_identity := Signer}) ->
        View = quod_operation_fixture:view(Store, P, Entry),
        S0 = quod_simplex:test_state(#{ns => Ns, self => maps:get(pubkey, Signer),
          id => Signer, genesis_hash => Anchor, store => Store, slot => 2,
          last_applied => 2, sync => ready, prolog_ready => true}),
        S = quod_simplex:test_install_projection(maps:get(projection, View), S0),
        with_endpoint_state(Ns, Anchor, maps:get(committee_id, P), S, F, Test)
    end).

with_endpoint(Ready, Test) ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"outcome-wait-", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    Anchor = <<11:256>>,
    Committee = <<12:256>>,
    Key = <<13:256>>,
    S = quod_simplex:test_state(#{ns => Ns, self => Key, validators => [Key],
          genesis_hash => Anchor, committee_id => Committee, slot => 3,
          last_applied => 3, sync => ready, prolog_ready => Ready, store => memory}),
    with_endpoint_state(Ns, Anchor, Committee, S, #{}, Test).

with_endpoint_state(Ns, Anchor, Committee, S, Extra, Test) ->
    Parent = self(),
    Stub = spawn(fun() ->
        true = quod_reg:reg({quod_prolog, Ns}),
        Parent ! {stub_ready, self()},
        prolog_stub(Ns, Parent)
    end),
    receive {stub_ready, Stub} -> ok after 1000 -> error(stub_not_ready) end,
    Owner = spawn(fun() ->
        true = quod_reg:reg({quod_simplex, Ns}),
        Parent ! {owner_ready, self()}, owner_loop(Parent, S)
    end),
    receive {owner_ready, Owner} -> ok after 1000 -> error(owner_not_ready) end,
    F = Extra#{ns => Ns, anchor => Anchor, committee => Committee, owner => Owner,
          tag => make_ref(), request_id => crypto:strong_rand_bytes(16)},
    try Test(F)
    after
        stop_process(Owner),
        stop_process(Stub)
    end.

prolog_stub(Ns, Parent) ->
    receive
        {'$gen_call', {Worker, _} = From, {outcome_snapshot, _Ref}} ->
            Parent ! {snapshot_call, Ns, Worker, From},
            prolog_stub(Ns, Parent)
    end.

owner_loop(Parent, S) ->
    receive
        {'$gen_call', From, {append, Change, _Trace}} ->
            Parent ! {append_call, Change, From}, owner_loop(Parent, S);
        {'$gen_call', From, {dtx_endpoint_local, Request, [], Timeout, _TraceCtx}} ->
            case quod_simplex:test_start_local_dtx_endpoint_request(Request, [], Timeout, From, S) of
                {ok, S1, Actions} -> reply_actions(Actions), owner_loop(Parent, S1);
                Error -> gen_statem:reply(From, Error), owner_loop(Parent, S)
            end;
        {'$gen_call', From, {history_view, Identity, Requirement, Deadline}} ->
            Result = quod_simplex:test_local_history_view(Identity, Requirement, Deadline, S),
            Parent ! {history_capture, self(), Identity, Requirement, Result},
            gen_statem:reply(From, Result),
            owner_loop(Parent, S);
        {call, Ref, {start, Request, Timeout, From}} ->
            case quod_simplex:test_start_local_dtx_endpoint_request(
                   Request, [], Timeout, From, S) of
                {ok, S1, Actions} ->
                    reply_actions(Actions), Parent ! {Ref, ok}, owner_loop(Parent, S1);
                Error -> Parent ! {Ref, Error}, owner_loop(Parent, S)
            end;
        {call, Ref, {update, Overrides}} ->
            S1 = maps:fold(fun quod_simplex:test_state_set/3, S, Overrides),
            ok = quod_simplex:test_wake_dtx_snapshot_workers(S, S1),
            Parent ! {Ref, ok}, owner_loop(Parent, S1);
        {call, Ref, count} ->
            Parent ! {Ref, maps:get(workers, quod_simplex:test_dtx_endpoint_counts(S))},
            owner_loop(Parent, S);
        {dtx_endpoint_worker_result, Worker, Result} ->
            {S1, Actions} = quod_simplex:test_finish_dtx_worker(Worker, Result, S),
            Parent ! {endpoint_result, self(), Result},
            reply_actions(Actions),
            owner_loop(Parent, S1);
        {'DOWN', _, process, _, _} -> owner_loop(Parent, S)
    end.

reply_actions(Actions) ->
    lists:foreach(fun({reply, From, Reply}) -> gen_statem:reply(From, Reply) end, Actions).

request(#{request_id := Id, certified_target_ref := Ref}, operation_applied) ->
    {operation_applied, Id, Ref};
request(F, outcome) ->
    #{ns := Ns, anchor := Anchor, committee := Cid, request_id := Id} = F,
    {outcome, Id, {transaction, Ns, Anchor, <<14:256>>}, Cid, 3}.

snapshot(Height) -> {ok, #{applied_floor => Height, outcome => not_found}}.

operation_snapshot(#{target_ref := Ref}, Floor, Verdict) ->
    Row = case Verdict of
        committed -> #{ref => Ref, height => 2, status => committed};
        {rejected, Reason} -> #{ref => Ref, height => 2, status => rejected, reason => Reason}
    end,
    {ok, #{applied_floor => Floor, outcome => Row}}.

await_operation_snapshot(#{owner := Owner}, {ok, Snapshot}) ->
    receive {endpoint_result, Owner, {operation_applied_state, _, Snapshot}} -> ok
    after 1000 -> error(operation_snapshot_not_processed)
    end.

assert_one_history_capture(#{owner := Owner, target := Target}) ->
    receive {history_capture, Owner, Target, any, {ok, #{slot := 2}}} -> ok;
            {history_capture, Owner, Identity, Requirement, Result} ->
                error({unexpected_history_capture, Identity, Requirement, Result})
    after 1000 -> error(no_exact_history_capture)
    end.
assert_no_history_capture(#{owner := Owner}) ->
    receive {history_capture, Owner, _, _, _} -> error(recaptured_pinned_history)
    after 0 -> ok
    end.
assert_no_reply(#{tag := Tag}) ->
    receive {Tag, Reply} -> error({signed_before_publication, Reply})
    after 0 -> ok
    end.
assert_operation_vote(F = #{tag := Tag, certified_target_ref := Ref, request_id := Id,
                            network := Network, evidence := Evidence}, Expected) ->
    receive {Tag, {ok, {operation_applied, Id, Ref, Statement, Key, Signature}, []}} ->
        ?assertEqual({ok, Statement}, quod_applied_certificate:operation_statement(Network, Evidence, Expected)),
        ?assertEqual(maps:get(pubkey, maps:get(node_identity, F)), Key),
        ?assert(quod_applied_certificate:verify_operation_vote(Statement, Key, Signature))
    after 1000 -> error(operation_vote_not_received)
    end.

start_request(F, Kind, Timeout) -> ?assertEqual(ok, admit(F, request(F, Kind), Timeout)).
admit(F, Request, Timeout) ->
    owner_call(F, {start, Request, Timeout, {self(), maps:get(tag, F)}}).
update_owner(F, Overrides) -> ?assertEqual(ok, owner_call(F, {update, Overrides})).
worker_count(F) -> owner_call(F, count).
owner_call(#{owner := Owner}, Message) ->
    Ref = make_ref(),
    Owner ! {call, Ref, Message},
    receive {Ref, Reply} -> Reply after 1000 -> error(owner_not_responding) end.

snapshot_call(#{ns := Ns}) ->
    receive {snapshot_call, Ns, Worker, From} -> {Worker, From}
    after 1000 -> error(snapshot_not_requested)
    end.
await_result(#{owner := Owner}, Result) ->
    receive {endpoint_result, Owner, Result} -> ok
    after 1000 -> error({result_not_processed, Result})
    end.
assert_no_snapshot(#{ns := Ns}) ->
    receive {snapshot_call, Ns, _, _} -> error(snapshot_spun_without_progress)
    after 30 -> ok
    end.
subscribers(#{ns := Ns}) -> gproc:lookup_pids({p, l, {runtime, Ns}}).
assert_subscribed(F, Worker) -> ?assertEqual([Worker], subscribers(F)).
assert_outcome(#{tag := Tag, request_id := Id, ns := Ns,
                 anchor := Anchor, committee := Cid}, Kind, Floor) ->
    receive {Tag, Reply} ->
        ?assertEqual({ok, {Kind, Id, {Ns, Anchor}, Cid, Floor, not_found}, []}, Reply)
    after 1000 -> error(endpoint_never_replied)
    end.
assert_refused(#{tag := Tag, request_id := Id}) ->
    receive {Tag, Reply} -> ?assertEqual({ok, {error, Id, not_ready}, []}, Reply)
    after 1000 -> error(endpoint_never_refused)
    end.
assert_worker_gone(F, Worker) ->
    Monitor = monitor(process, Worker),
    receive {'DOWN', Monitor, process, Worker, _} -> ok
    after 1000 -> error(worker_retained_after_reply)
    end,
    ?assertEqual(0, worker_count(F)),
    ?assertEqual([], subscribers(F)).
stop_process(Pid) ->
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(fixture_process_did_not_stop)
    end.
