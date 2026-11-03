"""Bind retained primary protocol source and qualified execution dependencies."""
import hashlib,json,os,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,key,raw
os.umask(0o077);ev=Path(__file__).resolve().parent;root=Path.cwd();d=Digests()
def load(p):return json.loads(Path(p).read_text())
version=load(ev/'compositor-version.json');commit='efb50993780079460b0cbed1363e2166a2de1d9f'
assert version['commit']==commit and not version['dirty']
treefile=TASK/'downloads/hyprland-efb509-tree.json';tree=load(treefile);assert not tree['truncated']
entries={r['path']:r for r in tree['tree']};sources={}
for local,name in [('hyprland-efb509-event-manager.cpp','src/managers/EventManager.cpp'),
 ('hyprland-efb509-compositor.cpp','src/Compositor.cpp'),('hyprland-efb509-focus-state.cpp','src/desktop/state/FocusState.cpp')]:
 p=TASK/'downloads'/local;data=p.read_bytes();receipt=load(p.with_name(p.name+'.receipt.json'))
 digest=hashlib.sha256(data).hexdigest();blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
 assert receipt['status']==200 and receipt['sha256']==digest and blob==entries[name]['sha']
 assert receipt['url']==f'https://raw.githubusercontent.com/hyprwm/Hyprland/{commit}/{name}'
 sources[name]={'path':str(p),'sha256':digest,'bytes':len(data),'git_blob':blob,'url':receipt['url']}
protocol={'reported_compositor':version,'primary_sources':sources,'tree_index_sha256':raw(treefile),
 'format':'event>>data followed by newline; data capped1024 bytes by provider',
 'event':'activewindowv2; lowercase hexadecimal uintptr without0x; empty means no focused window',
 'path':'XDG_RUNTIME_DIR/hypr/HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock',
 'ordering':'Socket connected before initial owner snapshot; FIFO events never discarded or overwritten by snapshot. No provider subscription acknowledgement or cross-socket snapshot barrier/sequence is exposed.',
 'prepared_listener_armed':False,'closed_case10_extension':'UNRUN: instruction81 arrived after normal retirement.',
 'web_documentation_failure':'web open https://wiki.hypr.land/IPC/ returned404; retained primary pinned source was used instead.'}
(ev/'protocol-provenance.json').write_text(json.dumps(protocol,indent=2)+'\n')
prior=TASK/'artifacts/quod-godot-m4-vive-retest-handoff-ca84d4f8-20261030-01'
source=load(prior/'source-manifest.json');name='doc/evidence/godot-m4-r2-20261029/inputs/runtime-compatible02-install.json'
assert d.h(root/name)==source[name]['sha256']
installed=load(root/name);assert installed['commit']=='59be345db769a89c93d1bdf6ed8316fa6209d8ae' and installed['child_exit']==0
prefix=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime/monado-compatible02-install');outputs={}
for name in ['bin/monado-service','bin/monado-ctl','lib/libopenxr_monado.so','share/openxr/1/openxr_monado.json']:
 p=prefix/name;r=installed['installed_outputs'][name];before=key(p);cached=before in d.values
 assert r['link'] is None and not p.is_symlink() and p.stat().st_mode==int(r['mode'],8)
 assert d.h(p)==r['sha256']
 outputs[name]={'sha256':r['sha256'],'actual_bytes':p.stat().st_size,'full_mode':oct(p.stat().st_mode),'stat_key':before,'strict_cache_hit':cached}
record=load(root/'doc/evidence/godot-m4-vive-retest-20261030/native-vive-product10/result.json')
assert record['runtime_manifest_sha256']==outputs['share/openxr/1/openxr_monado.json']['sha256']
assert record['runtime_command'][-1]==str(prefix/'bin/monado-service')
(ev/'runtime-binding.json').write_text(json.dumps({'passed':True,'scope':'Actual invoked paths plus unchanged qualified file identities; no whole-host or memory-image claim.',
 'commit':installed['commit'],'outputs':outputs,'new_build_or_runtime_execution':False},indent=2)+'\n')
cache=TASK/'cache/case10-provenance-hashes.json';d.write(cache)
(ev/'provenance-cache.json').write_text(json.dumps({'path':str(cache),'sha256':raw(cache),'new_hashes':d.new,'new_bytes':d.bytes,'strict_hits':d.hits},indent=2)+'\n')
print(json.dumps({'passed':True,'primary_protocol_source_files':len(sources),'runtime_identity_files':len(outputs),'listener_armed':False,'strict_hits':d.hits,'new_bytes':d.bytes}))
