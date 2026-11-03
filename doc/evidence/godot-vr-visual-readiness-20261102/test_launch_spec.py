"""Exercise actual argv/environment owner with a harmless finite parser child."""
import json,subprocess,sys
from launch_spec import fixture_environment,client_arguments

checks=[]
def check(value,name):
    assert value,name
    checks.append(name);print('PASS '+name)
ready={'port':32123,'control_port':32124,'network':'test-network'}
private='/private/test space; $(no-execution)';server='/private/fixture space'
env=fixture_environment(ready,private,'/installed SteamVR/steamxr_linux64.json')
check(env['M1B_CONTROL_PORT']=='32124' and env['M1B_NETWORK']=='test-network','fresh M1B_READY binds original-outcome resolution to its actual owned control port')
check(env['QT_QPA_PLATFORM']=='xcb' and env['XR_RUNTIME_JSON']=='/installed SteamVR/steamxr_linux64.json','Qt xcb and SteamVR selection are process-only overrides')
check('DISPLAY' not in env and 'WAYLAND_DISPLAY' not in env and 'QT_PLUGIN_PATH' not in env,'actual display/socket/plugin settings are inherited without replacement')
argv=client_arguments('/private/current companion',private,server,ready)
child=subprocess.run([sys.executable,'-B','-c','import json,sys;print(json.dumps(sys.argv[1:]));raise SystemExit(37)',*argv],capture_output=True,text=True,timeout=5)
check(child.returncode==37 and json.loads(child.stdout)==argv and child.stderr=='','literal spaces and shell punctuation reach the finite child unchanged with true exit37 and EOF')
check(argv[argv.index('--display-driver')+1]=='wayland' and argv[argv.index('--rendering-method')+1]=='mobile' and argv[argv.index('--rendering-driver')+1]=='vulkan','Godot retains its explicit Wayland Vulkan mobile path')
check(argv[argv.index('--node')+1]=='https://127.0.0.1:32123' and argv[argv.index('--ca')+1]==server+'/backend-ca.pem','the current fixture endpoint and CA are exact literal arguments')
for key in ['port','control_port']:
    bad={**ready,key:0}
    try:fixture_environment(bad,private,'runtime') if key=='control_port' else client_arguments('exe',private,server,bad)
    except ValueError:check(True,'invalid '+key+' is refused without invoking an application')
    else:raise AssertionError(key)
print('LAUNCH_SPEC_PASS '+json.dumps({'checks':len(checks),'finite_child_exit':37,'eof':True,'application_or_fixture_or_runtime':False}))
