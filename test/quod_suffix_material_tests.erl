-module(quod_suffix_material_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

signature_counts_exclude_other_owners_test() ->
    {Pub, _} = Pair = quod_identity:generate(),
    Bytes = <<"signature counter isolation">>,
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(Pair)),
    Other = spawn(fun() ->
        receive {verify, ReplyTo} ->
            ReplyTo ! {verified, self(), quod_identity:verify(Signature, Bytes, Pub)}
        end
    end),
    try
        {true, Counts} = counted(fun() ->
            Other ! {verify, self()},
            receive {verified, Other, true} -> ok
            after 1000 -> error(other_verifier_did_not_finish) end,
            quod_identity:verify(Signature, Bytes, Pub)
        end),
        ?assertEqual(#{crypto => 1, request => 0}, Counts)
    after exit(Other, kill) end.

%% Real signed content and founding-derived projections, not a witness of
%% consensus admission. The production suffix path must retain all semantic
%% checks while paying the already-checked transaction signatures only once.
suffix_checks_finality_without_reauthenticating_content_test_() ->
    {timeout, 30, fun() ->
        lists:foreach(fun(N) -> quod_operation_fixture:with(N, fun(F) ->
            Origin = maps:get(origin, F),
            {ok, ClaimEntry} = quod_ledger_store:read_at(maps:get(source_store, F), 2),
            Before = maps:get(source_projection, F),
            {ok, After} = quod_simplex:history_validate_advance(Origin, ClaimEntry, Before),
            lists:foreach(fun({Target, Entry, Projection}) ->
                {ok, Bytes} = quod_ledger:encode_entry(Entry),
                {{ok, Decoded}, DecodeCounts} = counted(fun() ->
                    quod_ledger:decode_entry(Bytes, wrapped)
                end),
                {{ok, Received}, Counts} = receive_group(Target, Projection, Bytes, Entry),
                ?assertEqual(Decoded, Received),
                %% Entry and proof share the same exact-envelope context.
                %% Beyond one payload decode, only the head QC is authenticated.
                ?assertEqual(maps:get(crypto, DecodeCounts) + 1, maps:get(crypto, Counts)),
                ?assertEqual(maps:get(request, DecodeCounts), maps:get(request, Counts)),
                ?assertEqual({ok, Bytes}, quod_ledger:encode_entry(Received))
            end, [{Origin, ClaimEntry, Before},
                  {Origin, maps:get(source_entry, F), After},
                  {maps:get(target, F), maps:get(entry, F), maps:get(projection, F)}])
        end) end, [1, 2, 4, 8])
    end}.

authentication_receipt_never_substitutes_for_binding_test() ->
    quod_operation_fixture:with(2, fun(F) ->
        App = maps:get(application, F),
        Target = {Ns, Anchor} = maps:get(target, F),
        {ok, Binding} = quod_simplex:history_binding(
            Target, App#transaction.author, maps:get(projection, F)),
        {ok, Bytes} = quod_transaction:encode_ledger_transaction(App),
        {ok, Tx} = quod_transaction:decode_ledger_transaction(Bytes, wrapped),
        ?assertEqual(App#transaction.authentication, Tx#transaction.authentication),
        {true, #{crypto := 0}} = counted(fun() -> quod_transaction:verify(Binding, Tx) end),
        %% A native view without the codec receipt still authenticates normally.
        Raw = Tx#transaction{authentication = none},
        {true, #{crypto := 1}} = counted(fun() -> quod_transaction:verify(Binding, Raw) end),
        ?assertEqual({ok, Bytes}, quod_transaction:encode_ledger_transaction(Raw)),
        {Ref, Claim} = Tx#transaction.evidence,
        {agent_goal_v1, Digest, Request, Signature} = Claim#transaction.request_auth,
        BadClaim = Claim#transaction{request_auth =
            {agent_goal_v1, Digest, Request, flip(Signature)}},
        lists:foreach(fun(Bad) ->
            ?assertNot(quod_transaction:verify(Binding, Bad)),
            ?assertMatch({error, _}, quod_transaction:encode_ledger_transaction(Bad))
        end, [Tx#transaction{author = <<0:256>>},
              Tx#transaction{sig = flip(Tx#transaction.sig)},
              Tx#transaction{signed_bytes = flip(Tx#transaction.signed_bytes)},
              Tx#transaction{diff = []}, Tx#transaction{author_seq = 99},
              Tx#transaction{evidence = {Ref, BadClaim}},
              Tx#transaction{goal = <<>>},
              Tx#transaction{read_check = #{{changed, 0} => absent}}]),
        ?assertNot(quod_transaction:verify({Ns, Anchor, <<0:256>>}, Tx)),
        ?assertNot(quod_transaction:verify({Ns, <<0:256>>, element(3, Binding)}, Tx)),
        ?assertNot(quod_transaction:verify({<<"another">>, Anchor, element(3, Binding)}, Tx))
    end).

request_context_is_rechecked_without_reverifying_signature_test() ->
    quod_operation_fixture:with(2, fun(F) ->
        {ok, Bytes} = quod_transaction:encode_ledger_transaction(maps:get(claim, F)),
        {ok, Claim} = quod_transaction:decode_ledger_transaction(Bytes, wrapped),
        Network = maps:get(network, F), Origin = maps:get(origin, F),
        {agent_goal_v1, _, RequestBytes, _} = Claim#transaction.request_auth,
        {ok, #{not_after_ms := Expiry}} = quod_client_goal:decode(RequestBytes),
        {{ok, _}, #{crypto := 0, request := 0}} = counted(fun() ->
            quod_transaction:validate_request(Network, Origin, Expiry, Claim)
        end),
        ?assertEqual({error, expired}, quod_transaction:validate_request(Network, Origin, Expiry + 1, Claim)),
        ?assertEqual({error, wrong_network}, quod_transaction:validate_request(<<0:256>>, Origin, Expiry, Claim)),
        ?assertEqual({error, invalid_request_binding},
            quod_transaction:validate_request(Network, {element(1, Origin), <<0:256>>}, Expiry, Claim)),
        lists:foreach(fun(Bad) ->
            ?assertEqual({error, invalid_request_binding},
                quod_transaction:validate_request(Network, Origin, Expiry, Bad))
        end, [Claim#transaction{goal = <<>>}, Claim#transaction{claim_view = none}])
    end).

history_still_rejects_wrong_admission_and_invalid_finality_test() ->
    quod_operation_fixture:with(2, fun(F) ->
        Target = maps:get(target, F),
        {ok, Bytes} = quod_ledger:encode_entry(maps:get(entry, F)),
        {ok, Entry} = quod_ledger:decode_entry(Bytes, wrapped),
        Projection = maps:get(projection, F),
        Author = (maps:get(application, F))#transaction.author,
        BadProjection = Projection#{admissions := #{Author => <<0:256>>}},
        ?assertEqual({error, {invalid_transaction, 2}},
            quod_simplex:history_validate_advance(Target, Entry, BadProjection)),
        {quod_entry, 2, I, Block, Cert} = binary_to_term(Bytes, [safe]),
        {quod_finality, 1, Era, View, Hash, _} = Cert,
        BadCert = {quod_finality, 1, Era, View, Hash, [{Author, <<0:512>>}]},
        {ok, Bad} = quod_ledger:decode_entry(
            term_to_binary({quod_entry, 2, I, Block, BadCert}, [deterministic]), wrapped),
        ?assertEqual({error, {bad_cert, 2}},
            quod_ct:verify_finality(Target, Bad, Projection))
    end).

wire_never_carries_or_accepts_authentication_receipts_test() ->
    quod_operation_fixture:with(2, fun(F) ->
        Tx = maps:get(application, F),
        {ok, Bytes} = quod_transaction:encode_ledger_transaction(Tx),
        {submit, Author, Signature, Canonical} = binary_to_term(Bytes, [safe]),
        ?assertEqual(Tx#transaction.signed_bytes, Canonical),
        ?assertMatch({error, _}, quod_transaction:decode_ledger_transaction(
            term_to_binary({submit, Author, flip(Signature), Canonical}, [deterministic]), wrapped)),
        ?assertMatch({error, _}, quod_transaction:decode_ledger_transaction(
            term_to_binary({submit, Author, flip(Signature), Canonical,
                            Tx#transaction.authentication}, [deterministic]), wrapped))
    end).

duplicate_dormant_handoff_keeps_exact_custody_test() ->
    with_custody(dormant, fun(Change, Admission, S0) ->
        Owner = self(),
        {ok, Submission, S1} = quod_simplex:test_register_dormant_transaction(
                                Admission, Change, Owner, S0),
        try
            ?assertEqual({ok, Submission, S1},
                without_resigning(fun() -> quod_simplex:test_register_dormant_transaction(
                  Admission, Change, Owner, S1) end)),
            ?assertError(transaction_custody_conflict,
                quod_simplex:test_register_dormant_transaction(
                  Admission, Change#transaction{submitted_at = 2}, Owner, S1)),
            ?assertEqual(1, map_size(quod_signing_journal:pending_transactions(
                                       quod_simplex:test_signing_journal(S1))))
        after
            #{dormant_owner := {_, Monitor}} =
                quod_simplex:test_custody_owner(Change#transaction.tx_id, S1),
            erlang:demonitor(Monitor, [flush])
        end
    end).

duplicate_effect_handoff_keeps_exact_custody_test() ->
    with_custody(effect, fun(Change, Admission, S0) ->
        From = {self(), make_ref()},
        {keep_state, S1, Actions1} = quod_simplex:running(
            {call, From}, {handoff_effect, Admission, Change}, S0),
        ?assert(lists:member({reply, From, ok}, Actions1)),
        {keep_state, S2, Actions2} = without_resigning(fun() -> quod_simplex:running(
            {call, From}, {handoff_effect, Admission, Change}, S1) end),
        ?assert(lists:member({reply, From, ok}, Actions2)),
        ?assertEqual(quod_simplex:test_custody(S1), quod_simplex:test_custody(S2)),
        ?assertEqual(quod_simplex:test_signing_journal(S1),
                     quod_simplex:test_signing_journal(S2)),
        ?assertEqual(1, map_size(quod_signing_journal:pending_transactions(
                                   quod_simplex:test_signing_journal(S2)))),
        TxId = Change#transaction.tx_id,
        ?assertError({transaction_signing_conflict, TxId},
            quod_simplex:running({call, From},
                {handoff_effect, Admission, Change#transaction{submitted_at = 2}}, S2))
    end).

%% Constructor-produced unsigned material, never a signed fixture with only
%% its signature cleared. Certified references are structural here: this pins
%% owner/journal custody, not consensus admission or certificate verification.
with_custody(Kind, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_ct:signed_effect_operation_submission(),
    Claim = #transaction{role = {remote_claim, Manifest, Bundles, _}} = maps:get(claim, F),
    Origin = {OriginNs, OriginAnchor} = maps:get(origin, F),
    {Target, Identity, Fresh} = case Kind of
        dormant ->
            {Origin, maps:get(source_identity, F),
             quod_transaction:remote_claim(Origin, Manifest, Bundles,
                 Claim#transaction.request_auth, Claim#transaction.foreign_reads)};
        effect ->
            ClaimRef = {transaction, OriginNs, OriginAnchor, Claim#transaction.tx_id},
            {ok, Certified} = quod_dtx:certified_ref(OriginNs, OriginAnchor,
                2, <<213:256>>, Claim#transaction.tx_id,
                quod_ct:fixture_finality(1, <<213:256>>)),
            Target0 = maps:get(target, F),
            {Target0, maps:get(target_identity, F),
             quod_transaction:attach_evidence(
                 quod_transaction:remote_application(ClaimRef, Claim, Target0), Certified, Claim)}
    end,
    #{pubkey := Author} = Identity,
    Change = Fresh#transaction{author = Author, submitted_at = 1},
    ?assertEqual(none, Change#transaction.authentication),
    {Ns, Anchor} = Target,
    Admission = maps:get(admission, F),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Dir = filename:join("/tmp", "quod_suffix_custody_" ++
                           binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Journal} = quod_signing_journal:initialize(Ns, Domain, Dir),
    try
        S0 = quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
            consensus_domain => Domain, self => Author, id => Identity,
            validators => [Author], author_admissions => #{Author => Admission},
            committee_id => <<215:256>>, sync => ready, prolog_ready => true,
            slot => 1, history_head => {1, Anchor},
            eng => quod_simplex:eng_new(Domain, [Author],
                {{quod_ledger:initial_era(Target), 0, Anchor}, 0}),
            store => memory, signing_journal => Journal}),
        Fun(Change, Admission, S0)
    after
        ok = quod_signing_journal:close(Journal),
        file:del_dir_r(Dir)
    end.

receive_group(Target = {Ns, _}, Projection, Bytes, Entry) ->
    Dir = filename:join("/tmp", "quod-suffix-receiver-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Index} = quod_dtx_phase_index:open(Dir, Ns),
    try
        quod_ledger_store:with_proof_stage(filename:join(Dir, "proof"), fun(Stage) ->
            Height = quod_ledger:entry_index(Entry),
            {ok, Block} = quod_ledger:block_from_entry(Entry),
            Parts = [{group, Height, Height}, {entry, Bytes},
                     {proof, quod_ledger:block_bytes(Block)}, end_group],
            Range = quod_catchup:range_begin(Target, Height, wrapped, Stage,
                                            none, Projection, Index),
            Install = fun(#{entries := [Installed], projection := P}, none) ->
                {ok, Installed, P, Index}
            end,
            counted(fun() ->
                case quod_catchup:range_accept(Range, Parts, Height, done, Install) of
                    {ok, Received} -> {ok, quod_catchup:range_context(Received)};
                    Error -> Error
                end
            end)
        end)
    after
        quod_dtx_phase_index:close(Index),
        file:del_dir_r(Dir)
    end.

without_resigning(Fun) ->
    {Result, {call_time, Rows}} = tprof:profile(Fun, #{type => call_time,
        set_on_spawn => false, report => return, pattern => {quod_identity, sign, 2}}),
    ?assertEqual(0, count(quod_identity, Rows)),
    Result.

flip(<<B, Rest/binary>>) -> <<(B bxor 1), Rest/binary>>.

counted(Fun) ->
    [{module, M} = code:ensure_loaded(M) || M <- [crypto, quod_client_goal]],
    %% call_count is VM-wide. call_time supplies per-process call counts;
    %% count only this verification, even while other owners authenticate.
    {Result, {call_time, Rows}} = tprof:profile(Fun, #{type => call_time,
        set_on_spawn => false, report => return, timeout => 30000,
        pattern => [{crypto, verify, 5}, {quod_client_goal, verify, 2}]}),
    {Result, #{crypto => count(crypto, Rows), request => count(quod_client_goal, Rows)}}.
count(Module, Rows) ->
    lists:sum([N || {M, _, _, Ps} <- Rows, M =:= Module, {_, N, _} <- Ps]).
