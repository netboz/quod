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
    def owned_window(title):
        windows=json.loads(subprocess.check_output(['hyprctl','-j','clients']))
        owned=[w for w in windows if w.get('pid')==pid and w.get('mapped') and w.get('title')==title]
        if len(owned)!=1:raise RuntimeError('Native input must name one exact owned visible window')
        return owned[0]
    def geometry(window):
        return {k:window[k] for k in ('address','at','size')}
    def run(command, require_focus=True, target=None):
        nonlocal before
        environment=dict(os.environ,YDOTOOL_SOCKET=str(Path('/run/user')/str(os.getuid())/'.ydotool_socket'))
        child = subprocess.run(command, capture_output=True, text=True, timeout=5,env=environment)
        after = json.loads(subprocess.check_output(['hyprctl', '-j', 'activewindow']))
        records.append({'command': command, 'child_exit': child.returncode,
            'stdout': child.stdout, 'stderr': child.stderr, 'owned_pid': pid,
            'before_pid': before.get('pid'), 'after_pid': after.get('pid'), 'target_geometry':target})
        if child.returncode or (require_focus and after.get('pid') != pid):
            raise RuntimeError('Native qualification input lost its owned window')
        before = after
    if key_event:
        if before.get('pid') != pid:
            run(['hyprctl', 'dispatch', 'hl.dsp.focus({window="pid:' + str(pid) + '"})'])
        key=line.split()[1]
        if key in ('hold-w','release-w'):run(['ydotool','key','17:1' if key=='hold-w' else '17:0'])
        elif key in ('space','Return','F24'):run(['wtype', '-k', key])
        else:raise RuntimeError('Unsupported native key')
    else:
        payload=json.loads(line.split(' ',1)[1])
        window=owned_window(payload['title'])
        address=window['address']
        if before.get('address')!=address:
            run(['hyprctl','dispatch','hl.dsp.focus({window="address:'+address+'"})'],target=geometry(window))
        current=owned_window(payload['title'])
        if current['address']!=address or current['size']!=window['size']:
            raise RuntimeError('Native input target changed layout before dispatch')
        window=current
        if close_event:
            # Addressed close may legitimately retire its focused window.
            # The campaign separately requires the real process exit and EOF.
            run(['hyprctl','dispatch','hl.dsp.window.close({window="address:'+address+'"})'],False,geometry(window))
        else:
            x,y,width,height=(float(payload[k]) for k in ['x','y','width','height'])
            if not (0<=x<width and 0<=y<height):raise RuntimeError('Native pointer lies outside its exact window')
            screen_x=round(window['at'][0]+x*window['size'][0]/width)
            screen_y=round(window['at'][1]+y*window['size'][1]/height)
            run(['hyprctl','dispatch',f'hl.dsp.cursor.move({{x={screen_x},y={screen_y}}})'],target=geometry(window))
            current=owned_window(payload['title'])
            cursor=json.loads(subprocess.check_output(['hyprctl','-j','cursorpos']))
            left,top=current['at'];width,height=current['size']
            if geometry(current)!=geometry(window) or not (left<=cursor['x']<left+width and top<=cursor['y']<top+height) or abs(cursor['x']-screen_x)>1 or abs(cursor['y']-screen_y)>1:
                records.append({'refused_before_click':True,'owned_pid':pid,'requested':[screen_x,screen_y],'actual_cursor':cursor,'target_geometry':geometry(current)})
                raise RuntimeError('Native pointer did not remain inside its exact owned window')
            run(['ydotool','click','0xC0'],target=geometry(current))
