# Run within namespace generator, with the current proposed dictionaries.
n='src/quod_foreign_log.erl'
rep(n,'ensure_manifest(Owner, RequestRef, Root, {Ns, Anchor}, CacheNs) ->\n    Path', 'ensure_manifest(Owner, RequestRef, Root, {Ns, Anchor}, CacheNs) ->\n    ok = quod_ledger_store:check_namespace_layout(Root, CacheNs),\n    Path')
n='src/quod_outcome.erl'
rep(n,'''-spec lookup_live(binary(), file:filename_all(), binary()) ->
          {ok, map()} | {error, not_found | ontology_unreachable |
                                outcome_index_corrupt}.''','''-spec lookup_live(binary(), file:filename_all(), binary()) ->
          {ok, map()} | {error, not_found | ontology_unreachable | outcome_index_corrupt |
                                {unsupported_namespace_layout, file:filename_all()} |
                                {namespace_layout_io, file:filename_all(), term()}}.''')
# Exercise accepted long data; only the signed-goal request has a uint16 field.
for f in (R/'test').glob('*.erl'):
 n=str(f.relative_to(R));s=D.get(n,f.read_text())
 if '?DIRECTORY_MAX_NAMESPACE_BYTES' not in s:continue
 s=s.replace('?DIRECTORY_MAX_NAMESPACE_BYTES','((1 bsl 16) - 1)' if n=='test/quod_client_goal_tests.erl' else '1024')
 put(n,s)
n='test/quod_client_result_tests.erl'
rep(n,'               [{binary:copy(<<"n">>,1024+1),<<1:256>>,0}],\n','')
rep(n,'    BadDeps = [','    ?assertMatch({ok, _}, quod_client_result:encode({read, [{binary:copy(<<"n">>,1025),<<1:256>>,0}], fail})),\n    BadDeps = [')
n='client/test/agent-references.test.js'
rep(n,"test('agent-reference namespaces use the shared 255-byte protocol limit'", "test('agent-reference namespaces preserve UTF-8 through the signed length field'")
rep(n,"const namespace255 = `${'é'.repeat(127)}a`","const namespace255 = `${'é'.repeat(32767)}a`")
rep(n,'encode(namespace255).length, 255','encode(namespace255).length, 65535')
n='test/quod_namespace_layout_tests.erl'
put(n,get(n)+'''
old_foreign_manifest_refuses_before_projection_cleanup_test() ->
    temporary(fun(Root) ->
        Ns = <<"foreign:preserved">>, Anchor = <<7:256>>, Identity = {Ns, Anchor},
        CacheNs = quod_foreign_log:cache_namespace(Identity),
        Old = legacy(Root, CacheNs),
        %% The original valid manifest version is taken from the production owner.
        Manifest = {quod_foreign_log_cache, 7, Ns, Anchor, CacheNs},
        Path = filename:join(Old, "identity.term"),
        ok = filelib:ensure_dir(Path),
        Blob = term_to_binary(Manifest, [deterministic]), ok = file:write_file(Path, Blob),
        ProjectionMarker = filename:join([Root, "projections", "retained", "marker"]),
        ok = filelib:ensure_dir(ProjectionMarker), ok = file:write_file(ProjectionMarker, <<"preserved">>),
        ?assertError({badmatch, {error, {unsupported_namespace_layout, Old}}},
                     quod_foreign_log:init(#{cache_dir => Root})),
        ?assertEqual({ok, Blob}, file:read_file(Path)),
        ?assertEqual({ok, <<"preserved">>}, file:read_file(ProjectionMarker)),
        ?assertNot(filelib:is_dir(quod_ledger_store:ns_dir(Root, CacheNs)))
    end).
''')
n='client/godot-tests/AdmissionCodecChecks.cs'
rep(n,'        try {Term.Parse(text+" trailing")', '''        foreach(int size in new[]{256,1024,ushort.MaxValue}) {
            var exact=actor with { Namespace=new string('n',size) };
            byte[] request=Wire.Encode(new byte[32],key.PublicKey,new byte[32],exact,0,1800000000000,"true.");
            int offset=Encoding.UTF8.GetByteCount("quod.agent.goal.v1\\0")+96;
            Check(BinaryPrimitives.ReadUInt16BigEndian(request.AsSpan(offset))==size &&
                Encoding.UTF8.GetString(request,offset+2,size)==exact.Namespace &&
                Identity.Verify(key.PublicKey,request,key.Sign(request)),"long namespace keeps exact signed UTF8 bytes");
        }
        try {Wire.Encode(new byte[32],key.PublicKey,new byte[32],actor with { Namespace=new string('n',ushort.MaxValue+1) },0,1800000000000,"true.");throw new Exception("Accepted unrepresentable namespace");}
        catch(OverflowException) {Console.WriteLine("PASS uint16 representation overflow refuses");}
        try {Term.Parse(text+" trailing")''')

n='doc/multiwrite-architecture.md'
put(n,get(n)+'''

## Namespace storage representation

Namespace/genesis pairs remain exact authenticated identities. Shared store
paths and the existing feed/genesis ETS names use the deterministic namespace
key `ns.` followed by SHA256 hex. That key is a representation, never authority.
The dot keeps the layout disjoint from the prior raw-base64url component.

Store lifecycle entry and stopped-outcome reads refuse an existing prior-layout
path explicitly. Simplex preflights both configured ledger and signing roots
before creating either store. Foreign-cache startup inspects all manifests
before projection cleanup or writer launch, so a retained legacy cache cannot
be silently skipped. Preflight performs exact path metadata reads; ordinary
retained readers continue using their existing handles.

This is a storage format break. A deployment requires a separately approved
preservation/cutover procedure covering both roots, signing journals, ledger
archives, outcome indexes, phase indexes and foreign cache manifests. There is
no runtime fallback, automatic migration, deletion or replacement founding.
The raw signed namespace and encoded link channel retain their distinct uint16
length representations; neither may wrap or truncate a namespace.
''')
# Fixtures must use the actual existing ETS-name owner after its representation changes.
for f in (R/'test').glob('*.erl'):
 n=str(f.relative_to(R));s=D.get(n,f.read_text());old=s
 s=re.sub(r'<<"quod_simplex_genesis_",\s*([A-Za-z][A-Za-z0-9_]*)/binary>>',r'quod_simplex:genesis_table_name(\1)',s)
 s=re.sub(r"'quod_simplex_genesis_([^']+)'",lambda m:'binary_to_atom(quod_simplex:genesis_table_name(<<"'+m.group(1)+'">>), utf8)',s)
 if s!=old:put(n,s)
