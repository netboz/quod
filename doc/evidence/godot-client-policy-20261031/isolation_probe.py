"""Verify the exact qualified filesystem composition has no development tools."""
import json,os,subprocess
from pathlib import Path
from hashes import TASK
from isolation import command
os.umask(0o077);ev=Path(__file__).resolve().parent;private=TASK/'private/policy-isolation-probe01'
package=Path(json.loads((ev/'inputs/package-inspection02.json').read_text())['extracted'])
cmd=command(package,private,[])
cmd=cmd[:cmd.index('--')]+['--','/bin/sh','-c','set -eu; for tool in dotnet godot python python3 node cargo rebar3; do if command -v "$tool" >/dev/null; then exit 1; fi; done; test ! -e /home/yan; test ! -e /data; test ! -e /opt/dotnet; test -x "/opt/Quod app/quod"; test "$PWD" = /work']
r=subprocess.run(cmd,capture_output=True,timeout=10);assert r.returncode==0 and not r.stdout and not r.stderr
(ev/'inputs/isolation-probe01.json').write_text(json.dumps({'passed':True,'true_exit':r.returncode,'absent_tools':['dotnet','godot','python','python3','node','cargo','rebar3'],'developer_home_Data_SDK_absent':True,'cwd':'/work','package_path_contains_spaces':True,'command':cmd,'native_app_started':False},indent=2)+'\n')
print('PASS actual isolated environment has no developer tree or build tools')
