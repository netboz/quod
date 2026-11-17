"""Loaded only by the artifact generator; these are unexecuted proposed tests."""

def router_seams(s):
    s = s.replace('test_cursor_target_result/1, test_submit_target_result/2]).',
                  'test_cursor_target_result/1, test_submit_target_result/2,\n         test_send_result/3, test_send_response/2]).')
    return s.replace('test_stats(Router) ->', '''test_send_result(Link, Request, Result) -> send_result(Link, Request, Result).
test_send_response(Link, Response) -> send_response(Link, Response).

test_stats(Router) ->''')
edit('presentation-reply-owner', 'src/quod_client_goal_router.erl', router_seams)

router_tests = '''
remote_transport_overflow_delivers_correlated_public_refusal_test() ->
    {ok, Payload} = quod_wire_term:encode_bindings(
        #{<<"X">> => binary:copy(<<$x>>, ?QUOD_TRANSPORT_MAX_FRAME_BYTES)}, unlimited),
    Ref = {transaction, <<"quod:test">>, <<1:256>>, <<2:256>>},
    lists:foreach(fun({Cursor, Result}) ->
        with_router(fun(Router, Link, Fixture) ->
            Caller = submit_async(Router, Fixture, Cursor, 1000),
            {Request, _} = sent_request(Link),
            ok = quod_client_goal_router:test_send_result(Link, Request, Result),
            Frame = target_frame(Link),
            {ok, Response} = quod_client_goal_endpoint:decode_response(Frame),
            Id = quod_client_goal_endpoint:request_id(Request),
            {ok, Error} = quod_client_result:encode({error, result_too_large}),
            Expected = case Cursor of none -> {result, Id, Error};
                _ -> {cursor_result, Id, Cursor, Error} end,
            ?assertEqual(Expected, Response),
            Router ! {quod_message, {?PEER, Link}, quod_client_goal_endpoint:channel(), Frame},
            receive {Caller, {ok, _, {normalized, {error, result_too_large}}}} -> ok
            after 1000 -> error(overflow_refusal_missing) end,
            await_stats(Router, #{correlations => 0, routes => 0}),
            assert_released_lease(Link, Router)
        end)
    end, [{none, {answers, 7, [Payload]}},
          {<<9:256>>, {solution, <<9:256>>, 7, Payload}},
          {none, {committed, [Payload], Ref}}]).

target_encoding_keeps_outcome_and_distinguishes_invalid_from_size_test() ->
    Parent = self(), Link = spawn(fun() -> link_loop(Parent) end),
    Ref = {transaction, <<"quod:test">>, <<1:256>>, <<2:256>>},
    Request = {submit, <<8:128>>, <<>>, <<0:512>>, none, []},
    try
        lists:foreach(fun({Result, Expected}) ->
            ok = quod_client_goal_router:test_send_result(Link, Request, Result),
            {ok, {result, <<8:128>>, Blob}} = quod_client_goal_endpoint:decode_response(target_frame(Link)),
            ?assertEqual({ok, Expected}, quod_client_result:decode(Blob))
        end, [{{pending, Ref}, {pending, Ref}},
              {{committed, [], Ref}, {committed, [], Ref}},
              {{answers, 7, [<<"not canonical">>]}, {error, proof_unavailable}},
              {{error, {material_limit, proof, answer_bytes, 10, 9}},
               {error, {material_limit, proof, answer_bytes, 10, 9}}}]),
        ok = quod_client_goal_router:test_send_response(Link, {error, <<8:128>>, invalid_signature}),
        ?assertEqual({ok, {error, <<8:128>>, invalid_signature},
                     quod_client_goal_endpoint:decode_response(target_frame(Link)))
    after Link ! stop end.

late_overflow_reply_cannot_restore_cancelled_correlation_test() ->
    with_router(fun(Router, Link, Fixture) ->
        Caller = submit_async(Router, Fixture, none, 1000),
        {Request, _} = sent_request(Link),
        Monitor = monitor(process, Caller), exit(Caller, kill),
        receive {'DOWN', Monitor, process, Caller, killed} -> ok
        after 1000 -> error(caller_not_cancelled) end,
        await_stats(Router, #{correlations => 0, routes => 0}),
        {ok, Payload} = quod_wire_term:encode_bindings(
            #{<<"X">> => binary:copy(<<$x>>, ?QUOD_TRANSPORT_MAX_FRAME_BYTES)}, unlimited),
        ok = quod_client_goal_router:test_send_result(Link, Request, {answers, 7, [Payload]}),
        Router ! {quod_message, {?PEER, Link}, quod_client_goal_endpoint:channel(), target_frame(Link)},
        ?assertMatch(#{correlations := 0, routes := 0}, quod_client_goal_router:test_stats(Router))
    end).

target_frame(Link) ->
    receive {link_frame, Link, Frame} -> Frame
    after 1000 -> error(target_response_missing) end.
'''
edit('presentation-reply-tests', 'test/quod_client_goal_router_tests.erl',
     lambda s: s.replace('-include_lib("eunit/include/eunit.hrl").', '-include_lib("eunit/include/eunit.hrl").\n-include("quod_transport_limits.hrl").') + router_tests)

def nested_tests(s):
    start = s.index('nested_goal_is_not_readmitted_against_signed_input_quota_test()')
    end = s.index('\ndenied_transcript_keeps_request', start)
    s = s[:start] + '''binary_heavy_nested_goal_uses_complete_plan_admission_test() ->
    Session = session([]),
    Value = binary:copy(<<$p>>,160000),
    Goal = {assertz,{large_value,Value}},
    try
        {_Id,{solution,_}} = first(Session,Goal),
        {ok,Plan} = quod_dtx:seal_session(Session,bind()),
        {ok,Bytes} = quod_dtx:encode(Plan),
        {ok,Decoded} = quod_dtx:decode(Bytes),
        {Entries,_} = quod_proof_session:transcript(Session),
        ?assertEqual(Entries,quod_ct:plan_material(transcript,Decoded)),
        [{_,_,Blob,allowed,1,_,active}] = Entries,
        ?assertEqual({ok,Goal},quod_wire_term:decode_canonical(Blob,?QUOD_MAX_PLAN_ENVELOPE_BYTES))
    after quod_proof_session:stop(Session) end.

binary_heavy_cancel_and_malformed_goal_preserve_transcript_lifecycle_test() ->
    Session = session([]), Id = <<3:128>>, BadId = <<4:128>>,
    Goal = {pad,binary:copy(<<$p>>,160000)},
    try
        ?assertEqual({error,{protocol_error,bad_payload}},open(Session,BadId,{pad,self()})),
        ?assertEqual({error,unknown_invocation},quod_proof_session:next(Session,BadId)),
        ?assertEqual({[],0},quod_proof_session:transcript(Session)),
        ok = open(Session,Id,Goal),
        ok = quod_proof_session:cancel(Session,Id),
        ?assertEqual({error,unknown_invocation},quod_proof_session:next(Session,Id)),
        ?assertMatch({[{Id,_,_,allowed,0,_,cancelled}],_},quod_proof_session:transcript(Session)),
        ?assertEqual([],quod_proof_session:local_changes(Session))
    after quod_proof_session:stop(Session) end.
''' + s[end:]
    return s.replace('RequestedGoal = {assertz, {must_not_run, true}},',
        'RequestedGoal = {assertz, {must_not_run, binary:copy(<<$d>>,160000)}},')
edit('nested-goal-tests', 'test/quod_dtx_tests.erl', nested_tests)
edit('nested-goal-tests', 'test/quod_proof_answer_tests.erl', lambda s: replace_once(s,
    '    Value = binary:copy(<<"a">>, 80000),', '    Value = binary:copy(<<"a">>, 160000),'))

scope_tests = '''
binary_heavy_nested_scope_preserves_authorization_and_cancellation_test() ->
    lists:foreach(fun(Allowed) ->
        Facts = case Allowed of true -> [{can_invoke,{'_'},{'_'},{'_'},{'_'}}]; false -> [] end,
        {Handle,MRef} = quod_scope_session:start(id(95),key(96),self(),
            <<"quod:large-nested">>,key(97),0,committed(Facts),self(),
            #{principal => {node,key(98)},request_binding => none,
              deadline_ms => quod_time:mono_ms()+5000}),
        {quod_scope_session,Worker,_,ProofId,SessionRef,_,_} = Handle,
        Invocation = id(99), Value = binary:copy(<<$v>>,160000),
        try
            {ok,Opened} = quod_scope_session:invoke_open(Handle,Invocation,{'=',Value,Value},
                [{<<"quod:origin">>,key(100)}],quod_transaction_scope:empty_selection()),
            ?assertEqual({opened,Invocation},receive_scope_reply(Worker,ProofId,SessionRef,Opened)),
            {ok,Next} = quod_scope_session:invoke_next(Handle,Invocation,1),
            Reply = receive_scope_reply(Worker,ProofId,SessionRef,Next),
            case Allowed of
                true -> ?assertMatch({solution,1,_,_,false},Reply);
                false -> ?assertMatch({complete,1,[{not_allowed,<<"quod:large-nested">>}|_],false},Reply)
            end
        after
            ok = quod_scope_session:close(Handle),
            receive {'DOWN',MRef,process,Worker,_} -> ok
            after 1000 -> error(large_scope_not_retired) end
        end
    end,[true,false]).
'''
edit('nested-goal-tests', 'test/quod_scope_session_tests.erl', lambda s: s + scope_tests)

def terrain_tests(s):
    start = s.index('content_batches_fit_')
    end = s.index('frame_size(Resource)', start)
    s = s[:start] + '''complete_content_and_manifest_keep_every_requested_row_test() ->
    Token = <<42:256>>,
    Chunks = [{I,binary:copy(<<I>>,N)} || {I,N} <- [{0,233488},{1,100000},{2,233488},{3,100000}]],
    Content = quod_terrain_wire:message({terrain_chunks,Token,Chunks,true}),
    ?assert(frame_size({terrain_chunks,Token,Chunks,true}) > 512*1024),
    ?assertEqual(Chunks,[{maps:get(index,R),base64:decode(maps:get(payload,R),
        #{mode => urlsafe,padding => false})} || R <- maps:get(chunks,Content)]),
    Rows = [row(I,<<>>) || I <- lists:seq(0,3999)],
    ?assert(frame_size({terrain_manifest,Token,1,Rows}) > 512*1024),
    ?assertEqual(4000,length(maps:get(chunks,quod_terrain_wire:message({terrain_manifest,Token,1,Rows})))),
    ?assertMatch(#{chunks := [],complete := true},quod_terrain_wire:message({terrain_chunks,Token,[],true})).

''' + s[end:]
    return s.replace('-include("quod_client_goal_limits.hrl").\n','')
edit('presentation-reply-tests', 'test/quod_terrain_wire_tests.erl', terrain_tests)

def physics_tests(s):
    s = s.replace('voxel_signed_view_batches_large_resident_selection_test_', 'voxel_signed_view_delivers_complete_large_resident_selection_test_')
    s = s.replace('?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES','(512*1024)')
    s = s.replace('        Batches = consume_large_terrain(Socket,Pid,View,Token,Rows,0),\n        ?assert(Batches > 1),',
                  '        consume_large_terrain(Socket,Pid,View,Token,Rows),')
    s = s.replace('with more content than a single view frame can encode.', 'with more content than the retired presentation subquota.')
    start = s.index('consume_large_terrain(Socket,Pid,View,Token,Rows,Count) ->')
    end = s.index('\nwith_voxel_view(', start)
    return s[:start] + '''consume_large_terrain(Socket,Pid,View,Token,Rows) ->
    Content = terrain_reply(Socket,View,<<"terrain_chunks">>),
    ?assert(iolist_size(json:encode(Content)) > 512*1024),
    ?assertEqual(Token,maps:get(<<"token">>,Content)),
    Chunks = maps:get(<<"chunks">>,Content),
    ?assertEqual(length(Rows),length(Chunks)),
    lists:foreach(fun({Row,Chunk}) ->
        ?assertEqual(maps:get(<<"index">>,Row),maps:get(<<"index">>,Chunk)),
        Bytes = base64:decode(maps:get(<<"payload">>,Chunk),#{mode => urlsafe,padding => false}),
        ?assertEqual(hd(maps:get(<<"costs">>,Row)),byte_size(Bytes)),
        ?assertEqual(maps:get(<<"digest">>,Row),binary:encode_hex(crypto:hash(sha256,Bytes),lowercase))
    end,lists:zip(Rows,Chunks)),
    ?assertEqual(true,maps:get(<<"complete">>,Content)),
    %% A completion for a different retained snapshot cannot release credit.
    socket_command(Socket,#{type => terrain_ack,view => View,
        token => base64:encode(<<0:256>>,#{mode => urlsafe,padding => false}),complete => true}),
    _ = simulation_state(Socket),_ = gen_server:call(Pid,status),
    receive {simulation,Socket,_} -> error(stale_ack_released_delivery) after 0 -> ok end,
    socket_command(Socket,#{type => terrain_ack,view => View,token => Token,complete => true}).
''' + s[end:]
edit('presentation-reply-tests', 'test/quod_physics_tests.erl', physics_tests)

def browser_tests(s):
    start = s.index("test('content batches retain visible progress")
    end = s.index("test('a stale partial batch", start)
    s = s[:start] + '''test('complete requested content installs atomically and releases its exact token', async () => {
  const failures = []
  let current
  const { socket, stream, view } = await connection(value => { current = value }, failures)
  const token = Buffer.alloc(32, 12).toString('base64url')
  const encoded = Buffer.from(payload).toString('base64url')
  try {
    socket.receive({ type: 'terrain_manifest', view, token, interest_seq: '0', chunks: [row,
      { ...row, index: 1, chunk: ['1', '0', '0'], origin_mm: ['4000', '0', '0'] }] })
    assert.deepEqual((await socket.next()).want, [0, 1])
    assert.equal(current.terrainReady, false)
    socket.receive({ type: 'terrain_chunks', view, token, complete: true,
      chunks: [{ index: 0, payload: encoded }, { index: 1, payload: encoded }] })
    assert.deepEqual(await socket.next(), { type: 'terrain_ack', view, token, complete: true })
    assert.equal(current.terrain.size, 2)
    assert.equal(current.terrainReady, true)
    assert.deepEqual(failures, [])
  } finally { stream.close() }
})

''' + s[end:]
    s = s.replace("test('a stale partial batch releases only its own ending without installing content'", "test('a stale completed set releases only its own token without installing content'")
    s = s.replace("socket.receive({ type: 'terrain_chunks', view, token, complete: false,\n      chunks: [{ index: 0, payload: Buffer.from(payload).toString('base64url') }] })", "socket.receive({ type: 'terrain_chunks', view, token, complete: true,\n      chunks: [{ index: 0, payload: Buffer.from(payload).toString('base64url') },\n        { index: 1, payload: Buffer.from(payload).toString('base64url') }] })")
    s = s.replace('token, through: 0', 'token, complete: true')
    return s
edit('presentation-reply-tests', 'client/test/terrain-delivery.test.js', browser_tests)

optional_tests = '''
shared_binary_accounting_uses_existing_proof_installer_test() ->
    %% Aliases and slices are not summed by application code. The installer
    %% uses the same binary virtual-heap counters as max_heap_size.
    Binary = binary:copy(<<$b>>,2*1024*1024),
    put(shared_binary_fixture,[Binary,Binary,binary:part(Binary,1,1000)]),
    try
        with_session([],fun(_Session) ->
            ?assertMatch({max_heap_size,#{size := 0,include_shared_binaries := true}},
                         process_info(self(),max_heap_size)),
            {garbage_collection_info,Info} = process_info(self(),garbage_collection_info),
            Counters = maps:from_list(Info),
            ?assert(maps:get(bin_vheap_size,Counters)+maps:get(bin_old_vheap_size,Counters) > 0)
        end),
        Est = quod_ct:committed_kb([{material_limit_override,proof,heap_bytes,0}]),
        #est{db = #db{ref = Ref}} = Est,
        try
            ?assertException(throw,{quod_ask_error,{material_limit,proof,heap_bytes,_,0}},
                quod_proof_session:start(Est,#{proof_context => {origin,test}}))
        after quod_erlog_db_mvcc:delete(Ref) end
    after erase(shared_binary_fixture) end.

finite_shared_binary_budget_kills_at_gc_in_real_proof_worker_test() ->
    Parent = self(), Budget = 8*1024*1024,
    {Worker,Monitor} = spawn_monitor(fun() ->
        with_session([{material_limit_override,proof,heap_bytes,Budget}],fun(_Session) ->
            Parent ! {installed,self(),process_info(self(),max_heap_size)},
            receive allocate -> ok end,
            put(proof_binary_fixture,binary:copy(<<$x>>,Budget*2)),
            erlang:garbage_collect(),
            Parent ! {unexpected_survival,self()}
        end)
    end),
    receive {installed,Worker,{max_heap_size,#{include_shared_binaries := true}}} -> Worker ! allocate
    after 1000 -> error(proof_policy_not_installed) end,
    receive {'DOWN',Monitor,process,Worker,killed} -> ok
    after 5000 -> error(shared_binary_policy_not_enforced) end.

shared_parent_is_charged_by_initial_proof_admission_test() ->
    Parent = self(), Binary = binary:copy(<<$s>>,16*1024*1024),
    ParentBytes = byte_size(Binary), Slice = binary:part(Binary,1,1000),
    lists:foreach(fun(Value) ->
        {Worker,Monitor} = spawn_monitor(fun() ->
            put(shared_parent_fixture,[Value,Value]),
            #est{db = #db{ref = Ref}} = Est = quod_ct:committed_kb(
                [{material_limit_override,proof,heap_bytes,8*1024*1024}]),
            try
                try quod_proof_session:start(Est,#{proof_context => {origin,test}}) of
                    Session -> quod_proof_session:stop(Session),error(parent_bytes_not_charged)
                catch throw:{quod_ask_error,{material_limit,proof,heap_bytes,Actual,Limit}} ->
                    ?assert(Actual >= ParentBytes),?assertEqual(8*1024*1024,Limit),
                    Parent ! {parent_refused,self()}
                end
            after quod_erlog_db_mvcc:delete(Ref),erase(shared_parent_fixture) end
        end),
        receive {parent_refused,Worker} -> ok
        after 1000 -> error(parent_refusal_missing) end,
        receive {'DOWN',Monitor,process,Worker,normal} -> ok
        after 1000 -> error(parent_worker_not_retired) end
    end,[Binary,Slice]).
'''
edit('optional-shared-binary-tests', 'test/quod_material_admission_tests.erl', lambda s: s + optional_tests)

def terrain_doc(s):
    # Documentation is an unapplied proposal too, not a changed current contract.
    return replace_once(s, '''Terrain manifests and chunks share this same credit, with exact watch and
manifest tokens and exact acknowledged batch endings. Content batches fit the
existing encoded message limit; aggregate allocation remains Prolog policy.
Fresh frames alternate with resources on that credit, so a
long manifest cannot starve motion updates or vice versa. Completion gates
navigation commands; already verified chunks stay visible while loading.''',
'''Terrain manifests and chunks share this same credit, with exact watch and
manifest tokens. The viewer requests its missing indices; one content message
returns that complete set and the token's completion acknowledgement releases
credit. There is no separate presentation byte quota or prefix acknowledgement.
Authored resident resources, measured costs, interest fences and digest checks
still apply. Completion gates navigation commands; retained unchanged chunks
stay visible while the requested set is verified. Delivery and decoding of a
large admitted set can take time; this protocol promises no per-frame latency.''')
edit('presentation-docs', 'doc/physics-native.md', terrain_doc)
edit('optional-shared-binary-docs', 'doc/multiwrite-architecture.md', lambda s: replace_once(s,
    "checks its existing heap before installing the VM's hard kill limit.",
    "checks the VM's current heap-block and binary virtual-heap counters before\ninstalling the VM's hard kill limit with shared-binary accounting. The same\nshared binary can be charged in each referencing process; a slice can retain\nits whole parent. This is VM word accounting, not unique application bytes or\nRSS. Later enforcement occurs at GC and includes collection overhead, so this\ninitial snapshot is not a prediction of the next collection's peak. Bootstrap\n`unlimited` stays unlimited; finite overrides count a broader resource than\nheap-only accounting and require the owner's explicit policy choice."))
