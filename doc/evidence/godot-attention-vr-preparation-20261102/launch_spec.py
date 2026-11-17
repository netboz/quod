"""Pure launch arguments for the current removable companion and owned fixture."""
from pathlib import Path

def port(value):
    if type(value) is not int or not 0<value<65536:raise ValueError('invalid fresh fixture port')
    return str(value)

def fixture_environment(ready,private,runtime):
    return {'XR_RUNTIME_JSON':str(runtime),'QT_QPA_PLATFORM':'xcb',
            'M1B_PHASE':'vr-ready263','M1B_NETWORK':ready['network'],
            'M1B_CONTROL_PORT':port(ready['control_port']),'VR263_PRIVATE':str(private)}

def client_arguments(executable,private,server,ready):
    return [str(executable),'--display-driver','wayland','--audio-driver','Dummy',
            '--xr-mode','on','--rendering-method','mobile','--rendering-driver','vulkan',
            '--verbose','--','--qualification','--profile',str(Path(private)/'profile'),
            '--node','https://127.0.0.1:'+port(ready['port']),'--ca',str(Path(server)/'backend-ca.pem')]
