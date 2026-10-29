import pathlib,json,os,hashlib,subprocess,tarfile,tempfile,stat,time,traceback
ROOT=pathlib.Path('/home/yan/src/quod_worktrees/pearl-stone');S=pathlib.Path('/home/yan/.cache/quod-m3b-artifacts/quod-godot-m3b-handoff-8b352c53-20261029-02');E=ROOT/'doc/evidence/godot-m3b-20261029';OUT=ROOT/'_build/godot-m3b-coordinator-verification-20261029';R={};CACHE={}
def sha(p):
 st=p.stat();key=(st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns)
 if key not in CACHE:
  with p.open('rb') as f:CACHE[key]=hashlib.file_digest(f,'sha256').hexdigest()
 return CACHE[key]
def git(*args,cwd=ROOT):return subprocess.check_output(['git',*args],cwd=cwd)
def norm(s):
 while s.startswith('./'):s=s[2:]
 s=s.rstrip('/') or '.';assert not s.startswith('/') and '..' not in pathlib.PurePosixPath(s).parts,s
 return s
def filesystem(root,manifest,label):
 names=set()
 for base,dirs,files in os.walk(root,followlinks=False):
  for n in dirs+files:
   p=pathlib.Path(base)/n
   if p.is_symlink() or not p.is_dir():names.add(p.relative_to(root).as_posix())
 if label=='live':names=set(filter(None,git('ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0')))
 assert names==set(manifest),(label,'path-set',len(names),len(manifest))
 for n,row in manifest.items():
  p=root/n;s=p.lstat();assert stat.S_IMODE(s.st_mode)==row['mode'],(label,'mode',n)
  if row['kind']=='symlink':assert p.is_symlink() and str(p.readlink())==row['target'],(label,n)
  else:assert stat.S_ISREG(s.st_mode) and s.st_size==row['bytes'] and sha(p)==row['sha256'],(label,n)
 R[label+'_source_entries']=len(names);print(label,'source exact',len(names),flush=True)
def stream(path,include_dirs=False,materialize=None,changed=None):
 rows={}
 with tarfile.open(path,'r|*') as tar:
  for m in tar:
   n=norm(m.name)
   if m.isdir():
    if include_dirs:assert n not in rows;rows[n]={'directory':True,'mode':m.mode}
    continue
   assert n not in rows,('duplicate archive entry',path.name,n)
   if m.issym():row={'symlink':m.linkname,'mode':m.mode}
   elif m.islnk():row={'hardlink':norm(m.linkname),'mode':m.mode}
   else:
    assert m.isfile(),('unsupported archive type',path.name,n)
    f=tar.extractfile(m);h=hashlib.sha256();dst=None
    if materialize and n in changed:
     p=materialize/n;p.parent.mkdir(parents=True,exist_ok=True);dst=p.open('wb')
    for chunk in iter(lambda:f.read(2**20),b''):
     h.update(chunk)
     if dst:dst.write(chunk)
    if dst:dst.close();p.chmod(m.mode)
    row={'sha256':h.hexdigest(),'bytes':m.size,'mode':m.mode}
   if materialize and n in changed and m.issym():
    p=materialize/n;p.parent.mkdir(parents=True,exist_ok=True);p.symlink_to(m.linkname)
   assert not (materialize and n in changed and m.islnk()),'Changed base hardlink requires explicit materialization'
   rows[n]=row
 pending={n for n,r in rows.items() if 'hardlink' in r}
 while pending:
  ready=[n for n in pending if rows[n]['hardlink'] in rows and 'hardlink' not in rows[rows[n]['hardlink']]];assert ready,('unresolved hardlink',path.name)
  for n in ready:
   mode=rows[n]['mode'];rows[n]=dict(rows[rows[n]['hardlink']]);rows[n]['mode']=mode;pending.remove(n)
 return rows
def verify_rows(rows,expected,label,modes=True):
 assert set(rows)==set(expected),(label,'path-set',len(rows),len(expected),list(set(rows)^set(expected))[:5])
 for n,w in expected.items():
  a=rows[n]
  if isinstance(w,str):assert a.get('sha256')==w,(label,n)
  elif w.get('directory'):assert a.get('directory') and (not modes or a['mode']==w['mode']),(label,n)
  elif 'symlink' in w or 'target' in w:assert a.get('symlink')==w.get('symlink',w.get('target')),(label,n)
  else:
   assert a.get('sha256')==w.get('sha256') and ('bytes' not in w or a.get('bytes')==w['bytes']),(label,n)
   if modes and 'mode' in w:assert a['mode']==w['mode'],(label,'mode',n)
 R[label]=len(rows);print(label,len(rows),'archive entries exact',flush=True)
def main():
 assert sha(S/'snapshot.json')=='bda8941e95012e55786fc93f95e5c3ce73ce6dcf1a35ccfc275b73cfcbbde80c';R['snapshot_sha256']=sha(S/'snapshot.json')
 desc=json.loads((S/'snapshot.json').read_text());assert git('rev-parse','HEAD').decode().strip()==desc['head'];assert not git('diff','--cached','--name-only')
 assert git('diff','--binary','HEAD')==(S/'tracked.patch').read_bytes();R['patch_sha256']=sha(S/'tracked.patch')
 assert S.stat().st_mode&0o777==0o555
 assert {p.name for p in S.iterdir()}==set(desc['artifacts'])|{'snapshot.json'}
 for n,v in desc['artifacts'].items():
  p=S/n;assert not p.stat().st_mode&0o222 and p.stat().st_size==v['bytes'] and sha(p)==v['sha256'],('artifact',n)
 R['artifact_hashes']=len(desc['artifacts']);print('artifact hashes exact',len(desc['artifacts']),flush=True)
 man=json.loads((S/'source-manifest.json').read_text());filesystem(ROOT,man,'live')
 rec=json.loads((S/'independent-reconstruction.json').read_text());assert rec['outside_every_checkout'] and rec['patch_child_exit']==0
 recon=pathlib.Path(rec['workspace']);assert subprocess.run(['git','rev-parse','--is-inside-work-tree'],cwd=recon,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0
 filesystem(recon,man,'complete_materialized')
 changed=set(filter(None,git('diff','--name-only','HEAD','-z').decode().split('\0')));scratch=pathlib.Path(tempfile.mkdtemp(prefix='quod-m3b-coordinator-binary-patch-'))
 base=stream(S/'base.tar.gz',materialize=scratch,changed=changed)
 p=subprocess.run(['git','apply','--binary',str(S/'tracked.patch')],cwd=scratch,capture_output=True);assert p.returncode==0,p.stderr.decode();R['independent_binary_patch_child_exit']=p.returncode
 for n in changed:
  p=scratch/n
  if p.is_symlink():base[n]={'symlink':str(p.readlink()),'mode':stat.S_IMODE(p.lstat().st_mode)}
  elif p.is_file():base[n]={'sha256':sha(p),'bytes':p.stat().st_size,'mode':stat.S_IMODE(p.stat().st_mode)}
  else:base.pop(n,None)
 new=stream(S/'untracked.tar.xz');assert not set(base)&set(new);base.update(new)
 assert set(base)==set(man)
 for n,w in man.items():
  a=base[n]
  if w['kind']=='symlink':assert a.get('symlink')==w['target'],('reconstruction',n)
  else:assert a.get('sha256')==w['sha256'] and a.get('bytes')==w['bytes'] and a['mode']&0o111==w['mode']&0o111,('reconstruction',n)
 R['independent_reconstructed_entries']=len(base);R['independent_patch_scratch']=str(scratch);print('independent complete source stream and actual patch exact',len(base),flush=True)
 clean=json.loads((S/'clean-inputs.json').read_text());assert not clean['compiled_application_inputs_copied'];q=json.loads((S/'server-qualification.json').read_text());client=json.loads((S/'client-qualification.json').read_text())
 si=json.loads((E/'inputs/gates01-source-manifest.json').read_text());ss=pathlib.Path(si['stage'])/'source';cs=pathlib.Path(client['source'])
 for n,h in clean['server_authored_inputs'].items():assert sha(ROOT/n)==h and sha(ss/n)==h,('server input',n)
 for n,h in clean['client_authored_inputs'].items():assert sha(ROOT/n)==h and sha(cs/n)==h,('client input',n)
 for n,h in client['export_outputs'].items():assert sha(cs/n)==(h if isinstance(h,str) else h['sha256']),('current export',n)
 R['server_inputs']=len(clean['server_authored_inputs']);R['client_inputs']=len(clean['client_authored_inputs']);R['current_client_exports']=len(client['export_outputs'])
 assert client['passed'] and client['authored_inputs_unchanged'] and q['authored_inputs_unchanged'] and not client['compiled_application_inputs_copied']
 verify_rows(stream(S/'server-compiled-outputs.tar.gz',True),q['compiled_outputs']|q['native_packaged_outputs'],'compiled_archive_entries')
 verify_rows(stream(S/'local-release-outputs.tar.gz',True),q['packaged_release_outputs'],'complete_release_entries')
 verify_rows(stream(S/'derived-rebar-outputs.tar.gz',True),q['derived_rebar_indexes'],'derived_rebar_outputs')
 for label,archive,index,wrapper,dirs in [('native_build','native-build-outputs.tar.gz','native-build-outputs.json',None,True),('client_build','client-build-outputs.tar.gz','client-build-outputs.json','entries',False),('client_export','client-export.tar.gz','client-export-outputs.json',None,False),('fixture_providers','fixture-code-and-provider-outputs.tar.gz','fixture-code-and-provider-outputs.json','entries',False)]:
  expected=json.loads((S/index).read_text());expected=expected[wrapper] if wrapper else expected
  verify_rows(stream(S/archive,dirs),expected,label+'_entries')
 providers=json.loads((S/'provider-compiled-outputs.json').read_text());expected={label+'/'+n:r for label,items in providers.items() for n,r in items.items()};verify_rows(stream(S/'provider-compiled-outputs.tar.gz'),expected,'original_provider_entries')
 verify_rows(stream(S/'prerequisite-r1-dependency-inputs.tar.gz'),clean['dependency_sources'],'dependency_input_entries')
 for n,row in (q['compiled_outputs']|q['native_packaged_outputs']).items():assert sha(ss/n)==row['sha256'],('current compiled',n)
 g=json.loads((E/'gates01-result.json').read_text());assert g['source_unchanged'] and g['all_true_exits_zero'] and not g['explicitly_stopped'] and not g['unrun'] and len(g['results'])==6
 for row in g['results']:
  assert row['child_exit']==0 and row['completion_confirmed'] and not row['timed_out']
  assert sha(E/'logs'/pathlib.Path(row['private_raw_log']).name)==row['sanitized_sha256']
 R['six_qualified_gate_receipts_and_log_hashes']=True
 serial=json.loads((E/'serial-final03-result.json').read_text());assert serial['passed'] and len(serial['results'])==3 and all(r['child_exit']==0 for r in serial['results'])
 for label in ['final-navigation-final03','final-gui-final03','final-spaces-final03']:
  d=json.loads((E/(label+'-campaign.json')).read_text());assert d['passed'] and d['server_child_exit']==0 and all(r['child_exit']==0 for r in d['commands'])
  for n,h in d['driver_inputs'].items():assert sha(ROOT/n)==h,('final driver input',n)
 physics=json.loads((E/'physics-final03/campaign.json').read_text());assert physics['passed'] and physics['client_child_exit']==physics['server_child_exit']==0
 pr=json.loads((E/'physics-final03/client-result.json').read_text());assert pr['passed'] and len(pr['checks'])==29
 R['final_production_campaigns_verified']=True;R['physical_checks']=len(pr['checks']);R['head']=desc['head'];R['tests_rerun']=False
 R['status']='passed'
try:main()
except Exception as ex:R['status']='failed';R['error']=repr(ex);R['traceback']=traceback.format_exc();print(R['traceback'],flush=True)
R['completed_epoch']=time.time();out=OUT/'independent-verification-02.json';assert not out.exists();out.write_text(json.dumps(R,indent=2)+'\n');print(json.dumps(R,indent=2),flush=True);raise SystemExit(R['status']!='passed')
