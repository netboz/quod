"""Task-private process paths; preserve the user's actual display socket access."""
import os
from pathlib import Path
TASK=Path('/data/quod-m4-vr-ca84d4f8-20261029')
def environment():
    env=dict(os.environ)
    for key in ['LD_PRELOAD','LD_LIBRARY_PATH']:env.pop(key,None)
    paths={'TMPDIR':TASK/'tmp','TMP':TASK/'tmp','TEMP':TASK/'tmp',
        'XDG_CACHE_HOME':TASK/'cache/xdg','XDG_DATA_HOME':TASK/'cache/data','XDG_CONFIG_HOME':TASK/'cache/config','DOTNET_CLI_HOME':TASK/'cache/dotnet-home',
        'NUGET_PACKAGES':TASK/'cache/nuget','NUGET_HTTP_CACHE_PATH':TASK/'cache/nuget-http',
        'NUGET_PLUGINS_CACHE_PATH':TASK/'cache/nuget-plugins','PIP_CACHE_DIR':TASK/'cache/pip',
        'SCCACHE_DIR':TASK/'cache/sccache','CCACHE_DIR':TASK/'cache/ccache'}
    for key,path in paths.items():path.mkdir(mode=0o700,parents=True,exist_ok=True);env[key]=str(path)
    env['PYTHONDONTWRITEBYTECODE']='1';env['MSBUILDDISABLENODEREUSE']='1'
    # XDG_RUNTIME_DIR/WAYLAND_DISPLAY/DISPLAY stay compatible with the actual
    # compositor. An owned runtime may separately use a private IPC directory
    # while retaining an explicit absolute compositor socket.
    return env
