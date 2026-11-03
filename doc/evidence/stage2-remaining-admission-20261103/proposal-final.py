exec(compile((__import__('pathlib').Path(__file__).parent/'proposal-diagnostics.py').read_text(),'proposal-diagnostics.py','exec'))
# No disk allocation from a corrupt advertised length beyond the file's real extent.
n='src/quod_ledger_store.erl'
rep(n,'''fill(Fd, Off, Buf, Need) ->
    case file:pread(Fd, Off + byte_size(Buf), max(?READ_CHUNK, Need - byte_size(Buf))) of''','''fill(Fd, Off, Buf, Need) ->
    case file:position(Fd, eof) of
        {ok, End} ->
            At = Off + byte_size(Buf),
            Available = max(0, End - At),
            Read = min(Available, max(?READ_CHUNK, Need - byte_size(Buf))),
            fill_available(Fd, At, Buf, Need, Read);
        {error, Reason} -> {io_error, Reason}
    end.

fill_available(_Fd, _At, Buf, _Need, 0) -> {short, Buf};
fill_available(Fd, At, Buf, Need, Read) ->
    case file:pread(Fd, At, Read) of''')
rep(n,'%% Grow `Buf` (the bytes at `Off`) to at least `Need` bytes with one ?READ_CHUNK-or-bigger\n%% pread. `{short, Buf\'}\' = the file ends before `Need` bytes (pread returns short only at EOF).','') if False else None
rep(n,"%% Grow `Buf` (the bytes at `Off`) to at least `Need` bytes with one ?READ_CHUNK-or-bigger\n%% pread. `{short, Buf'}` = the file ends before `Need` bytes (pread returns short only at EOF).", "%% Read from the actual file extent, never allocate an advertised missing tail.\n%% Existing chunked reads preserve the cursor; a short frame remains a short frame.")
# Remove now-unused arguments/comments introduced by count retirement.
n='src/quod_foreign_log.erl'
rep(n,'Root, FetchFun, PageTimeout, Cursor = #verified_cursor{height = Height}) ->','Root, FetchFun, PageTimeout, Cursor = #verified_cursor{}) ->')
n='include/quod_proof_limits.hrl'
rep(n,'%% follow needs them. Exact monitors, deadlines and byte bounds own live work;','%% follow needs them. Exact monitors and deadlines own live work;')
# Existing diagnostics creator still receives only portable terms; malformed is not overflow.
n='src/quod_dtx.erl'
# Source specifications at callers remain reviewed separately; no status/outcome conversion.
emit()
# Split dependency changes out of runtime patch; never provide a patch targeting build cache for application.
p=E/'proposals';m=json.loads((p/'manifest.json').read_text());repo=[];dep=[]
for n in m['files']:
 diff=list(difflib.unified_diff(B[n].splitlines(True),D[n].splitlines(True),fromfile='a/'+n,tofile='b/'+n))
 if n.startswith('_build/default/lib/erlog/'):
  diff=[x.replace('_build/default/lib/erlog/','') if x.startswith(('---','+++')) else x for x in diff];dep.extend(diff)
 else:repo.extend(diff)
(p/'remaining-owners.patch').write_text(''.join(repo));(p/'erlog-diagnostics.patch').write_text(''.join(dep))
m['dependency']={'pin':'535395c60b2133703308bbe529a63309672cb7a0','patch':'erlog-diagnostics.patch','installed':False,'pin_changed':False,'requires_reviewed_dependency_revision':True}
m['production_applied_delta']={'added':0,'removed':0}
(p/'manifest.json').write_text(json.dumps(m,indent=2)+'\n')
