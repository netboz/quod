"""Run the offline recipe's real argv builder through a harmless finite child."""
import json,os,shutil,subprocess
from pathlib import Path
from launch_recipe import client_arguments
from hashes import TASK,raw
os.umask(0o077);ev=Path(__file__).resolve().parent
private=TASK/'private/attention-package-launch-arguments01';private.mkdir(mode=0o700,exist_ok=False)
package=private/'package with spaces';package.mkdir()
shutil.copy2(Path.cwd()/'client/godot-tools/package/quod',package/'quod')
child=package/'quod.x86_64';child.write_text('#!/bin/sh\nprintf "%s\\000" "$@"\nexit 37\n');child.chmod(0o755)
argv=client_arguments(package,private/'profile with spaces',14570,private/'CA $(literal).pem')
r=subprocess.run(argv,capture_output=True,timeout=5)
assert r.returncode==37 and not r.stderr and r.stdout.split(b'\0')[:-1]==[s.encode() for s in argv[1:]]
assert '--qualification' not in argv and argv[argv.index('--xr-mode')+1]=='on'
checks=['real offline builder preserves literal argv through package launcher and true child exit','ordinary VR arguments use Vulkan/mobile and no qualification flag']
for port in [0,65536,'14570']:
    try:client_arguments(package,private/'profile',port,private/'ca');raise AssertionError('invalid port accepted')
    except ValueError:checks.append('invalid fixture port rejected: '+str(port))
record={'passed':True,'checks':checks,'count':len(checks),'finite_child_exit':37,'application_runtime_or_fixture_launched':False,
        'builder_sha256':raw(ev/'launch_recipe.py'),'argv':argv}
(ev/'inputs/launch-arguments01.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record))
