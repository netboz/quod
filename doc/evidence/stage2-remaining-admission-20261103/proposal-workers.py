# Existing configurable owner; no new allocator, queue or default numeric budget.
n='src/quod_prolog.erl'
for key in ['max_proof_workers','max_scope_workers']:
 rep(n,key+' => 64',key+' => unlimited')
 rep(n,key+' = 64 :: pos_integer()',key+' = unlimited :: pos_integer() | unlimited')
rep(n,'MaxProofWorkers = positive_limit(','MaxProofWorkers = worker_allowance(')
rep(n,'MaxScopeWorkers = positive_limit(','MaxScopeWorkers = worker_allowance(')
rep(n,'positive_limit(_Name, Value) when', '''worker_allowance(_Name, unlimited) -> unlimited;
worker_allowance(Name, Value) -> positive_limit(Name, Value).

positive_limit(_Name, Value) when''')
s=get(n)
s=re.sub(r'map_size\((Waiting|Workers|GroupWaiters)\) < Max',r'(Max =:= unlimited orelse map_size(\1) < Max)',s)
s=re.sub(r'when map_size\(Workers\) >= Max',r'when Max =/= unlimited, map_size(Workers) >= Max',s)
put(n,s)
rep(n,'\nscope_capacity_available(Max, Active, Pending) ->','\nscope_capacity_available(unlimited, _Active, _Pending) -> true;\nscope_capacity_available(Max, Active, Pending) ->')
n='src/quod_app.erl'
for key in ['max_proof_workers','max_scope_workers']:rep(n,f'maps:get({key}, Content, 64)',f'maps:get({key}, Content, unlimited)')
n='src/quod_schema.erl'
for key in ['max_proof_workers','max_scope_workers']:
 rep(n,f'''{{{key},
       hoconsc:mk(integer(), #{{default => 64, validator => fun(N) -> N > 0 end}})}}''',f'''{{{key},
       hoconsc:mk(hoconsc:union([hoconsc:enum([unlimited]), integer()]),
                  #{{default => unlimited, validator => fun(N) -> N =:= unlimited orelse
                      (is_integer(N) andalso N > 0) end}})}}''')
n='test/quod_schema_tests.erl'
s=get(n);s=re.sub(r'\?assertEqual\(64,\s+maps:get\((max_proof_workers|max_scope_workers), (B|NsCfg)\)\)',r'?assertEqual(unlimited, maps:get(\1, \2))',s);put(n,s)
put(n,get(n)+'''
worker_allowances_keep_explicit_finite_configuration_test() ->
    Bin = <<"content=[{namespace=\\"quod:test\\", max_proof_workers=3, max_scope_workers=2}]">>,
    B = content1(check(Bin)),
    ?assertEqual(3, maps:get(max_proof_workers, B)),
    ?assertEqual(2, maps:get(max_scope_workers, B)),
    {_, Config} = quod_app:build_ns_config(B),
    ?assertEqual(3, maps:get(max_proof_workers, Config)),
    ?assertEqual(2, maps:get(max_scope_workers, Config)),
    ?assertEqual(unlimited, quod_prolog:worker_allowance(max_proof_workers, unlimited)),
    ?assertEqual(1, quod_prolog:worker_allowance(max_scope_workers, 1)),
    ?assertError({bad_config, {max_proof_workers, 0}},
                 quod_prolog:worker_allowance(max_proof_workers, 0)),
    ?assertError({bad_config, {proof_timeout_ms, unlimited}},
                 quod_prolog:positive_limit(proof_timeout_ms, unlimited)).
''')
n='test/quod_prolog_scope_target_tests.erl'
rep(n,'    ?assert(quod_prolog:test_scope_capacity_available(2, 1, 0)),','    ?assert(quod_prolog:test_scope_capacity_available(unlimited, 65, 65)),\n    ?assert(quod_prolog:test_scope_capacity_available(2, 1, 0)),')
n='test/quod_prolog_tests.erl'
put(n,get(n)+'''
default_proof_owner_retains_65_live_workers_and_releases_capacity_test_() ->
    {timeout, 60, fun() -> with_native_barrier(fun(Ns) ->
        Parent = self(),
        Rows = [begin
            Tag = make_ref(),
            Caller = spawn(fun() -> Parent ! {Tag, quod_prolog:execute(Ns, test_local_wait)} end),
            {Caller, native_waiting(), Tag}
        end || _ <- lists:seq(1, 65)],
        try
            ?assertEqual(65, maps:get(proof_workers, quod_prolog:stats(Ns))),
            lists:foreach(fun({_Caller, Worker, _Tag}) -> Worker ! release end, Rows),
            lists:foreach(fun({_Caller, _Worker, Tag}) ->
                receive {Tag, Result} -> ?assertMatch({ok, _, _}, Result)
                after 5000 -> error(worker_release_did_not_complete) end
            end, Rows),
            %% Replies pass through finish_proof at the engine. A subsequent
            %% stats call observes processed completion, without polling/sleep.
            ?assertEqual(0, maps:get(proof_workers, quod_prolog:stats(Ns))),
            ?assertMatch({ok, _, _}, quod_prolog:execute(Ns, true))
        after
            lists:foreach(fun({Caller, Worker, _}) -> Worker ! release, exit(Caller, kill) end, Rows)
        end
    end) end}.
''')
n='doc/multiwrite-architecture.md'
put(n,get(n)+'''

Proof and scope worker admission uses the existing ontology-engine owner and
configured allowances. The built-in population default is unlimited; explicit
positive finite settings still govern active/pending scopes, derivation workers
and retained completion waiters. Capacity release, exact operation deduplication,
worker monitors and original deadlines are unchanged. This is not an aggregate
memory reservation or a new proof-resource policy.
''')
