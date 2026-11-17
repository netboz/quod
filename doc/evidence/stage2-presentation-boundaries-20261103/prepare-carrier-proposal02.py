"""Build review artifacts only; never write proposed bytes into production."""
from pathlib import Path
import re,difflib,hashlib,json
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
out=e/'proposals-carrier02';out.mkdir(exist_ok=False)
changes={}
def edit(name,fn):
 p=r/name;a=p.read_text();b=fn(a)
 if a==b:raise RuntimeError('no change '+name)
 changes[name]=(a,b)

def scope(s):
 s=re.sub(r'-if\(\?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES.*?-endif\.\n','',s,flags=re.S)
 s=s.replace('?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES','?QUOD_LINK_PAYLOAD_CAPACITY')
 a=s.index('payload_limit(goal)');b=s.index('payload_limit(_) -> error.',a)
 s=s[:a]+'''%% Complete envelopes own actual framing capacity. Material allocation is
%% checked by the proof's pinned Prolog policy, not a second payload quota.
payload_limit(failure_reasons) -> {ok, ?ERLOG_MAX_FAILURE_REASONS_BYTES};
payload_limit(erlog_error) -> {ok, ?ERLOG_MAX_FAILURE_REASON_BYTES};
payload_limit(Kind) when Kind =:= goal; Kind =:= answer; Kind =:= plan;
                         Kind =:= manifest; Kind =:= attestation;
                         Kind =:= read_certificate; Kind =:= foreign_reads;
                         Kind =:= result; Kind =:= operation_submission -> {ok, unlimited};
'''+s[b:]
 s=s.replace('when byte_size(Encoded) =< MaxBytes','when MaxBytes =:= unlimited; byte_size(Encoded) =< MaxBytes')
 return s
edit('src/quod_scope_wire.erl',scope)
def journal(s):
 a=s.index('%% Exact deterministic-ETF overhead');b=s.index('\n-type block_hash',a)
 s=s[:a]+'''%% The journal frame has an unsigned 32-bit payload length.
-define(FRAME_PAYLOAD_CAPACITY, ((1 bsl 32) - 1)).
'''+s[b:]
 s=s.replace('?MAX_FRAME_PAYLOAD_BYTES','?FRAME_PAYLOAD_CAPACITY')
 s=re.sub(r', byte_size\((Body|Envelope)\) =< (?:\(\?MAX_BLOCK_BYTES \+ 1024\)|\?MAX_BLOCK_BYTES)','',s)
 # The reader already decoded an unsigned32 length; it cannot exceed that width.
 s=s.replace(')\n  when Len =< ?FRAME_PAYLOAD_CAPACITY ->',') ->')
 s=s.replace('read_current_frame(_Fd, Offset, _Mode,\n                   <<?MAGIC:32, Len:32, _CRC:32>>) ->\n    error({signing_journal_corruption, {frame_too_big, Len}, Offset});\n','')
 return s
edit('src/quod_signing_journal.erl',journal)
def phase(s):
 a=s.index('%% A history stores at most');b=s.index('\n-record(index',a);s=s[:a]+s[b:]
 s=s.replace('''    case HistoryBytes =< ?MAX_HISTORY_BYTES of
        true ->
            {ok, Delta#delta{rows = Rows#{GroupId => {History, HistoryBytes}},
                             bytes = NewBytes}};
        false ->
            {error, bad_phase_index_delta}
    end.''','''    {ok, Delta#delta{rows = Rows#{GroupId => {History, HistoryBytes}},
                     bytes = NewBytes}}.''')
 s=s.replace('Bytes =:= StoredBytes andalso Bytes =< ?MAX_HISTORY_BYTES','Bytes =:= StoredBytes')
 s=re.sub(r',\s*byte_size\(Blob\) =< \?MAX_HISTORY_BYTES','',s).replace('?MAX_HISTORY_BYTES','unlimited')
 return s
edit('src/quod_dtx_phase_index.erl',phase)
edit('src/predicates/quod_ask.erl',lambda s:s.replace('?QUOD_MAX_PLAN_ENVELOPE_BYTES','unlimited'))
manifest=[];patch=[]
for name,(a,b) in sorted(changes.items()):
 for label,text in [('before',a),('after',b)]:
  p=out/label/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
 d=list(difflib.unified_diff(a.splitlines(True),b.splitlines(True),fromfile='a/'+name,tofile='b/'+name));patch.extend(d)
 manifest.append(dict(path=name,before_sha256=hashlib.sha256(a.encode()).hexdigest(),proposed_sha256=hashlib.sha256(b.encode()).hexdigest(),added=sum(l.startswith('+') and not l.startswith('+++') for l in d),removed=sum(l.startswith('-') and not l.startswith('---') for l in d)))
(out/'carrier-custody.patch').write_text(''.join(patch))
(out/'manifest.json').write_text(json.dumps(dict(applied=False,compiled=False,executed=False,source_label='applied-admission-partial01',paths=manifest,delta=dict(added=sum(x['added'] for x in manifest),removed=sum(x['removed'] for x in manifest))),indent=2)+'\n')
print(json.dumps(manifest,indent=2))
