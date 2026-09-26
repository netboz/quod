-module(quod_entry_selection_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

served_page_authenticates_at_consumption_not_on_both_ends_test() ->
    with_served_entry(fun(_Ns, Store, Entry, Bytes, _Dir) ->
        Snapshot = quod_ledger_store:snapshot(Store),
        {{ok, Parts, done}, ServeCount} = counted(fun() -> serve(Snapshot, 2, 2) end),
        ?assertEqual([Bytes], [B || {entry, B} <- Parts]),
        ?assertEqual(0, ServeCount),
        {{ok, Entry}, ReceiveCount} = counted(fun() -> quod_ledger:decode_entry(Bytes, wrapped) end),
        ?assertEqual(56, ReceiveCount),
        {{ok, [Entry], 2}, LocalCount} = counted(fun() ->
            {ok, Reader} = quod_ledger_store:open_ro_snapshot(Snapshot),
            try quod_catchup:read_blocks(Reader, 2, 2)
            after quod_ledger_store:close(Reader) end
        end),
        ?assertEqual(56, LocalCount),
        ?assertEqual({error, bad_entry}, quod_ledger:encode_entry(Bytes)),
        ?assertException(error, function_clause, quod_ledger:entry_view(Bytes)),
        {Identity, Signer, _, _} = fixture(),
        {ok, Block} = quod_ledger:block_from_entry(Entry),
        #entry{data = {batch, [Tx | _]}} = quod_ledger:entry_view(Entry),
        {Era, _, _} = quod_ledger:block_ref(Block),
        {ok, ThirdBlock} = quod_ledger:new_block({Era, 3}, quod_ledger:block_ref(Block), 3, {batch, [Tx]}, 3),
        Third = quod_ledger:entry(3, ThirdBlock, quod_ct:protocol_certificate(
            ThirdBlock, #{identity => Identity, signer => Signer})),
        {ok, _Advanced} = append_group(Store, Third, [ThirdBlock]),
        ?assertEqual({ok, Parts, done}, serve(Snapshot, 2, 3))
    end).

served_page_retains_signature_checks_at_consumption_test() ->
    with_served_entry(fun(Ns, Store, _Entry, Bytes, Dir) ->
        {I, Parent, [{transaction, First} | Rest], Time, Cert} = unpack(Bytes),
        Bad = pack(I, Parent, [{transaction, bad_signature(First)} | Rest], Time, Cert),
        %% CRC-valid altered storage remains transport data. Only the receiver
        %% authenticates payloads; the server does not grant append authority.
        rewrite_frame(Ns, Dir, frame(<<2, Bytes/binary>>), frame(<<2, Bad/binary>>)),
        {ok, Parts, done} = serve(quod_ledger_store:snapshot(Store), 2, 2),
        ?assertEqual([Bad], [B || {entry, B} <- Parts]),
        ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(Bad, wrapped)),
        ?assertException(error, {corrupt_entry, 2, bad_entry}, quod_ledger_store:read_range(Store, 2, 2, all))
    end).

served_proof_payload_is_authenticated_by_the_receiver_test() ->
    with_served_entry(fun(Ns, Store, Entry, Bytes, Dir) ->
        {I, Parent, [{transaction, First} | Rest], Time, Cert} = unpack(Bytes),
        {quod_entry, 2, I, OriginalBlock, _} = binary_to_term(Bytes, [safe]),
        {quod_entry, 2, I, BadBlock, _} = binary_to_term(
            pack(I, Parent, [{transaction, bad_signature(First)} | Rest], Time, Cert), [safe]),
        rewrite_frame(Ns, Dir, frame(<<1, OriginalBlock/binary>>), frame(<<1, BadBlock/binary>>)),
        {ok, Parts, done} = serve(quod_ledger_store:snapshot(Store), 2, 2),
        Proofs = [B || {proof, B} <- Parts],
        ?assert(lists:member(BadBlock, Proofs)),
        F = quod_ct:protocol_fixture(Ns),
        ?assertEqual({error, {malformed_finality_link, 2}}, quod_ct:verify_finality(
            maps:get(identity, F), Entry, maps:get(projection, F),
            {fun([]) -> done; ([B | Tail]) -> {ok, B, Tail} end, Proofs}))
    end).

served_page_frame_integrity_test_() ->
    [{atom_to_list(Case), fun() -> with_served_entry(fun(Ns, Store, _Entry, Bytes, Dir) ->
        Original = frame(<<2, Bytes/binary>>),
        BadFrame = case Case of
            wrong_index ->
                {quod_entry, 2, 2, B, C} = binary_to_term(Bytes, [safe]),
                Changed = canonical({quod_entry, 2, 9, B, C}),
                frame(<<2, Changed/binary>>);
            bad_crc ->
                <<Magic:32, Len:32, CRC:32, Body/binary>> = Original,
                <<Magic:32, Len:32, (CRC bxor 1):32, Body/binary>>;
            truncated -> binary:part(Original, 0, byte_size(Original) - 1)
        end,
        rewrite_frame(Ns, Dir, Original, BadFrame),
        Snapshot = quod_ledger_store:snapshot(Store),
        case Case of
            truncated -> ?assertEqual({error, changed}, serve(Snapshot, 2, 2));
            wrong_index -> ?assertException(error, {corrupt_entry, 2, {wrong_index, 9}}, serve(Snapshot, 2, 2));
            bad_crc -> ?assertException(error, {corrupt_material_group, _, _}, serve(Snapshot, 2, 2))
        end
    end) end} || Case <- [wrong_index, bad_crc, truncated]].

with_served_entry(Fun) ->
    {{Ns, _}, _Signer, Entry, Bytes} = fixture(),
    F = quod_ct:protocol_fixture(Ns),
    Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
    Dir = filename:join("/tmp", "quod-served-page-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir, wrapped),
    try
        {ok, Store1} = quod_ledger_store:append(Store0, {none, [Genesis]}),
        {ok, Store} = append_group(Store1, Entry, proof_blocks(Entry)),
        Fun(Ns, Store, Entry, Bytes, Dir)
    after quod_ledger_store:close(Store0), file:del_dir_r(Dir) end.

serve(Snapshot, From, To) ->
    case quod_ledger_store:open_ro_snapshot(Snapshot) of
        {ok, Reader} ->
            try quod_catchup:transfer_page(Reader, quod_catchup:transfer_open(Reader, From, To))
            after quod_ledger_store:close(Reader) end;
        {error, _} = Error -> Error
    end.

append_group(Store, Entry, Blocks) ->
    Bytes = [quod_ledger:block_bytes(B) || B <- Blocks],
    Source = {lists:sum([quod_ledger_store:proof_frame_size(B) || B <- Bytes]),
        fun([]) -> done; ([B | Rest]) -> {B, Rest} end, Bytes},
    quod_ledger_store:append(Store, {Source, [Entry]}).

rewrite_frame(Ns, Dir, Original, Replacement) ->
    Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "log.0001"),
    {ok, Archive} = file:read_file(Path),
    [Before, After] = binary:split(Archive, Original),
    ok = file:write_file(Path, <<Before/binary, Replacement/binary, After/binary>>).

frame(Bytes) -> <<16#915106B2:32, (byte_size(Bytes)):32, (erlang:crc32(Bytes)):32, Bytes/binary>>.

%% Real signed two-target claims and applications, not a claim of consensus
%% admission. Each item has its own proof/request; the one-member QC is real.
selected_item_authenticates_seven_authorities_not_the_whole_batch_test() ->
    {Identity, _Signer, Entry, Bytes} = fixture(),
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
    ok = verify_fixture(Identity, Full),
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Full, Tx),
    ?assert(quod_dtx:certified_entry_claim_matches(Identity, Selected, Tx, Ref)),
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
    ?assertNot(quod_dtx:certified_entry_claim_matches(Identity, Bad, Tx, Ref)),
    ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(BadBytes, wrapped)),
    BadSelected = pack(I, Parent, [{transaction, bad_signature(FirstBytes)} | Rest], Time, Cert),
    ?assertEqual({error, bad_entry}, quod_ledger:select_entry(BadSelected, Select, wrapped)),
    %% A caller's preferred head is only a hint. The archive's selected proof
    %% is independently verified; corrupting that selected proof is refused.
    BadCert = setelement(6, Cert, [{maps:get(pubkey, Signer), <<0:512>>}]),
    BadRef = setelement(8, Ref, canonical(BadCert)),
    ?assert(quod_dtx:same_certified_ref(Ref, BadRef)),
    ?assert(quod_dtx:certified_entry_claim_matches(Identity, Good, Tx, BadRef)),
    {ok, Full} = quod_ledger:decode_entry(Bytes, wrapped),
    ok = verify_fixture(Identity, Full),
    {quod_entry, 2, I, B, Cert} = binary_to_term(Bytes, [safe]),
    {ok, BadSelectedProof} = quod_ledger:decode_entry(
        canonical({quod_entry, 2, I, B, BadCert}), wrapped),
    ?assertEqual({error, {bad_cert, I}}, verify_fixture(Identity, BadSelectedProof)).

carried_entry_decodes_only_its_selected_application_test() ->
    {Identity, _Signer, Full, Bytes} = fixture(),
    #entry{data = {batch, [Tx | _]}} = quod_ledger:entry_view(Full),
    ok = verify_fixture(Identity, Full),
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
    ?assert(quod_dtx:certified_entry_claim_matches(Identity, Received, Tx, Ref)),
    %% History import uses the shared full decoder and authenticates all eight
    %% applications. A point selection alone can never authorize append.
    {{ok, Imported}, ImportChecks} = counted(fun() -> quod_ledger:decode_entry(Bytes, wrapped) end),
    ?assertEqual(56, ImportChecks),
    ?assertEqual({ok, Bytes}, quod_ledger:encode_entry(Imported)),
    {I, Parent, [First, {transaction, Other} | Rest], Time, Cert} = unpack(Bytes),
    BadBytes = pack(I, Parent, [First, {transaction, bad_signature(Other)} | Rest], Time, Cert),
    {ok, BadHint} = quod_ledger:select_entry(BadBytes, {application, Tx#transaction.tx_id}, wrapped),
    ?assertEqual({ok, BadBytes}, quod_ledger:hint_bytes(BadHint)),
    ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(BadBytes, wrapped)).

ambiguous_missing_and_wrong_slot_selections_fail_closed_test() ->
    {Identity, _, _, Bytes} = fixture(),
    {I, Parent, [First | _], Time, Cert} = unpack(Bytes),
    {transaction, Blob} = First,
    {ok, Tx} = quod_transaction:decode_ledger_transaction(Blob, wrapped),
    Select = {application, Tx#transaction.tx_id},
    {ok, Duplicate} = quod_ledger:select_entry(pack(I, Parent, [First, First], Time, Cert), Select, wrapped),
    ?assertEqual(none, quod_ledger:selected_record(Duplicate)),
    {ok, Missing} = quod_ledger:select_entry(Bytes, {application, <<0:256>>}, wrapped),
    ?assertEqual(none, quod_ledger:selected_record(Missing)),
    {quod_entry, 2, I, Block, Cert} = binary_to_term(Bytes, [safe]),
    ?assertEqual({error, bad_entry}, quod_ledger:select_entry(
                   canonical({quod_entry, 2, 0, Block, Cert}), Select, wrapped)),
    ?assertEqual({error, bad_entry}, quod_ledger:select_entry(
        canonical({quod_entry, 2, I + 1, Block, Cert}), Select, wrapped)),
    ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(
        canonical({quod_entry, 2, I + 1, Block, Cert}), wrapped)),
    {ok, Good} = quod_ledger:select_entry(Bytes, Select, wrapped),
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Good, Tx),
    ?assert(quod_dtx:certified_entry_claim_matches(Identity, Good, Tx, Ref)).

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
    F0 = quod_ct:protocol_fixture(<<"quod:selection-target">>),
    Signer = maps:get(signer, F0), Key = maps:get(pubkey, Signer),
    Origin = {<<"quod:selection-source">>, <<31:256>>},
    Target = {Ns, Anchor} = maps:get(identity, F0),
    Txs = [begin
        F = quod_ct:signed_plan_fixture(#{target => Origin, participant_target => Target,
              node_identity => Signer, proof_id => <<I:256>>, provenance => 2}, [Origin, Target]),
        Admission = maps:get(admission, F),
        C0 = quod_transaction:remote_claim(Origin, maps:get(manifest, F), maps:get(bundles, F), maps:get(auth, F), []),
        {ok, Claim} = quod_transaction:sign({element(1, Origin), element(2, Origin), Admission},
          C0#transaction{author = Key, author_seq = I}, Signer),
        {ok, ClaimRef} = quod_dtx:certified_ref(element(1, Origin), element(2, Origin), 2,
                                              <<33:256>>, Claim#transaction.tx_id, quod_ct:fixture_finality(1, <<33:256>>)),
        A0 = quod_transaction:attach_evidence(quod_transaction:remote_application(
                 quod_transaction:stable_ref(ClaimRef), Claim, Target), ClaimRef, Claim),
        {ok, App} = quod_transaction:sign({Ns, Anchor, Admission},
                                          A0#transaction{author = Key, author_seq = I}, Signer), App
    end || I <- lists:seq(1, 8)],
    Era = maps:get(era, F0),
    {ok, Block} = quod_ledger:new_block({Era, 1}, {Era, 0, Anchor}, 2, {batch, Txs}, 2),
    {ok, Carrier} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(Block), 2, empty, 2),
    Entry = quod_ledger:entry(2, Block, quod_ct:protocol_certificate(Carrier, F0)),
    {ok, Bytes} = quod_ledger:encode_entry(Entry),
    {Target, Signer, Entry, Bytes}.

unpack(Bytes) ->
    {quod_entry, 2, I, Block, Cert} = binary_to_term(Bytes, [safe]),
    {quod_block, 3, Era, View, Parent, I, {batch, Items}, Time} = binary_to_term(Block, [safe]),
    {I, {Era, View, Parent}, Items, Time, Cert}.
pack(I, {Era, View, Parent}, Items, Time, Cert) ->
    canonical({quod_entry, 2, I, canonical({quod_block, 3, Era, View, Parent, I, {batch, Items}, Time}), Cert}).

proof_blocks(Entry) ->
    {ok, Block} = quod_ledger:block_from_entry(Entry),
    {Era, View, _} = Parent = quod_ledger:block_ref(Block),
    {ok, Carrier} = quod_ledger:new_block({Era, View + 1}, Parent, Block#block.height, empty, Block#block.timestamp),
    [Carrier, Block].
verify_fixture({Ns, _} = Identity, Entry) ->
    F = quod_ct:protocol_fixture(Ns),
    quod_ct:verify_finality(Identity, Entry, maps:get(projection, F),
        {fun([]) -> done; ([B | Rest]) -> {ok, quod_ledger:block_bytes(B), Rest} end,
         proof_blocks(Entry)}).
canonical(Term) -> term_to_binary(Term, [deterministic]).
bad_signature(Blob) ->
    {submit, A, S, B} = binary_to_term(Blob, [safe]), canonical({submit, A, flip(S), B}).
flip(<<B, Rest/binary>>) -> <<(B bxor 1), Rest/binary>>.
counted(Fun) ->
    {module, crypto} = code:ensure_loaded(crypto),
    {Result, {call_count, Rows}} = tprof:profile(Fun, #{type => call_count, report => return,
      pattern => [{crypto, verify, 5}], timeout => 30000}),
    {Result, lists:sum([N || {crypto, verify, 5, Ps} <- Rows, {_, N, _} <- Ps])}.
