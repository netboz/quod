"""Fresh official extraction, actual patch application, then clean native build.

No compiled native/application input is copied. The earlier immutable matched
counterfactual remains unchanged. This adds the clean final-engine prerequisite.
"""
import hashlib,json,os,re,shutil,subprocess,sys,tarfile
from pathlib import Path
from environment import TASK,environment
ev=Path(__file__).resolve().parent;root=Path.cwd()
assert len(sys.argv)==2 and re.fullmatch(r'clean[0-9]{2}',sys.argv[1]);label=sys.argv[1]
stage=TASK/'builds'/('engine-'+label);stage.mkdir(mode=0o700,exist_ok=False)
archive=TASK/'downloads/godot-4.7.2-stable.tar.xz'
def h(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
assert h(archive)=='a18ce0ccec3ecc40b0dd6c4f5132ca934e9fb7c2979717940ff32aee1eb35481'
assert shutil.disk_usage(TASK).free>5*1024**3
with tarfile.open(archive) as bundle:bundle.extractall(stage,filter='data')
source=stage/'godot-4.7.2-stable';old=TASK/'builds/engine01'
manifest=json.loads((old/'original-source-manifest.json').read_text())
actual={}
for directory,dirs,files in os.walk(source,followlinks=False):
    for name in dirs+files:actual[str((Path(directory)/name).relative_to(source))]=Path(directory)/name
assert set(actual)=={r['path'] for r in manifest},'Full original source path mismatch'
for row in manifest:
    p=actual[row['path']];assert p.lstat().st_mode&0o7777==row['mode'],row['path']
    if row['type']=='file':assert h(p)==row['sha256'],row['path']
    elif row['type']=='symlink':assert p.is_symlink() and str(p.readlink())==row['target'],row['path']
patch=ev/'godot-4.7.2-openxr-lifetimes.patch'
assert h(patch)=='06e06c0670bc1ebf3b25f6946bdbcbf48ab674d89e90a5d399a9dbca06e31fed'
assert subprocess.run(['git','rev-parse','--show-toplevel'],cwd=source,capture_output=True).returncode!=0
command=['git','apply','--check',str(patch)];subprocess.run(command,cwd=source,check=True)
subprocess.run(['git','apply',str(patch)],cwd=source,check=True)
changed=json.loads((TASK/'artifacts/engine/patch01/manifest.json').read_text())
original_modes={row['path']:row['mode'] for row in manifest};patch_modes={}
for name in changed:
    p=source/name;patch_modes[name]={'after_git_apply':p.stat().st_mode&0o7777,'official_archive_mode':original_modes[name]}
    p.chmod(original_modes[name])
for row in manifest:
    p=source/row['path'];assert p.lstat().st_mode&0o7777==row['mode'],row['path']
    if row['type']=='file':assert h(p)==changed.get(row['path'],{}).get('after',row['sha256']),row['path']
proof={'official_archive_sha256':h(archive),'original_entries':len(manifest),'full_official_original_path_content_link_modes_verified':True,'actual_patch_check_command':command,'actual_patch_apply_command':['git','apply',str(patch)],'patch_sha256':h(patch),'exact_final_authored_input_deltas':changed,'explicit_original_mode_restoration_after_git_apply':patch_modes,'complete_patched_input_content_modes_verified':True,'source':str(source),'outside_every_checkout':True,'compiled_inputs_copied':False,'scope':'New actual full official source extraction and real patch application before a clean build; not a copy of earlier generated native inputs. Git apply creates replacement files under the private077 umask; restore exact recorded official authored-file modes before full verification.'}
(stage/'source-reconstruction.json').write_text(json.dumps(proof,indent=2)+'\n')
print('M4_CLEAN_ENGINE_SOURCE_RECONSTRUCTION_PASS',flush=True)
env=environment();env['PYTHONPATH']=str(TASK/'cache/tools/scons-4.11.1');env['XDG_DATA_HOME']=str(TASK/'cache/engine-data');env['XDG_CONFIG_HOME']=str(TASK/'cache/engine-config')
build=[sys.executable,'-m','SCons','platform=linuxbsd','target=template_release','arch=x86_64','module_mono_enabled=yes','-j6','lto=none']
print(json.dumps({'command':build,'cwd':str(source),'clean':True}),flush=True)
subprocess.run(build,cwd=source,env=env,check=True)
binary=source/'bin/godot.linuxbsd.template_release.x86_64.mono'
out=TASK/'artifacts/engine'/label;out.mkdir(mode=0o700,exist_ok=False)
shutil.copy2(binary,out/binary.name)
receipt={'passed':True,'source':str(source),'binary':str(out/binary.name),'sha256':h(binary),'bytes':binary.stat().st_size,'earlier_patched_sha256':'02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268','byte_identical_to_qualified_patched_template':h(binary)=='02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268','clean_source_only':True,'compiled_inputs_copied':False,'command':build,'original_source_entries':len(manifest),'patch_sha256':h(patch)}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print('M4_CLEAN_ENGINE_BUILD_PASS '+json.dumps(receipt),flush=True)
