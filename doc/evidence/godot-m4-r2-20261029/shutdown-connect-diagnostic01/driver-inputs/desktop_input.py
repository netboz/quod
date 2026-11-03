"""Native desktop qualification input, scoped to the owned application PID."""
import json
import subprocess
import os
from pathlib import Path

def deliver(line, pid, desktop, records):
    key_event=line.startswith('M2_NATIVE_KEY ')
    click_event=line.startswith('M2_NATIVE_CLICK ')
    close_event=line.startswith('M2_NATIVE_CLOSE ')
    if not key_event and not click_event and not close_event:
        return
    if not desktop:
        raise RuntimeError('Unsupported native qualification input')
    before = json.loads(subprocess.check_output(['hyprctl', '-j', 'activewindow']))
    commands = []
    if key_event:
        if before.get('pid') != pid:
            commands.append(['hyprctl', 'dispatch', 'hl.dsp.focus({window="pid:' + str(pid) + '"})'])
        key=line.split()[1]
        if key in ('hold-w','release-w'):commands.append(['ydotool','key','17:1' if key=='hold-w' else '17:0'])
        elif key in ('space','Return','F24'):commands.append(['wtype', '-k', key])
        else:raise RuntimeError('Unsupported native key')
    else:
        payload=json.loads(line.split(' ',1)[1])
        windows=json.loads(subprocess.check_output(['hyprctl','-j','clients']))
        owned=[w for w in windows if w.get('pid')==pid and w.get('mapped') and w.get('title')==payload['title']]
        if len(owned)!=1:raise RuntimeError('Native input must name one exact owned visible window')
        window=owned[0]
        address=window['address']
        if before.get('address')!=address:
            commands.append(['hyprctl','dispatch','hl.dsp.focus({window="address:'+address+'"})'])
        if close_event:
            commands.append(['hyprctl','dispatch','hl.dsp.window.close({window="address:'+address+'"})'])
        else:
            x,y,width,height=(float(payload[k]) for k in ['x','y','width','height'])
            if not (0<=x<width and 0<=y<height):raise RuntimeError('Native pointer lies outside its exact window')
            screen_x=round(window['at'][0]+x*window['size'][0]/width)
            screen_y=round(window['at'][1]+y*window['size'][1]/height)
            commands.append(['hyprctl','dispatch',f'hl.dsp.cursor.move({{x={screen_x},y={screen_y}}})'])
            commands.append(['ydotool','click','0xC0'])
    for command in commands:
        environment=dict(os.environ,YDOTOOL_SOCKET=str(Path('/run/user')/str(os.getuid())/'.ydotool_socket'))
        child = subprocess.run(command, capture_output=True, text=True, timeout=5,env=environment)
        after = json.loads(subprocess.check_output(['hyprctl', '-j', 'activewindow']))
        records.append({'command': command, 'child_exit': child.returncode,
            'stdout': child.stdout, 'stderr': child.stderr, 'owned_pid': pid,
            'before_pid': before.get('pid'), 'after_pid': after.get('pid')})
        if child.returncode or after.get('pid') != pid:
            raise RuntimeError('Native qualification input lost its owned window')
        before = after
