"""Thin system-library filesystem, with no developer tree, SDK or package cache."""
import os
from pathlib import Path

def command(package,private,arguments,wayland=False,network=False):
    private=Path(private);private.mkdir(mode=0o700,exist_ok=True)
    for n in ['home','tmp','work','runtime']:(private/n).mkdir(mode=0o700,exist_ok=True)
    cmd=['bwrap','--die-with-parent','--new-session','--unshare-ipc','--unshare-uts','--clearenv',
        '--ro-bind','/usr/lib','/usr/lib','--symlink','usr/lib','/lib','--symlink','usr/lib','/lib64',
        '--dir','/bin','--ro-bind','/usr/bin/bash','/bin/sh','--ro-bind','/usr/bin/dirname','/bin/dirname',
        '--ro-bind','/usr/share/fonts','/usr/share/fonts','--ro-bind','/etc/fonts','/etc/fonts',
        '--ro-bind','/usr/share/xkeyboard-config-2','/usr/share/xkeyboard-config-2',
        '--ro-bind','/usr/share/X11','/usr/share/X11',
        '--ro-bind','/usr/share/glvnd','/usr/share/glvnd',
        '--ro-bind','/usr/share/drirc.d','/usr/share/drirc.d',
        '--ro-bind','/etc/ld.so.cache','/etc/ld.so.cache','--ro-bind','/etc/ssl','/etc/ssl',
        '--proc','/proc','--dev','/dev','--ro-bind',str(package),'/opt/Quod app',
        '--bind',str(private/'home'),'/home/test','--bind',str(private/'tmp'),'/tmp',
        '--bind',str(private/'work'),'/work','--bind',str(private/'runtime'),'/run/user/1000',
        '--chdir','/work','--setenv','HOME','/home/test','--setenv','PATH','/bin',
        '--setenv','XDG_DATA_HOME','/home/test/data','--setenv','XDG_CONFIG_HOME','/home/test/config',
        '--setenv','DOTNET_ROOT','/no-installed-dotnet','--setenv','LANG','C.UTF-8',
        '--setenv','XDG_RUNTIME_DIR','/run/user/1000','--setenv','GODOT_SILENCE_ROOT_WARNING','1',
        '--setenv','LIBGL_ALWAYS_SOFTWARE','1']
    if not network:cmd+=['--unshare-net']
    if wayland:
        socket=Path(os.environ['XDG_RUNTIME_DIR'])/os.environ['WAYLAND_DISPLAY']
        cmd+=['--ro-bind',str(socket),'/run/user/1000/wayland-1','--setenv','WAYLAND_DISPLAY','wayland-1']
    return cmd+['--','/opt/Quod app/quod',*arguments]
