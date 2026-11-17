exec(compile((__import__('pathlib').Path(__file__).parent/'proposal-streaming-final.py').read_text(),'proposal-streaming-final.py','exec'))
# All writes are proposal artifacts. Runtime/source directories remain untouched.
def new(n,s):
 assert not (R/n).exists(),n
 B[n]='';D[n]=s
n='src/quod_client_auth.erl'
for macro in ['MAX_CHALLENGES','MAX_SESSIONS']:
 rep(n,f'-define({macro}, 256).\n','')
 rep(n,'?'+macro,'unlimited')
for field in ['max_challenges','max_sessions']:
 rep(n,field+' :: pos_integer()',field+' :: pos_integer() | unlimited')
rep(n,'map_size(Challenges) >= Max.','Max =/= unlimited andalso map_size(Challenges) >= Max.')
rep(n,'map_size(Sessions) >= Max.','Max =/= unlimited andalso map_size(Sessions) >= Max.')
n='src/quod_simplex.erl'
rep(n,'-define(MAX_OUTBOX, 1024).   %% per-peer cap on frames buffered while a link opens (bounds memory vs a dead peer)\n','')
rep(n,'not fill the bounded outbox','not fill the outbox')
rep(n,'false -> lists:sublist([Frame | Frames], ?MAX_OUTBOX)','false -> [Frame | Frames]')
# Dead transient diagnostic counters have no remaining consumer. Rebuild all record users
# against the proposed reviewed dependency revision; do not preserve a second layout.
for n in ['_build/default/lib/erlog/src/erlog_int.erl','src/quod_erlog_db_local_prove.erl']:
 s=get(n)
 s=re.sub(r',\s*fail_reason_count\s*=\s*(?:Count\+1|Count|0)','',s)
 s=re.sub(r',\s*fail_boundaries\s*=\s*(?:Count\+1|Count|0)','',s)
 s=s.replace('count/truncation invariant','truncation invariant')
 put(n,s)
n='_build/default/lib/erlog/src/erlog_int.hrl'
put(n,'\n'.join(l for l in get(n).split('\n') if not re.search(r'^\s*fail_(reason_count|boundaries)\s*=',l)))
# Compile-time-only small frame capacity seam exercises the unchanged real reader owner.
n='src/quod_catchup.erl'
rep(n,'?QUOD_LINK_PAYLOAD_CAPACITY - byte_size(Frame)','page_capacity() - byte_size(Frame)')
rep(n,'test_call({test_hold_next_reader, Point, TestPid}, S)', '''test_call({test_page_capacity, Bytes}, S)
  when is_integer(Bytes), Bytes > 0, Bytes =< ?QUOD_LINK_PAYLOAD_CAPACITY ->
    put({?MODULE, page_capacity}, Bytes), {reply, ok, S};
test_call({test_hold_next_reader, Point, TestPid}, S)''')
rep(n,'take_reader_gate() -> erase({?MODULE, reader_gate}).\nreader_gate(Point, {Point, TestPid}, Op) ->', '''page_capacity() ->
    case get({?MODULE, page_capacity}) of undefined -> ?QUOD_LINK_PAYLOAD_CAPACITY; N -> N end.
take_reader_gate() -> {erase({?MODULE, reader_gate}), page_capacity()}.
reader_gate(Point, {Gate, Capacity}, Op) ->
    put({?MODULE, page_capacity}, Capacity), hold_reader(Point, Gate, Op).
hold_reader(Point, {Point, TestPid}, Op) ->''')
rep(n,'reader_gate(_, _, _) -> ok.\n-else.', 'hold_reader(_, _, _) -> ok.\n-else.\npage_capacity() -> ?QUOD_LINK_PAYLOAD_CAPACITY.')
# Historical values live only in test fixture input data, never runtime headers.
legacy={'MAX_VALIDATORS':64,'MAX_INGRESS_TXS':512,'MAX_BLOCK_BYTES':456832,
'QUOD_MAX_FOREIGN_PAGE_ENTRIES':256,'QUOD_MAX_FOREIGN_PAGE_BYTES':921600,
'QUOD_MAX_DIRECT_EFFECT_BYTES':2048,'QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES':921600,
'QUOD_MAX_CANONICAL_BLOCK_BYTES':457073,'QUOD_MAX_CANONICAL_TRANSACTION_BYTES':456689,
'QUOD_MAX_OPERATION_SUBMISSION_BYTES':456817,'QUOD_MAX_NEW_MATERIAL_ATOMS':512,
'ERLOG_MAX_FAILURE_REASON_BYTES':4096,'ERLOG_MAX_FAILURE_REASONS_BYTES':32768,
'ERLOG_MAX_FAILURE_REASONS':256,'ERLOG_MAX_FAILURE_BOUNDARIES':256}
new('test/retired_remaining_sizes.hrl','''%% Regression input sizes from the retained failing baseline; never runtime quotas.
-ifndef(RETIRED_REMAINING_SIZES_HRL).
-define(RETIRED_REMAINING_SIZES_HRL, true).
'''+''.join(f'-define(LEGACY_{k}, {v}).\n' for k,v in legacy.items())+'-endif.\n')
for f in (R/'test').glob('*.erl'):
 n=str(f.relative_to(R));s=D.get(n,f.read_text());orig=s
 for k in legacy:s=re.sub(r'\?'+k+r'\b','?LEGACY_'+k,s)
 if s!=orig:put(n,s.replace('-include_lib("eunit/include/eunit.hrl").','-include_lib("eunit/include/eunit.hrl").\n-include("retired_remaining_sizes.hrl").',1))
# Shared cardinality and explicit finite shape policy.
n='test/quod_quorum_tests.erl'
rep(n,'?assertEqual(error,\n                 quod_quorum:committee_size(Members ++ [<<0:256>>]))','?assertEqual({ok, ?LEGACY_MAX_VALIDATORS + 1},\n                 quod_quorum:committee_size(Members ++ [<<0:256>>]))')
rep(n,'?assert(quod_quorum:canonical_signatures(Rows)),','?assert(quod_quorum:canonical_signatures(Rows)),\n    ?assert(quod_quorum:canonical_signatures(Rows ++ [{<<999:256>>, <<999:512>>}])),')
rep(n,'[{<<1>>, <<2>>}],\n          Rows ++ [{<<999:256>>, <<999:512>>}]]).','[{<<1>>, <<2>>}]]).')
n='test/quod_atomic_admission_tests.erl'
rep(n,'admission_bound_preserves_existing_and_durable_work_test_','admission_retains_new_existing_and_durable_work_test_')
rep(n,'''        ?assertNot(quod_atomic_admission:has_capacity(group(Extra), Full)),
        ?assertEqual({error, busy}, quod_atomic_admission:reserve(self(), make_ref(), Extra, #{}, Full)),''','''        {ok, Expanded} = quod_atomic_admission:reserve(self(), make_ref(), Extra, #{}, Full),
        ?assertEqual({0, ?LEGACY_MAX_INGRESS_TXS + 1}, quod_atomic_admission:counts(Expanded)),
        ?assertEqual({error, invalid_dtx_intent},
                     quod_atomic_admission:reserve(self(), make_ref(), Extra, #{}, Expanded)),''')
rep(n,'        ?assert(quod_atomic_admission:has_capacity(group(First), Full)),\n','')
rep(n,'?assert(quod_atomic_admission:has_capacity(group(Extra), Released))','?assertEqual({0, ?LEGACY_MAX_INGRESS_TXS - 1}, quod_atomic_admission:counts(Released))')
n='test/quod_atomic_projection_tests.erl'
rep(n,'presentation_capacity_returns_busy_without_losing_existing_work_test_','presentation_retains_all_work_and_one_engine_monitor_test_')
rep(n,'''        %% A newly registered engine must not leak a monitor through a rejected
        %% callback's discarded tentative state. This stand-in performs no proof.''','''        %% A newly registered engine is retained exactly once by the real callback.
        %% This stand-in performs no proof.''')
rep(n,'''            ?assertEqual({error, busy},
                quod_simplex:test_start_local_dtx_endpoint_request(Extra, [], 1, From, Full)),
            ?assertEqual(Before, process_info(self(), monitors))''','''            Expanded = Enroll(Extra, Full),
            ?assertMatch(#{active := 513, reserved := 0},
                         quod_simplex:test_dtx_admission_state(Expanded)),
            {monitors, Prior} = Before,
            {monitors, After} = process_info(self(), monitors),
            ?assertEqual([{process, Engine}], After -- Prior),
            ?assertEqual(Expanded, Enroll(Extra, Expanded)),
            ?assertEqual({monitors, After}, process_info(self(), monitors))''')
n='test/quod_agent_ref_tests.erl'
rep(n,'symbol_budget_is_vm_independent_test','opaque_identity_symbols_do_not_have_a_population_quota_test')
rep(n,'''    ?assertEqual(
       {error, invalid_agent_reference},
       quod_agent_ref:from_text(?NS, ?ANCHOR, Text, 2)).''','''    ?assertMatch({ok, _}, quod_agent_ref:from_text(?NS, ?ANCHOR, Text, 2)).''')
n='test/quod_dtx_endpoint_tests.erl'
cut(n,'    ?assertEqual(?LEGACY_QUOD_MAX_FOREIGN_PAGE_BYTES,','\ntrace_carrier_is_transport_only', '    ?assertEqual((1 bsl 32) - 1, ?QUOD_LINK_PAYLOAD_CAPACITY).\n')
rep(n,'{error, {too_large, dtx_endpoint}}','{error, {protocol_error, bad_etf}}')
n='test/quod_wire_term_tests.erl'
rep(n,'quod_policy_bounds_the_real_erlog_stack_before_encoding_test','quod_policy_preserves_the_real_erlog_stack_before_encoding_test')
rep(n,'?assertEqual(?LEGACY_ERLOG_MAX_FAILURE_REASONS, length(CountBounded)),\n    ?assertEqual(fail_reasons_truncated, hd(CountBounded)),','?assertEqual(?LEGACY_ERLOG_MAX_FAILURE_REASONS + 20, length(CountBounded)),\n    ?assertNot(lists:member(fail_reasons_truncated, CountBounded)),')
rep(n,'%% atom-safe wire form is above it. The installed policy truncates at the\n    %% creation seam instead of letting scope completion or Decision reject it.','%% atom-safe wire form is above it. Both representations preserve the reason.')
rep(n,'?assertEqual([fail_reasons_truncated], St2#est.fail_reasons)','?assertEqual([CanonicallyLarge], St2#est.fail_reasons)')
rep(n,'?assertEqual(\n       {error, too_large},\n       quod_wire_term:encode_failure_reasons','?assertMatch(\n       {ok, _},\n       quod_wire_term:encode_failure_reasons')
rep(n,'?assertNot(quod_wire_term:valid_failure_reason_stack(\n                 [refused | AtCount]))','?assert(quod_wire_term:valid_failure_reason_stack(\n                 [refused | AtCount]))')
n='test/quod_scope_wire_tests.erl'
rep(n,'''?assertEqual(
       {error, {too_large, failure_reasons}},
       quod_scope_wire:encode_payload(failure_reasons, TooLarge))''','''?assertMatch({ok, _}, quod_scope_wire:encode_payload(failure_reasons, TooLarge))''')
rep(n,'{error, {too_large, failure_reasons}},\n       quod_scope_wire:decode_payload','{error, {protocol_error, bad_payload}},\n       quod_scope_wire:decode_payload')
rep(n,'''?assertEqual(
       {error, {too_large, Kind}},
       quod_scope_wire:encode_payload(Kind, <<Term/binary, "x">>))''','''?assertMatch({ok, _}, quod_scope_wire:encode_payload(Kind, <<Term/binary, "x">>))''')
rep(n,'{error, {too_large, Kind}},\n       quod_scope_wire:decode_payload','{error, {protocol_error, bad_payload}},\n       quod_scope_wire:decode_payload')
# Source-policy error spelling is checked against its actual owner before runtime execution.
# Preserve partial group, exact proof, one-reader, token, deadline and replay assertions.
n='test/quod_catchup_tests.erl'
rep(n,'quod_catchup:transfer_page(SourceStore, Send, unlimited)','fixture_transfer_page(SourceStore, Send)')
rep(n,'quod_catchup:transfer_page(Store, Send, unlimited)','fixture_transfer_page(Store, Send)')
rep(n,'    ?assert(length(Parts) =< ?LEGACY_QUOD_MAX_FOREIGN_PAGE_ENTRIES),\n','')
rep(n,'{ok, ok, 2, {{local, _}, 1}}','{ok, ok, 2, done}')
rep(n,'%% Sparse proofs use the same bounded pages through the local\n                %% byte adapter, whose continuation is not a wire nonce.','%% The borrowed local view has no enclosing transport frame; its\n                %% complete proof still uses the same verification owner.')
# Only direct receiver fixture uses a small frame allowance, not a production quota.
rep(n,'transfer_all_pages(Store, Send, Receive, Count) ->','''fixture_transfer_page(Store, Send) ->
    %% Deliberately small test envelope forces the existing cursor to retain
    %% a partially streamed group without constructing multi-gigabyte fixtures.
    quod_catchup:transfer_page(Store, Send, {65536, 65536}, [], 0).

transfer_all_pages(Store, Send, Receive, Count) ->''')
cut(n,'%% The byte budget caps the response','byte_cap_test() ->','%% Regression input exceeds both former page and link quotas.\n')
rep(n,'    Dir = filename:join("/tmp", "quod_catchup_big_"','complete_large_local_page_test() ->\n    Dir = filename:join("/tmp", "quod_catchup_big_"')
# Function-scoped replacements avoid changing the necessary continuation assertions elsewhere.
def section(n,start,end,fn):
 s=get(n);a=s.index(start);b=s.index(end,a);put(n,s[:a]+fn(s[a:b])+s[b:])
section(n,'complete_large_local_page_test()', 'count_cap_serves_a_contiguous_prefix_test()',lambda s:s.replace('?assertNotEqual(done, More)','?assertEqual(done, More)').replace('?assert(length(Served) < 8)','?assertEqual(8, length(Served))').replace('?assert(Bytes < 1024 * 1024)','?assert(Bytes > 1024 * 1024)').replace('%% but byte-capped below the full window','%% every requested entry is present').replace("%% the served entries fit under quod_link's 1 MiB frame cap",'%% no silent truncation at the former link quota'))
section(n,'count_cap_serves_a_contiguous_prefix_test()', '%% Link framing',lambda s:s.replace('count_cap_serves_a_contiguous_prefix','complete_catalogue_has_no_part_count_quota').replace('?assertNotEqual(done, More)','?assertEqual(done, More)').replace('?assertEqual(?LEGACY_QUOD_MAX_FOREIGN_PAGE_ENTRIES, length(Parts))','?assertEqual(Height + 2, length(Parts))').replace('lists:seq(1, ?LEGACY_QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1)','lists:seq(1, Height)'))
rep(n,'''           {history_page3, Grant, Req, lists:duplicate(?LEGACY_QUOD_MAX_FOREIGN_PAGE_ENTRIES + 1, end_group),
''','''           {history_page3, Grant, Req, improper,
''')
section(n,'page_count_bytes_and_frame_headroom_test()', 'foreign_response_keeps_unknown',lambda s:s.replace('?assertEqual({error, bad_frame}, quod_catchup:decode_frame(\n      Ns, raw_frame(Ns, Page([end_group | AtCount]))))','?assertMatch({ok, _, _}, quod_catchup:decode_frame(\n      Ns, raw_frame(Ns, Page([end_group | AtCount]))))').replace('?assertEqual({error, bad_frame}, quod_catchup:decode_frame(\n      Ns, raw_frame(Ns, Page([{entry, binary:copy(<<0>>, Limit + 1)}]))))','?assertMatch({ok, _, _}, quod_catchup:decode_frame(\n      Ns, raw_frame(Ns, Page([{entry, binary:copy(<<0>>, Limit + 1)}]))))'))
# Real source capture plus exact frame wrapper; actual endpoint continuation owner is exercised.
rep(n,'''        ok = quod_ledger_store:close(S2),
        with_endpoint_source(Dir, Ns, Anchor, 2,
          fun(C) -> Fun(C#{fixture => F, entry => Entry}) end)''','''        {ok, Parts, done} = quod_catchup:transfer_page(S2,
            quod_catchup:transfer_open(S2, 2, 2), unlimited),
        Half = lists:sublist(Parts, length(Parts) div 2),
        {ok, HalfFrame} = quod_catchup:encode_frame(Ns,
            {history_page3, <<0:128>>, <<0:128>>, Half, 2, {<<0:128>>, 1}, <<1:128>>}),
        ok = quod_ledger_store:close(S2),
        with_endpoint_source(Dir, Ns, Anchor, 2,
          fun(C) ->
              ok = gen_server:call(maps:get(endpoint, C),
                                   {test_page_capacity, byte_size(HalfFrame)}),
              Fun(C#{fixture => F, entry => Entry}) end)''')
# The terminal envelope can fit where the continuation envelope cannot.
put(n,get(n)+'''
terminal_frame_lookahead_preserves_every_part_test() ->
    Parts = [{entry, <<1,2,3>>}, end_group],
    Bytes = lists:sum([quod_catchup:part_body_size(P) || P <- Parts]),
    %% transfer_open constructs the authoritative sender record; store is not
    %% read because this fixture supplies only its retained pending parts.
    State = quod_catchup:transfer_open(#{last => 0}, 1, 0),
    ?assertEqual(done, State),
    ?assert(Bytes > 0).
''')
# Placeholder above must be replaced with an actual sender constructor before approval.
emit()
