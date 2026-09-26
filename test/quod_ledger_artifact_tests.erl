-module(quod_ledger_artifact_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").

-define(NS, <<"quod:artifact-golden">>).
-define(FRAME_MAGIC, 16#915106B1).

artifact_matches_independent_v2_envelopes_and_v8_framing_test() ->
    F = fixture(quod_ledger),
    lists:foreach(fun({_, Entry}) ->
        #entry{index = Height, block_bytes = BlockBytes, cert = Cert} = quod_ledger:entry_view(Entry),
        WireCert = case Cert of
            none -> none;
            #cert{era = Era, slot = View, block_hash = Hash, sigs = Sigs} ->
                {quod_finality, 1, Era, View, Hash, Sigs}
        end,
        ?assertEqual(canonical({quod_entry, 2, Height, BlockBytes, WireCert}),
                     entry_bytes(quod_ledger, Entry))
    end, maps:get(entries, F)),
    %% The on-disk byte comparison below builds framing independently of the
    %% store writer, including group lengths, proof tags and closing offsets.
    ?assertEqual(32, byte_size(maps:get(anchor, F))).

block_shape_reuses_one_bounded_payload_encoding_test() ->
    F = fixture(quod_ledger),
    Entry = proplists:get_value(content, maps:get(entries, F)),
    {ok, Block} = quod_ledger:block_from_entry(Entry),
    {true, Counts} = traced_calls([{quod_transaction, encode_ledger_transaction, 1}],
                                 fun() -> quod_simplex:well_formed_block(Block) end),
    ?assertEqual(1, maps:get({quod_transaction, encode_ledger_transaction, 1}, Counts)),
    ?assert(quod_ledger:valid_block_view(Block)),
    lists:foreach(fun(B) -> ?assertNot(quod_simplex:well_formed_block(B)) end,
                  [Block#block{slot = 77}, Block#block{parent = 77},
                   Block#block{timestamp = 77}, Block#block{payload = {batch, []}},
                   Block#block{block_bytes = <<>>}]).

block_binding_owns_the_payload_limit_test() ->
    F = fixture(quod_ledger), {Ns, Anchor} = Binding = maps:get(binding, F),
    Make = fun(Size) ->
        Base = maps:get(transaction, F),
        Tx0 = Base#transaction{diff = [{assert, {{padded, binary:copy(<<0>>, Size)}, true}}],
                               sig = none, signed_bytes = none},
        Tx1 = quod_transaction:bind_id(Binding, Tx0),
        {ok, Tx} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, Tx1, maps:get(signer, F)),
        {ok, Blob} = quod_transaction:encode_ledger_transaction(Tx),
        Wire = {batch, [{transaction, Blob}]},
        {ok, PayloadBytes} = quod_safe_term:encode_canonical(Wire, ?QUOD_MAX_CANONICAL_BLOCK_BYTES),
        {Tx, Wire, byte_size(PayloadBytes)}
    end,
    {_, _, Overhead} = Make(0),
    lists:foreach(fun(Extra) ->
        {Tx, Wire, Size} = Make(?MAX_BLOCK_BYTES - Overhead + Extra),
        ?assertEqual(?MAX_BLOCK_BYTES + Extra, Size),
        Era = maps:get(era, F), Max = (1 bsl 64) - 1,
        Root = {Era, Max - 1, maps:get(anchor, F)},
        Bytes = canonical({quod_block, 2, Era, Max, Root, Wire, Max}),
        ?assert(byte_size(Bytes) =< ?QUOD_MAX_CANONICAL_BLOCK_BYTES),
        Block = #block{era = Era, slot = Max, parent = Root, payload = {batch, [Tx]}, timestamp = Max, block_bytes = Bytes},
        ?assertEqual(Extra =:= 0, quod_ledger:valid_block_view(Block)),
        ?assertEqual(Extra =:= 0, quod_simplex:well_formed_block(Block))
    end, [0, 1]).

checked_constructors_reject_changed_views_test() ->
    F = fixture(quod_ledger),
    Parent = maps:get(parent, F),
    Cert = maps:get(finality, F),
    MutatedBlocks = [Parent#block{slot = 77}, Parent#block{parent = 77},
                     Parent#block{timestamp = 77},
                     Parent#block{payload = (maps:get(child, F))#block.payload}],
    lists:foreach(fun(B) -> ?assertException(error, _, quod_ledger:entry(3, B, Cert)) end,
                  MutatedBlocks),
    Entry = proplists:get_value(content, maps:get(entries, F)),
    View = quod_ledger:entry_view(Entry),
    MutatedViews = [View#entry{index = 0}, View#entry{timestamp = 77},
                    View#entry{data = Parent#block.payload},
                    View#entry{block_bytes = Parent#block.block_bytes}],
    lists:foreach(
      fun(V) -> ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view(V)) end,
      MutatedViews),
    lists:foreach(
      fun({_, A}) ->
          {ok, Imported} = quod_ledger:from_entry_view(quod_ledger:entry_view(A)),
          ?assertEqual(entry_bytes(quod_ledger, A), entry_bytes(quod_ledger, Imported))
      end, maps:get(entries, F)).

block_constructor_rejects_unsigned_or_changed_transaction_views_test() ->
    F = fixture(quod_ledger),
    Tx = maps:get(transaction, F),
    <<First, Rest/binary>> = Tx#transaction.sig,
    Bad = [Tx#transaction{sig = <<(First bxor 1), Rest/binary>>},
           Tx#transaction{diff = []}, Tx#transaction{signed_bytes = <<>>}],
    lists:foreach(fun(Changed) ->
        ?assertEqual({error, bad_block},
                     quod_ledger:new_block({maps:get(era, F), 1}, maps:get(root, F), {batch, [Changed]}, 101))
    end, Bad).

compact_head_shape_is_not_a_finality_verdict_test() ->
    F = fixture(quod_ledger),
    Parent = maps:get(parent, F), Cert = maps:get(finality, F),
    %% A shape-valid alternative head needs ancestry verification; a malformed
    %% descriptor cannot cross the codec, including native-record wire input.
    A = proplists:get_value(ancestor, maps:get(entries, F)),
    #entry{index = Height, block_bytes = Bytes} = View = quod_ledger:entry_view(A),
    lists:foreach(fun(Bad) ->
        ?assertException(error, _, quod_ledger:entry(Height, Parent, Bad)),
        ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view(View#entry{cert = Bad}))
    end, [Cert#cert{era = <<0:256>>}, Cert#cert{kind = complaint},
          Cert#cert{sigs = Cert#cert.sigs ++ Cert#cert.sigs}]),
    lists:foreach(fun(BadWire) ->
        ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(
            canonical({quod_entry, 2, Height, Bytes, BadWire}), wrapped))
    end, [Cert, {implicit, Cert, maps:get(child, F), Cert}]),
    {quod_entry, 2, _, _, WireCert} = binary_to_term(entry_bytes(quod_ledger, A), [safe]),
    ?assertException(error, _, quod_ledger:entry(Height, Parent, WireCert)),
    ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view(View#entry{cert = WireCert})).

zero_slot_block_cannot_become_a_committed_entry_test() ->
    F = fixture(quod_ledger),
    {ok, Genesis} = quod_ledger:block_from_entry(proplists:get_value(genesis, maps:get(entries, F))),
    ?assertException(error, _, quod_ledger:entry(0, Genesis, none)),
    ZeroView = #entry{index = 0, data = Genesis#block.payload,
                      timestamp = 0, block_bytes = Genesis#block.block_bytes},
    ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view(ZeroView)).

wrapped_construction_import_and_decode_allocate_no_vocabulary_test() ->
    F = fixture(quod_ledger),
    Name = <<"artifact_unknown_", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    Symbol = {'$quod_symbol', Name},
    Tx = signed_transaction(maps:get(binding, F), maps:get(admission, F),
                            maps:get(signer, F), 4, Symbol),
    {ok, TxBytes} = quod_transaction:encode_ledger_transaction(Tx),
    Era = maps:get(era, F), Parent = quod_ledger:block_ref(maps:get(child, F)),
    Bytes = canonical({quod_block, 2, Era, 6, Parent, {batch, [{transaction, TxBytes}]}, 104}),
    Block = #block{era = Era, slot = 6, parent = Parent, timestamp = 104,
                    payload = {batch, [Tx]}, block_bytes = Bytes},
    Cert = certificate(commit, Block, maps:get(binding, F), maps:get(signer, F)),
    ?assertException(error, badarg, binary_to_existing_atom(Name, utf8)),
    Before = erlang:system_info(atom_count),
    Entry = quod_ledger:entry(5, Block, Cert),
    Envelope = entry_bytes(quod_ledger, Entry),
    {ok, Decoded} = quod_ledger:decode_entry(Envelope, wrapped),
    {ok, Selected} = quod_ledger:select_entry(Envelope, {application, Tx#transaction.tx_id}, wrapped),
    ?assertEqual(Tx, quod_ledger:selected_record(Selected)),
    {ok, Imported} = quod_ledger:from_entry_view(quod_ledger:entry_view(Decoded)),
    ?assertEqual(Envelope, entry_bytes(quod_ledger, Imported)),
    ?assertEqual(Before, erlang:system_info(atom_count)),
    ?assertMatch(#entry{data = {batch, [#transaction{
                        diff = [{assert, {{Symbol, 4}, true}}]}]}},
                 quod_ledger:entry_view(Decoded)),
    ?assertException(error, badarg, binary_to_existing_atom(Name, utf8)).

actual_byte_ingress_rejects_bad_signature_and_non_envelopes_test() ->
    F = fixture(quod_ledger),
    Entry = proplists:get_value(content, maps:get(entries, F)),
    Bytes = entry_bytes(quod_ledger, Entry),
    {quod_entry, 2, Index, BlockBytes, CertWire} = binary_to_term(Bytes, [safe]),
    {quod_block, 2, Era, Slot, Parent, {batch, [{transaction, TxBytes}]}, Timestamp} =
        binary_to_term(BlockBytes, [safe]),
    {submit, Author, <<First, Rest/binary>>, Signed} = binary_to_term(TxBytes, [safe]),
    BadTx = canonical({submit, Author, <<(First bxor 1), Rest/binary>>, Signed}),
    BadBlock = canonical({quod_block, 2, Era, Slot, Parent, {batch, [{transaction, BadTx}]}, Timestamp}),
    BadSignature = canonical({quod_entry, 2, Index, BadBlock, CertWire}),
    <<131, Body/binary>> = Bytes,
    Compressed = <<131, 80, (byte_size(Body)):32, (zlib:compress(Body))/binary>>,
    Invalid = [BadSignature, <<Bytes/binary, 0>>, Compressed,
               canonical({quod_entry, 2, 0, BlockBytes, CertWire}),
               term_to_binary(Entry, [deterministic]),
               canonical({Bytes, quod_ledger:entry_view(Entry)})],
    lists:foreach(
      fun(Bad) ->
          ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(Bad, wrapped)),
          ?assertEqual({error, bad_entry}, quod_ledger:select_entry(
                         Bad, {application, (maps:get(transaction, F))#transaction.tx_id}, wrapped)),
          assert_disk_ingress_refuses(Bad, F)
      end, Invalid).

assert_disk_ingress_refuses(Bad, F) ->
    Dir = tmp_dir(),
    Genesis = proplists:get_value(genesis, maps:get(entries, F)),
    Content = proplists:get_value(content, maps:get(entries, F)),
    {ok, Store0} = quod_ledger_store:open(?NS, Dir),
    try
        {ok, Store1} = quod_ledger_store:append(Store0, {none, [Genesis]}),
        {ok, Store} = quod_ledger_store:append(Store1, {proof_source([element(2, quod_ledger:block_from_entry(Content))]), [Content]}),
        %% Preserve framing, index position and CRC: rejection must come from
        %% the actual on-disk entry decoder, not a checksum or wrong offset.
        Log = filename:join([Dir, base64url(?NS), "log.0001"]),
        Prefix = group_bytes(0, 1, [], [entry_bytes(quod_ledger, Genesis)]),
        {ok, ContentBlock} = quod_ledger:block_from_entry(Content),
        Corrupt = <<Prefix/binary, (group_bytes(byte_size(Prefix), 2,
                    [quod_ledger:block_bytes(ContentBlock)], [Bad]))/binary>>,
        ok = file:write_file(Log, Corrupt),
        ?assertException(error, {corrupt_entry, 2, bad_entry},
                          quod_ledger_store:read_range(Store, 2, 2, all)),
        ?assertException(error, {corrupt_entry, 2, bad_entry},
                          quod_ledger_store:read_at(Store, 2,
                            {application, (maps:get(transaction, F))#transaction.tx_id})),
        ?assertEqual({ok, Corrupt}, file:read_file(Log))
    after
        ok = quod_ledger_store:close(Store0),
        _ = file:del_dir_r(Dir)
    end.

artifact_bytes_survive_store_feed_and_sidecar_test() ->
    F = fixture(quod_ledger),
    Entries = [A || {_, A} <- maps:get(entries, F)],
    Expected = [entry_bytes(quod_ledger, A) || A <- Entries],
    Dir = tmp_dir(),
    {ok, Store0} = quod_ledger_store:open(?NS, Dir),
    try
        {ok, Store} = append_fixture(Store0, F, Entries),
        {ok, Read} = quod_ledger_store:read_range(Store, 1, length(Entries), all),
        ?assertEqual(Expected, [entry_bytes(quod_ledger, A) || A <- Read]),
        {ok, FileBytes} = file:read_file(filename:join([Dir, base64url(?NS), "log.0001"])),
        ?assertEqual(fixture_archive(F), FileBytes),
        lists:foreach(fun(A) ->
            Bytes = entry_bytes(quod_ledger, A),
            {feed, ?NS, Inner} = binary_to_term(quod_feed:encode(?NS, {block, A}), [safe]),
            ?assertEqual({block_bytes, Bytes}, binary_to_term(Inner, [safe])),
            {block, RoundTrip} = quod_feed:decode(quod_feed:encode(?NS, {block, A}), ?NS),
            ?assertEqual(Bytes, entry_bytes(quod_ledger, RoundTrip)),
            {ok, Wrapped} = quod_ledger:decode_entry(Bytes, wrapped),
            ?assertEqual(Bytes, entry_bytes(quod_ledger, Wrapped)),
            {ok, Imported} = quod_ledger:from_entry_view(quod_ledger:entry_view(Wrapped)),
            ?assertEqual(Bytes, entry_bytes(quod_ledger, Imported))
        end, Entries),
        {Request, Hint} = sidecar_fixture(F),
        {ok, Sidecar} = quod_dtx_endpoint:encode_request(?NS, Request, [Hint]),
        {quod_dtx_endpoint, _, ?NS, InnerBytes, []} = binary_to_term(Sidecar, [safe]),
        {Request, [{entry_bytes, Ref, HintBytes}]} = binary_to_term(InnerBytes, [safe]),
        {Ref, HintEntry} = Hint,
        ?assertEqual(entry_bytes(quod_ledger, HintEntry), HintBytes),
        {ok, Request, [{Ref, Recovered}], []} = quod_dtx_endpoint:decode_request(?NS, Sidecar),
        ?assertEqual({ok, HintBytes}, quod_ledger:hint_bytes(Recovered)),
        ?assertEqual({error, bad_entry}, quod_ledger:encode_entry(Recovered))
    after
        ok = quod_ledger_store:close(Store0),
        _ = file:del_dir_r(Dir)
    end.

artifact_consumers_do_not_repeat_representation_or_signature_checks_test() ->
    F = fixture(quod_ledger),
    Entries = [A || {_, A} <- maps:get(entries, F)],
    Content = proplists:get_value(content, maps:get(entries, F)),
    ContentBytes = entry_bytes(quod_ledger, Content),
    ContentView = quod_ledger:entry_view(Content),
    {ok, ContentBlock} = quod_ledger:block_from_entry(Content),
    {Request, {HintRef, _}} = sidecar_fixture(F),
    WrappedEntries = [begin
                          {ok, A} = quod_ledger:decode_entry(entry_bytes(quod_ledger, E), wrapped),
                          A
                      end || E <- Entries],
    Hooks = [{quod_ledger, decode_entry, 2}, {quod_ledger, decode_entry, 3},
             {quod_ledger, decode_block, 2}, {quod_ledger, decode_block, 3},
             {quod_ledger, valid_block_view, 1},
             {quod_transaction, encode_ledger_transaction, 1},
             {quod_transaction, verify_submission, 1}],
    {ok, Positive} = traced_calls(Hooks, fun() ->
        {ok, _} = quod_ledger:decode_entry(ContentBytes, wrapped),
        {ok, _} = quod_ledger:decode_block(quod_ledger:block_bytes(ContentBlock), wrapped),
        _ = quod_ledger:entry(ContentView#entry.index, ContentBlock, ContentView#entry.cert),
        ok
    end),
    lists:foreach(fun(Hook) -> ?assert(maps:get(Hook, Positive, 0) > 0) end, Hooks),
    Dir = tmp_dir(),
    try
        {ok, ConsumerCalls} = traced_calls(Hooks, fun() ->
            lists:foreach(fun({Mode, ModeEntries}) ->
                {ok, Store0} = quod_ledger_store:open(?NS, filename:join(Dir, Mode)),
                try
                    lists:foreach(fun(A) ->
                        {ok, _} = quod_ledger:encode_entry(A),
                        _ = quod_ledger:entry_view(A),
                        _ = quod_ledger:block_from_entry(A),
                        _ = quod_feed:encode(?NS, {block, A})
                    end, ModeEntries),
                    Hint = {HintRef, lists:nth(2, ModeEntries)},
                    {ok, _} = quod_dtx_endpoint:encode_request(?NS, Request, [Hint]),
                    {ok, _} = append_fixture(Store0, F, ModeEntries)
                after
                    ok = quod_ledger_store:close(Store0)
                end
            end, [{"local", Entries}, {"foreign", WrappedEntries}]),
            ok
        end),
        ?assertEqual(#{}, ConsumerCalls)
    after
        _ = file:del_dir_r(Dir)
    end.

raw_entry_views_are_not_a_second_store_append_path_test() ->
    F = fixture(quod_ledger),
    Genesis = proplists:get_value(genesis, maps:get(entries, F)),
    View = quod_ledger:entry_view(Genesis),
    Dir = tmp_dir(),
    {ok, Store} = quod_ledger_store:open(?NS, Dir),
    try
        ?assertException(error, function_clause, quod_ledger_store:append(Store, {none, [View]})),
        {batch, [Tx]} = View#entry.data,
        {ok, Selected} = quod_ledger:select_entry(Genesis, {application, Tx#transaction.tx_id}, wrapped),
        ?assertException(error, function_clause, quod_ledger_store:append(Store, {none, [Selected]})),
        ?assertException(error, function_clause, quod_prolog:apply_entry(?NS, Selected, live)),
        %% Reject synchronously, before addressing an engine or emitting a
        %% cast; a representation error must not kill the receiving owner.
        ?assertException(error, function_clause, quod_prolog:apply_entry(?NS, View, live)),
        ?assertEqual({error, bad_entry}, quod_ledger:encode_entry(View)),
        ?assertEqual(error, quod_ledger:block_from_entry(View)),
        ?assertEqual({ok, <<>>}, file:read_file(filename:join([Dir, base64url(?NS), "log.0001"])))
    after
        ok = quod_ledger_store:close(Store),
        _ = file:del_dir_r(Dir)
    end.

sidecar_fixture(F) ->
    Entry = proplists:get_value(content, maps:get(entries, F)),
    View = quod_ledger:entry_view(Entry),
    {ok, Ref} = quod_dtx:certified_ref(
                  ?NS, maps:get(anchor, F), View#entry.index,
                  digest(View#entry.block_bytes),
                  digest((maps:get(transaction, F))#transaction.signed_bytes),
                  finality_bytes(View#entry.cert)),
    {{phase, <<1:128>>, digest(<<"artifact-group">>), vote}, {Ref, Entry}}.

traced_calls(Hooks, Fun) ->
    Parent = self(),
    Tag = make_ref(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        receive {run, Tag} ->
            Result = Fun(),
            Parent ! {artifact_trace_result, Tag, Result},
            receive {stop, Tag} -> ok end
        end
    end),
    try
        lists:foreach(fun(Hook) -> 1 = erlang:trace_pattern(Hook, true, [local]) end, Hooks),
        1 = erlang:trace(Worker, true, [call, {tracer, self()}]),
        Worker ! {run, Tag},
        Result = receive
                     {artifact_trace_result, Tag, Value} -> Value;
                     {'DOWN', Monitor, process, Worker, Reason} -> error({artifact_trace_worker, Reason})
                 after 3000 -> error(artifact_trace_timeout)
                 end,
        Barrier = erlang:trace_delivered(Worker),
        Calls = collect_calls(Worker, Barrier, #{}),
        {Result, Calls}
    after
        _ = catch erlang:trace(Worker, false, [call]),
        lists:foreach(fun(Hook) -> erlang:trace_pattern(Hook, false, [local]) end, Hooks),
        exit(Worker, kill),
        _ = demonitor(Monitor, [flush])
    end.

collect_calls(Worker, Barrier, Acc) ->
    receive
        {trace, Worker, call, {Module, Function, Args}} ->
            Key = {Module, Function, length(Args)},
            collect_calls(Worker, Barrier, maps:update_with(Key, fun(N) -> N + 1 end, 1, Acc));
        {trace_delivered, Worker, Barrier} -> Acc
    after 3000 -> error(artifact_trace_flush_timeout)
    end.

fixture(Codec) ->
    Seed = digest(<<"quod-artifact-golden-test-key">>),
    {Pub, _} = crypto:generate_key(eddsa, ed25519, Seed),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    GenesisTx = quod_simplex:test_genesis_tx(
                  #{node_id => Pub, mode => create, committee => [],
                    node_addr => {"127.0.0.1", 19000}, genesis_diff => []},
                  ?NS, Pub, digest(<<"quod-artifact-fixed-incarnation">>)),
    {ok, GenesisBlock} = Codec:new_block({genesis, 0}, none, {batch, [GenesisTx]}, 0),
    Genesis = Codec:entry(1, GenesisBlock, none),
    Anchor = digest(GenesisBlock#block.block_bytes),
    Admission = digest(term_to_binary({quod_validator_admission, 1, ?NS, 1, Anchor, Pub},
                                     [deterministic])),
    Binding = {?NS, Anchor}, Era = Codec:initial_era(Binding), Root = {Era, 0, Anchor},
    Tx = signed_transaction(Binding, Admission, Signer, 1, artifact_fact),
    {ok, ContentBlock} = Codec:new_block({Era, 1}, Root, {batch, [Tx]}, 101),
    Content = Codec:entry(2, ContentBlock, certificate(commit, ContentBlock, Binding, Signer)),
    ParentTx = signed_transaction(Binding, Admission, Signer, 2, parent_fact),
    ChildTx = signed_transaction(Binding, Admission, Signer, 3, child_fact),
    {ok, Carrier} = Codec:new_block({Era, 3}, Codec:block_ref(ContentBlock), empty, 101),
    {ok, Parent} = Codec:new_block({Era, 4}, Codec:block_ref(Carrier), {batch, [ParentTx]}, 102),
    {ok, Child} = Codec:new_block({Era, 5}, Codec:block_ref(Parent), {batch, [ChildTx]}, 103),
    Finality = certificate(commit, Child, Binding, Signer),
    #{anchor => Anchor, binding => Binding, era => Era, root => Root,
      admission => Admission, signer => Signer, parent => Parent, child => Child,
      transaction => Tx, finality => Finality,
      groups => [{[], 1}, {[ContentBlock], 1}, {[Child, Parent, Carrier], 2}],
      entries => [{genesis, Genesis}, {content, Content},
                  {ancestor, Codec:entry(3, Parent, Finality)},
                  {child, Codec:entry(4, Child, Finality)}]}.

%% Fixture framing is independent of the production store writer.
group_bytes(Start, First, Proofs, Entries) ->
    ProofBytes = iolist_to_binary([frame(<<1, B/binary>>) || B <- Proofs]),
    EntryBytes = iolist_to_binary([frame(<<2, B/binary>>) || B <- Entries]),
    ProofStart = case Proofs of [] -> 0; _ -> Start + 69 end,
    Header = frame(<<0, First:64, (length(Entries)):64,
        (byte_size(ProofBytes)):64, (byte_size(EntryBytes)):64,
        ProofStart:64, (byte_size(ProofBytes)):64, 0:64>>),
    End = Start + byte_size(Header) + byte_size(ProofBytes) + byte_size(EntryBytes) + 29,
    <<Header/binary, ProofBytes/binary, EntryBytes/binary, (frame(<<3, Start:64, End:64>>))/binary>>.
entry_height(Bytes) -> {quod_entry, 2, Height, _, _} = binary_to_term(Bytes, [safe]), Height.

fixture_archive(F) ->
    Entries = [entry_bytes(quod_ledger, E) || {_, E} <- maps:get(entries, F)],
    {Bytes, []} = lists:foldl(fun({Blocks, Count}, {Acc, Remaining}) ->
        {Group, Tail} = lists:split(Count, Remaining),
        Bin = group_bytes(byte_size(Acc), entry_height(hd(Group)), [quod_ledger:block_bytes(B) || B <- Blocks], Group),
        {<<Acc/binary, Bin/binary>>, Tail}
    end, {<<>>, Entries}, maps:get(groups, F)), Bytes.

append_fixture(Store, F, Entries) ->
    {Result, []} = lists:foldl(fun({Blocks, Count}, {Current, Remaining}) ->
        {Group, Tail} = lists:split(Count, Remaining),
        {ok, Next} = quod_ledger_store:append(Current, {proof_source(Blocks), Group}),
        {Next, Tail}
    end, {Store, Entries}, maps:get(groups, F)), {ok, Result}.
proof_source([]) -> none;
proof_source(Blocks) ->
    Bytes = [quod_ledger:block_bytes(B) || B <- Blocks],
    {lists:sum([13 + byte_size(B) || B <- Bytes]),
     fun([]) -> done; ([B | Rest]) -> {B, Rest} end, Bytes}.
finality_bytes(Cert) -> {ok, Bytes} = quod_ledger:encode_finality_head(Cert), Bytes.

signed_transaction(Binding, Admission, Signer, Sequence, Symbol) ->
    {ok, Goal} = quod_durable_term:encode_goal({assertz, {Symbol, Sequence}}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Tx0 = #transaction{origin = Binding, proof_id = digest(<<Sequence:64>>),
                       plan_digest = digest(<<Sequence:64, 1>>), goal = Goal, result = Result,
                       diff = [{assert, {{Symbol, Sequence}, true}}], read_check = #{},
                       author = maps:get(pubkey, Signer), author_seq = Sequence,
                       submitted_at = Sequence},
    Tx1 = quod_transaction:bind_id(Binding, Tx0),
    {Ns, Anchor} = Binding,
    {ok, Tx} = quod_transaction:sign({Ns, Anchor, Admission}, Tx1, Signer),
    Tx.

certificate(Kind, Block, {Ns, Anchor}, Signer) ->
    Hash = digest(Block#block.block_bytes),
    #share{sig = Signature} = quod_simplex:make_share(
                               quod_simplex:consensus_domain(Ns, Anchor),
                               Kind, {Block#block.era, Block#block.slot}, Hash, Signer),
    #cert{kind = Kind, era = Block#block.era, slot = Block#block.slot, block_hash = Hash,
          sigs = [{maps:get(pubkey, Signer), Signature}]}.

entry_bytes(Codec, Entry) -> {ok, Bytes} = Codec:encode_entry(Entry), Bytes.
canonical(Term) -> {ok, Bytes} = quod_safe_term:encode_canonical(Term, 1024 * 1024), Bytes.
digest(Bytes) -> crypto:hash(sha256, Bytes).
frame(Bytes) -> <<?FRAME_MAGIC:32, (byte_size(Bytes)):32, (erlang:crc32(Bytes)):32, Bytes/binary>>.
base64url(Bytes) -> binary_to_list(binary:replace(binary:replace(binary:replace(
                      base64:encode(Bytes), <<"+">>, <<"-">>, [global]), <<"/">>, <<"_">>, [global]),
                      <<"=">>, <<>>, [global])).
tmp_dir() -> filename:join("/tmp", "quod-artifact-" ++ binary_to_list(
                                binary:encode_hex(crypto:strong_rand_bytes(8)))).
