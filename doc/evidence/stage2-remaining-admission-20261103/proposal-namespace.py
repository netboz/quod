exec(compile((__import__('pathlib').Path(__file__).parent/'proposal-tests-final.py').read_text(),'proposal-tests-final.py','exec'))
base=D.copy()
for n in ['src/quod_agent_ref.erl','src/quod_client_http.erl','src/quod_client_result.erl','src/quod_foreign_log.erl']:
 s=get(n)
 s=re.sub(r',\s*byte_size\((Ns|Namespace)\) =< \?DIRECTORY_MAX_NAMESPACE_BYTES','',s)
 put(n,s)
for n in ['src/quod_directory_shape.erl','src/quod_scope_wire.erl']:
 rep(n,'is_binary(Namespace) andalso byte_size(Namespace) > 0 andalso\n        byte_size(Namespace) =< ?DIRECTORY_MAX_NAMESPACE_BYTES.','is_binary(Namespace) andalso byte_size(Namespace) > 0.')
rep('include/quod_directory_limits.hrl','-define(DIRECTORY_MAX_NAMESPACE_BYTES, 255).\n','')
n='src/quod_client_goal.erl'
rep(n,'?DIRECTORY_MAX_NAMESPACE_BYTES','((1 bsl 16) - 1)')
n='src/quod_ontology.erl'
rep(n,'-define(MAX_NAMESPACE_BYTES, 128).\n','')
rep(n,'validate_name(Ns) when byte_size(Ns) > ?MAX_NAMESPACE_BYTES ->\n    {error, invalid_name};\n','')
n='client/src/protocol-limits.js'
cut(n,'const MAX_NAMESPACE_BYTES','const encoder =', '''// The signed request namespace field is an unsigned16-bit byte length.
export const SIGNED_GOAL_LIMITS = Object.freeze({ namespaceBytes: 2 ** 16 - 1 })

''')
n='client/godot/Core/Identity.cs'
rep(n,'// Exact identity widths and retained directory policy; length writes below are checked.','// Exact identity widths; the signed length writes below are checked.')
rep(n,'ns.Length is < 1 or > 255','ns.Length < 1')
# Deterministic filesystem key; '.' makes the new key disjoint from old base64url.
# Exact namespace/genesis remain the authenticated identities, never this path.
n='src/quod_ledger_store.erl'
rep(n,'data_dir/1, ns_dir/2','data_dir/1, ns_dir/2, namespace_key/1, check_namespace_layout/2, preflight_namespace/2')
rep(n,'ns_dir(DataDir, Ns) -> filename:join(DataDir, base64url(Ns)).', '''ns_dir(DataDir, Ns) -> filename:join(DataDir, binary_to_list(namespace_key(Ns))).

-spec namespace_key(binary()) -> binary().
namespace_key(Ns) when is_binary(Ns) ->
    <<"ns.", (binary:encode_hex(crypto:hash(sha256, Ns)))/binary>>.

%% Read-only preflight before opening any store or reporting a stopped outcome
%% absent. Never operate two layouts or silently replace retained signing duties.
-spec check_namespace_layout(file:filename_all(), binary()) -> ok | {error, term()}.
check_namespace_layout(Root, Ns) ->
    Legacy = filename:join(Root, base64url(Ns)),
    case file:read_link_info(Legacy) of
        {ok, _} -> {error, {unsupported_namespace_layout, Legacy}};
        {error, enoent} -> ok;
        %% This filesystem cannot represent the old raw-name component. No
        %% arbitrary byte allowance or directory-wide scan is substituted.
        {error, enametoolong} -> ok;
        {error, Reason} -> {error, {namespace_layout_io, Root, Reason}}
    end.

%% Both roots must pass before ledger creation, even when the only retained
%% old-format material is the signing journal on the separate durable volume.
-spec preflight_namespace(binary(), map()) -> ok | {error, term()}.
preflight_namespace(Ns, Config) ->
    lists:foldl(fun(Root, ok) -> check_namespace_layout(Root, Ns);
                  (_, Error) -> Error end,
                ok, lists:usort([ledger_dir(Config), data_dir(Config)])).
''')
# All mutable/open store owners check once at lifecycle entry; path derivation
# itself remains pure, so ordinary retained consumers do not rescan roots.
rep(n,'    Dir = ns_dir(DataDir, Ns),','    ok = require_namespace_layout(DataDir, Ns),\n    Dir = ns_dir(DataDir, Ns),')
rep(n,'-spec namespace_key(binary())', '''require_namespace_layout(Root, Ns) ->
    case check_namespace_layout(Root, Ns) of
        ok -> ok;
        {error, Reason} -> error(Reason)
    end.

-spec namespace_key(binary())''')
for n,root in [('src/quod_signing_journal.erl','DataDir'),('src/quod_outcome.erl','DataDir'),('src/quod_dtx_phase_index.erl','LedgerDir')]:
 rep(n,f'    Dir = quod_ledger_store:ns_dir({root}, Ns),', f'    ok = quod_ledger_store:check_namespace_layout({root}, Ns),\n    Dir = quod_ledger_store:ns_dir({root}, Ns),')
n='src/quod_outcome.erl'
rep(n,'''    Path = filename:join(quod_ledger_store:ns_dir(LedgerDir, Ns),
                         "outcomes.dets"),
    case dets:info(Path) of
        undefined -> lookup_closed(Path, Ns, TxId);
        _ -> lookup_table(Path, Ns, TxId)
    end;''','''    case quod_ledger_store:check_namespace_layout(LedgerDir, Ns) of
        ok ->
            Path = filename:join(quod_ledger_store:ns_dir(LedgerDir, Ns), "outcomes.dets"),
            case dets:info(Path) of
                undefined -> lookup_closed(Path, Ns, TxId);
                _ -> lookup_table(Path, Ns, TxId)
            end;
        {error, _} = Error -> Error
    end;''')
n='src/quod_simplex.erl'
rep(n,'    {ok, Store} = quod_ledger_store:open(Ns, quod_ledger_store:ledger_dir(Cfg)),','    ok = quod_ledger_store:preflight_namespace(Ns, Cfg),\n    {ok, Store} = quod_ledger_store:open(Ns, quod_ledger_store:ledger_dir(Cfg)),')
rep(n,'genesis_table_name(Ns) -> <<"quod_simplex_genesis_", Ns/binary>>.','genesis_table_name(Ns) -> <<"quod_simplex_genesis_", (quod_ledger_store:namespace_key(Ns))/binary>>.')
n='src/quod_feed.erl'
rep(n,'digest_table_name(Ns) -> <<"quod_feed_digests_", Ns/binary>>.','digest_table_name(Ns) -> <<"quod_feed_digests_", (quod_ledger_store:namespace_key(Ns))/binary>>.')
n='src/quod_foreign_log.erl'
rep(n,'            cleanup_projection_dirs(Root),','            Histories = retained_histories(Root),\n            cleanup_projection_dirs(Root),')
rep(n,'initialize_retained_histories(S0)}','initialize_retained_histories(Histories, S0)}')
cut(n,'initialize_retained_histories(S0 = #s{root = Root}) ->','start_history_initialization(Identity, Cause, S0) ->', '''%% Inspect every retained manifest before any projection cleanup or reader
%% start. A later legacy directory must not be discovered after earlier writes.
retained_histories(Root) ->
    case file:list_dir(Root) of
        {ok, Names} ->
            lists:flatmap(fun(Name) ->
                case load_history_dir(Root, filename:join(Root, Name)) of
                    {ok, H} -> [H];
                    error -> []
                end
            end, Names);
        {error, enoent} -> [];
        {error, Reason} -> error({foreign_history_catalogue, Reason})
    end.

initialize_retained_histories(Histories, S0) ->
    lists:foldl(fun(H = #history{identity = Identity, bytes = Bytes}, S) ->
        S1 = put_history(Identity, H, S#s{total_bytes = S#s.total_bytes + Bytes}),
        start_history_initialization(Identity, startup, S1)
    end, S0, Histories).

''')
rep(n,'            Identity = {Ns, Anchor},\n            Bytes = cache_persisted_bytes(Root, CacheNs),','''            Identity = {Ns, Anchor},
            ok = quod_ledger_store:check_namespace_layout(Root, CacheNs),
            Bytes = cache_persisted_bytes(Root, CacheNs),''')
# Actual producers also preflight the cached archive before writing its manifest.
# ns_dir call under projections is a disposable generation root; normal phase/store
# opens above still apply the shared check.
# New tests never touch user stores. Execution awaits separate approval.
new('test/quod_namespace_layout_tests.erl','''-module(quod_namespace_layout_tests).
-include_lib("eunit/include/eunit.hrl").

long_namespace_has_one_exact_representable_key_test() ->
    Ns = binary:copy(<<"n">>, 1024),
    Key = quod_ledger_store:namespace_key(Ns),
    ?assertEqual(<<"ns.", (binary:encode_hex(crypto:hash(sha256, Ns)))/binary>>, Key),
    ?assertNotEqual(Key, quod_ledger_store:namespace_key(<<Ns/binary, "x">>)),
    ?assertEqual(Key, quod_ledger_store:namespace_key(Ns)),
    ?assert(byte_size(quod_simplex:genesis_table_name(Ns)) < 255),
    ?assert(byte_size(quod_feed:digest_table_name(Ns)) < 255).

old_journal_in_other_root_refuses_before_ledger_creation_test() ->
    temporary(fun(Root) ->
        Ns = <<"preserved:namespace">>,
        Ledger = filename:join(Root, "ledger"), Data = filename:join(Root, "data"),
        Old = legacy(Data, Ns), Marker = filename:join(Old, "signing.journal"),
        ok = filelib:ensure_dir(Marker), ok = file:write_file(Marker, <<"preserved">>),
        Config = #{ledger_dir => Ledger, data_dir => Data},
        Error = {error, {unsupported_namespace_layout, Old}},
        ?assertEqual(Error, quod_ledger_store:preflight_namespace(Ns, Config)),
        ?assertError({badmatch, Error}, quod_simplex:test_restore_storage(Ns, Config, <<1:256>>)),
        ?assertNot(filelib:is_dir(Ledger)),
        ?assertEqual({ok, <<"preserved">>}, file:read_file(Marker)),
        ?assertEqual(Error, quod_outcome:lookup_live(Ns, Data, <<1:256>>)),
        ?assertError({badmatch, Error}, quod_signing_journal:initialize(Ns, <<2:256>>, Data)),
        ?assertError({badmatch, Error}, quod_signing_journal:recover(Ns, <<2:256>>, Data)),
        ?assertError({badmatch, Error}, quod_dtx_phase_index:open(Data, Ns)),
        ?assertError({badmatch, Error}, quod_outcome:open(Ns, <<2:256>>, #{data_dir => Data})),
        ?assertNot(filelib:is_dir(quod_ledger_store:ns_dir(Data, Ns)))
    end).

old_archive_refuses_even_when_new_layout_exists_test() ->
    temporary(fun(Root) ->
        Ns = <<"preserved:archive">>, Old = legacy(Root, Ns),
        ok = filelib:ensure_dir(filename:join(Old, "log.0001")),
        New = quod_ledger_store:ns_dir(Root, Ns),
        ok = filelib:ensure_path(New),
        ?assertError({unsupported_namespace_layout, Old}, quod_ledger_store:open_ro(Ns, Root)),
        ?assertError({unsupported_namespace_layout, Old}, quod_ledger_store:open(Ns, Root)),
        ?assertEqual({ok, []}, file:list_dir(New))
    end).

long_namespace_reopens_same_store_without_alias_test() ->
    temporary(fun(Root) ->
        Ns = binary:copy(<<"x">>, 1024),
        {ok, Store} = quod_ledger_store:open(Ns, Root),
        ?assertEqual(Ns, quod_ledger_store:namespace(Store)),
        ok = quod_ledger_store:close(Store),
        {ok, Reader} = quod_ledger_store:open_ro(Ns, Root),
        ?assertEqual(Ns, quod_ledger_store:namespace(Reader)),
        ok = quod_ledger_store:close(Reader),
        ?assertEqual({error, no_log}, quod_ledger_store:open_ro(<<Ns/binary, "x">>, Root))
    end).

legacy(Root, Ns) -> filename:join(Root, binary_to_list(base64:encode(Ns, #{mode => urlsafe, padding => false}))).
temporary(Fun) ->
    Root = filename:join("/tmp", "quod_namespace_layout_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16)))) ,
    try Fun(Root) after file:del_dir_r(Root) end.
''')
exec(compile((E/'proposal-namespace-tests.py').read_text(),'proposal-namespace-tests.py','exec'))
# Emit a separate, conditional format patch against the remaining-owner overlay.
patch=[];rows={}
for n,s in sorted(D.items()):
 old=base.get(n,B[n])
 if s==old:continue
 dest=E/'namespace-after'/n;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(s)
 diff=list(difflib.unified_diff(old.splitlines(True),s.splitlines(True),fromfile='a/'+n if old else '/dev/null',tofile='b/'+n));patch.extend(diff)
 rows[n]={'before':hashlib.sha256(old.encode()).hexdigest(),'after':hashlib.sha256(s.encode()).hexdigest(),'added':sum(x.startswith('+') and not x.startswith('+++') for x in diff),'removed':sum(x.startswith('-') and not x.startswith('---') for x in diff)}
(E/'proposals/namespace-admission-CONDITIONAL.patch').write_text(''.join(patch))
(E/'proposals/namespace-manifest.json').write_text(json.dumps({'applied':False,'runtime_verified':False,'requires':'Format-code approval and separately authorized preservation/cutover; no migration is executed','base':'remaining-owners.patch','files':rows},indent=2)+'\n')
