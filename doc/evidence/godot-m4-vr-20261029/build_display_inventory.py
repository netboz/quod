import json,shlex,subprocess,sys
from pathlib import Path
from environment import TASK
source=Path(__file__).resolve().parent/'display_inventory.c'
build=TASK/'builds'/('display-inventory'+(sys.argv[1] if len(sys.argv)>1 else '01'));build.mkdir(parents=True,exist_ok=False)
xml=Path('/usr/share/wayland-protocols/staging/drm-lease/drm-lease-v1.xml')
commands=[['wayland-scanner','client-header',str(xml),str(build/'drm-lease-v1-client-protocol.h')],['wayland-scanner','private-code',str(xml),str(build/'drm-lease-v1-protocol.c')]]
flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','libdrm'],text=True))
commands.append(['cc','-std=c11','-Wall','-Wextra','-Werror','-O2','-I'+str(build),str(source),str(build/'drm-lease-v1-protocol.c'),*flags,'-o',str(build/'display-inventory')])
for command in commands:print(json.dumps(command),flush=True);subprocess.run(command,check=True)
