-module(quod_entry_selection_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

served_page_authenticates_at_consumption_not_on_both_ends_test() ->
    with_served_entry(fun(Ns, Store, Entry, Bytes, _Dir) ->
        Snapshot = quod_ledger_store:snapshot(Store),
        {{ok, [Bytes], 2}, ServeCount} = counted(fun() ->
            quod_catchup:serve_blocks(Ns, Snapshot, 2, 2)
        end),
        ?assertEqual(0, ServeCount),
        {{ok, [Entry]}, ReceiveCount} = counted(fun() -> quod_catchup:decode_entries([Bytes], wrapped) end),
        ?assertEqual(56, ReceiveCount),
        {{ok, [Entry], 2}, LocalCount} = counted(fun() ->
            {ok, Reader} = quod_ledger_store:open_ro_snapshot(Snapshot),
            try quod_catchup:read_blocks(Reader, 2, 2)
            after quod_ledger_store:close(Reader) end
        end),
        ?assertEqual(56, LocalCount),
        ?assertEqual({error, bad_entry}, quod_ledger:encode_entry(Bytes)),
        ?assertException(error, function_clause, quod_ledger:entry_view(Bytes)),
        {ok, Third} = quod_ledger:new_entry(3, noop, 0, none),
        {ok, _Advanced} = quod_ledger_store:append(Store, [Third]),
        ?assertEqual({ok, [Bytes], 2}, quod_catchup:serve_blocks(Ns, Snapshot, 2, 3))
    end).

served_page_retains_signature_checks_at_consumption_test() ->
    with_served_entry(fun(Ns, Store, _Entry, Bytes, Dir) ->
        {I, Parent, [{transaction, First} | Rest], Time, Cert} = unpack(Bytes),
        Bad = pack(I, Parent, [{transaction, bad_signature(First)} | Rest], Time, Cert),
        %% CRC-valid altered storage is still only transport data. The server
        %% grants no authority; its receiver must reject the invalid signature.
        rewrite_served_frame(Ns, Store, Dir, frame(Bad)),
        ?assertEqual({ok, [Bad], 2}, quod_catchup:serve_blocks(Ns, quod_ledger_store:snapshot(Store), 2, 2)),
        ?assertEqual({error, bad_frame}, quod_catchup:decode_entries([Bad], wrapped)),
        ?assertException(error, {corrupt_entry, 2, bad_entry}, quod_ledger_store:read_range(Store, 2, 2, all))
    end).

served_implicit_child_is_authenticated_by_the_receiver_test() ->
    with_served_entry(fun(Ns, Store, _Entry, Bytes, Dir) ->
        {I, _Parent, [{transaction, First} | Rest], Time, Cert} = unpack(Bytes),
        {quod_entry, 1, I, BlockBytes, _} = binary_to_term(Bytes, [safe]),
        Child = canonical({quod_block, 1, I+1, I,
                           {batch, [{transaction, bad_signature(First)} | Rest]}, Time}),
        Bad = canonical({quod_entry, 1, I, BlockBytes, {implicit, Cert, Child, Cert}}),
        rewrite_served_frame(Ns, Store, Dir, frame(Bad)),
        ?assertEqual({ok, [Bad], 2}, quod_catchup:serve_blocks(Ns, quod_ledger_store:snapshot(Store), 2, 2)),
        ?assertEqual({error, bad_frame}, quod_catchup:decode_entries([Bad], wrapped))
    end).

served_page_frame_integrity_test_() ->
    [{atom_to_list(Case), fun() -> with_served_entry(fun(Ns, Store, _Entry, Bytes, Dir) ->
        BadFrame = case Case of
            wrong_index ->
                {quod_entry, 1, 2, B, C} = binary_to_term(Bytes, [safe]),
                frame(canonical({quod_entry, 1, 9, B, C}));
            bad_crc ->
                <<Magic:32, Len:32, CRC:32, Body/binary>> = frame(Bytes),
                <<Magic:32, Len:32, (CRC bxor 1):32, Body/binary>>;
            truncated -> binary:part(frame(Bytes), 0, byte_size(Bytes) + 11)
        end,
        rewrite_served_frame(Ns, Store, Dir, BadFrame),
        Result = quod_catchup:serve_blocks(Ns, quod_ledger_store:snapshot(Store), 2, 2),
        case Case of
            %% Snapshot resume rejects a shortened file before the cursor runs.
            truncated -> ?assertEqual({error, changed}, Result);
            _ -> ?assertMatch({error, {corrupt_entry, 2, _}}, Result)
        end
    end) end} || Case <- [wrong_index, bad_crc, truncated]].

with_served_entry(Fun) ->
    {{Ns, _}, _Signer, Entry, Bytes} = fixture(),
    Dir = filename:join("/tmp", "quod-served-page-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir, wrapped),
    {ok, Genesis} = quod_ledger:new_entry(1, noop, 0, none),
    try
        {ok, Store} = quod_ledger_store:append(Store0, [Genesis, Entry]),
        Fun(Ns, Store, Entry, Bytes, Dir)
    after quod_ledger_store:close(Store0), file:del_dir_r(Dir) end.

rewrite_served_frame(Ns, Store, Dir, Frame) ->
    {ok, First} = quod_ledger_store:read_at(Store, 1),
    {ok, Bytes} = quod_ledger:encode_entry(First),
    Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "log.0001"),
    ok = file:write_file(Path, <<(frame(Bytes))/binary, Frame/binary>>).

frame(Bytes) -> <<16#915106B0:32, (byte_size(Bytes)):32, (erlang:crc32(Bytes)):32, Bytes/binary>>.

%% Real signed two-target claims and applications, not a claim of consensus
%% admission. Each item has its own proof/request; the one-member QC is real.
selected_item_authenticates_seven_authorities_not_the_whole_batch_test() ->
    {Identity, Signer, Entry, Bytes} = fixture(),
    {{ok, Full}, FullCount} = counted(fun() -> quod_ledger:decode_entry(Bytes, wrapped) end),
    #entry{data = {batch, [Tx | _]}} = quod_ledger:entry_view(Full),
    {{ok, Selected}, Count} = counted(fun() ->
        quod_ledger:select_entry(Bytes, {application, Tx#transaction.tx_id}, wrapped)
    end),
    ?assertEqual(56, FullCount),
    ?assertEqual(7, Count),
    ?assertEqual(Tx, quod_ledger:selected_record(Selected)),
    ?assertEqual(quod_ledger:record_commitment(Full, Tx),
                 quod_ledger:record_commitment(Selected, Tx)),
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Full, Tx),
    ?assert(quod_dtx:certified_entry_ref_matches(Identity, Selected, Tx, Ref,
                                              [maps:get(pubkey, Signer)])),
    ?assertEqual({ok, Bytes}, quod_ledger:encode_entry(Entry)),
    ?assertEqual({error, bad_entry}, quod_ledger:encode_entry(Selected)),
    ?assertException(error, function_clause, quod_ledger:entry_view(Selected)),
    ?assertEqual(error, quod_ledger:block_from_entry(Selected)).

unselected_bytes_still_bind_the_certificate_test() ->
    {Identity, Signer, _Entry, Bytes} = fixture(),
    {I, Parent, [First, {transaction, Other} | Rest], Time, Cert} = unpack(Bytes),
    {transaction, FirstBytes} = First,
    {ok, Tx} = quod_transaction:decode_ledger_transaction(FirstBytes, wrapped),
    Select = {application, Tx#transaction.tx_id},
    {ok, Good} = quod_ledger:select_entry(Bytes, Select, wrapped),
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Good, Tx),
    BadBytes = pack(I, Parent, [First, {transaction, bad_signature(Other)} | Rest], Time, Cert),
    {ok, Bad} = quod_ledger:select_entry(BadBytes, Select, wrapped),
    ?assertEqual(Tx, quod_ledger:selected_record(Bad)),
    ?assertNot(quod_dtx:certified_entry_ref_matches(Identity, Bad, Tx, Ref,
                                                 [maps:get(pubkey, Signer)])),
    ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(BadBytes, wrapped)),
    BadSelected = pack(I, Parent, [{transaction, bad_signature(FirstBytes)} | Rest], Time, Cert),
    ?assertEqual({error, bad_entry}, quod_ledger:select_entry(BadSelected, Select, wrapped)),
    %% The immutable reference core does not authenticate each caller's proof.
    BadCert = Cert#cert{sigs = [{maps:get(pubkey, Signer), <<0:512>>}]},
    BadRef = setelement(8, Ref, canonical(BadCert)),
    ?assert(quod_dtx:same_certified_ref(Ref, BadRef)),
    ?assertNot(quod_dtx:certified_entry_ref_matches(Identity, Good, Tx, BadRef,
                                                 [maps:get(pubkey, Signer)])).

carried_entry_decodes_only_its_selected_application_test() ->
    {Identity, Signer, Full, Bytes} = fixture(),
    #entry{data = {batch, [Tx | _]}} = quod_ledger:entry_view(Full),
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Full, Tx),
    {ok, Selected} = quod_ledger:select_entry(Full, {application, Tx#transaction.tx_id}, wrapped),
    {{ok, Wire}, EncodeChecks} = counted(fun() ->
        quod_dtx_endpoint:encode_validation_sidecar([{Ref, Selected}])
    end),
    ?assertEqual(0, EncodeChecks),
    {[{Ref, Received}], DecodeChecks} = counted(fun() ->
        quod_dtx_endpoint:decode_validation_sidecar(Wire)
    end),
    ?assertEqual(7, DecodeChecks),
    ?assertEqual({ok, Bytes}, quod_ledger:hint_bytes(Received)),
    ?assertEqual({error, bad_entry}, quod_ledger:encode_entry(Received)),
    ?assert(quod_dtx:certified_entry_ref_matches(Identity, Received, Tx, Ref,
                                              [maps:get(pubkey, Signer)])),
    %% Only actual prefix advancement materializes all eight applications.
    {{ok, Imported}, ImportChecks} = counted(fun() -> quod_ledger:materialize_hint(Received) end),
    ?assertEqual(56, ImportChecks),
    ?assertEqual({ok, Bytes}, quod_ledger:encode_entry(Imported)),
    {I, Parent, [First, {transaction, Other} | Rest], Time, Cert} = unpack(Bytes),
    BadBytes = pack(I, Parent, [First, {transaction, bad_signature(Other)} | Rest], Time, Cert),
    {ok, BadHint} = quod_ledger:select_entry(BadBytes, {application, Tx#transaction.tx_id}, wrapped),
    ?assertEqual({error, bad_entry}, quod_ledger:materialize_hint(BadHint)).

ambiguous_missing_and_wrong_slot_selections_fail_closed_test() ->
    {_, _, _, Bytes} = fixture(),
    {I, Parent, [First | _], Time, Cert} = unpack(Bytes),
    {transaction, Blob} = First,
    {ok, Tx} = quod_transaction:decode_ledger_transaction(Blob, wrapped),
    Select = {application, Tx#transaction.tx_id},
    {ok, Duplicate} = quod_ledger:select_entry(pack(I, Parent, [First, First], Time, Cert), Select, wrapped),
    ?assertEqual(none, quod_ledger:selected_record(Duplicate)),
    {ok, Missing} = quod_ledger:select_entry(Bytes, {application, <<0:256>>}, wrapped),
    ?assertEqual(none, quod_ledger:selected_record(Missing)),
    {quod_entry, 1, I, Block, Cert} = binary_to_term(Bytes, [safe]),
    ?assertEqual({error, bad_entry}, quod_ledger:select_entry(
                   canonical({quod_entry, 1, I + 1, Block, Cert}), Select, wrapped)).

request_and_native_material_bindings_survive_reuse_test() ->
    {_, _, _, Bytes} = fixture(),
    {_, _, [{transaction, Blob} | _], _, _} = unpack(Bytes),
    {ok, Tx} = quod_transaction:decode_ledger_transaction(Blob, wrapped),
    {Ref, Claim} = Tx#transaction.evidence,
    {agent_goal_v1, Digest, Request, Signature} = Claim#transaction.request_auth,
    BadAuth = Claim#transaction{request_auth = {agent_goal_v1, Digest, Request, flip(Signature)}},
    ?assertEqual(error, quod_transaction:request_claim(BadAuth)),
    ?assertEqual(error, quod_transaction:request_claim(Claim#transaction{goal = <<>>})),
    lists:foreach(fun(Bad) ->
        ?assertEqual(Tx#transaction.signed_bytes, Bad#transaction.signed_bytes),
        ?assertMatch({error, _}, quod_transaction:encode_ledger_transaction(Bad)),
        ?assertNot(quod_transaction:same_ledger_transaction(Tx, Bad))
    end, [Tx#transaction{diff = []}, Tx#transaction{sig = flip(Tx#transaction.sig)},
          Tx#transaction{evidence = {Ref, BadAuth}}]),
    ?assertEqual({ok, Blob}, quod_transaction:encode_ledger_transaction(Tx)).

operation_selectors_use_the_same_signed_identity_test() ->
    quod_operation_fixture:with(2, fun(F) ->
        Source = maps:get(source_store, F), Ref = maps:get(operation_ref, F),
        lists:foreach(fun({Slot, Selector, Field}) ->
            {ok, Entry} = quod_ledger_store:read_at(Source, Slot, {Selector, Ref}),
            Tx = quod_ledger:selected_record(Entry),
            ?assertEqual(maps:get(Field, F), Tx),
            ?assertEqual(Slot, quod_ledger:entry_index(Entry))
        end, [{2, claim, claim}, {3, completion, completion}]),
        ?assertEqual(not_found, quod_ledger_store:read_at(Source, 4, {claim, Ref})),
        {ok, Genesis} = quod_ledger_store:read_at(Source, 1),
        #entry{data = {batch, [G]}} = quod_ledger:entry_view(Genesis),
        {ok, Selected} = quod_ledger:select_entry(Genesis, {application, G#transaction.tx_id}, wrapped),
        ?assertEqual(quod_dtx:certified_entry_ref(maps:get(origin, F), Genesis, G),
                     quod_dtx:certified_entry_ref(maps:get(origin, F), Selected, G))
    end).

fixture() ->
    {Key, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Key, key => quod_identity:key_term({Key, Seed})},
    Origin = {<<"quod:selection-source">>, <<31:256>>},
    Target = {Ns, Anchor} = {<<"quod:selection-target">>, <<32:256>>},
    Txs = [begin
        F = quod_ct:signed_plan_fixture(#{target => Origin, participant_target => Target,
              node_identity => Signer, proof_id => <<I:256>>, provenance => 2}, [Origin, Target]),
        Admission = maps:get(admission, F),
        C0 = quod_transaction:remote_claim(Origin, maps:get(manifest, F), maps:get(bundles, F), maps:get(auth, F), []),
        {ok, Claim} = quod_transaction:sign({element(1, Origin), element(2, Origin), Admission},
          C0#transaction{author = Key, author_seq = I}, Signer),
        {ok, ClaimRef} = quod_dtx:certified_ref(element(1, Origin), element(2, Origin), 2,
                                              <<33:256>>, Claim#transaction.tx_id, <<"qc">>),
        A0 = quod_transaction:attach_evidence(quod_transaction:remote_application(
                 quod_transaction:stable_ref(ClaimRef), Claim, Target), ClaimRef, Claim),
        {ok, App} = quod_transaction:sign({Ns, Anchor, Admission},
                                          A0#transaction{author = Key, author_seq = I}, Signer), App
    end || I <- lists:seq(1, 8)],
    {ok, Block} = quod_ledger:new_block(2, 1, {batch, Txs}, 2),
    Hash = quod_simplex:block_hash(Block),
    #share{sig = Sig} = quod_simplex:make_share(quod_simplex:consensus_domain(Ns, Anchor), commit, 2, Hash, Signer),
    Entry = quod_ledger:entry(Block, #cert{kind = commit, slot = 2, block_hash = Hash, sigs = [{Key, Sig}]}),
    {ok, Bytes} = quod_ledger:encode_entry(Entry),
    {Target, Signer, Entry, Bytes}.

unpack(Bytes) ->
    {quod_entry, 1, I, Block, Cert} = binary_to_term(Bytes, [safe]),
    {quod_block, 1, I, Parent, {batch, Items}, Time} = binary_to_term(Block, [safe]),
    {I, Parent, Items, Time, Cert}.
pack(I, Parent, Items, Time, Cert) ->
    canonical({quod_entry, 1, I, canonical({quod_block, 1, I, Parent, {batch, Items}, Time}), Cert}).
canonical(Term) -> term_to_binary(Term, [deterministic]).
bad_signature(Blob) ->
    {submit, A, S, B} = binary_to_term(Blob, [safe]), canonical({submit, A, flip(S), B}).
flip(<<B, Rest/binary>>) -> <<(B bxor 1), Rest/binary>>.
counted(Fun) ->
    {module, crypto} = code:ensure_loaded(crypto),
    {Result, {call_count, Rows}} = tprof:profile(Fun, #{type => call_count, report => return,
      pattern => [{crypto, verify, 5}], timeout => 30000}),
    {Result, lists:sum([N || {crypto, verify, 5, Ps} <- Rows, {_, N, _} <- Ps])}.
