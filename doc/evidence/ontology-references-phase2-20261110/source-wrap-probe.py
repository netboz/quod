import os,pathlib,subprocess,sys
r=pathlib.Path('/home/yan/src/quod_worktrees/pearl-stone')
command=[str(r/'client/_build/godot-clean/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64'),'--headless','--xr-mode','off','--path',str(r/'client/godot'),'--script','/tmp/pearl-phase2-wrap-probe.gd']
p=subprocess.Popen(command,env=dict(os.environ,WRAP_PROBE=sys.argv[1]))
try: result=p.wait(timeout=20)
except subprocess.TimeoutExpired:
 p.terminate(); result=p.wait(timeout=5);print('PROBE_WATCHDOG child_exit='+str(result),flush=True)
sys.exit(result)
