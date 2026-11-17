exec(compile((__import__('pathlib').Path(__file__).parent/'proposal-tests.py').read_text(),'proposal-tests.py','exec'))
n='src/quod_catchup.erl'
rep(n,'-ifdef(TEST).\ntest_call(test_recovery_state', '''-ifdef(TEST).
test_transfer_parts(Parts, Allowances) ->
    transfer_page(undefined, #transfer_sender{next = 1, last = 0, pending = Parts},
                  Allowances, [], 0).
test_call(test_recovery_state''')
n='test/quod_catchup_tests.erl'
cut(n,'terminal_frame_lookahead_preserves_every_part_test()', '\n', '') if False else None
s=get(n);s=s[:s.index('terminal_frame_lookahead_preserves_every_part_test()')]+'''terminal_frame_lookahead_preserves_every_part_test() ->
    Part = {entry, <<1,2,3>>}, End = end_group,
    Size = fun quod_catchup:part_body_size/1,
    More = Size(Part) - 1, Done = Size(Part) + Size(End),
    ?assertEqual({ok, [Part, End], done},
        quod_catchup:test_transfer_parts([Part, End], {More, Done})),
    Prefix = {group, 1, 1}, Parts = [Prefix, Part, End],
    Allowances = {Size(Prefix) + More, Size(Prefix) + Done - 1},
    {ok, [Prefix], Retained} = quod_catchup:test_transfer_parts(Parts, Allowances),
    ?assertEqual({ok, [Part, End], done},
        quod_catchup:transfer_page(undefined, Retained, {More, Done}, [], 0)),
    ?assertEqual({error, frame_unrepresentable},
        quod_catchup:test_transfer_parts([Part, End], {More, Done - 1})).
''';put(n,s)
n='test/quod_genesis_tests.erl'
rep(n,'founding_committee_cap_test','founding_committee_has_no_population_quota_test')
rep(n,'{error, {committee_too_large, ?LEGACY_MAX_VALIDATORS + 1}},','ok,')
rep(n,'?assertMatch({error, _}, quod_simplex:prepare_genesis(','?assertMatch({ok, _, _}, quod_simplex:prepare_genesis(')
rep(n,'%% Only a fresh founding\'s complete encoded envelope determines capacity.','%% Retained source is not readmitted; fresh founding keeps its complete material.')
rep(n,'complete_genesis_keeps_block_bound_test','complete_genesis_retains_all_authored_material_test')
rep(n,'%% Initial content alone fits the carrier. The generated\n    %% committee fact pushes the complete transaction above the block limit.','%% Include generated committee facts beyond the historical block quota.')
rep(n,'?assertThrow(\n       {genesis_failed, invalid_generated_genesis},','?assertMatch(\n       #transaction{},')
n='test/quod_catchup_verify_tests.erl'
cut(n,'%% Build an over-cap record','entry_with_data(Entry, Data) ->')
rep(n,'validator_cap_history_boundary_test','full_committee_history_boundary_test')
rep(n,'Oversized = oversized_genesis(pubs(committee(N + 1))),\n    ?assertEqual({error, {invalid_transaction, 1}},\n        verify_entries({?NS, gen_hash(Oversized)}, [Oversized])),','Expanded = committee(N + 1),\n    ?assertMatch({ok, _}, verify_chain(Expanded, [genesis(pubs(Expanded))])),')
rep(n,'?assertEqual({error, {invalid_transaction, 2}}, verify_chain(C, [G, Admission]))','?assertMatch({ok, _}, verify_chain(C, [G, Admission]))')
n='test/quod_committee_predicates_tests.erl'
cut(n,'%% The predicate gives an honest caller','admit_enforces_validator_cap_test()', '%% Admission remains governed by readiness and existing permission predicates.\n')
rep(n,' ->\n    Ns = <<"cp:cap">>,','admit_has_no_validator_population_quota_test() ->\n    Ns = <<"cp:cap">>,')
rep(n,'?assertEqual(\n       fail,\n       with_ready(\n         Ns, Extra,','?assertMatch(\n       [{assert, {{peer_admitted, Extra, "h", 1, Extra}, _}}],\n       with_ready(\n         Ns, Extra,')
n='test/quod_ledger_artifact_tests.erl'
rep(n,'block_binding_owns_the_payload_limit_test','block_binding_preserves_exact_large_payload_test')
rep(n,'quod_safe_term:encode_canonical(Wire, ?LEGACY_QUOD_MAX_CANONICAL_BLOCK_BYTES)','quod_safe_term:encode_canonical(Wire, unlimited)')
rep(n,'        ?assert(byte_size(Bytes) =< ?LEGACY_QUOD_MAX_CANONICAL_BLOCK_BYTES),\n','')
rep(n,'?assertEqual(Extra =:= 0, quod_ledger:valid_block_view(Block))','?assert(quod_ledger:valid_block_view(Block))')
rep(n,'?assertEqual(Extra =:= 0, quod_simplex:well_formed_block(Block))','?assert(quod_simplex:well_formed_block(Block))')
n='test/quod_ingress_state_tests.erl'
rep(n,'{reject, too_large},','{collect, 4},')
rep(n,'queue_per_author_bound_test','queue_preserves_all_authors_test')
rep(n,'    ?assertEqual(\n       full,\n       quod_ingress_state:enqueue(\n         local, overflow, Prepared, 65, S64)),','    {ok, 65, Expanded} = quod_ingress_state:enqueue(\n         local, next, Prepared, 65, S64),')
rep(n,'OtherPrepared = prepared(Other, S64)','OtherPrepared = prepared(Other, Expanded)')
rep(n,'{ok, 65, S65}','{ok, 66, S65}')
rep(n,'local, other, OtherPrepared, 66, S64','local, other, OtherPrepared, 66, Expanded')
rep(n,'#{A => 64, B => 1}','#{A => 65, B => 1}')
n='test/quod_foreign_log_tests.erl'
rep(n,'authenticated_bootstrap_candidates_are_bounded_and_peer_unique_test','authenticated_bootstrap_candidates_are_complete_and_peer_unique_test')
rep(n,'?assertEqual(Limit, maps:get(bootstrap_candidates, Stats1))','?assertEqual(Limit + 1, maps:get(bootstrap_candidates, Stats1))')
rep(n,'        ?assertEqual(1, maps:get(bootstrap_evicted, Stats1)),\n','')
rep(n,'?assert(length(Selected) =< ?LEGACY_MAX_VALIDATORS)','?assertEqual(Limit + 1, length(Selected))')
rep(n,'?assertEqual(Limit,\n                     maps:get(bootstrap_candidates,','?assertEqual(Limit + 1,\n                     maps:get(bootstrap_candidates,')
rep(n,'?assertEqual(2 * ?LEGACY_MAX_VALIDATORS,\n                     maps:get(bootstrap_candidates, Stats)),\n        ?assertEqual(2, maps:get(bootstrap_evicted, Stats))','?assertEqual(2 * ?LEGACY_MAX_VALIDATORS + 2,\n                     maps:get(bootstrap_candidates, Stats))')
rep(n,'?assert(byte_size(Frame) < ?LEGACY_QUOD_MAX_FOREIGN_PAGE_BYTES)','?assert(byte_size(Frame) =< ?QUOD_LINK_PAYLOAD_CAPACITY)')
n='test/quod_foreign_residency_tests.erl'
rep(n,'write_checkpoint, 5','write_checkpoint, 7')
rep(n,'Ranges = (Height + ?LEGACY_QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1)\n                 div ?LEGACY_QUOD_MAX_FOREIGN_PAGE_ENTRIES,','Ranges = 1,')
n='test/quod_simplex_tests.erl'
section(n,'blocked_author_does_not_block_other_authors_test()', '\n%% The first pass',lambda s:s.replace('blocked_author_does_not_block_other_authors','large_author_keeps_order_without_blocking_other_authors').replace('?assertMatch({park, _},','?assertEqual({collect, 4},').replace('''    {2, _, #{AuthorA := 2},
     [{relayed, A1Id, _}, {relayed, A2Id, _}]} =
        quod_simplex:test_ingress(Drained),
    ?assertEqual(A1#transaction.tx_id, A1Id),
    ?assertEqual(A2#transaction.tx_id, A2Id),
    ?assertEqual(2, maps:get(appends, quod_simplex:stats_map(Drained))),''','''    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual(4, maps:get(appends, quod_simplex:stats_map(Drained))),'''))
cut(n,'%% The first pass can itself change routing: B and C','drain_rechecks_held_authors_after_route_change_test()', '%% All queued material is retained without an artificial batch-byte closure.\n')
rep(n,' ->\n    Committee = committee(5),','large_batch_drain_preserves_all_authors_test() ->\n    Committee = committee(5),')
section(n,'large_batch_drain_preserves_all_authors_test()', '\n%% A participant',lambda s:s.replace('?assertEqual(3, maps:get(appends, Stats))','?assertEqual(5, maps:get(appends, Stats))').replace('?assertEqual(2, maps:get(r_redirect, Stats))','?assertEqual(0, maps:get(r_redirect, Stats))'))
cut(n,'%% Shared and per-author bounds: overflow','ingress_overflow_and_author_cap_test()', '%% The real append owner retains every distinct waiter while consensus is blocked.\n')
rep(n,' ->\n    Committee = committee(2),\n    Validators = pubs(Committee),\n    %% the node that leads','ingress_retains_all_authors_test() ->\n    Committee = committee(2),\n    Validators = pubs(Committee),\n    %% the node that leads')
rep(n,'?assert(lists:member({reply, FromB, {error, busy}}, A65)),\n    ?assertEqual(1, maps:get(ingress_overflow, quod_simplex:stats_map(S65)))','?assertEqual([], A65),\n    ?assertMatch({65, _, #{Me := 65}, _}, quod_simplex:test_ingress(S65))')
rep(n,'{65, _, #{Other := 1}, _} = quod_simplex:test_ingress(S66)','{66, _, #{Me := 65, Other := 1}, _} = quod_simplex:test_ingress(S66)')
rep(n,'membership_gate_enforces_validator_cap_test','membership_gate_uses_shape_and_permission_not_population_test')
rep(n,'?assertNot(quod_simplex:membership_change_ok(\n                 tx([pa(Candidate)]), Current))','?assert(quod_simplex:membership_change_ok(\n                 tx([pa(Candidate)]), Current))')
section(n,'ready_lower_sequence_capacity_block_prevents_local_overtake_test()', '\n%% Membership shares',lambda s:s.replace('ready_lower_sequence_capacity_block_prevents_local_overtake','ready_lower_sequence_keeps_priority_without_byte_quota').replace('{park, awaiting_turn},\n       quod_simplex:test_route','{collect, 5},\n       quod_simplex:test_route').replace('{CustodyHeld, []}','{CustodyHeld, _}').replace('{StillHeld, []}','{StillHeld, _}').replace('''    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(StillHeld),
    {1, _, #{Me := 1}, [{local, SmallId, _}]} =
        quod_simplex:test_ingress(StillHeld),
    ?assertEqual(1, maps:get(appends, quod_simplex:stats_map(StillHeld))),''','''    [{SubmissionId, 1, Submission, {local, 5}, Deadline, 1},
     {_, 2, _, {local, 5}, _, 1}] = quod_simplex:test_custody(StillHeld),
    {0, 0, _, []} = quod_simplex:test_ingress(StillHeld),
    ?assertEqual(3, maps:get(appends, quod_simplex:stats_map(StillHeld))),'''))
put(n,get(n)+'''
outbox_preserves_every_distinct_frame_and_deduplicates_test() ->
    Frames = [<<N:64>> || N <- lists:seq(1, 1025)],
    Buffered = lists:foldl(fun quod_simplex:buffer_frame/2, [], Frames),
    ?assertEqual(lists:reverse(Frames), Buffered),
    ?assertEqual(Buffered, quod_simplex:buffer_frame(hd(Frames), Buffered)).
''')
n='test/quod_client_auth_tests.erl'
put(n,get(n)+'''
default_auth_tables_retain_more_than_256_entries_test() ->
    with_auth(fun() ->
        KeyPair = quod_identity:generate(),
        Pending = [signed_challenge(KeyPair, <<N:256>>) || N <- lists:seq(1, 257)],
        Sessions = [begin
            {ok, #{session_id := Id}} = quod_client_auth:complete_challenge(C, Sig), Id
        end || {C, Sig} <- Pending],
        ?assertEqual(257, length(lists:usort(Sessions))),
        lists:foreach(fun(Id) -> ?assertMatch({ok, _}, quod_client_auth:session(Id)) end, Sessions),
        lists:foreach(fun({C, Sig}) ->
            ?assertEqual({error, invalid_challenge}, quod_client_auth:complete_challenge(C, Sig))
        end, Pending)
    end).
''')
# Dependency test expectations follow the same transient record change. Explicit
# callback policy truncation, portable terms, merge order, unbound rejection stay.
n='_build/default/lib/erlog/test/erlog_failure_reasons_tests.erl'
s=get(n)
for k in legacy:s=re.sub(r'\?'+k+r'\b',str(legacy[k]),s)
s=re.sub(r'^\s*\?assertEqual\([^\n]*, (?:Final|Outer|St2)#est\.fail_reason_count\),?\n','\n',s,flags=re.M)
s=s.replace('successful_call_boundaries_are_capped_test','successful_call_boundaries_are_retained_test')
s=s.replace('?assertEqual(256, length(Boundaries)),\n    ?assertEqual(256, Final#est.fail_boundaries),\n    ?assert(Final#est.fail_reasons_truncated).','?assertEqual(306, length(Boundaries)),\n    ?assertNot(Final#est.fail_reasons_truncated).')
s=s.replace('oversized_reason_is_truncated_test','large_reason_is_preserved_test').replace('?assertEqual([fail_reasons_truncated], Final#est.fail_reasons),\n    ?assertEqual(1, Final#est.fail_reason_count).','?assertEqual([Reason], Final#est.fail_reasons).')
s=s.replace('outer_frames_survive_an_inner_truncation_test','outer_frames_preserve_a_large_inner_reason_test').replace('?assertEqual([{outer, failed}, fail_reasons_truncated],\n                 Outer#est.fail_reasons),\n    ?assertEqual(2, Outer#est.fail_reason_count).','?assertEqual([{outer, failed}, Oversized], Outer#est.fail_reasons).')
a=s.index('total_reason_stack_is_bounded_test()');b=s.index('custom_stack_policy_truncates_at_creation_test()',a)
s=s[:a]+'''total_reason_stack_is_preserved_test() ->
    Reason = binary:copy(<<"x">>, 4000),
    Final = lists:foldl(
              fun(N, St) -> erlog_int:add_failure_reason({reason, N, Reason}, St) end,
              state(), lists:seq(1, 10)),
    ?assertEqual([{reason, N, Reason} || N <- lists:seq(10, 1, -1)], Final#est.fail_reasons),
    ?assertNot(Final#est.fail_reasons_truncated).

'''+s[b:]
s=s.replace('?assertEqual(error, erlog_int:merge_failure_reasons([Oversized], Local))','?assertMatch({ok, _}, erlog_int:merge_failure_reasons([Oversized], Local))')
put(n,s)
# Current-contract docs; historical handoffs and failures are immutable.
n='doc/multiwrite-architecture.md'
rep(n,'''encoding bounds; material decoding retains VM headroom checks. This is not a
new resource sandbox for arbitrary traffic from admitted committee members.
The full enclosing transaction, block and transport still have encoding
capacity checks. Their shared material capacity fits both the existing scope
carrier and the history page with a full-committee compact witness; accepted
canonical bytes are unchanged. Decoding accepted history does not reapply current admission
policy. It still validates the wire alphabet and real VM atom-table headroom.''','''encoding constraints. This is not a resource sandbox for arbitrary traffic
from admitted committee members. Materialization checks actual VM atom-table
capacity before allocating new names; this precheck does not reserve capacity
against unrelated concurrent VM allocation. Explicit finite client vocabulary
allowances remain enforced by the authentication owner.
The complete transport envelope and store record retain their actual encoded
length constraints. History readers retain one captured cursor and stream
complete frames with exact continuation tokens; partial finality groups are
never installed. Decoding accepted history does not reapply current admission
policy. It still validates the wire alphabet and canonical identity bindings.''')
n='doc/consensus-signatures.md'
rep(n,'delta before publishing the corresponding state. `quod_catchup` serves bounded\npages from an immutable captured view; the receiver verifies ancestry,','delta before publishing the corresponding state. `quod_catchup` serves pages\nwhich fit their complete encoded frames from one immutable captured view,\nretaining its cursor and continuation credits; the receiver verifies ancestry,')
# Correct generated test function headings; compile05 retains the failed draft.
rep('test/quod_catchup_tests.erl','byte_cap_test() ->\ncomplete_large_local_page_test() ->','complete_large_local_page_test() ->')
rep('test/quod_committee_predicates_tests.erl','admit_enforces_validator_cap_test()admit_has_no_validator_population_quota_test()','admit_has_no_validator_population_quota_test()')
rep('test/quod_simplex_tests.erl','drain_rechecks_held_authors_after_route_change_test()large_batch_drain_preserves_all_authors_test()','large_batch_drain_preserves_all_authors_test()')
rep('test/quod_simplex_tests.erl','ingress_overflow_and_author_cap_test()ingress_retains_all_authors_test()','ingress_retains_all_authors_test()')
# Include the concrete extra behavior cases in the reviewable repository test overlay.
new('test/quod_remaining_admission_tests.erl', (E/'proposals/remaining_admission_checks.erl').read_text().replace('-module(remaining_admission_checks).','-module(quod_remaining_admission_tests).').replace('-include_lib("erlog/src/erlog_int.hrl").','-include("erlog_int.hrl").'))
n='test/quod_foreign_log_tests.erl'
put(n,get(n)+'''
all_authored_route_endpoints_keep_order_and_shape_test() ->
    Routes = [{<<1:256>>, [{"first", 1001}, {"second", 1002}, {"third", 1003}]}],
    ?assertEqual({ok, Routes}, quod_foreign_log:normalize_route_candidates(Routes)),
    ?assertEqual(error, quod_foreign_log:normalize_route_candidates(Routes ++ Routes)),
    ?assertEqual(error, quod_foreign_log:normalize_route_candidates([{<<1:256>>, [{"first", 1001}, {"first", 1001}]}])),
    ?assertEqual(error, quod_foreign_log:normalize_route_candidates([{<<1:256>>, [{"first", 0}]}])).
''')
# The quota-only VM header has no remaining runtime or test owner.
for f in (R/'test').glob('*.erl'):
 n=str(f.relative_to(R));s=D.get(n,f.read_text())
 if '-include("quod_vm_limits.hrl").' in s:
  put(n,s.replace('-include("quod_vm_limits.hrl").\n',''))
rep('include/quod_client_goal_limits.hrl','%% correlations/workers. Population is not an admission policy; byte, term,\n%% deadline and VM-safety bounds remain at the untrusted boundary.','%% correlations/workers. Existing deadlines, authenticated encoding and explicit\n%% finite owner allowances govern the corresponding boundaries.')
n='test/quod_simplex_tests.erl'
put(n,get(n)+'''
held_membership_rechecks_after_same_event_batch_seal_test() ->
    Committee = committee(4), Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    [{A, IdA}, {B, IdB}, {C, IdC}] = [P || {Pub, _} = P <- Committee, Pub =/= Me],
    First = signed_tx(<<"t">>, <<"fixed-point-first">>, [{assert, {{ordinary, first}, true}}], {B, IdB}),
    Second = signed_tx(<<"t">>, <<"fixed-point-second">>, [{assert, {{ordinary, second}, true}}], {C, IdC}),
    Membership = signed_tx_seq(<<"t">>, <<"fixed-point-member">>, 10, [pa(<<99:256>>)], {A, IdA}),
    Tail = signed_tx_seq(<<"t">>, <<"fixed-point-tail">>, 11, [{assert, {{ordinary, tail}, true}}], {A, IdA}),
    Base = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                slot => 3, history_head => {3, <<1:256>>}, eng => root_engine(3)}),
    Now = quod_time:mono_ms(),
    Queued = quod_simplex:test_state_set(ingress,
        [{relayed, B, 4, First, Now}, {relayed, C, 4, Second, Now + 1},
         {relayed, A, 4, Membership, Now + 2}, {relayed, A, 4, Tail, Now + 3}], Base),
    %% The first two ordinary items form a batch. Membership cannot join it;
    %% stopping that pass seals the batch and closes its exact relay target.
    %% A single pass leaves the last two rows stranded. The existing fixed-point
    %% owner must revisit and redirect both during this same test_drain call.
    {Drained, Actions} = quod_simplex:test_drain(Queued),
    ?assert(lists:member({{timeout, batch}, cancel}, Actions)),
    ?assertMatch({0, 0, _, []}, quod_simplex:test_ingress(Drained)),
    Stats = quod_simplex:stats_map(Drained),
    ?assertEqual(2, maps:get(appends, Stats)),
    ?assertEqual(2, maps:get(r_redirect, Stats)),
    ?assertNot(quod_simplex:test_ingress_needs_drain(Drained, Drained)).
''')
exec(compile((E/'proposal-workers.py').read_text(),'proposal-workers.py','exec'))
# Split the review artifacts by repository ownership; nothing is installed.
emit()
p=E/'proposals';m=json.loads((p/'manifest.json').read_text());repo=[];dep=[]
for n in m['files']:
 diff=list(difflib.unified_diff(B[n].splitlines(True),D[n].splitlines(True),fromfile='a/'+n if B[n] else '/dev/null',tofile='b/'+n if D[n] else '/dev/null'))
 if n.startswith('_build/default/lib/erlog/'):
  diff=[x.replace('_build/default/lib/erlog/','') if x.startswith(('---','+++')) else x for x in diff];dep.extend(diff)
 else:repo.extend(diff)
(p/'remaining-owners.patch').write_text(''.join(repo));(p/'erlog-diagnostics.patch').write_text(''.join(dep))
m['dependency']={'pin':'535395c60b2133703308bbe529a63309672cb7a0','patch':'erlog-diagnostics.patch','installed':False,'pin_changed':False,'requires_reviewed_dependency_revision':True}
m['production_applied_delta']={'added':0,'removed':0};m['revision']='consolidated02';m['deleted']=['include/quod_vm_limits.hrl']
(p/'manifest.json').write_text(json.dumps(m,indent=2)+'\n')
