"""Pinned private native template build; application sources are not build inputs."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
from environment import TASK,environment
stage=sys.argv[1]
source=TASK/'builds/engine01/godot-4.7.2-stable'
env=environment();env['PYTHONPATH']=str(TASK/'cache/tools/scons-4.11.1')
env['XDG_DATA_HOME']=str(TASK/'cache/engine-data');env['XDG_CONFIG_HOME']=str(TASK/'cache/engine-config')
command=[sys.executable,'-m','SCons','platform=linuxbsd','target=template_release','arch=x86_64','module_mono_enabled=yes','-j6','lto=none']
print(json.dumps({'command':command,'cwd':str(source),'stage':stage}),flush=True)
subprocess.run(command,cwd=source,env=env,check=True)
binary=source/'bin/godot.linuxbsd.template_release.x86_64.mono'
out=TASK/'artifacts/engine'/stage;out.mkdir(parents=True,exist_ok=False)
shutil.copy2(binary,out/binary.name)
receipt={'stage':stage,'binary':str(out/binary.name),'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'bytes':binary.stat().st_size,'source_archive_sha256':'a18ce0ccec3ecc40b0dd6c4f5132ca934e9fb7c2979717940ff32aee1eb35481','command':command}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt),flush=True)
