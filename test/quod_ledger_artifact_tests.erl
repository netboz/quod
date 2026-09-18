-module(quod_ledger_artifact_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Used only to freeze independent pre-cut vectors with the archived codec.
-export([golden_vectors/1]).

-define(NS, <<"quod:artifact-golden">>).
-define(FRAME_MAGIC, 16#915106B0).

golden_vectors(Codec) ->
    F = fixture(Codec),
    #{anchor => maps:get(anchor, F),
      envelopes => [{Kind, digest(entry_bytes(Codec, Entry))}
                    || {Kind, Entry} <- maps:get(entries, F)],
      frames => digest(iolist_to_binary(
                         [frame(entry_bytes(Codec, Entry))
                          || {_, Entry} <- maps:get(entries, F)])),
      signed_transaction => digest((maps:get(transaction, F))#transaction.signed_bytes)}.

artifact_matches_v15_v7_golden_bytes_test() ->
    ?assertEqual(expected_golden_vectors(), golden_vectors(quod_ledger)).

checked_constructors_reject_changed_views_test() ->
    F = fixture(quod_ledger),
    Parent = maps:get(parent, F),
    Cert = maps:get(implicit, F),
    MutatedBlocks = [Parent#block{slot = 77}, Parent#block{parent = 77},
                     Parent#block{timestamp = 77},
                     Parent#block{payload = (maps:get(child, F))#block.payload}],
    lists:foreach(fun(B) -> ?assertException(error, _, quod_ledger:entry(B, Cert)) end,
                  MutatedBlocks),
    Entry = proplists:get_value(content, maps:get(entries, F)),
    View = quod_ledger:entry_view(Entry),
    MutatedViews = [View#entry{index = 77}, View#entry{timestamp = 77},
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
                     quod_ledger:new_block(2, 1, {batch, [Changed]}, 101))
    end, Bad).

checked_implicit_child_binding_is_not_discarded_test() ->
    F = fixture(quod_ledger),
    Parent = maps:get(parent, F),
    Cert = maps:get(implicit, F),
    Child = Cert#implicit_cert.child,
    ChangedChildren = [Child#block{slot = 91}, Child#block{parent = 91},
                       Child#block{timestamp = 91}, Child#block{payload = Parent#block.payload}],
    Entry = proplists:get_value(implicit, maps:get(entries, F)),
    View = quod_ledger:entry_view(Entry),
    lists:foreach(
      fun(ChangedChild) ->
          ChangedCert = Cert#implicit_cert{child = ChangedChild},
          ?assertException(error, _, quod_ledger:entry(Parent, ChangedCert)),
          ?assertEqual({error, bad_entry},
                       quod_ledger:from_entry_view(View#entry{cert = ChangedCert}))
      end, ChangedChildren).

native_implicit_certificate_is_not_a_wire_child_binding_test() ->
    F = fixture(quod_ledger),
    Entry = proplists:get_value(implicit, maps:get(entries, F)),
    {quod_entry, 1, Index, BlockBytes, {implicit, _, _, _}} =
        binary_to_term(entry_bytes(quod_ledger, Entry), [safe]),
    NativeCert = maps:get(implicit, F),
    %% Canonical ETF is not enough: a native record must not bypass the
    %% child's byte decoder just because its outer envelope is canonical.
    ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(
                   canonical({quod_entry, 1, Index, BlockBytes, NativeCert}), wrapped)),
    ?assertEqual({error, bad_entry}, quod_ledger:select_entry(
                   canonical({quod_entry, 1, Index, BlockBytes, NativeCert}),
                   {application, (maps:get(transaction, F))#transaction.tx_id}, wrapped)),
    lists:foreach(fun(NotBytes) ->
        BadCert = {implicit, NativeCert#implicit_cert.support,
                    NotBytes, NativeCert#implicit_cert.commit},
        ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(
                       canonical({quod_entry, 1, Index, BlockBytes, BadCert}), wrapped))
    end, [NativeCert#implicit_cert.child, none, <<"not-a-block">>]).

wire_implicit_certificate_is_not_a_native_constructor_view_test() ->
    F = fixture(quod_ledger),
    A = proplists:get_value(implicit, maps:get(entries, F)),
    {quod_entry, 1, _, _, WireCert} = binary_to_term(entry_bytes(quod_ledger, A), [safe]),
    ?assertException(error, _, quod_ledger:entry(maps:get(parent, F), WireCert)),
    View = quod_ledger:entry_view(A),
    ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view(View#entry{cert = WireCert})).

zero_slot_block_cannot_become_a_committed_entry_test() ->
    F = fixture(quod_ledger),
    {ok, Zero} = quod_ledger:new_block(0, 0, {batch, [maps:get(transaction, F)]}, 0),
    ?assertException(error, _, quod_ledger:entry(Zero, none)),
    ZeroView = #entry{index = 0, data = Zero#block.payload,
                      timestamp = 0, block_bytes = Zero#block.block_bytes},
    ?assertEqual({error, bad_entry}, quod_ledger:from_entry_view(ZeroView)).

wrapped_construction_import_and_decode_allocate_no_vocabulary_test() ->
    F = fixture(quod_ledger),
    Name = <<"artifact_unknown_", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    Symbol = {'$quod_symbol', Name},
    Tx = signed_transaction(maps:get(binding, F), maps:get(admission, F),
                            maps:get(signer, F), 4, Symbol),
    {ok, TxBytes} = quod_transaction:encode_ledger_transaction(Tx),
    Bytes = canonical({quod_block, 1, 6, 5, {batch, [{transaction, TxBytes}]}, 104}),
    Block = #block{slot = 6, parent = 5, timestamp = 104,
                    payload = {batch, [Tx]}, block_bytes = Bytes},
    Cert = certificate(commit, Block, maps:get(binding, F), maps:get(signer, F)),
    ?assertException(error, badarg, binary_to_existing_atom(Name, utf8)),
    Before = erlang:system_info(atom_count),
    Entry = quod_ledger:entry(Block, Cert),
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
    {quod_entry, 1, Index, BlockBytes, CertWire} = binary_to_term(Bytes, [safe]),
    {quod_block, 1, Slot, Parent, {batch, [{transaction, TxBytes}]}, Timestamp} =
        binary_to_term(BlockBytes, [safe]),
    {submit, Author, <<First, Rest/binary>>, Signed} = binary_to_term(TxBytes, [safe]),
    BadTx = canonical({submit, Author, <<(First bxor 1), Rest/binary>>, Signed}),
    BadBlock = canonical({quod_block, 1, Slot, Parent, {batch, [{transaction, BadTx}]}, Timestamp}),
    BadSignature = canonical({quod_entry, 1, Index, BadBlock, CertWire}),
    <<131, Body/binary>> = Bytes,
    Compressed = <<131, 80, (byte_size(Body)):32, (zlib:compress(Body))/binary>>,
    Invalid = [BadSignature, <<Bytes/binary, 0>>, Compressed,
               canonical({quod_entry, 1, Index + 1, BlockBytes, CertWire}),
               term_to_binary(Entry, [deterministic]),
               canonical({Bytes, quod_ledger:entry_view(Entry)})],
    lists:foreach(
      fun(Bad) ->
          ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(Bad, wrapped)),
          ?assertEqual({error, bad_entry}, quod_ledger:select_entry(
                         Bad, {application, (maps:get(transaction, F))#transaction.tx_id}, wrapped)),
          ?assertEqual({error, bad_frame}, quod_catchup:decode_entries([Bad], wrapped)),
          assert_disk_ingress_refuses(Bad, F)
      end, Invalid).

assert_disk_ingress_refuses(Bad, F) ->
    Dir = tmp_dir(),
    Genesis = proplists:get_value(genesis, maps:get(entries, F)),
    Content = proplists:get_value(content, maps:get(entries, F)),
    {ok, Store0} = quod_ledger_store:open(?NS, Dir),
    try
        {ok, Store} = quod_ledger_store:append(Store0, [Genesis, Content]),
        %% Preserve framing, index position and CRC: rejection must come from
        %% the actual on-disk entry decoder, not a checksum or wrong offset.
        Log = filename:join([Dir, base64url(?NS), "log.0001"]),
        Corrupt = <<(frame(entry_bytes(quod_ledger, Genesis)))/binary,
                    (frame(Bad))/binary>>,
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
        {ok, Store} = quod_ledger_store:append(Store0, Entries),
        {ok, Read} = quod_ledger_store:read_range(Store, 1, length(Entries), all),
        ?assertEqual(Expected, [entry_bytes(quod_ledger, A) || A <- Read]),
        {ok, FileBytes} = file:read_file(filename:join([Dir, base64url(?NS), "log.0001"])),
        ?assertEqual(iolist_to_binary([frame(B) || B <- Expected]), FileBytes),
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
        ?assertEqual({ok, length(Entries), lists:sum([byte_size(B) || B <- Expected])},
                     quod_catchup:page_stats(Entries)),
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
    Hooks = [{quod_ledger, decode_entry, 2}, {quod_ledger, decode_block, 2},
             {quod_ledger, valid_block_view, 1},
             {quod_transaction, encode_ledger_transaction, 1},
             {quod_transaction, verify_submission, 1}],
    {ok, Positive} = traced_calls(Hooks, fun() ->
        {ok, _} = quod_ledger:decode_entry(ContentBytes, wrapped),
        _ = quod_ledger:entry(ContentBlock, ContentView#entry.cert),
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
                    {ok, _, _} = quod_catchup:page_stats(ModeEntries),
                    Hint = {HintRef, lists:nth(2, ModeEntries)},
                    {ok, _} = quod_dtx_endpoint:encode_request(?NS, Request, [Hint]),
                    {ok, _} = quod_ledger_store:append(Store0, ModeEntries)
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
        ?assertException(error, function_clause, quod_ledger_store:append(Store, [View])),
        {batch, [Tx]} = View#entry.data,
        {ok, Selected} = quod_ledger:select_entry(Genesis, {application, Tx#transaction.tx_id}, wrapped),
        ?assertException(error, function_clause, quod_ledger_store:append(Store, [Selected])),
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
                  canonical(View#entry.cert)),
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
    {ok, Genesis} = Codec:new_entry(1, {batch, [GenesisTx]}, 0, none),
    {ok, GenesisBlock} = Codec:block_from_entry(Genesis),
    Anchor = digest(GenesisBlock#block.block_bytes),
    Admission = digest(term_to_binary({quod_validator_admission, 1, ?NS, 1, Anchor, Pub},
                                     [deterministic])),
    Binding = {?NS, Anchor},
    Tx = signed_transaction(Binding, Admission, Signer, 1, artifact_fact),
    {ok, ContentBlock} = Codec:new_block(2, 1, {batch, [Tx]}, 101),
    Content = Codec:entry(ContentBlock, certificate(commit, ContentBlock, Binding, Signer)),
    Skip = Codec:noop_entry(3, complaint_certificate(3, Binding, Signer)),
    ParentTx = signed_transaction(Binding, Admission, Signer, 2, parent_fact),
    ChildTx = signed_transaction(Binding, Admission, Signer, 3, child_fact),
    {ok, Parent} = Codec:new_block(4, 2, {batch, [ParentTx]}, 102),
    {ok, Child} = Codec:new_block(5, 4, {batch, [ChildTx]}, 103),
    Implicit = #implicit_cert{support = certificate(support, Parent, Binding, Signer),
                              child = Child,
                              commit = certificate(commit, Child, Binding, Signer)},
    #{anchor => Anchor, binding => Binding, admission => Admission, signer => Signer,
      parent => Parent, child => Child, transaction => Tx, implicit => Implicit,
      entries => [{genesis, Genesis}, {content, Content}, {skip, Skip},
                  {implicit, Codec:entry(Parent, Implicit)},
                  {child, Codec:entry(Child, Implicit#implicit_cert.commit)}]}.

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
                               Kind, Block#block.slot, Hash, Signer),
    #cert{kind = Kind, slot = Block#block.slot, block_hash = Hash,
          sigs = [{maps:get(pubkey, Signer), Signature}]}.

complaint_certificate(Slot, {Ns, Anchor}, Signer) ->
    #share{sig = Signature} = quod_simplex:make_share(
                               quod_simplex:consensus_domain(Ns, Anchor),
                               complaint, Slot, none, Signer),
    #cert{kind = complaint, slot = Slot, block_hash = none,
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

%% Captured with the frozen I1 ledger before native-control refactoring
%% (e4f767f, source SHA-256
%% 2fe4e9a9f32e9247906ee4cdd6df77dd4dd29a49b9930bfa35c90634e154c4e1)
%% and the current V15 transaction codec / V7 framing. The independent
%% constructor produces the same bytes as this tree. This pins the current
%% format, NOT compatibility with V14/V6; real old files are refused in the
%% carrier tests. All signatures use the fixed test-only seed.
expected_golden_vectors() ->
    #{anchor =>
          <<210,124,44,168,165,183,21,105,207,28,86,153,47,36,27,47,200,9,162,117,
            151,39,47,146,96,250,165,118,23,36,22,168>>,
      envelopes =>
          [{genesis,<<27,6,141,136,104,17,136,253,74,239,255,221,231,82,5,136,1,
                      27,222,88,63,193,154,102,56,178,114,177,30,178,213,123>>},
           {content,<<177,84,222,35,39,168,156,6,152,44,103,8,105,11,200,64,
                      243,130,78,106,111,199,193,137,45,123,239,149,67,1,76,19>>},
           {skip,<<219,158,161,111,183,71,100,244,0,156,23,3,66,204,131,78,230,75,
                   245,43,79,185,7,85,180,83,97,243,180,110,54,220>>},
           {implicit,<<222,160,146,71,61,197,213,161,125,134,56,145,26,202,
                       170,165,98,76,49,102,191,231,90,114,45,158,214,41,38,230,75,9>>},
           {child,<<79,115,147,208,21,10,28,28,216,31,163,241,92,248,219,81,
                    42,21,209,227,202,210,178,233,188,209,83,146,96,30,228,19>>}],
      frames =>
          <<178,202,129,193,5,246,11,68,194,231,55,83,178,145,204,161,191,9,
            193,78,0,193,146,96,118,189,166,173,222,83,255,129>>,
      signed_transaction =>
          <<48,115,211,113,178,38,115,64,169,1,151,252,110,99,117,13,25,15,
            112,202,6,193,111,150,59,174,49,236,226,32,161,223>>}.
